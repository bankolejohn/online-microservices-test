# Best Practices & Real-World Workflow

## Why This Document Exists

Tutorials teach you tools. Jobs require process. The gap between "I can deploy to Kubernetes" and "I can own a production system" is filled by practices, patterns, and decisions that come from experience.

This document treats our microservices project as if it belongs to a real company — ShopCorp. Everything from here forward follows the same standards a senior DevOps engineer would enforce at a startup or mid-size engineering team.

---

## 1. Git Workflow (How Code Moves Through Environments)

### Branching Strategy: Trunk-Based Development

In a real company, you never push directly to `main`. Here's how it works:

```
main (production)
  │
  ├── feature/add-redis-cart        ← developer works here
  ├── feature/add-monitoring        ← another developer works here
  ├── fix/checkout-timeout          ← bug fix
  └── infra/add-network-policies    ← infrastructure change
```

**Rules**:
- `main` is always deployable. It represents what's running in production.
- All work happens on feature/fix/infra branches.
- Changes get into `main` via Pull Requests (PRs) that are reviewed.
- Branches are short-lived (1-3 days max). Long branches = merge pain.

**Naming conventions**:
```
feature/<description>    — new functionality
fix/<description>        — bug fixes
infra/<description>      — infrastructure/DevOps changes
docs/<description>       — documentation only
refactor/<description>   — code improvement, no behavior change
```

**For this project going forward**:
```bash
# Create a branch for your work
git checkout -b infra/add-network-policies

# Do your work, commit often with meaningful messages
git add .
git commit -m "feat(network): add deny-all default policy for shopping namespace"

# Push and create PR
git push -u origin infra/add-network-policies
gh pr create --title "Add NetworkPolicies for inter-service communication" \
  --body "## What\nRestricts traffic between services to only allowed paths.\n\n## Why\nZero-trust networking for CKS prep and production hardening."
```

### Commit Message Convention (Conventional Commits)

Every commit message follows this pattern:
```
<type>(<scope>): <short description>

<optional body explaining WHY, not what>
```

**Types**:
- `feat` — new feature or capability
- `fix` — bug fix
- `infra` — infrastructure/DevOps changes (Dockerfiles, K8s manifests, CI/CD)
- `docs` — documentation changes
- `refactor` — code change that doesn't fix a bug or add a feature
- `test` — adding or modifying tests
- `chore` — maintenance (dependency updates, cleanup)

**Examples**:
```
feat(cart): add Redis as shared session store
infra(k8s): add resource quotas to shopping namespace
fix(checkout): increase payment-service timeout to 15s
docs(phase2): add ConfigMap and Secrets documentation
```

**Why this matters**: At a company, your git history IS your changelog. When something breaks at 2am, the on-call engineer reads commit messages to understand what changed. "fixed stuff" helps nobody.

---

## 2. Environment Strategy (Dev → Staging → Production)

### The Three Environments

| Environment | Purpose | Who Uses It | K8s Namespace |
|-------------|---------|-------------|---------------|
| Development | Rapid iteration, breaking is OK | Individual developers | `shopping-dev` |
| Staging | Pre-production validation, mirrors prod | QA team, product owners | `shopping-staging` |
| Production | Real users, real money | Everyone (read), SREs (write) | `shopping-prod` |

**In Kubernetes, this maps to**:
```yaml
# dev
kubectl apply -k overlays/dev/

# staging
kubectl apply -k overlays/staging/

# production
kubectl apply -k overlays/prod/
```

