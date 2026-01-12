# Используем официальный образ WordPress с PHP 8.5-FPM
FROM wordpress:php8.5-fpm

# 🛠 Устанавливаем необходимые системные зависимости для сборки расширений
# (В официальном образе они уже есть, но на всякий случай — для надёжности)
RUN apt-get update && apt-get install -y \
    libpng-dev \
    libjpeg62-turbo-dev \
    libfreetype6-dev \
    libzip-dev \
    zip \
    unzip \
	ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# 🚀 Устанавливаем расширения PDO и pdo_mysql
# Эти команды компилируют расширения прямо в PHP (если они отсутствуют)
RUN docker-php-ext-install -j$(nproc) pdo pdo_mysql

# 🧩 Устанавливаем расширение zip (часто нужно для WordPress)
RUN docker-php-ext-install -j$(nproc) zip

# 📌 Опционально: устанавливаем mysqli (если нужно, хотя pdo_mysql уже покрывает MySQL)
# RUN docker-php-ext-install -j$(nproc) mysqli

# 📌 Опционально: если нужно pdo_sqlite (не обязательно для WordPress)
# RUN docker-php-ext-install -j$(nproc) pdo_sqlite

# 🧹 Очистка кэша (опционально, для уменьшения размера образа)
RUN apt-get clean && rm -rf /var/lib/apt/lists/*

# 🚀 Устанавливаем утилиту WP-CLI
RUN curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    && chmod +x wp-cli.phar \
    && mv wp-cli.phar /usr/local/bin/wp

# 🚀 Устанавливаем расширение Redis через PECL
RUN pecl install redis \
    && docker-php-ext-enable redis

# 📂 Копируем кастомные файлы (если есть)
# Например, кастомные плагины или темы
# COPY ./wp-content /var/www/html/wp-content

# ⚠️ НЕ НАДО добавлять:
#   extension=pdo.so
#   extension=pdo_mysql
# Это вызовет ошибки — расширения теперь встроены!
