# Copyright (c) 2024 BB Tech Systems LLC

locals {
  # Pick each node's primary IP by matching the QEMU guest-agent report against
  # the node subnet, instead of a fixed positional interface index. The agent
  # also reports loopback, CNI (flannel), and KubeSpan addresses, and their
  # ordering across interfaces is not stable — a hard-coded index silently
  # selects the wrong address when that ordering shifts.
  node_network = cidrhost(var.node_ipv4_cidr, 0)
  node_masklen = split("/", var.node_ipv4_cidr)[1]

  # A shared VIP (e.g. the Talos control-plane VIP in cluster_endpoint) can live
  # in the node subnet and appear on whichever control node currently holds it,
  # alongside that node's own address. Exclude the endpoint host so the floating
  # VIP is never mistaken for a node IP. A non-IP endpoint (DNS/LB name) simply
  # never matches a candidate address, so the exclusion is a no-op there.
  endpoint_host = try(regex("^(?:https?://)?([^:/]+)", var.cluster_endpoint)[0], null)

  control_node_ip_map = {
    for name in keys(var.control_nodes) :
    name => one([
      for ip in flatten(proxmox_virtual_environment_vm.talos_control_vm[name].ipv4_addresses) :
      ip if ip != local.endpoint_host && cidrhost("${ip}/${local.node_masklen}", 0) == local.node_network
    ])
  }
  worker_node_ip_map = {
    for name in keys(var.worker_nodes) :
    name => one([
      for ip in flatten(proxmox_virtual_environment_vm.talos_worker_vm[name].ipv4_addresses) :
      ip if ip != local.endpoint_host && cidrhost("${ip}/${local.node_masklen}", 0) == local.node_network
    ])
  }

  primary_control_node_ip = local.control_node_ip_map[keys(var.control_nodes)[0]]
  control_node_ips        = values(local.control_node_ip_map)
  worker_node_ips         = values(local.worker_node_ip_map)
  node_ips = concat(
    local.control_node_ips,
    local.worker_node_ips
  )
}

# Short-name alias for the former proxmox_virtual_environment_download_file
# (the long name is deprecated and removed in bpg/proxmox v1.0).
resource "proxmox_download_file" "talos_image" {
  content_type = "iso"
  datastore_id = var.proxmox_iso_datastore
  node_name    = values(var.control_nodes)[0]
  url          = "https://factory.talos.dev/image/${var.talos_schematic_id}/v${var.talos_version}/metal-${var.talos_arch}.qcow2"
  file_name    = "${var.talos_cluster_name}-talos_linux-${var.talos_schematic_id}-${var.talos_version}-${var.talos_arch}.img"
}

resource "proxmox_virtual_environment_vm" "talos_control_vm" {
  for_each  = var.control_nodes
  name      = each.key
  node_name = each.value
  pool_id   = var.proxmox_control_pool_id
  agent {
    enabled = true
  }
  cpu {
    cores = var.proxmox_control_vm_cores
    type  = var.proxmox_vm_type
  }
  memory {
    dedicated = var.proxmox_control_vm_memory
    floating  = var.proxmox_control_vm_memory
  }
  disk {
    datastore_id = var.proxmox_image_datastore
    file_id      = proxmox_download_file.talos_image.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = var.proxmox_control_vm_disk_size
  }
  network_device {
    vlan_id     = var.proxmox_network_vlan_id
    bridge      = var.proxmox_network_bridge
    mac_address = lookup(var.control_plane_mac_addresses, each.key, null)
  }
  operating_system {
    type = "l26"
  }
}

resource "proxmox_virtual_environment_vm" "talos_worker_vm" {
  for_each  = var.worker_nodes
  name      = each.key
  node_name = each.value
  pool_id   = var.proxmox_worker_pool_id
  agent {
    enabled = true
  }
  cpu {
    cores = var.proxmox_worker_vm_cores
    type  = var.proxmox_vm_type
  }
  memory {
    dedicated = var.proxmox_worker_vm_memory
    floating  = var.proxmox_worker_vm_memory
  }
  disk {
    datastore_id = var.proxmox_image_datastore
    file_id      = proxmox_download_file.talos_image.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = var.proxmox_worker_vm_disk_size
  }
  network_device {
    vlan_id     = var.proxmox_network_vlan_id
    bridge      = var.proxmox_network_bridge
    mac_address = lookup(var.worker_mac_addresses, each.key, null)
  }
  dynamic "disk" {
    for_each = lookup(var.worker_extra_disks, each.key, [])
    content {
      datastore_id = disk.value.datastore_id
      file_format  = disk.value.file_format
      file_id      = disk.value.file_id
      interface    = "virtio${disk.key + 1}"
      iothread     = true
      discard      = "on"
      size         = disk.value.size
    }

  }
  operating_system {
    type = "l26"
  }
}

resource "talos_machine_secrets" "talos_secrets" {}

data "talos_machine_configuration" "control_mc" {
  cluster_name     = var.talos_cluster_name
  machine_type     = "controlplane"
  cluster_endpoint = var.cluster_endpoint
  machine_secrets  = talos_machine_secrets.talos_secrets.machine_secrets
}

data "talos_machine_configuration" "worker_mc" {
  cluster_name     = var.talos_cluster_name
  machine_type     = "worker"
  cluster_endpoint = var.cluster_endpoint
  machine_secrets  = talos_machine_secrets.talos_secrets.machine_secrets
}

data "talos_client_configuration" "talos_client_config" {
  cluster_name         = var.talos_cluster_name
  client_configuration = talos_machine_secrets.talos_secrets.client_configuration
  endpoints            = local.control_node_ips
  nodes                = local.node_ips
}

resource "talos_machine_configuration_apply" "talos_control_mc_apply" {
  for_each                    = var.control_nodes
  client_configuration        = talos_machine_secrets.talos_secrets.client_configuration
  machine_configuration_input = data.talos_machine_configuration.control_mc.machine_configuration
  node                        = local.control_node_ip_map[each.key]
  config_patches              = var.control_machine_config_patches
}

resource "talos_machine_configuration_apply" "talos_worker_mc_apply" {
  for_each                    = var.worker_nodes
  client_configuration        = talos_machine_secrets.talos_secrets.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker_mc.machine_configuration
  node                        = local.worker_node_ip_map[each.key]
  config_patches              = var.worker_machine_config_patches
}

# You only need to bootstrap 1 control node, we pick the first one
resource "talos_machine_bootstrap" "talos_bootstrap" {
  node                 = local.primary_control_node_ip
  client_configuration = talos_machine_secrets.talos_secrets.client_configuration
}

resource "talos_cluster_kubeconfig" "talos_kubeconfig" {
  depends_on = [
    talos_machine_bootstrap.talos_bootstrap
  ]
  client_configuration = talos_machine_secrets.talos_secrets.client_configuration
  node                 = local.primary_control_node_ip
}