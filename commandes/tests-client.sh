#!/bin/bash
# À lancer sur CLIENT-UBUNTU

# on interroge directement le serveur
dig @192.168.1.2 www.linux.local A

# sans @, dig passe par /etc/resolv.conf
# ça ne marche qu'une fois "nameserver 192.168.1.2" ajouté dans ce fichier
dig www.linux.local A
