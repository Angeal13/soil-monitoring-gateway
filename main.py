"""
Gateway Pi - Simple Forwarding Gateway
Routes sensor data to Database Pi (appV8.py)
"""
from flask import Flask, request, jsonify
import requests
import logging
import time
import sqlite3
import json
from datetime import datetime
from threading import Thread
from queue import Queue
import os

# ========================
# CONFIGURATION
# ========================
class Config:
    # Gateway settings
    GATEWAY_HOST = '0.0.0.0'
    GATEWAY_PORT = 5000  # MUST be 5000 (sensors expect this)
    
    # Database Pi (appV8.py) - UPDATE THIS!
    DATABASE_PI_URL = "http://192.168.1.76:5000"
    
    # Local offline storage
    OFFLINE_STORAGE_PATH = '/home/pi/gateway_data/offline_queue.db'
    MAX_OFFLINE_RECORDS = 10000
    
    # Forwarding settings
    FORWARD_TIMEOUT = 10  # seconds
    MAX_RETRIES = 3
    RETRY_DELAY = 5  # seconds
    
    # Health check interval (seconds)
    HEALTH_CHECK_INTERVAL = 300  # 5 minutes
    
    # Batch processing
    BATCH_SIZE = 50
    BATCH_INTERVAL = 60  # Process offline data every 60 seconds

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
    'forwarded_success': 0,
    'forwarded_failed': 0,
    'stored_offline': 0,
    'offline_synced': 0,
    'last_database_check': None,
    'database_available': False
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
        
        # Create offline queue table
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS offline_queue (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                endpoint TEXT NOT NULL,
                data TEXT NOT NULL,
                timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
                attempts INTEGER DEFAULT 0,
                last_attempt DATETIME
            )
        ''')
        
        # Create stats table
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS gateway_stats (
                key TEXT PRIMARY KEY,
                value TEXT,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
        ''')
        
        conn.commit()
        conn.close()
        logger.info(f"Offline storage initialized: {self.db_path}")
    
    def save_offline(self, endpoint, data):
        """Save request to offline queue"""
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        
        try:
            cursor.execute('''
                INSERT INTO offline_queue (endpoint, data)
                VALUES (?, ?)
            ''', (endpoint, json.dumps(data)))
            
            conn.commit()
            record_id = cursor.lastrowid
            
            # Check queue size
            cursor.execute('SELECT COUNT(*) FROM offline_queue')
            count = cursor.fetchone()[0]
            
            if count > Config.MAX_OFFLINE_RECORDS:
                # Remove oldest records
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
            
            logger.info(f"Saved to offline queue: {endpoint} (ID: {record_id})")
            return record_id
            
        except Exception as e:
            logger.error(f"Failed to save offline: {e}")
            return None
        finally:
            conn.close()
    
    def get_pending_records(self, limit=50):
        """Get pending records for retry"""
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        cursor = conn.cursor()
        
        cursor.execute('''
            SELECT * FROM offline_queue 
            WHERE attempts < ?
            ORDER BY timestamp ASC 
            LIMIT ?
        ''', (Config.MAX_RETRIES, limit))
        
        records = cursor.fetchall()
        conn.close()
        
        return records
    
    def update_attempt(self, record_id, success):
        """Update record after attempt"""
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        
        if success:
            # Delete successful record
            cursor.execute('DELETE FROM offline_queue WHERE id = ?', (record_id,))
            logger.info(f"Removed synced record: {record_id}")
        else:
            # Increment attempt count
            cursor.execute('''
                UPDATE offline_queue 
                SET attempts = attempts + 1, 
                    last_attempt = CURRENT_TIMESTAMP
                WHERE id = ?
            ''', (record_id,))
            
            # Get new attempt count
            cursor.execute('SELECT attempts FROM offline_queue WHERE id = ?', (record_id,))
            attempts = cursor.fetchone()[0]
            
            if attempts >= Config.MAX_RETRIES:
                logger.warning(f"Record {record_id} exceeded max retries, keeping for manual review")
        
        conn.commit()
        conn.close()
    
    def get_queue_stats(self):
        """Get offline queue statistics"""
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        
        cursor.execute('''
            SELECT 
                COUNT(*) as total,
                COUNT(CASE WHEN attempts = 0 THEN 1 END) as pending,
                COUNT(CASE WHEN attempts >= ? THEN 1 END) as failed
            FROM offline_queue
        ''', (Config.MAX_RETRIES,))
        
        stats = cursor.fetchone()
        conn.close()
        
        return {
            'total': stats[0],
            'pending': stats[1],
            'failed': stats[2]
        }

# Initialize offline storage
offline_storage = OfflineStorage(Config.OFFLINE_STORAGE_PATH)

