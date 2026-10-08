variable "name" {
  description = "VM name (also used as a prefix for the NIC, disk and public IP)."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group the VM is deployed into."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID the NIC attaches to."
  type        = string
}

variable "os_type" {
  description = "linux or windows."
  type        = string
  default     = "linux"

  validation {
    condition     = contains(["linux", "windows"], var.os_type)
    error_message = "os_type must be \"linux\" or \"windows\"."
  }
}

variable "size" {
  description = "VM SKU, e.g. Standard_B2s."
  type        = string
  default     = "Standard_B2s"
}

variable "admin_username" {
  description = "Local admin username."
  type        = string
  default     = "azureadmin"
}

variable "admin_ssh_public_key" {
  description = "SSH public key (Linux only)."
  type        = string
  default     = null
}

variable "admin_password" {
  description = "Admin password (Windows only)."
  type        = string
  default     = null
  sensitive   = true
}

variable "source_image" {
  description = "Marketplace image. Null = Ubuntu 22.04 LTS for Linux, Windows Server 2022 for Windows."
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
  default = null
}

variable "os_disk_type" {
  description = "Standard_LRS | StandardSSD_LRS | Premium_LRS."
  type        = string
  default     = "StandardSSD_LRS"
}

variable "os_disk_size_gb" {
  description = "OS disk size. Null = image default."
  type        = number
  default     = null
}

variable "zone" {
  description = "Availability zone (\"1\", \"2\", \"3\") or null."
  type        = string
  default     = null
}

variable "create_public_ip" {
  description = "Attach a Standard static public IP. Keep false and use Bastion/VPN where possible."
  type        = bool
  default     = false
}

variable "private_ip_address" {
  description = "Static private IP. Null = dynamic."
  type        = string
  default     = null
}

variable "enable_system_identity" {
  description = "Enable a system-assigned managed identity on the VM."
  type        = bool
  default     = true
}

variable "boot_diagnostics" {
  description = "Enable boot diagnostics with a managed storage account."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
