# Phase 5: Observability & Monitoring

## Overview

This phase adds full observability to our cluster. We go from "I hope everything is working" to "I can see exactly what's happening across all services, in real time."

**What we did**:
- Installed Prometheus (metrics collection) via Helm
- Installed Grafana (visualization dashboards)
- Installed Loki (log aggregation)
- Installed Promtail (log shipping agent)
- Created ServiceMonitors to scrape our shopping app
- Connected everything together — metrics AND logs in one place

**Why this matters**:
- You can't fix what you can't see — observability is how you debug production issues
- Metrics tell you WHAT is broken, logs tell you WHY
- Proactive alerting catches problems before users notice
- This is the foundation for SLOs, on-call, and incident response

---

## 1. The Three Pillars of Observability

Observability isn't just "monitoring." It's the ability to understand what's happening inside your system by looking at its outputs. There are three pillars:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    THE THREE PILLARS                                     │
│                                                                         │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐              │
│  │   METRICS    │    │    LOGS      │    │   TRACES     │              │
│  │              │    │              │    │              │              │
│  │  Numbers     │    │  Events      │    │  Request     │              │
│  │  over time   │    │  with        │    │  journey     │              │
│  │              │    │  context     │    │  across      │              │
│  │  "CPU is at  │    │              │    │  services    │              │
│  │   85%"       │    │  "Error:     │    │              │              │
│  │              │    │   connection │    │  "Request    │              │
│  │  "5 req/sec" │    │   refused"   │    │   took 2s    │              │
│  │              │    │              │    │   because    │              │
│  │              │    │              │    │   payment    │              │
│  │              │    │              │    │   was slow"  │              │
│  └──────────────┘    └──────────────┘    └──────────────┘              │
│                                                                         │
│  Tool: Prometheus    Tool: Loki         Tool: Jaeger/Tempo             │
│  Query: PromQL       Query: LogQL       (Future phase)                 │
└─────────────────────────────────────────────────────────────────────────┘
```

### Metrics (Prometheus)

**What**: Numeric measurements collected at regular intervals.
**Examples**: CPU usage, memory consumption, request count, error rate, response time.
**Strength**: Great for alerting and trend analysis. "Are things getting worse?"
**Weakness**: Tells you WHAT is broken, not WHY.

### Logs (Loki)

**What**: Timestamped event records from applications and systems.
**Examples**: Error messages, stack traces, request details, audit events.
**Strength**: Rich context for debugging. "Here's the exact error message."
**Weakness**: High volume, hard to search at scale without proper tooling.

### Traces (Future Phase)

**What**: The full journey of a single request across multiple services.
**Examples**: "User clicked checkout → frontend → checkout-service → payment-service → shipping-service"
**Strength**: Shows WHERE time is spent across service boundaries.
**Weakness**: Requires instrumentation in application code.

### Why You Need All Three

| Scenario | Metric tells you | Log tells you | Trace tells you |
|----------|-----------------|---------------|-----------------|
| Checkout is slow | "P99 latency jumped to 5s" | "Timeout connecting to payment-service" | "Payment service took 4.8s at the DB query step" |
| Pods restarting | "Restart count increased" | "OOMKilled: memory limit exceeded" | N/A (pod died) |
| Error spike | "5xx errors up 300%" | "NullPointerException at line 42" | "Error happens only when cart has 50+ items" |

In this phase, we implement Metrics + Logs. Traces come later when we add OpenTelemetry instrumentation.

---

## 2. Helm — Package Manager for Kubernetes

### Why Helm First

This is the first time we used Helm in this project. Every tool in this phase (Prometheus, Grafana, Loki, Promtail) is installed via Helm. So let's understand it before diving into the monitoring stack.

### What Is Helm?

Helm is to Kubernetes what `apt` is to Ubuntu or `brew` is to macOS — a package manager. Instead of writing 20+ YAML files for a complex application, you install a **chart** (a pre-packaged set of K8s resources) with a single command.

Without Helm, installing Prometheus would require manually creating:
- Deployments (Prometheus server, Alertmanager, Grafana, node-exporter, kube-state-metrics)
- Services (for each component)
- ConfigMaps (Prometheus config, Grafana dashboards, alerting rules)
- ServiceAccounts + RBAC (Prometheus needs cluster-wide read access)
- CRDs (ServiceMonitor, PrometheusRule, etc.)

That's 30+ YAML files. With Helm, it's one command + a values file.

### Key Concepts

| Concept | Analogy | Description |
|---------|---------|-------------|
| **Chart** | apt package | A bundle of K8s manifests + templates |
| **Repository** | apt source | Where charts are hosted (like a registry) |
| **Release** | installed package | A running instance of a chart in your cluster |
| **Values file** | config file | Your customizations (override chart defaults) |

### How Helm Works

```
┌─────────────────────────────────────────────────────┐
│  You (helm install)                                  │
│         │                                           │
│         ▼                                           │
│  ┌─────────────┐     ┌──────────────────────────┐  │
│  │ Values File │────▶│ Chart Templates           │  │
│  │ (your       │     │ (Go templates +           │  │
│  │  overrides) │     │  default values)          │  │
│  └─────────────┘     └──────────┬───────────────┘  │
│                                  │                  │
│                                  ▼                  │
│                      ┌──────────────────────────┐   │
│                      │ Rendered K8s manifests    │   │
│                      │ (Deployments, Services,   │   │
│                      │  ConfigMaps, etc.)        │   │
│                      └──────────┬───────────────┘   │
│                                  │                  │
│                                  ▼                  │
│                      ┌──────────────────────────┐   │
│                      │ kubectl apply             │   │
│                      │ (resources created in     │   │
│                      │  your cluster)            │   │
│                      └──────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

