#!/bin/bash
# Soil Monitoring Gateway - Installation Script
# GitHub: https://github.com/yourusername/soil-monitoring-gateway

echo "================================================"
echo "Installing Soil Monitoring Gateway Pi"
echo "GitHub Repository: soil-monitoring-gateway"
echo "================================================"

# ========================
# COLOR OUTPUT
# ========================
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

print_green() {
    echo -e "${GREEN}[✓] $1${NC}"
}

print_yellow() {
    echo -e "${YELLOW}[!] $1${NC}"
}

print_red() {
    echo -e "${RED}[✗] $1${NC}"
}

# ========================
# CHECK RUN AS PI USER
# ========================
if [[ "$USER" != "pi" ]]; then
    print_yellow "Warning: Not running as 'pi' user. Run with: sudo -u pi $0"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# ========================
# CHECK FOR GIT
# ========================
print_green "[1/12] Checking for Git installation..."
if ! command -v git &> /dev/null; then
    print_yellow "Git not found, installing..."
    sudo apt update
    sudo apt install git -y
else
    print_green "Git already installed"
fi

# ========================
# SYSTEM UPDATE
# ========================
print_green "[2/12] Updating system packages..."
sudo apt update
sudo apt upgrade -y

# ========================
# INSTALL SYSTEM DEPENDENCIES
# ========================
print_green "[3/12] Installing system dependencies..."
sudo apt install python3 python3-pip python3-venv python3-dev -y
sudo apt install curl wget -y
sudo apt install libmariadb-dev -y  # For MySQL client library

# ========================
# CREATE APPLICATION STRUCTURE
# ========================
print_green "[4/12] Setting up application directory structure..."

# Main application directory
APP_DIR="/home/pi/soil-gateway"
sudo mkdir -p $APP_DIR
sudo chown pi:pi $APP_DIR
sudo chmod 755 $APP_DIR

# Gateway data directory
GATEWAY_DATA_DIR="/home/pi/soil_gateway_data"
sudo mkdir -p $GATEWAY_DATA_DIR
sudo chown pi:pi $GATEWAY_DATA_DIR
sudo chmod 755 $GATEWAY_DATA_DIR

print_green "Application directories created:"
print_green "  - $APP_DIR (Python code)"
print_green "  - $GATEWAY_DATA_DIR (offline storage)"

# ========================
# COPY GATEWAY FILES
# ========================
print_green "[5/12] Copying gateway files..."

