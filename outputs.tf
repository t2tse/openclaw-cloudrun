###############################################################################
# OpenClaw on GCP -- Outputs
###############################################################################

output "workspace_bucket_names" {
  description = "Map of developer name to their GCS workspace bucket name (used in gcloud run deploy --add-volume)."
  value = {
    for dev, _ in var.developers :
    dev => google_storage_bucket.openclaw_workspace[dev].name
  }
}

output "cloudrun_subnet" {
  description = "Name of the Cloud Run Direct VPC Egress subnet (used in gcloud run deploy --subnet)."
  value       = google_compute_subnetwork.cloudrun_subnet.name
}

output "exec_vms" {
  description = "Map of execution VM names to their internal IPs."
  value = {
    for name, vm in google_compute_instance.exec_vm : name => {
      instance_name = vm.name
      internal_ip   = vm.network_interface[0].network_ip
      os_image      = var.exec_vms[name].os_image
    }
  }
}

output "artifact_registry_url" {
  description = "Artifact Registry URL for pushing sandbox images."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.sandbox.repository_id}"
}

output "gateway_token_secret" {
  description = "Secret Manager secret ID for the gateway token."
  value       = google_secret_manager_secret.gateway_token.secret_id
}

output "litellm_key_secret" {
  description = "Secret Manager secret ID for the LiteLLM master key."
  value       = google_secret_manager_secret.litellm_key.secret_id
}

output "cloudbuild_service_account" {
  description = "Cloud Build service account email."
  value       = google_service_account.cloudbuild.email
}

output "litellm_service_account" {
  description = "LiteLLM proxy service account email."
  value       = google_service_account.openclaw_litellm.email
}

output "brain_service_accounts" {
  description = "Map of developer name to their Cloud Run brain service account email."
  value = {
    for dev, _ in var.developers :
    dev => google_service_account.openclaw_brain[dev].email
  }
}

output "secrets_configured" {
  description = "List of Secret Manager secrets created."
  sensitive   = true
  value = concat(
    [google_secret_manager_secret.gateway_token.secret_id],
    [google_secret_manager_secret.litellm_key.secret_id],
    var.brave_api_key != "" ? [google_secret_manager_secret.brave_api_key[0].secret_id] : []
  )
}
