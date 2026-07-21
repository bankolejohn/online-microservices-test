# Phase 7: CI/CD and GitOps

## Overview

This phase replaces manual `kubectl apply` workflows with a fully automated CI/CD pipeline and GitOps deployment model. The pipeline builds, scans, and pushes container images on every commit, while ArgoCD continuously reconciles the cluster state with what's declared in git.

**The core principle:** Git is the single source of truth for what's deployed. No one runs `kubectl apply` in production — they push code, and the system converges.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Developer Workflow                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  1. Push code ──► 2. GitHub Actions CI ──► 3. GHCR (images)            │
│                         │                                               │
│                         ▼                                               │
│                   4. GitHub Actions CD                                   │
│                         │                                               │
│                         ▼                                               │
│              5. Update image tag in git                                  │
│                  (k8s/overlays/staging/)                                 │
│                         │                                               │
│                         ▼                                               │
│              6. ArgoCD detects change                                    │
│                         │                                               │
│                         ▼                                               │
│              7. ArgoCD syncs cluster                                     │
│                  (kubectl apply -k k8s/overlays/staging/)               │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Flow Summary

| Step | What happens | Who does it |
|------|-------------|-------------|
| 1 | Developer pushes code to `main` | Human |
| 2 | CI builds Docker images, runs tests, scans for vulnerabilities | GitHub Actions |
| 3 | Images pushed to GHCR with SHA tag | GitHub Actions |
| 4 | CD workflow triggered after successful CI | GitHub Actions |
| 5 | Image tags updated in Kustomize overlay, committed to git | GitHub Actions |
| 6 | ArgoCD polls repo (every 3 min), detects new commit | ArgoCD |
| 7 | ArgoCD applies the diff to the cluster | ArgoCD |

---

## Image Tagging Strategy

Every image gets multiple tags for different purposes:

| Tag Format | Example | When Applied | Purpose |
|-----------|---------|--------------|---------|
| `sha-<commit>` | `sha-a1b2c3d` | Every push to main | Immutable, traceable — this is what runs in staging/prod |
| `latest` | `latest` | Every push to main | Convenience for dev, never used in staging/prod |
| `v1.2.3` | `v1.0.0` | GitHub Release created | Semantic version for communication |
| `v1.2` | `v1.0` | GitHub Release created | Minor version (useful for "latest patch") |
| `v1` | `v1` | GitHub Release created | Major version (careful with this) |

**Rule:** Staging and production ALWAYS use SHA tags. Never `latest`. The SHA gives you instant traceability — "what code is running?" → look at the tag → that's the exact commit.

### OCI Image Labels

Every image includes standard OCI metadata:

```
org.opencontainers.image.title=cart-service
org.opencontainers.image.source=https://github.com/bankolejohn/online-microservices-test
org.opencontainers.image.revision=a1b2c3d4e5f6789...
org.opencontainers.image.created=2026-07-21T10:30:00Z
```

Inspect labels with: `docker inspect ghcr.io/bankolejohn/online-shopping/cart-service:sha-a1b2c3d`

---

## Directory Structure

```
.github/
└── workflows/
    ├── ci.yaml                    # Build, test, scan, push
    └── cd.yaml                    # Update image tags (GitOps bridge)

argocd/
├── install.sh                     # ArgoCD installation script
├── appproject.yaml                # Project-level RBAC and permissions
├── application-staging.yaml       # Staging ArgoCD Application (auto-sync)
├── application-prod.yaml          # Production ArgoCD Application (manual sync)
└── rollback.sh                    # Rollback helper script

k8s/
├── base/                          # Shared manifests (the "what")
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── configmap.yaml
│   ├── secrets.yaml
│   ├── rbac.yaml
│   ├── network-policies.yaml
│   ├── resource-quota.yaml
│   ├── limit-range.yaml
│   ├── pod-disruption-budgets.yaml
│   ├── hpa.yaml
│   ├── ingress.yaml
│   ├── deployments/               # All 7 service deployments
│   └── services/                  # All 7 service definitions
└── overlays/                      # Environment-specific config (the "where")
    ├── dev/                       # Local Kind cluster (1 replica, local images)
    ├── staging/                   # Pre-prod (2 replicas, GHCR images, auto-deploy)
    └── prod/                      # Production (3 replicas, higher resources, manual deploy)
```

