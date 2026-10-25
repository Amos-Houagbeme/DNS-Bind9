# TP 2 : serveur DNS avec BIND9

TP de la filière Systèmes, Réseaux et Cloud (SRC) à l'ESGIS Bénin, année 2026-2027. On installe un serveur DNS BIND9 sur Ubuntu, avec une zone directe (`linux.local`) et une zone inverse (`192.168.1.0/24`), puis on teste depuis le serveur et depuis un client.

*In short: authoritative DNS server with BIND9 on Ubuntu (two KVM/libvirt VMs). Forward and reverse zones, config checked with `named-checkconf` and `named-checkzone`, records tested with `dig` from the server and from a client.*

## Contenu

- `rapport/` : le rapport complet (PDF et Word)
- `configs/` : les fichiers de configuration du serveur et du client
- `commandes/` : les commandes du TP, en scripts
- `scripts/` : installation et test automatiques, serveur et client
- `captures/` : les captures d'écran, dans l'ordre du rapport

## Le labo

Deux machines virtuelles dans le même réseau `192.168.1.0/24` (KVM/libvirt, géré avec virt-manager).

| Machine | Adresse | Rôle |
|---|---|---|
| DNS-SRV (`server-dns`) | `192.168.1.2/24` | serveur DNS, BIND9 |
| CLIENT-UBUNTU (`PC-client`) | `192.168.1.3/24` | client de test, NetworkManager |

Le serveur a une adresse fixe (Netplan, voir `configs/serveur/01-dns-server.yaml`) et s'utilise lui-même comme serveur DNS (`127.0.0.1`). La passerelle `192.168.1.1` est déclarée pour sortir du réseau, mais la communication entre les deux machines ne dépend pas d'elle.

## Installation automatique

Les deux scripts de `scripts/` refont le TP en posant les questions (adresses, nom de la zone, enregistrements...), puis testent et écrivent un rapport texte dans le dossier courant. Ils demandent `sudo` quand il le faut.

```bash
# sur DNS-SRV
./scripts/setup-serveur.sh

# sur CLIENT-UBUNTU
./scripts/setup-client.sh
```

Avec `--simulation`, ils affichent ce qu'ils feraient sans rien modifier. Pour les copier sur les machines : `scp scripts/*.sh utilisateur@192.168.1.2:`.

