#!/usr/bin/env python3
"""
Telegram бот для управления sing-box
"""

import os
import sys
import json
import logging
import uuid
import subprocess
import re
import asyncio
import random
import string
import fcntl
from pathlib import Path
from io import BytesIO
from typing import Dict, Optional, List, Any, Union
from datetime import datetime
import shutil
from functools import partial

from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup, CallbackQuery
from telegram.ext import (
    Application, CommandHandler, CallbackQueryHandler,
    MessageHandler, filters, ContextTypes, ConversationHandler
)
import qrcode

logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)
logger = logging.getLogger(__name__)

NAME, CONFIRM = range(2)


class Config:
    BOT_TOKEN = os.getenv("BOT_TOKEN", "")
    ADMIN_IDS = [int(id_) for id_ in os.getenv("ADMIN_IDS", "").split(",") if id_]

    # Пути
    DATA_DIR = Path("/app/data")
    SINGBOX_CONFIG = Path("/etc/sing-box/config.json")
    TRAFFIC_SCRIPT = Path("/opt/singbox-stats/traffic_nft.sh")  # Путь к вашему скрипту
    USER_MAPPING_FILE = DATA_DIR / "telegram_users.json"

    @classmethod
    def validate(cls):
        if not cls.BOT_TOKEN:
            logger.error("BOT_TOKEN не установлен!")
            sys.exit(1)
        cls.DATA_DIR.mkdir(parents=True, exist_ok=True)


USER_MAPPING_FILE = Config.USER_MAPPING_FILE


class FileLock:
    def __init__(self, filepath: Path):
        self.filepath = filepath
        self.fd = None

    def __enter__(self):
        self.filepath.parent.mkdir(parents=True, exist_ok=True)
        self.fd = open(self.filepath, 'a')
        fcntl.flock(self.fd.fileno(), fcntl.LOCK_EX)
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        if self.fd:
            fcntl.flock(self.fd.fileno(), fcntl.LOCK_UN)
            self.fd.close()


def save_user_mapping(telegram_id: int, username: str) -> None:
    try:
        mapping = {}
        if USER_MAPPING_FILE.exists():
            with open(USER_MAPPING_FILE, 'r') as f:
                mapping = json.load(f)
        mapping[str(telegram_id)] = username
        with open(USER_MAPPING_FILE, 'w') as f:
            json.dump(mapping, f, indent=2)
        logger.info(f"Сохранен маппинг: {telegram_id} -> {username}")
    except Exception as e:
        logger.error(f"Ошибка сохранения маппинга: {e}")


def get_user_by_telegram_id(telegram_id: int) -> Optional[str]:
    try:
        if USER_MAPPING_FILE.exists():
            with open(USER_MAPPING_FILE, 'r') as f:
                mapping = json.load(f)
            return mapping.get(str(telegram_id))
    except Exception as e:
        logger.error(f"Ошибка загрузки маппинга: {e}")
    return None


def delete_user_mapping(telegram_id: int) -> bool:
    try:
        mapping = {}
        if USER_MAPPING_FILE.exists():
            with open(USER_MAPPING_FILE, 'r') as f:
                mapping = json.load(f)
        if str(telegram_id) in mapping:
            del mapping[str(telegram_id)]
            with open(USER_MAPPING_FILE, 'w') as f:
                json.dump(mapping, f, indent=2)
            logger.info(f"Удален маппинг для {telegram_id}")
            return True
    except Exception as e:
        logger.error(f"Ошибка удаления маппинга: {e}")
    return False


def load_users_from_config() -> List[Dict[str, Any]]:
    """Загружает пользователей из конфига sing-box"""
    if not Config.SINGBOX_CONFIG.exists():
        return []
    try:
        with open(Config.SINGBOX_CONFIG, 'r') as f:
            config = json.load(f)
        users = []
        for inbound in config.get('inbounds', []):
            if inbound.get('type') == 'vless':
                for user in inbound.get('users', []):
                    users.append({
                        'name': user.get('name'),
                        'uuid': user.get('uuid'),
                        'password': user.get('password', '')
                    })
        logger.info(f"Загружено {len(users)} пользователей из конфига")
        return users
    except Exception as e:
        logger.error(f"Ошибка загрузки пользователей: {e}")
        return []


