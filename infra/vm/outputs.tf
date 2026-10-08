output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "vms" {
  description = "Name, private IP and public IP of each VM."
  value = [for m in module.vm : {
    name       = m.vm_name
    id         = m.vm_id
    private_ip = m.private_ip_address
    public_ip  = m.public_ip_address
  }]
}

output "windows_admin_password" {
  description = "Generated Windows admin password (null for Linux)."
  value       = var.os_type == "windows" ? random_password.admin[0].result : null
  sensitive   = true
}
