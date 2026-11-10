#!/usr/bin/env bash
# =============================================================================
# Alisa — installation (ou mise à jour) d'un proxy ou d'un agent, Linux et macOS
# -----------------------------------------------------------------------------
# Usage (en root) :
#
#   Proxy (Linux) :
#     curl -fsSL https://raw.githubusercontent.com/cganiddle/alisa-releases/main/install/install.sh \
#       | sudo bash -s -- proxy
#
#   Agent (Linux, macOS) :
#     curl -fsSL https://raw.githubusercontent.com/cganiddle/alisa-releases/main/install/install.sh \
#       | sudo bash -s -- agent
#
# Aucun secret à fournir : le nœud s'annonce au serveur central et affiche un code
# de vérification. Approuvez-le (proxy) ou associez-le à un proxy (agent) dans
# l'interface Alisa, en vérifiant ce code.
#
# Options communes :
#   --server hôte:port   serveur central (défaut : alisa.netmonitoring.be:5443)
#   --version vX.Y.Z     version à installer (défaut : la dernière publiée)
#   --ca-file chemin     CA privée du serveur central
#   --force-config       réécrit la configuration même si elle existe déjà
# Options proxy :
#   --listen :5100       adresse d'écoute pour les agents (défaut : toutes les interfaces, port 5100)
# Options agent :
#   --proxy-tls          le proxy présente un certificat (sinon : connexion en clair,
#                        réservée à un réseau local de confiance)
#   --proxy-ca-file      CA ayant signé le certificat du proxy (implique --proxy-tls)
#
# Relancer le script met à jour le binaire et redémarre le service, en conservant
# la configuration et l'identité du nœud. Le binaire téléchargé est vérifié avec
# SHA256SUMS avant installation ; ensuite, les mises à jour sont automatiques.
# =============================================================================
set -Eeuo pipefail

readonly REPO="cganiddle/alisa-releases"
readonly DEFAULT_SERVER="alisa.netmonitoring.be:5443"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
        sed -n '3,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    else
        echo "Usage : install.sh proxy|agent [options] — voir https://github.com/cganiddle/alisa-releases"
    fi
    exit "${1:-0}"
}

# --- Arguments ---------------------------------------------------------------------
[[ $# -ge 1 ]] || usage 1
COMPONENT="$1"; shift
[[ "$COMPONENT" == "proxy" || "$COMPONENT" == "agent" ]] || usage 1

VERSION="latest" SERVER="$DEFAULT_SERVER" LISTEN=":5100" CA_FILE="" PROXY_CA_FILE=""
PROXY_TLS=false FORCE_CONFIG=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="${2:?}"; shift 2 ;;
        --server) SERVER="${2:?}"; shift 2 ;;
        --listen) LISTEN="${2:?}"; shift 2 ;;
        --ca-file) CA_FILE="${2:?}"; shift 2 ;;
        --proxy-tls) PROXY_TLS=true; shift ;;
        --proxy-ca-file) PROXY_CA_FILE="${2:?}"; PROXY_TLS=true; shift 2 ;;
        --force-config) FORCE_CONFIG=true; shift ;;
        -h|--help) usage 0 ;;
        *) die "Option inconnue : $1 (les anciennes options --token/--key/--proxy n'existent plus)" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "Lancez ce script en root (sudo)."

# --- Plateforme ------------------------------------------------------------------------
case "$(uname -s)" in
    Linux) OS=linux ;;
    Darwin) OS=darwin ;;
    *) die "Système non pris en charge : $(uname -s) (Windows : utilisez install.ps1)" ;;
esac
case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) die "Architecture non prise en charge : $(uname -m)" ;;
esac
[[ "$COMPONENT" == "proxy" && "$OS" != "linux" ]] && die "Le proxy s'installe sous Linux (ou Windows avec install.ps1)."

BIN_NAME="alisa-${COMPONENT}"
BIN_PATH="/usr/local/bin/${BIN_NAME}"
ASSET="${BIN_NAME}-${OS}-${ARCH}"
if [[ "$COMPONENT" == "agent" && "$OS" == "darwin" ]]; then
    CONFIG_DIR="/Library/Application Support/Alisa"
else
    CONFIG_DIR=/etc/alisa
fi
CONFIG_PATH="${CONFIG_DIR}/${COMPONENT}.yaml"

# --- Téléchargement vérifié ---------------------------------------------------------------
# ALISA_DOWNLOAD_BASE permet d'utiliser un miroir interne (ou un serveur de test).
if [[ -n "${ALISA_DOWNLOAD_BASE:-}" ]]; then
    BASE_URL="$ALISA_DOWNLOAD_BASE"
elif [[ "$VERSION" == "latest" ]]; then
    BASE_URL="https://github.com/${REPO}/releases/latest/download"
else
    BASE_URL="https://github.com/${REPO}/releases/download/${VERSION}"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

info "Téléchargement de ${ASSET} (${VERSION})"
curl -fsSL --retry 3 -o "$TMP/$ASSET" "$BASE_URL/$ASSET" ||
    die "Téléchargement impossible : $BASE_URL/$ASSET (version publiée ? réseau ?)"
curl -fsSL --retry 3 -o "$TMP/SHA256SUMS" "$BASE_URL/SHA256SUMS" ||
    die "Téléchargement impossible : $BASE_URL/SHA256SUMS"

expected="$(awk -v f="$ASSET" '$2 == f || $2 == "*"f {print $1}' "$TMP/SHA256SUMS")"
[[ -n "$expected" ]] || die "$ASSET absent de SHA256SUMS"
if command -v sha256sum >/dev/null; then
    actual="$(sha256sum "$TMP/$ASSET" | awk '{print $1}')"
