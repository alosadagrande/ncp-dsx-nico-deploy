#/bin/bash

D=$(curl -sfI http://172.16.2.12/ | awk -F': ' 'tolower($1)=="date"{print $2}' | tr -d '\r')
echo "server: $D"
sudo date -u -s "$D"                       # GNU date parsea "Wed, 04 Nov 2026 21:12:00 GMT"
sudo hwclock --systohc 2>/dev/null || true
