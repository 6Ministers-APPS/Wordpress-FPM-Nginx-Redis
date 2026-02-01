#!/bin/bash

# --- НАСТРОЙКИ ---
# Работаем только от root
if [[ $EUID -ne 0 ]]; then
   echo "Этот скрипт должен быть запущен от имени root" 
   exit 1
fi

set -e

# --- ЦВЕТА ---
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

ask_yes_no() {
    local prompt="$1"
    while true; do
        read -p "$prompt (y/n): " INPUT < /dev/tty
        case "$INPUT" in
            [yY]|[yY][eE][sS]) CONFIRM="y"; return 0 ;;
            [nN]|[nN][oO]) CONFIRM="n"; return 1 ;;
            *) echo -e "${YELLOW}Введите 'y' или 'n'.${NC}" ;;
        esac
    done
}

# --- 1. ОБНОВЛЕНИЕ ---
update_system() {
    info "Обновление пакетов..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get -qqy update
    apt-get -qqy -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
    apt-get -y autoremove
    # Установка утилиты для конвертации ключей
    apt-get install -y putty-tools
    info "Система обновлена."
}

# --- 2. НАСТРОЙКА SWAP (Новая функция) ---
configure_swap() {
    info "--- ПРОВЕРКА SWAP ---"
    
    # Проверяем, включен ли swap
    if swapon --show | grep -q "partition\|file"; then
        info "Swap уже активен. Пропуск создания."
    elif [ -f /swapfile ]; then
        warn "Файл /swapfile существует, но не активен. Пропуск во избежание конфликтов."
    else
        info "Создание Swap-файла размером 2GB..."
        fallocate -l 2G /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        
        # Добавляем в fstab для автозагрузки, если там еще нет записи
        if ! grep -q "/swapfile" /etc/fstab; then
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
            info "Swap добавлен в автозагрузку."
        fi
        
        info "✅ Swap (2GB) успешно создан и подключен."
    fi
}

# --- 3. НАСТРОЙКА ЯДРА (MEMORY OVERCOMMIT) ---
# 👇 ВАША НОВАЯ НАСТРОЙКА ДОБАВЛЕНА СЮДА
tune_kernel() {
    info "Настройка параметров ядра (Redis Fix)..."
    
    # 1. Применяем настройку прямо сейчас
    sysctl -w vm.overcommit_memory=1
    
    # 2. Проверяем, записана ли она в конфиг, если нет — записываем (для автозагрузки)
    if ! grep -q "vm.overcommit_memory = 1" /etc/sysctl.conf; then
        echo "vm.overcommit_memory = 1" >> /etc/sysctl.conf
        info "➕ Добавлено vm.overcommit_memory = 1 в /etc/sysctl.conf"
    else
        info "👌 Настройка уже есть в конфиге."
    fi
    
    info "✅ Параметры ядра настроены."
}


# --- 4. ГЕНЕРАЦИЯ КЛЮЧЕЙ ---
generate_keys() {
    info "--- ГЕНЕРАЦИЯ КЛЮЧЕЙ ---"
    
    KEY_PATH="/root/coolify_root_key"
    
    rm -f "${KEY_PATH}" "${KEY_PATH}.pub" "${KEY_PATH}.ppk"

    info "Генерация Ed25519 ключа..."
    ssh-keygen -t ed25519 -C "root-coolify-access" -f "$KEY_PATH" -N "" -q
    
    info "Конвертация в PPK (для PuTTY)..."
    puttygen "$KEY_PATH" -o "${KEY_PATH}.ppk" -O private

    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    
    if ! grep -qf "${KEY_PATH}.pub" /root/.ssh/authorized_keys 2>/dev/null; then
        cat "${KEY_PATH}.pub" >> /root/.ssh/authorized_keys
        info "Ключ добавлен в authorized_keys."
    fi
    chmod 600 /root/.ssh/authorized_keys
    
    PRIVATE_KEY_OPENSSH=$(cat "$KEY_PATH")
    PRIVATE_KEY_PPK=$(cat "${KEY_PATH}.ppk")
    
    # Удаляем ключи с диска
    rm -f "$KEY_PATH" "${KEY_PATH}.ppk" "${KEY_PATH}.pub"
}