### Commands We Used

```bash
# Add chart repositories (like adding apt sources)
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update    # Refresh the index (like apt update)

# Install a chart (creates a "release")
helm install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring -f monitoring/prometheus-values.yaml
#      │              │                                    │
#      │              │                                    └── Our overrides
#      │              └── Chart name (repo/chart)
#      └── Release name (what we call this installation)

# Install Loki
helm install loki grafana/loki \
  -n monitoring -f monitoring/loki-values.yaml

# Install Promtail
helm install promtail grafana/promtail \
  -n monitoring -f monitoring/promtail-values.yaml

# List installed releases
helm list -n monitoring
# NAME        NAMESPACE    REVISION    STATUS      CHART                          
# prometheus  monitoring   1           deployed    kube-prometheus-stack-65.8.1
# loki        monitoring   1           deployed    loki-6.24.0
# promtail    monitoring   1           deployed    promtail-6.16.6

# See what values a release is using
helm get values prometheus -n monitoring

# See ALL values (defaults + overrides)
helm get values prometheus -n monitoring --all

# Upgrade a release (after changing values file)
helm upgrade prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring -f monitoring/prometheus-values.yaml

# Uninstall (removes all resources created by the chart)
helm uninstall prometheus -n monitoring

# Search for charts
helm search repo prometheus
helm search repo grafana/loki
```

### Why Values Files?

Charts have hundreds of configuration options with sensible defaults. The values file lets you override just what you need:

```yaml
# monitoring/prometheus-values.yaml — we only override what differs from defaults
grafana:
  adminPassword: admin123          # Default is randomly generated
  additionalDataSources:           # Add Loki as a data source
    - name: Loki
      type: loki
      url: http://loki.monitoring:3100

prometheus:
  prometheusSpec:
    retention: 7d                  # Default is 10d, we use less for dev
    serviceMonitorSelectorNilUsesHelmValues: false  # Scrape ALL ServiceMonitors
```

Everything else (Grafana dashboards, node-exporter config, RBAC rules, etc.) uses the chart's defaults — we don't need to write those ourselves.

---

## 3. Prometheus — Metrics Collection

### What Is Prometheus?

Prometheus is a time-series database and monitoring system. It collects numeric metrics from your applications and infrastructure at regular intervals, stores them, and lets you query them with PromQL.

### Pull-Based Model

Unlike most monitoring systems (which receive data pushed to them), Prometheus **pulls** metrics from targets. Your services expose a `/metrics` endpoint, and Prometheus scrapes it every N seconds.

```
┌──────────────────────────────────────────────────────────────────┐
│                                                                    │
│  Prometheus Server                                                │
│  (pulls every 30s)                                                │
│         │                                                         │
│         ├──── GET /metrics ───▶ apiserver            (K8s API)    │
│         ├──── GET /metrics ───▶ coredns              (DNS)        │
│         ├──── GET /metrics ───▶ node-exporter        (Node HW)   │
│         ├──── GET /metrics ───▶ kube-state-metrics   (K8s state) │
│         ├──── GET /metrics ───▶ kubelet              (Container)  │
│         ├──── GET /health ───▶ product-catalog-svc   (Our app)   │
│         ├──── GET /health ───▶ cart-service          (Our app)   │
│         └──── ... 33 total scrape targets ...                     │
│                                                                    │
└──────────────────────────────────────────────────────────────────┘
```

**Why pull-based?**
- Prometheus controls the scrape interval (consistency)
- Easy to detect when a target is DOWN (scrape fails)
- No need to configure each service to "know where to push"
- ServiceMonitors tell Prometheus what to scrape (dynamic discovery)

### What We Get with kube-prometheus-stack

The Helm chart installs a full monitoring ecosystem:

| Component | What It Does |
|-----------|-------------|
| **Prometheus Server** | Scrapes and stores metrics |
| **Prometheus Operator** | Watches for ServiceMonitor/PrometheusRule CRDs |
| **Grafana** | Visualization dashboards |
| **AlertManager** | Routes alerts to Slack/email/PagerDuty |
| **node-exporter** | Exposes node-level metrics (CPU, disk, network) |
| **kube-state-metrics** | Exposes K8s object state (deployment replicas, pod status) |

### Our 33 Active Scrape Targets

After installation, Prometheus automatically discovers and scrapes:

```
Scrape Target                          What It Measures
─────────────────────────────────────  ─────────────────────────────────────
apiserver                              API request latency, etcd health
coredns                                DNS query rate, cache hits
kubelet (per node)                     Container CPU/memory, pod lifecycle
node-exporter (per node)               Node CPU, disk I/O, network, memory
kube-state-metrics                     Deployment status, pod phases, HPA state
prometheus-operator                    Operator reconciliation metrics
alertmanager                           Alert pipeline health
grafana                                Dashboard render time, data source health
prometheus itself                      Scrape duration, sample ingestion rate
our shopping services (ServiceMonitor) Application health endpoints
```

### PromQL Basics

PromQL is Prometheus's query language. Think SQL but for time-series data.

