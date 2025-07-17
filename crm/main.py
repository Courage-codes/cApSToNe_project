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
        pass

class CRMProducer:
    def __init__(self):
        self.api_url = os.getenv('API_URL', 'http://3.248.199.26:8000/api/customer-interaction/')
        self.stream_name = os.getenv('FIREHOSE_STREAM_NAME', 'crm-stream-dev')
        self.s3_bucket = os.getenv('S3_BUCKET_NAME', 'data-pipeline-dev-605134436600')
        self.poll_interval = int(os.getenv('POLL_INTERVAL', '30'))
        self.region = os.getenv('AWS_DEFAULT_REGION', 'eu-west-1')
        
        # Initialize AWS clients
        try:
            self.firehose = boto3.client('firehose', region_name=self.region)
            logger.info(f"Successfully initialized Firehose client for region: {self.region}")
        except Exception as e:
            logger.error(f"Failed to initialize Firehose client: {e}")
            raise
        
        try:
            self.s3 = boto3.client('s3', region_name=self.region)
            logger.info(f"Successfully initialized S3 client for region: {self.region}")
        except Exception as e:
            logger.error(f"Failed to initialize S3 client: {e}")
            raise
        
        logger.info(f"CRM Producer initialized - Stream: {self.stream_name}, S3 Bucket: {self.s3_bucket}, API: {self.api_url}")

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
        """Fetch data from CRM API"""
        try:
            logger.info(f"Polling CRM API: {self.api_url}")
            response = requests.get(self.api_url, timeout=30)
            response.raise_for_status()
            
            # Parse JSON response
            json_response = response.json()
            
            # Check if API returned an error
            if isinstance(json_response, dict) and 'error' in json_response:
                logger.warning(f"API returned error: {json_response['error']}")
                return None
            
            # Handle different response formats
            if isinstance(json_response, list):
                # Response is already a list
                data = json_response
            elif isinstance(json_response, dict):
                # Single record response - wrap in list
                data = [json_response]
            else:
                logger.error(f"Unexpected response format: {type(json_response)}")
                return None
            
            logger.info(f"Successfully fetched {len(data)} records from CRM API")
            
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

    def send_to_s3(self, records: List[Dict]) -> bool:
        """Send raw records directly to S3 with no enrichment"""
        try:
            if not records:
                logger.info("No records to send to S3")
                return True
            
            # Create S3 key with date partitioning
            current_date = datetime.utcnow().strftime('%Y-%m-%d')
            timestamp = int(time.time() * 1000)
            s3_key = f"direct/crm/{current_date}/batch_{timestamp}.json"
            
            # Send raw API data without any enrichment
            data_content = '\n'.join([json.dumps(record) for record in records])
            
            logger.info(f"Sending {len(records)} raw records to S3: s3://{self.s3_bucket}/{s3_key}")
            
            # Upload to S3
            self.s3.put_object(
                Bucket=self.s3_bucket,
                Key=s3_key,
                Body=data_content,
                ContentType='application/json'
            )
            
            logger.info(f"Successfully sent {len(records)} raw records to S3")
            return True
            
        except Exception as e:
            logger.error(f"S3 send failed: {e}")
            return False

    def send_to_firehose(self, records: List[Dict]) -> bool:
        """Send raw records to Kinesis Firehose with no enrichment"""
        try:
            if not records:
                logger.info("No records to send to Firehose")
                return True
            
            # Create Firehose records with raw API data (no enrichment)
            firehose_records = []
            for record in records:
                try:
                    # Skip error records
                    if isinstance(record, dict) and 'error' in record:
                        logger.debug(f"Skipping error record: {record}")
                        continue
                    
                    # Send raw record without any enrichment
                    firehose_record = {
                        'Data': json.dumps(record) + '\n'
                    }
                    firehose_records.append(firehose_record)
                except Exception as e:
                    logger.error(f"Error preparing record for Firehose: {e}")
                    continue
            
            if not firehose_records:
                logger.info("No valid records to send to Firehose after filtering")
                return True
            
            logger.info(f"Sending {len(firehose_records)} raw records to Firehose stream: {self.stream_name}")
            
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
            
            logger.info(f"Successfully sent {len(firehose_records)} raw records to Firehose")
            return True
            
        except Exception as e:
            logger.error(f"Firehose send failed: {e}")
            return False

    def send_to_both_destinations(self, records: List[Dict]) -> tuple:
        """Send raw data to both S3 and Firehose simultaneously"""
        s3_success = self.send_to_s3(records)
        firehose_success = self.send_to_firehose(records)
        
        return s3_success, firehose_success

    def run_cycle(self):
        """Run one polling cycle with dual streaming of raw data"""
        try:
            data = self.fetch_data()
            if data:
                logger.info(f"Sending {len(data)} raw records to both S3 and Firehose")
                
                # Send raw data to both destinations
                s3_success, firehose_success = self.send_to_both_destinations(data)
                
                # Log results
                if s3_success and firehose_success:
                    logger.info("✅ Successfully sent raw data to both S3 and Firehose")
                    logger.info("Polling cycle completed successfully")
                elif s3_success:
                    logger.warning("⚠️ S3 succeeded, Firehose failed")
                    logger.error("Polling cycle partially failed")
                elif firehose_success:
                    logger.warning("⚠️ Firehose succeeded, S3 failed")
                    logger.error("Polling cycle partially failed")
                else:
                    logger.error("❌ Both S3 and Firehose failed")
                    logger.error("Polling cycle failed completely")
            else:
                logger.info("No data available in this polling cycle")
        except Exception as e:
            logger.error(f"Error in polling cycle: {e}")

    def run(self):
        """Main run loop"""
        logger.info("Starting CRM Producer with dual streaming (S3 + Firehose) - NO DATA ENRICHMENT")
        
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
