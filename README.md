# Installation de Tomcat 9 sur CentOS 7 - Guide Complet

## Prérequis système
- **RAM** : ≥ 2 Go (4 Go recommandé)
- **Disque** : ≥ 20 Go (30 Go recommandé pour `/opt` et les logs)
- **CPU** : 2 cœurs minimum
- **Réseau** : Accès internet pour les téléchargements
- **ISO** : CentOS 7 7.9.2009 Minimal ou DVD

---

## Étapes réalisées

### 1. Installation de CentOS 7 7.9.2009 sur VirtualBox
```
VM: CentOS7-Tomcat
RAM: 4096 MB
Disque: 30 GB (dynamique)
Réseau: NAT + Host-Only (pour SSH)
```
Partitionnement standard (LVM), profil "Minimal" ou "Infrastructure Server", réseau activé pendant l'installation.

---

### 2. Vérification des ressources système
```bash
df -h /
free -h
uname -a
```

---

### 3. Configuration réseau
```bash
dhclient
ip addr show
ping -c 4 8.8.8.8
cat /etc/resolv.conf
nslookup archive.apache.org
curl -I --connect-timeout 10 https://archive.apache.org/dist/tomcat/
```
**⚠️ Ne pas continuer si le `curl` n'aboutit pas** — CentOS 7 étant en fin de vie, les dépôts par défaut sont cassés (voir étape 5).

---

### 4. Configuration réseau persistante (post-reboot)
```bash
# Détecter le nom réel de l'interface (ne pas supposer "enp0s3")
IFACE=$(ip -o link show | awk -F': ' '$2 !~ /^lo$/ {print $2; exit}')
echo "Interface détectée : ${IFACE}"

IFCFG="/etc/sysconfig/network-scripts/ifcfg-${IFACE}"
if [ -f "$IFCFG" ]; then
    sudo sed -i 's/ONBOOT=no/ONBOOT=yes/g' "$IFCFG"
else
    echo "Fichier ${IFCFG} introuvable — vérifier manuellement le nom de l'interface avec 'ip addr show'."
fi

sudo hostnamectl set-hostname tomcat-server
```

---

### 5. Bascule des dépôts vers `vault.centos.org` (CentOS 7 EOL)
```bash
TIMESTAMP=$(date +%s)
sudo mkdir -p /etc/yum.repos.d/backup.$TIMESTAMP
sudo cp /etc/yum.repos.d/CentOS-*.repo /etc/yum.repos.d/backup.$TIMESTAMP/

sudo sed -i 's/mirrorlist=/#mirrorlist=/g' /etc/yum.repos.d/CentOS-*.repo
sudo sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*.repo

sudo yum clean all
sudo yum makecache --verbose
sudo yum repolist
```
**Sans cette bascule, `yum install` échoue silencieusement ou renvoie des erreurs 404.**

---

### 6. Mise à jour du système
```bash
sudo yum update -y
sudo reboot
```
**⚠️ Le `reboot` coupe la session SSH.** Reconnectez-vous avant de poursuivre à l'étape 7.

---

### 7. Installation de Java — version explicitement choisie
```bash
sudo yum install -y java-11-openjdk java-11-openjdk-devel
sudo alternatives --display java
sudo alternatives --config java
# Choisir le numéro correspondant à java-11-openjdk

java -version
# Sortie attendue : openjdk version "11.0.x"
```

---

### 8. Téléchargement et vérification d'intégrité de Tomcat 9.0.121
```bash
cd /tmp
wget --progress=bar:force https://dlcdn.apache.org/tomcat/tomcat-9/v9.0.121/bin/apache-tomcat-9.0.121.tar.gz
wget https://downloads.apache.org/tomcat/tomcat-9/v9.0.121/bin/apache-tomcat-9.0.121.tar.gz.sha512

sha512sum -c apache-tomcat-9.0.121.tar.gz.sha512
# ⚠️ NE PAS CONTINUER si la commande n'affiche pas "OK"
```

---

### 9. Création d'un utilisateur de service dédié (non-root)
```bash
sudo useradd --system \
             --no-create-home \
             --shell /sbin/nologin \
             --comment "Apache Tomcat Service User" \
             tomcat

id tomcat
```

---

