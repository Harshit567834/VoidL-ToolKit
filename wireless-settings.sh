#!/bin/sh
# ============================================================================
#  void-wireless  --  wireless settings for Void Linux
#  ----------------------------------------------------------------------------
#  A small, dependency free text GUI for Wi-Fi and Bluetooth, meant to be
#  installed as /usr/local/bin/void-wireless.  It works with whatever wireless
#  stack is installed:
#
#     * iwd               (iwctl)
#     * NetworkManager    (nmcli)
#     * wpa_supplicant    (plain, config file written by this tool)
#
#  and with BlueZ (bluetoothctl) for Bluetooth.
#
#  Usage:
#     void-wireless                 interactive menu
#     void-wireless --status        show what is connected
#     void-wireless --scan          list nearby Wi-Fi networks
#     void-wireless --connect SSID [password]
#     void-wireless --bt-scan       list nearby Bluetooth devices
#     void-wireless --bt-pair MAC
#     void-wireless --help
#
#  Runs on x86_64, i686, aarch64, armv7hl, armv6hl (Raspberry Pi Zero W) and
#  every other architecture Void Linux supports -- it is plain POSIX sh.
# ============================================================================
VERSION="1.0.0"

ESC=$(printf '\033')
CR=$(printf '\r')
# NB: command substitution strips trailing newlines, so build NL with a
# sentinel and remove it -- plain $(printf '\n') would evaluate to "".
NL=$(printf '\nx'); NL=${NL%x}
QUIET=0
DRY_RUN=0
UI_SAVED_STTY=""
UI_COLS=80
UI_ROWS=24
UI_ITEMS=""
UI_RESULT=""
UI_INDEX=0
UI_LABEL=""
B_TL='+'; B_TR='+'; B_BL='+'; B_BR='+'; B_H='-'; B_V='|'
C_R=""; C_G=""; C_Y=""; C_B=""; C_N=""; C_BOLD=""

# ---------------------------------------------------------------------------
#  logging helpers
# ---------------------------------------------------------------------------
log()  { printf '%s\n' "$*"; }
info() { [ "$QUIET" = 1 ] || printf '  %s*%s %s\n' "$C_B" "$C_N" "$*"; }
ok()   { [ "$QUIET" = 1 ] || printf '  %s+%s %s\n' "$C_G" "$C_N" "$*"; }
warn() { [ "$QUIET" = 1 ] || printf '  %s!%s %s\n' "$C_Y" "$C_N" "$*" >&2; }
err()  { printf '  %sx%s %s\n' "$C_R" "$C_N" "$*" >&2; }
die()  { err "$*"; exit 1; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
#  tiny text UI (same idea as ToolKit.sh, kept self contained)
# ---------------------------------------------------------------------------
ui_raw_on()  { stty raw -echo 2>/dev/null || true; }
ui_raw_off() {
    if [ -n "$UI_SAVED_STTY" ]; then
        stty "$UI_SAVED_STTY" 2>/dev/null || stty sane 2>/dev/null || true
    else
        stty sane 2>/dev/null || true
    fi
}

ui_init() {
    UI_SAVED_STTY="$(stty -g 2>/dev/null || true)"
    UI_COLS="$(stty size 2>/dev/null | awk '{print $2}')"
    UI_ROWS="$(stty size 2>/dev/null | awk '{print $1}')"
    [ -n "$UI_COLS" ] || UI_COLS=80
    [ -n "$UI_ROWS" ] || UI_ROWS=24
    [ "$UI_COLS" -ge 60 ] || UI_COLS=60
    case "$LC_ALL$LANG" in *UTF-8*|*utf8*)
        B_TL='┌'; B_TR='┐'; B_BL='└'; B_BR='┘'; B_H='─'; B_V='│' ;;
    esac
    trap 'ui_restore; exit 130' INT TERM HUP
    printf '%s[?1049h%s[?25l' "$ESC" "$ESC" >/dev/tty 2>/dev/null || true
    ui_clear
}

ui_restore() {
    printf '%s[?25h%s[?1049l' "$ESC" "$ESC" >/dev/tty 2>/dev/null || true
    ui_raw_off
    trap - INT TERM HUP 2>/dev/null || true
}