---

## CI Pipeline (`.github/workflows/ci.yaml`)

### Trigger Conditions

| Event | What happens |
|-------|-------------|
| Push to `main` | Full pipeline: lint → test → build → scan → push to GHCR |
| Pull request to `main` | Build + scan only (no push) — validates the image builds |
| Release published | Build + push with semver tags (`v1.0.0`, `v1.0`, `v1`) |

### Path Filtering

The CI only builds services that have changed. If you modify only `cart-service/`, only cart-service gets built. This saves time and compute.

If `.github/workflows/ci.yaml` itself changes, all services are rebuilt (ensures pipeline changes don't break anything).

### Pipeline Stages

```
┌──────────┐    ┌──────────┐    ┌──────────────┐    ┌───────┐    ┌──────┐
│  Detect  │───►│   Lint   │───►│    Build     │───►│ Scan  │───►│ Push │
│ Changes  │    │  & Test  │    │ Docker Image │    │ Trivy │    │ GHCR │
└──────────┘    └──────────┘    └──────────────┘    └───────┘    └──────┘
```

**Lint & Test** — language-specific:
- Node.js services: `npm ci` → `npm test` → `npm run lint`
- Python services: `pip install` → `flake8` → `pytest`
- Go services: `go vet` → `go test`

**Build** — uses Docker Buildx with GitHub Actions build cache for fast rebuilds.

**Scan** — Trivy vulnerability scanner checks for CRITICAL and HIGH CVEs. Results uploaded to GitHub Security tab (SARIF format). CRITICAL vulnerabilities fail the build.

**Push** — images pushed to `ghcr.io/bankolejohn/online-shopping/<service>:<tag>`.

### Concurrency

Only one CI run per branch at a time. If you push again while CI is running, the in-progress run is cancelled. This prevents wasted compute and race conditions.

---

## CD Pipeline (`.github/workflows/cd.yaml`)

### Staging — Automatic

Triggered automatically after CI succeeds on `main`. Updates the image tags in `k8s/overlays/staging/kustomization.yaml` and commits the change. ArgoCD picks it up within 3 minutes.

### Production — Manual Approval

Triggered via `workflow_dispatch` (manual button in GitHub Actions UI). Requires:
1. Selecting "production" as the target environment
2. Specifying the image tag (typically the SHA that's proven stable in staging)
3. GitHub Environment protection rules (configurable reviewers)

The workflow verifies all images exist in GHCR before updating the prod overlay.

### Why separate CI and CD?

- **CI is about building** — it produces artifacts (images)
- **CD is about deploying** — it updates the desired state in git
- Separating them means CI failures don't accidentally deploy, and you can re-run CD independently (e.g., rollback by re-deploying an older tag)

---

## ArgoCD (GitOps Controller)

### What ArgoCD Does

ArgoCD runs in the cluster and continuously compares:
- **Desired state** — what's in git (`k8s/overlays/staging/`)
- **Live state** — what's actually running in the cluster

If they differ, ArgoCD either auto-syncs (staging) or shows "OutOfSync" (production, waiting for manual sync).

### Installation

```bash
./argocd/install.sh
```

This installs ArgoCD v2.13.3, creates the AppProject and Applications, and prints the admin credentials.

Access the UI:
```bash
kubectl port-forward svc/argocd-server -n argocd 8443:443
# Open https://localhost:8443
```

### AppProject — Least Privilege

The `online-shopping` AppProject restricts:
- **Source repos** — only our GitHub repo
- **Destinations** — only the `shopping` namespace on this cluster
- **Resource types** — only the Kubernetes resources our app actually uses (no ability to create ClusterRoles, etc.)
- **RBAC roles** — `developer` (read + sync staging) and `admin` (full access)

### Staging Application (auto-sync)

```yaml
syncPolicy:
  automated:
    prune: true      # Delete resources removed from git
    selfHeal: true   # Revert manual kubectl changes
```

- **Prune** — if you remove a service from git, ArgoCD deletes it from the cluster
- **Self-heal** — if someone runs `kubectl scale deployment frontend --replicas=10`, ArgoCD reverts it to match git (git wins)
- **Retry** — if sync fails, retries 3 times with exponential backoff

### Production Application (manual sync)

- No `automated` sync policy — changes appear as "OutOfSync" in the UI
- Engineer reviews the diff in ArgoCD UI
- Engineer clicks "Sync" or runs `argocd app sync online-shopping-prod`
- If the deployment becomes unhealthy after sync, ArgoCD marks it degraded

### Ignored Differences

ArgoCD ignores:
- `/spec/replicas` on Deployments — because HPA manages this dynamically
- `/spec/clusterIP` on Services — Kubernetes assigns this, it's not in git

Without this, ArgoCD would constantly show "OutOfSync" for these fields.

---

## Kustomize Overlays

### Base (shared across all environments)

Contains the canonical deployment specs with bare image names (`image: cart-service`). No registry prefix, no tag — those are added by each overlay's `images` transformer.

### Dev Overlay

```yaml
# 1 replica per service (save resources locally)
# imagePullPolicy: Never (images loaded via `kind load`)
# Local image names (no GHCR prefix)
images:
  - name: cart-service
    newName: cart-service
    newTag: latest
```

Usage: `kubectl apply -k k8s/overlays/dev`

### Staging Overlay

```yaml
# 2 replicas (matches production topology for testing)
# GHCR images with SHA tags (updated by CD pipeline)
images:
  - name: cart-service
    newName: ghcr.io/bankolejohn/online-shopping/cart-service
    newTag: sha-a1b2c3d    # Updated automatically by CD pipeline
```

### Production Overlay

```yaml
# 3 replicas (higher availability)
# Higher HPA limits (maxReplicas: 8-10)
# Higher resource quotas (12 CPU, 12Gi memory)
# Same GHCR images, promoted from staging
images:
  - name: cart-service
    newName: ghcr.io/bankolejohn/online-shopping/cart-service
    newTag: sha-a1b2c3d    # Same tag that was proven in staging
```

---

## Operational Procedures

### Deploy to Staging (automatic)

Just push to `main`. The pipeline handles everything:
```bash
git add .
git commit -m "feat(cart): add quantity validation"
git push origin main
# CI builds → CD updates tag → ArgoCD syncs (within ~5 minutes)
```

### Deploy to Production (manual)

1. Verify staging is healthy: `argocd app get online-shopping-staging`
2. Get the current staging tag: check `k8s/overlays/staging/kustomization.yaml`
3. Trigger production deploy:
   - GitHub Actions UI → CD workflow → Run workflow → environment: production, tag: `sha-a1b2c3d`
4. ArgoCD shows OutOfSync → review diff → click Sync

### Rollback

**Option 1: ArgoCD rollback (immediate)**
```bash
./argocd/rollback.sh staging    # Roll back to previous revision
./argocd/rollback.sh prod 3     # Roll back to specific revision
```

**Option 2: Git revert (permanent, GitOps-correct)**
```bash
# Find the CD commit that updated the tag
git log --oneline k8s/overlays/staging/kustomization.yaml

# Revert it
git revert <commit-sha>
git push origin main
# ArgoCD auto-syncs to the previous image tag
```

Option 2 is preferred because it keeps git as the source of truth. Option 1 is faster for emergencies but ArgoCD may re-sync forward on the next poll cycle unless you also revert in git.

### Create a Release (semver)

```bash
git tag v1.0.0
git push origin v1.0.0
# Or use GitHub UI: Releases → Create Release → Tag: v1.0.0
```

This triggers CI with semver tags: the images get tagged `v1.0.0`, `v1.0`, and `v1` in addition to the SHA tag.

### Check What's Deployed

```bash
# What tag is running in staging?
grep "newTag" k8s/overlays/staging/kustomization.yaml

# What tag is running in production?
grep "newTag" k8s/overlays/prod/kustomization.yaml

# What commit does that tag correspond to?
# sha-a1b2c3d → commit a1b2c3d
git log --oneline a1b2c3d

# ArgoCD status
argocd app get online-shopping-staging
argocd app get online-shopping-prod
```

### Local Development (unchanged)

Your local workflow remains the same:
```bash
# Build and load into Kind
./build-all.sh

# Deploy locally
kubectl apply -k k8s/overlays/dev

# Or restart to pick up new images
kubectl rollout restart deployment -n shopping
```

---

## Security Considerations

| Concern | How it's handled |
|---------|-----------------|
| Image provenance | SHA tags trace exactly to a git commit |
| Vulnerability scanning | Trivy blocks CRITICAL CVEs in CI |
| Registry access | GHCR uses GITHUB_TOKEN (no extra secrets needed) |
| Deployment authorization | Prod requires manual approval (environment protection rules) |
| Drift detection | ArgoCD self-heal reverts unauthorized changes |
| Least privilege | AppProject restricts what ArgoCD can deploy where |
| Audit trail | Git history shows every deployment + who triggered it |

---

## Prerequisites and Setup

### GitHub Repository Settings

1. **Enable GHCR**: Settings → Packages → ensure container registry is enabled (it's on by default)
2. **Environment protection** (optional): Settings → Environments → create "production" → add required reviewers
3. **Branch protection**: Settings → Branches → `main` → require CI status checks to pass

### ArgoCD Installation

```bash
# Install ArgoCD in your Kind cluster
./argocd/install.sh

# Access the UI
kubectl port-forward svc/argocd-server -n argocd 8443:443

# Login (password printed by install script)
argocd login localhost:8443 --insecure --username admin --password '<printed-password>'
```

### Install ArgoCD CLI (optional)

```bash
brew install argocd
```

---

## Troubleshooting

### CI is not triggering

- Check path filters — changes must be in a service directory
- Check branch — CI only runs on `main` and PRs targeting `main`
- View Actions tab in GitHub for error details

### ArgoCD shows OutOfSync but won't sync

```bash
# Check sync status and errors
argocd app get online-shopping-staging

# Force a sync (use with caution)
argocd app sync online-shopping-staging --force

# Check for resource conflicts
argocd app diff online-shopping-staging
```

### Images not pulling in staging/prod

```bash
# Verify image exists in GHCR
docker manifest inspect ghcr.io/bankolejohn/online-shopping/cart-service:sha-a1b2c3d

# Check pod events
kubectl describe pod <pod-name> -n shopping | grep -A5 Events

# Common issue: imagePullPolicy set wrong or image tag doesn't exist
```

### ArgoCD health check failing

```bash
# Check which resources are unhealthy
argocd app resources online-shopping-staging --health-status Degraded

# Check pod logs
kubectl logs deployment/<service> -n shopping

# Check if resource quotas are blocking pod creation
kubectl describe resourcequota -n shopping
```

---

## CKA/CKS Relevance

| Exam Domain | What this covers |
|-------------|-----------------|
| CKA: Workloads & Scheduling (15%) | Deployments, rollback strategy, update strategy |
| CKA: Cluster Architecture (25%) | Kustomize, GitOps patterns, cluster state management |
| CKS: Supply Chain Security (20%) | Image scanning (Trivy), image signing, registry security |
| CKS: Minimize Microservice Vulnerabilities (20%) | Immutable images, least-privilege registry access |

---

## What's Different from Junior-Level

| Junior approach | Senior approach (what we built) |
|----------------|-------------------------------|
| `docker build` → `kubectl apply` | CI builds + pushes to registry → ArgoCD syncs |
| `image: service:latest` everywhere | SHA-pinned images, semver on releases |
| No visibility into what's deployed | `git log` shows full deployment history |
| Manual rollback (panic + guessing) | `argocd rollback` or `git revert` |
| Same config for all environments | Kustomize overlays: dev / staging / prod |
| "It works on my machine" | Same image binary flows through all environments |
| No vulnerability scanning | Trivy blocks CRITICAL CVEs before deploy |
| No drift detection | ArgoCD self-heal reverts unauthorized changes |
| Single point of failure (your laptop) | Pipeline runs in GitHub, deploys are reproducible |

---

## Next Steps (Phase 8)

- Image signing with cosign (cryptographic attestation)
- OPA Gatekeeper / Kyverno admission control (block unsigned images)
- Sealed Secrets (encrypt secrets in git)
- Chaos engineering (kill pods and validate ArgoCD self-heals)
- CKA/CKS exam prep with these tools
