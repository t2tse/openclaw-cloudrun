###############################################################################
# OpenClaw Logging -- Alerts, Dashboard, and Log Routing
###############################################################################

# ──────────────────────────────────────────────────────────────────────────────
# Enable Monitoring API
# ──────────────────────────────────────────────────────────────────────────────

resource "google_project_service" "monitoring_api" {
  project            = var.project_id
  service            = "monitoring.googleapis.com"
  disable_on_destroy = false
}

# ──────────────────────────────────────────────────────────────────────────────
# Notification Channel (email)
# ──────────────────────────────────────────────────────────────────────────────

resource "google_monitoring_notification_channel" "openclaw_email" {
  count = var.alert_email != "" ? 1 : 0

  display_name = "OpenClaw Alerts"
  type         = "email"
  project      = var.project_id

  labels = {
    email_address = var.alert_email
  }

  depends_on = [google_project_service.monitoring_api]
}

# ──────────────────────────────────────────────────────────────────────────────
# Log-Based Alerts
# ──────────────────────────────────────────────────────────────────────────────

# Alert 1: Exec approval denied (SYSTEM_RUN_DENIED)
resource "google_logging_metric" "exec_denied" {
  name    = "${local.pfx}openclaw/exec_denied"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloud_run_revision"
    resource.labels.service_name=~"${local.pfx}openclaw-brain.*"
    textPayload=~"SYSTEM_RUN_DENIED"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}

