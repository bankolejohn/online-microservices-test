# Phase 4: Resource Management, Pod Security & Autoscaling

## Overview

This phase protects the cluster from resource abuse, hardens pods against privilege escalation, and adds automatic scaling. We go from "everything runs" to "everything runs safely within defined boundaries."

**What we did**:
- Created a ResourceQuota to cap total namespace consumption
- Added LimitRanges to enforce per-container boundaries with sensible defaults
- Applied securityContext to all pods (runAsNonRoot, drop capabilities)
- Created Pod Disruption Budgets to protect availability during maintenance
- Configured Horizontal Pod Autoscalers for traffic-sensitive services

**Why this matters**:
- A single misbehaving pod can't starve the cluster of resources
- Containers run with minimal privileges (defense in depth)
- Cluster upgrades and node maintenance won't cause outages
- Services automatically scale to handle traffic spikes

---

## 1. Resource Quotas

### What

A ResourceQuota puts a **hard ceiling** on the total resources a namespace can consume. Once the quota is hit, new pod creation is rejected until existing resources free up.

### Why

Without quotas, a single team or application could consume the entire cluster:
- A runaway deployment with `replicas: 100` would eat all available CPU
- A memory leak could starve other namespaces
- Object explosion (thousands of ConfigMaps) could overload the API server

Think of it like a departmental budget — the shopping team gets X amount of compute, and they can't exceed it regardless of how many pods they deploy.

### How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│ Cluster (16 CPU, 32Gi total)                                    │
│                                                                 │
│  ┌──────────────────────────┐  ┌────────────────────────────┐  │
│  │ shopping namespace        │  │ monitoring namespace         │  │
│  │ Quota: 4 CPU, 4Gi req    │  │ Quota: 2 CPU, 8Gi req       │  │
│  │        6 CPU, 6Gi lim    │  │        4 CPU, 16Gi lim      │  │
│  │        30 pods max        │  │        10 pods max           │  │
│  └──────────────────────────┘  └────────────────────────────┘  │
│                                                                 │
│  Remaining: 10 CPU, 20Gi (for other namespaces)                │
└─────────────────────────────────────────────────────────────────┘
```

### Our Configuration

```yaml
# k8s/resource-quota.yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: shopping-quota
  namespace: shopping
  labels:
    app.kubernetes.io/part-of: online-shopping
spec:
  hard:
    # CPU limits across all pods in this namespace
    requests.cpu: "4"           # Total CPU requests can't exceed 4 cores
    limits.cpu: "6"             # Total CPU limits can't exceed 6 cores

    # Memory limits across all pods in this namespace
    requests.memory: "4Gi"      # Total memory requests can't exceed 4GB
    limits.memory: "6Gi"        # Total memory limits can't exceed 6GB

    # Object count limits (prevent resource explosion)
    pods: "30"                  # Max 30 pods in this namespace
    services: "15"              # Max 15 services
    configmaps: "20"            # Max 20 ConfigMaps
    secrets: "20"               # Max 20 Secrets
    persistentvolumeclaims: "10" # Max 10 PVCs (for when we add databases)
```

### Why These Numbers?

| Resource | Value | Reasoning |
|----------|-------|-----------|
| requests.cpu: 4 | Our 7 services × 2 replicas × 100m = 1.4 CPU + headroom for scaling |
| requests.memory: 4Gi | 14 pods × 128Mi = 1.75Gi + headroom for spikes |
| pods: 30 | 14 base pods + room for HPA scaling (up to ~21) + margin |
| services: 15 | 7 current services + room for future additions |

### Important Behavior

Once a ResourceQuota exists in a namespace, **every pod must specify resource requests and limits**. If a pod doesn't, creation is rejected with:

```
Error from server (Forbidden): failed quota: shopping-quota:
must specify limits.cpu, limits.memory, requests.cpu, requests.memory
```

This is why we pair ResourceQuota with LimitRange — the LimitRange provides defaults for pods that don't specify their own.

### Verify

```bash
# Check quota status (shows used vs hard limits)
kubectl describe resourcequota shopping-quota -n shopping

# Expected output:
# Name:                   shopping-quota
# Namespace:              shopping
# Resource                Used    Hard
# --------                ----    ----
# configmaps              2       20
# limits.cpu              2800m   6
# limits.memory           2816Mi  6Gi
# persistentvolumeclaims  0       10
# pods                    14      30
# requests.cpu            1400m   4
# requests.memory         1792Mi  4Gi
# secrets                 2       20
# services                7       15

