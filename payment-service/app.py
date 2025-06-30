from flask import Flask, request, jsonify
from flask_cors import CORS
import uuid
import time
import random
import os

app = Flask(__name__)
CORS(app)

@app.route('/health', methods=['GET'])
def health_check():
    return jsonify({'status': 'healthy', 'service': 'payment-service'})

@app.route('/api/payment/process', methods=['POST'])
def process_payment():
    try:
        data = request.get_json()
        
        if not data:
            return jsonify({'error': 'No payment data provided'}), 400
        
        order_id = data.get('orderId')
        amount = data.get('amount')
        card_number = data.get('cardNumber')
        expiry_date = data.get('expiryDate')
        cvv = data.get('cvv')
        
        # Validate required fields
        if not all([order_id, amount, card_number, expiry_date, cvv]):
            return jsonify({'error': 'Missing required payment fields'}), 400
        
        # Validate amount
        if not isinstance(amount, (int, float)) or amount <= 0:
            return jsonify({'error': 'Invalid amount'}), 400
        
        # Simulate payment processing delay
        time.sleep(random.uniform(1, 3))
        
        # Mock payment validation
        # Simulate failure for specific test card numbers
        if card_number == '4000000000000002':
            return jsonify({'error': 'Payment declined - insufficient funds'}), 400
        elif card_number == '4000000000000119':
            return jsonify({'error': 'Payment declined - invalid card'}), 400
        
        # Generate payment ID
        payment_id = str(uuid.uuid4())
        
        # Mock successful payment response
        response = {
            'paymentId': payment_id,
            'orderId': order_id,
            'status': 'success',
            'amount': amount,
            'currency': 'USD',
            'transactionId': f'txn_{random.randint(100000, 999999)}',
            'processedAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
            'message': 'Payment processed successfully'
        }
        
        return jsonify(response)
        
    except Exception as e:
        print(f"Payment processing error: {e}")
        return jsonify({'error': 'Payment processing failed'}), 500

@app.route('/api/payment/status/<payment_id>', methods=['GET'])
def get_payment_status(payment_id):
    """Mock endpoint to check payment status"""
    try:
        # In a real implementation, this would query a database
        return jsonify({
            'paymentId': payment_id,
            'status': 'completed',
            'message': 'Payment completed successfully'
        })
    except Exception as e:
        print(f"Payment status error: {e}")
        return jsonify({'error': 'Failed to retrieve payment status'}), 500

if __name__ == '__main__':
    port = int(os.getenv('PORT', 5002))
    app.run(host='0.0.0.0', port=port, debug=False)