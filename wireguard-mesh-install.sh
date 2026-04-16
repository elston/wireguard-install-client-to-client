#!/bin/bash

#
# WireGuard Full-Mesh Installer — 3 узла
# ────────────────────────────────────────────────────────────────
#  Server 1 · Ubuntu 22.04+   · за NAT     · 10.10.0.1
#  Server 2 · AlmaLinux 9     · публичный  · 10.10.0.2  (relay)
#  Server 3 · CentOS Stream 8 · за NAT     · 10.10.0.3
# ────────────────────────────────────────────────────────────────
#  Трафик НЕ перенаправляется через туннель (нет redirect-gateway).
#  Server1 ↔ Server3 идёт через Server2 как relay.
#  Server1 и Server3 → Server2 напрямую (keepalive через NAT).
#
#  Использование: sudo bash wireguard-mesh-install.sh
#

# ── Базовые проверки ────────────────────────────────────────────

if readlink /proc/$$/exe | grep -q "dash"; then
    echo 'Запускайте через bash, не sh.'
    exit 1
fi
read -N 999999 -t 0.001   # сброс stdin при запуске через pipe

if [[ "$EUID" -ne 0 ]]; then
    echo "Требуются права root (sudo)."
    exit 1
fi

if ! grep -q sbin <<< "$PATH"; then
    echo '$PATH не содержит sbin. Используйте "su -" вместо "su".'
    exit 1
fi

# ── Определение ОС ──────────────────────────────────────────────

os_pretty=$(grep PRETTY_NAME /etc/os-release | cut -d '"' -f 2)

if grep -qs "ubuntu" /etc/os-release; then
    os="ubuntu"
    os_version=$(grep VERSION_ID /etc/os-release | cut -d '"' -f 2 | tr -d '.')
elif [[ -e /etc/almalinux-release ]]; then
    os="almalinux"
    os_version=$(grep -oE '[0-9]+' /etc/almalinux-release | head -1)
elif [[ -e /etc/centos-release ]]; then
    os="centos"
    os_version=$(grep -oE '[0-9]+' /etc/centos-release | head -1)
else
    echo "Неподдерживаемый дистрибутив. Поддерживаются: Ubuntu 22.04+, AlmaLinux 9, CentOS Stream 8."
    exit 1
fi

if [[ "$os" == "ubuntu" && "$os_version" -lt 2204 ]]; then
    echo "Требуется Ubuntu 22.04 или новее."; exit 1
fi
if [[ "$os" == "almalinux" && "$os_version" -lt 9 ]]; then
    echo "Требуется AlmaLinux 9 или новее."; exit 1
fi
if [[ "$os" == "centos" && "$os_version" -lt 8 ]]; then
    echo "Требуется CentOS Stream 8 или новее."; exit 1
fi

# ── Цвета и вывод ───────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERR ]${NC}  $*"; }

