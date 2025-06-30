import React, { createContext, useContext, useState, useEffect } from 'react';
import axios from 'axios';
import { useAuth } from './AuthContext';

const CartContext = createContext();

export const useCart = () => useContext(CartContext);

export const CartProvider = ({ children }) => {
  const [cart, setCart] = useState([]);
  const { user } = useAuth();

  const fetchCart = async () => {
    if (!user) return;
    try {
      const response = await axios.get(`/api/cart/${user.id}`);
      setCart(response.data.items || []);
    } catch (error) {
      console.error('Failed to fetch cart:', error);
    }
  };

  const addToCart = async (product, quantity = 1) => {
    if (!user) return;
    try {
      await axios.post(`/api/cart/${user.id}/items`, {
        productId: product.id,
        quantity,
        price: product.price
      });
      fetchCart();
    } catch (error) {
      console.error('Failed to add to cart:', error);
    }
  };

  const updateQuantity = async (itemId, quantity) => {
    if (!user) return;
    try {
      await axios.put(`/api/cart/${user.id}/items/${itemId}`, { quantity });
      fetchCart();
    } catch (error) {
      console.error('Failed to update quantity:', error);
    }
  };

  const removeFromCart = async (itemId) => {
    if (!user) return;
    try {
      await axios.delete(`/api/cart/${user.id}/items/${itemId}`);
      fetchCart();
    } catch (error) {
      console.error('Failed to remove from cart:', error);
    }
  };

  const clearCart = () => {
    setCart([]);
  };

  const getCartTotal = () => {
    return cart.reduce((total, item) => total + (item.price * item.quantity), 0);
  };

  useEffect(() => {
    fetchCart();
  }, [user]);

  return (
    <CartContext.Provider value={{
      cart,
      addToCart,
      updateQuantity,
      removeFromCart,
      clearCart,
      getCartTotal,
      fetchCart
    }}>
      {children}
    </CartContext.Provider>
  );
};