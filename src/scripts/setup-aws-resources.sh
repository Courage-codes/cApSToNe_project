#!/bin/bash

# CRM Pipeline AWS Resources Setup Script
# This script provides utilities for manual AWS resource management

set -e

# Default values
ENVIRONMENT="dev"
AWS_REGION="us-east-1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/../../config"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Help function
show_help() {
    cat << EOF
CRM Pipeline AWS Resources Setup Script

Usage: $0 [OPTIONS] COMMAND

Commands:
    validate    Validate AWS credentials and permissions
    create      Create AWS resources
    update      Update existing resources
    status      Check status of resources
    delete      Delete resources (with confirmation)
    help        Show this help message

Options:
    -e, --environment ENV    Environment (dev, staging, prod) [default: dev]
    -r, --region REGION      AWS region [default: us-east-1]
    -v, --verbose            Verbose output
    -h, --help               Show this help message

Examples:
    $0 -e dev validate
    $0 -e staging create
    $0 -e dev status
    $0 -e dev delete

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -e|--environment)
                ENVIRONMENT="$2"
                shift 2
                ;;
            -r|--region)
                AWS_REGION="$2"
                shift 2
                ;;
            -v|--verbose)
                set -x
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            validate|create|update|status|delete|help)
                COMMAND="$1"
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Validate AWS credentials and permissions
validate_aws() {
    log_info "Validating AWS credentials and permissions..."
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI is not installed"
        exit 1
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS credentials are not configured"
        exit 1
    fi
    
    # Get account info
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    USER_ARN=$(aws sts get-caller-identity --query Arn --output text)
    
    log_info "AWS Account ID: $ACCOUNT_ID"
    log_info "User/Role: $USER_ARN"
    
    # Check permissions
    log_info "Checking AWS permissions..."
    
    # S3 permissions
    if aws s3api list-buckets &> /dev/null; then
        log_info "✓ S3 permissions OK"
    else
        log_error "✗ S3 permissions missing"
        exit 1
    fi
    
    # IAM permissions
    if aws iam list-roles --max-items 1 &> /dev/null; then
        log_info "✓ IAM permissions OK"
    else
        log_error "✗ IAM permissions missing"
        exit 1
    fi
    
    # ECS permissions
    if aws ecs list-clusters --max-items 1 &> /dev/null; then
        log_info "✓ ECS permissions OK"
    else
        log_error "✗ ECS permissions missing"
        exit 1
    fi
    
    # Firehose permissions
    if aws firehose list-delivery-streams --limit 1 &> /dev/null; then
        log_info "✓ Firehose permissions OK"
    else
        log_error "✗ Firehose permissions missing"
        exit 1
    fi
    
    log_info "AWS validation completed successfully"
}

# Set environment variables
set_environment() {
    BUCKET_NAME="crm-interactions-raw-${ENVIRONMENT}"
    STREAM_NAME="crm-interactions-stream-${ENVIRONMENT}"
    CLUSTER_NAME="crm-producer-cluster-${ENVIRONMENT}"
    SERVICE_NAME="crm-producer-service-${ENVIRONMENT}"
    
    log_info "Environment: $ENVIRONMENT"
    log_info "Region: $AWS_REGION"
    log_info "Bucket: $BUCKET_NAME"
    log_info "Stream: $STREAM_NAME"
    log_info "Cluster: $CLUSTER_NAME"
}

