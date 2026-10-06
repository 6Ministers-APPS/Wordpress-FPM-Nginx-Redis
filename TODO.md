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

- [x] 2.1 Healthcheck FPM через `ping.path` + `cgi-fcgi` (пакет `libfcgi-bin` в образе); `depends_on: condition: service_healthy`; `restart: unless-stopped` для всех сервисов. MariaDB: пароль root передаётся через `MYSQL_PWD`, а не в аргументах. `healthcheck.sh` из образа не берём: на уже существующих каталогах данных нет служебного пользователя `healthcheck`, стек стал бы unhealthy.
- [~] 2.2 `init-script.sh` (сделано всё, кроме вызова `wp` от www-data: владельца файлов исправляет `find ... chown` в конце, так что на практике безопасно): убрать цикл `chmod 1777` каждые 30 с; убрать `chown -R` по всему сайту при каждом старте; права 755/644 вместо `chmod -R 775`; S3-Uploads скачивать только при смене версии; `wp` вызывать от `www-data`.
- [x] 2.3 Не выставлять `FLUENT_*_CLOUD_STORAGE=amazon_s3`, пока ключи пустые.
- [x] 2.4 `create-readonly-user.sh`: экранирование пароля, `ALTER USER` (пароль обновляется), root-пароль через `MYSQL_PWD`. Хост `'%'` оставлен: порт БД наружу не публикуется, подсеть Docker заранее неизвестна. Скрипт, как и раньше, срабатывает только при первой инициализации каталога данных.

## Этап 3. Nginx: кэш, безопасность, реальный IP

- [x] 3.1 Реальный IP клиента: `set_real_ip_from` для сетей Docker/Traefik, `real_ip_header X-Forwarded-For`.
- [x] 3.2 FastCGI-кэш: `cache_lock`, `background_update`, `use_stale ... updating`, TTL 12h (чистит Nginx Helper); исправить регулярку `$skip_cache_query` (сейчас `s=`/`p=` цепляют лишние URL), привязать к `(^|&)`.
  - Проверка: `?utm_source=x` → HIT, `?s=x` → BYPASS.
- [x] 3.3 Статика и сжатие: не ставить `expires max` на html/xml; убрать двойной Cache-Control в блоке CompressX (`private` + `expires`); дополнить `brotli_types`, включить `brotli_static`/`gzip_static`.
- [x] 3.4 Безопасность: `limit_req` на `wp-login.php`; заголовки с `always` для всех location (убран устаревший `X-XSS-Protection`, добавлен `Referrer-Policy`; `Permissions-Policy` не добавляли: `camera=()`/`payment=()` ломают встроенные видеозвонки и платёжные формы Fluent); ротация логов `./logs/nginx` или вывод в stdout.
- [x] 3.5 Unix-сокет между nginx и PHP-FPM через общий volume.

## Этап 4. PHP-FPM, OPcache, MariaDB, Redis (расчёт под 7 сайтов на 12 ГБ)

Сделано в коде (значения по умолчанию = профиль «обычный», всё переопределяется переменными окружения в Coolify):

