#!/bin/bash

#
# WireGuard peer-to-peer installer
# Server 1: Ubuntu 24.04  — behind NAT, OpenVPN already configured
# Server 2: AlmaLinux 9.7 — public IP, OpenVPN already configured
#
# Трафик НЕ перенаправляется через WireGuard.
# Туннель используется только для связи между двумя серверами.
#
# Использование:
#   bash wireguard-p2p-install.sh
#
# Запускать от root или через sudo.
#

# ─────────────────────────────────────────────
# Базовые проверки
# ─────────────────────────────────────────────

if readlink /proc/$$/exe | grep -q "dash"; then
    echo 'Скрипт должен запускаться через bash, не sh.'
    exit 1
fi

# Сбрасываем stdin (нужно при запуске через pipe)
read -N 999999 -t 0.001

if [[ "$EUID" -ne 0 ]]; then
    echo "Скрипт должен запускаться с правами суперпользователя (sudo или root)."
    exit 1
fi

if ! grep -q sbin <<< "$PATH"; then
    echo 'В $PATH отсутствует sbin. Попробуйте "su -" вместо "su".'
    exit 1
fi

# ─────────────────────────────────────────────
# Определение ОС
# ─────────────────────────────────────────────

if grep -qs "ubuntu" /etc/os-release; then
    os="ubuntu"
    os_version=$(grep 'VERSION_ID' /etc/os-release | cut -d '"' -f 2 | tr -d '.')
elif [[ -e /etc/almalinux-release ]]; then
    os="almalinux"
    os_version=$(grep -oE '[0-9]+' /etc/almalinux-release | head -1)
else
    echo "Этот скрипт поддерживает только Ubuntu 22.04 и AlmaLinux 9."
    exit 1
fi

if [[ "$os" == "ubuntu" && "$os_version" -lt 2204 ]]; then
    echo "Требуется Ubuntu 22.04 или новее."
    exit 1
fi

if [[ "$os" == "almalinux" && "$os_version" -lt 9 ]]; then
    echo "Требуется AlmaLinux 9 или новее."
    exit 1
fi

os_pretty=$(grep PRETTY_NAME /etc/os-release | cut -d '"' -f 2)

# ─────────────────────────────────────────────
# Вспомогательные функции
# ─────────────────────────────────────────────

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()     { echo -e "${RED}[ERR ]${NC}  $*"; }

# Проверка наличия команды
need_cmd() {
    if ! command -v "$1" &>/dev/null; then
        err "Команда '$1' не найдена."
        exit 1
    fi
}

# Проверка что OpenVPN не перенаправляет весь трафик
check_openvpn_routes() {
    if ip route show | grep -q "0.0.0.0/1.*tun\|128.0.0.0/1.*tun"; then
        warn "Обнаружены маршруты OpenVPN перенаправляющие весь трафик (0.0.0.0/1, 128.0.0.0/1)."
        warn "Убедитесь что конфигурация OpenVPN не содержит 'redirect-gateway def1'."
        echo
        read -p "Продолжить несмотря на это? [y/N]: " force_continue
        [[ ! "$force_continue" =~ ^[yY]$ ]] && exit 1
    else
        ok "OpenVPN маршруты выглядят корректно — весь трафик не перенаправляется."
    fi
}

# Получить основной сетевой интерфейс (не lo, не tun, не wg)
get_main_iface() {
    ip route show default | grep -v tun | grep -v wg | awk '/default/{print $5}' | head -1
}

# Получить публичный IP
get_public_ip() {
    { wget -T 10 -t 1 -4qO- "https://api4.ipify.org" 2>/dev/null \
      || curl -m 10 -4Ls "https://api4.ipify.org" 2>/dev/null; } \
    | grep -oE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
}

# Проверка что IP в приватном диапазоне (сервер за NAT)
is_private_ip() {
    echo "$1" | grep -qE '^(10\.|172\.1[6789]\.|172\.2[0-9]\.|172\.3[01]\.|192\.168)'
}