# Create AWS resources
create_resources() {
    log_info "Creating AWS resources for environment: $ENVIRONMENT"
    
    # Create S3 bucket
    log_info "Creating S3 bucket: $BUCKET_NAME"
    if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
        log_warn "S3 bucket already exists: $BUCKET_NAME"
    else
        aws s3api create-bucket \
            --bucket "$BUCKET_NAME" \
            --region "$AWS_REGION"
        
        # Enable versioning
        aws s3api put-bucket-versioning \
            --bucket "$BUCKET_NAME" \
            --versioning-configuration Status=Enabled
        
        # Set lifecycle policy
        aws s3api put-bucket-lifecycle-configuration \
            --bucket "$BUCKET_NAME" \
            --lifecycle-configuration '{
                "Rules": [{
                    "ID": "DeleteOldData",
                    "Status": "Enabled",
                    "Expiration": {"Days": 90}
                }]
            }'
        
        log_info "✓ S3 bucket created: $BUCKET_NAME"
    fi
    
    # Create IAM roles
    log_info "Creating IAM roles..."
    
    # Firehose delivery role
    if aws iam get-role --role-name "firehose-delivery-role-${ENVIRONMENT}" &>/dev/null; then
        log_warn "Firehose delivery role already exists"
    else
        aws iam create-role \
            --role-name "firehose-delivery-role-${ENVIRONMENT}" \
            --assume-role-policy-document '{
                "Version": "2012-10-17",
                "Statement": [{
                    "Effect": "Allow",
                    "Principal": {"Service": "firehose.amazonaws.com"},
                    "Action": "sts:AssumeRole"
                }]
            }'
        
        aws iam put-role-policy \
            --role-name "firehose-delivery-role-${ENVIRONMENT}" \
            --policy-name "S3DeliveryPolicy" \
            --policy-document '{
                "Version": "2012-10-17",
                "Statement": [{
                    "Effect": "Allow",
                    "Action": [
                        "s3:AbortMultipartUpload",
                        "s3:GetBucketLocation",
                        "s3:GetObject",
                        "s3:ListBucket",
                        "s3:ListBucketMultipartUploads",
                        "s3:PutObject"
                    ],
                    "Resource": [
                        "arn:aws:s3:::'$BUCKET_NAME'",
                        "arn:aws:s3:::'$BUCKET_NAME'/*"
                    ]
                }]
            }'
        
        log_info "✓ Firehose delivery role created"
    fi
    
    # Wait for IAM role propagation
    log_info "Waiting for IAM role propagation..."
    sleep 30
    
    # Create Kinesis Firehose stream
    log_info "Creating Kinesis Firehose stream: $STREAM_NAME"
    if aws firehose describe-delivery-stream --delivery-stream-name "$STREAM_NAME" &>/dev/null; then
        log_warn "Firehose stream already exists: $STREAM_NAME"
    else
        # Create temporary config file
        TEMP_CONFIG=$(mktemp)
        sed "s/BUCKET_NAME_PLACEHOLDER/$BUCKET_NAME/g" "$CONFIG_DIR/firehose-config.json" > "$TEMP_CONFIG"
        sed -i "s/ACCOUNT_ID_PLACEHOLDER/$ACCOUNT_ID/g" "$TEMP_CONFIG"
        sed -i "s/ENVIRONMENT_PLACEHOLDER/$ENVIRONMENT/g" "$TEMP_CONFIG"
        
        aws firehose create-delivery-stream \
            --delivery-stream-name "$STREAM_NAME" \
            --delivery-stream-type DirectPut \
            --s3-destination-configuration "file://$TEMP_CONFIG"
        
        rm "$TEMP_CONFIG"
        log_info "✓ Firehose stream created: $STREAM_NAME"
    fi
    
    # Create ECS cluster
    log_info "Creating ECS cluster: $CLUSTER_NAME"
    if aws ecs describe-clusters --clusters "$CLUSTER_NAME" --query 'clusters[0].clusterName' --output text 2>/dev/null | grep -q "$CLUSTER_NAME"; then
        log_warn "ECS cluster already exists: $CLUSTER_NAME"
    else
        aws ecs create-cluster \
            --cluster-name "$CLUSTER_NAME" \
            --capacity-providers FARGATE \
            --default-capacity-provider-strategy capacityProvider=FARGATE,weight=1
        
        log_info "✓ ECS cluster created: $CLUSTER_NAME"
    fi
    
    # Create CloudWatch log group
    log_info "Creating CloudWatch log group..."
    aws logs create-log-group \
        --log-group-name "/ecs/crm-producer-${ENVIRONMENT}" \
        --retention-in-days 30 2>/dev/null || log_warn "Log group already exists"
    
    log_info "Resource creation completed successfully"
}

# Check status of resources
check_status() {
    log_info "Checking status of resources for environment: $ENVIRONMENT"
    
    # S3 bucket
    if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
        log_info "✓ S3 bucket exists: $BUCKET_NAME"
        
        # Get bucket size
        BUCKET_SIZE=$(aws s3api list-objects-v2 --bucket "$BUCKET_NAME" --query 'Contents[].Size' --output text 2>/dev/null | awk '{sum+=$1} END {print sum/1024/1024 " MB"}')
        log_info "  Size: ${BUCKET_SIZE:-0 MB}"
    else
        log_error "✗ S3 bucket not found: $BUCKET_NAME"
    fi
    
    # Firehose stream
    if aws firehose describe-delivery-stream --delivery-stream-name "$STREAM_NAME" &>/dev/null; then
        STATUS=$(aws firehose describe-delivery-stream --delivery-stream-name "$STREAM_NAME" --query 'DeliveryStreamDescription.DeliveryStreamStatus' --output text)
        log_info "✓ Firehose stream exists: $STREAM_NAME (Status: $STATUS)"
    else
        log_error "✗ Firehose stream not found: $STREAM_NAME"
    fi
    
    # ECS cluster
    if aws ecs describe-clusters --clusters "$CLUSTER_NAME" --query 'clusters[0].clusterName' --output text 2>/dev/null | grep -q "$CLUSTER_NAME"; then
        ACTIVE_SERVICES=$(aws ecs describe-clusters --clusters "$CLUSTER_NAME" --query 'clusters[0].activeServicesCount' --output text)
        RUNNING_TASKS=$(aws ecs describe-clusters --clusters "$CLUSTER_NAME" --query 'clusters[0].runningTasksCount' --output text)
        log_info "✓ ECS cluster exists: $CLUSTER_NAME (Services: $ACTIVE_SERVICES, Tasks: $RUNNING_TASKS)"
    else
        log_error "✗ ECS cluster not found: $CLUSTER_NAME"
    fi
    
    # ECS service
    if aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" --query 'services[0].serviceName' --output text 2>/dev/null | grep -q "$SERVICE_NAME"; then
        SERVICE_STATUS=$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" --query 'services[0].status' --output text)
        DESIRED_COUNT=$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" --query 'services[0].desiredCount' --output text)
        RUNNING_COUNT=$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" --query 'services[0].runningCount' --output text)
        log_info "✓ ECS service exists: $SERVICE_NAME (Status: $SERVICE_STATUS, Desired: $DESIRED_COUNT, Running: $RUNNING_COUNT)"
    else
        log_warn "ECS service not found: $SERVICE_NAME"
    fi
}

