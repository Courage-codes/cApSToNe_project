#!/bin/bash
set -euo pipefail

ENVIRONMENT=${1:-dev}
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=${AWS_REGION:-eu-west-1}

log_info() {
    echo "$(date '+%H:%M:%S') [INFO] $1"
}

log_error() {
    echo "$(date '+%H:%M:%S') [ERROR] $1" >&2
}

resource_exists() {
    local check_command="$1"
    eval "$check_command" &>/dev/null
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
    
    # ECS Task Role with S3 and Firehose permissions for dual streaming
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
        
        # S3 permissions for direct writes
        cat > /tmp/ecs-task-s3-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:PutObjectAcl"
            ],
            "Resource": [
                "arn:aws:s3:::*/*"
            ]
        }
    ]
}
EOF
        aws iam put-role-policy --role-name "ecs-task-role-$ENVIRONMENT" --policy-name "S3WriteAccess" --policy-document file:///tmp/ecs-task-s3-policy.json
        
        # Firehose permissions
        cat > /tmp/ecs-task-firehose-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "firehose:PutRecord",
                "firehose:PutRecordBatch"
            ],
            "Resource": [
                "arn:aws:firehose:${REGION}:${ACCOUNT_ID}:deliverystream/*"
            ]
        }
    ]
}
EOF
        aws iam put-role-policy --role-name "ecs-task-role-$ENVIRONMENT" --policy-name "FirehoseAccess" --policy-document file:///tmp/ecs-task-firehose-policy.json
    fi
}

create_ecs_cluster() {
    local cluster_name="data-pipeline-cluster-$ENVIRONMENT"
    
    log_info "Checking for ECS cluster: $cluster_name"
    
    if aws ecs describe-clusters --clusters "$cluster_name" --query 'clusters[0].clusterName' --output text 2>/dev/null | grep -q "^$cluster_name$"; then
        log_info "ECS cluster already exists: $cluster_name"
    else
        log_info "Creating ECS cluster: $cluster_name"
        
        if aws ecs create-cluster --cluster-name "$cluster_name" --capacity-providers FARGATE; then
            log_info "ECS cluster creation initiated: $cluster_name"
            
            log_info "Waiting for cluster to become active..."
            local max_attempts=30
            local attempt=1
            
            while [ $attempt -le $max_attempts ]; do
                if aws ecs describe-clusters --clusters "$cluster_name" --query 'clusters[0].clusterName' --output text 2>/dev/null | grep -q "^$cluster_name$"; then
                    log_info "ECS cluster is now active: $cluster_name"
                    break
                fi
                
                if [ $attempt -eq $max_attempts ]; then
                    log_error "Cluster creation timeout after $max_attempts attempts"
                    exit 1
                fi
                
                log_info "Waiting for cluster... (attempt $attempt/$max_attempts)"
                sleep 5
                ((attempt++))
            done
        else
            log_error "Failed to create ECS cluster: $cluster_name"
            exit 1
        fi
    fi
    
    aws ssm put-parameter --name "/data-pipeline/$ENVIRONMENT/cluster-name" --value "$cluster_name" --type String --overwrite
}

create_security_group() {
    local sg_name="crm-producer-sg-$ENVIRONMENT"
    
    log_info "Checking for security group: $sg_name"
    
    SG_ID=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=$sg_name" \
        --query 'SecurityGroups[0].GroupId' \
        --output text 2>/dev/null)
    
    if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
        log_info "Creating security group: $sg_name"
        
        VPC_ID=$(aws ec2 describe-vpcs \
            --filters "Name=is-default,Values=true" \
            --query 'Vpcs[0].VpcId' \
            --output text)
        
        if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
            log_error "No default VPC found"
            exit 1
        fi
        
        SG_ID=$(aws ec2 create-security-group \
            --group-name "$sg_name" \
            --description "Security group for data pipeline services" \
            --vpc-id "$VPC_ID" \
            --query 'GroupId' \
            --output text)
        
        aws ec2 revoke-security-group-egress \
            --group-id $SG_ID \
            --protocol -1 \
            --cidr 0.0.0.0/0 2>/dev/null || true
        
        log_info "Configuring security group rules..."
        
        aws ec2 authorize-security-group-egress \
            --group-id $SG_ID \
            --protocol tcp \
            --port 443 \
            --cidr 0.0.0.0/0
        
        aws ec2 authorize-security-group-egress \
            --group-id $SG_ID \
            --protocol tcp \
            --port 80 \
            --cidr 0.0.0.0/0
        
        aws ec2 authorize-security-group-egress \
            --group-id $SG_ID \
            --protocol tcp \
            --port 8000 \
            --cidr 0.0.0.0/0
        
        aws ec2 authorize-security-group-egress \
            --group-id $SG_ID \
            --protocol udp \
            --port 53 \
            --cidr 0.0.0.0/0
        
        log_info "Created security group: $SG_ID"
    else
        log_info "Security group already exists: $SG_ID"
    fi
    
    aws ssm put-parameter \
        --name "/data-pipeline/$ENVIRONMENT/security-group-id" \
        --value "$SG_ID" \
        --type String \
        --overwrite
}

create_log_groups() {
    log_info "Creating CloudWatch log groups"
    
    for service in crm web; do
        local log_group="/ecs/$service-$ENVIRONMENT"
        if ! aws logs describe-log-groups --log-group-name-prefix "$log_group" --query "logGroups[?logGroupName=='$log_group']" --output text | grep -q "$log_group"; then
            log_info "Creating log group: $log_group"
            aws logs create-log-group --log-group-name "$log_group"
            aws logs put-retention-policy --log-group-name "$log_group" --retention-in-days 7
        else
            log_info "Log group already exists: $log_group"
        fi
    done
}

# Main execution
log_info "Setting up infrastructure for environment: $ENVIRONMENT"
create_iam_roles
create_ecs_cluster
create_security_group
create_log_groups
log_info "Infrastructure setup completed"
