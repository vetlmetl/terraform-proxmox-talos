# Copyright (c) 2024 BB Tech Systems LLC

terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
      # >= 0.100.0: introduces the short-name proxmox_download_file alias used in main.tf
      version = ">= 0.100.0"
    }
    talos = {
      source = "siderolabs/talos"
      version = ">= 0.6.1"
    }
  }
}