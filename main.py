# Gateway main.py - Simplified version
from flask import Flask, request, jsonify
import mysql.connector
import threading
import time
import logging
from datetime import datetime, timedelta
from queue import Queue, Empty

# ========================
# CONFIGURATION (Simplified)
# ========================
HOST = '0.0.0.0'
PORT = 5001
DEBUG = False
LOG_LEVEL = "INFO"
BATCH_PROCESS_INTERVAL = 60  # Process data every 60 seconds
MAX_BUFFER_SIZE = 1000

# PI Database configuration
PI_DB_CONFIG = {
    'user': 'DevOps',
    'password': 'DevTeam',
    'host': '192.168.1.76',
    'database': 'soilmonitornig',
    'raise_on_warnings': True
}

# ========================
# APPLICATION SETUP
# ========================

app = Flask(__name__)
data_queue = Queue()

gateway_stats = {
    'start_time': datetime.now(),
    'sensors_registered': 0,
    'data_received': 0,
    'data_stored': 0,
    'errors': 0,
    'last_sync': None
}

# Setup logging
logging.basicConfig(
    level=LOG_LEVEL,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('gateway.log'),
        logging.StreamHandler()
    ]
)

logger = logging.getLogger(__name__)

# ========================
# DATABASE FUNCTIONS
# ========================

def get_db_connection():
    """Create connection to PI MySQL database"""
    try:
        cnx = mysql.connector.connect(**PI_DB_CONFIG)
        return cnx
    except mysql.connector.Error as e:
        logger.error(f"Database connection failed: {e}")
        return None

def init_database():
    """Initialize database tables if they don't exist"""
    cnx = get_db_connection()
    if not cnx:
        logger.error("Failed to connect to database")
        return False
        
    try:
        cur = cnx.cursor()
        
        # Create sensor metadata table
        cur.execute("""
            CREATE TABLE IF NOT EXISTS sensors (
                machine_id VARCHAR(255) PRIMARY KEY,
                sensor_name VARCHAR(255),
                sensor_type VARCHAR(100),
                client_name VARCHAR(255),
                farm_name VARCHAR(255),
                zone_code VARCHAR(50),
                latitude DECIMAL(10, 8),
                longitude DECIMAL(11, 8),
                installation_date DATE,
                last_seen TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                is_active BOOLEAN DEFAULT TRUE,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """)
        
        # Create sensor readings table
        cur.execute("""
            CREATE TABLE IF NOT EXISTS sensor_readings (
                id INT AUTO_INCREMENT PRIMARY KEY,
                machine_id VARCHAR(255),
                timestamp DATETIME,
                moisture DECIMAL(5, 2),
                temperature DECIMAL(5, 2),
                ph_level DECIMAL(4, 2),
                nitrogen DECIMAL(5, 2),
                phosphorus DECIMAL(5, 2),
                potassium DECIMAL(5, 2),
                battery_level DECIMAL(4, 1),
                signal_strength INT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                INDEX idx_machine_id (machine_id),
                INDEX idx_timestamp (timestamp)
            )
        """)
        
        cnx.commit()
        logger.info("Database initialized successfully")
        return True
        
    except mysql.connector.Error as e:
        logger.error(f"Database initialization failed: {e}")
        return False
    finally:
        if 'cur' in locals():
            cur.close()
        cnx.close()

