output "master_public_ip" {
  description = "Public IP of the Kubernetes master node"
  value       = aws_instance.master.public_ip
}

output "master_private_ip" {
  description = "Private IP of the Kubernetes master node"
  value       = aws_instance.master.private_ip
}

output "worker_public_ips" {
  description = "Public IPs of worker nodes"
  value       = aws_instance.worker[*].public_ip
}

output "worker_private_ips" {
  description = "Private IPs of worker nodes"
  value       = aws_instance.worker[*].private_ip
}

output "ssh_master" {
  description = "SSH command to connect to master"
  value       = "ssh -i ~/.ssh/id_rsa ubuntu@${aws_instance.master.public_ip}"
}

output "kubespray_inventory" {
  description = "Generated Kubespray inventory (also written to file via local-exec)"
  value = templatefile("${path.module}/inventory.tftpl", {
    master_ip      = aws_instance.master.private_ip
    master_pub_ip  = aws_instance.master.public_ip
    worker_ips     = aws_instance.worker[*].private_ip
    worker_pub_ips = aws_instance.worker[*].public_ip
  })
}

# Write the inventory file automatically after apply
resource "local_file" "kubespray_inventory" {
  content = templatefile("${path.module}/inventory.tftpl", {
    master_ip      = aws_instance.master.private_ip
    master_pub_ip  = aws_instance.master.public_ip
    worker_ips     = aws_instance.worker[*].private_ip
    worker_pub_ips = aws_instance.worker[*].public_ip
  })
  filename        = "${path.module}/../kubespray/inventory/cluster/hosts.yaml"
  file_permission = "0644"
}
