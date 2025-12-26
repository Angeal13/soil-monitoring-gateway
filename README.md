# Soil Monitoring Gateway

An enhanced IoT gateway for soil monitoring systems that routes sensor data directly to MySQL database with offline capabilities.

## Features

- **Direct MySQL Insert**: Sensor data goes directly to MySQL database
- **Offline Storage**: SQLite backup when MySQL is unavailable
- **Automatic Retry**: Background process syncs offline data
- **Health Monitoring**: Comprehensive health check endpoints
- **Sensor Registration**: API for sensor registration and assignment checks
- **Auto-start on Boot**: Systemd service for reliability

## Installation

### Prerequisites
- Raspberry Pi (or Debian-based Linux)
- Python 3.7+
- MySQL/MariaDB server
- Network connectivity

### Quick Install
```bash
# Clone the repository
git clone https://github.com/yourusername/soil-monitoring-gateway.git
cd soil-monitoring-gateway

# Run installation script
chmod +x install.sh
sudo ./install.sh
