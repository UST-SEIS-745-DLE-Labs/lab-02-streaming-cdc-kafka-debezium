############################################
# INITIALIZE LAB PARAMETERS AND VARIABLES  #
############################################
source infra/lab-params.sh
EC2_INSTANCE_ID=`aws ec2 describe-instances --filters "Name=tag:Name,Values=${LAB_EC2_NAME}" "Name=instance-state-name,Values=running" --query 'Reservations[*].Instances[*].InstanceId | [0] | [0]' --output text`
EC2_DNS=`aws ec2 describe-instances --filters "Name=tag:Name,Values=${LAB_EC2_NAME}" --query 'Reservations[*].Instances[*].PublicDnsName | [0] | [0]' --output text`
S3_BUCKET_NAME=`aws s3api list-buckets --query "Buckets[0].Name" --output text`

############################################
# DELETE LAB RESOURCES                     #
############################################
aws ec2 terminate-instances --instance-ids ${EC2_INSTANCE_ID}  --no-cli-pager
aws ec2 delete-key-pair --key-name "${LAB_KEY_NAME}"  --no-cli-pager
rm -f "${LAB_KEY_FILE}"
aws rds delete-db-instance --db-instance-identifier "${DATABASE_INSTANCE}" --skip-final-snapshot --no-cli-pager
aws ec2 wait instance-terminated --instance-ids ${EC2_INSTANCE_ID}  --no-cli-pager
aws ec2 delete-security-group --group-name ${LAB_EC2_NAME}-sg  --no-cli-pager
aws rds wait db-instance-deleted --db-instance-identifier "${DATABASE_INSTANCE}"  --no-cli-pager
aws ec2 delete-security-group --group-name "rds-securitygroup"  --no-cli-pager
aws rds delete-db-parameter-group --db-parameter-group-name "mysql-debezium-pg"  --no-cli-pager