# Quick check — are we close to any limit?
kubectl get resourcequota shopping-quota -n shopping -o jsonpath='{.status}' | python3 -m json.tool
```

---

## 2. LimitRanges

### What

A LimitRange sets **per-container** constraints: default values, minimum floors, and maximum ceilings. It operates at the individual container level, while ResourceQuota operates at the namespace level.

### Why

ResourceQuota alone isn't enough:
- A dev could deploy one pod requesting 4 CPU and hit the entire namespace quota
- Pods without resource specs would be rejected (quota requires them)
- Without a floor, someone could request 1m CPU and get scheduled on a node that can't actually serve them

LimitRange solves all three problems.

### How They Work Together

```
┌─────────────────────────────────────────────────────────┐
│ ResourceQuota (Namespace total)                          │
│ "The namespace can use up to 4 CPU total"               │
│                                                         │
│  ┌───────────────────────────────────────────────────┐  │
│  │ LimitRange (Per container)                         │  │
│  │ "Each container gets 50m-1000m CPU"               │  │
│  │ "Default: 200m if not specified"                   │  │
│  │                                                   │  │
│  │  ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐       │  │
│  │  │200m │ │200m │ │100m │ │200m │ │100m │ ...    │  │
│  │  │     │ │     │ │     │ │     │ │     │        │  │
│  │  └─────┘ └─────┘ └─────┘ └─────┘ └─────┘       │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

### Our Configuration

```yaml
# k8s/limit-range.yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: shopping-limits
  namespace: shopping
  labels:
    app.kubernetes.io/part-of: online-shopping
spec:
  limits:
  - type: Container
    # Default values (applied if a container doesn't specify resources)
    default:
      cpu: "200m"
      memory: "256Mi"
    defaultRequest:
      cpu: "100m"
      memory: "128Mi"
    # Maximum any single container can request
    max:
      cpu: "1"
      memory: "512Mi"
    # Minimum any single container must request
    min:
      cpu: "50m"
      memory: "64Mi"
```

### What Each Field Does

| Field | Value | Meaning |
|-------|-------|---------|
| `default.cpu` | 200m | If a container doesn't set `limits.cpu`, it gets 200m |
| `default.memory` | 256Mi | If a container doesn't set `limits.memory`, it gets 256Mi |
| `defaultRequest.cpu` | 100m | If a container doesn't set `requests.cpu`, it gets 100m |
| `defaultRequest.memory` | 128Mi | If a container doesn't set `requests.memory`, it gets 128Mi |
| `max.cpu` | 1 | No container can have limits > 1 CPU (rejected at creation) |
| `max.memory` | 512Mi | No container can have limits > 512Mi |
| `min.cpu` | 50m | No container can request < 50m CPU |
| `min.memory` | 64Mi | No container can request < 64Mi |

### What Happens When Limits Are Violated

```bash
# Try to create a pod exceeding max:
# Error: [maximum cpu usage per Container is 1, but limit is 2]

# Try to create a pod below min:
# Error: [minimum memory usage per Container is 64Mi, but request is 32Mi]
```

### Verify

```bash
# View the LimitRange
kubectl describe limitrange shopping-limits -n shopping

# Expected output:
# Type        Resource  Min   Max    Default Request  Default Limit
# ----        --------  ---   ---    ---------------  -------------
# Container   cpu       50m   1      100m             200m
# Container   memory    64Mi  512Mi  128Mi            256Mi

# Test it — deploy a pod without resource specs and check what it gets:
kubectl run test-defaults --image=busybox -n shopping --command -- sleep 3600
kubectl get pod test-defaults -n shopping -o jsonpath='{.spec.containers[0].resources}' | python3 -m json.tool
# Should show the default values from LimitRange

# Clean up:
kubectl delete pod test-defaults -n shopping
```

---

## 3. Pod Security (securityContext)

### What

`securityContext` controls the privilege and access settings for pods and containers. It defines what a container can and cannot do at the OS level.

### Why

By default, containers run as root (UID 0). This is dangerous because:
- A container escape exploit gives the attacker root on the node
- Root inside the container can modify files in mounted volumes
- Privilege escalation (setuid binaries) could grant additional capabilities
- Linux capabilities (NET_RAW, SYS_ADMIN) enable kernel-level attacks