def store_sensor_data(sensor_data):
    """Store sensor data in database"""
    cnx = get_db_connection()
    if not cnx:
        logger.error("Cannot store data: Database connection failed")
        return False
    
    try:
        cur = cnx.cursor()
        
        machine_id = sensor_data.get('machine_id')
        timestamp = sensor_data.get('timestamp', datetime.now())
        
        # Handle timestamp format
        if isinstance(timestamp, str):
            try:
                timestamp = datetime.fromisoformat(timestamp.replace('Z', '+00:00'))
            except:
                timestamp = datetime.now()
        
        # Update sensor last seen
        cur.execute("""
            INSERT INTO sensors (machine_id, last_seen, is_active)
            VALUES (%s, %s, TRUE)
            ON DUPLICATE KEY UPDATE 
            last_seen = VALUES(last_seen),
            is_active = TRUE
        """, (machine_id, timestamp))
        
        # Insert sensor reading
        query = """
            INSERT INTO sensor_readings (
                machine_id, timestamp, moisture, temperature, ph_level, 
                nitrogen, phosphorus, potassium, battery_level, signal_strength
            ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        """
        
        values = (
            machine_id,
            timestamp,
            sensor_data.get('moisture'),
            sensor_data.get('temperature'),
            sensor_data.get('ph_level'),
            sensor_data.get('nitrogen'),
            sensor_data.get('phosphorus'),
            sensor_data.get('potassium'),
            sensor_data.get('battery_level'),
            sensor_data.get('signal_strength')
        )
        
        cur.execute(query, values)
        cnx.commit()
        
        gateway_stats['data_stored'] += 1
        logger.info(f"Data stored for sensor {machine_id}")
        return True
        
    except mysql.connector.Error as e:
        logger.error(f"Failed to store sensor data: {e}")
        cnx.rollback()
        return False
    finally:
        if 'cur' in locals():
            cur.close()
        cnx.close()

def store_immediately(sensor_data):
    """Store data immediately (for real-time processing)"""
    return store_sensor_data(sensor_data)

# ========================
# BACKGROUND WORKER
# ========================

def batch_data_worker():
    """Background worker for batch processing"""
    while True:
        try:
            time.sleep(BATCH_PROCESS_INTERVAL)
            
            # Process data queue
            processed_count = 0
            failed_data = []
            
            while not data_queue.empty() and processed_count < MAX_BUFFER_SIZE:
                try:
                    data = data_queue.get_nowait()
                    
                    if store_sensor_data(data):
                        processed_count += 1
                    else:
                        failed_data.append(data)
                    
                    data_queue.task_done()
                    
                except Empty:
                    break
                except Exception as e:
                    logger.error(f"Error processing queued data: {e}")
            
            # Put failed data back in queue
            for data in failed_data:
                data_queue.put(data)
            
            if processed_count > 0:
                logger.info(f"Batch processed {processed_count} records")
            
            gateway_stats['last_sync'] = datetime.now()
            
        except Exception as e:
            logger.error(f"Batch data worker error: {e}")
            time.sleep(60)

# ========================
# API ENDPOINTS
# ========================

@app.route('/api/health', methods=['GET'])
def health_check():
    """Gateway health check endpoint"""
    uptime = datetime.now() - gateway_stats['start_time']
    
    cnx = get_db_connection()
    sensor_count = 0
    reading_count = 0
    
    if cnx:
        try:
            cur = cnx.cursor()
            cur.execute("SELECT COUNT(*) FROM sensors WHERE is_active = TRUE")
            sensor_count = cur.fetchone()[0]
            cur.close()
        except:
            pass
        cnx.close()
    
    return jsonify({
        "status": "healthy",
        "uptime_seconds": int(uptime.total_seconds()),
        "data_received": gateway_stats['data_received'],
        "data_stored": gateway_stats['data_stored'],
        "errors": gateway_stats['errors'],
        "queue_size": data_queue.qsize(),
        "active_sensors": sensor_count,
        "database": "connected" if sensor_count >= 0 else "disconnected"
    })

