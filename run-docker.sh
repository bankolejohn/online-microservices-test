#!/bin/bash

echo "🚀 Starting Online Shopping Microservices with Docker Compose..."
echo ""

# Check if Docker is running
if ! docker info > /dev/null 2>&1; then
    echo "❌ Docker is not running. Please start Docker first."
    exit 1
fi

# Build and start all services
echo "📦 Building and starting all services..."
docker-compose up --build

echo ""
echo "🎉 All services are starting up!"
echo ""
echo "📱 Access the application at: http://localhost:3000"
echo ""
echo "🔧 Individual service endpoints:"
echo "   Frontend:        http://localhost:3000"
echo "   Product Catalog: http://localhost:3001"
echo "   Cart Service:    http://localhost:3002"
echo "   Auth Service:    http://localhost:3003"
echo "   Checkout:        http://localhost:5001"
echo "   Payment:         http://localhost:5002"
echo "   Shipping:        http://localhost:8080"
echo ""
echo "🛑 To stop all services: Ctrl+C or run 'docker-compose down'"