Running as non-root with dropped capabilities is **defense in depth** — even if an attacker breaches the application, they can't escalate beyond the container sandbox.

### Security Layers

```
┌─────────────────────────────────────────────────────┐
│ Pod-level securityContext                             │
│   runAsNonRoot: true      ← Reject if image is root │
│   runAsUser: 1000         ← Force UID 1000          │
│   fsGroup: 1000           ← Files owned by GID 1000 │
│                                                     │
│  ┌───────────────────────────────────────────────┐  │
│  │ Container-level securityContext                │  │
│  │   allowPrivilegeEscalation: false             │  │
│  │   capabilities:                               │  │
│  │     drop: ["ALL"]      ← No Linux capabilities│  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

### What Each Setting Does

| Setting | Level | Effect |
|---------|-------|--------|
| `runAsNonRoot: true` | Pod | Kubelet rejects the pod if the container tries to run as UID 0 |
| `runAsUser: 1000` | Pod | Force all processes to run as UID 1000 |
| `fsGroup: 1000` | Pod | Mounted volumes are writable by GID 1000 |
| `allowPrivilegeEscalation: false` | Container | Blocks setuid/setgid binaries from gaining elevated privileges |
| `capabilities.drop: ["ALL"]` | Container | Removes ALL Linux capabilities (NET_RAW, SYS_ADMIN, etc.) |

### Our Configuration (Standard Backend Service)

Applied to: checkout, payment, cart, auth, product-catalog, shipping

```yaml
# Pod-level (applies to all containers in the pod)
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 1000
  containers:
  - name: checkout-service
    image: checkout-service:latest
    # Container-level (specific to this container)
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
```

### The Nginx Exception (Frontend)

Nginx requires root to bind to port 80 and read its config. We couldn't apply the full security context:

```yaml
# frontend-service — reduced security (nginx requires root)
spec:
  # NO pod-level runAsNonRoot or runAsUser
  containers:
  - name: frontend-service
    image: frontend-service:latest
    securityContext:
      allowPrivilegeEscalation: false    # ← Still apply this!
      # NO capabilities drop (nginx needs NET_BIND_SERVICE)
```

**Why this is acceptable**:
- `allowPrivilegeEscalation: false` still prevents setuid escalation
- The frontend is a static file server with no sensitive data
- In production, you'd use nginx-unprivileged image (listens on 8080) to avoid this

**Production alternative**:
```yaml
# Use nginx-unprivileged and listen on port 8080
containers:
- name: frontend-service
  image: nginxinc/nginx-unprivileged:latest
  securityContext:
    runAsNonRoot: true
    runAsUser: 101
    allowPrivilegeEscalation: false
    capabilities:
      drop: ["ALL"]
  ports:
  - containerPort: 8080    # No root needed for ports > 1024
```

### The Shipping Service Fix (Go Binary Permissions)

The shipping service (Go binary) failed on first attempt because the compiled binary wasn't executable by UID 1000.

**The error**:
```
Error: container has runAsNonRoot and image will run as root
```

Then after adding `USER 1000` to the Dockerfile:
```
exec ./main: permission denied
```

**Root cause**: The Go binary was built and owned by root. When we switched to UID 1000, the user couldn't execute it.

**The fix** — Updated the Dockerfile to ensure the binary is executable:

```dockerfile
# shipping-service/Dockerfile
# Build stage
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod ./
COPY *.go ./
RUN go mod tidy && \
    go mod download && \
    CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o main .

# Production stage
FROM alpine:latest
RUN apk --no-cache add ca-certificates && \
    adduser -D -u 1000 appuser
WORKDIR /app

# Copy the binary and make it executable by all
COPY --from=builder /app/main .
RUN chmod +x ./main          # ← THIS was the fix

USER 1000
EXPOSE 8080
CMD ["./main"]
```

**Key lessons**:
1. Always create a non-root user in the Dockerfile (`adduser -D -u 1000 appuser`)
2. Ensure binaries are executable by that user (`chmod +x`)
3. Set `USER 1000` in the Dockerfile so it matches the pod's `runAsUser: 1000`
4. The pod-level `runAsUser` overrides the Dockerfile's `USER` directive anyway, but keeping them aligned is good practice

### Verify Security Context

```bash
# Check what user a pod is running as
kubectl exec -n shopping deployment/checkout-service -- id
# Expected: uid=1000 gid=0(root) groups=1000

