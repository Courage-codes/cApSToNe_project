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
                'service': 'web-producer',
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
        pass

class WebProducer:
    def __init__(self):
        self.api_url = os.getenv('API_URL', 'http://3.248.199.26:8000/api/web-traffic/')
        self.stream_name = os.getenv('STREAM_NAME', 'web-stream-dev')
        self.poll_interval = int(os.getenv('POLL_INTERVAL', '30'))
        self.region = os.getenv('AWS_DEFAULT_REGION', 'eu-west-1')
        
        try:
            self.firehose = boto3.client('firehose', region_name=self.region)
            logger.info(f"Successfully initialized Firehose client for region: {self.region}")
        except Exception as e:
            logger.error(f"Failed to initialize Firehose client: {e}")
            raise
        
        logger.info(f"Web Producer initialized - Stream: {self.stream_name}, API: {self.api_url}")

    def start_health_server(self):
        """Start health check server on port 8080"""
        try:
            server = HTTPServer(('0.0.0.0', 8080), HealthHandler)
            thread = Thread(target=server.serve_forever, daemon=True)
            thread.start()
            logger.info("Health check server started successfully on port 8080")
            
            time.sleep(1)
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
        """Fetch data from Web Traffic API"""
        try:
            logger.info(f"Polling Web API: {self.api_url}")
            response = requests.get(self.api_url, timeout=30)
            response.raise_for_status()
            
            # Parse JSON response
            json_response = response.json()
            logger.info(f"Raw API response type: {type(json_response)}")
            
            # Check if API returned an error
            if isinstance(json_response, dict) and 'error' in json_response:
                logger.warning(f"API returned error: {json_response['error']}")
                return None
            
            # CRITICAL FIX: Normalize response to list format
            if isinstance(json_response, dict):
                # Single record response - wrap in list
                data = [json_response]
                logger.info(f"Successfully fetched 1 record from Web API (wrapped single object)")
            elif isinstance(json_response, list):
                # Array response - use as-is
                data = json_response
                logger.info(f"Successfully fetched {len(data)} records from Web API")
            else:
                logger.error(f"Unexpected response format: {type(json_response)}")
                return None
            
            # Log sample record for debugging
            if data and len(data) > 0:
                logger.info(f"Sample record: {data[0]}")
            
            return data
            
        except requests.RequestException as e:
            logger.error(f"API request failed: {e}")
            return None
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse JSON response: {e}")
            logger.error(f"Response content: {response.text[:200]}...")
            return None
        except Exception as e:
            logger.error(f"Unexpected error fetching data: {e}")
            return None

    def is_valid_record(self, record: Dict) -> bool:
        """Check if a record is valid web traffic data"""
        try:
            if not isinstance(record, dict):
                return False
            
            # Check if record has expected web traffic fields
            required_fields = ['session_id', 'page', 'device_type', 'browser', 'event_type', 'timestamp']
            
            # Must have at least 4 of these fields
            has_fields = sum(1 for field in required_fields if field in record)
            
            if has_fields >= 4:
                # Additional validation: check if values are reasonable
                # user_id can be None, so we don't require it
                if 'timestamp' in record and record['timestamp'] is not None:
                    return True
            
            return False
        except Exception as e:
            logger.error(f"Error validating record: {e}")
            return False

    def process_record(self, record: Dict) -> Dict:
        """Process and enrich a single record"""
        try:
            # Ensure record is a dictionary
            if not isinstance(record, dict):
                logger.warning(f"Invalid record type: {type(record)}, converting to dict")
                record = {"raw_data": str(record)}
            
            # Skip error records
            if 'error' in record:
                logger.debug(f"Skipping error record: {record}")
                return None
            
            # Validate record
            if not self.is_valid_record(record):
                logger.debug(f"Skipping invalid record: {record}")
                return None
            
            # Enrich the record
            enriched_record = {
                **record,
                'processed_at': datetime.utcnow().isoformat(),
                'source': 'web-api',
                'pipeline': 'web-processor',
                'region': self.region
            }
            
            return enriched_record
        except Exception as e:
            logger.error(f"Error processing record: {e}")
            return None

    def send_to_firehose(self, records: List[Dict]) -> bool:
        """Send records to Kinesis Firehose"""
        try:
            if not records:
                logger.info("No records to send to Firehose")
                return True
            
            # Process each record and create Firehose records
            firehose_records = []
            for record in records:
                try:
                    processed_record = self.process_record(record)
                    if processed_record is not None:  # Skip None records (invalid/errors)
                        firehose_record = {
                            'Data': json.dumps(processed_record) + '\n'
                        }
                        firehose_records.append(firehose_record)
                except Exception as e:
                    logger.error(f"Error processing individual record: {e}")
                    continue
            
            if not firehose_records:
                logger.info("No valid records to send to Firehose after processing")
                return True  # Return True since this isn't an error
            
            logger.info(f"Sending {len(firehose_records)} records to Firehose stream: {self.stream_name}")
            
            response = self.firehose.put_record_batch(
                DeliveryStreamName=self.stream_name,
                Records=firehose_records
            )
            
            failed_count = response.get('FailedPutCount', 0)
            if failed_count > 0:
                logger.warning(f"Failed to send {failed_count} records to Firehose")
                # Log details of failed records
                for i, record_result in enumerate(response.get('RequestResponses', [])):
                    if 'ErrorCode' in record_result:
                        logger.error(f"Record {i} failed: {record_result}")
                return False
            
            logger.info(f"Successfully sent {len(firehose_records)} records to Firehose")
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
        logger.info("Starting Web Producer")
        
        try:
            health_server = self.start_health_server()
            logger.info("Health server started successfully")
        except Exception as e:
            logger.error(f"Failed to start health server: {e}")
            return
        
        time.sleep(2)
        
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
            logger.info("Received interrupt signal, shutting down Web Producer")
        except Exception as e:
            logger.error(f"Unexpected error in main loop: {e}")
            raise

if __name__ == "__main__":
    try:
        producer = WebProducer()
        producer.run()
    except Exception as e:
        logger.error(f"Fatal error starting Web Producer: {e}")
        exit(1)
