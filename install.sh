#!/bin/bash
# Soil Monitoring Gateway - Complete Installation Script
# For Raspberry Pi with gateway username
# MySQL connection to 192.168.1.100 (Database Pi)
# GitHub: https://github.com/yourusername/soil-monitoring-gateway

echo "================================================"
echo "Installing Soil Monitoring Gateway"
echo "User: gateway | MySQL Host: 192.168.1.100"
echo "================================================"

# ========================
# COLOR OUTPUT
# ========================
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
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

print_blue() {
    echo -e "${BLUE}[i] $1${NC}"
}

# ========================
# CHECK USER AND PERMISSIONS
# ========================
print_blue "[1/14] Checking user and permissions..."

if [[ "$USER" != "gateway" ]]; then
    print_yellow "Warning: Script is running as user: $USER"
    print_yellow "This installation is designed for 'gateway' user."
    
    if [[ "$USER" == "root" ]]; then
        print_yellow "Running as root. Will create 'gateway' user."
    else
        print_red "Please run as 'gateway' user or as root."
        print_yellow "To switch to gateway user: sudo su - gateway"
        print_yellow "Or run as root to create gateway user automatically."
        exit 1
    fi
fi

# ========================
# CREATE GATEWAY USER IF NEEDED
# ========================
if [[ "$USER" == "root" ]] || [[ "$USER" != "gateway" ]]; then
    print_blue "Checking/Creating gateway user..."
    
    if id "gateway" &>/dev/null; then
        print_green "User 'gateway' already exists"
    else
        print_yellow "Creating 'gateway' user..."
        useradd -m -s /bin/bash -G sudo,dialout,users gateway
        echo "gateway:gateway123" | chpasswd  # Change this password!
        print_green "User 'gateway' created (password: gateway123 - CHANGE THIS!)"
    fi
    
    # Continue installation as gateway user
    exec sudo -u gateway bash -c "cd '$PWD'; '$0'"
    exit 0
fi

# ========================
# SYSTEM UPDATE
# ========================
print_blue "[2/14] Updating system packages..."
sudo apt update
sudo apt upgrade -y -qq

# ========================
# INSTALL SYSTEM DEPENDENCIES
# ========================
print_blue "[3/14] Installing system dependencies..."
sudo apt install python3 python3-pip python3-venv python3-dev -y -qq
sudo apt install curl wget git -y -qq
sudo apt install sqlite3 -y -qq  # For offline storage

# ========================
# INSTALL DATABASE CLIENT LIBRARIES
# ========================
print_blue "[4/14] Installing database libraries..."

# Only install MySQL client libraries (NOT server)
sudo apt install libmariadb-dev libmariadb3 mariadb-client -y -qq
print_green "MySQL client libraries installed"
print_yellow "NOTE: MySQL server is at 192.168.1.100 (Database Pi)"

# ========================
# CREATE APPLICATION STRUCTURE
# ========================
print_blue "[5/14] Creating application structure..."

# Main application directory
APP_DIR="/home/gateway/soil-gateway"
mkdir -p $APP_DIR
chmod 755 $APP_DIR

# Gateway data directory (for SQLite offline storage)
GATEWAY_DATA_DIR="/home/gateway/soil_gateway_data"
mkdir -p $GATEWAY_DATA_DIR
chmod 755 $GATEWAY_DATA_DIR

# Log directory
LOG_DIR="/home/gateway/soil_gateway_logs"
mkdir -p $LOG_DIR
chmod 755 $LOG_DIR

print_green "Directories created:"
print_green "  📁 $APP_DIR (Application)"
print_green "  💾 $GATEWAY_DATA_DIR (SQLite offline storage)"
print_green "  📝 $LOG_DIR (Logs)"

