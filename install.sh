#!/bin/bash
echo "================================================"
echo "Installing Enhanced Gateway Pi with Virtual Environment"
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
fi

# ========================
# SYSTEM UPDATE
# ========================
print_green "[1/10] Updating system packages..."
sudo apt update
sudo apt upgrade -y

# ========================
# INSTALL SYSTEM DEPENDENCIES
# ========================
print_green "[2/10] Installing system dependencies..."
sudo apt install python3 python3-pip python3-venv python3-dev -y
sudo apt install git curl wget -y
sudo apt install libmariadb-dev -y  # For MySQL client library

# ========================
# CREATE APPLICATION STRUCTURE
# ========================
print_green "[3/10] Setting up application directory structure..."

# Main application directory
APP_DIR="/home/pi/gateway-app"
sudo mkdir -p $APP_DIR
sudo chown pi:pi $APP_DIR
sudo chmod 755 $APP_DIR

# Gateway data directory
GATEWAY_DATA_DIR="/home/pi/gateway_data"
sudo mkdir -p $GATEWAY_DATA_DIR
sudo chown pi:pi $GATEWAY_DATA_DIR
sudo chmod 755 $GATEWAY_DATA_DIR

# Logs directory
LOG_DIR="/home/pi/gateway_logs"
sudo mkdir -p $LOG_DIR
sudo chown pi:pi $LOG_DIR
sudo chmod 755 $LOG_DIR

print_green "Application directories created:"
print_green "  - $APP_DIR (Python code)"
print_green "  - $GATEWAY_DATA_DIR (offline storage)"
print_green "  - $LOG_DIR (system logs)"

# ========================
# CREATE PYTHON VIRTUAL ENVIRONMENT
# ========================
print_green "[4/10] Creating Python virtual environment..."

VENV_PATH="/home/pi/gateway-venv"
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
# ACTIVATE VENV AND INSTALL PYTHON PACKAGES
# ========================
print_green "[5/10] Installing Python packages in virtual environment..."

# Activate virtual environment
source $VENV_PATH/bin/activate

# Upgrade pip
pip install --upgrade pip

# Install Python packages
pip install flask==2.3.3
pip install requests==2.31.0
pip install mysql-connector-python==8.1.0
pip install python-dotenv==1.0.0

# Install development/testing packages
pip install pytest==7.4.2
pip install black==23.9.1

# Deactivate virtual environment
deactivate

print_green "Python packages installed successfully"

# ========================
# COPY GATEWAY CODE
# ========================
print_green "[6/10] Setting up gateway code..."

# Check if we're in the right directory
if [ -f "main.py" ]; then
    print_green "Copying gateway files to $APP_DIR..."
    cp -f main.py $APP_DIR/
    cp -f *.py $APP_DIR/ 2>/dev/null || true
    
    # Make main.py executable
    chmod +x $APP_DIR/main.py
else
    print_yellow "Note: No gateway code found in current directory"
    print_yellow "Please copy your gateway files to $APP_DIR manually"
fi

# ========================
# CREATE CONFIGURATION FILE
# ========================
print_green "[7/10] Creating configuration file..."

CONFIG_TEMPLATE="$APP_DIR/config_template.py"
sudo tee $CONFIG_TEMPLATE > /dev/null << 'EOF'
"""
Gateway Pi Configuration Template
Copy this to config.py and update with your values
"""

class Config:
    # Gateway settings
    GATEWAY_HOST = '0.0.0.0'
    GATEWAY_PORT = 5000  # MUST be 5000 (sensors expect this)
    
    # Database Pi (appV7.py) - API URL for non-data operations
    DATABASE_PI_API_URL = "http://192.168.1.95:5000"
    
    # Direct MySQL Configuration - UPDATE THESE!
    DB_CONFIG = {
        'host': '192.168.1.100',      # MySQL server IP
        'port': 3306,
        'database': 'soilmonitornig',
        'user': 'gateway_user',      # Create this user in MySQL
        'password': 'gateway_pass',  # Change this!
        'pool_name': 'gateway_pool',
        'pool_size': 5,
        'pool_reset_session': True
    }
    
    # Local offline storage
    OFFLINE_STORAGE_PATH = '/home/pi/gateway_data/offline_queue.db'
    MAX_OFFLINE_RECORDS = 10000
    
    # Forwarding settings
    API_TIMEOUT = 10
    MAX_RETRIES = 3
    RETRY_DELAY = 5
    
    # Health check interval (seconds)
    HEALTH_CHECK_INTERVAL = 300
    
    # Batch processing
    BATCH_SIZE = 50
    BATCH_INTERVAL = 60

