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
            self.wfile.write(json.dumps({'status': 'healthy', 'service': 'web'}).encode())
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        logger.info(format % args)

class WebProducer:
    def __init__(self):
        self.api_url = os.getenv('API_URL', 'http://3.248.199.26:8000/api/web-traffic/')
        self.stream_name = os.getenv('STREAM_NAME', 'web-stream-dev')
        self.poll_interval = int(os.getenv('POLL_INTERVAL', '30'))
        self.region = os.getenv('AWS_DEFAULT_REGION', 'eu-west-1')
        
        # Initialize AWS client
        self.firehose = boto3.client('firehose', region_name=self.region)
        
        logger.info(f"Web Producer initialized - Stream: {self.stream_name}, API: {self.api_url}")

    def start_health_server(self):
        """Start health check server"""
        server = HTTPServer(('', 8080), HealthHandler)
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        logger.info("Health server started on port 8080")
        return server

    def fetch_data(self) -> Optional[List[Dict]]:
        """Fetch data from Web Traffic API"""
        try:
            response = requests.get(self.api_url, timeout=30)
            response.raise_for_status()
            data = response.json()
            logger.info(f"Fetched {len(data)} records from Web Traffic API")
            return data
        except requests.RequestException as e:
            logger.error(f"API request failed: {e}")
            return None

    def validate_record(self, record: Dict) -> bool:
        """Validate web traffic record"""
        required_fields = ['session_id', 'page', 'timestamp']
        return all(field in record for field in required_fields)

    def process_record(self, record: Dict) -> Dict:
        """Process and enrich a single record"""
        if not self.validate_record(record):
            logger.warning(f"Invalid record: {record}")
            return None
            
        return {
            **record,
            'processed_at': datetime.utcnow().isoformat(),
            'source': 'web-traffic-api',
            'pipeline': 'web-processor'
        }

    def send_to_firehose(self, records: List[Dict]) -> bool:
        """Send records to Kinesis Firehose"""
        try:
            # Process and filter valid records
            processed_records = [
                self.process_record(record) for record in records
            ]
            valid_records = [r for r in processed_records if r is not None]
            
            if not valid_records:
                logger.info("No valid records to send")
                return True
            
            firehose_records = [
                {'Data': json.dumps(record) + '\n'}
                for record in valid_records
            ]
            
            response = self.firehose.put_record_batch(
                DeliveryStreamName=self.stream_name,
                Records=firehose_records
            )
            
            failed_count = response.get('FailedPutCount', 0)
            if failed_count > 0:
                logger.warning(f"Failed to send {failed_count} records")
            
            logger.info(f"Successfully sent {len(valid_records)} records to Firehose")
            return True
            
        except Exception as e:
            logger.error(f"Firehose send failed: {e}")
            return False

    def run_cycle(self):
        """Run one polling cycle"""
        data = self.fetch_data()
        if data:
            self.send_to_firehose(data)

    def run(self):
        """Main run loop"""
        logger.info("Starting Web Producer")
        
        # Start health server
        health_server = self.start_health_server()
        
        # Main processing loop
        try:
            while True:
                self.run_cycle()
                time.sleep(self.poll_interval)
        except KeyboardInterrupt:
            logger.info("Shutting down Web Producer")
        except Exception as e:
            logger.error(f"Unexpected error: {e}")
            raise

if __name__ == "__main__":
    producer = WebProducer()
    producer.run()
