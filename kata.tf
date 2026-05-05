# ──────────────────────────────────────────────────────────────────────────────
# Kata Containers — installed via official kata-deploy Helm chart
# Provides RuntimeClasses: kata-clh, kata-qemu, etc.
# Only deployed when sandbox_runtime = "kata".
# ──────────────────────────────────────────────────────────────────────────────

resource "helm_release" "kata_deploy" {
  count = var.sandbox_runtime == "kata" ? 1 : 0

  name       = "kata-deploy"
  repository = "oci://ghcr.io/kata-containers/kata-deploy-charts"
  chart      = "kata-deploy"
  version    = "3.28.0"
  namespace  = "default"

  # Wait for the DaemonSet pods to become ready (installs Kata on each node)
  wait    = true
  timeout = 900 # 15 minutes — Kata install/cleanup DaemonSet can be slow

  depends_on = [
    null_resource.kubeconfig,
    google_container_node_pool.kata_pool[0],
  ]
}

# Give kata-deploy DaemonSet time to configure containerd and restart it on all nodes
resource "time_sleep" "kata_ready" {
  count = var.sandbox_runtime == "kata" ? 1 : 0

  depends_on      = [helm_release.kata_deploy[0]]
  create_duration = "30s"
}
