resource "kubernetes_namespace" "openclaw" {
  metadata {
    name = "openclaw"
  }
}

# Gateway TLS certificate as K8s secret
resource "kubernetes_secret" "gateway_tls" {
  metadata {
    name      = "openclaw-gateway-tls"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }

  data = {
    "gateway-cert.pem" = tls_self_signed_cert.gateway_tls.cert_pem
    "gateway-key.pem"  = tls_private_key.gateway_tls.private_key_pem
  }

  type = "Opaque"
}

# Gateway auth token as K8s secret (sourced from Secret Manager value)
resource "kubernetes_secret" "gateway_token" {
  metadata {
    name      = "openclaw-gateway-token"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }

  data = {
    token = local.gateway_auth_token
  }

  type = "Opaque"
}

# LiteLLM master key as K8s secret (auto-generated random password)
resource "kubernetes_secret" "litellm_key" {
  metadata {
    name      = "litellm-master-key"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }

  data = {
    key = local.litellm_master_key
  }

  type = "Opaque"
}

resource "kubernetes_service_account" "openclaw_brain" {
  metadata {
    name      = "openclaw-brain"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
    annotations = {
      "iam.gke.io/gcp-service-account" = google_service_account.openclaw_brain.email
    }
  }
}

# LiteLLM proxy config for Vertex AI via ADC (Workload Identity)
resource "kubernetes_config_map" "litellm_config" {
  metadata {
    name      = "litellm-config"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }

  data = {
    "litellm_config.yaml" = yamlencode({
      model_list = [
        {
          model_name = "gemini-3.1-pro-preview"
          litellm_params = {
            model           = "vertex_ai/gemini-3.1-pro-preview"
            vertex_project  = var.project_id
            vertex_location = "global"
            timeout         = 120  # 2 minutes per request
            num_retries     = 2    # Retry failed requests twice
          }
        },
        {
          model_name = "gemini-3.1-flash-lite-preview"
          litellm_params = {
            model           = "vertex_ai/gemini-3.1-flash-lite-preview"
            vertex_project  = var.project_id
            vertex_location = "global"
            timeout         = 120  # 2 minutes per request
            num_retries     = 2    # Retry failed requests twice
          }
        }
      ]
      general_settings = {
        # master_key provided via LITELLM_MASTER_KEY env var from K8s secret
        master_key         = "os.environ/LITELLM_MASTER_KEY"
        request_timeout    = 300   # Global timeout: 5 minutes for slow models
        num_retries        = 2     # Retry on network errors
        allowed_fails      = 3     # Circuit breaker: allow 3 failures before marking unhealthy
        cooldown_time      = 10    # Wait 10s before retrying failed endpoint
      }
    })
  }
}

# Per-developer PVCs
resource "kubernetes_persistent_volume_claim" "openclaw_pvc" {
  for_each = var.developers

  metadata {
    name      = "openclaw-pvc-${each.key}"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
    labels = {
      app       = "openclaw"
      developer = each.key
    }
  }
  wait_until_bound = false
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "10Gi"
      }
    }
  }
}

