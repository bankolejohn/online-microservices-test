# Workload Migration: Minikube → Kind (Multi-Node Cluster)

## Overview

This document covers migrating our application from a single-node minikube cluster to a multi-node Kind (Kubernetes IN Docker) cluster with Calico CNI for NetworkPolicy support.

**Why we migrated**:
- Minikube's default CNI (bridge) does not enforce NetworkPolicies
- Minikube is single-node — can't practice node scheduling, affinity, taints/tolerations
- Kind is lighter, faster to create/destroy, and closer to real multi-node clusters
- CKA exam uses multi-node clusters — Kind prepares you better

**What changed**: Only the cluster tool. Zero application code changes. Zero manifest changes. This is the power of Kubernetes abstractions — the same YAML deploys to any conformant cluster.

---

## Key Concepts

### Kind (Kubernetes IN Docker)

**What**: A tool that creates Kubernetes clusters using Docker containers as nodes. Each "node" is a Docker container running the kubelet and containerd.

**Why Kind over Minikube**:

| Feature | Minikube | Kind |
|---------|----------|------|
| Multi-node | Experimental | First-class |
| CNI flexibility | Limited (addon-based) | Install anything |
| Speed | 1-2 min | 30-60 sec |
| Resource usage | Heavier (VM-like) | Lighter (containers) |
| CKA realism | Low (single node) | High (multi-node) |
| Image loading | `eval $(minikube docker-env)` or `minikube image load` | `kind load docker-image` |

### Calico

**What**: A CNI (Container Network Interface) plugin that provides networking and network security for Kubernetes pods.

**Why Calico**:
- Enforces NetworkPolicies (the default bridge/kindnet CNI does NOT)
- Industry standard — used in production by many companies
- Supports BGP routing, IPAM, and advanced policy features
- Required for our Phase 3 (NetworkPolicies)

### What is a CNI?

A CNI plugin is responsible for:
1. Assigning IP addresses to Pods
2. Setting up network routes between Pods (even across nodes)
3. Implementing NetworkPolicies (access control between Pods)

Without a CNI, pods can't communicate. That's why our nodes showed `NotReady` until Calico was installed.

---

## Migration Steps

### Step 1: Delete the Old Cluster

```bash
# Remove minikube entirely
minikube delete
```

**What this does**: Destroys the minikube VM/container, removes all Kubernetes resources, images, and configuration. Clean slate.

### Step 2: Install Kind

```bash
brew install kind

# Verify
kind version
# Expected: kind v0.32.0 ...
```

### Step 3: Create the Cluster Config

File: `kind-cluster.yaml`

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: shopping-cluster
networking:
  # Disable default CNI — we'll install Calico
  disableDefaultCNI: true
  # Pod subnet for Calico
  podSubnet: "192.168.0.0/16"
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30080
        hostPort: 80
        protocol: TCP
      - containerPort: 30443
        hostPort: 443
        protocol: TCP
  - role: worker
  - role: worker
  - role: worker
```

**Key decisions**:
- `disableDefaultCNI: true` — kindnet doesn't support NetworkPolicies. We'll install Calico instead.
- `podSubnet: "192.168.0.0/16"` — Calico's default expected subnet.
- 3 worker nodes — allows pod scheduling across nodes, practice affinity/taints.
- `extraPortMappings` — maps host ports to the control-plane node (for Ingress later).

### Step 4: Create the Cluster

```bash
kind create cluster --config kind-cluster.yaml

# Expected output:
# Creating cluster "shopping-cluster" ...
# ✓ Ensuring node image
# ✓ Preparing nodes
# ✓ Writing configuration
# ✓ Starting control-plane
# ✓ Installing StorageClass
# ✓ Joining worker nodes
# Set kubectl context to "kind-shopping-cluster"
```

### Step 5: Verify Nodes (They'll Be NotReady)

```bash
kubectl get nodes
# Expected:
# NAME                             STATUS     ROLES           AGE   VERSION
# shopping-cluster-control-plane   NotReady   control-plane   30s   v1.36.1
# shopping-cluster-worker          NotReady   <none>          10s   v1.36.1
# shopping-cluster-worker2         NotReady   <none>          10s   v1.36.1
# shopping-cluster-worker3         NotReady   <none>          10s   v1.36.1
```

**NotReady is expected** — no CNI means no pod networking.

### Step 6: Install Calico

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.3/manifests/calico.yaml
```

This installs:
- Calico CRDs (Custom Resource Definitions for network policies)
- calico-node DaemonSet (runs on every node — handles routing and policy enforcement)
- calico-kube-controllers (manages Calico resources)

### Step 7: Wait for Nodes to Become Ready

```bash
# Watch Calico pods come up
kubectl get pods -n kube-system -w

# Wait for all nodes
kubectl wait --for=condition=Ready nodes --all --timeout=180s

# Verify
kubectl get nodes
# All should show STATUS: Ready
```

### Step 8: Build and Load Images

With Kind, you build images on Docker Desktop (your host) then load them into the cluster:

```bash
# Build all 7 images on Docker Desktop
docker build -t frontend-service:latest ./frontend-service
docker build -t product-catalog-service:latest ./product-catalog-service
docker build -t cart-service:latest ./cart-service
docker build -t user-authentication-service:latest ./user-authentication-service
docker build -t checkout-service:latest ./checkout-service
docker build -t payment-service:latest ./payment-service
docker build -t shipping-service:latest ./shipping-service

# Load ALL images into Kind in one command
kind load docker-image \
  frontend-service:latest \
  product-catalog-service:latest \
  cart-service:latest \
  user-authentication-service:latest \
  checkout-service:latest \
  payment-service:latest \
  shipping-service:latest \
  --name shopping-cluster
```

**What `kind load` does**: Exports the image as a tarball from Docker Desktop, then imports it into every node in the Kind cluster. This is why we didn't need to change `imagePullPolicy: Never` in our manifests — same pattern as minikube.

### Step 9: Deploy the Application

```bash
# Same command as before — nothing changed in the manifests
kubectl apply -k .

# Wait for all pods
kubectl wait --for=condition=Ready pods --all -n shopping --timeout=60s
```

### Step 10: Verify E2E

```bash
# Port-forward to test
kubectl port-forward -n shopping service/frontend-service 8888:80

# In another terminal:
curl -s http://localhost:8888/api/products | python3 -c \
  "import sys,json; print(f'{len(json.load(sys.stdin))} products OK')"

# Test full checkout
curl -s -X POST http://localhost:8888/api/checkout \
  -H "Content-Type: application/json" \
  -d '{"userId":"test","items":[{"productId":1,"name":"Headphones","price":199.99,"quantity":1}],"total":199.99,"shippingAddress":{"address":"1 Kind Rd","city":"Node City","zipCode":"K8S"},"paymentDetails":{"cardNumber":"4242424242424242","expiryDate":"12/28","cvv":"321"}}'
# Expected: {"orderId":"...","status":"confirmed","trackingNumber":"..."}
```

---

## Verifying Multi-Node Distribution

One of the key benefits of Kind — pods spread across worker nodes:

```bash
kubectl get pods -n shopping -o custom-columns='POD:metadata.name,NODE:spec.nodeName'
```

Expected output shows pods on different workers:
```
POD                                            NODE
cart-service-xxx                               shopping-cluster-worker
cart-service-yyy                               shopping-cluster-worker3
checkout-service-xxx                           shopping-cluster-worker
checkout-service-yyy                           shopping-cluster-worker3
frontend-service-xxx                           shopping-cluster-worker
frontend-service-yyy                           shopping-cluster-worker2
...
```

The Kubernetes scheduler distributed pods across nodes for:
- **High availability** — if worker3 dies, pods on worker and worker2 keep running
- **Resource utilization** — spread load evenly
- **Fault tolerance** — no single point of failure

---

## Troubleshooting

### Nodes stuck in NotReady after Calico install

**Diagnosis**:
```bash
kubectl get pods -n kube-system | grep calico
# If pods are in Init or ImagePullBackOff, Calico images are still downloading
```

**Fix**: Wait. First-time Calico install pulls ~500MB of images. Give it 2-3 minutes.

### Images not found (ErrImagePull)

**Symptom**: Pods show `ImagePullBackOff`

**Diagnosis**:
```bash
# Check if images are loaded into Kind
docker exec shopping-cluster-worker crictl images | grep frontend
```

**Fix**: Reload images:
```bash
kind load docker-image frontend-service:latest --name shopping-cluster
```

### Kind cluster won't start

**Diagnosis**:
```bash
# Check Docker Desktop has enough resources
docker system info | grep -E "Memory|CPU"
# Need at least 8GB RAM and 4 CPUs for 4 nodes
```

**Fix**: Reduce to 2 workers if resources are tight:
```yaml
# kind-cluster.yaml
nodes:
  - role: control-plane
  - role: worker
  - role: worker
  # Remove the third worker
```

---

## Kind Cluster Management Commands

```bash
# List clusters
kind get clusters

# Delete a cluster
kind delete cluster --name shopping-cluster

# Recreate from scratch (fast — images cached after first time)
kind create cluster --config kind-cluster.yaml

# Get kubeconfig
kind get kubeconfig --name shopping-cluster

# Load an image after rebuild
kind load docker-image frontend-service:latest --name shopping-cluster

# Check Kind containers (Docker containers acting as nodes)
docker ps --filter "name=shopping-cluster"
```

---

## What We Learned

1. **Kubernetes is portable** — same manifests deployed to minikube and Kind without changes
2. **CNI matters** — without the right CNI, NetworkPolicies are just decorative YAML
3. **Multi-node scheduling** — Kubernetes automatically spreads pods for availability
4. **Image management differs per tool** — minikube uses `eval $(minikube docker-env)`, Kind uses `kind load`
5. **Migration is about infrastructure, not application** — zero code changes required

---

## CKA Exam Relevance

| Domain | What We Practiced |
|--------|-------------------|
| Cluster Architecture (25%) | Multi-node cluster setup, CNI installation, understanding control-plane vs workers |
| Workloads & Scheduling (15%) | Pod distribution across nodes (default scheduler behavior) |
| Troubleshooting (30%) | Diagnosing NotReady nodes, checking CNI status |