ui_clear() { printf '%s[H%s[2J' "$ESC" "$ESC" >/dev/tty 2>/dev/null || true; }
ui_goto()  { printf '%s[%d;%dH' "$ESC" "$2" "$1" >/dev/tty 2>/dev/null || true; }

ui_header() {
    _w="$UI_COLS"
    _t="void-wireless $VERSION"
    printf '%s' "$B_TL"
    _i=0; while [ "$_i" -lt $((_w-2)) ]; do printf '%s' "$B_H"; _i=$((_i+1)); done
    printf '%s\n' "$B_TR"
    _pad=$(( (_w - 2 - ${#_t}) / 2 ))
    _rpad=$(( _w - 2 - ${#_t} - _pad ))
    printf '%s%*s%s%s%s%*s%s\n' "$B_V" "$_pad" "" "$C_BOLD" "$_t" "$C_N" "$_rpad" "" "$B_V"
    printf '%s' "$B_BL"
    _i=0; while [ "$_i" -lt $((_w-2)) ]; do printf '%s' "$B_H"; _i=$((_i+1)); done
    printf '%s\n' "$B_BR"
    if [ -n "${1:-}" ]; then printf '%s%s%s\n' "$C_BOLD" "$1" "$C_N"; fi
}

ui_footer() {
    ui_goto "$UI_ROWS" 1
    printf '%s[7m%*s%s[0m' "$ESC" "$UI_COLS" "" >/dev/tty 2>/dev/null || true
    ui_goto "$UI_ROWS" 2
    printf '%s[7m%-*s%s[0m' "$ESC" $((UI_COLS-2)) "${1:-Up/Down move - Enter select - q quit}" >/dev/tty 2>/dev/null || true
}

ui_read_key() {
    KEY="$(dd bs=1 count=1 2>/dev/null </dev/tty; printf 'x')"
    KEY="${KEY%x}"
    if [ "$KEY" = "$ESC" ]; then
        _rest=""
        if [ -n "${BASH_VERSION:-}" ]; then
            IFS= read -r -s -n 2 -t 0.05 _rest 2>/dev/null || _rest=""
        fi
        KEY="$ESC$_rest"
    fi
    case "$KEY" in
        "$ESC"[A*|"$ESC"OA*) KEY="UP" ;;
        "$ESC"[B*|"$ESC"OB*) KEY="DOWN" ;;
        "$ESC")               KEY="ESC" ;;
        "$CR"|"$NL")         KEY="ENTER" ;;
    esac
    return 0
}

ui_select() {
    UI_TITLE="$1"; UI_PROMPT="$2"; _idx="${3:-0}"; _cancel="${4:-1}"
    _n=$(printf '%s\n' "$UI_ITEMS" | grep -c .)
    [ "$_n" -gt 0 ] || return 1
    [ "$_idx" -lt 0 ] && _idx=0
    [ "$_idx" -ge "$_n" ] && _idx=$((_n-1))
    while :; do
        ui_clear
        ui_header "$UI_TITLE"
        printf '%s\n' "$UI_PROMPT"
        printf '\n'
        _i=0
        printf '%s\n' "$UI_ITEMS" | while IFS= read -r _item; do
            [ -n "$_item" ] || continue
            _label="${_item%%|*}"
            if [ "$_i" -eq "$_idx" ]; then
                printf '%s[7m %2d) %-*s %s[0m\n' "$ESC" $((_i+1)) $((UI_COLS-7)) "$_label" "$ESC"
            else
                printf '  %2d) %-*s \n' $((_i+1)) $((UI_COLS-7)) "$_label"
            fi
            _i=$((_i+1))
        done
        printf '\n'
        ui_footer
        ui_raw_on; ui_read_key; ui_raw_off
        case "$KEY" in
            UP|k|K)   [ "$_idx" -gt 0 ] && _idx=$((_idx-1)) ;;
            DOWN|j|J) [ "$_idx" -lt $((_n-1)) ] && _idx=$((_idx+1)) ;;
            ENTER)    break ;;
            HOME|g)   _idx=0 ;;
            END|G)    _idx=$((_n-1)) ;;
            ESC|q|Q)  ui_clear; return "$_cancel" ;;
            [0-9])
                _num="$KEY"
                while [ ${#_num} -lt 3 ]; do
                    ui_raw_on; ui_read_key; ui_raw_off
                    case "$KEY" in
                        [0-9]) _num="$_num$KEY" ;;
                        ENTER) break ;;
                        *) break ;;
                    esac
                done
                case "$_num" in *[!0-9]*) continue ;; esac
                if [ "$_num" -ge 1 ] && [ "$_num" -le "$_n" ]; then
                    _idx=$((_num-1)); break
                fi ;;
        esac
    done
    UI_INDEX=$_idx
    UI_LABEL="$(printf '%s\n' "$UI_ITEMS" | sed -n "$((_idx+1))p" | cut -d'|' -f1)"
    UI_RESULT="$(printf '%s\n' "$UI_ITEMS" | sed -n "$((_idx+1))p" | cut -s -d'|' -f2-)"
    [ -n "$UI_RESULT" ] || UI_RESULT="$UI_LABEL"
    ui_clear
    return 0
}