# Shared LiteLLM proxy deployment
resource "kubernetes_deployment" "litellm" {
  metadata {
    name      = "litellm"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
    labels = {
      app       = "openclaw"
      component = "litellm"
    }
  }

  wait_for_rollout = false

  spec {
    # Replica count managed by HPA (kubernetes_horizontal_pod_autoscaler_v2.litellm)
    # replicas = 1

    selector {
      match_labels = {
        app       = "openclaw"
        component = "litellm"
      }
    }

    template {
      metadata {
        labels = {
          app       = "openclaw"
          component = "litellm"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.openclaw_brain.metadata[0].name

        # DNS configuration for better resolution reliability and caching
        dns_policy = "ClusterFirst"
        dns_config {
          option {
            name  = "ndots"
            value = "2"  # Reduce DNS search domain attempts
          }
          option {
            name  = "timeout"
            value = "5"  # DNS query timeout in seconds
          }
          option {
            name  = "attempts"
            value = "3"  # Retry failed DNS queries
          }
        }

        security_context {
          run_as_non_root = true
          run_as_user     = 65534
          fs_group        = 65534
        }

        container {
          name  = "litellm"
          image = "ghcr.io/berriai/litellm@sha256:7c311546c25e7bb6e8cafede9fcd3d0d622ac636b5c9418befaa32e85dfb0186"

          args = ["--config", "/app/config/litellm_config.yaml", "--port", "4000"]

          port {
            container_port = 4000
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "850Mi"  # Increased from 512Mi to match base usage (~800Mi)
            }
            limits = {
              cpu    = "500m"
              memory = "1Gi"
            }
          }

          env {
            name = "LITELLM_MASTER_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.litellm_key.metadata[0].name
                key  = "key"
              }
            }
          }

          # Logging and debugging
          env {
            name  = "LITELLM_LOG"
            value = "INFO"
          }

          # Connection pooling and DNS caching for better network resilience
          env {
            name  = "LITELLM_DROP_PARAMS"
            value = "false"
          }

          volume_mount {
            name       = "litellm-config"
            mount_path = "/app/config"
            read_only  = true
          }
        }

        volume {
          name = "litellm-config"
          config_map {
            name = kubernetes_config_map.litellm_config.metadata[0].name
          }
        }
      }
    }
  }
}

# LiteLLM internal service
resource "kubernetes_service" "litellm" {
  metadata {
    name      = "litellm"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
    labels = {
      app       = "openclaw"
      component = "litellm"
    }
  }

  spec {
    selector = {
      app       = "openclaw"
      component = "litellm"
    }

    port {
      port        = 4000
      target_port = 4000
    }
  }
}

# Horizontal Pod Autoscaler for LiteLLM
resource "kubernetes_horizontal_pod_autoscaler_v2" "litellm" {
  metadata {
    name      = "litellm"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }

  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment.litellm.metadata[0].name
    }

    min_replicas = 1
    max_replicas = 5  # For 50 OpenClaw pods: scale 1-5 LiteLLM replicas

    # Scale based on CPU usage
    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = 70  # Scale up when CPU >70%
        }
      }
    }

    # Scale based on memory usage
    metric {
      type = "Resource"
      resource {
        name = "memory"
        target {
          type                = "Utilization"
          average_utilization = 90  # Scale up when memory >90% (LiteLLM base usage ~90%)
        }
      }
    }

    behavior {
      scale_up {
        stabilization_window_seconds = 60  # Wait 60s before scaling up again
        select_policy                = "Max"
        policy {
          type           = "Percent"
          value          = 100  # Double replicas at a time
          period_seconds = 60
        }
      }
      scale_down {
        stabilization_window_seconds = 300  # Wait 5min before scaling down
        select_policy                = "Max"
        policy {
          type           = "Pods"
          value          = 1  # Remove 1 pod at a time
          period_seconds = 60
        }
      }
    }
  }
}

