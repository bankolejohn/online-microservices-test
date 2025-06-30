#!/bin/bash

echo "Deploying microservices to Kubernetes..."

# Apply all Kubernetes manifests
kubectl apply -k .

echo ""
echo "Deployment initiated. Checking status..."
echo ""

# Wait a moment for resources to be created
sleep 5

# Check deployment status
echo "Deployments:"
kubectl get deployments

echo ""
echo "Services:"
kubectl get services

echo ""
echo "Pods:"
kubectl get pods

echo ""
echo "Ingress:"
kubectl get ingress

echo ""
echo "To check logs for a specific service, run:"
echo "kubectl logs -f deployment/<service-name>"
echo ""
echo "To access the application, get the ingress IP:"
echo "kubectl get ingress shopping-ingress"