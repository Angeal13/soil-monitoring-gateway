#!/bin/bash
# Soil Monitoring Gateway - Complete Installation Script
# For Raspberry Pi with gateway username
# GitHub: https://github.com/yourusername/soil-monitoring-gateway

echo "================================================"
echo "Installing Soil Monitoring Gateway"
echo "User: gateway | Purpose: IoT Data Gateway"
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
print_blue "[1/15] Checking user and permissions..."

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
print_blue "[2/15] Updating system packages..."
sudo apt update
sudo apt upgrade -y -qq

# ========================
# INSTALL SYSTEM DEPENDENCIES
# ========================
print_blue "[3/15] Installing system dependencies..."
sudo apt install python3 python3-pip python3-venv python3-dev -y -qq
sudo apt install curl wget git -y -qq
sudo apt install sqlite3 -y -qq  # For offline storage

# ========================
# INSTALL DATABASE SYSTEMS
# ========================
print_blue "[4/15] Installing database systems..."

# Check and install MariaDB/MySQL Server
if ! dpkg -l | grep -q mariadb-server && ! dpkg -l | grep -q mysql-server; then
    print_yellow "Database server not found. Installing MariaDB..."
    sudo apt install mariadb-server mariadb-client -y -qq
    sudo systemctl enable mariadb
    sudo systemctl start mariadb
    print_green "MariaDB server installed and started"
else
    print_green "Database server already installed"
    
    # Ensure service is running
    sudo systemctl start mariadb 2>/dev/null || sudo systemctl start mysql 2>/dev/null
fi

# Install MySQL development libraries for Python connector
sudo apt install libmariadb-dev libmariadb3 -y -qq
print_green "Database libraries installed"

# ========================
# SECURE MYSQL INSTALLATION
# ========================
print_blue "[5/15] Securing MySQL database..."

# Check if MySQL is already secured
if sudo mysql -e "SELECT 1" 2>/dev/null; then
    print_yellow "MySQL root access without password detected."
    print_yellow "Running mysql_secure_installation..."
    
    # Automated mysql_secure_installation
    sudo mysql <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY 'RootPassword123!';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
    
    print_green "MySQL secured with root password: RootPassword123!"
else
    print_green "MySQL already secured"
fi

# ========================
# CREATE APPLICATION STRUCTURE
# ========================
print_blue "[6/15] Creating application structure..."

# Main application directory
APP_DIR="/home/gateway/soil-gateway"
mkdir -p $APP_DIR
chmod 755 $APP_DIR

# Gateway data directory
GATEWAY_DATA_DIR="/home/gateway/soil_gateway_data"
mkdir -p $GATEWAY_DATA_DIR
chmod 755 $GATEWAY_DATA_DIR

# Log directory
LOG_DIR="/home/gateway/soil_gateway_logs"
mkdir -p $LOG_DIR
chmod 755 $LOG_DIR

print_green "Directories created:"
print_green "  📁 $APP_DIR (Application)"
print_green "  💾 $GATEWAY_DATA_DIR (Data storage)"
print_green "  📝 $LOG_DIR (Logs)"

# ========================
# COPY GATEWAY FILES
# ========================
print_blue "[7/15] Copying gateway files..."

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
print_blue "[8/15] Creating Python virtual environment..."

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
print_blue "[9/15] Installing Python packages..."

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
# SETUP MYSQL DATABASE AND USER
# ========================
print_blue "[10/15] Setting up MySQL database..."

DB_NAME="soilmonitornig"
DB_USER="gateway_user"
DB_PASS=$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-12)

print_yellow "Setting up database: $DB_NAME"
print_yellow "Creating user: $DB_USER"

# Create SQL setup file
MYSQL_SETUP_FILE="$APP_DIR/setup_database.sql"
cat > $MYSQL_SETUP_FILE << EOF
-- Soil Monitoring Gateway Database Setup
-- Generated on $(date)

-- Create database
CREATE DATABASE IF NOT EXISTS $DB_NAME 
CHARACTER SET utf8mb4 
COLLATE utf8mb4_unicode_ci;

USE $DB_NAME;

-- Note: Main tables (sensors, sensor_data, farms, client) should be created by appV7.py
-- If you need to create them here, add CREATE TABLE statements

