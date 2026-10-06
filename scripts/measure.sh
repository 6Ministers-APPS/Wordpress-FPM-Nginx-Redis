#!/bin/bash
# Снимает показатели всех WordPress-стеков на этом сервере: память, воркеры PHP, Redis, БД, autoload,
# и замеряет скорость ответа по указанным адресам. Ничего не меняет, только читает.
#
# Запускать на хосте от root. Результат печатается и сохраняется в measure-<метка>-<дата>.txt.
#
#   LABEL=before ./scripts/measure.sh https://site1.ru https://site2.ru
#   LABEL=after  ./scripts/measure.sh https://site1.ru https://site2.ru
#
# Без адресов снимаются только показатели контейнеров.
set -u

LABEL=${LABEL:-run}
OUT="measure-${LABEL}-$(date +%Y%m%d-%H%M).txt"
exec > >(tee "$OUT") 2>&1

hr() { echo; echo "=================== $* ==================="; }

hr "ХОСТ ($(date '+%F %T'))"
echo "CPU: $(nproc) ядер; load average: $(cut -d' ' -f1-3 /proc/loadavg)"
free -h
echo "swappiness: $(cat /proc/sys/vm/swappiness)"
echo "swap in/out с момента загрузки (страниц): $(grep -E '^pswp(in|out)' /proc/vmstat | tr '\n' ' ')"
echo "OOM-убийств в логе ядра: $(dmesg 2>/dev/null | grep -ci 'out of memory\|oom-kill')"

hr "ПАМЯТЬ ПО КОНТЕЙНЕРАМ"
docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}'

for WP in $(docker ps --format '{{.Names}}' | grep '^wordpress-'); do
    ID=${WP#wordpress-}      # <uuid>-<суффикс>
    UUID=${ID%-*}
    DB=$(docker ps --format '{{.Names}}' | grep -m1 "^mariadb-${UUID}")
    RD=$(docker ps --format '{{.Names}}' | grep -m1 "^wp_redis-${UUID}")
    NG=$(docker ps --format '{{.Names}}' | grep -m1 "^nginx-${UUID}")

    hr "СТЕК $UUID"
    echo "лимиты памяти (МБ, 0 = не задан):"
    for C in "$WP" "$DB" "$RD" "$NG"; do
        [ -n "$C" ] && printf '  %-62s %s\n' "$C" "$(( $(docker inspect -f '{{.HostConfig.Memory}}' "$C") / 1048576 ))"
    done
    echo "статус здоровья: wordpress=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}нет{{end}}' "$WP")" \
         "перезапусков=$(docker inspect -f '{{.RestartCount}}' "$WP")" \
         "OOMKilled=$(docker inspect -f '{{.State.OOMKilled}}' "$WP")"

    echo "--- воркеры PHP-FPM (RSS, МБ)"
    docker exec "$WP" sh -c 'for d in /proc/[0-9]*; do [ "$(cat $d/comm 2>/dev/null)" = php-fpm ] && awk "/VmRSS/{print \$2}" $d/status; done' 2>/dev/null \
        | sort -n | awk '{a[NR]=$1/1024} END{ if(NR==0){print "  нет данных"} else {s=0; for(i=1;i<=NR;i++)s+=a[i]; printf "  процессов (с master): %d, мин %.0f, макс %.0f, средний %.0f\n",NR,a[1],a[NR],s/NR} }'

    echo "--- PHP/окружение"
    docker exec "$WP" sh -c 'echo "  memory_limit=$(php -r "echo ini_get(\"memory_limit\");") PHP_FPM_MAX_CHILDREN=$PHP_FPM_MAX_CHILDREN OPCACHE_MEMORY=$PHP_OPCACHE_MEMORY$OPCACHE_MEMORY"; php --ri redis 2>/dev/null | grep -iE "igbinary|lz4|zstd" | sed "s/^/  redis: /"' 2>/dev/null

    echo "--- WordPress (от www-data)"
    WPX() { docker exec -u www-data -e HOME=/tmp "$WP" wp "$@" --path=/var/www/html 2>&1 | tail -n "${TAIL:-12}"; }
    echo "  активных плагинов: $(WPX plugin list --status=active --field=name | wc -l)"
    PHP='global $wpdb; echo "autoload: ", round($wpdb->get_var("SELECT SUM(LENGTH(option_value)) FROM {$wpdb->options} WHERE autoload IN (\"yes\",\"on\",\"auto-on\",\"auto\")")/1048576, 2), " МБ; размер БД: ", round($wpdb->get_var("SELECT SUM(data_length+index_length) FROM information_schema.tables WHERE table_schema=DATABASE()")/1048576), " МБ\n";'
    echo "  $(docker exec -u www-data -e HOME=/tmp "$WP" wp eval "$PHP" --path=/var/www/html 2>&1 | tail -1)"
    echo "  объектный кэш:"; TAIL=8 WPX redis status | sed 's/^/    /'

    if [ -n "$RD" ]; then
        echo "--- Redis"
        docker exec "$RD" redis-cli info memory | grep -E '^(used_memory_human|maxmemory_human)' | sed 's/^/  /'
        docker exec "$RD" redis-cli info stats | awk -F: '/^keyspace_hits/{h=$2} /^keyspace_misses/{m=$2} /^evicted_keys/{e=$2} END{t=h+m; printf "  hit rate: %.1f%% (hits %d, misses %d), вытеснено ключей: %d\n", (t?100*h/t:0), h, m, e}'
    fi
done

if [ $# -gt 0 ]; then
    hr "СКОРОСТЬ ОТВЕТА (TTFB = время до первого байта)"
    probe() {   # probe <метка> <url>
        local H; H=$(mktemp)
        local R; R=$(curl -s -o /dev/null -D "$H" -H 'Accept-Encoding: br,gzip' -w '%{http_code} ttfb=%{time_starttransfer}s total=%{time_total}s size=%{size_download}Б' --max-time 60 "$2")
        printf '  %-28s %s  cache=%s\n' "$1" "$R" "$(grep -i '^x-fastcgi-cache' "$H" | awk '{print $2}' | tr -d '\r')"
        rm -f "$H"
    }
    for U in "$@"; do
        U=${U%/}
        echo "$U"
        probe "главная (1-й запрос)" "$U/"
        probe "главная (2-й)" "$U/"
        probe "главная (3-й)" "$U/"
        probe "поиск ?s= (PHP, без кэша)" "$U/?s=test"
        probe "wp-login.php (PHP, без кэша)" "$U/wp-login.php"
    done
    echo
    echo "Ожидание: 2-й и 3-й запрос главной — cache=HIT и TTFB в десятки мс; поиск и wp-login — cache=BYPASS."
    echo "Админку (залогиненный пользователь) замерьте вручную в браузере: DevTools → Network → время ответа /wp-admin/."
fi

echo
echo "Сохранено в $OUT"
