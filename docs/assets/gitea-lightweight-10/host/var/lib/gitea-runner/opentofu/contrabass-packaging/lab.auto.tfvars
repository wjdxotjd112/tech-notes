# Site-specific VMware values live here, not in variables.tf.
vcenter_server  = "203.0.113.10"
datacenter_name = "Datacenter"
host_name       = "203.0.113.11"
datastore_name  = "ESXi-Local-SSD"
template_path   = "release-test/template/rocky9.6-template"
vm_folder       = "release-test"
domain          = "lab.example.com"
ipv4_gateway    = "192.0.2.1"
deploy_vm_name  = "runner01"
ipv4_prefixes   = [24, 26, 26, 26]

vms = {
  runner01 = {
    ipv4_addresses = ["192.0.2.101", "198.51.100.11", "198.51.100.75", "198.51.100.139"]
  }
  runner02 = {
    ipv4_addresses = ["192.0.2.102", "198.51.100.12", "198.51.100.76", "198.51.100.140"]
  }
  runner03 = {
    ipv4_addresses = ["192.0.2.103", "198.51.100.13", "198.51.100.77", "198.51.100.141"]
  }
  runner04 = {
    ipv4_addresses = ["192.0.2.104", "198.51.100.14", "198.51.100.78", "198.51.100.142"]
  }
}