@app.route('/api/sensor-data', methods=['POST'])
def receive_sensor_data():
    """Receive sensor data from IoT devices"""
    try:
        data = request.json
        if not data:
            return jsonify({"error": "No data provided"}), 400
        
        machine_id = data.get('machine_id')
        if not machine_id:
            return jsonify({"error": "Missing machine_id"}), 400
        
        gateway_stats['data_received'] += 1
        
        # Validate required fields
        if 'moisture' not in data or 'temperature' not in data:
            return jsonify({"error": "Missing required sensor readings"}), 400
        
        # Option 1: Store immediately (simpler)
        if store_immediately(data):
            return jsonify({
                "status": "stored",
                "message": "Data stored successfully",
                "timestamp": datetime.now().isoformat()
            })
        else:
            # Option 2: Queue for later processing
            data_queue.put(data)
            return jsonify({
                "status": "queued",
                "message": "Data queued for processing",
                "queue_position": data_queue.qsize()
            })
        
    except Exception as e:
        gateway_stats['errors'] += 1
        logger.error(f"Error processing sensor data: {e}")
        return jsonify({"error": "Internal server error"}), 500

@app.route('/api/sensors/register', methods=['POST'])
def register_sensor():
    """Register a new sensor"""
    try:
        sensor_info = request.json
        machine_id = sensor_info.get('machine_id')
        
        if not machine_id:
            return jsonify({"error": "Missing machine_id"}), 400
        
        cnx = get_db_connection()
        if not cnx:
            return jsonify({"error": "Database unavailable"}), 503
        
        try:
            cur = cnx.cursor()
            
            # Check if sensor already exists
            cur.execute("SELECT machine_id FROM sensors WHERE machine_id = %s", (machine_id,))
            if cur.fetchone():
                return jsonify({
                    "status": "already_registered",
                    "message": "Sensor already registered"
                }), 200
            
            # Register new sensor
            query = """
                INSERT INTO sensors (
                    machine_id, sensor_name, sensor_type, client_name, 
                    farm_name, zone_code, installation_date
                ) VALUES (%s, %s, %s, %s, %s, %s, %s)
            """
            
            values = (
                machine_id,
                sensor_info.get('sensor_name', f"Sensor_{machine_id[-6:]}"),
                sensor_info.get('sensor_type', 'soil_sensor'),
                sensor_info.get('client_name', 'Default'),
                sensor_info.get('farm_name', 'Default Farm'),
                sensor_info.get('zone_code', 'A1'),
                sensor_info.get('installation_date', datetime.now().date())
            )
            
            cur.execute(query, values)
            cnx.commit()
            
            gateway_stats['sensors_registered'] += 1
            
            return jsonify({
                "status": "registered",
                "machine_id": machine_id,
                "message": "Sensor registered successfully"
            })
            
        except mysql.connector.Error as e:
            logger.error(f"Sensor registration failed: {e}")
            return jsonify({"error": "Registration failed"}), 500
        finally:
            if 'cur' in locals():
                cur.close()
            cnx.close()
            
    except Exception as e:
        logger.error(f"Error in sensor registration: {e}")
        return jsonify({"error": "Internal server error"}), 500

@app.route('/api/stats', methods=['GET'])
def get_stats():
    """Get gateway statistics"""
    stats = gateway_stats.copy()
    stats['uptime_seconds'] = int((datetime.now() - stats['start_time']).total_seconds())
    stats['queue_size'] = data_queue.qsize()
    return jsonify(stats)

# ========================
# MAIN APPLICATION
# ========================

def main():
    """Main gateway application entry point"""
    try:
        # Initialize database
        if not init_database():
            logger.error("Failed to initialize database")
            return
        
        # Start background worker (optional)
        worker_thread = threading.Thread(target=batch_data_worker, daemon=True)
        worker_thread.start()
        
        logger.info(f"🚀 Gateway starting on {HOST}:{PORT}")
        logger.info(f"Database: {PI_DB_CONFIG['host']}/{PI_DB_CONFIG['database']}")
        
        # Start Flask application
        app.run(
            host=HOST,
            port=PORT,
            debug=DEBUG,
            threaded=True
        )
        
    except Exception as e:
        logger.error(f"Gateway startup failed: {e}")
        raise

if __name__ == '__main__':
    main()