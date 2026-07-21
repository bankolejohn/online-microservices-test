# Phase 6: Istio Service Mesh

## Overview

This phase adds a service mesh to our cluster. We go from "services talk to each other over plain HTTP and we hope nobody is listening" to "every single request is encrypted, authenticated, authorized, and resilient — without changing a single line of application code."

**What we did**:
- Installed Istio 1.26.0 with the demo profile on our Kind cluster (v1.30.3)
- Enabled automatic sidecar injection (every pod gets an Envoy proxy)
- Enforced strict mutual TLS (all traffic encrypted, both sides verified)
- Added traffic management (retries, timeouts, circuit breakers)
- Created authorization policies (Layer 7 access control)
- Troubleshot resource conflicts (LimitRange, ResourceQuota, PDB interactions)

**Why this matters**:
- Zero-trust networking — every service proves its identity on every request
- Automatic encryption without touching application code
- Resilience patterns (retries, circuit breakers) at the infrastructure level
- Fine-grained access control that goes beyond "can this IP reach this port"
- Foundation for canary deployments, A/B testing, and traffic mirroring

---

## 1. What Is a Service Mesh?

### The Problem

In a microservices architecture, services talk to each other constantly. Our shopping app has:
- Frontend → Product Catalog, Cart, Checkout
- Checkout → Payment, Shipping
- All services → health checks from monitoring

That's a lot of network traffic. And by default, it's all **plain HTTP**. Anyone who can sniff the network sees everything — credit card numbers, user tokens, order details. Plus, there's no automatic retry logic, no circuit breaking, no traffic splitting for canary releases.

You could solve each of these in application code, but then every team, in every language, has to implement the same patterns. That's error-prone and impossible to enforce consistently.

### The Solution: A Service Mesh

A service mesh is an **infrastructure layer** that handles service-to-service communication. It transparently intercepts all network traffic and adds:
- Encryption (mTLS)
- Authentication (identity verification)
- Authorization (access control)
- Resilience (retries, timeouts, circuit breakers)
- Observability (metrics, traces, logs for every request)
- Traffic management (canary, A/B, mirroring)

All without changing application code.

### Before vs After Diagram

```
BEFORE (No Service Mesh):
═══════════════════════════════════════════════════════════════════

  ┌──────────┐   plain HTTP    ┌──────────┐   plain HTTP    ┌──────────┐
  │ Frontend │───────────────▶│ Checkout │───────────────▶│ Payment  │
  │          │                 │          │                 │          │
  └──────────┘                 └──────────┘                 └──────────┘
       │
       │  plain HTTP           Anyone sniffing the network sees:
       ▼                       - Request/response bodies
  ┌──────────┐                 - Auth tokens
  │  Cart    │                 - Credit card numbers
  └──────────┘                 - No identity verification
                               - No automatic retries
                               - No circuit breaking


AFTER (With Istio Service Mesh):
═══════════════════════════════════════════════════════════════════

  ┌────────────────┐  mTLS (encrypted)  ┌────────────────┐  mTLS  ┌────────────────┐
  │┌──────────────┐│                     │┌──────────────┐│        │┌──────────────┐│
  ││   Frontend   ││                     ││   Checkout   ││        ││   Payment    ││
  │└──────┬───────┘│                     │└──────┬───────┘│        │└──────┬───────┘│
  │       │        │                     │       │        │        │       │        │
  │┌──────▼───────┐│◀═══════encrypted═══▶│┌──────▼───────┐│◀═════▶│┌──────▼───────┐│
  ││ Envoy Proxy  ││   + authenticated   ││ Envoy Proxy  ││       ││ Envoy Proxy  ││
  ││ (sidecar)    ││   + authorized      ││ (sidecar)    ││       ││ (sidecar)    ││
  ││              ││   + retried          ││              ││       ││              ││
  │└──────────────┘│   + circuit-broken   │└──────────────┘│       │└──────────────┘│
  └────────────────┘                      └────────────────┘       └────────────────┘

  Network sniffer sees: encrypted gibberish
  Identity: cryptographically verified (x509 certificates)
  Access: enforced per-method, per-path, per-identity
  Resilience: automatic retries, timeouts, circuit breakers
```

### The Postcard vs Sealed Letter Analogy

Think of service-to-service communication like sending mail:

**Without a service mesh** = sending a postcard:
- Anyone who handles the postcard (network routers, other pods, compromised nodes) can read it
- The recipient has no way to verify who actually sent it
- If the post office loses it, too bad — no automatic re-delivery
- Anyone can send a postcard claiming to be from you

**With a service mesh** = sending a sealed, registered letter:
- The contents are sealed in an envelope (encryption — nobody in transit can read it)
- The sender's identity is verified with government ID (mTLS certificates)
- The mail carrier tries again if delivery fails (retries)
- Only authorized recipients can accept the letter (authorization policies)
- The postal service tracks the entire journey (observability)

And the best part: your application (the person writing the letter) doesn't need to know any of this is happening. They just write the letter. The postal infrastructure handles the rest.

---

## 2. Istio Architecture

Istio has two main planes: the **control plane** (brains) and the **data plane** (muscle).

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         ISTIO ARCHITECTURE                                   │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                      CONTROL PLANE                                     │  │
│  │                                                                       │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐  │  │
│  │  │                        istiod                                    │  │  │
│  │  │                                                                 │  │  │
│  │  │  ┌─────────┐    ┌──────────────┐    ┌────────────────────────┐ │  │  │
│  │  │  │  Pilot  │    │  Citadel     │    │  Galley (deprecated)   │ │  │  │
│  │  │  │         │    │              │    │                        │ │  │  │
│  │  │  │ Pushes  │    │ Certificate  │    │ Config validation      │ │  │  │
│  │  │  │ config  │    │ Authority    │    │ (now built into Pilot) │ │  │  │
│  │  │  │ to all  │    │ Issues &     │    │                        │ │  │  │
│  │  │  │ proxies │    │ rotates certs│    │                        │ │  │  │
│  │  │  └─────────┘    └──────────────┘    └────────────────────────┘ │  │  │
│  │  └─────────────────────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│         │                    │                                               │
│         │ Push xDS config    │ Issue certificates                            │
│         ▼                    ▼                                               │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                        DATA PLANE                                      │  │
│  │                                                                       │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐ │  │
│  │  │ Pod         │  │ Pod         │  │ Pod         │  │ Pod         │ │  │
│  │  │┌───────────┐│  │┌───────────┐│  │┌───────────┐│  │┌───────────┐│ │  │
│  │  ││  App      ││  ││  App      ││  ││  App      ││  ││  App      ││ │  │
│  │  │├───────────┤│  │├───────────┤│  │├───────────┤│  │├───────────┤│ │  │
│  │  ││  Envoy    ││  ││  Envoy    ││  ││  Envoy    ││  ││  Envoy    ││ │  │
│  │  ││  Proxy    ││  ││  Proxy    ││  ││  Proxy    ││  ││  Proxy    ││ │  │
│  │  │└───────────┘│  │└───────────┘│  │└───────────┘│  │└───────────┘│ │  │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘ │  │
│  │                                                                       │  │
│  │  Every pod gets an Envoy sidecar. ALL traffic flows through it.       │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                      GATEWAYS                                          │  │
│  │                                                                       │  │
│  │  ┌─────────────────────────┐    ┌─────────────────────────────────┐  │  │
│  │  │ istio-ingressgateway     │    │ istio-egressgateway              │  │  │
│  │  │                         │    │                                 │  │  │
│  │  │ Traffic INTO the mesh   │    │ Traffic OUT OF the mesh         │  │  │
│  │  │ (external → services)   │    │ (services → external APIs)     │  │  │
│  │  └─────────────────────────┘    └─────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

