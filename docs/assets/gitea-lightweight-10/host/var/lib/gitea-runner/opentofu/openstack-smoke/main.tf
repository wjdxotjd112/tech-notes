variable "overlay_network_type" {
  type = string

  validation {
    condition     = contains(["vxlan", "geneve"], var.overlay_network_type)
    error_message = "overlay_network_type must be vxlan or geneve."
  }
}

variable "provider_physical_network" {
  type = string
}

variable "provider_cidr" {
  type = string

  validation {
    condition     = can(cidrnetmask(var.provider_cidr))
    error_message = "provider_cidr에는 올바른 IPv4 CIDR을 지정한다."
  }
}

variable "test_name_prefix" {
  type    = string
  default = "release-smoke"
}

variable "image_file" {
  type    = string
  default = "noble-qemu-okestro2018.qcow2"
}

variable "overlay_cidr" {
  type    = string
  default = "203.0.113.64/26"

  validation {
    condition     = can(cidrnetmask(var.overlay_cidr))
    error_message = "overlay_cidr에는 올바른 IPv4 CIDR을 지정한다."
  }
}

variable "provider_allocation_pool" {
  type = object({
    start = string
    end   = string
  })
}

resource "openstack_images_image_v2" "test" {
  name             = "${var.test_name_prefix}-noble"
  local_file_path  = "${path.module}/${var.image_file}"
  container_format = "bare"
  disk_format      = "qcow2"

  properties = {
    hw_qemu_guest_agent = "yes"
    hw_require_fsfreeze = "yes"
  }
}

resource "openstack_compute_flavor_v2" "test" {
  name  = "${var.test_name_prefix}-2c2g"
  ram   = 2048
  vcpus = 2
  disk  = 0
}

resource "openstack_networking_network_v2" "overlay" {
  name = "${var.test_name_prefix}-overlay"

  value_specs = {
    "provider:network_type" = var.overlay_network_type
  }
}

resource "openstack_networking_subnet_v2" "overlay" {
  name        = "${var.test_name_prefix}-overlay-subnet"
  network_id  = openstack_networking_network_v2.overlay.id
  cidr        = var.overlay_cidr
  ip_version  = 4
  enable_dhcp = true
  no_gateway  = true
}

resource "openstack_networking_network_v2" "provider" {
  name     = "${var.test_name_prefix}-provider"
  external = true

  value_specs = {
    "provider:network_type"     = "flat"
    "provider:physical_network" = var.provider_physical_network
  }
}

resource "openstack_networking_subnet_v2" "provider" {
  name        = "${var.test_name_prefix}-provider-subnet"
  network_id  = openstack_networking_network_v2.provider.id
  cidr        = var.provider_cidr
  ip_version  = 4
  enable_dhcp = true
  no_gateway  = true

  allocation_pool {
    start = var.provider_allocation_pool.start
    end   = var.provider_allocation_pool.end
  }
}

resource "openstack_compute_instance_v2" "test" {
  name      = "${var.test_name_prefix}-vm"
  flavor_id = openstack_compute_flavor_v2.test.id

  block_device {
    uuid                  = openstack_images_image_v2.test.id
    source_type           = "image"
    destination_type      = "volume"
    volume_size           = 20
    boot_index            = 0
    delete_on_termination = true
  }

  network {
    uuid = openstack_networking_network_v2.overlay.id
  }

  network {
    uuid = openstack_networking_network_v2.provider.id
  }

  depends_on = [
    openstack_networking_subnet_v2.overlay,
    openstack_networking_subnet_v2.provider,
  ]
}

resource "openstack_blockstorage_volume_v3" "test" {
  name = "${var.test_name_prefix}-data"
  size = 1
}

resource "openstack_compute_volume_attach_v2" "test" {
  instance_id = openstack_compute_instance_v2.test.id
  volume_id   = openstack_blockstorage_volume_v3.test.id
}

output "smoke_result" {
  value = {
    instance_id        = openstack_compute_instance_v2.test.id
    image_status       = openstack_images_image_v2.test.status
    power_state        = openstack_compute_instance_v2.test.power_state
    network_ids        = [for nic in openstack_compute_instance_v2.test.network : nic.uuid]
    volume_id          = openstack_blockstorage_volume_v3.test.id
    attached_volume_id = openstack_compute_volume_attach_v2.test.volume_id
  }
}
