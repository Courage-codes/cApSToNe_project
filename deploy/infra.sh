create_security_group() {
    local sg_name="crm-producer-sg-$ENVIRONMENT"
    
    log_info "Checking for security group: $sg_name"
    
    # Check if security group exists
    SG_ID=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=$sg_name" \
        --query 'SecurityGroups[0].GroupId' \
        --output text 2>/dev/null)
    
    if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
        log_info "Creating security group: $sg_name"
        
        # Get default VPC
        VPC_ID=$(aws ec2 describe-vpcs \
            --filters "Name=is-default,Values=true" \
            --query 'Vpcs[0].VpcId' \
            --output text)
        
        if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
            log_error "No default VPC found"
            exit 1
        fi
        
        # Create security group
        SG_ID=$(aws ec2 create-security-group \
            --group-name "$sg_name" \
            --description "Security group for data pipeline services" \
            --vpc-id "$VPC_ID" \
            --query 'GroupId' \
            --output text)
        
        # Remove default outbound rule (all traffic)
        aws ec2 revoke-security-group-egress \
            --group-id $SG_ID \
            --protocol -1 \
            --cidr 0.0.0.0/0 2>/dev/null || true
        
        # Configure specific outbound rules
        log_info "Configuring security group rules..."
        
        # Allow outbound HTTPS (for AWS services like Firehose, ECR, S3)
        aws ec2 authorize-security-group-egress \
            --group-id $SG_ID \
            --protocol tcp \
            --port 443 \
            --cidr 0.0.0.0/0
        
        # Allow outbound HTTP (for general web access)
        aws ec2 authorize-security-group-egress \
            --group-id $SG_ID \
            --protocol tcp \
            --port 80 \
            --cidr 0.0.0.0/0
        
        # Allow outbound port 8000 (for your specific CRM API)
        aws ec2 authorize-security-group-egress \
            --group-id $SG_ID \
            --protocol tcp \
            --port 8000 \
            --cidr 0.0.0.0/0
        
        # Allow outbound DNS (for domain resolution)
        aws ec2 authorize-security-group-egress \
            --group-id $SG_ID \
            --protocol udp \
            --port 53 \
            --cidr 0.0.0.0/0
        
        log_info "Created security group: $SG_ID"
    else
        log_info "Security group already exists: $SG_ID"
    fi
    
    # Store in Parameter Store
    aws ssm put-parameter \
        --name "/data-pipeline/$ENVIRONMENT/security-group-id" \
        --value "$SG_ID" \
        --type String \
        --overwrite
}

# CORRECT FUNCTION (PLURAL)
create_log_groups() {
    log_info "Creating CloudWatch log groups"
    
    for service in crm web; do
        local log_group="/ecs/$service-$ENVIRONMENT"
        
        if aws logs describe-log-groups --log-group-name-prefix "$log_group" --query "logGroups[?logGroupName=='$log_group']" --output text | grep -q .; then
            log_info "Log group already exists: $log_group"
        else
            log_info "Creating log group: $log_group"
            aws logs create-log-group --log-group-name "$log_group"
            log_info "Created log group: $log_group"
        fi
        
        # Set retention policy
        aws logs put-retention-policy --log-group-name "$log_group" --retention-in-days 30
        log_info "Set retention policy for: $log_group"
    done
}

# Main execution
log_info "Setting up infrastructure for environment: $ENVIRONMENT"
create_s3_bucket
create_iam_roles
create_firehose_streams
create_ecs_cluster
create_security_group
create_log_groups  # ← This matches the function name above
log_info "Infrastructure setup completed"
