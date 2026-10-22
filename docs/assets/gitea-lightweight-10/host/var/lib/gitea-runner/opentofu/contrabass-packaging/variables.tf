variable "vcenter_server" {
  type = string
}

variable "allow_unverified_ssl" {
  type    = bool
  default = true
}

variable "datacenter_name" {
  type = string
}

variable "host_name" {
  type = string
}

variable "datastore_name" {
  type = string
}

variable "template_path" {
  type = string
}

variable "vm_folder" {
  type = string
}

variable "domain" {
  type = string
}

variable "ipv4_gateway" {
  type = string
}

variable "ipv4_prefixes" {
  type    = list(number)
  default = [24, 26, 26, 26]

  validation {
    condition     = length(var.ipv4_prefixes) == 4 && alltrue([for prefix in var.ipv4_prefixes : prefix >= 1 && prefix <= 32])
    error_message = "NIC 순서에 맞는 IPv4 prefix 네 개를 지정한다."
  }
}

variable "nested_hv" {
  type    = bool
  default = true
}

variable "provider_uplink_interface" {
  type    = string
  default = "ens38"

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9_.:-]*$", var.provider_uplink_interface))
    error_message = "provider uplink에는 인터페이스 이름만 지정한다."
  }
}

variable "ssh_public_key" {
  type        = string
  description = "Runner 공개키 내용. Workflow가 TOFU_SSH_PUBLIC_KEY 파일에서 읽는다."
  default     = ""
}

variable "vms" {
  type = map(object({
    ipv4_addresses = list(string)
  }))

  validation {
    condition = (
      length(var.vms) > 0 &&
      alltrue([for vm in values(var.vms) : length(vm.ipv4_addresses) == 4]) &&
      alltrue([
        for ip in flatten([for vm in values(var.vms) : vm.ipv4_addresses]) :
        can(cidrnetmask("${ip}/32"))
      ]) &&
      length(distinct(flatten([for vm in values(var.vms) : vm.ipv4_addresses]))) ==
      length(flatten([for vm in values(var.vms) : vm.ipv4_addresses]))
    )
    error_message = "VM마다 중복되지 않는 유효한 IPv4 주소 4개를 NIC 순서대로 지정한다."
  }
}

variable "bundle_url" {
  type = string

  validation {
    condition     = startswith(var.bundle_url, "https://")
    error_message = "bundle_url은 HTTPS 주소여야 한다."
  }
}

variable "ssh_private_key_path" {
  type = string
}

variable "nexus_user" {
  type = string
}

variable "nexus_password" {
  type      = string
  sensitive = true
}

variable "bundle_sha256" {
  type = string

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.bundle_sha256))
    error_message = "bundle_sha256에는 64자리 SHA256 값을 지정한다."
  }
}

variable "nexus_skip_verify" {
  type    = bool
  default = true
}

variable "deploy_vm_name" {
  type    = string
  default = "runner01"
}

variable "deploy_directory" {
  type    = string
  default = "/opt/contrabass-test"

  validation {
    condition     = can(regex("^/[A-Za-z0-9._/-]+$", var.deploy_directory))
    error_message = "deploy_directory에는 공백 없는 절대 경로를 지정한다."
  }
}