### istiod (Control Plane)

**What**: A single binary (`istiod`) that runs the entire control plane. It used to be three separate components (Pilot, Citadel, Galley) — they were merged for simplicity.

**What it does**:
1. **Pushes configuration** — When you create a VirtualService or DestinationRule, istiod translates it into Envoy-native configuration and pushes it to all sidecar proxies via the xDS API
2. **Manages certificates** — Acts as the mesh's Certificate Authority (CA). Issues short-lived x509 certificates to every sidecar, rotates them automatically (default: every 24 hours)
3. **Service discovery** — Watches Kubernetes Services/Endpoints and tells proxies about available backends
4. **Config validation** — Validates your Istio CRDs before accepting them

**Real company analogy**: istiod is like the corporate security team. They issue employee badges (certificates), set access policies (authorization), and configure the building's entry systems (proxy config) — but they don't stand at every door checking badges themselves.

### Envoy Sidecar Proxy (Data Plane)

**What**: A high-performance proxy (written in C++) injected into every pod as a sidecar container. It intercepts ALL inbound and outbound traffic from the application container.

**What it does**:
1. **Encrypts/decrypts** — Terminates mTLS on inbound, initiates mTLS on outbound
2. **Enforces policies** — Checks authorization policies before forwarding requests
3. **Applies resilience** — Retries, timeouts, circuit breaking
4. **Reports telemetry** — Sends metrics (request count, latency, error rate) to Prometheus
5. **Routes traffic** — Implements VirtualService rules (canary splits, header-based routing)

**How interception works**: Istio configures iptables rules inside the pod's network namespace. All traffic destined for port 80 (or any port) gets redirected to Envoy's listener on port 15006. The application has no idea this is happening.

```
Inside a Pod:
┌────────────────────────────────────────────────┐
│                                                │
│  App Container                                 │
│  (thinks it's talking directly to the network) │
│       │                                        │
│       │ sends to checkout-service:5001         │
│       ▼                                        │
│  ┌──────────────────────────────────────────┐  │
│  │ iptables (injected by istio-init)        │  │
│  │ REDIRECTS all outbound traffic to :15001 │  │
│  └────────────────────┬─────────────────────┘  │
│                       │                        │
│                       ▼                        │
│  ┌──────────────────────────────────────────┐  │
│  │ Envoy Proxy (port 15001)                 │  │
│  │                                          │  │
│  │ 1. Looks up routing rules (VirtualSvc)   │  │
│  │ 2. Checks authorization policy           │  │
│  │ 3. Initiates mTLS connection             │  │
│  │ 4. Applies retry/timeout policy          │  │
│  │ 5. Sends request to destination's Envoy  │  │
│  │ 6. Reports metrics to Prometheus         │  │
│  └──────────────────────────────────────────┘  │
│                                                │
└────────────────────────────────────────────────┘
```

### Gateways

**Ingress Gateway**: The front door to the mesh. External traffic enters here and gets routed to internal services. It's like a load balancer that understands Istio routing rules.

**Egress Gateway**: The controlled exit from the mesh. If your services call external APIs (Stripe, Twilio, etc.), the egress gateway ensures those calls are logged, authorized, and optionally encrypted.

In our setup, the demo profile installs both gateways automatically in the `istio-system` namespace.

---

## 3. Installation

### What We Used

- **Kind cluster** v1.30.3 (Kubernetes in Docker)
- **Istio** v1.26.0 (latest stable at time of installation)
- **Installation method**: `istioctl` with the `demo` profile

### Why the Demo Profile?

Istio has several installation profiles:

| Profile | Use Case | Components |
|---------|----------|------------|
| `minimal` | Production (start small) | istiod only, no gateways |
| `default` | Production | istiod + ingress gateway |
| `demo` | Learning/testing | istiod + ingress + egress + extras (higher resource usage, more telemetry) |
| `ambient` | Production (no sidecars) | L4 mesh without sidecar injection (newer approach) |

We used `demo` because it installs everything we need to learn with, including both gateways and extra telemetry. For production, you'd start with `default` and add only what you need.

### Installation Steps

```bash
# 1. Download Istio (creates istio-1.26.0/ directory)
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.26.0 sh -

# 2. Add istioctl to PATH
export PATH=$PWD/istio-1.26.0/bin:$PATH

# 3. Pre-check: verify cluster meets requirements
istioctl x precheck
# ✔ No issues found when checking the cluster.

# 4. Install Istio with demo profile
istioctl install --set profile=demo -y
# ✔ Istio core installed
# ✔ Istiod installed
# ✔ Ingress gateways installed
# ✔ Egress gateways installed
# ✔ Installation complete

# 5. Verify installation
kubectl get pods -n istio-system
# NAME                                    READY   STATUS    RESTARTS   AGE
# istiod-xxxxxxxxx-xxxxx                  1/1     Running   0          2m
# istio-ingressgateway-xxxxxxxxx-xxxxx    1/1     Running   0          2m
# istio-egressgateway-xxxxxxxxx-xxxxx     1/1     Running   0          2m

# 6. Verify Istio is healthy
istioctl verify-install
# ✔ Istio is installed and verified successfully
```

### About the istio-1.26.0/ Directory

The downloaded `istio-1.26.0/` directory contains:
- `bin/istioctl` — the CLI tool (binary, ~80MB)
- `manifests/` — Helm charts and installation templates
- `samples/` — example applications (Bookinfo, etc.)

**This directory should be gitignored** — it's a downloaded binary distribution, not project code. We added it to `.gitignore`:
```
# Istio binary distribution (downloaded, not source code)
istio-1.26.0/
```

The actual Istio configuration we wrote (PeerAuthentication, VirtualService, etc.) lives in our `istio/` directory and IS tracked in git.

---

## 4. Sidecar Injection

### What

Sidecar injection is how Istio adds an Envoy proxy container to every pod in a namespace. After injection, each pod has two containers: your application + the Envoy proxy.

### Why

The sidecar model means:
- **No code changes** — your app doesn't know it's in a mesh
- **Language-agnostic** — works with Node.js, Python, Go, Java, anything
- **Consistent enforcement** — every service gets the same security and resilience features
- **Transparent upgrades** — update Envoy separately from your application

### How

#### Step 1: Label the Namespace

```bash
# Tell Istio: "inject a sidecar into every pod created in this namespace"
kubectl label namespace shopping istio-injection=enabled

# Verify the label
kubectl get namespace shopping --show-labels
# NAME       STATUS   AGE   LABELS
# shopping   Active   14d   istio-injection=enabled,...
```

#### Step 2: Restart Existing Deployments

The label only affects **new** pods. Existing pods don't get sidecars until they're recreated:

```bash
# Restart all deployments to trigger sidecar injection
kubectl rollout restart deployment -n shopping

# Watch pods transition from 1/1 to 2/2
kubectl get pods -n shopping -w
# NAME                              READY   STATUS    
# product-catalog-xxx-old           1/1     Terminating     ← Old pod (no sidecar)
# product-catalog-xxx-new           2/2     Running         ← New pod (app + envoy)
# cart-service-xxx-old              1/1     Terminating
# cart-service-xxx-new              2/2     Running
# checkout-service-xxx-new          2/2     Running
# payment-service-xxx-new           2/2     Running
# shipping-service-xxx-new          2/2     Running
# frontend-service-xxx-new          2/2     Running
```

#### The 1/1 → 2/2 Transition

```
BEFORE injection:                    AFTER injection:
┌──────────────────────┐             ┌──────────────────────┐
│ Pod                  │             │ Pod                  │
│                      │             │                      │
│ ┌──────────────────┐ │             │ ┌──────────────────┐ │
│ │ App Container    │ │             │ │ App Container    │ │
│ │ (your code)      │ │             │ │ (your code)      │ │
│ └──────────────────┘ │             │ ├──────────────────┤ │
│                      │             │ │ Envoy Proxy      │ │
│ READY: 1/1           │             │ │ (istio-proxy)    │ │
└──────────────────────┘             │ └──────────────────┘ │
                                     │                      │
                                     │ READY: 2/2           │
                                     └──────────────────────┘
```

The `2/2` means both containers (app + istio-proxy) are ready. If you see `1/2`, it means the Envoy sidecar hasn't finished starting (usually waiting for certificates from istiod).

#### How Injection Actually Works (Under the Hood)

When you label a namespace with `istio-injection=enabled`, here's what happens:

1. You create/restart a pod
2. The Kubernetes API server intercepts the pod creation
3. It calls Istio's **Mutating Admission Webhook** (registered during install)
4. The webhook modifies the pod spec to add:
   - An `istio-init` init container (configures iptables rules)
   - The `istio-proxy` sidecar container (the Envoy proxy)
   - Volume mounts for certificates
5. The modified pod spec is persisted and scheduled

Your Deployment YAML never changes — the injection is handled at the API server level.

#### Verify Injection

```bash
# Check that pods have the sidecar
kubectl get pods -n shopping -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.name}{" "}{end}{"\n"}{end}'
# product-catalog-xxx    product-catalog istio-proxy
# cart-service-xxx       cart-service istio-proxy
# checkout-service-xxx   checkout-service istio-proxy
# ...

# Verify with istioctl
istioctl proxy-status
# NAME                                    CLUSTER   CDS    LDS    EDS    RDS    ECDS   ISTIOD
# cart-service-xxx.shopping               Kubernetes  SYNCED SYNCED SYNCED SYNCED        istiod-xxx
# checkout-service-xxx.shopping           Kubernetes  SYNCED SYNCED SYNCED SYNCED        istiod-xxx
# product-catalog-xxx.shopping            Kubernetes  SYNCED SYNCED SYNCED SYNCED        istiod-xxx
# ...
```

`SYNCED` means the proxy has the latest configuration from istiod. If you see `STALE`, the proxy isn't receiving updates.

---

## 5. Mutual TLS (mTLS)

### What

Mutual TLS means **both sides** of a connection verify each other's identity using x509 certificates. Regular TLS (like HTTPS in your browser) only verifies the server. mTLS verifies the client too.

### Why

In a Kubernetes cluster, pods can be scheduled on any node. Network traffic between pods travels over the node's physical network. Without encryption:
- A compromised node can sniff all traffic between services
- A rogue pod in another namespace could intercept requests
- There's no cryptographic proof of "who is calling me"

mTLS solves all three:
1. **Encryption** — traffic is encrypted with TLS 1.3, unreadable to sniffers
2. **Authentication** — each service has a cryptographic identity (SPIFFE ID)
3. **Integrity** — tampering is detected and rejected

### How

#### Our PeerAuthentication Resource

```yaml
# istio/peer-authentication.yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: strict-mtls
  namespace: shopping
spec:
  mtls:
    mode: STRICT    # REJECT any non-mTLS traffic
```

That's it. One resource, 8 lines of YAML. Every request between services in the `shopping` namespace is now:
- Encrypted (TLS 1.3)
- Mutually authenticated (both client and server present certificates)
- Automatically managed (no manual certificate rotation)

#### Modes

