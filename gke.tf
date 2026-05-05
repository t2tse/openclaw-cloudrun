locals {
  # The active cluster name — used by kubeconfig, outputs, and IAM.
  # One of the two clusters will always have count=0 (empty list); concat gives exactly one element.
  cluster_name = one(concat(
    google_container_cluster.standard[*].name,
    google_container_cluster.autopilot[*].name,
  ))

  # Workload Identity pool — identical format for both Standard and Autopilot.
  cluster_workload_pool = one(concat(
    [for c in google_container_cluster.standard : c.workload_identity_config[0].workload_pool],
    [for c in google_container_cluster.autopilot : c.workload_identity_config[0].workload_pool],
  ))
}

# ──────────────────────────────────────────────────────────────────────────────
# GKE Standard Cluster — used when sandbox_runtime = "kata"
# Kata Containers requires nested virtualization, which is only supported on
# Standard (non-Autopilot) node pools with N2 machine types.
# ──────────────────────────────────────────────────────────────────────────────

resource "google_container_cluster" "standard" {
  count = var.sandbox_runtime == "kata" ? 1 : 0

  name     = var.gke_cluster_name
  location = var.region

  deletion_protection = true

  # Standard cluster (not Autopilot) — required for Kata Containers
  initial_node_count       = 1
  remove_default_node_pool = true

  node_config {
    shielded_instance_config {
      enable_secure_boot = true
    }
  }

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.gke_subnet.id

  ip_allocation_policy {
    cluster_secondary_range_name  = "gke-pods"
    services_secondary_range_name = "gke-services"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = var.gke_subnet_cidr
      display_name = "GKE subnet"
    }
    dynamic "cidr_blocks" {
      for_each = local.exec_vms_enabled ? [1] : []
      content {
        cidr_block   = var.exec_vm_subnet_cidr
        display_name = "Execution VM subnet"
      }
    }
    dynamic "cidr_blocks" {
      for_each = var.master_authorized_cidrs
      content {
        cidr_block   = cidr_blocks.value
        display_name = cidr_blocks.key
      }
    }
    gcp_public_cidrs_access_enabled = false
  }

  release_channel {
    channel = "REGULAR"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Prevent recreation when node_config drifts (default pool gets deleted anyway)
  lifecycle {
    ignore_changes = [node_config]
  }

  depends_on = [
    google_compute_subnetwork.gke_subnet,
  ]
}

# ──────────────────────────────────────────────────────────────────────────────
# GKE Autopilot Cluster — used when sandbox_runtime = "gvisor"
# Autopilot manages node provisioning automatically.
# gVisor (runsc) is natively supported via runtimeClassName: gvisor — no
# additional Helm chart, DaemonSet, or sandbox_config is required.
# ──────────────────────────────────────────────────────────────────────────────

resource "google_container_cluster" "autopilot" {
  count = var.sandbox_runtime == "gvisor" ? 1 : 0

  name     = var.gke_cluster_name
  location = var.region

  deletion_protection = true

  # Autopilot manages all node pools and OS images automatically.
  # gVisor pods are scheduled on gVisor-capable nodes by GKE when
  # runtimeClassName: gvisor is set in the pod spec.
  enable_autopilot = true

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.gke_subnet.id

  ip_allocation_policy {
    cluster_secondary_range_name  = "gke-pods"
    services_secondary_range_name = "gke-services"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = var.gke_subnet_cidr
      display_name = "GKE subnet"
    }
    dynamic "cidr_blocks" {
      for_each = local.exec_vms_enabled ? [1] : []
      content {
        cidr_block   = var.exec_vm_subnet_cidr
        display_name = "Execution VM subnet"
      }
    }
    dynamic "cidr_blocks" {
      for_each = var.master_authorized_cidrs
      content {
        cidr_block   = cidr_blocks.value
        display_name = cidr_blocks.key
      }
    }
    gcp_public_cidrs_access_enabled = false
  }

  release_channel {
    channel = "REGULAR"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Override the default Compute Engine SA with the dedicated gke_nodes SA.
  # Autopilot applies this to all node VMs it provisions automatically.
  cluster_autoscaling {
      auto_provisioning_defaults {
        service_account = google_service_account.gke_nodes.email
        oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
      }
  }

  depends_on = [
    google_compute_subnetwork.gke_subnet,
  ]
}

# ──────────────────────────────────────────────────────────────────────────────
# Kata Node Pool — only provisioned when sandbox_runtime = "kata"
# Requires nested virtualization (N2 series), UBUNTU_CONTAINERD image,
# and the kata-deploy Helm chart (see kata.tf).
# ──────────────────────────────────────────────────────────────────────────────

resource "google_container_node_pool" "kata_pool" {
  count = var.sandbox_runtime == "kata" ? 1 : 0

  name       = "kata-pool"
  location   = var.region
  cluster    = google_container_cluster.standard[0].name
  node_count = var.gke_node_count

  node_config {
    machine_type = var.gke_machine_type
    image_type   = "UBUNTU_CONTAINERD"

    service_account = google_service_account.gke_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    advanced_machine_features {
      threads_per_core             = 2
      enable_nested_virtualization = true
    }

    shielded_instance_config {
      # Secure boot disabled: Kata Containers requires loading unsigned kernel
      # modules for nested virtualization (kata-clh runtime). Enabling this
      # prevents the Kata runtime from starting.
      enable_secure_boot = false
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = var.labels
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}
