#!/bin/bash
# IoT Gateway Installer - FIXED PIP VERSION

set -e

echo "========================================"
echo "🚀 IoT Gateway Installation (Fixed)"
echo "========================================"

GATEWAY_USER="gateway"
GATEWAY_DIR="/home/$GATEWAY_USER/iot-gateway"
SERVICE_NAME="iot-gateway"
LOG_DIR="/var/log/$SERVICE_NAME"
DB_PI_IP="192.168.1.95"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then 
    print_error "Please run as root (use sudo)"
    exit 1
fi

# Step 0: Create gateway user if it doesn't exist
if ! id "$GATEWAY_USER" &>/dev/null; then
    print_status "Creating user '$GATEWAY_USER'..."
    useradd -m -s /bin/bash "$GATEWAY_USER"
    echo "$GATEWAY_USER:gateway123" | chpasswd
    usermod -a -G dialout "$GATEWAY_USER"
fi

# Step 1: Update system
print_status "Updating system..."
apt-get update
apt-get upgrade -y

# Step 2: Install minimal dependencies
print_status "Installing dependencies..."
apt-get install -y python3 python3-pip git sqlite3

# Step 3: FIXED Python packages installation
print_status "Installing Python packages (FIXED METHOD)..."
# Clean up any broken pip installations first
pip3 cache purge 2>/dev/null || true

# Install packages WITHOUT breaking system - use --no-deps if needed
pip3 install --upgrade pip 2>/dev/null || true

# Try multiple installation methods
if pip3 install Flask==2.3.3 requests==2.31.0 --no-cache-dir 2>/dev/null; then
    print_status "✅ Packages installed successfully"
else
    print_status "⚠️ Trying alternative installation method..."
    # Use system packages if pip fails
    apt-get install -y python3-flask python3-requests 2>/dev/null || true
fi

# Step 4: Create gateway directory with correct permissions
print_status "Setting up gateway directory..."
if [ -d "$GATEWAY_DIR" ]; then
    print_status "Backing up existing directory..."
    backup_dir="${GATEWAY_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
    cp -r "$GATEWAY_DIR" "$backup_dir" 2>/dev/null || true
fi

# Remove and recreate clean
rm -rf "$GATEWAY_DIR" 2>/dev/null || true

# Create all necessary directories
mkdir -p "$GATEWAY_DIR"
mkdir -p "$GATEWAY_DIR/data"
mkdir -p "$LOG_DIR"

# Also create gateway_data directory (for logs)
GATEWAY_DATA_DIR="/home/$GATEWAY_USER/gateway_data"
mkdir -p "$GATEWAY_DATA_DIR"

# Set correct ownership
chown -R $GATEWAY_USER:$GATEWAY_USER "$GATEWAY_DIR"
chown -R $GATEWAY_USER:$GATEWAY_USER "$LOG_DIR"
chown -R $GATEWAY_USER:$GATEWAY_USER "$GATEWAY_DATA_DIR"
chmod 755 "$LOG_DIR" "$GATEWAY_DATA_DIR"

# Step 5: Create SIMPLIFIED gateway.py
print_status "Creating gateway code..."
cat > "$GATEWAY_DIR/gateway.py" << 'EOF'
"""
IoT Gateway - SIMPLIFIED VERSION
"""
from flask import Flask, request, jsonify
import requests
import sqlite3
import json
import logging
import time
import os

# Configuration
DATABASE_PI_URL = "http://192.168.1.95:5000"
LOG_FILE = "/home/gateway/gateway_data/gateway.log"
OFFLINE_DB = "/home/gateway/gateway_data/offline.db"
PORT = 5000

# Create log directory
os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)

# Simple logging to file AND console
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler()
    ]
)

app = Flask(__name__)
stats = {'received': 0, 'forwarded': 0, 'offline': 0}

def init_db():
    """Initialize SQLite database"""
    os.makedirs(os.path.dirname(OFFLINE_DB), exist_ok=True)
    conn = sqlite3.connect(OFFLINE_DB)
    c = conn.cursor()
    c.execute('CREATE TABLE IF NOT EXISTS queue (id INTEGER PRIMARY KEY, endpoint TEXT, data TEXT, timestamp DATETIME DEFAULT CURRENT_TIMESTAMP)')
    conn.commit()
    conn.close()
    logging.info(f"Database initialized: {OFFLINE_DB}")

def save_offline(endpoint, data):
    """Save to offline queue"""
    try:
        conn = sqlite3.connect(OFFLINE_DB)
        c = conn.cursor()
        c.execute('INSERT INTO queue (endpoint, data) VALUES (?, ?)', (endpoint, json.dumps(data)))
        conn.commit()
        conn.close()
        stats['offline'] += 1
        logging.info(f"Saved offline: {endpoint}")
        return True
    except Exception as e:
        logging.error(f"Failed to save: {e}")
        return False

