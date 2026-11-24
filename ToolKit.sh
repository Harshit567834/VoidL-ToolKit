#!/bin/sh
# ============================================================================
#  VoidL ToolKit  --  first-boot configurator for Void Linux
#  ----------------------------------------------------------------------------
#  Drop this file anywhere on the machine (e.g. /boot/VoidL-ToolKit.sh), make
#  it executable and run it as root *after* Void Linux has been installed:
#
#      sudo sh /boot/VoidL-ToolKit.sh
#
#  It is deliberately one self-contained file: no libraries, no python, no
#  dialog, no whiptail.  Everything it needs (a text UI, the Void package
#  names, runit service handling, Wi-Fi/Bluetooth, USB gadget mode) lives in
#  here so it can be copied onto a boot partition and just work.
#
#  Supported machines: x86_64, i686, aarch64, armv7hl, armv6hl (Raspberry Pi
#  Zero/Zero W/1), riscv64, ppc64/ppc64le, s390x and anything else Void runs
#  on.  Nothing here is architecture specific except the package/kernel
#  selection, which is detected from `uname -m`.
#
#  Licence: MIT
# ============================================================================
VERSION="1.0.0"

# ---------------------------------------------------------------------------
#  Globals
# ---------------------------------------------------------------------------
ROOT="/"                 # target root filesystem (changed by --root)
DRY_RUN=0                # --dry-run : print the plan, change nothing
INTERACTIVE=0            # 1 when we have a usable terminal
YES=0                    # --yes : accept every default
FORCE=0                  # --force : skip the "is this an installed system" guard
NO_INSTALL=0             # --no-install : never call xbps-install (testing)
NO_COLOR=0
ANSWERS_FILE=""
LOG_FILE=""
QUIET=0

# answers (see README for the full list)
A_DEVICE="auto"          A_HOSTNAME="void"        A_LOCALE=""      A_TIMEZONE="UTC"
A_KEYMAP="us"            A_USERNAME=""            A_USER_PASSWORD=""  A_USER_FULLNAME=""
A_USER_GROUPS=""         A_SUDO="yes"
A_DESKTOP="none"         A_DISPLAY_MANAGER="none" A_AUTOLOGIN="no"  A_AUTOLOGIN_USER=""
A_NET_MODE="ethernet"    A_NET_SERVICE="dhcpcd"   A_WIFI_SSID=""    A_WIFI_PASSWORD=""
A_WIFI_IFACE=""          A_WIFI_HIDDEN="no"       A_WIFI_STACK="wpa_supplicant"
A_STATIC_IP=""           A_STATIC_GATEWAY=""      A_STATIC_DNS=""
A_BLUETOOTH="no"         A_BLUETOOTH_ADAPTER=""
A_SWAP_MODE="none"       A_SWAP_SIZE="2048"
A_SSH="no"               A_SSH_PORT="22"          A_SSH_ROOT_LOGIN="no"  A_SSH_PASSWORD_AUTH="yes"
A_VNC="no"               A_VNC_MODE="virtual"     A_VNC_PASSWORD=""   A_VNC_GEOMETRY="1280x800"
A_VNC_DISPLAY="1"        A_REMOTE_MODE="lan"      A_IP_BANNER="yes"
A_KERNEL="linux"         A_FIRMWARE="yes"         A_MICROCODE="auto"
A_EXTRAS=""              A_GIT_URL="https://github.com/Harshit567834/VoidL-ToolKit.git"
A_GIT_BRANCH="main"      A_SKIP_FETCH="no"
A_KEYBOARD_LAYOUT=""     A_XKB_MODEL=""           A_XKB_OPTIONS=""

# detected hardware / system
D_ARCH=""                D_ARCH_FAMILY=""  D_MACHINE=""
D_CPU_VENDOR=""          D_MEM_MB=""       D_ROOT_FSTYPE=""  D_IS_RPI=0
D_RPI_MODEL=""           D_MUSL=0          D_NET_IFACES=""
D_DEFAULT_IFACE=""       D_WIFI_IFACES=""  D_BT_ADAPTERS=""

# ui state
UI_SAVED_STTY=""         UI_COLS=80        UI_ROWS=24        UI_UTF8=0
UI_ITEMS=""              UI_RESULT=""      UI_INDEX=0        UI_LABEL=""
ESC=$(printf '\033')
CR=$(printf '\r')
# NB: command substitution strips trailing newlines, so build NL with a
# sentinel and remove it -- plain $(printf '\n') would evaluate to "".
NL=$(printf '\nx'); NL=${NL%x}
B_TL='+'; B_TR='+'; B_BL='+'; B_BR='+'; B_H='-'; B_V='|'

# colours (empty when disabled)
C_R=""; C_G=""; C_Y=""; C_B=""; C_N=""; C_BOLD=""

# ---------------------------------------------------------------------------
#  Logging
# ---------------------------------------------------------------------------
log()  { printf '%s\n' "$*"; }
info() { [ "$QUIET" = 1 ] || printf '  %s*%s %s\n' "$C_B" "$C_N" "$*"; }
ok()   { [ "$QUIET" = 1 ] || printf '  %s+%s %s\n' "$C_G" "$C_N" "$*"; }
warn() { [ "$QUIET" = 1 ] || printf '  %s!%s %s\n' "$C_Y" "$C_N" "$*" >&2; }
err()  { printf '  %sx%s %s\n' "$C_R" "$C_N" "$*" >&2; }
die()  { err "$*"; exit 1; }

logf() {
    [ -n "$LOG_FILE" ] || return 0
    printf '%s\n' "$*" >>"$LOG_FILE" 2>/dev/null || true
}

run() {
    if [ "$DRY_RUN" = 1 ]; then
        log "    | $*"
        return 0
    fi
    logf "# $*"
    "$@"
}

run_sh() {
    if [ "$DRY_RUN" = 1 ]; then
        log "    | $*"
        return 0
    fi
    logf "# $*"
    sh -c "$*"
}

# ---------------------------------------------------------------------------
#  Small utilities
# ---------------------------------------------------------------------------
has_cmd() { command -v "$1" >/dev/null 2>&1; }
rpath()   { printf '%s%s' "${ROOT%/}" "$1"; }

write_file() {
    # write_file <path> <mode>   (content on stdin)
    _p="$1"; _m="${2:-0644}"
    _full="$(rpath "$_p")"
    if [ "$DRY_RUN" = 1 ]; then
        log "    | write $_full (mode $_m)"
        cat >/dev/null
        return 0
    fi
    mkdir -p "$(dirname "$_full")" 2>/dev/null || { warn "cannot create $(dirname "$_full")"; cat >/dev/null; return 1; }
    cat >"$_full" || return 1
    chmod "$_m" "$_full" 2>/dev/null || true
    logf "wrote $_full"
}

append_unique() {
    _f="$(rpath "$1")"; _l="$2"
    if [ "$DRY_RUN" = 1 ]; then
        log "    | ensure '$_l' in $_f"
        return 0
    fi
    mkdir -p "$(dirname "$_f")" 2>/dev/null || return 1
    touch "$_f" 2>/dev/null || return 1
    grep -qxF "$_l" "$_f" 2>/dev/null && return 0
    printf '%s\n' "$_l" >>"$_f"
    logf "appended to $_f: $_l"
}

mem_mb() {
    _m="$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)"
    [ -n "$_m" ] || _m=0
    printf '%s' "$_m"
}

is_number() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# ---------------------------------------------------------------------------
#  Detection
# ---------------------------------------------------------------------------
detect_arch() {
    _m="$(uname -m 2>/dev/null || echo unknown)"
    case "$_m" in
        x86_64|amd64)                D_ARCH="x86_64";   D_ARCH_FAMILY="x86" ;;
        i386|i486|i586|i686)         D_ARCH="i686";     D_ARCH_FAMILY="x86" ;;
        aarch64|arm64|armv8*)        D_ARCH="aarch64";  D_ARCH_FAMILY="arm" ;;
        armv7*)                      D_ARCH="armv7hl";  D_ARCH_FAMILY="arm" ;;
        armv6*)                      D_ARCH="armv6hl";  D_ARCH_FAMILY="arm" ;;
        riscv64)                     D_ARCH="riscv64";  D_ARCH_FAMILY="riscv" ;;
        ppc64le)                     D_ARCH="ppc64le";  D_ARCH_FAMILY="ppc" ;;
        ppc64|ppc)                   D_ARCH="ppc64";    D_ARCH_FAMILY="ppc" ;;
        s390x)                       D_ARCH="s390x";    D_ARCH_FAMILY="s390" ;;
        loongarch64)                 D_ARCH="loongarch64"; D_ARCH_FAMILY="loongarch" ;;
        *)                           D_ARCH="$_m";     D_ARCH_FAMILY="other" ;;
    esac
    # musl vs glibc: decided by the installed libc, not by uname.
    # A glibc system always has an ld-linux-*.so.2 loader, so check for it
    # first -- otherwise a stray musl loader would be misdetected.
    D_MUSL=1
    for _l in /lib/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2 \
              /lib/ld-linux-aarch64.so.1 /lib/ld-linux-armhf.so.3 \
              /lib/ld-linux-riscv64-lp64d.so.1 /lib/ld64.so.1 /lib/ld64.so.2; do
        if [ -e "$_l" ]; then D_MUSL=0; break; fi
        if [ "$ROOT" != "/" ] && [ -e "$(rpath "$_l")" ]; then D_MUSL=0; break; fi
    done
}

detect_machine() {
    _model=""
    for _f in /proc/device-tree/model /sys/firmware/devicetree/base/model; do
        if [ -r "$_f" ]; then
            _model="$(tr -d '\0' <"$_f" 2>/dev/null)"
            break
        fi
    done
    if [ -z "$_model" ] && [ -r /proc/cpuinfo ]; then
        _model="$(awk -F': *' '/^(model name|Model|Hardware|Revision)/{print $2; exit}' /proc/cpuinfo 2>/dev/null)"
    fi
    D_MACHINE="$_model"
    D_IS_RPI=0
    D_RPI_MODEL=""
    case "$_model" in
        *Raspberry\ Pi*)
            D_IS_RPI=1
            D_RPI_MODEL="$_model"
            case "$_model" in
                *Zero*2*) D_RPI_MODEL="Raspberry Pi Zero 2 W" ;;
                *Zero*)   D_RPI_MODEL="Raspberry Pi Zero W" ;;
                *Pi\ 5*)  D_RPI_MODEL="Raspberry Pi 5" ;;
                *Pi\ 4*)  D_RPI_MODEL="Raspberry Pi 4" ;;
                *Pi\ 3*)  D_RPI_MODEL="Raspberry Pi 3" ;;
                *Pi\ 2*)  D_RPI_MODEL="Raspberry Pi 2" ;;
                *)        D_RPI_MODEL="Raspberry Pi 1" ;;
            esac
            ;;
    esac
}

