#!/bin/bash
export PATH=$PATH:/usr/sbin:/usr/local/sbin

# 1. Собираем логи
mapfile -t LOGS < <(docker logs sing-box --tail 5000 2>&1)

# 2. Парсим: сначала находим IP, потом ищем имя в следующих строках
> /tmp/ip_user_map.txt
for ((i=0; i<${#LOGS[@]}; i++)); do
    line="${LOGS[$i]}"
    
    # Ищем строку с IP
    if echo "$line" | grep -q 'inbound connection from [0-9.]\+'; then
        ip=$(echo "$line" | grep -oP 'inbound connection from \K[0-9.]+')
        
        # Ищем имя пользователя в следующих 10 строках
        for ((j=i+1; j<i+10 && j<${#LOGS[@]}; j++)); do
            user=$(echo "${LOGS[$j]}" | grep -oP '\[[A-Za-z0-9_]+\]' | tail -1 | tr -d '[]')
            if [[ -n "$user" && "$user" != "REALITY" ]]; then
                echo "$ip:$user" >> /tmp/ip_user_map.txt
                break
            fi
        done
    fi
done

# 3. Уникальные маппинги
declare -A IP_TO_USER
while IFS=: read -r ip user; do
    IP_TO_USER["$ip"]="$user"
done < <(sort -u /tmp/ip_user_map.txt)

# 4. Создаем таблицу nft
nft add table inet traffic 2>/dev/null

# 5. Очищаем старые цепочки
for chain in $(nft -a list chains inet traffic 2>/dev/null | grep -oP 'chain \K[^ ]+' | head -100); do
    nft delete chain inet traffic "$chain" 2>/dev/null
done

# 6. Собираем статистику
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
