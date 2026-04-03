#!/bin/bash
export PATH=$PATH:/usr/sbin:/usr/local/sbin

LOCK_FILE="/tmp/traffic_nft.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || exit 1

MAP_FILE="/opt/singbox-stats/ip_user_map.txt"
NFT_STATE_FILE="/opt/singbox-stats/user_nft_state.txt"
TOTAL_STATE_FILE="/opt/singbox-stats/user_total_state.txt"

# === 1. ПОЛУЧАЕМ ЛОГИ И ОЧИЩАЕМ ANSI ===
LOGS=$(docker logs sing-box --tail 5000 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g')

# === 2. МАППИНГ IP -> USER ПО ID ===
declare -A ID_TO_IP
declare -A ID_TO_USER

while IFS= read -r line; do
    if [[ "$line" =~ \[([0-9]+)\ .*inbound\ connection\ from\ ([0-9.]+) ]]; then
        id="${BASH_REMATCH[1]}"
        ip="${BASH_REMATCH[2]}"
        ID_TO_IP["$id"]="$ip"
    fi
done <<< "$LOGS"

while IFS= read -r line; do
    if [[ "$line" =~ \[([0-9]+)\ .*\[([A-Za-z0-9_]+)\].*inbound\ connection\ to ]]; then
        id="${BASH_REMATCH[1]}"
        user="${BASH_REMATCH[2]}"
        if [[ "$user" != "REALITY" && "$user" != "direct" ]]; then
            ID_TO_USER["$id"]="$user"
        fi
    fi
done <<< "$LOGS"

declare -A IP_TO_USER
for id in "${!ID_TO_IP[@]}"; do
    ip="${ID_TO_IP[$id]}"
    user="${ID_TO_USER[$id]}"
    if [[ -n "$ip" && -n "$user" ]]; then
        IP_TO_USER["$ip"]="$user"
    fi
done

# Добавляем старый маппинг для IP, которых нет в свежих логах
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

# === 3. NFT: СОЗДАЁМ ЦЕПОЧКИ (только новые) ===
/usr/sbin/nft add table inet traffic 2>/dev/null

for ip in "${!IP_TO_USER[@]}"; do
    user="${IP_TO_USER[$ip]}"
    ip_clean="${ip//./_}"
    chain_in="traffic_in_${user}_${ip_clean}"
    chain_out="traffic_out_${user}_${ip_clean}"
    
    if ! /usr/sbin/nft list chain inet traffic "$chain_in" >/dev/null 2>&1; then
        /usr/sbin/nft add chain inet traffic "$chain_in" '{ type filter hook input priority 0; policy accept; }'
        /usr/sbin/nft add rule inet traffic "$chain_in" ip saddr "$ip" counter
    fi
    
    if ! /usr/sbin/nft list chain inet traffic "$chain_out" >/dev/null 2>&1; then
        /usr/sbin/nft add chain inet traffic "$chain_out" '{ type filter hook output priority 0; policy accept; }'
        /usr/sbin/nft add rule inet traffic "$chain_out" ip daddr "$ip" counter
    fi
done

# === 4. ЗАГРУЖАЕМ ПРОШЛЫЕ ПОКАЗАНИЯ NFT ===
declare -A PREV_NFT_UP
declare -A PREV_NFT_DOWN

if [[ -f "$NFT_STATE_FILE" ]]; then
    while IFS=':' read -r user up down; do
        PREV_NFT_UP["$user"]="$up"
        PREV_NFT_DOWN["$user"]="$down"
    done < "$NFT_STATE_FILE"
fi

# === 5. ЗАГРУЖАЕМ ОБЩИЙ ТРАФИК ===
declare -A TOTAL_UP
declare -A TOTAL_DOWN

if [[ -f "$TOTAL_STATE_FILE" ]]; then
    while IFS=':' read -r user up down; do
        TOTAL_UP["$user"]="$up"
        TOTAL_DOWN["$user"]="$down"
    done < "$TOTAL_STATE_FILE"
fi

# === 6. СБОР ТЕКУЩИХ ПОКАЗАНИЙ ИЗ NFT ===
declare -A CURRENT_NFT_UP
declare -A CURRENT_NFT_DOWN

for ip in "${!IP_TO_USER[@]}"; do
    user="${IP_TO_USER[$ip]}"
    ip_clean="${ip//./_}"
    chain_in="traffic_in_${user}_${ip_clean}"
    chain_out="traffic_out_${user}_${ip_clean}"
    
    up=0
    down=0
    
    in_rule=$(/usr/sbin/nft list chain inet traffic "$chain_in" 2>/dev/null | grep "ip saddr $ip")
    if [[ -n "$in_rule" && "$in_rule" =~ bytes\ ([0-9]+) ]]; then
        up="${BASH_REMATCH[1]}"
    fi
    
    out_rule=$(/usr/sbin/nft list chain inet traffic "$chain_out" 2>/dev/null | grep "ip daddr $ip")
    if [[ -n "$out_rule" && "$out_rule" =~ bytes\ ([0-9]+) ]]; then
        down="${BASH_REMATCH[1]}"
    fi
    
    CURRENT_NFT_UP["$user"]=$(( ${CURRENT_NFT_UP["$user"]:-0} + up ))
    CURRENT_NFT_DOWN["$user"]=$(( ${CURRENT_NFT_DOWN["$user"]:-0} + down ))
done

# === 7. СЧИТАЕМ ПРИРОСТ И ОБНОВЛЯЕМ ОБЩИЙ ТРАФИК ===
declare -A NEW_TOTAL_UP
declare -A NEW_TOTAL_DOWN

for user in "${!CURRENT_NFT_UP[@]}"; do
    current_up="${CURRENT_NFT_UP[$user]}"
    current_down="${CURRENT_NFT_DOWN[$user]}"
    
    prev_up="${PREV_NFT_UP[$user]:-0}"
    prev_down="${PREV_NFT_DOWN[$user]:-0}"
    
    delta_up=$((current_up - prev_up))
    delta_down=$((current_down - prev_down))
    
    # Защита от отрицательного прироста (если счётчик сбросился)
    [[ $delta_up -lt 0 ]] && delta_up=$current_up
    [[ $delta_down -lt 0 ]] && delta_down=$current_down
    
    old_total_up="${TOTAL_UP[$user]:-0}"
    old_total_down="${TOTAL_DOWN[$user]:-0}"
    
    NEW_TOTAL_UP["$user"]=$((old_total_up + delta_up))
    NEW_TOTAL_DOWN["$user"]=$((old_total_down + delta_down))
done

# === 8. СОХРАНЯЕМ СОСТОЯНИЯ ===
> "$NFT_STATE_FILE"
for user in "${!CURRENT_NFT_UP[@]}"; do
    echo "$user:${CURRENT_NFT_UP[$user]}:${CURRENT_NFT_DOWN[$user]}" >> "$NFT_STATE_FILE"
done

> "$TOTAL_STATE_FILE"
for user in "${!NEW_TOTAL_UP[@]}"; do
    echo "$user:${NEW_TOTAL_UP[$user]}:${NEW_TOTAL_DOWN[$user]}" >> "$TOTAL_STATE_FILE"
done

# === 9. ВЫВОД JSON ===
{
    echo "["
    first=true
    for user in $(printf "%s\n" "${!NEW_TOTAL_UP[@]}" | sort); do
        if [ "$first" = true ]; then
            first=false
        else
            echo ","
        fi
        printf '{"user":"%s","upload":%s,"download":%s,"total":%s}' \
            "$user" \
            "${NEW_TOTAL_UP[$user]}" \
            "${NEW_TOTAL_DOWN[$user]}" \
            "$(( ${NEW_TOTAL_UP[$user]} + ${NEW_TOTAL_DOWN[$user]} ))"
    done
    echo
    echo "]"
} > /opt/singbox-stats/traffic.json

flock -u 200
rm -f "$LOCK_FILE"
