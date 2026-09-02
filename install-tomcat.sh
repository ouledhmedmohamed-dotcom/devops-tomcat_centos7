#!/bin/bash

# --- Vérification / activation réseau (ajout) ---
ensure_network() {
    local iface
    iface=$(nmcli -t -f DEVICE,TYPE connection show | grep ethernet | cut -d: -f1)
    if [ -z "$iface" ]; then
        echo "Aucune interface ethernet trouvée."
        exit 1
    fi
    if ! ping -c1 -W2 8.8.8.8 &>/dev/null; then
        echo "Réseau inactif, activation de $iface..."
        sudo nmcli connection up "$iface"
        sudo nmcli connection modify "$iface" connection.autoconnect yes
        sleep 2
    fi
    if ! ping -c1 -W2 8.8.8.8 &>/dev/null; then
        echo "Échec de l'activation réseau."
        exit 1
    fi
    echo "Réseau OK."
}
ensure_network
# --- Fin ajout ---

# --- Correction dépôts CentOS 7 EOL (ajout) ---
fix_repos_eol() {
    if ! curl -s --head http://mirrorlist.centos.org &>/dev/null; then
        echo "Dépôts CentOS EOL détectés, redirection vers vault.centos.org..."
        sudo sed -i 's/mirrorlist=/#mirrorlist=/g' /etc/yum.repos.d/CentOS-*.repo
        sudo sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*.repo
        sudo yum clean all
    fi
    echo "Dépôts OK."
}
fix_repos_eol
# --- Fin ajout ---

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