# ========================
# DATABASE HEALTH CHECK
# ========================
def check_database_health():
    """Check if Database Pi is reachable"""
    try:
        response = requests.get(
            f"{Config.DATABASE_PI_URL}/api/test",
            timeout=5
        )
        gateway_stats['database_available'] = (response.status_code == 200)
        gateway_stats['last_database_check'] = datetime.now()
        
        if gateway_stats['database_available']:
            logger.info("✅ Database Pi is reachable")
        else:
            logger.warning(f"Database Pi returned status {response.status_code}")
            
        return gateway_stats['database_available']
        
    except Exception as e:
        gateway_stats['database_available'] = False
        gateway_stats['last_database_check'] = datetime.now()
        logger.warning(f"Database Pi not reachable: {e}")
        return False

# ========================
# FORWARDING FUNCTIONS
# ========================
def forward_to_database(endpoint, data, method='POST'):
    """Forward request to Database Pi"""
    url = f"{Config.DATABASE_PI_URL}{endpoint}"
    
    for attempt in range(Config.MAX_RETRIES):
        try:
            if method == 'POST':
                response = requests.post(url, json=data, timeout=Config.FORWARD_TIMEOUT)
            else:  # GET
                response = requests.get(url, timeout=Config.FORWARD_TIMEOUT)
            
            # Log the response for debugging
            logger.debug(f"Forward {endpoint}: Status {response.status_code}")
            
            if response.status_code in [200, 201]:
                gateway_stats['forwarded_success'] += 1
                return True, response.json()
            else:
                logger.warning(f"Forward {endpoint} failed: Status {response.status_code}")
                time.sleep(Config.RETRY_DELAY)
                
        except Exception as e:
            logger.warning(f"Forward attempt {attempt + 1} failed: {e}")
            if attempt < Config.MAX_RETRIES - 1:
                time.sleep(Config.RETRY_DELAY)
    
    gateway_stats['forwarded_failed'] += 1
    return False, None

def process_offline_queue():
    """Process offline queue in background"""
    while True:
        try:
            time.sleep(Config.BATCH_INTERVAL)
            
            # Check database health first
            if not check_database_health():
                logger.info("Database unavailable, skipping offline sync")
                continue
            
            # Get pending records
            records = offline_storage.get_pending_records(Config.BATCH_SIZE)
            
            if not records:
                continue
            
            logger.info(f"Processing {len(records)} offline records")
            synced_count = 0
            
            for record in records:
                record_id = record['id']
                endpoint = record['endpoint']
                data = json.loads(record['data'])
                
                success, _ = forward_to_database(endpoint, data)
                offline_storage.update_attempt(record_id, success)
                
                if success:
                    synced_count += 1
                    gateway_stats['offline_synced'] += 1
            
            if synced_count > 0:
                logger.info(f"Synced {synced_count} offline records to Database Pi")
            
        except Exception as e:
            logger.error(f"Error processing offline queue: {e}")
            time.sleep(60)

# ========================
# API ENDPOINTS
# ========================

@app.route('/api/test', methods=['GET'])
def test_gateway():
    """Test gateway connectivity"""
    db_status = "unknown"
    try:
        response = requests.get(f"{Config.DATABASE_PI_URL}/api/test", timeout=5)
        db_status = "connected" if response.status_code == 200 else f"error_{response.status_code}"
    except:
        db_status = "disconnected"
    
    return jsonify({
        "gateway": "online",
        "timestamp": datetime.now().isoformat(),
        "database_pi": db_status,
        "database_url": Config.DATABASE_PI_URL
    })

@app.route('/api/sensor-data', methods=['POST'])
def handle_sensor_data():
    """Receive sensor data and forward to Database Pi"""
    gateway_stats['requests_received'] += 1
    
    try:
        data = request.json
        if not data:
            return jsonify({"error": "No data provided"}), 400
        
        machine_id = data.get('machine_id')
        if not machine_id:
            return jsonify({"error": "Missing machine_id"}), 400
        
        logger.info(f"Received data from sensor {machine_id}")
        
        # Try to forward immediately
        success, response = forward_to_database('/api/sensor-data', data)
        
        if success:
            logger.info(f"Data forwarded for sensor {machine_id}")
            return jsonify({
                "status": "forwarded",
                "message": "Data forwarded to Database Pi",
                "timestamp": datetime.now().isoformat()
            })
        else:
            # Save to offline storage
            record_id = offline_storage.save_offline('/api/sensor-data', data)
            if record_id:
                gateway_stats['stored_offline'] += 1
                logger.info(f"Data saved offline for sensor {machine_id} (Record: {record_id})")
                return jsonify({
                    "status": "stored_offline",
                    "message": "Database Pi unavailable, data stored locally",
                    "offline_id": record_id,
                    "timestamp": datetime.now().isoformat()
                }), 202
            else:
                return jsonify({"error": "Failed to store data"}), 500
            
    except Exception as e:
        logger.error(f"Error handling sensor data: {e}")
        return jsonify({"error": "Internal server error"}), 500

