const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const { v4: uuidv4 } = require('uuid');

const app = express();
const PORT = process.env.PORT || 3002;

// Middleware
app.use(helmet());
app.use(cors());
app.use(express.json());

// In-memory cart storage (in production, use Redis or database)
const carts = new Map();

// Routes
app.get('/health', (req, res) => {
  res.json({ status: 'healthy', service: 'cart-service' });
});

app.get('/api/cart/:userId', (req, res) => {
  const { userId } = req.params;
  const cart = carts.get(userId) || { items: [] };
  res.json(cart);
});

app.post('/api/cart/:userId/items', (req, res) => {
  const { userId } = req.params;
  const { productId, quantity, price, name, image } = req.body;
  
  if (!productId || !quantity || !price) {
    return res.status(400).json({ error: 'Missing required fields' });
  }
  
  let cart = carts.get(userId) || { items: [] };
  
  // Check if item already exists in cart
  const existingItemIndex = cart.items.findIndex(item => item.productId === productId);
  
  if (existingItemIndex >= 0) {
    // Update quantity if item exists
    cart.items[existingItemIndex].quantity += quantity;
  } else {
    // Add new item
    const newItem = {
      id: uuidv4(),
      productId,
      name,
      image,
      price,
      quantity
    };
    cart.items.push(newItem);
  }
  
  carts.set(userId, cart);
  res.json(cart);
});

app.put('/api/cart/:userId/items/:itemId', (req, res) => {
  const { userId, itemId } = req.params;
  const { quantity } = req.body;
  
  if (!quantity || quantity < 1) {
    return res.status(400).json({ error: 'Invalid quantity' });
  }
  
  const cart = carts.get(userId);
  if (!cart) {
    return res.status(404).json({ error: 'Cart not found' });
  }
  
  const itemIndex = cart.items.findIndex(item => item.id === itemId);
  if (itemIndex === -1) {
    return res.status(404).json({ error: 'Item not found' });
  }
  
  cart.items[itemIndex].quantity = quantity;
  carts.set(userId, cart);
  res.json(cart);
});

app.delete('/api/cart/:userId/items/:itemId', (req, res) => {
  const { userId, itemId } = req.params;
  
  const cart = carts.get(userId);
  if (!cart) {
    return res.status(404).json({ error: 'Cart not found' });
  }
  
  cart.items = cart.items.filter(item => item.id !== itemId);
  carts.set(userId, cart);
  res.json(cart);
});

app.delete('/api/cart/:userId', (req, res) => {
  const { userId } = req.params;
  carts.delete(userId);
  res.json({ message: 'Cart cleared' });
});

app.listen(PORT, () => {
  console.log(`Cart service running on port ${PORT}`);
});