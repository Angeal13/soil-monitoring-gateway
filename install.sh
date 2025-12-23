#!/bin/bash
# Gateway Installer for Raspberry Pi
# This script installs dependencies, sets up the gateway as a system service

set -e  # Exit on error

echo "========================================"
echo "🚀 IoT Gateway Installation Script"
echo "========================================"

# Configuration
GATEWAY_USER="gateway"  # Changed from 'pi' to 'gateway'
GATEWAY_DIR="/home/$GATEWAY_USER/soil-monitoring-gateway"
SERVICE_NAME="soil-gateway"  # Shorter, cleaner service name
VENV_DIR="$GATEWAY_DIR/venv"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
print_status() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    print_error "Please run as root (use sudo)"
    exit 1
fi

# Step 0: Create gateway user if it doesn't exist
if ! id "$GATEWAY_USER" &>/dev/null; then
    print_status "Creating user '$GATEWAY_USER'..."
    useradd -m -s /bin/bash "$GATEWAY_USER"
    echo "User '$GATEWAY_USER' created successfully."
    
    # Set password for gateway user (optional - you'll be prompted)
    echo "Please set a password for the '$GATEWAY_USER' user:"
    passwd "$GATEWAY_USER"
else
    print_status "User '$GATEWAY_USER' already exists."
fi

# Add gateway user to necessary groups
usermod -a -G dialout,plugdev "$GATEWAY_USER"

# Step 1: Update system packages
print_status "Updating system packages..."
apt-get update && apt-get upgrade -y

# Step 2: Install required system packages
print_status "Installing system dependencies..."
apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    default-libmysqlclient-dev \
    build-essential \
    pkg-config \
    git \
    supervisor

# Step 3: Clone or copy gateway code
print_status "Setting up gateway directory..."
if [ -d "$GATEWAY_DIR" ]; then
    print_warning "Gateway directory already exists. Backing up..."
    backup_dir="${GATEWAY_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
    cp -r "$GATEWAY_DIR" "$backup_dir"
    print_status "Backup created at: $backup_dir"
    rm -rf "$GATEWAY_DIR"
fi

# Create directory and copy files
mkdir -p "$GATEWAY_DIR"
print_status "Copying gateway files..."

# If running from the script location, copy current directory
if [ -f "main.py" ]; then
    cp main.py "$GATEWAY_DIR/"
    print_status "Copied main.py"
else
    print_error "main.py not found in current directory!"
    exit 1
fi

# Create additional necessary files
print_status "Creating requirements.txt..."
cat > "$GATEWAY_DIR/requirements.txt" << 'EOF'
Flask==2.3.3
mysql-connector-python==8.1.0
gunicorn==21.2.0
python-dotenv==1.0.0
EOF

print_status "Creating config.py..."
cat > "$GATEWAY_DIR/config.py" << 'EOF'
# Gateway Configuration
HOST = '0.0.0.0'
PORT = 5001
DEBUG = False
LOG_LEVEL = "INFO"
BATCH_PROCESS_INTERVAL = 60
MAX_BUFFER_SIZE = 1000

# Database configuration (update these for your setup)
PI_DB_CONFIG = {
    'user': 'DevOps',
    'password': 'DevTeam',
    'host': '192.168.1.76',
    'database': 'soilmonitornig',
    'raise_on_warnings': True
}
EOF

# Create a .env file for sensitive data (optional)
print_status "Creating .env template..."
cat > "$GATEWAY_DIR/.env.example" << 'EOF'
# Database credentials
DB_HOST=192.168.1.76
DB_USER=DevOps
DB_PASSWORD=DevTeam
DB_NAME=soilmonitornig

# Gateway settings
GATEWAY_PORT=5001
LOG_LEVEL=INFO
EOF

# Set ownership
chown -R $GATEWAY_USER:$GATEWAY_USER "$GATEWAY_DIR"

# Step 4: Create Python virtual environment
print_status "Creating Python virtual environment..."
sudo -u $GATEWAY_USER python3 -m venv "$VENV_DIR"

