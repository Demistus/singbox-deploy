#!/bin/bash
set -e

echo "=== Установка sing-box + Telegram Bot ==="

# 1. Установка базовых зависимостей
echo "[1/6] Установка зависимостей..."
apt-get update && apt-get install -y jq

# 2. Установка Docker
echo "[2/6] Установка Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
fi

# 3. Установка Docker Compose
echo "[3/6] Установка Docker Compose..."
if ! command -v docker-compose &> /dev/null; then
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
fi

# 4. Клонирование репозитория
echo "[4/6] Клонирование репозитория..."
cd /opt
rm -rf singbox-deploy
git clone https://github.com/Demistus/singbox-deploy.git
cd singbox-deploy

# 5. Запрос переменных
echo "[5/6] Настройка бота..."
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

# 9. Копирование скриптов трафика
cp scripts/traffic_nft.sh /usr/local/bin/traffic_nft.sh
cp scripts/traffic_save.sh /usr/local/bin/traffic_save.sh
chmod +x /usr/local/bin/traffic_nft.sh
chmod +x /usr/local/bin/traffic_save.sh

# 10. Настройка cron
cat > /etc/cron.d/traffic-stats << 'CRON_EOF'
*/5 * * * * root /usr/local/bin/traffic_save.sh >> /var/log/traffic-stats.log 2>&1
CRON_EOF
chmod 644 /etc/cron.d/traffic-stats
systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null || service cron restart

# 11. Создание скрипта удаления
cat > /usr/local/bin/uninstall-singbox.sh << 'UNINSTALL'
#!/bin/bash
echo "=== Удаление sing-box + Telegram Bot ==="
cd /opt/singbox-deploy 2>/dev/null && docker-compose down 2>/dev/null
docker rmi singbox-deploy_sing-box singbox-deploy_bot 2>/dev/null
rm -rf /opt/singbox-deploy /etc/sing-box /var/lib/sing-box /var/log/sing-box /opt/singbox-stats
rm -f /usr/local/bin/traffic_nft.sh /usr/local/bin/traffic_save.sh
rm -f /etc/cron.d/traffic-stats
nft delete table inet traffic 2>/dev/null
echo "✅ Удаление завершено"
UNINSTALL
chmod +x /usr/local/bin/uninstall-singbox.sh

# 12. Запуск контейнеров
echo "[6/6] Запуск контейнеров (сборка может занять 2-3 минуты)..."
docker-compose up -d

echo ""
echo "=== Установка завершена ==="
echo ""
echo "✅ Бот запущен. Проверка: docker logs telegram-bot"
echo "✅ Статистика трафика обновляется каждые 5 минут"
echo "✅ Для удаления выполните: uninstall-singbox.sh"
echo ""
echo "📱 Бот доступен в Telegram: @$(echo $BOT_TOKEN | cut -d':' -f1)"