detect_cpu() {
    if [ -r /proc/cpuinfo ]; then
        D_CPU_VENDOR="$(awk -F': *' '/^vendor_id/{print $2; exit}' /proc/cpuinfo 2>/dev/null)"
        [ -n "$D_CPU_VENDOR" ] || D_CPU_VENDOR="$(awk -F': *' '/^model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null)"
    fi
    case "$D_CPU_VENDOR" in
        *AuthenticAMD*|*AMD*)   D_CPU_VENDOR="amd" ;;
        *GenuineIntel*|*Intel*) D_CPU_VENDOR="intel" ;;
        *)                      D_CPU_VENDOR="other" ;;
    esac
}

detect_system() {
    D_MEM_MB="$(mem_mb)"
    D_ROOT_FSTYPE="$(awk '$2=="/" && $3!="" {print $3; exit}' /proc/mounts 2>/dev/null)"
    [ -n "$D_ROOT_FSTYPE" ] || D_ROOT_FSTYPE="unknown"
    detect_net_ifaces
}

detect_net_ifaces() {
    D_NET_IFACES=""
    D_WIFI_IFACES=""
    if has_cmd ip; then
        D_NET_IFACES="$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v '^lo$' | tr '\n' ' ')"
    fi
    if has_cmd iw; then
        D_WIFI_IFACES="$(iw dev 2>/dev/null | awk '/Interface/{print $2}' | tr '\n' ' ')"
    fi
    if [ -z "$D_WIFI_IFACES" ] && [ -d /sys/class/net ]; then
        for _d in /sys/class/net/*; do
            if [ -e "$_d/wireless" ] || [ -d "$_d/phy80211" ]; then
                D_WIFI_IFACES="$D_WIFI_IFACES$(basename "$_d") "
            fi
        done
    fi
    D_DEFAULT_IFACE="$(printf '%s' "$D_NET_IFACES" | awk '{print $1}')"
    if [ -n "$D_WIFI_IFACES" ]; then
        D_DEFAULT_IFACE="$(printf '%s' "$D_WIFI_IFACES" | awk '{print $1}')"
    fi
    D_BT_ADAPTERS=""
    if has_cmd bluetoothctl; then
        D_BT_ADAPTERS="$(bluetoothctl list 2>/dev/null | awk '/^Controller/{print $2}' | tr '\n' ' ')"
    fi
}

is_installed_system() {
    # The live ISO runs from squashfs/overlay/tmpfs.  An installed system runs
    # from a real block device.  Refuse to configure a live environment.
    case "$D_ROOT_FSTYPE" in
        squashfs|overlay|tmpfs|romfs|aufs|zisofs) return 1 ;;
    esac
    has_cmd xbps-install || return 1
    if [ "$ROOT" != "/" ]; then return 0; fi
    [ -d /etc/xbps.d ] || [ -d /var/db/xbps/keys ] || return 1
    return 0
}

# ---------------------------------------------------------------------------
#  Text UI engine (pure sh, no dialog/whiptail)
# ---------------------------------------------------------------------------
ui_supported() {
    [ -t 0 ] && [ -t 1 ] || return 1
    [ -r /dev/tty ] && [ -w /dev/tty ] || return 1
    return 0
}

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
    case "$LC_ALL$LANG" in *UTF-8*|*utf8*) UI_UTF8=1 ;; esac
    if [ "$UI_UTF8" = 1 ]; then
        B_TL='┌'; B_TR='┐'; B_BL='└'; B_BR='┘'; B_H='─'; B_V='│'
    else
        B_TL='+'; B_TR='+'; B_BL='+'; B_BR='+'; B_H='-'; B_V='|'
    fi
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

# Centre $1 inside a field of $2 columns, padding BOTH sides so the returned
# string is always exactly $2 characters wide (that is what keeps the header
# box square).  Extra space goes to the right when the split is uneven.
ui_center() {
    _s="$1"; _w="${2:-$UI_COLS}"
    _l=${#_s}
    if [ "$_l" -ge "$_w" ]; then printf '%s' "$_s"; return 0; fi
    _pad=$(( (_w - _l) / 2 ))
    printf '%*s%s%*s' "$_pad" "" "$_s" "$((_w - _l - _pad))" ""
}

ui_header() {
    _w="$UI_COLS"
    _t="VoidL ToolKit $VERSION"
    printf '%s' "$B_TL"
    _i=0; while [ "$_i" -lt $((_w-2)) ]; do printf '%s' "$B_H"; _i=$((_i+1)); done
    printf '%s\n' "$B_TR"
    printf '%s%s%s\n' "$B_V" "$(ui_center "$_t" $((_w-2)))" "$B_V"
    printf '%s' "$B_BL"
    _i=0; while [ "$_i" -lt $((_w-2)) ]; do printf '%s' "$B_H"; _i=$((_i+1)); done
    printf '%s\n' "$B_BR"
    if [ -n "${1:-}" ]; then
        printf '%s%s%s\n' "$C_BOLD" "$1" "$C_N"
    fi
}

ui_footer() {
    ui_goto "$UI_ROWS" 1
    printf '%s[7m%*s' "$ESC" "$UI_COLS" "" >/dev/tty 2>/dev/null || true
    printf '%s[0m' "$ESC" >/dev/tty 2>/dev/null || true
    _msg="${1:-Up/Down move - Enter select - Esc back}"
    ui_goto "$UI_ROWS" 2
    printf '%s[7m%-*s' "$ESC" $((UI_COLS-2)) "$_msg" >/dev/tty 2>/dev/null || true
    printf '%s[0m' "$ESC" >/dev/tty 2>/dev/null || true
}

set_items_from_lines() {
    # build $UI_ITEMS from newline separated "label|value" lines without
    # losing the assignment in a pipeline subshell
    UI_ITEMS=""
    _f="$(mktemp 2>/dev/null || echo /tmp/.voidl.items.$$)"
    printf '%s\n' "$1" >"$_f" 2>/dev/null || true
    while IFS= read -r _l; do
        [ -n "$_l" ] || continue
        UI_ITEMS="$UI_ITEMS
$_l"
    done <"$_f"
    rm -f "$_f" 2>/dev/null || true
    UI_ITEMS="$(printf '%s\n' "$UI_ITEMS" | sed '/^$/d')"
}

ui_read_key() {
    # read exactly one byte from the terminal; keep trailing newlines by
    # appending a sentinel before the command substitution strips them
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
        "$ESC"[C*|"$ESC"OC*) KEY="RIGHT" ;;
        "$ESC"[D*|"$ESC"OD*) KEY="LEFT" ;;
        "$ESC")               KEY="ESC" ;;
        "$CR"|"$NL")         KEY="ENTER" ;;
    esac
    return 0
}

ui_select() {
    # ui_select <title> <prompt> <default-index> [cancel-code]
    # items: $UI_ITEMS, newline separated "label|value"
    UI_TITLE="$1"; UI_PROMPT="$2"; _idx="${3:-0}"; _cancel="${4:-1}"
    _n=$(printf '%s\n' "$UI_ITEMS" | grep -c .)
    [ "$_n" -gt 0 ] || return 1
    [ "$_idx" -lt 0 ] && _idx=0
    [ "$_idx" -ge "$_n" ] && _idx=$((_n-1))
    _maxrows=$((UI_ROWS-10))
    [ "$_maxrows" -lt 5 ] && _maxrows=5
    _first=0
    if [ "$_n" -gt "$_maxrows" ] && [ "$_idx" -ge "$_maxrows" ]; then
        _first=$((_idx - _maxrows + 1))
    fi
    while :; do
        ui_clear
        ui_header "$UI_TITLE"
        printf '%s\n' "$UI_PROMPT"
        printf '\n'
        _i=0
        printf '%s\n' "$UI_ITEMS" | while IFS= read -r _item; do
            [ -n "$_item" ] || continue
            if [ "$_i" -ge "$_first" ] && [ "$_i" -lt $((_first+_maxrows)) ]; then
                _label="${_item%%|*}"
                if [ "$_i" -eq "$_idx" ]; then
                    printf '%s[7m %2d) %-*s %s[0m\n' "$ESC" $((_i+1)) $((UI_COLS-7)) "$_label" "$ESC"
                else
                    printf '  %2d) %-*s \n' $((_i+1)) $((UI_COLS-7)) "$_label"
                fi
            fi
            _i=$((_i+1))
        done
        printf '\n'
        if [ "$_n" -gt "$_maxrows" ]; then
            printf '  (showing %d-%d of %d)\n' $((_first+1)) $((_first+_maxrows)) "$_n"
        fi
        ui_footer
        ui_raw_on
        ui_read_key
        ui_raw_off
        case "$KEY" in
            UP|k|K)   [ "$_idx" -gt 0 ] && _idx=$((_idx-1)) ;;
            DOWN|j|J) [ "$_idx" -lt $((_n-1)) ] && _idx=$((_idx+1)) ;;
            ENTER)    break ;;
            HOME|g)   _idx=0 ;;
            END|G)    _idx=$((_n-1)) ;;
            ESC|q|Q)
                ui_clear
                return "$_cancel" ;;
            [0-9])
                _num="$KEY"
                _limit=3
                while [ ${#_num} -lt "$_limit" ]; do
                    ui_raw_on; ui_read_key; ui_raw_off
                    case "$KEY" in
                        [0-9]) _num="$_num$KEY" ;;
                        ENTER) break ;;
                        *) break ;;
                    esac
                done
                if is_number "$_num" && [ "$_num" -ge 1 ] && [ "$_num" -le "$_n" ]; then
                    _idx=$((_num-1)); break
                fi
                ;;
            *) : ;;
        esac
        if [ "$_n" -gt "$_maxrows" ]; then
            if [ "$_idx" -lt "$_first" ]; then _first=$_idx; fi
            if [ "$_idx" -ge $((_first+_maxrows)) ]; then _first=$((_idx-_maxrows+1)); fi
        fi
    done
    UI_INDEX=$_idx
    UI_LABEL="$(printf '%s\n' "$UI_ITEMS" | sed -n "$((_idx+1))p" | cut -d'|' -f1)"
    UI_RESULT="$(printf '%s\n' "$UI_ITEMS" | sed -n "$((_idx+1))p" | cut -s -d'|' -f2-)"
    [ -n "$UI_RESULT" ] || UI_RESULT="$UI_LABEL"
    ui_clear
    return 0
}

ui_ask() {
    _q="$1"; _def="$2"; _var="$3"
    printf '%s\n' "$_q"
    printf '  [%s]: ' "$_def"
    IFS= read -r _ans </dev/tty 2>/dev/null || _ans=""
    [ -n "$_ans" ] || _ans="$_def"
    eval "$_var=\$_ans"
    printf '\n'
}

ui_ask_password() {
    _q="$1"; _var="$2"
    printf '%s\n' "$_q"
    printf '  (input hidden): '
    stty -echo 2>/dev/null || true
    IFS= read -r _ans </dev/tty 2>/dev/null || _ans=""
    stty echo 2>/dev/null || true
    printf '\n'
    eval "$_var=\$_ans"
}

ui_confirm() {
    _q="$1"; _def="${2:-yes}"
    UI_ITEMS="Yes|yes
No|no"
    _di=0
    [ "$_def" = "no" ] && _di=1
    ui_select "Confirm" "$_q" "$_di" || return 1
    [ "$UI_RESULT" = "yes" ]
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
    ui_clear
}

# ---------------------------------------------------------------------------
#  Answer handling
# ---------------------------------------------------------------------------
load_answers() {
    [ -f "$1" ] || die "answers file not found: $1"
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in
            ''|'#'*) continue ;;
        esac
        _k="${_line%%=*}"
        _v="${_line#*=}"
        case "$_k" in
            *[!A-Za-z0-9_]*) continue ;; esac
        case "$_k" in
            DEVICE|HOSTNAME|LOCALE|TIMEZONE|KEYMAP|USERNAME|USER_PASSWORD|USER_FULLNAME|\
            USER_GROUPS|SUDO|DESKTOP|DISPLAY_MANAGER|AUTOLOGIN|AUTOLOGIN_USER|\
            NET_MODE|NET_SERVICE|WIFI_SSID|WIFI_PASSWORD|WIFI_IFACE|WIFI_HIDDEN|WIFI_STACK|\
            STATIC_IP|STATIC_GATEWAY|STATIC_DNS|BLUETOOTH|BLUETOOTH_ADAPTER|\
            SWAP_MODE|SWAP_SIZE|SSH|SSH_PORT|SSH_ROOT_LOGIN|SSH_PASSWORD_AUTH|\
            VNC|VNC_MODE|VNC_PASSWORD|VNC_GEOMETRY|VNC_DISPLAY|REMOTE_MODE|IP_BANNER|\
            KERNEL|FIRMWARE|MICROCODE|EXTRAS|GIT_URL|GIT_BRANCH|SKIP_FETCH|\
            KEYBOARD_LAYOUT|XKB_MODEL|XKB_OPTIONS)
                eval "A_$_k=\$_v"
                ;;
            *) warn "unknown key in answers file: $_k" ;;
        esac
    done <"$1"
    ANSWERS_FILE="$1"
}

dump_answers() {
    cat <<EOF
# VoidL ToolKit answers file -- generated by --dump-answers
DEVICE=$A_DEVICE
HOSTNAME=$A_HOSTNAME
LOCALE=$A_LOCALE
TIMEZONE=$A_TIMEZONE
KEYMAP=$A_KEYMAP
KEYBOARD_LAYOUT=$A_KEYBOARD_LAYOUT
USERNAME=$A_USERNAME
USER_FULLNAME=$A_USER_FULLNAME
USER_GROUPS=$A_USER_GROUPS
SUDO=$A_SUDO
DESKTOP=$A_DESKTOP
DISPLAY_MANAGER=$A_DISPLAY_MANAGER
AUTOLOGIN=$A_AUTOLOGIN
AUTOLOGIN_USER=$A_AUTOLOGIN_USER
NET_MODE=$A_NET_MODE
NET_SERVICE=$A_NET_SERVICE
WIFI_IFACE=$A_WIFI_IFACE
WIFI_SSID=$A_WIFI_SSID
WIFI_HIDDEN=$A_WIFI_HIDDEN
WIFI_STACK=$A_WIFI_STACK
STATIC_IP=$A_STATIC_IP
STATIC_GATEWAY=$A_STATIC_GATEWAY
STATIC_DNS=$A_STATIC_DNS
BLUETOOTH=$A_BLUETOOTH
BLUETOOTH_ADAPTER=$A_BLUETOOTH_ADAPTER
SWAP_MODE=$A_SWAP_MODE
SWAP_SIZE=$A_SWAP_SIZE
SSH=$A_SSH
SSH_PORT=$A_SSH_PORT
SSH_ROOT_LOGIN=$A_SSH_ROOT_LOGIN
SSH_PASSWORD_AUTH=$A_SSH_PASSWORD_AUTH
VNC=$A_VNC
VNC_MODE=$A_VNC_MODE
VNC_GEOMETRY=$A_VNC_GEOMETRY
VNC_DISPLAY=$A_VNC_DISPLAY
REMOTE_MODE=$A_REMOTE_MODE
IP_BANNER=$A_IP_BANNER
KERNEL=$A_KERNEL
FIRMWARE=$A_FIRMWARE
MICROCODE=$A_MICROCODE
EXTRAS=$A_EXTRAS
SKIP_FETCH=$A_SKIP_FETCH
GIT_URL=$A_GIT_URL
GIT_BRANCH=$A_GIT_BRANCH
EOF
}

# ---------------------------------------------------------------------------
#  Prompts
# ---------------------------------------------------------------------------
prompt_device() {
    UI_ITEMS="Auto-detect ($D_ARCH)|auto
PC / server (x86_64)|x86_64
PC / server (i686)|i686
ARM64 board / Raspberry Pi 3-5 (aarch64)|aarch64
ARMv7 board (armv7hl)|armv7hl
Raspberry Pi Zero / Zero W / Pi 1 (armv6hl)|armv6hl
RISC-V 64|riscv64
PowerPC 64 (ppc64 / ppc64le)|ppc64
Other / manual|other"
    ui_select "Device" "What kind of machine is this?" 0 || return 0
    A_DEVICE="$UI_RESULT"
}

prompt_hostname() {
    ui_ask "Hostname (name of this machine on the network)" "$A_HOSTNAME" A_HOSTNAME
}

prompt_locale() {
    _def="$A_LOCALE"
    if [ -z "$_def" ]; then
        if [ "$D_MUSL" = 1 ]; then _def="C.UTF-8"; else _def="en_US.UTF-8"; fi
    fi
    ui_ask "Locale (e.g. en_US.UTF-8, en_GB.UTF-8, de_DE.UTF-8, C.UTF-8)" "$_def" A_LOCALE
}

prompt_timezone() {
    _def="$A_TIMEZONE"
    [ -n "$_def" ] || _def="UTC"
    ui_ask "Timezone (full path, e.g. Asia/Kolkata, Europe/London, America/New_York)" "$_def" A_TIMEZONE
}

prompt_keymap() {
    ui_ask "Console keymap (e.g. us, uk, de, fr, in)" "$A_KEYMAP" A_KEYMAP
    ui_ask "X11 keyboard layout (e.g. us, gb, de, fr, in)" "${A_KEYBOARD_LAYOUT:-$A_KEYMAP}" A_KEYBOARD_LAYOUT
}

prompt_user() {
    ui_ask "Username to create" "${A_USERNAME:-user}" A_USERNAME
    [ -n "$A_USERNAME" ] || A_USERNAME="user"
    ui_ask "Full name for the user" "${A_USER_FULLNAME:-$A_USERNAME}" A_USER_FULLNAME
    while :; do
        ui_ask_password "Password for '$A_USERNAME'" A_USER_PASSWORD
        ui_ask_password "Repeat password" _p2
        [ "$A_USER_PASSWORD" = "$_p2" ] && break
        warn "passwords do not match, try again"
    done
    ui_ask "Extra groups (space separated)" \
        "${A_USER_GROUPS:-wheel audio video input plugdev bluetooth lp storage network}" A_USER_GROUPS
}

prompt_desktop() {
    UI_ITEMS="No desktop (console / server)|none
Xfce  (light, classic)|xfce
LXQt  (very light Qt)|lxqt
MATE  (traditional GNOME 2)|mate
Cinnamon (modern, GNOME 3 based)|cinnamon
GNOME (full modern desktop)|gnome
KDE Plasma (full modern desktop)|kde-plasma
i3 (tiling window manager)|i3
Sway (Wayland tiling)|sway
Minimal X (xorg + xterm only)|minimal"
    ui_select "Desktop environment" "Which desktop should be installed?" 0 || return 0
    A_DESKTOP="$UI_RESULT"
}

prompt_display_manager() {
    if [ "$A_DESKTOP" = "none" ]; then
        UI_ITEMS="None (startx from the console)|none
LightDM|lightdm
SDDM|sddm
GDM|gdm
LXDM|lxdm"
    else
        UI_ITEMS="LightDM (recommended)|lightdm
SDDM (Qt, good for Plasma)|sddm
GDM (GNOME)|gdm
LXDM (lightweight)|lxdm
None (start from the console)|none"
    fi
    ui_select "Login screen" "Which display manager should greet you at boot?" 0 || return 0
    A_DISPLAY_MANAGER="$UI_RESULT"
    if [ "$A_DISPLAY_MANAGER" != "none" ]; then
        if ui_confirm "Log in automatically (skip the login screen)?" "$A_AUTOLOGIN"; then
            A_AUTOLOGIN="yes"
        else
            A_AUTOLOGIN="no"
        fi
        if [ "$A_AUTOLOGIN" = "yes" ]; then
            ui_ask "User to log in automatically" "${A_AUTOLOGIN_USER:-$A_USERNAME}" A_AUTOLOGIN_USER
        fi
    else
        A_AUTOLOGIN="no"
    fi
}

prompt_network() {
    UI_ITEMS="Wired ethernet only (DHCP)|ethernet
Wi-Fi (wireless)|wifi
Wired + Wi-Fi|both
No network configuration|none"
    ui_select "Networking" "How is this machine connected?" 0 || return 0
    A_NET_MODE="$UI_RESULT"
    case "$A_NET_MODE" in
        ethernet)
            UI_ITEMS="dhcpcd (default, simple)|dhcpcd
NetworkManager (roaming, VPN)|NetworkManager
connman (lightweight)|connman
Static IP (dhcpcd)|static"
            ui_select "Network service" "Which network stack?" 0 || return 0
            A_NET_SERVICE="$UI_RESULT"
            ;;
        wifi|both)
            UI_ITEMS="wpa_supplicant (default)|wpa_supplicant
iwd (modern, lightweight)|iwd
NetworkManager|NetworkManager"
            ui_select "Wi-Fi stack" "How should Wi-Fi be managed?" 0 || return 0
            A_WIFI_STACK="$UI_RESULT"
            ;;
    esac
}

prompt_wifi() {
    [ -n "$A_WIFI_IFACE" ] || A_WIFI_IFACE="$D_DEFAULT_IFACE"
    ui_ask "Wireless interface" "$A_WIFI_IFACE" A_WIFI_IFACE
    if [ "$INTERACTIVE" = 1 ]; then
        UI_ITEMS="Scan for networks now|scan
Enter the SSID manually|manual"
        ui_select "Wi-Fi network" "How do you want to pick the network?" 0 || true
        if [ "$UI_RESULT" = "scan" ]; then
            _ssid="$(wifi_scan_menu)"
            [ -n "$_ssid" ] && A_WIFI_SSID="$_ssid"
        fi
    fi
    ui_ask "Wi-Fi network name (SSID)" "$A_WIFI_SSID" A_WIFI_SSID
    ui_ask_password "Wi-Fi password (empty for open networks)" A_WIFI_PASSWORD
    if ui_confirm "Is this a hidden network?" "$A_WIFI_HIDDEN"; then A_WIFI_HIDDEN="yes"; else A_WIFI_HIDDEN="no"; fi
}

wifi_scan_menu() {
    _if="$A_WIFI_IFACE"
    [ -n "$_if" ] || _if="$D_DEFAULT_IFACE"
    if [ "$DRY_RUN" = 1 ] || ! has_cmd iw || [ -z "$_if" ]; then
        return 0
    fi
    info "scanning $_if ..."
    ip link set "$_if" up 2>/dev/null || true
    _list="$(iw dev "$_if" scan 2>/dev/null | awk -F': ' '/^\tSSID:/{gsub(/^ +/,"",$2); print $2}' | sort -u)"
    if [ -z "$_list" ]; then
        ui_msg "No networks found on $_if. You can still type the SSID."
        return 0
    fi
    _items=""
    _f="$(mktemp 2>/dev/null || echo /tmp/.voidl.ssid.$$)"
    printf '%s\n' "$_list" >"$_f"
    while IFS= read -r _s; do
        [ -n "$_s" ] || continue
        _items="$_items
$_s|$_s"
    done <"$_f"
    rm -f "$_f"
    set_items_from_lines "$_items"
    ui_select "Wi-Fi networks" "Choose a network" 0 || return 0
    printf '%s' "$UI_RESULT"
}

prompt_bluetooth() {
    if [ "$INTERACTIVE" = 1 ]; then
        if ui_confirm "Enable Bluetooth?" "$A_BLUETOOTH"; then A_BLUETOOTH="yes"; else A_BLUETOOTH="no"; fi
    fi
    if [ "$A_BLUETOOTH" = "yes" ]; then
        ui_ask "Bluetooth adapter (empty = first available)" "$A_BLUETOOTH_ADAPTER" A_BLUETOOTH_ADAPTER
    fi
}

prompt_swap() {
    UI_ITEMS="No swap|none
Swap file (recommended)|swapfile
zram (compressed RAM swap)|zram"
    ui_select "Swap" "Use swap?" 0 || return 0
    A_SWAP_MODE="$UI_RESULT"
    if [ "$A_SWAP_MODE" = "swapfile" ] || [ "$A_SWAP_MODE" = "zram" ]; then
        _mem="$D_MEM_MB"
        [ "$_mem" -gt 0 ] || _mem=1024
        UI_ITEMS="1 GB|1024
2 GB|2048
4 GB|4096
8 GB|8192
Same as RAM|$_mem
Twice the RAM|$(( _mem * 2 ))
Custom size (MB)|custom"
        ui_select "Swap size" "How much swap do you want?" 1 || return 0
        if [ "$UI_RESULT" = "custom" ]; then
            ui_ask "Swap size in MB" "$A_SWAP_SIZE" A_SWAP_SIZE
        else
            A_SWAP_SIZE="$UI_RESULT"
        fi
        is_number "$A_SWAP_SIZE" || A_SWAP_SIZE="2048"
    fi
}

prompt_remote() {
    UI_ITEMS="LAN / local network (show the IP address)|lan
USB gadget mode (Raspberry Pi only: ssh over USB)|gadget
No remote access|none"
    ui_select "Remote access" "How do you want to reach this machine?" 0 || return 0
    A_REMOTE_MODE="$UI_RESULT"
    if [ "$A_REMOTE_MODE" = "gadget" ] && [ "$D_IS_RPI" != 1 ]; then
        if ! ui_confirm "This does not look like a Raspberry Pi. Use gadget mode anyway?" no; then
            A_REMOTE_MODE="lan"
        fi
    fi
    if ui_confirm "Show the IP address on the console at boot?" "$A_IP_BANNER"; then
        A_IP_BANNER="yes"
    else
        A_IP_BANNER="no"
    fi
    if ui_confirm "Enable SSH?" "$A_SSH"; then A_SSH="yes"; else A_SSH="no"; fi
    if [ "$A_SSH" = "yes" ]; then
        ui_ask "SSH port" "$A_SSH_PORT" A_SSH_PORT
        is_number "$A_SSH_PORT" || A_SSH_PORT=22
        if ui_confirm "Allow root login over SSH?" "$A_SSH_ROOT_LOGIN"; then A_SSH_ROOT_LOGIN="yes"; else A_SSH_ROOT_LOGIN="no"; fi
        if ui_confirm "Allow password authentication?" "$A_SSH_PASSWORD_AUTH"; then A_SSH_PASSWORD_AUTH="yes"; else A_SSH_PASSWORD_AUTH="no"; fi
    fi
    if ui_confirm "Install a VNC server?" "$A_VNC"; then A_VNC="yes"; else A_VNC="no"; fi
    if [ "$A_VNC" = "yes" ]; then
        UI_ITEMS="Virtual desktop (vncserver :1)|virtual
Mirror the physical display (x0vncserver)|mirror"
        ui_select "VNC mode" "What should VNC show?" 0 || return 0
        A_VNC_MODE="$UI_RESULT"
        ui_ask "VNC display number" "$A_VNC_DISPLAY" A_VNC_DISPLAY
        is_number "$A_VNC_DISPLAY" || A_VNC_DISPLAY=1
        ui_ask "VNC resolution" "$A_VNC_GEOMETRY" A_VNC_GEOMETRY
        ui_ask_password "VNC password" A_VNC_PASSWORD
    fi
}

prompt_firmware() {
    if ui_confirm "Install firmware (Wi-Fi/GPU/bluetooth blobs)?" "$A_FIRMWARE"; then A_FIRMWARE="yes"; else A_FIRMWARE="no"; fi
    if [ "$D_ARCH_FAMILY" = "x86" ]; then
        UI_ITEMS="Auto-detect ($D_CPU_VENDOR)|auto
Intel CPU|intel
AMD CPU|amd
None|none"
        ui_select "Microcode" "Install CPU microcode updates?" 0 || return 0
        A_MICROCODE="$UI_RESULT"
    fi
    if [ "$D_IS_RPI" = 1 ]; then
        UI_ITEMS="Raspberry Pi kernel (rpi-kernel)|rpi-kernel
Mainline kernel (linux)|linux
LTS kernel (linux-lts)|linux-lts"
    else
        UI_ITEMS="Latest kernel (linux)|linux
LTS kernel (linux-lts)|linux-lts"
    fi
    ui_select "Kernel" "Which kernel should be installed?" 0 || return 0
    A_KERNEL="$UI_RESULT"
}

prompt_extras() {
    [ "$INTERACTIVE" = 1 ] || return 0
    if ! ui_confirm "Install extra packages (browsers, codecs, tools)?" no; then return 0; fi
    UI_ITEMS="None|none
Browsers (firefox)|firefox
Media (mpv, vlc)|media
Office (libreoffice)|libreoffice
Development tools|devel
All of the above|all"
    ui_select "Extra packages" "Pick a set" 0 || return 0
    A_EXTRAS="$UI_RESULT"
}

# ---------------------------------------------------------------------------
#  Apply
# ---------------------------------------------------------------------------
pkg_install() {
    _pkgs="$*"
    [ -n "$_pkgs" ] || return 0
    if [ "$DRY_RUN" = 1 ]; then
        log "    | xbps-install -Sy $_pkgs"
        return 0
    fi
    if [ "$NO_INSTALL" = 1 ]; then
        log "    | (skip install) $_pkgs"
        return 0
    fi
    if ! has_cmd xbps-install; then
        warn "xbps-install not available, cannot install: $_pkgs"
        return 0
    fi
    info "installing: $_pkgs"
    if ! xbps-install -Sy $_pkgs; then
        warn "failed to install some of: $_pkgs (continuing)"
    fi
}

service_dir() {
    # Directory where runit looks for enabled services.
    # /var/service is a symlink to /run/runit/runsvdir/current, which does not
    # exist until the machine has booted at least once, so fall back to the
    # persistent runlevel directory /etc/runit/runsvdir/default.
    _d="$ROOT/var/service"
    if [ -L "$_d" ]; then
        _t="$(readlink "$_d" 2>/dev/null)"
        case "$_t" in
            /*)  _abs="$_t" ;;
            *)   _abs="$(dirname "$_d")/$_t" ;;
        esac
        if [ -d "$_abs" ]; then printf '%s' "$_abs"; return 0; fi
    fi
    if [ -d "$ROOT/etc/runit/runsvdir/default" ]; then
        printf '%s' "$ROOT/etc/runit/runsvdir/default"
    else
        printf '%s' "$_d"
    fi
}

enable_service() {
    _s="$1"
    if [ "$DRY_RUN" = 1 ]; then
        log "    | enable service $_s"
        return 0
    fi
    if [ ! -d "$(rpath /etc/sv/$_s)" ]; then
        warn "service '$_s' is not installed (package missing?) - skipped"
        return 1
    fi
    _dir="$(service_dir)"
    mkdir -p "$_dir" 2>/dev/null || true
    ln -sfn "/etc/sv/$_s" "$_dir/$_s" 2>/dev/null || true
    logf "enabled service $_s"
}

disable_service() {
    _s="$1"
    if [ "$DRY_RUN" = 1 ]; then log "    | disable service $_s"; return 0; fi
    _dir="$(service_dir)"
    rm -f "$_dir/$_s" 2>/dev/null || true
    logf "disabled service $_s"
}

write_service() {
    _n="$1"; _m="${2:-0755}"
    if [ "$DRY_RUN" != 1 ]; then
        mkdir -p "$(rpath /etc/sv/$_n)" 2>/dev/null || true
    fi
    write_file "/etc/sv/$_n/run" "$_m"
}

mkdir_p() {
    [ "$DRY_RUN" = 1 ] && return 0
    mkdir -p "$1" 2>/dev/null || true
}

session_name() {
    case "$1" in
        xfce)        echo "xfce" ;;
        lxqt)        echo "LXQt" ;;
        mate)        echo "mate" ;;
        cinnamon)    echo "cinnamon" ;;
        gnome)       echo "gnome" ;;
        kde-plasma)  echo "plasma" ;;
        i3)          echo "i3" ;;
        sway)        echo "sway" ;;
        *)           echo "default" ;;
    esac
}

apply_identity() {
    section "System identity"

    printf '%s\n' "$A_HOSTNAME" | write_file /etc/hostname 0644
    if [ -f "$(rpath /etc/rc.conf)" ]; then
        if grep -q '^HOSTNAME=' "$(rpath /etc/rc.conf)" 2>/dev/null; then
            run_sh "sed -i 's|^HOSTNAME=.*|HOSTNAME=\"$A_HOSTNAME\"|' $(rpath /etc/rc.conf)"
        else
            append_unique /etc/rc.conf "HOSTNAME=\"$A_HOSTNAME\""
        fi
    fi

    if [ -d "$(rpath /usr/share/zoneinfo)" ] && [ -e "$(rpath /usr/share/zoneinfo/$A_TIMEZONE)" ]; then
        run ln -sf "/usr/share/zoneinfo/$A_TIMEZONE" "$(rpath /etc/localtime)"
    else
        [ "$DRY_RUN" = 1 ] || warn "timezone '$A_TIMEZONE' not found, keeping the current one"
    fi
    if [ -f "$(rpath /etc/rc.conf)" ]; then
        if grep -q '^TIMEZONE=' "$(rpath /etc/rc.conf)" 2>/dev/null; then
            run_sh "sed -i 's|^TIMEZONE=.*|TIMEZONE=\"$A_TIMEZONE\"|' $(rpath /etc/rc.conf)"
        else
            append_unique /etc/rc.conf "TIMEZONE=\"$A_TIMEZONE\""
        fi
    fi

    if [ "$D_MUSL" = 1 ]; then A_LOCALE="C.UTF-8"; fi
    {
        echo "LANG=$A_LOCALE"
        echo "LC_COLLATE=C"
    } | write_file /etc/locale.conf 0644
    mkdir_p "$(rpath /etc/profile.d)"
    printf 'export LANG=%s\nexport LC_COLLATE=C\n' "$A_LOCALE" | write_file /etc/profile.d/00-voidl-locale.sh 0644
    if [ -f "$(rpath /etc/default/libc-locales)" ]; then
        run_sh "sed -i 's|^#\? *${A_LOCALE%%.*}[[:space:]].*|${A_LOCALE} UTF-8 UTF-8|' $(rpath /etc/default/libc-locales)"
    fi
    if [ "$D_MUSL" != 1 ] && [ "$NO_INSTALL" != 1 ]; then
        if [ "$DRY_RUN" = 1 ]; then
            log "    | xbps-reconfigure -f glibc-locales"
        elif has_cmd xbps-reconfigure; then
            xbps-reconfigure -f glibc-locales >/dev/null 2>&1 || true
        fi
    fi

    if [ -f "$(rpath /etc/rc.conf)" ]; then
        if grep -q '^KEYMAP=' "$(rpath /etc/rc.conf)" 2>/dev/null; then
            run_sh "sed -i 's|^KEYMAP=.*|KEYMAP=\"$A_KEYMAP\"|' $(rpath /etc/rc.conf)"
        else
            append_unique /etc/rc.conf "KEYMAP=\"$A_KEYMAP\""
        fi
    fi
    if [ -n "$A_KEYBOARD_LAYOUT" ] && [ "$A_DESKTOP" != "none" ]; then
        mkdir_p "$(rpath /etc/X11/xorg.conf.d)"
        {
            echo 'Section "InputClass"'
            echo '    Identifier "system-keyboard"'
            echo '    MatchIsKeyboard "on"'
            echo "    Option \"XkbLayout\" \"$A_KEYBOARD_LAYOUT\""
            echo "    Option \"XkbModel\" \"${A_XKB_MODEL:-pc105}\""
            [ -n "$A_XKB_OPTIONS" ] && echo "    Option \"XkbOptions\" \"$A_XKB_OPTIONS\""
            echo 'EndSection'
        } | write_file /etc/X11/xorg.conf.d/00-keyboard.conf 0644
    fi
}

apply_user() {
    section "User account"
    [ -n "$A_USERNAME" ] || A_USERNAME="user"
    if [ "$DRY_RUN" = 1 ]; then
        log "    | create user $A_USERNAME (groups: $A_USER_GROUPS, sudo: $A_SUDO)"
        [ "$A_SUDO" = "yes" ] && log "    | install sudo + sudoers entry"
        return 0
    fi
    if id "$A_USERNAME" >/dev/null 2>&1; then
        info "user '$A_USERNAME' already exists"
    else
        if has_cmd useradd; then
            run useradd -m -c "$A_USER_FULLNAME" -s /bin/bash "$A_USERNAME"
        elif has_cmd adduser; then
            run adduser -h "/home/$A_USERNAME" -s /bin/bash -D "$A_USERNAME"
        else
            warn "no useradd/adduser found, cannot create the user"
        fi
    fi
    if [ -n "$A_USER_PASSWORD" ]; then
        if has_cmd chpasswd; then
            printf '%s:%s\n' "$A_USERNAME" "$A_USER_PASSWORD" | run_sh "chpasswd"
        else
            warn "chpasswd not available, set the password manually"
        fi
    fi
    if [ -n "$A_USER_GROUPS" ]; then
        for _g in $A_USER_GROUPS; do
            getent group "$_g" >/dev/null 2>&1 || groupadd "$_g" >/dev/null 2>&1 || true
            usermod -aG "$_g" "$A_USERNAME" >/dev/null 2>&1 || true
        done
    fi
    if [ "$A_SUDO" = "yes" ]; then
        mkdir -p "$(rpath /etc/sudoers.d)"
        printf '%s ALL=(ALL:ALL) ALL\n' "$A_USERNAME" >"$(rpath /etc/sudoers.d/$A_USERNAME)" 2>/dev/null || true
        chmod 0440 "$(rpath /etc/sudoers.d/$A_USERNAME)" 2>/dev/null || true
        pkg_install sudo
    fi
}

apply_desktop() {
    section "Desktop environment"
    case "$A_DESKTOP" in
        none)      log "    | no desktop selected" ;;
        xfce)      pkg_install xfce4 xfce4-terminal thunar xfce4-power-manager ;;
        lxqt)      pkg_install lxqt ;;
        mate)      pkg_install mate mate-extra ;;
        cinnamon)  pkg_install cinnamon ;;
        gnome)     pkg_install gnome gnome-tweaks gnome-terminal ;;
        kde-plasma) pkg_install kde-plasma kde-cli-tools ark ;;
        i3)        pkg_install i3 i3status i3lock dmenu xterm xinit ;;
        sway)      pkg_install sway swaylock swayidle foot wofi xterm ;;
        minimal)   pkg_install xorg-server xinit xterm ;;
        *)         warn "unknown desktop '$A_DESKTOP', skipping" ;;
    esac
    if [ "$A_DESKTOP" != "none" ]; then
        pkg_install pipewire alsa-pipewire wireplumber
    fi
}

apply_display_manager() {
    section "Login screen"
    case "$A_DISPLAY_MANAGER" in
        none)    log "    | no display manager" ;;
        lightdm) pkg_install lightdm lightdm-gtk-greeter ;;
        sddm)    pkg_install sddm ;;
        gdm)     pkg_install gdm ;;
        lxdm)    pkg_install lxdm ;;
    esac
    if [ "$A_DISPLAY_MANAGER" = "none" ]; then
        if [ "$A_AUTOLOGIN" = "yes" ] && [ -n "$A_AUTOLOGIN_USER" ]; then
            enable_console_autologin
        fi
        return 0
    fi
    enable_service "$A_DISPLAY_MANAGER"
    if [ "$A_AUTOLOGIN" = "yes" ] && [ -n "$A_AUTOLOGIN_USER" ]; then
        configure_autologin
    fi
}

configure_autologin() {
    _u="$A_AUTOLOGIN_USER"
    _sess="$(session_name "$A_DESKTOP")"
    case "$A_DISPLAY_MANAGER" in
        lightdm)
            mkdir_p "$(rpath /etc/lightdm)"
            {
                echo "[Seat:*]"
                echo "greeter-session=lightdm-gtk-greeter"
                echo "autologin-user=$_u"
                echo "autologin-user-timeout=0"
                echo "autologin-session=$_sess"
                echo "user-session=$_sess"
            } | write_file /etc/lightdm/lightdm.conf 0644
            ;;
        sddm)
            mkdir_p "$(rpath /etc/sddm.conf.d)"
            {
                echo "[Autologin]"
                echo "User=$_u"
                echo "Session=$_sess"
            } | write_file /etc/sddm.conf.d/autologin.conf 0644
            ;;
        gdm)
            mkdir_p "$(rpath /etc/gdm)"
            {
                echo "[daemon]"
                echo "AutomaticLoginEnable=True"
                echo "AutomaticLogin=$_u"
            } | write_file /etc/gdm/custom.conf 0644
            ;;
        lxdm)
            if [ -f "$(rpath /etc/lxdm/lxdm.conf)" ]; then
                run_sh "sed -i 's|^#\?autologin=.*|autologin=$_u|' $(rpath /etc/lxdm/lxdm.conf)"
            else
                printf 'autologin=%s\n' "$_u" | write_file /etc/lxdm/lxdm.conf 0644
            fi
            ;;
    esac
}

enable_console_autologin() {
    _u="$A_AUTOLOGIN_USER"
    [ -n "$_u" ] || return 0
    _run="$(rpath /etc/sv/agetty-tty1/run)"
    if [ -f "$_run" ]; then
        if grep -q -- '--autologin' "$_run" 2>/dev/null; then
            run_sh "sed -i 's|--autologin [^ ]*|--autologin $_u|' $_run"
        else
            run_sh "sed -i 's|exec agetty|exec agetty --autologin $_u|' $_run"
        fi
    else
        {
            echo '#!/bin/sh'
            echo "exec agetty --autologin $_u --noclear tty1 38400 linux"
        } | write_service agetty-tty1 0755
    fi
    enable_service agetty-tty1
}

apply_network() {
    section "Networking"
    [ "${A_NET_MODE:-ethernet}" = "none" ] && return 0
    case "$A_NET_SERVICE" in
        NetworkManager) pkg_install NetworkManager network-manager-applet; enable_service NetworkManager ;;
        connman)        pkg_install connman; enable_service connman ;;
        *)              pkg_install dhcpcd ;;
    esac
    if [ "$A_NET_SERVICE" = "static" ]; then
        {
            echo "# static configuration written by VoidL ToolKit"
            echo "interface $D_DEFAULT_IFACE"
            echo "static ip_address=$A_STATIC_IP"
            [ -n "$A_STATIC_GATEWAY" ] && echo "static routers=$A_STATIC_GATEWAY"
            [ -n "$A_STATIC_DNS" ] && echo "static domain_name_servers=$A_STATIC_DNS"
        } | write_file /etc/dhcpcd.conf 0644
    fi
    case "${A_NET_MODE:-ethernet}" in
        ethernet|both) enable_service dhcpcd ;;
    esac
    case "${A_NET_MODE:-ethernet}" in
        wifi|both) apply_wifi ;;
    esac
}

apply_wifi() {
    section "Wi-Fi"
    [ -n "$A_WIFI_SSID" ] || { log "    | no SSID given, skipping Wi-Fi setup"; return 0; }
    case "$A_WIFI_STACK" in
        iwd)
            pkg_install iwd
            mkdir_p "$(rpath /var/lib/iwd)"
            {
                echo "[Security]"
                if [ -n "$A_WIFI_PASSWORD" ]; then
                    echo "PreSharedKey=$A_WIFI_PASSWORD"
                    echo "Passphrase=$A_WIFI_PASSWORD"
                fi
                echo ""
                echo "[Settings]"
                echo "AutoConnect=true"
            } | write_file "/var/lib/iwd/$A_WIFI_SSID.psk" 0600
            enable_service iwd
            ;;
        NetworkManager)
            pkg_install NetworkManager
            mkdir_p "$(rpath /etc/NetworkManager/system-connections)"
            {
                echo "[connection]"
                echo "id=$A_WIFI_SSID"
                echo "type=wifi"
                echo "interface-name=$A_WIFI_IFACE"
                echo ""
                echo "[wifi]"
                echo "ssid=$A_WIFI_SSID"
                if [ "$A_WIFI_HIDDEN" = "yes" ]; then echo "hidden=true"; else echo "hidden=false"; fi
                echo ""
                echo "[wifi-security]"
                if [ -n "$A_WIFI_PASSWORD" ]; then
                    echo "key_mgmt=wpa-psk"
                    echo "psk=$A_WIFI_PASSWORD"
                else
                    echo "key_mgmt=none"
                fi
                echo ""
                echo "[ipv4]"
                echo "method=auto"
            } | write_file "/etc/NetworkManager/system-connections/$A_WIFI_SSID.nmconnection" 0600
            enable_service NetworkManager
            ;;
        *)
            pkg_install wpa_supplicant
            mkdir_p "$(rpath /etc/wpa_supplicant)"
            _psk="$A_WIFI_PASSWORD"
            _psk_line=""
            if [ -n "$_psk" ] && has_cmd wpa_passphrase && [ "$DRY_RUN" != 1 ]; then
                _psk_line="$(wpa_passphrase "$A_WIFI_SSID" "$_psk" 2>/dev/null | awk -F'psk=' '/psk=/{print $2; exit}')"
            fi
            {
                echo "# generated by VoidL ToolKit"
                echo "ctrl_interface=/run/wpa_supplicant"
                echo "update_config=1"
                echo "country=00"
                echo ""
                echo "network={"
                echo "    ssid=\"$A_WIFI_SSID\""
                if [ -n "$_psk" ]; then
                    if [ -n "$_psk_line" ]; then
                        echo "    psk=$_psk_line"
                    else
                        echo "    psk=\"$_psk\""
                    fi
                fi
                [ "$A_WIFI_HIDDEN" = "yes" ] && echo "    scan_ssid=1"
                [ -z "$_psk" ] && echo "    key_mgmt=NONE"
                echo "}"
            } | write_file /etc/wpa_supplicant/wpa_supplicant.conf 0600
            {
                echo '#!/bin/sh'
                echo '[ -r ./conf ] && . ./conf'
                echo "exec wpa_supplicant -i \"${A_WIFI_IFACE:-wlan0}\" -c /etc/wpa_supplicant/wpa_supplicant.conf -D nl80211,wext"
            } | write_service wpa_supplicant 0755
            enable_service wpa_supplicant
            enable_service dhcpcd
            ;;
    esac
}

apply_bluetooth() {
    section "Bluetooth"
    [ "$A_BLUETOOTH" = "yes" ] || { log "    | bluetooth disabled"; return 0; }
    pkg_install bluez blueman
    enable_service bluetoothd
    if has_cmd rfkill; then run rfkill unblock bluetooth; fi
    logf "bluetooth enabled (adapter: ${A_BLUETOOTH_ADAPTER:-auto})"
}

apply_swap() {
    section "Swap"
    case "$A_SWAP_MODE" in
        none) log "    | no swap" ;;
        zram)
            pkg_install zramen
            mkdir_p "$(rpath /etc/zramen)"
            printf 'ZRAM_SIZE_MB=%s\n' "$A_SWAP_SIZE" | write_file /etc/zramen/zramen.conf 0644
            enable_service zramen
            ;;
        swapfile)
            _size="$A_SWAP_SIZE"
            is_number "$_size" || _size=2048
            _swapfile="$(rpath /swapfile)"
            if [ "$DRY_RUN" = 1 ]; then
                log "    | create $_swapfile of ${_size}MB and add it to /etc/fstab"
            else
                if [ ! -f "$_swapfile" ]; then
                    info "creating ${_size}MB swap file (this can take a minute)"
                    dd if=/dev/zero of="$_swapfile" bs=1M count="$_size" status=none 2>/dev/null \
                        || dd if=/dev/zero of="$_swapfile" bs=1M count="$_size"
                    chmod 600 "$_swapfile"
                    mkswap "$_swapfile" >/dev/null 2>&1 || warn "mkswap failed"
                fi
                swapon "$_swapfile" 2>/dev/null || warn "could not enable $_swapfile"
            fi
            append_unique /etc/fstab "/swapfile none swap defaults 0 0"
            ;;
    esac
    if [ "$A_SWAP_MODE" != "none" ]; then
        mkdir_p "$(rpath /etc/sysctl.d)"
        {
            echo "# written by VoidL ToolKit"
            echo "vm.swappiness=10"
        } | write_file /etc/sysctl.d/99-voidl.conf 0644
    fi
}

apply_ssh() {
    section "SSH"
    [ "$A_SSH" = "yes" ] || { log "    | ssh disabled"; return 0; }
    pkg_install openssh
    mkdir_p "$(rpath /etc/ssh)"
    if [ -f "$(rpath /etc/ssh/sshd_config)" ]; then
        run_sh "sed -i 's|^#\?Port .*|Port $A_SSH_PORT|' $(rpath /etc/ssh/sshd_config)"
        run_sh "sed -i 's|^#\?PermitRootLogin .*|PermitRootLogin $A_SSH_ROOT_LOGIN|' $(rpath /etc/ssh/sshd_config)"
        run_sh "sed -i 's|^#\?PasswordAuthentication .*|PasswordAuthentication $A_SSH_PASSWORD_AUTH|' $(rpath /etc/ssh/sshd_config)"
    fi
    if [ "$DRY_RUN" != 1 ] && has_cmd ssh-keygen; then
        ssh-keygen -A >/dev/null 2>&1 || true
    fi
    enable_service sshd
}

apply_vnc() {
    section "VNC"
    [ "$A_VNC" = "yes" ] || { log "    | vnc disabled"; return 0; }
    pkg_install tigervnc
    _display="$A_VNC_DISPLAY"
    is_number "$_display" || _display=1
    mkdir_p "$(rpath /etc/voidl)"
    if [ "$A_VNC_MODE" = "mirror" ]; then
        pkg_install xorg-server
        {
            echo '#!/bin/sh'
            echo "exec x0vncserver -display :0 -passwordfile /etc/voidl/vnc.pass -rfbport $((5900 + _display))"
        } | write_service voidl-vnc 0755
    else
        {
            echo '#!/bin/sh'
            echo '[ -r /etc/voidl/vnc.conf ] && . /etc/voidl/vnc.conf'
            echo "exec su - \"${A_USERNAME:-user}\" -c \"vncserver :$_display -geometry ${A_VNC_GEOMETRY} -localhost no -fg -PasswordFile /etc/voidl/vnc.pass\""
        } | write_service voidl-vnc 0755
    fi
    if [ -n "$A_VNC_PASSWORD" ]; then
        if [ "$DRY_RUN" != 1 ]; then
            if has_cmd tigervncpasswd; then
                printf '%s\n%s\n' "$A_VNC_PASSWORD" "$A_VNC_PASSWORD" | tigervncpasswd /etc/voidl/vnc.pass >/dev/null 2>&1 || true
            elif has_cmd vncpasswd; then
                printf '%s\n%s\n' "$A_VNC_PASSWORD" "$A_VNC_PASSWORD" | vncpasswd /etc/voidl/vnc.pass >/dev/null 2>&1 || true
            fi
            chmod 600 /etc/voidl/vnc.pass 2>/dev/null || true
        else
            log "    | write /etc/voidl/vnc.pass"
        fi
    fi
    enable_service voidl-vnc
}

apply_remote() {
    section "Remote access"
    if [ "$A_REMOTE_MODE" = "gadget" ]; then apply_gadget; fi
    if [ "$A_IP_BANNER" = "yes" ]; then apply_ip_banner; fi
}

apply_gadget() {
    section "USB gadget mode"
    if [ "$D_IS_RPI" != 1 ] && [ "$FORCE" != 1 ]; then
        log "    | not a Raspberry Pi - skipping gadget setup"
        return 0
    fi
    pkg_install dnsmasq
    mkdir_p "$(rpath /etc/voidl)"
    mkdir_p "$(rpath /usr/local/bin)"
    cat <<'EOF' | write_file /usr/local/bin/voidl-gadget-setup 0755
#!/bin/sh
# Bring up a USB ethernet gadget (CDC ECM or RNDIS) and serve DHCP on it.
set -e
GADGET=/sys/kernel/config/usb_gadget/g1
IFACE=usb0
MODE="${VOIDL_GADGET_MODE:-ecm}"
IP="${VOIDL_GADGET_IP:-10.55.0.1}"
CIDR="${VOIDL_GADGET_CIDR:-24}"

modprobe libcomposite 2>/dev/null || true
modprobe dwc2 2>/dev/null || true

[ -d /sys/kernel/config/usb_gadget ] || mount -t configfs none /sys/kernel/config

mkdir -p "$GADGET"
cd "$GADGET"
echo 0x1d6b > idVendor
echo 0x0104 > idProduct
echo 0x0100 > bcdDevice
echo 0x0200 > bcdUSB
mkdir -p strings/0x409
echo "voidl-usb-gadget" > strings/0x409/serialnumber
echo "VoidL" > strings/0x409/manufacturer
echo "Void Linux USB Ethernet" > strings/0x409/product

mkdir -p configs/c.1/strings/0x409
echo "USB Ethernet" > configs/c.1/strings/0x409/configuration
echo 250 > configs/c.1/MaxPower

case "$MODE" in
    rndis)
        mkdir -p functions/rndis.usb0
        ln -sfn functions/rndis.usb0 configs/c.1/ 2>/dev/null || true
        ;;
    *)
        mkdir -p functions/ecm.usb0
        ln -sfn functions/ecm.usb0 configs/c.1/ 2>/dev/null || true
        ;;
esac

UDC=$(ls /sys/class/udc 2>/dev/null | head -n1)
[ -n "$UDC" ] && echo "$UDC" > UDC

ip link set "$IFACE" up 2>/dev/null || true
ip addr flush dev "$IFACE" 2>/dev/null || true
ip addr add "$IP/$CIDR" dev "$IFACE" 2>/dev/null || true
EOF
    cat <<'EOF' | write_file /etc/voidl/gadget.conf 0644
# USB gadget settings (sourced by the runit service)
VOIDL_GADGET_MODE=ecm
VOIDL_GADGET_IP=10.55.0.1
VOIDL_GADGET_CIDR=24
EOF
    cat <<'EOF' | write_service voidl-gadget 0755
#!/bin/sh
[ -r /etc/voidl/gadget.conf ] && . /etc/voidl/gadget.conf
exec /usr/local/bin/voidl-gadget-setup
EOF
    mkdir_p "$(rpath /etc/dnsmasq.d)"
    cat <<'EOF' | write_file /etc/dnsmasq.d/voidl-gadget.conf 0644
interface=usb0
port=0
dhcp-range=10.55.0.10,10.55.0.50,255.255.255.0,12h
dhcp-option=6
dhcp-option=3
EOF
    enable_service voidl-gadget
    enable_service dnsmasq
    enable_service sshd
}

apply_ip_banner() {
    section "IP banner"
    mkdir_p "$(rpath /usr/local/bin)"
    cat <<'EOF' | write_file /usr/local/bin/void-ip-banner 0755
#!/bin/sh
# Print the machine's addresses on the console and in /etc/issue so they
# are visible on the login screen.  Safe to run repeatedly.
quiet="${1:-}"
tmp=/etc/issue.voidl
out=""
if command -v ip >/dev/null 2>&1; then
    out="$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print $2": "a[1]}')"
fi
[ -n "$out" ] || out="no network address yet"
user="$(getent passwd 1000 2>/dev/null | cut -d: -f1)"
[ -n "$user" ] || user="root"
{
    echo ""
    echo "  Void Linux - VoidL ToolKit"
    echo "  -----------------------------------------"
    printf '%s\n' "$out" | sed 's/^/  /'
    if command -v sshd >/dev/null 2>&1; then
        printf '%s\n' "$out" | awk -F': ' -v u="$user" '{printf "  ssh %s@%s\n", u, $2}'
    fi
    echo "  -----------------------------------------"
    echo ""
} >"$tmp"
if [ -f /etc/issue.dist ]; then
    cat /etc/issue.dist "$tmp" >/etc/issue 2>/dev/null || cat "$tmp" >/etc/issue
else
    cat "$tmp" >/etc/issue
fi
if [ "$quiet" != "--quiet" ]; then
    cat "$tmp" >/dev/console 2>/dev/null || true
fi
EOF
    cat <<'EOF' | write_service voidl-ip-banner 0755
#!/bin/sh
# Refresh the address banner every 30 seconds.
while :; do
    /usr/local/bin/void-ip-banner --quiet
    sleep 30
done
EOF
    enable_service voidl-ip-banner
}

apply_firmware() {
    section "Firmware & kernel"
    if [ "$A_FIRMWARE" = "yes" ]; then
        pkg_install linux-firmware
        if [ "$D_ARCH_FAMILY" = "x86" ]; then
            case "$A_MICROCODE" in
                intel) pkg_install intel-ucode ;;
                amd)   pkg_install linux-firmware-amd ;;
                auto)
                    case "$D_CPU_VENDOR" in
                        intel) pkg_install intel-ucode ;;
                        amd)   pkg_install linux-firmware-amd ;;
                    esac
                    ;;
            esac
        fi
        if [ "$D_IS_RPI" = 1 ]; then pkg_install rpi-firmware; fi
    fi
    case "$A_KERNEL" in
        rpi-kernel) pkg_install rpi-kernel ;;
        linux-lts)  pkg_install linux-lts ;;
        linux)      pkg_install linux ;;
    esac
}

apply_extras() {
    section "Extra packages"
    case "$A_EXTRAS" in
        ''|none) return 0 ;;
        firefox)    pkg_install firefox ;;
        media)      pkg_install mpv vlc ;;
        libreoffice) pkg_install libreoffice ;;
        devel)      pkg_install git base-devel ;;
        all)        pkg_install firefox mpv vlc libreoffice git base-devel ;;
        *)          pkg_install $A_EXTRAS ;;
    esac
}

apply_bootloader() {
    section "Bootloader"
    if [ "$DRY_RUN" = 1 ]; then
        log "    | update bootloader configuration (grub/extlinux/rpi)"
        return 0
    fi
    if has_cmd grub-mkconfig && [ -d /boot/grub ]; then
        info "regenerating GRUB configuration"
        grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || warn "grub-mkconfig failed"
    elif [ -f /boot/extlinux/extlinux.conf ]; then
        info "extlinux found - check that the kernel line matches the new kernel"
    elif [ -f /boot/config.txt ] || [ -f /boot/firmware/config.txt ]; then
        info "Raspberry Pi firmware found - checking /boot/cmdline.txt"
        _cmd=/boot/cmdline.txt
        [ -f /boot/firmware/cmdline.txt ] && _cmd=/boot/firmware/cmdline.txt
        grep -q 'root=' "$_cmd" 2>/dev/null || warn "no root= in $_cmd"
    else
        warn "no supported bootloader detected - update it manually"
    fi
}

apply_cleanup() {
    section "Cleanup"
    if [ "$NO_INSTALL" != 1 ] && has_cmd xbps-remove; then
        run_sh "xbps-remove -O 2>/dev/null || true"
    fi
}

# ---------------------------------------------------------------------------
#  Downloading the wireless tool
# ---------------------------------------------------------------------------
#  The wireless TUI lives in the same repository as this script, so the normal
#  path is `git clone`.  Minimal Void images often have no git yet (and no
#  curl/wget either), so there are two fallbacks: any HTTP client that happens
#  to be installed, and as a last resort a bare HTTPS GET done with
#  `openssl s_client` -- openssl is part of the base system on Void.
#  Fetching is best effort: it must never abort the rest of the install.

# git_archive_url URL BRANCH -> codeload tarball URL (empty if not github)
git_archive_url() {
    _gu="$1"; _gb="${2:-main}"
    case "$_gu" in
        http://github.com/*|https://github.com/*) ;;
        *) return 1 ;;
    esac
    _gp=${_gu#*://github.com/}
    _gp=${_gp%/}
    _gp=${_gp%.git}
    printf 'https://codeload.github.com/%s/tar.gz/refs/heads/%s\n' "$_gp" "$_gb"
}

# http_get URL OUTFILE -> 0 when OUTFILE holds the response body
http_get() {
    _u="$1"; _o="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 90 "$_u" -o "$_o" 2>/dev/null && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q -T 90 -O "$_o" "$_u" 2>/dev/null && return 0
    fi
    command -v openssl >/dev/null 2>&1 || return 1
    case "$_u" in
        https://*) ;;
        *) return 1 ;;
    esac
    _host=${_u#https://}; _host=${_host%%/*}
    _path=/${_u#https://$_host}
    _raw="$_o.headers"
    printf 'GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: VoidL-ToolKit/%s\r\nAccept: */*\r\nConnection: close\r\n\r\n' \
        "$_path" "$_host" "$VERSION" \
        | openssl s_client -quiet -connect "$_host:443" -servername "$_host" > "$_raw" 2>/dev/null
    [ -s "$_raw" ] || { rm -f "$_raw" 2>/dev/null; return 1; }
    # find where the header block ends (\r\n\r\n) and keep only what follows
    _crlf=$(printf '\r\n\r\nx'); _crlf=${_crlf%x}
    _off=$(grep -abo -m1 -F -- "$_crlf" "$_raw" 2>/dev/null | head -n 1 | cut -d: -f1)
    case "$_off" in ''|*[!0-9]*) rm -f "$_raw" 2>/dev/null; return 1 ;; esac
    tail -c +"$((_off + 5))" "$_raw" > "$_o" 2>/dev/null
    rm -f "$_raw" 2>/dev/null
    [ -s "$_o" ] || return 1
    return 0
}

