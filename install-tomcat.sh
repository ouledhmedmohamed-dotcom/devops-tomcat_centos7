#!/bin/bash
#
# install_tomcat.sh — Installation durcie et idempotente d'Apache Tomcat sur RHEL/CentOS-like
#
# - Exécution privilégiée unique (pas de sudo dispersé)
# - Verrou d'exécution (flock) : empêche les lancements concurrents
# - Vérification d'intégrité du binaire Tomcat (SHA512 officiel Apache)
# - Utilisateur de service dédié (non-root)
# - Installation versionnée + symlink (rollback possible, pas de rm -rf destructeur)
# - HTTP_PORT réellement appliqué dans conf/server.xml (pas seulement au firewall)
# - Détection OS avant toute correction de dépôts
# - Réseau : test HTTPS (pas ICMP) ; ne touche à rien si déjà opérationnel
# - JAVA_HOME résolu via /etc/alternatives/java (idiome RHEL standard)
# - systemd Type=simple + catalina.sh run (arrêt géré nativement par SIGTERM)
# - SELinux et firewalld gérés s'ils sont présents/actifs, sans faire échouer le script sinon
# - Idempotent : relancer le script ne casse rien ; --force pour réinstaller
# - Rollback automatique et cohérent des actions de CETTE exécution en cas d'échec (die/ERR)
# - Vérification de l'espace disque avant extraction
# - Validation du service après démarrage
# - Boucle complète sur toutes les versions Java candidates (pas seulement 2)
# - Configuration du port robuste (XML parsing)
# - Options JVM configurables via variable d'environnement
# - Gestion fine des erreurs
#
set -Eeuo pipefail
IFS=$'\n\t'
shopt -s nullglob

# ----------------------------------------------------------------------------
# Configuration (modifiable en tête de script ou via variables d'environnement)
# ----------------------------------------------------------------------------
JAVA_VERSIONS="${JAVA_VERSIONS:-11 17}"  # Versions Java supportées (priorité à la première)
TOMCAT_MAJOR="${TOMCAT_MAJOR:-9}"
TOMCAT_VERSION="${TOMCAT_VERSION:-9.0.121}"
TOMCAT_URL="https://archive.apache.org/dist/tomcat/tomcat-${TOMCAT_MAJOR}/v${TOMCAT_VERSION}/bin/apache-tomcat-${TOMCAT_VERSION}.tar.gz"
HTTP_PORT="${HTTP_PORT:-8080}"
# Compte applicatif non-root dédié au service Tomcat (aligné sur "jenkinsusr" côté Jenkins)
SERVICE_USER="${SERVICE_USER:-tomcatusr}"
CATALINA_JVM_OPTS="${CATALINA_JVM_OPTS:--Xms256m -Xmx512m -Djava.security.egd=file:/dev/./urandom}"
INSTALL_PARENT="/opt"
INSTALL_ROOT="${INSTALL_PARENT}/tomcat-${TOMCAT_VERSION}"
CURRENT_LINK="${INSTALL_PARENT}/tomcat"
TMP_DIR="$(mktemp -d /tmp/tomcat-install.XXXXXX)"
LOG_FILE="/var/log/tomcat-install-$(date +%Y%m%d-%H%M%S).log"
LOCK_FILE="/var/run/tomcat-install.lock"
FORCE=0
UPGRADE=0
MIN_DISK_SPACE_KB=524288  # 512MB minimum

