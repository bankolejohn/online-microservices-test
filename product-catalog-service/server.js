const express = require('express');
const cors = require('cors');
const helmet = require('helmet');

const app = express();
const PORT = process.env.PORT || 3001;

// Middleware
app.use(helmet());
app.use(cors());
app.use(express.json());

// Mock product data
const products = [
  {
    id: 1,
    name: "Wireless Headphones",
    description: "High-quality wireless headphones with noise cancellation",
    price: 199.99,
    image: "https://images.unsplash.com/photo-1505740420928-5e560c06d30e?w=400"
  },
  {
    id: 2,
    name: "Smart Watch",
    description: "Feature-rich smartwatch with health monitoring",
    price: 299.99,
    image: "https://images.unsplash.com/photo-1523275335684-37898b6baf30?w=400"
  },
  {
    id: 3,
    name: "Laptop Stand",
    description: "Ergonomic aluminum laptop stand for better posture",
    price: 79.99,
    image: "https://images.unsplash.com/photo-1527864550417-7fd91fc51a46?w=400"
  },
  {
    id: 4,
    name: "Wireless Mouse",
    description: "Precision wireless mouse with long battery life",
    price: 49.99,
    image: "https://images.unsplash.com/photo-1527814050087-3793815479db?w=400"
  },
  {
    id: 5,
    name: "USB-C Hub",
    description: "Multi-port USB-C hub with HDMI and USB 3.0",
    price: 89.99,
    image: "https://images.unsplash.com/photo-1558618666-fcd25c85cd64?w=400"
  },
  {
    id: 6,
    name: "Bluetooth Speaker",
    description: "Portable Bluetooth speaker with premium sound",
    price: 129.99,
    image: "https://images.unsplash.com/photo-1608043152269-423dbba4e7e1?w=400"
  },
  {
    id: 7,
    name: "Phone Case",
    description: "Protective phone case with wireless charging support",
    price: 29.99,
    image: "https://images.unsplash.com/photo-1556656793-08538906a9f8?w=400"
  },
  {
    id: 8,
    name: "Desk Lamp",
    description: "LED desk lamp with adjustable brightness and color",
    price: 69.99,
    image: "https://images.unsplash.com/photo-1507473885765-e6ed057f782c?w=400"
  },
  {
    id: 9,
    name: "Mechanical Keyboard",
    description: "RGB mechanical keyboard with tactile switches",
    price: 159.99,
    image: "https://images.unsplash.com/photo-1541140532154-b024d705b90a?w=400"
  },
  {
    id: 10,
    name: "Monitor Stand",
    description: "Adjustable monitor stand with storage drawer",
    price: 99.99,
    image: "https://images.unsplash.com/photo-1527443224154-c4a3942d3acf?w=400"
  }
];

// Routes
app.get('/health', (req, res) => {
  res.json({ status: 'healthy', service: 'product-catalog-service' });
});

app.get('/api/products', (req, res) => {
  res.json(products);
});

app.get('/api/products/:id', (req, res) => {
  const productId = parseInt(req.params.id);
  const product = products.find(p => p.id === productId);
  
  if (!product) {
    return res.status(404).json({ error: 'Product not found' });
  }
  
  res.json(product);
});

app.listen(PORT, () => {
  console.log(`Product catalog service running on port ${PORT}`);
});