# Per-developer OpenClaw deployments with Kata Containers
resource "kubernetes_deployment" "openclaw_brain" {
  for_each = var.developers

  metadata {
    name      = "openclaw-brain-${each.key}"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
    labels = {
      app       = "openclaw"
      component = "brain"
      developer = each.key
    }
  }

  wait_for_rollout = false

  depends_on = [
    time_sleep.kata_ready,             # empty when sandbox_runtime = "gvisor" (count = 0)
    null_resource.build_openclaw_image,
  ]

  spec {
    replicas = each.value.active ? 1 : 0

    selector {
      match_labels = {
        app       = "openclaw"
        component = "brain"
        developer = each.key
      }
    }

    template {
      metadata {
        labels = {
          app       = "openclaw"
          component = "brain"
          developer = each.key
        }
      }

      spec {
        service_account_name = kubernetes_service_account.openclaw_brain.metadata[0].name
        # sandbox_runtime = "kata"   → kata-clh (provided by kata-deploy Helm chart)
        # sandbox_runtime = "gvisor" → gvisor   (provided by GKE Autopilot natively)
        runtime_class_name = var.sandbox_runtime == "kata" ? "kata-clh" : "gvisor"

        # DNS configuration for better resolution reliability and caching
        dns_policy = "ClusterFirst"
        dns_config {
          option {
            name  = "ndots"
            value = "2"  # Reduce DNS search domain attempts
          }
          option {
            name  = "timeout"
            value = "5"  # DNS query timeout in seconds
          }
          option {
            name  = "attempts"
            value = "3"  # Retry failed DNS queries
          }
        }

        security_context {
          run_as_non_root = true
          run_as_user     = 10001
          run_as_group    = 10001
          fs_group        = 10001
        }

        container {
          name  = "openclaw"
          image = local.openclaw_image

          port {
            container_port = 18789
          }

          resources {
            requests = {
              cpu    = "500m"
              memory = "1Gi"
            }
            limits = {
              cpu    = "2000m"
              memory = "2Gi"
            }
          }

          env {
            name  = "OPENCLAW_STATE_DIR"
            value = "/app/workspace/.openclaw-state"
          }
          # Disable internal respawn - let Kubernetes handle pod restarts
          env {
            name  = "OPENCLAW_NO_RESPAWN"
            value = "1"
          }
          # Enable Node.js compile cache for faster CLI invocations
          env {
            name  = "NODE_COMPILE_CACHE"
            value = "/app/workspace/.openclaw-state/compile-cache"
          }
          # Kata VM overhead causes the default 10s WSS handshake to time out.
          # Both gateway (server) and CLI (client) read this env var.
          env {
            name  = "OPENCLAW_HANDSHAKE_TIMEOUT_MS"
            value = "60000"
          }
          # Required: gateway uses a self-signed TLS cert with fingerprint pinning.
          # Node hosts validate via --tls-fingerprint, not CA chain.
          # Without this, the node.js process rejects the self-signed cert.
          env {
            name  = "NODE_TLS_REJECT_UNAUTHORIZED"
            value = "0"
          }
          env {
            name  = "MODEL_PRIMARY"
            value = var.model_primary
          }
          env {
            name  = "MODEL_FALLBACKS"
            value = var.model_fallbacks
          }
          env {
            name  = "VERTEXAI_PROJECT"
            value = var.project_id
          }
          env {
            name  = "VERTEXAI_LOCATION"
            value = "global"
          }
          env {
            name  = "GOOGLE_VERTEX_BASE_URL"
            value = "https://aiplatform.googleapis.com/"
          }
          env {
            name = "GATEWAY_AUTH_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.gateway_token.metadata[0].name
                key  = "token"
              }
            }
          }
          env {
            name = "LITELLM_MASTER_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.litellm_key.metadata[0].name
                key  = "key"
              }
            }
          }
          env {
            name  = "EXEC_VMS_ENABLED"
            value = local.exec_vms_enabled ? "true" : "false"
          }
          # Gateway bind mode: "lan" when exec VMs need network access, "loopback" otherwise
          env {
            name  = "GATEWAY_BIND"
            value = local.exec_vms_enabled ? "lan" : "loopback"
          }
          volume_mount {
            name       = "workspace"
            mount_path = "/app/workspace"
          }

          volume_mount {
            name       = "gateway-tls"
            mount_path = "/app/tls"
            read_only  = true
          }

        }

        volume {
          name = "workspace"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.openclaw_pvc[each.key].metadata[0].name
          }
        }

        volume {
          name = "gateway-tls"
          secret {
            secret_name = kubernetes_secret.gateway_tls.metadata[0].name
          }
        }
      }
    }
  }
}

# Per-developer gateway services (for execution VM node host to connect)
# Uses Internal Load Balancer so the VM can reach gateway pods from the VPC
# Only created when execution VM is enabled
resource "kubernetes_service" "openclaw_gateway" {
  for_each = local.exec_vms_enabled ? var.developers : {}

  metadata {
    name      = "openclaw-gateway-${each.key}"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
    labels = {
      app       = "openclaw"
      component = "brain"
      developer = each.key
    }
    annotations = {
      "networking.gke.io/load-balancer-type"                     = "Internal"
      "networking.gke.io/internal-load-balancer-allow-global-access" = "true"
    }
  }

  spec {
    selector = {
      app       = "openclaw"
      component = "brain"
      developer = each.key
    }

    type = "LoadBalancer"

    port {
      port        = 18789
      target_port = 18789
    }
  }
}