# ========================
# COPY GATEWAY FILES
# ========================
print_blue "[6/14] Copying gateway files..."

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [ -f "$SCRIPT_DIR/gateway.py" ]; then
    print_green "Found gateway.py, copying files..."
    
    # Copy main application
    cp -f "$SCRIPT_DIR/gateway.py" $APP_DIR/
    chmod +x $APP_DIR/gateway.py
    
    # Copy all Python files except install.sh
    for pyfile in "$SCRIPT_DIR"/*.py; do
        if [ -f "$pyfile" ] && [ "$(basename "$pyfile")" != "install.sh" ]; then
            cp -f "$pyfile" $APP_DIR/
            print_green "  Copied: $(basename "$pyfile")"
        fi
    done
    
    # Copy support files if they exist
    [ -f "$SCRIPT_DIR/requirements.txt" ] && cp -f "$SCRIPT_DIR/requirements.txt" $APP_DIR/
    [ -f "$SCRIPT_DIR/README.md" ] && cp -f "$SCRIPT_DIR/README.md" $APP_DIR/
    [ -f "$SCRIPT_DIR/.gitignore" ] && cp -f "$SCRIPT_DIR/.gitignore" $APP_DIR/
    
else
    print_red "Error: gateway.py not found!"
    print_yellow "Run this script from the soil-monitoring-gateway directory"
    exit 1
fi

# ========================
# CREATE PYTHON VIRTUAL ENVIRONMENT
# ========================
print_blue "[7/14] Creating Python virtual environment..."

VENV_PATH="/home/gateway/soil-gateway-venv"
if [ -d "$VENV_PATH" ]; then
    print_yellow "Virtual environment already exists"
    read -p "Recreate it? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf $VENV_PATH
        python3 -m venv $VENV_PATH
        print_green "Virtual environment recreated"
    else
        print_yellow "Using existing virtual environment"
    fi
else
    python3 -m venv $VENV_PATH
    print_green "Virtual environment created"
fi

# ========================
# INSTALL PYTHON PACKAGES
# ========================
print_blue "[8/14] Installing Python packages..."

source $VENV_PATH/bin/activate
pip install --upgrade pip

if [ -f "$APP_DIR/requirements.txt" ]; then
    print_green "Installing from requirements.txt..."
    pip install -r $APP_DIR/requirements.txt
else
    print_yellow "No requirements.txt, installing core packages..."
    pip install flask==2.3.3
    pip install requests==2.31.0
    pip install mysql-connector-python==8.1.0
    pip install python-dotenv==1.0.0
    
    # Create requirements.txt
    pip freeze > $APP_DIR/requirements.txt
    print_green "Created requirements.txt"
fi

deactivate
print_green "Python packages installed"

# ========================
# SETUP DATABASE CREDENTIALS
# ========================
print_blue "[9/14] Setting up database credentials..."

DB_NAME="soilmonitornig"
DB_USER="gateway_user"
DB_PASS="gateway_pass"  # Default - user should change this

print_yellow "Database Configuration:"
print_yellow "  Host: 192.168.1.100 (Database Pi)"
print_yellow "  Database: $DB_NAME"
print_yellow "  Username: $DB_USER"
print_yellow "  Password: $DB_PASS"
echo ""
print_yellow "⚠️  IMPORTANT: Ensure these credentials are correct on Database Pi!"
print_yellow "   Run on Database Pi (192.168.1.100):"
print_yellow "   CREATE USER '$DB_USER'@'%' IDENTIFIED BY '$DB_PASS';"
print_yellow "   GRANT INSERT,SELECT ON $DB_NAME.* TO '$DB_USER'@'%';"

# Create credentials file
CRED_FILE="$APP_DIR/mysql_credentials.txt"
cat > $CRED_FILE << EOF
MySQL Credentials for Database Pi (192.168.1.100)
=================================================
Host: 192.168.1.100
Database: $DB_NAME
Username: $DB_USER
Password: $DB_PASS
=================================================
IMPORTANT:
1. These must match the user/password on Database Pi
2. Update gateway.py if credentials are different
3. Test connection: mysql -h 192.168.1.100 -u $DB_USER -p$DB_PASS $DB_NAME
EOF

chmod 600 $CRED_FILE
print_green "Credentials file created: $CRED_FILE"

# ========================
# UPDATE GATEWAY CONFIGURATION
# ========================
print_blue "[10/14] Updating gateway configuration..."

GATEWAY_FILE="$APP_DIR/gateway.py"
if [ -f "$GATEWAY_FILE" ]; then
    # Backup original
    cp "$GATEWAY_FILE" "$GATEWAY_FILE.backup"
    
    # Update ONLY offline storage path (preserve 192.168.1.100 host)
    sed -i "s|/home/[^/]*/gateway_data|$GATEWAY_DATA_DIR|g" "$GATEWAY_FILE"
    
    print_green "Gateway configuration updated:"
    echo ""
    print_yellow "Current MySQL configuration:"
    grep -A1 "'host':" "$GATEWAY_FILE"
    grep -A1 "'user':" "$GATEWAY_FILE"
    grep -A1 "'database':" "$GATEWAY_FILE"
    echo ""
    
    # Verify host is 192.168.1.100
    if grep -q "'host': '192.168.1.100'" "$GATEWAY_FILE"; then
        print_green "✅ MySQL host correctly set to 192.168.1.100"
    else
        print_red "❌ MySQL host is NOT 192.168.1.100!"
        print_yellow "Please edit gateway.py and set host to '192.168.1.100'"
    fi
    
