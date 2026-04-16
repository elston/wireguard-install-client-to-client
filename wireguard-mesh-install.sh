#!/bin/bash

#
# WireGuard Mesh Installer
# ────────────────────────────────────────────────────────────────
#  Роль выбирается вручную — не зависит от ОС:
#    relay  — публичный узел, форвардит трафик между NAT-пирами
#    nat    — узел за NAT, подключается к relay
#
#  Поддерживаемые ОС: Ubuntu 22.04+, AlmaLinux 9+, CentOS Stream 8+
#  Трафик НЕ перенаправляется в интернет (нет redirect-gateway).
#
#  Использование: sudo bash wireguard-mesh-install.sh
#

# ── Базовые проверки ────────────────────────────────────────────

if readlink /proc/$$/exe | grep -q "dash"; then
    echo 'Запускайте через bash, не sh.'; exit 1
fi
read -N 999999 -t 0.001

if [[ "$EUID" -ne 0 ]]; then
    echo "Требуются права root (sudo)."; exit 1
fi

if ! grep -q sbin <<< "$PATH"; then
    echo '$PATH не содержит sbin. Используйте "su -" вместо "su".'; exit 1
fi

# ── Определение ОС (только для пакетного менеджера) ─────────────

os_pretty=$(grep PRETTY_NAME /etc/os-release | cut -d '"' -f 2)

if grep -qs "ubuntu" /etc/os-release; then
    os="ubuntu"
    os_version=$(grep VERSION_ID /etc/os-release | cut -d '"' -f 2 | tr -d '.')
    [[ "$os_version" -lt 2204 ]] && { echo "Требуется Ubuntu 22.04+."; exit 1; }
elif [[ -e /etc/almalinux-release ]]; then
    os="almalinux"
    os_version=$(grep -oE '[0-9]+' /etc/almalinux-release | head -1)
    [[ "$os_version" -lt 9 ]] && { echo "Требуется AlmaLinux 9+."; exit 1; }
elif [[ -e /etc/centos-release ]]; then
    os="centos"
    os_version=$(grep -oE '[0-9]+' /etc/centos-release | head -1)
    [[ "$os_version" -lt 8 ]] && { echo "Требуется CentOS Stream 8+."; exit 1; }
else
    echo "Неподдерживаемый дистрибутив. Поддержка: Ubuntu 22.04+, AlmaLinux 9+, CentOS Stream 8+."
    exit 1
fi

# ── Цвета ───────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

info() { echo -e "${CYAN}[info]${NC}  $*"; }
ok()   { echo -e "${GREEN}[ ok ]${NC}  $*"; }
warn() { echo -e "${YELLOW}[warn]${NC}  $*"; }
err()  { echo -e "${RED}[ !! ]${NC}  $*"; }
hr()   { echo -e "${DIM}────────────────────────────────────────────────${NC}"; }

banner() {
    echo; hr
    echo -e "  ${BOLD}$*${NC}"
    hr; echo
}

# ── Утилиты ─────────────────────────────────────────────────────

get_main_iface() {
    ip route show default | grep -v tun | grep -v wg | awk '/default/{print $5}' | head -1
}

get_public_ip() {
    { wget -T 10 -t 1 -4qO- "https://api4.ipify.org" 2>/dev/null \
      || curl -m 10 -4Ls "https://api4.ipify.org" 2>/dev/null; } \
    | grep -oE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
}

is_valid_ip() {
    [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]
}

is_valid_cidr() {
    [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]
}

# Читаем метаданные из конфига
cfg_get() {
    grep "# CFG_${1}" /etc/wireguard/wg0.conf 2>/dev/null | awk '{print $3}'
}

check_openvpn_routes() {
    if ip route show 2>/dev/null | grep -q "0.0.0.0/1.*tun\|128.0.0.0/1.*tun"; then
        warn "Обнаружены маршруты OpenVPN перенаправляющие весь трафик."
        read -p "  Продолжить? [y/N]: " fc
        [[ ! "$fc" =~ ^[yY]$ ]] && exit 1
    else
        ok "Маршруты OpenVPN корректны."
    fi
}

