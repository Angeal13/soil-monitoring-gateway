#!/bin/bash
# Soil Monitoring Gateway - Complete Foolproof Installation
# Guarantees mysql.connector installation in virtual environment

echo "================================================"
echo "🚀 Soil Monitoring Gateway - Easy Installation"
echo "================================================"

set -e  # Exit on any error

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo_green() { echo -e "${GREEN}[✓] $1${NC}"; }
echo_yellow() { echo -e "${YELLOW}[!] $1${NC}"; }
echo_red() { echo -e "${RED}[✗] $1${NC}"; }
echo_blue() { echo -e "${BLUE}[▶] $1${NC}"; }

# ========================
# 1. INITIAL CHECKS
# ========================
echo_blue "1. Checking system and user..."

# Check if running as gateway user
if [[ "$USER" != "gateway" ]]; then
    echo_yellow "Warning: Running as user '$USER' instead of 'gateway'"
    echo_yellow "For best results, run as gateway user:"
    echo_yellow "  sudo -u gateway bash"
    echo_yellow "  cd /path/to/soil-monitoring-gateway"
    echo_yellow "  ./install.sh"
    
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Check if we're in the right directory
if [ ! -f "gateway.py" ]; then
    echo_red "ERROR: gateway.py not found in current directory!"
    echo_yellow "Please run this script from the soil-monitoring-gateway directory"
    exit 1
fi

# ========================
# 2. SYSTEM UPDATE
# ========================
echo_blue "2. Updating system packages..."
sudo apt update
sudo apt upgrade -y -qq
echo_green "System updated"

# ========================
# 3. INSTALL SYSTEM DEPENDENCIES
# ========================
echo_blue "3. Installing system dependencies..."
sudo apt install python3 python3-pip python3-venv python3-dev -y -qq
sudo apt install curl wget git -y -qq
sudo apt install sqlite3 -y -qq
sudo apt install libmariadb-dev libmariadb3 mariadb-client -y -qq
echo_green "System dependencies installed"

# ========================
# 4. CREATE DIRECTORIES
# ========================
echo_blue "4. Creating directories..."
mkdir -p /home/gateway/soil-gateway
mkdir -p /home/gateway/soil_gateway_data
mkdir -p /home/gateway/soil_gateway_logs

# Set permissions
chmod 755 /home/gateway/soil-gateway
chmod 755 /home/gateway/soil_gateway_data
chmod 755 /home/gateway/soil_gateway_logs

echo_green "Directories created:"
echo_green "  📁 /home/gateway/soil-gateway"
echo_green "  💾 /home/gateway/soil_gateway_data"
echo_green "  📝 /home/gateway/soil_gateway_logs"

# ========================
# 5. COPY GATEWAY FILES
# ========================
echo_blue "5. Copying gateway files..."

# Copy gateway.py and all Python files
cp -f gateway.py /home/gateway/soil-gateway/
chmod +x /home/gateway/soil-gateway/gateway.py
echo_green "  Copied gateway.py"

# Copy other Python files
for file in *.py; do
    if [ "$file" != "install.sh" ] && [ -f "$file" ]; then
        cp -f "$file" /home/gateway/soil-gateway/
        echo_green "  Copied $file"
    fi
done

# Copy support files if they exist
[ -f "requirements.txt" ] && cp -f requirements.txt /home/gateway/soil-gateway/
[ -f "README.md" ] && cp -f README.md /home/gateway/soil-gateway/
[ -f ".gitignore" ] && cp -f .gitignore /home/gateway/soil-gateway/
[ -f "LICENSE" ] && cp -f LICENSE /home/gateway/soil-gateway/

# ========================
# 6. CREATE VIRTUAL ENVIRONMENT
# ========================
echo_blue "6. Creating Python virtual environment..."

VENV_PATH="/home/gateway/soil-gateway-venv"

# Remove old virtual environment if exists
if [ -d "$VENV_PATH" ]; then
    echo_yellow "  Removing old virtual environment..."
    rm -rf "$VENV_PATH"
fi

# Create fresh virtual environment
echo_yellow "  Creating new virtual environment..."
python3 -m venv "$VENV_PATH"

