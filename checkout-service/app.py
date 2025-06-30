from flask import Flask, request, jsonify
from flask_cors import CORS
import requests
import uuid
import os

app = Flask(__name__)
CORS(app)

# Service URLs
CART_SERVICE_URL = os.getenv('CART_SERVICE_URL', 'http://cart-service:3002')
PAYMENT_SERVICE_URL = os.getenv('PAYMENT_SERVICE_URL', 'http://payment-service:5002')
SHIPPING_SERVICE_URL = os.getenv('SHIPPING_SERVICE_URL', 'http://shipping-service:8080')

@app.route('/health', methods=['GET'])
def health_check():
    return jsonify({'status': 'healthy', 'service': 'checkout-service'})

@app.route('/api/checkout', methods=['POST'])
def process_checkout():
    try:
        data = request.get_json()
        
        if not data:
            return jsonify({'error': 'No data provided'}), 400
        
        user_id = data.get('userId')
        items = data.get('items', [])
        total = data.get('total', 0)
        shipping_address = data.get('shippingAddress', {})
        payment_details = data.get('paymentDetails', {})
        
        if not user_id or not items:
            return jsonify({'error': 'Missing required fields'}), 400
        
        # Generate order ID
        order_id = str(uuid.uuid4())
        
        # Process payment
        payment_payload = {
            'orderId': order_id,
            'amount': total,
            'cardNumber': payment_details.get('cardNumber'),
            'expiryDate': payment_details.get('expiryDate'),
            'cvv': payment_details.get('cvv')
        }
        
        try:
            payment_response = requests.post(
                f'{PAYMENT_SERVICE_URL}/api/payment/process',
                json=payment_payload,
                timeout=10
            )
            
            if payment_response.status_code != 200:
                return jsonify({'error': 'Payment failed'}), 400
            
            payment_result = payment_response.json()
            
        except requests.RequestException as e:
            print(f"Payment service error: {e}")
            return jsonify({'error': 'Payment service unavailable'}), 503
        
        # Create shipping order
        shipping_payload = {
            'orderId': order_id,
            'items': items,
            'address': shipping_address
        }
        
        try:
            shipping_response = requests.post(
                f'{SHIPPING_SERVICE_URL}/api/shipping/create',
                json=shipping_payload,
                timeout=10
            )
            
            if shipping_response.status_code != 200:
                return jsonify({'error': 'Shipping creation failed'}), 400
            
            shipping_result = shipping_response.json()
            
        except requests.RequestException as e:
            print(f"Shipping service error: {e}")
            return jsonify({'error': 'Shipping service unavailable'}), 503
        
        # Clear user's cart
        try:
            requests.delete(f'{CART_SERVICE_URL}/api/cart/{user_id}', timeout=5)
        except requests.RequestException as e:
            print(f"Cart service error: {e}")
            # Don't fail checkout if cart clearing fails
        
        # Return successful checkout response
        return jsonify({
            'orderId': order_id,
            'status': 'confirmed',
            'paymentId': payment_result.get('paymentId'),
            'trackingNumber': shipping_result.get('trackingNumber'),
            'estimatedDelivery': shipping_result.get('estimatedDelivery'),
            'total': total
        })
        
    except Exception as e:
        print(f"Checkout error: {e}")
        return jsonify({'error': 'Internal server error'}), 500

if __name__ == '__main__':
    port = int(os.getenv('PORT', 5001))
    app.run(host='0.0.0.0', port=port, debug=False)