#!/bin/bash
# IoT Gateway Installer - FORWARDING VERSION
# Installs the correct gateway that forwards to Database Pi (appV8.py)

set -e  # Exit on error

echo "========================================"
echo "🚀 IoT Forwarding Gateway Installation"
echo "========================================"

# Configuration
GATEWAY_USER="gateway"  # Use existing pi user
GATEWAY_DIR="/home/$GATEWAY_USER/iot-gateway"
SERVICE_NAME="iot-gateway"
LOG_DIR="/var/log/$SERVICE_NAME"
DB_PI_IP="192.168.1.76"  # Your Database Pi IP - UPDATE THIS!

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    print_error "Please run as root (use sudo)"
    exit 1
fi

# Step 1: Update system
print_status "Updating system..."
apt-get update
apt-get upgrade -y

# Step 2: Install dependencies
print_status "Installing dependencies..."
apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    git \
    sqlite3  # For offline storage

# Step 3: Create gateway directory
print_status "Setting up gateway directory..."
if [ -d "$GATEWAY_DIR" ]; then
    print_warning "Gateway directory exists, backing up..."
    backup_dir="${GATEWAY_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
    cp -r "$GATEWAY_DIR" "$backup_dir"
    rm -rf "$GATEWAY_DIR"
fi

mkdir -p "$GATEWAY_DIR"
mkdir -p "$GATEWAY_DIR/data"  # For offline storage

# Step 4: Create the CORRECT gateway.py
print_status "Creating correct gateway code..."

cat > "$GATEWAY_DIR/gateway.py" << 'EOF'
"""
IoT Forwarding Gateway
Forwards data to Database Pi (appV8.py) with offline fallback
"""
from flask import Flask, request, jsonify
import requests
import sqlite3
import json
import logging
from datetime import datetime
from threading import Thread
import time
import os

# ========================
# CONFIGURATION - UPDATE THESE!
# ========================
DATABASE_PI_URL = "http://192.168.1.76:5000"  # Your Database Pi IP
OFFLINE_DB = "/home/pi/iot-gateway/data/offline.db"
PORT = 5000  # MUST be 5000

# ========================
# SETUP
# ========================
app = Flask(__name__)
logging.basicConfig(level=logging.INFO)

# Statistics
stats = {
    'received': 0,
    'forwarded': 0,
    'offline': 0,
    'errors': 0
}

# ========================
# OFFLINE STORAGE
# ========================
def init_offline_db():
    os.makedirs(os.path.dirname(OFFLINE_DB), exist_ok=True)
    conn = sqlite3.connect(OFFLINE_DB)
    c = conn.cursor()
    c.execute('''
        CREATE TABLE IF NOT EXISTS queue (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            endpoint TEXT,
            data TEXT,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
        )
    ''')
    conn.commit()
    conn.close()

def save_offline(endpoint, data):
    conn = sqlite3.connect(OFFLINE_DB)
    c = conn.cursor()
    c.execute('INSERT INTO queue (endpoint, data) VALUES (?, ?)',
              (endpoint, json.dumps(data)))
    conn.commit()
    conn.close()
    stats['offline'] += 1
    return True

def forward_offline():
    """Forward offline data when Database Pi is back"""
    conn = sqlite3.connect(OFFLINE_DB)
    conn.row_factory = sqlite3.Row
    c = conn.cursor()
    c.execute('SELECT * FROM queue ORDER BY timestamp ASC LIMIT 50')
    records = c.fetchall()
    
    for record in records:
        try:
            response = requests.post(
                f"{DATABASE_PI_URL}{record['endpoint']}",
                json=json.loads(record['data']),
                timeout=10
            )
            if response.status_code == 200:
                c.execute('DELETE FROM queue WHERE id = ?', (record['id'],))
                stats['forwarded'] += 1
        except:
            pass
    
    conn.commit()
    conn.close()