fetch_wireless_tool() {
    section "Wireless settings tool"
    if [ "$A_SKIP_FETCH" = "yes" ]; then
        log "    | fetch skipped (SKIP_FETCH=yes)"
        return 0
    fi
    if [ "$DRY_RUN" = 1 ]; then
        log "    | install git and fetch wireless-settings.sh from $A_GIT_URL"
        return 0
    fi
    command -v git >/dev/null 2>&1 || pkg_install git
    _tmp="$(mktemp -d 2>/dev/null || echo /tmp/voidl-fetch)"
    mkdir -p "$_tmp"
    _src=""
    if command -v git >/dev/null 2>&1; then
        if git clone --depth 1 --branch "$A_GIT_BRANCH" "$A_GIT_URL" "$_tmp/repo" >/dev/null 2>&1; then
            _src="$_tmp/repo/wireless-settings.sh"
        fi
    fi
    if [ -z "$_src" ] || [ ! -f "$_src" ]; then
        info "git unavailable or clone failed - downloading the archive instead"
        _tar="$_tmp/src.tar.gz"
        _url="$(git_archive_url "$A_GIT_URL" "$A_GIT_BRANCH")" || _url=""
        if [ -n "$_url" ] && http_get "$_url" "$_tar"; then
            mkdir -p "$_tmp/x"
            tar -xzf "$_tar" -C "$_tmp/x" 2>/dev/null
            _src="$(find "$_tmp/x" -type f -name wireless-settings.sh 2>/dev/null | head -n 1)"
        fi
    fi
    if [ -n "$_src" ] && [ -f "$_src" ]; then
        mkdir -p /usr/local/bin
        cp "$_src" /usr/local/bin/void-wireless
        chmod 0755 /usr/local/bin/void-wireless 2>/dev/null || true
        ok "installed void-wireless (wireless settings TUI)"
        logf "installed void-wireless"
    else
        warn "could not fetch wireless-settings.sh - install void-wireless manually"
    fi
    rm -rf "$_tmp" 2>/dev/null || true
    return 0
}

