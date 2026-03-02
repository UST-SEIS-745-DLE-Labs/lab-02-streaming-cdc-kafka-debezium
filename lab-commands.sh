############################################
# INITIALIZE LAB PARAMETERS AND PACKAGES   #
############################################
CLIENT_IP="172.100.100.100" # Change this line
LAB_EC2_NAME="lab-debezium-ec2"
LAB_KEY_NAME="${LAB_EC2_NAME}-keypair"
LAB_KEY_FILE="${LAB_KEY_NAME}.pem"
TOKEN=`curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"`
CLOUD9_LOCAL_IPV4=`curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4`

DATABASE_INSTANCE="labrdsinstance"
DATABASE_NAME="retaildb"
DATABASE_USER="dbadmin"
DATABASE_SECURITY_GROUP="rds-securitygroup"

if [ ! -f "/usr/local/aws-cli/v2/current/bin/aws" ]; 
then
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip awscliv2.zip
    sudo ./aws/install
fi

alias aws2="/usr/local/aws-cli/v2/current/bin/aws"
aws configure set region us-east-1
aws2 configure set region us-east-1

export AWS_SHARED_CREDENTIALS_FILE=/home/ec2-user/.aws/credentials

############################################
# USE EXISTING OR CREATE NEW S3 BUCKET     #
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

aws ec2 authorize-security-group-ingress --group-id ${SECURITY_GROUP_ID} --protocol tcp --port 22 --cidr "${CLOUD9_LOCAL_IPV4}/32" --no-cli-pager
aws ec2 authorize-security-group-ingress --group-id ${SECURITY_GROUP_ID} --protocol tcp --port 8083 --cidr "${CLOUD9_LOCAL_IPV4}/32" --no-cli-pager
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
  
aws ec2 authorize-security-group-ingress --group-name "${DATABASE_SECURITY_GROUP}" --protocol tcp --port 3306 --cidr "${CLOUD9_LOCAL_IPV4}${CIDR_SUFFIX}" --no-cli-pager
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
aws2 rds create-db-instance \
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

# Connect to and initialize database with data, streaming tables
aws rds wait db-instance-available --db-instance-identifier "labrdsinstance"  --no-cli-pager
MYSQL_PASSWORD_SECRET_ARN=`aws rds describe-db-instances --db-instance-identifier 'labrdsinstance' --query "DBInstances | [0] | MasterUserSecret.SecretArn" --output text`
MYSQL_PASSWORD_STRING=`aws secretsmanager get-secret-value --secret-id "${MYSQL_PASSWORD_SECRET_ARN}" --query "SecretString" --output text`
MYSQL_USER=`aws rds describe-db-instances --db-instance-identifier 'labrdsinstance' --query "DBInstances | [0] | MasterUsername" --output text`
MYSQL_HOST=`aws rds describe-db-instances --db-instance-identifier 'labrdsinstance' --query "DBInstances | [0] | Endpoint.Address" --output text`
MYSQL_PASSWORD=`echo $MYSQL_PASSWORD_STRING | python3 -c "import sys, json; print(json.load(sys.stdin)['password'])"`

git clone https://github.com/datacharmer/test_db /home/ec2-user/sample_data/test_db
cd /home/ec2-user/sample_data/test_db

mysql -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -h"${MYSQL_HOST}" < employees.sql
mysql -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -h"${MYSQL_HOST}" -t < test_employees_md5.sql
mysql -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -h"${MYSQL_HOST}" -t < /home/ec2-user/environment/sql-create-streaming-tables.sql
MYSQL_SERVER_ID=`mysql -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -h"${MYSQL_HOST}" -sN <<< "SELECT @@server_id"`
mysql -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -h"${MYSQL_HOST}" -sN <<< "SHOW TABLES FROM employees"


############################################
# IMPORTANT                                #
############################################

# Before moving on to the next section, run
# setup-debezium.sh to start Debezium services.

############################################
# SET UP STREAMING PIPELINE FROM RDS TO S3 #
############################################

curl -i -X POST -H "Accept:application/json" -H "Content-Type:application/json" ${EC2_DNS}:8083/connectors/ \
  -d '
    {
      "name": "employees-mysql-source",
      "config": {
        "connector.class": "io.debezium.connector.mysql.MySqlConnector",
        "tasks.max": "1",
        "database.hostname": '"\"${MYSQL_HOST}\""',
        "database.port": "3306",
        "database.user": '"\"${MYSQL_USER}\""',
        "database.password": '"\"${MYSQL_PASSWORD}\""',
        "database.server.id": '"\"${MYSQL_SERVER_ID}\""',
        "topic.prefix": "employeesdb",
        "database.include.list": "employees",
        "schema.history.internal.kafka.bootstrap.servers": "kafka:9092",
        "schema.history.internal.kafka.topic": "schemahistory.employees",
        "table.include.list": "employees.departments_streaming,employees.employees_streaming,employees.dept_emp_streaming,employees.dept_manager_streaming,employees.salaries_streaming,employees.titles_streaming"
      }
    }
  '

