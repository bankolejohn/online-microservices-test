# Phase 1: Running the Microservices Application with Docker Compose

## Overview

This document covers the complete process of getting our 7-microservice online shopping application running locally using Docker Compose. It includes the problems encountered, how they were solved, and how the application was validated end-to-end.

**Goal**: Prove that all services build correctly as Docker containers and can communicate with each other over a shared network — before moving to Kubernetes.

**Why Docker Compose first?**
- It validates that each Dockerfile builds correctly
- It confirms inter-service communication works (same pattern as Kubernetes — services talk via DNS names)
- It's faster to iterate on than Kubernetes (no abstraction layers to debug on top of app issues)
- If it works in Compose, migrating to K8s becomes purely an infrastructure concern

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Docker Network                           │
│                    (microservices bridge)                        │
│                                                                 │
│  ┌──────────────────┐                                          │
│  │   Frontend        │  Port 3000 → 80 (nginx)                 │
│  │   (React + Nginx) │                                          │
│  │                    │  Serves static React app                │
│  │   Reverse Proxy:   │  Proxies /api/* to backend services     │
│  │   /api/products → product-catalog:3001                      │
│  │   /api/cart     → cart:3002                                 │
│  │   /api/auth     → auth:3003                                 │
│  │   /api/checkout → checkout:5001                             │
│  │   /api/payment  → payment:5002                              │
│  │   /api/shipping → shipping:8080                             │
│  └──────────────────┘                                          │
│                                                                 │
│  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐   │
│  │ Product Catalog │  │  Cart Service  │  │  Auth Service  │   │
│  │ (Node.js)      │  │  (Node.js)     │  │  (Node.js)     │   │
│  │ Port 3001      │  │  Port 3002     │  │  Port 3003     │   │
│  └────────────────┘  └────────────────┘  └────────────────┘   │
│                                                                 │
│  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐   │
│  │ Checkout Svc   │  │ Payment Svc    │  │ Shipping Svc   │   │
│  │ (Python/Flask) │  │ (Python/Flask) │  │ (Go/Gin)       │   │
│  │ Port 5001      │  │ Port 5002      │  │ Port 8080      │   │
│  └────────────────┘  └────────────────┘  └────────────────┘   │
│                                                                 │
│  Checkout orchestrates: payment-service + shipping-service      │
└─────────────────────────────────────────────────────────────────┘
```

---

## What Was Done

### 1. Frontend Nginx Reverse Proxy Configuration

**What**: Updated `frontend-service/nginx.conf` to proxy API requests to backend services.

**Why**: The React frontend makes API calls using relative URLs (e.g., `/api/products`, `/api/cart/...`). When the app runs in the browser at `http://localhost:3000`, those requests hit the nginx container. Without proxy rules, nginx would return 404 for all `/api/*` routes.

**How**: Added `proxy_pass` directives for each backend service, using Docker Compose service names as hostnames (Docker's internal DNS resolves these automatically).

**File**: `frontend-service/nginx.conf`

```nginx
events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    server {
        listen 80;
        server_name localhost;
        root /usr/share/nginx/html;
        index index.html;

        # Serve React app - all non-API routes fall back to index.html (SPA routing)
        location / {
            try_files $uri $uri/ /index.html;
        }

        # Proxy API requests to backend services (resolved via Docker DNS)
        location /api/products {
            proxy_pass http://product-catalog:3001;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        location /api/cart {
            proxy_pass http://cart:3002;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        location /api/auth {
            proxy_pass http://auth:3003;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        location /api/checkout {
            proxy_pass http://checkout:5001;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        location /api/payment {
            proxy_pass http://payment:5002;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        location /api/shipping {
            proxy_pass http://shipping:8080;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }
    }
}
```

**Key concepts**:
- `proxy_pass` tells nginx to forward the request to another server
- Docker Compose creates a DNS entry for each service name (e.g., `product-catalog` resolves to that container's IP)
- `proxy_set_header Host $host` preserves the original host header
- `try_files $uri $uri/ /index.html` is essential for single-page apps — it serves `index.html` for all non-file routes so React Router handles client-side routing

---

### 2. Docker Compose Port Mapping Fix

**What**: Changed the frontend port mapping from `3000:3000` to `3000:80`.

**Why**: The frontend Dockerfile builds the React app and serves it via nginx on port 80 inside the container. The original docker-compose mapped host port 3000 to container port 3000, but nothing listens on port 3000 inside the container.

**How**: Updated `docker-compose.yml`:

```yaml
frontend:
  build: ./frontend-service
  ports:
    - "3000:80"  # Host port 3000 → Container port 80 (nginx)
```

**Key concept**: Docker port mapping format is `HOST_PORT:CONTAINER_PORT`. You access the app on your machine at `localhost:3000`, but inside the container, nginx listens on port 80.

---

### 3. Checkout Service Environment Variable

**What**: Added `CART_SERVICE_URL` environment variable to the checkout service in docker-compose.

**Why**: The checkout service's Python code defaults to `http://cart-service:3002` (the Kubernetes service name), but in Docker Compose the service is named `cart`. Without this override, the checkout service would fail when trying to clear the user's cart after a successful order.

**How**: Added to `docker-compose.yml`:

```yaml
checkout:
  environment:
    - CART_SERVICE_URL=http://cart:3002
    - PAYMENT_SERVICE_URL=http://payment:5002
    - SHIPPING_SERVICE_URL=http://shipping:8080
```

**Key concept**: Service names differ between Docker Compose and Kubernetes. Using environment variables for service URLs makes the code portable — you just override the env vars depending on the environment.

---

### 4. Shipping Service (Go) - Dockerfile Rebuild

**What**: Completely rewrote the shipping service Dockerfile and deleted the invalid `go.sum` file.

**Why**: The original project was generated by AI (Amazon Q Developer), which produced a `go.sum` file with fabricated checksums. Go's module system uses `go.sum` as a security mechanism to verify that downloaded dependencies match expected hashes. Since the hashes were fake, every build attempt failed with `SECURITY ERROR: checksum mismatch`.

**How**:

1. Deleted the invalid `go.sum` file entirely
2. Restructured the Dockerfile to let Go regenerate dependencies from source:

```dockerfile
# Build stage
FROM golang:1.22-alpine AS builder

WORKDIR /app

# Copy everything needed for the build
COPY go.mod ./
COPY *.go ./

# Resolve dependencies and build
RUN go mod tidy && \
    go mod download && \
    CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o main .

# Production stage
FROM alpine:latest

RUN apk --no-cache add ca-certificates
WORKDIR /root/

# Copy the binary from builder stage
COPY --from=builder /app/main .

EXPOSE 8080

CMD ["./main"]
```

3. Updated Go version from 1.21 to 1.22 in both `go.mod` and the Dockerfile because `gin v1.9.1`'s dependencies require at least Go 1.22.

**Key concepts**:
- `go.sum` is Go's dependency lock file with cryptographic hashes — never fabricate it
- `go mod tidy` resolves and downloads the exact versions needed based on your imports
- Multi-stage Docker builds: the builder stage compiles the binary, the production stage is a minimal Alpine image with just the binary (much smaller final image)
- `CGO_ENABLED=0` creates a statically linked binary that doesn't need libc (required for running on Alpine)
- `COPY *.go ./` instead of `COPY . .` avoids copying stale/invalid files from the host

---

## Troubleshooting Log

### Issue 1: Docker DNS Resolution Failure

**Symptom**: `docker-compose up --build` failed with:
```
failed to resolve source metadata for docker.io/library/alpine:latest:
dial tcp: lookup registry-1.docker.io: no such host
```

**Root cause**: Docker Desktop's internal VM lost DNS resolution. The host machine could reach Docker Hub (verified with `curl`), but Docker's build process couldn't.

**Diagnosis**:
```bash
# Host can resolve (works fine)
nslookup registry-1.docker.io
curl -s -o /dev/null -w "%{http_code}" https://registry-1.docker.io/v2/
# Returns 401 (expected - means connection works)

# But docker pull times out
docker pull alpine:latest  # hangs
```

**Fix**: Restarted Docker Desktop entirely. In some cases, adding DNS to Docker's daemon config helps:
```json
{
  "dns": ["8.8.8.8", "8.8.4.4"]
}
```
(Docker Desktop → Settings → Docker Engine)

---

### Issue 2: go.sum Checksum Mismatch

**Symptom**:
```
verifying github.com/google/uuid@v1.3.0: checksum mismatch
    downloaded: h1:t6JiXgmwXMjEs8VusXIJk2BXHsn+wx8BZdTaoZ5fu7I=
    go.sum:     h1:t6JiXuUQIp+llhl4hNvNJZiJKKUKjUNK+4zNBdNffrQ=
SECURITY ERROR
```

**Root cause**: The `go.sum` file was AI-generated with incorrect checksums. Go's module verification rejected the downloaded module because it didn't match the (fake) expected hash.

**Fix**: Deleted `go.sum` and let `go mod tidy` regenerate it during the Docker build.

---

### Issue 3: Go Toolchain Version Incompatibility

**Symptom**:
```
go: github.com/gin-gonic/gin@v1.12.0 requires go >= 1.25.0
(running go 1.21.13; GOTOOLCHAIN=local)
```

**Root cause**: When `go mod tidy` runs, it resolves the latest compatible version of dependencies. The latest gin (v1.12.0) requires Go 1.25+, but we specified `go 1.21` in `go.mod`.

**Fix**: Updated to `go 1.22` in both `go.mod` and the Dockerfile base image (`golang:1.22-alpine`). With Go 1.22, `go mod tidy` resolves gin v1.9.1 correctly (which is what we specified in `require`).

---

### Issue 4: Stale go.sum Overwriting Fresh One

**Symptom**: After fixing the Dockerfile to regenerate go.sum, the build still failed because `COPY . .` brought in the old bad `go.sum` from the host filesystem, overwriting the freshly generated one.

**Fix**: Changed `COPY . .` to `COPY *.go ./` to only copy source files, not the stale go.sum.

---

## Testing & Validation

### Prerequisites
- Docker Desktop running
- All containers up: `docker-compose up -d`

### Step 1: Verify All Containers Are Running

```bash
docker-compose ps
```

Expected output — all 7 services with status "Up":
```
NAME                                          STATUS    PORTS
online-microservices-test-auth-1              Up        0.0.0.0:3003->3003/tcp
online-microservices-test-cart-1              Up        0.0.0.0:3002->3002/tcp
online-microservices-test-checkout-1          Up        0.0.0.0:5001->5001/tcp
online-microservices-test-frontend-1          Up        0.0.0.0:3000->80/tcp
online-microservices-test-payment-1           Up        0.0.0.0:5002->5002/tcp
online-microservices-test-product-catalog-1   Up        0.0.0.0:3001->3001/tcp
online-microservices-test-shipping-1          Up        0.0.0.0:8080->8080/tcp
```

### Step 2: Health Check All Services

Each service exposes a `/health` endpoint. Test them directly (bypassing the frontend proxy):

```bash
curl -s http://localhost:3001/health
# {"status":"healthy","service":"product-catalog-service"}

curl -s http://localhost:3002/health
# {"status":"healthy","service":"cart-service"}

curl -s http://localhost:3003/health
# {"status":"healthy","service":"user-authentication-service"}

curl -s http://localhost:5001/health
# {"service":"checkout-service","status":"healthy"}

curl -s http://localhost:5002/health
# {"service":"payment-service","status":"healthy"}

curl -s http://localhost:8080/health
# {"service":"shipping-service","status":"healthy"}
```

### Step 3: Test Frontend Serves React App

```bash
curl -s -o /dev/null -w "HTTP %{http_code}" http://localhost:3000/
# HTTP 200
```

This confirms nginx is serving the built React app.

### Step 4: Test Nginx Proxy (API Through Frontend)

```bash
curl -s http://localhost:3000/api/products | python3 -m json.tool | head -10
```

Expected output (products proxied through nginx to product-catalog service):
```json
[
    {
        "id": 1,
        "name": "Wireless Headphones",
        "description": "High-quality wireless headphones with noise cancellation",
        "price": 199.99,
        "image": "https://images.unsplash.com/photo-1505740420928-5e560c06d30e?w=400"
    },
    ...
]
```

### Step 5: Test User Registration

```bash
curl -s -X POST http://localhost:3000/api/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com","password":"password123","name":"Test User"}'
```

Expected response:
```json
{
  "message": "User registered successfully",
  "token": "eyJhbGciOiJIUzI1NiIs...",
  "user": {
    "id": "1c7e94f5-708e-414b-b85e-ca615b9b9ed9",
    "email": "test@example.com",
    "name": "Test User"
  }
}
```

Save the `user.id` from the response — you'll need it for cart and checkout.

### Step 6: Test Add to Cart

Replace `USER_ID` with the ID from step 5:

```bash
curl -s -X POST "http://localhost:3000/api/cart/USER_ID/items" \
  -H "Content-Type: application/json" \
  -d '{"productId":1,"quantity":2,"price":199.99,"name":"Wireless Headphones"}'
```

Expected response:
```json
{
  "items": [
    {
      "id": "a00d8081-71ba-4393-bb53-c10fc2f6ca2d",
      "productId": 1,
      "name": "Wireless Headphones",
      "price": 199.99,
      "quantity": 2
    }
  ]
}
```

### Step 7: Test Get Cart

```bash
curl -s "http://localhost:3000/api/cart/USER_ID"
```

Should return the same cart contents as above.

### Step 8: Test Full Checkout (End-to-End)

This is the critical test — it exercises inter-service communication:
- Checkout service → Payment service (processes payment)
- Checkout service → Shipping service (creates shipment)
- Checkout service → Cart service (clears cart)

```bash
curl -s -X POST http://localhost:3000/api/checkout \
  -H "Content-Type: application/json" \
  -d '{
    "userId": "USER_ID",
    "items": [{"productId":1,"name":"Wireless Headphones","price":199.99,"quantity":2}],
    "total": 399.98,
    "shippingAddress": {
      "address": "123 Main St",
      "city": "Lagos",
      "zipCode": "100001"
    },
    "paymentDetails": {
      "cardNumber": "4111111111111111",
      "expiryDate": "12/25",
      "cvv": "123"
    }
  }'
```

Expected response (confirms all 3 backend services were called successfully):
```json
{
  "orderId": "f56caada-3e92-4cb5-98c5-a0e2e0803bb6",
  "status": "confirmed",
  "paymentId": "b0ad13cb-0991-41ee-820e-5c372260157c",
  "trackingNumber": "SHP956242088",
  "estimatedDelivery": "2026-07-15",
  "total": 399.98
}
```

### Step 9: Test Payment Failure (Negative Test)

Use the test card number for insufficient funds:

```bash
curl -s -X POST http://localhost:3000/api/checkout \
  -H "Content-Type: application/json" \
  -d '{
    "userId": "USER_ID",
    "items": [{"productId":1,"name":"Test","price":10,"quantity":1}],
    "total": 10,
    "shippingAddress": {"address": "123 St","city": "Test","zipCode": "00000"},
    "paymentDetails": {
      "cardNumber": "4000000000000002",
      "expiryDate": "12/25",
      "cvv": "123"
    }
  }'
```

Expected response:
```json
{
  "error": "Payment failed"
}
```

### Step 10: Access in Browser

Open http://localhost:3000 in your browser to use the full UI:
1. Register a new account
2. Browse the product catalog
3. Add items to your cart
4. Complete checkout with any card number (except `4000000000000002` and `4000000000000119`)
5. See your order confirmation with tracking number

---

## Stopping the Application

```bash
# Stop all containers (preserves built images)
docker-compose down

# Stop and remove all images too (full cleanup)
docker-compose down --rmi all

# View logs for a specific service (useful for debugging)
docker-compose logs -f checkout
docker-compose logs -f frontend
```

---

## Files Modified (Summary)

| File | Change |
|------|--------|
| `frontend-service/nginx.conf` | Added reverse proxy rules for all `/api/*` routes |
| `docker-compose.yml` | Fixed port mapping (3000:80), added CART_SERVICE_URL, removed unused REACT_APP_* env vars |
| `shipping-service/Dockerfile` | Complete rewrite: Go 1.22, multi-stage build, regenerate go.sum from source |
| `shipping-service/go.mod` | Updated to `go 1.22` |
| `shipping-service/go.sum` | Deleted (was AI-generated with invalid checksums) |

---

## Key Takeaways for Kubernetes

Everything we did here maps directly to Kubernetes concepts:

| Docker Compose | Kubernetes Equivalent |
|----------------|----------------------|
| Service name (e.g., `cart`) | Kubernetes Service name (e.g., `cart-service`) |
| `ports: "3000:80"` | Service `port` / `targetPort` |
| `environment:` vars | ConfigMap or Secret |
| `depends_on:` | Not directly — K8s uses readiness probes |
| `networks: microservices` | Kubernetes namespace + Pod networking |
| `docker-compose up` | `kubectl apply -k .` |
| Container health check | Liveness/Readiness probes |

The nginx reverse proxy pattern we used here is the same concept as a Kubernetes Ingress — both route traffic from a single entry point to multiple backend services based on URL path.

---

## Next: Moving to Kubernetes

With Docker Compose validated, we know:
- All container images build correctly
- All services start and respond on their expected ports
- Inter-service communication works (checkout → payment, checkout → shipping)
- The frontend proxy correctly routes to backends

The next phase deploys this same application to Kubernetes using minikube, where we'll learn about Pods, Deployments, Services, ConfigMaps, and Ingress controllers.