# Verify no capabilities
kubectl exec -n shopping deployment/shipping-service -- cat /proc/1/status | grep -i cap
# Expected: CapEff: 0000000000000000 (all zeros = no capabilities)

# Verify privilege escalation is blocked
kubectl exec -n shopping deployment/checkout-service -- cat /proc/1/status | grep NoNewPrivs
# Expected: NoNewPrivs: 1

# Check the full security context of a running pod
kubectl get pod -n shopping -l app=checkout-service -o jsonpath='{.items[0].spec.securityContext}'
# Expected: {"fsGroup":1000,"runAsNonRoot":true,"runAsUser":1000}
```

---

## 4. Pod Disruption Budgets (PDB)

### What

A PodDisruptionBudget tells Kubernetes: "During voluntary disruptions, you must keep at least N pods running for this application." This guarantees availability during planned maintenance.

### Why

Without PDBs, a `kubectl drain` (or cluster autoscaler removing a node) could evict ALL pods of a service simultaneously, causing downtime. PDBs make the eviction controller respect your availability requirements.

### Voluntary vs Involuntary Disruptions

| Type | Examples | PDB Protects? |
|------|----------|---------------|
| **Voluntary** | `kubectl drain`, node autoscaler, cluster upgrade | Yes |
| **Involuntary** | Node crash, kernel panic, OOM kill, hardware failure | No |

### Our Configuration

With 2 replicas per service, `minAvailable: 1` means Kubernetes can evict at most 1 pod at a time:

```yaml
# k8s/pod-disruption-budgets.yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: frontend-pdb
  namespace: shopping
spec:
  minAvailable: 1              # At least 1 pod must stay running
  selector:
    matchLabels:
      app: frontend-service
```

We created PDBs for all 7 services:

| PDB Name | Service | minAvailable | Replicas | Can Evict |
|----------|---------|-------------|----------|-----------|
| frontend-pdb | frontend-service | 1 | 2 | 1 at a time |
| product-catalog-pdb | product-catalog-service | 1 | 2 | 1 at a time |
| cart-pdb | cart-service | 1 | 2 | 1 at a time |
| auth-pdb | user-authentication-service | 1 | 2 | 1 at a time |
| checkout-pdb | checkout-service | 1 | 2 | 1 at a time |
| payment-pdb | payment-service | 1 | 2 | 1 at a time |
| shipping-pdb | shipping-service | 1 | 2 | 1 at a time |

### minAvailable vs maxUnavailable

Both achieve the same thing, just expressed differently:

```yaml
# These two are equivalent for 2 replicas:
spec:
  minAvailable: 1        # At least 1 must stay up → can evict 1

spec:
  maxUnavailable: 1      # At most 1 can be down → must keep 1 up
```

**When to use which**:
- `minAvailable` — when you have a hard minimum (e.g., "we need at least 3 for quorum")
- `maxUnavailable` — when you think in terms of "how much disruption is tolerable" (works better with variable replica counts and HPA)

### The Math

```
Allowed disruptions = replicas - minAvailable
                    = 2 - 1
                    = 1

If HPA scales to 4 replicas:
Allowed disruptions = 4 - 1 = 3  (PDB becomes more permissive)
```

### Verify

```bash
# List all PDBs
kubectl get pdb -n shopping

# Expected output:
# NAME                  MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
# frontend-pdb          1               N/A               1                     5m
# product-catalog-pdb   1               N/A               1                     5m
# cart-pdb              1               N/A               1                     5m
# auth-pdb              1               N/A               1                     5m
# checkout-pdb          1               N/A               1                     5m
# payment-pdb           1               N/A               1                     5m
# shipping-pdb          1               N/A               1                     5m

# Check details of a specific PDB
kubectl describe pdb frontend-pdb -n shopping

# Test it — try draining a node:
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
# Kubernetes will evict pods one at a time, waiting for replacements
# If it can't evict without violating PDB, the drain will block
```

---

## 5. Horizontal Pod Autoscaler (HPA)

### What

HPA automatically adjusts the number of pod replicas based on observed metrics (typically CPU or memory utilization). When traffic spikes, more pods are created. When traffic drops, excess pods are removed.

### Why

Fixed replica counts are wasteful:
- Too few replicas → service degrades under load
- Too many replicas → paying for idle compute 24/7
- HPA gives you elastic scaling within defined boundaries

### How It Works

```
                    ┌─────────────┐
                    │ HPA         │ Checks every 15s
                    │ Controller  │
                    └──────┬──────┘
                           │
            ┌──────────────┼──────────────┐
            │              │              │
            ▼              ▼              ▼
    ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
    │ metrics-server│ │  Deployment  │ │   Pods       │
    │ (current CPU)│ │  (scale)     │ │  (actual)    │
    └──────────────┘ └──────────────┘ └──────────────┘

