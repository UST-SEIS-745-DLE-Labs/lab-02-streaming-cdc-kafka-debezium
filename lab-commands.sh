############################################
# INITIALIZE LAB PARAMETERS AND VARIABLES  #
############################################
source infra/lab-params.sh
EC2_INSTANCE_ID=`aws ec2 describe-instances --filters "Name=tag:Name,Values=${LAB_EC2_NAME}" "Name=instance-state-name,Values=running" --query 'Reservations[*].Instances[*].InstanceId | [0] | [0]' --output text`
EC2_DNS=`aws ec2 describe-instances --filters "Name=tag:Name,Values=${LAB_EC2_NAME}" --query 'Reservations[*].Instances[*].PublicDnsName | [0] | [0]' --output text`
S3_BUCKET_NAME=`aws s3api list-buckets --query "Buckets[0].Name" --output text`

MYSQL_PASSWORD_SECRET_ARN=`aws rds describe-db-instances --db-instance-identifier "${DATABASE_INSTANCE}" --query "DBInstances | [0] | MasterUserSecret.SecretArn" --output text`
MYSQL_PASSWORD_STRING=`aws secretsmanager get-secret-value --secret-id "${MYSQL_PASSWORD_SECRET_ARN}" --query "SecretString" --output text`
MYSQL_USER=`aws rds describe-db-instances --db-instance-identifier "${DATABASE_INSTANCE}" --query "DBInstances | [0] | MasterUsername" --output text`
MYSQL_HOST=`aws rds describe-db-instances --db-instance-identifier "${DATABASE_INSTANCE}" --query "DBInstances | [0] | Endpoint.Address" --output text`
MYSQL_PASSWORD=`echo $MYSQL_PASSWORD_STRING | python3 -c "import sys, json; print(json.load(sys.stdin)['password'])"`
MYSQL_SERVER_ID=`mysql -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -h"${MYSQL_HOST}" -sN <<< "SELECT @@server_id"`

############################################
# SET UP STREAMING PIPELINE FROM RDS TO S3 #
############################################
echo "Access Debezium UI here: http://${EC2_DNS}:8080"

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

echo "Access Debezium UI here: http://${EC2_DNS}:8080"

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
  
