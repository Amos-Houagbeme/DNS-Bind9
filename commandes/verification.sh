#!/bin/bash
# À lancer sur DNS-SRV avant de recharger BIND9
# named-checkconf ne doit rien afficher, named-checkzone doit finir par OK

sudo named-checkconf
sudo named-checkzone linux.local /etc/bind/db.linux.local
sudo named-checkzone 1.168.192.in-addr.arpa /etc/bind/db.192.168.1

# relit la configuration sans arrêter le service
sudo systemctl reload bind9
systemctl status bind9
