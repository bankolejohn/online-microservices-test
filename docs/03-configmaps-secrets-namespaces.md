# Phase 2: ConfigMaps, Secrets, and Namespaces

## Overview

This phase separates configuration from code — a fundamental principle in production Kubernetes. We extract hardcoded values from deployment manifests into dedicated ConfigMap and Secret resources, and organize all resources under a dedicated namespace.

**What we did**:
- Created a `shopping` namespace to isolate our application
- Extracted service ports and URLs into a ConfigMap
- Moved the JWT secret into a Kubernetes Secret
- Updated all deployments to reference these external configurations

**Why this matters**:
- Same container image can run in dev/staging/prod with different configs
- Secrets are managed separately from application code (access control, rotation)
- Namespaces provide isolation, resource quotas, and RBAC boundaries
- Changes to configuration don't require rebuilding container images

---

## Core Concepts

### Namespace

**What**: A virtual partition within a Kubernetes cluster. Resources in different namespaces are logically isolated.

**Why**:
- **Organization** — group related resources (all shopping app resources together)
- **Access control** — RBAC policies can restrict access per namespace
- **Resource quotas** — limit how much CPU/memory a namespace can consume
- **Name scoping** — two namespaces can each have a Service called `cart-service` without conflict

**Real-world usage**:
```
Cluster
├── shopping-dev          ← development environment
├── shopping-staging      ← pre-production
├── shopping-prod         ← production
├── monitoring            ← Prometheus, Grafana
├── istio-system          ← service mesh control plane
├── ingress-nginx         ← ingress controller
└── cert-manager          ← TLS certificate automation
```

**Key commands**:
```bash
# List all namespaces
kubectl get namespaces

# List resources in a specific namespace
kubectl get pods -n shopping

# Set a default namespace (so you don't type -n every time)
kubectl config set-context --current --namespace=shopping

# List resources across ALL namespaces
kubectl get pods --all-namespaces
# or shorthand:
kubectl get pods -A
```

---

### ConfigMap

**What**: A Kubernetes resource that stores non-sensitive configuration data as key-value pairs. Pods can consume ConfigMaps as environment variables or mounted files.

**Why**:
- Decouple configuration from container images
- Change config without rebuilding/redeploying containers
- Share common config across multiple services
- Environment-specific values (dev uses different URLs than prod)

**When to use ConfigMap vs Secret**:
| Data Type | Use |
|-----------|-----|
| Service URLs, ports, feature flags | ConfigMap |
| Database connection strings (without password) | ConfigMap |
| Passwords, API keys, tokens | Secret |
| TLS certificates | Secret |

**Our ConfigMap** (`k8s/configmap.yaml`):
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: service-config
  labels:
    app.kubernetes.io/part-of: online-shopping
    app.kubernetes.io/managed-by: kustomize
data:
  # Service ports
  PRODUCT_CATALOG_PORT: "3001"
  CART_PORT: "3002"
  AUTH_PORT: "3003"
  CHECKOUT_PORT: "5001"
  PAYMENT_PORT: "5002"
  SHIPPING_PORT: "8080"

  # Inter-service URLs
  CART_SERVICE_URL: "http://cart-service:3002"
  PAYMENT_SERVICE_URL: "http://payment-service:5002"
  SHIPPING_SERVICE_URL: "http://shipping-service:8080"
```

**How pods consume it** (individual keys):
```yaml
env:
- name: PORT
  valueFrom:
    configMapKeyRef:
      name: service-config      # Which ConfigMap
      key: CHECKOUT_PORT        # Which key within it
```

**Alternative: inject ALL keys at once** (not used here, but good to know):
```yaml
envFrom:
- configMapRef:
    name: service-config
