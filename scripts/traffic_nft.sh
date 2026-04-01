
#!/bin/bash
export PATH=$PATH:/usr/sbin:/usr/local/sbin

# Собираем логи
mapfile -t LOGS < <(docker logs sing-box --tail 1500 2>&1)

# Собираем ID -> IP
declare -A ID_TO_IP
for line in "${LOGS[@]}"; do
    if [[ "$line" =~ inbound\ connection\ from\ ([0-9.]+) ]]; then
        ip="${BASH_REMATCH[1]}"
        if [[ "$line" =~ \[([0-9]+) ]]; then
            id="${BASH_REMATCH[1]}"
            ID_TO_IP["$id"]="$ip"
        fi
    fi
done

# Собираем ID -> пользователь (только строки с inbound/vless[REALITY]: [имя])
declare -A ID_TO_USER
for line in "${LOGS[@]}"; do
    if [[ "$line" =~ inbound/vless\[REALITY\]:\ \[([A-Za-z0-9_]+)\] ]]; then
        user="${BASH_REMATCH[1]}"
        if [[ "$user" != "REALITY" ]]; then
            if [[ "$line" =~ \[([0-9]+) ]]; then
                id="${BASH_REMATCH[1]}"
                ID_TO_USER["$id"]="$user"
            fi
        fi
    fi
done

# Связываем IP и пользователя через ID
> /tmp/ip_user_map.txt
for id in "${!ID_TO_IP[@]}"; do
    ip="${ID_TO_IP[$id]}"
    user="${ID_TO_USER[$id]}"
    if [[ -n "$ip" && -n "$user" ]]; then
        echo "$ip:$user" >> /tmp/ip_user_map.txt
    fi
done

# Уникальные маппинги (последнее вхождение)
declare -A IP_TO_USER
while IFS=: read -r ip user; do
    IP_TO_USER["$ip"]="$user"
done < <(tac /tmp/ip_user_map.txt | sort -u -t: -k1,1)

# Создаем таблицу nft
nft add table inet traffic 2>/dev/null

# Очищаем старые цепочки
for chain in $(nft -a list chains inet traffic 2>/dev/null | grep -oP 'chain \K[^ ]+' | head -100); do
    nft delete chain inet traffic "$chain" 2>/dev/null
done

# Собираем статистику
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

rm -f /tmp/ip_user_map.txt