Formula:
  desiredReplicas = ceil( currentMetricValue / targetValue × currentReplicas )

Example:
  Current CPU: 140% (across 2 pods, avg 70% each)
  Target: 70%
  Desired = ceil(140% / 70% × 2) = ceil(4) = 4 replicas → Scale to 4!
```

### Prerequisites

HPA requires **metrics-server** to be running. It reads CPU/memory usage from the Kubernetes Metrics API.

```bash
# Install metrics-server (kind cluster)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# For kind/minikube, you may need to add --kubelet-insecure-tls:
kubectl patch deployment metrics-server -n kube-system --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

# Verify metrics-server is working
kubectl top nodes
kubectl top pods -n shopping
```

**Important**: HPA uses `requests` as the baseline for percentage calculations. A pod requesting 100m CPU at 70% target will scale up when average CPU usage exceeds 70m.

### Our Configuration

```yaml
# k8s/hpa.yaml

# Frontend HPA — scales based on CPU (user-facing, traffic-sensitive)
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: frontend-hpa
  namespace: shopping
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: frontend-service
  minReplicas: 2           # Never go below 2 (availability)
  maxReplicas: 5           # Cap at 5 (resource budget)
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70    # Scale up when avg CPU > 70% of request

---
# Checkout HPA — most resource-intensive (calls payment + shipping)
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: checkout-hpa
  namespace: shopping
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: checkout-service
  minReplicas: 2
  maxReplicas: 4
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 60    # Lower threshold — checkout is critical path

---
# Product Catalog HPA — most queried service (browse products)
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: product-catalog-hpa
  namespace: shopping
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: product-catalog-service
  minReplicas: 2
  maxReplicas: 4
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
```

### Why These Services and Thresholds

| Service | Max Replicas | Target CPU | Reasoning |
|---------|-------------|------------|-----------|
| frontend | 5 | 70% | Highest traffic — users browse constantly |
| checkout | 4 | 60% | Critical path, lower threshold = scale earlier |
| product-catalog | 4 | 70% | Most-queried backend service |
| cart, auth, payment, shipping | No HPA | - | Lower traffic, 2 replicas sufficient |

**Why checkout has a 60% threshold**: Checkout orchestrates calls to payment and shipping. If checkout becomes a bottleneck, the entire purchase flow degrades. We scale it earlier (60% vs 70%) to stay ahead of demand.

**Why not HPA on everything**: Auth, cart, payment, and shipping have lower sustained load. Adding HPA to services that rarely scale just adds complexity. We can always add them later if metrics show they need it.

### Scaling Behavior

HPA has built-in stabilization to avoid thrashing (scaling up and down rapidly):

- **Scale up**: Happens quickly (within 15 seconds of threshold breach)
- **Scale down**: Has a 5-minute stabilization window (default). Must stay below threshold for 5 minutes before scaling down.

### Verify

```bash
# Check HPA status
kubectl get hpa -n shopping

# Expected output:
# NAME                  REFERENCE                       TARGETS   MINPODS   MAXPODS   REPLICAS   AGE
# frontend-hpa          Deployment/frontend-service     12%/70%   2         5         2          5m
# checkout-hpa          Deployment/checkout-service     8%/60%    2         4         2          5m
# product-catalog-hpa   Deployment/product-catalog...   15%/70%   2         4         2          5m

# If TARGETS shows <unknown>/70%, metrics-server isn't working
# Fix: ensure metrics-server is running and has --kubelet-insecure-tls flag

# Watch scaling in real-time
kubectl get hpa -n shopping -w

# Generate load to trigger scaling (in another terminal):
kubectl run load-generator --image=busybox -n shopping --restart=Never -- \
  sh -c "while true; do wget -q -O- http://frontend-service:80 > /dev/null; done"

# Watch pods scale up:
kubectl get pods -n shopping -l app=frontend-service -w

