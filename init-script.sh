#!/bin/bash

# --- 0. НАСТРОЙКА ПАПКИ КЭША (Для Nginx Helper) ---
# Путь внутри контейнера (который смотрит наружу в ./nginx-cache)
CACHE_DIR="/var/run/nginx-cache"

# Проверяем, существует ли папка. Если нет — создаем.
if [ ! -d "$CACHE_DIR" ]; then
    echo "📁 Папка кэша не найдена. Создаю: $CACHE_DIR"
    mkdir -p "$CACHE_DIR"
else
    echo "👌 Папка кэша уже существует."
fi

# ВАЖНО: Всегда обновляем права на 777.
# Это гарантирует, что и Nginx, и WordPress (www-data) смогут удалять файлы кэша.
chmod 777 "$CACHE_DIR"
echo "🔓 Права 777 для кэша установлены."


# --- 1. ПРОВЕРКА МАРКЕРА (Setup Lock) ---
MARKER="/var/www/html/.setup_done"

if [ -f "$MARKER" ]; then
    echo "✅ Настройка уже выполнялась ранее (маркер найден). Скрипт завершен."
    exit 0
fi

echo "🚀 Первый запуск или маркер удален. Начинаем проверку..."

# Ждем инициализации WordPress
until [ -f "/var/www/html/wp-cron.php" ]; do
    sleep 5
done
sleep 5

# --- 2. ЗАЩИТА ОТ ПОВТОРНОЙ НАСТРОЙКИ ---
# Если плагины уже стоят, просто восстанавливаем маркер.
if [ -d "/var/www/html/wp-content/plugins/redis-cache" ]; then
    echo "⚠️ Плагины уже установлены. Восстанавливаю маркер и выхожу."
    touch "$MARKER"
    exit 0
fi


# --- 3. ФУНКЦИИ БЕЗОПАСНОЙ НАСТРОЙКИ CONFIG ---
# (Чтобы не дублировать строки в wp-config.php)

# Для значений без кавычек (true, false, числа)
set_config_safe() {
    KEY=$1
    VALUE=$2
    if ! wp config has "$KEY" --allow-root --path=/var/www/html > /dev/null 2>&1; then
        echo "➕ Добавляю конфиг: $KEY"
        wp config set "$KEY" "$VALUE" --raw --allow-root --path=/var/www/html
    else
        echo "⏩ Конфиг $KEY уже существует."
    fi
}

# Для строковых значений (в кавычках)
set_config_string_safe() {
    KEY=$1
    VALUE=$2
    if ! wp config has "$KEY" --allow-root --path=/var/www/html > /dev/null 2>&1; then
        echo "➕ Добавляю конфиг: $KEY"
        wp config set "$KEY" "$VALUE" --allow-root --path=/var/www/html
    fi
}


echo "🔌 Начинаю чистую установку и настройку..."

# --- А. УДАЛЕНИЕ МУСОРА ---
wp plugin delete hello akismet --allow-root --path=/var/www/html || true

# --- Б. БАЗОВЫЕ НАСТРОЙКИ ---
echo "⚙️ Применяю системные настройки..."
set_config_string_safe WP_MEMORY_LIMIT "512M"
set_config_safe WP_AUTO_UPDATE_CORE "false"

# --- В. НАСТРОЙКА REDIS ---
echo "⚙️ Настраиваю Redis..."
set_config_string_safe WP_REDIS_HOST "redis"
set_config_safe        WP_REDIS_PORT 6379
set_config_safe        WP_REDIS_TIMEOUT 1
set_config_safe        WP_REDIS_READ_TIMEOUT 1
set_config_string_safe WP_CACHE_KEY_SALT "wp_cloud_"
set_config_safe        WP_REDIS_IGNORED_GROUPS "['counts', 'plugins', 'themes', 'comment', 'html-forms']"

# --- Г. НАСТРОЙКА FLUENT STORAGE ---
echo "⚙️ Настраиваю Fluent Cloud Storage..."

# Fluent Boards
set_config_string_safe FLUENT_BOARDS_CLOUD_STORAGE "amazon_s3"
set_config_string_safe FLUENT_BOARDS_CLOUD_STORAGE_ACCESS_KEY ""
set_config_string_safe FLUENT_BOARDS_CLOUD_STORAGE_SECRET_KEY ""
set_config_string_safe FLUENT_BOARDS_CLOUD_STORAGE_BUCKET ""
set_config_string_safe FLUENT_BOARDS_CLOUD_STORAGE_REGION ""
set_config_string_safe FLUENT_BOARDS_CLOUD_STORAGE_ENDPOINT ""
set_config_string_safe FLUENT_BOARDS_CLOUD_STORAGE_SUB_FOLDER ""

# Fluent Community
set_config_string_safe FLUENT_COMMUNITY_CLOUD_STORAGE "amazon_s3"
set_config_string_safe FLUENT_COMMUNITY_CLOUD_STORAGE_ACCESS_KEY ""
set_config_string_safe FLUENT_COMMUNITY_CLOUD_STORAGE_SECRET_KEY ""
set_config_string_safe FLUENT_COMMUNITY_CLOUD_STORAGE_BUCKET ""
set_config_string_safe FLUENT_COMMUNITY_CLOUD_STORAGE_REGION ""
set_config_string_safe FLUENT_COMMUNITY_CLOUD_STORAGE_ENDPOINT ""
set_config_string_safe FLUENT_COMMUNITY_CLOUD_STORAGE_SUB_FOLDER ""

# Fluent Cart
set_config_string_safe FLUENT_CART_CLOUD_STORAGE "amazon_s3"
set_config_string_safe FLUENT_CART_CLOUD_STORAGE_ACCESS_KEY ""
set_config_string_safe FLUENT_CART_CLOUD_STORAGE_SECRET_KEY ""
set_config_string_safe FLUENT_CART_CLOUD_STORAGE_BUCKET ""
set_config_string_safe FLUENT_CART_CLOUD_STORAGE_REGION ""
set_config_string_safe FLUENT_CART_CLOUD_STORAGE_ENDPOINT ""
set_config_string_safe FLUENT_CART_CLOUD_STORAGE_SUB_FOLDER ""

# --- Д. УСТАНОВКА ПЛАГИНОВ И ТЕМЫ ---
echo "⬇️ Загружаю плагины и тему..."

PLUGINS_LIST="
  seopress
  elementor
  cyr-to-lat
  aimogen
  betterdocs
  essential-addons-for-elementor-lite
  essential-blocks
  fluent-boards
  fluentform
  fluent-snippets
  fluent-support
  fluent-affiliate
  fluent-security
  fluent-booking
  fluent-cart
  fluent-community
  fluent-crm
  fluent-smtp
  loco-translate
  nginx-helper
  paymattic
  really-simple-ssl
  redis-cache
  templately
  wpvivid-backuprestore
  compressx
"

wp theme install hello-elementor --activate --allow-root --path=/var/www/html
wp plugin install $PLUGINS_LIST --activate --allow-root --path=/var/www/html

# --- Е. ВКЛЮЧЕНИЕ REDIS OBJECT CACHE ---
echo "⚡ Включаем Redis Object Cache..."
wp redis enable --allow-root --path=/var/www/html

# --- 4. ФИНАЛ ---
touch "$MARKER"
echo "✅ Установка и настройка полностью завершена. Маркер создан."