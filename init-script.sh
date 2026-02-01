#!/bin/bash

# ==============================================================================
# 0. НАСТРОЙКА ОКРУЖЕНИЯ (КЭШ NGINX)
# ==============================================================================
CACHE_DIR="/var/run/nginx-cache"

if [ ! -d "$CACHE_DIR" ]; then
    echo "📁 Папка кэша не найдена. Создаю: $CACHE_DIR"
    mkdir -p "$CACHE_DIR"
else
    echo "👌 Папка кэша уже существует."
fi

# 777 нужны, так как Nginx и WP могут работать от разных пользователей
chmod 777 "$CACHE_DIR"
echo "🔓 Права 777 для кэша установлены."

# ==============================================================================
# 1. ЖДЕМ WORDPRESS
# ==============================================================================
echo "🚀 Запуск init-script..."

# Ждем создания wp-config.php
until [ -f "/var/www/html/wp-config.php" ]; do
    sleep 2
    echo "⏳ Жду появления wp-config.php..."
done
sleep 2

# ==============================================================================
# 2. ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ==============================================================================

# Функция FORCE (для Зоны "Всегда"). Перезаписывает значение.
set_config_force() {
    KEY=$1; VALUE=$2
    if wp config has "$KEY" --allow-root --path=/var/www/html > /dev/null 2>&1; then
        wp config set "$KEY" "$VALUE" --raw --type=constant --allow-root --path=/var/www/html
    else
        wp config set "$KEY" "$VALUE" --raw --type=constant --allow-root --path=/var/www/html
    fi
}

set_config_string_force() {
    KEY=$1; VALUE=$2
    if wp config has "$KEY" --allow-root --path=/var/www/html > /dev/null 2>&1; then
        wp config set "$KEY" "$VALUE" --type=constant --allow-root --path=/var/www/html
    else
        wp config set "$KEY" "$VALUE" --type=constant --allow-root --path=/var/www/html
    fi
}

# Функция ONCE (для Зоны "Один раз"). Не перезаписывает, если уже есть.
set_config_once() {
    KEY=$1; VALUE=$2
    if ! wp config has "$KEY" --allow-root --path=/var/www/html > /dev/null 2>&1; then
        wp config set "$KEY" "$VALUE" --raw --allow-root --path=/var/www/html
    fi
}

set_config_string_once() {
    KEY=$1; VALUE=$2
    if ! wp config has "$KEY" --allow-root --path=/var/www/html > /dev/null 2>&1; then
        wp config set "$KEY" "$VALUE" --allow-root --path=/var/www/html
    fi
}

# ==============================================================================
# 3. ЗОНА "ВСЕГДА" (СИСТЕМНЫЕ НАСТРОЙКИ)
# ==============================================================================
echo "⚙️ Актуализация системных настроек..."


# --- A. Настройки Дебага (FORCE) ---
ENV_WP_DEBUG=${WP_DEBUG:-false}
ENV_WP_DEBUG_LOG=${WP_DEBUG_LOG:-false}
ENV_WP_DEBUG_DISPLAY=${WP_DEBUG_DISPLAY:-false}

set_config_force WP_DEBUG "$ENV_WP_DEBUG"
set_config_force WP_DEBUG_LOG "$ENV_WP_DEBUG_LOG"
set_config_force WP_DEBUG_DISPLAY "$ENV_WP_DEBUG_DISPLAY"
set_config_force SCRIPT_DEBUG "false"

# Защита от вывода PHP ошибок (через sed)
if ! grep -q "display_errors" /var/www/html/wp-config.php; then
    sed -i "/WP_DEBUG_DISPLAY/a @ini_set( 'display_errors', 0 );" /var/www/html/wp-config.php
fi

# --- C. Сетевой фикс SSL ---
if ! grep -q "HTTP_X_FORWARDED_PROTO" /var/www/html/wp-config.php; then
    sed -i "1a if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && strpos(\$_SERVER['HTTP_X_FORWARDED_PROTO'], 'https') !== false) { \$_SERVER['HTTPS'] = 'on'; }" /var/www/html/wp-config.php
fi

# ==============================================================================
# 4. ПРОВЕРКА МАРКЕРА (СТОП-ЛИНИЯ)
# ==============================================================================
MARKER="/var/www/html/.setup_done"

if [ -f "$MARKER" ]; then
    echo "✅ Базовая установка уже была. Плагины и Static Config не трогаем."
    
    # Права обновляем всегда
    mkdir -p /var/www/html/wp-content/uploads
    chown -R www-data:www-data /var/www/html/wp-content
    
    exit 0
fi

# ==============================================================================
# 5. ЗОНА "ОДИН РАЗ" (ПЛАГИНЫ И ПЕРВИЧНЫЙ КОНФИГ)
# ==============================================================================
echo "🚀 Первый запуск! Начинаю полную установку..."

# --- D. Конфигурация Redis (Один раз) ---
echo "⚙️ Настраиваю Redis..."
set_config_string_once WP_REDIS_HOST "redis"
set_config_once        WP_REDIS_PORT 6379
set_config_once        WP_REDIS_TIMEOUT 1
set_config_once        WP_REDIS_READ_TIMEOUT 1
set_config_string_once WP_CACHE_KEY_SALT "wp_cloud_"
set_config_once        WP_REDIS_IGNORED_GROUPS "['counts', 'plugins', 'themes', 'comment', 'html-forms']"
set_config_string_once WP_REDIS_COMPRESSION "lz4" 
set_config_string_once WP_REDIS_SERIALIZER "igbinary"

