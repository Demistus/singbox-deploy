#!/bin/bash

export PATH=$PATH:/usr/sbin:/usr/local/sbin

MAP_FILE="/opt/singbox-stats/ip_user_map.txt"
STATE_FILE="/opt/singbox-stats/user_traffic_state.txt"

# Очистка ANSI-кодов обязательна для корректного парсинга
LOGS=$(docker logs sing-box --tail 5000 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g')

# === НОВАЯ ЛОГИКА МАППИНГА ПО ID ===
declare -A IP_BY_ID
declare -A USER_BY_ID

# Собираем IP по ID из строк inbound connection from
while IFS= read -r line; do
    if [[ "$line" =~ \[([0-9]+)\ .*inbound\ connection\ from\ ([0-9.]+) ]]; then
        id="${BASH_REMATCH[1]}"
        ip="${BASH_REMATCH[2]}"
        IP_BY_ID["$id"]="$ip"
    fi
done <<< "$LOGS"

# Собираем имя по ID из строк inbound connection to
while IFS= read -r line; do
    if [[ "$line" =~ \[([0-9]+)\ .*\[([A-Za-z0-9_]+)\].*inbound\ connection\ to ]]; then
        id="${BASH_REMATCH[1]}"
        user="${BASH_REMATCH[2]}"
        if [[ "$user" != "REALITY" && "$user" != "direct" ]]; then
            USER_BY_ID["$id"]="$user"
        fi
    fi
done <<< "$LOGS"

# Связываем IP и имя через общий ID
declare -A IP_TO_USER
for id in "${!IP_BY_ID[@]}"; do
    if [[ -n "${USER_BY_ID[$id]}" ]]; then
        ip="${IP_BY_ID[$id]}"
        user="${USER_BY_ID[$id]}"
        # Если IP уже есть - не перезаписываем (оставляем первое попавшееся)
        [[ -z "${IP_TO_USER[$ip]}" ]] && IP_TO_USER["$ip"]="$user"
    fi
done

# Добавляем старый маппинг только для IP, которых ещё нет
if [[ -f "$MAP_FILE" ]]; then
    while IFS=':' read -r ip user; do
        [[ -z "${IP_TO_USER[$ip]}" ]] && IP_TO_USER["$ip"]="$user"
    done < "$MAP_FILE"
fi

# Сохраняем маппинг
> "$MAP_FILE"
for ip in "${!IP_TO_USER[@]}"; do
    echo "$ip:${IP_TO_USER[$ip]}" >> "$MAP_FILE"
done

# === nft таблица ===
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

# Создаём цепочки и правила для каждого пользователя
declare -A USER_IPS
for ip in "${!IP_TO_USER[@]}"; do
    user="${IP_TO_USER[$ip]}"
    USER_IPS["$user"]="${USER_IPS["$user"]} $ip"
done

for user in "${!USER_IPS[@]}"; do
    chain_in="traffic_in_${user}"
    chain_out="traffic_out_${user}"

# Создаём цепочки если нет
if ! /usr/sbin/nft list chain inet traffic "$chain_in" >/dev/null 2>&1; then
    /usr/sbin/nft add chain inet traffic "$chain_in" '{ type filter hook input priority 0; policy accept; }'
fi
if ! /usr/sbin/nft list chain inet traffic "$chain_out" >/dev/null 2>&1; then
    /usr/sbin/nft add chain inet traffic "$chain_out" '{ type filter hook output priority 0; policy accept; }'
fi

    # Очищаем старые правила
    /usr/sbin/nft flush chain inet traffic "$chain_in" 2>/dev/null
    /usr/sbin/nft flush chain inet traffic "$chain_out" 2>/dev/null

    # Добавляем правила для каждого IP
    for ip in ${USER_IPS["$user"]}; do
        /usr/sbin/nft add rule inet traffic "$chain_in" ip saddr "$ip" counter
        /usr/sbin/nft add rule inet traffic "$chain_out" ip daddr "$ip" counter
    done
done

# === СБОР СТАТИСТИКИ ===
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

# Исправленный парсинг bytes из nft
for ip in "${!IP_TO_USER[@]}"; do
    user="${IP_TO_USER[$ip]}"
    chain_in="traffic_in_${user}"
    chain_out="traffic_out_${user}"

    upload=0
    download=0

    in_rule=$(/usr/sbin/nft list chain inet traffic "$chain_in" 2>/dev/null | grep "ip saddr $ip")
    if [[ -n "$in_rule" ]]; then
        if [[ "$in_rule" =~ bytes\ ([0-9]+) ]]; then
            upload="${BASH_REMATCH[1]}"
        fi
    fi

    out_rule=$(/usr/sbin/nft list chain inet traffic "$chain_out" 2>/dev/null | grep "ip daddr $ip")
    if [[ -n "$out_rule" ]]; then
        if [[ "$out_rule" =~ bytes\ ([0-9]+) ]]; then
            download="${BASH_REMATCH[1]}"
        fi
    fi

    USER_UPLOAD["$user"]=$(( ${USER_UPLOAD["$user"]:-0} + upload ))
    USER_DOWNLOAD["$user"]=$(( ${USER_DOWNLOAD["$user"]:-0} + download ))
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

# === ВЫВОД JSON ===
{
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
} > /opt/singbox-stats/traffic.json

