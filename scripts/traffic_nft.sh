#!/bin/bash
export PATH=$PATH:/usr/sbin:/usr/local/sbin

# Блокировка от одновременного запуска
LOCK_FILE="/tmp/traffic_nft.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || exit 1

MAP_FILE="/opt/singbox-stats/ip_user_map.txt"
TEMP_FILE="/tmp/ip_user_freq.txt"
STATE_FILE="/opt/singbox-stats/user_traffic_state.txt"

# Собираем логи
mapfile -t LOGS < <(docker logs sing-box --tail 5000 2>&1)

# Собираем ID -> IP (игнорируем ошибки валидации REALITY)
declare -A ID_TO_IP
for line in "${LOGS[@]}"; do
    [[ "$line" =~ "TLS handshake: REALITY: processed invalid connection" ]] && continue
    if [[ "$line" =~ inbound\ connection\ from\ ([0-9.]+) ]]; then
        ip="${BASH_REMATCH[1]}"
        if [[ "$line" =~ \[([0-9]+) ]]; then
            id="${BASH_REMATCH[1]}"
            ID_TO_IP["$id"]="$ip"
        fi
    fi
done

# Собираем ID -> USER (игнорируем ошибки валидации REALITY)
declare -A ID_TO_USER
for line in "${LOGS[@]}"; do
    [[ "$line" =~ "TLS handshake: REALITY: processed invalid connection" ]] && continue
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

# Добавляем старый маппинг
[[ -f "$MAP_FILE" ]] && cat "$MAP_FILE" >> "$TEMP_FILE"

# Выбор наиболее частого USER для IP
sort "$TEMP_FILE" | uniq -c | sort -rn > "$TEMP_FILE.sorted"

# Загружаем старый маппинг как основу
declare -A IP_TO_USER
if [[ -f "$MAP_FILE" ]]; then
    while IFS=: read -r ip user; do
        IP_TO_USER["$ip"]="$user"
    done < "$MAP_FILE"
fi

# Обновляем активными IP из логов
while read -r count pair; do
    ip="${pair%:*}"
    user="${pair#*:}"
    IP_TO_USER["$ip"]="$user"
done < "$TEMP_FILE.sorted"

# Сохраняем маппинг
> "$MAP_FILE"
for ip in "${!IP_TO_USER[@]}"; do
    echo "$ip:${IP_TO_USER[$ip]}" >> "$MAP_FILE"
done

# nft таблица
/usr/sbin/nft add table inet traffic 2>/dev/null

# Получаем существующие цепочки
declare -A EXISTING_CHAINS
for chain in $(/usr/sbin/nft list table inet traffic 2>/dev/null | grep -oP 'chain traffic_(in|out)_\K[^ ]+' | sort -u); do
    EXISTING_CHAINS["$chain"]=1
done

# Собираем нужные цепочки
declare -A NEEDED_CHAINS
for ip in "${!IP_TO_USER[@]}"; do
    user="${IP_TO_USER[$ip]}"
    NEEDED_CHAINS["$user"]=1
done

# Удаляем лишние цепочки
for chain in "${!EXISTING_CHAINS[@]}"; do
    if [[ -z "${NEEDED_CHAINS[$chain]}" ]]; then
        /usr/sbin/nft delete chain inet traffic "traffic_in_${chain}" 2>/dev/null
        /usr/sbin/nft delete chain inet traffic "traffic_out_${chain}" 2>/dev/null
    fi
done

# Создаем цепочки и правила для каждого пользователя
declare -A USER_IPS
for ip in "${!IP_TO_USER[@]}"; do
    user="${IP_TO_USER[$ip]}"
    USER_IPS["$user"]="${USER_IPS["$user"]} $ip"
done

for user in "${!USER_IPS[@]}"; do
    chain_in="traffic_in_${user}"
    chain_out="traffic_out_${user}"
    
    # Создаем цепочки если нет
    if ! /usr/sbin/nft list chain inet traffic "$chain_in" >/dev/null 2>&1; then
        /usr/sbin/nft add chain inet traffic "$chain_in" '{ type filter hook input priority 0; policy accept; }'
    fi
    if ! /usr/sbin/nft list chain inet traffic "$chain_out" >/dev/null 2>&1; then
        /usr/sbin/nft add chain inet traffic "$chain_out" '{ type filter hook output priority 0; policy accept; }'
    fi
    
    # Очищаем старые правила в цепочках
    /usr/sbin/nft flush chain inet traffic "$chain_in" 2>/dev/null
    /usr/sbin/nft flush chain inet traffic "$chain_out" 2>/dev/null
    
    # Добавляем правила для каждого IP
    for ip in ${USER_IPS["$user"]}; do
        /usr/sbin/nft add rule inet traffic "$chain_in" ip saddr "$ip" counter
        /usr/sbin/nft add rule inet traffic "$chain_out" ip daddr "$ip" counter
    done
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

# Текущая статистика из nft
declare -A USER_UPLOAD
declare -A USER_DOWNLOAD

for user in "${!USER_IPS[@]}"; do
    chain_in="traffic_in_${user}"
    chain_out="traffic_out_${user}"
    
    upload=0
    while read -r bytes; do
        upload=$((upload + bytes))
    done < <(/usr/sbin/nft list chain inet traffic "$chain_in" | grep -oP 'bytes \K[0-9]+')
    
    download=0
    while read -r bytes; do
        download=$((download + bytes))
    done < <(/usr/sbin/nft list chain inet traffic "$chain_out" | grep -oP 'bytes \K[0-9]+')
    
    USER_UPLOAD["$user"]=$upload
    USER_DOWNLOAD["$user"]=$download
done

# Суммируем с предыдущим состоянием
for user in "${!USER_UPLOAD[@]}"; do
    USER_UPLOAD["$user"]=$(( ${USER_UPLOAD["$user"]} + ${PREV_UPLOAD["$user"]:-0} ))
    USER_DOWNLOAD["$user"]=$(( ${USER_DOWNLOAD["$user"]} + ${PREV_DOWNLOAD["$user"]:-0} ))
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
flock -u 200
rm -f "$LOCK_FILE"
