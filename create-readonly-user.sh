#!/bin/bash
set -e

echo "🤖 Проверка настройки Read-Only пользователя..."

# --- ШАГ 1. ПРОВЕРКА ПАРОЛЯ ---
# Проверяем, пустая ли переменная READONLY_PASSWORD
if [ -z "$READONLY_PASSWORD" ]; then
    echo "ℹ️ Переменная READONLY_DB_PASSWORD не задана в Coolify."
    echo "⏭️ Пользователь 'monitor_user' создан НЕ БУДЕТ. Пропускаю."
    exit 0
fi

# --- ШАГ 2. СОЗДАНИЕ (Если пароль есть) ---
echo "🔑 Пароль обнаружен. Приступаю к настройке..."

# Экранируем \ и ' в пароле, чтобы он не ломал SQL.
PW_ESC=${READONLY_PASSWORD//\\/\\\\}
PW_ESC=${PW_ESC//\'/\\\'}

# Пароль root — через MYSQL_PWD, а не аргументом командной строки.
# CREATE IF NOT EXISTS + ALTER USER: пароль обновляется, даже если пользователь уже есть.
MYSQL_PWD="${MARIADB_ROOT_PASSWORD}" mysql -u root <<-EOSQL
    CREATE USER IF NOT EXISTS 'monitor_user'@'%' IDENTIFIED BY '${PW_ESC}';
    ALTER USER 'monitor_user'@'%' IDENTIFIED BY '${PW_ESC}';
    GRANT SELECT ON \`${MARIADB_DATABASE}\`.* TO 'monitor_user'@'%';
    FLUSH PRIVILEGES;
EOSQL

echo "✅ Пользователь 'monitor_user' успешно настроен."
