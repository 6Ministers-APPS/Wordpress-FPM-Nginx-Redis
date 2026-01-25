#!/bin/bash

# ==============================================================================
# 0. НАСТРОЙКА ОКРУЖЕНИЯ
# ==============================================================================

# Настройка папки кэша Nginx
CACHE_DIR="/var/run/nginx-cache"

if [ ! -d "$CACHE_DIR" ]; then
    echo "📁 Папка кэша не найдена. Создаю: $CACHE_DIR"
    mkdir -p "$CACHE_DIR"
else
    echo "👌 Папка кэша уже существует."
fi

# Права 777 для избежания конфликтов записи
chmod 777 "$CACHE_DIR"
echo "🔓 Права 777 для кэша установлены."


# ==============================================================================
# 1. ЗАЩИТА ОТ ПОВТОРНОГО ЗАПУСКА
# ==============================================================================
MARKER="/var/www/html/.setup_done"

if [ -f "$MARKER" ]; then
    echo "✅ Настройка уже выполнялась. Скрипт завершен."
    exit 0
fi

echo "🚀 Первый запуск. Ждем инициализации WordPress..."

# Ждем создания wp-config.php контейнером
until [ -f "/var/www/html/wp-config.php" ]; do
    sleep 2
    echo "⏳ Жду появления wp-config.php..."
done
sleep 3


# ==============================================================================
# 2. ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ==============================================================================

# Для значений БЕЗ кавычек (true, false, числа)
set_config_safe() {
    KEY=$1
    VALUE=$2
    if ! wp config has "$KEY" --allow-root --path=/var/www/html > /dev/null 2>&1; then
        echo "➕ Добавляю конфиг: $KEY"
        wp config set "$KEY" "$VALUE" --raw --allow-root --path=/var/www/html
    fi
}

# Для значений В КАВЫЧКАХ (строки)
set_config_string_safe() {
    KEY=$1
    VALUE=$2
    if ! wp config has "$KEY" --allow-root --path=/var/www/html > /dev/null 2>&1; then
        echo "➕ Добавляю конфиг: $KEY"
        wp config set "$KEY" "$VALUE" --allow-root --path=/var/www/html
    fi
}

echo "🔌 Настраиваю wp-config.php..."


# ==============================================================================
# РАЗДЕЛ А: СИСТЕМНЫЕ НАСТРОЙКИ
# ==============================================================================
set_config_string_safe WP_MEMORY_LIMIT "512M"
set_config_safe WP_AUTO_UPDATE_CORE "false"
set_config_safe DISABLE_WP_CRON "true"


# ==============================================================================
# РАЗДЕЛ Б: НАСТРОЙКА REDIS
# ==============================================================================
set_config_string_safe WP_REDIS_HOST "redis"
set_config_safe        WP_REDIS_PORT 6379
set_config_safe        WP_REDIS_TIMEOUT 1
set_config_safe        WP_REDIS_READ_TIMEOUT 1
set_config_string_safe WP_CACHE_KEY_SALT "wp_cloud_"
set_config_safe        WP_REDIS_IGNORED_GROUPS "['counts', 'plugins', 'themes', 'comment', 'html-forms']"

# Сжатие и сериализация (ВАЖНО: добавляем как строки, в кавычках)
set_config_string_safe WP_REDIS_COMPRESSION "lz4" 
set_config_string_safe WP_REDIS_SERIALIZER "igbinary"


# ==============================================================================
# РАЗДЕЛ В: НАСТРОЙКА FLUENT STORAGE (ПОЛНАЯ)
# ==============================================================================

# --- Fluent Boards ---
set_config_string_safe FLUENT_BOARDS_CLOUD_STORAGE "amazon_s3"
set_config_string_safe FLUENT_BOARDS_CLOUD_STORAGE_ACCESS_KEY ""
set_config_string_safe FLUENT_BOARDS_CLOUD_STORAGE_SECRET_KEY ""
set_config_string_safe FLUENT_BOARDS_CLOUD_STORAGE_BUCKET ""
set_config_string_safe FLUENT_BOARDS_CLOUD_STORAGE_REGION ""
set_config_string_safe FLUENT_BOARDS_CLOUD_STORAGE_ENDPOINT ""
set_config_string_safe FLUENT_BOARDS_CLOUD_STORAGE_SUB_FOLDER ""

# --- Fluent Community ---
set_config_string_safe FLUENT_COMMUNITY_CLOUD_STORAGE "amazon_s3"
set_config_string_safe FLUENT_COMMUNITY_CLOUD_STORAGE_ACCESS_KEY ""
set_config_string_safe FLUENT_COMMUNITY_CLOUD_STORAGE_SECRET_KEY ""
set_config_string_safe FLUENT_COMMUNITY_CLOUD_STORAGE_BUCKET ""
set_config_string_safe FLUENT_COMMUNITY_CLOUD_STORAGE_REGION ""
set_config_string_safe FLUENT_COMMUNITY_CLOUD_STORAGE_ENDPOINT ""
set_config_string_safe FLUENT_COMMUNITY_CLOUD_STORAGE_SUB_FOLDER ""

# --- Fluent Cart ---
set_config_string_safe FLUENT_CART_CLOUD_STORAGE "amazon_s3"
set_config_string_safe FLUENT_CART_CLOUD_STORAGE_ACCESS_KEY ""
set_config_string_safe FLUENT_CART_CLOUD_STORAGE_SECRET_KEY ""
set_config_string_safe FLUENT_CART_CLOUD_STORAGE_BUCKET ""
set_config_string_safe FLUENT_CART_CLOUD_STORAGE_REGION ""
set_config_string_safe FLUENT_CART_CLOUD_STORAGE_ENDPOINT ""
set_config_string_safe FLUENT_CART_CLOUD_STORAGE_SUB_FOLDER ""


# ==============================================================================
# РАЗДЕЛ Г: СЕТЕВОЙ ФИКС (REVERSE PROXY / SSL)
# ==============================================================================
if ! grep -q "HTTP_X_FORWARDED_PROTO" /var/www/html/wp-config.php; then
    echo "🔧 Применяю SSL фикс для Reverse Proxy..."
    sed -i "1a if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && strpos(\$_SERVER['HTTP_X_FORWARDED_PROTO'], 'https') !== false) { \$_SERVER['HTTPS'] = 'on'; }" /var/www/html/wp-config.php
fi


# ==============================================================================
# ФИНАЛ
# ==============================================================================
touch "$MARKER"
echo "✅ Конфигурация завершена. Переходите к установке в браузере."