# ---------------------------------------------------------------------------
#  Summary + main
# ---------------------------------------------------------------------------
print_summary() {
    section "Selected configuration"
    log "    Hostname        : $A_HOSTNAME"
    log "    Device          : $A_DEVICE ($D_ARCH)"
    log "    Locale / TZ     : $A_LOCALE / $A_TIMEZONE"
    log "    Keymap          : $A_KEYMAP"
    log "    User            : $A_USERNAME (sudo: $A_SUDO)"
    log "    Desktop         : $A_DESKTOP"
    log "    Display manager : $A_DISPLAY_MANAGER (autologin: $A_AUTOLOGIN)"
    log "    Network         : ${A_NET_MODE:-ethernet} / $A_NET_SERVICE"
    [ -n "$A_WIFI_SSID" ] && log "    Wi-Fi           : $A_WIFI_SSID on ${A_WIFI_IFACE:-auto} ($A_WIFI_STACK)"
    log "    Bluetooth       : $A_BLUETOOTH"
    log "    Swap            : $A_SWAP_MODE ($A_SWAP_SIZE MB)"
    log "    SSH             : $A_SSH (port $A_SSH_PORT)"
    log "    VNC             : $A_VNC ($A_VNC_MODE)"
    log "    Remote mode     : $A_REMOTE_MODE (banner: $A_IP_BANNER)"
    log "    Kernel          : $A_KERNEL (firmware: $A_FIRMWARE)"
    [ -n "$A_EXTRAS" ] && log "    Extras          : $A_EXTRAS"
    log ""
}