Using Kustomize overlays (we'll implement this in a later phase), you keep one base configuration and override per environment:
```
k8s/
├── base/                    # Shared configuration
│   ├── deployment.yaml
│   ├── service.yaml
│   └── kustomization.yaml
├── overlays/
│   ├── dev/                 # 1 replica, debug logging, relaxed limits
│   │   └── kustomization.yaml
│   ├── staging/             # 2 replicas, mirrors prod config
│   │   └── kustomization.yaml
│   └── prod/                # 3 replicas, strict limits, monitoring
│       └── kustomization.yaml
```

**For this project**: We're using minikube (development). As we progress, we'll build the overlay structure so you understand how configuration changes between environments without duplicating manifests.

---

## 3. How to Approach Each Phase (Engineering Process)

When a senior DevOps engineer gets a task, they don't just start typing. Here's the actual process:

### Step 1: Understand the Requirement
- What problem does this solve?
- Who is affected if it breaks?
- What's the blast radius?

### Step 2: Research & Design
- How have others solved this?
- What are the options? (At least 2-3 approaches)
- What are the trade-offs?
- Document the decision (Architecture Decision Record)

### Step 3: Implement in Dev
- Work on a branch
- Test locally (minikube)
- Write the documentation as you go (not after)

### Step 4: Review
- Create a PR with context (what, why, how to test)
- Get at least one review (in our case, self-review by re-reading after 30 minutes)

### Step 5: Test in Staging
- Apply to a staging environment
- Run smoke tests
- Check monitoring/logs

### Step 6: Deploy to Production
- Use GitOps (ArgoCD) or CI/CD pipeline
- Monitor the rollout
- Be ready to rollback

### Step 7: Document & Close
- Update runbooks if needed
- Close the ticket/issue
- Share learnings with the team

**For this project**: We follow this at a lighter scale. Each phase gets:
1. A branch (once we start using branches)
2. Implementation + documentation
3. Testing with validation commands
4. Commit + push with clear message

---

## 4. Naming Conventions & Labels

### Resource Naming

```yaml
# Format: <service-name>
# Examples:
name: cart-service
name: payment-service
name: user-authentication-service

# NOT:
name: cart            # too vague
name: cartService     # no camelCase in K8s
name: my-cart-svc     # no abbreviations
```

### Kubernetes Labels (Standard)

Every resource should have these labels:
```yaml
labels:
  app.kubernetes.io/name: cart-service          # What is this?
  app.kubernetes.io/component: backend          # frontend/backend/database
  app.kubernetes.io/part-of: online-shopping    # Which application?
  app.kubernetes.io/managed-by: kustomize       # How is it deployed?
  app.kubernetes.io/version: "1.0.0"            # What version?
```

**Why labels matter**:
- Querying: `kubectl get pods -l app.kubernetes.io/component=backend`
- Monitoring: Grafana dashboards filter by label
- NetworkPolicies: "Allow traffic only from Pods with label X"
- Cost allocation: "How much does the frontend cost us?"

### Docker Image Tagging

```bash
# Never use :latest in production
# It's non-deterministic — you don't know which version is running

# Good patterns:
frontend-service:1.2.3            # Semantic version
frontend-service:abc1234          # Git commit SHA (most common in CI/CD)
frontend-service:2026-07-08       # Date-based

# For local development, :latest is fine (minikube)
frontend-service:latest
```

---

## 5. Security Practices (Day 1)

These aren't "nice to have" — they're expected from day 1 at any serious company:

### Never put secrets in code or manifests
```yaml
# BAD — hardcoded in deployment.yaml
env:
- name: JWT_SECRET
  value: "my-secret-key"

# GOOD — referenced from a Secret
env:
- name: JWT_SECRET
  valueFrom:
    secretKeyRef:
      name: auth-secrets
      key: jwt-secret
```

### Run containers as non-root
```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
```

### Scan images for vulnerabilities
```bash
# Before deploying, scan with Trivy
trivy image frontend-service:latest
```

### Restrict network traffic (zero-trust)
```yaml
# Default: deny all ingress traffic
kind: NetworkPolicy
spec:
  podSelector: {}
  policyTypes:
  - Ingress
```

Then explicitly allow only what's needed.

### Use resource limits on everything
```yaml
resources:
  requests:
    memory: "128Mi"    # Guaranteed minimum
    cpu: "100m"
  limits:
    memory: "256Mi"    # Hard ceiling
    cpu: "200m"
```

Without limits, one runaway Pod can starve the entire node.

---

## 6. Observability (The Three Pillars)

A senior DevOps engineer doesn't deploy something and walk away. They ensure they can answer: "Is it working? If not, why not?"

### Metrics (What's happening right now?)
- CPU/memory usage per pod
- Request rate, error rate, latency (RED method)
- Queue depths, connection pools

**Tool**: Prometheus + Grafana

### Logs (What happened in the past?)
- Structured JSON logs (not plain text)
- Centralized log aggregation
- Correlation IDs across services

**Tool**: Loki + Grafana or ELK stack

### Traces (How did a request flow through the system?)
- End-to-end request tracing across all 7 services
- Where is the latency? Which service is slow?

**Tool**: Jaeger + OpenTelemetry

**For this project**: We'll add these in Phase 5 (Observability). You'll be able to watch a single checkout request flow from frontend → checkout → payment → shipping in Jaeger.

---

## 7. Incident Response Mindset

When something breaks in production, a senior engineer doesn't panic. They follow a process:

### 1. Detect
How do you know something is wrong?
- Alerts from monitoring (PagerDuty/OpsGenie)
- Customer reports
- Error rate spike in dashboard

### 2. Triage
How bad is it?
- Full outage? Partial? Performance degradation?
- How many users affected?
- Is it getting worse?

### 3. Mitigate (don't fix, mitigate)
Stop the bleeding first:
```bash
# Rollback to the last known good version
kubectl rollout undo deployment/checkout-service

# Scale up if traffic is overwhelming
kubectl scale deployment/frontend-service --replicas=5

# If one pod is bad, delete it (Deployment recreates)
kubectl delete pod checkout-service-xxx
```

### 4. Fix
Now find and fix the root cause:
```bash
# Check what changed
git log --oneline -10

# Check pod events
kubectl describe pod <name>

# Check logs
kubectl logs deployment/checkout-service --since=30m
```

### 5. Post-mortem
After the incident:
- What happened? (Timeline)
- Why did it happen? (Root cause)
- How did we detect it? (Monitoring gap?)
- How do we prevent it? (Action items)

**For this project**: As we intentionally break things in later phases (fault injection, chaos engineering), you'll practice this exact response loop.

---

## 8. Documentation Standards

### Every Phase Gets
1. **Overview** — What are we doing and why
2. **Architecture diagram** — Visual of what changes
3. **Step-by-step guide** — Reproducible commands
4. **Testing/Validation** — How to verify it works
5. **Troubleshooting** — Common issues and fixes
6. **CKA/CKS relevance** — What exam domains this covers

### Every Decision Gets
A lightweight ADR (Architecture Decision Record):
```markdown
## Decision: Use nginx as the Ingress Controller

**Context**: We need external traffic routing to our services.
**Options considered**:
1. nginx Ingress Controller (widely used, CKA tested)
2. Traefik (lighter, auto-config)
3. AWS ALB Ingress Controller (cloud-specific)

**Decision**: nginx — it's the most widely used, tested in CKA, and well-documented.
**Consequences**: Need to manage nginx config/annotations. Not cloud-native.
```

---

## 9. The Senior DevOps Engineer Checklist

Before declaring any phase "done", verify:

- [ ] **It works** — tested with actual requests, not just "pods are running"
- [ ] **It's documented** — someone else could reproduce it
- [ ] **It's version controlled** — committed with a meaningful message
- [ ] **It's secure** — no plaintext secrets, no root containers (later phases)
- [ ] **It's observable** — you can tell if it's healthy without exec-ing into pods
- [ ] **It's recoverable** — you know how to rollback
- [ ] **It's scalable** — you know what happens if traffic 10x's
- [ ] **It handles failure** — you know what happens if a pod dies

This is the bar. Not just "it deploys" — but "I would trust this in production at 2am."

---

## 10. Project Structure (Final Target)

By the end of all phases, the project will look like:

```
online-microservices-test/
├── docs/                              # Learning documentation
│   ├── 00-best-practices-and-workflow.md
│   ├── 01-docker-compose-setup.md
│   ├── 02-kubernetes-deployment.md
│   ├── 03-configmaps-secrets-namespaces.md
│   ├── 04-network-policies-rbac.md
│   ├── 05-observability-monitoring.md
│   ├── 06-istio-service-mesh.md
│   ├── 07-cicd-gitops.md
│   └── 08-production-hardening.md
├── k8s/
│   ├── base/                          # Base manifests
│   └── overlays/                      # Per-environment overrides
│       ├── dev/
│       ├── staging/
│       └── prod/
├── helm/                              # Helm charts (alternative to Kustomize)
├── terraform/                         # Infrastructure as Code
├── .github/
│   └── workflows/                     # CI/CD pipelines
├── monitoring/
│   ├── prometheus/
│   ├── grafana/
│   └── alerts/
├── istio/                             # Service mesh configuration
│   ├── virtual-services/
│   ├── destination-rules/
│   └── authorization-policies/
├── frontend-service/
├── product-catalog-service/
├── cart-service/
├── user-authentication-service/
├── checkout-service/
├── payment-service/
├── shipping-service/
├── docker-compose.yml
├── kustomization.yaml
└── README.md
```

---

## 11. How to Use This Project in Interviews

When a recruiter or hiring manager asks about your Kubernetes experience, here's how this project maps to real answers:

| Interview Question | Your Answer (backed by this project) |
|-------------------|--------------------------------------|
| "Have you deployed to Kubernetes?" | "Yes — 7 microservices with Deployments, Services, Ingress, health probes, and resource limits." |
| "How do you handle service-to-service communication?" | "Kubernetes DNS for internal routing, with the option of Istio for mTLS and traffic management." |
| "How do you manage configuration?" | "ConfigMaps for non-sensitive config, Secrets (encrypted at rest) for credentials, with env-specific overlays via Kustomize." |
| "How do you handle security?" | "NetworkPolicies for zero-trust networking, RBAC for least-privilege access, Pod Security Standards, and image scanning with Trivy." |
| "How do you monitor your services?" | "Prometheus for metrics, Grafana for dashboards, Loki for logs, Jaeger for distributed tracing." |
| "How do you deploy changes?" | "GitOps with ArgoCD — push to git, ArgoCD syncs to cluster. Canary deployments via Istio VirtualServices." |
| "Tell me about an incident you handled." | Describe the cart-service statelessness issue, how you identified it (GETs returning empty), root cause (in-memory + multiple replicas), and fix (Redis/session affinity). |

---

## Summary

The difference between a junior and senior DevOps engineer isn't just technical knowledge — it's:

1. **Process discipline** — branches, PRs, commit messages, documentation
2. **Security mindset** — assume breach, least privilege, zero trust
3. **Observability** — if you can't measure it, you can't manage it
4. **Incident readiness** — knowing what to do when (not if) things break
5. **Communication** — documenting decisions, explaining trade-offs, writing runbooks

Every phase from here forward follows these practices. By the end, you won't just know Kubernetes — you'll know how to operate it like someone who's been doing it for years.