else
    print_red "Error: gateway.py not found!"
    exit 1
fi

# ========================
# CREATE CONFIGURATION FILE
# ========================
print_blue "[11/14] Creating configuration file..."

CONFIG_FILE="$APP_DIR/gateway_config.env"
cat > $CONFIG_FILE << EOF
# Soil Monitoring Gateway Configuration
# Auto-generated on $(date)

# Database Configuration (Database Pi at 192.168.1.100)
MYSQL_HOST=192.168.1.100
MYSQL_DATABASE=$DB_NAME
MYSQL_USER=$DB_USER
MYSQL_PASSWORD=$DB_PASS

# Application Paths
APP_DIR=$APP_DIR
DATA_DIR=$GATEWAY_DATA_DIR
LOG_DIR=$LOG_DIR
VENV_PATH=$VENV_PATH

# Gateway Settings
GATEWAY_HOST=0.0.0.0
GATEWAY_PORT=5000
API_URL=http://192.168.1.95:5000

# Offline Storage (SQLite on Gateway Pi)
OFFLINE_DB=$GATEWAY_DATA_DIR/offline_queue.db
MAX_OFFLINE_RECORDS=10000
EOF

chmod 600 $CONFIG_FILE
print_green "Configuration file created: $CONFIG_FILE"

# ========================
# SETUP AUTO-START SERVICE
# ========================
print_blue "[12/14] Setting up auto-start service..."

SERVICE_FILE="/etc/systemd/system/soil-gateway.service"
sudo tee $SERVICE_FILE > /dev/null << EOF
[Unit]
Description=Soil Monitoring Gateway Service
After=network.target
Wants=network.target
StartLimitIntervalSec=500
StartLimitBurst=5

[Service]
Type=simple
User=gateway
Group=gateway
WorkingDirectory=$APP_DIR

# Run gateway.py with virtual environment
ExecStart=$VENV_PATH/bin/python $APP_DIR/gateway.py

Restart=always
RestartSec=10
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=soil-gateway

# Environment
Environment="PATH=$VENV_PATH/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="PYTHONPATH=$APP_DIR"

# Security
NoNewPrivileges=true
ProtectSystem=strict
PrivateTmp=true
ReadWritePaths=$GATEWAY_DATA_DIR $LOG_DIR
ProtectHome=read-only

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable soil-gateway.service
print_green "Systemd service created and enabled"

# ========================
# SETUP LOG ROTATION
# ========================
print_blue "[13/14] Setting up log rotation..."

