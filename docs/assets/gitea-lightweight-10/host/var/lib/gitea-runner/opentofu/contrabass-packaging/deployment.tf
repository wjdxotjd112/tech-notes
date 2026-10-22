locals {
  deploy_ip = var.vms[var.deploy_vm_name].ipv4_addresses[0]
}

resource "terraform_data" "ssh_ready" {
  for_each         = var.vms
  triggers_replace = vsphere_virtual_machine.vm[each.key].id

  connection {
    type        = "ssh"
    host        = each.value.ipv4_addresses[0]
    user        = "root"
    private_key = file(var.ssh_private_key_path)
    timeout     = "15m"
  }

  provisioner "remote-exec" {
    inline = [
      "#!/bin/bash",
      "set -euo pipefail",
      "timeout 10m bash -c 'until grep -qx \"guest-init complete\" /var/log/opentofu-guest-init.log 2>/dev/null; do sleep 5; done'",
    ]
  }
}

resource "terraform_data" "deploy" {
  depends_on = [terraform_data.ssh_ready]

  triggers_replace = {
    vm_ids        = [for name in sort(keys(var.vms)) : vsphere_virtual_machine.vm[name].id]
    bundle_url    = var.bundle_url
    bundle_sha256 = var.bundle_sha256
  }

  connection {
    type        = "ssh"
    host        = local.deploy_ip
    user        = "root"
    private_key = file(var.ssh_private_key_path)
    timeout     = "15m"
  }

  provisioner "remote-exec" {
    inline = [
      "#!/bin/bash",
      "set -euo pipefail",
      "umask 077",
      "mkdir -p '${var.deploy_directory}'",
      "cd '${var.deploy_directory}'",
      "nexus_auth=$(printf '%s' '${base64encode("${var.nexus_user}:${var.nexus_password}")}' | base64 -d)",
      "bundle_url=$(printf '%s' '${base64encode(var.bundle_url)}' | base64 -d)",
      "nexus_auth=\"$${nexus_auth//\\\\/\\\\\\\\}\"",
      "nexus_auth=\"$${nexus_auth//\\\"/\\\\\\\"}\"",
      "printf 'user = \"%s\"\\n' \"$nexus_auth\" | curl -fsSL --connect-timeout 10 --retry 3 ${var.nexus_skip_verify ? "--insecure" : ""} --config /dev/stdin \"$bundle_url\" -o contrabass-engine-deploy.tar",
      "unset nexus_auth",
      "printf '%s  %s\\n' '${var.bundle_sha256}' contrabass-engine-deploy.tar | sha256sum -c -",
      "tar -xf contrabass-engine-deploy.tar",
      "cd contrabass-engine-deploy",
      "bash ./deploy.sh '${local.deploy_ip}' --accept-eula",
    ]
  }

  provisioner "remote-exec" {
    inline = [
      "#!/bin/bash",
      "set -euo pipefail",
      "nerdctl exec nexus true",
      "nerdctl exec okestro-os-ansible true",
    ]
  }

  provisioner "remote-exec" {
    inline = [
      "#!/bin/bash",
      "set -euo pipefail",
      "nerdctl exec okestro-os-ansible sh -lc 'cd /root/okestro/okestro-openstack && ansible-playbook -i inventory/inventory.ini main.yml' 2>&1 | tee /var/log/contrabass-ansible.log",
    ]
  }

}
