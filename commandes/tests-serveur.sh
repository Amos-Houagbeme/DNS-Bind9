#!/bin/bash
# À lancer sur DNS-SRV : on interroge BIND9 en local

dig @127.0.0.1 www.linux.local A
dig @127.0.0.1 www.linux.local AAAA
dig @127.0.0.1 web.linux.local CNAME
dig @127.0.0.1 linux.local MX
dig -x 192.168.1.10 @127.0.0.1
