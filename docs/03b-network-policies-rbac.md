# Phase 3: NetworkPolicies and RBAC

## Overview

This phase implements zero-trust networking and least-privilege access control — two pillars of Kubernetes security that every production cluster needs and both CKA/CKS exams test heavily.

**What we did**:
- Created a default-deny NetworkPolicy (blocks ALL traffic by default)
- Added 7 allow-policies for each service's legitimate communication paths
- Created ServiceAccounts for each service (no more default SA)
- Implemented RBAC Roles and RoleBindings for config/secret access
- Added `automountServiceAccountToken: false` to services that don't need API access

**Why this matters**:
- If an attacker compromises one pod, they can't reach other services (lateral movement blocked)
- Services can only read the secrets they need (no shared access)
- Follows the principle of least privilege — the foundation of all security

---

## Core Concepts

### NetworkPolicy

**What**: A Kubernetes resource that controls traffic flow between pods. It acts as a firewall at the pod level.

**Why**: By default, ALL pods in a cluster can talk to ALL other pods. This is like having no walls in an office building — anyone can walk into any room. NetworkPolicies add walls and doors.

**How it works**:
1. Without any NetworkPolicy → all traffic allowed (wide open)
2. Once you create ANY NetworkPolicy that selects a pod → all traffic TO that pod is denied EXCEPT what the policy allows
3. This is an "additive" model — you add rules to allow traffic, never to deny it

**Critical understanding**: NetworkPolicies are ONLY enforced if your CNI supports them. That's why we installed Calico.

### The Zero-Trust Model

```
Traditional (castle-and-moat):    Zero-Trust:
┌────────────────────────┐        ┌────────────────────────┐
│  Firewall              │        │  Every pod has its     │
│  ┌──────────────────┐  │        │  own firewall          │
│  │ Everything trusts │  │        │  ┌──┐ ┌──┐ ┌──┐      │
│  │ everything inside │  │        │  │🔒│ │🔒│ │🔒│      │
│  └──────────────────┘  │        │  └──┘ └──┘ └──┘      │
└────────────────────────┘        └────────────────────────┘
"Once you're in, you're in"       "Prove you're allowed, every time"
```

### RBAC (Role-Based Access Control)

**What**: Controls WHO can do WHAT on WHICH resources in Kubernetes.

**Components**:
- **ServiceAccount** — an identity for a pod (like a user account, but for applications)
- **Role** — a set of permissions (e.g., "can read ConfigMaps")
- **RoleBinding** — connects a ServiceAccount to a Role ("this pod gets these permissions")

**Why**: By default, pods may use the `default` ServiceAccount which could have broad permissions. Creating dedicated SAs with minimal rights limits what an attacker can do if they compromise a pod.

---

## Communication Map (What Talks to What)

Before writing policies, you MUST map your service dependencies:

```
┌─────────────────────────────────────────────────────────────┐
│                     shopping namespace                        │
│                                                              │
│  [Ingress] ───→ [Frontend :80] ───┬──→ [Product Catalog :3001]
│                                    ├──→ [Cart :3002]
│                                    ├──→ [Auth :3003]
│                                    ├──→ [Checkout :5001]
│                                    ├──→ [Payment :5002]
│                                    └──→ [Shipping :8080]
│                                         │
│                   [Checkout :5001] ──────┼──→ [Payment :5002]
│                                         ├──→ [Shipping :8080]
│                                         └──→ [Cart :3002]
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

**What's NOT allowed** (examples):
- shipping → auth (why would shipping need authentication data?)
- product-catalog → payment (products don't process payments)
- cart → shipping (cart doesn't create shipments)
- payment → anything (payment only receives requests, never initiates)

---

## Implementation

### Step 1: Default Deny All (The Lock)

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: shopping
spec:
  podSelector: {}       # Empty = ALL pods
  policyTypes:
  - Ingress             # Block all incoming traffic
```

After this is applied, **nothing can reach anything** in the namespace. Every service is isolated.

### Step 2: Allow Specific Paths (The Keys)

Example — allow frontend to reach product-catalog:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-product-catalog-from-frontend
  namespace: shopping
spec:
  podSelector:
    matchLabels:
      app: product-catalog-service     # WHO is being protected
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: frontend-service        # WHO is allowed in
    ports:
    - protocol: TCP
      port: 3001                       # WHICH port
