# Phase 8: Production Hardening and CKA/CKS Prep

## Overview

This phase covers the security and operational practices that separate a production-ready cluster from a development experiment. Every tool and technique here is either directly tested on the CKA/CKS exams or required for enterprise compliance (SOC2, PCI-DSS, HIPAA).

The theme: **prevention, detection, and response.**
- Prevention: PSA, Kyverno, image scanning (stop bad things before they start)
- Detection: Falco, kube-bench, Trivy Operator (find problems that exist)
- Response: etcd backup/restore, rollback scripts (recover when things go wrong)

---

## 8.1: etcd Backup and Restore

### What is etcd?

etcd is the distributed key-value store that holds ALL Kubernetes cluster state. Every Deployment, Service, Secret, ConfigMap, NetworkPolicy — everything you've ever `kubectl apply`'d lives in etcd.

If etcd dies without a backup, your entire cluster state is gone.

### Why it matters

- **CKA exam**: directly tested — take a snapshot, restore from it
- **Production**: scheduled backups every 6 hours, stored offsite (S3/GCS)
- **Disaster recovery**: the ONLY way to recover from cluster corruption

### Key concepts

| Concept | What it means |
|---------|--------------|
| Static pod | etcd runs directly on the control-plane node, managed by kubelet (not the API server) |
| TLS mutual auth | You need CA cert + server cert + server key to talk to etcd |
| Data directory | `/var/lib/etcd` — where etcd stores its data on disk |
| Snapshot | Point-in-time copy of the entire database |
| Restore | Replaces the data directory with a snapshot, then restarts etcd |

### Commands (CKA exam — memorize these)

```bash
# Take a backup
etcdctl snapshot save /path/backup.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# Restore (etcd v3.6+ uses etcdutl)
etcdutl snapshot restore /path/backup.db --data-dir=/var/lib/etcd

# For older versions (etcd v3.5 and below):
etcdctl snapshot restore /path/backup.db --data-dir=/var/lib/etcd-restored
```

### How to stop/start etcd

etcd is a static pod — its manifest lives at `/etc/kubernetes/manifests/etcd.yaml`. The kubelet watches this directory:
- **Move the file OUT** → kubelet stops etcd
- **Move the file BACK** → kubelet starts etcd

```bash
# Stop etcd
mv /etc/kubernetes/manifests/etcd.yaml /tmp/etcd.yaml.bak

# Start etcd
mv /tmp/etcd.yaml.bak /etc/kubernetes/manifests/etcd.yaml
```

### What we demonstrated

1. Found etcd pod and its certificate paths
2. Took a 26 MB snapshot (entire cluster state)
3. Copied it to local machine (`backups/` directory)
4. Deleted the `service-config` ConfigMap (simulated disaster)
5. Stopped etcd → restored from snapshot → started etcd
6. Verified: deleted ConfigMap was back ✅

### Scripts created

- `scripts/etcd-backup.sh` — automated backup with health check, retention policy
- `scripts/etcd-restore.sh` — guided restore with confirmation prompt

### Production scheduling

```bash
# Cron job (run every 6 hours)
0 */6 * * * /path/to/etcd-backup.sh --retention 28 >> /var/log/etcd-backup.log 2>&1

# Upload to S3 (add to backup script)
aws s3 cp $BACKUP_FILE s3://my-etcd-backups/$(date +%Y/%m/%d)/
```

### Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| `connection refused` on etcdctl | etcd isn't running or wrong endpoint | Check `--listen-client-urls` in etcd pod spec |
| `authentication handshake failed` | Wrong certificates | Verify cert paths from `kubectl describe pod etcd-*` |
| `etcdctl: not found` in Kind node | Binary only exists inside the etcd container | Use `kubectl exec` into the etcd pod, or find binary in containerd snapshots |
| Restore says "no such file" | File path inside container doesn't match host | Copy snapshot to `/root/` not `/tmp/` (tmpfs gets cleared) |
| API server unresponsive after restore | etcd hasn't fully started yet | Wait 30-60 seconds, kubelet restarts the static pod |

---

## 8.2: Cluster Upgrade Process

### What it is

Upgrading Kubernetes from one minor version to the next (e.g., 1.36 → 1.37). Must be done periodically for security patches and feature access.

### Rules (memorize for CKA)

1. **One minor version at a time** (1.36→1.37, NOT 1.36→1.38)
2. **Control plane first**, then workers
3. **Workers one at a time** (never all at once)
4. **API server can be at most 1 minor version ahead of kubelets**
5. **Always take an etcd backup before starting**

