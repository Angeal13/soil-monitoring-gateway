#!/bin/bash
# IoT Gateway Installer - FIXED VERSION

set -e

echo "========================================"
echo "🚀 IoT Gateway Installation (Fixed)"
echo "========================================"

GATEWAY_USER="gateway"
GATEWAY_DIR="/home/$GATEWAY_USER/iot-gateway"
SERVICE_NAME="iot-gateway"
LOG_DIR="/var/log/$SERVICE_NAME"
DB_PI_IP="192.168.1.95"  # appV7.py IP

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

# Step 3: Install Python packages SYSTEM-WIDE
print_status "Installing Python packages..."
pip3 install --break-system-packages Flask==2.3.3 requests==2.31.0

# Step 4: Create gateway directory with correct permissions
print_status "Setting up gateway directory..."
if [ -d "$GATEWAY_DIR" ]; then
    print_status "Backing up existing directory..."
    backup_dir="${GATEWAY_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
    cp -r "$GATEWAY_DIR" "$backup_dir"
    rm -rf "$GATEWAY_DIR"
fi

# Create all necessary directories
mkdir -p "$GATEWAY_DIR"
mkdir -p "$GATEWAY_DIR/data"
mkdir -p "$LOG_DIR"

# Set correct ownership
chown -R $GATEWAY_USER:$GATEWAY_USER "$GATEWAY_DIR"
chown -R $GATEWAY_USER:$GATEWAY_USER "$LOG_DIR"