# This injects EVERY key from the ConfigMap as an env var
```

---

### Secret

**What**: A Kubernetes resource that stores sensitive data (passwords, tokens, keys). Similar to ConfigMap but with additional protections.

**Why**:
- Separates sensitive data from pod specs and container images
- Can be encrypted at rest (with proper cluster configuration)
- Access can be restricted via RBAC (only specific ServiceAccounts can read specific Secrets)
- Avoids committing credentials to git

**Critical understanding**: Base64 is NOT encryption. Secrets are base64-encoded by default, which is trivially reversible. The real security comes from:
1. RBAC — restricting who can `kubectl get secrets`
2. Encryption at rest — encrypting etcd storage
3. External secrets managers — Vault, AWS Secrets Manager, etc.

**Our Secret** (`k8s/secrets.yaml`):
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: auth-secrets
type: Opaque
data:
  # echo -n "super-secret-jwt-key-for-shopping-app-2026" | base64
  jwt-secret: c3VwZXItc2VjcmV0LWp3dC1rZXktZm9yLXNob3BwaW5nLWFwcC0yMDI2
```

**How pods consume it**:
```yaml
env:
- name: JWT_SECRET
  valueFrom:
    secretKeyRef:
      name: auth-secrets       # Which Secret
      key: jwt-secret          # Which key within it
```

**Encoding and decoding**:
```bash
# Encode a value
echo -n "my-password" | base64
# Output: bXktcGFzc3dvcmQ=

# Decode a value
echo "bXktcGFzc3dvcmQ=" | base64 --decode
# Output: my-password

# View a secret's decoded value directly
kubectl get secret auth-secrets -n shopping -o jsonpath='{.data.jwt-secret}' | base64 --decode
```

---

## What We Changed

### Before (Phase 1) — Hardcoded values in deployments:
```yaml
# checkout-service/k8s/deployment.yaml (BEFORE)
env:
- name: PORT
  value: "5001"                              # Hardcoded
- name: CART_SERVICE_URL
  value: "http://cart-service:3002"          # Hardcoded
- name: PAYMENT_SERVICE_URL
  value: "http://payment-service:5002"       # Hardcoded

# user-authentication-service/k8s/deployment.yaml (BEFORE)
env:
- name: JWT_SECRET
  value: "your-jwt-secret-key"              # SECRET IN PLAIN TEXT!
```

### After (Phase 2) — References to ConfigMap/Secret:
```yaml
# checkout-service/k8s/deployment.yaml (AFTER)
env:
- name: PORT
  valueFrom:
    configMapKeyRef:
      name: service-config
      key: CHECKOUT_PORT
- name: CART_SERVICE_URL
  valueFrom:
    configMapKeyRef:
      name: service-config
      key: CART_SERVICE_URL

# user-authentication-service/k8s/deployment.yaml (AFTER)
env:
- name: JWT_SECRET
  valueFrom:
    secretKeyRef:
      name: auth-secrets
      key: jwt-secret
```

### Kustomization — Namespace injection:
```yaml
# kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: shopping    # ← This line injects namespace into ALL resources

resources:
  - k8s/namespace.yaml
  - k8s/configmap.yaml
  - k8s/secrets.yaml
  - frontend-service/k8s/deployment.yaml
  # ... etc
```

The `namespace: shopping` field in kustomization.yaml means you don't need to add `namespace: shopping` to every individual manifest. Kustomize injects it automatically during `kubectl apply -k .`

---

## File Structure After Phase 2

```
online-microservices-test/
├── k8s/
│   ├── namespace.yaml          # NEW: Namespace definition
│   ├── configmap.yaml          # NEW: Service configuration
│   └── secrets.yaml            # NEW: Sensitive credentials
├── kustomization.yaml          # UPDATED: Added namespace + new resources
├── frontend-service/k8s/
│   └── deployment.yaml         # UPDATED: Added labels
├── product-catalog-service/k8s/
│   └── deployment.yaml         # UPDATED: PORT from ConfigMap
├── cart-service/k8s/
│   └── deployment.yaml         # UPDATED: PORT from ConfigMap
├── user-authentication-service/k8s/
│   └── deployment.yaml         # UPDATED: PORT from ConfigMap, JWT from Secret
├── checkout-service/k8s/
│   └── deployment.yaml         # UPDATED: PORT + 3 URLs from ConfigMap
├── payment-service/k8s/
│   └── deployment.yaml         # UPDATED: PORT from ConfigMap
└── shipping-service/k8s/
    └── deployment.yaml         # UPDATED: PORT from ConfigMap
```

