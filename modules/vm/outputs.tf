output "vm_id" {
  description = "VM resource ID."
  value       = local.is_linux ? azurerm_linux_virtual_machine.this[0].id : azurerm_windows_virtual_machine.this[0].id
}

output "vm_name" {
  description = "VM name."
  value       = var.name
}

output "private_ip_address" {
  description = "Private IP of the NIC."
  value       = azurerm_network_interface.this.private_ip_address
}

output "public_ip_address" {
  description = "Public IP (null if not created)."
  value       = var.create_public_ip ? azurerm_public_ip.this[0].ip_address : null
}

output "principal_id" {
  description = "System-assigned identity principal ID (null if disabled)."
  value = var.enable_system_identity ? (
    local.is_linux
    ? azurerm_linux_virtual_machine.this[0].identity[0].principal_id
    : azurerm_windows_virtual_machine.this[0].identity[0].principal_id
  ) : null
}
