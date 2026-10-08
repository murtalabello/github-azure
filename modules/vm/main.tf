locals {
  is_linux = var.os_type == "linux"

  default_images = {
    linux = {
      publisher = "Canonical"
      offer     = "0001-com-ubuntu-server-jammy"
      sku       = "22_04-lts-gen2"
      version   = "latest"
    }
    windows = {
      publisher = "MicrosoftWindowsServer"
      offer     = "WindowsServer"
      sku       = "2022-datacenter-azure-edition"
      version   = "latest"
    }
  }

  image = coalesce(var.source_image, local.default_images[var.os_type])

  # Windows computer names are limited to 15 chars.
  computer_name = local.is_linux ? var.name : substr(replace(var.name, "-", ""), 0, 15)
}

resource "azurerm_public_ip" "this" {
  count               = var.create_public_ip ? 1 : 0
  name                = "${var.name}-pip"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.zone == null ? null : [var.zone]
  tags                = var.tags
}

resource "azurerm_network_interface" "this" {
  name                = "${var.name}-nic"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = var.private_ip_address == null ? "Dynamic" : "Static"
    private_ip_address            = var.private_ip_address
    public_ip_address_id          = var.create_public_ip ? azurerm_public_ip.this[0].id : null
  }
}

resource "azurerm_linux_virtual_machine" "this" {
  count = local.is_linux ? 1 : 0

  name                            = var.name
  computer_name                   = local.computer_name
  resource_group_name             = var.resource_group_name
  location                        = var.location
  size                            = var.size
  zone                            = var.zone
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.this.id]
  tags                            = var.tags

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_public_key
  }

  os_disk {
    name                 = "${var.name}-osdisk"
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = local.image.publisher
    offer     = local.image.offer
    sku       = local.image.sku
    version   = local.image.version
  }

  dynamic "identity" {
    for_each = var.enable_system_identity ? [1] : []
    content {
      type = "SystemAssigned"
    }
  }

  dynamic "boot_diagnostics" {
    for_each = var.boot_diagnostics ? [1] : []
    content {}
  }

  lifecycle {
    precondition {
      condition     = var.admin_ssh_public_key != null && var.admin_ssh_public_key != ""
      error_message = "admin_ssh_public_key is required when os_type = \"linux\"."
    }
  }
}

resource "azurerm_windows_virtual_machine" "this" {
  count = local.is_linux ? 0 : 1

  name                  = var.name
  computer_name         = local.computer_name
  resource_group_name   = var.resource_group_name
  location              = var.location
  size                  = var.size
  zone                  = var.zone
  admin_username        = var.admin_username
  admin_password        = var.admin_password
  network_interface_ids = [azurerm_network_interface.this.id]
  patch_mode            = "AutomaticByPlatform"
  tags                  = var.tags

  os_disk {
    name                 = "${var.name}-osdisk"
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = local.image.publisher
    offer     = local.image.offer
    sku       = local.image.sku
    version   = local.image.version
  }

  dynamic "identity" {
    for_each = var.enable_system_identity ? [1] : []
    content {
      type = "SystemAssigned"
    }
  }

  dynamic "boot_diagnostics" {
    for_each = var.boot_diagnostics ? [1] : []
    content {}
  }

  lifecycle {
    precondition {
      condition     = var.admin_password != null && var.admin_password != ""
      error_message = "admin_password is required when os_type = \"windows\"."
    }
  }
}
