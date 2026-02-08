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

# Функция FORCE (для констант типа true/false/чисел). Перезаписывает.
set_config_force() {
    KEY=$1; VALUE=$2
    if wp config has "$KEY" --allow-root --path=/var/www/html > /dev/null 2>&1; then
        wp config set "$KEY" "$VALUE" --raw --type=constant --allow-root --path=/var/www/html
    else
        wp config set "$KEY" "$VALUE" --raw --type=constant --allow-root --path=/var/www/html
    fi
}

# Функция FORCE (для СТРОК). Перезаписывает.
# Исправлено: убран type=constant, чтобы строки были в кавычках.
set_config_string_force() {
    KEY=$1; VALUE=$2
    if wp config has "$KEY" --allow-root --path=/var/www/html > /dev/null 2>&1; then
        wp config set "$KEY" "$VALUE" --allow-root --path=/var/www/html
    else
        wp config set "$KEY" "$VALUE" --allow-root --path=/var/www/html
    fi
}

# Функция ONCE (для констант). Не перезаписывает, если уже есть.
set_config_once() {
    KEY=$1; VALUE=$2
    if ! wp config has "$KEY" --allow-root --path=/var/www/html > /dev/null 2>&1; then
        wp config set "$KEY" "$VALUE" --raw --allow-root --path=/var/www/html
    fi
}

# Функция ONCE (для СТРОК). Не перезаписывает, если уже есть.
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

# --- B. Сетевой фикс SSL ---
if ! grep -q "HTTP_X_FORWARDED_PROTO" /var/www/html/wp-config.php; then
    sed -i "1a if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && strpos(\$_SERVER['HTTP_X_FORWARDED_PROTO'], 'https') !== false) { \$_SERVER['HTTPS'] = 'on'; }" /var/www/html/wp-config.php
fi


# ==============================================================================
# 4. MU-PLUGINS (ЗАЩИТА REST API) - ВЫПОЛНЯЕТСЯ ВСЕГДА
# ==============================================================================
echo "🛡 Обновление MU-плагинов безопасности..."
mkdir -p /var/www/html/wp-content/mu-plugins

# 1. Защита от перебора
cat <<EOT > /var/www/html/wp-content/mu-plugins/disable-user-enum.php
<?php
/* Plugin Name: Stop User Enumeration */
add_filter( 'rest_endpoints', function( \$endpoints ) {
    if ( ! is_user_logged_in() ) {
        if ( isset( \$endpoints['/wp/v2/users'] ) ) unset( \$endpoints['/wp/v2/users'] );
        if ( isset( \$endpoints['/wp/v2/users/(?P<id>[\d]+)'] ) ) unset( \$endpoints['/wp/v2/users/(?P<id>[\d]+)'] );
    }
    return \$endpoints;
});
EOT

# 2. Скрытие ссылок и отключение Application Passwords
cat <<EOT > /var/www/html/wp-content/mu-plugins/hide-rest-links.php
<?php
/* Plugin Name: Hide REST API Links & Disable App Passwords */
remove_action('xmlrpc_rsd_apis', 'rest_output_rsd');
remove_action('wp_head', 'rest_output_link_wp_head');
remove_action('template_redirect', 'rest_output_link_header', 11, 0);
add_filter('wp_is_application_passwords_available', '__return_false');
EOT

# ==============================================================================
# 5. S3 UPLOADS (КОД ПЛАГИНА) - ВЫПОЛНЯЕТСЯ ВСЕГДА (ОБНОВЛЕНИЕ)
# ==============================================================================
echo "☁️ Проверка и обновление S3-Uploads..."
cd /var/www/html/wp-content/plugins

# Версия плагина (меняйте тут для обновления)
S3_VERSION="v3.0.6"

# Удаляем старую версию, чтобы накатить новую (Clean Install)
rm -rf s3-uploads
rm -f s3-uploads.zip

echo "⬇️ Скачиваю S3-Uploads ($S3_VERSION)..."
wget -q "https://github.com/humanmade/S3-Uploads/releases/download/$S3_VERSION/s3-uploads.zip" -O "s3-uploads.zip"

if [ -s "s3-uploads.zip" ]; then
    unzip -q "s3-uploads.zip" && rm "s3-uploads.zip"
    if [ -d "S3-Uploads-${S3_VERSION#v}" ]; then mv "S3-Uploads-${S3_VERSION#v}" "s3-uploads"; fi
    
    # --- A. Настройка WP-CLI (перезаписываем всегда) ---
    echo "⚙️ Обновляю wp-cli.yml..."
    cat <<EOT > /var/www/html/wp-cli.yml
require:
  - wp-content/plugins/s3-uploads/inc/class-wp-cli-command.php