section() {
    [ "$QUIET" = 1 ] && return 0
    if [ "$INTERACTIVE" = 1 ]; then
        ui_clear
        ui_header "$1"
    else
        log ""
        log "== $1 =="
    fi
}

run_wizard() {
    ui_clear
    ui_header "Welcome"
    printf 'This tool configures a freshly installed Void Linux system.\n\n'
    printf '  Machine : %s\n' "${D_MACHINE:-unknown}"
    printf '  Arch    : %s   (%s)\n' "$D_ARCH" "$( [ "$D_MUSL" = 1 ] && echo musl || echo glibc )"
    printf '  Memory  : %s MB\n' "$D_MEM_MB"
    printf '  Root fs : %s\n' "$D_ROOT_FSTYPE"
    if [ "$D_IS_RPI" = 1 ]; then printf '  Board   : %s\n' "$D_RPI_MODEL"; fi
    printf '\n'
    ui_pause

    prompt_device
    prompt_hostname
    prompt_locale
    prompt_timezone
    prompt_keymap
    prompt_user
    prompt_desktop
    prompt_display_manager
    prompt_network
    case "${A_NET_MODE:-ethernet}" in
        wifi|both) prompt_wifi ;;
    esac
    prompt_bluetooth
    prompt_swap
    prompt_remote
    prompt_firmware
    prompt_extras

    ui_clear
    ui_header "Review"
    print_summary
    ui_confirm "Apply this configuration now?" "yes" || die "aborted by user"
    apply_all
    ui_clear
    ui_header "Finished"
    printf 'All done.  Reboot to apply everything:\n\n    reboot\n\n'
    ui_pause
}