### The workflow

```
Pre-flight checks → etcd backup → upgrade control plane → 
upgrade worker 1 (cordon→drain→upgrade→uncordon) →
upgrade worker 2 → ... → post-upgrade verification
```

### Key commands

```bash
# Cordon (mark node unschedulable)
kubectl cordon <node-name>

# Drain (evict pods — PDBs protect availability)
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# Upgrade kubeadm on the node
sudo apt-get install -y kubeadm=1.37.0-1.1

# Upgrade control plane
sudo kubeadm upgrade apply v1.37.0

# Upgrade worker node config
sudo kubeadm upgrade node

# Upgrade kubelet
sudo apt-get install -y kubelet=1.37.0-1.1 kubectl=1.37.0-1.1
sudo systemctl daemon-reload && sudo systemctl restart kubelet

# Uncordon (allow scheduling again)
kubectl uncordon <node-name>
```

### What we demonstrated

- Cordoned worker3 → status changed to `SchedulingDisabled`
- Drained worker3 → all 5 pods evicted and rescheduled to worker/worker2
- PDBs ensured no service lost all replicas (zero downtime)
- Uncordoned worker3 → back to `Ready`

### Why Kind can't be upgraded in-place

Kind nodes use a fixed container image per Kubernetes version. You can't run `kubeadm upgrade` inside them. The cordon/drain/uncordon workflow works (we proved it), but the actual version change requires a new Kind cluster.

### Scripts created

- `scripts/cluster-upgrade.sh` — full runbook with `--dry-run` mode showing every command

---

## 8.3: Image Vulnerability Scanning with Trivy

### What it is

Scanning container images for known security vulnerabilities (CVEs) in:
- OS packages (alpine, debian packages)
- Language dependencies (npm, pip, go modules)
- Application libraries

### Three layers of scanning

| Layer | Where | When | Purpose |
|-------|-------|------|---------|
| CI pipeline | GitHub Actions | On every push/PR | Gate — block bad images before deploy |
| Registry | Trivy Operator in cluster | Continuous (daily) | Catch new CVEs on already-deployed images |
| Developer | Local Trivy CLI | Before pushing | Fast feedback loop |

### Installation

```bash
# Local CLI (developer workflow)
curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin

# In-cluster (Trivy Operator — Helm)
helm install trivy-operator aqua/trivy-operator \
  --namespace trivy-system --create-namespace \
  -f security/trivy-operator-values.yaml
```

### Scan results for our services

| Service | CRITICAL | HIGH | Root cause |
|---------|:---:|:---:|---|
| shipping-service | 1 | 33 | Go 1.22 (outdated stdlib + x/crypto) |
| cart-service | 3 | 30 | Node.js 18 + npm packages |
| product-catalog-service | 3 | 30 | Node.js 18 + npm packages |
| user-authentication-service | 3 | 30 | Node.js 18 + npm packages |
| checkout-service | 4 | 24 | Python 3.11 + pip packages |
| payment-service | 4 | 24 | Python 3.11 + pip packages |
| frontend-service | 0 | 8 | nginx:alpine (minimal) |

### How to fix

```dockerfile
# shipping-service: Go 1.22 → 1.26
FROM golang:1.26-alpine AS builder

# Node services: node:18 → node:22
FROM node:22-alpine

# Python services: python:3.11 → python:3.13
FROM python:3.13-slim
```

### Severity prioritization (how real companies handle it)

| Severity | SLA | Action |
|----------|-----|--------|
| CRITICAL | Fix within 24 hours | Block deploy in CI, page on-call |
| HIGH | Fix within 1-2 weeks | Sprint backlog item |
| MEDIUM | Fix within the quarter | Track in vulnerability dashboard |
| LOW | Track | Don't rush — address when updating base images |

### Scripts created

- `scripts/scan-images.sh` — one-command scan of all 7 services with severity table
- `security/trivy-operator-values.yaml` — Helm values for in-cluster scanning
- `security/install-trivy-operator.sh` — installation script

### Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| `Need to update DB` on first run | Trivy downloads vulnerability database (~40MB) | Wait for download, or pre-cache with `trivy image --download-db-only` |
| Scan shows 0 vulnerabilities | Image has no OS packages (scratch-based) | Expected for distroless/scratch images |
| `GHCR 403` when scanning remote images | Not authenticated to registry | `echo $GITHUB_TOKEN \| docker login ghcr.io -u USERNAME --password-stdin` |