# Clean up load generator:
kubectl delete pod load-generator -n shopping
```

### HPA + PDB Interaction

HPA and PDB work together:
- HPA scales to 4 replicas under load
- PDB says `minAvailable: 1`
- Now `allowedDisruptions = 4 - 1 = 3`
- A node drain can evict up to 3 pods at once (more permissive during scale-up)

When HPA scales back down to 2:
- `allowedDisruptions = 2 - 1 = 1` (back to conservative)

---

## Troubleshooting

### Issue: Pod rejected — exceeds ResourceQuota

**Symptom**:
```
Error from server (Forbidden): error when creating "deployment.yaml":
pods "checkout-service-xxx" is forbidden: exceeded quota: shopping-quota,
requested: requests.cpu=100m, used: requests.cpu=3900m, limited: requests.cpu=4
```

**Root cause**: The namespace has used up all allocated CPU. Total requests from all pods + this new pod exceeds the quota.

**Fix options**:
1. Reduce resource requests on existing pods
2. Scale down other deployments
3. Increase the quota (if cluster capacity allows)

```bash
# Check current usage
kubectl describe resourcequota shopping-quota -n shopping

# Find the biggest consumers
kubectl top pods -n shopping --sort-by=cpu
```

### Issue: Container violates LimitRange

**Symptom**:
```
Error from server (Forbidden): error when creating "deployment.yaml":
maximum cpu usage per Container is 1, but limit is 2
```

**Root cause**: A container's resource spec exceeds the LimitRange maximum.

**Fix**: Reduce the container's limits to stay within LimitRange bounds:
```yaml
resources:
  limits:
    cpu: "1"         # Max allowed by LimitRange
    memory: "512Mi"  # Max allowed by LimitRange
```

### Issue: Pod CrashLoopBackOff with securityContext

**Symptom**:
```
NAME                        READY   STATUS             RESTARTS   AGE
shipping-service-xxx        0/1     CrashLoopBackOff   3          2m
```

**Diagnosis**:
```bash
# Check the error
kubectl logs -n shopping deployment/shipping-service --previous

# Common errors:
# "exec ./main: permission denied"     ← Binary not executable by UID 1000
# "listen tcp :80: bind: permission denied"  ← Port < 1024 requires root
# "open /etc/nginx/nginx.conf: permission denied"  ← File owned by root
```

**Fix for Go/compiled binaries**:
```dockerfile
# In Dockerfile, ensure binary is executable
COPY --from=builder /app/main .
RUN chmod +x ./main
USER 1000
```

**Fix for applications needing specific ports**:
```yaml
# Change the application to listen on port > 1024
env:
- name: PORT
  value: "8080"    # Instead of 80
```

### Issue: "container has runAsNonRoot and image will run as root"

**Symptom**:
```
Error: container has runAsNonRoot and image will run as root
```

**Root cause**: The pod spec says `runAsNonRoot: true` but the container image's `USER` directive is root (or unset, which defaults to root).

**Fix**: Add a non-root user to the Dockerfile:
```dockerfile
RUN adduser -D -u 1000 appuser
USER 1000
```

Or if you can't change the image, set `runAsUser` in the pod spec (overrides image's USER):
```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000     # Force UID 1000 regardless of image USER
```

### Issue: HPA shows `<unknown>/70%` in TARGETS

**Symptom**:
```
NAME            REFERENCE               TARGETS         MINPODS   MAXPODS   REPLICAS
frontend-hpa    Deployment/frontend     <unknown>/70%   2         5         2
```

**Root cause**: metrics-server isn't running or can't scrape pod metrics.

**Diagnosis**:
```bash
# Check if metrics-server is running
kubectl get pods -n kube-system | grep metrics-server

# Check metrics-server logs
kubectl logs -n kube-system deployment/metrics-server

# Common error: "x509: cannot validate certificate"
# Fix: Add --kubelet-insecure-tls flag
kubectl patch deployment metrics-server -n kube-system --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

# Wait 30 seconds, then verify
kubectl top pods -n shopping
```

### Issue: Node drain blocked by PDB

**Symptom**:
```
evicting pod shopping/frontend-service-xxx
error when evicting pods/"frontend-service-xxx" -n "shopping" (will retry after 5s):
Cannot evict pod as it would violate the pod's disruption budget.
```

**Root cause**: All replicas are on the same node, and evicting one would leave zero running (violating `minAvailable: 1`).

**Fix**: Ensure pods are spread across nodes using topology spread constraints or pod anti-affinity:
```yaml
spec:
  topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app: frontend-service