resource "google_monitoring_alert_policy" "exec_denied" {
  count = var.alert_email != "" ? 1 : 0

  display_name = "OpenClaw: Exec Approval Denied"
  project      = var.project_id
  combiner     = "OR"

  conditions {
    display_name = "Exec approval denied (SYSTEM_RUN_DENIED)"

    condition_threshold {
      filter          = "resource.type = \"cloud_run_revision\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.exec_denied.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.openclaw_email[0].name]

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    content   = "An exec command was denied on an OpenClaw node host. This means the exec-approvals.json on the node has empty or restrictive defaults. Check the auto-approve loop in the gateway entrypoint and verify the node is receiving approval pushes."
    mime_type = "text/markdown"
  }

  depends_on = [google_project_service.monitoring_api]
}

# Alert 2: Node host disconnected (NOT_CONNECTED errors indicate stale pairings or network issues)
resource "google_logging_metric" "node_disconnected" {
  name    = "${local.pfx}openclaw/node_disconnected"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloud_run_revision"
    resource.labels.service_name=~"${local.pfx}openclaw-brain.*"
    textPayload=~"NOT_CONNECTED: node not connected"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}

resource "google_monitoring_alert_policy" "node_disconnected" {
  count = var.alert_email != "" ? 1 : 0

  display_name = "OpenClaw: Node Host Disconnected"
  project      = var.project_id
  combiner     = "OR"

  conditions {
    display_name = "High rate of node disconnection errors"

    condition_threshold {
      filter          = "resource.type = \"cloud_run_revision\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.node_disconnected.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 50
      duration        = "300s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.openclaw_email[0].name]

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    content   = "High rate of NOT_CONNECTED errors from OpenClaw gateway. This usually means stale paired node entries or that a node host VM is down. Check VM status and consider cleaning up stale pairings."
    mime_type = "text/markdown"
  }

  depends_on = [google_project_service.monitoring_api]
}

# Alert 3: Gateway crash / pod restart
resource "google_logging_metric" "gateway_crash" {
  name    = "${local.pfx}openclaw/gateway_restart"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloud_run_revision"
    resource.labels.service_name=~"${local.pfx}openclaw-brain.*"
    severity>="ERROR"
    textPayload=~"process exited|container.*exit|SIGKILL|unhandledRejection"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}

resource "google_monitoring_alert_policy" "gateway_crash" {
  count = var.alert_email != "" ? 1 : 0

  display_name = "OpenClaw: Gateway Container Crash"
  project      = var.project_id
  combiner     = "OR"

  conditions {
    display_name = "Gateway container exiting repeatedly"

    condition_threshold {
      filter          = "resource.type = \"cloud_run_revision\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.gateway_crash.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.openclaw_email[0].name]

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    content   = "An OpenClaw gateway container is crashing. Common causes: invalid config (gateway.bind != 'lan'), missing secrets, or throwOnLoadError issues. Check logs with: gcloud logging read 'resource.type=\"cloud_run_revision\"' --project=PROJECT_ID --limit=50"
    mime_type = "text/markdown"
  }

  depends_on = [google_project_service.monitoring_api]
}

# Alert 4: VM node host service failure (Linux)
resource "google_logging_metric" "vm_node_failure" {
  name    = "${local.pfx}openclaw/vm_node_failure"
  project = var.project_id
  filter  = <<-EOT
    resource.type="gce_instance"
    logName=~"logs/openclaw"
    textPayload=~"Node host exited|ERROR|failed"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}

resource "google_monitoring_alert_policy" "vm_node_failure" {
  count = var.alert_email != "" ? 1 : 0

  display_name = "OpenClaw: VM Node Host Failure"
  project      = var.project_id
  combiner     = "OR"

  conditions {
    display_name = "VM node host process exited or errored"

    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.vm_node_failure.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 5
      duration        = "300s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.openclaw_email[0].name]

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    content   = "An OpenClaw node host process on a VM is repeatedly failing. Check the VM's serial console and journald (Linux) or Event Viewer (Windows) for details."
    mime_type = "text/markdown"
  }

  depends_on = [google_project_service.monitoring_api]
}

# ──────────────────────────────────────────────────────────────────────────────
# Log Storage -- GCS Bucket Sink
# All OpenClaw logs (Cloud Run services + VMs) are exported to a GCS bucket for long-term
# retention, querying, and compliance. Cloud Logging retains logs for 30 days;
# the bucket provides unlimited retention.
# ──────────────────────────────────────────────────────────────────────────────

resource "google_storage_bucket" "openclaw_logs" {
  name          = "${var.project_id}-${local.pfx}openclaw-logs"
  location      = var.region
  project       = var.project_id
  force_destroy = false

  uniform_bucket_level_access = true

  lifecycle_rule {
    condition {
      age = 90
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }

  lifecycle_rule {
    condition {
      age = 365
    }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
  }

  labels = var.labels
}

# Log sink: export all OpenClaw-related logs to the GCS bucket
resource "google_logging_project_sink" "openclaw_gcs" {
  name        = "${local.pfx}openclaw-logs-to-gcs"
  project     = var.project_id
  destination = "storage.googleapis.com/${google_storage_bucket.openclaw_logs.name}"

  filter = <<-EOT
    (resource.type="cloud_run_revision" AND resource.labels.service_name=~"${local.pfx}openclaw.*")
    OR
    (resource.type="gce_instance" AND resource.labels.instance_id=~"openclaw-exec-.*")
  EOT

  unique_writer_identity = true
}

# Grant the log sink's service account write access to the bucket
resource "google_storage_bucket_iam_member" "log_sink_writer" {
  bucket = google_storage_bucket.openclaw_logs.name
  role   = "roles/storage.objectCreator"
  member = google_logging_project_sink.openclaw_gcs.writer_identity
}

# ──────────────────────────────────────────────────────────────────────────────
# Centralized Logging Dashboard
# ──────────────────────────────────────────────────────────────────────────────

resource "google_monitoring_dashboard" "openclaw" {
  project        = var.project_id
  dashboard_json = jsonencode({
    displayName = "OpenClaw Operations"
    mosaicLayout = {
      columns = 12
      tiles = [
        {
          xPos   = 0
          yPos   = 0
          width  = 6
          height = 4
          widget = {
            title = "Brain Service Logs (all developers)"
            logsPanel = {
              filter = "resource.type=\"cloud_run_revision\"\nresource.labels.service_name=~\"${local.pfx}openclaw-brain.*\""
            }
          }
        },
        {
          xPos   = 6
          yPos   = 0
          width  = 6
          height = 4
          widget = {
            title = "Execution VM Logs"
            logsPanel = {
              filter = "resource.type=\"gce_instance\"\nresource.labels.instance_id=~\"openclaw-exec-.*\""
            }
          }
        },
        {
          xPos   = 0
          yPos   = 4
          width  = 4
          height = 4
          widget = {
            title = "Exec Denied Events"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "resource.type = \"cloud_run_revision\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.exec_denied.name}\""
                    aggregation = {
                      alignmentPeriod  = "300s"
                      perSeriesAligner = "ALIGN_SUM"
                    }
                  }
                }
              }]
              timeshiftDuration = "0s"
              yAxis = { scale = "LINEAR" }
            }
          }
        },
        {
          xPos   = 4
          yPos   = 4
          width  = 4
          height = 4
          widget = {
            title = "Node Disconnection Errors"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "resource.type = \"cloud_run_revision\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.node_disconnected.name}\""
                    aggregation = {
                      alignmentPeriod  = "300s"
                      perSeriesAligner = "ALIGN_SUM"
                    }
                  }
                }
              }]
              timeshiftDuration = "0s"
              yAxis = { scale = "LINEAR" }
            }
          }
        },
        {
          xPos   = 8
          yPos   = 4
          width  = 4
          height = 4
          widget = {
            title = "VM Node Host Failures"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "resource.type = \"gce_instance\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.vm_node_failure.name}\""
                    aggregation = {
                      alignmentPeriod  = "300s"
                      perSeriesAligner = "ALIGN_SUM"
                    }
                  }
                }
              }]
              timeshiftDuration = "0s"
              yAxis = { scale = "LINEAR" }
            }
          }
        },
        {
          xPos   = 0
          yPos   = 8
          width  = 6
          height = 4
          widget = {
            title = "Brain Service Errors Only"
            logsPanel = {
              filter = "resource.type=\"cloud_run_revision\"\nresource.labels.service_name=~\"${local.pfx}openclaw-brain.*\"\nseverity>=\"ERROR\""
            }
          }
        },
        {
          xPos   = 6
          yPos   = 8
          width  = 6
          height = 4
          widget = {
            title = "WebSocket Activity"
            logsPanel = {
              filter = "resource.type=\"cloud_run_revision\"\nresource.labels.service_name=~\"${local.pfx}openclaw-brain.*\"\ntextPayload=~\"\\\\[ws\\\\]\""
            }
          }
        }
      ]
    }
  })

  depends_on = [google_project_service.monitoring_api]
}