---

## 8.4: Runtime Security with Falco

### What it is

Falco monitors system calls (syscalls) made by every process in every container and fires alerts when it detects suspicious behavior — shell access, file reads, network connections, privilege escalation.

### Prevention vs Detection

| Tool | Type | Analogy |
|------|------|---------|
| Trivy | Prevention | Airport security — check baggage before boarding |
| PSA/Kyverno | Prevention | Door lock — block entry if you don't have the key |
| Falco | Detection | Security camera — watch what happens after entry |

### How Falco works

1. eBPF probe hooks into Linux kernel (every syscall is visible)
2. Falco engine evaluates syscalls against rules
3. If a rule matches → alert fired (stdout, Slack, Prometheus, webhook)
4. Runs as DaemonSet (one pod per node — sees everything on that node)

### Custom rules we created

| Rule | Detects | MITRE ATT&CK |
|------|---------|--------------|
| Shell in Shopping Container | `bash`/`sh` spawned in any shopping pod | Execution |
| Sensitive File Read | `/etc/shadow`, `/proc/environ` read | Credential Access |
| Unexpected Outbound Connection | Connections to non-RFC1918 IPs | Exfiltration |
| Package Manager Usage | `apt`, `npm`, `pip` run in a live container | Persistence |
| K8s API Access | Pod connecting to port 6443 | Lateral Movement |
| Crypto Mining | Known miner process names (xmrig, etc.) | Impact |

### What we demonstrated

1. Installed Falco (4 DaemonSet pods, modern_ebpf driver)
2. Custom rules loaded successfully (`schema validation: ok`)
3. Triggered test: `kubectl exec cart-service -- sh -c "echo hacked"`
4. Falco detected TWO alerts:
   - "Sensitive File Read" (`/etc/passwd` accessed during exec init)
   - "Shell spawned in shopping container" (`sh -c echo hacked`)
5. Full JSON output with container name, pod name, image, user, timestamp

### Who writes Falco rules

| Source | Example |
|--------|---------|
| Built-in (100+ rules) | Shell in container, sensitive file access |
| Security team | "Detect attempts to read payment data" |
| Post-incident | "Last week someone ran kubectl from a pod — write a rule" |
| Compliance | "PCI-DSS requires detecting unauthorized access" |
| DevOps who knows the app | "Cart-service should NEVER make outbound HTTP" |

### Installation

```bash
helm install falco falcosecurity/falco \
  --namespace falco --create-namespace \
  -f security/falco/values.yaml
```

### Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| `CrashLoopBackOff` | Custom rule syntax error | Check logs: `kubectl logs -n falco <pod> -c falco` |
| `LOAD_ERR_COMPILE_CONDITION` | Wrong field syntax (e.g., `startswith` not supported for IPs) | Use `fd.snet in (10.0.0.0/8)` for IP ranges |
| High CPU usage (198%) | modern_ebpf intercepting every syscall on loaded cluster | Reduce monitored syscalls or add resource limits |
| Cluster becomes unresponsive | Falco + Istio + monitoring = too much for Docker Desktop | Uninstall Falco when not actively testing |

### Important lesson learned

Falco's eBPF probes add significant CPU overhead (~30-50% per node). On a resource-constrained Kind cluster running Istio + Prometheus + ArgoCD, this overwhelmed the cluster. In production, you'd have dedicated monitoring nodes or more powerful hardware.

### Files created

- `security/falco/values.yaml` — Helm values with custom rules
- `security/falco/install.sh` — installation script

---

## 8.5: Pod Security Admission (PSA)

### What it is

Namespace-level enforcement of pod security standards. Instead of trusting developers to add `securityContext` to every pod, PSA rejects pods that don't meet the standard.

### Three profiles

| Profile | What it allows | Use case |
|---------|---------------|----------|
| **Privileged** | Anything | System components (Istio, Calico, monitoring) |
| **Baseline** | Blocks hostNetwork, hostPID, privileged containers | General workloads |
| **Restricted** | Requires runAsNonRoot, drop ALL, no privilege escalation, seccomp | Production apps |

### Three modes

| Mode | Behavior |
|------|----------|
| **enforce** | REJECT the pod |
| **warn** | Allow but show warning to user |
| **audit** | Allow but log violation |

### What we configured