ui_ask() {
    printf '%s\n' "$1"
    printf '  [%s]: ' "$2"
    IFS= read -r _ans </dev/tty 2>/dev/null || _ans=""
    [ -n "$_ans" ] || _ans="$2"
    eval "$3=\$_ans"
    printf '\n'
}

ui_ask_password() {
    printf '%s\n' "$1"
    printf '  (input hidden): '
    stty -echo 2>/dev/null || true
    IFS= read -r _ans </dev/tty 2>/dev/null || _ans=""
    stty echo 2>/dev/null || true
    printf '\n'
    eval "$2=\$_ans"
}

ui_pause() {
    printf '\n  Press Enter to continue...'
    IFS= read -r _ </dev/tty 2>/dev/null || true
}

ui_msg() {
    ui_clear
    ui_header "Message"
    printf '%s\n' "$1"
    ui_pause
}

set_items_from_lines() {
    # build $UI_ITEMS from newline separated "label|value" lines without
    # losing the assignment in a pipeline subshell
    UI_ITEMS=""
    _f="$(mktemp 2>/dev/null || echo /tmp/.void-wireless.items.$$)"
    printf '%s\n' "$1" >"$_f" 2>/dev/null || true
    while IFS= read -r _l; do
        [ -n "$_l" ] || continue
        UI_ITEMS="$UI_ITEMS
$_l"
    done <"$_f"
    rm -f "$_f" 2>/dev/null || true
    UI_ITEMS="$(printf '%s\n' "$UI_ITEMS" | sed '/^$/d')"
}

# ---------------------------------------------------------------------------
#  network helpers
# ---------------------------------------------------------------------------
all_ifaces() {
    if has_cmd ip; then
        ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v '^lo$'
    elif [ -d /sys/class/net ]; then
        ls /sys/class/net 2>/dev/null | grep -v '^lo$'
    fi
}

wifi_ifaces() {
    if has_cmd iw; then
        iw dev 2>/dev/null | awk '/Interface/{print $2}'
        return 0
    fi
    for _d in /sys/class/net/*; do
        [ -e "$_d/wireless" ] || [ -d "$_d/phy80211" ] || continue
        basename "$_d"
    done
}

first_wifi_iface() {
    printf '%s\n' "$(wifi_ifaces)" | head -n1
}

iface_state() {
    ip -o link show "$1" 2>/dev/null | grep -q 'state UP' && echo up || echo down
}

iface_ip() {
    ip -4 -o addr show dev "$1" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}'
}

wifi_stack() {
    if has_cmd iwctl && [ -S /run/iwd ]; then echo iwd; return 0; fi
    if has_cmd nmcli && nmcli general status >/dev/null 2>&1; then echo NetworkManager; return 0; fi
    if has_cmd wpa_supplicant; then echo wpa_supplicant; return 0; fi
    echo none
}

wifi_scan() {
    # wifi_scan <iface> -> "SSID<TAB>signal<TAB>security"
    _if="${1:-$(first_wifi_iface)}"
    [ -n "$_if" ] || return 1
    ip link set "$_if" up 2>/dev/null || true
    if has_cmd iw; then
        iw dev "$_if" scan 2>/dev/null | awk '
            /^\tBSS /{ if (ssid != "") print ssid "\t" sig "\t" sec; ssid=""; sig=""; sec="open" }
            /^\tSSID:/{ s=$0; sub(/^\tSSID: */,"",s); ssid=s }
            /signal:/{ s=$0; sub(/.*signal: */,"",s); sub(/ dBm.*/,"",s); sig=s }
            /\tRSN:/{ sec="secured" }
            /\tWPA:/{ sec="secured" }
            END{ if (ssid != "") print ssid "\t" sig "\t" sec }'
    elif has_cmd iwctl; then
        iwctl station "$_if" get-networks 2>/dev/null | awk 'NR>4 && $1!="" {print $1 "\t-\t-"}'
    elif has_cmd nmcli; then
        nmcli -t -f SSID,SIGNAL,SECURITY dev wifi list ifname "$_if" 2>/dev/null
    fi
}