banner() {
    echo
    echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  $*${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
    echo
}

# ── Вспомогательные функции ─────────────────────────────────────

get_main_iface() {
    ip route show default | grep -v tun | grep -v wg | awk '/default/{print $5}' | head -1
}

get_public_ip() {
    { wget -T 10 -t 1 -4qO- "https://api4.ipify.org" 2>/dev/null \
      || curl -m 10 -4Ls "https://api4.ipify.org" 2>/dev/null; } \
    | grep -oE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
}

is_private_ip() {
    echo "$1" | grep -qE '^(10\.|172\.1[6789]\.|172\.2[0-9]\.|172\.3[01]\.|192\.168)'
}

# Проверка что OpenVPN не перехватывает весь трафик
check_openvpn_routes() {
    if ip route show 2>/dev/null | grep -q "0.0.0.0/1.*tun\|128.0.0.0/1.*tun"; then
        warn "Обнаружены маршруты OpenVPN перенаправляющие весь трафик."
        warn "Убедитесь что в конфиге OpenVPN нет 'redirect-gateway def1'."
        echo
        read -p "Продолжить? [y/N]: " fc
        [[ ! "$fc" =~ ^[yY]$ ]] && exit 1
    else
        ok "Маршруты OpenVPN корректны — весь трафик не перенаправляется."
    fi
}

# Генерация ключей
generate_keys() {
    mkdir -p /etc/wireguard
    chmod 700 /etc/wireguard
    wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
    chmod 600 /etc/wireguard/private.key
    ok "Ключи сгенерированы."
}

# Включение ip_forward
enable_ip_forward() {
    echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-wireguard.conf
    sysctl --system -q
    ok "ip_forward включён."
}

# ── Установка WireGuard под разные ОС ───────────────────────────

install_wireguard_packages() {
    case "$os" in
    ubuntu)
        info "Устанавливаем wireguard (Ubuntu)..."
        apt-get update -q
        apt-get install -y wireguard wireguard-tools
        ;;
    almalinux)
        info "Устанавливаем wireguard (AlmaLinux)..."
        dnf install -y epel-release
        dnf install -y wireguard-tools
        _load_wireguard_module
        ;;
    centos)
        info "Устанавливаем wireguard (CentOS Stream 8)..."
        # CentOS Stream 8 достиг EOL — проверяем и при необходимости
        # переключаем на vault-репозитории
        _fix_centos8_repos
        dnf install -y epel-release
        # ELRepo нужен для kmod-wireguard (ядро 4.18 не содержит модуль)
        dnf install -y https://www.elrepo.org/elrepo-release-8.el8.elrepo.noarch.rpm 2>/dev/null || \
        dnf install -y elrepo-release 2>/dev/null || true
        dnf --enablerepo=elrepo install -y kmod-wireguard wireguard-tools
        _load_wireguard_module
        ;;
    esac
}

_load_wireguard_module() {
    info "Загружаем модуль ядра wireguard..."
    if ! modprobe wireguard 2>/dev/null; then
        warn "Модуль не загрузился автоматически."
        if [[ "$os" == "centos" ]]; then
            warn "Пробуем установить kernel-devel для текущего ядра..."
            dnf install -y "kernel-devel-$(uname -r)" 2>/dev/null || \
            dnf install -y kernel-devel 2>/dev/null || true
            depmod -a
            modprobe wireguard || { err "Не удалось загрузить модуль wireguard. Возможно требуется перезагрузка."; exit 1; }
        fi
    fi
    # Добавляем в автозагрузку
    echo "wireguard" > /etc/modules-load.d/wireguard.conf
    ok "Модуль wireguard загружен."
}

_fix_centos8_repos() {
    # CentOS Stream 8 EOL — репозитории перемещены на vault
    if ! dnf repolist 2>/dev/null | grep -q "baseos"; then
        warn "Репозитории CentOS Stream 8 недоступны, переключаемся на vault..."
        sed -i 's|mirrorlist=|#mirrorlist=|g' /etc/yum.repos.d/CentOS-*.repo 2>/dev/null
        sed -i 's|#baseurl=http://mirror.centos.org|baseurl=https://vault.centos.org|g' \
            /etc/yum.repos.d/CentOS-*.repo 2>/dev/null
        ok "Репозитории переключены на vault.centos.org"
    fi
}

# ── Открытие порта в firewall ────────────────────────────────────

open_firewall_port() {
    local port="$1"
    case "$os" in
    ubuntu)
        if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
            ufw allow "$port"/udp
            ok "UFW: порт $port/udp открыт."
        else
            info "UFW не активен, пропускаем."
        fi
        ;;
    almalinux|centos)
        if systemctl is-active --quiet firewalld; then
            firewall-cmd --permanent --add-port="${port}/udp"
            firewall-cmd --reload
            ok "firewalld: порт $port/udp открыт."
        else
            iptables -I INPUT -p udp --dport "$port" -j ACCEPT
            warn "firewalld не запущен, добавлено правило iptables (не сохранится после ребута)."
        fi
        ;;
    esac
}

# ── Watchdog ────────────────────────────────────────────────────

