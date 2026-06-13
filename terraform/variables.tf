variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "eu-west-1"
}

variable "cluster_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "soroush-k8s"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "operator_cidr" {
  description = "Your IP CIDR for SSH and API access. Change this to your actual IP."
  type        = string
  default     = "0.0.0.0/0" # Restrict this to your IP in production: e.g. "1.2.3.4/32"
}

variable "ssh_public_key_path" {
  description = "Path to your SSH public key"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

# Master: t3.xlarge = 4 vCPU, 16GB — handles control plane + GitLab components
variable "master_instance_type" {
  description = "EC2 instance type for the master node"
  type        = string
  default     = "t3.xlarge"
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 2
}

# Worker 1: t3.xlarge for GitLab workloads
# Worker 2: t3.large for Prometheus + Grafana
variable "worker_instance_type" {
  description = "EC2 instance types for worker nodes (one per worker)"
  type        = list(string)
  default     = ["t3.xlarge", "t3.large"]
}

variable "common_tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    Project     = "k8s-gitops-infra"
    Environment = "demo"
    ManagedBy   = "Terraform"
    Owner       = "Soroush"
  }
}