```

**Reading this in plain English**: "Allow TCP traffic on port 3001 to any pod labeled `app: product-catalog-service` ONLY from pods labeled `app: frontend-service`"

### Step 3: ServiceAccounts (Identity Per Service)

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cart-sa
  namespace: shopping
```

Then in the deployment:
```yaml
spec:
  template:
    spec:
      serviceAccountName: cart-sa
      automountServiceAccountToken: false   # Don't mount K8s API token
```

`automountServiceAccountToken: false` is critical — if a pod doesn't need to talk to the Kubernetes API (most application pods don't), don't give it the ability to. An attacker who gets shell in that pod can't use `kubectl` or the K8s API.

### Step 4: RBAC Roles (Permissions)

```yaml
# Role: what actions are allowed
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: config-reader
  namespace: shopping
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["auth-secrets"]   # Only THIS specific secret
  verbs: ["get"]

---
# RoleBinding: who gets the permissions
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: auth-config-reader
  namespace: shopping
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: config-reader
subjects:
- kind: ServiceAccount
  name: auth-sa
  namespace: shopping
```

---

## Testing & Validation

### Test Allowed Paths Work

```bash
# Port-forward to frontend
kubectl port-forward -n shopping service/frontend-service 8888:80

# Products (frontend → product-catalog): SHOULD WORK
curl -s http://localhost:8888/api/products | python3 -c \
  "import sys,json; print(f'{len(json.load(sys.stdin))} products OK')"

# Register (frontend → auth): SHOULD WORK
curl -s -X POST http://localhost:8888/api/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"test@x.com","password":"p","name":"T"}'

# Checkout (frontend → checkout → payment + shipping): SHOULD WORK
curl -s -X POST http://localhost:8888/api/checkout \
  -H "Content-Type: application/json" \
  -d '{"userId":"t","items":[{"productId":1,"name":"X","price":10,"quantity":1}],"total":10,"shippingAddress":{"address":"x","city":"x","zipCode":"x"},"paymentDetails":{"cardNumber":"4242424242424242","expiryDate":"12/28","cvv":"1"}}'
```

### Test Blocked Paths (Proving Zero-Trust)

```bash
# From shipping pod, try to reach auth: SHOULD TIMEOUT (BLOCKED)
kubectl exec -n shopping deployment/shipping-service -- \
  wget --timeout=3 -qO- http://user-authentication-service:3003/health
# Expected: "wget: download timed out"

# From product-catalog pod, try to reach payment: SHOULD TIMEOUT (BLOCKED)
kubectl exec -n shopping deployment/product-catalog-service -- \
  wget --timeout=3 -qO- http://payment-service:5002/health
# Expected: "wget: download timed out"
```

### Test Allowed Internal Paths

```bash
# From checkout, reach payment: SHOULD WORK (allowed by policy)
kubectl exec -n shopping deployment/checkout-service -- \
  python3 -c "import urllib.request; print(urllib.request.urlopen('http://payment-service:5002/health', timeout=3).read().decode())"
# Expected: {"service":"payment-service","status":"healthy"}

# From checkout, reach shipping: SHOULD WORK (allowed by policy)
kubectl exec -n shopping deployment/checkout-service -- \
  python3 -c "import urllib.request; print(urllib.request.urlopen('http://shipping-service:8080/health', timeout=3).read().decode())"
# Expected: {"service":"shipping-service","status":"healthy"}
```

### Verify ServiceAccounts

```bash
# Check each pod uses its dedicated ServiceAccount
kubectl get pods -n shopping -o custom-columns='POD:metadata.name,SA:spec.serviceAccountName' | head -10

# Verify automountServiceAccountToken is disabled
kubectl get pod -n shopping -l app=cart-service -o jsonpath='{.items[0].spec.automountServiceAccountToken}'
# Expected: false
```

---

## Troubleshooting

### Pods stuck in CrashLoopBackOff after applying NetworkPolicies

**Symptom**: Liveness probes failing, pods restarting.

**Root cause**: Kubelet health checks come from the node IP, not from another pod. Most CNIs (including Calico) allow kubelet probes by default. If yours doesn't, you need to allow traffic from the node CIDR.

**Diagnosis**:
```bash
kubectl describe pod <pod-name> -n shopping | grep -A3 "Events"
# Look for "Liveness probe failed" or "Readiness probe failed"
```

### Service-to-service calls timing out after NetworkPolicy