install_watchdog() {
    # Принимает список публичных ключей всех пиров через пробел
    local peer_keys="$1"

    cat > /usr/local/bin/wg-watchdog.sh << WATCHDOG
#!/bin/bash
# WireGuard watchdog — перезапускает туннель если handshake устарел
IFACE="wg0"
MAX_SECONDS=120
LOG_TAG="wg-watchdog"

if ! ip link show "\$IFACE" &>/dev/null; then
    logger -t "\$LOG_TAG" "Интерфейс \$IFACE не найден."
    exit 0
fi

PEER_KEYS="${peer_keys}"
STALE=0

for PKEY in \$PEER_KEYS; do
    LAST_HS=\$(wg show "\$IFACE" latest-handshakes 2>/dev/null | grep "\$PKEY" | awk '{print \$2}')
    [[ -z "\$LAST_HS" || "\$LAST_HS" == "0" ]] && { STALE=1; break; }
    NOW=\$(date +%s)
    DIFF=\$((NOW - LAST_HS))
    if [[ "\$DIFF" -gt "\$MAX_SECONDS" ]]; then
        logger -t "\$LOG_TAG" "Handshake с пиром устарел на \${DIFF}с, перезапуск..."
        STALE=1
        break
    fi
done

if [[ "\$STALE" -eq 1 ]]; then
    wg-quick down "\$IFACE" 2>/dev/null
    sleep 2
    wg-quick up "\$IFACE"
    logger -t "\$LOG_TAG" "Перезапуск завершён."
fi
WATCHDOG

    chmod +x /usr/local/bin/wg-watchdog.sh

    if ! crontab -l 2>/dev/null | grep -q "wg-watchdog"; then
        { crontab -l 2>/dev/null; echo "*/2 * * * * /usr/local/bin/wg-watchdog.sh"; } | crontab -
        ok "Watchdog установлен (cron, каждые 2 мин)."
    else
        ok "Watchdog уже есть в crontab."
    fi
}

remove_watchdog() {
    { crontab -l 2>/dev/null | grep -v "wg-watchdog"; } | crontab -
    rm -f /usr/local/bin/wg-watchdog.sh
    ok "Watchdog удалён."
}

# ── Диалог: запрос публичного ключа пира ────────────────────────

ask_peer_key() {
    local peer_name="$1"
    local varname="$2"
    echo
    echo "  Введите публичный ключ ${peer_name} (или Enter — добавить позже):"
    read -p "  Ключ: " key_input
    eval "$varname='$key_input'"
}

show_own_key() {
    echo
    echo -e "  Ваш публичный ключ (скопируйте и передайте на другие серверы):"
    echo
    echo -e "  ${GREEN}$(cat /etc/wireguard/public.key)${NC}"
    echo
}

# ════════════════════════════════════════════════════════════════
#  УСТАНОВКА: SERVER 1 — Ubuntu, за NAT, 10.10.0.1
#  Единственный пир: Server 2 (relay)
#  AllowedIPs включает и 10.10.0.3 — трафик до Server3 идёт через Server2
# ════════════════════════════════════════════════════════════════