def save_users_to_config(users: List[Dict[str, Any]]) -> bool:
    """Сохраняет пользователей в конфиг sing-box"""
    if not Config.SINGBOX_CONFIG.exists():
        return False
    try:
        with open(Config.SINGBOX_CONFIG, 'r') as f:
            config = json.load(f)

        for inbound in config.get('inbounds', []):
            if inbound.get('type') == 'vless':
                inbound['users'] = [
                    {
                        'name': u['name'],
                        'uuid': u['uuid'],
                        'flow': 'xtls-rprx-vision'
                    }
                    for u in users
                ]
                break

        with open(Config.SINGBOX_CONFIG, 'w') as f:
            json.dump(config, f, indent=2, ensure_ascii=False)

        logger.info(f"Сохранено {len(users)} пользователей в конфиг")
        return True
    except Exception as e:
        logger.error(f"Ошибка сохранения: {e}")
        return False


def load_users() -> list:
    return load_users_from_config()


def get_traffic_stats() -> List[Dict[str, Any]]:
    """Получает статистику из bash скрипта"""
    try:
        result = subprocess.run(
            [str(Config.TRAFFIC_SCRIPT)],
            capture_output=True,
            text=True,
            timeout=30
        )

        if result.returncode != 0:
            logger.error(f"Traffic script error: {result.stderr}")
            return []

        # Парсим JSON из вывода
        data = json.loads(result.stdout)
        logger.info(f"Loaded traffic stats for {len(data)} users")
        return data
    except json.JSONDecodeError as e:
        logger.error(f"JSON decode error: {e}\nOutput: {result.stdout}")
        return []
    except Exception as e:
        logger.error(f"Error getting traffic stats: {e}")
        return []


def format_bytes(bytes_num: int) -> str:
    """Форматирование байтов в читаемый вид"""
    if bytes_num == 0:
        return "0 B"

    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if bytes_num < 1024.0:
            return f"{bytes_num:.2f} {unit}"
        bytes_num /= 1024.0
    return f"{bytes_num:.2f} PB"


def get_server_params() -> Dict[str, str]:
    """Получает параметры сервера из конфига"""
    params = {
        'domain': 'jacket.casacam.net',
        'port': '443',
        'public_key': 'sGUInZ4epsI4uzQ9CKHWAzwIhG9Cy5P9KTAuzTVmfzg',
        'short_id': '',
        'vless_sni': 'www.microsoft.com',
        'hy2_sni': 'jacket.casacam.net'
    }
    if Config.SINGBOX_CONFIG.exists():
        try:
            with open(Config.SINGBOX_CONFIG, 'r') as f:
                config = json.load(f)
            for inbound in config.get('inbounds', []):
                if inbound.get('type') == 'vless':
                    tls = inbound.get('tls', {})
                    reality = tls.get('reality', {})
                    params['short_id'] = reality.get('short_id', '')
                    params['vless_sni'] = tls.get('server_name', params['vless_sni'])
                    break
        except:
            pass
    return params


def generate_client_config(username: str, user_uuid: str, password: str, platform: str = "android") -> Dict:
    params = get_server_params()
    dns_servers = [
        {"tag": "dns-direct", "server": "208.67.222.220", "server_port": 5353},
        {"tag": "dns-remote", "server": "dns.google", "server_port": 853, "detour": "vless-out"}
    ]
    if platform == "android":
        dns_servers[0]["type"] = "udp"
        dns_servers[1]["type"] = "tls"
    return {
        "log": {"level": "warn"},
        "dns": {
            "servers": dns_servers,
            "rules": [
                {"domain": [params['domain'], "github.com", "raw.githubusercontent.com", "dns.google"], "server": "dns-direct"},
                {"server": "dns-remote"}
            ],
            "strategy": "prefer_ipv4"
        },
        "inbounds": [{
            "type": "tun",
            "tag": "tun-in",
            "interface_name": "tun0",
            "mtu": 1400,
            "address": "172.19.0.1/30",
            "auto_route": True,
            "strict_route": True,
            "stack": "system",
            "sniff": True,
            "sniff_override_destination": True
        }],
        "outbounds": [
            {"type": "direct", "tag": "direct"},
            {
                "type": "vless",
                "tag": "vless-out",
                "server": params['domain'],
                "server_port": int(params['port']),
                "uuid": user_uuid,
                "flow": "xtls-rprx-vision",
                "tls": {
                    "enabled": True,
                    "server_name": params['vless_sni'],
                    "utls": {"enabled": True, "fingerprint": "chrome"},
                    "reality": {
                        "enabled": True,
                        "public_key": params['public_key'],
                        "short_id": params['short_id']
                    }
                }
            }
        ],
        "route": {
            "default_domain_resolver": "dns-direct",
            "rule_set": [{
                "tag": "geoip-ru",
                "type": "remote",
                "format": "binary",
                "url": "https://github.com/SagerNet/sing-geoip/raw/rule-set/geoip-ru.srs",
                "download_detour": "direct"
            }],
            "rules": [
                {"domain": [params['domain'], "github.com", "raw.githubusercontent.com"], "outbound": "direct"},
                {"rule_set": ["geoip-ru"], "outbound": "direct"}
            ],
            "final": "vless-out",
            "auto_detect_interface": True
        }
    }


