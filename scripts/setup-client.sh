#!/bin/bash
# setup-client.sh
# Configure un client Ubuntu pour utiliser le serveur DNS du labo, teste la résolution
# (directe, puis par le résolveur du système) et écrit un rapport.
#
# Usage : ./setup-client.sh [--simulation]
#   --simulation   affiche ce qui serait fait, sans rien modifier
# Les droits administrateur sont demandés avec sudo quand il le faut.

SIM=0
case "${1:-}" in
  "") ;;
  --simulation|-s) SIM=1 ;;
  -h|--aide|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "Option inconnue : $1 (voir --aide)"; exit 1 ;;
esac

PORT="${DNSLAB_PORT:-53}"   # utile seulement pour tester le script en local

# ---------------------------------------------------------------- affichage
if [ -t 1 ]; then
  RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLD=$'\033[1m'; RST=$'\033[0m'
else
  RED=""; GRN=""; YEL=""; BLD=""; RST=""
fi
LOG=(); NB_OK=0; NB_KO=0; NB_WARN=0

title() { printf '\n%s== %s ==%s\n' "$BLD" "$*" "$RST"; }
note()  { printf '  %s\n' "$*"; }
ok()    { printf '  [%sOK%s]         %s\n' "$GRN" "$RST" "$*"; LOG+=("[OK]         $*"); NB_OK=$((NB_OK+1)); }
ko()    { printf '  [%sECHEC%s]      %s\n' "$RED" "$RST" "$*"; LOG+=("[ECHEC]      $*"); NB_KO=$((NB_KO+1)); }
warn()  { printf '  [%sATTENTION%s]  %s\n' "$YEL" "$RST" "$*"; LOG+=("[ATTENTION]  $*"); NB_WARN=$((NB_WARN+1)); }
inf()   { printf '  [INFO]       %s\n' "$*"; LOG+=("[INFO]       $*"); }
sok()   { # action réellement faite, ou simplement simulée
  if [ "$SIM" -eq 1 ]; then printf '  [SIMULÉ]     %s\n' "$*"; LOG+=("[SIMULÉ]     $*"); else ok "$*"; fi
}
die()   { printf '%sErreur : %s%s\n' "$RED" "$*" "$RST" >&2; exit 1; }

# ---------------------------------------------------------------- questions
ask() {      # ask VARIABLE "Question" "valeur par défaut" [fonction de validation]
  local var=$1 q=$2 def=${3-} val=${4-} rep
  while true; do
    if [ -n "$def" ]; then read -r -p "$q [$def] : " rep; rep=${rep:-$def}
    else read -r -p "$q : " rep; fi
    if [ -z "$val" ] || "$val" "$rep"; then printf -v "$var" '%s' "$rep"; return 0; fi
    echo "  Valeur invalide, recommence."
  done
}
ask_opt() {  # comme ask, mais "-" (ou rien sans défaut) veut dire : ne pas en mettre
  local var=$1 q=$2 def=${3-} val=${4-} rep
  while true; do
    read -r -p "$q [${def:+$def, }- pour ignorer] : " rep; rep=${rep:-$def}
    if [ -z "$rep" ] || [ "$rep" = "-" ]; then printf -v "$var" ''; return 0; fi
    if [ -z "$val" ] || "$val" "$rep"; then printf -v "$var" '%s' "$rep"; return 0; fi
    echo "  Valeur invalide, recommence."
  done
}
confirm() {  # confirm "Question" [o|n]   (défaut : o)
  local q=$1 def=${2:-o} rep hint="[O/n]"
  [ "$def" = n ] && hint="[o/N]"
  read -r -p "$q $hint " rep; rep=${rep:-$def}
  case "$rep" in o|O|oui|OUI|y|Y|yes) return 0 ;; *) return 1 ;; esac
}