---

## Deployment & Validation

### Deploy

```bash
# Apply all resources (namespace, configmap, secret, deployments, services, ingress)
kubectl apply -k .

# Expected output:
# namespace/shopping created
# configmap/service-config created
# secret/auth-secrets created
# service/cart-service created
# ... (all services)
# deployment.apps/cart-service created
# ... (all deployments)
# ingress.networking.k8s.io/shopping-ingress created
```

### Verify Resources

```bash
# Check all pods are running in the shopping namespace
kubectl get pods -n shopping
# All 14 should be READY 1/1, STATUS Running

# Verify ConfigMap exists and has correct data
kubectl get configmap service-config -n shopping -o yaml

# Verify Secret exists (don't print the value in logs!)
kubectl get secret auth-secrets -n shopping
```

### Verify Env Vars Are Injected

```bash
# Check checkout-service gets its URLs from ConfigMap
kubectl exec -n shopping deployment/checkout-service -- env | grep -E "(PORT|SERVICE_URL)"
# Expected:
# PORT=5001
# CART_SERVICE_URL=http://cart-service:3002
# PAYMENT_SERVICE_URL=http://payment-service:5002
# SHIPPING_SERVICE_URL=http://shipping-service:8080

# Check auth-service gets JWT_SECRET from Secret (verify first 10 chars only)
kubectl exec -n shopping deployment/user-authentication-service -- sh -c 'echo ${JWT_SECRET}' | cut -c1-10
# Expected: super-secr
```

### Test End-to-End

```bash
# Port-forward to frontend
kubectl port-forward -n shopping service/frontend-service 8888:80

# In another terminal:

# Test products
curl -s http://localhost:8888/api/products | python3 -c \
  "import sys,json; print(f'{len(json.load(sys.stdin))} products OK')"

# Test registration (proves JWT_SECRET from Secret works)
curl -s -X POST http://localhost:8888/api/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"phase2@test.com","password":"pass123","name":"Phase2 User"}'

# Test checkout (proves service URLs from ConfigMap work)
curl -s -X POST http://localhost:8888/api/checkout \
  -H "Content-Type: application/json" \
  -d '{
    "userId": "test",
    "items": [{"productId":1,"name":"Headphones","price":199.99,"quantity":1}],
    "total": 199.99,
    "shippingAddress": {"address":"1 Namespace Blvd","city":"ConfigCity","zipCode":"CM001"},
    "paymentDetails": {"cardNumber":"4242424242424242","expiryDate":"12/28","cvv":"321"}
  }'
# Expected: {"orderId":"...","status":"confirmed","trackingNumber":"..."}
```

---

## Troubleshooting

### Issue: Pod stuck in `CreateContainerConfigError`

**Symptom**:
```
NAME                    READY   STATUS                       RESTARTS   AGE
cart-service-xxx        0/1     CreateContainerConfigError   0          30s
```

**Root cause**: The pod references a ConfigMap or Secret that doesn't exist.

**Diagnosis**:
```bash
kubectl describe pod <pod-name> -n shopping
# Look for events like:
# Error: configmap "service-config" not found
# Error: secret "auth-secrets" not found
```

**Fix**: Ensure the ConfigMap/Secret is created in the same namespace as the pod:
```bash
kubectl get configmap -n shopping
kubectl get secret -n shopping
```

### Issue: Env var is empty in the pod

**Symptom**: Application logs show empty config values.

**Diagnosis**:
```bash
# Check the actual env in the running pod
kubectl exec -n shopping deployment/checkout-service -- env | grep PORT

# Verify the ConfigMap has the expected key
kubectl get configmap service-config -n shopping -o jsonpath='{.data.CHECKOUT_PORT}'
```

**Common causes**:
- Typo in the `key` field (case-sensitive)
- ConfigMap/Secret name mismatch
- ConfigMap updated but pod not restarted (env vars are set at pod creation time)