apply_all() {
    apply_identity
    apply_user
    apply_desktop
    apply_display_manager
    apply_network
    apply_bluetooth
    apply_swap
    apply_ssh
    apply_vnc
    apply_remote
    apply_firmware
    apply_extras
    apply_bootloader
    fetch_wireless_tool
    apply_cleanup
    log ""
    if [ "$DRY_RUN" = 1 ]; then
        log "Dry run - nothing was changed."
    else
        ok "configuration applied. Reboot to use it."
    fi
}

usage() {
    cat <<EOF
VoidL ToolKit $VERSION - first-boot configurator for Void Linux

Usage: $0 [options]

Options:
  --answers FILE   read answers from FILE (KEY=VALUE per line), non-interactive
  --dump-answers   print the current answers as an answers file and exit
  --dry-run        show what would be done, change nothing
  --yes            accept all defaults (still interactive unless --answers)
  --force          skip the "installed system" check
  --no-install     never call xbps-install (for testing)
  --root DIR       operate on DIR instead of / (for testing)
  --no-color       disable colours
  --quiet          less output
  --log FILE       also write a log to FILE
  --version        print the version and exit
  --help           this help

Answers file keys (all optional, defaults in brackets):
  DEVICE [auto]        x86_64 i686 aarch64 armv7hl armv6hl riscv64 ppc64 other
  HOSTNAME [void]
  LOCALE [en_US.UTF-8] TIMEZONE [UTC] KEYMAP [us] KEYBOARD_LAYOUT [us]
  USERNAME [user] USER_PASSWORD USER_FULLNAME USER_GROUPS SUDO [yes]
  DESKTOP [none]       xfce lxqt mate cinnamon gnome kde-plasma i3 sway minimal
  DISPLAY_MANAGER [none] lightdm sddm gdm lxdm
  AUTOLOGIN [no] AUTOLOGIN_USER
  NET_MODE [ethernet]  ethernet wifi both none
  NET_SERVICE [dhcpcd] dhcpcd NetworkManager connman static
  WIFI_IFACE WIFI_SSID WIFI_PASSWORD WIFI_HIDDEN [no] WIFI_STACK [wpa_supplicant]
  STATIC_IP STATIC_GATEWAY STATIC_DNS
  BLUETOOTH [no] BLUETOOTH_ADAPTER
  SWAP_MODE [none]      none swapfile zram
  SWAP_SIZE [2048]      size in MB
  SSH [no] SSH_PORT [22] SSH_ROOT_LOGIN [no] SSH_PASSWORD_AUTH [yes]
  VNC [no] VNC_MODE [virtual] VNC_PASSWORD VNC_GEOMETRY [1280x800] VNC_DISPLAY [1]
  REMOTE_MODE [lan]     lan gadget none
  IP_BANNER [yes]
  KERNEL [linux]        linux linux-lts rpi-kernel
  FIRMWARE [yes] MICROCODE [auto]
  EXTRAS [none]         firefox media libreoffice devel all <pkgs>
  GIT_URL [$A_GIT_URL] GIT_BRANCH [$A_GIT_BRANCH]
  SKIP_FETCH [no]

Examples:
  sudo sh ToolKit.sh
  sudo sh ToolKit.sh --answers ./my-setup.conf
  sudo sh ToolKit.sh --dry-run --answers ./my-setup.conf
  sudo sh ToolKit.sh --dump-answers > my-setup.conf
EOF
}

