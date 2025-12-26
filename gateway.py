"""
Gateway Pi - Enhanced Gateway with Direct MySQL Access
Routes sensor data directly to MySQL database
Uses API for assignment checks and registration
"""
from flask import Flask, request, jsonify
import requests
import logging
import time
import sqlite3
import json
from datetime import datetime
from threading import Thread
import os
import mysql.connector
from mysql.connector import pooling, Error

# ========================
# CONFIGURATION
# ========================
class Config:
    # Gateway settings
    GATEWAY_HOST = '0.0.0.0'
    GATEWAY_PORT = 5000  # MUST be 5000 (sensors expect this)
    
    # Database Pi (appV7.py) - API URL for non-data operations
    DATABASE_PI_API_URL = "http://192.168.1.95:5000"
    
    # Direct MySQL Configuration
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
    API_TIMEOUT = 10  # seconds for API calls
    MAX_RETRIES = 3
    RETRY_DELAY = 5  # seconds
    
    # Health check interval (seconds)
    HEALTH_CHECK_INTERVAL = 300  # 5 minutes
    
    # Batch processing
    BATCH_SIZE = 50
    BATCH_INTERVAL = 60  # Process offline data every 60 seconds

# ========================
# DATABASE MANAGER
# ========================
class DatabaseManager:
    _connection_pool = None
    
    @classmethod
    def initialize_pool(cls):
        """Initialize MySQL connection pool"""
        try:
            cls._connection_pool = pooling.MySQLConnectionPool(
                pool_name=Config.DB_CONFIG['pool_name'],
                pool_size=Config.DB_CONFIG['pool_size'],
                pool_reset_session=Config.DB_CONFIG['pool_reset_session'],
                host=Config.DB_CONFIG['host'],
                port=Config.DB_CONFIG['port'],
                database=Config.DB_CONFIG['database'],
                user=Config.DB_CONFIG['user'],
                password=Config.DB_CONFIG['password']
            )
            
            # Test connection
            conn = cls.get_connection()
            if conn.is_connected():
                logging.info("✅ MySQL connection pool initialized successfully")
                conn.close()
                return True
            else:
                logging.error("❌ MySQL pool initialization failed")
                return False
                
        except Error as e:
            logging.error(f"❌ MySQL pool initialization error: {e}")
            cls._connection_pool = None
            return False
    
    @classmethod
    def get_connection(cls):
        """Get connection from pool"""
        if not cls._connection_pool:
            if not cls.initialize_pool():
                raise Exception("Database connection pool not available")
        
        try:
            return cls._connection_pool.get_connection()
        except Error as e:
            logging.error(f"❌ Failed to get database connection: {e}")
            raise
    
    @classmethod
    def get_sensor_assignment(cls, machine_id):
        """Get sensor assignment info from database"""
        query = """
            SELECT 
                s.machine_id,
                s.farm_id,
                s.zone_code,
                s.installation,
                f.farm_name,
                c.client_name,
                c.client_id
            FROM sensors s
            LEFT JOIN farms f ON s.farm_id = f.farm_id
            LEFT JOIN client c ON f.client_id = c.client_id
            WHERE s.machine_id = %s
        """
        
        conn = None
        cursor = None
        try:
            conn = cls.get_connection()
            cursor = conn.cursor(dictionary=True)
            cursor.execute(query, (machine_id,))
            result = cursor.fetchone()
            
            if not result:
                return None
            
            return {
                'machine_id': machine_id,
                'assigned': result['farm_id'] is not None,
                'farm_id': result['farm_id'],
                'zone_code': result['zone_code'],
                'installation_date': result['installation'],
                'farm_name': result['farm_name'],
                'client_id': result['client_id'],
                'client_name': result['client_name']
            }
            
        except Error as e:
            logging.error(f"Database error getting sensor assignment: {e}")
            return None
        finally:
            if cursor:
                cursor.close()
            if conn:
                conn.close()
    
    @classmethod
    def insert_sensor_data(cls, data):
        """Insert sensor data directly into MySQL"""
        query = """
            INSERT INTO sensor_data 
            (farm_id, zone_code, machine_id, timestamp, moisture, temperature, 
             conductivity, ph, nitrogen, phosphorus, potassium) 
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        """
        
        # First, get farm_id and zone_code for this sensor
        assignment_info = cls.get_sensor_assignment(data['machine_id'])
        
        if not assignment_info or not assignment_info['assigned']:
            raise Exception(f"Sensor {data['machine_id']} is not assigned to any farm/zone")
        
        values = (
            assignment_info['farm_id'],
            assignment_info['zone_code'],
            data['machine_id'],
            data.get('timestamp', datetime.now().strftime('%Y-%m-%d %H:%M:%S')),
            data.get('moisture', 0),
            data.get('temperature', 0),
            data.get('conductivity', 0),
            data.get('ph', 0),
            data.get('nitrogen', 0),
            data.get('phosphorus', 0),
            data.get('potassium', 0)
        )
        
        conn = None
        cursor = None
        try:
            conn = cls.get_connection()
            cursor = conn.cursor()
            cursor.execute(query, values)
            conn.commit()
            
            inserted_id = cursor.lastrowid
            logging.info(f"✅ Sensor data inserted into MySQL (ID: {inserted_id})")
            return inserted_id
            
        except Error as e:
            logging.error(f"❌ MySQL insert error: {e}")
            if conn:
                conn.rollback()
            raise
        finally:
            if cursor:
                cursor.close()
            if conn:
                conn.close()
    
    @classmethod
    def check_health(cls):
        """Check MySQL database health"""
        try:
            conn = cls.get_connection()
            cursor = conn.cursor()
            cursor.execute("SELECT 1")
            result = cursor.fetchone()
            cursor.close()
            conn.close()
            return result[0] == 1
        except Error as e:
            logging.error(f"MySQL health check failed: {e}")
            return False

