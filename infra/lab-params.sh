############################################
# INITIALIZE LAB PARAMS                    #
############################################
CLIENT_IP="10.10.10.10" # Change this line
LAB_EC2_NAME="lab-debezium-ec2"
LAB_KEY_NAME="${LAB_EC2_NAME}-keypair"
LAB_KEY_FILE="/home/codespace/${LAB_KEY_NAME}.pem"
CODESPACE_IP=`curl ifconfig.me`

DATABASE_INSTANCE="labrdsinstance"
DATABASE_NAME="retaildb"
DATABASE_USER="dbadmin"
DATABASE_SECURITY_GROUP="rds-securitygroup"
