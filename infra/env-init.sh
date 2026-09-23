############################################
# INITIALIZE LAB PARAMETERS AND VARIABLES  #
############################################
source infra/lab-params.sh

############################################
# CREATE OR REPLACE S3 BUCKET              #
############################################
S3_BUCKET_NAME=`aws s3api list-buckets --query "Buckets[0].Name" --output text`

if [ "${S3_BUCKET_NAME}" == None ]; 
then
    S3_BUCKET_NAME="s3-dle-`uuidgen`"
    aws s3api create-bucket --bucket ${S3_BUCKET_NAME} --no-cli-pager
fi

############################################
# CREATE EC2 INSTANCE USING AWS CLI        #
############################################
CIDR_SUFFIX=
if [ "${CLIENT_IP}" = "0.0.0.0" ]; then
    CIDR_SUFFIX="/0"
else
    CIDR_SUFFIX="/32"
fi

aws ec2 create-key-pair \
    --key-name "${LAB_KEY_NAME}" \
    --query 'KeyMaterial' \
    --output text >> "${LAB_KEY_FILE}" --no-cli-pager

chmod 400 "${LAB_KEY_FILE}" # Change file permissions 

# Add necessary firewall rules to EC2 security group
aws ec2 create-security-group --group-name "${LAB_EC2_NAME}-sg" \
  --description "Debezium lab security group" --no-cli-pager
  
SECURITY_GROUP_ID=`aws ec2 describe-security-groups --group-names "${LAB_EC2_NAME}-sg" --query "SecurityGroups | [0].GroupId" --output text`

aws ec2 authorize-security-group-ingress --group-id ${SECURITY_GROUP_ID} --protocol tcp --port 22 --cidr "${CODESPACE_IP}/32" --no-cli-pager
aws ec2 authorize-security-group-ingress --group-id ${SECURITY_GROUP_ID} --protocol tcp --port 8083 --cidr "${CODESPACE_IP}/32" --no-cli-pager
aws ec2 authorize-security-group-ingress --group-id ${SECURITY_GROUP_ID} --protocol tcp --port 8080 --cidr "${CLIENT_IP}${CIDR_SUFFIX}" --no-cli-pager
aws ec2 authorize-security-group-ingress --group-id ${SECURITY_GROUP_ID} --protocol tcp --port 9092 --cidr "${CLIENT_IP}${CIDR_SUFFIX}" --no-cli-pager

# Run instances
aws ec2 run-instances --image-id ami-06e46074ae430fba6 \
  --count 1 \
  --instance-type t2.large \
  --key-name ${LAB_KEY_NAME} \
  --security-group-ids ${SECURITY_GROUP_ID} \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${LAB_EC2_NAME}}]" --no-cli-pager

# Query instance details
EC2_INSTANCE_ID=`aws ec2 describe-instances --filters "Name=tag:Name,Values=${LAB_EC2_NAME}" --query 'Reservations[*].Instances[*].InstanceId | [0] | [0]' --output text`
aws ec2 wait instance-running --instance-ids ${EC2_INSTANCE_ID}  --no-cli-pager
EC2_DNS=`aws ec2 describe-instances --filters "Name=tag:Name,Values=${LAB_EC2_NAME}" --query 'Reservations[*].Instances[*].PublicDnsName | [0] | [0]' --output text`
EC2_LOCAL_IPV4=`aws ec2 describe-instances --filters "Name=tag:Name,Values=${LAB_EC2_NAME}" --query 'Reservations[*].Instances[*].PrivateIpAddress | [0] | [0]' --output text`

# Associate LabInstanceProfile with EC2 instance for S3 access
aws ec2 associate-iam-instance-profile --iam-instance-profile Name=LabInstanceProfile --instance-id ${EC2_INSTANCE_ID} --no-cli-pager

############################################
# CREATE RDS INSTANCE USING AWS CLI        #
############################################
# Create security group for secure database access
aws ec2 create-security-group \
  --description "RDS Network ACL" \
  --group-name "${DATABASE_SECURITY_GROUP}" --no-cli-pager
  
aws ec2 authorize-security-group-ingress --group-name "${DATABASE_SECURITY_GROUP}" --protocol tcp --port 3306 --cidr "${CODESPACE_IP}${CIDR_SUFFIX}" --no-cli-pager
aws ec2 authorize-security-group-ingress --group-name "${DATABASE_SECURITY_GROUP}" --protocol tcp --port 3306 --cidr "${CLIENT_IP}${CIDR_SUFFIX}" --no-cli-pager
aws ec2 authorize-security-group-ingress --group-name "${DATABASE_SECURITY_GROUP}" --protocol tcp --port 3306 --cidr "${EC2_LOCAL_IPV4}/32" --no-cli-pager

RDS_SG_ID=`aws ec2 describe-security-groups --group-name "${DATABASE_SECURITY_GROUP}" --query "SecurityGroups | [0] | GroupId" --output text`

# Create a DB parameter group for necessary Debezium configurations
aws rds create-db-parameter-group \
    --db-parameter-group-name "mysql-debezium-pg" \
    --db-parameter-group-family MySQL8.0 \
    --description "Parameter group to configure MySQL for usage with debezium" --no-cli-pager
    