install_server1() {
    banner "Server 1 · ${os_pretty} · NAT · 10.10.0.1"
    check_openvpn_routes

    local main_iface; main_iface=$(get_main_iface)
    [[ -z "$main_iface" ]] && { err "Не найден основной сетевой интерфейс."; exit 1; }
    info "Основной интерфейс: $main_iface"

    echo
    read -p "WireGuard порт [51820]: " wg_port
    [[ -z "$wg_port" ]] && wg_port="51820"

    read -p "WireGuard адрес этого сервера [10.10.0.1/24]: " wg_addr
    [[ -z "$wg_addr" ]] && wg_addr="10.10.0.1/24"

    echo
    echo "Введите публичный IP Сервера 2 (AlmaLinux):"
    read -p "IP Server 2: " s2_ip
    until [[ "$s2_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; do
        read -p "Неверный IP. Повторите: " s2_ip
    done

    read -p "Порт WireGuard на Server 2 [51820]: " s2_port
    [[ -z "$s2_port" ]] && s2_port="51820"

    read -p "Keepalive в секундах [20]: " keepalive
    [[ -z "$keepalive" ]] && keepalive="20"

    echo
    echo "  ┌─────────────────────────────────────────┐"
    echo "  │ Параметры установки                     │"
    echo "  │  Интерфейс : $main_iface                 "
    echo "  │  WG адрес  : $wg_addr                   "
    echo "  │  Порт      : $wg_port                   "
    echo "  │  Server 2  : $s2_ip:$s2_port            "
    echo "  │  Keepalive : ${keepalive}s               "
    echo "  │  Relay     : Server1↔Server3 через S2   "
    echo "  └─────────────────────────────────────────┘"
    echo
    read -n1 -r -p "Нажмите любую клавишу для начала..."
    echo

    install_wireguard_packages
    generate_keys
    enable_ip_forward

    local priv_key; priv_key=$(cat /etc/wireguard/private.key)

    # Создаём конфиг
    # AllowedIPs для Server2: 10.10.0.2/32 + 10.10.0.3/32
    # Так трафик до Server3 автоматически идёт через туннель к Server2
    cat > /etc/wireguard/wg0.conf << EOF
# WireGuard — Server 1 (${os_pretty}, NAT)
# Трафик до 10.10.0.3 идёт через Server 2 (relay)
#
# ROLE server1_nat
# S2_ENDPOINT ${s2_ip}:${s2_port}
# KEEPALIVE ${keepalive}
# MAIN_IFACE ${main_iface}

[Interface]
Address = ${wg_addr}
ListenPort = ${wg_port}
PrivateKey = ${priv_key}

PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT

# BEGIN_PEER server2
# (ключ добавляется ниже)
# END_PEER server2
EOF
    chmod 600 /etc/wireguard/wg0.conf

    open_firewall_port "$wg_port"
    show_own_key

    # Запрашиваем ключ Server 2
    local s2_key
    ask_peer_key "Server 2 (AlmaLinux)" s2_key
    if [[ -n "$s2_key" ]]; then
        _write_peer_server1 "$s2_key"
        install_watchdog "$s2_key"
    else
        warn "Ключ Server 2 не введён. Добавьте позже через меню управления."
    fi

    systemctl enable --now wg-quick@wg0
    ok "wg-quick@wg0 запущен и добавлен в автозагрузку."

    _show_post_install_info
}

_write_peer_server1() {
    local s2_key="$1"
    local endpoint keepalive
    endpoint=$(grep '# S2_ENDPOINT' /etc/wireguard/wg0.conf | awk '{print $3}')
    keepalive=$(grep '# KEEPALIVE'  /etc/wireguard/wg0.conf | awk '{print $3}')

    sed -i '/# BEGIN_PEER server2/,/# END_PEER server2/d' /etc/wireguard/wg0.conf

    cat >> /etc/wireguard/wg0.conf << EOF

# BEGIN_PEER server2
[Peer]
# Server 2 (AlmaLinux, relay)
# AllowedIPs включает 10.10.0.3 — трафик до Server3 идёт через этот пир
PublicKey    = ${s2_key}
AllowedIPs   = 10.10.0.2/32, 10.10.0.3/32
Endpoint     = ${endpoint}
PersistentKeepalive = ${keepalive}
# END_PEER server2
EOF
    ok "Пир Server 2 записан в конфиг."
    _reload_peer server2
}

# ════════════════════════════════════════════════════════════════
#  УСТАНОВКА: SERVER 2 — AlmaLinux, публичный, 10.10.0.2, RELAY
#  Два пира: Server 1 и Server 3
#  Форвардинг wg0→wg0 обеспечивает relay между NAT-серверами
# ════════════════════════════════════════════════════════════════

install_server2() {
    banner "Server 2 · ${os_pretty} · Публичный · Relay · 10.10.0.2"
    check_openvpn_routes

    local main_iface; main_iface=$(get_main_iface)
    [[ -z "$main_iface" ]] && { err "Не найден основной сетевой интерфейс."; exit 1; }

    local detected_ip; detected_ip=$(get_public_ip)
    echo
    read -p "Публичный IP этого сервера [${detected_ip}]: " public_ip
    [[ -z "$public_ip" ]] && public_ip="$detected_ip"
    info "Публичный IP: $public_ip"

    read -p "WireGuard порт [51820]: " wg_port
    [[ -z "$wg_port" ]] && wg_port="51820"

    read -p "WireGuard адрес этого сервера [10.10.0.2/24]: " wg_addr
    [[ -z "$wg_addr" ]] && wg_addr="10.10.0.2/24"

    echo
    echo "  ┌─────────────────────────────────────────┐"
    echo "  │ Параметры установки                     │"
    echo "  │  Публичный IP : $public_ip              "
    echo "  │  WG адрес     : $wg_addr                "
    echo "  │  Порт         : $wg_port                "
    echo "  │  Роль         : relay (S1↔S3)           "
    echo "  └─────────────────────────────────────────┘"
    echo
    read -n1 -r -p "Нажмите любую клавишу для начала..."
    echo

    install_wireguard_packages
    generate_keys
    enable_ip_forward

    local priv_key; priv_key=$(cat /etc/wireguard/private.key)

    cat > /etc/wireguard/wg0.conf << EOF
# WireGuard — Server 2 (${os_pretty}, публичный, relay)
# Обеспечивает связь между Server 1 и Server 3 (оба за NAT)
#
# ROLE server2_relay
# PUBLIC_IP ${public_ip}
# MAIN_IFACE ${main_iface}

[Interface]
Address = ${wg_addr}
ListenPort = ${wg_port}
PrivateKey = ${priv_key}

# Разрешаем форвардинг между пирами (критично для relay!)
PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT

# BEGIN_PEER server1
# (ключ добавляется ниже)
# END_PEER server1

# BEGIN_PEER server3
# (ключ добавляется ниже)
# END_PEER server3
EOF
    chmod 600 /etc/wireguard/wg0.conf

    open_firewall_port "$wg_port"

    # Добавляем Server 2 в trusted zone firewalld для relay-трафика
    if systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --zone=trusted --add-interface=wg0 2>/dev/null || true
        firewall-cmd --reload
        ok "wg0 добавлен в trusted zone firewalld (нужно для relay)."
    fi

    show_own_key

    local s1_key s3_key
    ask_peer_key "Server 1 (Ubuntu)" s1_key
    ask_peer_key "Server 3 (CentOS)" s3_key

    [[ -n "$s1_key" ]] && _write_peer_server2_s1 "$s1_key"
    [[ -n "$s3_key" ]] && _write_peer_server2_s3 "$s3_key"

    if [[ -z "$s1_key" || -z "$s3_key" ]]; then
        warn "Не все ключи введены. Добавьте оставшиеся через меню управления."
    fi

    systemctl enable --now wg-quick@wg0
    ok "wg-quick@wg0 запущен и добавлен в автозагрузку."

    _show_post_install_info
}

_write_peer_server2_s1() {
    local s1_key="$1"
    sed -i '/# BEGIN_PEER server1/,/# END_PEER server1/d' /etc/wireguard/wg0.conf
    cat >> /etc/wireguard/wg0.conf << EOF

# BEGIN_PEER server1
[Peer]
# Server 1 (Ubuntu, NAT)
# Endpoint не задаётся — запомнится автоматически при первом соединении
PublicKey  = ${s1_key}
AllowedIPs = 10.10.0.1/32
# END_PEER server1
EOF
    ok "Пир Server 1 записан в конфиг Server 2."
    _reload_peer server1
}

_write_peer_server2_s3() {
    local s3_key="$1"
    sed -i '/# BEGIN_PEER server3/,/# END_PEER server3/d' /etc/wireguard/wg0.conf
    cat >> /etc/wireguard/wg0.conf << EOF

# BEGIN_PEER server3
[Peer]
# Server 3 (CentOS, NAT)
# Endpoint не задаётся — запомнится автоматически при первом соединении
PublicKey  = ${s3_key}
AllowedIPs = 10.10.0.3/32
# END_PEER server3
EOF
    ok "Пир Server 3 записан в конфиг Server 2."
    _reload_peer server3
}

# ════════════════════════════════════════════════════════════════
#  УСТАНОВКА: SERVER 3 — CentOS Stream 8, за NAT, 10.10.0.3
#  Единственный пир: Server 2 (relay)
#  AllowedIPs включает 10.10.0.1 — трафик до Server1 идёт через Server2
# ════════════════════════════════════════════════════════════════

install_server3() {
    banner "Server 3 · ${os_pretty} · NAT · 10.10.0.3"
    check_openvpn_routes

    local main_iface; main_iface=$(get_main_iface)
    [[ -z "$main_iface" ]] && { err "Не найден основной сетевой интерфейс."; exit 1; }
    info "Основной интерфейс: $main_iface"

    echo
    read -p "WireGuard порт [51820]: " wg_port
    [[ -z "$wg_port" ]] && wg_port="51820"

    read -p "WireGuard адрес этого сервера [10.10.0.3/24]: " wg_addr
    [[ -z "$wg_addr" ]] && wg_addr="10.10.0.3/24"

    echo
    echo "Введите публичный IP Сервера 2 (AlmaLinux):"
    read -p "IP Server 2: " s2_ip
    until [[ "$s2_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; do
        read -p "Неверный IP. Повторите: " s2_ip
    done

    read -p "Порт WireGuard на Server 2 [51820]: " s2_port
    [[ -z "$s2_port" ]] && s2_port="51820"

    read -p "Keepalive в секундах [20]: " keepalive
    [[ -z "$keepalive" ]] && keepalive="20"

    echo
    echo "  ┌─────────────────────────────────────────┐"
    echo "  │ Параметры установки                     │"
    echo "  │  Интерфейс : $main_iface                 "
    echo "  │  WG адрес  : $wg_addr                   "
    echo "  │  Порт      : $wg_port                   "
    echo "  │  Server 2  : $s2_ip:$s2_port            "
    echo "  │  Keepalive : ${keepalive}s               "
    echo "  │  Relay     : Server3↔Server1 через S2   "
    echo "  └─────────────────────────────────────────┘"
    echo
    read -n1 -r -p "Нажмите любую клавишу для начала..."
    echo

    install_wireguard_packages
    generate_keys
    enable_ip_forward

    local priv_key; priv_key=$(cat /etc/wireguard/private.key)

    cat > /etc/wireguard/wg0.conf << EOF
# WireGuard — Server 3 (${os_pretty}, NAT)
# Трафик до 10.10.0.1 идёт через Server 2 (relay)
#
# ROLE server3_nat
# S2_ENDPOINT ${s2_ip}:${s2_port}
# KEEPALIVE ${keepalive}
# MAIN_IFACE ${main_iface}

[Interface]
Address = ${wg_addr}
ListenPort = ${wg_port}
PrivateKey = ${priv_key}

PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT

# BEGIN_PEER server2
# (ключ добавляется ниже)
# END_PEER server2
EOF
    chmod 600 /etc/wireguard/wg0.conf

    open_firewall_port "$wg_port"
    show_own_key

    local s2_key
    ask_peer_key "Server 2 (AlmaLinux)" s2_key
    if [[ -n "$s2_key" ]]; then
        _write_peer_server3 "$s2_key"
        install_watchdog "$s2_key"
    else
        warn "Ключ Server 2 не введён. Добавьте позже через меню управления."
    fi

    systemctl enable --now wg-quick@wg0
    ok "wg-quick@wg0 запущен и добавлен в автозагрузку."

    _show_post_install_info
}

_write_peer_server3() {
    local s2_key="$1"
    local endpoint keepalive
    endpoint=$(grep '# S2_ENDPOINT' /etc/wireguard/wg0.conf | awk '{print $3}')
    keepalive=$(grep '# KEEPALIVE'  /etc/wireguard/wg0.conf | awk '{print $3}')

    sed -i '/# BEGIN_PEER server2/,/# END_PEER server2/d' /etc/wireguard/wg0.conf

    cat >> /etc/wireguard/wg0.conf << EOF

# BEGIN_PEER server2
[Peer]
# Server 2 (AlmaLinux, relay)
# AllowedIPs включает 10.10.0.1 — трафик до Server1 идёт через этот пир
PublicKey    = ${s2_key}
AllowedIPs   = 10.10.0.2/32, 10.10.0.1/32
Endpoint     = ${endpoint}
PersistentKeepalive = ${keepalive}
# END_PEER server2
EOF
    ok "Пир Server 2 записан в конфиг."
    _reload_peer server2
}

# ── Применение изменений к живому интерфейсу ────────────────────

_reload_peer() {
    local peer_name="$1"
    if ip link show wg0 &>/dev/null; then
        info "Применяем пира $peer_name к живому интерфейсу..."
        wg addconf wg0 <(
            sed -n "/# BEGIN_PEER ${peer_name}/,/# END_PEER ${peer_name}/p" \
                /etc/wireguard/wg0.conf | grep -v '^#'
        ) 2>/dev/null && ok "Применено без перезапуска." \
                       || { warn "wg addconf не сработал, перезапускаем..."; \
                            systemctl restart wg-quick@wg0; }
    fi
}

# ── Пост-установочная информация ────────────────────────────────

_show_post_install_info() {
    echo
    echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Проверки после установки${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
    echo
    echo "  Статус туннеля:"
    echo "    sudo wg show"
    echo
    echo "  Пинг до Server 2: ping 10.10.0.2"
    echo "  Пинг до Server 1: ping 10.10.0.1  (только с S2 и S3)"
    echo "  Пинг до Server 3: ping 10.10.0.3  (только с S1 и S2)"
    echo
    echo "  Маршрут по умолчанию должен идти НЕ через wg0:"
    echo "    ip route get 8.8.8.8"
    echo
    echo "  Логи watchdog:"
    echo "    journalctl -t wg-watchdog -f"
    echo
}

# ════════════════════════════════════════════════════════════════
#  МЕНЮ УПРАВЛЕНИЯ
# ════════════════════════════════════════════════════════════════

management_menu() {
    clear
    local role
    role=$(grep '# ROLE' /etc/wireguard/wg0.conf 2>/dev/null | awk '{print $3}')

    banner "WireGuard уже установлен · ${os_pretty}"

    echo "  Роль: ${role:-неизвестна}"
    echo "  Публичный ключ: $(cat /etc/wireguard/public.key 2>/dev/null)"
    echo
    echo "  Статус:"
    wg show wg0 2>/dev/null | sed 's/^/    /' || echo "    (wg0 не запущен)"
    echo
    echo "  Выберите действие:"
    echo "   1) Статус туннеля и маршруты"
    echo "   2) Показать мой публичный ключ"
    echo "   3) Добавить / обновить ключ пира"
    echo "   4) Перезапустить WireGuard"
    echo "   5) Остановить WireGuard"
    echo "   6) Запустить WireGuard"
    echo "   7) Переустановить watchdog"
    echo "   8) Удалить WireGuard полностью"
    echo "   9) Выход"
    echo
    read -p "  Выбор: " opt
    until [[ "$opt" =~ ^[1-9]$ ]]; do
        read -p "  Неверный выбор: " opt
    done

    case "$opt" in
    1)
        echo
        echo "── wg show ──────────────────────────────────"
        wg show
        echo
        echo "── ip route show ────────────────────────────"
        ip route show
        echo
        echo "── ip route get 8.8.8.8 (должен быть eth/enp, не wg0) ──"
        ip route get 8.8.8.8
        echo
        read -n1 -r -p "Нажмите любую клавишу..."; management_menu
        ;;
    2)
        echo
        echo -e "  ${GREEN}$(cat /etc/wireguard/public.key)${NC}"
        echo
        read -n1 -r -p "Нажмите любую клавишу..."; management_menu
        ;;
    3)
        _menu_add_peer "$role"
        read -n1 -r -p "Нажмите любую клавишу..."; management_menu
        ;;
    4)
        systemctl restart wg-quick@wg0 && ok "Перезапущен." || err "Ошибка перезапуска."
        sleep 1; management_menu
        ;;
    5)
        wg-quick down wg0 && ok "Остановлен."
        ;;
    6)
        wg-quick up wg0 && ok "Запущен."
        sleep 1; management_menu
        ;;
    7)
        echo
        read -p "  Введите публичный ключ пира (или все через пробел): " wkeys
        install_watchdog "$wkeys"
        read -n1 -r -p "Нажмите любую клавишу..."; management_menu
        ;;
    8)
        _menu_uninstall
        ;;
    9)
        exit 0
        ;;
    esac
}