def forward_to_db(endpoint, data):
    """Forward to database"""
    try:
        response = requests.post(f"{DATABASE_PI_URL}{endpoint}", json=data, timeout=10)
        if response.status_code == 200:
            stats['forwarded'] += 1
            logging.info(f"Forwarded: {endpoint}")
            return True, response.json()
        else:
            logging.warning(f"Failed: {endpoint} - Status {response.status_code}")
            return False, None
    except Exception as e:
        logging.warning(f"Forward error: {e}")
        return False, None

@app.route('/api/sensor-data', methods=['POST'])
def sensor_data():
    stats['received'] += 1
    data = request.json
    machine_id = data.get('machine_id', 'unknown')
    logging.info(f"Received from {machine_id}")
    
    success, _ = forward_to_db('/api/sensor-data', data)
    if success:
        return jsonify({"status": "forwarded"}), 200
    else:
        if save_offline('/api/sensor-data', data):
            return jsonify({"status": "offline"}), 202
        return jsonify({"error": "failed"}), 500

@app.route('/api/sensors/register', methods=['POST'])
def register():
    stats['received'] += 1
    data = request.json
    machine_id = data.get('machine_id', 'unknown')
    logging.info(f"Register: {machine_id}")
    
    success, response = forward_to_db('/api/sensors/register', data)
    if success:
        return jsonify(response), 200
    else:
        if save_offline('/api/sensors/register', data):
            return jsonify({"status": "queued"}), 202
        return jsonify({"error": "failed"}), 500

@app.route('/api/sensors/<machine_id>/assignment', methods=['GET'])
def assignment(machine_id):
    logging.info(f"Assignment check: {machine_id}")
    try:
        response = requests.get(f"{DATABASE_PI_URL}/api/sensors/{machine_id}/assignment", timeout=5)
        return jsonify(response.json()), response.status_code
    except:
        return jsonify({"error": "db_unavailable"}), 503

@app.route('/api/test', methods=['GET'])
def test():
    try:
        response = requests.get(f"{DATABASE_PI_URL}/api/test", timeout=3)
        db_status = "connected" if response.status_code == 200 else "error"
    except:
        db_status = "disconnected"
    
    return jsonify({
        "gateway": "online",
        "database": db_status,
        "url": DATABASE_PI_URL,
        "stats": stats
    })

@app.route('/api/health', methods=['GET'])
def health():
    return jsonify({"status": "ok", "stats": stats})

if __name__ == '__main__':
    print("=" * 50)
    print(f"Gateway starting on port {PORT}")
    print(f"Forwarding to: {DATABASE_PI_URL}")
    print(f"Log file: {LOG_FILE}")
    print("=" * 50)
    
    init_db()
    app.run(host='0.0.0.0', port=PORT, debug=False)
EOF

# Update IP
sed -i "s|http://192.168.1.95:5000|http://${DB_PI_IP}:5000|g" "$GATEWAY_DIR/gateway.py"

# Step 6: Set permissions
print_status "Setting permissions..."
chown -R $GATEWAY_USER:$GATEWAY_USER "$GATEWAY_DIR"
chmod 755 "$GATEWAY_DIR"
chmod 644 "$GATEWAY_DIR/gateway.py"

# Step 7: Create systemd service
print_status "Creating systemd service..."
cat > "/etc/systemd/system/$SERVICE_NAME.service" << 'EOF'
[Unit]
Description=IoT Gateway
After=network.target

[Service]
Type=simple
User=gateway
Group=gateway
WorkingDirectory=/home/gateway/iot-gateway
ExecStart=/usr/bin/python3 /home/gateway/iot-gateway/gateway.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Step 8: Enable and start
print_status "Starting service..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"

sleep 3

# Step 9: Check
if systemctl is-active --quiet "$SERVICE_NAME"; then
    print_status "✅ Gateway running!"
    
    # Test
    echo ""
    print_status "Testing connection..."
    sleep 2
    if curl -s http://localhost:5000/api/test; then
        print_status "✅ API working!"
    else
        print_error "API test failed"
        journalctl -u "$SERVICE_NAME" -n 20 --no-pager
    fi
else
    print_error "Service failed to start"
    journalctl -u "$SERVICE_NAME" -n 30 --no-pager
    exit 1
fi

# Step 10: Simple management script
cat > "/usr/local/bin/gateway-manage" << 'EOF'
#!/bin/bash
case "$1" in
    start) sudo systemctl start iot-gateway ;;
    stop) sudo systemctl stop iot-gateway ;;
    restart) sudo systemctl restart iot-gateway ;;
    status) sudo systemctl status iot-gateway ;;
    logs) sudo journalctl -u iot-gateway -f ;;
    test) curl -s http://localhost:5000/api/test ;;
    *) echo "Use: gateway-manage {start|stop|restart|status|logs|test}" ;;
esac
EOF

chmod +x /usr/local/bin/gateway-manage

# Done
echo ""
echo "========================================"
print_status "✅ INSTALLATION COMPLETE!"
echo "========================================"
echo ""
echo "Gateway is running!"
echo "Test: curl http://localhost:5000/api/test"
echo "Manage: gateway-manage {start|stop|restart|status|logs}"
echo ""
echo "Logs: /home/gateway/gateway_data/gateway.log"
echo "Offline data: /home/gateway/gateway_data/offline.db"
echo "========================================"
