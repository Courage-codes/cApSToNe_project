import json
import time
import boto3
import requests
from datetime import datetime
import logging
import os
import sys
from threading import Thread
from http.server import HTTPServer, BaseHTTPRequestHandler
import signal

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger(__name__)

class HealthCheckHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'OK')
        else:
            self.send_response(404)
            self.end_headers()

class CRMInteractionProducer:
    def __init__(self):
        self.api_url = os.getenv('CRM_API_URL', 'http://3.248.199.26:8000/api/customer-interaction/')
        self.firehose_stream_name = os.getenv('FIREHOSE_STREAM_NAME')
        self.poll_interval = int(os.getenv('POLL_INTERVAL', '30'))
        self.max_retries = int(os.getenv('MAX_RETRIES', '3'))
        self.retry_delay = int(os.getenv('RETRY_DELAY', '60'))
        self.batch_size = int(os.getenv('BATCH_SIZE', '100'))
        
        # Initialize AWS clients
        self.firehose_client = boto3.client('firehose')
        
        # Application state
        self.running = True
        self.last_poll_time = None
        self.total_records_processed = 0
        self.last_error = None
        
        # Validate configuration
        if not self.firehose_stream_name:
            raise ValueError("FIREHOSE_STREAM_NAME environment variable is required")
        
        logger.info(f"Initialized CRM Producer with stream: {self.firehose_stream_name}")
        logger.info(f"API URL: {self.api_url}")
        logger.info(f"Poll interval: {self.poll_interval} seconds")
    
    def poll_api(self):
        """Poll the CRM API for new interactions"""
        try:
            logger.debug(f"Polling API: {self.api_url}")
            
            response = requests.get(
                self.api_url,
                timeout=30,
                headers={'User-Agent': 'CRM-Producer/1.0'}
            )
            response.raise_for_status()
            
            data = response.json()
            self.last_poll_time = datetime.utcnow()
            
            # Handle both single record and list of records
            if isinstance(data, dict):
                data = [data]
            elif not isinstance(data, list):
                logger.warning(f"Unexpected data format: {type(data)}")
                return []
            
            logger.info(f"Polled API successfully, retrieved {len(data)} records")
            return data
            
        except requests.exceptions.Timeout:
            logger.error("API request timed out")
            self.last_error = "API timeout"
            return None
        except requests.exceptions.RequestException as e:
            logger.error(f"API polling failed: {e}")
            self.last_error = str(e)
            return None
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse API response: {e}")
            self.last_error = "JSON decode error"
            return None
        except Exception as e:
            logger.error(f"Unexpected error during API polling: {e}")
            self.last_error = str(e)
            return None
    
    def validate_record(self, record):
        """Validate a single record"""
        if not isinstance(record, dict):
            return False
        
        required_fields = ['customer_id', 'interaction_type', 'timestamp']
        for field in required_fields:
            if field not in record:
                logger.warning(f"Record missing required field: {field}")
                return False
        
        # Validate data types
        if not isinstance(record['customer_id'], int):
            logger.warning(f"Invalid customer_id type: {type(record['customer_id'])}")
            return False
        
        if not isinstance(record['interaction_type'], str):
            logger.warning(f"Invalid interaction_type type: {type(record['interaction_type'])}")
            return False
        
        return True
    
    def enrich_record(self, record):
        """Enrich a record with additional metadata"""
        enriched = record.copy()
        
        # Add processing metadata
        enriched['processed_at'] = datetime.utcnow().isoformat()
        enriched['processor_version'] = '1.0'
        
        # Add data quality score
        quality_score = 1.0
        if 'rating' not in record:
            quality_score -= 0.2
        if 'message_excerpt' not in record:
            quality_score -= 0.1
        if 'channel' not in record:
            quality_score -= 0.1
        
        enriched['data_quality_score'] = quality_score
        
        # Normalize timestamp if needed
        if isinstance(record.get('timestamp'), (int, float)):
            enriched['timestamp_iso'] = datetime.fromtimestamp(record['timestamp']).isoformat()
        
        return enriched
    
    def send_to_firehose(self, records):
        """Send records to Kinesis Firehose"""
        if not records:
            return True
        
        # Validate and enrich records
        valid_records = []
        for record in records:
            if self.validate_record(record):
                enriched = self.enrich_record(record)
                valid_records.append(enriched)
            else:
                logger.warning(f"Skipping invalid record: {record}")
        
        if not valid_records:
            logger.warning("No valid records to send")
            return True
        
        # Process in batches
        for i in range(0, len(valid_records), self.batch_size):
            batch = valid_records[i:i + self.batch_size]
            if not self._send_batch_to_firehose(batch):
                return False
        
        return True
    
    def _send_batch_to_firehose(self, batch):
        """Send a batch of records to Firehose"""
        try:
            # Prepare records for Firehose
            firehose_records = []
            for record in batch:
                firehose_records.append({
                    'Data': json.dumps(record, default=str) + '\n'
                })
            
            # Send to Firehose
            response = self.firehose_client.put_record_batch(
                DeliveryStreamName=self.firehose_stream_name,
                Records=firehose_records
            )
            
            # Check for failures
            failed_count = response.get('FailedPutCount', 0)
            if failed_count > 0:
                logger.error(f"Failed to send {failed_count} out of {len(batch)} records")
                
                # Log details about failures
                for i, record_result in enumerate(response.get('RequestResponses', [])):
                    if 'ErrorCode' in record_result:
                        logger.error(f"Record {i} failed: {record_result['ErrorCode']} - {record_result.get('ErrorMessage', '')}")
                
                return False
            else:
                logger.info(f"Successfully sent {len(batch)} records to Firehose")
                self.total_records_processed += len(batch)
                return True
                
        except Exception as e:
            logger.error(f"Firehose delivery failed: {e}")
            self.last_error = str(e)
            return False
    
    def run_with_retries(self):
        """Run the polling loop with retry logic"""
        consecutive_failures = 0
        
        while self.running:
            try:
                # Poll the API
                records = self.poll_api()
                
                if records is not None:
                    # Send to Firehose
                    if self.send_to_firehose(records):
                        consecutive_failures = 0
                        self.last_error = None
                    else:
                        consecutive_failures += 1
                        logger.warning(f"Firehose delivery failed, consecutive failures: {consecutive_failures}")
                else:
                    consecutive_failures += 1
                    logger.warning(f"API polling failed, consecutive failures: {consecutive_failures}")
                
                # Handle too many consecutive failures
                if consecutive_failures >= self.max_retries:
                    logger.error(f"Too many consecutive failures ({consecutive_failures}), waiting {self.retry_delay} seconds")
                    time.sleep(self.retry_delay)
                    consecutive_failures = 0
                else:
                    # Normal polling interval
                    time.sleep(self.poll_interval)
                
            except KeyboardInterrupt:
                logger.info("Received interrupt signal, shutting down...")
                self.running = False
                break
            except Exception as e:
                logger.error(f"Unexpected error in main loop: {e}")
                consecutive_failures += 1
                time.sleep(self.retry_delay)
    
    def start_health_check_server(self):
        """Start HTTP server for health checks"""
        try:
            server = HTTPServer(('', 8080), HealthCheckHandler)
            server_thread = Thread(target=server.serve_forever, daemon=True)
            server_thread.start()
            logger.info("Health check server started on port 8080")
            return server
        except Exception as e:
            logger.error(f"Failed to start health check server: {e}")
            return None
    
    def run(self):
        """Main application entry point"""
        logger.info("Starting CRM Interaction Producer")
        
        # Start health check server
        health_server = self.start_health_check_server()
        
        # Set up signal handlers
        def signal_handler(signum, frame):
            logger.info(f"Received signal {signum}, shutting down...")
            self.running = False
        
        signal.signal(signal.SIGTERM, signal_handler)
        signal.signal(signal.SIGINT, signal_handler)
        
        try:
            # Start the main polling loop
            self.run_with_retries()
        finally:
            # Cleanup
            if health_server:
                health_server.shutdown()
            
            logger.info(f"Producer stopped. Total records processed: {self.total_records_processed}")

def main():
    """Application entry point"""
    try:
        producer = CRMInteractionProducer()
        producer.run()
    except Exception as e:
        logger.error(f"Failed to start producer: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