# Step 5: Create fixed gateway.py with correct log path
print_status "Creating gateway code..."
cat > "$GATEWAY_DIR/gateway.py" << 'EOF'
"""
IoT Forwarding Gateway - Fixed Version
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

DATABASE_PI_URL = "http://192.168.1.95:5000"  # appV7.py
OFFLINE_DB = "/home/gateway/iot-gateway/data/offline.db"
LOG_FILE = "/var/log/iot-gateway/gateway.log"
PORT = 5000

app = Flask(__name__)

# Setup logging with file handler
os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

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
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
            attempts INTEGER DEFAULT 0,
            last_attempt DATETIME
        )
    ''')
    conn.commit()
    conn.close()
    logger.info(f"Offline database initialized: {OFFLINE_DB}")

def save_offline(endpoint, data):
    try:
        conn = sqlite3.connect(OFFLINE_DB)
        c = conn.cursor()
        c.execute('INSERT INTO queue (endpoint, data) VALUES (?, ?)',
                  (endpoint, json.dumps(data)))
        conn.commit()
        conn.close()
        stats['offline'] += 1
        logger.info(f"Saved to offline queue: {endpoint}")
        return True
    except Exception as e:
        logger.error(f"Failed to save offline: {e}")
        return False

def forward_offline():
    try:
        conn = sqlite3.connect(OFFLINE_DB)
        conn.row_factory = sqlite3.Row
        c = conn.cursor()
        c.execute('SELECT * FROM queue WHERE attempts < 3 ORDER BY timestamp ASC LIMIT 20')
        records = c.fetchall()
        
        if not records:
            return
        
        logger.info(f"Processing {len(records)} offline records...")
        
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
                    logger.info(f"Successfully forwarded offline record {record['id']}")
                else:
                    c.execute('UPDATE queue SET attempts = attempts + 1, last_attempt = CURRENT_TIMESTAMP WHERE id = ?', (record['id'],))
            except Exception as e:
                c.execute('UPDATE queue SET attempts = attempts + 1, last_attempt = CURRENT_TIMESTAMP WHERE id = ?', (record['id'],))
        
        conn.commit()
        conn.close()
    except Exception as e:
        logger.error(f"Error processing offline queue: {e}")

def forward_to_database(endpoint, data):
    try:
        response = requests.post(
            f"{DATABASE_PI_URL}{endpoint}",
            json=data,
            timeout=10
        )
        if response.status_code == 200:
            stats['forwarded'] += 1
            logger.info(f"Forwarded {endpoint}: Status {response.status_code}")
            return True, response.json()
        else:
            logger.warning(f"Forward {endpoint} failed: Status {response.status_code}")
            return False, None
    except Exception as e:
        logger.warning(f"Forward failed: {e}")
        return False, None

@app.route('/api/sensor-data', methods=['POST'])
def handle_sensor_data():
    stats['received'] += 1
    try:
        data = request.json
        if not data:
            return jsonify({"error": "No data provided"}), 400
        
        machine_id = data.get('machine_id')
        if not machine_id:
            return jsonify({"error": "Missing machine_id"}), 400
        
        logger.info(f"Received data from sensor {machine_id}")
        
        success, response = forward_to_database('/api/sensor-data', data)
        if success:
            return jsonify({"status": "forwarded"}), 200
        else:
            if save_offline('/api/sensor-data', data):
                return jsonify({"status": "stored_offline"}), 202
            else:
                return jsonify({"error": "Failed to store offline"}), 500
    except Exception as e:
        logger.error(f"Error handling sensor data: {e}")
        return jsonify({"error": "Internal server error"}), 500

@app.route('/api/sensors/register', methods=['POST'])
def handle_register():
    stats['received'] += 1
    try:
        data = request.json
        if not data:
            return jsonify({"error": "No data provided"}), 400
        
        machine_id = data.get('machine_id')
        if not machine_id:
            return jsonify({"error": "Missing machine_id"}), 400
        
        logger.info(f"Registration request for sensor {machine_id}")
        
        success, response = forward_to_database('/api/sensors/register', data)
        if success:
            return jsonify(response), 200
        else:
            if save_offline('/api/sensors/register', data):
                return jsonify({"status": "queued"}), 202
            else:
                return jsonify({"error": "Failed to queue registration"}), 500
    except Exception as e:
        logger.error(f"Error handling registration: {e}")
        return jsonify({"error": "Internal server error"}), 500

@app.route('/api/sensors/<machine_id>/assignment', methods=['GET'])
def handle_assignment(machine_id):
    try:
        logger.info(f"Assignment check for sensor {machine_id}")
        response = requests.get(
            f"{DATABASE_PI_URL}/api/sensors/{machine_id}/assignment",
            timeout=10
        )
        if response.status_code == 200:
            return jsonify(response.json()), 200
        else:
            return jsonify(response.json()), response.status_code
    except Exception as e:
        logger.warning(f"Assignment check failed: {e}")
        return jsonify({
            "error": "database_unavailable",
            "machine_id": machine_id,
            "suggestion": "Retry later"
        }), 503

@app.route('/api/test', methods=['GET'])
def test():
    db_status = "unknown"
    try:
        response = requests.get(f"{DATABASE_PI_URL}/api/test", timeout=5)
        db_status = "connected" if response.status_code == 200 else f"error_{response.status_code}"
    except:
        db_status = "disconnected"
    
    return jsonify({
        "gateway": "online",
        "timestamp": datetime.now().isoformat(),
        "database_pi": db_status,
        "database_url": DATABASE_PI_URL
    })

@app.route('/api/health', methods=['GET'])
def health():
    return jsonify({
        "status": "healthy",
        "timestamp": datetime.now().isoformat(),
        "stats": stats,
        "database_url": DATABASE_PI_URL
    })

def background_worker():
    while True:
        time.sleep(60)
        try:
            forward_offline()
        except Exception as e:
            logger.error(f"Background worker error: {e}")

if __name__ == '__main__':
    print("=" * 60)
    print("🚀 IoT Gateway Starting")
    print(f"   Host: 0.0.0.0:{PORT}")
    print(f"   Database Pi: {DATABASE_PI_URL}")
    print(f"   Offline Storage: {OFFLINE_DB}")
    print(f"   Log File: {LOG_FILE}")
    print("=" * 60)
    
    init_offline_db()
    
    worker = Thread(target=background_worker, daemon=True)
    worker.start()
    
    app.run(host='0.0.0.0', port=PORT, debug=False, threaded=True)
EOF

# Update IP in the Python file
sed -i "s|http://192.168.1.95:5000|http://${DB_PI_IP}:5000|g" "$GATEWAY_DIR/gateway.py"

# Step 6: Set correct permissions for everything
print_status "Setting permissions..."
chown -R $GATEWAY_USER:$GATEWAY_USER "$GATEWAY_DIR"
chmod 755 "$GATEWAY_DIR"
chmod 644 "$GATEWAY_DIR/gateway.py"

# Create log directory with correct permissions
mkdir -p "$LOG_DIR"
chown $GATEWAY_USER:$GATEWAY_USER "$LOG_DIR"
chmod 755 "$LOG_DIR"

# Step 7: Create systemd service
print_status "Creating systemd service..."
cat > "/etc/systemd/system/$SERVICE_NAME.service" << EOF
[Unit]
Description=IoT Forwarding Gateway
After=network.target
Wants=network.target

[Service]
Type=simple
User=$GATEWAY_USER
Group=$GATEWAY_USER
WorkingDirectory=$GATEWAY_DIR
ExecStart=/usr/bin/python3 $GATEWAY_DIR/gateway.py
Restart=always
RestartSec=10
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=$SERVICE_NAME

# Security
NoNewPrivileges=true
ProtectSystem=strict
PrivateTmp=true
ReadWritePaths=$GATEWAY_DIR/data $LOG_DIR

[Install]
WantedBy=multi-user.target
EOF

# Step 8: Enable and start
print_status "Starting gateway service..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"

# Wait a moment
sleep 5

# Step 9: Check status
if systemctl is-active --quiet "$SERVICE_NAME"; then
    print_status "✅ Gateway is running!"
    
    # Show logs
    echo ""
    print_status "Checking startup logs..."
    journalctl -u "$SERVICE_NAME" -n 10 --no-pager
    
    # Test API
    echo ""
    print_status "Testing API endpoint..."
    sleep 2
    curl -s http://localhost:5000/api/test | python3 -m json.tool 2>/dev/null || \
        echo "API test failed - check logs"
else
    print_error "Failed to start gateway"
    echo ""
    print_error "Last 20 lines of logs:"
    journalctl -u "$SERVICE_NAME" -n 20 --no-pager
    exit 1
fi

# Step 10: Create management script
print_status "Creating management script..."
cat > "$GATEWAY_DIR/manage.sh" << 'EOF'
#!/bin/bash
SERVICE="iot-gateway"
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
        sudo systemctl status $SERVICE --no-pager
        ;;
    logs) 
        sudo journalctl -u $SERVICE -f
        ;;
    test) 
        curl -s http://localhost:5000/api/test | python3 -m json.tool
        ;;
    health) 
        curl -s http://localhost:5000/api/health | python3 -m json.tool
        ;;
    offline-stats)
        sudo -u gateway sqlite3 /home/gateway/iot-gateway/data/offline.db "SELECT COUNT(*) as total, COUNT(CASE WHEN attempts > 0 THEN 1 END) as failed FROM queue"
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|logs|test|health|offline-stats}"
        echo ""
        echo "Commands:"
        echo "  start          - Start gateway service"
        echo "  stop           - Stop gateway service"
        echo "  restart        - Restart gateway service"
        echo "  status         - Check service status"
        echo "  logs           - View live logs"
        echo "  test           - Test API connectivity"
        echo "  health         - Check gateway health"
        echo "  offline-stats  - Show offline queue statistics"
        ;;
esac
EOF

chmod +x "$GATEWAY_DIR/manage.sh"
chown $GATEWAY_USER:$GATEWAY_USER "$GATEWAY_DIR/manage.sh"

# Create symlink for easy access
ln -sf "$GATEWAY_DIR/manage.sh" /usr/local/bin/gateway-manage 2>/dev/null || true

# Step 11: Create logrotate configuration
print_status "Setting up log rotation..."
cat > "/etc/logrotate.d/$SERVICE_NAME" << EOF
$LOG_DIR/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 644 $GATEWAY_USER $GATEWAY_USER
    postrotate
        systemctl kill -s HUP $SERVICE_NAME.service 2>/dev/null || true
    endscript
}
EOF

# Display summary
echo ""
echo "========================================"
print_status "✅ IoT Gateway Installation Complete!"
echo "========================================"
echo ""
echo "📊 INSTALLATION SUMMARY:"
echo "   Username:      $GATEWAY_USER"
echo "   Directory:     $GATEWAY_DIR"
echo "   Service:       $SERVICE_NAME"
echo "   Port:          5000"
echo "   Database Pi:   $DB_PI_IP:5000 (appV7.py)"
echo "   Logs:          $LOG_DIR"
echo "   Offline DB:    $GATEWAY_DIR/data/offline.db"
echo ""
echo "🛠️  MANAGEMENT COMMANDS:"
echo "   gateway-manage start          # Start gateway"
echo "   gateway-manage status         # Check status"
echo "   gateway-manage logs           # View logs"
echo "   gateway-manage test           # Test API"
echo "   gateway-manage health         # Health check"
echo "   gateway-manage offline-stats  # Offline queue stats"
echo ""
echo "🌐 TEST ENDPOINTS:"
echo "   http://$(hostname -I | awk '{print $1}'):5000/api/test"
echo "   http://$(hostname -I | awk '{print $1}'):5000/api/health"
echo ""
echo "🔧 TROUBLESHOOTING:"
echo "   sudo journalctl -u $SERVICE_NAME -f     # Live logs"
echo "   sudo -u gateway ls -la $GATEWAY_DIR/data/  # Check data dir"
echo "   sudo -u gateway ls -la $LOG_DIR/            # Check logs dir"
echo ""
print_status "Gateway should now be running and forwarding to appV7.py at $DB_PI_IP:5000"
echo "========================================"
