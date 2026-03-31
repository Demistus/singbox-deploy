#!/bin/bash
set -e

echo "=== Установка sing-box + Telegram Bot ==="

# Проверка Docker
if ! command -v docker &> /dev/null; then
    echo "Установка Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
fi

# Установка Docker Compose
if ! command -v docker-compose &> /dev/null; then
    echo "Установка Docker Compose..."
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
fi

# Установка jq
if ! command -v jq &> /dev/null; then
    echo "Установка jq..."
    apt-get update && apt-get install -y jq
fi

# Клонирование репозитория
cd /opt
rm -rf singbox-deploy
git clone https://github.com/Demistus/singbox-deploy.git
cd singbox-deploy

# Запрос переменных
echo ""
echo "=== Настройка бота ==="
echo "Введите BOT_TOKEN (получите у @BotFather):"
read BOT_TOKEN
echo ""
echo "Введите ADMIN_IDS (ваш Telegram ID, можно узнать у @userinfobot):"
read ADMIN_IDS
echo ""

# Создание .env
cat > .env << ENV_EOF
BOT_TOKEN=$BOT_TOKEN
ADMIN_IDS=$ADMIN_IDS
ENV_EOF

echo "✓ .env создан"

# Создание директорий
mkdir -p /etc/sing-box /var/lib/sing-box /var/log/sing-box /opt/singbox-stats
mkdir -p /usr/local/bin

# Копирование конфига sing-box
cp configs/singbox/config.json /etc/sing-box/config.json 2>/dev/null || echo "⚠️ Конфиг sing-box не найден, будет создан минимальный"

# Копирование скриптов
cp scripts/traffic_nft.sh /usr/local/bin/traffic_nft.sh
cp scripts/traffic_save.sh /usr/local/bin/traffic_save.sh
chmod +x /usr/local/bin/traffic_nft.sh
chmod +x /usr/local/bin/traffic_save.sh

# Настройка cron
cat > /etc/cron.d/traffic-stats << 'CRON_EOF'
*/5 * * * * root /usr/local/bin/traffic_save.sh >> /var/log/traffic-stats.log 2>&1
CRON_EOF
chmod 644 /etc/cron.d/traffic-stats
systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null || service cron restart

# Запуск
docker-compose up -d

echo ""
echo "=== Установка завершена ==="
echo "Проверка: docker ps && docker logs telegram-bot"
