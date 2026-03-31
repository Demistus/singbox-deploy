#!/bin/bash

STATS_FILE="/opt/singbox-stats/traffic.json"
mkdir -p "$(dirname "$STATS_FILE")"

CURRENT_JSON=$(/usr/local/bin/traffic_nft.sh)

declare -A STATS
if [ -f "$STATS_FILE" ]; then
    while IFS= read -r line; do
        user=$(echo "$line" | jq -r '.user')
        upload=$(echo "$line" | jq -r '.upload')
        download=$(echo "$line" | jq -r '.download')
        STATS["$user"]="$upload:$download"
    done < <(jq -c '.[]' "$STATS_FILE" 2>/dev/null)
fi

for user in $(echo "$CURRENT_JSON" | jq -r '.[].user' | sort -u); do
    upload=$(echo "$CURRENT_JSON" | jq -r ".[] | select(.user==\"$user\") | .upload" | sort -nr | head -1)
    download=$(echo "$CURRENT_JSON" | jq -r ".[] | select(.user==\"$user\") | .download" | sort -nr | head -1)
    upload=${upload:-0}
    download=${download:-0}
    
    old="${STATS["$user"]}"
    old_upload=$(echo "$old" | cut -d':' -f1)
    old_download=$(echo "$old" | cut -d':' -f2)
    old_upload=${old_upload:-0}
    old_download=${old_download:-0}
    
    STATS["$user"]="$((old_upload + upload)):$((old_download + download))"
done

echo "[" > "$STATS_FILE"
first=true
for user in "${!STATS[@]}"; do
    if [ "$first" = true ]; then
        first=false
    else
        echo "," >> "$STATS_FILE"
    fi
    upload=$(echo "${STATS[$user]}" | cut -d':' -f1)
    download=$(echo "${STATS[$user]}" | cut -d':' -f2)
    echo "{\"user\":\"$user\",\"upload\":$upload,\"download\":$download,\"total\":$((upload + download))}" >> "$STATS_FILE"
done
echo "]" >> "$STATS_FILE"

echo "Статистика сохранена"
