# Phase 1: Deploying to Kubernetes with Minikube

## Overview

This document covers deploying our 7-microservice online shopping application to Kubernetes using minikube. Every concept is explained with what/why/how so anyone learning Kubernetes can follow along and understand the reasoning.

**Goal**: Take the same application that works in Docker Compose and deploy it to a Kubernetes cluster, learning every core K8s concept along the way.

**Prerequisites**:
- Docker Desktop installed and running
- minikube installed (`brew install minikube`)
- kubectl installed (`brew install kubectl`)
- All Docker images building successfully (see `docs/01-docker-compose-setup.md`)

---

## Kubernetes Core Concepts (What You Need to Know First)

Before we deploy, let's understand the building blocks:

### Pod
**What**: The smallest deployable unit in Kubernetes. A Pod wraps one or more containers.
**Why**: Kubernetes doesn't manage containers directly — it manages Pods. A Pod gives containers a shared network namespace (they can talk via `localhost`) and shared storage.
**Analogy**: If a container is a person, a Pod is an apartment. People in the same apartment share the same address and kitchen.

### Deployment
**What**: A controller that manages a set of identical Pods (replicas). It ensures the desired number of Pods are always running.
**Why**: If a Pod crashes, the Deployment automatically creates a new one. It also handles rolling updates (zero-downtime deployments).
**Analogy**: A Deployment is like a manager who ensures exactly N workers are always on shift. If one calls in sick, the manager hires a replacement.

### Service
**What**: A stable network endpoint (IP + DNS name) that routes traffic to a set of Pods.
**Why**: Pods are ephemeral — they get new IP addresses when recreated. A Service provides a fixed DNS name (e.g., `cart-service`) that always routes to healthy Pods, regardless of which specific Pods are running.
**Analogy**: A Service is like a phone number for a department. You call the number and get connected to any available agent — you don't care which specific person answers.

### Ingress
**What**: A rule that defines how external traffic (from outside the cluster) reaches Services inside the cluster.
**Why**: Services are internal by default (ClusterIP). Ingress provides a single entry point with path-based routing, SSL termination, and load balancing for external traffic.
**Analogy**: An Ingress is like the front door/reception of an office building. All visitors enter through one door, and the receptionist directs them to the right department.

### Namespace
**What**: A virtual partition of the cluster. Resources in different namespaces are isolated.
**Why**: Organize resources, apply access controls, prevent naming conflicts between teams.
**Default**: We use the `default` namespace for this project. The ingress controller lives in `ingress-nginx`.

### Kustomize
**What**: A tool built into kubectl that lets you manage multiple YAML manifests as a unit.
**Why**: Instead of running `kubectl apply -f` on 15 separate files, you run `kubectl apply -k .` once. It reads `kustomization.yaml` to know which files to apply.

---

## Architecture on Kubernetes

```
┌───────────────────────────────────────────────────────────────────────┐
│                        Minikube Cluster                                │
│                                                                       │
│  ┌─────────────────────────────────────────────────────────────────┐ │
│  │  Ingress Controller (nginx)                                      │ │
│  │  Listens on port 80, routes to Services based on Ingress rules   │ │
│  └──────────────────────────────┬──────────────────────────────────┘ │
│                                 │                                     │
│                                 │ path: / → frontend-service:80       │
│                                 ▼                                     │
│  ┌─────────────────────────────────────────────────────────────────┐ │
│  │  Frontend Service (ClusterIP :80)                                │ │
│  │  ┌─────────────┐  ┌─────────────┐                              │ │
│  │  │   Pod 1     │  │   Pod 2     │  (nginx + React SPA)         │ │
│  │  │  nginx:80   │  │  nginx:80   │                              │ │
│  │  └─────────────┘  └─────────────┘                              │ │
│  │  nginx proxies /api/* to backend K8s Services                    │ │
│  └──────────┬──────────┬──────────┬──────────┬────────────────────┘ │
│             │          │          │          │                       │
│     ┌───────┘    ┌─────┘    ┌─────┘    ┌─────┘                     │
│     ▼            ▼          ▼          ▼                            │
│  ┌──────┐   ┌──────┐   ┌──────┐   ┌──────────┐                    │
│  │Prod. │   │Cart  │   │Auth  │   │ Checkout  │                    │
│  │Catlog│   │Svc   │   │Svc   │   │ Service   │                    │
│  │:3001 │   │:3002 │   │:3003 │   │  :5001    │                    │
│  └──────┘   └──────┘   └──────┘   └─────┬─────┘                    │
│                                          │                           │
│                                    ┌─────┴─────┐                    │
│                                    ▼           ▼                     │
│                              ┌──────────┐ ┌──────────┐              │
│                              │ Payment  │ │ Shipping │              │
│                              │  :5002   │ │  :8080   │              │
│                              └──────────┘ └──────────┘              │
│                                                                       │
│  Each Service has 2 Pods (replicas) behind it                        │
│  Total: 14 Pods running                                              │
└───────────────────────────────────────────────────────────────────────┘
```