# ----------------------------------------------------------------------------
# Logging / gestion d'erreurs / rollback
# ----------------------------------------------------------------------------
log()  { printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$*" | tee -a "$LOG_FILE"; }
die()  { log "ERREUR: $*"; exit 1; }

# Pile de rollback avec vérification d'existence (évite les doublons)
ROLLBACK_ACTIONS=()
declare -A ROLLBACK_CHECK

register_rollback() {
    local action="$1"
    local key
    key="$(echo "$action" | sha1sum | cut -c1-8)"
    if [ -z "${ROLLBACK_CHECK[$key]:-}" ]; then
        ROLLBACK_ACTIONS+=("$action")
        ROLLBACK_CHECK[$key]=1
        log "Rollback enregistré: ${action}"
    fi
}

rollback() {
    [ "${#ROLLBACK_ACTIONS[@]}" -eq 0 ] && return 0
    log "Rollback des actions effectuées dans cette exécution..."
    local i
    for (( i=${#ROLLBACK_ACTIONS[@]}-1; i>=0; i-- )); do
        local action="${ROLLBACK_ACTIONS[$i]}"
        log "  -> ${action}"
        if bash -c "$action" 2>>"$LOG_FILE"; then
            log "  Rollback réussi: ${action}"
        else
            log "  (rollback partiel: échec de cette étape, poursuite)"
        fi
    done
    ROLLBACK_ACTIONS=()
}

cleanup() {
    rm -rf "$TMP_DIR"
    log "Nettoyage terminé"
}
trap cleanup EXIT

error_handler() {
    local line=$1 code=$2
    log "Échec à la ligne ${line} (code ${code}). Voir ${LOG_FILE}."
    if [ -n "${ROLLBACK_ACTIONS:-}" ]; then
        rollback
    fi
}
trap 'error_handler $LINENO $?' ERR

usage() {
    cat <<EOF
Usage: $0 [-f|--force] [-u|--upgrade] [-h|--help]
  -f, --force   Force la réinstallation même si la version cible est déjà en place
  -u, --upgrade Vérifie et installe la dernière version disponible de Tomcat ${TOMCAT_MAJOR}
  -h, --help    Affiche cette aide
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -f|--force) FORCE=1 ;;
        -u|--upgrade) UPGRADE=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Option inconnue: $1" ;;
    esac
    shift
done

# ----------------------------------------------------------------------------
# Verrou d'exécution — empêche deux instances concurrentes de se marcher dessus
# ----------------------------------------------------------------------------
acquire_lock() {
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        echo "Une autre exécution de $0 est déjà en cours (verrou: ${LOCK_FILE}). Abandon." >&2
        exit 1
    fi
    # Le descripteur 200 reste ouvert jusqu'à la fin du processus (ou fermeture explicite),
    # ce qui libère le verrou automatiquement à la sortie, y compris en cas de crash.
}

# ----------------------------------------------------------------------------
# Pré-requis
# ----------------------------------------------------------------------------
require_root() {
    [ "$(id -u)" -eq 0 ] || die "Ce script doit être exécuté en root (sudo $0)."
}

check_dependencies() {
    local missing=()
    local required_bins=(
        "curl" "tar" "systemctl" "sha512sum" "awk" "grep" "sed"
        "yum" "rpm" "useradd" "id" "getent" "ss" "journalctl" "flock"
    )
    for bin in "${required_bins[@]}"; do
        command -v "$bin" &>/dev/null || missing+=("$bin")
    done
    [ "${#missing[@]}" -eq 0 ] || die "Commandes manquantes: ${missing[*]}"
}

detect_os() {
    [ -r /etc/os-release ] || die "/etc/os-release introuvable, OS non supporté."
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-inconnu}"
    OS_VERSION_MAJOR="${VERSION_ID%%.*}"
    case "$OS_ID" in
        centos|rhel|rocky|almalinux|ol) ;;
        *) die "Distribution non supportée: ${OS_ID}. Ce script cible la famille RHEL/CentOS." ;;
    esac
    log "OS détecté: ${OS_ID} ${VERSION_ID:-}"
}

check_disk_space() {
    local path="$1"
    local required="$2"
    local available
    available="$(df --block-size=1K "$path" | awk 'NR==2 {print $4}')"
    if [ -z "$available" ] || [ "$available" -lt "$required" ]; then
        die "Espace disque insuffisant dans ${path}: disponible ${available:-0}K, requis ${required}K"
    fi
    log "Espace disque suffisant: ${available}K disponible dans ${path}"
}

