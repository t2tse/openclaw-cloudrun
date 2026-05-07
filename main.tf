###############################################################################
# OpenClaw on GCP -- Main Infrastructure
# Click-to-deploy with secure-by-default settings.
###############################################################################

terraform {
  required_version = ">= 1.5"

  # Backend bucket must be created before first `terraform init`.
  # Override with: terraform init -backend-config="bucket=YOUR_BUCKET"
  backend "gcs" {
    bucket = ""
    prefix = "openclaw-cloudrun"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ──────────────────────────────────────────────────────────────────────────────
# Enable Required APIs
# ──────────────────────────────────────────────────────────────────────────────

resource "google_project_service" "apis" {
  for_each = toset([
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "compute.googleapis.com",
    "run.googleapis.com",
    "storage.googleapis.com",
    "secretmanager.googleapis.com",
    "artifactregistry.googleapis.com",
    "iap.googleapis.com",
    "logging.googleapis.com",
    "iam.googleapis.com",
    "cloudbuild.googleapis.com",
    "containerscanning.googleapis.com",
    "aiplatform.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}