# Установить watchdog-скрипт
install_watchdog() {
    local peer_pubkey="$1"
    local iface="wg0"
    local max_seconds=120

    cat > /usr/local/bin/wg-watchdog.sh << WATCHDOG
#!/bin/bash
# WireGuard watchdog — перезапускает туннель если handshake устарел
# Устанавливается cron-задачей каждые 2 минуты

PEER_PUBKEY="${peer_pubkey}"
IFACE="${iface}"
MAX_SECONDS=${max_seconds}
LOG_TAG="wg-watchdog"

if ! ip link show "\$IFACE" &>/dev/null; then
    logger -t "\$LOG_TAG" "Интерфейс \$IFACE не найден, пропускаем."
    exit 0
fi

LAST_HS=\$(wg show "\$IFACE" latest-handshakes 2>/dev/null \
    | grep "\$PEER_PUBKEY" | awk '{print \$2}')

if [[ -z "\$LAST_HS" || "\$LAST_HS" == "0" ]]; then
    logger -t "\$LOG_TAG" "Нет handshake с пиром, перезапуск \$IFACE..."
    wg-quick down "\$IFACE" 2>/dev/null
    sleep 2
    wg-quick up "\$IFACE"
    exit 0
fi

NOW=\$(date +%s)
DIFF=\$((NOW - LAST_HS))

if [[ "\$DIFF" -gt "\$MAX_SECONDS" ]]; then
    logger -t "\$LOG_TAG" "Handshake устарел на \${DIFF}с (порог: \${MAX_SECONDS}с), перезапуск..."
    wg-quick down "\$IFACE" 2>/dev/null
    sleep 2
    wg-quick up "\$IFACE"
    logger -t "\$LOG_TAG" "Перезапуск завершён."
else
    logger -t "\$LOG_TAG" "Туннель активен, последний handshake \${DIFF}с назад."
fi
WATCHDOG

    chmod +x /usr/local/bin/wg-watchdog.sh

    # Добавляем в cron если ещё нет
    if ! crontab -l 2>/dev/null | grep -q "wg-watchdog"; then
        { crontab -l 2>/dev/null; echo "*/2 * * * * /usr/local/bin/wg-watchdog.sh"; } | crontab -
        ok "Watchdog добавлен в crontab (каждые 2 минуты)."
    else
        ok "Watchdog уже есть в crontab."
    fi
}

# Удалить watchdog
remove_watchdog() {
    { crontab -l 2>/dev/null | grep -v "wg-watchdog"; } | crontab -
    rm -f /usr/local/bin/wg-watchdog.sh
    ok "Watchdog удалён."
}

# ─────────────────────────────────────────────
# Установка: Сервер 1 — Ubuntu за NAT
# ─────────────────────────────────────────────