```promql
# Instant vector — current value of a metric
up
# Returns: up{job="apiserver"} = 1, up{job="coredns"} = 1, ...

# Filter by label
up{job="node-exporter"}
# Returns: up{instance="kind-worker:9100"} = 1

# Range vector — values over time (last 5 minutes)
node_cpu_seconds_total[5m]

# Rate — per-second rate of increase (most common function)
rate(node_cpu_seconds_total{mode="idle"}[5m])

# Aggregation — sum across all instances
sum(rate(container_cpu_usage_seconds_total{namespace="shopping"}[5m])) by (pod)

# Percentage — CPU usage as percentage
100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
```

**Key PromQL concepts**:

| Concept | Example | Meaning |
|---------|---------|---------|
| Instant vector | `up` | Current value right now |
| Range vector | `up[5m]` | Values over the last 5 minutes |
| `rate()` | `rate(requests_total[5m])` | Per-second increase rate |
| `sum() by ()` | `sum(metric) by (pod)` | Aggregate, grouped by label |
| `{label="value"}` | `up{namespace="shopping"}` | Filter by label |

### Access Prometheus UI

```bash
# Port-forward to access Prometheus web UI
kubectl port-forward -n monitoring service/prometheus-kube-prometheus-prometheus 9090:9090

# Open http://localhost:9090
# Go to Status → Targets to see all 33 scrape targets
# Go to Graph to run PromQL queries
```

---

## 4. Grafana — Visualization & Dashboards

### What Is Grafana?

Grafana is a visualization platform that connects to data sources (Prometheus, Loki, etc.) and renders dashboards with graphs, tables, and alerts. It's the "single pane of glass" where you see everything.

### Our Setup

The kube-prometheus-stack chart installs Grafana pre-configured with:
- **Prometheus data source** — already connected
- **Loki data source** — we added this in our values file
- **Pre-built dashboards** — Kubernetes cluster health, node metrics, pod resources

### Access Grafana

```bash
# Port-forward Grafana
kubectl port-forward -n monitoring service/prometheus-grafana 3000:80

# Open http://localhost:3000
# Login: admin / admin123
```

### Pre-Built Dashboards

After login, go to Dashboards → Browse. You'll find:

| Dashboard | What It Shows |
|-----------|--------------|
| Kubernetes / Compute Resources / Cluster | Total cluster CPU, memory, network |
| Kubernetes / Compute Resources / Namespace (Pods) | Per-pod resource usage in a namespace |
| Kubernetes / Compute Resources / Node (Pods) | Which pods are consuming each node |
| Node Exporter / Nodes | Detailed node hardware metrics |
| CoreDNS | DNS query rates, cache performance |
| etcd | etcd health (relevant for CKA) |
| Kubernetes / Networking / Pod | Network I/O per pod |

### Data Sources

```
┌─────────────────────────────────────────────────┐
│ Grafana                                          │
│                                                  │
│  Data Sources:                                   │
│  ┌─────────────────────────────────────────────┐│
│  │ Prometheus (default)                         ││
│  │ URL: http://prometheus-kube-prometheus-      ││
│  │      prometheus.monitoring:9090              ││
│  │ Use for: metrics, graphs, alerting           ││
│  └─────────────────────────────────────────────┘│
│  ┌─────────────────────────────────────────────┐│
│  │ Loki                                         ││
│  │ URL: http://loki.monitoring:3100             ││
│  │ Use for: log queries, log panels             ││
│  └─────────────────────────────────────────────┘│
└─────────────────────────────────────────────────┘
```

### Creating Custom Dashboards

You can create your own dashboards for the shopping app:

1. Click **+ → New Dashboard → Add Visualization**
2. Select **Prometheus** data source
3. Enter a PromQL query (e.g., `sum(up{namespace="shopping"}) by (job)`)
4. Choose visualization type (time series, stat, gauge, table)
5. Save the dashboard

---

## 5. Loki — Log Aggregation

### What Is Loki?

Loki is a log aggregation system designed by Grafana Labs. Think of it as "ELK stack (Elasticsearch + Logstash + Kibana) but 10x lighter." It doesn't index the full text of logs — it only indexes labels (like pod name, namespace, container). This makes it much cheaper to run.

### Why Not Just `kubectl logs`?