# Step 5: Install Python dependencies
print_status "Installing Python dependencies..."
sudo -u $GATEWAY_USER "$VENV_DIR/bin/pip" install --upgrade pip
sudo -u $GATEWAY_USER "$VENV_DIR/bin/pip" install --break-system-packages -r "$GATEWAY_DIR/requirements.txt"

# Step 6: Create log directory
print_status "Setting up logging..."
LOG_DIR="/var/log/$SERVICE_NAME"
mkdir -p "$LOG_DIR"
chown $GATEWAY_USER:$GATEWAY_USER "$LOG_DIR"
chmod 755 "$LOG_DIR"

# Step 7: Create systemd service file
print_status "Creating systemd service..."
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Soil Monitoring IoT Gateway Service
After=network.target mysql.service
Wants=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=$GATEWAY_USER
Group=$GATEWAY_USER
WorkingDirectory=$GATEWAY_DIR
Environment="PATH=$VENV_DIR/bin"
Environment="PYTHONPATH=$GATEWAY_DIR"
ExecStart=$VENV_DIR/bin/python main.py
Restart=always
RestartSec=10
StandardOutput=append:$LOG_DIR/gateway.log
StandardError=append:$LOG_DIR/gateway-error.log

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=$LOG_DIR $GATEWAY_DIR
ReadOnlyPaths=/etc

[Install]
WantedBy=multi-user.target
EOF

# Step 8: Create supervisor configuration (alternative option)
print_status "Creating Supervisor configuration (optional)..."
SUPERVISOR_CONF="/etc/supervisor/conf.d/${SERVICE_NAME}.conf"

cat > "$SUPERVISOR_CONF" << EOF
[program:$SERVICE_NAME]
command=$VENV_DIR/bin/python main.py
directory=$GATEWAY_DIR
user=$GATEWAY_USER
autostart=true
autorestart=true
stderr_logfile=$LOG_DIR/supervisor-error.log
stdout_logfile=$LOG_DIR/supervisor.log
environment=PYTHONPATH="$GATEWAY_DIR",PATH="$VENV_DIR/bin:%(ENV_PATH)s"
EOF

# Step 9: Enable and start the service
print_status "Enabling and starting gateway service..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"

# Wait a moment for service to start
sleep 3

# Step 10: Check service status
print_status "Checking service status..."
if systemctl is-active --quiet "$SERVICE_NAME"; then
    print_status "Service is running successfully!"
else
    print_error "Service failed to start. Checking logs..."
    journalctl -u "$SERVICE_NAME" --no-pager -n 20
    exit 1
fi

# Step 11: Create setup completion file
print_status "Creating setup completion marker..."
cat > "$GATEWAY_DIR/.setup-complete" << EOF
Gateway installed: $(date)
Service: $SERVICE_NAME
User: $GATEWAY_USER
Logs: $LOG_DIR
Virtual Environment: $VENV_DIR
EOF

# Step 12: Create management script
print_status "Creating management script..."
cat > "$GATEWAY_DIR/manage-gateway.sh" << 'EOF'
#!/bin/bash
# Gateway Management Script

SERVICE_NAME="soil-gateway"
LOG_DIR="/var/log/$SERVICE_NAME"
GATEWAY_USER="gateway"

case "$1" in
    start)
        sudo systemctl start $SERVICE_NAME
        echo "Gateway started"
        ;;
    stop)
        sudo systemctl stop $SERVICE_NAME
        echo "Gateway stopped"
        ;;
    restart)
        sudo systemctl restart $SERVICE_NAME
        echo "Gateway restarted"
        ;;
    status)
        sudo systemctl status $SERVICE_NAME
        ;;
    logs)
        sudo tail -f $LOG_DIR/gateway.log
        ;;
    errors)
        sudo tail -f $LOG_DIR/gateway-error.log
        ;;
    update)
        echo "Updating gateway..."
        cd /home/gateway/soil-monitoring-gateway
        sudo -u gateway git pull
        sudo systemctl restart $SERVICE_NAME
        ;;
    backup)
        echo "Creating backup..."
        BACKUP_DIR="/home/gateway/backup_$(date +%Y%m%d_%H%M%S)"
        sudo -u gateway cp -r /home/gateway/soil-monitoring-gateway "$BACKUP_DIR"
        echo "Backup created at: $BACKUP_DIR"
        ;;
    switch-user)
        echo "Switching to gateway user..."
        sudo su - gateway
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|logs|errors|update|backup|switch-user}"
        exit 1
        ;;
