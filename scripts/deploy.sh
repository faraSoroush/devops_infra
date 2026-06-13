#!/usr/bin/env bash
# ─────────────────────────────────────────
# deploy.sh — Full stack deployment script
# Run this from the project root.
# Prerequisites: terraform, ansible, helm, kubectl installed locally.
# ─────────────────────────────────────────
set -euo pipefail

CLUSTER_NAME="soroush-k8s"
KUBESPRAY_VERSION="v2.27.0"
GITLAB_CHART_VERSION="8.2.0"   # GitLab 17.x
MONITORING_CHART_VERSION="65.0.0"  # kube-prometheus-stack
GITLAB_NAMESPACE="gitlab"
MONITORING_NAMESPACE="monitoring"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +%T)] $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +%T)] WARN: $*${NC}"; }
err()  { echo -e "${RED}[$(date +%T)] ERROR: $*${NC}"; exit 1; }

# ─────────────────────────────────────────
# STEP 1: Terraform — provision AWS infra
# ─────────────────────────────────────────
step1_terraform() {
  log "==> STEP 1: Provisioning AWS infrastructure with Terraform..."
  cd terraform/
  terraform init
  terraform validate
  terraform plan -out=tfplan
  terraform apply tfplan
  MASTER_IP=$(terraform output -raw master_public_ip)
  log "Master node IP: $MASTER_IP"
  cd ..
}

# ─────────────────────────────────────────
# STEP 2: Wait for SSH to be available
# ─────────────────────────────────────────
step2_wait_ssh() {
  log "==> STEP 2: Waiting for SSH on all nodes..."
  MASTER_IP=$(cd terraform && terraform output -raw master_public_ip)
  WORKER_IPS=$(cd terraform && terraform output -json worker_public_ips | jq -r '.[]')

  for IP in "$MASTER_IP" $WORKER_IPS; do
    log "Waiting for SSH on $IP..."
    until ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
      -i ~/.ssh/id_rsa ubuntu@"$IP" "echo ready" 2>/dev/null; do
      sleep 5
    done
    log "$IP is ready."
  done
}

# ─────────────────────────────────────────
# STEP 3: Kubespray — deploy Kubernetes
# ─────────────────────────────────────────
step3_kubespray() {
  log "==> STEP 3: Deploying Kubernetes with Kubespray..."

  # Clone Kubespray if not present
  if [ ! -d "kubespray-src" ]; then
    git clone --depth=1 --branch "$KUBESPRAY_VERSION" \
      https://github.com/kubernetes-sigs/kubespray.git kubespray-src
  fi

  cd kubespray-src/

  # Install Python dependencies
  pip3 install -r requirements.txt --quiet

  # Copy our inventory
  cp -rfp inventory/sample inventory/cluster 2>/dev/null || true
  cp -f ../kubespray/inventory/cluster/hosts.yaml inventory/cluster/hosts.yaml
  cp -f ../kubespray/inventory/cluster/group_vars/all.yml \
        inventory/cluster/group_vars/all/all.yml
  cp -f ../kubespray/inventory/cluster/group_vars/k8s_cluster.yml \
        inventory/cluster/group_vars/k8s_cluster/k8s-cluster.yml

  # Run playbook
  ansible-playbook -i inventory/cluster/hosts.yaml \
    --become --become-user=root \
    --private-key ~/.ssh/id_rsa \
    cluster.yml \
    -v

  cd ..

  # Fetch kubeconfig
  MASTER_IP=$(cd terraform && terraform output -raw master_public_ip)
  mkdir -p ~/.kube
  scp -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no \
    ubuntu@"$MASTER_IP":/etc/kubernetes/admin.conf ~/.kube/config
  sed -i "s|server: https://.*:6443|server: https://$MASTER_IP:6443|g" ~/.kube/config

  log "Kubeconfig saved. Testing cluster..."
  kubectl get nodes
}

# ─────────────────────────────────────────
# STEP 4: Install Helm + Monitoring Stack
# ─────────────────────────────────────────
step4_monitoring() {
  log "==> STEP 4: Installing Prometheus + Grafana..."

  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm repo update

  kubectl create namespace "$MONITORING_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
    --namespace "$MONITORING_NAMESPACE" \
    --version "$MONITORING_CHART_VERSION" \
    --values helm/monitoring/values.yaml \
    --wait --timeout 10m

  log "Monitoring stack installed."
  log "Grafana: http://grafana.soroush (add to /etc/hosts)"
}

