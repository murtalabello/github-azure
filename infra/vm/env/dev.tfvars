environment        = "dev"
workload           = "app"
location           = "southcentralus"
vnet_address_space = ["10.10.0.0/16"]
subnet_prefix      = "10.10.1.0/24"

os_type      = "linux" # or "windows"
vm_count     = 1
vm_size      = "Standard_B2s"
os_disk_type = "StandardSSD_LRS"
zones        = []

create_public_ip   = false
admin_source_cidrs = [] # e.g. ["203.0.113.10/32"]

tags = {
  cost_center = "dev"
}
