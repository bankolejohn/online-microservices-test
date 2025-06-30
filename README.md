# Online Shopping Microservices Platform

A production-ready online shopping website built with microservices architecture and deployed on Kubernetes.

## Architecture Overview

This application consists of 7 microservices:

- **frontend-service**: React.js SPA with Tailwind CSS
- **product-catalog-service**: Node.js/Express API for product management
- **cart-service**: Node.js/Express API for shopping cart operations
- **checkout-service**: Python/Flask API for order processing
- **payment-service**: Python/Flask mock payment processor
- **user-authentication-service**: Node.js/Express JWT-based auth
- **shipping-service**: Go API for shipping simulation

## Project Structure

```
online-microservices-test/
├── README.md
├── kustomization.yaml
├── ingress.yaml
├── build-all.sh
├── deploy.sh
├── frontend-service/
│   ├── src/
│   │   ├── components/
│   │   ├── context/
│   │   ├── App.js
│   │   └── index.js
│   ├── public/
│   ├── Dockerfile
│   ├── package.json
│   └── k8s/
├── product-catalog-service/
│   ├── server.js
│   ├── package.json
│   ├── Dockerfile
│   └── k8s/
├── cart-service/
│   ├── server.js
│   ├── package.json
│   ├── Dockerfile
│   └── k8s/
├── user-authentication-service/
│   ├── server.js
│   ├── package.json
│   ├── Dockerfile
│   └── k8s/
├── checkout-service/
│   ├── app.py
│   ├── requirements.txt
│   ├── Dockerfile
│   └── k8s/
├── payment-service/
│   ├── app.py
│   ├── requirements.txt
│   ├── Dockerfile
│   └── k8s/
└── shipping-service/
    ├── main.go
    ├── go.mod
    ├── Dockerfile
    └── k8s/
```

## Prerequisites

- Docker
- minikube
- kubectl

## Minikube Deployment Guide

### Prerequisites Installation

```bash
# Install minikube (if not already installed)
brew install minikube

# Install kubectl (if not already installed)
brew install kubectl

# Verify Docker is running
docker --version
```

### Step 1: Start Minikube

```bash
# Start minikube with sufficient resources
minikube start --memory=4096 --cpus=4

# Enable ingress addon
minikube addons enable ingress

# Verify minikube is running
minikube status
```

### Step 2: Configure Docker Environment

```bash
# Point Docker to minikube's Docker daemon
eval $(minikube docker-env)

# Verify you're using minikube's Docker
docker ps
```

### Step 3: Build Docker Images

```bash
# Navigate to your project directory
cd /Users/bankolejohn/Documents/online-microservices-test

# Build all images using the script
./build-all.sh

# Verify images are built
docker images | grep -E "(frontend|product|cart|checkout|payment|user|shipping)"
```

### Step 4: Deploy to Kubernetes

```bash
# Deploy all services
./deploy.sh

# Wait for all pods to be ready (may take 2-3 minutes)
kubectl get pods -w
```

### Step 5: Access the Application

```bash
# Get minikube IP
minikube ip

# Check ingress status
kubectl get ingress shopping-ingress

# Open application in browser
open http://$(minikube ip)
```

### Troubleshooting Commands

```bash
# Check pod status
kubectl get pods

# View logs for specific service
kubectl logs -f deployment/frontend-service

# Check services
kubectl get services

# Restart a deployment if needed
kubectl rollout restart deployment/frontend-service
```

### Testing the Application

1. **Register a new user** at the login page
2. **Browse products** on the homepage
3. **Add items to cart** and view cart
4. **Complete checkout** using any card number (except test failure cards)
5. **View order confirmation** with tracking number

### Cleanup When Done

```bash
# Remove all resources
kubectl delete -k .

# Stop minikube
minikube stop
```

The application will be accessible at your minikube IP address (typically `http://192.168.49.2` or similar). The entire deployment process should take about 5-10 minutes depending on your system.

## API Endpoints

### Product Catalog Service (Port 3001)
- `GET /api/products` - Get all products
- `GET /api/products/:id` - Get product by ID

### Cart Service (Port 3002)
- `GET /api/cart/:userId` - Get user's cart
- `POST /api/cart/:userId/items` - Add item to cart
- `PUT /api/cart/:userId/items/:itemId` - Update item quantity
- `DELETE /api/cart/:userId/items/:itemId` - Remove item from cart

### User Authentication Service (Port 3003)
- `POST /api/auth/register` - Register new user
- `POST /api/auth/login` - User login
- `GET /api/auth/verify` - Verify JWT token

### Checkout Service (Port 5001)
- `POST /api/checkout` - Process order

### Payment Service (Port 5002)
- `POST /api/payment/process` - Process payment

### Shipping Service (Port 8080)
- `POST /api/shipping/create` - Create shipping order

## Features

### Frontend Features
- Responsive design with Tailwind CSS
- Product browsing and search
- Shopping cart management
- User authentication
- Checkout process
- Order confirmation

### Backend Features
- JWT-based authentication
- RESTful APIs
- Service-to-service communication
- Mock payment processing
- Shipping simulation
- Health checks and monitoring

## Development

Each service can be run independently for development:

```bash
cd <service-directory>
npm start  # for Node.js services
python app.py  # for Python services
go run main.go  # for Go services
```

## Testing

### Test Payment Cards
- Success: Any card number except test cards below
- Insufficient funds: `4000000000000002`
- Invalid card: `4000000000000119`

### Test User Registration
Register with any email/password combination through the frontend.

## Additional Commands

```bash
# View logs
kubectl logs -f deployment/<service-name>

# Scale services
kubectl scale deployment <service-name> --replicas=3

# Port forward for local testing
kubectl port-forward service/<service-name> <local-port>:<service-port>
```

## Production Considerations

For production deployment, consider:

1. **Security**: Use proper secrets management, HTTPS, and security policies
2. **Database**: Replace in-memory storage with persistent databases
3. **Monitoring**: Add proper logging, metrics, and alerting
4. **Scaling**: Configure HPA (Horizontal Pod Autoscaler)
5. **CI/CD**: Implement automated build and deployment pipelines
6. **Service Mesh**: Consider Istio for advanced traffic management
7. **Storage**: Use persistent volumes for stateful services