#!/bin/bash
echo Installation Java 11
sudo yum install -y java-11-openjdk java-11-openjdk-devel
echo Telechargement Tomcat
cd /tmp
sudo wget https://downloads.apache.org/tomcat/tomcat-9/v9.0.121/bin/apache-tomcat-9.0.121.tar.gz -O tomcat.tar.gz
sudo tar -xzf tomcat.tar.gz
sudo rm -rf /opt/tomcat 
sudo mv apache-tomcat-9.0.121 /opt/tomcat
sudo chmod +x /opt/tomcat/bin/*.sh
sudo cp tomcat.service /etc/systemd/system/tomcat.service
sudo systemctl daemon-reload
sudo systemctl enable tomcat
sudo systemctl start tomcat
sudo systemctl status tomcat