---

## Step-by-Step Deployment

### Step 1: Start Minikube

**What**: Create a local single-node Kubernetes cluster.

**Why**: Minikube runs a full Kubernetes environment on your machine. It's designed for learning and local development.

**How**:

```bash
# Delete any existing cluster with driver issues
minikube delete

# Start fresh with Docker driver (recommended for macOS)
minikube start --driver=docker --memory=4096 --cpus=4
```

**Verify it's running**:
```bash
minikube status
# Expected:
# minikube
# type: Control Plane
# host: Running
# kubelet: Running
# apiserver: Running
# kubeconfig: Configured

kubectl cluster-info
# Expected: Kubernetes control plane is running at https://127.0.0.1:XXXXX

kubectl get nodes
# Expected:
# NAME       STATUS   ROLES           AGE   VERSION
# minikube   Ready    control-plane   Xs    v1.32.0
```

**Key flags explained**:
- `--driver=docker`: Uses Docker as the VM/container technology to run the cluster node
- `--memory=4096`: Allocates 4GB RAM to the cluster (we run 14 pods, so this is needed)
- `--cpus=4`: Allocates 4 CPU cores

---

### Step 2: Build Docker Images Inside Minikube

**What**: Build all 7 service images directly inside minikube's Docker daemon.

**Why**: Kubernetes pods can only use images that exist in their runtime's image store. Minikube has its own Docker daemon, separate from Docker Desktop on your host. Images built on Docker Desktop are NOT visible to minikube.

**How**:

```bash
# Switch your Docker CLI to talk to minikube's Docker daemon
eval $(minikube docker-env)

# Verify you're now inside minikube
docker info --format '{{.Name}}'
# Expected: minikube

# Navigate to project root
cd /path/to/online-microservices-test

# Build all 7 images
docker build -t frontend-service:latest ./frontend-service
docker build -t product-catalog-service:latest ./product-catalog-service
docker build -t cart-service:latest ./cart-service
docker build -t user-authentication-service:latest ./user-authentication-service
docker build -t checkout-service:latest ./checkout-service
docker build -t payment-service:latest ./payment-service
docker build -t shipping-service:latest ./shipping-service

# Verify all images exist
docker images | grep -E "(frontend|product|cart|user-auth|checkout|payment|shipping)"
```

**Understanding the Two Docker Daemons**:

```
┌─────────────────────────────────────┐
│  Your Mac                           │
│                                     │
│  Docker Desktop ← docker-compose    │
│  (Host Docker)    builds go here    │
│                                     │
│  Minikube       ← kubectl/K8s       │
│  (K8s Docker)     needs images here │
│                                     │
└─────────────────────────────────────┘
```

`eval $(minikube docker-env)` temporarily redirects your `docker` CLI to minikube's daemon. Run `eval $(minikube docker-env --unset)` to switch back.

