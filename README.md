# 🚀 WordPress High-Performance Docker Stack (Coolify)

Стек для WordPress под **Coolify**: PHP 8.3-FPM, nginx с FastCGI-кэшем и Brotli, Redis (объектный кэш), MariaDB 11 и отдельный контейнер для WP-Cron. Рассчитан на сервер, где крутится **несколько сайтов** (по одному стеку на сайт): потребление памяти ограничено и настраивается переменными окружения.

План дальнейших работ и состояние выполнения — в [`TODO.md`](TODO.md).

---

## 📂 Структура репозитория

| Файл | Назначение |
| --- | --- |
| `docker-compose.yaml` | Сервисы `wordpress`, `wp-cron`, `nginx`, `mariadb`, `wp_redis`; healthcheck'и, лимиты памяти, профили через переменные окружения |
| `Dockerfile` | PHP-образ: `pdo_mysql`, `bz2`, `igbinary`, `phpredis` (с igbinary/lz4/zstd), WP-CLI с проверкой sha512 |
| `nginx/nginx.conf` | Сайт: FastCGI-кэш, реальный IP, лимит на `wp-login.php`, правила CompressX (AVIF/WebP), sitemap SEOPress, сжатие |
| `nginx/php-fastcgi.inc` | Общая часть `location` для PHP (обычные `.php` и `/wp-admin/`) |
| `nginx/security-headers.inc` | Заголовки безопасности (подключаются из каждого `location`) |
| `php/wp-php.ini` | Настройки PHP и OPcache; `memory_limit` и размер OPcache берутся из окружения |
| `php-fpm-tuning.conf` | Пул PHP-FPM: `ondemand`, Unix-сокет, slowlog, `/ping` для healthcheck |
| `my.cnf` | MariaDB: InnoDB, кодировка, slow log |
| `init-script.sh` | Автонастройка `wp-config.php`, установка плагинов при первом запуске, S3-Uploads, права, Nginx Helper |
| `create-readonly-user.sh` | Создаёт `monitor_user` (только `SELECT`), если задан `READONLY_DB_PASSWORD` |
| `setup.sh` | Первичная настройка чистого VPS (Docker, swap, sysctl, UFW, SSH, Fail2Ban, автообновления) |
| `scripts/pma-connect.sh` | Подключает phpMyAdmin к сетям всех стеков, чтобы открывать базы всех сайтов |

---

## ⚡ Подготовка сервера

Запускается один раз от root на хосте:

```bash
chmod +x setup.sh && ./setup.sh
```

Скрипт: обновляет систему и включает `unattended-upgrades` (только security, без авто-перезагрузки); создаёт swap 2 ГБ; выставляет `vm.overcommit_memory=1` (Redis) и `vm.swappiness=10`; генерирует SSH-ключ (Ed25519, показывается один раз — **сохраните**); настраивает UFW (22, 80, 443, 443/udp); ставит Docker; запрещает вход по паролю; ставит Fail2Ban.

> ⚠️ UFW **не защищает** порты, которые Docker публикует через `ports:` — Docker правит iptables в обход UFW. Не публикуйте БД и Redis наружу.

---

## 🧠 Ресурсы и профили

Один стек = один сайт. Все значения ниже задаются переменными окружения в Coolify; по умолчанию — профиль «обычный». Нагруженному сайту переопределите нужные переменные.

| Переменная | Обычный (по умолчанию) | Нагруженный | Что делает |
| --- | --- | --- | --- |
| `PHP_FPM_MAX_CHILDREN` | 5 | 8 | Потолок воркеров PHP-FPM (`pm = ondemand`: в простое воркеров нет) |
| `PHP_MEMORY_LIMIT` | 256M | 256M | `memory_limit` PHP |
| `WP_MEMORY_LIMIT` | 256M | 256M | Пишется в `wp-config.php` при каждом старте. Не держите выше `PHP_MEMORY_LIMIT`: иначе WordPress сам поднимет лимит для всех запросов |
| `WP_MAX_MEMORY_LIMIT` | 512M | 512M | Потолок только для админки (Elementor, импорт, обновления) |
| `OPCACHE_MEMORY` | 128 | 192 | МБ под OPcache (JIT выключен) |
| `WORDPRESS_MEM_LIMIT` | 768m | 1280m | Потолок памяти контейнера wordpress |
| `INNODB_BUFFER_POOL_SIZE` | 192M | 512M | Ориентир — размер данных БД × 1.3 |
| `DB_MAX_CONNECTIONS` | 60 | 80 | |
| `DB_MEM_LIMIT` | 512m | 1g | |
| `REDIS_MAXMEMORY` / `REDIS_MEM_LIMIT` | 64mb / 128m | 128mb / 192m | Redis — чистый кэш, на диск не пишет |
| `CRON_MEM_LIMIT` | 256m | 256m | |

