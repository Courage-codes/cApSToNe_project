#!/bin/bash
set -euo pipefail

SERVICE=$1
ENVIRONMENT=${2:-dev}
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="$ACCOUNT_ID.dkr.ecr.eu-west-1.amazonaws.com"
IMAGE_TAG=${GITHUB_SHA:-$(date +%s)}

log_info() {
    echo "$(date '+%H:%M:%S') [INFO] $1"
}

build_and_push() {
    log_info "Building and pushing $SERVICE container"
    
    # Login to ECR
    aws ecr get-login-password --region eu-west-1 | docker login --username AWS --password-stdin $ECR_REGISTRY
    
    # Create ECR repository if it doesn't exist
    aws ecr describe-repositories --repository-names $SERVICE 2>/dev/null || \
    aws ecr create-repository --repository-name $SERVICE
    
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
    
    # Update task definition
    sed "s|{account}|$ACCOUNT_ID|g; s|{environment}|$ENVIRONMENT|g; s|{image_uri}|$image_uri|g" \
        config/$SERVICE.json > /tmp/task-definition.json
    
    # Register task definition
    aws ecs register-task-definition --family $task_family --cli-input-json file:///tmp/task-definition.json
    
    # Get VPC configuration
    VPC_ID=$(aws ec2 describe-vpcs --filters "Name=is-default,Values=true" --query 'Vpcs[0].VpcId' --output text)
    SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[0:2].SubnetId' --output text | tr '\t' ',')
    
    # Create or update service
    if aws ecs describe-services --cluster $cluster_name --services $service_name --query 'services[0].serviceName' --output text 2>/dev/null | grep -q $service_name; then
        log_info "Updating existing service"
        aws ecs update-service --cluster $cluster_name --service $service_name --task-definition $task_family
    else
        log_info "Creating new service"
        aws ecs create-service \
            --cluster $cluster_name \
            --service-name $service_name \
            --task-definition $task_family \
            --desired-count 1 \
            --launch-type FARGATE \
            --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_IDS],assignPublicIp=ENABLED}"
    fi
    
    # Wait for deployment
    log_info "Waiting for deployment to complete"
    aws ecs wait services-stable --cluster $cluster_name --services $service_name
}

# Main execution
log_info "Building and deploying $SERVICE service for environment: $ENVIRONMENT"
build_and_push
deploy_service
log_info "Deployment completed successfully"