curl -i -X POST -H "Accept:application/json" -H "Content-Type:application/json" ${EC2_DNS}:8083/connectors/ \
  -d '
    {
      "name": "employees-s3-sink",
      "config": {
        "connector.class": "io.confluent.connect.s3.S3SinkConnector",
        "tasks.max": "1",
        "topics": "employeesdb.employees.departments_streaming,employeesdb.employees.employees_streaming,employeesdb.employees.dept_emp_streaming,employeesdb.employees.dept_manager_streaming,employeesdb.employees.salaries_streaming,employeesdb.employees.titles_streaming",
        "s3.region": "us-east-1",
        "s3.bucket.name": '"\"${S3_BUCKET_NAME}\""',
        "s3.part.size": "5242880",
        "flush.size": "3",
        "storage.class": "io.confluent.connect.s3.storage.S3Storage",
        "format.class": "io.confluent.connect.s3.format.json.JsonFormat",
        "schema.generator.class": "io.confluent.connect.storage.hive.schema.DefaultSchemaGenerator",
        "partitioner.class": "io.confluent.connect.storage.partitioner.DefaultPartitioner",
        "schema.compatibility": "NONE",
        "name": "employees-s3-sink",
        "behavior.on.null.values": "ignore",
        "topics.dir": "employeesdb_topics"
      }
    }
  '

# Check connector and task status using the Kafka Connect API
curl http://${EC2_DNS}:8083/connectors
curl http://${EC2_DNS}:8083/connectors/employees-mysql-source/status
curl http://${EC2_DNS}:8083/connectors/employees-s3-sink/status


# Simulate streaming data: create, update, delete operations

mysql -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -h"${MYSQL_HOST}" # Input commands from sql-generate-sql-records.sql

# Check output in S3

# Exit MySQL command line interface when done
exit;

# Generate a new Debezium connector instance to observe snapshot capabilities
curl -i -X POST -H "Accept:application/json" -H "Content-Type:application/json" ${EC2_DNS}:8083/connectors/ \
  -d '
    {
      "name": "employees-mysql-source-new",
      "config": {
        "connector.class": "io.debezium.connector.mysql.MySqlConnector",
        "tasks.max": "1",
        "database.hostname": '"\"${MYSQL_HOST}\""',
        "database.port": "3306",
        "database.user": '"\"${MYSQL_USER}\""',
        "database.password": '"\"${MYSQL_PASSWORD}\""',
        "database.server.id": '"\"${MYSQL_SERVER_ID}\""',
        "topic.prefix": "employeesdb-new",
        "database.include.list": "employees",
        "schema.history.internal.kafka.bootstrap.servers": "kafka:9092",
        "schema.history.internal.kafka.topic": "schemahistory.employees-new",
        "table.include.list": "employees.departments_streaming,employees.employees_streaming,employees.dept_emp_streaming,employees.dept_manager_streaming,employees.salaries_streaming,employees.titles_streaming"
      }
    }
  '

# Generate a corresponding S3 connectgor instance to observe snapshot capabilities
curl -i -X POST -H "Accept:application/json" -H "Content-Type:application/json" ${EC2_DNS}:8083/connectors/ \
  -d '
    {
      "name": "employees-s3-sink-new",
      "config": {
        "connector.class": "io.confluent.connect.s3.S3SinkConnector",
        "tasks.max": "1",
        "topics": "employeesdb-new.employees.departments_streaming",
        "s3.region": "us-east-1",
        "s3.bucket.name": '"\"${S3_BUCKET_NAME}\""',
        "s3.part.size": "5242880",
        "flush.size": "3",
        "storage.class": "io.confluent.connect.s3.storage.S3Storage",
        "format.class": "io.confluent.connect.s3.format.json.JsonFormat",
        "schema.generator.class": "io.confluent.connect.storage.hive.schema.DefaultSchemaGenerator",
        "partitioner.class": "io.confluent.connect.storage.partitioner.DefaultPartitioner",
        "schema.compatibility": "NONE",
        "name": "employees-s3-sink-new",
        "behavior.on.null.values": "ignore",
        "topics.dir": "employeesdb_topics_new"
      }
    }
  '
  
############################################
# DELETE LAB RESOURCES                     #
############################################
EC2_INSTANCE_ID=`aws ec2 describe-instances --filters "Name=tag:Name,Values=${LAB_EC2_NAME}" --query 'Reservations[*].Instances[*].InstanceId | [0] | [0]' --output text`
aws ec2 terminate-instances --instance-ids ${EC2_INSTANCE_ID}  --no-cli-pager
aws ec2 delete-key-pair --key-name "${LAB_KEY_NAME}"  --no-cli-pager
aws rds delete-db-instance --db-instance-identifier "labrdsinstance" --skip-final-snapshot --no-cli-pager
rm -f "${LAB_KEY_FILE}"
aws ec2 wait instance-terminated --instance-ids ${EC2_INSTANCE_ID}  --no-cli-pager
aws rds wait db-instance-deleted --db-instance-identifier "labrdsinstance"  --no-cli-pager
aws ec2 delete-security-group --group-name "rds-securitygroup"  --no-cli-pager
aws ec2 delete-security-group --group-name ${LAB_EC2_NAME}-sg  --no-cli-pager
aws rds delete-db-parameter-group --db-parameter-group-name "mysql-debezium-pg"  --no-cli-pager