wifi_status() {
    _if="${1:-$(first_wifi_iface)}"
    printf 'Wireless interface : %s\n' "${_if:-none}"
    if [ -z "$_if" ]; then return 0; fi
    printf 'State               : %s\n' "$(iface_state "$_if")"
    printf 'IP address          : %s\n' "$(iface_ip "$_if")"
    _stack="$(wifi_stack)"
    printf 'Wireless stack      : %s\n' "$_stack"
    case "$_stack" in
        iwd)
            iwctl station "$_if" show 2>/dev/null | sed 's/^/  /'
            ;;
        NetworkManager)
            nmcli -t -f NAME,TYPE,DEVICE con show --active 2>/dev/null | sed 's/^/  /'
            ;;
        wpa_supplicant)
            if [ -S /run/wpa_supplicant/$_if ] && has_cmd wpa_cli; then
                wpa_cli -i "$_if" status 2>/dev/null | grep -E '^(ssid|wpa_state|ip_address)=' | sed 's/^/  /'
            fi
            ;;
    esac
}

wifi_connect() {
    # wifi_connect <ssid> [password] [iface]
    _ssid="$1"; _pass="$2"; _if="${3:-$(first_wifi_iface)}"
    [ -n "$_ssid" ] || { warn "no SSID given"; return 1; }
    [ -n "$_if" ] || { warn "no wireless interface found"; return 1; }
    info "connecting to '$_ssid' on $_if ..."
    _stack="$(wifi_stack)"
    case "$_stack" in
        iwd)
            if [ -n "$_pass" ]; then
                iwctl --passphrase "$_pass" station "$_if" connect "$_ssid"
            else
                iwctl station "$_if" connect "$_ssid"
            fi
            ;;
        NetworkManager)
            if [ -n "$_pass" ]; then
                nmcli dev wifi connect "$_ssid" password "$_pass" ifname "$_if"
            else
                nmcli dev wifi connect "$_ssid" ifname "$_if"
            fi
            ;;
        *)
            write_wpa_config "$_ssid" "$_pass"
            restart_service wpa_supplicant
            ;;
    esac
    sleep 3
    if [ -n "$(iface_ip "$_if")" ]; then
        ok "connected, address $(iface_ip "$_if")"
    else
        warn "no address yet - check with 'void-wireless --status'"
    fi
}

write_wpa_config() {
    _ssid="$1"; _pass="$2"
    if [ "$DRY_RUN" = 1 ]; then
        log "    | write /etc/wpa_supplicant/wpa_supplicant.conf for '$_ssid'"
        return 0
    fi
    [ -w /etc ] || { warn "cannot write /etc/wpa_supplicant (not root?)"; return 1; }
    mkdir -p /etc/wpa_supplicant
    _conf=/etc/wpa_supplicant/wpa_supplicant.conf
    [ -f "$_conf" ] || printf 'ctrl_interface=/run/wpa_supplicant\nupdate_config=1\n' >"$_conf"
    # remove an existing block for this ssid
    awk -v s="$_ssid" '
        BEGIN{ skip=0 }
        /^network=\{/ { if ($0 ~ "ssid=\"" s "\"") { skip=1; next } }
        skip && /^\}/ { skip=0; next }
        !skip { print }
    ' "$_conf" >"$_conf.tmp" 2>/dev/null || cp "$_conf" "$_conf.tmp"
    {
        echo ""
        echo "network={"
        echo "    ssid=\"$_ssid\""
        if [ -n "$_pass" ]; then
            echo "    psk=\"$_pass\""
        else
            echo "    key_mgmt=NONE"
        fi
        echo "}"
    } >>"$_conf.tmp"
    mv "$_conf.tmp" "$_conf"
    chmod 600 "$_conf"
    logf "wrote wpa_supplicant config for $_ssid"
}

