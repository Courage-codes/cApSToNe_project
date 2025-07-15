#!/bin/bash
set -euo pipefail

ENVIRONMENT=${1:-dev}
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=${AWS_REGION:-eu-west-1}

log_info() {
    echo "$(date '+%H:%M:%S') [INFO] $1"
}

resource_exists() {
    local check_command="$1"
    eval "$check_command" &>/dev/null
}

create_s3_bucket() {
    local bucket_name="data-pipeline-${ENVIRONMENT}-${ACCOUNT_ID}"
    
    if resource_exists "aws s3api head-bucket --bucket $bucket_name"; then
        log_info "S3 bucket exists: $bucket_name"
    else
        log_info "Creating S3 bucket: $bucket_name in region: $REGION"
        if [[ "$REGION" == "us-east-1" ]]; then
            # us-east-1 doesn't need LocationConstraint
            aws s3api create-bucket --bucket "$bucket_name" --region "$REGION"
        else
            # All other regions need LocationConstraint
            aws s3api create-bucket \
                --bucket "$bucket_name" \
                --region "$REGION" \
                --create-bucket-configuration LocationConstraint="$REGION"
        fi
        
        log_info "Configuring bucket versioning and lifecycle"
        aws s3api put-bucket-versioning --bucket "$bucket_name" --versioning-configuration Status=Enabled
        aws s3api put-bucket-lifecycle-configuration --bucket "$bucket_name" --lifecycle-configuration '{
            "Rules": [{
                "ID": "DeleteOldData",
                "Status": "Enabled",
                "Expiration": {"Days": 90}
            }]
        }'
    fi
    
    aws ssm put-parameter --name "/data-pipeline/$ENVIRONMENT/bucket-name" --value "$bucket_name" --type String --overwrite
}

create_iam_roles() {
    # ECS Execution Role
    if ! resource_exists "aws iam get-role --role-name ecs-execution-role-$ENVIRONMENT"; then
        log_info "Creating ECS execution role"
        aws iam create-role --role-name "ecs-execution-role-$ENVIRONMENT" --assume-role-policy-document '{
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Principal": {"Service": "ecs-tasks.amazonaws.com"},
                "Action": "sts:AssumeRole"
            }]
        }'
        aws iam attach-role-policy --role-name "ecs-execution-role-$ENVIRONMENT" --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
    fi
    
    # ECS Task Role
    if ! resource_exists "aws iam get-role --role-name ecs-task-role-$ENVIRONMENT"; then
        log_info "Creating ECS task role"
        aws iam create-role --role-name "ecs-task-role-$ENVIRONMENT" --assume-role-policy-document '{
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Principal": {"Service": "ecs-tasks.amazonaws.com"},
                "Action": "sts:AssumeRole"
            }]
        }'
        aws iam attach-role-policy --role-name "ecs-task-role-$ENVIRONMENT" --policy-arn arn:aws:iam::aws:policy/AmazonKinesisFirehoseFullAccess
    fi
    
    # Firehose Role
    if ! resource_exists "aws iam get-role --role-name firehose-role-$ENVIRONMENT"; then
        log_info "Creating Firehose role"
        aws iam create-role --role-name "firehose-role-$ENVIRONMENT" --assume-role-policy-document '{
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Principal": {"Service": "firehose.amazonaws.com"},
                "Action": "sts:AssumeRole"
            }]
        }'
        aws iam put-role-policy --role-name "firehose-role-$ENVIRONMENT" --policy-name S3DeliveryPolicy --policy-document '{
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
                    "arn:aws:s3:::data-pipeline-'$ENVIRONMENT'-'$ACCOUNT_ID'",
                    "arn:aws:s3:::data-pipeline-'$ENVIRONMENT'-'$ACCOUNT_ID'/*"
                ]
            }]
        }'
    fi
}

create_firehose_streams() {
    local bucket_name="data-pipeline-${ENVIRONMENT}-${ACCOUNT_ID}"
    
    # CRM Stream
    if ! resource_exists "aws firehose describe-delivery-stream --delivery-stream-name crm-stream-$ENVIRONMENT"; then
        log_info "Creating CRM Firehose stream"
        aws firehose create-delivery-stream \
            --delivery-stream-name "crm-stream-$ENVIRONMENT" \
            --delivery-stream-type DirectPut \
            --s3-destination-configuration '{
                "RoleARN": "arn:aws:iam::'$ACCOUNT_ID':role/firehose-role-'$ENVIRONMENT'",
                "BucketARN": "arn:aws:s3:::'$bucket_name'",
                "Prefix": "crm/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/",
                "BufferingHints": {"SizeInMBs": 1, "IntervalInSeconds": 60},
                "CompressionFormat": "GZIP"
            }'
    fi
    
    # Web Stream
    if ! resource_exists "aws firehose describe-delivery-stream --delivery-stream-name web-stream-$ENVIRONMENT"; then
        log_info "Creating Web Firehose stream"
        aws firehose create-delivery-stream \
            --delivery-stream-name "web-stream-$ENVIRONMENT" \
            --delivery-stream-type DirectPut \
            --s3-destination-configuration '{
                "RoleARN": "arn:aws:iam::'$ACCOUNT_ID':role/firehose-role-'$ENVIRONMENT'",
                "BucketARN": "arn:aws:s3:::'$bucket_name'",
                "Prefix": "web/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/",
                "BufferingHints": {"SizeInMBs": 1, "IntervalInSeconds": 60},
                "CompressionFormat": "GZIP"
            }'
    fi
}

create_ecs_cluster() {
    local cluster_name="data-pipeline-cluster-$ENVIRONMENT"
    
    if ! resource_exists "aws ecs describe-clusters --clusters $cluster_name"; then
        log_info "Creating ECS cluster"
        aws ecs create-cluster --cluster-name "$cluster_name" --capacity-providers FARGATE
    fi
    
    aws ssm put-parameter --name "/data-pipeline/$ENVIRONMENT/cluster-name" --value "$cluster_name" --type String --overwrite
}

create_log_groups() {
    for service in crm web; do
        local log_group="/ecs/$service-$ENVIRONMENT"
        if ! resource_exists "aws logs describe-log-groups --log-group-name-prefix $log_group"; then
            log_info "Creating log group: $log_group"
            aws logs create-log-group --log-group-name "$log_group"
            aws logs put-retention-policy --log-group-name "$log_group" --retention-in-days 30
        fi
    done
}

# Main execution
log_info "Setting up infrastructure for environment: $ENVIRONMENT"
create_s3_bucket
create_iam_roles
create_firehose_streams
create_ecs_cluster
create_log_groups
log_info "Infrastructure setup completed"