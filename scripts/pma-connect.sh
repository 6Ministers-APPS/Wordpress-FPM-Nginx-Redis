#!/bin/bash
# Подключает контейнер phpMyAdmin к сетям всех WordPress-стеков на этом сервере,
# чтобы одним phpMyAdmin можно было открыть базы всех сайтов.
#
# Запускать на хосте от root ПОСЛЕ каждого редеплоя phpMyAdmin или WP-стека
# (подключение к сети не переживает пересоздание контейнера, а суффикс имени
# контейнера MariaDB после редеплоя меняется).
#
# Использование:  ./scripts/pma-connect.sh
# Затем в phpMyAdmin (PMA_ARBITRARY=1) в поле «Сервер» вводите имя контейнера из списка ниже
# и логин monitor_user (только чтение, см. create-readonly-user.sh), а не root.
set -euo pipefail

nets_of() {
    docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$1"
}

PMA=$(docker ps --format '{{.Names}}' | grep -m1 '^phpmyadmin-' || true)
if [ -z "$PMA" ]; then
    echo "❌ Контейнер phpMyAdmin не найден (имя должно начинаться с 'phpmyadmin-')." >&2
    exit 1
fi
echo "phpMyAdmin: $PMA"
echo

for DB in $(docker ps --format '{{.Names}}' | grep '^mariadb-'); do
    for NET in $(nets_of "$DB"); do
        if nets_of "$PMA" | tr ' ' '\n' | grep -qx "$NET"; then
            STATUS="уже подключён"
        else
            docker network connect "$NET" "$PMA"
            STATUS="подключён"
        fi
        echo "$DB   (сеть $NET: $STATUS)"
    done
done

echo
echo "Подсказка: чтобы выбирать сервер из списка, задайте в env phpMyAdmin:"
echo "  PMA_HOSTS=<имена mariadb-... через запятую>"
echo "  PMA_VERBOSES=<подписи через запятую в том же порядке>"