nginx: 192 МБ (внутри — 128 МБ tmpfs под FastCGI-кэш, он считается в память контейнера).

Потолок сайта ≈ 1.8 ГБ (обычный) / 2.9 ГБ (нагруженный); типичное потребление — около 0.6 / 1.2 ГБ. Расчёт бюджета сервера на 12 ГБ — в `TODO.md`.

---

## 🔧 Остальные переменные окружения

| Переменная | Описание |
| --- | --- |
| `SERVICE_FQDN_WORDPRESS` | Домен сайта (Coolify) |
| `SERVICE_USER_WORDPRESS`, `SERVICE_PASSWORD_WORDPRESS` | Пользователь и пароль БД WordPress |
| `SERVICE_PASSWORD_ROOT` | Root-пароль MariaDB |
| `READONLY_DB_PASSWORD` | (опц.) пароль read-only пользователя `monitor_user`; пользователь создаётся только при первой инициализации БД |
| `WP_DEBUG`, `WP_DEBUG_LOG`, `WP_DEBUG_DISPLAY` | Отладка (по умолчанию `false`) |

---

## 🚀 Порядок установки и обновления

1. Подготовить сервер (`setup.sh`).
2. В Coolify создать стек из репозитория, задать переменные окружения.
3. Деплой. При первом запуске `init-script.sh` дождётся `wp-config.php`, скачает плагины и настроит Redis/S3-шаблоны; затем откройте сайт и завершите установку WordPress. Плагины `nginx-helper` и `redis-cache` активируются при следующем рестарте.
4. **Обновление шаблона:** изменения из репозитория применяются к стеку только после его редеплоя. Раскатывайте сначала на одном сайте, через сутки на остальные. Редеплоить `wordpress` и `nginx` нужно вместе (общий сокет PHP-FPM).
5. После редеплоя phpMyAdmin или любого WP-стека запустите `./scripts/pma-connect.sh`.

---

## 🔎 Как проверить, что всё работает

```bash
# Расход памяти по контейнерам и свободная память хоста (swap не должен расти)
docker stats --no-stream; free -h

# Кэш nginx: второй запрос должен дать HIT; ?s=x — BYPASS; залогиненный — BYPASS
curl -sI https://сайт/ | grep -i x-fastcgi-cache

# PHP-расширения и объектный кэш
docker exec <wordpress> php --ri redis | grep -iE 'igbinary|lz4'
docker exec <wordpress> wp redis status --allow-root

# Медленные страницы PHP (>10 с): лог контейнера wordpress; медленные запросы БД: mariadb-data/slow.log
docker logs --tail 100 <wordpress>
```

---

## 🛡 Что настроено в nginx

* **FastCGI-кэш** (tmpfs 128 МБ, TTL 12 ч; страницы чистит плагин Nginx Helper): не кэшируются POST, админка, REST, залогиненные пользователи и корзина; параметры UTM кэшируются. `cache_lock` и `background_update` защищают от лавины запросов при истечении кэша.
* **Реальный IP клиента** из `X-Forwarded-For` для приватных сетей Docker/Traefik.
* **Лимит** 10 POST/мин на `wp-login.php`; `xmlrpc.php` закрыт.
* **Тайм-ауты:** фронт 60 с, `/wp-admin/` 300 с (бэкапы, импорт).
* **Сжатие:** Gzip и Brotli; **CompressX:** отдача `.avif`/`.webp` по заголовку `Accept`.
* **Логи** идут в stdout/stderr (ротация Docker: 10 МБ × 3).
* HSTS и HTTP/3 настраиваются в Traefik (Coolify), не здесь.