# ---------------------------------------------------------------------------
#  Entry point
# ---------------------------------------------------------------------------
main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --answers)      ANSWERS_FILE="$2"; shift 2 ;;
            --dump-answers) DUMP_ANSWERS=1; shift ;;
            --dry-run)      DRY_RUN=1; shift ;;
            --yes)          YES=1; shift ;;
            --force)        FORCE=1; shift ;;
            --no-install)   NO_INSTALL=1; shift ;;
            --root)         ROOT="${2%/}/"; shift 2 ;;
            --no-color)     NO_COLOR=1; shift ;;
            --quiet)        QUIET=1; shift ;;
            --log)          LOG_FILE="$2"; shift 2 ;;
            --version|-v)   echo "VoidL ToolKit $VERSION"; exit 0 ;;
            --help|-h)      usage; exit 0 ;;
            *)              err "unknown option: $1"; usage >&2; exit 2 ;;
        esac
    done

    if [ "$NO_COLOR" = 1 ] || [ ! -t 1 ]; then
        C_R=""; C_G=""; C_Y=""; C_B=""; C_N=""; C_BOLD=""
    else
        C_R="${ESC}[1;31m"; C_G="${ESC}[1;32m"; C_Y="${ESC}[1;33m"
        C_B="${ESC}[1;34m"; C_N="${ESC}[0m"; C_BOLD="${ESC}[1m"
    fi

    if [ -n "$ANSWERS_FILE" ]; then
        load_answers "$ANSWERS_FILE"
        INTERACTIVE=0
    elif ui_supported; then
        INTERACTIVE=1
    else
        INTERACTIVE=0
    fi

    if [ "$(id -u)" != 0 ] && [ "$DRY_RUN" != 1 ]; then
        die "this tool must run as root (try: sudo sh $0)"
    fi

    detect_arch
    detect_machine
    detect_cpu
    detect_system

    if [ -n "${DUMP_ANSWERS:-}" ]; then
        dump_answers
        exit 0
    fi

    if [ "$INTERACTIVE" = 1 ]; then ui_init; fi

    if [ "$FORCE" != 1 ] && [ "$DRY_RUN" != 1 ] && ! is_installed_system; then
        warn "this does not look like an installed Void Linux system"
        warn "(root filesystem is '$D_ROOT_FSTYPE', xbps-install: $(has_cmd xbps-install && echo yes || echo no))"
        warn "the live installer environment must not be configured with this tool."
        warn "run it again after the installation has finished."
        [ "$INTERACTIVE" = 1 ] && ui_pause
        exit 1
    fi

    if [ "$INTERACTIVE" = 1 ]; then
        run_wizard
    else
        [ -n "$A_USERNAME" ] || A_USERNAME="user"
        [ -n "$A_KEYBOARD_LAYOUT" ] || A_KEYBOARD_LAYOUT="$A_KEYMAP"
        [ -n "$A_USER_GROUPS" ] || A_USER_GROUPS="wheel audio video input plugdev bluetooth lp storage network"
        [ -n "$A_LOCALE" ] || A_LOCALE="en_US.UTF-8"
        print_summary
        apply_all
    fi

    if [ "$INTERACTIVE" = 1 ]; then ui_restore; fi
}

main "$@"
