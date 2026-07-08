#!/bin/bash

set -e  # Exit on any error

echo "Building all microservices Docker images..."

# Use host Docker daemon instead of minikube's
echo "Using host Docker daemon for building images..."

# Build frontend service
echo "Building frontend-service..."
cd frontend-service
docker build -t frontend-service:latest .
cd ..

# Build product catalog service
echo "Building product-catalog-service..."
cd product-catalog-service
docker build -t product-catalog-service:latest .
cd ..

# Build cart service
echo "Building cart-service..."
cd cart-service
docker build -t cart-service:latest .
cd ..

# Build user authentication service
echo "Building user-authentication-service..."
cd user-authentication-service
docker build -t user-authentication-service:latest .
cd ..

# Build checkout service
echo "Building checkout-service..."
cd checkout-service
docker build -t checkout-service:latest .
cd ..

# Build payment service
echo "Building payment-service..."
cd payment-service
docker build -t payment-service:latest .
cd ..

# Build shipping service
echo "Building shipping-service..."
cd shipping-service
docker build -t shipping-service:latest .
cd ..

echo "All Docker images built successfully!"
echo ""
echo "Loading images into minikube..."
minikube image load frontend-service:latest
minikube image load product-catalog-service:latest
minikube image load cart-service:latest
minikube image load user-authentication-service:latest
minikube image load checkout-service:latest
minikube image load payment-service:latest
minikube image load shipping-service:latest

echo ""
echo "Verifying images in minikube:"
minikube image ls | grep -E "(frontend|product|cart|checkout|payment|user|shipping)"
echo ""
echo "To deploy to Kubernetes, run:"
echo "kubectl apply -k ."