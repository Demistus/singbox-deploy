#!/bin/bash
export PATH=$PATH:/usr/sbin:/usr/local/sbin

MAP_FILE="/opt/singbox-stats/ip_user_map.txt"
TEMP_FILE="/tmp/ip_user_freq.txt"
STATE_FILE="/opt/singbox-stats/user_traffic_state.txt"

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

# Собираем ID -> USER
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

# Связываем IP:USER
> "$TEMP_FILE"
for id in "${!ID_TO_IP[@]}"; do
    ip="${ID_TO_IP[$id]}"
    user="${ID_TO_USER[$id]}"
    [[ -n "$ip" && -n "$user" ]] && echo "$ip:$user" >> "$TEMP_FILE"
done

[[ -f "$MAP_FILE" ]] && cat "$MAP_FILE" >> "$TEMP_FILE"

# Выбор наиболее частого USER для IP
sort "$TEMP_FILE" | uniq -c | sort -rn > "$TEMP_FILE.sorted"

declare -A IP_TO_USER
while read -r count pair; do
    ip="${pair%:*}"
    user="${pair#*:}"
    [[ -z "${IP_TO_USER[$ip]}" ]] && IP_TO_USER["$ip"]="$user"
done < "$TEMP_FILE.sorted"

# Сохраняем маппинг
> "$MAP_FILE"
for ip in "${!IP_TO_USER[@]}"; do
    echo "$ip:${IP_TO_USER[$ip]}" >> "$MAP_FILE"
done

# nft таблица
/usr/sbin/nft add table inet traffic 2>/dev/null

# Получаем существующие chain
mapfile -t EXISTING_CHAINS < <(/usr/sbin/nft list table inet traffic 2>/dev/null | grep -oP 'chain \K[^ ]+')

# Нужные chain
declare -A NEEDED_CHAINS
for ip in "${!IP_TO_USER[@]}"; do
    user="${IP_TO_USER[$ip]}"
    chain_in="traffic_in_${user}_${ip//./_}"
    chain_out="traffic_out_${user}_${ip//./_}"
    NEEDED_CHAINS["$chain_in"]=1
    NEEDED_CHAINS["$chain_out"]=1
done

# Удаляем лишние
for chain in "${EXISTING_CHAINS[@]}"; do
    [[ -z "${NEEDED_CHAINS[$chain]}" ]] && /usr/sbin/nft delete chain inet traffic "$chain" 2>/dev/null
done

# Загружаем прошлое состояние
declare -A PREV_UPLOAD
declare -A PREV_DOWNLOAD

if [[ -f "$STATE_FILE" ]]; then
    while IFS=":" read -r user up down; do
        PREV_UPLOAD["$user"]="$up"
        PREV_DOWNLOAD["$user"]="$down"
    done < "$STATE_FILE"
fi

# Текущая статистика
declare -A USER_UPLOAD
declare -A USER_DOWNLOAD

for ip in "${!IP_TO_USER[@]}"; do
    user="${IP_TO_USER[$ip]}"
    chain_in="traffic_in_${user}_${ip//./_}"
    chain_out="traffic_out_${user}_${ip//./_}"

    if ! /usr/sbin/nft list chain inet traffic "$chain_in" >/dev/null 2>&1; then
        /usr/sbin/nft add chain inet traffic "$chain_in" '{ type filter hook input priority 0; policy accept; }'
    fi
    if ! /usr/sbin/nft list chain inet traffic "$chain_in" | grep -q "ip saddr $ip"; then
        /usr/sbin/nft add rule inet traffic "$chain_in" ip saddr "$ip" counter
    fi

    if ! /usr/sbin/nft list chain inet traffic "$chain_out" >/dev/null 2>&1; then
        /usr/sbin/nft add chain inet traffic "$chain_out" '{ type filter hook output priority 0; policy accept; }'
    fi
    if ! /usr/sbin/nft list chain inet traffic "$chain_out" | grep -q "ip daddr $ip"; then
        /usr/sbin/nft add rule inet traffic "$chain_out" ip daddr "$ip" counter
    fi

    upload=$(/usr/sbin/nft list chain inet traffic "$chain_in" | grep "ip saddr $ip" | grep -oP 'bytes \K[0-9]+' | head -1)
    download=$(/usr/sbin/nft list chain inet traffic "$chain_out" | grep "ip daddr $ip" | grep -oP 'bytes \K[0-9]+' | head -1)

    upload=${upload:-0}
    download=${download:-0}

    USER_UPLOAD["$user"]=$(( ${USER_UPLOAD["$user"]:-0} + upload ))
    USER_DOWNLOAD["$user"]=$(( ${USER_DOWNLOAD["$user"]:-0} + download ))
done

# Сохраняем состояние
> "$STATE_FILE"
for user in "${!USER_UPLOAD[@]}"; do
    echo "$user:${USER_UPLOAD[$user]}:${USER_DOWNLOAD[$user]}" >> "$STATE_FILE"
done

# Вывод JSON
echo "["
first=true
for user in $(printf "%s\n" "${!USER_UPLOAD[@]}" | sort); do
    total_up=${USER_UPLOAD[$user]}
    total_down=${USER_DOWNLOAD[$user]}

    if [ "$first" = true ]; then
        first=false
    else
        echo ","
    fi

    printf '{"user":"%s","upload":%s,"download":%s,"total":%s}' \
        "$user" \
        "$total_up" \
        "$total_down" \
        "$((total_up + total_down))"
done
echo
echo "]"

rm -f "$TEMP_FILE" "$TEMP_FILE.sorted"