_menu_add_peer() {
    local role="$1"
    echo
    case "$role" in
    server1_nat)
        echo "  Добавление/обновление ключа Server 2:"
        read -p "  Публичный ключ Server 2: " s2_key
        [[ -n "$s2_key" ]] && { _write_peer_server1 "$s2_key"; install_watchdog "$s2_key"; \
                                 systemctl restart wg-quick@wg0; }
        ;;
    server2_relay)
        echo "  Какой пир добавить?"
        echo "   1) Server 1 (Ubuntu)"
        echo "   2) Server 3 (CentOS)"
        read -p "  Выбор: " pc
        case "$pc" in
        1)
            read -p "  Публичный ключ Server 1: " s1_key
            [[ -n "$s1_key" ]] && { _write_peer_server2_s1 "$s1_key"; \
                                     systemctl restart wg-quick@wg0; }
            ;;
        2)
            read -p "  Публичный ключ Server 3: " s3_key
            [[ -n "$s3_key" ]] && { _write_peer_server2_s3 "$s3_key"; \
                                     systemctl restart wg-quick@wg0; }
            ;;
        esac
        ;;
    server3_nat)
        echo "  Добавление/обновление ключа Server 2:"
        read -p "  Публичный ключ Server 2: " s2_key
        [[ -n "$s2_key" ]] && { _write_peer_server3 "$s2_key"; install_watchdog "$s2_key"; \
                                  systemctl restart wg-quick@wg0; }
        ;;
    *)
        warn "Роль не определена. Редактируйте /etc/wireguard/wg0.conf вручную."
        ;;
    esac
}

