"""
Gateway Pi - Enhanced Gateway with Direct MySQL Access
Routes sensor data to Database Pi (192.168.1.100)
Uses SQLite for offline storage locally
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
    
    # Direct MySQL Configuration - CONNECTS TO DATABASE PI (192.168.1.100)
    DB_CONFIG = {
        'host': '192.168.1.100',      # Database Pi IP - DO NOT CHANGE TO localhost
        'port': 3306,
        'database': 'soilmonitornig',
        'user': 'gateway_user',       # User on Database Pi
        'password': 'gateway_pass',   # Password on Database Pi
        'pool_name': 'gateway_pool',
        'pool_size': 5,
        'pool_reset_session': True
    }
    
    # Local offline storage (SQLite on Gateway Pi)
    OFFLINE_STORAGE_PATH = '/home/gateway/soil_gateway_data/offline_queue.db'
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
        """Initialize MySQL connection pool to Database Pi"""
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
            
            # Test connection to Database Pi
            conn = cls.get_connection()
            if conn.is_connected():
                logging.info(f"✅ MySQL connection to {Config.DB_CONFIG['host']} initialized successfully")
                conn.close()
                return True
            else:
                logging.error(f"❌ MySQL pool initialization failed for {Config.DB_CONFIG['host']}")
                return False
                
        except Error as e:
            logging.error(f"❌ MySQL connection error to {Config.DB_CONFIG['host']}: {e}")
            cls._connection_pool = None
            return False
    
    @classmethod
    def get_connection(cls):
        """Get connection from pool to Database Pi"""
        if not cls._connection_pool:
            if not cls.initialize_pool():
                raise Exception(f"Database connection pool to {Config.DB_CONFIG['host']} not available")
        
        try:
            return cls._connection_pool.get_connection()
        except Error as e:
            logging.error(f"❌ Failed to get database connection to {Config.DB_CONFIG['host']}: {e}")
            raise
    
    @classmethod
    def get_sensor_assignment(cls, machine_id):
        """Get sensor assignment info from Database Pi"""
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
            logging.error(f"Database error getting sensor assignment from {Config.DB_CONFIG['host']}: {e}")
            return None
        finally:
            if cursor:
                cursor.close()
            if conn:
                conn.close()
    
    @classmethod
    def insert_sensor_data(cls, data):
        """Insert sensor data directly into Database Pi"""
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
            logging.info(f"✅ Sensor data inserted into MySQL at {Config.DB_CONFIG['host']} (ID: {inserted_id})")
            return inserted_id
            
        except Error as e:
            logging.error(f"❌ MySQL insert error at {Config.DB_CONFIG['host']}: {e}")
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
        """Check Database Pi MySQL health"""
        try:
            conn = cls.get_connection()
            cursor = conn.cursor()
            cursor.execute("SELECT 1")
            result = cursor.fetchone()
            cursor.close()
            conn.close()
            return result[0] == 1
        except Error as e:
            logging.error(f"MySQL health check failed for {Config.DB_CONFIG['host']}: {e}")
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
        logging.FileHandler('/home/gateway/soil_gateway_data/gateway.log'),
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
# OFFLINE STORAGE (SQLite on Gateway Pi)
# ========================
class OfflineStorage:
    def __init__(self, db_path):
        self.db_path = db_path
        self.init_db()
    
    def init_db(self):
        """Initialize SQLite database for offline storage on Gateway Pi"""
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
        logger.info(f"SQLite offline storage initialized: {self.db_path}")
    
    def save_offline(self, endpoint, data, destination):
        """Save request to offline SQLite queue"""
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
            
            logger.info(f"Saved to SQLite offline queue: {endpoint} (Dest: {destination}, ID: {record_id})")
            return record_id
            
        except Exception as e:
            logger.error(f"Failed to save to SQLite: {e}")
            return None
        finally:
            conn.close()
    
    def get_pending_records(self, destination, limit=50):
        """Get pending records from SQLite for retry"""
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
        """Update SQLite record after attempt"""
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        
        if success:
            cursor.execute('DELETE FROM offline_queue WHERE id = ?', (record_id,))
            logger.info(f"Removed synced record from SQLite: {record_id}")
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
                logger.warning(f"SQLite record {record_id} exceeded max retries, keeping for manual review")
        
        conn.commit()
        conn.close()

# Initialize components
offline_storage = OfflineStorage(Config.OFFLINE_STORAGE_PATH)

# ========================
# HEALTH CHECKS
# ========================
def check_mysql_health():
    """Check if Database Pi (192.168.1.100) is reachable"""
    try:
        gateway_stats['mysql_available'] = DatabaseManager.check_health()
        gateway_stats['last_mysql_check'] = datetime.now()
        
        if gateway_stats['mysql_available']:
            logger.info(f"✅ Database Pi MySQL ({Config.DB_CONFIG['host']}) is reachable")
        else:
            logger.warning(f"Database Pi MySQL ({Config.DB_CONFIG['host']}) not reachable")
            
        return gateway_stats['mysql_available']
        
    except Exception as e:
        gateway_stats['mysql_available'] = False
        gateway_stats['last_mysql_check'] = datetime.now()
        logger.warning(f"Database Pi MySQL ({Config.DB_CONFIG['host']}) not reachable: {e}")
        return False

def check_api_health():
    """Check if Database Pi API (192.168.1.95) is reachable"""
    try:
        response = requests.get(
            f"{Config.DATABASE_PI_API_URL}/api/test",
            timeout=5
        )
        gateway_stats['api_available'] = (response.status_code == 200)
        gateway_stats['last_api_check'] = datetime.now()
        
        if gateway_stats['api_available']:
            logger.info(f"✅ Database Pi API ({Config.DATABASE_PI_API_URL}) is reachable")
        else:
            logger.warning(f"Database Pi API ({Config.DATABASE_PI_API_URL}) returned status {response.status_code}")
            
        return gateway_stats['api_available']
        
    except Exception as e:
        gateway_stats['api_available'] = False
        gateway_stats['last_api_check'] = datetime.now()
        logger.warning(f"Database Pi API ({Config.DATABASE_PI_API_URL}) not reachable: {e}")
        return False

# ========================
# REQUEST PROCESSING
# ========================
def call_api(endpoint, data, method='POST'):
    """Call Database Pi API (192.168.1.95)"""
    url = f"{Config.DATABASE_PI_API_URL}{endpoint}"
    
    for attempt in range(Config.MAX_RETRIES):
        try:
            if method == 'POST':
                response = requests.post(url, json=data, timeout=Config.API_TIMEOUT)
            else:  # GET
                response = requests.get(url, timeout=Config.API_TIMEOUT)
            
            logger.debug(f"API {endpoint} to {Config.DATABASE_PI_API_URL}: Status {response.status_code}")
            
            if response.status_code in [200, 201]:
                gateway_stats['api_calls'] += 1
                return True, response.json()
            else:
                logger.warning(f"API {endpoint} to {Config.DATABASE_PI_API_URL} failed: Status {response.status_code}")
                time.sleep(Config.RETRY_DELAY)
                
        except Exception as e:
            logger.warning(f"API attempt {attempt + 1} to {Config.DATABASE_PI_API_URL} failed: {e}")
            if attempt < Config.MAX_RETRIES - 1:
                time.sleep(Config.RETRY_DELAY)
    
    gateway_stats['api_errors'] += 1
    return False, None

def process_sensor_data(data):
    """Process sensor data - try Database Pi MySQL first, fallback to SQLite"""
    try:
        # Try direct MySQL insert to Database Pi
        inserted_id = DatabaseManager.insert_sensor_data(data)
        gateway_stats['mysql_inserts'] += 1
        return True, {'mysql_id': inserted_id, 'host': Config.DB_CONFIG['host']}
        
    except Exception as e:
        logger.warning(f"MySQL insert to {Config.DB_CONFIG['host']} failed, saving to SQLite: {e}")
        gateway_stats['mysql_errors'] += 1
        
        # Save to SQLite offline storage on Gateway Pi
        record_id = offline_storage.save_offline('/api/sensor-data', data, 'mysql')
        if record_id:
            gateway_stats['stored_offline'] += 1
            return False, {'offline_id': record_id, 'message': f'Data saved to SQLite, will sync to {Config.DB_CONFIG["host"]}'}
        
        return False, {'error': 'Failed to save data to SQLite'}

def process_offline_queue():
    """Process SQLite offline queue in background - sync to Database Pi"""
    while True:
        try:
            time.sleep(Config.BATCH_INTERVAL)
            
            # Process MySQL-bound records (sync to Database Pi)
            if check_mysql_health():
                mysql_records = offline_storage.get_pending_records('mysql', Config.BATCH_SIZE)
                if mysql_records:
                    logger.info(f"Processing {len(mysql_records)} SQLite records to sync with {Config.DB_CONFIG['host']}")
                    
                    for record in mysql_records:
                        record_id = record['id']
                        data = json.loads(record['data'])
                        
                        try:
                            inserted_id = DatabaseManager.insert_sensor_data(data)
                            offline_storage.update_attempt(record_id, True)
                            gateway_stats['offline_synced'] += 1
                            logger.info(f"Synced SQLite record {record_id} to MySQL at {Config.DB_CONFIG['host']}")
                        except Exception as e:
                            offline_storage.update_attempt(record_id, False)
                            logger.error(f"Failed to sync SQLite record {record_id} to {Config.DB_CONFIG['host']}: {e}")
            
            # Process API-bound records (sync to Database Pi API)
            if check_api_health():
                api_records = offline_storage.get_pending_records('api', Config.BATCH_SIZE)
                if api_records:
                    logger.info(f"Processing {len(api_records)} SQLite records to sync with {Config.DATABASE_PI_API_URL}")
                    
                    for record in api_records:
                        record_id = record['id']
                        endpoint = record['endpoint']
                        data = json.loads(record['data'])
                        
                        success, response = call_api(endpoint, data)
                        offline_storage.update_attempt(record_id, success)
                        
                        if success:
                            gateway_stats['offline_synced'] += 1
                            logger.info(f"Synced SQLite record {record_id} to API at {Config.DATABASE_PI_API_URL}")
                        else:
                            logger.error(f"Failed to sync SQLite API record {record_id} to {Config.DATABASE_PI_API_URL}")
            
        except Exception as e:
            logger.error(f"Error processing SQLite offline queue: {e}")
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
        "mysql_host": Config.DB_CONFIG['host'],
        "api": api_status,
        "api_url": Config.DATABASE_PI_API_URL,
        "offline_storage": "sqlite",
        "offline_path": Config.OFFLINE_STORAGE_PATH
    })

@app.route('/api/sensor-data', methods=['POST'])
def handle_sensor_data():
    """Receive sensor data and store in Database Pi MySQL (or SQLite offline)"""
    gateway_stats['requests_received'] += 1
    
    try:
        data = request.json
        if not data:
            return jsonify({"error": "No data provided"}), 400
        
        machine_id = data.get('machine_id')
        if not machine_id:
            return jsonify({"error": "Missing machine_id"}), 400
        
        logger.info(f"Received data from sensor {machine_id}")
        
        # Process data (try Database Pi MySQL first)
        success, result = process_sensor_data(data)
        
        if success:
            logger.info(f"Data stored in MySQL at {Config.DB_CONFIG['host']} for sensor {machine_id}")
            return jsonify({
                "status": "stored",
                "message": f"Data stored in MySQL database at {Config.DB_CONFIG['host']}",
                "mysql_id": result.get('mysql_id'),
                "mysql_host": Config.DB_CONFIG['host'],
                "timestamp": datetime.now().isoformat()
            })
        else:
            # Data was saved to SQLite offline
            if 'offline_id' in result:
                logger.info(f"Data saved to SQLite for sensor {machine_id} (Record: {result['offline_id']})")
                return jsonify({
                    "status": "stored_offline",
                    "message": f"MySQL at {Config.DB_CONFIG['host']} unavailable, data stored in SQLite",
                    "offline_id": result['offline_id'],
                    "offline_storage": "sqlite",
                    "mysql_host": Config.DB_CONFIG['host'],
                    "timestamp": datetime.now().isoformat()
                }), 202
            else:
                return jsonify({"error": "Failed to store data"}), 500
            
    except Exception as e:
        logger.error(f"Error handling sensor data: {e}")
        return jsonify({"error": "Internal server error"}), 500

@app.route('/api/sensors/register', methods=['POST'])
def handle_sensor_registration():
    """Handle sensor registration via Database Pi API"""
    gateway_stats['requests_received'] += 1
    
    try:
        data = request.json
        if not data:
            return jsonify({"error": "No data provided"}), 400
        
        machine_id = data.get('machine_id')
        if not machine_id:
            return jsonify({"error": "Missing machine_id"}), 400
        
        logger.info(f"Registration request for sensor {machine_id}")
        
        # Try to call Database Pi API
        success, response = call_api('/api/sensors/register', data)
        
        if success:
            logger.info(f"Registration completed for sensor {machine_id} via {Config.DATABASE_PI_API_URL}")
            return jsonify(response), 200
        else:
            # Save to SQLite offline storage
            record_id = offline_storage.save_offline('/api/sensors/register', data, 'api')
            if record_id:
                gateway_stats['stored_offline'] += 1
                logger.info(f"Registration saved to SQLite for sensor {machine_id}")
                return jsonify({
                    "status": "queued",
                    "message": f"API {Config.DATABASE_PI_API_URL} unavailable, registration queued in SQLite",
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
    """Check sensor assignment status via Database Pi API"""
    gateway_stats['requests_received'] += 1
    
    logger.info(f"Assignment check for sensor {machine_id}")
    
    # Try to call Database Pi API
    success, response = call_api(f'/api/sensors/{machine_id}/assignment', None, method='GET')
    
    if success:
        return jsonify(response), 200
    else:
        # For GET requests, try direct Database Pi MySQL check as fallback
        try:
            assignment_info = DatabaseManager.get_sensor_assignment(machine_id)
            if assignment_info:
                return jsonify(assignment_info), 200
            else:
                return jsonify({
                    "error": "Sensor not found",
                    "machine_id": machine_id,
                    "mysql_host": Config.DB_CONFIG['host']
                }), 404
        except Exception as e:
            logger.warning(f"Could not check assignment for {machine_id} from {Config.DB_CONFIG['host']}: {e}")
            return jsonify({
                "error": f"API {Config.DATABASE_PI_API_URL} and MySQL {Config.DB_CONFIG['host']} unavailable",
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
            "offline_synced": gateway_stats['offline_synced'],
            "offline_storage": "sqlite",
            "offline_path": Config.OFFLINE_STORAGE_PATH
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
        },
        "offline_queue": {
            "size": 0,
            "pending_mysql": 0,
            "pending_api": 0
        }
    }
    
    # Get SQLite offline queue stats
    try:
        conn = sqlite3.connect(Config.OFFLINE_STORAGE_PATH)
        cursor = conn.cursor()
        
        # Total records
        cursor.execute('SELECT COUNT(*) FROM offline_queue')
        health_data['offline_queue']['size'] = cursor.fetchone()[0]
        
        # MySQL-bound pending
        cursor.execute('SELECT COUNT(*) FROM offline_queue WHERE destination = "mysql" AND attempts < ?', (Config.MAX_RETRIES,))
        health_data['offline_queue']['pending_mysql'] = cursor.fetchone()[0]
        
        # API-bound pending
        cursor.execute('SELECT COUNT(*) FROM offline_queue WHERE destination = "api" AND attempts < ?', (Config.MAX_RETRIES,))
        health_data['offline_queue']['pending_api'] = cursor.fetchone()[0]
        
        conn.close()
    except:
        pass
    
    return jsonify(health_data)

# ========================
# DATABASE SETUP UTILITY
# ========================
def setup_database_user():
    """Script to create the gateway user in Database Pi MySQL"""
    print("=" * 60)
    print("MySQL Gateway User Setup for Database Pi (192.168.1.100)")
    print("=" * 60)
    print("\nRun these commands on Database Pi (192.168.1.100) in MySQL:")
    print("\n1. Create gateway user:")
    print(f"""