print_green "Configuration template created at $CONFIG_TEMPLATE"

# ========================
# CREATE ENVIRONMENT VARIABLES FILE
# ========================
print_green "[8/10] Creating environment variables file..."

ENV_FILE="$APP_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
    sudo tee $ENV_FILE > /dev/null << 'EOF'
# Environment Variables for Gateway Pi
# This file is loaded by the application

# Virtual Environment Path
VENV_PATH="/home/pi/gateway-venv"

# Application Directory
APP_DIR="/home/pi/gateway-app"

# Logging
LOG_LEVEL="INFO"

# Database Credentials (Alternative to config.py)
# DB_USER="gateway_user"
# DB_PASSWORD="gateway_pass"
EOF
    chown pi:pi $ENV_FILE
    chmod 600 $ENV_FILE
    print_green "Environment file created at $ENV_FILE"
fi

# ========================
# SETUP AUTO-START SERVICE
# ========================
print_green "[9/10] Setting up auto-start service..."

# Create systemd service file with virtual environment activation
SERVICE_FILE="/etc/systemd/system/gateway-pi.service"
sudo tee $SERVICE_FILE > /dev/null << EOF
[Unit]
Description=Enhanced Gateway Pi Service
After=network.target mysql.service
Wants=network.target
StartLimitIntervalSec=500
StartLimitBurst=5

[Service]
Type=simple
User=pi
WorkingDirectory=$APP_DIR

# Activate virtual environment and run application
ExecStart=$VENV_PATH/bin/python $APP_DIR/main.py

Restart=always
RestartSec=10
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=gateway-pi

# Environment variables
Environment="PATH=$VENV_PATH/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="PYTHONPATH=$APP_DIR"

# Security enhancements
NoNewPrivileges=true
ProtectSystem=strict
PrivateTmp=true
ReadWritePaths=$GATEWAY_DATA_DIR $LOG_DIR
ProtectHome=read-only

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable service
sudo systemctl daemon-reload
sudo systemctl enable gateway-pi.service

print_green "Systemd service created and enabled"

# ========================
# SETUP LOG ROTATION
# ========================
print_green "[10/10] Setting up log rotation..."

