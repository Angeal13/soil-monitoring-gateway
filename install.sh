#!/bin/bash
# IoT Gateway Installer - SIMPLIFIED (No Virtual Environment)

set -e

echo "========================================"
echo "🚀 IoT Gateway Installation (Simplified)"
echo "========================================"

GATEWAY_USER="gateway"
GATEWAY_DIR="/home/$GATEWAY_USER/iot-gateway"
SERVICE_NAME="iot-gateway"
LOG_DIR="/var/log/$SERVICE_NAME"
DB_PI_IP="192.168.1.76"  # UPDATE THIS!

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

# Step 1: Update system
print_status "Updating system..."
apt-get update
apt-get upgrade -y

# Step 2: Install minimal dependencies
print_status "Installing dependencies..."
apt-get install -y python3 python3-pip git sqlite3

# Step 3: Install Python packages SYSTEM-WIDE
print_status "Installing Python packages..."
pip3 install --break-system-packages Flask==2.3.3 requests==2.31.0

# Step 4: Create gateway directory
print_status "Setting up gateway directory..."
if [ -d "$GATEWAY_DIR" ]; then
    print_status "Backing up existing directory..."
    backup_dir="${GATEWAY_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
    cp -r "$GATEWAY_DIR" "$backup_dir"
    rm -rf "$GATEWAY_DIR"
fi

mkdir -p "$GATEWAY_DIR"
mkdir -p "$GATEWAY_DIR/data"
chown -R $GATEWAY_USER:$GATEWAY_USER "$GATEWAY_DIR"

# Step 5: Create gateway.py (same as before)
print_status "Creating gateway code..."
cat > "$GATEWAY_DIR/gateway.py" << 'EOF'
"""
IoT Forwarding Gateway - System-wide installation
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

DATABASE_PI_URL = "http://192.168.1.101:5000"
OFFLINE_DB = "/home/pi/iot-gateway/data/offline.db"
PORT = 5000

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)

stats = {'received': 0, 'forwarded': 0, 'offline': 0}

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
    except:
        return False, None

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

def background_worker():
    while True:
        time.sleep(60)
        try:
            forward_offline()
        except:
            pass

if __name__ == '__main__':
    print(f"🚀 Starting IoT Gateway on port {PORT}")
    print(f"📡 Forwarding to: {DATABASE_PI_URL}")
    
    init_offline_db()
    
    worker = Thread(target=background_worker, daemon=True)
    worker.start()
    
    app.run(host='0.0.0.0', port=PORT, debug=False)
EOF

# Update IP
sed -i "s|http://192.168.1.101:5000|http://${DB_PI_IP}:5000|g" "$GATEWAY_DIR/gateway.py"

# Step 6: Create systemd service
print_status "Creating systemd service..."
mkdir -p "$LOG_DIR"
chown $GATEWAY_USER:$GATEWAY_USER "$LOG_DIR"

cat > "/etc/systemd/system/$SERVICE_NAME.service" << EOF
[Unit]
Description=IoT Forwarding Gateway
After=network.target
Wants=network.target

[Service]
Type=simple
User=$GATEWAY_USER
WorkingDirectory=$GATEWAY_DIR
ExecStart=/usr/bin/python3 $GATEWAY_DIR/gateway.py
Restart=always
RestartSec=10
StandardOutput=append:$LOG_DIR/gateway.log
StandardError=append:$LOG_DIR/error.log

[Install]
WantedBy=multi-user.target
EOF

# Step 7: Enable and start
print_status "Starting gateway service..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"

sleep 3

if systemctl is-active --quiet "$SERVICE_NAME"; then
    print_status "✅ Gateway is running!"
else
    print_error "Failed to start gateway"
    journalctl -u "$SERVICE_NAME" -n 20
    exit 1
fi

# Step 8: Create management script
cat > "$GATEWAY_DIR/manage.sh" << 'EOF'
#!/bin/bash
SERVICE="iot-gateway"
case "$1" in
    start) sudo systemctl start $SERVICE ;;
    stop) sudo systemctl stop $SERVICE ;;
    restart) sudo systemctl restart $SERVICE ;;
    status) sudo systemctl status $SERVICE ;;
    logs) sudo tail -f /var/log/$SERVICE/gateway.log ;;
    test) curl -s http://localhost:5000/api/test | python3 -m json.tool ;;
    *) echo "Usage: $0 {start|stop|restart|status|logs|test}" ;;
esac
EOF

chmod +x "$GATEWAY_DIR/manage.sh"
ln -sf "$GATEWAY_DIR/manage.sh" /usr/local/bin/gateway-manage

# Display summary
print_status "========================================"
print_status "✅ IoT Gateway Installed (System-wide)"
print_status "========================================"
echo ""
echo "📊 Summary:"
echo "   Gateway:      /home/gateway/iot-gateway/"
echo "   Port:         5000"
echo "   Database Pi:  $DB_PI_IP:5000"
echo "   Service:      $SERVICE_NAME"
echo "   Logs:         /var/log/$SERVICE_NAME/"
echo ""
echo "🛠️  Commands:"
echo "   gateway-manage start    # Start"
echo "   gateway-manage status   # Check status"
echo "   gateway-manage logs     # View logs"
echo "   gateway-manage test     # Test API"
echo ""
echo "🌐 Test: curl http://$(hostname -I | awk '{print $1}'):5000/api/test"
print_status "========================================"