# ─────────────────────────────────────────
# STEP 5: Generate self-signed cert for gitlab.soroush
# ─────────────────────────────────────────
step5_tls() {
  log "==> STEP 5: Generating self-signed TLS certificate for *.soroush..."
  mkdir -p certs/
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout certs/soroush.key \
    -out certs/soroush.crt \
    -subj "/CN=*.soroush/O=Soroush-Demo" \
    -addext "subjectAltName=DNS:gitlab.soroush,DNS:registry.soroush,DNS:minio.soroush,DNS:grafana.soroush"

  kubectl create namespace "$GITLAB_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  # Create wildcard TLS secret
  kubectl create secret tls soroush-wildcard-tls \
    --cert=certs/soroush.crt \
    --key=certs/soroush.key \
    --namespace "$GITLAB_NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

  log "TLS secret created."
}

# ─────────────────────────────────────────
# STEP 6: Install GitLab via Helm
# ─────────────────────────────────────────
step6_gitlab() {
  log "==> STEP 6: Installing GitLab..."

  helm repo add gitlab https://charts.gitlab.io/
  helm repo update

  # Create required secrets
  kubectl create secret generic gitlab-postgresql-password \
    --from-literal=postgresql-password="$(openssl rand -hex 16)" \
    --namespace "$GITLAB_NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic gitlab-redis-secret \
    --from-literal=secret="$(openssl rand -hex 16)" \
    --namespace "$GITLAB_NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic gitlab-minio-secret \
    --from-literal=accesskey="$(openssl rand -hex 8)" \
    --from-literal=secretkey="$(openssl rand -hex 16)" \
    --namespace "$GITLAB_NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic gitlab-runner-secret \
    --from-literal=runner-registration-token="$(openssl rand -hex 16)" \
    --namespace "$GITLAB_NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

  helm upgrade --install gitlab gitlab/gitlab \
    --namespace "$GITLAB_NAMESPACE" \
    --version "$GITLAB_CHART_VERSION" \
    --values helm/gitlab/values.yaml \
    --set global.ingress.tls.secretName=soroush-wildcard-tls \
    --wait --timeout 20m

  log "GitLab installed!"

  # Print initial root password
  log "Fetching initial GitLab root password..."
  kubectl get secret gitlab-gitlab-initial-root-password \
    --namespace "$GITLAB_NAMESPACE" \
    -o jsonpath='{.data.password}' | base64 --decode
  echo ""
}

# ─────────────────────────────────────────
# STEP 7: Configure /etc/hosts entries
# ─────────────────────────────────────────
step7_hosts() {
  log "==> STEP 7: /etc/hosts configuration..."
  MASTER_IP=$(cd terraform && terraform output -raw master_public_ip)
  WORKER1_IP=$(cd terraform && terraform output -json worker_public_ips | jq -r '.[0]')

  echo ""
  warn "Add these lines to your /etc/hosts (or local DNS):"
  echo "────────────────────────────────────────"
  echo "$WORKER1_IP  gitlab.soroush registry.soroush minio.soroush"
  echo "$WORKER1_IP  grafana.soroush"
  echo "────────────────────────────────────────"
  echo ""
  log "GitLab URL: https://gitlab.soroush"
  log "Grafana URL: https://grafana.soroush"
}

# ─────────────────────────────────────────
# Main
# ─────────────────────────────────────────
main() {
  log "Starting full deployment of $CLUSTER_NAME..."
  step1_terraform
  step2_wait_ssh
  step3_kubespray
  step4_monitoring
  step5_tls
  step6_gitlab
  step7_hosts
  log "✅ All done! Your Kubernetes + GitLab stack is ready."
}

# Allow running individual steps
case "${1:-all}" in
  terraform)   step1_terraform ;;
  kubespray)   step3_kubespray ;;
  monitoring)  step4_monitoring ;;
  gitlab)      step5_tls && step6_gitlab ;;
  hosts)       step7_hosts ;;
  all)         main ;;
  *) echo "Usage: $0 [all|terraform|kubespray|monitoring|gitlab|hosts]" ;;
esac