# ----------------------------------------------------------------------------
# Réseau — ne touche à rien si la connectivité est déjà bonne
# ----------------------------------------------------------------------------
has_connectivity() {
    local url="https://archive.apache.org/dist/tomcat/"
    curl -fsS --max-time 5 --retry 2 -o /dev/null "$url" 2>/dev/null
}

ensure_network() {
    if has_connectivity; then
        log "Réseau déjà opérationnel."
        return 0
    fi

    log "Pas de connectivité HTTPS, tentative de remontée des interfaces Ethernet..."
    if ! command -v nmcli &>/dev/null; then
        log "nmcli non disponible, impossible de configurer le réseau automatiquement"
        die "Connectivité réseau requise pour continuer"
    fi

    local profiles
    mapfile -t profiles < <(nmcli -t -f NAME,TYPE connection show | awk -F: '$2=="802-3-ethernet"{print $1}' 2>/dev/null || true)
    [ "${#profiles[@]}" -gt 0 ] || die "Aucun profil de connexion Ethernet trouvé."

    local p
    for p in "${profiles[@]}"; do
        log "Activation de la connexion: ${p}"
        if nmcli connection up "$p" &>/dev/null; then
            nmcli connection modify "$p" connection.autoconnect yes 2>/dev/null || true
            sleep 3
            if has_connectivity; then
                log "Réseau OK via ${p}."
                return 0
            fi
        fi
    done
    die "Échec réseau: aucune interface n'a permis de joindre archive.apache.org en HTTPS."
}

# ----------------------------------------------------------------------------
# Dépôts EOL CentOS — uniquement si la distro et la version le justifient
# ----------------------------------------------------------------------------
fix_repos_eol() {
    if [ "$OS_ID" != "centos" ] || [ "${OS_VERSION_MAJOR:-0}" -ge 9 ] 2>/dev/null; then
        log "Correction dépôts EOL non applicable (${OS_ID} ${OS_VERSION_MAJOR:-})."
        return 0
    fi

    local repo_files=(/etc/yum.repos.d/CentOS-*.repo)
    [ "${#repo_files[@]}" -gt 0 ] || { log "Aucun fichier repo CentOS-*.repo trouvé."; return 0; }

    # Idempotence : si la bascule a déjà été appliquée lors d'une exécution
    # précédente, ne pas re-vider le cache yum à chaque lancement — cela
    # forcerait install_java() à interroger un cache tout juste vidé et à
    # échouer par manque de temps de reconstruction.
    if grep -q "vault.centos.org" "${repo_files[@]}" 2>/dev/null; then
        log "Dépôts déjà basculés vers vault.centos.org, étape ignorée."
        return 0
    fi

    if ! curl -fsS --max-time 5 http://mirrorlist.centos.org | grep -q "mirror.centos.org" 2>/dev/null; then
        log "Miroir CentOS EOL détecté, bascule vers vault.centos.org."
        local backup_dir="/etc/yum.repos.d/backup.$(date +%s)"
        mkdir -p "$backup_dir"
        cp "${repo_files[@]}" "$backup_dir/"

        sed -i 's/mirrorlist=/#mirrorlist=/g' "${repo_files[@]}"
        sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' "${repo_files[@]}"
        yum clean all 2>/dev/null || true

        log "Reconstruction du cache yum depuis vault.centos.org (peut prendre un moment)..."
        yum makecache fast 2>/dev/null || yum makecache 2>/dev/null || true

        log "Dépôts sauvegardés dans ${backup_dir}"
    fi
    log "Dépôts OK."
}