```

---

## File Structure After Phase 4

```
online-microservices-test/
├── k8s/
│   ├── namespace.yaml
│   ├── configmap.yaml
│   ├── secrets.yaml
│   ├── network-policies.yaml
│   ├── rbac.yaml
│   ├── resource-quota.yaml         # NEW: Namespace resource limits
│   ├── limit-range.yaml            # NEW: Per-container defaults/bounds
│   ├── pod-disruption-budgets.yaml # NEW: Availability guarantees
│   └── hpa.yaml                    # NEW: Autoscaling rules
├── shipping-service/
│   └── Dockerfile                  # UPDATED: chmod +x, USER 1000
├── frontend-service/k8s/
│   └── deployment.yaml             # UPDATED: allowPrivilegeEscalation only
├── checkout-service/k8s/
│   └── deployment.yaml             # UPDATED: Full securityContext
├── (all other services)/k8s/
│   └── deployment.yaml             # UPDATED: Full securityContext
└── kustomization.yaml              # UPDATED: Added new resources
```

---

## Deployment & Validation

### Deploy Everything

```bash
# Apply all resources
kubectl apply -k .

# Verify new resources exist
kubectl get resourcequota -n shopping
kubectl get limitrange -n shopping
kubectl get pdb -n shopping
kubectl get hpa -n shopping
```

### Full Health Check

```bash
# All pods running as non-root with security context
for deploy in checkout-service payment-service cart-service shipping-service product-catalog-service user-authentication-service; do
  echo "=== $deploy ==="
  kubectl exec -n shopping deployment/$deploy -- id
done

# Check resource usage vs quota
kubectl describe resourcequota shopping-quota -n shopping

# Verify PDBs are protecting all services
kubectl get pdb -n shopping

# Verify HPAs are reading metrics
kubectl get hpa -n shopping
```

---

## Real-World Considerations

### What We'd Do Differently in Production

| This Project | Production |
|-------------|------------|
| Single LimitRange for all services | Different limits for CPU-heavy vs memory-heavy services |
| Fixed ResourceQuota | Dynamic quotas with alerts at 80% usage |
| minAvailable:1 PDB | minAvailable:2 for critical services (3+ replicas) |
| CPU-only HPA | Custom metrics HPA (requests/sec, queue depth) |
| securityContext in each deployment | Pod Security Admission (cluster-wide enforcement) |
| metrics-server | Prometheus + Prometheus Adapter for custom metrics |

### Pod Security Admission (Cluster-Wide)

In Kubernetes 1.25+, you can enforce security at the namespace level using Pod Security Admission labels:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: shopping
  labels:
    pod-security.kubernetes.io/enforce: restricted    # Block non-compliant pods
    pod-security.kubernetes.io/warn: restricted       # Warn about violations
    pod-security.kubernetes.io/audit: restricted      # Log violations
```

The three levels:
- **Privileged** — no restrictions (system namespaces)
- **Baseline** — blocks known privilege escalations
- **Restricted** — full hardening (what we did manually, but enforced cluster-wide)

### Resource Management Maturity

| Level | Approach |
|-------|----------|
| 1 (Dangerous) | No limits — any pod can consume unlimited resources |
| 2 (Basic) | LimitRange defaults — pods get reasonable defaults |
| 3 (Current) | Quota + LimitRange + explicit requests in deployments |
| 4 (Production) | VPA (Vertical Pod Autoscaler) recommends optimal requests |
| 5 (Advanced) | Goldilocks / kubecost — continuous right-sizing with cost visibility |

---

## kubectl Commands Reference

### Resource Quotas

```bash
# Create a quota imperatively (CKA exam)
kubectl create quota my-quota -n shopping \
  --hard=pods=10,requests.cpu=2,requests.memory=2Gi,limits.cpu=4,limits.memory=4Gi

# View quota usage
kubectl describe resourcequota shopping-quota -n shopping

# Check if a namespace has any quotas
kubectl get resourcequota -n shopping

# Delete a quota
kubectl delete resourcequota shopping-quota -n shopping
```

### LimitRanges

```bash
# View limit range details
kubectl describe limitrange shopping-limits -n shopping

# Check what defaults will be applied to new pods
kubectl get limitrange shopping-limits -n shopping -o yaml

# Delete a limit range
kubectl delete limitrange shopping-limits -n shopping
```

