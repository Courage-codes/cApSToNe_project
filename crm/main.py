import os
import json
import time
import logging
import requests
import boto3
from datetime import datetime
from threading import Thread
from http.server import HTTPServer, BaseHTTPRequestHandler
from typing import Dict, List, Optional

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

class HealthHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            response = {
                'status': 'healthy',
                'service': 'crm-producer',
                'timestamp': datetime.utcnow().isoformat(),
                'version': '1.0'
            }
            self.wfile.write(json.dumps(response).encode())
            logger.info("Health check requested - returning healthy status")
        else:
            self.send_response(404)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'error': 'Not found'}).encode())

    def log_message(self, format, *args):
        # Suppress default HTTP server logs to reduce noise
        pass

class CRMProducer:
    def __init__(self):
        self.api_url = os.getenv('API_URL', 'http://3.248.199.26:8000/api/customer-interaction/')
        self.stream_name = os.getenv('STREAM_NAME', 'crm-stream-dev')
        self.poll_interval = int(os.getenv('POLL_INTERVAL', '30'))
        self.region = os.getenv('AWS_DEFAULT_REGION', 'eu-west-1')
        
        # Initialize AWS client
        try:
            self.firehose = boto3.client('firehose', region_name=self.region)
            logger.info(f"Successfully initialized Firehose client for region: {self.region}")
        except Exception as e:
            logger.error(f"Failed to initialize Firehose client: {e}")
            raise
        
        logger.info(f"CRM Producer initialized - Stream: {self.stream_name}, API: {self.api_url}")

    def start_health_server(self):
        """Start health check server on port 8080"""
        try:
            server = HTTPServer(('0.0.0.0', 8080), HealthHandler)
            thread = Thread(target=server.serve_forever, daemon=True)
            thread.start()
            logger.info("Health check server started successfully on port 8080")
            
            # Test the health endpoint immediately
            time.sleep(1)  # Give server a moment to start
            try:
                import urllib.request
                response = urllib.request.urlopen('http://localhost:8080/health', timeout=5)
                if response.getcode() == 200:
                    logger.info("Health endpoint verified - responding correctly")
                else:
                    logger.warning(f"Health endpoint returned status: {response.getcode()}")
            except Exception as e:
                logger.warning(f"Could not verify health endpoint: {e}")
            
            return server
        except Exception as e:
            logger.error(f"Failed to start health server: {e}")
            raise

    def fetch_data(self) -> Optional[List[Dict]]:
        """Fetch data from CRM API"""
        try:
            logger.info(f"Polling CRM API: {self.api_url}")
            response = requests.get(self.api_url, timeout=30)
            response.raise_for_status()
            data = response.json()
            logger.info(f"Successfully fetched {len(data)} records from CRM API")
            return data
        except requests.RequestException as e:
            logger.error(f"API request failed: {e}")
            return None
        except Exception as e:
            logger.error(f"Unexpected error fetching data: {e}")
            return None

    def process_record(self, record: Dict) -> Dict:
        """Process and enrich a single record"""
        return {
            **record,
            'processed_at': datetime.utcnow().isoformat(),
            'source': 'crm-api',
            'pipeline': 'crm-processor',
            'region': self.region
        }

    def send_to_firehose(self, records: List[Dict]) -> bool:
        """Send records to Kinesis Firehose"""
        try:
            if not records:
                logger.info("No records to send to Firehose")
                return True
                
            firehose_records = [
                {'Data': json.dumps(self.process_record(record)) + '\n'}
                for record in records
            ]
            
            logger.info(f"Sending {len(firehose_records)} records to Firehose stream: {self.stream_name}")
            response = self.firehose.put_record_batch(
                DeliveryStreamName=self.stream_name,
                Records=firehose_records
            )
            
            failed_count = response.get('FailedPutCount', 0)
            if failed_count > 0:
                logger.warning(f"Failed to send {failed_count} records to Firehose")
                return False
            
            logger.info(f"Successfully sent {len(records)} records to Firehose")
            return True
            
        except Exception as e:
            logger.error(f"Firehose send failed: {e}")
            return False

    def run_cycle(self):
        """Run one polling cycle"""
        try:
            data = self.fetch_data()
            if data:
                success = self.send_to_firehose(data)
                if success:
                    logger.info("Polling cycle completed successfully")
                else:
                    logger.error("Polling cycle failed during Firehose send")
            else:
                logger.info("No data available in this polling cycle")
        except Exception as e:
            logger.error(f"Error in polling cycle: {e}")

    def run(self):
        """Main run loop"""
        logger.info("Starting CRM Producer")
        
        # Start health check server first
        try:
            health_server = self.start_health_server()
            logger.info("Health server started successfully")
        except Exception as e:
            logger.error(f"Failed to start health server: {e}")
            return
        
        # Give the health server time to fully initialize
        time.sleep(2)
        
        # Main processing loop
        try:
            logger.info(f"Starting main polling loop with {self.poll_interval}s interval")
            cycle_count = 0
            while True:
                cycle_count += 1
                logger.info(f"Starting polling cycle #{cycle_count}")
                self.run_cycle()
                logger.info(f"Completed polling cycle #{cycle_count}, sleeping for {self.poll_interval}s")
                time.sleep(self.poll_interval)
        except KeyboardInterrupt:
            logger.info("Received interrupt signal, shutting down CRM Producer")
        except Exception as e:
            logger.error(f"Unexpected error in main loop: {e}")
            raise

if __name__ == "__main__":
    try:
        producer = CRMProducer()
        producer.run()
    except Exception as e:
        logger.error(f"Fatal error starting CRM Producer: {e}")
        exit(1)