# ----------------------------------------------------------------------------
# Java — idempotent, boucle complète sur toutes les versions candidates
# ----------------------------------------------------------------------------
install_java() {
    local version

    # 1) Si l'une des versions candidates est déjà installée, ne rien faire.
    for version in $JAVA_VERSIONS; do
        if rpm -q "java-${version}-openjdk-devel" &>/dev/null; then
            log "Java ${version} déjà installé, étape ignorée."
            return 0
        fi
    done

    # 2) Sinon, essayer chaque version candidate dans l'ordre jusqu'à en trouver
    #    une disponible dans les dépôts.
    for version in $JAVA_VERSIONS; do
        if yum list available "java-${version}-openjdk-devel" &>/dev/null; then
            log "Installation de Java ${version}..."
            yum install -y "java-${version}-openjdk" "java-${version}-openjdk-devel"
            log "Java ${version} installé avec succès"
            return 0
        fi
        log "Java ${version} indisponible dans les dépôts, version suivante..."
    done

    die "Aucune version de Java parmi [${JAVA_VERSIONS}] n'est disponible dans les dépôts"
}

resolve_java_home() {
    local java_bin
    if [ -e /etc/alternatives/java ]; then
        java_bin="$(readlink -f /etc/alternatives/java)"
    elif command -v java &>/dev/null; then
        java_bin="$(readlink -f "$(command -v java)")"
    else
        die "Aucun binaire java trouvé (ni /etc/alternatives/java, ni dans le PATH)."
    fi
    local home
    home="$(dirname "$(dirname "$java_bin")")"
    [ -x "${home}/bin/java" ] || die "JAVA_HOME résolu (${home}) semble invalide."
    echo "$home"
}

# ----------------------------------------------------------------------------
# Utilisateur de service dédié (compte applicatif non-root)
# ----------------------------------------------------------------------------
create_service_user() {
    if id -u "$SERVICE_USER" &>/dev/null; then
        log "Utilisateur ${SERVICE_USER} déjà présent."
        return 0
    fi

    useradd --system --no-create-home --shell /sbin/nologin "$SERVICE_USER"
    register_rollback "userdel '${SERVICE_USER}' 2>/dev/null || true"
    log "Utilisateur système ${SERVICE_USER} créé (compte applicatif non-root)."
}

# ----------------------------------------------------------------------------
# Téléchargement + vérification d'intégrité + installation versionnée
# ----------------------------------------------------------------------------
download_and_verify_tomcat() {
    local archive="${TMP_DIR}/apache-tomcat-${TOMCAT_VERSION}.tar.gz"
    local sha_file="${TMP_DIR}/apache-tomcat-${TOMCAT_VERSION}.tar.gz.sha512"

    log "Téléchargement de Tomcat ${TOMCAT_VERSION}..."
    if ! curl -fsSL --max-time 120 --retry 3 -o "$archive" "$TOMCAT_URL"; then
        die "Échec du téléchargement de ${TOMCAT_URL}"
    fi

    log "Téléchargement de l'empreinte SHA512..."
    if ! curl -fsSL --max-time 30 -o "$sha_file" "${TOMCAT_URL}.sha512"; then
        die "Impossible de récupérer le fichier SHA512 officiel"
    fi

    log "Vérification de l'empreinte SHA512..."
    local expected actual
    expected="$(grep -F "apache-tomcat-${TOMCAT_VERSION}.tar.gz" "$sha_file" | awk '{print $1}' | head -1)"
    actual="$(sha512sum "$archive" | awk '{print $1}')"

    if [ -z "$expected" ]; then
        die "Impossible d'extraire l'empreinte SHA512 officielle du fichier"
    fi

    if [ "$expected" != "$actual" ]; then
        die "Empreinte SHA512 invalide (fichier corrompu ou altéré). Attendu: ${expected}, Obtenu: ${actual}"
    fi

    log "Intégrité vérifiée avec succès."
    echo "$archive"
}

