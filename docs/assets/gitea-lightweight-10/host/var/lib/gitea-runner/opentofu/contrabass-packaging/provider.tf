terraform {
  required_version = ">= 1.6.0"

  required_providers {
    vsphere = {
      source  = "vmware/vsphere"
      version = "= 2.17.1"
    }
  }
}

provider "vsphere" {
  vsphere_server       = var.vcenter_server
  allow_unverified_ssl = var.allow_unverified_ssl
}