logf() { :; }

wifi_saved() {
    _stack="$(wifi_stack)"
    case "$_stack" in
        iwd)
            if [ -d /var/lib/iwd ]; then
                ls /var/lib/iwd/*.psk 2>/dev/null | while read -r f; do
                    basename "$f" .psk
                done
            fi
            ;;
        wpa_supplicant)
            [ -f /etc/wpa_supplicant/wpa_supplicant.conf ] && \
                awk -F'"' '/ssid=/{print $2}' /etc/wpa_supplicant/wpa_supplicant.conf
            ;;
        NetworkManager)
            has_cmd nmcli && nmcli -t -f NAME,TYPE con show 2>/dev/null | awk -F: '$2=="802-11-wireless"{print $1}'
            ;;
    esac
}

wifi_forget() {
    _ssid="$1"
    _stack="$(wifi_stack)"
    case "$_stack" in
        iwd) rm -f "/var/lib/iwd/$_ssid.psk" 2>/dev/null || true ;;
        NetworkManager) has_cmd nmcli && nmcli con delete "$_ssid" >/dev/null 2>&1 || true ;;
        *)
            if [ -f /etc/wpa_supplicant/wpa_supplicant.conf ]; then
                awk -v s="$_ssid" '
                    /^network=\{/ { skip=0; if ($0 ~ "ssid=\"" s "\"") { skip=1; next } }
                    skip && /^\}/ { skip=0; next }
                    !skip { print }' /etc/wpa_supplicant/wpa_supplicant.conf >/etc/wpa_supplicant/wpa_supplicant.conf.new
                mv /etc/wpa_supplicant/wpa_supplicant.conf.new /etc/wpa_supplicant/wpa_supplicant.conf
            fi
            ;;
    esac
    restart_service wpa_supplicant 2>/dev/null || true
    ok "forgot '$_ssid'"
}

# ---------------------------------------------------------------------------
#  bluetooth helpers
# ---------------------------------------------------------------------------
bt_controllers() {
    has_cmd bluetoothctl || return 0
    bluetoothctl list 2>/dev/null | awk '/^Controller/{print $2}'
}

bt_power() {
    has_cmd bluetoothctl || { warn "bluetoothctl not installed (install the 'bluez' package)"; return 1; }
    bluetoothctl power "$1" >/dev/null 2>&1
    bluetoothctl "$([ "$1" = on ] && echo discoverable-on || echo discoverable-off)" >/dev/null 2>&1 || true
}

bt_scan() {
    has_cmd bluetoothctl || { warn "bluetoothctl not installed (install the 'bluez' package)"; return 1; }
    bluetoothctl power on >/dev/null 2>&1 || true
    bluetoothctl scan on >/dev/null 2>&1 || true
    info "scanning for 8 seconds..."
    sleep 8
    bluetoothctl scan off >/dev/null 2>&1 || true
    bluetoothctl devices 2>/dev/null | sed 's/^Device //'
}

bt_devices() {
    has_cmd bluetoothctl || return 0
    bluetoothctl devices 2>/dev/null | sed 's/^Device //'
}

bt_info() {
    _mac="$1"
    has_cmd bluetoothctl || return 0
    bluetoothctl info "$_mac" 2>/dev/null
}

bt_pair() {
    _mac="$1"
    has_cmd bluetoothctl || return 1
    bluetoothctl power on >/dev/null 2>&1 || true
    bluetoothctl pair "$_mac"
    bluetoothctl trust "$_mac" >/dev/null 2>&1 || true
    bluetoothctl connect "$_mac" >/dev/null 2>&1 || true
}

bt_remove() {
    _mac="$1"
    has_cmd bluetoothctl || return 1
    bluetoothctl remove "$_mac"
}

# ---------------------------------------------------------------------------
#  services
# ---------------------------------------------------------------------------
service_enabled() {
    [ -e "/var/service/$1" ] || [ -e "/run/runit/service/$1" ]
}

toggle_service() {
    _s="$1"
    if service_enabled "$_s"; then
        rm -f "/var/service/$_s" "/run/runit/service/$_s" 2>/dev/null || true
        ok "disabled service $_s"
    else
        if [ ! -d "/etc/sv/$_s" ]; then
            warn "service $_s is not installed"
            return 1
        fi
        ln -sfn "/etc/sv/$_s" "/var/service/$_s" 2>/dev/null || true
        ok "enabled service $_s"
    fi
}

restart_service() {
    _s="$1"
    if has_cmd sv; then
        sv restart "$_s" >/dev/null 2>&1 || true
    fi
}

# ---------------------------------------------------------------------------
#  screens
# ---------------------------------------------------------------------------
screen_status() {
    ui_clear
    ui_header "Status"
    printf 'Network interfaces\n'
    printf '------------------\n'
    for _i in $(all_ifaces); do
        printf '  %-12s %-6s %s\n' "$_i" "$(iface_state "$_i")" "$(iface_ip "$_i")"
    done
    printf '\n'
    wifi_status
    printf '\nBluetooth\n'
    printf '---------\n'
    if has_cmd bluetoothctl; then
        _macs="$(bt_controllers)"
        if [ -n "$_macs" ]; then
            printf '%s\n' "$_macs" | while read -r _m; do
                [ -n "$_m" ] || continue
                printf '  controller %s\n' "$_m"
                bluetoothctl show "$_m" 2>/dev/null | grep -E 'Name|Powered|Discoverable|Discovering' | sed 's/^/    /'
            done
        else
            printf '  no Bluetooth controller found\n'
        fi
    else
        printf '  bluetoothctl not installed\n'
    fi
    ui_pause
}

screen_wifi() {
    while :; do
        UI_ITEMS="Scan and connect to a network|scan
Show Wi-Fi status|status
Forget a saved network|forget
Rescan|rescan
Back|back"
        ui_select "Wi-Fi" "Wireless interface: $(first_wifi_iface)   stack: $(wifi_stack)" 0 || return 0
        case "$UI_RESULT" in
            scan) screen_wifi_scan ;;
            status) screen_status ;;
            forget) screen_wifi_forget ;;
            rescan) : ;;
            back) return 0 ;;
        esac
    done
}

screen_wifi_scan() {
    _if="$(first_wifi_iface)"
    if [ -z "$_if" ]; then ui_msg "No wireless interface found."; return 0; fi
    info "scanning $_if ..."
    _list="$(wifi_scan "$_if")"
    if [ -z "$_list" ]; then
        ui_msg "No networks found on $_if. Check that the radio is not blocked: rfkill unblock all"
        return 0
    fi
    _items=""
    _f="$(mktemp 2>/dev/null || echo /tmp/.void-wireless.ap.$$)"
    printf '%s\n' "$_list" >"$_f"
    while IFS="$(printf '\t')" read -r _ssid _sig _sec; do
        [ -n "$_ssid" ] || continue
        _items="$_items
$_ssid ($_sig dBm, $_sec)|$_ssid"
    done <"$_f"
    rm -f "$_f"
    set_items_from_lines "$_items"
    ui_select "Networks" "Choose a network" 0 || return 0
    _ssid="$UI_RESULT"
    _pass=""
    if printf '%s\n' "$_list" | awk -F'\t' -v s="$_ssid" '$1==s && $3=="secured"{f=1} END{exit !f}'; then
        ui_ask_password "Password for '$_ssid'" _pass
    fi
    wifi_connect "$_ssid" "$_pass" "$_if"
    ui_pause
}

screen_wifi_forget() {
    _saved="$(wifi_saved)"
    if [ -z "$_saved" ]; then ui_msg "No saved networks."; return 0; fi
    _items=""
    _f="$(mktemp 2>/dev/null || echo /tmp/.void-wireless.saved.$$)"
    printf '%s\n' "$_saved" >"$_f"
    while IFS= read -r _s; do
        [ -n "$_s" ] || continue
        _items="$_items
$_s|$_s"
    done <"$_f"
    rm -f "$_f"
    set_items_from_lines "$_items"
    ui_select "Saved networks" "Which network should be forgotten?" 0 || return 0
    wifi_forget "$UI_RESULT"
    ui_pause
}

screen_bluetooth() {
    while :; do
        UI_ITEMS="Scan for devices|scan
Paired / known devices|devices
Bluetooth status|status
Power on|on
Power off|off
Back|back"
        ui_select "Bluetooth" "Controller: $(bt_controllers | head -n1)" 0 || return 0
        case "$UI_RESULT" in
            scan) screen_bt_scan ;;
            devices) screen_bt_devices ;;
            status) screen_status ;;
            on) bt_power on ;;
            off) bt_power off ;;
            back) return 0 ;;
        esac
    done
}

screen_bt_scan() {
    _devices="$(bt_scan)"
    if [ -z "$_devices" ]; then ui_msg "No devices found."; return 0; fi
    _items=""
    _f="$(mktemp 2>/dev/null || echo /tmp/.void-wireless.bt.$$)"
    printf '%s\n' "$_devices" >"$_f"
    while IFS= read -r _d; do
        [ -n "$_d" ] || continue
        _mac="${_d%% *}"
        _name="${_d#* }"
        _items="$_items
$_name ($_mac)|$_mac"
    done <"$_f"
    rm -f "$_f"
    set_items_from_lines "$_items"
    ui_select "Devices" "Which device do you want to pair with?" 0 || return 0
    bt_pair "$UI_RESULT"
    ui_pause
}

screen_bt_devices() {
    _devices="$(bt_devices)"
    if [ -z "$_devices" ]; then ui_msg "No known devices."; return 0; fi
    _items=""
    _f="$(mktemp 2>/dev/null || echo /tmp/.void-wireless.btd.$$)"
    printf '%s\n' "$_devices" >"$_f"
    while IFS= read -r _d; do
        [ -n "$_d" ] || continue
        _mac="${_d%% *}"
        _name="${_d#* }"
        _items="$_items
$_name ($_mac)|$_mac"
    done <"$_f"
    rm -f "$_f"
    set_items_from_lines "$_items"
    ui_select "Devices" "Choose a device" 0 || return 0
    _mac="$UI_RESULT"
    ui_clear
    ui_header "Device"
    bt_info "$_mac"
    printf '\n'
    UI_ITEMS="Connect|connect
Trust|trust
Remove|remove
Back|back"
    ui_select "Action" "What do you want to do with $_mac?" 0 || return 0
    case "$UI_RESULT" in
        connect) bluetoothctl connect "$_mac" ;;
        trust)   bluetoothctl trust "$_mac" ;;
        remove)  bt_remove "$_mac" ;;
    esac
    ui_pause
}

screen_services() {
    while :; do
        _ws="disabled"; service_enabled wpa_supplicant && _ws="enabled"
        _is="disabled"; service_enabled iwd && _is="enabled"
        _nm="disabled"; service_enabled NetworkManager && _nm="enabled"
        _bt="disabled"; service_enabled bluetoothd && _bt="enabled"
        UI_ITEMS="wpa_supplicant - $_ws|wpa_supplicant
iwd - $_is|iwd
NetworkManager - $_nm|NetworkManager
bluetoothd - $_bt|bluetoothd
Back|back"
        ui_select "Services" "Toggle a service (runit)" 0 || return 0
        case "$UI_RESULT" in
            back) return 0 ;;
            *) toggle_service "$UI_RESULT" ;;
        esac
    done
}

screen_static_ip() {
    ui_clear
    ui_header "Static IP"
    printf 'This writes a static configuration for dhcpcd.\n\n'
    _if="$(first_wifi_iface)"
    [ -n "$_if" ] || _if="$(all_ifaces | head -n1)"
    ui_ask "Interface" "$_if" _if
    ui_ask "IP address with prefix (e.g. 192.168.1.50/24)" "" _ip
    ui_ask "Gateway (e.g. 192.168.1.1)" "" _gw
    ui_ask "DNS server (e.g. 192.168.1.1)" "" _dns
    [ -n "$_ip" ] || { warn "no address given"; return 0; }
    if [ "$DRY_RUN" = 1 ]; then
        log "    | static $_ip on $_if"
        return 0
    fi
    [ -w /etc ] || { warn "cannot write /etc/dhcpcd.conf (not root?)"; return 1; }
    {
        echo "# written by void-wireless"
        echo "interface $_if"
        echo "static ip_address=$_ip"
        [ -n "$_gw" ] && echo "static routers=$_gw"
        [ -n "$_dns" ] && echo "static domain_name_servers=$_dns"
    } >/etc/dhcpcd.conf
    restart_service dhcpcd
    ok "static configuration written"
}

main_menu() {
    while :; do
        UI_ITEMS="Wi-Fi - scan and connect|wifi
Wi-Fi - status and saved networks|wstatus
Bluetooth - scan and pair|bt
Bluetooth - status|bstatus
Static IP address|static
Services (enable/disable)|services
Refresh|refresh
Quit|quit"
        ui_select "void-wireless" "What do you want to configure?" 0 || return 0
        case "$UI_RESULT" in
            wifi) screen_wifi ;;
            wstatus) screen_status ;;
            bt) screen_bluetooth ;;
            bstatus) screen_status ;;
            static) screen_static_ip ;;
            services) screen_services ;;
            refresh) : ;;
            quit) return 0 ;;
        esac
    done
}

usage() {
    cat <<EOF
void-wireless $VERSION - Wi-Fi and Bluetooth settings for Void Linux

Usage:
  void-wireless                 interactive text menu
  void-wireless --status        show interfaces, Wi-Fi and Bluetooth status
  void-wireless --scan          list nearby Wi-Fi networks
  void-wireless --connect SSID [password]
  void-wireless --bt-scan       list nearby Bluetooth devices
  void-wireless --bt-pair MAC   pair, trust and connect a device
  void-wireless --services      toggle wireless/bluetooth services
  void-wireless --help          this help

Works with iwd (iwctl), NetworkManager (nmcli) or plain wpa_supplicant, and
with BlueZ (bluetoothctl).  Runs on every architecture Void Linux supports,
including armv6hl boards like the Raspberry Pi Zero W.
EOF
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --status)   ACTION=status; shift ;;
            --scan)     ACTION=scan; shift ;;
            --connect)  ACTION=connect; shift ;;
            --bt-scan)  ACTION=btscan; shift ;;
            --bt-pair)  ACTION=btpair; shift ;;
            --services) ACTION=services; shift ;;
            --help|-h)  usage; exit 0 ;;
            --version)  echo "void-wireless $VERSION"; exit 0 ;;
            --dry-run)  DRY_RUN=1; shift ;;
            --no-color) shift ;;
            *)          ACTION=""; break ;;
        esac
    done

    if [ -t 1 ]; then
        C_R="${ESC}[1;31m"; C_G="${ESC}[1;32m"; C_Y="${ESC}[1;33m"; C_B="${ESC}[1;34m"; C_N="${ESC}[0m"; C_BOLD="${ESC}[1m"
    fi

    case "${ACTION:-}" in
        status)
            for _i in $(all_ifaces); do
                printf '%-12s %-6s %s\n' "$_i" "$(iface_state "$_i")" "$(iface_ip "$_i")"
            done
            echo "---"
            wifi_status
            echo "---"
            bt_devices
            exit 0
            ;;
        scan)
            wifi_scan
            exit 0
            ;;
        connect)
            wifi_connect "${1:-}" "${2:-}"
            exit $?
            ;;
        btscan)
            bt_scan
            exit 0
            ;;
        btpair)
            bt_pair "${1:-}"
            exit $?
            ;;
        services)
            screen_services
            exit 0
            ;;
    esac

    if [ ! -t 0 ] || [ ! -t 1 ]; then
        die "no terminal - use one of --status, --scan, --connect, --bt-scan, --bt-pair"
    fi

    ui_init
    main_menu
    ui_restore
}

main "$@"
