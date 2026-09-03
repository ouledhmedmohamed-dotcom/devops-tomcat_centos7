#!/bin/bash
set -e

# --- Réseau ---
ensure_network() {
    local iface
    iface=$(nmcli -t -f DEVICE,TYPE connection show | grep ethernet | cut -d: -f1)
    if [ -z "$iface" ]; then echo "Aucune interface trouvée."; exit 1; fi
    sudo nmcli connection up "$iface"
    sudo nmcli connection modify "$iface" connection.autoconnect yes
    sleep 2
    if ! ping -c1 -W2 8.8.8.8 &>/dev/null; then
        echo "Échec réseau."
        exit 1
    fi
    echo "Réseau OK."
}
ensure_network

# --- Repos EOL ---
fix_repos_eol() {
    if ! curl -s --head http://mirrorlist.centos.org &>/dev/null; then
        sudo sed -i 's/mirrorlist=/#mirrorlist=/g' /etc/yum.repos.d/CentOS-*.repo
        sudo sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*.repo
        sudo yum clean all
    fi
    echo "Dépôts OK."
}
fix_repos_eol

# --- Java ---
echo "Installation Java 11"
sudo yum install -y java-11-openjdk java-11-openjdk-devel

# --- Tomcat ---
echo "Téléchargement Tomcat"
cd /tmp
sudo curl -L -o tomcat.tar.gz https://archive.apache.org/dist/tomcat/tomcat-9/v9.0.121/bin/apache-tomcat-9.0.121.tar.gz
sudo tar -xzf tomcat.tar.gz
sudo rm -rf /opt/tomcat
sudo mv apache-tomcat-9.0.121 /opt/tomcat
sudo chmod +x /opt/tomcat/bin/*.sh

# --- Service systemd (généré directement, pas de fichier externe) ---
sudo tee /etc/systemd/system/tomcat.service > /dev/null <<'EOF'
[Unit]
Description=Apache Tomcat 9
After=network.target

[Service]
Type=forking
Environment=JAVA_HOME=/usr/lib/jvm/jre
Environment=CATALINA_PID=/opt/tomcat/temp/tomcat.pid
Environment=CATALINA_HOME=/opt/tomcat
Environment=CATALINA_BASE=/opt/tomcat
ExecStart=/opt/tomcat/bin/startup.sh
ExecStop=/opt/tomcat/bin/shutdown.sh
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable tomcat
sudo systemctl start tomcat

# --- Firewall ---
sudo firewall-cmd --permanent --add-port=8080/tcp
sudo firewall-cmd --reload

echo "Terminé ! Tomcat status:"
sudo systemctl status tomcat --no-pager
