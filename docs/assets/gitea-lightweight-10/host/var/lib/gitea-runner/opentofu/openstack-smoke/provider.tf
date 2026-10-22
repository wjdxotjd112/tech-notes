terraform {
  required_version = ">= 1.6.0"

  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "= 1.53.0"
    }
  }
}

provider "openstack" {}