@app.route('/api/sensors/register', methods=['POST'])
def handle_sensor_registration():
    """Handle sensor registration"""
    gateway_stats['requests_received'] += 1
    
    try:
        data = request.json
        if not data:
            return jsonify({"error": "No data provided"}), 400
        
        machine_id = data.get('machine_id')
        if not machine_id:
            return jsonify({"error": "Missing machine_id"}), 400
        
        logger.info(f"Registration request for sensor {machine_id}")
        
        # Try to forward immediately
        success, response = forward_to_database('/api/sensors/register', data)
        
        if success:
            logger.info(f"Registration forwarded for sensor {machine_id}")
            return jsonify(response), 200
        else:
            # Save to offline storage
            record_id = offline_storage.save_offline('/api/sensors/register', data)
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
    """Check sensor assignment status"""
    gateway_stats['requests_received'] += 1
    
    logger.info(f"Assignment check for sensor {machine_id}")
    
    # Try to forward immediately
    success, response = forward_to_database(f'/api/sensors/{machine_id}/assignment', None, method='GET')
    
    if success:
        return jsonify(response), 200
    else:
        # For GET requests, we can't queue them - just return cached/error response
        logger.warning(f"Could not check assignment for {machine_id}, Database Pi unavailable")
        return jsonify({
            "error": "Database Pi unavailable",
            "machine_id": machine_id,
            "suggestion": "Retry later or check gateway status"
        }), 503

@app.route('/api/health', methods=['GET'])
def health_check():
    """Comprehensive health check"""
    queue_stats = offline_storage.get_queue_stats()
    uptime = datetime.now() - gateway_stats['start_time']
    
    # Check database health
    db_healthy = check_database_health()
    
    health_data = {
        "gateway": {
            "status": "healthy",
            "uptime_seconds": int(uptime.total_seconds()),
            "start_time": gateway_stats['start_time'].isoformat(),
            "requests_received": gateway_stats['requests_received'],
            "forwarded_success": gateway_stats['forwarded_success'],
            "forwarded_failed": gateway_stats['forwarded_failed'],
            "stored_offline": gateway_stats['stored_offline'],
            "offline_synced": gateway_stats['offline_synced']
        },
        "database_pi": {
            "url": Config.DATABASE_PI_URL,
            "available": db_healthy,
            "last_check": gateway_stats['last_database_check'].isoformat() if gateway_stats['last_database_check'] else None
        },
        "offline_storage": {
            "path": Config.OFFLINE_STORAGE_PATH,
            "total_records": queue_stats['total'],
            "pending_records": queue_stats['pending'],
            "failed_records": queue_stats['failed'],
            "max_records": Config.MAX_OFFLINE_RECORDS
        }
    }
    
    return jsonify(health_data)

@app.route('/api/stats', methods=['GET'])
def get_gateway_stats():
    """Get gateway statistics"""
    queue_stats = offline_storage.get_queue_stats()
    
    stats = gateway_stats.copy()
    stats['uptime'] = str(datetime.now() - stats['start_time'])
    stats['offline_queue'] = queue_stats
    stats['database_pi_url'] = Config.DATABASE_PI_URL
    stats['database_available'] = gateway_stats['database_available']
    
    return jsonify(stats)

@app.route('/api/debug/queue', methods=['GET'])
def debug_queue():
    """Debug endpoint to view offline queue (limited)"""
    limit = request.args.get('limit', 10, type=int)
    
    conn = sqlite3.connect(Config.OFFLINE_STORAGE_PATH)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    
    cursor.execute('''
        SELECT id, endpoint, timestamp, attempts, last_attempt
        FROM offline_queue 
        ORDER BY timestamp ASC 
        LIMIT ?
    ''', (limit,))
    
    records = [dict(row) for row in cursor.fetchall()]
    conn.close()
    
    return jsonify({
        "count": len(records),
        "records": records,
        "queue_stats": offline_storage.get_queue_stats()
    })

# ========================
# MAIN APPLICATION
# ========================
def main():
    """Main gateway application entry point"""
    try:
        # Initial database health check
        check_database_health()
        
        # Start offline queue processor
        queue_processor = Thread(target=process_offline_queue, daemon=True)
        queue_processor.start()
        logger.info("Offline queue processor started")
        
        # Display startup information
        logger.info("=" * 60)
        logger.info("🚀 IoT Gateway Starting")
        logger.info(f"   Host: {Config.GATEWAY_HOST}:{Config.GATEWAY_PORT}")
        logger.info(f"   Database Pi: {Config.DATABASE_PI_URL}")
        logger.info(f"   Offline Storage: {Config.OFFLINE_STORAGE_PATH}")
        logger.info("=" * 60)
        logger.info("📡 Endpoints available:")
        logger.info("   POST /api/sensor-data        - Receive sensor data")
        logger.info("   POST /api/sensors/register   - Register sensor")
        logger.info("   GET  /api/sensors/{id}/assignment - Check assignment")
        logger.info("   GET  /api/health             - Health check")
        logger.info("   GET  /api/stats              - Gateway statistics")
        logger.info("   GET  /api/test               - Connectivity test")
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
