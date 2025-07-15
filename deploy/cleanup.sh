#!/bin/bash
set -euo pipefail

ENVIRONMENT=${1:-dev}
PRESERVE_DATA=${2:-true}

log_info() {
    echo "$(date '+%H:%M:%S') [INFO] $1"
}

cleanup_services() {
    local cluster_name="data-pipeline-cluster-$ENVIRONMENT"
    
    for service in crm web; do
        local service_name="$service-service-$ENVIRONMENT"
        
        if aws ecs describe-services --cluster $cluster_name --services $service_name --query 'services[0].serviceName' --output text 2>/dev/null | grep -q $service_name; then
            log_info "Stopping service: $service_name"
            aws ecs update-service --cluster $cluster_name --service $service_name --desired-count 0
            aws ecs wait services-stable --cluster $cluster_name --services $service_name
            aws ecs delete-service --cluster $cluster_name --service $service_name
        fi
    done
    
    # Delete cluster
    if aws ecs describe-clusters --clusters $cluster_name --query 'clusters[0].clusterName' --output text 2>/dev/null | grep -q $cluster_name; then
        log_info "Deleting cluster: $cluster_name"
        aws ecs delete-cluster --cluster $cluster_name
    fi
}

cleanup_firehose() {
    for stream in crm-stream web-stream; do
        local stream_name="$stream-$ENVIRONMENT"
        if aws firehose describe-delivery-stream --delivery-stream-name $stream_name 2>/dev/null; then
            log_info "Deleting Firehose stream: $stream_name"
            aws firehose delete-delivery-stream --delivery-stream-name $stream_name
        fi
    done
}

cleanup_iam() {
    for role in ecs-execution-role ecs-task-role firehose-role; do
        local role_name="$role-$ENVIRONMENT"
        if aws iam get-role --role-name $role_name 2>/dev/null; then
            log_info "Deleting IAM role: $role_name"
            
            # Detach policies
            aws iam list-attached-role-policies --role-name $role_name --query 'AttachedPolicies[].PolicyArn' --output text | while read policy; do
                [ -n "$policy" ] && aws iam detach-role-policy --role-name $role_name --policy-arn $policy
            done
            
            # Delete inline policies
            aws iam list-role-policies --role-name $role_name --query 'PolicyNames[]' --output text | while read policy; do
                [ -n "$policy" ] && aws iam delete-role-policy --role-name $role_name --policy-name $policy
            done
            
            aws iam delete-role --role-name $role_name
        fi
    done
}

cleanup_logs() {
    for service in crm web; do
        local log_group="/ecs/$service-$ENVIRONMENT"
        if aws logs describe-log-groups --log-group-name-prefix $log_group 2>/dev/null | grep -q $log_group; then
            log_info "Deleting log group: $log_group"
            aws logs delete-log-group --log-group-name $log_group
        fi
    done
}

cleanup_s3() {
    local bucket_name="data-pipeline-$ENVIRONMENT"
    
    if aws s3api head-bucket --bucket $bucket_name 2>/dev/null; then
        if [ "$PRESERVE_DATA" = "false" ]; then
            log_info "Deleting S3 bucket and data: $bucket_name"
            aws s3 rm s3://$bucket_name --recursive
            aws s3api delete-bucket --bucket $bucket_name
        else
            log_info "Preserving S3 bucket: $bucket_name"
        fi
    fi
}

cleanup_parameters() {
    aws ssm delete-parameter --name "/data-pipeline/$ENVIRONMENT/bucket-name" 2>/dev/null || true
    aws ssm delete-parameter --name "/data-pipeline/$ENVIRONMENT/cluster-name" 2>/dev/null || true
}

# Main execution
log_info "Starting cleanup for environment: $ENVIRONMENT"
cleanup_services
cleanup_firehose
cleanup_iam
cleanup_logs
cleanup_s3
cleanup_parameters
log_info "Cleanup completed"