esac
EOF

chmod +x "$GATEWAY_DIR/manage-gateway.sh"
chown $GATEWAY_USER:$GATEWAY_USER "$GATEWAY_DIR/manage-gateway.sh"

# Create symbolic link for easier access
if [ -f "/usr/local/bin/manage-gateway" ]; then
    rm /usr/local/bin/manage-gateway
fi
ln -s "$GATEWAY_DIR/manage-gateway.sh" /usr/local/bin/manage-gateway
chmod +x /usr/local/bin/manage-gateway

# Step 13: Create a test script
print_status "Creating test script..."
cat > "$GATEWAY_DIR/test-gateway.sh" << 'EOF'
#!/bin/bash
# Test script for the gateway

echo "Testing Gateway Installation..."
echo "================================"

# Test 1: Check if service is running
echo "1. Checking service status..."
sudo systemctl is-active soil-gateway && echo "✓ Service is running" || echo "✗ Service is not running"

# Test 2: Check API endpoint
echo ""
echo "2. Testing API endpoint..."
curl -s http://localhost:5001/api/health | python3 -m json.tool || echo "✗ API not responding"

# Test 3: Check logs
echo ""
echo "3. Checking recent logs..."
tail -5 /var/log/soil-gateway/gateway.log 2>/dev/null || echo "No logs found"

# Test 4: Check database connection (optional)
echo ""
echo "4. Checking Python environment..."
sudo -u gateway /home/gateway/soil-monitoring-gateway/venv/bin/python --version

echo ""
echo "================================"
echo "Tests completed!"
EOF

chmod +x "$GATEWAY_DIR/test-gateway.sh"
chown $GATEWAY_USER:$GATEWAY_USER "$GATEWAY_DIR/test-gateway.sh"

# Step 14: Display installation summary
print_status "========================================"
print_status "✅ Installation Complete!"
print_status "========================================"
echo ""
echo "📊 Installation Summary:"
echo "   Username:           $GATEWAY_USER"
echo "   Gateway Directory:  $GATEWAY_DIR"
echo "   Virtual Environment: $VENV_DIR"
echo "   Service Name:       $SERVICE_NAME"
echo "   Log Directory:      $LOG_DIR"
echo ""
echo "🛠️  Management Commands:"
echo "   Start:             sudo systemctl start $SERVICE_NAME"
echo "   Stop:              sudo systemctl stop $SERVICE_NAME"
echo "   Restart:           sudo systemctl restart $SERVICE_NAME"
echo "   Status:            sudo systemctl status $SERVICE_NAME"
echo "   View Logs:         sudo tail -f $LOG_DIR/gateway.log"
echo "   Quick Management:  manage-gateway {start|stop|restart|status|logs|errors}"
echo "   Switch User:       sudo su - gateway"
echo ""
echo "🔧 Next Steps:"
echo "   1. Review configuration: sudo -u gateway nano $GATEWAY_DIR/config.py"
echo "   2. Test the installation: $GATEWAY_DIR/test-gateway.sh"
echo "   3. Monitor logs: sudo tail -f $LOG_DIR/gateway.log"
echo ""
echo "🌐 Gateway will be accessible at:"
echo "   - Locally: http://localhost:5001"
echo "   - Network: http://<raspberry-pi-ip>:5001"
echo ""
echo "📝 Quick Test Commands:"
echo "   curl http://localhost:5001/api/health"
echo "   manage-gateway status"
echo "   manage-gateway logs"
print_status "========================================"

# Display initial logs
print_status "Displaying initial logs..."
sleep 2
tail -10 "$LOG_DIR/gateway.log" 2>/dev/null || echo "No logs yet. Service is starting..."