LOGROTATE_FILE="/etc/logrotate.d/soil-gateway"
sudo tee $LOGROTATE_FILE > /dev/null << EOF
$GATEWAY_DATA_DIR/*.log $LOG_DIR/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 644 gateway gateway
    sharedscripts
    postrotate
        systemctl kill -s HUP soil-gateway.service 2>/dev/null || true
    endscript
}
EOF

print_green "Log rotation configured (14 days retention)"

# ========================
# CREATE UTILITY SCRIPTS
# ========================
print_blue "[14/14] Creating utility scripts..."

# Main management script
MANAGE_SCRIPT="$APP_DIR/manage-gateway.sh"
cat > $MANAGE_SCRIPT << 'EOF'
#!/bin/bash
# Soil Monitoring Gateway Management

SCRIPT_NAME=$(basename "$0")
GATEWAY_SERVICE="soil-gateway"

show_help() {
    echo "Soil Monitoring Gateway Management Script"
    echo "Usage: $SCRIPT_NAME [command]"
    echo ""
    echo "Commands:"
    echo "  start       - Start gateway service"
    echo "  stop        - Stop gateway service"
    echo "  restart     - Restart gateway service"
    echo "  status      - Show service status"
    echo "  logs        - View service logs (follow)"
    echo "  logs-tail   - View last 50 log lines"
    echo "  config      - Edit gateway configuration"
    echo "  test        - Test gateway connectivity"
    echo "  health      - Check gateway health"
    echo "  db-test     - Test MySQL connection to 192.168.1.100"
    echo "  backup      - Backup gateway data"
    echo "  update      - Update from repository"
    echo "  help        - Show this help"
}

case "$1" in
    start)
        echo "Starting Soil Gateway..."
        sudo systemctl start $GATEWAY_SERVICE
        sleep 2
        sudo systemctl status $GATEWAY_SERVICE --no-pager --lines=3
        ;;
    stop)
        echo "Stopping Soil Gateway..."
        sudo systemctl stop $GATEWAY_SERVICE
        echo "Service stopped"
        ;;
    restart)
        echo "Restarting Soil Gateway..."
        sudo systemctl restart $GATEWAY_SERVICE
        sleep 2
        sudo systemctl status $GATEWAY_SERVICE --no-pager --lines=3
        ;;
    status)
        sudo systemctl status $GATEWAY_SERVICE --no-pager
        ;;
    logs)
        echo "Showing gateway logs (Ctrl+C to exit)..."
        sudo journalctl -u $GATEWAY_SERVICE -f
        ;;
    logs-tail)
        echo "Last 50 log entries:"
        sudo journalctl -u $GATEWAY_SERVICE -n 50 --no-pager
        ;;
    config)
        echo "Editing gateway configuration..."
        nano /home/gateway/soil-gateway/gateway.py
        ;;
    test)
        echo "Testing gateway connectivity..."
        curl -s http://localhost:5000/api/test || echo "Gateway not responding"
        ;;
    health)
        echo "Checking gateway health..."
        curl -s http://localhost:5000/api/health | python3 -m json.tool 2>/dev/null || echo "Health check failed"
        ;;
    db-test)
        echo "Testing MySQL connection to 192.168.1.100..."
        # Extract credentials from gateway.py
        DB_HOST=$(grep -A1 "'host':" /home/gateway/soil-gateway/gateway.py | tail -1 | grep -o "'.*'" | tr -d "'")
        DB_USER=$(grep -A1 "'user':" /home/gateway/soil-gateway/gateway.py | tail -1 | grep -o "'.*'" | tr -d "'")
        DB_PASS=$(grep -A1 "'password':" /home/gateway/soil-gateway/gateway.py | tail -1 | grep -o "'.*'" | tr -d "'")
        DB_NAME=$(grep -A1 "'database':" /home/gateway/soil-gateway/gateway.py | tail -1 | grep -o "'.*'" | tr -d "'")
        
        echo "Testing connection to: $DB_HOST"
        if mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -e "USE $DB_NAME; SELECT '✅ Connection successful' AS status;" 2>/dev/null; then
            echo "✅ MySQL connection successful to $DB_HOST"
        else
            echo "❌ MySQL connection failed to $DB_HOST"
            echo "Check credentials in: /home/gateway/soil-gateway/gateway.py"
        fi
        ;;
    backup)
        echo "Backing up gateway data..."
        BACKUP_FILE="/home/gateway/soil_gateway_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
        tar -czf "$BACKUP_FILE" -C /home/gateway soil_gateway_data
        echo "Backup created: $BACKUP_FILE"
        ls -lh "$BACKUP_FILE"
        ;;
    update)
        echo "Updating gateway from repository..."
        cd /home/gateway/soil-gateway
        git pull
        sudo systemctl restart $GATEWAY_SERVICE
        echo "Update complete"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Unknown command: $1"
        show_help
        exit 1
        ;;
esac
EOF
chmod +x $MANAGE_SCRIPT

# Quick test script
TEST_SCRIPT="$APP_DIR/test-gateway.sh"
cat > $TEST_SCRIPT << 'EOF'
#!/bin/bash
echo "=== Gateway Quick Test ==="
echo ""

echo "1. Service Status:"
sudo systemctl is-active soil-gateway >/dev/null && echo "✅ Service is running" || echo "❌ Service not running"

echo ""
echo "2. Process Check:"
pgrep -f "gateway.py" >/dev/null && echo "✅ Gateway process found" || echo "❌ No gateway process"

echo ""
echo "3. Port Check:"
sudo lsof -i :5000 >/dev/null && echo "✅ Port 5000 in use" || echo "❌ Port 5000 not in use"

echo ""
echo "4. Quick API Test:"
if curl -s --max-time 5 http://localhost:5000/api/test >/dev/null; then
    echo "✅ API responding"
    RESPONSE=$(curl -s http://localhost:5000/api/test)
    echo "   Gateway: $(echo $RESPONSE | grep -o '"gateway":"[^"]*"' | cut -d'"' -f4)"
    echo "   MySQL: $(echo $RESPONSE | grep -o '"mysql":"[^"]*"' | cut -d'"' -f4)"
    echo "   MySQL Host: $(echo $RESPONSE | grep -o '"host":"[^"]*"' | cut -d'"' -f4)"
else
    echo "❌ API not responding"
fi

echo ""
echo "=== Test Complete ==="
EOF
chmod +x $TEST_SCRIPT

print_green "Utility scripts created"

# ========================
# START SERVICE AND TEST
# ========================
print_blue "Starting gateway service..."
sudo systemctl start soil-gateway
sleep 3

print_blue "Testing installation..."

echo ""
echo "================================================"
print_green "✅ SOIL MONITORING GATEWAY INSTALLATION COMPLETE!"
echo "================================================"
echo ""
echo "📋 INSTALLATION SUMMARY:"
echo "   👤 User:           gateway"
echo "   📍 Application:    $APP_DIR/"
echo "   💾 Data Storage:   $GATEWAY_DATA_DIR/ (SQLite offline)"
echo "   📝 Logs:           $LOG_DIR/"
echo "   🐍 Virtual Env:    $VENV_PATH/"
echo "   🗄️  Database Host:  192.168.1.100 (Database Pi)"
echo "   📊 Database:       soilmonitornig"
echo "   👤 DB User:        gateway_user"
echo ""
echo "🔧 SERVICE STATUS:"
sudo systemctl status soil-gateway --no-pager --lines=3
echo ""
echo "🚀 QUICK START:"
echo "   Test gateway:     $APP_DIR/test-gateway.sh"
echo "   Test DB conn:     $APP_DIR/manage-gateway.sh db-test"
echo "   Manage gateway:   $APP_DIR/manage-gateway.sh [command]"
echo ""
echo "🌐 TEST ENDPOINTS:"
echo "   curl http://localhost:5000/api/test"
echo "   curl http://localhost:5000/api/health"
echo ""
echo "📡 GATEWAY URL:"
echo "   http://$(hostname -I | awk '{print $1}'):5000"
echo ""
echo "🔐 DATABASE SETUP REQUIRED ON 192.168.1.100:"
echo "   Run on Database Pi:"
echo "   CREATE USER 'gateway_user'@'%' IDENTIFIED BY 'gateway_pass';"
echo "   GRANT INSERT,SELECT ON soilmonitornig.* TO 'gateway_user'@'%';"
echo "   FLUSH PRIVILEGES;"
echo ""
echo "❓ TROUBLESHOOTING:"
echo "   View logs:        sudo journalctl -u soil-gateway -f"
echo "   Test DB:          $APP_DIR/manage-gateway.sh db-test"
echo "   Edit config:      nano $APP_DIR/gateway.py"
echo ""
echo "================================================"
print_yellow "⚠️  IMPORTANT: Configure user on Database Pi (192.168.1.100)!"
print_yellow "⚠️  Update gateway.py if MySQL credentials are different"
echo "================================================"