`setup-serveur.sh` installe BIND9, écrit le fichier Netplan (si tu le demandes), génère la zone directe et la zone inverse, les vérifie avec `named-checkzone` avant de toucher à `/etc/bind`, déclare les zones, recharge le service puis teste chaque enregistrement avec `dig`. Les fichiers remplacés sont sauvegardés dans `/var/backups/dns-lab/`. Relancé avec les mêmes réponses, il ne change rien (le numéro de série n'augmente que si les zones changent).

`setup-client.sh` propose quatre façons de pointer le client vers le serveur : NetworkManager (durable), `resolvectl` (temporaire), un `/etc/resolv.conf` fixe comme dans le TP, ou rien. Il teste d'abord le serveur directement, puis la résolution par le système. Si celle-ci échoue, il propose de passer au `resolv.conf` fixe. La commande pour annuler les changements est donnée dans le rapport.

## Installation à la main

```bash
sudo apt update
sudo apt install bind9 bind9-utils dnsutils -y
systemctl status bind9
```

`bind9` est le serveur (service `named`, config dans `/etc/bind/`), `bind9-utils` fournit `named-checkconf` et `named-checkzone`, `dnsutils` fournit `dig`. Le journal affiche des « network unreachable » pour des adresses IPv6 de serveurs racine : elles ne sont pas joignables depuis le labo, ça ne touche que la résolution vers l'extérieur.

## Les zones

Déclarées dans `/etc/bind/named.conf.local` (fichier complet dans `configs/serveur/`).

Zone `linux.local`, fichier `db.linux.local` :

| Nom | Type | Valeur |
|---|---|---|
| `dns1` | A | `192.168.1.2` |
| `www` | A | `192.168.1.10` |
| `www` | AAAA | `2001:db8::10` |
| `web` | CNAME | `www.linux.local.` |
| `@` | MX 10 | `mail.linux.local.` |
| `mail` | A | `192.168.1.20` |

Zone inverse `1.168.192.in-addr.arpa`, fichier `db.192.168.1` : un PTR qui associe `192.168.1.10` à `www.linux.local`. Pour le nom de la zone, on prend la partie réseau et on inverse les octets (`192.168.1` donne `1.168.192`).

À savoir :

- Le numéro de série du SOA (`2026101401`) doit être augmenté à chaque modification du fichier, sinon les serveurs secondaires ne voient pas le changement.
- `192.168.1.10` et `192.168.1.20` sont seulement déclarées dans le DNS. Il n'y a ni serveur web ni serveur de messagerie dans le labo.
- `2001:db8::10` est dans un préfixe réservé à la documentation, l'enregistrement AAAA ne prouve pas que l'IPv6 marche.

## Vérification

```bash
sudo named-checkconf
sudo named-checkzone linux.local /etc/bind/db.linux.local
sudo named-checkzone 1.168.192.in-addr.arpa /etc/bind/db.192.168.1
sudo systemctl reload bind9
```

`named-checkconf` n'affiche rien, les deux zones sont chargées avec le serial `2026101401` et finissent par `OK`, le rechargement passe et le journal indique `all zones loaded`.

## Tests

Sur le serveur (`commandes/tests-serveur.sh`), on interroge `127.0.0.1`. Tout répond `NOERROR` avec le drapeau `aa` (réponse d'un serveur qui fait autorité) :

| Requête | Réponse |
|---|---|
| `www.linux.local A` | `192.168.1.10` |
| `www.linux.local AAAA` | `2001:db8::10` |
| `web.linux.local CNAME` | `www.linux.local.` |
| `linux.local MX` | `10 mail.linux.local.` (avec `192.168.1.20` en section additionnelle) |
| `-x 192.168.1.10` | `www.linux.local.` |

Sur le client, `dig @192.168.1.2 www.linux.local A` renvoie `192.168.1.10`, avec `SERVER: 192.168.1.2#53`. Ces tests montrent que BIND9 sert bien les deux zones, pas que des machines existent à ces adresses.

## Le client et resolv.conf

`dig @192.168.1.2 ...` teste le serveur. `dig ...` sans `@` passe par le résolveur du client et teste donc sa configuration.

Sur CLIENT-UBUNTU, `resolvectl status` donne bien `192.168.1.2` comme serveur DNS de l'interface, mais `/etc/resolv.conf` (mode stub, géré par `systemd-resolved`) contient `nameserver 127.0.0.53`. Résultat : `dig www.linux.local A` sans `@` interroge `127.0.0.53` et finit en `SERVFAIL`.

On a commenté les trois lignes du fichier (`nameserver 127.0.0.53`, `options`, `search`) et ajouté `nameserver 192.168.1.2` (voir `configs/client/resolv.conf`). Après ça, la même commande interroge `192.168.1.2` et renvoie `192.168.1.10`.

Limites : on n'a pas cherché pourquoi le `SERVFAIL` apparaissait au départ, et le fichier est géré par le système, donc notre modification peut être écrasée (on a dû la refaire). Une solution plus durable serait de donner `192.168.1.2` et le domaine `~linux.local` à NetworkManager avec `nmcli`, mais on ne l'a pas testée.

## Le suffixe .local

Le domaine du TP est `linux.local`, mais `.local` est réservé au mDNS. C'est pour ça que `dig` affiche « .local is reserved for Multicast DNS ». Le serveur répond quand même ; `ping` ou un navigateur pourraient se comporter autrement.

## Ce qui n'est pas fait

- pas de serveur secondaire ni de transfert de zone
- résolution de noms externes non testée
- pas de serveur web ni de messagerie derrière `www` et `mail`

## Captures

| Fichier | Contenu |
|---|---|
| `01-netplan-serveur.png` | Netplan et adresse de `enp1s0` |
| `02-etat-bind9.png` | état du service |
| `03-zone-directe.png` | `named.conf.local` et `db.linux.local` |
| `04-zone-inverse.png` | `named.conf.local` (2 zones) et `db.192.168.1` |
| `05-verification.png` | vérification et rechargement |
| `06` à `10` | tests `dig` sur le serveur (A, AAAA, CNAME, MX, PTR) |
| `11-dig-client.png` | test depuis le client |
| `12-client-avant.png` | configuration du client avant modification |
| `13-servfail.png` | `dig` sans `@` : `SERVFAIL` |
| `14-apres-resolv-conf.png` | même test après modification |
