# terraform-proxmox-talos

Terraform module to provision Talos Linux Kubernetes clusters on Proxmox VE.

> **Personal fork** of [`bbtechsys/talos/proxmox`](https://registry.terraform.io/modules/bbtechsys/talos/proxmox).
> It intentionally diverges from upstream (see [Fork differences](#fork-differences))
> and is pinned by **release tag**, not consumed from the registry.

## Fork differences

- **`cluster_endpoint` is required** (no default). Point it at a shared Talos VIP
  or load balancer for an HA Kubernetes API endpoint — see
  [HA control plane (VIP)](#high-availability-control-plane-endpoint-vip).
- The upstream **per-node** config-patch variables were removed in favour of the
  cluster-wide `control_machine_config_patches` / `worker_machine_config_patches`.
- Uses the short-name `proxmox_download_file` resource, so it requires
  **`bpg/proxmox >= 0.100.0`**.

Consume it by tag:

```terraform
module "talos" {
  source = "git::https://github.com/vetlmetl/terraform-proxmox-talos.git?ref=v1.0.2"
  # ...
}
```

## Example usage

```terraform
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.100.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = ">= 0.6.1"
    }
  }
}

provider "proxmox" {
  endpoint  = "https://192.168.1.21:8006/"
  api_token = var.proxmox_api_token # or PROXMOX_VE_* env vars
  insecure  = true
}

module "talos" {
  source = "git::https://github.com/vetlmetl/terraform-proxmox-talos.git?ref=v1.0.2"

  talos_cluster_name = "test-cluster"
  talos_version      = "1.13.0"
  cluster_endpoint   = "https://192.168.88.200:6443" # required (VIP)

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
  value     = module.talos.talos_config
  sensitive = true
}

output "kubeconfig" {
  value     = module.talos.kubeconfig
  sensitive = true
}
```

## High-availability control plane endpoint (VIP)

Set `cluster_endpoint` to a shared
[Talos VIP](https://www.talos.dev/latest/talos-guides/network/vip/) and define
that VIP on the control nodes via a config patch. Because passing
`control_machine_config_patches` **replaces** the module default, re-include the
install disk:

```terraform
module "talos" {
  # ... cluster_name, version, nodes ...

  cluster_endpoint = "https://192.168.88.200:6443" # shared VIP

  control_machine_config_patches = [
    yamlencode({
      machine = {
        install = { disk = "/dev/vda" }
        network = {
          interfaces = [{
            deviceSelector = { driver = "virtio_net" }
            dhcp           = true
            vip            = { ip = "192.168.88.200" }
          }]
        }
      }
      cluster = { apiServer = { certSANs = ["192.168.88.200"] } }
    })
  ]
}
```

## System extensions (`talos_schematic_id`)

Which [Talos system extensions](https://github.com/siderolabs/extensions) are
baked into the node image is controlled by `talos_schematic_id` — an ID from the
[Talos Image Factory](https://factory.talos.dev/). The default carries only
`qemu-guest-agent`. To add extensions (for example the `iscsi-tools` +
`util-linux-tools` that Longhorn needs), generate a new schematic and pass its ID:

```yaml
# schematic.yaml
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/iscsi-tools
      - siderolabs/qemu-guest-agent
      - siderolabs/util-linux-tools
```

```bash
curl -sX POST --data-binary @schematic.yaml https://factory.talos.dev/schematics
# -> {"id":"<schematic-id>"}
```

```terraform
module "talos" {
  # ...
  talos_schematic_id = "<schematic-id>"
}
```

> Changing `talos_schematic_id` changes the image, so the VMs are **reinstalled**
> (a full rebuild), not updated in place.

## Worker config patches

`worker_machine_config_patches` works like the control-plane variant and also
**replaces** the module default (which only sets the install disk), so re-include
it. Example adding the kubelet bind mount Longhorn requires on workers:

```terraform
worker_machine_config_patches = [
  yamlencode({
    machine = {
      install = { disk = "/dev/vda" }
      kubelet = {
        extraMounts = [{
          destination = "/var/lib/longhorn"
          type        = "bind"
          source      = "/var/lib/longhorn"
          options     = ["bind", "rshared", "rw"]
        }]
      }
    }
  })
]
```

## Outputs

| Output         | Description                          |
| -------------- | ------------------------------------ |
| `talos_config` | Talos client configuration (sensitive). |
| `kubeconfig`   | Kubernetes kubeconfig (sensitive).   |

Check out the original authors' [blog post](https://bbtechsystems.com/blog/k8s-with-pxe-tf/)
for background on the upstream module.

## License

Released under the [MIT License](LICENSE).

- Copyright (c) 2024 BB Tech Systems LLC — original module
- Copyright (c) 2026 vetl — fork modifications