aws rds modify-db-parameter-group \
    --db-parameter-group-name "mysql-debezium-pg" \
    --parameters \
	    "ParameterName=binlog_format,ParameterValue=ROW,ApplyMethod=immediate" \
	    "ParameterName=binlog_row_image,ParameterValue=FULL,ApplyMethod=immediate" --no-cli-pager

# Create the RDS instance
aws rds create-db-instance \
  --db-instance-identifier "${DATABASE_INSTANCE}" \
  --db-instance-class db.t3.micro \
  --engine mysql \
  --engine-version "8.0" \
  --master-username admin \
  --manage-master-user-password \
  --vpc-security-group-ids $RDS_SG_ID \
  --allocated-storage 20 \
  --db-parameter-group-name "mysql-debezium-pg" \
  --no-cli-auto-prompt \
  --no-cli-pager

aws rds wait db-instance-available --db-instance-identifier "${DATABASE_INSTANCE}"  --no-cli-pager

############################################
# INITIALIZE DATABASE TABLES IN RDS        #
############################################
MYSQL_PASSWORD_SECRET_ARN=`aws rds describe-db-instances --db-instance-identifier "${DATABASE_INSTANCE}" --query "DBInstances | [0] | MasterUserSecret.SecretArn" --output text`
MYSQL_PASSWORD_STRING=`aws secretsmanager get-secret-value --secret-id "${MYSQL_PASSWORD_SECRET_ARN}" --query "SecretString" --output text`
MYSQL_USER=`aws rds describe-db-instances --db-instance-identifier "${DATABASE_INSTANCE}" --query "DBInstances | [0] | MasterUsername" --output text`
MYSQL_HOST=`aws rds describe-db-instances --db-instance-identifier "${DATABASE_INSTANCE}" --query "DBInstances | [0] | Endpoint.Address" --output text`
MYSQL_PASSWORD=`echo $MYSQL_PASSWORD_STRING | python3 -c "import sys, json; print(json.load(sys.stdin)['password'])"`
MYSQL_SERVER_ID=`mysql -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -h"${MYSQL_HOST}" -sN <<< "SELECT @@server_id"`

git clone https://github.com/datacharmer/test_db /home/codespace/sample_data/test_db

mysql -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -h"${MYSQL_HOST}" < /home/codespace/sample_data/test_db/employees.sql
mysql -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -h"${MYSQL_HOST}" -t < /home/codespace/sample_data/test_db/test_employees_md5.sql
mysql -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -h"${MYSQL_HOST}" -t < sql-create-streaming-tables.sql
mysql -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -h"${MYSQL_HOST}" -sN <<< "SHOW TABLES FROM employees"

############################################
# SET UP KAFKA AND DEBEZIUM                #
############################################
mkdir /home/codespace/lab2-files
mv *.zip /home/codespace/lab2-files
scp -r -i "${LAB_KEY_FILE}" /home/codespace/lab2-files "ec2-user@${EC2_DNS}:/home/ec2-user/docker-share"

ssh -i "${LAB_KEY_FILE}" "ec2-user@${EC2_DNS}"

# Install and configure docker
sudo yum -y install docker # For running debezium, zk, kafka, connect

sudo systemctl start docker
sudo usermod -aG docker "ec2-user"
newgrp docker
chmod 777 docker-share
cd docker-share
unzip confluentinc-kafka-connect-s3-10.5.6.zip

# Start Zookeeper
docker run -d \
  -it \
  --rm \
  --name zookeeper \
  -p 2181:2181 -p 2888:2888 -p 3888:3888 \
  quay.io/debezium/zookeeper:2.3 # Run zk

docker container logs zookeeper | grep "binding to port" # Verify zk is up and running

# Start Kafka
docker run -d \
  -it \
  --rm \
  --name kafka \
  -p 9092:9092 \
  --link zookeeper:zookeeper \
  quay.io/debezium/kafka:2.3
  
docker container logs kafka | grep started # Verify Kafka broker is up and running

# Start Debezium and Kafka Connect
docker run -d \
  -it \
  --rm \
  --name connect \
  -p 8083:8083 \
  -e GROUP_ID=1 \
  -e CONFIG_STORAGE_TOPIC=my_connect_configs \
  -e OFFSET_STORAGE_TOPIC=my_connect_offsets \
  -e STATUS_STORAGE_TOPIC=my_connect_statuses \
  -v /home/ec2-user/docker-share/confluentinc-kafka-connect-s3-10.5.6:/kafka/connect/confluentinc-kafka-connect-s3-10.5.6 \
  --link kafka:kafka \
  quay.io/debezium/connect:2.3 # Run debezium, Kafka connect

docker container logs connect | grep "Finished starting " # Verify Kafka Connect and Debezium are up and running

# Start Debezium UI
docker run -d \
  -it \
  --rm \
  --name debezium-ui \
  -p 8080:8080 \
  --link connect:connect \
  -e KAFKA_CONNECT_URIS=http://connect:8083 \
  quay.io/debezium/debezium-ui:2.4 # Run debezium-ui (port 8080)

docker exec kafka /kafka/bin/kafka-topics.sh --list --bootstrap-server 0.0.0.0:9092

exit
exit