```yaml
# On the shopping namespace:
pod-security.kubernetes.io/enforce: privileged    # Istio needs NET_ADMIN
pod-security.kubernetes.io/warn: restricted       # Developers see what's wrong
pod-security.kubernetes.io/audit: restricted      # Everything logged
```

### Why `enforce: privileged` (not restricted)?

Istio's init container needs `NET_ADMIN` and `NET_RAW` capabilities to set up iptables rules for traffic interception. This violates even `baseline`. The options were:
1. Don't use PSA enforce (bad)
2. Set enforce to privileged + warn restricted (what we did — pragmatic)
3. Configure API server exemptions for Istio containers (requires API server flag changes — not possible in Kind)

Companies using Istio all face this tradeoff. The mitigation: Istio itself provides strong security (mTLS, AuthorizationPolicies) at the network level.

### What we proved

- Created a privileged pod → PSA warning shown (restricted violations listed)
- Tried to create a pod with `privileged: true` with enforce=baseline → REJECTED
- Developers see exactly what they need to fix in the warning message

---

## 8.6: CIS Benchmark with kube-bench

### What it is

The CIS Kubernetes Benchmark is a checklist of ~200 security configuration checks. kube-bench automates running these checks against your cluster.

### How to run

```bash
# As a Kubernetes Job (runs on control-plane node)
kubectl apply -f security/kube-bench-job.yaml
kubectl wait --for=condition=complete job/kube-bench
kubectl logs job/kube-bench
```

### Our results

- **34 PASS** — file permissions, PKI ownership, kubelet config
- **34 FAIL** — audit logging not configured, etcd permissions, profiling enabled
- **51 WARN** — manual verification needed

### Key failures explained

| Check | What it means | Fix (on real clusters) |
|-------|--------------|----------------------|
| `--audit-log-path` not set | API requests aren't logged | Add audit policy to API server config |
| etcd directory permissions | Data readable by non-etcd users | `chmod 700 /var/lib/etcd` |
| `--profiling` enabled | Performance debugging endpoints exposed | Add `--profiling=false` to API server |
| admission plugins missing | AlwaysAdmit, NodeRestriction not configured | Kind limitation — kubeadm clusters pass these |

### Context: Kind vs Production

Many failures are because Kind is a development tool — it uses simplified configs. On EKS/GKE/kubeadm production clusters, 80-90% pass by default.

### Files created

- `security/kube-bench-job.yaml` — Job manifest for running the benchmark

---

## 8.7: Admission Control with Kyverno

### What it is

A policy engine that intercepts every `kubectl apply` and validates/mutates resources based on rules you define in YAML. Think of it as a programmable bouncer at the API server door.

### Why Kyverno over OPA Gatekeeper

| | Kyverno | OPA Gatekeeper |
|---|---|---|
| Policy language | YAML | Rego (custom language) |
| Learning curve | Low (same YAML you already know) | High (must learn Rego) |
| CNCF status | Graduated | Graduated |
| Best for | Most teams | Large enterprises with complex logic |

### Policies we created and tested

| Policy | Action | What it blocks |
|--------|--------|---------------|
| `disallow-latest-tag` | Enforce | Any pod using `:latest` or no tag |
| `require-resource-limits` | Enforce | Pods without CPU/memory limits |
| `require-labels` | Enforce | Deployments without `app` label |
| `restrict-image-registries` | Audit | Images from unapproved registries |
| `disallow-privilege-escalation` | Audit | Containers without `allowPrivilegeEscalation: false` |

### What we proved

```bash
# Test 1: latest tag → REJECTED
$ kubectl run bad --image=nginx:latest -n shopping
Error: "Using image tag ':latest' is not allowed. Use a specific version tag"

# Test 2: missing labels → REJECTED
$ kubectl apply -f bad-deployment.yaml
Error: "Deployments must have 'app' label in metadata.labels"

# Test 3: no resource limits → PASSED (LimitRange injected defaults!)
# This shows defense-in-depth: LimitRange provides fallback, Kyverno validates
```

### Installation

```bash
helm install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  --set admissionController.replicas=1 \
  --set backgroundController.replicas=1 \
  --set cleanupController.replicas=1 \
  --set reportsController.replicas=1
```

### Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| `webhook denied the request` | Policy is in Enforce mode and resource violates | Fix the resource to comply, or set policy to Audit |
| `failed calling webhook` after Kyverno pod restart | Webhook registered but pod not ready yet | Wait 30s for Kyverno to become ready |
| Can't delete pods (`connection refused` to webhook) | Kyverno pod crashed — webhook still registered | Scale Kyverno back up, or delete the webhook: `kubectl delete validatingwebhookconfigurations kyverno-*` |
| CRD conflicts during install | Leftover CRDs from failed install | `kubectl get crds \| grep kyverno \| awk '{print $1}' \| xargs kubectl delete crd` |

### Files created

- `security/kyverno/install.sh` — installation script
- `security/kyverno/policies/disallow-latest-tag.yaml`
- `security/kyverno/policies/require-resource-limits.yaml`
- `security/kyverno/policies/require-labels.yaml`
- `security/kyverno/policies/restrict-image-registries.yaml`
- `security/kyverno/policies/disallow-privilege-escalation.yaml`

---

## Security Architecture Summary

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Defense-in-Depth Security Layers                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  LAYER 1: Supply Chain (before images are deployed)                         │
│  ├── Trivy in CI → blocks CRITICAL CVEs                                    │
│  ├── Image tagging → SHA-pinned, never latest                              │
│  └── Registry restriction → only approved sources (Kyverno)                │
│                                                                             │
│  LAYER 2: Admission Control (when resources are created)                    │
│  ├── Kyverno → enforces labels, limits, tags, registries                   │
│  ├── PSA → warns on restricted profile violations                          │
│  └── LimitRange → injects defaults as safety net                           │
│                                                                             │
│  LAYER 3: Runtime Security (while containers are running)                   │
│  ├── Falco → detects shells, file access, network anomalies                │
│  ├── NetworkPolicies → zero-trust (block lateral movement)                 │
│  ├── Istio mTLS → encrypt all service-to-service traffic                   │
│  └── Istio AuthorizationPolicies → mesh-level access control               │
│                                                                             │
│  LAYER 4: Observability (see what's happening)                              │
│  ├── Prometheus → metrics (CPU, memory, request rate)                       │
│  ├── Grafana → dashboards and alerting                                     │
│  ├── Loki → centralized logs                                               │
│  └── ArgoCD → drift detection and self-heal                                │
│                                                                             │
│  LAYER 5: Recovery (when things go wrong)                                   │
│  ├── etcd backup → point-in-time cluster state restore                     │
│  ├── ArgoCD rollback → revert to previous deployment                       │
│  └── Git revert → rollback via source of truth                             │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## CKA/CKS Exam Relevance

| Topic | Exam | Domain | Weight |
|-------|------|--------|--------|
| etcd backup/restore | CKA | Cluster Architecture | 25% |
| Cluster upgrade (kubeadm) | CKA | Cluster Architecture | 25% |
| cordon/drain/uncordon | CKA | Workloads & Scheduling | 15% |
| Image scanning (Trivy) | CKS | Supply Chain Security | 20% |
| Runtime security (Falco) | CKS | Monitoring & Runtime Security | 20% |
| Pod Security (PSA) | CKS | Minimize Microservice Vulnerabilities | 20% |
| CIS Benchmark (kube-bench) | CKS | Cluster Hardening | 15% |
| Admission control (Kyverno/OPA) | CKS | Minimize Microservice Vulnerabilities | 20% |
| NetworkPolicies | CKS | Cluster Hardening | 15% |
| RBAC | CKA + CKS | Multiple domains | 15-25% |

---

## Directory Structure (Phase 8 additions)

```
scripts/
├── etcd-backup.sh            # Automated etcd backup with retention
├── etcd-restore.sh           # Guided etcd restore from snapshot
├── cluster-upgrade.sh        # Cluster upgrade runbook (dry-run mode)
└── scan-images.sh            # Scan all service images with Trivy

security/
├── trivy-operator-values.yaml    # Helm values for in-cluster scanning
├── install-trivy-operator.sh     # Trivy Operator installation
├── kube-bench-job.yaml           # CIS benchmark scanner Job
├── falco/
│   ├── values.yaml               # Falco Helm values + custom rules
│   └── install.sh                # Falco installation script
└── kyverno/
    ├── install.sh                # Kyverno installation script
    └── policies/
        ├── disallow-latest-tag.yaml
        ├── require-resource-limits.yaml
        ├── require-labels.yaml
        ├── restrict-image-registries.yaml
        └── disallow-privilege-escalation.yaml

backups/                          # etcd snapshots (gitignored)
└── etcd-snapshot-*.db
```