# ========================
# APPLICATION SETUP
# ========================
app = Flask(__name__)

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/home/pi/gateway_data/gateway.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

# Statistics
gateway_stats = {
    'start_time': datetime.now(),
    'requests_received': 0,
    'mysql_inserts': 0,
    'mysql_errors': 0,
    'api_calls': 0,
    'api_errors': 0,
    'stored_offline': 0,
    'offline_synced': 0,
    'last_mysql_check': None,
    'mysql_available': False,
    'last_api_check': None,
    'api_available': False
}

# ========================
# OFFLINE STORAGE (SQLite)
# ========================
class OfflineStorage:
    def __init__(self, db_path):
        self.db_path = db_path
        self.init_db()
    
    def init_db(self):
        """Initialize SQLite database for offline storage"""
        os.makedirs(os.path.dirname(self.db_path), exist_ok=True)
        
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS offline_queue (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                endpoint TEXT NOT NULL,
                data TEXT NOT NULL,
                timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
                attempts INTEGER DEFAULT 0,
                last_attempt DATETIME,
                destination TEXT NOT NULL CHECK(destination IN ('mysql', 'api'))
            )
        ''')
        
        conn.commit()
        conn.close()
        logger.info(f"Offline storage initialized: {self.db_path}")
    
    def save_offline(self, endpoint, data, destination):
        """Save request to offline queue"""
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        
        try:
            cursor.execute('''
                INSERT INTO offline_queue (endpoint, data, destination)
                VALUES (?, ?, ?)
            ''', (endpoint, json.dumps(data), destination))
            
            conn.commit()
            record_id = cursor.lastrowid
            
            # Check queue size
            cursor.execute('SELECT COUNT(*) FROM offline_queue')
            count = cursor.fetchone()[0]
            
            if count > Config.MAX_OFFLINE_RECORDS:
                cursor.execute('''
                    DELETE FROM offline_queue 
                    WHERE id IN (
                        SELECT id FROM offline_queue 
                        ORDER BY timestamp ASC 
                        LIMIT ?
                    )
                ''', (count - Config.MAX_OFFLINE_RECORDS,))
                conn.commit()
                logger.warning(f"Offline queue trimmed to {Config.MAX_OFFLINE_RECORDS} records")
            
            logger.info(f"Saved to offline queue: {endpoint} (Dest: {destination}, ID: {record_id})")
            return record_id
            
        except Exception as e:
            logger.error(f"Failed to save offline: {e}")
            return None
        finally:
            conn.close()
    
    def get_pending_records(self, destination, limit=50):
        """Get pending records for retry"""
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        cursor = conn.cursor()
        
        cursor.execute('''
            SELECT * FROM offline_queue 
            WHERE attempts < ? AND destination = ?
            ORDER BY timestamp ASC 
            LIMIT ?
        ''', (Config.MAX_RETRIES, destination, limit))
        
        records = cursor.fetchall()
        conn.close()
        
        return records
    
    def update_attempt(self, record_id, success):
        """Update record after attempt"""
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        
        if success:
            cursor.execute('DELETE FROM offline_queue WHERE id = ?', (record_id,))
            logger.info(f"Removed synced record: {record_id}")
        else:
            cursor.execute('''
                UPDATE offline_queue 
                SET attempts = attempts + 1, 
                    last_attempt = CURRENT_TIMESTAMP
                WHERE id = ?
            ''', (record_id,))
            
            cursor.execute('SELECT attempts FROM offline_queue WHERE id = ?', (record_id,))
            attempts = cursor.fetchone()[0]
            
            if attempts >= Config.MAX_RETRIES:
                logger.warning(f"Record {record_id} exceeded max retries, keeping for manual review")
        
        conn.commit()
        conn.close()

# Initialize components
offline_storage = OfflineStorage(Config.OFFLINE_STORAGE_PATH)

# ========================
# HEALTH CHECKS
# ========================
def check_mysql_health():
    """Check if MySQL is reachable"""
    try:
        gateway_stats['mysql_available'] = DatabaseManager.check_health()
        gateway_stats['last_mysql_check'] = datetime.now()
        
        if gateway_stats['mysql_available']:
            logger.info("✅ MySQL database is reachable")
        else:
            logger.warning("MySQL database not reachable")
            
        return gateway_stats['mysql_available']
        
    except Exception as e:
        gateway_stats['mysql_available'] = False
        gateway_stats['last_mysql_check'] = datetime.now()
        logger.warning(f"MySQL not reachable: {e}")
        return False

def check_api_health():
    """Check if Database Pi API is reachable"""
    try:
        response = requests.get(
            f"{Config.DATABASE_PI_API_URL}/api/test",
            timeout=5
        )
        gateway_stats['api_available'] = (response.status_code == 200)
        gateway_stats['last_api_check'] = datetime.now()
        
        if gateway_stats['api_available']:
            logger.info("✅ Database Pi API is reachable")
        else:
            logger.warning(f"Database Pi API returned status {response.status_code}")
            
        return gateway_stats['api_available']
        
    except Exception as e:
        gateway_stats['api_available'] = False
        gateway_stats['last_api_check'] = datetime.now()
        logger.warning(f"Database Pi API not reachable: {e}")
        return False

# ========================
# REQUEST PROCESSING
# ========================
def call_api(endpoint, data, method='POST'):
    """Call Database Pi API"""
    url = f"{Config.DATABASE_PI_API_URL}{endpoint}"
    
    for attempt in range(Config.MAX_RETRIES):
        try:
            if method == 'POST':
                response = requests.post(url, json=data, timeout=Config.API_TIMEOUT)
            else:  # GET
                response = requests.get(url, timeout=Config.API_TIMEOUT)
            
            logger.debug(f"API {endpoint}: Status {response.status_code}")
            
            if response.status_code in [200, 201]:
                gateway_stats['api_calls'] += 1
                return True, response.json()
            else:
                logger.warning(f"API {endpoint} failed: Status {response.status_code}")
                time.sleep(Config.RETRY_DELAY)
                
        except Exception as e:
            logger.warning(f"API attempt {attempt + 1} failed: {e}")
            if attempt < Config.MAX_RETRIES - 1:
                time.sleep(Config.RETRY_DELAY)
    
    gateway_stats['api_errors'] += 1
    return False, None

def process_sensor_data(data):
    """Process sensor data - try MySQL first, fallback to offline storage"""
    try:
        # Try direct MySQL insert
        inserted_id = DatabaseManager.insert_sensor_data(data)
        gateway_stats['mysql_inserts'] += 1
        return True, {'mysql_id': inserted_id}
        
    except Exception as e:
        logger.warning(f"MySQL insert failed, saving offline: {e}")
        gateway_stats['mysql_errors'] += 1
        
        # Save to offline storage
        record_id = offline_storage.save_offline('/api/sensor-data', data, 'mysql')
        if record_id:
            gateway_stats['stored_offline'] += 1
            return False, {'offline_id': record_id, 'message': 'Data saved offline'}
        
        return False, {'error': 'Failed to save data'}

def process_offline_queue():
    """Process offline queue in background"""
    while True:
        try:
            time.sleep(Config.BATCH_INTERVAL)
            
            # Process MySQL-bound records
            if check_mysql_health():
                mysql_records = offline_storage.get_pending_records('mysql', Config.BATCH_SIZE)
                if mysql_records:
                    logger.info(f"Processing {len(mysql_records)} offline MySQL records")
                    
                    for record in mysql_records:
                        record_id = record['id']
                        data = json.loads(record['data'])
                        
                        try:
                            inserted_id = DatabaseManager.insert_sensor_data(data)
                            offline_storage.update_attempt(record_id, True)
                            gateway_stats['offline_synced'] += 1
                            logger.info(f"Synced offline record {record_id} to MySQL")
                        except Exception as e:
                            offline_storage.update_attempt(record_id, False)
                            logger.error(f"Failed to sync offline record {record_id}: {e}")
            
            # Process API-bound records
            if check_api_health():
                api_records = offline_storage.get_pending_records('api', Config.BATCH_SIZE)
                if api_records:
                    logger.info(f"Processing {len(api_records)} offline API records")
                    
                    for record in api_records:
                        record_id = record['id']
                        endpoint = record['endpoint']
                        data = json.loads(record['data'])
                        
                        success, response = call_api(endpoint, data)
                        offline_storage.update_attempt(record_id, success)
                        
                        if success:
                            gateway_stats['offline_synced'] += 1
                            logger.info(f"Synced offline record {record_id} to API")
                        else:
                            logger.error(f"Failed to sync offline API record {record_id}")
            
        except Exception as e:
            logger.error(f"Error processing offline queue: {e}")
            time.sleep(60)

# ========================
# API ENDPOINTS
# ========================
@app.route('/api/test', methods=['GET'])
def test_gateway():
    """Test gateway connectivity"""
    mysql_status = "unknown"
    api_status = "unknown"
    
    mysql_status = "connected" if check_mysql_health() else "disconnected"
    api_status = "connected" if check_api_health() else "disconnected"
    
    return jsonify({
        "gateway": "online",
        "timestamp": datetime.now().isoformat(),
        "mysql": mysql_status,
        "api": api_status,
        "mysql_config": {
            "host": Config.DB_CONFIG['host'],
            "database": Config.DB_CONFIG['database']
        },
        "api_url": Config.DATABASE_PI_API_URL
    })

@app.route('/api/sensor-data', methods=['POST'])
def handle_sensor_data():
    """Receive sensor data and store in MySQL"""
    gateway_stats['requests_received'] += 1
    
    try:
        data = request.json
        if not data:
            return jsonify({"error": "No data provided"}), 400
        
        machine_id = data.get('machine_id')
        if not machine_id:
            return jsonify({"error": "Missing machine_id"}), 400
        
        logger.info(f"Received data from sensor {machine_id}")
        
        # Process data (try MySQL first)
        success, result = process_sensor_data(data)
        
        if success:
            logger.info(f"Data stored in MySQL for sensor {machine_id}")
            return jsonify({
                "status": "stored",
                "message": "Data stored directly in MySQL database",
                "mysql_id": result.get('mysql_id'),
                "timestamp": datetime.now().isoformat()
            })
        else:
            # Data was saved offline
            if 'offline_id' in result:
                logger.info(f"Data saved offline for sensor {machine_id} (Record: {result['offline_id']})")
                return jsonify({
                    "status": "stored_offline",
                    "message": "MySQL unavailable, data stored locally",
                    "offline_id": result['offline_id'],
                    "timestamp": datetime.now().isoformat()
                }), 202
            else:
                return jsonify({"error": "Failed to store data"}), 500
            
    except Exception as e:
        logger.error(f"Error handling sensor data: {e}")
        return jsonify({"error": "Internal server error"}), 500

@app.route('/api/sensors/register', methods=['POST'])
def handle_sensor_registration():
    """Handle sensor registration via API"""
    gateway_stats['requests_received'] += 1
    
    try:
        data = request.json
        if not data:
            return jsonify({"error": "No data provided"}), 400
        
        machine_id = data.get('machine_id')
        if not machine_id:
            return jsonify({"error": "Missing machine_id"}), 400
        
        logger.info(f"Registration request for sensor {machine_id}")
        
        # Try to call API
        success, response = call_api('/api/sensors/register', data)
        
        if success:
            logger.info(f"Registration completed for sensor {machine_id}")
            return jsonify(response), 200
        else:
            # Save to offline storage
            record_id = offline_storage.save_offline('/api/sensors/register', data, 'api')
            if record_id:
                gateway_stats['stored_offline'] += 1
                logger.info(f"Registration saved offline for sensor {machine_id}")
                return jsonify({
                    "status": "queued",
                    "message": "Registration queued, will retry",
                    "machine_id": machine_id,
                    "timestamp": datetime.now().isoformat()
                }), 202
            else:
                return jsonify({"error": "Failed to queue registration"}), 500
            
    except Exception as e:
        logger.error(f"Error handling registration: {e}")
        return jsonify({"error": "Internal server error"}), 500

@app.route('/api/sensors/<machine_id>/assignment', methods=['GET'])
def handle_assignment_check(machine_id):
    """Check sensor assignment status via API"""
    gateway_stats['requests_received'] += 1
    
    logger.info(f"Assignment check for sensor {machine_id}")
    
    # Try to call API
    success, response = call_api(f'/api/sensors/{machine_id}/assignment', None, method='GET')
    
    if success:
        return jsonify(response), 200
    else:
        # For GET requests, try direct database check as fallback
        try:
            assignment_info = DatabaseManager.get_sensor_assignment(machine_id)
            if assignment_info:
                return jsonify(assignment_info), 200
            else:
                return jsonify({
                    "error": "Sensor not found",
                    "machine_id": machine_id
                }), 404
        except Exception as e:
            logger.warning(f"Could not check assignment for {machine_id}: {e}")
            return jsonify({
                "error": "API and database unavailable",
                "machine_id": machine_id,
                "suggestion": "Retry later"
            }), 503

@app.route('/api/health', methods=['GET'])
def health_check():
    """Comprehensive health check"""
    uptime = datetime.now() - gateway_stats['start_time']
    
    # Check health
    mysql_healthy = check_mysql_health()
    api_healthy = check_api_health()
    
    health_data = {
        "gateway": {
            "status": "healthy",
            "uptime_seconds": int(uptime.total_seconds()),
            "start_time": gateway_stats['start_time'].isoformat(),
            "requests_received": gateway_stats['requests_received'],
            "mysql_inserts": gateway_stats['mysql_inserts'],
            "mysql_errors": gateway_stats['mysql_errors'],
            "api_calls": gateway_stats['api_calls'],
            "api_errors": gateway_stats['api_errors'],
            "stored_offline": gateway_stats['stored_offline'],
            "offline_synced": gateway_stats['offline_synced']
        },
        "mysql": {
            "host": Config.DB_CONFIG['host'],
            "database": Config.DB_CONFIG['database'],
            "available": mysql_healthy,
            "last_check": gateway_stats['last_mysql_check'].isoformat() if gateway_stats['last_mysql_check'] else None
        },
        "api": {
            "url": Config.DATABASE_PI_API_URL,
            "available": api_healthy,
            "last_check": gateway_stats['last_api_check'].isoformat() if gateway_stats['last_api_check'] else None
        }
    }
    
    return jsonify(health_data)

# ========================
# DATABASE SETUP UTILITY
# ========================
def setup_database_user():
    """Script to create the gateway user in MySQL"""
    print("=" * 60)
    print("MySQL Gateway User Setup")
    print("=" * 60)
    print("\nRun these commands in MySQL (as root or admin user):")
    print("\n1. Create gateway user:")
    print(f"""
CREATE USER 'gateway_user'@'{Config.DB_CONFIG['host']}' 
IDENTIFIED BY 'gateway_pass';
    """)
    print("\n2. Grant minimal permissions:")
    print(f"""
GRANT INSERT, SELECT ON {Config.DB_CONFIG['database']}.sensor_data 
TO 'gateway_user'@'{Config.DB_CONFIG['host']}';

GRANT SELECT ON {Config.DB_CONFIG['database']}.sensors 
TO 'gateway_user'@'{Config.DB_CONFIG['host']}';

GRANT SELECT ON {Config.DB_CONFIG['database']}.farms 
TO 'gateway_user'@'{Config.DB_CONFIG['host']}';

GRANT SELECT ON {Config.DB_CONFIG['database']}.client 
TO 'gateway_user'@'{Config.DB_CONFIG['host']}';
    """)
    print("\n3. Flush privileges:")
    print("FLUSH PRIVILEGES;")
    print("\n" + "=" * 60)

# ========================
# MAIN APPLICATION
# ========================
def main():
    """Main gateway application entry point"""
    try:
        # Display setup reminder
        print("=" * 60)
        print("🚀 Enhanced Gateway Pi Starting")
        print("=" * 60)
        print("\n⚠️  IMPORTANT: Before starting, ensure MySQL user is created:")
        setup_database_user()
        
        # Initial health checks
        check_mysql_health()
        check_api_health()
        
        # Start offline queue processor
        queue_processor = Thread(target=process_offline_queue, daemon=True)
        queue_processor.start()
        logger.info("Offline queue processor started")
        
        # Display startup information
        logger.info("=" * 60)
        logger.info("🚀 Enhanced IoT Gateway Starting")
        logger.info(f"   Host: {Config.GATEWAY_HOST}:{Config.GATEWAY_PORT}")
        logger.info(f"   MySQL: {Config.DB_CONFIG['host']}/{Config.DB_CONFIG['database']}")
        logger.info(f"   API: {Config.DATABASE_PI_API_URL}")
        logger.info(f"   Offline Storage: {Config.OFFLINE_STORAGE_PATH}")
        logger.info("=" * 60)
        logger.info("📡 Endpoints available:")
        logger.info("   POST /api/sensor-data        - Store sensor data (direct to MySQL)")
        logger.info("   POST /api/sensors/register   - Register sensor (via API)")
        logger.info("   GET  /api/sensors/{id}/assignment - Check assignment (via API)")
        logger.info("   GET  /api/health             - Health check")
        logger.info("   GET  /api/test               - Connectivity test")
        logger.info("=" * 60)
        logger.info("💾 Data Flow:")
        logger.info("   Sensor Data → Direct MySQL Insert")
        logger.info("   Registration/Assignment → API Call")
        logger.info("   Offline Fallback → SQLite → Retry")
        logger.info("=" * 60)
        
        # Start Flask application
        app.run(
            host=Config.GATEWAY_HOST,
            port=Config.GATEWAY_PORT,
            debug=False,
            threaded=True
        )
        
    except Exception as e:
        logger.error(f"Gateway startup failed: {e}")
        raise

if __name__ == '__main__':
    main()