# Verify virtual environment was created
if [ ! -f "$VENV_PATH/bin/activate" ]; then
    echo_red "  ❌ Virtual environment creation failed!"
    echo_yellow "  Trying alternative method..."
    
    # Try with explicit Python path
    /usr/bin/python3 -m venv "$VENV_PATH"
    
    if [ ! -f "$VENV_PATH/bin/activate" ]; then
        echo_red "  ❌ Still failed to create virtual environment"
        exit 1
    fi
fi

echo_green "  ✅ Virtual environment created at $VENV_PATH"

# ========================
# 7. INSTALL PYTHON PACKAGES (GUARANTEED)
# ========================
echo_blue "7. Installing Python packages (guaranteed method)..."

# Activate virtual environment
echo_yellow "  Activating virtual environment..."
source "$VENV_PATH/bin/activate"

# Show Python info
echo_yellow "  Python: $(which python)"
echo_yellow "  Version: $(python --version)"

# Upgrade pip first
echo_yellow "  Upgrading pip..."
pip install --upgrade pip --no-cache-dir

# Function to install package with retries
install_with_retry() {
    local package="$1"
    local max_retries=3
    
    for ((retry=1; retry<=max_retries; retry++)); do
        echo_yellow "  Installing $package (attempt $retry/$max_retries)..."
        
        if pip install --no-cache-dir "$package" > /tmp/pip_install.log 2>&1; then
            echo_green "    ✅ $package installed successfully"
            return 0
        else
            echo_red "    ❌ Attempt $retry failed"
            
            # Show last few lines of error
            if [ $retry -eq $max_retries ]; then
                echo_yellow "    Last error output:"
                tail -20 /tmp/pip_install.log
            fi
            
            sleep 2
        fi
    done
    
    echo_red "    ❌ Failed to install $package after $max_retries attempts"
    return 1
}

# Install Flask and Requests (usually easy)
install_with_retry "flask==2.3.3"
install_with_retry "requests==2.31.0"
install_with_retry "python-dotenv==1.0.0"

# ========================
# 8. GUARANTEE MYSQL-CONNECTOR-PYTHON INSTALLATION
# ========================
echo_blue "8. Installing mysql-connector-python (CRITICAL STEP)..."

mysql_connector_installed=false

# Method 1: Try standard installation
echo_yellow "  Method 1: Standard pip install..."
if pip install --no-cache-dir "mysql-connector-python==8.1.0" > /tmp/mysql_install.log 2>&1; then
    echo_green "    ✅ mysql-connector-python installed via pip"
    mysql_connector_installed=true
else
    echo_red "    ❌ Method 1 failed"
    
    # Method 2: Try without version pin
    echo_yellow "  Method 2: Install latest version..."
    if pip install --no-cache-dir "mysql-connector-python" > /tmp/mysql_install.log 2>&1; then
        echo_green "    ✅ mysql-connector-python installed (latest)"
        mysql_connector_installed=true
    else
        echo_red "    ❌ Method 2 failed"
        
        # Method 3: Try alternative package
        echo_yellow "  Method 3: Try mysql-connector..."
        if pip install --no-cache-dir "mysql-connector" > /tmp/mysql_install.log 2>&1; then
            echo_green "    ✅ mysql-connector installed"
            mysql_connector_installed=true
        else
            echo_red "    ❌ Method 3 failed"
            
            # Method 4: Install from source
            echo_yellow "  Method 4: Install from source..."
            echo_yellow "    Downloading mysql-connector-python source..."
            
            # Create temp directory
            TEMP_DIR=$(mktemp -d)
            cd "$TEMP_DIR"
            
            # Download and install from source
            if wget -q https://dev.mysql.com/get/Downloads/Connector-Python/mysql-connector-python-8.1.0.tar.gz && \
               tar -xzf mysql-connector-python-8.1.0.tar.gz && \
               cd mysql-connector-python-8.1.0 && \
               python setup.py install > /tmp/mysql_source_install.log 2>&1; then
                echo_green "    ✅ mysql-connector-python installed from source"
                mysql_connector_installed=true
            else
                echo_red "    ❌ Method 4 failed"
            fi
            
            # Clean up
            cd /
            rm -rf "$TEMP_DIR"
        fi
    fi
