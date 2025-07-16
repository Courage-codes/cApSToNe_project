#!/bin/bash
set -euo pipefail

SERVICE=$1
ENVIRONMENT=${2:-dev}
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=${AWS_REGION:-eu-west-1}
ECR_REGISTRY="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
IMAGE_TAG=${GITHUB_SHA:-$(date +%s)}

log_info() {
    echo "$(date '+%H:%M:%S') [INFO] $1"
}

log_error() {
    echo "$(date '+%H:%M:%S') [ERROR] $1" >&2
}

build_and_push() {
    log_info "Building and pushing $SERVICE container"
    
    # Login to ECR in the correct region
    aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR_REGISTRY
    
    # Create ECR repository if it doesn't exist
    aws ecr describe-repositories --repository-names $SERVICE --region $REGION 2>/dev/null || \
    aws ecr create-repository --repository-name $SERVICE --region $REGION
    
    # Build and push
    docker build -t $SERVICE:$IMAGE_TAG $SERVICE/
    docker tag $SERVICE:$IMAGE_TAG $ECR_REGISTRY/$SERVICE:$IMAGE_TAG
    docker push $ECR_REGISTRY/$SERVICE:$IMAGE_TAG
    
    echo "IMAGE_URI=$ECR_REGISTRY/$SERVICE:$IMAGE_TAG"
}

deploy_service() {
    local image_uri="$ECR_REGISTRY/$SERVICE:$IMAGE_TAG"
    local cluster_name="data-pipeline-cluster-$ENVIRONMENT"
    local service_name="$SERVICE-service-$ENVIRONMENT"
    local task_family="$SERVICE-task-$ENVIRONMENT"
    
    log_info "Deploying $SERVICE service"
    
    # Retrieve security group created by the infra script
    SECURITY_GROUP_ID=$(aws ssm get-parameter \
        --name "/data-pipeline/$ENVIRONMENT/security-group-id" \
        --query 'Parameter.Value' \
        --output text)
    
    if [ -z "$SECURITY_GROUP_ID" ] || [ "$SECURITY_GROUP_ID" = "None" ]; then
        log_error "No security group found. Please run infrastructure setup first."
        exit 1
    fi
    
    log_info "Using security group: $SECURITY_GROUP_ID"
    
    # Update task definition
    sed "s|{account}|$ACCOUNT_ID|g; s|{environment}|$ENVIRONMENT|g; s|{image_uri}|$image_uri|g" \
        config/$SERVICE.json > /tmp/task-definition.json
    
    # Register task definition
    TASK_DEF_ARN=$(aws ecs register-task-definition --family $task_family --cli-input-json file:///tmp/task-definition.json --query 'taskDefinition.taskDefinitionArn' --output text)
    log_info "Registered task definition: $TASK_DEF_ARN"
    
    # Get VPC configuration
    VPC_ID=$(aws ec2 describe-vpcs --filters "Name=is-default,Values=true" --query 'Vpcs[0].VpcId' --output text)
    SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[0:2].SubnetId' --output text | tr '\t' ',')
    
    # Create or update service
    if aws ecs describe-services --cluster $cluster_name --services $service_name --query 'services[0].serviceName' --output text 2>/dev/null | grep -q $service_name; then
        log_info "Updating existing service"
        aws ecs update-service \
            --cluster $cluster_name \
            --service $service_name \
            --task-definition $task_family \
            --desired-count 1 \
            --force-new-deployment \
            --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_IDS],securityGroups=[$SECURITY_GROUP_ID],assignPublicIp=ENABLED}"
    else
        log_info "Creating new service"
        aws ecs create-service \
            --cluster $cluster_name \
            --service-name $service_name \
            --task-definition $task_family \
            --desired-count 1 \
            --launch-type FARGATE \
            --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_IDS],securityGroups=[$SECURITY_GROUP_ID],assignPublicIp=ENABLED}"
    fi
    
    # Wait for deployment with extended timeout
    log_info "Waiting for deployment to complete (this may take up to 15 minutes)"
    aws ecs wait services-stable --cluster $cluster_name --services $service_name
    
    # Verify deployment success
    SERVICE_STATUS=$(aws ecs describe-services \
        --cluster $cluster_name \
        --services $service_name \
        --query 'services[0].{Running:runningCount,Desired:desiredCount,Status:status}')
    
    log_info "Service deployment status: $SERVICE_STATUS"
}

# Input validation
if [[ "$SERVICE" != "crm" && "$SERVICE" != "web" ]]; then
    log_error "Invalid service '$SERVICE'. Must be 'crm' or 'web'"
    exit 1
fi

# Check if service directory exists
if [[ ! -d "$SERVICE" ]]; then
    log_error "Service directory '$SERVICE/' not found"
    exit 1
fi

# Main execution
log_info "Building and deploying $SERVICE service for environment: $ENVIRONMENT"
build_and_push
deploy_service
log_info "Deployment completed successfully"