- [x] 4.1 PHP: `memory_limit` 256M, `max_execution_time` 300, `default_socket_timeout` 60; ошибки PHP в stderr. nginx: `/wp-admin/*.php` с тайм-аутами 300s (общая часть вынесена в `nginx/php-fastcgi.inc`), фронт 60s. `WP_MEMORY_LIMIT`/`WP_MAX_MEMORY_LIMIT` теперь пишутся в `wp-config.php` при каждом старте из окружения (раньше 512M ставилось один раз и само поднимало лимит PHP для всех запросов).
- [x] 4.2 FPM: `pm = ondemand`, `max_children` из `PHP_FPM_MAX_CHILDREN`, `process_idle_timeout 30s`, `max_requests 500`, slowlog (>10 с) в лог контейнера.
- [x] 4.3 OPcache: `OPCACHE_MEMORY` (128/192), JIT выключен, `interned_strings_buffer 32`, `revalidate_freq 60`.
- [x] 4.4 MariaDB: пул и соединения из окружения, `innodb_log_file_size 128M`, `tmp_table_size 32M`, `table_open_cache`, `thread_cache_size`, slow log (`long_query_time=1`, файл `mariadb-data/slow.log` — периодически очищать).
- [x] 4.5 Redis: `maxmemory` из окружения (64mb/128mb). Кэш nginx в tmpfs 256M → 128M (`max_size=110m`, `inactive=12h`, `keys_zone=20m`).
- [x] 4.6 `mem_limit` для всех контейнеров (см. таблицу). Лимит nginx 192M включает tmpfs-кэш — он считается в память контейнера.
- [ ] 4.7 Проверка после выкатки (через сутки): `docker stats`, `free -h` (swap не растёт), `wp redis status`, заголовок `X-FastCGI-Cache`, лог контейнера на `slowlog`/`OOM`. Нагрузочный тест `hey -z 30s -c 20 <url>` на кэшируемую и на некэшируемую (`?s=x`) страницу до/после.

### Профили ресурсов (7 сайтов: 4 нагруженных + 3 обычных)

| Переменная окружения | Обычный (по умолчанию) | Нагруженный |
|---|---|---|
| `PHP_FPM_MAX_CHILDREN` | 5 | 8 |
| `PHP_MEMORY_LIMIT` / `WP_MEMORY_LIMIT` | 256M | 256M |
| `WP_MAX_MEMORY_LIMIT` (админка) | 512M | 512M |
| `OPCACHE_MEMORY` | 128 | 192 |
| `WORDPRESS_MEM_LIMIT` | 768m | 1280m |
| `INNODB_BUFFER_POOL_SIZE` | 192M | 512M |
| `DB_MAX_CONNECTIONS` | 60 | 80 |
| `DB_MEM_LIMIT` | 512m | 1g |
| `REDIS_MAXMEMORY` | 64mb | 128mb |
| `REDIS_MEM_LIMIT` | 128m | 192m |
| `CRON_MEM_LIMIT` | 256m | 256m |
| nginx (не настраивается) | 192m (кэш 128M) | 192m (кэш 128M) |
| **Потолок на сайт** | **~1.8 ГБ** | **~2.9 ГБ** |
| **Типично в работе** (оценка) | ~0.6 ГБ | ~1.2 ГБ |

Бюджет сервера (11.7 ГБ): типично 3×0.6 + 4×1.2 ≈ 6.6 ГБ на WP + ~1.9 ГБ остальное (Coolify, Traefik, Rybbit, phpMyAdmin) ≈ 8.5 ГБ, ~3 ГБ остаётся под кэш файловой системы и пики. Сумма потолков (~17 ГБ) больше RAM намеренно: все сайты одновременно на максимуме не бывают, а лимит защищает от того, что один сайт съест всё. Если по `docker stats` реальный RSS окажется выше оценки — поднимать профиль «нагруженный» нужно только тем сайтам, которым это действительно нужно. Размер `INNODB_BUFFER_POOL_SIZE` уточнить по размеру БД (этап 0.2): пул больше данных бессмысленен.

## Этап 5. Приложение WordPress (в админке, вместе с владельцем)

- [ ] 5.1 Размер autoload в `wp_options`: `wp db query "SELECT SUM(LENGTH(option_value))/1024/1024 FROM wp_options WHERE autoload IN ('yes','on')"`, вычистить тяжёлые опции.
- [~] 5.2 Из шаблона убраны (список согласован с владельцем): essential-addons-for-elementor-lite, essential-blocks, templately, mainwp-child, sessions, independent-analytics, aimogen, ninja-tables, wp-payment-form, fluent-affiliate/-booking/-cart/-boards/-support/-community. Осталось 18 плагинов. **На уже работающих сайтах они остаются — удалять вручную** (`wp plugin deactivate <имя> && wp plugin delete <имя>`): сначала бэкап и проверка, что на страницах не используются их блоки/виджеты (особенно Essential Addons/Blocks и Templately в Elementor). Оставшийся аудит: плагинов на пересечения (Autoptimize и CompressX при FastCGI-кэше, два набора аддонов Elementor, Security Ninja и Fluent Security). Отключение решает владелец.
- [ ] 5.3 Найти тяжёлые плагины по `slow_query_log`.