**Diagnosis**:
```bash
# Check which NetworkPolicies apply to a pod
kubectl get networkpolicy -n shopping

# Describe a specific policy to see its rules
kubectl describe networkpolicy allow-cart-from-frontend-and-checkout -n shopping
```

**Common mistakes**:
- Wrong label in `podSelector` (case-sensitive!)
- Missing port number
- Wrong namespace in `namespaceSelector`
- Forgetting that multiple `from` items are OR'd (any match allows)

### How to temporarily disable all NetworkPolicies (emergency)

```bash
# Delete all policies (opens everything back up)
kubectl delete networkpolicy --all -n shopping

# Re-apply when ready
kubectl apply -f k8s/network-policies.yaml
```

---

## Real-World Considerations

| This Project | Production |
|-------------|------------|
| All pods in one namespace | Separate namespaces per team/service group |
| Manual NetworkPolicy YAML | Generated by tools (Cilium Network Policy Editor) |
| Ingress-only policies | Also add Egress policies (restrict outbound traffic) |
| `automountServiceAccountToken: false` | Also disable service account token auto-mount at namespace level |
| Role with hardcoded secret names | Dynamic secrets from Vault, no direct K8s secret access needed |

### What We'd Add in Production

1. **Egress policies** — restrict what pods can call OUTSIDE the cluster (prevent data exfiltration)
2. **DNS egress allowance** — explicitly allow CoreDNS traffic (pods need DNS to resolve service names)
3. **Monitoring namespace access** — allow Prometheus to scrape metrics from all pods
4. **Audit logging** — track who accessed what via RBAC

---

## kubectl Commands Reference (CKA/CKS)

```bash
# NetworkPolicies
kubectl get networkpolicy -n shopping
kubectl describe networkpolicy default-deny-ingress -n shopping
kubectl delete networkpolicy default-deny-ingress -n shopping

# ServiceAccounts
kubectl get serviceaccounts -n shopping
kubectl describe serviceaccount cart-sa -n shopping

# Roles and RoleBindings
kubectl get roles -n shopping
kubectl get rolebindings -n shopping
kubectl describe role config-reader -n shopping
kubectl describe rolebinding auth-config-reader -n shopping

# Test RBAC (can a SA do something?)
kubectl auth can-i get configmaps --as=system:serviceaccount:shopping:checkout-sa -n shopping
# Expected: yes

kubectl auth can-i get secrets --as=system:serviceaccount:shopping:cart-sa -n shopping
# Expected: no

# ClusterRoles (cluster-wide, not namespace-scoped)
kubectl get clusterroles
kubectl get clusterrolebindings
```

---

## CKA/CKS Exam Relevance

### CKA Domains Covered

| Domain | What We Practiced |
|--------|-------------------|
| Cluster Architecture (25%) | RBAC, ServiceAccounts, understanding API access model |
| Services & Networking (20%) | NetworkPolicies, understanding pod-to-pod communication |
| Troubleshooting (30%) | Diagnosing blocked traffic, checking policy selectors |

### CKS Domains Covered

| Domain | What We Practiced |
|--------|-------------------|
| Cluster Setup (10%) | NetworkPolicies for restricting traffic |
| Cluster Hardening (15%) | RBAC, ServiceAccounts, disabling token auto-mount |
| Minimize Microservice Vulnerabilities (20%) | Least-privilege access, pod identity isolation |

### CKS Exam Tips
- Know how to write a NetworkPolicy from scratch (deny-all + specific allow)
- Know the difference between `podSelector`, `namespaceSelector`, and `ipBlock`
- Know that multiple items in `from:` array are OR'd (any match allows)
- Know that `podSelector` + `namespaceSelector` in the SAME item are AND'd
- Know `kubectl auth can-i` for testing RBAC permissions
- Know how to create a Role and RoleBinding imperatively:
  ```bash
  kubectl create role pod-reader --verb=get,list --resource=pods -n shopping
  kubectl create rolebinding pod-reader-binding --role=pod-reader --serviceaccount=shopping:checkout-sa -n shopping
  ```

---

## Next Steps (Phase 4)

With networking locked down and identity established, the next phase covers:
- **Resource Quotas & LimitRanges** — prevent one service from consuming all cluster resources
- **Pod Security Standards** — enforce non-root containers, read-only filesystems
- **Horizontal Pod Autoscaler (HPA)** — auto-scale based on CPU/memory