def generate_vless_link(username: str, user_uuid: str) -> str:
    params = get_server_params()
    return (f"vless://{user_uuid}@{params['domain']}:{params['port']}"
            f"?encryption=none&security=reality&flow=xtls-rprx-vision"
            f"&type=tcp&sni={params['vless_sni']}"
            f"&pbk={params['public_key']}&sid={params['short_id']}"
            f"&fp=chrome#{username}")


def generate_hysteria_link(username: str, password: str) -> str:
    params = get_server_params()
    return f"hysteria2://{password}@{params['domain']}:8443?insecure=0&sni={params['hy2_sni']}#{username}"


def generate_qr_code(data: str) -> BytesIO:
    qr = qrcode.QRCode(version=1, box_size=6, border=2)
    qr.add_data(data)
    qr.make(fit=True)
    img = qr.make_image(fill_color="black", back_color="white")
    bio = BytesIO()
    img.save(bio, 'PNG')
    bio.seek(0)
    return bio


async def restart_singbox_server() -> bool:
    """Отправляет сигнал HUP для перезагрузки конфига"""
    try:
        result = await asyncio.get_event_loop().run_in_executor(
            None,
            lambda: subprocess.run(
                ['docker', 'exec', 'sing-box', 'kill', '-HUP', '1'],
                capture_output=True,
                text=True,
                timeout=10
            )
        )
        if result.returncode == 0:
            logger.info("sing-box конфиг перезагружен (HUP)")
            return True
        logger.error(f"Ошибка HUP: {result.stderr}")
        return False
    except Exception as e:
        logger.error(f"Ошибка: {e}")
        return False


async def add_user_operation(user_info: Dict) -> tuple[bool, str]:
    try:
        users = load_users_from_config()
        if any(u.get('name') == user_info['name'] for u in users):
            return False, "Пользователь уже существует"
        users.append(user_info)
        if not save_users_to_config(users):
            return False, "Ошибка сохранения"
        await restart_singbox_server()
        return True, "Success"
    except Exception as e:
        return False, str(e)


async def remove_user_operation(username: str) -> tuple[bool, str]:
    try:
        users = load_users_from_config()
        user_to_remove = next((u for u in users if u.get('name') == username), None)
        if not user_to_remove:
            return False, "Пользователь не найден"
        users = [u for u in users if u.get('name') != username]
        if not save_users_to_config(users):
            return False, "Ошибка сохранения"
        await restart_singbox_server()
        return True, "Success"
    except Exception as e:
        return False, str(e)


async def send_client_config_to_user(query, context, username, user_uuid, password):
    keyboard = [
        [InlineKeyboardButton("📱 Android", callback_data=f"config_android_{username}"),
         InlineKeyboardButton("🍎 iOS", callback_data=f"config_ios_{username}")]
    ]
    context.user_data['waiting_for_platform'] = True
    await query.message.reply_text(
        "📱 <b>Выберите вашу платформу:</b>",
        parse_mode='HTML',
        reply_markup=InlineKeyboardMarkup(keyboard)
    )