## Этап 6. Хост и внешний слой

- [x] 6.1 `setup.sh`: `vm.swappiness=10`, `unattended-upgrades`, предупреждение, что опубликованные порты Docker обходят правила UFW.
- [ ] 6.2 HTTP/3 и HSTS в Traefik (Coolify).
- [ ] 6.3 (опционально) CDN перед сайтами.
- [x] 6.4 `scripts/pma-connect.sh`. Скрипт подключения phpMyAdmin к сетям всех стеков (`docker network connect`), запускать после редеплоя. Входить под `monitor_user` (чтение), не под root; не публиковать phpMyAdmin без basic auth или фильтра по IP. Включить `PMA_ARBITRARY=1` или задать `PMA_HOSTS`/`PMA_VERBOSES`.

```bash
for c in $(docker ps --format '{{.Names}}' | grep ^mariadb-); do
  echo "$c → $(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' $c)"
done
PMA=$(docker ps --format '{{.Names}}' | grep ^phpmyadmin-)
for n in <uuid-стека-1> <uuid-стека-2> ...; do docker network connect $n $PMA; done
```

## Этап 7. Документация и итог

- [x] 7.1 Обновить README: новые переменные окружения, бюджет памяти, как проверять кэш. Сейчас там устаревшие числа (`pm.max_children = 10`, «~4GB RAM»).
- [ ] 7.2 Повторить замеры этапа 0 и составить таблицу «до/после».

## Прочие мелочи

- [x] Удалить пустой неиспользуемый `php/pma-custom-php.ini`.
- [x] Закрепить тег `redis` вместо `latest`.
- [x] Healthcheck MariaDB без пароля root в командной строке (см. 2.1).
- [ ] `location = /xmlrpc.php { deny all; }` ломает Jetpack и мобильное приложение WP: убедиться, что они не используются.

## Инцидент 2026-10-06: деплой стека упал на healthcheck MariaDB

- Причина: в образе `mariadb:11.8` нет `mysqladmin` (клиент называется `mariadb-admin`). Старый healthcheck не работал и раньше, но от него ничего не зависело, пока я не добавил `depends_on: service_healthy`; деплой остановился, новые wordpress/nginx/wp-cron остались в статусе Created, сайт лежал. Вручную запущено `docker start` на три контейнера.
- Исправлено: healthcheck ищет `mariadb-admin` или `mysqladmin` (+ `start_period: 60s`); `depends_on` без условий здоровья (healthcheck остаётся для статуса); `create-readonly-user.sh` вызывает `mariadb`; возвращены прежние `size=256M` у тома `fastcgi_cache` (смена параметров существующего тома ломает деплой) и `innodb_log_file_size = 256M`.
- Урок для выкатки: проверять healthcheck на реальном образе до того, как от него начинают зависеть другие сервисы.
- [ ] Убрать устаревший `innodb_flush_method = O_DIRECT` из `my.cnf` (MariaDB 11.8 предупреждает, что опция устарела).
- [ ] Остальные 4 стека деплоить только после слияния этого исправления.

## Блокеры

Нет.

## Для редеплоя этапа 2

- Плагины Fluent Boards/Community/Cart удалены из шаблона вместе с их константами хранилища. На существующих сайтах после удаления плагинов уберите константы из `wp-config.php`: `wp config list | grep FLUENT_` → `wp config delete <имя>` для `FLUENT_BOARDS_*`, `FLUENT_COMMUNITY_*`, `FLUENT_CART_*`.
- Первый старт после обновления выполнит один `find ... chown` по сайту; если контейнер долго «starting», это он.
