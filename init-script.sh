#!/bin/bash

# ==============================================================================
# 0. НАСТРОЙКА ОКРУЖЕНИЯ
# ==============================================================================
CACHE_DIR="/var/run/nginx-cache"

if [ ! -d "$CACHE_DIR" ]; then
    echo "📁 Папка кэша не найдена. Создаю: $CACHE_DIR"
    mkdir -p "$CACHE_DIR"
else
    echo "👌 Папка кэша уже существует."
fi

chmod 777 "$CACHE_DIR"
echo "🔓 Права 777 для кэша установлены."


# ==============================================================================
# 1. ГЛОБАЛЬНАЯ ЗАЩИТА (МАРКЕР)
# ==============================================================================
# Если этот файл есть, скрипт полностью прекращает работу.
MARKER="/var/www/html/.setup_done"

if [ -f "$MARKER" ]; then
    echo "✅ Глобальный маркер найден (.setup_done). Скрипт завершен."
    exit 0
fi

echo "🚀 Первый запуск. Ждем инициализации WordPress..."

# Ждем создания wp-config.php
until [ -f "/var/www/html/wp-config.php" ]; do
    sleep 2
    echo "⏳ Жду появления wp-config.php..."
done
sleep 3


# ==============================================================================
# 2. ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ==============================================================================
set_config_safe() {
    KEY=$1; VALUE=$2
    if ! wp config has "$KEY" --allow-root --path=/var/www/html > /dev/null 2>&1; then
        echo "➕ Добавляю конфиг: $KEY"
        wp config set "$KEY" "$VALUE" --raw --allow-root --path=/var/www/html
    fi
}

set_config_string_safe() {
    KEY=$1; VALUE=$2
    if ! wp config has "$KEY" --allow-root --path=/var/www/html > /dev/null 2>&1; then
        echo "➕ Добавляю конфиг: $KEY"
        wp config set "$KEY" "$VALUE" --allow-root --path=/var/www/html
    fi
}

echo "🔌 Начинаю настройку wp-config.php..."


# ==============================================================================
# РАЗДЕЛ А: СИСТЕМНЫЕ НАСТРОЙКИ (Выполняются всегда при первом запуске)
# ==============================================================================
set_config_string_safe WP_MEMORY_LIMIT "512M"
set_config_safe WP_AUTO_UPDATE_CORE "false"
set_config_safe DISABLE_WP_CRON "true"


# ==============================================================================
# ПРОВЕРКА НА СУЩЕСТВОВАНИЕ REDIS
# ==============================================================================
# Если плагин Redis уже установлен, мы пропускаем настройку его конфигов
# и конфигов Fluent, чтобы не перезаписать пользовательские данные.

if [ -d "/var/www/html/wp-content/plugins/redis-cache" ]; then
    echo "⚠️ Плагин Redis найден. Пропускаю настройку разделов Б и В..."
else
    echo "⚙️ Redis не найден. Применяю настройки..."

    # ==============================================================================
    # РАЗДЕЛ Б: НАСТРОЙКА REDIS (Выполняется, только если нет плагина)
    # ==============================================================================
    set_config_string_safe WP_REDIS_HOST "redis"
    set_config_safe        WP_REDIS_PORT 6379
    set_config_safe        WP_REDIS_TIMEOUT 1
    set_config_safe        WP_REDIS_READ_TIMEOUT 1
    set_config_string_safe WP_CACHE_KEY_SALT "wp_cloud_"
    set_config_safe        WP_REDIS_IGNORED_GROUPS "['counts', 'plugins', 'themes', 'comment', 'html-forms']"
    set_config_string_safe WP_REDIS_COMPRESSION "lz4" 
    set_config_string_safe WP_REDIS_SERIALIZER "igbinary"


    # ==============================================================================
    # РАЗДЕЛ В: FLUENT STORAGE (Выполняется, только если нет плагина Redis)
    # ==============================================================================
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
fi