v_cidr()  { python3 -c 'import sys,ipaddress
a=sys.argv[1]
try:
    i=ipaddress.ip_interface(a); assert i.version==4 and "/" in a and 8<=i.network.prefixlen<=30
except Exception: sys.exit(1)' "$1" 2>/dev/null; }
v_ip4()   { python3 -c 'import sys,ipaddress; ipaddress.IPv4Address(sys.argv[1])' "$1" 2>/dev/null; }
v_zone()  { [[ ${1,,} =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$ ]]; }
v_iface() { [ "$1" != lo ] && [ -d "/sys/class/net/$1" ]; }
v_hosts() { local h; [ -n "$1" ] || return 1; for h in $1; do [[ ${h,,} =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || return 1; done; }
v_choice() { [[ $1 =~ ^[1-4]$ ]]; }

# ---------------------------------------------------------------- sudo
SUDO=""
if [ "$EUID" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || die "sudo est absent : lance le script en root."
  SUDO="sudo"
fi
as_root() {
  if [ "$SIM" -eq 1 ]; then echo "  (simulation) ${SUDO:+$SUDO }$*"; return 0; fi
  $SUDO "$@"
}
put_file() { # put_file DESTINATION  (contenu lu sur l'entrée standard)
  if [ "$SIM" -eq 1 ]; then echo "  (simulation) écriture de $1 :"; sed 's/^/      | /'; return 0; fi
  $SUDO tee "$1" >/dev/null
}

command -v python3 >/dev/null 2>&1 || die "python3 est nécessaire (il est installé par défaut sur Ubuntu)."
command -v dig >/dev/null 2>&1 || warn "dig est absent : il sera installé avec le paquet dnsutils."

printf '%sConfiguration d'"'"'un client DNS%s\n' "$BLD" "$RST"
[ "$SIM" -eq 1 ] && echo "Mode simulation : rien ne sera modifié."
if [ "$SIM" -eq 0 ] && [ -n "$SUDO" ]; then
  echo "Les droits administrateur vont être demandés (sudo)."
  sudo -v || die "sudo refusé."
  ( while true; do sudo -n true 2>/dev/null; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
  KEEPALIVE=$!
  trap 'kill "$KEEPALIVE" 2>/dev/null' EXIT
fi

# ---------------------------------------------------------------- détection
list_ifaces() { local d; for d in /sys/class/net/*; do d=${d##*/}; [ "$d" != lo ] && echo "$d"; done; }
nm_running() { command -v nmcli >/dev/null 2>&1 && nmcli -t -f RUNNING general 2>/dev/null | grep -q '^running'; }
nm_conn_of() { # nom de la connexion NetworkManager active sur l'interface $1
  local line dev name
  while IFS= read -r line; do
    dev=${line##*:}; name=${line%:*}; name=${name//\\:/:}
    [ "$dev" = "$1" ] && { echo "$name"; return 0; }
  done < <(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null)
  return 1
}
resolved_running() { systemctl is-active --quiet systemd-resolved 2>/dev/null; }

# ---------------------------------------------------------------- questions
title "Serveur DNS à utiliser"
ask SERVER_IP "Adresse IP du serveur DNS" "192.168.1.2" v_ip4
ask ZONE "Nom de la zone (domaine) à résoudre" "linux.local" v_zone; ZONE=${ZONE,,}
ask HOSTS "Noms de machines à tester dans la zone (séparés par des espaces)" "www" v_hosts; HOSTS=${HOSTS,,}

title "Interface du client"
DEF_IF=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
[ -z "$DEF_IF" ] && DEF_IF=$(list_ifaces | head -n1)
note "Interfaces disponibles : $(list_ifaces | tr '\n' ' ')"
ask IFACE "Interface réseau" "$DEF_IF" v_iface

HAVE_NM=0; CONN=""
if nm_running; then CONN=$(nm_conn_of "$IFACE") && HAVE_NM=1; fi
if [ "$HAVE_NM" -eq 1 ]; then note "NetworkManager gère $IFACE (connexion « $CONN »)."
else note "NetworkManager ne gère pas $IFACE (ou n'est pas lancé)."; fi

CONF_IP=0
CUR_CIDR=$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4; exit}')
CUR_GW=$(ip -4 route show default dev "$IFACE" 2>/dev/null | awk '{print $3; exit}')
note "Adresse actuelle : ${CUR_CIDR:-aucune}"
if [ "$HAVE_NM" -eq 1 ] && confirm "Fixer aussi l'adresse IP du client (NetworkManager) ?" n; then
  CONF_IP=1
  ask CLIENT_CIDR "Adresse IP du client avec son masque" "${CUR_CIDR:-192.168.1.3/24}" v_cidr
  ask_opt CLIENT_GW "Passerelle" "${CUR_GW:-}" v_ip4
fi

title "Comment le client doit-il utiliser ce serveur ?"
cat <<'EOF'
  1) NetworkManager : serveur DNS et domaine de routage enregistrés dans la connexion (durable)
  2) resolvectl     : réglage immédiat sur l'interface, perdu au redémarrage ou à la reconnexion
  3) /etc/resolv.conf statique : comme dans le TP, le fichier pointe directement vers le serveur
  4) Ne rien modifier : seulement tester
