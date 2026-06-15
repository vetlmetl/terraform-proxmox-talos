# terraform-proxmox-talos

Terraform module to provision Talos Linux Kubernetes clusters with Proxmox

## Example usage

```bash
export PROXMOX_VE_USERNAME="root@pam"
export PROXMOX_VE_PASSWORD="super-secret"
```

```terraform
terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
      version = "~> 0.75.0"
    }
    talos = {
      source = "siderolabs/talos"
      version = "~> 0.7.1"
    }
  }
}

provider "proxmox" {
  endpoint = "https://192.168.1.21:8006/"
  insecure = true
}

module "talos" {
    source  = "bbtechsys/talos/proxmox"
    version = "0.1.5"
    talos_cluster_name = "test-cluster"
    talos_version = "1.9.5"
    control_nodes = {
        "test-control-0" = "pve1"
        "test-control-1" = "pve1"
        "test-control-2" = "pve1"
    }
    worker_nodes = {
        "test-worker-0" = "pve1"
        "test-worker-1" = "pve1"
        "test-worker-2" = "pve1"
    }
}

output "talos_config" {
    description = "Talos configuration file"
    value       = module.talos.talos_config
    sensitive   = true
}

output "kubeconfig" {
    description = "Kubeconfig file"
    value       = module.talos.kubeconfig
    sensitive   = true
}
```

## High-availability control plane endpoint (VIP)

By default the cluster endpoint points at the first control node's IP, which is a
single point of failure. To make it highly available, set `cluster_endpoint` to a
shared [Talos VIP](https://www.talos.dev/latest/talos-guides/network/vip/) and
define that VIP on the control nodes via a config patch:

```terraform
module "talos" {
  source  = "bbtechsys/talos/proxmox"
  # ... cluster_name, version, nodes ...

  cluster_endpoint = "https://192.168.88.200:6443" # shared VIP

  control_machine_config_patches = [
    yamlencode({
      machine = {
        install = { disk = "/dev/vda" }
        network = {
          interfaces = [{
            interface = "eth0"
            dhcp      = true
            vip       = { ip = "192.168.88.200" }
          }]
        }
      }
    })
  ]
}
```

`cluster_endpoint` defaults to `null` (legacy first-node behavior), so this change
is fully backward compatible.

## Per-node configuration patches

`control_node_config_patches` and `worker_node_config_patches` are maps keyed by
node name. Their patches are appended *after* the shared
`control_machine_config_patches` / `worker_machine_config_patches`, so they can
override shared values — useful for per-node tuning such as kubelet args or node
labels:

```terraform
  worker_node_config_patches = {
    "test-worker-0" = [yamlencode({
      machine = { kubelet = { extraArgs = { "node-labels" = "gpu=true" } } }
    })]
  }
```

Both default to `{}`, so they are backward compatible.

> Note: avoid using these to set static node IPs via `dhcp: false`. This module
> discovers node IPs through the guest agent and assumes they are stable, so a
> static-address patch can change a node's IP out from under that discovery (or
> strand the node). For predictable IPs, pin a `mac_address` and use a DHCP
> reservation instead.

Check out our [blog post](https://bbtechsystems.com/blog/k8s-with-pxe-tf/) for more details on using this module.

Copyright (c) 2024 BB Tech Systems LLC