_menu_uninstall() {
    echo
    read -p "  Удалить WireGuard и все конфиги? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[yY]$ ]] && { echo "Отменено."; sleep 1; management_menu; return; }

    systemctl disable --now wg-quick@wg0 2>/dev/null
    remove_watchdog

    local port; port=$(grep ListenPort /etc/wireguard/wg0.conf 2>/dev/null | awk '{print $3}')

    case "$os" in
    ubuntu)
        apt-get remove --purge -y wireguard wireguard-tools 2>/dev/null
        [[ -n "$port" ]] && command -v ufw &>/dev/null && ufw delete allow "$port"/udp 2>/dev/null
        ;;
    almalinux|centos)
        dnf remove -y wireguard-tools kmod-wireguard 2>/dev/null
        if systemctl is-active --quiet firewalld && [[ -n "$port" ]]; then
            firewall-cmd --permanent --remove-port="${port}/udp"
            firewall-cmd --permanent --zone=trusted --remove-interface=wg0 2>/dev/null || true
            firewall-cmd --reload
        fi
        ;;
    esac

    rm -rf /etc/wireguard
    rm -f /etc/sysctl.d/99-wireguard.conf
    rm -f /etc/modules-load.d/wireguard.conf
    sysctl --system -q

    ok "WireGuard полностью удалён."
}