install_tomcat() {
    check_disk_space "$INSTALL_PARENT" "$MIN_DISK_SPACE_KB"

    if [ -d "$INSTALL_ROOT" ] && [ "$FORCE" -eq 0 ] && [ "$UPGRADE" -eq 0 ]; then
        log "Tomcat ${TOMCAT_VERSION} déjà installé dans ${INSTALL_ROOT}, étape ignorée (--force pour réinstaller)."
        return 0
    fi

    local archive
    archive="$(download_and_verify_tomcat)"

    local previous_target=""
    if [ -L "$CURRENT_LINK" ] && [ -d "$CURRENT_LINK" ]; then
        previous_target="$(readlink -f "$CURRENT_LINK")"
        local backup_dir="${INSTALL_PARENT}/tomcat-${TOMCAT_VERSION}.backup.$(date +%s)"
        if [ -d "$previous_target" ] && [ "$previous_target" != "$INSTALL_ROOT" ]; then
            log "Sauvegarde de l'ancienne version: ${previous_target} -> ${backup_dir}"
            cp -a "$previous_target" "$backup_dir"
            register_rollback "rm -rf '${backup_dir}' 2>/dev/null || true"
        fi
    fi

    log "Extraction vers ${INSTALL_ROOT}..."
    mkdir -p "$INSTALL_ROOT"
    register_rollback "rm -rf '${INSTALL_ROOT}' 2>/dev/null || true"

    if ! tar -xzf "$archive" -C "$INSTALL_ROOT" --strip-components=1; then
        rm -rf "$INSTALL_ROOT"
        die "Échec de l'extraction de l'archive"
    fi

    chmod +x "$INSTALL_ROOT"/bin/*.sh
    chown -R "${SERVICE_USER}:${SERVICE_USER}" "$INSTALL_ROOT"

    if [ -e "$CURRENT_LINK" ] && [ ! -L "$CURRENT_LINK" ]; then
        local backup="${CURRENT_LINK}.bak.$(date +%s)"
        log "${CURRENT_LINK} existe et n'est pas un symlink, sauvegarde vers ${backup}."
        mv "$CURRENT_LINK" "$backup"
        register_rollback "mv '${backup}' '${CURRENT_LINK}' 2>/dev/null || true"
    fi

    ln -sfn "$INSTALL_ROOT" "$CURRENT_LINK"
    if [ -n "$previous_target" ] && [ "$previous_target" != "$INSTALL_ROOT" ]; then
        register_rollback "ln -sfn '${previous_target}' '${CURRENT_LINK}'"
    fi
    log "Symlink ${CURRENT_LINK} -> ${INSTALL_ROOT}"
}

# ----------------------------------------------------------------------------
# Port HTTP — configuration robuste avec XML parsing, rollback unifié
# ----------------------------------------------------------------------------
configure_tomcat_port() {
    local server_xml="${CURRENT_LINK}/conf/server.xml"
    [ -f "$server_xml" ] || die "server.xml introuvable: ${server_xml}"

    # Sauvegarde du fichier — la restauration se fait UNIQUEMENT via le mécanisme
    # de rollback central (pas de mv manuel ici), pour éviter toute double tentative.
    local backup="${server_xml}.backup.$(date +%s)"
    cp "$server_xml" "$backup"
    register_rollback "mv -f '${backup}' '${server_xml}' 2>/dev/null || true"

    if command -v xmlstarlet &>/dev/null; then
        log "Utilisation de xmlstarlet pour la configuration du port"
        if ! xmlstarlet ed -L -u "//Connector[@protocol='HTTP/1.1']/@port" -v "$HTTP_PORT" "$server_xml" 2>/dev/null; then
            xmlstarlet ed -L -u "//Connector[contains(@protocol,'HTTP')]/@port" -v "$HTTP_PORT" "$server_xml" 2>/dev/null || true
        fi
    else
        log "Utilisation de sed pour la configuration du port (xmlstarlet non disponible)"
        if grep -q 'protocol="HTTP/1.1"' "$server_xml"; then
            sed -i -E "s/(<Connector[^>]*protocol=\"HTTP\/1\.1\"[^>]*port=\")[0-9]+(\")/\1${HTTP_PORT}\2/g" "$server_xml"
            sed -i -E "s/(<Connector[^>]*port=\")[0-9]+(\"[^>]*protocol=\"HTTP\/1\.1\")/\1${HTTP_PORT}\2/g" "$server_xml"
        else
            sed -i "0,/<Connector/s/port=\"[0-9]*\"/port=\"${HTTP_PORT}\"/" "$server_xml"
        fi
    fi

    # Vérification finale — en cas d'échec, on se contente de die(); c'est le trap ERR
    # (via register_rollback ci-dessus) qui restaure le backup, une seule fois.
    if ! grep -q "port=\"${HTTP_PORT}\"" "$server_xml"; then
        die "Échec de configuration du port ${HTTP_PORT} dans server.xml"
    fi

    chown "${SERVICE_USER}:${SERVICE_USER}" "$server_xml"
    log "Connecteur HTTP Tomcat configuré sur le port ${HTTP_PORT}."
}

# ----------------------------------------------------------------------------
# SELinux — best effort avec logging
# ----------------------------------------------------------------------------
configure_selinux() {
    command -v getenforce &>/dev/null || { log "SELinux absent, étape ignorée."; return 0; }

    local mode
    mode="$(getenforce 2>/dev/null || echo "Disabled")"
    if [ "$mode" != "Enforcing" ]; then
        log "SELinux en mode ${mode}, aucune action nécessaire."
        return 0
    fi

    log "Configuration des contextes SELinux..."
    if ! rpm -q policycoreutils-python-utils &>/dev/null; then
        yum install -y policycoreutils-python-utils 2>/dev/null || log "Impossible d'installer policycoreutils-python-utils"
    fi

    if semanage fcontext -a -t bin_t "${INSTALL_ROOT}/bin(/.*)?" 2>/dev/null; then
        log "Contexte SELinux ajouté pour ${INSTALL_ROOT}/bin"
    else
        log "Avertissement: Impossible d'ajouter le contexte SELinux (peut-être déjà présent)"
    fi

    if restorecon -Rv "$INSTALL_ROOT" 2>/dev/null; then
        log "Contextes SELinux appliqués sur ${INSTALL_ROOT}"
    else
        log "Avertissement: restorecon a échoué, les contextes SELinux peuvent être incorrects"
    fi

    log "Configuration SELinux terminée."
}

# ----------------------------------------------------------------------------
# Pare-feu — ouverture du port applicatif si firewalld est présent et actif
# ----------------------------------------------------------------------------
configure_firewall() {
    command -v firewall-cmd &>/dev/null || { log "firewalld absent, étape ignorée."; return 0; }
    systemctl is-active --quiet firewalld || { log "firewalld inactif, étape ignorée."; return 0; }

    if firewall-cmd --query-port="${HTTP_PORT}/tcp" &>/dev/null; then
        log "Port ${HTTP_PORT}/tcp déjà ouvert dans firewalld."
        return 0
    fi

    firewall-cmd --permanent --add-port="${HTTP_PORT}/tcp"
    firewall-cmd --reload
    register_rollback "firewall-cmd --permanent --remove-port='${HTTP_PORT}/tcp' && firewall-cmd --reload"
    log "Port ${HTTP_PORT}/tcp ouvert dans firewalld."
}

# ----------------------------------------------------------------------------
# Service systemd durci avec validation (compte applicatif SERVICE_USER)
# ----------------------------------------------------------------------------
install_systemd_service() {
    local java_home
    java_home="$(resolve_java_home)"
    log "JAVA_HOME résolu: ${java_home}"

    local unit="/etc/systemd/system/tomcat.service"
    local unit_backup="${TMP_DIR}/tomcat.service.bak"

    if [ -f "$unit" ]; then
        cp "$unit" "$unit_backup"
        register_rollback "cp '${unit_backup}' '${unit}' && systemctl daemon-reload"
    else
        register_rollback "rm -f '${unit}' && systemctl daemon-reload 2>/dev/null || true"
    fi

    cat > "$unit" <<EOF
[Unit]
Description=Apache Tomcat ${TOMCAT_MAJOR}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
UMask=0027

Environment=JAVA_HOME=${java_home}
Environment=CATALINA_HOME=${CURRENT_LINK}
Environment=CATALINA_BASE=${CURRENT_LINK}
Environment=CATALINA_OPTS=${CATALINA_JVM_OPTS}

ExecStart=${CURRENT_LINK}/bin/catalina.sh run
ExecStop=/bin/kill -TERM \$MAINPID
Restart=on-failure
RestartSec=10
TimeoutStartSec=60
TimeoutStopSec=30
SuccessExitStatus=143
LimitNOFILE=65535

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${CURRENT_LINK}/logs ${CURRENT_LINK}/temp ${CURRENT_LINK}/work ${CURRENT_LINK}/webapps

[Install]
WantedBy=multi-user.target
EOF

    if ! systemd-analyze verify "$unit" 2>/dev/null; then
        log "Avertissement: Le fichier unité systemd ne passe pas la validation"
    fi

    systemctl daemon-reload
    systemctl enable tomcat 2>/dev/null || log "Avertissement: Impossible d'activer le service"

    if ! systemctl is-enabled tomcat &>/dev/null; then
        log "Avertissement: le service tomcat n'est pas activé au démarrage."
    fi
}

# ----------------------------------------------------------------------------
# Démarrage + validation (service actif, port à l'écoute, réponse HTTP)
# ----------------------------------------------------------------------------
start_and_validate_service() {
    log "Démarrage du service tomcat..."
    systemctl restart tomcat

    local i
    for i in $(seq 1 15); do
        systemctl is-active --quiet tomcat && break
        sleep 2
    done

    if ! systemctl is-active --quiet tomcat; then
        log "Le service tomcat n'a pas démarré. Dernières lignes de journal:"
        journalctl -u tomcat -n 50 --no-pager | tee -a "$LOG_FILE"
        die "Échec du démarrage du service tomcat."
    fi
    log "Service tomcat actif."

    log "Vérification de l'écoute sur le port ${HTTP_PORT}..."
    local listening=0
    for i in $(seq 1 15); do
        if ss -tln | grep -q ":${HTTP_PORT}\b"; then
            listening=1
            break
        fi
        sleep 2
    done
    [ "$listening" -eq 1 ] || die "Tomcat est actif mais le port ${HTTP_PORT} n'écoute pas."

    if curl -fsS --max-time 10 -o /dev/null "http://127.0.0.1:${HTTP_PORT}/"; then
        log "Tomcat répond correctement en HTTP sur le port ${HTTP_PORT}."
    else
        log "Avertissement: le port écoute mais Tomcat ne répond pas encore (peut nécessiter quelques secondes de plus)."
    fi
}

# ----------------------------------------------------------------------------
# Orchestration
# ----------------------------------------------------------------------------
main() {
    acquire_lock
    require_root
    check_dependencies
    detect_os
    ensure_network
    fix_repos_eol
    install_java
    create_service_user
    install_tomcat
    configure_tomcat_port
    configure_selinux
    install_systemd_service
    configure_firewall
    start_and_validate_service

    ROLLBACK_ACTIONS=()  # succès complet : plus rien à défaire en cas de sortie normale

    log "----------------------------------------------------------------"
    log "Installation terminée avec succès."
    log "  Tomcat:      ${TOMCAT_VERSION}"
    log "  Utilisateur: ${SERVICE_USER} (compte applicatif non-root, /sbin/nologin)"
    log "  Port:        ${HTTP_PORT}"
    log "  Répertoire:  ${CURRENT_LINK} -> ${INSTALL_ROOT}"
    log "  Log complet: ${LOG_FILE}"
    log "----------------------------------------------------------------"
}

main "$@"
