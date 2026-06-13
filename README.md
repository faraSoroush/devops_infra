# k8s-gitops-infra

Production-style Kubernetes infrastructure on AWS, with self-hosted GitLab CE and a full observability stack.

This project brings together the tools I worked with at ToobaTech — Kubernetes, Helm, GitLab CI/CD, Prometheus/Grafana — and deploys them from scratch on AWS using Terraform and Kubespray.

---

## Architecture

```
AWS Cloud
└── VPC (10.0.0.0/16)
    └── Public Subnet (10.0.1.0/24)
        ├── master1  [t3.xlarge]  — K8s control plane
        ├── worker1  [t3.xlarge]  — GitLab workloads
        └── worker2  [t3.large]   — Prometheus + Grafana
```

### Stack

| Component | Tool | Notes |
|-----------|------|-------|
| Cloud Infra | Terraform | VPC, EC2, SG, key pairs |
| K8s Cluster | Kubespray v2.27 | Ansible-based, production-grade |
| CNI | Calico | NetworkPolicy support |
| Ingress | ingress-nginx | Domain-based routing |
| GitOps/CI | GitLab CE (Helm) | Self-hosted, `gitlab.soroush` |
| CI Runner | GitLab Runner | In-cluster, Docker-in-Docker |
| Monitoring | Prometheus + Grafana | `grafana.soroush` |
| Container Registry | GitLab Registry | `registry.soroush` |
| Object Storage | MinIO (bundled) | S3-compatible |

---

## Why these choices

**Kubespray over kubeadm directly** — I used Kubespray at ToobaTech for deploying clusters because it handles the full lifecycle (upgrades, node additions) with Ansible playbooks, rather than just bootstrapping. The inventory template in `terraform/inventory.tftpl` auto-generates `hosts.yaml` after `terraform apply`, so there's no manual copy-paste step.

**Calico over Flannel** — Calico supports NetworkPolicy objects, which matters when you want to restrict pod-to-pod traffic (e.g. the GitLab namespace shouldn't be reachable from staging workloads). Flannel is simpler but doesn't give you that control.

**t3.xlarge sizing** — The GitLab Helm chart needs at least 8 vCPU and 16–30 GB RAM distributed across the cluster. Running it on smaller instances causes OOMKilled pods on gitaly or webservice, which I learned the hard way at ToobaTech.

**Self-signed TLS** — Avoids needing a real domain while still deploying proper HTTPS through ingress-nginx. The `deploy.sh` script generates a wildcard cert for `*.soroush` and stores it as a Kubernetes secret.

**GitLab Runner in-cluster** — Registers against the self-hosted GitLab automatically on install. No external runner registration needed; the runner token is generated and stored as a Kubernetes secret before Helm deploys it.

---

## Prerequisites

```bash
# Terraform >= 1.5
brew install terraform

# Ansible + Kubespray Python deps
pip3 install ansible netaddr jinja2

# Helm 3
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# jq (used in deploy.sh to parse Terraform outputs)
brew install jq

# AWS CLI, configured with your credentials
aws configure
```

---

## Quick Start

### 1. Clone and configure

```bash
git clone https://github.com/YOUR_USERNAME/k8s-gitops-infra
cd k8s-gitops-infra

# SSH key for EC2 access
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""

# Restrict SSH/API access to your own IP (recommended)
# Edit terraform/variables.tf and set operator_cidr:
#   default = "YOUR.IP.HERE/32"
```

### 2. Deploy everything

```bash
chmod +x scripts/deploy.sh
./scripts/deploy.sh all
```

Or run individual steps:

```bash
./scripts/deploy.sh terraform    # Provision AWS infra
./scripts/deploy.sh kubespray    # Deploy K8s with Kubespray
./scripts/deploy.sh monitoring   # Prometheus + Grafana
./scripts/deploy.sh gitlab       # GitLab + TLS certs
./scripts/deploy.sh hosts        # Print /etc/hosts entries
```

### 3. Add to /etc/hosts

After deployment the script prints the IPs. Add to your local `/etc/hosts`:

```
<worker1-ip>  gitlab.soroush registry.soroush minio.soroush
<worker1-ip>  grafana.soroush app.soroush app-staging.soroush
```

### 4. Access services

| Service | URL | Credentials |
|---------|-----|-------------|
| GitLab | https://gitlab.soroush | root / (printed by deploy script) |
| Grafana | https://grafana.soroush | admin / ChangeMeOnFirstLogin! |
| K8s API | https://\<master-ip\>:6443 | via ~/.kube/config |

---

## CI/CD Pipeline

The pipeline in `gitlab-ci/.gitlab-ci.yml` defines 5 stages:

```
lint → build → test → push → deploy
```

| Stage | What it does |
|-------|-------------|
| lint | Dockerfile lint (hadolint) + YAML lint |
| build | Docker image built and pushed to GitLab Registry |
| test | Unit tests run inside the built image |
| push | Image tagged with branch/ref slug |
| deploy staging | Auto-deploys on `develop` branch |
| deploy production | Manual approval gate, on `main`/tags |

### CI/CD setup in your project

1. Push your app to the self-hosted GitLab
2. Copy `gitlab-ci/.gitlab-ci.yml` to your repo root
3. Copy `gitlab-ci/k8s/manifests.yaml` to your repo under `k8s/`
4. In GitLab → Settings → CI/CD → Variables, add:
   - `KUBE_CONFIG` — base64-encoded `~/.kube/config`

---

## Project Structure

```
k8s-gitops-infra/
├── terraform/
│   ├── main.tf              # VPC, subnet, SGs, EC2 instances
│   ├── variables.tf         # All configurable parameters
│   ├── outputs.tf           # IPs, SSH command, writes Kubespray inventory
│   └── inventory.tftpl      # Kubespray hosts.yaml template
├── kubespray/
│   └── inventory/cluster/
│       ├── hosts.yaml           # Auto-generated by Terraform
│       └── group_vars/
│           ├── all.yml          # CNI, container runtime, NTP, DNS
│           └── k8s_cluster.yml  # Kubernetes version, RBAC, kube-proxy mode
├── helm/
│   ├── gitlab/
│   │   └── values.yaml      # GitLab with ingress, runner, sizing
│   └── monitoring/
│       └── values.yaml      # Prometheus + Grafana with pre-loaded dashboards
├── gitlab-ci/
│   ├── .gitlab-ci.yml       # 5-stage pipeline
│   └── k8s/
│       └── manifests.yaml   # Deployment, Service, Ingress for staging + production
├── scripts/
│   └── deploy.sh            # Orchestrates full deployment, step by step
└── README.md
```

---

## Cleanup

```bash
cd terraform/
terraform destroy
```

This removes all AWS resources (VPC, EC2, security groups, key pair). Local files (`certs/`, `~/.kube/config`) are not deleted automatically.

---

## Known limitations

- Single master node — no HA control plane. For production, use 3 masters with an external load balancer in front of the API server.
- Self-signed TLS — browsers will show a warning. Replace with Let's Encrypt or a real certificate for any externally accessible deployment.
- All nodes in a public subnet — acceptable for a demo, but production should put worker nodes in a private subnet with a NAT gateway.
- `operator_cidr` defaults to `0.0.0.0/0` — always restrict this to your actual IP before deploying.
