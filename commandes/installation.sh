#!/bin/bash
# Installation de BIND9 sur DNS-SRV

sudo apt update
sudo apt install bind9 bind9-utils dnsutils -y

# le service s'appelle named
systemctl status bind9
