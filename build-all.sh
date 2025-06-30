#!/bin/bash

echo "Building all microservices Docker images..."

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
echo "To deploy to Kubernetes, run:"
echo "kubectl apply -k ."