# --- E. Конфигурация Fluent Storage (Один раз) ---
echo "⚙️ Настраиваю Fluent Storage..."

# Fluent Boards
set_config_string_once FLUENT_BOARDS_CLOUD_STORAGE "amazon_s3"
set_config_string_once FLUENT_BOARDS_CLOUD_STORAGE_ACCESS_KEY ""
set_config_string_once FLUENT_BOARDS_CLOUD_STORAGE_SECRET_KEY ""
set_config_string_once FLUENT_BOARDS_CLOUD_STORAGE_BUCKET ""
set_config_string_once FLUENT_BOARDS_CLOUD_STORAGE_REGION ""
set_config_string_once FLUENT_BOARDS_CLOUD_STORAGE_ENDPOINT ""
set_config_string_once FLUENT_BOARDS_CLOUD_STORAGE_SUB_FOLDER ""

# Fluent Community
set_config_string_once FLUENT_COMMUNITY_CLOUD_STORAGE "amazon_s3"
set_config_string_once FLUENT_COMMUNITY_CLOUD_STORAGE_ACCESS_KEY ""
set_config_string_once FLUENT_COMMUNITY_CLOUD_STORAGE_SECRET_KEY ""
set_config_string_once FLUENT_COMMUNITY_CLOUD_STORAGE_BUCKET ""
set_config_string_once FLUENT_COMMUNITY_CLOUD_STORAGE_REGION ""
set_config_string_once FLUENT_COMMUNITY_CLOUD_STORAGE_ENDPOINT ""
set_config_string_once FLUENT_COMMUNITY_CLOUD_STORAGE_SUB_FOLDER ""

# Fluent Cart
set_config_string_once FLUENT_CART_CLOUD_STORAGE "amazon_s3"
set_config_string_once FLUENT_CART_CLOUD_STORAGE_ACCESS_KEY ""
set_config_string_once FLUENT_CART_CLOUD_STORAGE_SECRET_KEY ""
set_config_string_once FLUENT_CART_CLOUD_STORAGE_BUCKET ""
set_config_string_once FLUENT_CART_CLOUD_STORAGE_REGION ""
set_config_string_once FLUENT_CART_CLOUD_STORAGE_ENDPOINT ""
set_config_string_once FLUENT_CART_CLOUD_STORAGE_SUB_FOLDER ""

# --- A. Лимиты и Ядро (FORCE) ---
set_config_string_force WP_MEMORY_LIMIT "512M"
set_config_force WP_AUTO_UPDATE_CORE "false"
set_config_force DISABLE_WP_CRON "true"

# --- F. Генерация ключей безопасности ---
echo "🔑 Генерирую ключи (Salts)..."
wp config shuffle-salts --allow-root --path=/var/www/html
wp cache flush --allow-root --path=/var/www/html

# --- G. Загрузка плагинов ---
echo "📦 Скачиваю плагины..."
cd /var/www/html/wp-content/plugins

PLUGINS=(
  "mainwp-child"
  "security-ninja"
  "sessions"
  "ninja-tables"
  "autoptimize"
  "easy-code-manager"
  "independent-analytics"
  "wp-seopress"
  "elementor"
  "cyr-to-lat"
  "aimogen"
  "betterdocs"
  "essential-addons-for-elementor-lite"
  "essential-blocks"
  "fluent-boards"
  "fluentform"
  "fluent-support"
  "fluent-affiliate"
  "fluent-security"
  "fluent-booking"
  "fluent-cart"
  "fluent-community"
  "fluent-crm"
  "fluent-smtp"
  "loco-translate"
  "nginx-helper"
  "wp-payment-form"
  "really-simple-ssl"
  "redis-cache"
  "templately"
  "wpvivid-backuprestore"
  "compressx"
)

for plugin in "${PLUGINS[@]}"; do
    if [ ! -d "$plugin" ]; then
        echo "⬇️ Скачиваю $plugin..."
        wget -q "https://downloads.wordpress.org/plugin/$plugin.latest-stable.zip" -O "$plugin.zip"
        
        if [ -s "$plugin.zip" ]; then
            unzip -q "$plugin.zip" && rm "$plugin.zip"
            echo "✅ $plugin установлен."
        else
            echo "❌ Ошибка/Нет в репозитории: $plugin"
            rm -f "$plugin.zip"
        fi
    fi
done

# --- H. Удаление мусора (Обновлено) ---
echo "🗑 Очистка системы..."

# Удаляем Hello Dolly и Akismet
rm -f hello.php
rm -rf akismet

# Удаляем файлы, раскрывающие версию WP (Ваш запрос)
echo "🔒 Удаляю license.txt и readme.html..."
rm -f license.txt
rm -f readme.html

# --- I. Финальные права доступа ---
echo "🔧 Финальная настройка прав..."
cd /var/www/html
mkdir -p wp-content/uploads

# 1. Отдаем все файлы пользователю www-data
chown -R www-data:www-data /var/www/html

# 2. Права на папки (стандарт)
chmod -R 775 wp-content

# 3. 🔒 ЗАЩИТА WP-CONFIG (Ваша рекомендация)
# 640 = Владелец пишет/читает, Группа читает, Остальные - идут лесом.
chmod 640 /var/www/html/wp-config.php

# --- J. Финал ---
touch "$MARKER"
echo "🎉 Полная конфигурация завершена."