# ==============================================================================
# РАЗДЕЛ F: ЛОГИРОВАНИЕ ОШИБОК (DEBUG LOG)
# ==============================================================================
# Включает режим отладки, но скрывает ошибки с экрана и пишет их в файл.
# Файл будет лежать тут: /var/www/html/wp-content/debug.log

echo "🐞 Настраиваю Error Log..."

# Принимаем значения из Docker Compose.
# Если вдруг переменная пришла пустой, ставим безопасный дефолт.
ENV_WP_DEBUG=${WP_DEBUG:-false}
ENV_WP_DEBUG_LOG=${WP_DEBUG_LOG:-false}
ENV_WP_DEBUG_DISPLAY=${WP_DEBUG_DISPLAY:-false}

set_config_safe WP_DEBUG "$ENV_WP_DEBUG"
set_config_safe WP_DEBUG_LOG "$ENV_WP_DEBUG_LOG"
set_config_safe WP_DEBUG_DISPLAY "$ENV_WP_DEBUG_DISPLAY"
set_config_safe SCRIPT_DEBUG "false"


# ==============================================================================
# РАЗДЕЛ Г: СЕТЕВОЙ ФИКС (REVERSE PROXY)
# ==============================================================================
if ! grep -q "HTTP_X_FORWARDED_PROTO" /var/www/html/wp-config.php; then
    echo "🔧 Применяю SSL фикс..."
    sed -i "1a if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && strpos(\$_SERVER['HTTP_X_FORWARDED_PROTO'], 'https') !== false) { \$_SERVER['HTTPS'] = 'on'; }" /var/www/html/wp-config.php
fi


# ==============================================================================
# РАЗДЕЛ E: ЗАГРУЗКА ПЛАГИНОВ
# ==============================================================================
echo "📦 Проверка и загрузка плагинов..."

# Переходим в папку плагинов
cd /var/www/html/wp-content/plugins

# Список плагинов
PLUGINS=(
  "mainwp-child"
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

# Цикл загрузки стандартных плагинов
for plugin in "${PLUGINS[@]}"; do
    if [ ! -d "$plugin" ]; then
        echo "⬇️ Скачиваю $plugin..."
        # Используем wget. Если его нет, скрипт упадет.
        wget -q "https://downloads.wordpress.org/plugin/$plugin.latest-stable.zip" -O "$plugin.zip"
        
        if [ -s "$plugin.zip" ]; then
            unzip -q "$plugin.zip" && rm "$plugin.zip"
            echo "✅ $plugin установлен."
        else
            echo "❌ Ошибка скачивания $plugin (проверьте имя/интернет)."
            rm -f "$plugin.zip"
        fi
    else
        : # Плагин уже есть, пропускаем молча
    fi
done

# УДАЛЕНИЕ МУСОРА (Hello Dolly)
# Проверяем и удаляем файл hello.php, который идет по умолчанию с WordPress
if [ -f "hello.php" ]; then
    echo "🗑 Удаляю Hello Dolly..."
    rm -f "hello.php"
fi

# Также можно удалить Akismet, если вы им не пользуетесь (он идет папкой)
if [ -d "akismet" ]; then
    echo "🗑 Удаляю Akismet..."
    rm -rf "akismet"
fi

# ==============================================================================
# ФИНАЛЬНОЕ ИСПРАВЛЕНИЕ ПРАВ
# ==============================================================================
echo "🔧 Исправляю права доступа для всей папки wp-content..."

# 1. Создаем папку uploads, если её вдруг нет (чтобы сразу задать права)
mkdir -p /var/www/html/wp-content/uploads

# 2. Отдаем права пользователю веб-сервера (www-data)
# Мы делаем это для всей папки wp-content, чтобы захватить uploads, plugins, themes и cache
chown -R www-data:www-data /var/www/html/wp-content

# 3. Дополнительная страховка: права на запись для группы
chmod -R 775 /var/www/html/wp-content

# ==============================================================================
# ФИНАЛ
# ==============================================================================
touch "$MARKER"
echo "✅ Конфигурация завершена."