# Delete resources
delete_resources() {
    log_error "WARNING: This will delete all resources for environment: $ENVIRONMENT"
    echo -n "Type 'DELETE' to confirm: "
    read -r confirmation
    
    if [ "$confirmation" != "DELETE" ]; then
        log_info "Deletion cancelled"
        exit 0
    fi
    
    log_info "Deleting resources for environment: $ENVIRONMENT"
    
    # Delete ECS service
    if aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" --query 'services[0].serviceName' --output text 2>/dev/null | grep -q "$SERVICE_NAME"; then
        log_info "Scaling down ECS service: $SERVICE_NAME"
        aws ecs update-service \
            --cluster "$CLUSTER_NAME" \
            --service "$SERVICE_NAME" \
            --desired-count 0
        
        log_info "Waiting for service to scale down..."
        aws ecs wait services-stable \
            --cluster "$CLUSTER_NAME" \
            --services "$SERVICE_NAME"
        
        log_info "Deleting ECS service: $SERVICE_NAME"
        aws ecs delete-service \
            --cluster "$CLUSTER_NAME" \
            --service "$SERVICE_NAME"
    fi
    
    # Delete ECS cluster
    if aws ecs describe-clusters --clusters "$CLUSTER_NAME" --query 'clusters[0].clusterName' --output text 2>/dev/null | grep -q "$CLUSTER_NAME"; then
        log_info "Deleting ECS cluster: $CLUSTER_NAME"
        aws ecs delete-cluster --cluster "$CLUSTER_NAME"
    fi
    
    # Delete Firehose stream
    if aws firehose describe-delivery-stream --delivery-stream-name "$STREAM_NAME" &>/dev/null; then
        log_info "Deleting Firehose stream: $STREAM_NAME"
        aws firehose delete-delivery-stream --delivery-stream-name "$STREAM_NAME"
    fi
    
    # Delete IAM roles
    if aws iam get-role --role-name "firehose-delivery-role-${ENVIRONMENT}" &>/dev/null; then
        log_info "Deleting IAM role: firehose-delivery-role-${ENVIRONMENT}"
        aws iam delete-role-policy \
            --role-name "firehose-delivery-role-${ENVIRONMENT}" \
            --policy-name "S3DeliveryPolicy" || true
        aws iam delete-role --role-name "firehose-delivery-role-${ENVIRONMENT}"
    fi
    
    # Delete CloudWatch log group
    aws logs delete-log-group --log-group-name "/ecs/crm-producer-${ENVIRONMENT}" || true
    
    log_warn "S3 bucket preserved: $BUCKET_NAME"
    log_warn "To delete S3 bucket: aws s3 rb s3://$BUCKET_NAME --force"
    
    log_info "Resource deletion completed"
}

# Main function
main() {
    parse_args "$@"
    
    if [ -z "$COMMAND" ]; then
        log_error "No command specified"
        show_help
        exit 1
    fi
    
    # Validate environment
    if [[ ! "$ENVIRONMENT" =~ ^(dev|staging|prod)$ ]]; then
        log_error "Invalid environment: $ENVIRONMENT"
        log_error "Valid environments: dev, staging, prod"
        exit 1
    fi
    
    # Set environment variables
    set_environment
    
    case "$COMMAND" in
        validate)
            validate_aws
            ;;
        create)
            validate_aws
            create_resources
            ;;
        update)
            validate_aws
            create_resources  # Same as create, but with existence checks
            ;;
        status)
            validate_aws
            check_status
            ;;
        delete)
            validate_aws
            delete_resources
            ;;
        help)
            show_help
            ;;
        *)
            log_error "Unknown command: $COMMAND"
            show_help
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