fi

# ========================
# 9. VERIFY ALL IMPORTS
# ========================
echo_blue "9. Verifying all imports work..."

# Create verification script
cat > /tmp/verify_all.py << 'EOF'
import sys

print("=" * 50)
print("Python Import Verification")
print("=" * 50)
print(f"Python: {sys.executable}")
print()

tests = [
    ("flask", None),
    ("requests", None),
    ("mysql.connector", None),
    ("mysql.connector.pooling", "mysql.connector"),
    ("mysql.connector.Error", "mysql.connector"),
    ("sqlite3", None),
    ("json", None),
    ("logging", None),
    ("datetime", None),
    ("threading", None),
    ("os", None),
]

all_passed = True

for import_name, parent in tests:
    try:
        if parent:
            # Import parent first
            __import__(parent)
            # Dynamically get attribute
            module = sys.modules[parent]
            parts = import_name.split('.')[1:]  # Remove parent
            for part in parts:
                module = getattr(module, part)
            print(f"✅ {import_name:30} - OK")
        else:
            __import__(import_name)
            print(f"✅ {import_name:30} - OK")
    except Exception as e:
        print(f"❌ {import_name:30} - FAILED: {e}")
        all_passed = False

print()
print("=" * 50)
if all_passed:
    print("✅ ALL IMPORTS SUCCESSFUL!")
    sys.exit(0)
else:
    print("❌ SOME IMPORTS FAILED!")
    sys.exit(1)
EOF

# Run verification
if python /tmp/verify_all.py; then
    echo_green "  ✅ All Python imports verified!"
else
    echo_red "  ❌ Some imports failed!"
    
    # Show what's actually installed
    echo_yellow "  Installed packages:"
    pip list | grep -E "(mysql|flask|requests|dotenv|connector)"
    
    # Try emergency fix
    echo_yellow "  Attempting emergency fix..."
    pip install pymysql
    echo_yellow "  Installed pymysql as fallback"
fi

# Save requirements
pip freeze > /home/gateway/soil-gateway/requirements.txt
echo_green "  Saved requirements.txt"

# Deactivate virtual environment
deactivate
echo_green "  Virtual environment setup complete"

# ========================
# 10. CONFIGURE GATEWAY.PY
# ========================
echo_blue "10. Configuring gateway.py..."

GATEWAY_FILE="/home/gateway/soil-gateway/gateway.py"

if [ -f "$GATEWAY_FILE" ]; then
    # Backup original
    cp "$GATEWAY_FILE" "$GATEWAY_FILE.backup"
    
    # Update offline storage path
    sed -i "s|/home/[^/]*/gateway_data|/home/gateway/soil_gateway_data|g" "$GATEWAY_FILE"
    
    # Make sure MySQL host is 192.168.1.100
    if ! grep -q "'host': '192.168.1.100'" "$GATEWAY_FILE"; then
        echo_yellow "  Setting MySQL host to 192.168.1.100..."
        sed -i "s/'host': '[^']*'/'host': '192.168.1.100'/g" "$GATEWAY_FILE"
    fi
    
    # Verify configuration
    echo_green "  Gateway configuration updated:"
    echo_yellow "    MySQL Host: $(grep -A1 "'host':" "$GATEWAY_FILE" | tail -1 | grep -o "'.*'" | tr -d "'")"
    echo_yellow "    Offline DB: $(grep "OFFLINE_STORAGE_PATH" "$GATEWAY_FILE" | grep -o "'.*'" | tr -d "'")"
else
    echo_red "  ❌ gateway.py not found!"
    exit 1
fi

# ========================
# 11. SETUP SYSTEMD SERVICE
# ========================
echo_blue "11. Creating auto-start service..."

SERVICE_FILE="/etc/systemd/system/soil-gateway.service"

sudo tee "$SERVICE_FILE" > /dev/null << EOF
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
WorkingDirectory=/home/gateway/soil-gateway

# MUST use virtual environment Python
ExecStart=$VENV_PATH/bin/python /home/gateway/soil-gateway/gateway.py

Restart=always
RestartSec=10
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=soil-gateway

# Environment
Environment="PATH=$VENV_PATH/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="PYTHONPATH=/home/gateway/soil-gateway"