**Alternative method** (slower but doesn't require env switch):
```bash
# Build on Docker Desktop, then copy into minikube
docker build -t frontend-service:latest ./frontend-service
minikube image load frontend-service:latest
```

---

### Step 3: Understand the Kubernetes Manifests

Before deploying, let's understand what each file does.

#### Deployment Manifest (e.g., `cart-service/k8s/deployment.yaml`)

```yaml
apiVersion: apps/v1          # Which K8s API group this resource belongs to
kind: Deployment              # The type of resource
metadata:
  name: cart-service          # Unique name for this Deployment
  labels:
    app: cart-service         # Labels for organizing/selecting resources
spec:
  replicas: 2                 # Run 2 identical Pods (for high availability)
  selector:
    matchLabels:
      app: cart-service       # "Manage Pods that have this label"
  template:                   # Template for creating Pods
    metadata:
      labels:
        app: cart-service     # Pods get this label (matches selector above)
    spec:
      containers:
      - name: cart-service
        image: cart-service:latest     # Docker image to run
        imagePullPolicy: Never         # Don't try to pull from registry (use local)
        ports:
        - containerPort: 3002          # Port the app listens on inside the container
        env:
        - name: PORT                   # Environment variable passed to the app
          value: "3002"
        resources:
          requests:                    # Minimum resources guaranteed
            memory: "128Mi"
            cpu: "100m"               # 100 millicores = 0.1 CPU
          limits:                      # Maximum resources allowed
            memory: "256Mi"
            cpu: "200m"
        livenessProbe:                 # "Is the container alive?"
          httpGet:                     # K8s hits this endpoint to check
            path: /health
            port: 3002
          initialDelaySeconds: 30      # Wait 30s before first check
          periodSeconds: 10            # Check every 10s
        readinessProbe:                # "Is the container ready to receive traffic?"
          httpGet:
            path: /health
            port: 3002
          initialDelaySeconds: 5       # Wait 5s before first check
          periodSeconds: 5             # Check every 5s
```

**Key fields explained**:
- `imagePullPolicy: Never` — Critical for minikube. Without this, K8s would try to pull from Docker Hub and fail (our images aren't published there).
- `resources.requests` — What the scheduler uses to place the Pod on a node. "I need at least this much."
- `resources.limits` — Hard ceiling. If the container exceeds this, it gets OOM-killed (memory) or throttled (CPU).
- `livenessProbe` — If this fails, K8s restarts the container. Catches deadlocks.
- `readinessProbe` — If this fails, the Service stops sending traffic to this Pod. Catches startup time.

#### Service Manifest (e.g., `cart-service/k8s/service.yaml`)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: cart-service          # This becomes the DNS name: cart-service.default.svc.cluster.local
  labels:
    app: cart-service
spec:
  selector:
    app: cart-service          # Route traffic to Pods with this label
  ports:
  - port: 3002                 # Port the Service listens on
    targetPort: 3002           # Port on the Pod to forward to
    protocol: TCP
  type: ClusterIP              # Internal-only IP (not accessible outside cluster)
```

**Key fields explained**:
- `selector: app: cart-service` — The Service finds Pods by label matching. Any Pod with `app: cart-service` receives traffic from this Service.
- `type: ClusterIP` — Default. The Service gets a cluster-internal IP. Other pods access it via DNS: `http://cart-service:3002`
- Service types: `ClusterIP` (internal), `NodePort` (external via node port), `LoadBalancer` (external via cloud LB)

#### Ingress Manifest (`ingress.yaml`)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shopping-ingress
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "10m"  # Allow larger request bodies
spec:
  ingressClassName: nginx       # Which Ingress Controller handles this
  rules:
  - http:
      paths:
      - path: /                 # Match all paths
        pathType: Prefix
        backend:
          service:
            name: frontend-service   # Route to frontend Service
            port:
              number: 80
```

**Design decision**: We route ALL traffic to the frontend. The frontend's nginx handles API routing internally. This is the most common production pattern — a single entry point with internal routing.

#### Kustomization (`kustomization.yaml`)

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:                      # All manifest files to apply
  - frontend-service/k8s/deployment.yaml
  - frontend-service/k8s/service.yaml
  - product-catalog-service/k8s/deployment.yaml
  - product-catalog-service/k8s/service.yaml
  # ... all other services
  - ingress.yaml
```

---

### Step 4: Deploy to Kubernetes

**What**: Apply all manifests to create Deployments, Services, and the Ingress.

**How**:

```bash
# Deploy everything with one command
kubectl apply -k .

# Expected output:
# service/cart-service created
# service/checkout-service created
# service/frontend-service created
# service/payment-service created
# service/product-catalog-service created
# service/shipping-service created
# service/user-authentication-service created
# deployment.apps/cart-service created
# deployment.apps/checkout-service created
# deployment.apps/frontend-service created
# deployment.apps/payment-service created
# deployment.apps/product-catalog-service created
# deployment.apps/shipping-service created
# deployment.apps/user-authentication-service created
# ingress.networking.k8s.io/shopping-ingress created
```

**Verify Pods are running**:
```bash
kubectl get pods
# Wait until all show READY 1/1 and STATUS Running
# Should see 14 pods (2 replicas × 7 services)
```

**Verify Deployments**:
```bash
kubectl get deployments
# All should show READY 2/2
```

**Verify Services**:
```bash
kubectl get services
# All should have CLUSTER-IP assigned
```

---

### Step 5: Enable the Ingress Controller

**What**: Install the nginx Ingress Controller so our Ingress resource actually works.

**Why**: An Ingress resource is just a configuration document. It needs a controller (a running program) that reads Ingress resources and configures routing accordingly. Without a controller, the Ingress does nothing.

**How**:

```bash
# Enable the minikube ingress addon
minikube addons enable ingress

# Wait for the controller to be ready
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

# Verify
kubectl get pods -n ingress-nginx
# Should show ingress-nginx-controller with STATUS Running

# Check our ingress picked up an address
kubectl get ingress
# Expected:
# NAME               CLASS   HOSTS   ADDRESS        PORTS   AGE
# shopping-ingress   nginx   *       192.168.49.2   80      Xm
```

---

### Step 6: Access the Application

There are multiple ways to access your app running in minikube:

#### Method 1: Port-forward to a specific Service (best for debugging)

```bash
# Access frontend directly
kubectl port-forward service/frontend-service 3000:80
# Then open http://localhost:3000

# Access a backend service directly
kubectl port-forward service/product-catalog-service 3001:3001
# Then curl http://localhost:3001/api/products
```

#### Method 2: Port-forward to Ingress Controller (tests full routing)

```bash
# Forward to the ingress controller
kubectl port-forward -n ingress-nginx service/ingress-nginx-controller 8080:80
# Then open http://localhost:8080
```

#### Method 3: Minikube Tunnel (maps to localhost:80, requires sudo)

```bash
minikube tunnel
# Requires sudo password for privileged port 80
# Then open http://localhost (or http://127.0.0.1)
```

---

## Testing & Validation

### Test 1: Health Checks via Port-Forward

```bash
# Port-forward to frontend
kubectl port-forward service/frontend-service 8888:80 &

# Test frontend serves HTML
curl -s -o /dev/null -w "HTTP %{http_code}" http://localhost:8888/
# Expected: HTTP 200

# Test API proxying (frontend → product-catalog via K8s DNS)
curl -s http://localhost:8888/api/products | python3 -m json.tool | head -10
# Expected: JSON array of products
```

### Test 2: User Registration (frontend → auth-service)

```bash
curl -s -X POST http://localhost:8888/api/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"k8s-test@example.com","password":"password123","name":"K8s Test User"}'
```

Expected response:
```json
{
  "message": "User registered successfully",
  "token": "eyJhbGciOi...",
  "user": {
    "id": "63733419-6af5-459a-99b3-d1acc0d184e4",
    "email": "k8s-test@example.com",
    "name": "K8s Test User"
  }
}
```

### Test 3: Full Checkout (checkout → payment + shipping)

```bash
curl -s -X POST http://localhost:8888/api/checkout \
  -H "Content-Type: application/json" \
  -d '{
    "userId": "USER_ID_FROM_STEP_ABOVE",
    "items": [
      {"productId": 1, "name": "Wireless Headphones", "price": 199.99, "quantity": 1},
      {"productId": 2, "name": "Smart Watch", "price": 299.99, "quantity": 2}
    ],
    "total": 799.97,
    "shippingAddress": {
      "address": "789 Ingress Ave",
      "city": "Cluster Town",
      "zipCode": "K8S01"
    },
    "paymentDetails": {
      "cardNumber": "4242424242424242",
      "expiryDate": "01/28",
      "cvv": "999"
    }
  }'
```

Expected response:
```json
{
  "orderId": "3de5ddc0-e70d-42a7-be6d-b5fd6311bda2",
  "status": "confirmed",
  "paymentId": "ffa788e6-5c0e-4e1c-9f90-da175a027536",
  "trackingNumber": "SHP483038948",
  "estimatedDelivery": "2026-07-11",
  "total": 799.97
}
```

This confirms the full inter-service communication chain works within Kubernetes:
- Frontend nginx → resolves `checkout-service` via CoreDNS → routes to checkout Pod
- Checkout Pod → resolves `payment-service` via CoreDNS → routes to payment Pod
- Checkout Pod → resolves `shipping-service` via CoreDNS → routes to shipping Pod

### Test 4: Via Ingress (full production path)

```bash
# Port-forward to ingress controller
kubectl port-forward -n ingress-nginx service/ingress-nginx-controller 8080:80 &

# Test full path: Ingress → Frontend → Backend
curl -s http://localhost:8080/api/products | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(f'{len(d)} products via Ingress')"
# Expected: 10 products via Ingress
```

---

## Troubleshooting Guide

### Issue 1: Pods in `ImagePullBackOff` or `ErrImagePull`

**Symptom**:
```
NAME                    READY   STATUS             RESTARTS   AGE
cart-service-xxx        0/1     ImagePullBackOff   0          30s
```

**Root cause**: Kubernetes is trying to pull the image from Docker Hub, but it doesn't exist there.

**Fix**: Ensure `imagePullPolicy: Never` is set in the deployment manifest AND the image was built inside minikube's Docker:
```bash
# Check you're building in minikube's Docker
eval $(minikube docker-env)
docker images | grep cart-service
# Should show the image

# If missing, rebuild it
docker build -t cart-service:latest ./cart-service
```

### Issue 2: Pods in `CrashLoopBackOff`

**Symptom**: Pod keeps restarting.

**Diagnosis**:
```bash
# Check what's happening
kubectl describe pod <pod-name>

# Check application logs
kubectl logs <pod-name>

# If the pod already crashed, check previous logs
kubectl logs <pod-name> --previous
```

**Common causes**:
- App failing to start (wrong port, missing env var)
- Liveness probe failing (app takes too long to start → increase `initialDelaySeconds`)
- OOM killed (app exceeds memory limit → increase `resources.limits.memory`)

### Issue 3: Service not reachable from another Pod

**Symptom**: Checkout can't reach payment-service.

**Diagnosis**:
```bash
# Exec into a pod to test DNS
kubectl exec -it <checkout-pod-name> -- sh

# Inside the pod, try to reach the other service
wget -qO- http://payment-service:5002/health
# If this fails, DNS or the Service is misconfigured

# Check if the Service exists and has endpoints
kubectl get endpoints payment-service
# Should show Pod IPs. If empty, the Service selector doesn't match Pod labels.
```

### Issue 4: Ingress has no ADDRESS

**Symptom**: `kubectl get ingress` shows empty ADDRESS column.

**Fix**:
1. Check ingress controller is running: `kubectl get pods -n ingress-nginx`
2. Ensure `ingressClassName: nginx` is set in the Ingress manifest
3. Check IngressClass exists: `kubectl get ingressclass`

### Issue 5: Minikube won't start (hyperkit/docker issues)

**Fix**: Nuclear option — delete and recreate:
```bash
minikube delete
minikube start --driver=docker --memory=4096 --cpus=4
```

### Issue 6: Cart service inconsistency (add item, then can't find it)

**Symptom**: POST to add item succeeds, but GET shows empty cart.

**Root cause**: Cart has 2 replicas with in-memory storage. POST hits Pod A, GET hits Pod B (which has no data). Kubernetes Services load-balance across replicas.

**This is expected** with in-memory state and multiple replicas. Solutions:
- Scale to 1 replica (`kubectl scale deployment cart-service --replicas=1`)
- Use a shared data store (Redis, database) — covered in later phases
- Use session affinity (`service.spec.sessionAffinity: ClientIP`)

---

## Useful kubectl Commands (CKA Exam Reference)

### Viewing Resources
```bash
kubectl get pods                          # List all pods
kubectl get pods -o wide                  # Show node, IP details
kubectl get all                           # Show pods, services, deployments
kubectl get pods -n ingress-nginx         # Pods in specific namespace
kubectl describe pod <name>               # Detailed pod info
kubectl describe service <name>           # Service details + endpoints
```

### Logs & Debugging
```bash
kubectl logs <pod-name>                   # View pod logs
kubectl logs <pod-name> -f                # Stream logs (follow)
kubectl logs deployment/cart-service      # Logs from any pod in deployment
kubectl exec -it <pod-name> -- sh         # Shell into a running pod
kubectl top pods                          # CPU/memory usage (requires metrics-server)
```

### Scaling & Updates
```bash
kubectl scale deployment cart-service --replicas=3   # Scale up
kubectl rollout status deployment/cart-service       # Watch rollout progress
kubectl rollout restart deployment/cart-service      # Restart all pods
kubectl rollout undo deployment/cart-service         # Rollback to previous version
```

### Port Forwarding & Access
```bash
kubectl port-forward service/frontend-service 3000:80     # Access service locally
kubectl port-forward pod/<pod-name> 3001:3001             # Access specific pod
```

### Cleanup
```bash
kubectl delete -k .                       # Remove all resources
kubectl delete pod <pod-name>             # Delete specific pod (Deployment recreates it)
kubectl delete deployment cart-service    # Delete the deployment + its pods
minikube stop                             # Stop the cluster (preserves state)
minikube delete                           # Destroy the cluster entirely
```

---

## How Kubernetes DNS Works (Key Concept)

When you create a Service named `cart-service` in the `default` namespace, Kubernetes (CoreDNS) automatically creates DNS records:

```
cart-service                           → 10.104.159.137  (short form, same namespace)
cart-service.default                   → 10.104.159.137  (with namespace)
cart-service.default.svc               → 10.104.159.137  (with svc subdomain)
cart-service.default.svc.cluster.local → 10.104.159.137  (fully qualified)
```

Inside our nginx config, `proxy_pass http://cart-service:3002` works because:
1. nginx resolves `cart-service` using the Pod's `/etc/resolv.conf`
2. `/etc/resolv.conf` points to CoreDNS (the cluster DNS)
3. CoreDNS returns the Service's ClusterIP (`10.104.159.137`)
4. Traffic goes to that IP, which load-balances across all Pods matching the Service selector

This is the same pattern as Docker Compose DNS, just a different DNS server (CoreDNS vs Docker's embedded DNS).

---

## What We Changed from Docker Compose

| Change | Reason |
|--------|--------|
| nginx.conf: proxy targets changed to K8s service names | Docker Compose names were `cart`, `auth`, etc. K8s names are `cart-service`, `user-authentication-service`, etc. |
| docker-compose.yml: service names updated to match K8s | Keeps one nginx config working in both environments |
| ingress.yaml: simplified to route all to frontend | Frontend already handles /api/* routing internally |
| ingress.yaml: added `ingressClassName: nginx` | Required for the controller to pick up the Ingress |

---

## Key Differences: Docker Compose vs Kubernetes

| Aspect | Docker Compose | Kubernetes |
|--------|---------------|------------|
| Scale | Manual (`docker-compose up --scale`) | Declarative (`replicas: 2`) |
| Self-healing | None (container dies = it's dead) | Automatic restart via Deployment controller |
| Health checks | Basic Docker healthcheck | Liveness + Readiness probes with separate behaviors |
| Service discovery | Docker DNS (container name) | CoreDNS (service name) |
| Load balancing | Round-robin by Docker | kube-proxy (iptables/IPVS rules) |
| External access | Port mapping (`3000:80`) | Ingress + Ingress Controller |
| Config | `docker-compose.yml` (one file) | Multiple YAML manifests (deployment, service, ingress) |
| Rollbacks | None built-in | `kubectl rollout undo` |
| Resource limits | Optional | Best practice (scheduler needs them) |

---

## CKA Exam Relevance

This phase covers these CKA domains:

| Domain | Weight | What We Practiced |
|--------|--------|-------------------|
| Cluster Architecture, Installation & Configuration | 25% | minikube setup, understanding control plane components |
| Workloads & Scheduling | 15% | Deployments, replicas, resource requests/limits |
| Services & Networking | 20% | ClusterIP Services, DNS, Ingress, port-forwarding |
| Troubleshooting | 30% | Pod debugging, logs, describe, exec |

---

## Next Steps

With the basics working, Phase 2 will cover:
- **ConfigMaps & Secrets** — externalize configuration (JWT secret, service URLs)
- **Namespaces** — organize resources properly
- **NetworkPolicies** — restrict which services can talk to each other
- **Persistent storage** — replace in-memory data with persistent databases
- **RBAC** — service accounts and role-based access control
