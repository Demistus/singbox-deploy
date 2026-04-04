#!/bin/bash
set -e

echo "=== Установка sing-box + Telegram Bot ==="

# 1. Установка базовых зависимостей
echo "[1/8] Установка зависимостей..."
apt-get update && apt-get install -y jq nftables

# 2. Установка Docker
echo "[2/8] Установка Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
fi

# 3. Установка Docker Compose
echo "[3/8] Установка Docker Compose..."
if ! command -v docker-compose &> /dev/null; then
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
fi

# 4. Клонирование репозитория
echo "[4/8] Клонирование репозитория..."
cd /opt
rm -rf singbox-deploy
git clone https://github.com/Demistus/singbox-deploy.git
cd singbox-deploy

# 5. Запрос переменных
echo "[5/8] Настройка бота..."
echo "Введите BOT_TOKEN (получите у @BotFather):"
read -r BOT_TOKEN </dev/tty
echo "Введите ADMIN_IDS (ваш Telegram ID):"
read -r ADMIN_IDS </dev/tty

# 6. Создание .env
cat > .env << ENV_EOF
BOT_TOKEN=$BOT_TOKEN
ADMIN_IDS=$ADMIN_IDS
ENV_EOF

# 7. Создание директорий
mkdir -p /etc/sing-box /var/lib/sing-box /var/log/sing-box /opt/singbox-stats
mkdir -p /usr/local/bin

# 8. Копирование конфига sing-box
if [ -f configs/singbox/config.json ]; then
    cp configs/singbox/config.json /etc/sing-box/config.json
else
    echo "Создание минимального конфига..."
    cat > /etc/sing-box/config.json << 'SING_EOF'
{
  "log": {"level": "info"},
  "experimental": {
    "clash_api": {"external_controller": "0.0.0.0:9090"}
  },
  "inbounds": [],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
SING_EOF
fi

# 9. Копирование скриптов
echo "[6/8] Установка скриптов..."
cp scripts/traffic_nft.sh /opt/singbox-stats/traffic_nft.sh
chmod +x /opt/singbox-stats/traffic_nft.sh

# 10. Настройка nftables
echo "[7/8] Настройка nftables..."
cat > /etc/nftables.conf << 'NFT_EOF'
#!/usr/sbin/nft -f

flush ruleset

table ip filter {
    chain input {
        type filter hook input priority filter; policy drop;
        
        ct state established,related accept
        iif lo accept
        ip protocol icmp icmp type echo-request accept
        tcp dport 22 accept
        tcp dport {80, 443, 8080} accept
        udp dport 443 accept
        
        log prefix "BLOCKED: " limit rate 5/minute
        reject with icmp type port-unreachable
    }
    
    chain forward {
        type filter hook forward priority filter; policy drop;
        ct state established,related accept
    }
    
    chain output {
        type filter hook output priority filter; policy accept;
    }
}
NFT_EOF

# Применяем nftables
nft -f /etc/nftables.conf
systemctl enable nftables
systemctl restart nftables

# 11. Настройка traffic-stats.service
cat > /etc/systemd/system/traffic-stats.service << 'EOF'
[Unit]
Description=Update traffic stats

[Service]
Type=oneshot
ExecStart=/opt/singbox-stats/traffic_nft.sh
StandardOutput=journal
StandardError=journal
User=root
EOF

# Таймер (каждые 5 минут)
cat > /etc/systemd/system/traffic-stats.timer << 'EOF'
[Unit]
Description=Run traffic-stats every 5 minutes

[Timer]
OnCalendar=*:0/5
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable traffic-stats.timer
systemctl start traffic-stats.timer

# 12. Создание скрипта удаления
cat > /opt/singbox-deploy/scripts/uninstall-singbox.sh << 'UNINSTALL'
#!/bin/bash
echo "=== Удаление sing-box + Telegram Bot ==="
cd /opt/singbox-deploy 2>/dev/null && docker-compose down 2>/dev/null
docker rmi singbox-deploy_sing-box singbox-deploy_bot 2>/dev/null
rm -rf /opt/singbox-deploy /etc/sing-box /var/lib/sing-box /var/log/sing-box /opt/singbox-stats
rm -f /etc/cron.d/singbox-stats
rm -f /etc/nftables.conf
nft delete table ip filter 2>/dev/null
nft delete table ip nat 2>/dev/null
echo "✅ Удаление завершено"
UNINSTALL
chmod +x /opt/singbox-deploy/scripts/uninstall-singbox.sh

# 13. Запуск контейнеров
echo "Запуск контейнеров (сборка может занять до 10 минут)..."
docker build --network host -f docker/Dockerfile.singbox -t singbox-deploy-sing-box .
docker build --network host -f docker/Dockerfile.bot -t singbox-deploy-bot .
docker-compose up -d

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                 ✅ УСТАНОВКА ЗАВЕРШЕНА                       ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  📁 Конфиги:        /etc/sing-box                            ║"
echo "║  📊 Статистика:     /opt/singbox-stats/traffic.json          ║"
echo "║  🔥 Firewall:       /etc/nftables.conf                       ║"
echo "║  🤖 Бот:            docker logs telegram-bot                 ║"
echo "║  ✅ Статистика обновляется каждые 5 минут                    ║"
echo "║  📅 Дневной снимок: 00:00                                    ║"
echo "║  🧹 Удаление:/opt/singbox-deploy/scripts/uninstall-singbox.sh║"
echo "╚══════════════════════════════════════════════════════════════╝"