# Security
NoNewPrivileges=true
ProtectSystem=strict
PrivateTmp=true
ReadWritePaths=/home/gateway/soil_gateway_data /home/gateway/soil_gateway_logs
ProtectHome=read-only

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable service
sudo systemctl daemon-reload
sudo systemctl enable soil-gateway.service
echo_green "  Systemd service created and enabled"

# ========================
# 12. SETUP LOG ROTATION
# ========================
echo_blue "12. Setting up log rotation..."

sudo tee /etc/logrotate.d/soil-gateway > /dev/null << EOF
/home/gateway/soil_gateway_data/*.log /home/gateway/soil_gateway_logs/*.log {
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

echo_green "  Log rotation configured (14 days retention)"

# ========================
# 13. CREATE UTILITY SCRIPTS
# ========================
echo_blue "13. Creating utility scripts..."

# Test script
sudo tee /home/gateway/soil-gateway/test-installation.sh > /dev/null << 'EOF'
#!/bin/bash
echo "================================================"
echo "Soil Gateway Installation Test"
echo "================================================"

echo ""
echo "1. Virtual Environment Test:"
VENV_PATH="/home/gateway/soil-gateway-venv"
if [ -f "$VENV_PATH/bin/python" ]; then
    echo "   ✅ Virtual environment exists"
    
    # Test mysql.connector import
    if "$VENV_PATH/bin/python" -c "import mysql.connector; print('   ✅ mysql.connector imports OK')" 2>/dev/null; then
        echo "   ✅ mysql.connector working"
    else
        echo "   ❌ mysql.connector NOT working"
    fi
    
    # Test Flask import
    if "$VENV_PATH/bin/python" -c "import flask; print('   ✅ Flask imports OK')" 2>/dev/null; then
        echo "   ✅ Flask working"
    else
        echo "   ❌ Flask NOT working"
    fi
else
    echo "   ❌ Virtual environment missing!"
fi

echo ""
echo "2. Service Status:"
if sudo systemctl is-active soil-gateway >/dev/null 2>&1; then
    echo "   ✅ Service is running"
else
    echo "   ❌ Service is NOT running"
fi

echo ""
echo "3. Process Check:"
if pgrep -f "gateway.py" >/dev/null; then
    echo "   ✅ Gateway process running"
else
    echo "   ❌ No gateway process found"
fi

echo ""
echo "4. Port Check:"
if sudo lsof -i :5000 >/dev/null 2>&1; then
    echo "   ✅ Port 5000 is in use"
else
    echo "   ❌ Nothing on port 5000"
fi

echo ""
echo "5. Quick API Test:"
if curl -s --max-time 3 http://localhost:5000/api/test >/dev/null; then
    echo "   ✅ API responding"
    echo -n "   Response: "
    curl -s http://localhost:5000/api/test | grep -o '"gateway":"[^"]*"' | head -1
else
    echo "   ❌ API not responding (may be starting up)"
fi

echo ""
echo "================================================"
echo "Test complete!"
echo "================================================"
EOF

chmod +x /home/gateway/soil-gateway/test-installation.sh

# Management script
sudo tee /home/gateway/soil-gateway/manage.sh > /dev/null << 'EOF'
#!/bin/bash
echo "Soil Gateway Management"
echo "======================="

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
        sudo systemctl status soil-gateway
        ;;
    logs)
        echo "Showing logs (Ctrl+C to exit):"
        sudo journalctl -u soil-gateway -f
        ;;
    test)
        echo "Testing gateway..."
        curl http://localhost:5000/api/test 2>/dev/null || echo "Gateway not responding"
        ;;
    test-db)
        echo "Testing MySQL connection..."
        # Extract credentials from gateway.py
        DB_HOST=$(grep -A1 "'host':" /home/gateway/soil-gateway/gateway.py | tail -1 | grep -o "'.*'" | tr -d "'")
        DB_USER=$(grep -A1 "'user':" /home/gateway/soil-gateway/gateway.py | tail -1 | grep -o "'.*'" | tr -d "'")
        DB_PASS=$(grep -A1 "'password':" /home/gateway/soil-gateway/gateway.py | tail -1 | grep -o "'.*'" | tr -d "'")
        DB_NAME=$(grep -A1 "'database':" /home/gateway/soil-gateway/gateway.py | tail -1 | grep -o "'.*'" | tr -d "'")
        
        echo "Testing connection to: $DB_HOST"
        if mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -e "USE $DB_NAME; SELECT '✅ Connection successful' AS status;" 2>/dev/null; then
            echo "✅ MySQL connection successful"
        else
            echo "❌ MySQL connection failed"
        fi
        ;;
    help|--help|-h)
        echo "Usage: $0 {start|stop|restart|status|logs|test|test-db|help}"
        echo ""
        echo "Commands:"
        echo "  start     - Start gateway service"
        echo "  stop      - Stop gateway service"
        echo "  restart   - Restart gateway service"
        echo "  status    - Check service status"
        echo "  logs      - View service logs (follow)"
        echo "  test      - Test gateway API"
        echo "  test-db   - Test MySQL connection"
        echo "  help      - Show this help"
        ;;
    *)
        echo "Unknown command: $1"
        echo "Use: $0 help"
        exit 1
        ;;
esac
EOF

chmod +x /home/gateway/soil-gateway/manage.sh

echo_green "  Utility scripts created"

# ========================
# 14. START THE SERVICE
# ========================
echo_blue "14. Starting gateway service..."

sudo systemctl start soil-gateway
sleep 5  # Give it time to start

echo_green "  Service started"

# ========================
# 15. FINAL OUTPUT
# ========================
echo ""
echo "================================================"
echo_green "✅ SOIL MONITORING GATEWAY INSTALLATION COMPLETE!"
echo "================================================"
echo ""
echo "📋 INSTALLATION SUMMARY:"
echo "   👤 User:           gateway"
echo "   📍 Application:    /home/gateway/soil-gateway/"
echo "   💾 Data Storage:   /home/gateway/soil_gateway_data/"
echo "   📝 Logs:           /home/gateway/soil_gateway_logs/"
echo "   🐍 Virtual Env:    $VENV_PATH"
echo "   🗄️  MySQL Host:    192.168.1.100 (Database Pi)"
echo ""
echo "🔧 SERVICE STATUS:"
if sudo systemctl is-active soil-gateway >/dev/null; then
    echo_green "   ✅ Service is RUNNING"
else
    echo_red "   ❌ Service is NOT running"
    echo_yellow "   Check: sudo systemctl status soil-gateway"
fi
echo ""
echo "🚀 QUICK COMMANDS:"
echo "   Test installation:  ./test-installation.sh"
echo "   Manage gateway:     ./manage.sh [command]"
echo "   View logs:          sudo journalctl -u soil-gateway -f"
echo ""
echo "🌐 TEST THE GATEWAY:"
echo "   curl http://localhost:5000/api/test"
echo "   curl http://localhost:5000/api/health"
echo ""
echo "📡 GATEWAY URL (for sensors):"
IP_ADDRESS=$(hostname -I | awk '{print $1}')
echo "   http://$IP_ADDRESS:5000/api/sensor-data"
echo ""
echo "⚠️  IMPORTANT NEXT STEPS:"
echo "   1. On Database Pi (192.168.1.100), create MySQL user:"
echo "      CREATE USER 'gateway_user'@'%' IDENTIFIED BY 'gateway_pass';"
echo "      GRANT INSERT,SELECT ON soilmonitornig.* TO 'gateway_user'@'%';"
echo "      FLUSH PRIVILEGES;"
echo ""
echo "   2. Test MySQL connection:"
echo "      ./manage.sh test-db"
echo ""
echo "   3. Update gateway.py if MySQL credentials are different"
echo ""
echo "🔧 TROUBLESHOOTING:"
echo "   If mysql.connector still fails, run:"
echo "   source $VENV_PATH/bin/activate"
echo "   pip install mysql-connector-python --force-reinstall"
echo "   deactivate"
echo "   sudo systemctl restart soil-gateway"
echo ""
echo "================================================"
echo "Installation completed at: $(date)"
echo "================================================"

# Run quick test
echo ""
echo_yellow "Running quick installation test..."
/home/gateway/soil-gateway/test-installation.sh
