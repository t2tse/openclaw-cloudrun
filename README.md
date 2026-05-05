# OpenClaw on GCP — Multi-Tenant GKE with Sandbox Isolation

Deploy [OpenClaw](https://docs.openclaw.ai) on Google Cloud with sandbox isolation (Kata Containers on GKE Standard, or gVisor on GKE Autopilot), and Vertex AI — fully managed by Terraform. Optionally add execution VMs (Windows/Linux) for OS-native command execution.

---

## Table of Contents

- [Architecture](#architecture)
- [Sandbox Runtime Options](#sandbox-runtime-options)
- [Security Features](#security-features)
- [Deployment Guide](#deployment-guide)
- [End-to-End Testing](#end-to-end-testing)
- [Adding Messaging Channels](#adding-messaging-channels)
  - [Telegram](#telegram)
- [Execution VM (Optional)](#execution-vm-optional)
- [Windows VM Golden Image](#windows-vm-golden-image)
- [Observability](#observability)
- [Variables Reference](#variables-reference)
- [Outputs Reference](#outputs-reference)
- [File Structure](#file-structure)
- [Troubleshooting](#troubleshooting)
- [Cleanup](#cleanup)

---

## Architecture

[Back to top](#table-of-contents)

### Default: GKE-Only (no execution VM)

```mermaid
graph TD
    Dev["Developer (kubectl / TUI)"]

    Dev -->|"IAP TCP Tunnel"| GKE

    subgraph GCP["GCP Project"]

        subgraph GKE["GKE (Standard: kata-clh  |  Autopilot: gvisor)"]
            subgraph NS["Namespace: openclaw"]

                subgraph PodA["Pod: openclaw-brain-alice"]
                    direction LR
                    GA["OpenClaw Gateway\n(:18789)"]
                end

                subgraph PodB["Pod: openclaw-brain-bob"]
                    direction LR
                    GB["OpenClaw Gateway\n(:18789)"]
                end

                LITELLM["LiteLLM Proxy\n(:4000)"]

                PodA -.-|"mount"| PVCA["PVC alice (10Gi)"]
                PodB -.-|"mount"| PVCB["PVC bob (10Gi)"]

                GA -->|"localhost:4000"| LITELLM
                GB -->|"localhost:4000"| LITELLM

                KSA["K8s SA: openclaw-brain"]
                PodA -.- KSA
                PodB -.- KSA
            end
        end

        KSA -->|"Workload Identity"| GSA["GCP SA: openclaw-brain@"]
        GSA -->|"roles/aiplatform.user"| Vertex["Vertex AI\nGemini Models"]
        LITELLM -->|"Workload Identity\nNo API Keys"| Vertex

        SM["Secret Manager\n(gateway-token, brave-key)"]
        SM -.-|"mount as env"| NS

        subgraph Ops["Operations"]
            direction LR
            Logging["Cloud Logging"]
            GCS["GCS Log Bucket"]
            Mon["Monitoring\nDashboard + Alerts"]
            Logging --> GCS
            Logging --> Mon
        end

        GKE -->|"pod logs"| Logging

        AR["Artifact Registry"] -->|"pull image"| GKE

        subgraph Net["VPC Network"]
            direction LR
            NAT["Cloud NAT\n(outbound only)"]
            FW["Deny-all ingress\n+ IAP SSH only"]
        end

        GKE --- Net
    end
```

### With Execution VM (`enable_exec_vm = true`)

```mermaid
graph TD
    Dev["Developer (kubectl / TUI)"]

    Dev -->|"IAP TCP Tunnel"| GCP

    subgraph GCP["GCP Project"]

        subgraph GKE["GKE (Standard: kata-clh  |  Autopilot: gvisor)"]
            subgraph NS["Namespace: openclaw"]
                PodA["Pod: openclaw-brain-alice\n(gateway :18789)"]
                PodB["Pod: openclaw-brain-bob\n(gateway :18789)"]
                LITELLM["LiteLLM Proxy\n(:4000)"]
                PodA --> LITELLM
                PodB --> LITELLM
            end
        end

        subgraph VM["Execution VMs (Shielded, No Public IP)"]
            direction TB
            NH_A["Node Host: alice"]
            NH_B["Node Host: bob"]
            OPS["Ops Agent\n(journald / Event Log)"]
        end

        PodA <-->|"ILB (TLS :18789)"| NH_A
        PodB <-->|"ILB (TLS :18789)"| NH_B

        LITELLM -->|"Workload Identity"| Vertex["Vertex AI\nGemini Models"]

        SM["Secret Manager"] --> GKE
        SM --> VM

        subgraph Ops["Operations"]
            direction LR
            Logging["Cloud Logging"]
            GCS["GCS Log Bucket"]
            Mon["Dashboard + Alerts"]
            Logging --> GCS
            Logging --> Mon
        end

        GKE -->|"stdout/stderr"| Logging
        OPS -->|"node host logs"| Logging

        subgraph Net["VPC Network"]
            NAT["Cloud NAT"]
            FW["Firewall Rules"]
        end

        GKE --- Net
        VM --- Net
    end
```

### Component Overview

| Component | Purpose |
|-----------|---------|
| **GKE Standard + Kata** | Managed Kubernetes (Standard mode) with VM-level pod isolation via Kata Containers (`sandbox_runtime = "kata"`) |
| **GKE Autopilot + gVisor** | Fully-managed Kubernetes (Autopilot mode) with user-space kernel isolation via gVisor (`sandbox_runtime = "gvisor"`) |
| **LiteLLM Proxy** | Routes LLM requests to Vertex AI Gemini models via Workload Identity — no API keys |
| **Workload Identity** | Maps K8s ServiceAccount to GCP SA — no service account keys stored anywhere |
| **Per-Developer Pods** | Each developer gets an isolated pod + PVC with their own OpenClaw gateway instance |
| **Execution VM** *(optional)* | Windows or Linux VM for OS-native command execution (PowerShell, CMD, bash) |
| **Node Hosts** *(optional)* | Per-developer `openclaw node run` processes on VMs, connecting to gateway pods over TLS WebSocket |
| **Internal Load Balancers** *(optional)* | Per-developer ILBs for VM-to-GKE connectivity |
| **Cloud Monitoring** | Dashboard with 7 tiles, alert policies for crashes, disconnections, and exec denials |
| **Cloud Logging** | Logs routed to GCS with lifecycle policies (90d Nearline, 365d Coldline) |

[Back to top](#table-of-contents)

---

## Sandbox Runtime Options

[Back to top](#table-of-contents)

OpenClaw supports two pod sandbox runtimes, selectable via the `sandbox_runtime` variable. **Each runtime deploys a different GKE cluster mode:**

| | `kata` (default) | `gvisor` |
|---|---|---|
| **GKE cluster mode** | **Standard** | **Autopilot** |
| **Node pool** | `kata-pool` (user-managed) | Managed by Autopilot |
| **RuntimeClass** | `kata-clh` | `gvisor` |
| **Isolation model** | Lightweight VM per pod (KVM/QEMU) | User-space kernel (syscall interception) |
| **Machine type** | N2 series (nested virtualization required) | Managed by Autopilot |
| **Node image** | `UBUNTU_CONTAINERD` | Managed by Autopilot |
| **Extra setup** | kata-deploy Helm chart + DaemonSet | None (Autopilot supports gVisor natively) |
| **Secure Boot** | Disabled (unsigned kernel modules) | Enabled |
| **Overhead** | ~256 MB RAM + VM startup latency | Lower overhead, no VM boot |

### Choosing a Runtime

**Use `kata`** when you need the strongest isolation boundary (hardware-enforced VM per pod). Required if you are running untrusted code that must be fully kernel-isolated.

**Use `gvisor`** when you want simpler setup, fully managed nodes, and can accept a user-space syscall-filtering boundary. Autopilot manages all node provisioning automatically — no node pools, machine types, or Helm charts to configure.

### Configuring the Runtime

In `terraform.tfvars`:

```hcl
# Option 1: Kata Containers — GKE Standard cluster (default)
sandbox_runtime = "kata"

# Option 2: gVisor — GKE Autopilot cluster
sandbox_runtime = "gvisor"
```

Only one cluster is provisioned at a time. Switching runtimes on an existing deployment requires destroying and re-creating the cluster — plan for downtime accordingly.

[Back to top](#table-of-contents)

---

## Security Features

[Back to top](#table-of-contents)

### Sandbox Isolation

Every OpenClaw brain pod runs inside a sandbox runtime — either Kata Containers (Standard cluster) or gVisor (Autopilot cluster) — selected at deploy time via `sandbox_runtime`.

#### Kata Containers (`sandbox_runtime = "kata"`) — GKE Standard

Every pod runs inside a [Kata Container](https://katacontainers.io/) providing full VM isolation via [nested virtualization](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/nested-virtualization) on N2 nodes:

- **Full kernel isolation** — Each pod gets its own guest kernel. Even if OpenClaw executes malicious code, it cannot reach the host kernel.
- **Hardware-enforced boundary** — KVM/QEMU provides a true VM boundary, stronger than syscall filtering.
- **Explicit opt-in** — Pods use `runtimeClassName: kata-clh`, installed via the kata-deploy Helm chart.

#### gVisor (`sandbox_runtime = "gvisor"`) — GKE Autopilot

Every pod runs under [gVisor](https://gvisor.dev/) on a fully-managed GKE Autopilot cluster:

- **Syscall interception** — The `runsc` runtime intercepts all Linux syscalls before they reach the host kernel, significantly reducing the attack surface.
- **No VM overhead** — gVisor runs in user-space; no VM boot, lower memory overhead (~50–80 MB vs ~256 MB for Kata).
- **Zero node management** — GKE Autopilot provisions and manages all nodes automatically. No node pools, machine types, or OS images to configure.
- **Native Autopilot support** — Pods use `runtimeClassName: gvisor`; Autopilot automatically schedules them on gVisor-capable nodes. No Helm chart needed.

### Zero API Keys in the Cluster

The authentication chain uses identity federation — no API key secrets exist:

```
Pod → K8s ServiceAccount → Workload Identity → GCP Service Account → Vertex AI
```

- LiteLLM uses Application Default Credentials via the metadata server.
- Tokens are automatically refreshed — no key rotation needed.
- The only secrets stored are the gateway auth token (auto-generated) and optional Brave API key.

### Network Isolation

| Control | Implementation |
|---------|---------------|
| Private GKE nodes | Nodes have no public IPs |
| Cloud NAT | Outbound-only internet access for pulling images and calling Vertex AI |
| Deny-all ingress firewall | Only IAP SSH (`35.235.240.0/20`) and VM-to-GKE (`:18789`) allowed |
| Master authorized networks | Control plane restricted to GKE/VM subnets + explicitly listed CIDRs |
| Per-developer PVC isolation | Each developer's data is on a separate PersistentVolumeClaim |
| VPC flow logs | Enabled on GKE subnet with full metadata |

### IAM Least Privilege

| Service Account | Roles | Purpose |
|----------------|-------|---------|
| `openclaw-brain` | `aiplatform.user`, `logging.logWriter`, `monitoring.metricWriter` | Pod workload identity |
| `openclaw-exec-vm` | `logging.logWriter`, `monitoring.metricWriter` | VM log/metric shipping |
| Per-secret IAM | `secretmanager.secretAccessor` | Individual secret bindings, not project-wide |

### Application Security

| Layer | Protection |
|-------|-----------|
| **TLS + fingerprint pinning** | Self-signed ECDSA P256 cert, SHA256 fingerprint validated by node hosts |
| **Token authentication** | All WebSocket connections require `OPENCLAW_GATEWAY_TOKEN` from Secret Manager |
| **Non-root containers** | UID 10001, enforced by `runAsNonRoot: true` |
| **Shielded VMs** | Secure Boot, vTPM, Integrity Monitoring on GKE nodes and execution VMs |
| **Container scanning** | `containerscanning.googleapis.com` enabled on Artifact Registry |
| **Pinned LiteLLM image** | SHA256 digest, not mutable tag |
| **Cluster deletion protection** | `deletion_protection = true` |

### Device Auth Design Decision

This deployment sets `dangerouslyDisableDeviceAuth: true` — a deliberate choice for headless/server deployments, **not** a security oversight.

**Why:** With device auth enabled, every WebSocket connection requires interactive pairing approval. In a headless GKE deployment there is no UI to approve the first operator pairing — creating a chicken-and-egg problem.

**Why it is still secure:** The gateway sits on a private ILB (`10.10.0.0/24`), all connections require the gateway auth token from Secret Manager, and VPC firewall rules restrict access to pods and VMs on the VPC. For channel-level access control (e.g., Telegram), use `dmPolicy: "pairing"` on each channel.

> **Warning:** Never set `dangerouslyDisableDeviceAuth: false` in headless deployments — it will permanently lock out all connections if pairing data is lost.

[Back to top](#table-of-contents)

---

## Deployment Guide

[Back to top](#table-of-contents)

### Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- [gcloud CLI](https://cloud.google.com/sdk/docs/install) authenticated with a project owner account
- [kubectl](https://kubernetes.io/docs/tasks/tools/) installed
- A GCP project with billing enabled

### Step 1: Project Org Policy Update

#### Kata Containers only (`sandbox_runtime = "kata"`)

Kata requires loading unsigned kernel modules for nested virtualization. These org policies must be relaxed:

> Requires `roles/orgpolicy.policyAdmin` IAM role.

```bash
export PROJECT_ID="my-gcp-project"
gcloud resource-manager org-policies disable-enforce compute.requireShieldedVm --project=$PROJECT_ID
gcloud resource-manager org-policies disable-enforce compute.disableNestedVirtualization --project=$PROJECT_ID
```

#### gVisor (`sandbox_runtime = "gvisor"`)

No org policy changes required. GKE Autopilot is a fully managed GKE feature — skip this step entirely.

### Step 2: Create the State Bucket

```bash
export PROJECT_ID="my-gcp-project"
export TF_STATE_BUCKET_REGION="asia-southeast1"

# Create Terraform state bucket
gsutil mb -p "$PROJECT_ID" -l $TF_STATE_BUCKET_REGION "gs://${PROJECT_ID}-openclaw-gke-tf-state"
gsutil versioning set on "gs://${PROJECT_ID}-openclaw-gke-tf-state"
```

[Back to top](#table-of-contents)

### Step 3: Clone and Configure

```bash
git clone https://github.com/zken-cloud/openclaw-gke-kata.git
cd openclaw-gke-kata
```

Copy `terraform.tfvars.example` to `terraform.tfvars` and edit:

```hcl
# Required
project_id = "my-gcp-project"

# Target Region & Zone to deploy
region = "us-central1"
zone   = "us-central1-c"

# Developers / OpenClaw Users -- each gets an isolated OpenClaw pod + PVC
developers = {
  "alice" = { active = true }
  "bob"   = { active = true }
}

# OpenClaw
openclaw_version = "latest"
model_primary    = "litellm/gemini-3.1-pro-preview"
model_fallbacks  = "[\"litellm/gemini-3.1-flash-lite-preview\"]"

# Sandbox runtime — choose one:
#   "kata"   — GKE Standard cluster, kata-pool (N2 nodes, kata-clh RuntimeClass, kata-deploy Helm chart)
#   "gvisor" — GKE Autopilot cluster, gVisor RuntimeClass, no node pools or Helm chart needed
sandbox_runtime = "kata"

# GKE Control plane access (add your IP/CIDR)
master_authorized_cidrs = {
  "My IP"   = "YOUR_IP/32"
  "My CIDR" = "YOUR_SUBNET/24"
}

# Optional: Execution VMs (uncomment to enable)
# exec_vms = {
#   "windows" = { os_image = "windows-cloud/windows-2022-core" }
#   "linux"   = { os_image = "debian-cloud/debian-12" }
# }

# Alerts (optional)
alert_email = "you@example.com"
```

Getting the client external IP for GKE Control plane access (`master_authorized_cidrs`)
```bash
curl ifconfig.me
```


Set sensitive variables via environment:

```bash
export TF_VAR_gateway_auth_token=""  # leave empty to auto-generate
export TF_VAR_brave_api_key=""       # optional
```

[Back to top](#table-of-contents)

### Step 4: Deploy

```bash
terraform init -backend-config="bucket=${PROJECT_ID}-openclaw-gke-tf-state"
terraform plan
terraform apply
```

This will:
1. Enable all required GCP APIs
2. Create VPC, subnet, Cloud NAT, firewall rules
3. Create a GKE cluster based on the selected runtime:
   - **`kata`** — GKE **Standard** cluster with N2 nodes, nested virtualization, and kata-deploy Helm chart
   - **`gvisor`** — GKE **Autopilot** cluster; gVisor RuntimeClass available natively, no node pools to manage
4. *(kata only)* Install Kata Containers via the kata-deploy Helm chart
5. Deploy per-developer OpenClaw pods, PVCs, and ILB services
6. Deploy LiteLLM proxy with Workload Identity
7. Create Secret Manager secrets and IAM bindings
8. Set up monitoring dashboard, alert policies, and log sink
9. *(If `exec_vms` is non-empty)* Create execution VMs, subnet, firewall, and node hosts

Deployment takes approximately 15–20 minutes (GKE cluster creation is the bottleneck).

Note 1: If you see this error while Terraform is running, your client host is likely on a different GKE context. 
Get cluster credentials in Step 6 would give you the correct GKE context and the control plane IP for Terraform to conenct to.
```
│ Error: Post "https://<Invalid GKE Control Plane IP>/api/v1/namespaces": dial tcp <Invalid GKE Control Plane IP>: i/o timeout
│ 
│   with kubernetes_namespace.openclaw,
│   on kubernetes.tf line 1, in resource "kubernetes_namespace" "openclaw":
│    1: resource "kubernetes_namespace" "openclaw" {
│ 
╵
```

Note 2: Sometimes there is race condition when executing the container image build while the IAM permission is propagating in the background. Run `terraform apply` once again to continue.
```
 Error: local-exec provisioner error
│ 
│   with null_resource.build_openclaw_image,
│   on storage.tf line 77, in resource "null_resource" "build_openclaw_image":
│   77:   provisioner "local-exec" {
│ 
│ Error running command 'bash ./scripts/build_and_push.sh': exit status 1. Output: Building and pushing image using Cloud Build...
│ Creating temporary archive of 100 file(s) totalling 395.5 KiB before compression.
│ Uploading tarball of [.] to [gs://<PROJECT_ID>/source/<hex number>.tgz]
│ ERROR: (gcloud.builds.submit) INVALID_ARGUMENT: could not resolve source: googleapi: Error 403: openclaw-cloudbuild@<PROJECT_ID>.iam.gserviceaccount.com does not have
│ storage.objects.get access to the Google Cloud Storage object. Permission 'storage.objects.get' denied on resource (or it may not exist)., forbidden
```

[Back to top](#table-of-contents)

### Step 5 (Optional): Build and Push the Container Image then Restart Pods.

> **This step can be skipped** by default it uses the openclaw image built in the project Artifact Registry

> **Only run this step** if you customise the image Dockerfile and want to redeploy.
```bash
export PROJECT_ID="my-gcp-project"
export REGION="us-central1"
./scripts/build_and_push.sh
```

```bash
kubectl rollout restart deployment -n openclaw -l component=brain
```

[Back to top](#table-of-contents)

### Step 6: Verify

```bash
# Get cluster credentials
export REGION="us-central1"

gcloud container clusters get-credentials openclaw-cluster \
  --region $(terraform output -raw gke_cluster_region 2>/dev/null || echo $REGION) \
  --project $PROJECT_ID

# Check pods are running
kubectl get pods -n openclaw

# Expected:
# NAME                                    READY   STATUS    AGE
# litellm-xxxxx                           1/1     Running   5m
# openclaw-brain-alice-xxxxx              1/1     Running   5m
# openclaw-brain-bob-xxxxx                1/1     Running   5m

# Verify sandbox runtime is active
kubectl get pods -n openclaw -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.runtimeClassName}{"\n"}{end}'
# kata:   openclaw-brain-alice -> kata-clh
# gvisor: openclaw-brain-alice -> gvisor

# Verify non-root
kubectl exec -n openclaw deployment/openclaw-brain-alice -- id
# Expected: uid=10001(openclaw) gid=10001(openclaw)
```

#### Optional: Kata Containers — verify nested virtualization

Confirm [nested virtualization is enabled](https://docs.cloud.google.com/compute/docs/instances/nested-virtualization/enabling#confirm_that_nested_virtualization_is_enabled_on_the_vm) on GKE Node:

```bash
# Connect to the GKE Node VM instance
gcloud compute ssh "my-gke-node-vm-name"

# Verify nested virtualization is enabled
grep -cw vmx /proc/cpuinfo
```

If nested virtualization is disabled, brain pods will fail with:
```
openclaw-brain-alice, openclaw-brain-bob stuck at ContainerCreating
Failed to create pod sandbox: rpc error: code = Unknown desc = failed to start sandbox "some-hex-number": failed to create containerd task: failed to create shim task: Could not create the sandbox resource controller failed to add any hypervisor device to devices cgroup	FailedCreatePodSandBox
```

#### Optional: gVisor — verify RuntimeClass (Autopilot)

```bash
# Confirm the gvisor RuntimeClass exists (registered automatically by Autopilot)
kubectl get runtimeclass gvisor

# Verify pod is using gVisor
kubectl get pods -n openclaw -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.runtimeClassName}{"\n"}{end}'
# Expected: openclaw-brain-alice -> gvisor
```

[Back to top](#table-of-contents)

### Step 7: Approve Node Host Pairing (only if `exec_vms` is non-empty)

Wait 3–5 minutes for the VM startup script to install OpenClaw and start node hosts. Each node host will attempt to connect to its developer's gateway pod and request pairing approval.

> **Automatic Pairing (New):** When `exec_vms` is non-empty, a background loop automatically approves pending node host pairing requests every 60 seconds. This loop is **automatically disabled** when no execution VMs are deployed to avoid event loop blocking. Manual approval via TUI/CLI is still supported if you prefer manual control.

#### Option A: Approve via TUI

```bash
kubectl exec -it -n openclaw deployment/openclaw-brain-alice -- npx openclaw tui
```

Once in the TUI, you will see a pairing request notification. Type the approval command shown (e.g., `/approve <request-id> allow`).

#### Option B: Approve via CLI

```bash
# List pending pairing requests
kubectl exec -n openclaw deployment/openclaw-brain-alice -- npx openclaw nodes pending

# Approve a pending request by ID
kubectl exec -n openclaw deployment/openclaw-brain-alice -- npx openclaw nodes approve <REQUEST_ID>
```

> **Tip:** The node host retries every 10 seconds. If `nodes pending` shows no requests, wait a moment and try again — the request may appear briefly between retries.

#### Verify Connection

```bash
# Check alice's nodes
kubectl exec -n openclaw deployment/openclaw-brain-alice -- npx openclaw nodes status
# Expected: linux-alice and/or windows-alice showing "paired · connected"

# Check bob
kubectl exec -n openclaw deployment/openclaw-brain-bob -- npx openclaw nodes status
```

[Back to top](#table-of-contents)

---

## End-to-End Testing

[Back to top](#table-of-contents)

Step-by-step guide to verify every feature after deployment.

### Prerequisites

```bash
# Ensure you have cluster access
gcloud container clusters get-credentials openclaw-cluster \
  --region $REGION --project $PROJECT_ID

# Verify pods are running
kubectl get pods -n openclaw
# Expected: openclaw-brain-alice, openclaw-brain-bob, and litellm in Running state
```

[Back to top](#table-of-contents)

### Test 1: LiteLLM Proxy Health

```bash
# liveness check
kubectl exec -n openclaw deployment/litellm -- node -e "fetch('http://localhost:4000/health/liveness').then(r => r.text()).then(console.log)"

# readiness check
kubectl exec -n openclaw deployment/litellm -- node -e "fetch('http://localhost:4000/health/readiness').then(r => r.json()).then(console.log)"
```

Expected: `{"status":"ok"}`

[Back to top](#table-of-contents)

### Test 2: Sandbox Runtime Verification

```bash
# Verify RuntimeClass exists
# kata:
kubectl get runtimeclass kata-clh
# gvisor:
kubectl get runtimeclass gvisor

# Verify pods use the configured sandbox
kubectl get pods -n openclaw -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.runtimeClassName}{"\n"}{end}'
# kata:   openclaw-brain-alice -> kata-clh
# gvisor: openclaw-brain-alice -> gvisor

# Verify kernel isolation (dmesg should be blocked under both runtimes)
kubectl exec -n openclaw deployment/openclaw-brain-alice -- dmesg 2>&1 | head -5
# Expected: "dmesg: read kernel buffer failed: Operation not permitted"
```

[Back to top](#table-of-contents)

### Test 3: OpenClaw TUI (Interactive)

```bash
# Launch the TUI inside alice's pod
kubectl exec -it -n openclaw deployment/openclaw-brain-alice -- npx openclaw tui
```

In the TUI:

1. **Test basic conversation:**
   ```
   You: Hello, what model are you using?
   ```
   Verify the agent responds and identifies the Gemini model.

2. **Test command execution** (requires execution VM):
   ```
   You: Run "hostname" on the Windows node host
   ```
   Approve the command when the approval box appears:
   ```
   ┌─ exec ──────────────────────────────
   │ hostname
   │ host: windows-alice
   │ id: a1b2c3
   │ ─────────────────────────────────
   │ /approve a1b2c3 allow
   └─────────────────────────────────────
   ```
   Type `/approve a1b2c3 allow` (replace with the actual id shown).

3. **Exit:** Press `Ctrl+C` or type `/exit`

[Back to top](#table-of-contents)

### Test 4: Node Invoke (Non-Interactive)

```bash
# Get alice's connected node ID
ALICE_NODE=$(kubectl exec -n openclaw deployment/openclaw-brain-alice -- \
  npx openclaw nodes status --json 2>/dev/null | jq -r '.nodes[] | select(.connected) | .id')

# Invoke a system command
kubectl exec -n openclaw deployment/openclaw-brain-alice -- \
  npx openclaw nodes invoke --node "$ALICE_NODE" \
  --command system.which --params '{"bins":["cmd","powershell","node"]}'

# Expected: {"ok":true, "payload":{"bins":{"cmd":"C:\\Windows\\system32\\cmd.exe",...}}}
```

[Back to top](#table-of-contents)

### Test 5: Multi-Developer Isolation

```bash
# Write a file in alice's pod
kubectl exec -n openclaw deployment/openclaw-brain-alice -- \
  bash -c 'echo "alice-private" > /tmp/secret.txt'

# Verify bob cannot see it
kubectl exec -n openclaw deployment/openclaw-brain-bob -- \
  cat /tmp/secret.txt 2>&1
# Expected: "No such file or directory"

# Verify alice can still read it
kubectl exec -n openclaw deployment/openclaw-brain-alice -- cat /tmp/secret.txt
# Expected: "alice-private"
```

[Back to top](#table-of-contents)

### Test 6: PVC Persistence

```bash
# Write a marker file to the PVC mount
kubectl exec -n openclaw deployment/openclaw-brain-alice -- \
  bash -c 'echo "persist-test" > /app/workspace/marker.txt'

# Delete the pod (deployment recreates it)
kubectl delete pod -n openclaw -l developer=alice

# Wait for new pod
kubectl wait --for=condition=ready pod -n openclaw -l developer=alice --timeout=120s

# Verify the file survived
kubectl exec -n openclaw deployment/openclaw-brain-alice -- \
  cat /app/workspace/marker.txt
# Expected: "persist-test"
```

[Back to top](#table-of-contents)

### Test 7: Logging Pipeline

```bash
# Check logs are flowing to Cloud Logging
gcloud logging read \
  'resource.type="k8s_container" AND resource.labels.namespace_name="openclaw"' \
  --project=$PROJECT_ID --limit=5 --format='value(textPayload)'

# Verify log sink exists
gcloud logging sinks list --project=$PROJECT_ID

# Verify alert policies
gcloud alpha monitoring policies list --project=$PROJECT_ID \
  --format='table(displayName,enabled)'
```

Expected:
- Recent log entries from OpenClaw pods
- Log sink pointing to a GCS bucket
- Alert policies for CrashLoop, Node Disconnected, Exec Denied, and VM Node Host Failure

[Back to top](#table-of-contents)

### Test 8: Outbound Network Access

```bash
kubectl exec -n openclaw deployment/openclaw-brain-alice -- \
  node -e "fetch('https://www.google.com').then(r => console.log(r.status))"
# Expected: 200 (Cloud NAT provides outbound access)
```

[Back to top](#table-of-contents)

---

## Adding Messaging Channels

[Back to top](#table-of-contents)

OpenClaw supports 20+ channels including Telegram, WhatsApp, Slack, Discord, Signal, Google Chat, Microsoft Teams, and more. Channels are configured via **CLI commands** or the **Control UI** — no SSH or VM access required.

### Telegram

[Back to top](#table-of-contents)

#### 1. Create a Telegram Bot

1. Open Telegram and message [@BotFather](https://t.me/BotFather)
2. Send `/newbot` and follow the prompts
3. Copy the bot token (format: `123456789:ABCdefGHIjklMNOpqrsTUVwxyz`)

#### 2. Add the Channel via CLI

```bash
kubectl exec -n openclaw deploy/openclaw-brain-alice -- \
  npx openclaw channels add --channel telegram --token "YOUR_BOT_TOKEN"
```

#### 3. Restart the Pod

```bash
kubectl delete pod -n openclaw -l developer=alice
```

#### 4. Approve Pairing

Send a message to your bot on Telegram. The bot will reply with a **pairing code** and ask you to approve it. From your terminal, run:

```bash
kubectl exec -n openclaw deploy/openclaw-brain-alice -- \
  npx openclaw pairing approve telegram <PAIRING_CODE>
```

Replace `<PAIRING_CODE>` with the code shown in the Telegram message.

#### 5. Test

Send another message to the bot. You should now receive a response from the OpenClaw agent.

#### 6. Optional: Restrict Access

To require pairing codes for all future Telegram conversations (recommended for production):

```bash
kubectl exec -n openclaw deploy/openclaw-brain-alice -- \
  npx openclaw config set channels.telegram.dmPolicy "pairing"
```

[Back to top](#table-of-contents)

### Managing Channels

```bash
# List configured channels
kubectl exec -n openclaw deploy/openclaw-brain-alice -- npx openclaw channels list

# Check channel status
kubectl exec -n openclaw deploy/openclaw-brain-alice -- npx openclaw channels status

# Remove a channel
kubectl exec -n openclaw deploy/openclaw-brain-alice -- npx openclaw channels remove --channel telegram

# Check channel logs
kubectl exec -n openclaw deploy/openclaw-brain-alice -- npx openclaw channels logs

# Or use the Control UI via port-forward:
kubectl port-forward -n openclaw svc/openclaw-gateway-alice 18789:18789
# Then open http://localhost:18789
```

### Other Supported Channels

OpenClaw supports 20+ channels beyond Telegram. Use `npx openclaw channels add --help` inside a pod to see all available options:

| Channel | Auth Method |
|---------|-------------|
| WhatsApp | QR code scan (`channels login --channel whatsapp`) |
| Slack | App token + Bot token |
| Discord | Bot token |
| Signal | Linked device (QR code) |
| Google Chat | Service account |
| Microsoft Teams | App credentials |
| IRC | Server/nick config |
| Matrix | Homeserver + access token |

For full channel documentation, see the [OpenClaw Channels docs](https://docs.openclaw.ai/channels).

[Back to top](#table-of-contents)

---

## Execution VM (Optional)

[Back to top](#table-of-contents)

By default, only the GKE brain pods are deployed (`exec_vms = {}`). To add execution VMs, define them in the `exec_vms` map:

```hcl
exec_vms = {
  "windows" = { os_image = "windows-cloud/windows-2022-core" }
  "linux"   = { os_image = "debian-cloud/debian-12" }
}
```

### OS Auto-Detection

The OS type is auto-detected from the image name:

| Image | OS | Node Host | Startup Script |
|-------|-----|-----------|----------------|
| Any image containing "windows" | Windows | Scheduled Tasks (SYSTEM) | `scripts/windows_startup.ps1` |
| Any other image | Linux | systemd services | `scripts/linux_startup.sh` |

### What Gets Created

When `exec_vms` is non-empty, Terraform creates:
- A GCE VM per entry (no public IP, Shielded VM)
- A shared subnet and firewall rule for VM-to-GKE connectivity
- A shared service account with logging/monitoring/Secret Manager access
- Per-developer Internal Load Balancer services on GKE
- Per-developer node host processes on each VM

### Data Flow: Agent Command Execution

```mermaid
graph LR
    A["Developer (TUI)"] --> B["OpenClaw Agent\n(Pod)"]
    B --> C["Gateway"]
    C -->|"TLS WebSocket"| D["Node Host\n(Execution VM)"]
    D --> E["OS Commands"]
    E --> D
    D -->|"Result"| C
    C --> B
    B --> A
```

### Node Host Pairing

Each node host must be paired with its developer's gateway pod before it can execute commands. The VM startup script starts per-developer node hosts automatically, but **pairing requires manual approval**.

1. VM startup script installs OpenClaw, fetches the gateway token, and starts per-developer node hosts
2. Each node host connects to its developer's ILB and sends a pairing request
3. The developer approves the request via TUI or CLI (see [Step 7](#step-7-approve-node-host-pairing-only-if-exec_vms-is-non-empty) in the Deployment Guide)
4. The node host reconnects and is fully operational

After initial pairing, the node host identity is persisted on the VM. Subsequent reconnections (e.g., after pod restart) reuse the same identity and do not require re-approval — unless the VM is reprovisioned or identity files are deleted.

### Managing Nodes

```bash
# List all paired nodes and their connection status
kubectl exec -n openclaw deploy/openclaw-brain-alice -- npx openclaw nodes status

# List pending pairing requests
kubectl exec -n openclaw deploy/openclaw-brain-alice -- npx openclaw nodes pending

# Approve a pending node
kubectl exec -n openclaw deploy/openclaw-brain-alice -- npx openclaw nodes approve <REQUEST_ID>

# Reject a pending node
kubectl exec -n openclaw deploy/openclaw-brain-alice -- npx openclaw nodes reject <REQUEST_ID>

# Invoke a command on a connected node
kubectl exec -n openclaw deploy/openclaw-brain-alice -- \
  npx openclaw nodes invoke --node <NODE_ID> --command system.which --params '{"bins":["node"]}'
```

### Adding New VMs

To add more execution VMs, add entries to the `exec_vms` map in `terraform.tfvars` and apply:

```hcl
exec_vms = {
  "windows" = { os_image = "windows-cloud/windows-2022-core" }
  "linux"   = { os_image = "debian-cloud/debian-12" }
  # Add a new VM:
  "linux-2" = {
    os_image          = "debian-cloud/debian-12"
    machine_type      = "e2-standard-4"
    boot_disk_size_gb = 100
  }
}
```

```bash
terraform apply
```

Terraform will create the new VM, install OpenClaw via the startup script, and start per-developer node hosts. You will need to approve pairing for each new node host (see [Step 7](#step-7-approve-node-host-pairing-only-if-exec_vms-is-non-empty)).

### Removing Stale Nodes

If nodes accumulate stale paired entries (e.g., after VM reprovisioning), clean them up:

```bash
# List all paired nodes — note IDs of stale/disconnected entries
kubectl exec -n openclaw deploy/openclaw-brain-alice -- npx openclaw nodes list

# Remove stale entries by deleting the pairing data and restarting the pod
kubectl exec -n openclaw deploy/openclaw-brain-alice -- \
  sh -c "rm -f ~/.openclaw/nodes/paired.json ~/.openclaw/devices/paired.json"
kubectl delete pod -n openclaw -l developer=alice
```

Then re-approve the node hosts when they reconnect.

[Back to top](#table-of-contents)

---

## Windows VM Golden Image

[Back to top](#table-of-contents)

Build a pre-configured Windows Server golden image with OpenClaw, Node.js, and all dependencies pre-installed.

### Step 1: Create a Source VM

```bash
# Set Region & Zone for Windows VM builder
export REGION="us-central1"
export ZONE="us-central1-c"

gcloud compute instances create openclaw-win-builder \
  --project=$PROJECT_ID \
  --zone=$ZONE \
  --machine-type=e2-standard-4 \
  --image-project=windows-cloud \
  --image-family=windows-2022-core \
  --boot-disk-size=50GB \
  --boot-disk-type=pd-balanced \
  --shielded-secure-boot \
  --shielded-vtpm \
  --shielded-integrity-monitoring \
  --no-address \
  --subnet=projects/$PROJECT_ID/regions/$REGION/subnetworks/openclaw-vpc-windows-subnet
```

[Back to top](#table-of-contents)

### Step 2: Connect and Install Software

```bash
# Set a Windows password
gcloud compute reset-windows-password openclaw-win-builder \
  --zone=$ZONE --quiet

# Connect via IAP RDP tunnel
gcloud compute start-iap-tunnel openclaw-win-builder 3389 \
  --zone=$ZONE --local-host-port=localhost:33389
# Then RDP to localhost:33389
```

Once connected, run in PowerShell:

```powershell
# Install Node.js 22 LTS
$nodeVersion = "22.15.0"
$nodeUrl = "https://nodejs.org/dist/v$nodeVersion/node-v$nodeVersion-x64.msi"
Invoke-WebRequest -Uri $nodeUrl -OutFile C:\Windows\Temp\node-installer.msi -UseBasicParsing
Start-Process msiexec.exe -ArgumentList "/i C:\Windows\Temp\node-installer.msi /qn /norestart" -Wait
$env:PATH = "C:\Program Files\nodejs;$env:PATH"
[Environment]::SetEnvironmentVariable("PATH", "C:\Program Files\nodejs;$([Environment]::GetEnvironmentVariable('PATH', 'Machine'))", "Machine")

# Install OpenClaw
npm install -g openclaw@latest --ignore-scripts

# Create directories
New-Item -ItemType Directory -Path "C:\openclaw\state" -Force
New-Item -ItemType Directory -Path "C:\openclaw\nodes" -Force
[Environment]::SetEnvironmentVariable("OPENCLAW_STATE_DIR", "C:\openclaw\state", "Machine")

# Clean up
Remove-Item C:\Windows\Temp\node-installer.msi -Force -ErrorAction SilentlyContinue
```

[Back to top](#table-of-contents)

### Step 3: Sysprep and Create Image

```powershell
# On the VM — generalize the image
& "$env:SystemRoot\System32\Sysprep\Sysprep.exe" /generalize /oobe /shutdown /quiet
```

Wait for the VM to shut down, then:

```bash
gcloud compute images create openclaw-windows-golden-v1 \
  --project=$PROJECT_ID \
  --source-disk=openclaw-win-builder \
  --source-disk-zone=$ZONE \
  --family=openclaw-windows \
  --storage-location=$REGION \
  --labels=app=openclaw,managed-by=terraform \
  --description="OpenClaw Windows golden image with Node.js 22 and OpenClaw pre-installed"
```

[Back to top](#table-of-contents)

### Step 4: Clean Up and Use

```bash
# Delete the builder VM
gcloud compute instances delete openclaw-win-builder \
  --zone=$ZONE --quiet
```

Update `terraform.tfvars` to use the golden image:

```hcl
exec_vms = {
  "windows" = { os_image = "projects/my-gcp-project/global/images/family/openclaw-windows" }
}
```

Then apply:

```bash
terraform apply
```

[Back to top](#table-of-contents)

---

## Observability

[Back to top](#table-of-contents)

All OpenClaw logs from pods and VMs are collected, stored, and monitored through a unified observability stack managed entirely by Terraform.

```mermaid
graph LR
    subgraph Sources
        POD["Gateway Pods\nstdout/stderr"]
        LINUX_VM["Linux VM\njournald"]
        WIN_VM["Windows VM\nEvent Log + File Logs"]
    end

    subgraph Collection
        GKE_LOG["GKE Auto-shipping"]
        OPS_LINUX["Ops Agent\n(systemd_journal)"]
        OPS_WIN["Ops Agent\n(windows_event_log + files)"]
    end

    subgraph Storage
        CL["Cloud Logging\n(30-day retention)"]
        GCS["GCS Bucket\n(90d Standard → Nearline\n365d → Coldline)"]
    end

    subgraph Monitoring
        METRICS["Log-Based Metrics"]
        ALERTS["Alert Policies\n(Email)"]
        DASH["Operations Dashboard"]
    end

    POD --> GKE_LOG --> CL
    LINUX_VM --> OPS_LINUX --> CL
    WIN_VM --> OPS_WIN --> CL
    CL -->|"Log Sink"| GCS
    CL --> METRICS --> ALERTS
    METRICS --> DASH
```

### Log Collection

| Source | Mechanism | What's Collected |
|--------|-----------|-----------------|
| **Gateway pods** | GKE auto-ships stdout/stderr | Gateway startup, WebSocket activity, pairing, exec results, errors |
| **Linux VM** | Ops Agent (`systemd_journal` receiver) | Node host connect/disconnect, exec output, restart events |
| **Windows VM** | Ops Agent (`windows_event_log` + `files` receiver) | Node host output, scheduled task events, errors |

### Log Storage

| Tier | Retention | Use Case |
|------|-----------|----------|
| **Cloud Logging** | 30 days | Real-time querying, tailing, dashboard panels |
| **GCS Bucket** | Unlimited | Long-term retention, compliance, post-incident analysis |

GCS lifecycle policies: 0–90 days Standard, 90–365 days Nearline, 365+ days Coldline.

### Alerting

| Alert | Trigger | Meaning |
|-------|---------|---------|
| **Exec Approval Denied** | `SYSTEM_RUN_DENIED` in pod logs | Node host denied a command |
| **Node Host Disconnected** | `NOT_CONNECTED` >50 in 5 min | Stale paired nodes or VM down |
| **Gateway CrashLoop** | `CrashLoopBackOff` in pod logs | Bad config, missing secrets |
| **VM Node Host Failure** | `Node host exited` or `ERROR` >5 in 5 min | Node host process crashing |

To enable alerts:

```hcl
# In terraform.tfvars
alert_email = "your-team@example.com"
```

### Dashboard

Access at: **Cloud Console → Monitoring → Dashboards → OpenClaw Operations**

| Panel | Shows |
|-------|-------|
| Gateway Pod Logs | All gateway pod logs (all developers) |
| Execution VM Logs | All VM logs (Linux + Windows) |
| Exec Denied Events | `SYSTEM_RUN_DENIED` events over time |
| Node Disconnection Errors | `NOT_CONNECTED` errors over time |
| VM Node Host Failures | VM node host errors over time |
| Gateway Errors Only | Severity >= ERROR from gateway pods |
| WebSocket Activity | All `[ws]` request/response logs |

[Back to top](#table-of-contents)

---

## Variables Reference

[Back to top](#table-of-contents)

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `project_id` | Yes | — | GCP project ID |
| `region` | No | `us-central1` | GCP region |
| `zone` | No | `us-central1-c` | GCE instance zone |
| `network_name` | No | `openclaw-vpc` | VPC network name |
| `gke_subnet_cidr` | No | `10.10.0.0/24` | GKE subnet CIDR |
| `gke_pods_cidr` | No | `10.100.0.0/16` | Secondary CIDR for pods |
| `gke_services_cidr` | No | `10.101.0.0/16` | Secondary CIDR for services |
| `gke_cluster_name` | No | `openclaw-cluster` | GKE cluster name |
| `gke_machine_type` | No | `n2-standard-4` | GKE node machine type. N2 required for Kata; any type for gVisor |
| `gke_node_count` | No | `1` | Nodes per zone |
| `sandbox_runtime` | No | `kata` | Sandbox runtime: `"kata"` (kata-pool, kata-clh) or `"gvisor"` (gvisor-pool, GKE Sandbox) |
| **Execution VMs** | | | |
| `exec_vms` | No | `{}` | Map of execution VMs to deploy |
| `exec_vm_subnet_cidr` | No | `10.20.0.0/24` | VM subnet CIDR |
| `master_authorized_cidrs` | No | `{}` | Additional CIDRs for GKE control plane access |
| **Secrets** | | | |
| `gateway_auth_token` | No | auto-generated | Gateway auth token (sensitive) |
| `brave_api_key` | No | `""` | Brave Search API key (sensitive) |
| **OpenClaw** | | | |
| `sandbox_image` | No | `""` | Custom Docker image for brain pods |
| `openclaw_version` | No | `latest` | OpenClaw npm package version |
| `model_primary` | No | `litellm/gemini-3.1-pro-preview` | Primary LLM model |
| `model_fallbacks` | No | `["litellm/gemini-3.1-flash-lite-preview"]` | Fallback models (JSON array) |
| `developers` | No | `{"default" = {active = true}}` | Map of developer names to config |
| `deployer_service_account` | No | `""` | SA email for IAP tunnel access |
| **Monitoring** | | | |
| `alert_email` | No | `""` | Email for operational alerts |
| **Labels** | | | |
| `labels` | No | `{app="openclaw",...}` | Resource labels |

[Back to top](#table-of-contents)

---

## Outputs Reference

[Back to top](#table-of-contents)

| Output | Description |
|--------|-------------|
| `gke_cluster_name` | GKE cluster name |
| `gke_cluster_endpoint` | GKE API server endpoint |
| `exec_vms` | Map of execution VM names to instance name, IP, and OS image |
| `artifact_registry_url` | Docker registry URL |
| `gateway_token_secret` | Secret Manager resource for gateway token |
| `cloudbuild_service_account` | Cloud Build service account email |
| `secrets_configured` | List of Secret Manager secrets created (sensitive) |

[Back to top](#table-of-contents)

---

## File Structure

[Back to top](#table-of-contents)

```
openclaw-gke/
├── main.tf                    # Providers, backend, API enablement
├── gke.tf                     # GKE cluster + kata-pool / gvisor-pool (conditional)
├── network.tf                 # VPC, subnet, Cloud NAT, firewalls
├── iam.tf                     # Service accounts, Workload Identity, IAM
├── storage.tf                 # Artifact Registry, Cloud Build, Secret Manager
├── kubernetes.tf              # Namespace, deployments, PVCs, services
├── logging.tf                 # Monitoring dashboard, alerts, log sink
├── kata.tf                    # Kata Containers Helm release (kata only)
├── exec_vm.tf                 # Execution VM resources (optional)
├── variables.tf               # Input variables (incl. sandbox_runtime)
├── outputs.tf                 # Output values
├── terraform.tfvars           # Variable values (do not commit)
├── terraform.tfvars.example   # Example variable values
├── Dockerfile                 # OpenClaw container image
├── openclaw.json.template     # OpenClaw config (rendered at startup)
└── scripts/
    ├── entrypoint.sh          # Container entrypoint (auto-approve + gateway)
    ├── build_and_push.sh      # Cloud Build image build script
    ├── linux_startup.sh       # Linux VM startup (node hosts via systemd)
    └── windows_startup.ps1    # Windows VM startup (node hosts via Scheduled Tasks)
```

[Back to top](#table-of-contents)

---

## Troubleshooting

[Back to top](#table-of-contents)

### Slow Agent Response / Event Loop Delays

**Symptoms:**
- OpenClaw TUI is extremely slow (30+ second delays)
- Agent requests timeout
- Gateway logs show event loop delay warnings (50+ seconds)

**Cause:**
The auto-pair background loop runs continuously when `exec_vms` is non-empty, polling for pending device pairings every 60 seconds. Each poll creates a WebSocket connection that can block the Node.js event loop, especially in sandbox environments (Kata/gVisor).

**Solution:**
This has been **fixed automatically** in recent versions. The auto-pair loop now only runs when execution VMs are actually deployed:
- If `exec_vms = {}` (empty): Loop is **disabled** → no event loop blocking
- If `exec_vms` has entries: Loop **enabled** → automatic node host pairing

**Verification:**
```bash
# Check if auto-pair loop is running
kubectl logs -n openclaw deployment/openclaw-brain-alice | grep "auto-pair"

# Expected when exec_vms is empty:
# "[entrypoint] Skipping auto-pair background loop (no exec VMs deployed)"

# Expected when exec_vms is non-empty:
# "[entrypoint] Starting auto-pair background loop (exec VMs enabled)"
```

**Performance improvement:**
- Before fix: 97+ second event loop delays, 99.9% utilization, CLI timeouts
- After fix: <50ms event loop delays, <40% utilization, responsive TUI

If you still experience slowness after this fix, check gateway logs for other sources of event loop blocking.

[Back to top](#table-of-contents)

---

## Cleanup

[Back to top](#table-of-contents)

> **Note:** Cluster deletion protection is enabled. To destroy, first disable it:

```bash
# Disable deletion protection
terraform apply -var="deletion_protection=false" -target=google_container_cluster.primary

# Then destroy
terraform destroy
```

[Back to top](#table-of-contents)
