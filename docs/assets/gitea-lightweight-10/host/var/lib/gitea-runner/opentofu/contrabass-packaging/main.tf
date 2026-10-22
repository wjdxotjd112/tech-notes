data "vsphere_datacenter" "dc" {
  name = var.datacenter_name
}

data "vsphere_host" "host" {
  name          = var.host_name
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_datastore" "storage" {
  name          = var.datastore_name
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_virtual_machine" "template" {
  name          = var.template_path
  datacenter_id = data.vsphere_datacenter.dc.id
}

resource "vsphere_virtual_machine" "vm" {
  for_each = var.vms

  name             = each.key
  folder           = var.vm_folder
  resource_pool_id = data.vsphere_host.host.resource_pool_id
  host_system_id   = data.vsphere_host.host.id
  datastore_id     = data.vsphere_datastore.storage.id

  num_cpus             = data.vsphere_virtual_machine.template.num_cpus
  num_cores_per_socket = data.vsphere_virtual_machine.template.num_cores_per_socket
  memory               = data.vsphere_virtual_machine.template.memory
  guest_id             = data.vsphere_virtual_machine.template.guest_id
  firmware             = data.vsphere_virtual_machine.template.firmware
  scsi_type            = data.vsphere_virtual_machine.template.scsi_type
  nested_hv_enabled    = var.nested_hv

  dynamic "network_interface" {
    for_each = data.vsphere_virtual_machine.template.network_interfaces

    content {
      network_id   = network_interface.value.network_id
      adapter_type = network_interface.value.adapter_type
    }
  }

  dynamic "disk" {
    for_each = data.vsphere_virtual_machine.template.disks

    content {
      label            = "disk${disk.key}"
      unit_number      = disk.value.unit_number
      size             = disk.value.size
      thin_provisioned = disk.value.thin_provisioned
      eagerly_scrub    = disk.value.eagerly_scrub
    }
  }

  clone {
    template_uuid = data.vsphere_virtual_machine.template.id
    linked_clone  = false
    timeout       = 30

    customize {
      timeout = 15

      linux_options {
        host_name = each.key
        domain    = var.domain

        script_text = templatefile("${path.module}/guest-init.sh.tftpl", {
          ssh_public_key            = var.ssh_public_key
          provider_uplink_interface = var.provider_uplink_interface
        })
      }

      dynamic "network_interface" {
        for_each = each.value.ipv4_addresses

        content {
          ipv4_address = network_interface.value
          ipv4_netmask = var.ipv4_prefixes[network_interface.key]
        }
      }

      network_interface {}

      ipv4_gateway = var.ipv4_gateway
    }
  }

  wait_for_guest_net_timeout = 10

  lifecycle {
    precondition {
      condition     = length(data.vsphere_virtual_machine.template.network_interfaces) == 5
      error_message = "고정 IP용 NIC 4개와 provider uplink 1개가 있는 템플릿을 사용한다."
    }
  }
}
