const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const { v4: uuidv4 } = require('uuid');
const { Pool } = require('pg');

const app = express();
const PORT = process.env.PORT || 3002;

// Middleware
app.use(helmet());
app.use(cors());
app.use(express.json());

// ============================================================================
// Database Connection
// ============================================================================
// Uses DATABASE_URL if available (production with PostgreSQL).
// Falls back to in-memory storage if no database is configured (development).
// This pattern allows the service to work in both modes.
// ============================================================================
let pool = null;
let useDatabase = false;

if (process.env.DATABASE_URL) {
  pool = new Pool({
    connectionString: process.env.DATABASE_URL,
    max: 10,                    // Maximum connections in pool
    idleTimeoutMillis: 30000,   // Close idle connections after 30s
    connectionTimeoutMillis: 5000, // Fail fast if DB unreachable
  });

  // Test connection on startup
  pool.query('SELECT 1')
    .then(() => {
      console.log('Connected to PostgreSQL');
      useDatabase = true;
    })
    .catch((err) => {
      console.warn('PostgreSQL unavailable, using in-memory storage:', err.message);
      useDatabase = false;
    });
} else {
  console.log('No DATABASE_URL configured, using in-memory storage');
}

// In-memory fallback (for development without database)
const cartsInMemory = new Map();

// ============================================================================
// Database helper functions
// ============================================================================
async function getOrCreateCart(userId) {
  const result = await pool.query(
    'SELECT id FROM carts WHERE user_id = $1',
    [userId]
  );

  if (result.rows.length > 0) {
    return result.rows[0].id;
  }

  const newCart = await pool.query(
    'INSERT INTO carts (user_id) VALUES ($1) RETURNING id',
    [userId]
  );
  return newCart.rows[0].id;
}

async function getCartItems(cartId) {
  const result = await pool.query(
    `SELECT id, product_id as "productId", product_name as "name",
            product_image as "image", price, quantity
     FROM cart_items WHERE cart_id = $1`,
    [cartId]
  );
  return result.rows;
}

// ============================================================================
// Routes
// ============================================================================
app.get('/health', (req, res) => {
  res.json({
    status: 'healthy',
    service: 'cart-service',
    storage: useDatabase ? 'postgresql' : 'in-memory'
  });
});

// GET cart for a user
app.get('/api/cart/:userId', async (req, res) => {
  try {
    const { userId } = req.params;

    if (useDatabase) {
      const cartId = await getOrCreateCart(userId);
      const items = await getCartItems(cartId);
      return res.json({ items });
    }

    // Fallback: in-memory
    const cart = cartsInMemory.get(userId) || { items: [] };
    res.json(cart);
  } catch (err) {
    console.error('Error getting cart:', err.message);
    res.status(500).json({ error: 'Failed to retrieve cart' });
  }
});

// ADD item to cart
app.post('/api/cart/:userId/items', async (req, res) => {
  try {
    const { userId } = req.params;
    const { productId, quantity, price, name, image } = req.body;

    if (!productId || !quantity || !price) {
      return res.status(400).json({ error: 'Missing required fields' });
    }

    if (useDatabase) {
      const cartId = await getOrCreateCart(userId);

      // Check if item already exists
      const existing = await pool.query(
        'SELECT id, quantity FROM cart_items WHERE cart_id = $1 AND product_id = $2',
        [cartId, productId]
      );

      if (existing.rows.length > 0) {
        // Update quantity
        await pool.query(
          'UPDATE cart_items SET quantity = quantity + $1 WHERE id = $2',
          [quantity, existing.rows[0].id]
        );
      } else {
        // Insert new item
        await pool.query(
          `INSERT INTO cart_items (cart_id, product_id, product_name, product_image, price, quantity)
           VALUES ($1, $2, $3, $4, $5, $6)`,
          [cartId, productId, name, image, price, quantity]
        );
      }

      const items = await getCartItems(cartId);
      return res.json({ items });
    }

    // Fallback: in-memory
    let cart = cartsInMemory.get(userId) || { items: [] };
    const existingIndex = cart.items.findIndex(item => item.productId === productId);

    if (existingIndex >= 0) {
      cart.items[existingIndex].quantity += quantity;
    } else {
      cart.items.push({ id: uuidv4(), productId, name, image, price, quantity });
    }

    cartsInMemory.set(userId, cart);
    res.json(cart);
  } catch (err) {
    console.error('Error adding to cart:', err.message);
    res.status(500).json({ error: 'Failed to add item to cart' });
  }
});

// UPDATE item quantity
app.put('/api/cart/:userId/items/:itemId', async (req, res) => {
  try {
    const { userId, itemId } = req.params;
    const { quantity } = req.body;

    if (!quantity || quantity < 1) {
      return res.status(400).json({ error: 'Invalid quantity' });
    }

    if (useDatabase) {
      await pool.query(
        'UPDATE cart_items SET quantity = $1 WHERE id = $2',
        [quantity, itemId]
      );
      const cartId = await getOrCreateCart(userId);
      const items = await getCartItems(cartId);
      return res.json({ items });
    }

    // Fallback: in-memory
    const cart = cartsInMemory.get(userId);
    if (!cart) return res.status(404).json({ error: 'Cart not found' });

    const itemIndex = cart.items.findIndex(item => item.id === itemId);
    if (itemIndex === -1) return res.status(404).json({ error: 'Item not found' });

    cart.items[itemIndex].quantity = quantity;
    cartsInMemory.set(userId, cart);
    res.json(cart);
  } catch (err) {
    console.error('Error updating cart:', err.message);
    res.status(500).json({ error: 'Failed to update cart item' });
  }
});

// DELETE item from cart
app.delete('/api/cart/:userId/items/:itemId', async (req, res) => {
  try {
    const { userId, itemId } = req.params;

    if (useDatabase) {
      await pool.query('DELETE FROM cart_items WHERE id = $1', [itemId]);
      const cartId = await getOrCreateCart(userId);
      const items = await getCartItems(cartId);
      return res.json({ items });
    }

    // Fallback: in-memory
    const cart = cartsInMemory.get(userId);
    if (!cart) return res.status(404).json({ error: 'Cart not found' });

    cart.items = cart.items.filter(item => item.id !== itemId);
    cartsInMemory.set(userId, cart);
    res.json(cart);
  } catch (err) {
    console.error('Error deleting cart item:', err.message);
    res.status(500).json({ error: 'Failed to delete cart item' });
  }
});

// CLEAR entire cart
app.delete('/api/cart/:userId', async (req, res) => {
  try {
    const { userId } = req.params;

    if (useDatabase) {
      const cartId = await getOrCreateCart(userId);
      await pool.query('DELETE FROM cart_items WHERE cart_id = $1', [cartId]);
      return res.json({ message: 'Cart cleared' });
    }

    // Fallback: in-memory
    cartsInMemory.delete(userId);
    res.json({ message: 'Cart cleared' });
  } catch (err) {
    console.error('Error clearing cart:', err.message);
    res.status(500).json({ error: 'Failed to clear cart' });
  }
});

// Graceful shutdown (close database pool)
process.on('SIGTERM', async () => {
  console.log('SIGTERM received. Closing database pool...');
  if (pool) await pool.end();
  process.exit(0);
});

app.listen(PORT, () => {
  console.log(`Cart service running on port ${PORT}`);
});