# --- 5. ФАЕРВОЛ ---
setup_firewall() {
    info "--- НАСТРОЙКА UFW ---"
    
    if ! command -v ufw &> /dev/null; then
        apt-get install -y ufw
    fi

    ufw --force reset > /dev/null
    ufw default deny incoming
    ufw default allow outgoing

    ufw allow 22/tcp comment 'SSH'
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    ufw allow 443/udp comment 'HTTP/3'

    echo "y" | ufw enable
    info "✅ Порты 22, 80, 443 открыты."
}

# --- 6. SSH HARDENING (ROOT) ---
harden_ssh() {
    info "--- НАСТРОЙКА SSH ---"
    warn "ВНИМАНИЕ: Парольный вход будет отключен!"
    
    SSHD_CONFIG="/etc/ssh/sshd_config"
    cp $SSHD_CONFIG "${SSHD_CONFIG}.bak"

    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSHD_CONFIG"
    sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' "$SSHD_CONFIG"
    sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' "$SSHD_CONFIG"
    sed -i 's/^#\?ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' "$SSHD_CONFIG"
    sed -i 's/^#\?UsePAM .*/UsePAM no/' "$SSHD_CONFIG"

    systemctl restart ssh
    info "✅ SSH настроен: Root разрешен (только ключи), пароли отключены."
}

# --- 7. DOCKER ---
install_docker() {
    info "--- УСТАНОВКА DOCKER ---"
    if ! command -v docker &> /dev/null; then
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        rm get-docker.sh
        info "Docker установлен."
    else
        info "Docker уже установлен."
    fi
}

# --- 8. FAIL2BAN ---
install_fail2ban() {
    info "--- FAIL2BAN ---"
    apt-get install -y fail2ban
    cat <<EOF > /etc/fail2ban/jail.local
[sshd]
enabled = true
port    = ssh
filter  = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
EOF
    systemctl restart fail2ban
    systemctl enable fail2ban
    info "✅ Fail2Ban активен."
}

# --- ЗАПУСК ---
ask_yes_no "Начать настройку сервера (Root, Keys, UFW, Swap, Docker)?"
if [[ "$CONFIRM" == "n" ]]; then exit 0; fi

update_system
configure_swap
tune_kernel    
generate_keys
setup_firewall
install_docker
harden_ssh
install_fail2ban

# --- ОТЧЕТ ---
clear
echo ""
echo -e "${GREEN}==========================================================${NC}"
echo -e "${GREEN}   НАСТРОЙКА ЗАВЕРШЕНА УСПЕШНО${NC}"
echo -e "${GREEN}==========================================================${NC}"
echo ""
echo "IP сервера: $(curl -s4 https://ifconfig.me)"
echo "Пользователь: root"
echo "Порт SSH: 22"
echo "Swap: Активен (2GB)"
echo ""
echo -e "${YELLOW}!!! СКОПИРУЙТЕ КЛЮЧИ ПРЯМО СЕЙЧАС !!!${NC}"
echo "Ключи удалены с диска. Если вы закроете окно без сохранения,"
echo "доступ к серверу будет потерян навсегда."
echo ""
echo "----------------------------------------------------------"
echo "PRIVATE KEY (OpenSSH) - Для Coolify / Linux / Mac:"
echo "----------------------------------------------------------"
echo "$PRIVATE_KEY_OPENSSH"
echo ""
echo "----------------------------------------------------------"
echo "PRIVATE KEY (PuTTY .ppk) - Для Windows:"
echo "----------------------------------------------------------"
echo "$PRIVATE_KEY_PPK"
echo "----------------------------------------------------------"
echo ""