async def send_config_by_platform(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    bot = context.bot
    chat_id = query.message.chat_id
    platform, username = query.data.replace("config_", "").split("_", 1)

    users = load_users_from_config()
    user = next((u for u in users if u.get('name') == username), None)
    if not user:
        await query.message.edit_text("❌ Пользователь не найден", parse_mode='HTML')
        return

    user_uuid = user['uuid']
    password = user['password']
    client_config = generate_client_config(username, user_uuid, password, platform)

    import time
    timestamp = int(time.time())
    send_file = Config.DATA_DIR / f"{username}_{platform}_{timestamp}.json"
    with open(send_file, 'w') as f:
        json.dump(client_config, f, indent=2, ensure_ascii=False)

    with open(send_file, 'rb') as f:
        await bot.send_document(
            chat_id=chat_id,
            document=f,
            filename=f"{username}_singbox_{platform}_{timestamp}.json",
            caption=f"📱 <b>Конфиг для Sing-box</b>\n\n"
                    f"👤 <b>Имя:</b> {username}\n"
                    f"🔑 <b>UUID:</b> <code>{user_uuid}</code>\n"
                    f"🔑 <b>Пароль:</b> <code>{password}</code>\n\n"
                    f"<b>⭐ Особенности:</b>\n"
                    f"• Российские сайты (.ru) — прямое подключение\n"
                    f"• Заблокированные сайты — через VPN\n\n"
                    f"<b>📱 Как подключиться:</b>\n"
                    f"1. Сохраните файл\n"
                    f"2. Установите Sing-box\n"
                    f"3. Импортируйте файл\n"
                    f"4. Нажмите для подключения",
            parse_mode='HTML'
        )

    vless_qr = generate_qr_code(generate_vless_link(username, user_uuid))
    hysteria_qr = generate_qr_code(generate_hysteria_link(username, password))

    await bot.send_photo(chat_id=chat_id, photo=vless_qr,
                         caption=f"📱 <b>QR-код VLESS</b> для {username}", parse_mode='HTML')
    await bot.send_photo(chat_id=chat_id, photo=hysteria_qr,
                         caption=f"📱 <b>QR-код Hysteria2</b> для {username}", parse_mode='HTML')

    send_file.unlink()
    context.user_data.pop('waiting_for_platform', None)


async def send_existing_config(query, context, username):
    users = load_users_from_config()
    user = next((u for u in users if u.get('name') == username), None)
    if not user:
        await query.message.edit_text("❌ Конфиг не найден", parse_mode='HTML')
        return
    await send_client_config_to_user(query, context, username, user['uuid'], user['password'])


async def show_menu(bot, chat_id: int, user_id: int):
    keyboard = [
        [InlineKeyboardButton("📱 Мои конфиги", callback_data="my_configs")],
        [InlineKeyboardButton("📊 Мой трафик", callback_data="show_my_traffic")],  # Изменено
        [InlineKeyboardButton("🔑 Создать мой конфиг", callback_data="create_my_config")],
        [InlineKeyboardButton("ℹ️ Информация о сервере", callback_data="server_info")],
        [InlineKeyboardButton("❓ Помощь", callback_data="help")]
    ]
    if user_id and user_id in Config.ADMIN_IDS:
        keyboard.insert(0, [
            InlineKeyboardButton("➕ Добавить пользователя", callback_data="add_user"),
            InlineKeyboardButton("🗑️ Удалить пользователя", callback_data="delete_user")
        ])
        keyboard.append([InlineKeyboardButton("📊 Статистика всех пользователей", callback_data="show_total_traffic")])  # Изменено

    reply_markup = InlineKeyboardMarkup(keyboard)
    text = "📱 <b>Главное меню</b>\n\nВыберите действие:"
    await bot.send_message(chat_id=chat_id, text=text, parse_mode='HTML', reply_markup=reply_markup)


async def menu(update: Union[Update, CallbackQuery], context: ContextTypes.DEFAULT_TYPE):
    if isinstance(update, Update):
        if update.callback_query:
            user_id = update.callback_query.from_user.id
            chat_id = update.callback_query.message.chat_id
            try:
                await update.callback_query.message.delete()
            except:
                pass
            await show_menu(context.bot, chat_id, user_id)
        elif update.message:
            user_id = update.message.from_user.id
            chat_id = update.message.chat_id
            await show_menu(context.bot, chat_id, user_id)


async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = update.effective_user.id
    chat_id = update.effective_chat.id
    await show_menu(context.bot, chat_id, user_id)


async def help_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    help_text = (
        "❓ <b>Помощь</b>\n\n"
        "<b>📱 Как подключиться:</b>\n"
        "1. Скачайте JSON конфиг\n"
        "2. Установите Sing-box\n"
        "3. Импортируйте файл\n"
        "4. Нажмите для подключения\n\n"
        "<b>🔧 Команды:</b>\n"
        "/start - Главное меню\n"
        "/help - Эта справка"
    )
    await update.message.reply_text(help_text, parse_mode='HTML')


async def create_my_config(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    user_id = update.effective_user.id
    username = update.effective_user.username or f"user_{user_id}"
    username = re.sub(r'[^a-zA-Z0-9_\-]', '_', username)[:20]
    if username and username[0].isdigit():
        username = f"user_{username}"

    existing_username = get_user_by_telegram_id(user_id)
    if existing_username:
        users = load_users_from_config()
        existing_user = next((u for u in users if u.get('name') == existing_username), None)
        if existing_user:
            await send_existing_config(query, context, existing_username)
            return
        else:
            delete_user_mapping(user_id)

    users = load_users_from_config()
    base_username = username
    counter = 1
    while any(u.get('name') == username for u in users):
        username = f"{base_username}_{counter}"
        counter += 1

    user_uuid = str(uuid.uuid4())
    password = ''.join(random.choices(string.ascii_letters + string.digits, k=12))
    user_info = {'name': username, 'uuid': user_uuid, 'password': password}

    status_msg = await query.message.reply_text("🔄 <b>Создаем конфиг...</b>", parse_mode='HTML')
    success, error_msg = await add_user_operation(user_info)
    if not success:
        await status_msg.edit_text(f"❌ <b>Ошибка:</b>\n<code>{error_msg}</code>", parse_mode='HTML')
        return

    await restart_singbox_server()
    save_user_mapping(user_id, username)
    await status_msg.delete()
    await send_client_config_to_user(query, context, username, user_uuid, password)
    context.user_data.clear()


async def show_user_configs(update_obj):
    if hasattr(update_obj, 'callback_query'):
        query = update_obj.callback_query
        chat_id = query.message.chat.id
        is_admin = chat_id in Config.ADMIN_IDS
        edit_func = query.edit_message_text
        answer_func = query.answer
    elif hasattr(update_obj, 'message') and hasattr(update_obj, 'edit_message_text'):
        chat_id = update_obj.message.chat.id
        is_admin = chat_id in Config.ADMIN_IDS
        edit_func = update_obj.edit_message_text
        answer_func = update_obj.answer
    else:
        chat_id = update_obj.chat.id
        is_admin = chat_id in Config.ADMIN_IDS
        edit_func = update_obj.reply_text
        answer_func = None

    users = load_users_from_config()
    if is_admin:
        filtered_users = users
    else:
        user_name = get_user_by_telegram_id(chat_id)
        filtered_users = [u for u in users if u.get('name') == user_name] if user_name else []

    if not filtered_users:
        keyboard = [[InlineKeyboardButton("🔑 Создать мой конфиг", callback_data="create_my_config")]]
        await edit_func("❌ Нет конфигов", parse_mode='HTML', reply_markup=InlineKeyboardMarkup(keyboard))
        if answer_func:
            await answer_func()
        return

    keyboard = [[InlineKeyboardButton(f"📄 {u['name']}", callback_data=f"config_{u['name']}")] for u in filtered_users]
    keyboard.append([InlineKeyboardButton("🔙 Назад", callback_data="back_to_menu")])
    text = "📱 <b>Ваши конфиги:</b>" if not is_admin else "📱 <b>Все конфиги:</b>"
    await edit_func(text, parse_mode='HTML', reply_markup=InlineKeyboardMarkup(keyboard))
    if answer_func:
        await answer_func()


async def send_user_config(query, username, context):
    user_id = query.message.chat.id
    is_admin = user_id in Config.ADMIN_IDS
    if not is_admin:
        user_name = get_user_by_telegram_id(user_id)
        if user_name != username:
            await query.message.edit_text("❌ Доступ запрещен", parse_mode='HTML')
            return
    users = load_users_from_config()
    user = next((u for u in users if u.get('name') == username), None)
    if not user:
        await query.message.edit_text("❌ Пользователь не найден", parse_mode='HTML')
        return
    await send_client_config_to_user(query, context, username, user['uuid'], user['password'])


async def show_server_info(update):
    params = get_server_params()
    users = load_users_from_config()
    if hasattr(update, 'callback_query'):
        query = update.callback_query
        await query.message.edit_text(
            f"🖥️ <b>Сервер</b>\n🌐 {params['domain']}:{params['port']}\n👥 Пользователей: {len(users)}",
            parse_mode='HTML',
            reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("🔙 Назад", callback_data="back_to_menu")]])
        )
        await query.answer()
    else:
        await update.message.reply_text(
            f"🖥️ <b>Сервер</b>\n🌐 {params['domain']}:{params['port']}\n👥 Пользователей: {len(users)}",
            parse_mode='HTML'
        )