EOT

    # --- B. MU-Plugin для Beget (перезаписываем всегда) ---
    echo "🔌 Обновляю адаптер Beget..."
    cat <<EOT > /var/www/html/wp-content/mu-plugins/s3-endpoint.php
<?php
/* Plugin Name: S3 Custom Endpoint (Beget Support) */
add_filter( 's3_uploads_s3_client_params', function ( \$params ) {
    if ( defined( 'S3_UPLOADS_ENDPOINT' ) && S3_UPLOADS_ENDPOINT ) {
        \$params['endpoint'] = S3_UPLOADS_ENDPOINT;
        \$params['use_path_style_endpoint'] = true;
        \$params['region'] = 'us-east-1';
    }
    return \$params;
});
EOT
    
    # Ручное включение (Ваш запрос: S3_UPLOADS_AUTOENABLE = false)
    # Используем тип 'constant', чтобы записать false без кавычек. Используем set_config_once, чтобы не сбить, если вы поменяете на true.
    set_config_once S3_UPLOADS_AUTOENABLE "false"

    # Активация
    wp plugin activate s3-uploads --allow-root --path=/var/www/html
else
    echo "❌ Ошибка скачивания S3-Uploads"
fi

# Возвращаемся в корень
cd /var/www/html

# ==============================================================================
# 6. ЗОНА "ОДИН РАЗ" (ПЛАГИНЫ И ПЕРВИЧНЫЙ КОНФИГ)
# ==============================================================================
MARKER="/var/www/html/.setup_done"

if [ ! -f "$MARKER" ]; then
    echo "🚀 Первый запуск! Начинаю полную установку..."

    # --- A. Конфигурация Redis ---
    echo "⚙️ Настраиваю Redis..."
    set_config_string_once WP_REDIS_HOST "redis"
    set_config_once        WP_REDIS_PORT 6379
    set_config_once        WP_REDIS_TIMEOUT 1
    set_config_once        WP_REDIS_READ_TIMEOUT 1
    set_config_string_once WP_CACHE_KEY_SALT "wp_cloud_"
    set_config_once        WP_REDIS_IGNORED_GROUPS "['counts', 'plugins', 'themes', 'comment', 'html-forms']"
    set_config_string_once WP_REDIS_COMPRESSION "lz4" 
    set_config_string_once WP_REDIS_SERIALIZER "igbinary"

    # --- B. Конфигурация Fluent Storage ---
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

    # --- C. S3 Uploads (Только конфиг!) ---
    echo "⚙️ Настраиваю S3 Uploads (пустые шаблоны)..."
    set_config_string_once S3_UPLOADS_BUCKET ""
    set_config_string_once S3_UPLOADS_KEY ""
    set_config_string_once S3_UPLOADS_SECRET ""
    set_config_string_once S3_UPLOADS_REGION ""
    set_config_string_once S3_UPLOADS_ENDPOINT ""

    # --- D. Лимиты и Ядро ---
    set_config_string_force WP_MEMORY_LIMIT "512M"
    set_config_force WP_AUTO_UPDATE_CORE "false"
    set_config_force DISABLE_WP_CRON "true"

    # --- E. Генерация ключей безопасности ---
    echo "🔑 Генерирую ключи (Salts)..."
    wp config shuffle-salts --allow-root --path=/var/www/html
    wp cache flush --allow-root --path=/var/www/html

    # --- F. Загрузка плагинов ---
    echo "📦 Скачиваю плагины..."
    cd /var/www/html/wp-content/plugins

    PLUGINS=(
      "wp-crontrol"
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

    touch "$MARKER"
    echo "✅ Первичная установка завершена."
fi

# ==============================================================================
# 7. ЗОНА "ВЫПОЛНЯТЬ ВСЕГДА" (ФИНАЛИЗАЦИЯ)
# ==============================================================================
# Этот код сработает ПРИ КАЖДОМ РЕДЕПЛОЕ

# --- H. Удаление мусора ---
echo "🗑 Очистка системы..."
rm -f /var/www/html/wp-content/plugins/hello.php
rm -rf /var/www/html/wp-content/plugins/akismet
rm -f /var/www/html/license.txt
rm -f /var/www/html/readme.html

# --- I. Финальные права доступа ---
echo "🔧 Финальная настройка прав..."
cd /var/www/html
mkdir -p wp-content/uploads

chown -R www-data:www-data /var/www/html
chmod -R 775 wp-content
chmod 640 /var/www/html/wp-config.php

# --- НАСТРОЙКА NGINX HELPER (ПУТЬ К КЭШУ) ---
echo "⚙️ Настраиваю путь кэша для Nginx Helper..."

echo "🎉 Полная конфигурация завершена."