### Security Context

```bash
# Check what user a pod runs as
kubectl exec -n shopping deployment/checkout-service -- id

# Check capabilities
kubectl exec -n shopping deployment/checkout-service -- cat /proc/1/status | grep Cap

# Verify readOnlyRootFilesystem (if set)
kubectl exec -n shopping deployment/checkout-service -- touch /tmp/test
# Should fail if readOnlyRootFilesystem: true

# Get pod security context from spec
kubectl get pod -n shopping -l app=checkout-service \
  -o jsonpath='{.items[0].spec.securityContext}' | python3 -m json.tool
```

### Pod Disruption Budgets

```bash
# Create a PDB imperatively
kubectl create pdb my-pdb --selector=app=frontend-service --min-available=1 -n shopping

# List PDBs with disruption info
kubectl get pdb -n shopping

# Check allowed disruptions for a specific PDB
kubectl get pdb frontend-pdb -n shopping -o jsonpath='{.status.disruptionsAllowed}'

# Simulate a drain (dry-run)
kubectl drain <node> --dry-run=client --ignore-daemonsets --delete-emptydir-data
```

### Horizontal Pod Autoscaler

```bash
# Create an HPA imperatively (CKA exam)
kubectl autoscale deployment frontend-service -n shopping \
  --min=2 --max=5 --cpu-percent=70

# Check current HPA status
kubectl get hpa -n shopping

# Detailed HPA info (events, conditions)
kubectl describe hpa frontend-hpa -n shopping

# Watch scaling events
kubectl get hpa -n shopping -w

# Check if metrics-server is providing data
kubectl top pods -n shopping
kubectl top nodes

# Delete an HPA (returns to fixed replicas)
kubectl delete hpa frontend-hpa -n shopping
```

### Metrics Server

```bash
# Install metrics-server
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Fix for kind/minikube (TLS issue)
kubectl patch deployment metrics-server -n kube-system --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

# Verify it's working
kubectl get apiservice v1beta1.metrics.k8s.io
# Should show AVAILABLE=True

kubectl top nodes
kubectl top pods -n shopping --sort-by=cpu
```

---

## CKA/CKS Exam Relevance

### CKA Domains Covered

| Domain | Weight | What We Practiced |
|--------|--------|-------------------|
| Workloads & Scheduling (15%) | High | Resource requests/limits, HPA, LimitRange |
| Cluster Architecture (25%) | Medium | ResourceQuota, namespace resource management |
| Troubleshooting (30%) | High | Diagnosing quota violations, CrashLoopBackOff from security context |

### CKS Domains Covered

| Domain | Weight | What We Practiced |
|--------|--------|-------------------|
| System Hardening (15%) | High | securityContext, drop capabilities, non-root |
| Minimize Microservice Vulnerabilities (20%) | High | Pod Security, privilege escalation prevention |
| Supply Chain Security (20%) | Medium | Dockerfile best practices (non-root user) |

### CKA Exam Tips

1. **Know imperative commands** — `kubectl create quota`, `kubectl autoscale`
2. **ResourceQuota behavior** — once a quota exists, all pods MUST specify resources
3. **HPA formula** — `desired = ceil(current/target × replicas)`
4. **PDB blocking drain** — know that drain respects PDBs for voluntary disruptions
5. **LimitRange defaults** — a pod without resource specs gets the LimitRange defaults

### CKS Exam Tips

1. **securityContext levels** — know pod-level vs container-level settings
2. **capabilities** — know that `drop: ["ALL"]` removes all Linux capabilities
3. **runAsNonRoot** — this is a kubelet enforcement, not just a suggestion
4. **Pod Security Admission** — know the three levels (privileged, baseline, restricted)
5. **allowPrivilegeEscalation** — prevents setuid binaries from gaining privileges
6. **readOnlyRootFilesystem** — not used here, but know that it prevents writes to the container filesystem (use emptyDir for temp files)

---

## Next Steps

With resource management and security hardened, future phases could add:
- **Prometheus + Grafana** — observe actual resource usage patterns over time
- **Vertical Pod Autoscaler (VPA)** — automatically recommend optimal resource requests
- **Pod Security Admission** — enforce security at the namespace level (replace per-pod securityContext)
- **OPA Gatekeeper** — custom policies (e.g., "all images must come from our registry")
- **Resource right-sizing** — analyze actual usage vs requests with kubecost/Goldilocks