# ========================
# FORWARDING FUNCTIONS
# ========================
def forward_to_database(endpoint, data):
    try:
        response = requests.post(
            f"{DATABASE_PI_URL}{endpoint}",
            json=data,
            timeout=10
        )
        if response.status_code == 200:
            stats['forwarded'] += 1
            return True, response.json()
        return False, None
    except Exception as e:
        return False, None

# ========================
# API ENDPOINTS
# ========================
@app.route('/api/sensor-data', methods=['POST'])
def handle_sensor_data():
    stats['received'] += 1
    data = request.json
    
    success, response = forward_to_database('/api/sensor-data', data)
    if success:
        return jsonify({"status": "forwarded"}), 200
    else:
        save_offline('/api/sensor-data', data)
        return jsonify({"status": "queued_offline"}), 202

@app.route('/api/sensors/register', methods=['POST'])
def handle_register():
    stats['received'] += 1
    data = request.json
    
    success, response = forward_to_database('/api/sensors/register', data)
    if success:
        return jsonify(response), 200
    else:
        save_offline('/api/sensors/register', data)
        return jsonify({"status": "queued"}), 202

@app.route('/api/sensors/<machine_id>/assignment', methods=['GET'])
def handle_assignment(machine_id):
    try:
        response = requests.get(
            f"{DATABASE_PI_URL}/api/sensors/{machine_id}/assignment",
            timeout=10
        )
        return jsonify(response.json()), response.status_code
    except:
        return jsonify({"error": "database_unavailable"}), 503

@app.route('/api/test', methods=['GET'])
def test():
    try:
        response = requests.get(f"{DATABASE_PI_URL}/api/test", timeout=5)
        db_status = "connected" if response.status_code == 200 else "error"
    except:
        db_status = "disconnected"
    
    return jsonify({
        "gateway": "online",
        "database": db_status,
        "port": PORT,
        "stats": stats
    })

@app.route('/api/health', methods=['GET'])
def health():
    return jsonify({
        "status": "healthy",
        "timestamp": datetime.now().isoformat(),
        "stats": stats
    })

# ========================
# BACKGROUND WORKER
# ========================
def background_worker():
    while True:
        time.sleep(60)  # Check every minute
        try:
            # Try to forward offline data
            forward_offline()
        except:
            pass

# ========================
# MAIN
# ========================
if __name__ == '__main__':
    print(f"🚀 Starting IoT Gateway on port {PORT}")
    print(f"📡 Forwarding to: {DATABASE_PI_URL}")
    print(f"💾 Offline storage: {OFFLINE_DB}")
    
    init_offline_db()
    
    # Start background worker
    worker = Thread(target=background_worker, daemon=True)
    worker.start()
    
    app.run(host='0.0.0.0', port=PORT, debug=False)
EOF

# Update the IP in the gateway code
sed -i "s|http://192.168.1.101:5000|http://${DB_PI_IP}:5000|g" "$GATEWAY_DIR/gateway.py"

# Step 5: Create requirements.txt
print_status "Creating requirements.txt..."
cat > "$GATEWAY_DIR/requirements.txt" << 'EOF'
Flask==2.3.3
requests==2.31.0
EOF

# Step 6: Create virtual environment
print_status "Setting up Python environment..."
sudo -u $GATEWAY_USER python3 -m venv "$GATEWAY_DIR/venv"
sudo -u $GATEWAY_USER "$GATEWAY_DIR/venv/bin/pip" install --upgrade pip
sudo -u $GATEWAY_USER "$GATEWAY_DIR/venv/bin/pip" install -r "$GATEWAY_DIR/requirements.txt"

# Step 7: Create log directory
print_status "Setting up logging..."
mkdir -p "$LOG_DIR"
chown $GATEWAY_USER:$GATEWAY_USER "$LOG_DIR"
chmod 755 "$LOG_DIR"

# Step 8: Create systemd service
print_status "Creating systemd service..."
cat > "/etc/systemd/system/$SERVICE_NAME.service" << EOF
[Unit]
Description=IoT Forwarding Gateway
After=network.target
Wants=network.target

