#!/bin/bash

declare -A IP_TO_USER
IP_TO_USER["84.201.241.141"]="openwrt"
IP_TO_USER["178.178.243.230"]="Ronego"

nft add table inet traffic 2>/dev/null

for chain in $(nft -a list chains inet traffic 2>/dev/null | grep -oP 'chain \K[^ ]+' | head -100); do
    nft delete chain inet traffic "$chain" 2>/dev/null
done

echo "["
first=true
for ip in "${!IP_TO_USER[@]}"; do
    user="${IP_TO_USER[$ip]}"
    chain_in="traffic_in_${user}_${ip//./_}"
    chain_out="traffic_out_${user}_${ip//./_}"
    
    if ! nft list chain inet traffic "$chain_in" 2>/dev/null | grep -q "Chain"; then
        nft add chain inet traffic "$chain_in" { type filter hook input priority 0\; }
        nft add rule inet traffic "$chain_in" ip saddr "$ip" counter
    fi
    
    if ! nft list chain inet traffic "$chain_out" 2>/dev/null | grep -q "Chain"; then
        nft add chain inet traffic "$chain_out" { type filter hook output priority 0\; }
        nft add rule inet traffic "$chain_out" ip daddr "$ip" counter
    fi
    
    upload=$(nft list chain inet traffic "$chain_in" | grep "ip saddr $ip" | grep -oP 'bytes \K[0-9]+' | head -1)
    download=$(nft list chain inet traffic "$chain_out" | grep "ip daddr $ip" | grep -oP 'bytes \K[0-9]+' | head -1)
    
    if [ "$first" = true ]; then
        first=false
    else
        echo ","
    fi
    echo "{\"user\":\"$user\",\"ip\":\"$ip\",\"upload\":${upload:-0},\"download\":${download:-0}}"
done
echo "]"