# ── Установка пакетов ────────────────────────────────────────────

install_wireguard_packages() {
    case "$os" in
    ubuntu)
        info "Устанавливаем wireguard (apt)..."
        apt-get update -q
        apt-get install -y wireguard wireguard-tools
        ;;
    almalinux)
        info "Устанавливаем wireguard (dnf)..."
        dnf install -y epel-release
        dnf install -y wireguard-tools
        _load_wg_module
        ;;
    centos)
        info "Устанавливаем wireguard (dnf + ELRepo)..."
        _fix_centos8_repos
        dnf install -y epel-release
        dnf install -y https://www.elrepo.org/elrepo-release-8.el8.elrepo.noarch.rpm \
            2>/dev/null || dnf install -y elrepo-release 2>/dev/null || true
        dnf --enablerepo=elrepo install -y kmod-wireguard wireguard-tools
        _load_wg_module
        ;;
    esac
    ok "WireGuard установлен."
}

_load_wg_module() {
    if modprobe wireguard 2>/dev/null; then
        echo "wireguard" > /etc/modules-load.d/wireguard.conf
        ok "Модуль wireguard загружен."
        return 0
    fi

    # Модуль недоступен — проверяем контейнерную среду
    local virt; virt=$(systemd-detect-virt 2>/dev/null)
    if [[ "$virt" == "openvz" || "$virt" == "lxc" || "$virt" == "lxc-libvirt" ]]; then
        warn "Обнаружена контейнерная среда (${virt}) — ядерный модуль недоступен."
        warn "Переключаемся на BoringTun (userspace WireGuard)..."
        _install_boringtun
    else
        # Не контейнер — пробуем kernel-devel (актуально для CentOS Stream 8)
        warn "Модуль не загрузился, пробуем пересобрать через kernel-devel..."
        dnf install -y "kernel-devel-$(uname -r)" 2>/dev/null \
            || dnf install -y kernel-devel 2>/dev/null || true
        depmod -a
        modprobe wireguard || { err "Не удалось загрузить модуль wireguard."; exit 1; }
        echo "wireguard" > /etc/modules-load.d/wireguard.conf
        ok "Модуль wireguard загружен."
    fi
}

_install_boringtun() {
    # Проверяем TUN-устройство — без него BoringTun не работает
    if [[ ! -e /dev/net/tun ]]; then
        err "TUN-устройство недоступно (/dev/net/tun не найден)."
        err "Попросите хостера включить TUN или модуль wireguard для контейнера."
        exit 1
    fi

    # Проверяем что boringtun уже установлен
    if command -v boringtun &>/dev/null; then
        ok "BoringTun уже установлен: $(boringtun --version)"
    else
        info "Скачиваем BoringTun..."
        local url="https://github.com/robvanoostenrijk/boringtun-static/releases/download/v0.5.2/boringtun-cli-0.5.2-x86_64-unknown-linux-musl.tar.xz"
        local tmp; tmp=$(mktemp -d)

        if ! { wget -qO "${tmp}/bt.tar.xz" "$url" 2>/dev/null \
               || curl -Lo "${tmp}/bt.tar.xz" "$url" 2>/dev/null; }; then
            err "Не удалось скачать BoringTun."
            err "Скачайте вручную и положите бинарник в /usr/local/sbin/boringtun"
            err "  ${url}"
            exit 1
        fi

        tar -xf "${tmp}/bt.tar.xz" -C "${tmp}"
        local binary; binary=$(find "$tmp" -type f -executable ! -name "*.tar*" | head -1)
        [[ -z "$binary" ]] && { err "Бинарник не найден в архиве."; exit 1; }

        cp "$binary" /usr/local/sbin/boringtun
        chmod +x /usr/local/sbin/boringtun
        rm -rf "$tmp"
        ok "BoringTun установлен: $(boringtun --version)"
    fi

    # Настраиваем wg-quick для использования BoringTun
    mkdir -p /etc/systemd/system/wg-quick@wg0.service.d/
    cat > /etc/systemd/system/wg-quick@wg0.service.d/boringtun.conf << 'EOF'
[Service]
Environment=WG_QUICK_USERSPACE_IMPLEMENTATION=boringtun
Environment=WG_SUDO=1
EOF
    systemctl daemon-reload
    ok "wg-quick настроен на использование BoringTun."
}

