#!/bin/bash
export PATH=$PATH:/usr/sbin:/usr/local/sbin

MAP_FILE="/opt/singbox-stats/ip_user_map.txt"
TEMP_FILE="/tmp/ip_user_freq.txt"

# Собираем логи
mapfile -t LOGS < <(docker logs sing-box --tail 5000 2>&1)

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

# Собираем ID -> пользователь (исключая outbound)
declare -A ID_TO_USER
for line in "${LOGS[@]}"; do
    [[ "$line" =~ outbound ]] && continue
    if [[ "$line" =~ \[([0-9]+).*\[([A-Za-z0-9_]+)\] ]]; then
        id="${BASH_REMATCH[1]}"
        user="${BASH_REMATCH[2]}"
        if [[ -n "$id" && -n "$user" && "$user" != "REALITY" ]]; then
            ID_TO_USER["$id"]="$user"
        fi
    fi
done

# Связываем
> "$TEMP_FILE"
for id in "${!ID_TO_IP[@]}"; do
    ip="${ID_TO_IP[$id]}"
    user="${ID_TO_USER[$id]}"
    if [[ -n "$ip" && -n "$user" ]]; then
        echo "$ip:$user" >> "$TEMP_FILE"
    fi
done

# Добавляем старый маппинг
[[ -f "$MAP_FILE" ]] && cat "$MAP_FILE" >> "$TEMP_FILE"

# Выбираем для каждого IP пользователя с максимальной частотой (используем временные файлы вместо ассоциативных массивов с точками)
> "$TEMP_FILE.sorted"
sort "$TEMP_FILE" | uniq -c | sort -rn > "$TEMP_FILE.sorted"

declare -A IP_TO_USER
while read -r count pair; do
    ip="${pair%:*}"
    user="${pair#*:}"
    if [[ -z "${IP_TO_USER[$ip]}" ]]; then
        IP_TO_USER["$ip"]="$user"
    fi
done < "$TEMP_FILE.sorted"

# Сохраняем маппинг
> "$MAP_FILE"
for ip in "${!IP_TO_USER[@]}"; do
    echo "$ip:${IP_TO_USER[$ip]}" >> "$MAP_FILE"
done

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

rm -f "$TEMP_FILE" "$TEMP_FILE.sorted"
