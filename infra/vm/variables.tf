variable "environment" {
  description = "dev or prod."
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}

variable "workload" {
  description = "Short workload name used in resource names."
  type        = string
  default     = "app"
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "southcentralus"
}

variable "vnet_address_space" {
  description = "VNet CIDR."
  type        = list(string)
}

variable "subnet_prefix" {
  description = "VM subnet CIDR."
  type        = string
}

variable "admin_source_cidrs" {
  description = "CIDRs allowed to SSH/RDP. Empty = no inbound admin access (use Bastion)."
  type        = list(string)
  default     = []
}

variable "vm_count" {
  description = "Number of VMs."
  type        = number
  default     = 1
}

variable "os_type" {
  description = "linux or windows."
  type        = string
  default     = "linux"
}

variable "vm_size" {
  description = "VM SKU."
  type        = string
  default     = "Standard_B2s"
}

variable "os_disk_type" {
  description = "OS disk SKU."
  type        = string
  default     = "StandardSSD_LRS"
}

variable "zones" {
  description = "Zones to spread VMs across (round-robin). Empty = no zone."
  type        = list(string)
  default     = []
}

variable "create_public_ip" {
  description = "Give each VM a public IP."
  type        = bool
  default     = false
}

variable "admin_username" {
  description = "Local admin username."
  type        = string
  default     = "azureadmin"
}

variable "admin_ssh_public_key" {
  description = "SSH public key for Linux VMs. Supplied by the workflow as TF_VAR_admin_ssh_public_key."
  type        = string
  default     = null
}

variable "tags" {
  description = "Extra tags."
  type        = map(string)
  default     = {}
}
