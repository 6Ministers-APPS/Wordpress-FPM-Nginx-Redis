# План работ: оптимизация и исправления WP-стека

Ветка: `claude/vigilant-faraday-7gw3ct`. Один шаг — один коммит.
Отметки: `[x]` сделано, `[ ]` не сделано, `[~]` частично / ждёт внешнего действия.

## Контекст сервера (замер от 2026-10-05)

- 6 vCPU, 12 ГБ RAM, swap 2 ГБ (занято ~0.9 ГБ), диск 145 ГБ (занято 28%).
- Coolify + 5 WP-стеков + Rybbit (ClickHouse/Postgres) + phpMyAdmin. CPU простаивает (~20% одного ядра суммарно).
- Реальное потребление стека: WordPress 430–590 МБ, MariaDB 160–400 МБ, Redis 5–34 МБ.
- Лимиты в шаблоне на один стек: ~7.4 ГБ (FPM 5×1024M, OPcache+JIT 640M, InnoDB 1G, Redis 512M, tmpfs 256M). Для 8 сайтов на 12 ГБ это перерасход.
- Бюджет: ОС+Coolify ~1 ГБ, Rybbit ~1.3 ГБ, резерв ~2 ГБ, на WP остаётся ~7.5 ГБ (~0.9 ГБ на сайт).
- Redis гоняет 7–13 ГБ трафика при 5–34 МБ данных: сериализатор igbinary и сжатие lz4 заданы, но не были установлены.

## Заметки по эксплуатации

- Под Coolify `container_name` переименовывается в `сервис-<uuid>-<суффикс>`, у каждого стека своя сеть. Фиксированные имена `mariadb`/`wp_redis` безопасны, **шаг про container_name из плана отменён**. Конфликт возможен только без Coolify или при включённой «Connect to Predefined Network».
- Изменения из репозитория применяются к стеку только после его редеплоя. Выкатывать сначала на один наименее важный сайт, через сутки на остальные.
- После смены сериализатора Redis сделать `wp cache flush` / `wp redis flush` (старые данные в другом формате).

## Этап 0. Замер «до» (на сервере, делает владелец)

- [x] 0.1 Ресурсы хоста: `nproc`, `free -h`, `df -h`, `docker stats`.
- [ ] 0.2 Размер каждой БД, RSS воркеров php-fpm, заполнение OPcache, `wp redis status`.
- [ ] 0.3 Базовый TTFB главной, внутренней страницы и `/wp-admin/`, заголовок `X-FastCGI-Cache`.
- [ ] 0.4 Бэкап: дамп БД (или WPvivid) и копия `wp-config.php`.
- [ ] 0.5 Разобрать два наблюдения: у стека `sq1uh2vbj5...` не запущен nginx (`0B/0B`), у wp-cron стека `zshy39...` 12/9 ГБ сети и 4.8/5.3 ГБ диска.

Команды для 0.2 и 0.5:

```bash
for c in $(docker ps --format '{{.Names}}' | grep ^mariadb-); do
  echo -n "$c: "; docker exec $c sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -N -e "SELECT ROUND(SUM(data_length+index_length)/1024/1024) FROM information_schema.tables"'
done
for c in $(docker ps --format '{{.Names}}' | grep ^wordpress-); do
  echo "== $c"; docker exec $c sh -c 'ps -o rss= -C php-fpm | sort -n | tail -3'
  docker exec $c php -r 'var_dump(opcache_get_status(false)["memory_usage"]["used_memory"]/1048576);' 2>/dev/null
done
docker logs --tail 50 $(docker ps --format '{{.Names}}' | grep ^wp-cron-zshy)
docker ps -a --filter name=nginx-sq1uh --format '{{.Status}}'; docker logs --tail 30 $(docker ps -aq --filter name=nginx-sq1uh)
```

## Этап 1. Образ и критичные ошибки

- [x] 1.1 `Dockerfile`: igbinary 3.2.16 + phpredis 6.2.0 с igbinary/lz4/zstd, WP-CLI 2.12.0 с проверкой sha512, убраны лишние пакеты. Коммит `b022344`, **локально, не запушен**.
  - Проверка после сборки: `php --ri redis` показывает igbinary и lz4; `wp redis status` без ошибок.
  - Сборка не проверялась (в среде разработки нет Docker и закрыт PECL) — первая сборка в Coolify на одном сайте.
- [x] 1.2 `docker-compose.yaml`: закреплены `redis:7-alpine` и `fholzer/nginx-brotli:v1.31.3`, убран volume `redis-data`. `container_name` не трогали. Общий образ для `wordpress` и `wp-cron` не делали: Coolify собирает сервисы сам, второй `build` берётся из кэша слоёв.
- [x] 1.3 wp-cron: запуск от `33:33` без `--allow-root`, ожидание `wp-config.php` вместо `sleep 20`, убрать «временный» вывод.
  - Проверка: `find wp-content -user root` пусто.
- [x] 1.4 Сброс объектного кэша Redis после смены сериализатора (init-script один раз делает `wp cache flush`, маркер `.redis_format_igbinary_lz4`).

## Этап 2. Надёжность запуска

- [ ] 2.1 Healthcheck: FPM через `ping.path` + `cgi-fcgi`; MariaDB через `healthcheck.sh --connect --innodb_initialized`; `depends_on: condition: service_healthy`; `restart: unless-stopped` для всех сервисов.
- [ ] 2.2 `init-script.sh`: убрать цикл `chmod 1777` каждые 30 с; убрать `chown -R` по всему сайту при каждом старте; права 755/644 вместо `chmod -R 775`; S3-Uploads скачивать только при смене версии; `wp` вызывать от `www-data`.
- [ ] 2.3 Не выставлять `FLUENT_*_CLOUD_STORAGE=amazon_s3`, пока ключи пустые.
- [ ] 2.4 `create-readonly-user.sh`: экранирование пароля в SQL, ограничить хост `monitor_user`.

