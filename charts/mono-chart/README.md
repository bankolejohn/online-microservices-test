# Mono Chart — One Chart to Deploy Them All

## The Concept

Instead of writing a Helm chart per service (which means 200 charts to maintain
for 200 services), the Mono Chart is a SINGLE parameterized chart deployed N
times — once per service — each with a different values file.

Reference: [Ewere Diagboya — Single Helm Chart for All Kubernetes Deployments](https://medium.com/mycloudseries/single-helm-chart-for-all-kubernetes-deployments-using-argocd-mono-chart-e39dee186e4e)

## Structure

```
mono-chart/
├── Chart.yaml
├── values.yaml              # Default values + documentation of every knob
├── templates/
│   ├── _helpers.tpl
│   ├── deployment.yaml      # Fully parameterized — works for ANY service
│   ├── service.yaml
│   ├── hpa.yaml             # Only if autoscaling.enabled
│   ├── pdb.yaml             # Only if pdb.enabled
│   └── ingress.yaml         # Only if ingress.enabled
├── values/                  # ONE file per service
│   ├── frontend-service.yaml
│   ├── cart-service.yaml
│   ├── checkout-service.yaml
│   └── ... (7 total)
└── deploy-all.sh
```

## Usage

### Deploy a single service

```bash
helm upgrade --install cart-service ./charts/mono-chart \
  -f ./charts/mono-chart/values/cart-service.yaml \
  -n shopping --create-namespace
```

### Deploy all services

```bash
./charts/mono-chart/deploy-all.sh
```

Each service becomes its own Helm release:

```
$ helm list -n shopping
NAME                          STATUS      CHART
cart-service                  deployed    mono-chart-1.0.0
checkout-service              deployed    mono-chart-1.0.0
frontend-service              deployed    mono-chart-1.0.0
...
```

Notice: same chart (`mono-chart-1.0.0`), 7 independent releases.

### Validate without deploying

```bash
helm template cart-service ./charts/mono-chart -f ./charts/mono-chart/values/cart-service.yaml
```

## At Scale: ArgoCD ApplicationSet

For 400 services, use the ApplicationSet (`argocd/applicationset-mono-chart.yaml`).
It generates one ArgoCD Application per service, all using this chart.

Adding a service:
1. Create `values/new-service.yaml`
2. Add one line to the ApplicationSet `elements` list (or use a Git generator to auto-discover)
3. ArgoCD creates and syncs the Application automatically

## Mono Chart vs Umbrella Chart

This project has BOTH patterns for comparison:

| | Umbrella chart (`charts/online-shopping/`) | Mono chart (`charts/mono-chart/`) |
|---|---|---|
| Structure | One chart, all services in values.yaml | One generic chart, deployed N times |
| Releases | 1 release for everything | 1 release per service |
| Deploy one service | No (all-or-nothing) | Yes (independent) |
| Rollback one service | No | Yes |
| Best for | Small, tightly-coupled apps | Many services, independent teams |
| Scale ceiling | ~10-20 services | Hundreds |

## Tradeoffs

**Pros:**
- DRY — one template, maintained once
- Golden path — every service deploys identically
- Consistency — services physically cannot drift apart
- Scales to hundreds of services

**Cons:**
- Single point of failure — a bug in the chart affects ALL services
- Requires a well-designed, thoroughly-tested template
- Less flexibility for a service that needs something truly unique
  (handle with conditional blocks or `enabled` flags)
