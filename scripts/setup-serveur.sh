#!/bin/bash
# setup-serveur.sh
# Installe et configure un serveur DNS BIND9 sur Ubuntu : réseau (Netplan),
# zone directe, zone inverse. Pose les questions, vérifie, teste, puis écrit un rapport.
#
# Usage : ./setup-serveur.sh [--simulation]
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
sok()   { # action réellement faite, ou simplement simulée
  if [ "$SIM" -eq 1 ]; then printf '  [SIMULÉ]     %s\n' "$*"; LOG+=("[SIMULÉ]     $*"); else ok "$*"; fi
}
warn()  { printf '  [%sATTENTION%s]  %s\n' "$YEL" "$RST" "$*"; LOG+=("[ATTENTION]  $*"); NB_WARN=$((NB_WARN+1)); }
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
v_ip6()   { python3 -c 'import sys,ipaddress; ipaddress.IPv6Address(sys.argv[1])' "$1" 2>/dev/null; }
v_label() { [[ ${1,,} =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; }
v_zone()  { [[ ${1,,} =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$ ]]; }
v_num()   { [[ $1 =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ]; }
v_iface() { [ "$1" != lo ] && [ -d "/sys/class/net/$1" ]; }
v_pair()  { local n=${1%%=*} a=${1#*=}; [ "$n" != "$1" ] && v_label "$n" && v_ip4 "$a"; }
norm6()   { python3 -c 'import sys,ipaddress; print(ipaddress.IPv6Address(sys.argv[1]).compressed)' "$1"; }

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
  local dest=$1
  if [ "$SIM" -eq 1 ]; then echo "  (simulation) écriture de $dest :"; sed 's/^/      | /'; return 0; fi
  $SUDO tee "$dest" >/dev/null
}

# ---------------------------------------------------------------- vérifications de départ
command -v python3 >/dev/null 2>&1 || die "python3 est nécessaire (il est installé par défaut sur Ubuntu)."
command -v apt-get >/dev/null 2>&1 || die "Ce script est prévu pour Ubuntu/Debian (apt)."
command -v systemctl >/dev/null 2>&1 || die "systemd est nécessaire."
command -v ip >/dev/null 2>&1 || die "La commande ip est introuvable."

printf '%sConfiguration d'"'"'un serveur DNS BIND9%s\n' "$BLD" "$RST"
[ "$SIM" -eq 1 ] && echo "Mode simulation : rien ne sera modifié."
if [ "$SIM" -eq 0 ] && [ -n "$SUDO" ]; then
  echo "Les droits administrateur vont être demandés (sudo)."
  sudo -v || die "sudo refusé."
  ( while true; do sudo -n true 2>/dev/null; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
  KEEPALIVE=$!
  trap 'kill "$KEEPALIVE" 2>/dev/null' EXIT
fi

# ---------------------------------------------------------------- réseau : questions
title "Réseau du serveur"
list_ifaces() { local d; for d in /sys/class/net/*; do d=${d##*/}; [ "$d" != lo ] && echo "$d"; done; }
INTERFACES=$(list_ifaces | tr '\n' ' ')
DEF_IF=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
[ -z "$DEF_IF" ] && DEF_IF=$(list_ifaces | head -n1)
note "Interfaces disponibles : $INTERFACES"
ask IFACE "Interface réseau" "$DEF_IF" v_iface

CUR_CIDR=$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4; exit}')
CUR_GW=$(ip -4 route show default dev "$IFACE" 2>/dev/null | awk '{print $3; exit}')
ask IP_CIDR "Adresse IP du serveur avec son masque (ex. 192.168.1.2/24)" "${CUR_CIDR:-192.168.1.2/24}" v_cidr
SERVER_IP=${IP_CIDR%/*}
ask_opt GATEWAY "Passerelle par défaut" "${CUR_GW:-}" v_ip4
ask DNS_SELF "Serveur DNS utilisé par ce serveur (lui-même)" "127.0.0.1" v_ip4

# ---------------------------------------------------------------- zone : questions
title "Zone DNS"
ask ZONE "Nom de la zone (domaine)" "linux.local" v_zone;           ZONE=${ZONE,,}
ask NS_LABEL "Nom de ce serveur DNS dans la zone" "dns1" v_label;    NS_LABEL=${NS_LABEL,,}
ask ADMIN "Contact de l'administrateur (devient admin.$ZONE)" "admin" v_label; ADMIN=${ADMIN,,}
ask TTL "Durée de vie par défaut des enregistrements, en secondes" "86400" v_num

SOA_REFRESH=3600; SOA_RETRY=1800; SOA_EXPIRE=604800; SOA_NEG=86400
if confirm "Modifier les paramètres avancés du SOA (refresh, retry, expire) ?" n; then
  ask SOA_REFRESH "Refresh (s)" "$SOA_REFRESH" v_num
  ask SOA_RETRY   "Retry (s)"   "$SOA_RETRY"   v_num
  ask SOA_EXPIRE  "Expire (s)"  "$SOA_EXPIRE"  v_num
  ask SOA_NEG     "TTL négatif (s)" "$SOA_NEG" v_num
fi

title "Enregistrements"
BASE=${SERVER_IP%.*}
REC=""
addrec() { REC+="$1|$2|$3"$'\n'; }
addrec A "$NS_LABEL" "$SERVER_IP"

ask_opt WWW "Nom du site web" "www" v_label;  WWW=${WWW,,}
WWW_IP4=""; WWW_IP6=""; ALIAS=""
if [ -n "$WWW" ]; then
  ask_opt WWW_IP4 "Adresse IPv4 de $WWW.$ZONE" "$BASE.10" v_ip4
  ask_opt WWW_IP6 "Adresse IPv6 de $WWW.$ZONE" "2001:db8::10" v_ip6
  [ -n "$WWW_IP6" ] && WWW_IP6=$(norm6 "$WWW_IP6")
  if [ -n "$WWW_IP4" ] || [ -n "$WWW_IP6" ]; then
    ask_opt ALIAS "Alias (CNAME) vers $WWW.$ZONE" "web" v_label; ALIAS=${ALIAS,,}
  fi
fi
[ -n "$WWW_IP4" ] && addrec A "$WWW" "$WWW_IP4"
[ -n "$WWW_IP6" ] && addrec AAAA "$WWW" "$WWW_IP6"
[ -n "$ALIAS" ] && addrec CNAME "$ALIAS" "$WWW"

ask_opt MAIL "Nom du serveur de messagerie (MX)" "mail" v_label; MAIL=${MAIL,,}
if [ -n "$MAIL" ]; then
  ask MAIL_IP4 "Adresse IPv4 de $MAIL.$ZONE" "$BASE.20" v_ip4
  ask MX_PRIO "Priorité du MX" "10" v_num
  addrec A "$MAIL" "$MAIL_IP4"
  addrec MX "@" "$MX_PRIO $MAIL"
fi

while true; do
  read -r -p "Autre enregistrement A, au format nom=adresse (Entrée pour terminer) : " x
  [ -z "$x" ] && break
  if v_pair "$x"; then x=${x,,}; addrec A "${x%%=*}" "${x#*=}"; else echo "  Format attendu : ftp=192.168.1.30"; fi
done

title "Zone inverse"
ask PTR_NAMES "Noms pour lesquels créer un PTR (séparés par des espaces, ou 'tous')" "${WWW:-tous}"

# ---------------------------------------------------------------- options système
title "Options"
CONF_NET=0
if ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | grep -qx "$IP_CIDR"; then
  note "$IFACE a déjà l'adresse $IP_CIDR."
  confirm "Réécrire quand même la configuration Netplan ?" n && CONF_NET=1
else
  confirm "Configurer l'adresse avec Netplan ?" o && CONF_NET=1
fi
NP_FILE="01-dns-server.yaml"
[ "$CONF_NET" -eq 1 ] && ask NP_FILE "Nom du fichier Netplan" "$NP_FILE"

UFW_OPEN=0
if command -v ufw >/dev/null 2>&1 && $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then
  confirm "Le pare-feu ufw est actif : autoriser le port 53 (TCP et UDP) ?" o && UFW_OPEN=1
fi

# ---------------------------------------------------------------- récapitulatif
title "Récapitulatif"
cat <<EOF
  Interface            : $IFACE
  Adresse              : $IP_CIDR
  Passerelle           : ${GATEWAY:-aucune}
  DNS du serveur       : $DNS_SELF
  Zone directe         : $ZONE (serveur $NS_LABEL.$ZONE, contact $ADMIN.$ZONE)
  TTL                  : $TTL
  Enregistrements      :
$(printf '%s' "$REC" | awk -F'|' '{printf "      %-6s %-10s %s\n", $1, $2, $3}')
  PTR pour             : $PTR_NAMES
  Netplan              : $([ "$CONF_NET" -eq 1 ] && echo "oui (/etc/netplan/$NP_FILE)" || echo "non, réseau inchangé")
  Pare-feu             : $([ "$UFW_OPEN" -eq 1 ] && echo "ouverture du port 53" || echo "inchangé")
EOF
echo
confirm "Lancer la configuration ?" o || { echo "Annulé, rien n'a été modifié."; exit 0; }

# ---------------------------------------------------------------- sauvegardes
BACKUP_DIR="/var/backups/dns-lab/$(date +%Y%m%d-%H%M%S)"
CREATED=()          # fichiers créés par le script (pour pouvoir les retirer en cas d'échec)
backup() {          # backup /chemin/fichier
  [ -e "$1" ] || return 0
  as_root mkdir -p "$BACKUP_DIR"
  as_root cp -a "$1" "$BACKUP_DIR/$(echo "$1" | tr '/' '_')"
}
restore() {         # restore /chemin/fichier
  local b
  b="$BACKUP_DIR/$(echo "$1" | tr '/' '_')"
  if [ -e "$b" ]; then as_root cp -a "$b" "$1"; fi
}

# ---------------------------------------------------------------- 1. paquets
title "Installation de BIND9"
if dpkg -s bind9 bind9-utils dnsutils >/dev/null 2>&1; then
  ok "bind9, bind9-utils et dnsutils sont déjà installés"
else
  as_root apt-get update -q
  if as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y bind9 bind9-utils dnsutils; then
    sok "Paquets installés : bind9, bind9-utils, dnsutils"
  else
    ko "Installation des paquets"
    [ "$SIM" -eq 0 ] && die "Installation impossible, arrêt."
  fi
fi

# ---------------------------------------------------------------- 2. réseau
if [ "$CONF_NET" -eq 1 ]; then
  title "Configuration réseau (Netplan)"
  warn "Si tu es connecté en SSH, un changement d'adresse coupe la connexion."
  NP_PATH="/etc/netplan/$NP_FILE"
  backup "$NP_PATH"
  # autres fichiers Netplan qui configurent la même interface
  for f in /etc/netplan/*.yaml; do
    [ -e "$f" ] && [ "$f" != "$NP_PATH" ] || continue
    if grep -qw "$IFACE" "$f" 2>/dev/null; then
      if confirm "$f configure aussi $IFACE. Le désactiver (renommé en .yaml.bak) ?" o; then
        backup "$f"; as_root mv "$f" "$f.bak"; note "$f désactivé."
      else
        warn "$f configure aussi $IFACE : les deux fichiers peuvent se contredire."
      fi
    fi
  done
  {
    echo "network:"
    echo "  version: 2"
    echo "  ethernets:"
    echo "    $IFACE:"
    echo "      dhcp4: false"
    echo "      addresses:"
    echo "        - $IP_CIDR"
    if [ -n "$GATEWAY" ]; then
      echo "      routes:"
      echo "        - to: default"
      echo "          via: $GATEWAY"
    fi
    echo "      nameservers:"
    echo "        addresses:"
    echo "          - $DNS_SELF"
  } | put_file "$NP_PATH"
  as_root chmod 600 "$NP_PATH"
  if as_root netplan generate; then
    sok "Fichier Netplan valide ($NP_PATH)"
    note "Application de la configuration : confirme dans les 60 secondes, sinon elle sera annulée."
    if as_root netplan try --timeout 60; then sok "Configuration réseau appliquée : $IP_CIDR sur $IFACE"
    else ko "Application Netplan refusée ou expirée (ancienne configuration rétablie)"; fi
  else
    ko "Fichier Netplan invalide, ancienne configuration remise"
    restore "$NP_PATH"
  fi
  sleep 2
fi

# ---------------------------------------------------------------- 3. fichiers de zone
title "Fichiers de zone"
STAGE=$(mktemp -d)
today=$(date +%Y%m%d)
export ZONE NS_LABEL ADMIN TTL IP_CIDR SOA_REFRESH SOA_RETRY SOA_EXPIRE SOA_NEG PTR_NAMES STAGE
export RECORDS="$REC"

# Générateur des fichiers de zone (Python, pour calculer la zone inverse et aligner les colonnes)
read -r -d '' PYGEN <<'PYEOF'
import os, sys, ipaddress
e = os.environ
zone, ns, admin = e["ZONE"], e["NS_LABEL"], e["ADMIN"]
recs = [l.split("|", 2) for l in e["RECORDS"].splitlines() if l.strip()]
net = ipaddress.ip_interface(e["IP_CIDR"]).network

def fq(n):
    if n == "@": return zone + "."
    return n if n.endswith(".") else n + "." + zone + "."

def soa(extra=""):
    return ["$TTL %s" % e["TTL"],
            "@ IN SOA %s.%s. %s.%s. (" % (ns, zone, admin, zone),
            "    %s" % e["SERIAL"], "    %s" % e["SOA_REFRESH"], "    %s" % e["SOA_RETRY"],
            "    %s" % e["SOA_EXPIRE"], "    %s" % e["SOA_NEG"], ")", ""]

# zone directe
rows = []
for typ, name, val in recs:
    if typ == "CNAME": val = fq(val)
    elif typ == "MX":
        prio, host = val.split(); val = "%s %s" % (prio, fq(host))
    rows.append((name, typ, val))
w = max([len(r[0]) for r in rows] + [1])
lines = soa() + ["%s IN NS    %s.%s." % ("@".ljust(w), ns, zone)]
lines += ["%s IN %-5s %s" % (n.ljust(w), t, v) for n, t, v in rows]
fwd = "db." + zone
open(os.path.join(e["STAGE"], fwd), "w").write("\n".join(lines) + "\n")

# zone inverse
p = net.prefixlen
n_oct = min(max(p // 8, 1), 3)
if p % 8:
    print("Masque /%d : la zone inverse couvre tout le /%d." % (p, n_oct * 8), file=sys.stderr)
base = str(net.network_address).split(".")[:n_oct]
rev_zone = ".".join(reversed(base)) + ".in-addr.arpa"
rev_file = "db." + ".".join(base)
a_recs = {n: v for t, n, v in recs if t == "A"}
wanted = e["PTR_NAMES"].split()
names = list(a_recs) if wanted == ["tous"] else wanted
ptr = []
for n in names:
    ip = a_recs.get(n)
    if ip is None:
        print("PTR ignoré : %s n'a pas d'enregistrement A." % n, file=sys.stderr); continue
    parts = ip.split(".")
    if parts[:n_oct] != base:
        print("PTR ignoré : %s (%s) est hors du réseau %s." % (n, ip, net), file=sys.stderr); continue
    ptr.append((".".join(reversed(parts[n_oct:])), ip, fq(n)))
lines = soa() + ["@  IN NS  %s.%s." % (ns, zone)]
lines += ["%s IN PTR %s" % (lab.ljust(max([len(x[0]) for x in ptr] + [1])), f) for lab, ip, f in ptr]
open(os.path.join(e["STAGE"], rev_file), "w").write("\n".join(lines) + "\n")
print(fwd); print(rev_zone); print(rev_file)
for lab, ip, f in ptr: print("PTR|%s|%s" % (ip, f))
PYEOF

gen_zones() {   # génère les deux fichiers dans $STAGE avec le serial $SERIAL
  export SERIAL
  mapfile -t GEN < <(python3 -c "$PYGEN")
  [ "${#GEN[@]}" -ge 3 ] || die "Impossible de générer les fichiers de zone."
}

# Si les fichiers existent déjà et ne changent pas, on garde leur numéro de série.
old=""
[ -r "/etc/bind/db.$ZONE" ] && old=$(grep -Eo '[0-9]{10}' "/etc/bind/db.$ZONE" | head -n1)
SERIAL="${today}01"
if [ -n "$old" ]; then
  SERIAL=$old; gen_zones
  if cmp -s "$STAGE/${GEN[0]}" "/etc/bind/${GEN[0]}" && cmp -s "$STAGE/${GEN[2]}" "/etc/bind/${GEN[2]}"; then
    note "Les zones existantes sont identiques : le numéro de série ($old) est conservé."
  else
    SERIAL="${today}01"; [ "$old" -ge "$SERIAL" ] && SERIAL=$((old+1))
    gen_zones
  fi
else
  gen_zones
fi
FWD_FILE=${GEN[0]}; REV_ZONE=${GEN[1]}; REV_FILE=${GEN[2]}
PTR_LIST=("${GEN[@]:3}")
ok "Fichiers générés : $FWD_FILE (zone $ZONE) et $REV_FILE (zone $REV_ZONE), serial $SERIAL"

if command -v named-checkzone >/dev/null 2>&1; then
  if named-checkzone "$ZONE" "$STAGE/$FWD_FILE" >/dev/null 2>&1; then ok "named-checkzone $ZONE : OK"
  else ko "named-checkzone $ZONE"; named-checkzone "$ZONE" "$STAGE/$FWD_FILE"; die "Fichier de zone invalide, rien n'a été installé."; fi
  if named-checkzone "$REV_ZONE" "$STAGE/$REV_FILE" >/dev/null 2>&1; then ok "named-checkzone $REV_ZONE : OK"
  else ko "named-checkzone $REV_ZONE"; named-checkzone "$REV_ZONE" "$STAGE/$REV_FILE"; die "Fichier de zone inverse invalide, rien n'a été installé."; fi
else
  warn "named-checkzone absent (paquets pas encore installés en simulation) : zones non vérifiées"
fi

# ---------------------------------------------------------------- 4. installation dans /etc/bind
title "Installation dans /etc/bind"
BIND_DIR=/etc/bind
for f in "$FWD_FILE" "$REV_FILE"; do
  if [ -e "$BIND_DIR/$f" ]; then
    if cmp -s "$STAGE/$f" "$BIND_DIR/$f"; then note "$f est déjà à jour."; continue; fi
    confirm "$BIND_DIR/$f existe déjà. Le remplacer (une sauvegarde est faite) ?" o || { warn "$f conservé tel quel"; continue; }
    backup "$BIND_DIR/$f"
  else
    CREATED+=("$BIND_DIR/$f")
  fi
  put_file "$BIND_DIR/$f" < "$STAGE/$f"
  as_root chown root:bind "$BIND_DIR/$f" 2>/dev/null || true
  as_root chmod 644 "$BIND_DIR/$f"
  sok "$BIND_DIR/$f installé"
done

LOCAL_CONF="$BIND_DIR/named.conf.local"
backup "$LOCAL_CONF"
declare_zone() { # declare_zone nom fichier
  if [ -r "$LOCAL_CONF" ] && grep -Fq "zone \"$1\"" "$LOCAL_CONF"; then
    note "La zone $1 est déjà déclarée dans named.conf.local."
  else
    printf '\nzone "%s" {\n    type master;\n    file "%s/%s";\n};\n' "$1" "$BIND_DIR" "$2" |
      { if [ "$SIM" -eq 1 ]; then echo "  (simulation) ajout à $LOCAL_CONF :"; sed 's/^/      | /'; else $SUDO tee -a "$LOCAL_CONF" >/dev/null; fi; }
    sok "Zone $1 déclarée dans named.conf.local"
  fi
}
declare_zone "$ZONE" "$FWD_FILE"
declare_zone "$REV_ZONE" "$REV_FILE"

rollback() {
  warn "Retour à la configuration précédente."
  restore "$LOCAL_CONF"
  for f in "${CREATED[@]}"; do as_root rm -f "$f"; done
  restore "$BIND_DIR/$FWD_FILE"; restore "$BIND_DIR/$REV_FILE"
}
if command -v named-checkconf >/dev/null 2>&1; then
  if as_root named-checkconf; then sok "named-checkconf : OK"
  else ko "named-checkconf"; rollback; die "Configuration BIND invalide. Sauvegardes dans $BACKUP_DIR."; fi
fi

# ---------------------------------------------------------------- 5. service
title "Service BIND9"
SVC=bind9
systemctl list-unit-files 2>/dev/null | grep -q '^named\.service' && SVC=named
if [ "$SIM" -eq 1 ]; then
  note "(simulation) systemctl enable --now $SVC, puis reload"
elif systemctl is-active --quiet "$SVC"; then
  as_root systemctl reload "$SVC" && sok "Service $SVC rechargé" || ko "Rechargement de $SVC"
else
  as_root systemctl enable --now "$SVC" && sok "Service $SVC démarré et activé au démarrage" || ko "Démarrage de $SVC"
fi
if [ "$UFW_OPEN" -eq 1 ]; then
  as_root ufw allow 53 >/dev/null && sok "Pare-feu : port 53 autorisé" || ko "Pare-feu : ouverture du port 53"
fi
rm -rf "$STAGE"

# ---------------------------------------------------------------- 6. tests
title "Tests"
if [ "$SIM" -eq 1 ]; then
  note "(simulation) tests non exécutés."
else
  sleep 2
  fqdn() { [ "$1" = "@" ] && echo "$ZONE" || echo "$1.$ZONE"; }
  t_dig() {   # t_dig "libellé" "attendu" serveur nom type
    local label=$1 expect=$2 srv=$3 name=$4 type=$5 out
    out=$(dig +time=3 +tries=1 +noall +comments +answer -p "$PORT" "@$srv" "$name" "$type" 2>&1)
    if grep -q "status: NOERROR" <<<"$out" && grep -Fq -- "$expect" <<<"$out"; then ok "$label"
    else ko "$label (attendu : $expect)"; fi
  }
  systemctl is-active --quiet "$SVC" && ok "Service $SVC actif" || ko "Service $SVC inactif"
  systemctl is-enabled --quiet "$SVC" 2>/dev/null && ok "Service $SVC activé au démarrage" || warn "Service $SVC non activé au démarrage"
  ip -4 -o addr show 2>/dev/null | awk '{print $4}' | grep -qx "$IP_CIDR" && ok "Adresse $IP_CIDR présente sur le serveur" || warn "Adresse $IP_CIDR absente (réseau non configuré par le script ?)"

  t_dig "SOA de $ZONE (serial $SERIAL)" "$SERIAL" 127.0.0.1 "$ZONE" SOA
  t_dig "NS de $ZONE" "$NS_LABEL.$ZONE." 127.0.0.1 "$ZONE" NS
  while IFS='|' read -r typ name val; do
    [ -z "$typ" ] && continue
    case "$typ" in
      A)     t_dig "A $(fqdn "$name") = $val" "$val" 127.0.0.1 "$(fqdn "$name")" A ;;
      AAAA)  t_dig "AAAA $(fqdn "$name") = $val" "$val" 127.0.0.1 "$(fqdn "$name")" AAAA ;;
      CNAME) t_dig "CNAME $(fqdn "$name") -> $(fqdn "$val")" "$(fqdn "$val")." 127.0.0.1 "$(fqdn "$name")" CNAME ;;
      MX)    t_dig "MX $ZONE = ${val% *} $(fqdn "${val#* }")" "${val% *} $(fqdn "${val#* }")." 127.0.0.1 "$ZONE" MX ;;
    esac
  done <<<"$REC"
  for p in "${PTR_LIST[@]}"; do
    IFS='|' read -r _ ip host <<<"$p"
    t_dig "PTR $ip -> $host" "$host" 127.0.0.1 "$(python3 -c 'import sys,ipaddress; print(ipaddress.ip_address(sys.argv[1]).reverse_pointer)' "$ip")" PTR
  done
  dig +noall +comments -p "$PORT" @127.0.0.1 "$ZONE" SOA 2>&1 | grep -q 'flags:.* aa' && ok "Les réponses font autorité (drapeau aa)" || ko "Drapeau aa absent"
  t_dig "Le serveur répond aussi sur $SERVER_IP" "$SERVER_IP" "$SERVER_IP" "$NS_LABEL.$ZONE" A
fi

# ---------------------------------------------------------------- 7. rapport
title "Rapport"
REPORT_FILE="rapport-serveur-dns-$(date +%Y%m%d-%H%M%S).txt"
[ -w . ] || REPORT_FILE="/tmp/$REPORT_FILE"
{
  echo "Rapport du serveur DNS"
  echo "Date           : $(date '+%d/%m/%Y %H:%M:%S')"
  echo "Machine        : $(hostname)"
  echo "Mode           : $([ "$SIM" -eq 1 ] && echo simulation || echo réel)"
  echo "Interface      : $IFACE, $IP_CIDR, passerelle ${GATEWAY:-aucune}"
  echo "Zone directe   : $ZONE ($FWD_FILE)"
  echo "Zone inverse   : $REV_ZONE ($REV_FILE)"
  echo "Serial         : $SERIAL"
  if [ "$SIM" -eq 0 ]; then
    echo "BIND           : $(named -v 2>/dev/null)"
    echo "Service        : $(systemctl is-active "$SVC") / $(systemctl is-enabled "$SVC" 2>/dev/null)"
    echo "Écoute port 53 : $(ss -H -lnu 2>/dev/null | awk '{print $4}' | grep -E ':53$' | tr '\n' ' ')"
  fi
  echo "Sauvegardes    : $BACKUP_DIR"
  echo
  echo "Enregistrements :"
  printf '%s' "$REC" | awk -F'|' '{printf "  %-6s %-10s %s\n", $1, $2, $3}'
  echo
  echo "Résultats :"
  for l in "${LOG[@]}"; do echo "  $l"; done
  echo
  echo "Bilan : $NB_OK réussi(s), $NB_KO échec(s), $NB_WARN avertissement(s)"
  echo
  echo "Sur le client, lancer scripts/setup-client.sh avec :"
  echo "  serveur DNS = $SERVER_IP   zone = $ZONE"
} > "$REPORT_FILE"
cat "$REPORT_FILE"
echo
echo "Rapport enregistré dans : $REPORT_FILE"
[ "$NB_KO" -eq 0 ] || exit 2