_fix_centos8_repos() {
    if ! dnf repolist 2>/dev/null | grep -q "baseos"; then
        warn "Переключаем репозитории CentOS 8 на vault..."
        sed -i 's|mirrorlist=|#mirrorlist=|g' /etc/yum.repos.d/CentOS-*.repo 2>/dev/null
        sed -i 's|#baseurl=http://mirror.centos.org|baseurl=https://vault.centos.org|g' \
            /etc/yum.repos.d/CentOS-*.repo 2>/dev/null
        ok "Репозитории → vault.centos.org"
    fi
}

open_firewall_port() {
    local port="$1"
    case "$os" in
    ubuntu)
        if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
            ufw allow "$port"/udp && ok "UFW: $port/udp открыт."
        fi
        ;;
    almalinux|centos)
        if systemctl is-active --quiet firewalld; then
            firewall-cmd --permanent --add-port="${port}/udp"
            firewall-cmd --reload
            ok "firewalld: $port/udp открыт."
        else
            iptables -I INPUT -p udp --dport "$port" -j ACCEPT
            warn "firewalld не активен — добавлено временное правило iptables."
        fi
        ;;
    esac
}

enable_relay_forwarding_firewall() {
    if [[ "$os" != "ubuntu" ]] && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --zone=trusted --add-interface=wg0 2>/dev/null || true
        firewall-cmd --reload
        ok "firewalld: wg0 → trusted zone (relay forwarding)."
    fi
}

# ── Ключи ───────────────────────────────────────────────────────

generate_keys() {
    mkdir -p /etc/wireguard && chmod 700 /etc/wireguard
    wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
    chmod 600 /etc/wireguard/private.key
    ok "Ключевая пара сгенерирована."
}

show_own_key() {
    echo
    echo -e "  Ваш публичный ключ ${DIM}(передайте на другие узлы)${NC}:"
    echo
    echo -e "  ${GREEN}${BOLD}$(cat /etc/wireguard/public.key)${NC}"
    echo
}

enable_ip_forward() {
    echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-wireguard.conf
    sysctl --system -q
    ok "ip_forward = 1"
}

# ── Watchdog ────────────────────────────────────────────────────