EOF
DEF_METHOD=4
if [ "$HAVE_NM" -eq 1 ]; then DEF_METHOD=1; elif resolved_running; then DEF_METHOD=2; else DEF_METHOD=3; fi
ask METHOD "Choix" "$DEF_METHOD" v_choice
if [ "$METHOD" = 1 ] && [ "$HAVE_NM" -eq 0 ]; then warn "Méthode 1 indisponible (NetworkManager ne gère pas $IFACE) : passage à la méthode 3."; METHOD=3; fi
if [ "$METHOD" = 2 ] && ! resolved_running; then warn "Méthode 2 indisponible (systemd-resolved inactif) : passage à la méthode 3."; METHOD=3; fi

title "Récapitulatif"
cat <<EOF
  Serveur DNS          : $SERVER_IP
  Zone                 : $ZONE
  Machines à tester    : $HOSTS
  Interface            : $IFACE
  Adresse du client    : $([ "$CONF_IP" -eq 1 ] && echo "$CLIENT_CIDR (passerelle ${CLIENT_GW:-aucune})" || echo "inchangée")
  Méthode              : $METHOD
EOF
echo
confirm "Lancer la configuration ?" o || { echo "Annulé, rien n'a été modifié."; exit 0; }

# ---------------------------------------------------------------- sauvegardes
BACKUP_DIR="/var/backups/dns-lab/$(date +%Y%m%d-%H%M%S)-client"
as_root mkdir -p "$BACKUP_DIR"
UNDO=()
nm_get() { nmcli -g "$1" connection show "$CONN" 2>/dev/null; }

# ---------------------------------------------------------------- outils
title "Outils"
if command -v dig >/dev/null 2>&1; then ok "dig est installé"
else
  as_root apt-get update -q
  if as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y dnsutils; then sok "dnsutils installé"
  else ko "Installation de dnsutils"; [ "$SIM" -eq 0 ] && die "dig est nécessaire pour les tests."; fi
fi

# ---------------------------------------------------------------- adresse IP
if [ "$CONF_IP" -eq 1 ]; then
  title "Adresse IP du client"
  warn "Si tu es connecté en SSH, un changement d'adresse coupe la connexion."
  {
    echo "ipv4.method:    $(nm_get ipv4.method)"
    echo "ipv4.addresses: $(nm_get ipv4.addresses)"
    echo "ipv4.gateway:   $(nm_get ipv4.gateway)"
  } | put_file "$BACKUP_DIR/ip-$CONN.txt"
  if as_root nmcli connection modify "$CONN" ipv4.method manual ipv4.addresses "$CLIENT_CIDR" ipv4.gateway "${CLIENT_GW:-}"; then
    if as_root nmcli connection up "$CONN" >/dev/null; then sok "Adresse $CLIENT_CIDR appliquée sur $IFACE"
    else ko "Activation de la connexion $CONN"; fi
  else ko "Modification de la connexion $CONN"; fi
  UNDO+=("Adresse précédente : voir $BACKUP_DIR/ip-$CONN.txt")
  sleep 2
fi

# ---------------------------------------------------------------- DNS du client
apply_nm() {
  local old_dns old_search
  old_dns=$(nm_get ipv4.dns); old_search=$(nm_get ipv4.dns-search)
  printf 'ipv4.dns: %s\nipv4.dns-search: %s\n' "$old_dns" "$old_search" | put_file "$BACKUP_DIR/dns-$CONN.txt"
  local mods=()
  grep -Fq "$SERVER_IP" <<<"$old_dns" || mods+=(+ipv4.dns "$SERVER_IP")
  grep -Fq "~$ZONE" <<<"$old_search" || mods+=(+ipv4.dns-search "~$ZONE")
  if [ "${#mods[@]}" -eq 0 ]; then note "La connexion « $CONN » utilise déjà ce serveur pour $ZONE."; return 0; fi
  if as_root nmcli connection modify "$CONN" "${mods[@]}"; then
    if as_root nmcli device reapply "$IFACE" >/dev/null 2>&1 || as_root nmcli connection up "$CONN" >/dev/null 2>&1; then
      sok "NetworkManager : $SERVER_IP enregistré pour $IFACE, domaine de routage ~$ZONE"
    else ko "Application de la connexion $CONN"; fi
  else ko "Modification de la connexion $CONN"; fi
  UNDO+=("nmcli connection modify \"$CONN\" -ipv4.dns $SERVER_IP -ipv4.dns-search ~$ZONE && nmcli device reapply $IFACE")
}
apply_resolvectl() {
  if as_root resolvectl dns "$IFACE" "$SERVER_IP" && as_root resolvectl domain "$IFACE" "~$ZONE"; then
    sok "resolvectl : $SERVER_IP et ~$ZONE sur $IFACE (valable jusqu'au prochain redémarrage ou reconnexion)"
  else ko "resolvectl"; fi
  UNDO+=("resolvectl revert $IFACE")
}
apply_static() {
  as_root cp -a /etc/resolv.conf "$BACKUP_DIR/resolv.conf.avant" 2>/dev/null
  [ -L /etc/resolv.conf ] && readlink /etc/resolv.conf | put_file "$BACKUP_DIR/resolv.conf.lien"
  [ -L /etc/resolv.conf ] && as_root rm -f /etc/resolv.conf
  printf '# Généré par setup-client.sh le %s\nnameserver %s\nsearch %s\n' "$(date '+%d/%m/%Y %H:%M')" "$SERVER_IP" "$ZONE" | put_file /etc/resolv.conf
  sok "/etc/resolv.conf pointe maintenant vers $SERVER_IP"
  warn "Le système peut réécrire ce fichier (redémarrage, reconnexion) : relance le script si la résolution cesse de marcher."
  UNDO+=("sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf   (sauvegarde : $BACKUP_DIR/resolv.conf.avant)")
}

