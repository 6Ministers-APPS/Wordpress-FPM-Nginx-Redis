# Используем официальный образ WordPress с PHP 8.3-FPM
# (gd, zip, exif, mysqli, intl, opcache в нём уже есть)
FROM wordpress:php8.3-fpm

# Версии фиксируем, чтобы сборка была воспроизводимой
ARG IGBINARY_VERSION=3.2.16
ARG PHPREDIS_VERSION=6.2.0
ARG WP_CLI_VERSION=2.12.0
ARG WP_CLI_SHA512=be928f6b8ca1e8dfb9d2f4b75a13aa4aee0896f8a9a0a1c45cd5d2c98605e6172e6d014dda2e27f88c98befc16c040cbb2bd1bfa121510ea5cdf5f6a30fe8832

# 🛠 Системные пакеты:
#   libbz2-dev           — для сборки bz2
#   liblz4-dev, libzstd-dev — сжатие в phpredis (WP_REDIS_COMPRESSION)
#   libfcgi-bin          — cgi-fcgi для healthcheck php-fpm
#   ffmpeg, unzip, wget  — нужны плагинам и init-script.sh
RUN apt-get update && apt-get install -y --no-install-recommends \
    libbz2-dev \
    liblz4-dev \
    libzstd-dev \
    libfcgi-bin \
    ffmpeg \
    zip \
    unzip \
    bzip2 \
    wget \
    && rm -rf /var/lib/apt/lists/*

# 🚀 PHP-расширения, которых нет в базовом образе
RUN docker-php-ext-install -j$(nproc) pdo_mysql bz2

# 🚀 igbinary + phpredis с поддержкой igbinary/lz4/zstd.
# Без этих флагов WP_REDIS_SERIALIZER=igbinary и WP_REDIS_COMPRESSION=lz4
# из init-script.sh не работают.
RUN pecl install igbinary-${IGBINARY_VERSION} \
    && docker-php-ext-enable igbinary \
    && pecl install -D 'enable-redis-igbinary="yes" enable-redis-lzf="no" enable-redis-zstd="yes" enable-redis-msgpack="no" enable-redis-lz4="yes" with-liblz4="yes"' redis-${PHPREDIS_VERSION} \
    && docker-php-ext-enable redis \
    && rm -rf /tmp/pear \
    && php -r 'exit(defined("Redis::SERIALIZER_IGBINARY") && defined("Redis::COMPRESSION_LZ4") ? 0 : 1);'

# 🚀 WP-CLI (фиксированная версия с проверкой контрольной суммы)
RUN curl -fsSL -o /usr/local/bin/wp \
      "https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar" \
    && echo "${WP_CLI_SHA512}  /usr/local/bin/wp" | sha512sum -c - \
    && chmod +x /usr/local/bin/wp

# 📂 Копируем кастомные файлы (если есть)
# COPY ./wp-content /var/www/html/wp-content

# ⚠️ НЕ НАДО добавлять extension=pdo.so / extension=pdo_mysql в ini —
# расширения включаются через docker-php-ext-*, повторное подключение даст ошибку.