-- Create gateway user
DROP USER IF EXISTS '$DB_USER'@'localhost';
CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';

-- Grant permissions (minimal required)
GRANT INSERT, SELECT ON $DB_NAME.sensor_data TO '$DB_USER'@'localhost';
GRANT SELECT ON $DB_NAME.sensors TO '$DB_USER'@'localhost';
GRANT SELECT ON $DB_NAME.farms TO '$DB_USER'@'localhost';
GRANT SELECT ON $DB_NAME.client TO '$DB_USER'@'localhost';

-- For remote MySQL server, use this instead:
-- CREATE USER '$DB_USER'@'%' IDENTIFIED BY '$DB_PASS';
-- GRANT ... TO '$DB_USER'@'%';

FLUSH PRIVILEGES;

-- Show summary
SELECT '=== DATABASE SETUP COMPLETE ===' AS '';
SELECT CONCAT('Database: ', '$DB_NAME') AS '';
SELECT CONCAT('Username: ', '$DB_USER@localhost') AS '';
SELECT CONCAT('Password: ', '$DB_PASS') AS '';
SELECT 'Update gateway.py with these credentials!' AS '';
EOF

print_green "MySQL setup script created: $MYSQL_SETUP_FILE"

# Execute MySQL setup
print_yellow "Setting up MySQL database..."
if sudo mysql -u root -pRootPassword123! < $MYSQL_SETUP_FILE 2>/dev/null || \
   sudo mysql -u root < $MYSQL_SETUP_FILE 2>/dev/null; then
    print_green "✅ MySQL database setup complete!"
    
    # Save credentials to file
    CRED_FILE="$APP_DIR/mysql_credentials.txt"
    echo "MySQL Credentials:" > $CRED_FILE
    echo "=================" >> $CRED_FILE
    echo "Host: localhost" >> $CRED_FILE
    echo "Database: $DB_NAME" >> $CRED_FILE
    echo "Username: $DB_USER" >> $CRED_FILE
    echo "Password: $DB_PASS" >> $CRED_FILE
    echo "=================" >> $CRED_FILE
    echo "Generated: $(date)" >> $CRED_FILE
    
    chmod 600 $CRED_FILE
    print_green "Credentials saved to: $CRED_FILE"
    
    # Show credentials
    echo ""
    cat $CRED_FILE
    echo ""
    
else
    print_red "Failed to setup MySQL database automatically."
    print_yellow "Manual setup required:"
    print_yellow "  sudo mysql -u root -p < $MYSQL_SETUP_FILE"
    DB_PASS="gateway_pass"  # Fallback to default
fi

# ========================
# UPDATE GATEWAY CONFIGURATION
# ========================
print_blue "[11/15] Updating gateway configuration..."

GATEWAY_FILE="$APP_DIR/gateway.py"
if [ -f "$GATEWAY_FILE" ]; then
    # Backup original
    cp "$GATEWAY_FILE" "$GATEWAY_FILE.backup"
    
    # Update offline storage path
    sed -i "s|/home/[^/]*/gateway_data|$GATEWAY_DATA_DIR|g" "$GATEWAY_FILE"
    
    # Update MySQL configuration for local database
    sed -i "s/'host': '[^']*'/'host': 'localhost'/g" "$GATEWAY_FILE"
    sed -i "s/'user': '[^']*'/'user': '$DB_USER'/g" "$GATEWAY_FILE"
    sed -i "s/'password': '[^']*'/'password': '$DB_PASS'/g" "$GATEWAY_FILE"
    sed -i "s/'database': '[^']*'/'database': '$DB_NAME'/g" "$GATEWAY_FILE"
    
    print_green "Gateway configuration updated:"
    echo ""
    grep -A1 "'host':" "$GATEWAY_FILE"
    grep -A1 "'user':" "$GATEWAY_FILE"
    grep -A1 "'database':" "$GATEWAY_FILE"
    echo ""
    
else
    print_red "Error: gateway.py not found!"
    exit 1
fi

# ========================
# CREATE CONFIGURATION FILE
# ========================
print_blue "[12/15] Creating configuration file..."

CONFIG_FILE="$APP_DIR/gateway_config.env"
cat > $CONFIG_FILE << EOF
# Soil Monitoring Gateway Configuration
# Auto-generated on $(date)

# Database Configuration
MYSQL_HOST=localhost
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