title "Configuration DNS du client"
case "$METHOD" in
  1) apply_nm ;;
  2) apply_resolvectl ;;
  3) apply_static ;;
  4) note "Aucune modification du client." ;;
esac

# ---------------------------------------------------------------- tests
run_tests() {
  local h fq out ips ip6 ptr mdns_note=0
  local ALL_IPS=()
  title "Tests"
  if [ "$SIM" -eq 1 ]; then note "(simulation) tests non exécutés."; return; fi
  sleep 1
  ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | grep -q . \
    && ok "$IFACE a l'adresse $(ip -4 -o addr show dev "$IFACE" | awk '{print $4; exit}')" || ko "$IFACE n'a pas d'adresse IPv4"
  if ping -c1 -W2 "$SERVER_IP" >/dev/null 2>&1; then ok "Le serveur $SERVER_IP répond au ping"
  else warn "Pas de réponse au ping vers $SERVER_IP (le ping est parfois bloqué, le test DNS tranchera)"; fi

  note "-- Interrogation directe du serveur ($SERVER_IP)"
  out=$(dig +time=3 +tries=1 +noall +comments +answer -p "$PORT" "@$SERVER_IP" "$ZONE" SOA 2>&1)
  if grep -q "status: NOERROR" <<<"$out" && grep -q "SOA" <<<"$out"; then
    ok "Le serveur répond pour la zone $ZONE (SOA, serial $(awk '/SOA/{print $7; exit}' <<<"$out"))"
    grep -q 'flags:.* aa' <<<"$out" && ok "Réponse faisant autorité (drapeau aa)" || warn "Drapeau aa absent : ce serveur ne fait pas autorité sur $ZONE ?"
  else
    ko "Le serveur $SERVER_IP ne répond pas pour la zone $ZONE (port $PORT, pare-feu, zone absente ?)"
  fi
  out=$(dig +short +time=3 +tries=1 -p "$PORT" "@$SERVER_IP" "$ZONE" NS 2>/dev/null | tr '\n' ' '); [ -n "$out" ] && inf "NS de $ZONE : $out"
  out=$(dig +short +time=3 +tries=1 -p "$PORT" "@$SERVER_IP" "$ZONE" MX 2>/dev/null | tr '\n' ' '); [ -n "$out" ] && inf "MX de $ZONE : $out"

  for h in $HOSTS; do
    fq="$h.$ZONE"
    ips=$(dig +short +time=3 +tries=1 -p "$PORT" "@$SERVER_IP" "$fq" A 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$')
    if [ -n "$ips" ]; then
      ok "A $fq = $(tr '\n' ' ' <<<"$ips" | sed 's/ $//')"
      while read -r ip; do ALL_IPS+=("$ip"); done <<<"$ips"
    else
      ko "A $fq : aucune adresse trouvée"
    fi
    ip6=$(dig +short +time=3 +tries=1 -p "$PORT" "@$SERVER_IP" "$fq" AAAA 2>/dev/null | grep -E '^[0-9a-f]*:[0-9a-f:]+$' | tr '\n' ' ')
    [ -n "$ip6" ] && inf "AAAA $fq = $ip6"
    out=$(dig +short +time=3 +tries=1 -p "$PORT" "@$SERVER_IP" "$fq" CNAME 2>/dev/null | tr '\n' ' ')
    [ -n "$out" ] && inf "CNAME $fq -> $out"
  done
  mapfile -t ALL_IPS < <(printf '%s\n' "${ALL_IPS[@]}" | sort -u)
  for ip in "${ALL_IPS[@]}"; do
    ptr=$(dig +short +time=3 +tries=1 -p "$PORT" "@$SERVER_IP" -x "$ip" 2>/dev/null | tr '\n' ' ')
    if [ -n "$ptr" ]; then ok "PTR $ip -> $ptr"; else inf "Pas de PTR pour $ip (ce n'est pas forcément une erreur)"; fi
  done

  note "-- Résolution par le système (sans préciser le serveur)"
  for h in $HOSTS; do
    fq="$h.$ZONE"
    ips=$(dig +short +time=3 +tries=1 "$fq" A 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$' | tr '\n' ' ')
    used=$(dig +time=3 +tries=1 "$fq" A 2>/dev/null | awk '/^;; SERVER:/{print $3; exit}')
    if [ -n "$ips" ]; then ok "dig $fq (résolveur par défaut, via ${used:-?}) = $ips"
    else ko "dig $fq par le résolveur par défaut : aucune réponse (serveur utilisé : ${used:-inconnu})"; DEFAULT_FAIL=1; fi
    if getent hosts "$fq" >/dev/null 2>&1; then ok "getent hosts $fq : $(getent hosts "$fq" | awk '{print $1; exit}')"
    else
      warn "getent hosts $fq ne résout pas (c'est ce que voient ping et les navigateurs)"
      case "$ZONE" in *.local|local) [ "$mdns_note" -eq 0 ] && note "  Le suffixe .local est associé au mDNS : certains outils n'interrogent pas le DNS pour ces noms."; mdns_note=1 ;; esac
    fi
  done
}

DEFAULT_FAIL=0
SNAP_LOG=("${LOG[@]}"); SNAP_OK=$NB_OK; SNAP_KO=$NB_KO; SNAP_WARN=$NB_WARN
run_tests
if [ "$SIM" -eq 0 ] && [ "$DEFAULT_FAIL" -eq 1 ] && [ "$METHOD" != 3 ]; then
  echo
  echo "La résolution par défaut ne marche pas avec la méthode choisie."
  if confirm "Essayer la méthode 3 (/etc/resolv.conf pointant directement vers $SERVER_IP, comme dans le TP) ?" o; then
    LOG=("${SNAP_LOG[@]}"); NB_OK=$SNAP_OK; NB_KO=$SNAP_KO; NB_WARN=$SNAP_WARN
    inf "Premier essai : la résolution par défaut échouait avec la méthode $METHOD."
    METHOD=3; apply_static; DEFAULT_FAIL=0; run_tests
  fi
fi

# ---------------------------------------------------------------- rapport
title "Rapport"
REPORT_FILE="rapport-client-dns-$(date +%Y%m%d-%H%M%S).txt"
[ -w . ] || REPORT_FILE="/tmp/$REPORT_FILE"
{
  echo "Rapport du client DNS"
  echo "Date           : $(date '+%d/%m/%Y %H:%M:%S')"
  echo "Machine        : $(hostname)"
  echo "Mode           : $([ "$SIM" -eq 1 ] && echo simulation || echo réel)"
  echo "Interface      : $IFACE ($(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4; exit}'))"
  echo "Serveur DNS    : $SERVER_IP   Zone : $ZONE   Machines testées : $HOSTS"
  echo "Méthode        : $METHOD ($(case $METHOD in 1) echo NetworkManager;; 2) echo resolvectl;; 3) echo "resolv.conf statique";; *) echo "aucune modification";; esac))"
  if [ "$SIM" -eq 0 ] && command -v resolvectl >/dev/null 2>&1 && resolved_running; then
    echo "resolvectl     : $(resolvectl status "$IFACE" 2>/dev/null | grep -E 'DNS Servers|DNS Domain' | sed 's/^ *//' | tr '\n' ';')"
  fi
  [ -r /etc/resolv.conf ] && echo "resolv.conf    : $(grep -E '^(nameserver|search)' /etc/resolv.conf | tr '\n' ';')"
  echo "Sauvegardes    : $BACKUP_DIR"
  echo
  echo "Résultats :"
  for l in "${LOG[@]}"; do echo "  $l"; done
  echo
  echo "Bilan : $NB_OK réussi(s), $NB_KO échec(s), $NB_WARN avertissement(s)"
  if [ "${#UNDO[@]}" -gt 0 ]; then
    echo
    echo "Pour annuler les changements :"
    for u in "${UNDO[@]}"; do echo "  $u"; done
  fi
} > "$REPORT_FILE"
cat "$REPORT_FILE"
echo
echo "Rapport enregistré dans : $REPORT_FILE"
[ "$NB_KO" -eq 0 ] || exit 2
