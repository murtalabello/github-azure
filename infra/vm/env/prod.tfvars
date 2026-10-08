environment        = "prod"
workload           = "app"
location           = "southcentralus"
vnet_address_space = ["10.20.0.0/16"]
subnet_prefix      = "10.20.1.0/24"

os_type      = "linux" # or "windows"
vm_count     = 2
vm_size      = "Standard_D2s_v5"
os_disk_type = "Premium_LRS"
zones        = ["1", "2"]

create_public_ip   = false
admin_source_cidrs = []

tags = {
  cost_center = "prod"
}
