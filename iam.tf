# ──────────────────────────────────────────────────────────────────────────────
# Per-Developer Brain Service Accounts
# One SA per developer — strict IAM isolation and separate audit trail.
# Each SA is bound to exactly one Cloud Run service and one GCS workspace bucket.
# ──────────────────────────────────────────────────────────────────────────────
resource "google_service_account" "openclaw_brain" {
  for_each = var.developers

  account_id   = "${local.pfx}openclaw-brain-${each.key}"
  display_name = "OpenClaw Brain — ${each.key}"
  project      = var.project_id
}

# Vertex AI — call Gemini models via metadata server (no API key needed)
resource "google_project_iam_member" "brain_vertex_ai_user" {
  for_each = var.developers
  project  = var.project_id
  role     = "roles/aiplatform.user"
  member   = google_service_account.openclaw_brain[each.key].member
}

# Cloud Logging — write stdout/stderr from Cloud Run to Cloud Logging
resource "google_project_iam_member" "brain_logging_writer" {
  for_each = var.developers
  project  = var.project_id
  role     = "roles/logging.logWriter"
  member   = google_service_account.openclaw_brain[each.key].member
}

# Cloud Monitoring — emit custom metrics
resource "google_project_iam_member" "brain_monitoring_writer" {
  for_each = var.developers
  project  = var.project_id
  role     = "roles/monitoring.metricWriter"
  member   = google_service_account.openclaw_brain[each.key].member
}

# Cloud Run invoker — allow brain services to call the LiteLLM Cloud Run service
resource "google_project_iam_member" "brain_run_invoker" {
  for_each = var.developers
  project  = var.project_id
  role     = "roles/run.invoker"
  member   = google_service_account.openclaw_brain[each.key].member
}

# GCS workspace: each brain SA accesses only its own developer's bucket
resource "google_storage_bucket_iam_member" "openclaw_workspace_access" {
  for_each = var.developers

  bucket = google_storage_bucket.openclaw_workspace[each.key].name
  role   = "roles/storage.objectUser"
  member = google_service_account.openclaw_brain[each.key].member
}

# Secret: gateway token — all brain SAs need to read it at startup
resource "google_secret_manager_secret_iam_member" "brain_gateway_token_accessor" {
  for_each = var.developers

  secret_id = google_secret_manager_secret.gateway_token.secret_id
  project   = var.project_id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.openclaw_brain[each.key].member
}

# Secret: LiteLLM master key — brain SAs pass this to the LiteLLM proxy for auth
resource "google_secret_manager_secret_iam_member" "brain_litellm_key_accessor" {
  for_each = var.developers

  secret_id = google_secret_manager_secret.litellm_key.secret_id
  project   = var.project_id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.openclaw_brain[each.key].member
}

# Secret: Brave API key — only granted when key is configured
resource "google_secret_manager_secret_iam_member" "brain_brave_accessor" {
  for_each = var.brave_api_key != "" ? var.developers : {}

  secret_id = google_secret_manager_secret.brave_api_key[0].secret_id
  project   = var.project_id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.openclaw_brain[each.key].member
}

# ──────────────────────────────────────────────────────────────────────────────
# LiteLLM Service Account (shared, single service)
# Needs Vertex AI user + LiteLLM key secret access + logging/monitoring.
# ──────────────────────────────────────────────────────────────────────────────
resource "google_service_account" "openclaw_litellm" {
  account_id   = "${local.pfx}openclaw-litellm"
  display_name = "OpenClaw LiteLLM Service Account"
  project      = var.project_id
}

resource "google_project_iam_member" "litellm_vertex_ai_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = google_service_account.openclaw_litellm.member
}

resource "google_project_iam_member" "litellm_logging_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = google_service_account.openclaw_litellm.member
}

resource "google_project_iam_member" "litellm_monitoring_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = google_service_account.openclaw_litellm.member
}

resource "google_secret_manager_secret_iam_member" "litellm_key_accessor" {
  secret_id = google_secret_manager_secret.litellm_key.secret_id
  project   = var.project_id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.openclaw_litellm.member
}

# ──────────────────────────────────────────────────────────────────────────────
# Execution VM Service Account (optional, shared across all exec VMs)
# ──────────────────────────────────────────────────────────────────────────────
resource "google_service_account" "exec_vm" {
  count = local.exec_vms_enabled ? 1 : 0

  account_id   = "${local.pfx}openclaw-exec-vm"
  display_name = "OpenClaw Execution VM Service Account"
  project      = var.project_id
}

resource "google_project_iam_member" "exec_vm_logging_writer" {
  count   = local.exec_vms_enabled ? 1 : 0
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = google_service_account.exec_vm[0].member
}

resource "google_project_iam_member" "exec_vm_monitoring_writer" {
  count   = local.exec_vms_enabled ? 1 : 0
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = google_service_account.exec_vm[0].member
}

# Exec VMs read the gateway token to connect node hosts to Cloud Run services
resource "google_secret_manager_secret_iam_member" "exec_vm_gateway_token_accessor" {
  count     = local.exec_vms_enabled ? 1 : 0
  secret_id = google_secret_manager_secret.gateway_token.secret_id
  project   = var.project_id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.exec_vm[0].member
}

# ──────────────────────────────────────────────────────────────────────────────
# Cloud Build Service Account
# Used by Terraform's null_resource to build and push the OpenClaw image.
# ──────────────────────────────────────────────────────────────────────────────
resource "google_service_account" "cloudbuild" {
  account_id   = "${local.pfx}openclaw-cloudbuild"
  display_name = "OpenClaw Cloud Build Service Account"
  project      = var.project_id
}

resource "google_project_iam_member" "cloudbuild_builder" {
  project = var.project_id
  role    = "roles/cloudbuild.builds.builder"
  member  = google_service_account.cloudbuild.member
}

resource "google_project_iam_member" "cloudbuild_ar_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = google_service_account.cloudbuild.member
}

resource "google_project_iam_member" "cloudbuild_storage" {
  project = var.project_id
  role    = "roles/storage.objectAdmin"
  member  = google_service_account.cloudbuild.member
}

resource "google_project_iam_member" "cloudbuild_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = google_service_account.cloudbuild.member
}

# ──────────────────────────────────────────────────────────────────────────────
# IAP Access (optional — for exec VM SSH tunnels via IAP)
# ──────────────────────────────────────────────────────────────────────────────
resource "google_project_iam_member" "iap_access" {
  count   = var.deployer_service_account != "" ? 1 : 0
  project = var.project_id
  role    = "roles/iap.tunnelResourceAccessor"
  member  = "serviceAccount:${var.deployer_service_account}"
}