async def show_help(update):
    help_text = "❓ <b>Помощь</b>\n\n<b>📱 Как подключиться:</b>\n1. Скачайте JSON конфиг\n2. Импортируйте в Sing-box"
    if hasattr(update, 'callback_query'):
        query = update.callback_query
        await query.message.edit_text(help_text, parse_mode='HTML', reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("🔙 Назад", callback_data="back_to_menu")]]))
        await query.answer()
    else:
        await update.message.reply_text(help_text, parse_mode='HTML')


async def show_my_traffic(query: CallbackQuery, context: ContextTypes.DEFAULT_TYPE):
    """Показывает трафик текущего пользователя"""
    user_id = query.from_user.id
    await query.answer()

    username = get_user_by_telegram_id(user_id)
    if not username:
        await query.message.edit_text(
            "❌ У вас нет активного конфига.\nСоздайте его через 'Создать мой конфиг'",
            parse_mode='HTML',
            reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("🔑 Создать конфиг", callback_data="create_my_config")]])
        )
        return

    stats = get_traffic_stats()

    # Ищем статистику для пользователя
    user_stats = next((s for s in stats if s.get('user') == username), None)

    if user_stats:
        total_up = user_stats.get('total_upload', 0)
        total_down = user_stats.get('total_download', 0)
        day_up = user_stats.get('day_upload', 0)
        day_down = user_stats.get('day_download', 0)

        text = f"📊 <b>Ваш трафик</b>\n\n"
        text += f"👤 <b>{username}</b>\n"
        text += f"📤 <b>За день:</b> {format_bytes(day_up)}\n"
        text += f"📥 <b>За день:</b> {format_bytes(day_down)}\n"
        text += f"📈 <b>Всего отправлено:</b> {format_bytes(total_up)}\n"
        text += f"📉 <b>Всего получено:</b> {format_bytes(total_down)}\n"
        text += f"📊 <b>Общий трафик:</b> {format_bytes(total_up + total_down)}"
    else:
        text = f"📊 <b>Ваш трафик</b>\n\n👤 {username}\n📊 Нет данных о трафике"

    await query.message.edit_text(
        text,
        parse_mode='HTML',
        reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("🔙 Назад", callback_data="back_to_menu")]])
    )