### 10. Installation versionnée + symlink
```bash
sudo mkdir -p /opt/tomcat-9.0.121
sudo tar -xzf /tmp/apache-tomcat-9.0.121.tar.gz -C /opt/tomcat-9.0.121 --strip-components=1
sudo ln -sfn /opt/tomcat-9.0.121 /opt/tomcat
ls -la /opt/tomcat
```
Rollback possible en cas de problème après une future mise à niveau (voir étape 19) :
```bash
sudo systemctl stop tomcat
sudo ln -sfn /opt/tomcat-<ancienne_version> /opt/tomcat
sudo systemctl start tomcat
```

---

### 11. Permissions
```bash
sudo chmod +x /opt/tomcat/bin/*.sh
sudo chown -R tomcat:tomcat /opt/tomcat-9.0.121
ls -la /opt/tomcat/bin/
```

---

### 12. Contexte SELinux (Enforcing par défaut sur CentOS 7)
```bash
getenforce
# Si "Enforcing" :
sudo yum install -y policycoreutils-python

# Contexte "bin_t" : seul contexte pertinent ici, pour permettre l'exécution
# des scripts par un processus confiné. Les contextes "httpd_*" ne s'appliquent
# PAS à Tomcat (processus Java, pas Apache httpd) — ne pas les utiliser.
sudo semanage fcontext -a -t bin_t "/opt/tomcat-9.0.121/bin(/.*)?"
sudo restorecon -Rv /opt/tomcat-9.0.121

ls -Z /opt/tomcat/bin/
```
En cas de blocage résiduel (Tomcat démarre mais ne répond pas, rien d'anormal dans `catalina.out`), consulter `/var/log/audit/audit.log` :
```bash
sudo ausearch -m avc -ts recent
# Générer un module de politique dédié si besoin :
# sudo ausearch -m avc -ts recent | audit2allow -M tomcat_local
# sudo semodule -i tomcat_local.pp
```

---

### 13. Service systemd
```bash
# JAVA_HOME dérivé du binaire actif (résolution identique à celle vérifiée en étape 7)
JAVA_HOME_PATH=$(dirname "$(dirname "$(readlink -f /etc/alternatives/java)")")
echo "JAVA_HOME résolu : ${JAVA_HOME_PATH}"

sudo tee /etc/systemd/system/tomcat.service > /dev/null <<'EOF'
[Unit]
Description=Apache Tomcat 9.0.121
Documentation=http://tomcat.apache.org/tomcat-9.0-doc/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=tomcat
Group=tomcat
UMask=0007

Environment=JAVA_HOME=__JAVA_HOME__
Environment=CATALINA_HOME=/opt/tomcat
Environment=CATALINA_BASE=/opt/tomcat
Environment=CATALINA_OPTS=-Xms512m -Xmx1024m -XX:MaxMetaspaceSize=256m -Djava.security.egd=file:/dev/./urandom -Djava.net.preferIPv4Stack=true
Environment=JAVA_OPTS=-Djava.awt.headless=true

ExecStart=/opt/tomcat/bin/catalina.sh run
ExecStop=/bin/kill -TERM $MAINPID
SuccessExitStatus=143

Restart=on-failure
RestartSec=10
StartLimitIntervalSec=60
StartLimitBurst=3

LimitNOFILE=65535
LimitNPROC=4096

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/tomcat/logs /opt/tomcat/temp /opt/tomcat/work /opt/tomcat/webapps

[Install]
WantedBy=multi-user.target
EOF

# Injection du JAVA_HOME réel (le heredoc est cité 'EOF' pour ne rien laisser
# bash interpréter, notamment $MAINPID qui appartient à systemd, pas au shell)
sudo sed -i "s|__JAVA_HOME__|${JAVA_HOME_PATH}|" /etc/systemd/system/tomcat.service
```
Notes sur ce service, par rapport à une version précédente à corriger :
- `ExecStop=/bin/kill -TERM $MAINPID` + `SuccessExitStatus=143` : `catalina.sh run` s'exécute au premier plan et se termine avec le code 143 (128+SIGTERM) lors d'un arrêt propre par signal — c'est cette paire, cohérente, qui est utilisée, pas `catalina.sh stop` (qui suppose un fichier PID que ce mode `run` ne produit pas).
- Pas d'`ExecReload` : Tomcat n'a pas de gestionnaire `SIGHUP` pour recharger sa configuration à chaud ; en ajouter un ne fait rien et donne une fausse impression de capacité de rechargement.

---

### 14. Activation et démarrage du service
```bash
sudo systemctl daemon-reload
sudo systemctl enable tomcat
sudo systemctl start tomcat
sudo systemctl status tomcat --no-pager
sudo journalctl -u tomcat -f
```

---

### 15. Ouverture du port 8080 — règle persistante
```bash
sudo firewall-cmd --permanent --add-port=8080/tcp
sudo firewall-cmd --reload
sudo firewall-cmd --list-all
```
**Ne pas ajouter `--add-service=http`** : ce service ouvre le port 80, sur lequel rien n'écoute ici — cela ajouterait une règle inutile et trompeuse par rapport à l'objectif réel (8080).

---

### 16. Sécurisation post-installation
```bash
# 1. Supprimer les applications par défaut inutiles
sudo rm -rf /opt/tomcat/webapps/docs
sudo rm -rf /opt/tomcat/webapps/examples
sudo rm -rf /opt/tomcat/webapps/host-manager
# ROOT (page d'accueil) et manager sont conservées

# 2. Créer le compte admin avec un mot de passe généré (pas de placeholder à éditer
#    à la main, et insertion AVANT la balise fermante pour ne pas casser le XML)
ADMIN_PASSWORD=$(openssl rand -base64 24)

sudo sed -i "s|</tomcat-users>|  <role rolename=\"manager-gui\"/>\n  <role rolename=\"admin-gui\"/>\n  <user username=\"admin\" password=\"${ADMIN_PASSWORD}\" roles=\"manager-gui,admin-gui\"/>\n</tomcat-users>|" /opt/tomcat/conf/tomcat-users.xml

echo "Mot de passe admin Tomcat généré : ${ADMIN_PASSWORD}"
echo "⚠️ Noter ce mot de passe dans un gestionnaire de secrets — il n'est affiché qu'une fois ici."

# Vérifier que le XML reste valide
xmllint --noout /opt/tomcat/conf/tomcat-users.xml && echo "XML valide"

# 3. Restreindre l'accès au Manager à localhost (par défaut déjà restreint,
#    à adapter si l'accès doit se faire depuis une IP précise)
grep -A2 "RemoteAddrValve" /opt/tomcat/webapps/manager/META-INF/context.xml
# Pour autoriser une IP spécifique en plus de 127.0.0.1 :
# sudo sed -i 's/allow="127\\.0\\.0\\.1[^"]*"/allow="127\\.0\\.0\\.1|::1|VOTRE_IP"/' \
#   /opt/tomcat/webapps/manager/META-INF/context.xml

sudo systemctl restart tomcat

# 4. Rotation des logs (catalina.out n'est pas géré nativement par JULI,
#    contrairement à localhost.*.log qui tourne déjà par lui-même)
sudo tee /etc/logrotate.d/tomcat > /dev/null <<'EOF'
/opt/tomcat/logs/catalina.out {
    daily
    rotate 7
    size 100M
    compress
    missingok
    copytruncate
}
EOF
# "copytruncate" suffit : le fichier est vidé sur place sans qu'il soit nécessaire
# d'envoyer un signal au processus (pas d'ExecReload utile côté systemd, voir étape 13).
```

---

### 17. Vérification complète
```bash
sudo systemctl is-active tomcat
sudo ss -tlnp | grep 8080
curl -I http://localhost:8080
sudo tail -20 /opt/tomcat/logs/catalina.out
# Depuis la machine hôte : http://<IP_VM>:8080/
```

---

### 18. Monitoring et maintenance
```bash
sudo tee /usr/local/bin/tomcat-healthcheck.sh > /dev/null <<'EOF'
#!/bin/bash
if systemctl is-active --quiet tomcat; then
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:8080 | grep -q "200\|302"; then
        echo "OK - Tomcat is running and responding"
        exit 0
    else
        echo "WARNING - Tomcat is active but not responding"
        exit 1
    fi
else
    echo "CRITICAL - Tomcat service is not running"
    exit 2
fi
EOF
sudo chmod +x /usr/local/bin/tomcat-healthcheck.sh

# Tâche cron optionnelle :
# sudo crontab -e
# */5 * * * * /usr/local/bin/tomcat-healthcheck.sh >> /var/log/tomcat-health.log 2>&1
```

---

### 19. Procédure de mise à jour
```bash
NEW_VERSION="9.0.122"
cd /tmp
wget https://dlcdn.apache.org/tomcat/tomcat-9/v${NEW_VERSION}/bin/apache-tomcat-${NEW_VERSION}.tar.gz
wget https://downloads.apache.org/tomcat/tomcat-9/v${NEW_VERSION}/bin/apache-tomcat-${NEW_VERSION}.tar.gz.sha512
sha512sum -c apache-tomcat-${NEW_VERSION}.tar.gz.sha512

sudo systemctl stop tomcat

sudo mkdir -p /opt/tomcat-${NEW_VERSION}
sudo tar -xzf /tmp/apache-tomcat-${NEW_VERSION}.tar.gz -C /opt/tomcat-${NEW_VERSION} --strip-components=1

# Reprendre la configuration existante
sudo cp -r /opt/tomcat/conf/* /opt/tomcat-${NEW_VERSION}/conf/

# Ne copier que les applications réellement déployées (pas tout webapps/,
# pour ne pas réintroduire docs/examples/host-manager déjà supprimées,
# ni écraser ROOT/manager par la version précédente)
for app in /opt/tomcat/webapps/*/; do
    name=$(basename "$app")
    case "$name" in
        ROOT|manager) continue ;;  # déjà fournis par la nouvelle version
        *) sudo cp -r "$app" "/opt/tomcat-${NEW_VERSION}/webapps/" ;;
    esac
done

sudo chown -R tomcat:tomcat /opt/tomcat-${NEW_VERSION}
sudo ln -sfn /opt/tomcat-${NEW_VERSION} /opt/tomcat

sudo systemctl start tomcat
sudo systemctl status tomcat --no-pager

# Rollback si nécessaire :
# sudo systemctl stop tomcat
# sudo ln -sfn /opt/tomcat-9.0.121 /opt/tomcat
# sudo systemctl start tomcat
```

---

## Résumé des bonnes pratiques implémentées

| Pratique | Impact |
|---|---|
| Intégrité de l'archive vérifiée (SHA512) | Sécurité — évite altération/troncature |
| Utilisateur dédié non-root | Sécurité — moindre privilège |
| Installation versionnée + symlink | Maintenabilité — rollback trivial |
| Service systemd (`ExecStop`/`SuccessExitStatus` cohérents) | Fiabilité — arrêt propre, redémarrage auto |
| Dépôts CentOS EOL corrigés | Disponibilité — `yum` fonctionnel |
| Contexte SELinux correct (`bin_t` seulement) | Sécurité — pas de contextes httpd hors-sujet |
| Java unique et explicite | Stabilité — pas d'ambiguïté |
| Pare-feu limité au port réellement utilisé | Sécurité — pas de règle 80/tcp inutile |
| `tomcat-users.xml` généré sans casser le XML | Fiabilité — realm utilisateur chargeable |
| Mot de passe admin généré, pas de placeholder à la main | Sécurité — pas de mot de passe faible par défaut |
| Rotation des logs (`copytruncate`, sans signal inutile) | Maintenance — évite saturation disque |
| Détection dynamique de l'interface réseau | Portabilité — pas de nom d'interface supposé |
| Monitoring (healthcheck) + procédure de mise à jour testée | Supervision et maintenabilité |

---

## Annexe : Résolution des problèmes courants

### Tomcat démarre mais ne répond pas
```bash
sudo journalctl -u tomcat | grep -i selinux
sudo ausearch -m avc -ts recent
# Test isolant SELinux (à remettre en Enforcing après diagnostic) :
sudo setenforce 0
```

### Port 8080 déjà utilisé
```bash
sudo ss -tlnp | grep 8080
sudo kill -9 <PID>
```

### Mémoire insuffisante
```bash
# Dans /etc/systemd/system/tomcat.service, réduire :
Environment=CATALINA_OPTS=-Xms256m -Xmx512m
sudo systemctl daemon-reload
sudo systemctl restart tomcat
```

### Page 404 après déploiement
```bash
ls -la /opt/tomcat/webapps/
sudo tail -100 /opt/tomcat/logs/localhost.*.log
```

---

## Auteur
**mohamed-v1**
*Version : 3.0 — corrections XML, SELinux, firewall, JAVA_HOME et unité systemd*