[Service]
Type=simple
User=$GATEWAY_USER
WorkingDirectory=$GATEWAY_DIR
Environment="PATH=$GATEWAY_DIR/venv/bin"
ExecStart=$GATEWAY_DIR/venv/bin/python $GATEWAY_DIR/gateway.py
Restart=always
RestartSec=10
StandardOutput=append:$LOG_DIR/gateway.log
StandardError=append:$LOG_DIR/error.log

[Install]
WantedBy=multi-user.target
EOF

# Step 9: Create management script
print_status "Creating management script..."
cat > "$GATEWAY_DIR/manage.sh" << 'EOF'
#!/bin/bash
# Gateway management script

SERVICE="iot-gateway"
LOG_DIR="/var/log/$SERVICE"

case "$1" in
    start)
        sudo systemctl start $SERVICE
        echo "Gateway started"
        ;;
    stop)
        sudo systemctl stop $SERVICE
        echo "Gateway stopped"
        ;;
    restart)
        sudo systemctl restart $SERVICE
        echo "Gateway restarted"
        ;;
    status)
        sudo systemctl status $SERVICE
        ;;
    logs)
        sudo tail -f $LOG_DIR/gateway.log
        ;;
    test)
        echo "Testing gateway..."
        curl -s http://localhost:5000/api/test | python3 -m json.tool
        ;;
    config)
        echo "Current configuration:"
        grep "DATABASE_PI_URL" /home/pi/iot-gateway/gateway.py
        grep "PORT" /home/pi/iot-gateway/gateway.py
        ;;
    update-ip)
        if [ -z "$2" ]; then
            echo "Usage: $0 update-ip <new-ip>"
            exit 1
        fi
        sudo sed -i "s|http://[0-9.]*:5000|http://$2:5000|g" /home/pi/iot-gateway/gateway.py
        sudo systemctl restart $SERVICE
        echo "Updated Database Pi IP to: $2"
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|logs|test|config|update-ip <new-ip>}"
        exit 1
        ;;
esac
EOF

chmod +x "$GATEWAY_DIR/manage.sh"
ln -sf "$GATEWAY_DIR/manage.sh" /usr/local/bin/iot-gateway-manage

# Step 10: Enable and start service
print_status "Starting gateway service..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"

# Wait and check
sleep 3
if systemctl is-active --quiet "$SERVICE_NAME"; then
    print_status "Gateway is running!"
else
    print_error "Failed to start gateway. Check logs:"
    journalctl -u "$SERVICE_NAME" -n 20
    exit 1
fi

# Step 11: Display success message
print_status "========================================"
print_status "✅ IoT Forwarding Gateway Installed!"
print_status "========================================"
echo ""
echo "📊 Summary:"
echo "   Gateway User:      $GATEWAY_USER"
echo "   Gateway Port:      5000 (correct for your sensors)"
echo "   Database Pi:       $DB_PI_IP:5000"
echo "   Service Name:      $SERVICE_NAME"
echo "   Logs:              $LOG_DIR/"
echo ""
echo "🛠️  Management Commands:"
echo "   iot-gateway-manage start      # Start gateway"
echo "   iot-gateway-manage stop       # Stop gateway"
echo "   iot-gateway-manage status     # Check status"
echo "   iot-gateway-manage logs       # View logs"
echo "   iot-gateway-manage test       # Test API"
echo "   iot-gateway-manage config     # Show config"
echo "   iot-gateway-manage update-ip 192.168.1.XXX  # Change Database Pi IP"
echo ""
echo "🌐 Test the gateway:"
echo "   curl http://localhost:5000/api/test"
echo "   curl http://$(hostname -I | awk '{print $1}'):5000/api/health"
echo ""
echo "🔧 Configuration file:"
echo "   nano $GATEWAY_DIR/gateway.py"
echo ""
echo "📡 Your sensors should connect to:"
echo "   http://$(hostname -I | awk '{print $1}'):5000"
print_status "========================================"

# Test the gateway
print_status "Running quick test..."
sleep 2
curl -s http://localhost:5000/api/test || echo "Gateway not responding yet (waiting for startup)"