async def show_total_traffic(query: CallbackQuery, context: ContextTypes.DEFAULT_TYPE):
    """Показывает статистику всех пользователей (только для админов)"""
    user_id = query.from_user.id
    await query.answer()

    # Проверка прав администратора
    if user_id not in Config.ADMIN_IDS:
        await query.message.edit_text(
            "❌ Доступ запрещен. Только для администраторов.",
            parse_mode='HTML',
            reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("🔙 Назад", callback_data="back_to_menu")]])
        )
        return

    stats = get_traffic_stats()

    if not stats:
        await query.message.edit_text(
            "📊 <b>Статистика трафика</b>\n\nНет данных о трафике",
            parse_mode='HTML',
            reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("🔙 Назад", callback_data="back_to_menu")]])
        )
        return

    text = "📊 <b>Статистика трафика всех пользователей</b>\n\n"

    # Сортируем по общему трафику (upload + download)
    sorted_stats = sorted(stats, key=lambda x: x.get('total_upload', 0) + x.get('total_download', 0), reverse=True)

    for user_data in sorted_stats:
        username = user_data.get('user', 'Unknown')
        total_up = user_data.get('total_upload', 0)
        total_down = user_data.get('total_download', 0)
        day_up = user_data.get('day_upload', 0)
        day_down = user_data.get('day_download', 0)

        text += f"👤 <b>{username}</b>\n"
        text += f"  📤 За день: {format_bytes(day_up)}\n"
        text += f"  📥 За день: {format_bytes(day_down)}\n"
        text += f"  📈 Всего: {format_bytes(total_up + total_down)}\n"
        text += "─" * 25 + "\n"

    await query.message.edit_text(
        text,
        parse_mode='HTML',
        reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("🔙 Назад", callback_data="back_to_menu")]])
    )