`kubectl logs` works for debugging one pod right now. But:
- Logs are lost when pods restart or get evicted
- You can't search across all pods simultaneously
- No correlation between logs from different services
- No historical logs (only current pod's stdout)

Loki solves all of these — it stores logs long-term, lets you search across all pods, and integrates directly into Grafana alongside your metrics.

### How Loki Works

```
┌────────────────────────────────────────────────────────────────┐
│                                                                  │
│  Node 1                    Node 2                    Node 3     │
│  ┌──────────┐              ┌──────────┐              ┌────────┐│
│  │ Promtail │              │ Promtail │              │Promtail││
│  │ (agent)  │              │ (agent)  │              │(agent) ││
│  └────┬─────┘              └────┬─────┘              └───┬────┘│
│       │                         │                        │      │
│       │  Reads container logs from /var/log/pods/*       │      │
│       │                         │                        │      │
│       └─────────────────────────┼────────────────────────┘      │
│                                 │                                │
│                                 ▼                                │
│                    ┌──────────────────────┐                      │
│                    │       Loki           │                      │
│                    │  (stores + indexes)  │                      │
│                    └──────────┬───────────┘                      │
│                               │                                  │
│                               ▼                                  │
│                    ┌──────────────────────┐                      │
│                    │      Grafana         │                      │
│                    │  (query + display)   │                      │
│                    └──────────────────────┘                      │
└────────────────────────────────────────────────────────────────┘
```

### Our Loki Configuration

We run Loki in **SingleBinary mode** — all components (ingester, querier, compactor) in one pod. This is fine for development but wouldn't scale for production.

```yaml
# monitoring/loki-values.yaml (key settings)
deploymentMode: SingleBinary       # All-in-one (dev mode)
loki:
  auth_enabled: false              # No multi-tenancy needed
  storage:
    type: filesystem               # Store on disk (not S3/GCS)
  schemaConfig:
    configs:
      - from: "2024-01-01"
        store: tsdb                # Time-series DB for index
        schema: v13                # Latest schema version
```

### LogQL — Querying Logs

LogQL is Loki's query language. It's similar to PromQL but for logs.

```logql
# Basic — all logs from a specific pod
{namespace="shopping", pod=~"checkout-service.*"}

# Filter by content (grep equivalent)
{namespace="shopping"} |= "error"

# Exclude lines
{namespace="shopping"} != "health"

# Regex filter
{namespace="shopping"} |~ "status=[45]\\d{2}"

# JSON parsing — extract fields from structured logs
{namespace="shopping"} | json | status >= 400

# Count errors per service (metric from logs!)
sum(rate({namespace="shopping"} |= "error" [5m])) by (pod)

# Log volume over time
sum(rate({namespace="shopping"}[1m])) by (container)
```

**Key LogQL concepts**:

| Syntax | Meaning | Example |
|--------|---------|---------|
| `{label="value"}` | Stream selector (required) | `{namespace="shopping"}` |
| `\|= "text"` | Line contains text | `\|= "error"` |
| `!= "text"` | Line does NOT contain text | `!= "healthcheck"` |
| `\|~ "regex"` | Line matches regex | `\|~ "HTTP/1.1 [45]"` |
| `\| json` | Parse JSON logs | `\| json \| level="error"` |
| `rate({}[5m])` | Log lines per second | Turns logs into metrics |

### Access Loki via Grafana

You don't typically access Loki directly. Instead:
1. Open Grafana (port 3000)
2. Go to **Explore** (compass icon in sidebar)
3. Select **Loki** as the data source
4. Enter a LogQL query

---

## 6. Promtail — Log Shipping Agent

### What Is Promtail?

Promtail is a lightweight agent that runs on **every node** in the cluster (as a DaemonSet). Its job is simple: read container logs from the node's filesystem and ship them to Loki.

### How It Collects Logs

Every container's stdout/stderr is written to a file on the node by the container runtime (containerd). Promtail reads these files and adds Kubernetes metadata as labels.

```
Container (stdout) → containerd → /var/log/pods/shopping_checkout-xxx/checkout/0.log
                                                    │
                                            Promtail reads this
                                                    │
                                                    ▼
                                            Adds labels:
                                              namespace=shopping
                                              pod=checkout-xxx
                                              container=checkout-service
                                                    │
                                                    ▼
                                            Pushes to Loki
```

### DaemonSet Behavior

A DaemonSet ensures exactly one Promtail pod runs on each node. When a new node joins the cluster, a Promtail pod is automatically scheduled on it. When a node is removed, the Promtail pod is removed too.

```bash
# Verify Promtail is running on all nodes
kubectl get pods -n monitoring -l app.kubernetes.io/name=promtail -o wide

# Expected — one pod per node:
# NAME              READY   STATUS    NODE
# promtail-abc12   1/1     Running   kind-worker
# promtail-def34   1/1     Running   kind-worker2
# promtail-ghi56   1/1     Running   kind-control-plane
```

### Our Configuration

```yaml
# monitoring/promtail-values.yaml
config:
  clients:
    - url: http://loki.monitoring:3100/loki/api/v1/push  # Where to send logs

resources:
  requests:
    memory: "64Mi"
    cpu: "50m"
  limits:
    memory: "128Mi"
    cpu: "100m"
```

The Promtail chart handles all the complex parts automatically:
- Mounting `/var/log/pods` from the node
- Kubernetes service discovery (auto-labeling pods)
- Position tracking (remembers where it left off if restarted)
- Multiline log handling

---

## 7. ServiceMonitors — Telling Prometheus What to Scrape

### What Is a ServiceMonitor?

A ServiceMonitor is a **Custom Resource Definition (CRD)** installed by the Prometheus Operator. It tells Prometheus: "hey, scrape metrics from this Kubernetes Service on this port and path."

### How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                   │
│  1. You create a ServiceMonitor YAML                             │
│  2. Prometheus Operator watches for ServiceMonitor resources     │
│  3. Operator generates scrape config for Prometheus              │
│  4. Prometheus scrapes the target endpoints                      │
│                                                                   │
│  ┌──────────────┐     ┌─────────────────┐     ┌──────────────┐ │
│  │ServiceMonitor│────▶│Prometheus       │────▶│Prometheus    │ │
│  │ (CRD)        │     │Operator          │     │Server        │ │
│  │              │     │(watches + config)│     │(scrapes)     │ │
│  └──────────────┘     └─────────────────┘     └──────────────┘ │
│                                                                   │
└─────────────────────────────────────────────────────────────────┘
```

Without the Operator, you'd have to manually edit Prometheus's `prometheus.yml` config file every time you add a service. ServiceMonitors make it declarative and dynamic.

### Our ServiceMonitors

```yaml
# monitoring/service-monitors.yaml

# Monitor all backend Node.js services
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: nodejs-services
  namespace: monitoring
  labels:
    release: prometheus        # ← CRITICAL: must match Prometheus Operator's selector
spec:
  namespaceSelector:
    matchNames:
      - shopping               # Look for services in the shopping namespace
  selector:
    matchLabels:
      app.kubernetes.io/component: backend   # Match services with this label
  endpoints:
  - port: http                 # Which port to scrape (named port from Service)
    path: /health              # What path to hit
    interval: 30s              # How often to scrape

---
# Monitor frontend service
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: frontend-service
  namespace: monitoring
  labels:
    release: prometheus
spec:
  namespaceSelector:
    matchNames:
      - shopping
  selector:
    matchLabels:
      app: frontend-service
  endpoints:
  - port: http
    path: /
    interval: 30s
```

### The `release: prometheus` Label

This is the most common gotcha. The Prometheus Operator only watches ServiceMonitors that match its selector. By default, it looks for `release: prometheus` (the Helm release name). If you forget this label, Prometheus will never scrape your target.

### Verify ServiceMonitors Are Working

```bash
# List ServiceMonitors
kubectl get servicemonitors -n monitoring

# Check Prometheus targets in the UI
kubectl port-forward -n monitoring service/prometheus-kube-prometheus-prometheus 9090:9090
# Go to http://localhost:9090/targets
# Look for your services — they should show "UP"

# If a target shows "DOWN", check:
# 1. Does the Service exist in the shopping namespace?
# 2. Does the Service have the matching labels?
# 3. Is the port name correct?
# 4. Is the app actually responding on that path?
```

---

## 8. Accessing the Monitoring Stack

All monitoring components run as ClusterIP services (not exposed externally). We use `kubectl port-forward` to access them locally.

### Port-Forward Commands

```bash
# ═══════════════════════════════════════════════════════════════
# Grafana — Main dashboard UI
# ═══════════════════════════════════════════════════════════════
kubectl port-forward -n monitoring service/prometheus-grafana 3000:80
# → http://localhost:3000
# Login: admin / admin123

# ═══════════════════════════════════════════════════════════════
# Prometheus — Raw metrics & PromQL queries
# ═══════════════════════════════════════════════════════════════
kubectl port-forward -n monitoring service/prometheus-kube-prometheus-prometheus 9090:9090
# → http://localhost:9090
# No login required

# ═══════════════════════════════════════════════════════════════
# AlertManager — Alert routing & silencing
# ═══════════════════════════════════════════════════════════════
kubectl port-forward -n monitoring service/prometheus-kube-prometheus-alertmanager 9093:9093
# → http://localhost:9093
# No login required

# ═══════════════════════════════════════════════════════════════
# Loki — Log API (usually accessed via Grafana, not directly)
# ═══════════════════════════════════════════════════════════════
kubectl port-forward -n monitoring service/loki 3100:3100
# → http://localhost:3100/ready (health check)
# → http://localhost:3100/metrics (Loki's own metrics)
```

### Quick Health Check

```bash
# Verify all monitoring pods are running
kubectl get pods -n monitoring

# Expected output (simplified):
# NAME                                                     READY   STATUS    
# prometheus-kube-prometheus-operator-xxx                  1/1     Running
# prometheus-prometheus-kube-prometheus-prometheus-0        2/2     Running
# prometheus-grafana-xxx                                   3/3     Running
# prometheus-kube-state-metrics-xxx                        1/1     Running
# prometheus-kube-prometheus-node-exporter-xxx             1/1     Running
# alertmanager-prometheus-kube-prometheus-alertmanager-0   2/2     Running
# loki-0                                                   1/1     Running
# promtail-xxx                                            1/1     Running
```

---

## 9. Useful PromQL Queries for Our Shopping App

These queries work in both the Prometheus UI and Grafana dashboards.

### Cluster Health

```promql
# How many pods are running in the shopping namespace?
count(kube_pod_status_phase{namespace="shopping", phase="Running"})

# Are all our services healthy? (1 = up, 0 = down)
up{namespace="shopping"}

# Pod restart count (high restarts = something is crashing)
sum(kube_pod_container_status_restarts_total{namespace="shopping"}) by (pod)

# Pods NOT in Running phase (should be 0)
kube_pod_status_phase{namespace="shopping", phase!="Running"} > 0
```

### Resource Usage

```promql
# CPU usage per pod in shopping namespace (cores)
sum(rate(container_cpu_usage_seconds_total{namespace="shopping"}[5m])) by (pod)

# Memory usage per pod (bytes → MB)
sum(container_memory_working_set_bytes{namespace="shopping"}) by (pod) / 1024 / 1024

# CPU usage as percentage of request (are we right-sized?)
sum(rate(container_cpu_usage_seconds_total{namespace="shopping"}[5m])) by (pod)
/
sum(kube_pod_container_resource_requests{namespace="shopping", resource="cpu"}) by (pod)
* 100

# Memory usage as percentage of limit (approaching OOM?)
sum(container_memory_working_set_bytes{namespace="shopping"}) by (pod)
/
sum(kube_pod_container_resource_limits{namespace="shopping", resource="memory"}) by (pod)
* 100
```

### HPA Monitoring

```promql
# Current replicas vs desired replicas (are HPAs scaling?)
kube_horizontalpodautoscaler_status_current_replicas{namespace="shopping"}
kube_horizontalpodautoscaler_status_desired_replicas{namespace="shopping"}

# HPA at max capacity? (bad — can't scale further)
kube_horizontalpodautoscaler_status_current_replicas{namespace="shopping"}
==
kube_horizontalpodautoscaler_spec_max_replicas{namespace="shopping"}
```

### Node Health

```promql
# Node CPU usage percentage
100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# Node memory usage percentage
(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100

# Disk usage percentage
(1 - (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"})) * 100
```

### Network

```promql
# Network receive bytes per pod (bytes/sec)
sum(rate(container_network_receive_bytes_total{namespace="shopping"}[5m])) by (pod)

# Network transmit bytes per pod
sum(rate(container_network_transmit_bytes_total{namespace="shopping"}[5m])) by (pod)
```

---

## 10. Troubleshooting

### Issue: Monitoring pods stuck in Pending

**Symptom**:
```
NAME                                          READY   STATUS    
prometheus-prometheus-kube-prometheus-prom-0   0/2     Pending
```

**Root cause**: Usually insufficient resources. Prometheus needs ~256Mi memory and the cluster may not have enough after all shopping pods are running.

**Diagnosis**:
```bash
# Check why it's pending
kubectl describe pod prometheus-prometheus-kube-prometheus-prometheus-0 -n monitoring

# Look for events like:
# "0/3 nodes are available: 3 Insufficient memory"
# "0/3 nodes are available: 3 Insufficient cpu"

# Check node resources
kubectl top nodes
kubectl describe nodes | grep -A 5 "Allocated resources"
```

**Fix options**:
1. Scale down shopping replicas temporarily: `kubectl scale deployment --all --replicas=1 -n shopping`
2. Reduce Prometheus resource requests in values file
3. Add more nodes to the Kind cluster (edit `kind-cluster.yaml`)

### Issue: Helm install timeout

**Symptom**:
```
Error: INSTALLATION FAILED: timed out waiting for the condition
```

**Root cause**: The chart's pods didn't become Ready within the default timeout (5 minutes). Common with kube-prometheus-stack because it deploys many components.

**Fix**:
```bash
# Increase timeout
helm install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring -f monitoring/prometheus-values.yaml --timeout 10m

# If it partially installed, check what's failing
kubectl get pods -n monitoring
kubectl describe pod <pending-pod> -n monitoring

# If you need to start over
helm uninstall prometheus -n monitoring
# Wait for all pods to terminate, then reinstall
```

### Issue: Loki not receiving logs

**Symptom**: Grafana → Explore → Loki shows no log streams.

**Diagnosis**:
```bash
# 1. Is Loki running?
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki

# 2. Is Promtail running on all nodes?
kubectl get pods -n monitoring -l app.kubernetes.io/name=promtail -o wide

# 3. Check Promtail logs — is it connecting to Loki?
kubectl logs -n monitoring -l app.kubernetes.io/name=promtail --tail=50

# Look for errors like:
# "msg=\"error sending batch\" status=503"    ← Loki is down/overloaded
# "msg=\"error connecting to Loki\""          ← Wrong URL

# 4. Verify Loki is ready
kubectl port-forward -n monitoring service/loki 3100:3100
curl http://localhost:3100/ready
# Should return: "ready"

# 5. Check if any labels are indexed
curl http://localhost:3100/loki/api/v1/labels
# Should return: {"status":"success","data":["namespace","pod","container",...]}
```

**Common fixes**:
- Promtail URL mismatch: Ensure `clients.url` in promtail-values.yaml points to `http://loki.monitoring:3100/loki/api/v1/push`
- Loki gateway issue: We disabled the gateway (`gateway.enabled: false`), ensure Promtail connects directly to the Loki service
- Loki OOMKilled: Check `kubectl describe pod loki-0 -n monitoring` for OOM events, increase memory limit

### Issue: Grafana can't connect to Loki data source

**Symptom**: In Grafana → Data Sources → Loki, clicking "Test" returns an error.

**Fix**: Verify the URL in the data source configuration:
```yaml
# In prometheus-values.yaml, the Loki data source URL must be:
additionalDataSources:
  - name: Loki
    type: loki
    url: http://loki.monitoring:3100    # Service name + namespace
    access: proxy                        # Grafana server makes the request
```

If you changed the Loki service name or namespace, update this accordingly. After changing values, upgrade the Helm release:
```bash
helm upgrade prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring -f monitoring/prometheus-values.yaml
```

### Issue: ServiceMonitor target showing as DOWN

**Symptom**: In Prometheus UI → Targets, your shopping service shows state "DOWN" with an error.

**Diagnosis**:
```bash
# 1. Does the target Service exist with matching labels?
kubectl get svc -n shopping --show-labels

# 2. Can you reach the endpoint manually?
kubectl port-forward -n shopping service/product-catalog-service 8080:80
curl http://localhost:8080/health

# 3. Does the ServiceMonitor port name match the Service port name?
kubectl get svc product-catalog-service -n shopping -o yaml | grep -A3 "ports:"
# The port name in ServiceMonitor must match the Service's port name

# 4. Is Prometheus allowed to reach the shopping namespace? (NetworkPolicy)
# If you have strict network policies, ensure monitoring → shopping traffic is allowed
```

### Issue: "CRD not found" when applying ServiceMonitors

**Symptom**:
```
error: resource mapping not found for name: "nodejs-services"
kind: ServiceMonitor — ensure CRDs are installed first
```

**Root cause**: The ServiceMonitor CRD is installed by kube-prometheus-stack. If Prometheus isn't installed yet (or installation failed), the CRD doesn't exist.

**Fix**: Install Prometheus first, then apply ServiceMonitors:
```bash
# Install the Helm chart (installs CRDs)
helm install prometheus prometheus-community/kube-prometheus-stack -n monitoring -f monitoring/prometheus-values.yaml

# Verify CRDs exist
kubectl get crd | grep monitoring.coreos.com

# Then apply ServiceMonitors
kubectl apply -f monitoring/service-monitors.yaml
```

---

## 11. CKA/CKS Exam Relevance

### CKA Domains Covered

| Domain | Weight | What We Practiced |
|--------|--------|-------------------|
| Cluster Architecture (25%) | High | Understanding monitoring components, how Prometheus integrates with K8s |
| Workloads & Scheduling (15%) | Medium | DaemonSets (Promtail), resource management for monitoring pods |
| Troubleshooting (30%) | High | Using metrics/logs to diagnose cluster issues, understanding scrape targets |
| Services & Networking (20%) | Medium | Service discovery, port-forwarding, ClusterIP access patterns |

### CKS Domains Covered

| Domain | Weight | What We Practiced |
|--------|--------|-------------------|
| Monitoring, Logging, Runtime Security (20%) | High | This entire phase — audit logs, monitoring cluster health |
| Cluster Hardening (15%) | Medium | RBAC for monitoring (Prometheus needs cluster-read access) |
| System Hardening (15%) | Low | Securing Grafana credentials, understanding what's exposed |

### CKA Exam Tips

1. **Know `kubectl top`** — requires metrics-server (not Prometheus), but concept is the same
2. **Know how to check component health** — `kubectl get componentstatuses` (deprecated) vs checking pods in kube-system
3. **Understand DaemonSets** — Promtail is a perfect DaemonSet example (one per node, auto-scheduled)
4. **Know Service types** — all monitoring uses ClusterIP (internal only) + port-forward for access
5. **Troubleshooting with logs** — `kubectl logs`, but understand that centralized logging (Loki) is the production approach

### CKS Exam Tips

1. **Audit logging** — CKS expects you to know how to enable and query audit logs (Loki can store these)
2. **Falco vs Prometheus** — know that Prometheus monitors metrics, Falco monitors runtime behavior (syscalls)
3. **Secure Grafana** — in production, never use default credentials. Know how to change secrets
4. **RBAC for monitoring** — Prometheus needs `ClusterRole` with get/list/watch on pods, services, endpoints
5. **Network Policies for monitoring** — know that monitoring namespace needs ingress from shopping namespace (for scraping)

### Exam Commands to Remember

```bash
# Check cluster component health
kubectl get pods -n kube-system

# View resource usage (requires metrics-server)
kubectl top nodes
kubectl top pods -n shopping --sort-by=cpu

# Check logs for troubleshooting
kubectl logs -n kube-system <pod-name>
kubectl logs -n shopping deployment/checkout-service --previous  # Previous crash

# DaemonSet operations
kubectl get daemonset -n monitoring
kubectl rollout status daemonset/promtail -n monitoring

# CRD listing (ServiceMonitors are CRDs)
kubectl get crd | grep monitoring
kubectl get servicemonitors -A
```

---

## 12. How This Maps to a Real Company

### The On-Call Experience

In production, you wouldn't be manually running `kubectl port-forward`. Here's what a real monitoring setup looks like:

```
┌─────────────────────────────────────────────────────────────────────┐
│ Production Monitoring Flow                                           │
│                                                                     │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────────┐ │
│  │Prometheus│───▶│AlertMgr  │───▶│PagerDuty │───▶│On-call       │ │
│  │(detects) │    │(routes)  │    │(pages)   │    │engineer phone│ │
│  └──────────┘    └──────────┘    └──────────┘    └──────────────┘ │
│       │                                                  │         │
│       ▼                                                  ▼         │
│  ┌──────────┐                                    ┌──────────────┐ │
│  │ Grafana  │◀───────────────────────────────────│ Opens laptop │ │
│  │(dashbrd) │    "Let me check the dashboard"    │ Investigates │ │
│  └──────────┘                                    └──────────────┘ │
│       │                                                  │         │
│       ▼                                                  ▼         │
│  ┌──────────┐                                    ┌──────────────┐ │
│  │  Loki    │◀───────────────────────────────────│ Checks logs  │ │
│  │ (logs)   │    "What error is causing this?"   │ Finds root   │ │
│  └──────────┘                                    │ cause         │ │
│                                                  └──────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

### Alerting Rules (What We'd Add Next)

```yaml
# Example: Alert if checkout service is down for > 1 minute
groups:
- name: shopping-alerts
  rules:
  - alert: CheckoutServiceDown
    expr: up{job="checkout-service", namespace="shopping"} == 0
    for: 1m
    labels:
      severity: critical
    annotations:
      summary: "Checkout service is DOWN"
      description: "No healthy checkout pods for 1+ minute. Revenue impact."
      runbook: "https://wiki.company.com/runbook/checkout-down"

  - alert: HighErrorRate
    expr: |
      sum(rate(http_requests_total{namespace="shopping", status=~"5.."}[5m]))
      /
      sum(rate(http_requests_total{namespace="shopping"}[5m]))
      > 0.05
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "Error rate above 5% in shopping namespace"
```

### SLOs (Service Level Objectives)

SLOs define "how reliable should this service be?" They're the bridge between monitoring data and business requirements.

| Service | SLO | Metric | Alert Threshold |
|---------|-----|--------|-----------------|
| Frontend | 99.9% availability | `up{app="frontend-service"}` | < 99.9% over 30 days |
| Checkout | < 500ms P99 latency | `histogram_quantile(0.99, ...)` | > 500ms for 5 minutes |
| All services | < 1% error rate | `rate(5xx) / rate(total)` | > 1% for 5 minutes |

### What Engineers Use Daily

| Tool | When | Use Case |
|------|------|----------|
| Grafana dashboards | Start of shift | "Is everything healthy?" Quick glance at key metrics |
| Prometheus alerts | Reactive | "Something is wrong!" PagerDuty wakes you at 3am |
| Loki logs | Investigation | "WHY is it broken?" Dig into error messages |
| Traces (future) | Deep debugging | "Where exactly is the slowness?" |

### Our Project vs Production

| This Project | Production |
|-------------|------------|
| `port-forward` to access Grafana | Grafana behind auth proxy (SSO) on a domain |
| admin/admin123 | OAuth/SAML, no shared passwords |
| emptyDir storage (data lost on restart) | Persistent volumes or S3/GCS for long-term retention |
| 7-day retention | 30-90 days metrics, 14-30 days logs |
| No alerting configured | AlertManager → PagerDuty/Slack/email |
| Single Prometheus instance | Thanos or Mimir for HA and long-term storage |
| SingleBinary Loki | Distributed Loki with S3 backend |
| Manual dashboards | Dashboards-as-code (Jsonnet/Grafonnet) |

---

## File Structure After Phase 5

```
online-microservices-test/
├── monitoring/
│   ├── README.md                  # Quick reference (install/access/uninstall)
│   ├── prometheus-values.yaml     # Prometheus + Grafana + AlertManager config
│   ├── loki-values.yaml           # Loki log aggregation config
│   ├── promtail-values.yaml       # Promtail log agent config
│   └── service-monitors.yaml      # CRDs telling Prometheus what to scrape
├── k8s/
│   ├── ... (all previous resources)
│   └── hpa.yaml                   # HPA uses metrics-server (related)
└── docs/
    └── 05-observability-monitoring.md  # This file
```

---

## Full Installation Walkthrough

For a complete fresh install, here's the exact sequence:

```bash
# 1. Create the monitoring namespace
kubectl create namespace monitoring

# 2. Add Helm chart repositories
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# 3. Install kube-prometheus-stack (Prometheus + Grafana + AlertManager)
helm install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f monitoring/prometheus-values.yaml \
  --timeout 10m

# 4. Wait for Prometheus pods to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=prometheus -n monitoring --timeout=300s

# 5. Install Loki (log storage)
helm install loki grafana/loki \
  -n monitoring \
  -f monitoring/loki-values.yaml

# 6. Install Promtail (log agent)
helm install promtail grafana/promtail \
  -n monitoring \
  -f monitoring/promtail-values.yaml

# 7. Apply ServiceMonitors for our shopping app
kubectl apply -f monitoring/service-monitors.yaml

# 8. Verify everything is running
kubectl get pods -n monitoring
kubectl get servicemonitors -n monitoring

# 9. Access Grafana
kubectl port-forward -n monitoring service/prometheus-grafana 3000:80
# → http://localhost:3000 (admin/admin123)
```

---

## Helm Commands Reference

```bash
# ═══════════════════════════════════════════════════════════════
# Repository Management
# ═══════════════════════════════════════════════════════════════
helm repo add <name> <url>          # Add a chart repository
helm repo update                    # Refresh index from all repos
helm repo list                      # List configured repos
helm repo remove <name>             # Remove a repo

# ═══════════════════════════════════════════════════════════════
# Chart Discovery
# ═══════════════════════════════════════════════════════════════
helm search repo <keyword>          # Search repos for charts
helm show values <chart>            # Show all configurable values
helm show readme <chart>            # Show the chart's README

# ═══════════════════════════════════════════════════════════════
# Installation & Management
# ═══════════════════════════════════════════════════════════════
helm install <release> <chart> -n <namespace> -f <values.yaml>
helm upgrade <release> <chart> -n <namespace> -f <values.yaml>
helm uninstall <release> -n <namespace>
helm rollback <release> <revision> -n <namespace>

# ═══════════════════════════════════════════════════════════════
# Inspection
# ═══════════════════════════════════════════════════════════════
helm list -n <namespace>            # List installed releases
helm status <release> -n <namespace>  # Release status
helm get values <release> -n <namespace>  # User-supplied values
helm get values <release> -n <namespace> --all  # All values (defaults + overrides)
helm get manifest <release> -n <namespace>  # Rendered K8s manifests
helm history <release> -n <namespace>  # Release revision history

# ═══════════════════════════════════════════════════════════════
# Useful Flags
# ═══════════════════════════════════════════════════════════════
--timeout 10m                       # Wait longer for big charts
--dry-run                           # Render templates without installing
--debug                             # Verbose output
--create-namespace                  # Create namespace if it doesn't exist
--wait                              # Wait until all resources are ready
```

---

## Next Steps

With observability in place, future phases could add:
- **Alerting rules** — define alerts for checkout downtime, high error rates, resource exhaustion
- **Custom application metrics** — instrument our services with Prometheus client libraries
- **Distributed tracing** — add OpenTelemetry + Tempo/Jaeger for request tracing across services
- **Dashboards-as-code** — version control Grafana dashboards with Jsonnet
- **Log-based alerts** — trigger alerts when specific error patterns appear in Loki
- **Long-term storage** — Thanos or Mimir for metrics retention beyond 7 days