| Mode | Behavior | When to Use |
|------|----------|-------------|
| `PERMISSIVE` | Accepts both mTLS and plaintext | During migration (some pods don't have sidecars yet) |
| `STRICT` | **Only** accepts mTLS, rejects plaintext | After all pods have sidecars (our setup) |
| `DISABLE` | No mTLS enforcement | Testing/debugging only |

We used `STRICT` because all our pods have sidecars. If you enable `STRICT` before all pods are injected, non-mesh pods can't communicate with mesh pods.

#### Zero Code Changes

Here's the magic — our application code still does:
```javascript
// cart-service/server.js — unchanged
const response = await fetch('http://checkout-service:5001/api/checkout');
```

The app thinks it's making a plain HTTP call. But the Envoy sidecar intercepts this, upgrades it to mTLS, sends it encrypted to the destination's Envoy, which decrypts it and hands plain HTTP to the destination app. The apps never see the certificates.

```
App A ──plain HTTP──▶ Envoy A ══mTLS══▶ Envoy B ──plain HTTP──▶ App B
      (localhost)              (encrypted over network)        (localhost)
```

#### Certificate Lifecycle

Istio handles the entire certificate lifecycle automatically:

```
┌─────────────────────────────────────────────────────────────┐
│ Certificate Management (fully automatic)                     │
│                                                             │
│  1. Pod starts → Envoy sidecar generates a private key      │
│  2. Envoy sends a CSR (Certificate Signing Request) to      │
│     istiod over a secure gRPC channel                       │
│  3. istiod signs the certificate (identity: SPIFFE ID)      │
│     Format: spiffe://cluster.local/ns/shopping/sa/cart-sa   │
│  4. Certificate returned to Envoy                           │
│  5. Certificate expires after 24 hours                      │
│  6. Before expiry, Envoy automatically requests a new one   │
│                                                             │
│  You never: create CSRs, manage CAs, rotate certs, or      │
│  configure trust stores. Istio does ALL of it.              │
└─────────────────────────────────────────────────────────────┘
```

#### Verify mTLS Is Working

```bash
# Check mTLS status for all services
istioctl authn tls-check <pod-name>.shopping

# Or use proxy-config to inspect a specific pod's TLS settings
istioctl proxy-config endpoints <pod-name>.shopping --cluster "outbound|5001||checkout-service.shopping.svc.cluster.local"

# Verify PeerAuthentication is applied
kubectl get peerauthentication -n shopping
# NAME          MODE     AGE
# strict-mtls   STRICT   5h
```

---

## 6. Traffic Management

Traffic management is where Istio really shines over basic Kubernetes Services. Kubernetes gives you round-robin load balancing. Istio gives you fine-grained control over how traffic flows between services.

### VirtualService — Routing Rules

**What**: A VirtualService defines how requests are routed to a service. Think of it as a "traffic cop" that can split traffic, add retries, set timeouts, and route based on headers.

**Why**: Without it, Kubernetes just load-balances across all healthy pods equally. You can't do:
- Send 10% of traffic to a canary version
- Retry failed requests automatically
- Set a maximum timeout for slow services
- Route based on HTTP headers (A/B testing)

#### Our VirtualService for Product Catalog

```yaml
# istio/traffic-management.yaml (excerpt)
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: product-catalog-routing
  namespace: shopping
spec:
  hosts:
    - product-catalog-service      # Traffic to this hostname
  http:
  - route:
    - destination:
        host: product-catalog-service
      weight: 100                  # 100% of traffic goes here
    # Retry policy: retry failed requests automatically
    retries:
      attempts: 3                  # Retry up to 3 times
      perTryTimeout: 2s            # Each attempt gets 2 seconds
      retryOn: 5xx,reset,connect-failure,retriable-4xx
    # Timeout: total time allowed for the request
    timeout: 10s
```

**What this does**:
1. If a request to product-catalog gets a 5xx error, Envoy automatically retries up to 3 times
2. Each retry attempt has 2 seconds before timing out
3. The entire request (including retries) has a 10-second total timeout
4. Retries happen transparently — the calling service doesn't know

**Why retries matter in real companies**: Transient failures are the #1 cause of user-facing errors. A pod restarting, a brief network blip, a garbage collection pause — all cause single-request failures. Automatic retries eliminate these from the user experience without any code changes.

#### Our VirtualService for Checkout

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: checkout-routing
  namespace: shopping
spec:
  hosts:
    - checkout-service
  http:
  - route:
    - destination:
        host: checkout-service
      weight: 100
    retries:
      attempts: 2
      perTryTimeout: 5s
      retryOn: 5xx,reset,connect-failure
    timeout: 15s                   # Checkout orchestrates multiple calls, needs more time
```

Checkout gets a longer timeout (15s vs 10s) because it calls Payment + Shipping downstream. It also only retries twice (not 3) because checkout operations may not be idempotent.

### DestinationRule — Circuit Breakers & Connection Pools

**What**: A DestinationRule defines policies that apply AFTER routing. It configures load balancing, connection pooling, and circuit breaking for a specific service.

**Why**: Circuit breakers prevent cascade failures. If Payment is down, you don't want Checkout to keep sending requests (wasting resources, increasing latency). Instead, "break the circuit" — fail immediately and return an error quickly.

#### Our DestinationRule for Payment

```yaml
# istio/traffic-management.yaml (excerpt)
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: payment-circuit-breaker
  namespace: shopping
spec:
  host: payment-service
  trafficPolicy:
    connectionPool:
      http:
        http1MaxPendingRequests: 50   # Max queued requests
        http2MaxRequests: 50          # Max concurrent requests
    outlierDetection:
      consecutive5xxErrors: 3         # After 3 failures...
      interval: 10s                   # ...checked every 10s...
      baseEjectionTime: 30s           # ...eject the pod for 30s
      maxEjectionPercent: 100         # Allow ejecting all pods (fail fast)
```

#### How Circuit Breaking Works

```
Normal operation:
  Checkout ──request──▶ Payment Pod 1 ✓
  Checkout ──request──▶ Payment Pod 2 ✓
  Checkout ──request──▶ Payment Pod 1 ✓

Payment Pod 1 starts failing:
  Checkout ──request──▶ Payment Pod 1 ✗ (5xx, failure #1)
  Checkout ──request──▶ Payment Pod 1 ✗ (5xx, failure #2)
  Checkout ──request──▶ Payment Pod 1 ✗ (5xx, failure #3)

Circuit BREAKS (outlierDetection triggers):
  ┌───────────────────────────────────────────────┐
  │ Payment Pod 1 EJECTED for 30 seconds          │
  │ All traffic goes to remaining healthy pods    │
  └───────────────────────────────────────────────┘

  Checkout ──request──▶ Payment Pod 2 ✓  (Pod 1 is out of rotation)
  Checkout ──request──▶ Payment Pod 2 ✓

After 30s, Pod 1 is let back in:
  Checkout ──request──▶ Payment Pod 1 ✓  (recovered!)
  Checkout ──request──▶ Payment Pod 2 ✓
```

**Real company impact**: Without circuit breakers, a failing downstream service causes requests to pile up, threads to exhaust, memory to spike, and eventually the CALLING service crashes too. This is a cascade failure. Circuit breakers contain the blast radius.

### Canary Deployment Concept

A canary deployment sends a small percentage of traffic to a new version while keeping most traffic on the stable version. If the canary is healthy, gradually increase traffic. If it fails, route everything back.

```yaml
# EXAMPLE: Canary deployment (not applied yet — we'd do this when deploying v2)
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: product-catalog-canary
  namespace: shopping
spec:
  hosts:
    - product-catalog-service
  http:
  - route:
    - destination:
        host: product-catalog-service
        subset: stable             # v1 (existing version)
      weight: 90                   # 90% of traffic
    - destination:
        host: product-catalog-service
        subset: canary             # v2 (new version)
      weight: 10                   # 10% of traffic

---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: product-catalog-versions
  namespace: shopping
spec:
  host: product-catalog-service
  subsets:
  - name: stable
    labels:
      version: v1                  # Pods with label version=v1
  - name: canary
    labels:
      version: v2                  # Pods with label version=v2
```

**Progression**: 10% → 25% → 50% → 100% (update the weights in VirtualService at each step, monitoring error rates between each step).

---

## 7. Authorization Policies

### What

Istio AuthorizationPolicies are **Layer 7 access control** — they let you control WHO can call WHAT endpoint using WHICH HTTP method. This is far more granular than Kubernetes NetworkPolicies.

### Why

NetworkPolicies (Phase 3b) operate at Layer 3/4:
- "Can this pod's IP reach that pod's port?"
- They can't distinguish between GET and POST
- They can't inspect HTTP paths
- They can't verify service identity

AuthorizationPolicies operate at Layer 7:
- "Can checkout-service's service account POST to /api/payment/process?"
- They verify cryptographic identity (not just IP)
- They inspect HTTP methods and paths
- They can even check headers and request properties

### Comparison: NetworkPolicy vs AuthorizationPolicy

```
┌────────────────────────────────────────────────────────────────────────┐
│                                                                        │
│  NetworkPolicy (Layer 3/4):                                            │
│  "Checkout pod at 10.244.1.5 can reach Payment pod at port 5002"       │
│                                                                        │
│  ┌──────────┐         port 5002         ┌──────────┐                  │
│  │ Checkout │ ──────────────────────────▶│ Payment  │   ✓ Allowed     │
│  │10.244.1.5│                            │10.244.2.3│                  │
│  └──────────┘                            └──────────┘                  │
│                                                                        │
│  Problem: Checkout can call ANY endpoint on port 5002:                 │
│    POST /api/payment/process  ✓ (intended)                             │
│    GET  /api/payment/refund   ✓ (NOT intended!)                        │
│    GET  /admin/reset-database ✓ (DANGEROUS!)                           │
│                                                                        │
├────────────────────────────────────────────────────────────────────────┤
│                                                                        │
│  AuthorizationPolicy (Layer 7):                                        │
│  "checkout-sa can POST to /api/payment/process ONLY"                   │
│                                                                        │
│  ┌──────────┐  POST /api/payment/process ┌──────────┐                 │
│  │ Checkout │ ─────────────────────────▶ │ Payment  │   ✓ Allowed    │
│  │checkout-sa│                            │          │                 │
│  └──────────┘                            └──────────┘                  │
│                                                                        │
│  ┌──────────┐  GET /api/payment/refund   ┌──────────┐                 │
│  │ Checkout │ ─────────────────────────▶ │ Payment  │   ✗ DENIED     │
│  │checkout-sa│                            │          │                 │
│  └──────────┘                            └──────────┘                  │
│                                                                        │
│  ┌──────────┐  POST /api/payment/process ┌──────────┐                 │
│  │   Cart   │ ─────────────────────────▶ │ Payment  │   ✗ DENIED     │
│  │  cart-sa  │                            │          │  (wrong source) │
│  └──────────┘                            └──────────┘                  │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

### Our Authorization Policies

#### Payment Service Access

```yaml
# istio/authorization-policies.yaml (excerpt)
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: payment-access
  namespace: shopping
spec:
  selector:
    matchLabels:
      app: payment-service          # Apply to payment pods
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/shopping/sa/checkout-sa"]
    to:
    - operation:
        methods: ["POST"]
        paths: ["/api/payment/process"]
  - from:
    - source:
        principals: ["cluster.local/ns/shopping/sa/frontend-sa"]
    to:
    - operation:
        methods: ["GET"]
        paths: ["/health"]
```

**What this says in plain English**:
1. Only `checkout-sa` (checkout service's service account) can POST to `/api/payment/process`
2. Only `frontend-sa` can GET `/health` (for health checks)
3. **Everything else is DENIED** (implicit deny when ALLOW rules exist)

The `principals` field uses SPIFFE IDs — the cryptographic identity from the mTLS certificate. This isn't just checking a label that could be faked; it's verifying a certificate issued by Istio's CA.

#### Shipping Service Access

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: shipping-access
  namespace: shopping
spec:
  selector:
    matchLabels:
      app: shipping-service
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/shopping/sa/checkout-sa"]
    to:
    - operation:
        methods: ["POST"]
        paths: ["/api/shipping/create"]
  - from:
    - source:
        principals: ["cluster.local/ns/shopping/sa/frontend-sa"]
    to:
    - operation:
        methods: ["GET"]
        paths: ["/health"]
```

### Applying the Policies

```bash
# Apply all authorization policies
kubectl apply -f istio/authorization-policies.yaml

# Verify they're active
kubectl get authorizationpolicies -n shopping
# NAME              AGE
# payment-access    2h
# shipping-access   2h

# Test: this should SUCCEED (checkout → payment, correct method+path)
kubectl exec -n shopping deployment/checkout-service -c checkout-service -- \
  curl -s -o /dev/null -w "%{http_code}" -X POST http://payment-service:5002/api/payment/process

# Test: this should FAIL with 403 (cart → payment, wrong source)
kubectl exec -n shopping deployment/cart-service -c cart-service -- \
  curl -s -o /dev/null -w "%{http_code}" -X POST http://payment-service:5002/api/payment/process
# 403 — RBAC: access denied
```

---

## 8. Troubleshooting — Real Problems We Hit

This was the hardest part of Istio setup. The sidecar proxy adds resources to every pod, which conflicts with LimitRanges, ResourceQuotas, and PDBs we set up in Phase 4. Here's what happened and how we fixed it.

### Problem 1: LimitRange Blocking Sidecar Injection

**Symptom**: Pods stuck in `Init:CrashLoopBackOff` after enabling sidecar injection.

```bash
kubectl get pods -n shopping
# NAME                              READY   STATUS                  RESTARTS
# product-catalog-xxx               0/2     Init:CrashLoopBackOff   3
```

**Root Cause**: Our LimitRange from Phase 4 had these settings:
```yaml
# BEFORE (broken):
spec:
  limits:
  - type: Container
    min:
      cpu: "50m"        # ← Problem: sidecar requests only 10m CPU
      memory: "64Mi"    # ← Problem: sidecar init container needs less
    max:
      cpu: "1"          # ← Problem: sidecar has default limit of 2 CPU
      memory: "1Gi"
```

The Istio sidecar proxy (`istio-proxy`) has these defaults:
- CPU request: `10m` (below our minimum of 50m)
- CPU limit: `2000m` / `2` CPU (above our maximum of 1 CPU)

The Kubernetes API server rejects the pod because the sidecar's resources violate the LimitRange.

**Fix**: Update LimitRange to accommodate the sidecar AND add explicit sidecar resource annotations to deployments.

```yaml
# k8s/limit-range.yaml — AFTER (fixed):
spec:
  limits:
  - type: Container
    min:
      cpu: "10m"        # Lowered from 50m to allow sidecar's 10m request
      memory: "40Mi"    # Lowered from 64Mi to allow sidecar init
    max:
      cpu: "2"          # Raised from 1 to allow sidecar's 2 CPU limit
      memory: "2Gi"     # Raised to give headroom
    default:
      cpu: "200m"
      memory: "256Mi"
    defaultRequest:
      cpu: "50m"
      memory: "64Mi"
```

**Additionally**, add sidecar resource annotations to deployments to override Istio's defaults:

```yaml
# In each deployment's pod template:
metadata:
  annotations:
    sidecar.istio.io/proxyCPU: "50m"
    sidecar.istio.io/proxyCPULimit: "500m"
    sidecar.istio.io/proxyMemory: "64Mi"
    sidecar.istio.io/proxyMemoryLimit: "256Mi"
```

These annotations tell Istio: "Don't use your defaults for this pod's sidecar. Use these values instead."

### Problem 2: ResourceQuota Exceeded

**Symptom**: New pods fail to create after enabling sidecars.

```bash
kubectl get events -n shopping --field-selector reason=FailedCreate
# Error creating: pods "checkout-xxx" is forbidden:
# exceeded quota: shopping-quota, requested: limits.cpu=2500m,
# used: limits.cpu=8500m, limited: limits.cpu=6
```

**Root Cause**: Each sidecar adds its default resource limit (2 CPU) to every pod. With 6 services × 2 replicas × 2 CPU sidecar limit = 24 extra CPU in limits alone. Our quota only allowed 6 CPU total limits.

**Calculation**:
```
Before sidecars:  6 services × 2 replicas × ~500m CPU limit  = 6 CPU total
After sidecars:   6 services × 2 replicas × (500m + 2000m)   = 30 CPU total
                                                                ^^^^
                                               Sidecar adds 2000m per pod!
```

**Fix**: Two changes:
1. Update ResourceQuota to accommodate sidecar resources
2. Use sidecar resource annotations to reduce sidecar defaults

```yaml
# k8s/resource-quota.yaml — AFTER (fixed):
apiVersion: v1
kind: ResourceQuota
metadata:
  name: shopping-quota
  namespace: shopping
spec:
  hard:
    requests.cpu: "4"
    requests.memory: "4Gi"
    limits.cpu: "10"          # Raised from 6 to accommodate sidecars
    limits.memory: "12Gi"     # Raised from 6Gi
    pods: "30"
```

With the sidecar resource annotations (`proxyCPULimit: 500m` instead of the default 2 CPU), each pod now uses 500m + 500m = 1 CPU limit instead of 500m + 2000m = 2.5 CPU. This fits comfortably within 10 CPU total.

### Problem 3: PDB Slowing Rollout

**Symptom**: `kubectl rollout restart` takes forever. Pods are being replaced one at a time, very slowly.

```bash
kubectl rollout status deployment/product-catalog -n shopping
# Waiting for deployment "product-catalog" rollout to finish: 1 old replicas are pending termination...
# (stuck for minutes)
```

**Root Cause**: Our PodDisruptionBudget from Phase 4:
```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: product-catalog-pdb
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: product-catalog
```

With `minAvailable: 1` and `replicas: 2`, Kubernetes can only take down 1 pod at a time. During a rolling restart, it:
1. Terminates Pod A → waits for Pod B to confirm ready
2. Only then can create the new Pod A
3. Waits for new Pod A to be ready (sidecar needs to connect to istiod and get certs)
4. Then can terminate Pod B

Each pod takes longer to start now (sidecar initialization adds 10-30 seconds), so the entire rollout takes 2-5 minutes instead of 30 seconds.

**This is not a bug** — the PDB is working correctly. It's protecting availability during the rollout. The tradeoff is rollout speed vs availability guarantee.

**Mitigation options**:
1. **Accept it** — this is the safe behavior in production
2. **Increase replicas to 3** — with minAvailable:1 and 3 replicas, 2 can roll simultaneously
3. **Use maxUnavailable instead** — `maxUnavailable: 1` allows 1 pod to be down, meaning both can roll in parallel with 2 replicas
4. **Temporarily scale up** — `kubectl scale --replicas=3` before rollout, then scale back down

### Summary of Resource Changes

| Resource | Before Istio | After Istio | Why |
|----------|-------------|-------------|-----|
| LimitRange min CPU | 50m | 10m | Sidecar requests 10m |
| LimitRange max CPU | 1 | 2 | Sidecar default limit is 2 |
| LimitRange min memory | 64Mi | 40Mi | Sidecar init needs less |
| ResourceQuota limits.cpu | 6 | 10 | Sidecars add CPU per pod |
| ResourceQuota limits.memory | 6Gi | 12Gi | Sidecars add memory per pod |
| Deployment annotations | none | sidecar.istio.io/proxy* | Override sidecar defaults |

### Lesson Learned

Istio doesn't exist in a vacuum. When you have strict resource governance (LimitRanges, Quotas, PDBs), adding a service mesh creates conflicts. **Plan for sidecar resources before enabling injection**. In a real company, the platform team would set LimitRanges and Quotas knowing that Istio sidecars exist.

---

## 9. How Istio Compares to NetworkPolicies

We have BOTH NetworkPolicies (Phase 3b) and Istio AuthorizationPolicies. They don't replace each other — they complement each other as defense-in-depth.

### Layer Comparison

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    DEFENSE IN DEPTH                                       │
│                                                                         │
│  Layer 7 (Application):   Istio AuthorizationPolicy                     │
│  ─────────────────────────────────────────────────────────────────────  │
│  Controls: HTTP method, path, headers, source identity (SPIFFE)         │
│  Example: "Only checkout-sa can POST to /api/payment/process"           │
│  Enforced by: Envoy sidecar proxy                                       │
│                                                                         │
│  Layer 4 (Transport):     Istio PeerAuthentication (mTLS)               │
│  ─────────────────────────────────────────────────────────────────────  │
│  Controls: Encryption, mutual authentication                            │
│  Example: "All traffic must be encrypted with mutual TLS"               │
│  Enforced by: Envoy sidecar proxy                                       │
│                                                                         │
│  Layer 3/4 (Network):     Kubernetes NetworkPolicy                      │
│  ─────────────────────────────────────────────────────────────────────  │
│  Controls: IP-to-IP connectivity, port access                           │
│  Example: "Only pods with label app=checkout can reach port 5002"       │
│  Enforced by: CNI plugin (Calico, Cilium)                               │
│                                                                         │
│  Layer 2 (Data Link):     Node-level firewalls                          │
│  ─────────────────────────────────────────────────────────────────────  │
│  Controls: Node-to-node connectivity                                    │
│  Example: "Only nodes in the same VPC can communicate"                  │
│  Enforced by: Cloud provider / OS                                       │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Why Keep Both?

| Scenario | NetworkPolicy | Istio AuthzPolicy |
|----------|:---:|:---:|
| Pod without sidecar tries to reach payment | ✓ Blocks | ✗ Not enforced (no sidecar) |
| Compromised sidecar proxy | ✗ Can't help | ✗ Bypassed |
| Non-HTTP traffic (TCP, gRPC health) | ✓ Controls | ✗ Doesn't apply to raw TCP |
| Fine-grained HTTP method control | ✗ Can't see HTTP | ✓ Full HTTP inspection |
| Namespace isolation | ✓ Blocks cross-NS | ✓ Also blocks cross-NS |
| External traffic ingress | ✓ Controls | ✗ Only for mesh traffic |

**Bottom line**: NetworkPolicies are the first wall (can't even establish a connection). Istio AuthorizationPolicies are the second wall (even if you connect, you can't call unauthorized endpoints). If either fails, the other still protects you.

### Our Defense Layers for Payment Service

```
External attacker → NetworkPolicy DENIES (can't reach shopping namespace)
Cart service → NetworkPolicy ALLOWS port 5002 (it's in the namespace)
            → Istio AuthzPolicy DENIES (cart-sa not in allowed principals)
            → Request never reaches payment application

Checkout service → NetworkPolicy ALLOWS port 5002
                → Istio AuthzPolicy ALLOWS (checkout-sa + POST + /api/payment/process)
                → Request reaches payment application ✓
```

---

## 10. Real Company Usage

A senior DevOps engineer at a real company would use Istio for these patterns daily:

### Canary Releases

**The problem**: Deploying v2 to 100% of users at once is risky. If v2 has a bug, all users are affected.

**The solution**: Deploy v2 alongside v1, send 5-10% of traffic to v2, monitor error rates, and gradually increase.

```
Day 1:  v1 (95%) ████████████████████ | v2 (5%)  █
Day 2:  v1 (75%) ███████████████      | v2 (25%) █████
Day 3:  v1 (50%) ██████████           | v2 (50%) ██████████
Day 4:  v1 (0%)                       | v2 (100%) ████████████████████
```

At any point, if v2 shows elevated errors in Grafana, you change the weight back to 100% v1. Instant rollback, zero downtime.

### Fault Injection (Chaos Engineering)

**The problem**: You don't know how your system behaves when a service is slow or failing until it actually happens in production at 3am.

**The solution**: Inject artificial faults in staging to test resilience:

```yaml
# EXAMPLE: Inject 5-second delay into 10% of payment requests
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: payment-fault-injection
  namespace: shopping
spec:
  hosts:
    - payment-service
  http:
  - fault:
      delay:
        percentage:
          value: 10.0             # 10% of requests
        fixedDelay: 5s            # Get a 5-second delay
    route:
    - destination:
        host: payment-service
```

This lets you verify:
- Does checkout's timeout fire correctly?
- Does the frontend show a graceful error message?
- Does the circuit breaker trip?
- Do retries cause duplicate orders?

### A/B Testing (Header-Based Routing)

**The problem**: You want to test a new checkout UI with only internal employees before rolling out to users.

**The solution**: Route based on HTTP headers:

```yaml
# EXAMPLE: Route internal users to v2, everyone else to v1
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: checkout-ab-test
  namespace: shopping
spec:
  hosts:
    - checkout-service
  http:
  - match:
    - headers:
        x-internal-user:
          exact: "true"           # If this header is present...
    route:
    - destination:
        host: checkout-service
        subset: v2                # ...route to v2
  - route:
    - destination:
        host: checkout-service
        subset: v1                # Everyone else → v1
```

### Blue-Green Deployments

**The problem**: You want to switch ALL traffic from one version to another instantly (not gradually like canary).

**The solution**: Deploy the new version, verify it's healthy, then flip the switch:

```
BLUE (current):  100% traffic → v1 (blue)
                   0% traffic → v2 (green, deployed but receiving no traffic)

Run tests against v2 directly (port-forward or internal header routing)

GREEN (switch):    0% traffic → v1 (blue, still running as fallback)
                 100% traffic → v2 (green)

If anything goes wrong: instantly flip back to blue
```

### Traffic Mirroring (Shadow Traffic)

**The problem**: You want to test v2 with real production traffic without affecting users.

**The solution**: Mirror (copy) live traffic to v2, but only respond to users from v1:

```yaml
# EXAMPLE: Mirror traffic to v2 for testing
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: product-catalog-mirror
spec:
  hosts:
    - product-catalog-service
  http:
  - route:
    - destination:
        host: product-catalog-service
        subset: v1
      weight: 100
    mirror:
      host: product-catalog-service
      subset: v2
    mirrorPercentage:
      value: 100.0              # Mirror all traffic (responses discarded)
```

Users only see v1's response. But v2 receives the same requests, and you can monitor its error rate, latency, and resource usage in Grafana before promoting it.

---

## 11. CKA/CKS Exam Relevance

### CKA Exam Domains

Istio itself is NOT directly tested on CKA, but the concepts are foundational:

| Domain | Weight | What Istio Teaches You |
|--------|--------|----------------------|
| Cluster Architecture (25%) | High | Understanding control plane vs data plane, sidecars, admission webhooks |
| Workloads & Scheduling (15%) | Medium | Init containers (istio-init), multi-container pods, rolling updates with PDBs |
| Services & Networking (20%) | High | Service discovery, traffic routing, ingress, how services communicate |
| Troubleshooting (30%) | High | Debugging multi-container pods (2/2 vs 1/2), reading events, resource conflicts |
| Storage (10%) | Low | Certificate storage, secret volumes |

### CKS Exam Domains

Istio concepts map more directly to CKS (security-focused):

| Domain | Weight | What Istio Teaches You |
|--------|--------|----------------------|
| Cluster Hardening (15%) | High | mTLS, zero-trust networking, restricting inter-service communication |
| System Hardening (15%) | Medium | Admission controllers (mutating webhooks), pod security with sidecars |
| Minimize Microservice Vulnerabilities (20%) | High | Service mesh security, authorization policies, encrypted communication |
| Supply Chain Security (20%) | Low | Verifying sidecar image integrity |
| Monitoring, Logging, Runtime Security (20%) | Medium | Istio telemetry, access logs from Envoy, detecting unauthorized access |

### Key Concepts for Exams

**CKA**:
- Multi-container pods (sidecar pattern) — know how to describe a pod with 2+ containers
- Init containers — understand that `istio-init` runs before the main containers
- Admission webhooks — understand mutating vs validating webhooks
- Service types and DNS — how services discover each other (`service.namespace.svc.cluster.local`)
- PDBs — understand how they interact with rollouts

**CKS**:
- Mutual TLS — understand the difference between mTLS and one-way TLS
- Network Policies vs service mesh — know the layers and when each applies
- RBAC + ServiceAccounts — Istio uses K8s ServiceAccounts as identity
- Secrets management — understand how certificates are stored and rotated
- Runtime security — Envoy access logs show all traffic (audit trail)

### CKS Practice Question

> "A security audit requires that all inter-pod communication in the `production` namespace is encrypted. Implement this without modifying application code."

**Answer approach**:
1. Install Istio (or reference existing installation)
2. Label namespace: `kubectl label ns production istio-injection=enabled`
3. Restart deployments to inject sidecars
4. Apply PeerAuthentication with `mode: STRICT`
5. Verify with `istioctl authn tls-check`

---

## 12. Istio Commands Reference (istioctl)

### Installation & Profile

```bash
# ═══════════════════════════════════════════════════════════════
# Installation
# ═══════════════════════════════════════════════════════════════
istioctl install --set profile=demo -y        # Install with demo profile
istioctl install --set profile=default -y     # Install with default (production)
istioctl install --set profile=minimal -y     # Install minimal (istiod only)
istioctl manifest generate --set profile=demo # Preview what would be installed (dry run)
istioctl verify-install                       # Verify installation is healthy
istioctl x uninstall --purge                  # Completely remove Istio

# ═══════════════════════════════════════════════════════════════
# Pre-flight Checks
# ═══════════════════════════════════════════════════════════════
istioctl x precheck                           # Check cluster readiness before install
istioctl version                              # Show client and control plane versions
```

### Proxy & Mesh Status

```bash
# ═══════════════════════════════════════════════════════════════
# Proxy Status (are sidecars connected and synced?)
# ═══════════════════════════════════════════════════════════════
istioctl proxy-status                         # All proxies and their sync state
# SYNCED = good, STALE = proxy hasn't received latest config

istioctl proxy-status <pod-name>.<namespace>  # Status of a specific proxy

# ═══════════════════════════════════════════════════════════════
# Proxy Configuration (what config does a proxy have?)
# ═══════════════════════════════════════════════════════════════
istioctl proxy-config routes <pod>.<ns>       # Show routing rules the proxy knows
istioctl proxy-config clusters <pod>.<ns>     # Show upstream clusters
istioctl proxy-config endpoints <pod>.<ns>    # Show endpoint IPs
istioctl proxy-config listeners <pod>.<ns>    # Show listener ports
istioctl proxy-config bootstrap <pod>.<ns>    # Show bootstrap config
istioctl proxy-config secret <pod>.<ns>       # Show certificates (expiry, SAN)
```

### Debugging & Analysis

```bash
# ═══════════════════════════════════════════════════════════════
# Analyze (find configuration problems)
# ═══════════════════════════════════════════════════════════════
istioctl analyze                              # Analyze entire mesh for issues
istioctl analyze -n shopping                  # Analyze specific namespace
istioctl analyze --all-namespaces             # Analyze everything

# Common findings:
# ✗ VirtualService references non-existent gateway
# ✗ DestinationRule references non-existent subset
# ⚠ Pod missing sidecar (not injected)

# ═══════════════════════════════════════════════════════════════
# Auth & mTLS Debugging
# ═══════════════════════════════════════════════════════════════
istioctl authn tls-check <pod>.<ns>           # Check mTLS status for a pod
istioctl authz check <pod>.<ns>               # Check authorization status

# ═══════════════════════════════════════════════════════════════
# Describe (human-readable summary of Istio config affecting a pod)
# ═══════════════════════════════════════════════════════════════
istioctl x describe pod <pod-name> -n <ns>    # Full description of all Istio config
# Shows: VirtualServices, DestinationRules, PeerAuth, AuthzPolicies affecting this pod

# ═══════════════════════════════════════════════════════════════
# Dashboards (open observability UIs)
# ═══════════════════════════════════════════════════════════════
istioctl dashboard kiali                      # Service mesh visualization
istioctl dashboard grafana                    # Grafana dashboards
istioctl dashboard prometheus                 # Prometheus UI
istioctl dashboard jaeger                     # Distributed tracing
istioctl dashboard envoy <pod>.<ns>           # Envoy admin UI for a specific proxy
```

### Sidecar Management

```bash
# ═══════════════════════════════════════════════════════════════
# Injection
# ═══════════════════════════════════════════════════════════════
# Enable auto-injection for a namespace
kubectl label namespace <ns> istio-injection=enabled

# Disable auto-injection
kubectl label namespace <ns> istio-injection-

# Check if injection is enabled
kubectl get namespace -L istio-injection

# Manual injection (preview what the injected pod looks like)
istioctl kube-inject -f deployment.yaml | kubectl apply -f -

# ═══════════════════════════════════════════════════════════════
# Sidecar Resource Annotations (add to pod template)
# ═══════════════════════════════════════════════════════════════
# sidecar.istio.io/proxyCPU: "50m"            # CPU request
# sidecar.istio.io/proxyCPULimit: "500m"      # CPU limit
# sidecar.istio.io/proxyMemory: "64Mi"        # Memory request
# sidecar.istio.io/proxyMemoryLimit: "256Mi"  # Memory limit
# sidecar.istio.io/inject: "false"            # Opt-out for specific pod
```

### Quick Debugging Workflow

When something isn't working in the mesh, follow this checklist:

```bash
# 1. Is the sidecar injected?
kubectl get pod <pod> -n <ns> -o jsonpath='{.spec.containers[*].name}'
# Should include "istio-proxy"

# 2. Is the proxy synced with istiod?
istioctl proxy-status | grep <pod>
# Should show SYNCED for CDS, LDS, EDS, RDS

# 3. Are there configuration issues?
istioctl analyze -n <ns>

# 4. What does the proxy think the route is?
istioctl proxy-config routes <pod>.<ns> --name <service>

# 5. Can you see the certificates?
istioctl proxy-config secret <pod>.<ns>
# Check expiry and SPIFFE ID

# 6. Check Envoy access logs
kubectl logs <pod> -n <ns> -c istio-proxy --tail=50

# 7. Describe the full Istio config affecting this pod
istioctl x describe pod <pod> -n <ns>
```

---

## 13. Files Created in This Phase

```
online-microservices-test/
├── istio/
│   ├── peer-authentication.yaml       # Strict mTLS enforcement
│   ├── traffic-management.yaml        # VirtualServices + DestinationRules
│   │                                  # (retries, timeouts, circuit breakers)
│   └── authorization-policies.yaml    # Layer 7 access control
│                                      # (payment + shipping restricted)
├── k8s/
│   ├── limit-range.yaml               # Updated: min CPU lowered to 10m,
│   │                                  # max CPU raised to 2 for sidecar
│   └── resource-quota.yaml            # Updated: limits.cpu=10, limits.memory=12Gi
├── kind-cluster.yaml                  # Updated for Istio compatibility
├── istio-1.26.0/                      # Downloaded binary (GITIGNORED)
│   ├── bin/istioctl                   # CLI tool
│   ├── manifests/                     # Charts and templates
│   └── samples/                       # Example apps
└── docs/
    └── 06-istio-service-mesh.md       # This file
```

### File Details

| File | Purpose | Key Content |
|------|---------|-------------|
| `istio/peer-authentication.yaml` | Enforce encrypted communication | `mode: STRICT` — reject any unencrypted traffic |
| `istio/traffic-management.yaml` | Resilience patterns | Retries (3 attempts), timeouts (10-15s), circuit breakers (eject after 3 failures) |
| `istio/authorization-policies.yaml` | Access control | Payment only from checkout-sa POST, shipping only from checkout-sa POST |
| `k8s/limit-range.yaml` | Per-container resource boundaries | Min CPU lowered to 10m (from 50m) for sidecar compatibility |
| `k8s/resource-quota.yaml` | Namespace resource ceiling | CPU limits raised to 10 (from 6) to fit sidecar overhead |

---

## 14. How This Maps to a Real Company

### Day-to-Day as a Senior DevOps Engineer

| Task | How Istio Helps |
|------|----------------|
| Deploying a new version | Canary release: 5% → 25% → 50% → 100%, monitoring at each step |
| Incident response | Envoy access logs show exactly which requests failed, from where, to where |
| Security audit | mTLS certificates prove identity, authorization policies prove access control |
| Performance debugging | Per-request latency from Envoy metrics, breakdown by source/destination |
| Testing resilience | Fault injection in staging — see how the system behaves when payment is slow |
| Compliance (SOC2, PCI) | "All inter-service traffic is encrypted" — show PeerAuthentication + STRICT mode |
| Team onboarding | New service automatically gets mTLS, retries, observability — no extra work |

### What We Built vs What Production Needs

| This Project | Production |
|-------------|------------|
| Demo profile | Default or minimal profile |
| Sidecar injection | Consider ambient mesh (newer, no sidecars) |
| Basic VirtualServices | Full canary automation (Argo Rollouts + Istio) |
| Manual `istioctl` | GitOps with Flux/ArgoCD managing Istio resources |
| Self-signed CA | Integration with Vault or cloud KMS for root CA |
| In-cluster istiod | Multi-cluster mesh with shared control plane |
| No rate limiting | Envoy rate limiting per source/path/user |
| No telemetry export | OpenTelemetry → Datadog/Honeycomb/Lightstep |

---

## 15. Summary — What/Why/How Quick Reference

| Concept | What | Why | How |
|---------|------|-----|-----|
| Service Mesh | Infrastructure layer for service-to-service communication | Encryption, auth, resilience without code changes | Istio with Envoy sidecars |
| istiod | Control plane (cert management + config push) | Central authority for mesh configuration | Installed via `istioctl install` |
| Envoy sidecar | Data plane (intercepts all traffic) | Enforces policies transparently | Auto-injected via namespace label |
| mTLS | Mutual TLS between all services | Zero-trust: encrypt everything, verify everyone | PeerAuthentication `mode: STRICT` |
| VirtualService | Routing rules (retries, timeouts, traffic split) | Resilience + canary deployments | Applied via `kubectl apply` |
| DestinationRule | Circuit breakers + connection pools | Prevent cascade failures | Applied via `kubectl apply` |
| AuthorizationPolicy | Layer 7 access control (method + path + identity) | Fine-grained security beyond NetworkPolicies | Applied via `kubectl apply` |
| Sidecar injection | Adds Envoy to every pod in a namespace | Transparent mesh enrollment | `kubectl label ns ... istio-injection=enabled` |

---

## Next Steps

With the service mesh in place, future enhancements could include:
- **Argo Rollouts integration** — automated canary analysis (promote/rollback based on metrics)
- **Rate limiting** — protect APIs from abuse using Envoy's rate limit filter
- **External authorization** — integrate with OPA (Open Policy Agent) for complex policies
- **Multi-cluster mesh** — extend the mesh across multiple Kubernetes clusters
- **Ambient mesh** — Istio's new sidecar-less mode (L4 mesh at the node level)
- **OpenTelemetry** — distributed tracing across all meshed services
- **Wasm plugins** — extend Envoy behavior with custom WebAssembly filters