async def add_user_start(update, context):
    if update.effective_user.id not in Config.ADMIN_IDS:
        await update.callback_query.answer("❌ Доступ запрещен", show_alert=True)
        return ConversationHandler.END
    message = update.callback_query.message
    context.user_data['menu_message_id'] = message.message_id
    await message.edit_text(
        "➕ <b>Введите имя пользователя</b> (a-z, 3-20 символов):\n<i>/cancel - отмена</i>",
        parse_mode='HTML'
    )
    await update.callback_query.answer()
    return NAME


async def add_user_name(update, context):
    username = update.message.text.strip()
    if not re.match(r'^[a-z][a-z0-9_]{2,19}$', username):
        await update.message.reply_text("❌ Некорректное имя! Попробуйте еще раз:")
        return NAME
    users = load_users_from_config()
    if any(u.get('name') == username for u in users):
        await update.message.reply_text(f"❌ Пользователь {username} уже существует!")
        return NAME
    user_uuid = str(uuid.uuid4())
    password = ''.join(random.choices(string.ascii_letters + string.digits, k=12))
    context.user_data['new_user'] = {'name': username, 'uuid': user_uuid, 'password': password}
    keyboard = [[InlineKeyboardButton("✅ Да", callback_data="confirm_add"), InlineKeyboardButton("❌ Нет", callback_data="cancel_add")]]
    await update.message.reply_text(
        f"📝 <b>Подтвердите:</b>\n👤 {username}\n🔑 <code>{user_uuid}</code>\n🔐 <code>{password}</code>\n\nДобавить?",
        parse_mode='HTML', reply_markup=InlineKeyboardMarkup(keyboard)
    )
    return CONFIRM


async def confirm_add_user(update, context):
    query = update.callback_query
    await query.answer()
    bot = context.bot
    user_info = context.user_data.get('new_user')
    if not user_info:
        await query.message.reply_text("❌ Ошибка")
        return ConversationHandler.END
    username = user_info['name']
    chat_id = query.message.chat_id
    try:
        await query.message.delete()
    except:
        pass
    if 'menu_message_id' in context.user_data:
        try:
            await bot.delete_message(chat_id=chat_id, message_id=context.user_data['menu_message_id'])
        except:
            pass
    status_msg = await bot.send_message(chat_id=chat_id, text=f"🔄 <b>Добавляем {username}...</b>", parse_mode='HTML')
    success, error_msg = await add_user_operation(user_info)
    if not success:
        await status_msg.edit_text(f"❌ <b>Ошибка:</b>\n<code>{error_msg}</code>", parse_mode='HTML')
        return ConversationHandler.END
    await restart_singbox_server()
    await status_msg.delete()
    await bot.send_message(chat_id=chat_id, text=f"✅ <b>Пользователь {username} добавлен!</b>", parse_mode='HTML')

    # Создаем фейковый query для отправки конфига
    class FakeQuery:
        def __init__(self, message):
            self.message = message
        async def answer(self):
            pass

    fake_query = FakeQuery(query.message)
    await send_client_config_to_user(fake_query, context, username, user_info['uuid'], user_info['password'])
    return ConversationHandler.END


async def delete_user_start(update, context):
    if update.effective_user.id not in Config.ADMIN_IDS:
        await update.callback_query.answer("❌ Доступ запрещен", show_alert=True)
        return
    users = load_users_from_config()
    if not users:
        await update.callback_query.message.edit_text("❌ Нет пользователей", parse_mode='HTML')
        return
    keyboard = [[InlineKeyboardButton(f"🗑️ {u['name']}", callback_data=f"del_{u['name']}")] for u in users]
    keyboard.append([InlineKeyboardButton("🔙 Назад", callback_data="back_to_menu")])
    await update.callback_query.message.edit_text("🗑️ <b>Выберите пользователя:</b>", parse_mode='HTML', reply_markup=InlineKeyboardMarkup(keyboard))
    await update.callback_query.answer()


async def confirm_delete_user(update, context):
    query = update.callback_query
    await query.answer()
    username = query.data.replace("del_", "")
    context.user_data['delete_username'] = username
    keyboard = [[InlineKeyboardButton("✅ Да", callback_data="confirm_delete"), InlineKeyboardButton("❌ Нет", callback_data="cancel_delete")]]
    await query.message.edit_text(f"⚠️ <b>Удалить {username}?</b>", parse_mode='HTML', reply_markup=InlineKeyboardMarkup(keyboard))


