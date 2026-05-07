###############################################################################
# OpenClaw on GCP -- Terraform Variables
# Secure-by-default values for all configurable parameters.
###############################################################################

# ──────────────────────────────────────────────────────────────────────────────
# Project & Region
# ──────────────────────────────────────────────────────────────────────────────

variable "project_id" {
  description = "GCP project ID where all resources will be created."
  type        = string
}

variable "region" {
  description = "GCP region for regional resources (Cloud Run, Artifact Registry, Secret Manager)."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone for the Compute Engine instance."
  type        = string
  default     = "us-central1-c"
}

# ──────────────────────────────────────────────────────────────────────────────
# Naming
# ──────────────────────────────────────────────────────────────────────────────

variable "name_prefix" {
  description = <<-EOT
    Short prefix prepended to all resource names to avoid clashes when
    deploying alongside another OpenClaw stack (e.g. GKE) in the same project.
    Examples: "run" (default), "dev", "staging".
    Leave empty for no prefix.
  EOT
  type    = string
  default = "run"

  validation {
    condition     = can(regex("^[a-z0-9-]{0,8}$", var.name_prefix))
    error_message = "name_prefix must be lowercase alphanumeric/hyphens, max 8 chars."
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Networking
# ──────────────────────────────────────────────────────────────────────────────

variable "network_name" {
  description = "Name of the VPC network."
  type        = string
  default     = "openclaw-run-vpc"
}

variable "subnet_cidr" {
  description = "CIDR range for the Cloud Run Direct VPC Egress subnet."
  type        = string
  default     = "10.10.0.0/24"
}

variable "exec_vm_subnet_cidr" {
  description = "CIDR range for the execution VM subnet. Only used when exec_vms is non-empty."
  type        = string
  default     = "10.20.0.0/24"
}

# ──────────────────────────────────────────────────────────────────────────────
# Cloud Run
# ──────────────────────────────────────────────────────────────────────────────

variable "execution_environment" {
  description = <<-EOT
    Cloud Run execution environment for OpenClaw brain services:
      "gen2" — 2nd generation (MicroVM, seccomp syscall filtering + Sandbox2 Linux namespace
               isolation, recommended for compatibility)
      "gen1" — 1st generation (gVisor, user-space kernel with syscall interception)
  EOT
  type    = string
  default = "gen2"

  validation {
    condition     = contains(["gen1", "gen2"], var.execution_environment)
    error_message = "execution_environment must be 'gen1' or 'gen2'."
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Execution VMs (optional -- empty by default)
# Add VMs for executing OS-native commands (Windows and/or Linux).
# The OS type (Windows vs Linux) is auto-detected from the image name.
# ──────────────────────────────────────────────────────────────────────────────

variable "exec_vms" {
  description = "Map of execution VMs to create. Each VM runs per-developer node hosts that connect back to gateway services. The OS is auto-detected from the image (images containing 'windows' use PowerShell startup, others use bash)."
  type = map(object({
    machine_type      = optional(string, "e2-standard-2")
    boot_disk_size_gb = optional(number, 50)
    boot_disk_type    = optional(string, "pd-balanced")
    os_image          = string
  }))
  default = {}
}

# ──────────────────────────────────────────────────────────────────────────────
# Secrets
# ──────────────────────────────────────────────────────────────────────────────

variable "gateway_auth_token" {
  description = "OpenClaw gateway auth token. Leave empty to auto-generate a 48-char hex token."
  type        = string
  sensitive   = true
  default     = ""
}

variable "brave_api_key" {
  description = "Brave Search API key (optional). Leave empty to disable."
  type        = string
  sensitive   = true
  default     = ""
}

# ──────────────────────────────────────────────────────────────────────────────
# OpenClaw Configuration
# ──────────────────────────────────────────────────────────────────────────────

variable "openclaw_version" {
  description = "OpenClaw npm package version to install."
  type        = string
  default     = "latest"
}

variable "sandbox_image" {
  description = "Docker image for OpenClaw brain containers. When empty (default), uses the image from the project's Artifact Registry built by scripts/build_and_push.sh."
  type        = string
  default     = ""
}

variable "model_primary" {
  description = "Primary model identifier for OpenClaw agents."
  type        = string
  default     = "litellm/gemini-3.1-pro-preview"
}

variable "model_fallbacks" {
  description = "Fallback model identifiers (JSON array)."
  type        = string
  default     = "[\"litellm/gemini-3.1-flash-lite-preview\"]"
}

variable "developers" {
  description = "Map of developer names to their configuration. Each developer gets a dedicated Cloud Run service, GCS workspace bucket, and service account. Names must be lowercase alphanumeric with hyphens only."
  type = map(object({
    active = bool
  }))
  default = {
    "default" = { active = true }
  }

  validation {
    condition     = alltrue([for name in keys(var.developers) : can(regex("^[a-z0-9][a-z0-9-]{0,62}$", name))])
    error_message = "Developer names must be lowercase alphanumeric with hyphens, starting with a letter or digit (max 63 chars). This prevents command injection in startup scripts."
  }
}

variable "deployer_service_account" {
  description = "Service account email for the deployer (granted IAP tunnel access). Leave empty to skip."
  type        = string
  default     = ""
}

# ──────────────────────────────────────────────────────────────────────────────
# Monitoring & Alerting
# ──────────────────────────────────────────────────────────────────────────────

variable "alert_email" {
  description = "Email address for OpenClaw operational alerts (exec denied, node disconnects, container restarts)."
  type        = string
  default     = ""
}

# ──────────────────────────────────────────────────────────────────────────────
# Labels
# ──────────────────────────────────────────────────────────────────────────────

variable "labels" {
  description = "Labels to apply to all resources."
  type        = map(string)
  default = {
    app         = "openclaw"
    managed-by  = "terraform"
    environment = "production"
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Locals
# ──────────────────────────────────────────────────────────────────────────────

locals {
  # Resource name prefix: "run-" when name_prefix = "run", "" when empty
  pfx = var.name_prefix != "" ? "${var.name_prefix}-" : ""
}