install_server1_ubuntu() {
    clear
    echo "==========================================="
    echo " WireGuard: Сервер 1 (${os_pretty} / NAT)"
    echo "==========================================="
    echo

    check_openvpn_routes

    # Определяем основной интерфейс
    main_iface=$(get_main_iface)
    if [[ -z "$main_iface" ]]; then
        err "Не удалось определить основной сетевой интерфейс."
        exit 1
    fi
    info "Основной интерфейс: $main_iface"

    # Определяем локальный IP
    local_ip=$(ip -4 addr show "$main_iface" | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
    info "Локальный IP: $local_ip"

    if ! is_private_ip "$local_ip"; then
        warn "IP $local_ip выглядит публичным. Этот скрипт предназначен для сервера за NAT."
        read -p "Продолжить? [y/N]: " c
        [[ ! "$c" =~ ^[yY]$ ]] && exit 1
    fi

    # Запрашиваем WireGuard порт
    echo
    read -p "Порт WireGuard для прослушивания [51820]: " wg_port
    until [[ -z "$wg_port" || "$wg_port" =~ ^[0-9]+$ && "$wg_port" -le 65535 ]]; do
        echo "Неверный порт."
        read -p "Порт [51820]: " wg_port
    done
    [[ -z "$wg_port" ]] && wg_port="51820"

    # WireGuard адрес этого сервера
    echo
    read -p "WireGuard адрес этого сервера [10.10.0.1/24]: " wg_addr
    [[ -z "$wg_addr" ]] && wg_addr="10.10.0.1/24"

    # Публичный IP сервера 2 (AlmaLinux)
    echo
    echo "Введите публичный IP-адрес Сервера 2 (AlmaLinux):"
    read -p "IP Сервера 2: " peer_endpoint_ip
    until [[ "$peer_endpoint_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; do
        echo "Неверный IP-адрес."
        read -p "IP Сервера 2: " peer_endpoint_ip
    done

    read -p "Порт WireGuard на Сервере 2 [51820]: " peer_endpoint_port
    until [[ -z "$peer_endpoint_port" || "$peer_endpoint_port" =~ ^[0-9]+$ && "$peer_endpoint_port" -le 65535 ]]; do
        echo "Неверный порт."
        read -p "Порт [51820]: " peer_endpoint_port
    done
    [[ -z "$peer_endpoint_port" ]] && peer_endpoint_port="51820"

    # WireGuard адрес пира (Сервер 2)
    echo
    read -p "WireGuard адрес Сервера 2 (AllowedIPs) [10.10.0.2/32]: " peer_allowed_ip
    [[ -z "$peer_allowed_ip" ]] && peer_allowed_ip="10.10.0.2/32"

    # Значение keepalive
    echo
    read -p "PersistentKeepalive в секундах [20]: " keepalive
    until [[ -z "$keepalive" || "$keepalive" =~ ^[0-9]+$ ]]; do
        echo "Неверное значение."
        read -p "Keepalive [20]: " keepalive
    done
    [[ -z "$keepalive" ]] && keepalive="20"

    echo
    echo "-------------------------------------------"
    echo " Параметры установки:"
    echo "   Основной интерфейс : $main_iface"
    echo "   WireGuard адрес    : $wg_addr"
    echo "   ListenPort         : $wg_port"
    echo "   Endpoint Сервера 2 : $peer_endpoint_ip:$peer_endpoint_port"
    echo "   AllowedIPs пира    : $peer_allowed_ip"
    echo "   PersistentKeepalive: $keepalive"
    echo "-------------------------------------------"
    echo
    read -n1 -r -p "Нажмите любую клавишу для начала установки..."
    echo

    # Установка пакетов
    info "Устанавливаем wireguard-tools..."
    apt-get update -q
    apt-get install -y wireguard wireguard-tools

    # Создаём директорию и ключи
    mkdir -p /etc/wireguard
    chmod 700 /etc/wireguard

    info "Генерируем ключевую пару..."
    wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
    chmod 600 /etc/wireguard/private.key
    private_key=$(cat /etc/wireguard/private.key)
    public_key=$(cat /etc/wireguard/public.key)

    # Включаем ip_forward
    info "Включаем ip_forward..."
    echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-wireguard.conf
    sysctl --system -q

    # Создаём конфиг wg0
    # Пока без [Peer] — публичный ключ пира добавим отдельно
    cat > /etc/wireguard/wg0.conf << EOF
# WireGuard — Сервер 1 (Ubuntu, за NAT)
# Трафик НЕ перенаправляется через туннель.
# Только peer-to-peer связь с Сервером 2.
#
# ROLE server1_nat
# PEER_ENDPOINT ${peer_endpoint_ip}:${peer_endpoint_port}
# PEER_ALLOWED_IPS ${peer_allowed_ip}
# KEEPALIVE ${keepalive}
# MAIN_IFACE ${main_iface}

[Interface]
Address = ${wg_addr}
ListenPort = ${wg_port}
PrivateKey = ${private_key}

# Разрешаем форвардинг только между WireGuard-пирами
PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT

# BEGIN_PEER server2
# (публичный ключ будет добавлен на следующем шаге)
# END_PEER server2
EOF

    chmod 600 /etc/wireguard/wg0.conf

    # UFW: разрешаем порт (на всякий случай, даже при NAT)
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        info "Открываем порт $wg_port/udp в UFW..."
        ufw allow "$wg_port"/udp
    fi

    ok "Конфиг wg0 создан."
    echo
    echo "==========================================="
    echo " Шаг 2: Обмен ключами"
    echo "==========================================="
    echo
    echo "Ваш публичный ключ (Сервер 1):"
    echo
    echo -e "  ${GREEN}${public_key}${NC}"
    echo
    echo "Скопируйте этот ключ и передайте его на Сервер 2."
    echo "Затем запустите этот скрипт на Сервере 2 и получите его публичный ключ."
    echo
    read -p "Введите публичный ключ Сервера 2 (или Enter чтобы пропустить): " peer_pubkey

    if [[ -n "$peer_pubkey" ]]; then
        _add_peer_server1 "$peer_pubkey"
    else
        warn "Публичный ключ пира не введён."
        warn "Добавьте его позже, запустив скрипт снова и выбрав 'Добавить ключ пира'."
    fi

    # Запускаем и включаем автостарт
    info "Запускаем wg-quick@wg0..."
    systemctl enable --now wg-quick@wg0

    # Устанавливаем watchdog
    if [[ -n "$peer_pubkey" ]]; then
        info "Устанавливаем watchdog..."
        install_watchdog "$peer_pubkey"
    else
        warn "Watchdog будет установлен после добавления ключа пира."
    fi

    echo
    ok "Установка завершена!"
    echo
    echo "Проверка статуса туннеля: sudo wg show"
    echo "Проверка маршрутов:       ip route show"
    echo "Журнал watchdog:          journalctl -t wg-watchdog"
    echo
    _show_route_check_warning
}

# Добавить [Peer] в конфиг Сервера 1
_add_peer_server1() {
    local peer_pubkey="$1"

    # Читаем параметры из комментариев конфига
    local endpoint  allowed  keepalive
    endpoint=$(grep  '# PEER_ENDPOINT'     /etc/wireguard/wg0.conf | awk '{print $3}')
    allowed=$(grep   '# PEER_ALLOWED_IPS'  /etc/wireguard/wg0.conf | awk '{print $3}')
    keepalive=$(grep '# KEEPALIVE'         /etc/wireguard/wg0.conf | awk '{print $3}')

    # Заменяем placeholder [Peer] на реальный
    sed -i '/# BEGIN_PEER server2/,/# END_PEER server2/d' /etc/wireguard/wg0.conf

    cat >> /etc/wireguard/wg0.conf << EOF

# BEGIN_PEER server2
[Peer]
# Сервер 2 (AlmaLinux, публичный IP)
PublicKey = ${peer_pubkey}
AllowedIPs = ${allowed}
Endpoint = ${endpoint}
# Keepalive критически важен при NAT — удерживает маппинг открытым
PersistentKeepalive = ${keepalive}
# END_PEER server2
EOF

    ok "Ключ пира добавлен в /etc/wireguard/wg0.conf"

    # Применяем на лету если интерфейс уже поднят
    if ip link show wg0 &>/dev/null; then
        info "Применяем изменения к живому интерфейсу..."
        wg addconf wg0 <(sed -n '/# BEGIN_PEER server2/,/# END_PEER server2/p' /etc/wireguard/wg0.conf \
            | grep -v '^#')
        ok "Изменения применены без перезапуска."
    fi
}

# ─────────────────────────────────────────────
# Установка: Сервер 2 — AlmaLinux 9.7, публичный IP
# ─────────────────────────────────────────────

install_server2_almalinux() {
    clear
    echo "=============================================="
    echo " WireGuard: Сервер 2 (AlmaLinux 9 / публичный)"
    echo "=============================================="
    echo

    check_openvpn_routes

    # Определяем основной интерфейс
    main_iface=$(get_main_iface)
    if [[ -z "$main_iface" ]]; then
        err "Не удалось определить основной сетевой интерфейс."
        exit 1
    fi
    info "Основной интерфейс: $main_iface"

    # Определяем публичный IP
    detected_ip=$(get_public_ip)
    echo
    if [[ -n "$detected_ip" ]]; then
        read -p "Публичный IP этого сервера [$detected_ip]: " public_ip
        [[ -z "$public_ip" ]] && public_ip="$detected_ip"
    else
        read -p "Не удалось определить IP. Введите публичный IP этого сервера: " public_ip
        until [[ "$public_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; do
            echo "Неверный IP-адрес."
            read -p "Публичный IP: " public_ip
        done
    fi
    info "Публичный IP: $public_ip"

    # Порт
    echo
    read -p "Порт WireGuard [51820]: " wg_port
    until [[ -z "$wg_port" || "$wg_port" =~ ^[0-9]+$ && "$wg_port" -le 65535 ]]; do
        echo "Неверный порт."
        read -p "Порт [51820]: " wg_port
    done
    [[ -z "$wg_port" ]] && wg_port="51820"

    # WireGuard адрес этого сервера
    echo
    read -p "WireGuard адрес этого сервера [10.10.0.2/24]: " wg_addr
    [[ -z "$wg_addr" ]] && wg_addr="10.10.0.2/24"

    # AllowedIPs для Сервера 1
    echo
    read -p "WireGuard адрес Сервера 1 (AllowedIPs) [10.10.0.1/32]: " peer_allowed_ip
    [[ -z "$peer_allowed_ip" ]] && peer_allowed_ip="10.10.0.1/32"

    echo
    echo "-------------------------------------------"
    echo " Параметры установки:"
    echo "   Основной интерфейс : $main_iface"
    echo "   Публичный IP       : $public_ip"
    echo "   WireGuard адрес    : $wg_addr"
    echo "   ListenPort         : $wg_port"
    echo "   AllowedIPs пира    : $peer_allowed_ip"
    echo "   Endpoint пира      : не задаётся (авто-обнаружение)"
    echo "-------------------------------------------"
    echo
    read -n1 -r -p "Нажмите любую клавишу для начала установки..."
    echo

    # Установка пакетов
    info "Устанавливаем wireguard-tools..."
    dnf install -y epel-release
    dnf install -y wireguard-tools

    # Проверяем модуль ядра
    info "Проверяем модуль ядра WireGuard..."
    if ! modprobe wireguard 2>/dev/null; then
        warn "Модуль wireguard не загрузился. Пробуем установить kernel-modules-extra..."
        dnf install -y "kernel-modules-extra-$(uname -r)" 2>/dev/null || true
        modprobe wireguard || { err "Не удалось загрузить модуль wireguard."; exit 1; }
    fi

    # Добавляем в автозагрузку модуля
    echo "wireguard" > /etc/modules-load.d/wireguard.conf

    # Создаём директорию и ключи
    mkdir -p /etc/wireguard
    chmod 700 /etc/wireguard

    info "Генерируем ключевую пару..."
    wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
    chmod 600 /etc/wireguard/private.key
    private_key=$(cat /etc/wireguard/private.key)
    public_key=$(cat /etc/wireguard/public.key)

    # Включаем ip_forward
    info "Включаем ip_forward..."
    cat > /etc/sysctl.d/99-wireguard.conf << EOF
net.ipv4.ip_forward=1
EOF
    sysctl --system -q

    # Создаём конфиг wg0
    cat > /etc/wireguard/wg0.conf << EOF
# WireGuard — Сервер 2 (AlmaLinux, публичный IP)
# Трафик НЕ перенаправляется через туннель.
# Только peer-to-peer связь с Сервером 1.
#
# ROLE server2_public
# PUBLIC_IP ${public_ip}
# PEER_ALLOWED_IPS ${peer_allowed_ip}
# MAIN_IFACE ${main_iface}

[Interface]
Address = ${wg_addr}
ListenPort = ${wg_port}
PrivateKey = ${private_key}

# Разрешаем форвардинг только между WireGuard-пирами
PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT

# BEGIN_PEER server1
# (публичный ключ будет добавлен на следующем шаге)
# END_PEER server1
EOF

    chmod 600 /etc/wireguard/wg0.conf

    # Открываем порт в firewalld
    info "Открываем порт $wg_port/udp в firewalld..."
    if systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="${wg_port}/udp"
        firewall-cmd --permanent --zone=trusted --add-source="$(echo $peer_allowed_ip | cut -d/ -f1)/32" 2>/dev/null || true
        firewall-cmd --reload
        ok "Порт открыт в firewalld."
    else
        warn "firewalld не запущен. Открываем через iptables..."
        iptables -I INPUT -p udp --dport "$wg_port" -j ACCEPT
    fi

    ok "Конфиг wg0 создан."
    echo
    echo "==========================================="
    echo " Шаг 2: Обмен ключами"
    echo "==========================================="
    echo
    echo "Ваш публичный ключ (Сервер 2):"
    echo
    echo -e "  ${GREEN}${public_key}${NC}"
    echo
    echo "Передайте этот ключ на Сервер 1."
    echo
    read -p "Введите публичный ключ Сервера 1 (или Enter чтобы пропустить): " peer_pubkey

    if [[ -n "$peer_pubkey" ]]; then
        _add_peer_server2 "$peer_pubkey"
    else
        warn "Публичный ключ пира не введён."
        warn "Добавьте его позже, запустив скрипт снова и выбрав 'Добавить ключ пира'."
    fi

    # Запускаем и включаем автостарт
    info "Запускаем wg-quick@wg0..."
    systemctl enable --now wg-quick@wg0

    echo
    ok "Установка завершена!"
    echo
    echo "Проверка статуса туннеля: sudo wg show"
    echo "Проверка маршрутов:       ip route show"
    echo
    echo "Endpoint Сервера 1 будет автоматически определён"
    echo "как только он установит первое соединение."
    echo
    _show_route_check_warning
}

# Добавить [Peer] в конфиг Сервера 2
_add_peer_server2() {
    local peer_pubkey="$1"
    local allowed
    allowed=$(grep '# PEER_ALLOWED_IPS' /etc/wireguard/wg0.conf | awk '{print $3}')

    sed -i '/# BEGIN_PEER server1/,/# END_PEER server1/d' /etc/wireguard/wg0.conf

    cat >> /etc/wireguard/wg0.conf << EOF

# BEGIN_PEER server1
[Peer]
# Сервер 1 (Ubuntu, за NAT)
# Endpoint НЕ задаётся — WireGuard запомнит его автоматически
# когда Сервер 1 установит первое соединение.
PublicKey = ${peer_pubkey}
AllowedIPs = ${allowed}
# END_PEER server1
EOF

    ok "Ключ пира добавлен в /etc/wireguard/wg0.conf"

    if ip link show wg0 &>/dev/null; then
        info "Применяем изменения к живому интерфейсу..."
        wg addconf wg0 <(sed -n '/# BEGIN_PEER server1/,/# END_PEER server1/p' /etc/wireguard/wg0.conf \
            | grep -v '^#')
        ok "Изменения применены без перезапуска."
    fi
}

# Предупреждение о маршрутах
_show_route_check_warning() {
    echo "==========================================="
    echo " Важные проверки после установки"
    echo "==========================================="
    echo
    echo "1. Маршрут по умолчанию должен идти через основной интерфейс, НЕ wg0:"
    echo "   ip route get 8.8.8.8"
    echo "   → должно показать: via <ШЛЮЗ_ХОСТЕРА> dev eth0 (или аналог)"
    echo
    echo "2. OpenVPN маршруты должны остаться нетронутыми:"
    echo "   ip route show | grep tun0"
    echo
    echo "3. WireGuard добавляет только свою подсеть:"
    echo "   ip route show | grep wg0"
    echo "   → должен быть только маршрут 10.10.0.0/24 (или ваш диапазон)"
    echo
}

# ─────────────────────────────────────────────
# Меню управления (когда WireGuard уже установлен)
# ─────────────────────────────────────────────

management_menu() {
    clear
    echo "==========================================="
    echo " WireGuard уже установлен"
    echo "==========================================="
    echo
    echo "Статус туннеля:"
    echo
    wg show wg0 2>/dev/null || echo "  (интерфейс wg0 не поднят)"
    echo

    # Определяем роль
    role=$(grep '# ROLE' /etc/wireguard/wg0.conf 2>/dev/null | awk '{print $3}')
    echo "Роль сервера: ${role:-неизвестна}"
    echo
    echo "Выберите действие:"
    echo "  1) Показать статус и маршруты"
    echo "  2) Добавить / обновить ключ пира"
    echo "  3) Перезапустить WireGuard"
    echo "  4) Остановить WireGuard"
    echo "  5) Запустить WireGuard"
    echo "  6) Показать публичный ключ этого сервера"
    echo "  7) Удалить WireGuard (полностью)"
    echo "  8) Выход"
    echo
    read -p "Выбор: " option
    until [[ "$option" =~ ^[1-8]$ ]]; do
        echo "Неверный выбор."
        read -p "Выбор: " option
    done

    case "$option" in
    1)
        echo
        echo "── Статус WireGuard ─────────────────────"
        wg show
        echo
        echo "── Маршруты ─────────────────────────────"
        ip route show
        echo
        echo "── Маршрут до 8.8.8.8 ───────────────────"
        ip route get 8.8.8.8
        echo
        read -n1 -r -p "Нажмите любую клавишу..."
        management_menu
        ;;
    2)
        echo
        echo "Текущий публичный ключ этого сервера:"
        echo -e "  ${GREEN}$(cat /etc/wireguard/public.key)${NC}"
        echo
        read -p "Введите публичный ключ пира: " peer_pubkey
        if [[ -z "$peer_pubkey" ]]; then
            warn "Ключ не введён."
        else
            if [[ "$role" == "server1_nat" ]]; then
                _add_peer_server1 "$peer_pubkey"
                info "Обновляем watchdog с новым ключом..."
                install_watchdog "$peer_pubkey"
                systemctl restart wg-quick@wg0
            else
                _add_peer_server2 "$peer_pubkey"
                systemctl restart wg-quick@wg0
            fi
        fi
        read -n1 -r -p "Нажмите любую клавишу..."
        management_menu
        ;;
    3)
        systemctl restart wg-quick@wg0
        ok "WireGuard перезапущен."
        sleep 1
        management_menu
        ;;
    4)
        wg-quick down wg0
        ok "WireGuard остановлен."
        ;;
    5)
        wg-quick up wg0
        ok "WireGuard запущен."
        sleep 1
        management_menu
        ;;
    6)
        echo
        echo "Публичный ключ этого сервера:"
        echo
        echo -e "  ${GREEN}$(cat /etc/wireguard/public.key)${NC}"
        echo
        read -n1 -r -p "Нажмите любую клавишу..."
        management_menu
        ;;
    7)
        echo
        read -p "Вы уверены? Это удалит WireGuard и все конфиги. [y/N]: " confirm
        if [[ "$confirm" =~ ^[yY]$ ]]; then
            systemctl disable --now wg-quick@wg0 2>/dev/null
            remove_watchdog

            if [[ "$os" == "ubuntu" ]]; then
                apt-get remove --purge -y wireguard wireguard-tools 2>/dev/null
            elif [[ "$os" == "almalinux" ]]; then
                dnf remove -y wireguard-tools 2>/dev/null
            fi

            # Убираем firewall-правила
            if systemctl is-active --quiet firewalld; then
                local port
                port=$(grep ListenPort /etc/wireguard/wg0.conf 2>/dev/null | awk '{print $3}')
                [[ -n "$port" ]] && firewall-cmd --permanent --remove-port="${port}/udp" && firewall-cmd --reload
            fi

            rm -rf /etc/wireguard
            rm -f /etc/sysctl.d/99-wireguard.conf
            sysctl --system -q

            ok "WireGuard удалён."
        else
            echo "Отменено."
            sleep 1
            management_menu
        fi
        ;;
    8)
        exit 0
        ;;
    esac
}