else
    actual="$(shasum -a 256 "$TMP/$ASSET" | awk '{print $1}')"
fi
[[ "$expected" == "$actual" ]] || die "Empreinte SHA-256 invalide pour $ASSET : fichier corrompu ou altéré."
info "Empreinte SHA-256 vérifiée"

# --- Configuration (aucun secret) ---------------------------------------------------------
# Les valeurs sont écrites entre guillemets simples YAML (une apostrophe est doublée).
yaml_quote() { printf "'%s'" "${1//\'/\'\'}"; }

server_tls_block() {
    if [[ -n "$CA_FILE" ]]; then
        echo "server_tls:"
        echo "  ca_file: $(yaml_quote "$CA_FILE")"
    else
        echo "server_tls: {}   # magasin de certificats du système"
    fi
}

write_proxy_config() {
    cat <<EOF
# Configuration du proxy Alisa — générée par install.sh le $(date '+%Y-%m-%d %H:%M').
# Référence complète : go/configs/proxy.example.yaml
server_address: $(yaml_quote "$SERVER")
$(server_tls_block)
listen: $(yaml_quote "$LISTEN")
cache_dir: /var/lib/alisa-proxy
spool_max_mb: 256
log_level: info
EOF
}

write_agent_config() {
    local proxy_block="proxy_tls:"$'\n'"  enabled: false   # proxy sans certificat : réseau local de confiance uniquement"
    if $PROXY_TLS; then
        proxy_block="proxy_tls:"$'\n'"  enabled: true"
        [[ -n "$PROXY_CA_FILE" ]] && proxy_block+=$'\n'"  ca_file: $(yaml_quote "$PROXY_CA_FILE")"
    fi
    cat <<EOF
# Configuration de l'agent Alisa — générée par install.sh le $(date '+%Y-%m-%d %H:%M').
# Référence complète : go/configs/agent.example.yaml
server_address: $(yaml_quote "$SERVER")
$(server_tls_block)
${proxy_block}
buffer_max: 10000
scripts:
  enabled: false
  allowed_commands: []
  allowed_dirs: []
log_level: info
EOF
}

install -d -m 755 "$CONFIG_DIR"
if [[ -f "$CONFIG_PATH" ]] && ! $FORCE_CONFIG; then
    info "Configuration existante conservée : $CONFIG_PATH"
else
    info "Écriture de la configuration : $CONFIG_PATH"
    ( umask 077; "write_${COMPONENT}_config" > "$TMP/config.yaml" )
    install -m 600 "$TMP/config.yaml" "$CONFIG_PATH"
fi

# --- Binaire + service -------------------------------------------------------------------------
if [[ -x "$BIN_PATH" ]]; then
    info "Arrêt du service existant"
    "$BIN_PATH" stop >/dev/null 2>&1 || true
fi
install -m 755 "$TMP/$ASSET" "$BIN_PATH"
rm -f "${BIN_PATH}.old" "${BIN_PATH}.failed"
[[ "$OS" == "darwin" ]] && xattr -d com.apple.quarantine "$BIN_PATH" 2>/dev/null || true
info "Installé : $("$BIN_PATH" version 2>/dev/null || echo "$BIN_PATH")"

if "$BIN_PATH" install -config "$CONFIG_PATH" >/dev/null 2>&1; then
    info "Service ${BIN_NAME} créé"
else
    info "Service ${BIN_NAME} déjà présent"
fi
"$BIN_PATH" start >/dev/null 2>&1 || "$BIN_PATH" restart >/dev/null 2>&1 ||
    die "Le service ne démarre pas. Diagnostic : sudo $BIN_PATH run -config '$CONFIG_PATH'"

# --- Code de vérification ------------------------------------------------------------------------
# Le service crée l'identité du nœud au démarrage ; on l'attend jusqu'à 20 s.
enrollment=""
for _ in $(seq 1 20); do
    if enrollment="$("$BIN_PATH" enrollment -config "$CONFIG_PATH" 2>/dev/null)"; then
        break
    fi
    enrollment=""
    sleep 1
done

echo
if [[ -n "$enrollment" ]]; then
    printf '\033[1m%s\033[0m\n' "──────────────────────────────────────────────────────────────"
    printf '%s\n' "$enrollment"
    printf '\033[1m%s\033[0m\n' "──────────────────────────────────────────────────────────────"
    if [[ "$COMPONENT" == "proxy" ]]; then
        echo "→ Approuvez ce proxy dans l'interface Alisa (Proxies → En attente)"
    else
        echo "→ Associez cet agent à un proxy dans l'interface Alisa (Hôtes → En attente)"
    fi
    echo "  en vérifiant que le code affiché est identique. Pour le revoir : sudo $BIN_NAME enrollment"
else
    warn "Code de vérification pas encore disponible : sudo $BIN_NAME enrollment"
fi
echo
info "État du service : $("$BIN_PATH" status 2>&1 || true)"
if [[ "$OS" == "linux" ]]; then
    echo "Journaux : journalctl -u ${BIN_NAME} -f"
else
    echo "Journaux : log show --predicate 'process == \"${BIN_NAME}\"' --last 10m"
fi
if [[ "$COMPONENT" == "proxy" ]]; then
    echo "Pare-feu : ouvrez le port ${LISTEN##*:} (TCP) aux agents."
    echo "Traps SNMP et syslog (si activés dans l'interface, fiche du proxy) : ouvrez aussi"
    echo "UDP 162 (traps) et UDP/TCP 514 (syslog) aux équipements. Voir docs/events.md."
else
    echo "L'agent doit pouvoir joindre ${SERVER} (enrôlement), puis son proxy (port 5100)."
fi