async def perform_delete_user(update, context):
    query = update.callback_query
    await query.answer()
    username = context.user_data.get('delete_username')
    if not username:
        await query.message.edit_text("❌ Ошибка", parse_mode='HTML')
        return
    user_id = None
    try:
        if USER_MAPPING_FILE.exists():
            with open(USER_MAPPING_FILE, 'r') as f:
                mapping = json.load(f)
            for uid, uname in mapping.items():
                if uname == username:
                    user_id = int(uid)
                    break
    except:
        pass
    try:
        status_msg = await query.message.edit_text(f"🔄 <b>Удаляем {username}...</b>", parse_mode='HTML')
    except:
        status_msg = await query.message.reply_text(f"🔄 <b>Удаляем {username}...</b>", parse_mode='HTML')
    success, error_msg = await remove_user_operation(username)
    if not success:
        await status_msg.edit_text(f"❌ <b>Ошибка:</b>\n<code>{error_msg}</code>", parse_mode='HTML')
        return
    if user_id:
        delete_user_mapping(user_id)
    await restart_singbox_server()
    await status_msg.edit_text(f"✅ <b>Пользователь {username} удален!</b>", parse_mode='HTML')
    context.user_data.clear()
    await menu(update, context)


async def cancel_delete(update, context):
    query = update.callback_query
    await query.answer()
    context.user_data.clear()
    await menu(update, context)


async def cancel_operation(update, context):
    if update.callback_query:
        await update.callback_query.answer()
        await update.callback_query.message.edit_text("❌ Отменено", parse_mode='HTML')
    else:
        await update.message.reply_text("❌ Отменено", parse_mode='HTML')
    context.user_data.clear()
    await menu(update, context)
    return ConversationHandler.END


async def handle_callback(update, context):
    query = update.callback_query
    await query.answer()

    if query.data == "my_configs":
        await show_user_configs(query)
    elif query.data == "create_my_config":
        await create_my_config(update, context)
    elif query.data == "show_my_traffic":
        await show_my_traffic(query, context)
    elif query.data == "show_total_traffic":
        await show_total_traffic(query, context)
    elif query.data.startswith("config_android_") or query.data.startswith("config_ios_"):
        await send_config_by_platform(update, context)
    elif query.data == "server_info":
        await show_server_info(update)
    elif query.data == "help":
        await show_help(update)
    elif query.data == "add_user":
        await add_user_start(update, context)
    elif query.data == "delete_user":
        await delete_user_start(update, context)
    elif query.data.startswith("del_"):
        await confirm_delete_user(update, context)
    elif query.data == "confirm_delete":
        await perform_delete_user(update, context)
    elif query.data == "cancel_delete":
        await cancel_delete(update, context)
    elif query.data.startswith("config_"):
        username = query.data.replace("config_", "")
        await send_user_config(query, username, context)
    elif query.data == "back_to_menu":
        await menu(update, context)


async def handle_message(update, context):
    text = update.message.text.lower()
    if text == '/my_configs':
        await show_user_configs(update.message)
    else:
        await update.message.reply_text("Используйте /start для доступа к меню")


def main():
    Config.validate()
    from telegram.request import HTTPXRequest
    request = HTTPXRequest(connect_timeout=60.0, read_timeout=60.0, write_timeout=60.0, pool_timeout=60.0)
    application = Application.builder().token(Config.BOT_TOKEN).request(request).build()

    conv_handler = ConversationHandler(
        entry_points=[CallbackQueryHandler(add_user_start, pattern='^add_user$')],
        states={
            NAME: [MessageHandler(filters.TEXT & ~filters.COMMAND, add_user_name)],
            CONFIRM: [CallbackQueryHandler(confirm_add_user, pattern='^confirm_add$'),
                      CallbackQueryHandler(cancel_operation, pattern='^cancel_add$')],
        },
        fallbacks=[CommandHandler('cancel', cancel_operation)],
        allow_reentry=True
    )

    application.add_handler(conv_handler)
    application.add_handler(CommandHandler("start", start))
    application.add_handler(CommandHandler("menu", menu))
    application.add_handler(CommandHandler("help", help_command))
    application.add_handler(CallbackQueryHandler(handle_callback))
    application.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_message))

    logger.info("🚀 Бот запущен!")
    application.run_polling()


if __name__ == '__main__':
    main()