# ─────────────────────────────────────────────
# Точка входа
# ─────────────────────────────────────────────

if [[ -e /etc/wireguard/wg0.conf ]]; then
    # WireGuard уже установлен — показываем меню управления
    management_menu
else
    # Первичная установка
    clear
    echo "==========================================="
    echo " WireGuard P2P Installer"
    echo " Peer-to-peer туннель без redirect-gateway"
    echo "==========================================="
    echo
    echo "Обнаружена ОС: $os"
    echo

    if [[ "$os" == "ubuntu" ]]; then
        echo "Ubuntu обнаружена — предполагается роль Сервера 1 (за NAT)."
        echo
        read -p "Это Сервер 1 (Ubuntu, за NAT)? [Y/n]: " confirm
        if [[ -z "$confirm" || "$confirm" =~ ^[yY]$ ]]; then
            install_server1_ubuntu
        else
            echo "Для установки на AlmaLinux запустите скрипт на том сервере."
            exit 0
        fi

    elif [[ "$os" == "almalinux" ]]; then
        echo "AlmaLinux обнаружена — предполагается роль Сервера 2 (публичный IP)."
        echo
        read -p "Это Сервер 2 (AlmaLinux, публичный IP)? [Y/n]: " confirm
        if [[ -z "$confirm" || "$confirm" =~ ^[yY]$ ]]; then
            install_server2_almalinux
        else
            echo "Для установки на Ubuntu запустите скрипт на том сервере."
            exit 0
        fi
    fi
fi