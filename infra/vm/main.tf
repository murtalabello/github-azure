locals {
  name_prefix = "${var.workload}-${var.environment}"

  tags = merge({
    environment = var.environment
    workload    = var.workload
    managed_by  = "terraform"
    repo        = "github-actions"
  }, var.tags)

  admin_port = var.os_type == "windows" ? "3389" : "22"
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.name_prefix}-vm"
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  address_space       = var.vnet_address_space
  tags                = local.tags
}

resource "azurerm_subnet" "vm" {
  name                 = "snet-vm"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.subnet_prefix]
}

resource "azurerm_network_security_group" "vm" {
  name                = "nsg-${local.name_prefix}-vm"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags

  dynamic "security_rule" {
    for_each = length(var.admin_source_cidrs) > 0 ? [1] : []
    content {
      name                       = "allow-admin-inbound"
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = local.admin_port
      source_address_prefixes    = var.admin_source_cidrs
      destination_address_prefix = "*"
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "vm" {
  subnet_id                 = azurerm_subnet.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}

# Windows only: generated admin password (kept in state — store state in a
# locked-down account, and copy it to Key Vault if people need it).
resource "random_password" "admin" {
  count            = var.os_type == "windows" ? 1 : 0
  length           = 24
  special          = true
  override_special = "!@#$%*-_=+"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

module "vm" {
  # Point this at your existing module if it lives elsewhere in the repo,
  # e.g. "../../terraform/modules/vm" or "git::https://github.com/<org>/<repo>.git//modules/vm?ref=v1.0.0"
  source = "../../modules/vm"
  count  = var.vm_count

  name                 = format("vm-%s-%02d", local.name_prefix, count.index + 1)
  resource_group_name  = azurerm_resource_group.this.name
  location             = azurerm_resource_group.this.location
  subnet_id            = azurerm_subnet.vm.id
  os_type              = var.os_type
  size                 = var.vm_size
  os_disk_type         = var.os_disk_type
  zone                 = length(var.zones) > 0 ? var.zones[count.index % length(var.zones)] : null
  create_public_ip     = var.create_public_ip
  admin_username       = var.admin_username
  admin_ssh_public_key = var.os_type == "linux" ? var.admin_ssh_public_key : null
  admin_password       = var.os_type == "windows" ? random_password.admin[0].result : null
  tags                 = local.tags

  depends_on = [azurerm_subnet_network_security_group_association.vm]
}
