###############################################################################
# Private Google Access — DNS for *.run.app
#
# Routes *.run.app to private.googleapis.com VIP so that
# Cloud Run containers with Direct VPC Egress can call other Cloud Run services
# (e.g., the LiteLLM proxy or brain services) via their *.run.app URLs without
# leaving the Google network or requiring external IP addresses.
###############################################################################

# Enable Cloud DNS API (idempotent — safe even if already enabled)
resource "google_project_service" "dns_api" {
  project            = var.project_id
  service            = "dns.googleapis.com"
  disable_on_destroy = false
}

# ──────────────────────────────────────────────────────────────────────────────
# Step 1: Private DNS zone for run.app
# ──────────────────────────────────────────────────────────────────────────────

resource "google_dns_managed_zone" "run_app_private" {
  name        = "${local.pfx}run-app-private"
  dns_name    = "run.app."
  description = "Private zone: routes *.run.app to private.googleapis.com for Private Google Access"
  project     = var.project_id
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.vpc.id
    }
  }

  depends_on = [google_project_service.dns_api]
}

# ──────────────────────────────────────────────────────────────────────────────
# Step 2: A record — run.app → private.googleapis.com IPs
# ──────────────────────────────────────────────────────────────────────────────

resource "google_dns_record_set" "run_app_a" {
  name         = "run.app."
  type         = "A"
  ttl          = 300
  managed_zone = google_dns_managed_zone.run_app_private.name
  project      = var.project_id

  # private.googleapis.com IPv4 VIP addresses
  rrdatas = [
    "199.36.153.8",
    "199.36.153.9",
    "199.36.153.10",
    "199.36.153.11",
  ]
}

# ──────────────────────────────────────────────────────────────────────────────
# Step 3: Wildcard CNAME — *.run.app → run.app
# ──────────────────────────────────────────────────────────────────────────────

resource "google_dns_record_set" "run_app_wildcard_cname" {
  name         = "*.run.app."
  type         = "CNAME"
  ttl          = 300
  managed_zone = google_dns_managed_zone.run_app_private.name
  project      = var.project_id

  rrdatas = ["run.app."]
}
