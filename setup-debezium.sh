############################################
# CONNECT TO EC2 INSTANCE, SET UP DEBEZIUM #
############################################
LAB_EC2_NAME="lab-debezium-ec2"
LAB_KEY_NAME="${LAB_EC2_NAME}-keypair"
LAB_KEY_FILE="${LAB_KEY_NAME}.pem"
EC2_DNS=`aws ec2 describe-instances --filters "Name=tag:Name,Values=${LAB_EC2_NAME}" --query 'Reservations[*].Instances[*].PublicDnsName | [0] | [0]' --output text`

mkdir lab-files
mv *.zip lab-files
scp -r -i "${LAB_KEY_FILE}" /home/ec2-user/environment/lab-files "ec2-user@${EC2_DNS}:/home/ec2-user/docker-share"

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