# Create logrotate configuration
LOGROTATE_FILE="/etc/logrotate.d/gateway-pi"
sudo tee $LOGROTATE_FILE > /dev/null << EOF
$GATEWAY_DATA_DIR/*.log $LOG_DIR/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 644 pi pi
    postrotate
        systemctl kill -s HUP gateway-pi.service 2>/dev/null || true
    endscript
}
EOF

print_green "Log rotation configured (keeps 14 days of logs)"

# ========================
# CREATE USEFUL SCRIPTS
# ========================
print_green "Creating utility scripts..."

# Start script
START_SCRIPT="$APP_DIR/start.sh"
sudo tee $START_SCRIPT > /dev/null << 'EOF'
#!/bin/bash
# Start Gateway Pi with virtual environment

echo "Starting Gateway Pi..."
source /home/pi/gateway-venv/bin/activate
cd /home/pi/gateway-app
python main.py
EOF
chmod +x $START_SCRIPT

# Stop script
STOP_SCRIPT="$APP_DIR/stop.sh"
sudo tee $STOP_SCRIPT > /dev/null << 'EOF'
#!/bin/bash
# Stop Gateway Pi service

echo "Stopping Gateway Pi..."
sudo systemctl stop gateway-pi.service
echo "Service stopped"
EOF
chmod +x $STOP_SCRIPT

# Log viewer script
LOG_SCRIPT="$APP_DIR/view-logs.sh"
sudo tee $LOG_SCRIPT > /dev/null << 'EOF'
#!/bin/bash
# View Gateway Pi logs

echo "=== System Journal ==="
sudo journalctl -u gateway-pi -f -n 50

echo -e "\n=== Application Log ==="
tail -f /home/pi/gateway_data/gateway.log
EOF
chmod +x $LOG_SCRIPT

# MySQL setup helper
MYSQL_SCRIPT="$APP_DIR/setup-mysql-user.sql"
sudo tee $MYSQL_SCRIPT > /dev/null << 'EOF'
-- MySQL User Setup for Gateway Pi
-- Run these commands in MySQL as root or admin

-- 1. Create gateway user (replace 'gateway_pass' with strong password)
CREATE USER 'gateway_user'@'%' IDENTIFIED BY 'gateway_pass';

-- 2. Grant minimal permissions for gateway operations
GRANT INSERT, SELECT ON soilmonitornig.sensor_data TO 'gateway_user'@'%';
GRANT SELECT ON soilmonitornig.sensors TO 'gateway_user'@'%';
GRANT SELECT ON soilmonitornig.farms TO 'gateway_user'@'%';
GRANT SELECT ON soilmonitornig.client TO 'gateway_user'@'%';

-- 3. Optionally restrict to specific IP (recommended)
-- DROP USER 'gateway_user'@'%';
-- CREATE USER 'gateway_user'@'192.168.1.80' IDENTIFIED BY 'gateway_pass';
-- GRANT ... TO 'gateway_user'@'192.168.1.80';

-- 4. Flush privileges
FLUSH PRIVILEGES;

-- 5. Verify permissions
SHOW GRANTS FOR 'gateway_user'@'%';
EOF

print_green "Utility scripts created in $APP_DIR"

# ========================
# FIREWALL CONFIGURATION
# ========================
print_green "Configuring firewall..."
sudo ufw allow 5000/tcp  # Allow Flask app port
sudo ufw allow 22/tcp    # Allow SSH
sudo ufw --force enable 2>/dev/null || true

# ========================
# SET PERMISSIONS
# ========================
print_green "Setting permissions..."
sudo chown -R pi:pi $APP_DIR
sudo chown -R pi:pi $GATEWAY_DATA_DIR
sudo chown -R pi:pi $LOG_DIR
sudo chown -R pi:pi $VENV_PATH

# ========================
# INSTALLATION COMPLETE
# ========================
echo "================================================"
echo -e "${GREEN}✅ ENHANCED GATEWAY PI INSTALLATION COMPLETE!${NC}"
echo "================================================"
echo ""
echo "📋 NEXT STEPS:"
echo "1. Update MySQL user permissions:"
echo "   Run the commands in: $APP_DIR/setup-mysql-user.sql"
echo ""
echo "2. Configure gateway:"
echo "   cp $APP_DIR/config_template.py $APP_DIR/config.py"
echo "   nano $APP_DIR/config.py  # Update IPs and credentials"
echo ""
echo "3. Copy your gateway code to:"
echo "   $APP_DIR/main.py"
echo ""
echo "4. Test the installation:"
echo "   $APP_DIR/start.sh  # Manual start"
echo "   OR"
echo "   sudo systemctl start gateway-pi  # Start service"
echo ""
echo "🔧 SERVICE COMMANDS:"
echo "   sudo systemctl start gateway-pi     # Start now"
echo "   sudo systemctl stop gateway-pi      # Stop service"
echo "   sudo systemctl restart gateway-pi   # Restart service"
echo "   sudo systemctl status gateway-pi    # Check status"
echo "   sudo journalctl -u gateway-pi -f    # View live logs"
echo ""
echo "📊 LOG FILES:"
echo "   $GATEWAY_DATA_DIR/gateway.log      # Application logs"
echo "   $GATEWAY_DATA_DIR/offline_queue.db # Offline data storage"
echo ""
echo "🐍 VIRTUAL ENVIRONMENT:"
echo "   Location: $VENV_PATH"
echo "   Activate: source $VENV_PATH/bin/activate"
echo "   Deactivate: deactivate"
echo ""
echo "🔄 The service will automatically start on boot!"
echo ""
echo "⚠️  IMPORTANT SECURITY NOTES:"
echo "   1. Change MySQL password in config.py"
echo "   2. Consider restricting MySQL user to Gateway Pi IP"
echo "   3. Keep appV7.py running for registration/assignment API"
echo ""
echo "================================================"
echo -e "${YELLOW}⚠️  Don't forget to update config.py with your actual IPs!${NC}"
echo "================================================"
