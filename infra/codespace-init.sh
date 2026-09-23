############################################
# INSTALL MISC DEPENDENCIES                #
############################################
sudo apt update && sudo apt install -y uuid-runtime mysql-client

############################################
# CONFIGURE AWS CLI                        #
############################################
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/home/codespace/awscliv2.zip"
unzip /home/codespace/awscliv2.zip -d /home/codespace
sudo /home/codespace/aws/install

aws configure