install_watchdog() {
    cat > /usr/local/bin/wg-watchdog.sh << 'WATCHDOG'
#!/bin/bash
IFACE="wg0"
MAX_SECONDS=120
LOG_TAG="wg-watchdog"

ip link show "$IFACE" &>/dev/null || exit 0

STALE=0
while IFS= read -r line; do
    HS=$(echo "$line" | awk '{print $2}')
    [[ -z "$HS" || "$HS" == "0" ]] && { STALE=1; break; }
    DIFF=$(( $(date +%s) - HS ))
    [[ "$DIFF" -gt "$MAX_SECONDS" ]] && { STALE=1; break; }
done < <(wg show "$IFACE" latest-handshakes 2>/dev/null)

if [[ "$STALE" -eq 1 ]]; then
    logger -t "$LOG_TAG" "Туннель завис, перезапуск wg0..."
    wg-quick down "$IFACE" 2>/dev/null
    sleep 2
    wg-quick up "$IFACE"
    logger -t "$LOG_TAG" "Перезапущен."
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

# ── Управление пирами ────────────────────────────────────────────

_apply_peer_live() {
    local peer_id="$1"
    if ip link show wg0 &>/dev/null; then
        wg addconf wg0 <(
            sed -n "/# BEGIN_PEER ${peer_id}/,/# END_PEER ${peer_id}/p" \
                /etc/wireguard/wg0.conf | grep -v '^#'
        ) 2>/dev/null \
        && ok "Пир '${peer_id}' применён к живому интерфейсу." \
        || { warn "wg addconf не сработал, перезапускаем wg0..."
             systemctl restart wg-quick@wg0; }
    fi
}

_remove_peer_from_config() {
    local peer_id="$1"
    sed -i "/# BEGIN_PEER ${peer_id}/,/# END_PEER ${peer_id}/d" /etc/wireguard/wg0.conf
}

_list_peers() {
    grep '# BEGIN_PEER' /etc/wireguard/wg0.conf 2>/dev/null | awk '{print $3}'
}

_peer_count() {
    grep -c '# BEGIN_PEER' /etc/wireguard/wg0.conf 2>/dev/null || echo 0
}

# ════════════════════════════════════════════════════════════════
#  РОЛЬ: RELAY
# ════════════════════════════════════════════════════════════════

setup_relay() {
    banner "Установка: роль RELAY"
    check_openvpn_routes

    echo "  WireGuard адрес этого узла:"
    echo -e "  ${DIM}Пример: 10.10.0.1/24${NC}"
    read -p "  Адрес: " wg_addr
    until is_valid_cidr "$wg_addr"; do
        read -p "  Неверный формат (нужен IP/маска). Повторите: " wg_addr
    done

    read -p "  WireGuard порт [51820]: " wg_port
    [[ -z "$wg_port" ]] && wg_port="51820"

    read -p "  Имя этого узла [relay]: " node_name
    [[ -z "$node_name" ]] && node_name="relay"

    local os_short="${os_pretty:0:32}"
    echo
    echo "  ┌────────────────────────────────────────┐"
    printf "  │  %-38s│\n" "ОС    : ${os_short}"
    printf "  │  %-38s│\n" "Роль  : relay"
    printf "  │  %-38s│\n" "Адрес : ${wg_addr}"
    printf "  │  %-38s│\n" "Порт  : ${wg_port}"
    printf "  │  %-38s│\n" "Имя   : ${node_name}"
    echo "  └────────────────────────────────────────┘"
    echo
    read -n1 -r -p "  Нажмите любую клавишу для начала установки..."
    echo; echo

    install_wireguard_packages
    generate_keys
    enable_ip_forward

    local priv_key; priv_key=$(cat /etc/wireguard/private.key)

    cat > /etc/wireguard/wg0.conf << EOF
# WireGuard — ${node_name} (${os_pretty})
# Роль: relay — форвардит трафик между NAT-узлами
# Трафик НЕ перенаправляется в интернет.
#
# CFG_ROLE relay
# CFG_NODE_NAME ${node_name}
# CFG_WG_ADDR ${wg_addr}
# CFG_PORT ${wg_port}

[Interface]
Address    = ${wg_addr}
ListenPort = ${wg_port}
PrivateKey = ${priv_key}

# Форвардинг между пирами (критично для relay!)
PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT
EOF
    chmod 600 /etc/wireguard/wg0.conf

    open_firewall_port "$wg_port"
    enable_relay_forwarding_firewall
    show_own_key

    echo "  Добавьте NAT-узлы которые будут подключаться к этому relay."
    echo "  Для каждого нужен публичный ключ и WG-адрес."
    echo
    _relay_add_peers_loop

    systemctl enable --now wg-quick@wg0
    ok "wg-quick@wg0 запущен и добавлен в автозагрузку."
    _post_install_summary relay
}

_relay_add_peers_loop() {
    local count=0
    while true; do
        hr
        echo "  Пир $((count + 1))"
        read -p "  Имя пира (Enter — завершить): " peer_id
        [[ -z "$peer_id" ]] && break

        peer_id=$(echo "$peer_id" | tr -cs 'a-zA-Z0-9_-' '_')

        read -p "  Публичный ключ пира: " peer_key
        [[ -z "$peer_key" ]] && { warn "Ключ не введён, пропускаем."; continue; }

        echo "  WireGuard IP пира:"
        echo -e "  ${DIM}Только IP, без маски. Пример: 10.10.0.2${NC}"
        read -p "  IP: " peer_wg_ip
        until is_valid_ip "$peer_wg_ip"; do
            read -p "  Неверный IP. Повторите: " peer_wg_ip
        done

        _write_relay_peer "$peer_id" "$peer_key" "$peer_wg_ip"
        (( count++ ))
        echo
    done
    [[ "$count" -gt 0 ]] && ok "Добавлено пиров: ${count}." \
        || warn "Пиров нет. Добавьте через меню управления."
}

_write_relay_peer() {
    local peer_id="$1" peer_key="$2" peer_wg_ip="$3"
    _remove_peer_from_config "$peer_id"
    cat >> /etc/wireguard/wg0.conf << EOF

# BEGIN_PEER ${peer_id}
[Peer]
# NAT-узел — Endpoint не задаётся, запомнится автоматически
PublicKey  = ${peer_key}
AllowedIPs = ${peer_wg_ip}/32
# END_PEER ${peer_id}
EOF
    ok "Пир '${peer_id}' (${peer_wg_ip}) → конфиг."
    _apply_peer_live "$peer_id"
}

# ════════════════════════════════════════════════════════════════
#  РОЛЬ: NAT
# ════════════════════════════════════════════════════════════════

setup_nat() {
    banner "Установка: роль NAT (за NAT / без публичного IP)"
    check_openvpn_routes

    local main_iface; main_iface=$(get_main_iface)
    [[ -z "$main_iface" ]] && { err "Не найден основной сетевой интерфейс."; exit 1; }
    info "Основной интерфейс: $main_iface"

    echo
    echo "  WireGuard адрес этого узла:"
    echo -e "  ${DIM}Пример: 10.10.0.2/24${NC}"
    read -p "  Адрес: " wg_addr
    until is_valid_cidr "$wg_addr"; do
        read -p "  Неверный формат. Повторите: " wg_addr
    done

    read -p "  WireGuard порт [51820]: " wg_port
    [[ -z "$wg_port" ]] && wg_port="51820"

    read -p "  Keepalive в секундах [20]: " keepalive
    [[ -z "$keepalive" ]] && keepalive="20"

    read -p "  Имя этого узла [node]: " node_name
    [[ -z "$node_name" ]] && node_name="node"

    local os_short="${os_pretty:0:26}"
    echo
    echo "  ┌────────────────────────────────────────┐"
    printf "  │  %-38s│\n" "ОС          : ${os_short}"
    printf "  │  %-38s│\n" "Роль        : NAT"
    printf "  │  %-38s│\n" "Адрес       : ${wg_addr}"
    printf "  │  %-38s│\n" "Порт        : ${wg_port}"
    printf "  │  %-38s│\n" "Keepalive   : ${keepalive}s"
    printf "  │  %-38s│\n" "Имя         : ${node_name}"
    echo "  └────────────────────────────────────────┘"
    echo
    read -n1 -r -p "  Нажмите любую клавишу для начала установки..."
    echo; echo

    install_wireguard_packages
    generate_keys
    enable_ip_forward

    local priv_key; priv_key=$(cat /etc/wireguard/private.key)

    cat > /etc/wireguard/wg0.conf << EOF
# WireGuard — ${node_name} (${os_pretty})
# Роль: nat (за NAT)
# Трафик НЕ перенаправляется в интернет.
#
# CFG_ROLE nat
# CFG_NODE_NAME ${node_name}
# CFG_WG_ADDR ${wg_addr}
# CFG_PORT ${wg_port}
# CFG_KEEPALIVE ${keepalive}
# CFG_MAIN_IFACE ${main_iface}

[Interface]
Address    = ${wg_addr}
ListenPort = ${wg_port}
PrivateKey = ${priv_key}

PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT
EOF
    chmod 600 /etc/wireguard/wg0.conf

    open_firewall_port "$wg_port"
    show_own_key

    echo "  Добавьте relay-узел(ы). Через relay идёт трафик"
    echo "  до всех остальных узлов сети."
    echo
    _nat_add_relays_loop "$keepalive"

    if [[ "$(_peer_count)" -eq 0 ]]; then
        warn "Relay не добавлен — добавьте через меню управления."
    else
        install_watchdog
    fi

    systemctl enable --now wg-quick@wg0
    ok "wg-quick@wg0 запущен и добавлен в автозагрузку."
    _post_install_summary nat
}

_nat_add_relays_loop() {
    local keepalive="$1"
    local count=0

    while true; do
        hr
        echo "  Relay-пир $((count + 1))"
        read -p "  Имя relay-узла (Enter — завершить): " peer_id

        if [[ -z "$peer_id" ]]; then
            [[ "$count" -eq 0 ]] && warn "Нужен хотя бы один relay."
            break
        fi
        peer_id=$(echo "$peer_id" | tr -cs 'a-zA-Z0-9_-' '_')

        read -p "  Публичный ключ relay: " peer_key
        [[ -z "$peer_key" ]] && { warn "Ключ не введён, пропускаем."; continue; }

        echo "  Публичный IP relay-узла:"
        read -p "  IP: " relay_ip
        until is_valid_ip "$relay_ip"; do
            read -p "  Неверный IP. Повторите: " relay_ip
        done

        read -p "  Порт relay [51820]: " relay_port
        [[ -z "$relay_port" ]] && relay_port="51820"

        echo "  WG-адрес relay-узла (только IP):"
        echo -e "  ${DIM}Пример: 10.10.0.1${NC}"
        read -p "  WG IP relay: " relay_wg_ip
        until is_valid_ip "$relay_wg_ip"; do
            read -p "  Неверный IP. Повторите: " relay_wg_ip
        done

        # Дополнительные IP, доступные через этот relay (другие NAT-узлы)
        echo
        echo "  Какие ещё WG-адреса доступны через этот relay?"
        echo -e "  ${DIM}Другие узлы сети через пробел или запятую.${NC}"
        echo -e "  ${DIM}Пример: 10.10.0.3 10.10.0.4 — или просто Enter, если больше нет${NC}"
        read -p "  Дополнительные IP: " extra_ips_raw

        # Собираем AllowedIPs
        local allowed="${relay_wg_ip}/32"
        if [[ -n "$extra_ips_raw" ]]; then
            local normalized
            normalized=$(echo "$extra_ips_raw" | tr ',' ' ' | tr -s ' ')
            for ip in $normalized; do
                [[ -z "$ip" ]] && continue
                [[ "$ip" != */* ]] && ip="${ip}/32"
                allowed="${allowed}, ${ip}"
            done
        fi

        _write_nat_peer "$peer_id" "$peer_key" \
            "${relay_ip}:${relay_port}" "$allowed" "$keepalive"
        (( count++ ))

        echo
        read -p "  Добавить ещё relay? [y/N]: " more
        [[ ! "$more" =~ ^[yY]$ ]] && break
        echo
    done
    [[ "$count" -gt 0 ]] && ok "Добавлено relay-пиров: ${count}."
}

_write_nat_peer() {
    local peer_id="$1" peer_key="$2" endpoint="$3"
    local allowed_ips="$4" keepalive="$5"

    _remove_peer_from_config "$peer_id"
    cat >> /etc/wireguard/wg0.conf << EOF

# BEGIN_PEER ${peer_id}
[Peer]
# Relay — инициируем соединение сами, keepalive держит NAT открытым
PublicKey           = ${peer_key}
AllowedIPs          = ${allowed_ips}
Endpoint            = ${endpoint}
PersistentKeepalive = ${keepalive}
# END_PEER ${peer_id}
EOF
    ok "Relay '${peer_id}' → конфиг. AllowedIPs: ${allowed_ips}"
    _apply_peer_live "$peer_id"
}

# ── Пост-установочная сводка ─────────────────────────────────────

_post_install_summary() {
    local role="$1"
    echo; hr
    echo -e "  ${BOLD}Установка завершена${NC}"
    hr; echo
    echo "  sudo wg show              — статус пиров и handshake"
    echo "  ip route show             — таблица маршрутов"
    echo "  ip route get 8.8.8.8      — интернет должен идти НЕ через wg0"
    echo "  journalctl -t wg-watchdog — лог watchdog"
    echo
    if [[ "$role" == "relay" ]]; then
        echo "  Relay принимает подключения. Передайте ваш публичный ключ"
        echo "  всем NAT-узлам сети."
    else
        local ka; ka=$(cfg_get KEEPALIVE)
        echo "  Handshake с relay произойдёт в течение ${ka:-20} секунд."
        echo "  Если ping не проходит: sudo wg show → проверьте 'latest handshake'."
    fi
    echo
}

# ════════════════════════════════════════════════════════════════
#  МЕНЮ УПРАВЛЕНИЯ
# ════════════════════════════════════════════════════════════════

management_menu() {
    clear
    local role node_name
    role=$(cfg_get ROLE)
    node_name=$(cfg_get NODE_NAME)

    banner "WireGuard · ${node_name:-узел} · роль: ${role:-?} · ${os_pretty}"

    echo -e "  Публичный ключ: ${GREEN}$(cat /etc/wireguard/public.key 2>/dev/null)${NC}"
    echo
    echo "  Статус:"
    wg show wg0 2>/dev/null | sed 's/^/    /' || echo "    (wg0 не запущен)"
    echo
    hr
    echo "   1) Статус + маршруты"
    echo "   2) Мой публичный ключ"
    if [[ "$role" == "relay" ]]; then
        echo "   3) Добавить NAT-пира"
        echo "   4) Удалить пира"
    else
        echo "   3) Добавить / обновить relay-пира"
        echo "   4) Обновить AllowedIPs у relay-пира"
    fi
    echo "   5) Перезапустить WireGuard"
    echo "   6) Остановить / Запустить WireGuard"
    echo "   7) Watchdog: переустановить"
    echo "   8) Удалить WireGuard полностью"
    echo "   9) Выход"
    hr; echo
    read -p "  Выбор: " opt
    until [[ "$opt" =~ ^[1-9]$ ]]; do read -p "  Введите 1-9: " opt; done

    case "$opt" in
    1)
        echo
        echo "── wg show ──────────────────────────────"; wg show
        echo; echo "── ip route ─────────────────────────────"; ip route show
        echo; echo "── route get 8.8.8.8 ────────────────────"; ip route get 8.8.8.8
        echo; read -n1 -r -p "  Нажмите любую клавишу..."
        management_menu ;;
    2)
        echo
        echo -e "  ${GREEN}${BOLD}$(cat /etc/wireguard/public.key)${NC}"
        echo; read -n1 -r -p "  Нажмите любую клавишу..."
        management_menu ;;
    3)
        echo
        if [[ "$role" == "relay" ]]; then
            _relay_add_peers_loop
        else
            local ka; ka=$(cfg_get KEEPALIVE); [[ -z "$ka" ]] && ka=20
            _nat_add_relays_loop "$ka"
            install_watchdog
        fi
        systemctl restart wg-quick@wg0
        read -n1 -r -p "  Нажмите любую клавишу..."
        management_menu ;;
    4)
        echo
        local peers=(); mapfile -t peers < <(_list_peers)
        if [[ "${#peers[@]}" -eq 0 ]]; then
            warn "Нет пиров в конфиге."
        else
            echo "  Пиры:"
            for i in "${!peers[@]}"; do echo "    $((i+1))) ${peers[$i]}"; done
            echo
            if [[ "$role" == "relay" ]]; then
                read -p "  Номер пира для удаления: " pnum
                if [[ "$pnum" =~ ^[0-9]+$ && "$pnum" -le "${#peers[@]}" ]]; then
                    local pid="${peers[$((pnum-1))]}"
                    local pkey
                    pkey=$(sed -n "/# BEGIN_PEER ${pid}/,/# END_PEER ${pid}/p" \
                        /etc/wireguard/wg0.conf | grep PublicKey | awk '{print $3}')
                    [[ -n "$pkey" ]] && wg set wg0 peer "$pkey" remove 2>/dev/null
                    _remove_peer_from_config "$pid"
                    ok "Пир '${pid}' удалён."
                else
                    warn "Неверный номер."
                fi
            else
                # NAT: обновляем AllowedIPs
                read -p "  Номер relay для обновления AllowedIPs: " pnum
                if [[ "$pnum" =~ ^[0-9]+$ && "$pnum" -le "${#peers[@]}" ]]; then
                    local pid="${peers[$((pnum-1))]}"
                    local pkey endpoint ka_val
                    pkey=$(sed -n "/# BEGIN_PEER ${pid}/,/# END_PEER ${pid}/p" \
                        /etc/wireguard/wg0.conf | grep PublicKey | awk '{print $3}')
                    endpoint=$(sed -n "/# BEGIN_PEER ${pid}/,/# END_PEER ${pid}/p" \
                        /etc/wireguard/wg0.conf | grep Endpoint | awk '{print $3}')
                    ka_val=$(cfg_get KEEPALIVE); [[ -z "$ka_val" ]] && ka_val=20
                    read -p "  Новые AllowedIPs (через запятую): " new_allowed
                    _remove_peer_from_config "$pid"
                    _write_nat_peer "$pid" "$pkey" "$endpoint" "$new_allowed" "$ka_val"
                    systemctl restart wg-quick@wg0
                    ok "AllowedIPs обновлены."
                fi
            fi
        fi
        read -n1 -r -p "  Нажмите любую клавишу..."
        management_menu ;;
    5)
        systemctl restart wg-quick@wg0 && ok "Перезапущен." || err "Ошибка."
        sleep 1; management_menu ;;
    6)
        if ip link show wg0 &>/dev/null; then
            wg-quick down wg0 && ok "Остановлен."
        else
            wg-quick up wg0 && ok "Запущен."
            sleep 1; management_menu
        fi ;;
    7)
        install_watchdog
        read -n1 -r -p "  Нажмите любую клавишу..."
        management_menu ;;
    8)
        echo
        read -p "  Удалить WireGuard и все конфиги? [y/N]: " confirm
        if [[ "$confirm" =~ ^[yY]$ ]]; then
            systemctl disable --now wg-quick@wg0 2>/dev/null
            remove_watchdog
            local port; port=$(grep ListenPort /etc/wireguard/wg0.conf 2>/dev/null | awk '{print $3}')
            case "$os" in
            ubuntu)
                apt-get remove --purge -y wireguard wireguard-tools 2>/dev/null
                [[ -n "$port" ]] && command -v ufw &>/dev/null \
                    && ufw delete allow "$port"/udp 2>/dev/null ;;
            almalinux|centos)
                dnf remove -y wireguard-tools kmod-wireguard 2>/dev/null
                if systemctl is-active --quiet firewalld && [[ -n "$port" ]]; then
                    firewall-cmd --permanent --remove-port="${port}/udp"
                    firewall-cmd --permanent --zone=trusted \
                        --remove-interface=wg0 2>/dev/null || true
                    firewall-cmd --reload
                fi ;;
            esac
            rm -rf /etc/wireguard
            rm -f /etc/sysctl.d/99-wireguard.conf
            rm -f /etc/modules-load.d/wireguard.conf
            sysctl --system -q
            ok "WireGuard полностью удалён."
        else
            echo "  Отменено."; sleep 1; management_menu
        fi ;;
    9) exit 0 ;;
    esac
}

# ════════════════════════════════════════════════════════════════
#  ТОЧКА ВХОДА
# ════════════════════════════════════════════════════════════════

if [[ -e /etc/wireguard/wg0.conf ]]; then
    management_menu
    exit 0
fi

clear
banner "WireGuard Mesh Installer"
echo "  Система: ${os_pretty}"
echo
echo "  Выберите роль этого узла:"
echo
echo -e "   ${BOLD}1) relay${NC}  — публичный IP"
echo      "             Принимает подключения от NAT-узлов"
echo      "             Форвардит трафик между ними"
echo
echo -e "   ${BOLD}2) nat${NC}    — за NAT / без публичного IP"
echo      "             Подключается к relay"
echo      "             Трафик до других узлов идёт через relay"
echo
hr
read -p "  Роль [1/2]: " role_choice
until [[ "$role_choice" =~ ^[12]$ ]]; do
    read -p "  Введите 1 или 2: " role_choice
done

case "$role_choice" in
1) setup_relay ;;
2) setup_nat   ;;
esac