# Check if we're running from git repository directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [ -f "$SCRIPT_DIR/gateway.py" ]; then
    print_green "Copying gateway.py from $SCRIPT_DIR..."
    cp -f "$SCRIPT_DIR/gateway.py" $APP_DIR/
    chmod +x $APP_DIR/gateway.py
    
    # Copy other Python files if they exist
    for pyfile in "$SCRIPT_DIR"/*.py; do
        if [ "$(basename "$pyfile")" != "gateway.py" ] && [ "$(basename "$pyfile")" != "install.sh" ]; then
            cp -f "$pyfile" $APP_DIR/
            print_green "Copied: $(basename "$pyfile")"
        fi
    done
    
    # Copy requirements.txt if it exists
    if [ -f "$SCRIPT_DIR/requirements.txt" ]; then
        cp -f "$SCRIPT_DIR/requirements.txt" $APP_DIR/
        print_green "Copied: requirements.txt"
    fi
    
    # Copy README if it exists
    if [ -f "$SCRIPT_DIR/README.md" ]; then
        cp -f "$SCRIPT_DIR/README.md" $APP_DIR/
        print_green "Copied: README.md"
    fi
else
    print_red "Error: gateway.py not found in $SCRIPT_DIR"
    print_yellow "Please run this script from the soil-monitoring-gateway repository directory"
    exit 1
fi

# ========================
# CREATE PYTHON VIRTUAL ENVIRONMENT
# ========================
print_green "[6/12] Creating Python virtual environment..."

VENV_PATH="/home/pi/soil-gateway-venv"
if [ -d "$VENV_PATH" ]; then
    print_yellow "Virtual environment already exists at $VENV_PATH"
    read -p "Do you want to recreate it? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_yellow "Removing existing virtual environment..."
        rm -rf $VENV_PATH
    else
        print_yellow "Using existing virtual environment..."
    fi
fi

if [ ! -d "$VENV_PATH" ]; then
    python3 -m venv $VENV_PATH
    if [ $? -eq 0 ]; then
        print_green "Virtual environment created at $VENV_PATH"
    else
        print_red "Failed to create virtual environment"
        exit 1
    fi
fi

# ========================
# INSTALL PYTHON PACKAGES
# ========================
print_green "[7/12] Installing Python packages..."

# Activate virtual environment
source $VENV_PATH/bin/activate

# Upgrade pip
pip install --upgrade pip

# Install from requirements.txt if it exists
if [ -f "$APP_DIR/requirements.txt" ]; then
    print_green "Installing from requirements.txt..."
    pip install -r $APP_DIR/requirements.txt
else
    # Install required packages
    print_green "Installing required packages..."
    pip install flask==2.3.3
    pip install requests==2.31.0
    pip install mysql-connector-python==8.1.0
    pip install python-dotenv==1.0.0
    
    # Create requirements.txt for future use
    pip freeze > $APP_DIR/requirements.txt
    print_green "Created requirements.txt"
fi

# Deactivate virtual environment
deactivate

print_green "Python packages installed successfully"

# ========================
# UPDATE CONFIGURATION IF NEEDED
# ========================
print_green "[8/12] Checking gateway configuration..."

GATEWAY_FILE="$APP_DIR/gateway.py"
if [ -f "$GATEWAY_FILE" ]; then
    # Update offline storage path if it's different
    CURRENT_PATH=$(grep "OFFLINE_STORAGE_PATH" "$GATEWAY_FILE" | grep -o "'.*'" | tr -d "'")
    if [[ "$CURRENT_PATH" != "$GATEWAY_DATA_DIR/offline_queue.db" ]]; then
        print_yellow "Updating offline storage path in gateway.py..."
        sed -i "s|$CURRENT_PATH|$GATEWAY_DATA_DIR/offline_queue.db|g" "$GATEWAY_FILE"
        print_green "Updated offline storage path"
    fi
    
    # Show current MySQL configuration
    DB_HOST=$(grep -A1 "'host':" "$GATEWAY_FILE" | tail -1 | grep -o "'.*'" | tr -d "'" || echo "192.168.1.100")
    DB_USER=$(grep -A1 "'user':" "$GATEWAY_FILE" | tail -1 | grep -o "'.*'" | tr -d "'" || echo "gateway_user")
    
    echo ""
    print_yellow "Current configuration in gateway.py:"
    print_yellow "  MySQL Host: $DB_HOST"
    print_yellow "  MySQL User: $DB_USER"
    print_yellow "  Offline Storage: $GATEWAY_DATA_DIR/offline_queue.db"
    echo ""
    print_yellow "To change these values, edit:"
    print_yellow "  sudo nano $APP_DIR/gateway.py"
else
    print_red "Error: gateway.py not found in $APP_DIR"
    exit 1
fi

# ========================
# CREATE CONFIGURATION BACKUP
# ========================
print_green "[9/12] Creating configuration backup..."

# Create a backup of the original gateway.py
BACKUP_FILE="$APP_DIR/gateway.py.backup"
if [ ! -f "$BACKUP_FILE" ]; then
    cp "$APP_DIR/gateway.py" "$BACKUP_FILE"
    print_green "Created backup: $BACKUP_FILE"
fi

# ========================
# SETUP AUTO-START SERVICE
# ========================
print_green "[10/12] Setting up auto-start service..."

# Create systemd service file
SERVICE_FILE="/etc/systemd/system/soil-gateway.service"
sudo tee $SERVICE_FILE > /dev/null << EOF
[Unit]
Description=Soil Monitoring Gateway Service
After=network.target mysql.service
Wants=network.target
StartLimitIntervalSec=500
StartLimitBurst=5

[Service]
Type=simple
User=pi
WorkingDirectory=$APP_DIR

# Activate virtual environment and run gateway.py
ExecStart=$VENV_PATH/bin/python $APP_DIR/gateway.py

Restart=always
RestartSec=10
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=soil-gateway

# Environment variables
Environment="PATH=$VENV_PATH/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="PYTHONPATH=$APP_DIR"

# Security enhancements
NoNewPrivileges=true
ProtectSystem=strict
PrivateTmp=true
ReadWritePaths=$GATEWAY_DATA_DIR
ProtectHome=read-only

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable service
sudo systemctl daemon-reload
sudo systemctl enable soil-gateway.service

print_green "Systemd service created and enabled"

# ========================
# SETUP LOG ROTATION
# ========================
print_green "[11/12] Setting up log rotation..."

# Create logrotate configuration
LOGROTATE_FILE="/etc/logrotate.d/soil-gateway"
sudo tee $LOGROTATE_FILE > /dev/null << EOF
$GATEWAY_DATA_DIR/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 644 pi pi
    postrotate
        systemctl kill -s HUP soil-gateway.service 2>/dev/null || true
    endscript
}
EOF

print_green "Log rotation configured (keeps 14 days of logs)"

# ========================
# CREATE UTILITY SCRIPTS
# ========================
print_green "[12/12] Creating utility scripts..."

# Start script
START_SCRIPT="$APP_DIR/start-gateway.sh"
sudo tee $START_SCRIPT > /dev/null << 'EOF'
#!/bin/bash
# Start Soil Monitoring Gateway

echo "Starting Soil Monitoring Gateway..."
source /home/pi/soil-gateway-venv/bin/activate
cd /home/pi/soil-gateway
python gateway.py
EOF
chmod +x $START_SCRIPT

# Management script
MANAGE_SCRIPT="$APP_DIR/manage-gateway.sh"
sudo tee $MANAGE_SCRIPT > /dev/null << 'EOF'
#!/bin/bash
# Soil Monitoring Gateway Management Script

case "$1" in
    start)
        sudo systemctl start soil-gateway
        echo "Gateway started"
        ;;
    stop)
        sudo systemctl stop soil-gateway
        echo "Gateway stopped"
        ;;
    restart)
        sudo systemctl restart soil-gateway
        echo "Gateway restarted"
        ;;
    status)
        sudo systemctl status soil-gateway --no-pager
        ;;
    logs)
        sudo journalctl -u soil-gateway -f
        ;;
    config)
        echo "Editing gateway configuration..."
        sudo nano /home/pi/soil-gateway/gateway.py
        ;;
    update)
        echo "Updating from GitHub..."
        cd /home/pi/soil-gateway
        git pull
        sudo systemctl restart soil-gateway
        echo "Update completed"
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|logs|config|update}"
        echo ""
        echo "Commands:"
        echo "  start     - Start the gateway service"
        echo "  stop      - Stop the gateway service"
        echo "  restart   - Restart the gateway service"
        echo "  status    - Check gateway status"
        echo "  logs      - View gateway logs (follow mode)"
        echo "  config    - Edit gateway configuration"
        echo "  update    - Update from GitHub and restart"
        exit 1
        ;;
esac
EOF
chmod +x $MANAGE_SCRIPT

# MySQL setup script
MYSQL_SCRIPT="$APP_DIR/setup-mysql.sql"
sudo tee $MYSQL_SCRIPT > /dev/null << 'EOF'
-- MySQL Setup for Soil Monitoring Gateway
-- Run these commands in MySQL as root or admin user

-- 1. Create gateway user (change 'strong_password' to your password)
CREATE USER IF NOT EXISTS 'gateway_user'@'%' IDENTIFIED BY 'strong_password';

-- 2. Grant necessary permissions
GRANT INSERT, SELECT ON soilmonitornig.sensor_data TO 'gateway_user'@'%';
GRANT SELECT ON soilmonitornig.sensors TO 'gateway_user'@'%';
GRANT SELECT ON soilmonitornig.farms TO 'gateway_user'@'%';
GRANT SELECT ON soilmonitornig.client TO 'gateway_user'@'%';

-- 3. For better security, restrict to specific IP (replace 192.168.1.XXX with your Pi's IP)
-- DROP USER 'gateway_user'@'%';
-- CREATE USER 'gateway_user'@'192.168.1.XXX' IDENTIFIED BY 'strong_password';
-- GRANT ... TO 'gateway_user'@'192.168.1.XXX';

-- 4. Flush privileges
FLUSH PRIVILEGES;

-- 5. Verify permissions
SHOW GRANTS FOR 'gateway_user'@'%';
EOF

# Firewall configuration
print_green "Configuring firewall..."
sudo ufw allow 5000/tcp  # Gateway port
sudo ufw allow 22/tcp    # SSH
sudo ufw --force enable 2>/dev/null || true

# Set permissions
sudo chown -R pi:pi $APP_DIR
sudo chown -R pi:pi $GATEWAY_DATA_DIR

# ========================
# INSTALLATION COMPLETE
# ========================
echo ""
echo "================================================"
echo -e "${GREEN}✅ SOIL MONITORING GATEWAY INSTALLATION COMPLETE!${NC}"
echo "================================================"
echo ""
echo "📋 INSTALLATION SUMMARY:"
echo "   ✅ Gateway: $APP_DIR/gateway.py"
echo "   ✅ Virtual Environment: $VENV_PATH"
echo "   ✅ Data Directory: $GATEWAY_DATA_DIR"
echo "   ✅ Service: soil-gateway.service (auto-start on boot)"
echo ""
echo "🔧 CONFIGURATION STEPS:"
echo "1. Setup MySQL user:"
echo "   mysql -u root -p < $APP_DIR/setup-mysql.sql"
echo ""
echo "2. Update gateway configuration if needed:"
echo "   sudo nano $APP_DIR/gateway.py"
echo "   (Update MySQL IP, credentials, API URL)"
echo ""
echo "3. Start the gateway:"
echo "   sudo systemctl start soil-gateway"
echo ""
echo "🔧 MANAGEMENT COMMANDS:"
echo "   $APP_DIR/manage-gateway.sh start     # Start gateway"
echo "   $APP_DIR/manage-gateway.sh stop      # Stop gateway"
echo "   $APP_DIR/manage-gateway.sh restart   # Restart gateway"
echo "   $APP_DIR/manage-gateway.sh status    # Check status"
echo "   $APP_DIR/manage-gateway.sh logs      # View logs"
echo "   $APP_DIR/manage-gateway.sh config    # Edit config"
echo ""
echo "🌐 TEST THE GATEWAY:"
echo "   curl http://localhost:5000/api/test"
echo "   curl http://localhost:5000/api/health"
echo ""
echo "📡 GATEWAY ENDPOINTS:"
echo "   POST /api/sensor-data              # Sensor data ingestion"
echo "   POST /api/sensors/register         # Sensor registration"
echo "   GET  /api/sensors/{id}/assignment  # Check assignment"
echo "   GET  /api/health                   # Health check"
echo "   GET  /api/test                     # Connectivity test"
echo ""
echo "💾 DATA FLOW:"
echo "   Sensors → Gateway (Port 5000) → MySQL Database"
echo "   Offline data stored in: $GATEWAY_DATA_DIR"
echo ""
echo "🐙 GITHUB REPOSITORY:"
echo "   https://github.com/yourusername/soil-monitoring-gateway"
echo ""
echo "================================================"
echo -e "${YELLOW}⚠️  IMPORTANT: Update MySQL credentials in gateway.py!${NC}"
echo "================================================"