## Этап 3. Nginx: кэш, безопасность, реальный IP

- [ ] 3.1 Реальный IP клиента: `set_real_ip_from` для сетей Docker/Traefik, `real_ip_header X-Forwarded-For`.
- [ ] 3.2 FastCGI-кэш: `cache_lock`, `background_update`, `use_stale ... updating`, TTL 12h (чистит Nginx Helper); исправить регулярку `$skip_cache_query` (сейчас `s=`/`p=` цепляют лишние URL), привязать к `(^|&)`.
  - Проверка: `?utm_source=x` → HIT, `?s=x` → BYPASS.
- [ ] 3.3 Статика и сжатие: не ставить `expires max` на html/xml; убрать двойной Cache-Control в блоке CompressX (`private` + `expires`); дополнить `brotli_types`, включить `brotli_static`/`gzip_static`.
- [ ] 3.4 Безопасность: `limit_req` на `wp-login.php`; заголовки с `always` для всех location (убрать устаревший `X-XSS-Protection`, добавить `Referrer-Policy`, `Permissions-Policy`); ротация логов `./logs/nginx` или вывод в stdout.
- [ ] 3.5 Unix-сокет между nginx и PHP-FPM через общий volume.

## Этап 4. PHP-FPM, OPcache, MariaDB, Redis (числа под 8 сайтов на 12 ГБ)

Все значения вынести в переменные окружения Coolify, чтобы тяжёлому сайту их можно было поднять без правки файлов.

- [ ] 4.1 PHP: `memory_limit` 1024M → 256M (`WP_MAX_MEMORY_LIMIT` 512M для админки); единые таймауты — 60s для фронта и отдельный `location /wp-admin/` на 300s для бэкапов/импорта; логи PHP в stderr.
- [ ] 4.2 FPM: `pm = ondemand`, `max_children = 6`, `process_idle_timeout = 30s`, `max_requests = 500`, slowlog.
- [ ] 4.3 OPcache: 512M → 128M, JIT выключить, `revalidate_freq 60` (или `validate_timestamps=0` со сбросом при деплое), `save_comments=1`.
- [ ] 4.4 MariaDB: `innodb_buffer_pool_size` 1G → 256M (уточнить по размерам БД из 0.2), `innodb_log_file_size` = 25% пула, `table_open_cache`, `thread_cache_size`, `slow_query_log` (`long_query_time=1`).
- [ ] 4.5 Redis: `maxmemory` 512M → 128M (уточнить по `used_memory`); tmpfs-кэш nginx 256M → 128M.
- [ ] 4.6 Лимиты контейнеров (`mem_limit`): wordpress 1G, mariadb 512M, redis 160M, nginx 64M.
  - Проверка через сутки: `docker stats`, swap ≈ 0. Нагрузочный тест `hey`/`ab` на некэшированную страницу до и после.

## Этап 5. Приложение WordPress (в админке, вместе с владельцем)

- [ ] 5.1 Размер autoload в `wp_options`: `wp db query "SELECT SUM(LENGTH(option_value))/1024/1024 FROM wp_options WHERE autoload IN ('yes','on')"`, вычистить тяжёлые опции.
- [ ] 5.2 Аудит плагинов на пересечения (Autoptimize и CompressX при FastCGI-кэше, два набора аддонов Elementor, Security Ninja и Fluent Security). Отключение решает владелец.
- [ ] 5.3 Найти тяжёлые плагины по `slow_query_log`.

## Этап 6. Хост и внешний слой

- [ ] 6.1 `setup.sh`: `vm.swappiness=10`, `unattended-upgrades`, предупреждение, что опубликованные порты Docker обходят правила UFW.
- [ ] 6.2 HTTP/3 и HSTS в Traefik (Coolify).
- [ ] 6.3 (опционально) CDN перед сайтами.
- [ ] 6.4 Скрипт подключения phpMyAdmin к сетям всех стеков (`docker network connect`), запускать после редеплоя. Входить под `monitor_user` (чтение), не под root; не публиковать phpMyAdmin без basic auth или фильтра по IP. Включить `PMA_ARBITRARY=1` или задать `PMA_HOSTS`/`PMA_VERBOSES`.

```bash
for c in $(docker ps --format '{{.Names}}' | grep ^mariadb-); do
  echo "$c → $(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' $c)"
done
PMA=$(docker ps --format '{{.Names}}' | grep ^phpmyadmin-)
for n in <uuid-стека-1> <uuid-стека-2> ...; do docker network connect $n $PMA; done
```

## Этап 7. Документация и итог

- [ ] 7.1 Обновить README: новые переменные окружения, бюджет памяти, как проверять кэш. Сейчас там устаревшие числа (`pm.max_children = 10`, «~4GB RAM»).
- [ ] 7.2 Повторить замеры этапа 0 и составить таблицу «до/после».

## Прочие мелочи

- [ ] Удалить пустой неиспользуемый `php/pma-custom-php.ini`.
- [ ] Закрепить тег `redis` вместо `latest`.
- [ ] Healthcheck MariaDB без пароля root в командной строке (см. 2.1).
- [ ] `location = /xmlrpc.php { deny all; }` ломает Jetpack и мобильное приложение WP: убедиться, что они не используются.

## Блокеры

Нет.
