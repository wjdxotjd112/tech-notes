output "vm_info" {
  value = {
    for name, vm in vsphere_virtual_machine.vm : name => {
      name          = vm.name
      management_ip = var.vms[name].ipv4_addresses[0]
    }
  }
}