### Issue: ConfigMap updated but pods still use old values

**Root cause**: Environment variables from ConfigMaps are injected at pod startup. Updating a ConfigMap does NOT automatically update running pods.

**Fix**: Restart the deployment to pick up new values:
```bash
kubectl rollout restart deployment/checkout-service -n shopping
```

**Pro tip**: In production, use immutable ConfigMaps with unique names (e.g., `service-config-v2`) and update the deployment to reference the new name. This triggers a rolling update automatically.

---

## Real-World Considerations

### What We'd Do Differently in Production

| This Project | Production |
|-------------|------------|
| Secret in YAML file committed to git | External Secrets Operator fetching from HashiCorp Vault or AWS Secrets Manager |
| Single ConfigMap for all services | Per-service ConfigMaps for independent lifecycle |
| Manual `kubectl apply` | GitOps (ArgoCD) auto-syncs from git |
| One namespace | Separate namespaces per environment (shopping-dev, shopping-prod) |
| No encryption at rest | etcd encryption enabled for Secrets |

### Secrets Management Progression (Maturity Levels)

| Level | Approach | Security |
|-------|----------|----------|
| 1 (Bad) | Hardcoded in deployment YAML | Anyone with repo access sees credentials |
| 2 (Current) | Kubernetes Secret (base64) | Better — requires K8s RBAC to access |
| 3 (Good) | Sealed Secrets / SOPS | Encrypted in git, decrypted at deploy time |
| 4 (Best) | External Secrets + Vault | Dynamic secrets, auto-rotation, audit logging |

### ConfigMap Best Practices

1. **Name clearly** — `service-config`, not `config` or `cm1`
2. **Label everything** — `app.kubernetes.io/part-of: online-shopping`
3. **Don't put secrets in ConfigMaps** — even "non-sensitive" database hostnames can be sensitive
4. **Consider immutable ConfigMaps** — set `immutable: true` to prevent accidental changes
5. **Keep them small** — ConfigMaps have a 1MB limit. Use volume mounts for large configs.

---

## kubectl Commands Reference (CKA Relevant)

```bash
# ConfigMaps
kubectl create configmap my-config --from-literal=key1=value1 --from-literal=key2=value2
kubectl create configmap my-config --from-file=config.properties
kubectl get configmap service-config -n shopping -o yaml
kubectl edit configmap service-config -n shopping
kubectl delete configmap service-config -n shopping

# Secrets
kubectl create secret generic my-secret --from-literal=password=s3cr3t
kubectl create secret tls my-tls --cert=cert.pem --key=key.pem
kubectl get secret auth-secrets -n shopping -o jsonpath='{.data.jwt-secret}' | base64 -d
kubectl delete secret auth-secrets -n shopping

# Namespaces
kubectl create namespace shopping
kubectl get namespaces
kubectl delete namespace shopping    # WARNING: deletes ALL resources in it

# Context (default namespace)
kubectl config set-context --current --namespace=shopping
kubectl config view --minify | grep namespace
```

---

## CKA Exam Relevance

| Domain | What We Practiced |
|--------|-------------------|
| Cluster Architecture (25%) | Namespaces, kustomize, resource organization |
| Workloads & Scheduling (15%) | Deployment env vars, configMapKeyRef, secretKeyRef |
| Troubleshooting (30%) | Diagnosing CreateContainerConfigError, checking env vars |

**CKA exam tips for this topic**:
- You'll be asked to create ConfigMaps and Secrets imperatively (using `kubectl create`)
- Know both `--from-literal` and `--from-file` approaches
- Know how to mount a ConfigMap as a volume (not just env vars)
- Know how to decode a Secret: `kubectl get secret X -o jsonpath='{.data.key}' | base64 -d`

---

## Next Steps (Phase 3)

With configuration externalized, the next phase adds:
- **NetworkPolicies** — restrict which services can communicate (zero-trust)
- **RBAC** — ServiceAccounts with least-privilege access per service
- **Resource Quotas** — limit what the shopping namespace can consume