# ════════════════════════════════════════════════════════════════
#  ТОЧКА ВХОДА
# ════════════════════════════════════════════════════════════════

if [[ -e /etc/wireguard/wg0.conf ]]; then
    management_menu
    exit 0
fi

# Первичная установка
clear
banner "WireGuard Mesh Installer · 3 узла"

echo "  Обнаружена ОС: ${os_pretty}"
echo
echo "  Топология сети:"
echo "   Server 1 · Ubuntu    · NAT     · 10.10.0.1"
echo "   Server 2 · AlmaLinux · Публичный · 10.10.0.2  ← relay"
echo "   Server 3 · CentOS    · NAT     · 10.10.0.3"
echo
echo "  Server1 ↔ Server3 трафик идёт через Server2 (relay)"
echo

case "$os" in
ubuntu)
    echo "  Ubuntu обнаружена → роль: Server 1 (NAT)"
    read -p "  Подтвердить? [Y/n]: " c
    [[ "$c" =~ ^[nN]$ ]] && exit 0
    install_server1
    ;;
almalinux)
    echo "  AlmaLinux обнаружена → роль: Server 2 (публичный, relay)"
    read -p "  Подтвердить? [Y/n]: " c
    [[ "$c" =~ ^[nN]$ ]] && exit 0
    install_server2
    ;;
centos)
    echo "  CentOS обнаружена → роль: Server 3 (NAT)"
    read -p "  Подтвердить? [Y/n]: " c
    [[ "$c" =~ ^[nN]$ ]] && exit 0
    install_server3
    ;;
esac