# Offline Storage
OFFLINE_DB=$GATEWAY_DATA_DIR/offline_queue.db
MAX_OFFLINE_RECORDS=10000
EOF

chmod 600 $CONFIG_FILE
print_green "Configuration file created: $CONFIG_FILE"

# ========================
# SETUP AUTO-START SERVICE
# ========================
print_blue "[13/15] Setting up auto-start service..."

SERVICE_FILE="/etc/systemd/system/soil-gateway.service"
sudo tee $SERVICE_FILE > /dev/null << EOF
[Unit]
Description=Soil Monitoring Gateway Service
After=network.target mariadb.service mysql.service
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
print_blue "[14/15] Setting up log rotation..."

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
print_blue "[15/15] Creating utility scripts..."

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
else
    echo "❌ API not responding"
fi

echo ""
echo "=== Test Complete ==="
EOF
chmod +x $TEST_SCRIPT

# Setup database test
DB_TEST_SCRIPT="$APP_DIR/test-database.sh"
cat > $DB_TEST_SCRIPT << EOF
#!/bin/bash
echo "=== Database Connection Test ==="
echo ""

echo "1. SQLite (Offline Storage):"
if [ -f "$GATEWAY_DATA_DIR/offline_queue.db" ]; then
    echo "✅ Offline database exists"
    sqlite3 "$GATEWAY_DATA_DIR/offline_queue.db" ".tables" 2>/dev/null && echo "✅ Tables accessible" || echo "❌ Cannot access tables"
else
    echo "⚠️  Offline database not created yet"
fi

echo ""
echo "2. MySQL Connection:"
if mysql -u $DB_USER -p$DB_PASS -h localhost -e "USE $DB_NAME; SELECT '✅ MySQL connection successful' AS status;" 2>/dev/null; then
    echo "✅ MySQL connection successful"
    echo "   Database: $DB_NAME"
    echo "   User: $DB_USER"
    
    # Check tables
    TABLES=\$(mysql -u $DB_USER -p$DB_PASS -h localhost -D $DB_NAME -e "SHOW TABLES;" 2>/dev/null)
    if [ ! -z "\$TABLES" ]; then
        echo "✅ Tables found in database"
    else
        echo "⚠️  No tables found (they may be created by appV7.py)"
    fi
else
    echo "❌ MySQL connection failed"
    echo "   Check credentials in: $APP_DIR/mysql_credentials.txt"
fi
EOF
chmod +x $DB_TEST_SCRIPT

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
echo "   💾 Data Storage:   $GATEWAY_DATA_DIR/"
echo "   📝 Logs:           $LOG_DIR/"
echo "   🐍 Virtual Env:    $VENV_PATH/"
echo "   🗄️  Database:       $DB_NAME (MySQL)"
echo "   👤 DB User:        $DB_USER"
echo ""
echo "🔧 SERVICE STATUS:"
sudo systemctl status soil-gateway --no-pager --lines=3
echo ""
echo "🚀 QUICK START:"
echo "   Test gateway:     $APP_DIR/test-gateway.sh"
echo "   Test databases:   $APP_DIR/test-database.sh"
echo "   Manage gateway:   $APP_DIR/manage-gateway.sh [command]"
echo ""
echo "🌐 TEST ENDPOINTS:"
echo "   curl http://localhost:5000/api/test"
echo "   curl http://localhost:5000/api/health"
echo ""
echo "📡 GATEWAY URL:"
echo "   http://$(hostname -I | awk '{print $1}'):5000"
echo ""
echo "🔐 DATABASE CREDENTIALS:"
echo "   Saved to: $APP_DIR/mysql_credentials.txt"
echo "   🔒 Keep this file secure!"
echo ""
echo "🔄 AUTO-START:"
echo "   Service enabled - Gateway starts automatically on boot"
echo ""
echo "❓ TROUBLESHOOTING:"
echo "   View logs:        sudo journalctl -u soil-gateway -f"
echo "   Restart service:  sudo systemctl restart soil-gateway"
echo "   Check status:     sudo systemctl status soil-gateway"
echo ""
echo "================================================"
print_yellow "⚠️  IMPORTANT: Update API_URL in gateway.py if needed!"
print_yellow "⚠️  Change MySQL root password from 'RootPassword123!'"
echo "================================================"
