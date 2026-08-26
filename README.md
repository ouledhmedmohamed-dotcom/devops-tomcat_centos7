# Installation de Tomcat 9 sur CentOS7

## Etapes realisées

1.Installation de CentOS7 7.9.2009 sur virtualBox (VM: CentOS7-Tomcat)
2.Configuration réseau (dhclient + DNS)
3.Installation de Java (OpenJDK 8 et 11) 
4.Téléchargement de Tomcat 9.0.121 :
wget https://dlcdn.apache.org/tomcat/tomcat-9/v9.0.121/bin/apache-tomcat-9.0.121.tar.gz
5.Extraction dans /opt/tomcat
6.Configuration des permissions
7.Démarrage : /opt/tomcat/bin/startup.sh
8.Ouverture du port 8080 (firewall-cmd)
9.Vérification : curl -I http://localhost:8080==>  


## Auteur
mohamed-v1