CREATE USER 'gateway_user'@'%' 
IDENTIFIED BY 'gateway_pass';
    """)
    print("\n2. Grant minimal permissions:")
    print(f"""
GRANT INSERT, SELECT ON soilmonitornig.sensor_data 
TO 'gateway_user'@'%';

GRANT SELECT ON soilmonitornig.sensors 
TO 'gateway_user'@'%';

GRANT SELECT ON soilmonitornig.farms 
TO 'gateway_user'@'%';

GRANT SELECT ON soilmonitornig.client 
TO 'gateway_user'@'%';
    """)
    print("\n3. Flush privileges:")
    print("FLUSH PRIVILEGES;")
    print("\n" + "=" * 60)
    print("IMPORTANT: Update gateway.py with these credentials!")
    print("=" * 60)

# ========================
# MAIN APPLICATION
# ========================
def main():
    """Main gateway application entry point"""
    try:
        # Display setup reminder
        print("=" * 60)
        print("🚀 Enhanced Soil Monitoring Gateway Starting")
        print("=" * 60)
        print(f"\n📊 Database Configuration:")
        print(f"   MySQL Host: {Config.DB_CONFIG['host']}")
        print(f"   Database: {Config.DB_CONFIG['database']}")
        print(f"   User: {Config.DB_CONFIG['user']}")
        print(f"\n💾 Local Storage:")
        print(f"   SQLite Offline: {Config.OFFLINE_STORAGE_PATH}")
        print(f"\n🌐 API Endpoint:")
        print(f"   Database Pi API: {Config.DATABASE_PI_API_URL}")
        print("=" * 60)
        
        # Initial health checks
        check_mysql_health()
        check_api_health()
        
        # Start offline queue processor
        queue_processor = Thread(target=process_offline_queue, daemon=True)
        queue_processor.start()
        logger.info("SQLite offline queue processor started")
        
        # Display startup information
        logger.info("=" * 60)
        logger.info("🚀 Soil Monitoring Gateway Starting")
        logger.info(f"   User: gateway")
        logger.info(f"   Host: {Config.GATEWAY_HOST}:{Config.GATEWAY_PORT}")
        logger.info(f"   MySQL: {Config.DB_CONFIG['host']}/{Config.DB_CONFIG['database']}")
        logger.info(f"   API: {Config.DATABASE_PI_API_URL}")
        logger.info(f"   SQLite Offline: {Config.OFFLINE_STORAGE_PATH}")
        logger.info("=" * 60)
        logger.info("📡 Endpoints available:")
        logger.info("   POST /api/sensor-data        - Store sensor data to Database Pi")
        logger.info("   POST /api/sensors/register   - Register sensor (via API)")
        logger.info("   GET  /api/sensors/{id}/assignment - Check assignment")
        logger.info("   GET  /api/health             - Health check")
        logger.info("   GET  /api/test               - Connectivity test")
        logger.info("=" * 60)
        logger.info("💾 Data Flow:")
        logger.info(f"   Sensor Data → Database Pi MySQL ({Config.DB_CONFIG['host']})")
        logger.info("   If unavailable → SQLite offline → Sync when back online")
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
