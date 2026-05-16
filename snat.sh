#!/usr/bin/sh
#
# vpn-fw-helper.sh
#
# 功能:
# 1. 判断系统类型
# 2. 自动识别当前可用/活跃防火墙后端: firewalld / ufw / nftables / iptables
# 3. 检测并配置 IPv4 转发
# 4. 检测并展示默认防火墙策略: 入站 / 出站 / 转发
# 5. 显示当前网卡，用户按编号选择“当前配置接口”
# 6. 按接口分别维护 SNAT 源网段
# 7. 按接口分别维护端口/协议放行规则（仅服务器本机 INPUT）
# 8. 应用并持久化保存配置
#
# 设计原则:
# - 不关闭系统防火墙
# - 不把 INPUT/OUTPUT/FORWARD 默认策略改成全允许
# - 只放行用户指定的协议/端口
# - SNAT 只针对用户指定的源网段 + 所属接口
# - 支持多个出口接口并行配置，互不覆盖
#

PROGRAM_NAME="vpn-fw-helper"
BASE_DIR="/etc/${PROGRAM_NAME}"
CONFIG_FILE="${BASE_DIR}/config.env"
SNAT_STORE="${BASE_DIR}/snat.rules"
PORT_STORE="${BASE_DIR}/port.rules"
SYSCTL_FILE="/etc/sysctl.d/99-${PROGRAM_NAME}.conf"

UFW_BEFORE_RULES="/etc/ufw/before.rules"
UFW_SYSCTL_FILE="/etc/ufw/sysctl.conf"

UFW_NAT_BEGIN="# VPNFWHELPER NAT START"
UFW_NAT_END="# VPNFWHELPER NAT END"
UFW_FILTER_BEGIN="# VPNFWHELPER FILTER START"
UFW_FILTER_END="# VPNFWHELPER FILTER END"

IPTABLES_CHAIN_INPUT="VPNFWHELPER_INPUT"
IPTABLES_CHAIN_FORWARD="VPNFWHELPER_FORWARD"
IPTABLES_CHAIN_POSTROUTING="VPNFWHELPER_POSTROUTING"

NFT_RULES_FILE="${BASE_DIR}/nftables.rules"
NFT_APPLY_SCRIPT="/usr/local/sbin/${PROGRAM_NAME}-nft-apply.sh"
NFT_SYSTEMD_SERVICE="/etc/systemd/system/${PROGRAM_NAME}-nftables.service"
NFT_OPENRC_SERVICE="/etc/init.d/${PROGRAM_NAME}-nftables"

IPTABLES_RULES_FILE="${BASE_DIR}/iptables.rules"
IPTABLES_APPLY_SCRIPT="/usr/local/sbin/${PROGRAM_NAME}-iptables-restore.sh"
IPTABLES_SYSTEMD_SERVICE="/etc/systemd/system/${PROGRAM_NAME}-iptables.service"
IPTABLES_OPENRC_SERVICE="/etc/init.d/${PROGRAM_NAME}-iptables"

TTY_IN="/dev/tty"
SELF_UPDATE_URL_PRIMARY="https://www.feijiangkeji.com/assets/uploads/snat.sh"
SELF_UPDATE_URL_SECONDARY="https://pan.yydy.link:2023/d/share/script/snat.sh"

TMP_BASE="${TMPDIR:-/tmp}"
SNAT_TMP="$(mktemp "${TMP_BASE}/${PROGRAM_NAME}.snat.XXXXXX")"
PORT_TMP="$(mktemp "${TMP_BASE}/${PROGRAM_NAME}.port.XXXXXX")"
IFACE_TMP="$(mktemp "${TMP_BASE}/${PROGRAM_NAME}.iface.XXXXXX")"
VIEW_TMP1="$(mktemp "${TMP_BASE}/${PROGRAM_NAME}.view1.XXXXXX")"
VIEW_TMP2="$(mktemp "${TMP_BASE}/${PROGRAM_NAME}.view2.XXXXXX")"
WORK_TMP1="$(mktemp "${TMP_BASE}/${PROGRAM_NAME}.work1.XXXXXX")"
WORK_TMP2="$(mktemp "${TMP_BASE}/${PROGRAM_NAME}.work2.XXXXXX")"
WORK_TMP3="$(mktemp "${TMP_BASE}/${PROGRAM_NAME}.work3.XXXXXX")"
WORK_TMP4="$(mktemp "${TMP_BASE}/${PROGRAM_NAME}.work4.XXXXXX")"
SELF_UPDATE_TMP="$(mktemp "${TMP_BASE}/${PROGRAM_NAME}.self.XXXXXX")"

OS_ID=""
OS_LIKE=""
OS_NAME=""
OS_FAMILY=""
PKG_MGR=""
BACKEND=""
CURRENT_IF=""
DEFAULT_WAN_IF=""
IP_FORWARD_PLAN="nochange"
FW_INPUT_PLAN="nochange"
FW_OUTPUT_PLAN="nochange"
FW_FORWARD_PLAN="nochange"

fw_in_policy=""
fw_out_policy=""
fw_fwd_policy=""
fw_policy_detail=""

SELECTED_IF=""
SELECTED_PROTO=""
USER_INPUT=""

FIREWALLD_POLICY_ALLOW_PRIO="0"
FIREWALLD_POLICY_DENY_PRIO="32000"

COLOR_ENABLED="0"
CLR_RESET=""
CLR_RED=""
CLR_GREEN=""
CLR_YELLOW=""
CLR_BLUE=""
CLR_PURPLE=""
SCRIPT_SELF=""

cleanup() {
    rm -f "$SNAT_TMP" "$PORT_TMP" "$IFACE_TMP" "$VIEW_TMP1" "$VIEW_TMP2" \
          "$WORK_TMP1" "$WORK_TMP2" "$WORK_TMP3" "$WORK_TMP4" "$SELF_UPDATE_TMP"
}
trap cleanup EXIT INT TERM

msg() {
    printf '%s\n' "$*"
}

err() {
    printf '错误: %s\n' "$*" >&2
}

init_colors() {
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
        COLOR_ENABLED="1"
        _esc="$(printf '\033')"
        CLR_RESET="${_esc}[0m"
        CLR_RED="${_esc}[31m"
        CLR_GREEN="${_esc}[32m"
        CLR_YELLOW="${_esc}[33m"
        CLR_BLUE="${_esc}[34m"
        CLR_PURPLE="${_esc}[35m"
    else
        COLOR_ENABLED="0"
        CLR_RESET=""
        CLR_RED=""
        CLR_GREEN=""
        CLR_YELLOW=""
        CLR_BLUE=""
        CLR_PURPLE=""
    fi
}

color_wrap() {
    _color="$1"
    shift
    if [ "$COLOR_ENABLED" = "1" ] && [ -n "$_color" ]; then
        printf '%s%s%s' "$_color" "$*" "$CLR_RESET"
    else
        printf '%s' "$*"
    fi
}

format_policy_value() {
    case "$1" in
        允许|默认允许|allow|ACCEPT|accept) color_wrap "$CLR_GREEN" "$1" ;;
        拒绝|默认拒绝|deny|DROP|drop|REJECT|reject) color_wrap "$CLR_RED" "$1" ;;
        不修改|nochange) color_wrap "$CLR_YELLOW" "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}

format_plan_value() {
    _label="$(policy_plan_label "$1")"
    format_policy_value "$_label"
}

format_iface_value() {
    color_wrap "$CLR_BLUE" "$1"
}

format_count_value() {
    color_wrap "$CLR_PURPLE" "$1"
}

read_tty() {
    USER_INPUT=""
    if [ ! -e "$TTY_IN" ]; then
        err "当前环境没有可用的交互终端 /dev/tty"
        exit 1
    fi
    IFS= read -r USER_INPUT < "$TTY_IN"
}

pause() {
    printf '按回车继续...' > "$TTY_IN"
    read_tty
}

confirm() {
    printf '%s [y/N]: ' "$1" > "$TTY_IN"
    read_tty
    case "$USER_INPUT" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

require_root() {
    if [ "$(id -u 2>/dev/null)" != "0" ]; then
        err "请使用 root 运行此脚本。"
        exit 1
    fi
}

count_nonempty_lines() {
    if [ ! -f "$1" ]; then
        echo 0
        return
    fi
    awk 'NF { c++ } END { print c+0 }' "$1"
}

backup_file() {
    _f="$1"
    if [ -f "$_f" ]; then
        _ts="$(date +%Y%m%d%H%M%S 2>/dev/null || echo now)"
        cp -f "$_f" "${_f}.bak.${_ts}" 2>/dev/null || true
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

resolve_script_self() {
    _candidate="$0"

    if [ -n "$_candidate" ] && [ -f "$_candidate" ]; then
        case "$_candidate" in
            /*) SCRIPT_SELF="$_candidate" ;;
            *) SCRIPT_SELF="$(cd "$(dirname "$_candidate")" 2>/dev/null && pwd)/$(basename "$_candidate")" ;;
        esac
        return 0
    fi

    _resolved="$(command -v "$_candidate" 2>/dev/null | head -n 1)"
    if [ -n "$_resolved" ] && [ -f "$_resolved" ]; then
        SCRIPT_SELF="$_resolved"
        return 0
    fi

    SCRIPT_SELF=""
    return 1
}

has_systemd() {
    command_exists systemctl && [ -d /run/systemd/system ]
}

has_openrc() {
    command_exists rc-service && command_exists rc-update
}

enable_service() {
    _svc="$1"
    if has_systemd; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable "$_svc" >/dev/null 2>&1 || true
        return 0
    fi
    if has_openrc; then
        rc-update add "$_svc" default >/dev/null 2>&1 || true
        return 0
    fi
    return 0
}

download_to_file() {
    _url="$1"
    _dst="$2"

    if command_exists curl; then
        curl -fsSL --connect-timeout 15 --max-time 120 "$_url" -o "$_dst"
        return $?
    fi

    if command_exists wget; then
        wget -q -T 15 -O "$_dst" "$_url"
        return $?
    fi

    ensure_package curl curl || return 1
    curl -fsSL --connect-timeout 15 --max-time 120 "$_url" -o "$_dst"
}

normalize_downloaded_script() {
    _src="$1"
    _dst="$2"
    awk '{ sub(/\r$/, ""); print }' "$_src" > "$_dst"
}

validate_downloaded_script() {
    _file="$1"
    [ -s "$_file" ] || return 1
    _first_line="$(awk 'NR==1 { sub(/^\xef\xbb\xbf/, ""); print; exit }' "$_file")"

    case "$_first_line" in
        '#!/bin/sh'|'#!/usr/bin/sh'|'#!/usr/bin/env sh'|'#!/bin/bash'|'#!/usr/bin/bash'|'#!/usr/bin/env bash')
            ;;
        *)
            return 1
            ;;
    esac

    grep -q '^PROGRAM_NAME="vpn-fw-helper"$' "$_file" || return 1
    grep -q '^main_menu() {$' "$_file" || return 1
    return 0
}

download_with_retries() {
    _url="$1"
    _tries="$2"
    _n=1

    while [ "$_n" -le "$_tries" ]; do
        : > "$SELF_UPDATE_TMP"
        msg "尝试更新(${_n}/${_tries}): ${_url}"
        if download_to_file "$_url" "$WORK_TMP1"; then
            normalize_downloaded_script "$WORK_TMP1" "$SELF_UPDATE_TMP"
            if validate_downloaded_script "$SELF_UPDATE_TMP"; then
                return 0
            fi
            err "下载内容校验失败，内容不像有效的 snat.sh。"
        else
            err "下载失败。"
        fi
        _n=$((_n + 1))
    done

    return 1
}

update_self_script() {
    if ! resolve_script_self; then
        err "无法确定当前脚本路径，不能执行自更新。"
        return 1
    fi

    msg "当前脚本路径: ${SCRIPT_SELF}"
    msg "开始从主地址更新..."
    if ! download_with_retries "$SELF_UPDATE_URL_PRIMARY" 3; then
        msg "主地址连续 3 次更新失败，开始切换备用地址..."
        if ! download_with_retries "$SELF_UPDATE_URL_SECONDARY" 3; then
            err "主地址和备用地址都更新失败。"
            return 1
        fi
    fi

    if [ -f "$SCRIPT_SELF" ]; then
        backup_file "$SCRIPT_SELF"
    fi

    if cmp -s "$SELF_UPDATE_TMP" "$SCRIPT_SELF" 2>/dev/null; then
        msg "当前脚本已经是最新内容，无需覆盖。"
        return 0
    fi

    cat "$SELF_UPDATE_TMP" > "$SCRIPT_SELF" || {
        err "覆盖当前脚本失败。"
        return 1
    }
    chmod 755 "$SCRIPT_SELF" >/dev/null 2>&1 || true

    msg ""
    msg "脚本更新成功。"
    msg "已备份旧文件，建议立即重新执行最新的 snat.sh。"
    exit 0
}

start_service() {
    _svc="$1"
    if has_systemd; then
        systemctl start "$_svc" >/dev/null 2>&1 || true
        return 0
    fi
    if has_openrc; then
        rc-service "$_svc" start >/dev/null 2>&1 || true
        return 0
    fi
    return 0
}

detect_os() {
    if [ -r /etc/os-release ]; then
        OS_ID="$(awk -F= '/^ID=/{gsub(/"/,"",$2); print $2}' /etc/os-release)"
        OS_LIKE="$(awk -F= '/^ID_LIKE=/{gsub(/"/,"",$2); print $2}' /etc/os-release)"
        OS_NAME="$(awk -F= '/^PRETTY_NAME=/{sub(/^PRETTY_NAME=/,""); gsub(/"/,""); print}' /etc/os-release)"
    else
        OS_ID="unknown"
        OS_LIKE=""
        OS_NAME="unknown"
    fi

    case " ${OS_ID} ${OS_LIKE} " in
        *" ubuntu "*|*" debian "*|*" kali "*)
            OS_FAMILY="debian"
            PKG_MGR="apt"
            ;;
        *" centos "*|*" rhel "*|*" rocky "*|*" almalinux "*|*" fedora "*)
            OS_FAMILY="rhel"
            if command_exists dnf; then
                PKG_MGR="dnf"
            else
                PKG_MGR="yum"
            fi
            ;;
        *" alpine "*)
            OS_FAMILY="alpine"
            PKG_MGR="apk"
            ;;
        *" arch "*)
            OS_FAMILY="arch"
            PKG_MGR="pacman"
            ;;
        *)
            if command_exists apt-get; then
                OS_FAMILY="debian"
                PKG_MGR="apt"
            elif command_exists dnf; then
                OS_FAMILY="rhel"
                PKG_MGR="dnf"
            elif command_exists yum; then
                OS_FAMILY="rhel"
                PKG_MGR="yum"
            elif command_exists apk; then
                OS_FAMILY="alpine"
                PKG_MGR="apk"
            elif command_exists pacman; then
                OS_FAMILY="arch"
                PKG_MGR="pacman"
            else
                OS_FAMILY="unknown"
                PKG_MGR=""
            fi
            ;;
    esac
}

pkg_update() {
    case "$PKG_MGR" in
        apt) apt-get update ;;
        dnf) dnf makecache -y ;;
        yum) yum makecache -y ;;
        apk) apk update ;;
        pacman) pacman -Sy --noconfirm ;;
        *)
            err "无法识别包管理器，无法自动安装依赖。"
            return 1
            ;;
    esac
}

pkg_install() {
    case "$PKG_MGR" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
        dnf) dnf install -y "$@" ;;
        yum) yum install -y "$@" ;;
        apk) apk add "$@" ;;
        pacman) pacman -S --noconfirm --needed "$@" ;;
        *)
            err "无法识别包管理器，无法自动安装依赖。"
            return 1
            ;;
    esac
}

ensure_package() {
    _cmd="$1"
    _pkg="$2"
    if command_exists "$_cmd"; then
        return 0
    fi
    msg "检测到缺少命令: ${_cmd}，准备安装软件包: ${_pkg}"
    pkg_update || return 1
    pkg_install "$_pkg" || return 1
}

detect_backend() {
    if command_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        echo "firewalld"
        return
    fi

    if command_exists ufw && ufw status 2>/dev/null | grep -qi '^Status: active'; then
        echo "ufw"
        return
    fi

    if command_exists nft; then
        if nft list ruleset 2>/dev/null | grep -q '[^[:space:]]'; then
            :
        else
            echo "nftables"
            return
        fi
    fi

    echo "iptables"
}

get_ip_forward_runtime_value() {
    if [ -r /proc/sys/net/ipv4/ip_forward ]; then
        cat /proc/sys/net/ipv4/ip_forward 2>/dev/null
        return
    fi
    if command_exists sysctl; then
        sysctl -n net.ipv4.ip_forward 2>/dev/null
        return
    fi
    echo "unknown"
}

ip_forward_runtime_label() {
    _v="$(get_ip_forward_runtime_value)"
    case "$_v" in
        1) echo "已开启" ;;
        0) echo "未开启" ;;
        *) echo "未知" ;;
    esac
}

ip_forward_plan_label() {
    case "$IP_FORWARD_PLAN" in
        permanent) echo "永久开启" ;;
        temporary) echo "临时开启" ;;
        nochange|"") echo "不修改" ;;
        *) echo "$IP_FORWARD_PLAN" ;;
    esac
}

policy_plan_label() {
    case "$1" in
        allow) echo "默认允许" ;;
        deny) echo "默认拒绝" ;;
        nochange|"") echo "不修改" ;;
        *) echo "$1" ;;
    esac
}

get_policy_plan_value() {
    case "$1" in
        input) printf '%s\n' "$FW_INPUT_PLAN" ;;
        output) printf '%s\n' "$FW_OUTPUT_PLAN" ;;
        forward) printf '%s\n' "$FW_FORWARD_PLAN" ;;
        *) printf '%s\n' "nochange" ;;
    esac
}

set_policy_plan_value() {
    case "$1" in
        input) FW_INPUT_PLAN="$2" ;;
        output) FW_OUTPUT_PLAN="$2" ;;
        forward) FW_FORWARD_PLAN="$2" ;;
    esac
}

reset_fw_policy_cache() {
    fw_in_policy="未知"
    fw_out_policy="未知"
    fw_fwd_policy="未知"
    fw_policy_detail=""
}

normalize_policy_label() {
    case "$1" in
        ACCEPT|accept|ALLOW|allow) echo "允许" ;;
        DROP|drop|REJECT|reject|DENY|deny) echo "拒绝" ;;
        *) echo "未知" ;;
    esac
}

detect_iptables_policies() {
    _input_raw="$(iptables -L INPUT 2>/dev/null | awk '/^Chain INPUT / {gsub(/[()]/,""); for(i=1;i<=NF;i++){if($i=="policy"){print $(i+1); exit}}}')"
    _output_raw="$(iptables -L OUTPUT 2>/dev/null | awk '/^Chain OUTPUT / {gsub(/[()]/,""); for(i=1;i<=NF;i++){if($i=="policy"){print $(i+1); exit}}}')"
    _forward_raw="$(iptables -L FORWARD 2>/dev/null | awk '/^Chain FORWARD / {gsub(/[()]/,""); for(i=1;i<=NF;i++){if($i=="policy"){print $(i+1); exit}}}')"

    fw_in_policy="$(normalize_policy_label "$_input_raw")"
    fw_out_policy="$(normalize_policy_label "$_output_raw")"
    fw_fwd_policy="$(normalize_policy_label "$_forward_raw")"
    fw_policy_detail="iptables原始策略: INPUT=${_input_raw:-unknown}, OUTPUT=${_output_raw:-unknown}, FORWARD=${_forward_raw:-unknown}"
}

detect_nftables_policies() {
    _input_raw="$(nft list ruleset 2>/dev/null | awk '
        /hook input/ {
            for (i=1;i<=NF;i++) {
                if ($i=="policy") {
                    gsub(/;/,"",$(i+1))
                    print $(i+1)
                    exit
                }
            }
        }'
    )"

    _output_raw="$(nft list ruleset 2>/dev/null | awk '
        /hook output/ {
            for (i=1;i<=NF;i++) {
                if ($i=="policy") {
                    gsub(/;/,"",$(i+1))
                    print $(i+1)
                    exit
                }
            }
        }'
    )"

    _forward_raw="$(nft list ruleset 2>/dev/null | awk '
        /hook forward/ {
            for (i=1;i<=NF;i++) {
                if ($i=="policy") {
                    gsub(/;/,"",$(i+1))
                    print $(i+1)
                    exit
                }
            }
        }'
    )"

    fw_in_policy="$(normalize_policy_label "$_input_raw")"
    fw_out_policy="$(normalize_policy_label "$_output_raw")"
    fw_fwd_policy="$(normalize_policy_label "$_forward_raw")"
    fw_policy_detail="nftables原始策略: input=${_input_raw:-unknown}, output=${_output_raw:-unknown}, forward=${_forward_raw:-unknown}"
}

detect_ufw_policies() {
    _status="$(ufw status verbose 2>/dev/null)"

    _incoming_raw="$(printf '%s\n' "$_status" | awk -F': ' '/Default:/{
        split($2,a,",")
        gsub(/^[ \t]+|[ \t]+$/,"",a[1])
        print a[1]
        exit
    }')"

    _outgoing_raw="$(printf '%s\n' "$_status" | awk -F': ' '/Default:/{
        split($2,a,",")
        gsub(/^[ \t]+|[ \t]+$/,"",a[2])
        print a[2]
        exit
    }')"

    _routed_raw="$(printf '%s\n' "$_status" | awk -F': ' '/Default:/{
        split($2,a,",")
        gsub(/^[ \t]+|[ \t]+$/,"",a[3])
        print a[3]
        exit
    }')"

    fw_in_policy="$(normalize_policy_label "$_incoming_raw")"
    fw_out_policy="$(normalize_policy_label "$_outgoing_raw")"
    fw_fwd_policy="$(normalize_policy_label "$_routed_raw")"
    fw_policy_detail="ufw原始默认策略: incoming=${_incoming_raw:-unknown}, outgoing=${_outgoing_raw:-unknown}, routed=${_routed_raw:-unknown}"
}

detect_firewalld_policies() {
    _default_zone="$(firewall-cmd --get-default-zone 2>/dev/null | head -n 1)"
    _zone_target=""
    _zone_info=""
    _forward_flag=""
    _direct_rules="$(firewall-cmd --direct --get-all-rules 2>/dev/null)"
    if [ -n "$_default_zone" ]; then
        _zone_info="$(firewall-cmd --info-zone="$_default_zone" 2>/dev/null)"
        _zone_target="$(printf '%s\n' "$_zone_info" | awk -F': ' '/^[[:space:]]*target:/ {print $2; exit}')"
        _forward_flag="$(printf '%s\n' "$_zone_info" | awk -F': ' '/^[[:space:]]*forward:/ {print $2; exit}')"
    fi

    case "$_zone_target" in
        ACCEPT|accept)
            fw_in_policy="允许"
            ;;
        DROP|drop|REJECT|reject)
            fw_in_policy="拒绝"
            ;;
        default|DEFAULT|"")
            fw_in_policy="拒绝"
            ;;
        *)
            fw_in_policy="拒绝"
            ;;
    esac

    # firewalld 的常规主机模型下，未显式允许的入站默认阻断，出站默认允许。
    fw_out_policy="允许"

    case "$_forward_flag" in
        yes|true|on)
            fw_fwd_policy="拒绝"
            fw_policy_detail="firewalld默认区域=${_default_zone:-unknown}, zone target=${_zone_target:-default}, intra-zone forward=${_forward_flag}, inter-zone默认拒绝"
            ;;
        no|false|off|"")
            fw_fwd_policy="拒绝"
            fw_policy_detail="firewalld默认区域=${_default_zone:-unknown}, zone target=${_zone_target:-default}, intra-zone forward=${_forward_flag:-no}, inter-zone默认拒绝"
            ;;
        *)
            fw_fwd_policy="拒绝"
            fw_policy_detail="firewalld默认区域=${_default_zone:-unknown}, zone target=${_zone_target:-default}, intra-zone forward=${_forward_flag:-unknown}, inter-zone默认拒绝"
            ;;
    esac

    _input_direct="$(printf '%s\n' "$_direct_rules" | awk -v ap="$FIREWALLD_POLICY_ALLOW_PRIO" -v dp="$FIREWALLD_POLICY_DENY_PRIO" '
        $1=="ipv4" && $2=="filter" && $3=="INPUT" && $4==ap && $0 ~ /-j ACCEPT$/ { print "允许"; exit }
        $1=="ipv4" && $2=="filter" && $3=="INPUT" && $4==dp && $0 ~ /-j DROP$/ { print "拒绝"; exit }
    ')"
    _output_direct="$(printf '%s\n' "$_direct_rules" | awk -v ap="$FIREWALLD_POLICY_ALLOW_PRIO" -v dp="$FIREWALLD_POLICY_DENY_PRIO" '
        $1=="ipv4" && $2=="filter" && $3=="OUTPUT" && $4==ap && $0 ~ /-j ACCEPT$/ { print "允许"; exit }
        $1=="ipv4" && $2=="filter" && $3=="OUTPUT" && $4==dp && $0 ~ /-j DROP$/ { print "拒绝"; exit }
    ')"
    _forward_direct="$(printf '%s\n' "$_direct_rules" | awk -v ap="$FIREWALLD_POLICY_ALLOW_PRIO" -v dp="$FIREWALLD_POLICY_DENY_PRIO" '
        $1=="ipv4" && $2=="filter" && $3=="FORWARD" && $4==ap && $0 ~ /-j ACCEPT$/ { print "允许"; exit }
        $1=="ipv4" && $2=="filter" && $3=="FORWARD" && $4==dp && $0 ~ /-j DROP$/ { print "拒绝"; exit }
    ')"

    [ -n "$_input_direct" ] && fw_in_policy="$_input_direct"
    [ -n "$_output_direct" ] && fw_out_policy="$_output_direct"
    [ -n "$_forward_direct" ] && fw_fwd_policy="$_forward_direct"
}

detect_firewall_policies() {
    reset_fw_policy_cache

    case "$BACKEND" in
        iptables)
            detect_iptables_policies
            ;;
        nftables)
            detect_nftables_policies
            ;;
        ufw)
            detect_ufw_policies
            ;;
        firewalld)
            detect_firewalld_policies
            ;;
        *)
            fw_in_policy="未知"
            fw_out_policy="未知"
            fw_fwd_policy="未知"
            fw_policy_detail="未识别后端，无法判断默认策略"
            ;;
    esac
}

configure_ip_forward_menu() {
    while :; do
        msg ""
        msg "===== IPv4 转发配置 ====="
        msg "当前系统运行状态: $(ip_forward_runtime_label)"
        msg "当前脚本计划: $(ip_forward_plan_label)"
        msg ""
        msg "1) 永久开启"
        msg "2) 临时开启"
        msg "3) 不修改"
        msg "4) 仅刷新查看当前状态"
        msg "0) 返回主菜单"
        printf '请选择: ' > "$TTY_IN"
        read_tty
        case "$USER_INPUT" in
            1)
                IP_FORWARD_PLAN="permanent"
                msg "已设置: IPv4 转发 = 永久开启"
                pause
                return 0
                ;;
            2)
                IP_FORWARD_PLAN="temporary"
                msg "已设置: IPv4 转发 = 临时开启"
                pause
                return 0
                ;;
            3)
                IP_FORWARD_PLAN="nochange"
                msg "已设置: IPv4 转发 = 不修改"
                pause
                return 0
                ;;
            4)
                msg "当前系统 IPv4 转发运行状态: $(ip_forward_runtime_label)"
                pause
                ;;
            0)
                return 0
                ;;
            *)
                err "无效选项。"
                pause
                ;;
        esac
    done
}

configure_single_default_policy() {
    _key="$1"
    _label="$2"
    while :; do
        msg ""
        msg "===== ${_label} 默认策略 ====="
        msg "当前计划: $(policy_plan_label "$(get_policy_plan_value "$_key")")"
        msg ""
        msg "1) 默认允许"
        msg "2) 默认拒绝"
        msg "3) 不修改"
        msg "0) 返回上一级"
        printf '请选择: ' > "$TTY_IN"
        read_tty
        case "$USER_INPUT" in
            1)
                set_policy_plan_value "$_key" "allow"
                msg "已设置: ${_label} = 默认允许"
                pause
                return 0
                ;;
            2)
                set_policy_plan_value "$_key" "deny"
                msg "已设置: ${_label} = 默认拒绝"
                pause
                return 0
                ;;
            3)
                set_policy_plan_value "$_key" "nochange"
                msg "已设置: ${_label} = 不修改"
                pause
                return 0
                ;;
            0)
                return 0
                ;;
            *)
                err "无效选项。"
                pause
                ;;
        esac
    done
}

configure_default_policy_menu() {
    while :; do
        msg ""
        msg "===== 默认策略配置 ====="
        msg "入站计划: $(policy_plan_label "$FW_INPUT_PLAN")"
        msg "出站计划: $(policy_plan_label "$FW_OUTPUT_PLAN")"
        msg "转发计划: $(policy_plan_label "$FW_FORWARD_PLAN")"
        msg ""
        msg "1) 配置默认入站策略"
        msg "2) 配置默认出站策略"
        msg "3) 配置默认转发策略"
        msg "4) 全部设为默认允许"
        msg "5) 全部设为默认拒绝"
        msg "6) 全部设为不修改"
        msg "0) 返回主菜单"
        printf '请选择: ' > "$TTY_IN"
        read_tty
        case "$USER_INPUT" in
            1) configure_single_default_policy "input" "入站" ;;
            2) configure_single_default_policy "output" "出站" ;;
            3) configure_single_default_policy "forward" "转发" ;;
            4)
                FW_INPUT_PLAN="allow"
                FW_OUTPUT_PLAN="allow"
                FW_FORWARD_PLAN="allow"
                msg "已设置: 入站/出站/转发 = 默认允许"
                pause
                ;;
            5)
                FW_INPUT_PLAN="deny"
                FW_OUTPUT_PLAN="deny"
                FW_FORWARD_PLAN="deny"
                msg "已设置: 入站/出站/转发 = 默认拒绝"
                pause
                ;;
            6)
                FW_INPUT_PLAN="nochange"
                FW_OUTPUT_PLAN="nochange"
                FW_FORWARD_PLAN="nochange"
                msg "已设置: 入站/出站/转发 = 不修改"
                pause
                ;;
            0) return 0 ;;
            *)
                err "无效选项。"
                pause
                ;;
        esac
    done
}

get_default_wan_if() {
    ip route show default 2>/dev/null | awk '
        /default/ {
            for (i=1; i<=NF; i++) {
                if ($i == "dev") {
                    print $(i+1)
                    exit
                }
            }
        }
    '
}

build_interface_cache() {
    : > "$IFACE_TMP"

    if command_exists ip; then
        ip -o link show 2>/dev/null | awk -F': ' '
            {
                name=$2
                sub(/@.*/, "", name)
                if (name != "" && name != "lo" && !seen[name]++) {
                    print name
                }
            }
        ' > "$IFACE_TMP"
    fi

    if [ ! -s "$IFACE_TMP" ] && [ -d /sys/class/net ]; then
        for _path in /sys/class/net/*; do
            [ -e "$_path" ] || continue
            _name="$(basename "$_path")"
            [ "$_name" = "lo" ] && continue
            printf '%s\n' "$_name" >> "$IFACE_TMP"
        done
        trim_file_nonempty_unique "$IFACE_TMP"
    fi
}

list_interfaces() {
    _default_if="$1"
    build_interface_cache
    if [ ! -s "$IFACE_TMP" ]; then
        msg "未检测到可用网卡。"
        return 1
    fi

    awk -v def="$_default_if" '
        {
            mark=""
            if ($0 == def) mark="  [默认出口]"
            printf "%d) %s%s\n", NR, $0, mark
        }
    ' "$IFACE_TMP"
}

choose_interface_by_number() {
    _title="$1"
    _default_if="$2"
    SELECTED_IF=""

    build_interface_cache
    if [ ! -s "$IFACE_TMP" ]; then
        err "未检测到可用网卡。"
        return 1
    fi

    while :; do
        msg ""
        msg "===== ${_title} ====="
        list_interfaces "$_default_if"
        printf '请输入网卡编号 [0返回]: ' > "$TTY_IN"
        read_tty

        case "$USER_INPUT" in
            0)
                return 0
                ;;
            '')
                err "请输入编号。"
                ;;
            *)
                if echo "$USER_INPUT" | awk '$0 ~ /^[0-9]+$/ { ok=1 } END { exit ok ? 0 : 1 }'; then
                    _chosen="$(awk -v n="$USER_INPUT" 'NR==n { print; exit }' "$IFACE_TMP")"
                    if [ -n "$_chosen" ]; then
                        SELECTED_IF="$_chosen"
                        return 0
                    fi
                fi
                err "编号无效。"
                ;;
        esac
    done
}

trim_file_nonempty_unique() {
    _src="$1"
    [ -f "$_src" ] || return 0
    awk 'NF && !seen[$0]++ { print }' "$_src" > "$WORK_TMP1"
    cat "$WORK_TMP1" > "$_src"
}

normalize_snat_file() {
    _src="$1"
    _dst="$2"
    _fallback_if="$3"
    : > "$_dst"
    [ -f "$_src" ] || return 0
    awk -F'|' -v fi="$_fallback_if" '
        NF==2 && $1 != "" && $2 != "" { print $1 "|" $2; next }
        NF==1 && $1 != "" && fi != "" { print fi "|" $1; next }
    ' "$_src" > "$_dst"
}

normalize_port_file() {
    _src="$1"
    _dst="$2"
    _fallback_if="$3"
    : > "$_dst"
    [ -f "$_src" ] || return 0
    awk -F'|' -v fi="$_fallback_if" '
        NF==3 && $1 != "" && $2 != "" && $3 != "" { print $1 "|" $2 "|" $3; next }
        NF==2 && $1 != "" && $2 != "" && fi != "" { print fi "|" $1 "|" $2; next }
    ' "$_src" > "$_dst"
}

load_saved_config() {
    mkdir -p "$BASE_DIR"
    if [ -f "$CONFIG_FILE" ]; then
        . "$CONFIG_FILE"
    fi

    if [ -z "$CURRENT_IF" ] && [ -n "${WAN_IF:-}" ]; then
        CURRENT_IF="$WAN_IF"
    fi

    [ -n "$IP_FORWARD_PLAN" ] || IP_FORWARD_PLAN="nochange"
    [ -n "$FW_INPUT_PLAN" ] || FW_INPUT_PLAN="nochange"
    [ -n "$FW_OUTPUT_PLAN" ] || FW_OUTPUT_PLAN="nochange"
    [ -n "$FW_FORWARD_PLAN" ] || FW_FORWARD_PLAN="nochange"

    normalize_snat_file "$SNAT_STORE" "$SNAT_TMP" "$CURRENT_IF"
    normalize_port_file "$PORT_STORE" "$PORT_TMP" "$CURRENT_IF"

    trim_file_nonempty_unique "$SNAT_TMP"
    trim_file_nonempty_unique "$PORT_TMP"
}

proto_label() {
    case "$1" in
        tcp) echo "tcp" ;;
        udp) echo "udp" ;;
        tcpudp) echo "tcp+udp" ;;
        icmp) echo "icmp" ;;
        *) echo "$1" ;;
    esac
}

save_current_config() {
    mkdir -p "$BASE_DIR"
    cat > "$CONFIG_FILE" <<EOF
CURRENT_IF='${CURRENT_IF}'
BACKEND='${BACKEND}'
OS_FAMILY='${OS_FAMILY}'
PKG_MGR='${PKG_MGR}'
IP_FORWARD_PLAN='${IP_FORWARD_PLAN}'
FW_INPUT_PLAN='${FW_INPUT_PLAN}'
FW_OUTPUT_PLAN='${FW_OUTPUT_PLAN}'
FW_FORWARD_PLAN='${FW_FORWARD_PLAN}'
EOF
    cp -f "$SNAT_TMP" "$SNAT_STORE"
    cp -f "$PORT_TMP" "$PORT_STORE"
}

read_saved_value() {
    _key="$1"
    if [ ! -f "$CONFIG_FILE" ]; then
        echo ""
        return
    fi
    (
        . "$CONFIG_FILE" 2>/dev/null
        if [ -z "${CURRENT_IF:-}" ] && [ -n "${WAN_IF:-}" ]; then
            CURRENT_IF="$WAN_IF"
        fi
        case "$_key" in
            CURRENT_IF) printf '%s' "${CURRENT_IF:-}" ;;
            BACKEND) printf '%s' "${BACKEND:-}" ;;
            IP_FORWARD_PLAN) printf '%s' "${IP_FORWARD_PLAN:-}" ;;
            FW_INPUT_PLAN) printf '%s' "${FW_INPUT_PLAN:-}" ;;
            FW_OUTPUT_PLAN) printf '%s' "${FW_OUTPUT_PLAN:-}" ;;
            FW_FORWARD_PLAN) printf '%s' "${FW_FORWARD_PLAN:-}" ;;
            *) printf '' ;;
        esac
    )
}

require_current_interface() {
    if [ -z "$CURRENT_IF" ]; then
        err "请先在主菜单选择一个当前配置接口。"
        return 1
    fi
    return 0
}

add_port_rule() {
    require_current_interface || return
    choose_port_proto
    _proto="$SELECTED_PROTO"
    [ -n "$_proto" ] || return

    if [ "$_proto" = "icmp" ]; then
        if grep -Fxq "${CURRENT_IF}|icmp|-" "$PORT_TMP"; then
            err "该接口下 ICMP 放行规则已存在。"
            return
        fi
        printf '%s|%s|%s\n' "$CURRENT_IF" "icmp" "-" >> "$PORT_TMP"
        trim_file_nonempty_unique "$PORT_TMP"
        msg "已添加: 接口=${CURRENT_IF}  协议=icmp"
        return
    fi

    printf '请输入端口号 [1-65535]: ' > "$TTY_IN"
    read_tty
    _port="$USER_INPUT"
    if ! is_valid_port "$_port"; then
        err "端口号不正确。"
        return
    fi

    if grep -Fxq "${CURRENT_IF}|${_proto}|${_port}" "$PORT_TMP"; then
        err "该接口下该端口规则已存在。"
        return
    fi

    printf '%s|%s|%s\n' "$CURRENT_IF" "$_proto" "$_port" >> "$PORT_TMP"
    trim_file_nonempty_unique "$PORT_TMP"
    msg "已添加: 接口=${CURRENT_IF}  协议=$(proto_label "$_proto")  端口=${_port}"
}

choose_port_proto() {
    SELECTED_PROTO=""
    while :; do
        msg ""
        msg "请选择要放行的协议类型:"
        msg "1) tcp"
        msg "2) udp"
        msg "3) tcp_udp"
        msg "4) icmp"
        printf '请选择 [1-4]: ' > "$TTY_IN"
        read_tty
        case "$USER_INPUT" in
            1) SELECTED_PROTO="tcp"; return 0 ;;
            2) SELECTED_PROTO="udp"; return 0 ;;
            3) SELECTED_PROTO="tcpudp"; return 0 ;;
            4) SELECTED_PROTO="icmp"; return 0 ;;
            *) err "无效选项，请重新输入。" ;;
        esac
    done
}

edit_port_rule() {
    require_current_interface || return
    build_current_port_view
    if [ ! -s "$VIEW_TMP2" ]; then
        err "接口 ${CURRENT_IF} 当前没有可修改的端口规则。"
        return
    fi

    show_current_port_rules
    printf '请输入要修改的编号: ' > "$TTY_IN"
    read_tty
    _display_no="$USER_INPUT"

    _actual_line="$(awk -F'|' -v n="$_display_no" '$1==n {print $2; exit}' "$VIEW_TMP2")"
    _old_proto="$(awk -F'|' -v n="$_display_no" '$1==n {print $3; exit}' "$VIEW_TMP2")"
    _old_port="$(awk -F'|' -v n="$_display_no" '$1==n {print $4; exit}' "$VIEW_TMP2")"
    if [ -z "$_actual_line" ] || [ -z "$_old_proto" ]; then
        err "编号无效。"
        return
    fi

    msg "当前规则: 接口=${CURRENT_IF}  协议=$(proto_label "$_old_proto")  端口=${_old_port}"
    choose_port_proto
    _new_proto="$SELECTED_PROTO"
    [ -n "$_new_proto" ] || return

    if [ "$_new_proto" = "icmp" ]; then
        _new_port="-"
    else
        if [ "$_old_proto" != "icmp" ] && [ -n "$_old_port" ] && [ "$_old_port" != "-" ]; then
            printf '请输入新的端口号 [1-65535] [%s]: ' "$_old_port" > "$TTY_IN"
        else
            printf '请输入新的端口号 [1-65535]: ' > "$TTY_IN"
        fi
        read_tty
        _new_port="$USER_INPUT"
        if [ -z "$_new_port" ] && [ "$_old_proto" != "icmp" ] && [ -n "$_old_port" ] && [ "$_old_port" != "-" ]; then
            _new_port="$_old_port"
        fi
        if ! is_valid_port "$_new_port"; then
            err "端口号不正确。"
            return
        fi
    fi

    awk -F'|' -v ln="$_actual_line" -v ifc="$CURRENT_IF" -v proto="$_new_proto" -v port="$_new_port" '
        NR==ln { print ifc "|" proto "|" port; next }
        { print }
    ' "$PORT_TMP" > "$WORK_TMP1"
    cat "$WORK_TMP1" > "$PORT_TMP"
    trim_file_nonempty_unique "$PORT_TMP"
    msg "已修改。"
}

delete_port_rule() {
    require_current_interface || return
    build_current_port_view
    if [ ! -s "$VIEW_TMP2" ]; then
        err "接口 ${CURRENT_IF} 当前没有可删除的端口规则。"
        return
    fi
    show_current_port_rules
    printf '请输入要删除的编号: ' > "$TTY_IN"
    read_tty
    _display_no="$USER_INPUT"

    _actual_line="$(awk -F'|' -v n="$_display_no" '$1==n {print $2; exit}' "$VIEW_TMP2")"
    _old_proto="$(awk -F'|' -v n="$_display_no" '$1==n {print $3; exit}' "$VIEW_TMP2")"
    _old_port="$(awk -F'|' -v n="$_display_no" '$1==n {print $4; exit}' "$VIEW_TMP2")"
    if [ -z "$_actual_line" ] || [ -z "$_old_proto" ]; then
        err "编号无效。"
        return
    fi

    awk -v ln="$_actual_line" 'NR!=ln { print }' "$PORT_TMP" > "$WORK_TMP1"
    cat "$WORK_TMP1" > "$PORT_TMP"
    msg "已删除: 接口=${CURRENT_IF}  协议=$(proto_label "$_old_proto")  端口=${_old_port}"
}

build_current_snat_view() {
    : > "$VIEW_TMP1"
    awk -F'|' -v ifc="$CURRENT_IF" '
        $1==ifc {
            c++
            printf "%d|%d|%s\n", c, NR, $2
        }
    ' "$SNAT_TMP" > "$VIEW_TMP1"
}

build_current_port_view() {
    : > "$VIEW_TMP2"
    awk -F'|' -v ifc="$CURRENT_IF" '
        $1==ifc {
            c++
            printf "%d|%d|%s|%s\n", c, NR, $2, $3
        }
    ' "$PORT_TMP" > "$VIEW_TMP2"
}

show_current_snat_rules() {
    require_current_interface || return
    build_current_snat_view
    if [ ! -s "$VIEW_TMP1" ]; then
        msg "接口 ${CURRENT_IF} 当前没有 SNAT 源网段。"
        return
    fi
    awk -F'|' '{printf "%d) %s\n", $1, $3}' "$VIEW_TMP1"
}

show_current_port_rules() {
    require_current_interface || return
    build_current_port_view
    if [ ! -s "$VIEW_TMP2" ]; then
        msg "接口 ${CURRENT_IF} 当前没有端口放行规则。"
        return
    fi
    awk -F'|' '
        {
            proto=$3
            port=$4
            if (proto=="tcpudp") proto_show="tcp+udp"; else proto_show=proto
            if (proto=="icmp") {
                printf "%d) 协议=%s\n", $1, proto_show
            } else {
                printf "%d) 协议=%s  端口=%s\n", $1, proto_show, port
            }
        }
    ' "$VIEW_TMP2"
}

add_snat_rule() {
    require_current_interface || return
    printf '请输入需要在接口 %s 上做 SNAT 的源网段，例如 10.8.0.0/24: ' "$CURRENT_IF" > "$TTY_IN"
    read_tty
    _subnet="$USER_INPUT"
    if ! is_valid_ipv4_cidr "$_subnet"; then
        err "网段格式不正确。"
        return
    fi
    if grep -Fxq "${CURRENT_IF}|${_subnet}" "$SNAT_TMP"; then
        err "该接口下该网段已存在。"
        return
    fi
    printf '%s|%s\n' "$CURRENT_IF" "$_subnet" >> "$SNAT_TMP"
    trim_file_nonempty_unique "$SNAT_TMP"
    msg "已添加: 接口=${CURRENT_IF}  源网段=${_subnet}"
}

edit_snat_rule() {
    require_current_interface || return
    build_current_snat_view
    if [ ! -s "$VIEW_TMP1" ]; then
        err "接口 ${CURRENT_IF} 当前没有可修改的 SNAT 源网段。"
        return
    fi
    show_current_snat_rules
    printf '请输入要修改的编号: ' > "$TTY_IN"
    read_tty
    _display_no="$USER_INPUT"
    _actual_line="$(awk -F'|' -v n="$_display_no" '$1==n {print $2; exit}' "$VIEW_TMP1")"
    _old_subnet="$(awk -F'|' -v n="$_display_no" '$1==n {print $3; exit}' "$VIEW_TMP1")"
    if [ -z "$_actual_line" ] || [ -z "$_old_subnet" ]; then
        err "编号无效。"
        return
    fi

    printf '请输入新的网段 [%s]: ' "$_old_subnet" > "$TTY_IN"
    read_tty
    _new_subnet="$USER_INPUT"
    [ -n "$_new_subnet" ] || _new_subnet="$_old_subnet"

    if ! is_valid_ipv4_cidr "$_new_subnet"; then
        err "网段格式不正确。"
        return
    fi

    awk -F'|' -v ln="$_actual_line" -v ifc="$CURRENT_IF" -v subnet="$_new_subnet" '
        NR==ln { print ifc "|" subnet; next }
        { print }
    ' "$SNAT_TMP" > "$WORK_TMP1"
    cat "$WORK_TMP1" > "$SNAT_TMP"
    trim_file_nonempty_unique "$SNAT_TMP"
    msg "已修改。"
}

delete_snat_rule() {
    require_current_interface || return
    build_current_snat_view
    if [ ! -s "$VIEW_TMP1" ]; then
        err "接口 ${CURRENT_IF} 当前没有可删除的 SNAT 源网段。"
        return
    fi
    show_current_snat_rules
    printf '请输入要删除的编号: ' > "$TTY_IN"
    read_tty
    _display_no="$USER_INPUT"
    _actual_line="$(awk -F'|' -v n="$_display_no" '$1==n {print $2; exit}' "$VIEW_TMP1")"
    _old_subnet="$(awk -F'|' -v n="$_display_no" '$1==n {print $3; exit}' "$VIEW_TMP1")"
    if [ -z "$_actual_line" ] || [ -z "$_old_subnet" ]; then
        err "编号无效。"
        return
    fi

    awk -v ln="$_actual_line" 'NR!=ln { print }' "$SNAT_TMP" > "$WORK_TMP1"
    cat "$WORK_TMP1" > "$SNAT_TMP"
    msg "已删除: 接口=${CURRENT_IF}  源网段=${_old_subnet}"
}

count_config_ifaces() {
    {
        awk -F'|' 'NF>=2 {print $1}' "$SNAT_TMP"
        awk -F'|' 'NF>=3 {print $1}' "$PORT_TMP"
    } | awk 'NF && !seen[$0]++ { c++ } END { print c+0 }'
}

build_config_iface_list() {
    {
        awk -F'|' 'NF>=2 {print $1}' "$SNAT_TMP"
        awk -F'|' 'NF>=3 {print $1}' "$PORT_TMP"
    } | awk 'NF && !seen[$0]++ { print }' > "$WORK_TMP4"
}

config_type_label() {
    _snat_count="$(count_nonempty_lines "$SNAT_TMP")"
    _port_count="$(count_nonempty_lines "$PORT_TMP")"

    if [ "$_snat_count" -gt 0 ] && [ "$_port_count" -gt 0 ]; then
        echo "已同时配置 SNAT 和端口放行"
    elif [ "$_snat_count" -gt 0 ]; then
        echo "仅配置 SNAT"
    elif [ "$_port_count" -gt 0 ]; then
        echo "仅配置端口放行"
    else
        echo "当前没有任何配置"
    fi
}

show_summary() {
    detect_firewall_policies
    msg ""
    msg "===== 当前配置摘要 ====="
    msg "系统名称: ${OS_NAME}"
    msg "系统家族: ${OS_FAMILY}"
    msg "包管理器: ${PKG_MGR}"
    msg "防火墙后端: ${BACKEND}"
    msg "默认出口接口: $(format_iface_value "${DEFAULT_WAN_IF:-未识别}")"
    msg "当前配置接口: $(format_iface_value "${CURRENT_IF:-未设置}")"
    msg "当前系统 IPv4 转发: $(ip_forward_runtime_label)"
    msg "IPv4 转发计划: $(ip_forward_plan_label)"
    msg "默认入站策略: $(format_policy_value "${fw_in_policy:-未知}")"
    msg "默认出站策略: $(format_policy_value "${fw_out_policy:-未知}")"
    msg "默认转发策略: $(format_policy_value "${fw_fwd_policy:-未知}")"
    msg "默认入站策略计划: $(format_plan_value "$FW_INPUT_PLAN")"
    msg "默认出站策略计划: $(format_plan_value "$FW_OUTPUT_PLAN")"
    msg "默认转发策略计划: $(format_plan_value "$FW_FORWARD_PLAN")"
    msg "策略原始信息: ${fw_policy_detail:-未知}"
    msg "配置类型: $(config_type_label)"
    msg "已配置接口数量: $(format_count_value "$(count_config_ifaces)")"
    msg "SNAT 规则总数: $(format_count_value "$(count_nonempty_lines "$SNAT_TMP")")"
    msg "端口放行总数: $(format_count_value "$(count_nonempty_lines "$PORT_TMP")")"
}

get_firewalld_zone_of_if() {
    _if="$1"
    _zone="$(firewall-cmd --get-zone-of-interface="$_if" 2>/dev/null | head -n 1)"
    case "$_zone" in
        ""|"no zone")
            firewall-cmd --get-default-zone 2>/dev/null | head -n 1
            ;;
        *)
            printf '%s\n' "$_zone"
            ;;
    esac
}

print_detailed_config() {
    detect_firewall_policies

    msg ""
    msg "================ 当前已保存/待应用配置明细 ================"
    msg "系统名称: ${OS_NAME}"
    msg "系统家族: ${OS_FAMILY}"
    msg "包管理器: ${PKG_MGR}"
    msg "防火墙后端: ${BACKEND}"
    msg "当前配置接口: $(format_iface_value "${CURRENT_IF:-未设置}")"
    msg "当前系统 IPv4 转发运行状态: $(ip_forward_runtime_label)"
    msg "本脚本 IPv4 转发计划: $(ip_forward_plan_label)"
    msg "默认入站策略: $(format_policy_value "${fw_in_policy:-未知}")"
    msg "默认出站策略: $(format_policy_value "${fw_out_policy:-未知}")"
    msg "默认转发策略: $(format_policy_value "${fw_fwd_policy:-未知}")"
    msg "默认入站策略计划: $(format_plan_value "$FW_INPUT_PLAN")"
    msg "默认出站策略计划: $(format_plan_value "$FW_OUTPUT_PLAN")"
    msg "默认转发策略计划: $(format_plan_value "$FW_FORWARD_PLAN")"
    msg "策略原始信息: ${fw_policy_detail:-未知}"
    msg "配置类型: $(config_type_label)"
    msg "已配置接口数量: $(format_count_value "$(count_config_ifaces)")"
    msg ""

    build_config_iface_list

    if [ ! -s "$WORK_TMP4" ]; then
        msg "当前还没有任何接口配置。"
        msg "========================================================"
        return
    fi

    while IFS= read -r _ifc; do
        [ -n "$_ifc" ] || continue
        msg "--------------------------------------------------------"
        msg "接口: $(format_iface_value "${_ifc}")"
        if [ "$BACKEND" = "firewalld" ]; then
            _zone="$(get_firewalld_zone_of_if "$_ifc")"
            [ -n "$_zone" ] && msg "firewalld zone: ${_zone}"
        fi
        msg ""
        msg "[${_ifc} 下的 SNAT 源网段]"
        awk -F'|' -v ifc="$_ifc" '
            $1==ifc { c++; printf "  %d) %s\n", c, $2 }
            END { if (c==0) print "  无" }
        ' "$SNAT_TMP"

        msg ""
        msg "[${_ifc} 下的端口/协议放行（仅本机）]"
        awk -F'|' -v ifc="$_ifc" '
            $1==ifc {
                c++
                proto=$2
                port=$3
                if (proto=="tcpudp") proto_show="tcp+udp"; else proto_show=proto
                if (proto=="icmp") {
                    printf "  %d) 协议=%s\n", c, proto_show
                } else {
                    printf "  %d) 协议=%s  端口=%s\n", c, proto_show, port
                }
            }
            END { if (c==0) print "  无" }
        ' "$PORT_TMP"
        msg ""
    done < "$WORK_TMP4"

    msg "========================================================"
}

snat_menu() {
    require_current_interface || return
    while :; do
        msg ""
        msg "===== SNAT 配置 ====="
        msg "当前配置接口: ${CURRENT_IF}"
        show_current_snat_rules
        msg ""
        msg "1) 查看当前接口下的 SNAT"
        msg "2) 添加"
        msg "3) 修改"
        msg "4) 删除"
        msg "0) 返回主菜单"
        printf '请选择: ' > "$TTY_IN"
        read_tty
        case "$USER_INPUT" in
            1) show_current_snat_rules; pause ;;
            2) add_snat_rule; pause ;;
            3) edit_snat_rule; pause ;;
            4) delete_snat_rule; pause ;;
            0) return 0 ;;
            *) err "无效选项。"; pause ;;
        esac
    done
}

port_menu() {
    require_current_interface || return
    while :; do
        msg ""
        msg "===== 端口放行配置 ====="
        msg "当前配置接口: ${CURRENT_IF}"
        show_current_port_rules
        msg ""
        msg "1) 查看当前接口下的端口放行"
        msg "2) 添加"
        msg "3) 修改"
        msg "4) 删除"
        msg "0) 返回主菜单"
        printf '请选择: ' > "$TTY_IN"
        read_tty
        case "$USER_INPUT" in
            1) show_current_port_rules; pause ;;
            2) add_port_rule; pause ;;
            3) edit_port_rule; pause ;;
            4) delete_port_rule; pause ;;
            0) return 0 ;;
            *) err "无效选项。"; pause ;;
        esac
    done
}

is_valid_ipv4_cidr() {
    echo "$1" | awk -F'[./]' '
        NF==5 &&
        $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/ &&
        $1>=0 && $1<=255 &&
        $2>=0 && $2<=255 &&
        $3>=0 && $3<=255 &&
        $4>=0 && $4<=255 &&
        $5>=0 && $5<=32 { ok=1 }
        END { exit ok ? 0 : 1 }
    '
}

is_valid_port() {
    echo "$1" | awk '
        $0 ~ /^[0-9]+$/ && $0 >= 1 && $0 <= 65535 { ok=1 }
        END { exit ok ? 0 : 1 }
    '
}

set_sysctl_kv() {
    _file="$1"
    _key="$2"
    _value="$3"
    [ -f "$_file" ] || touch "$_file"
    awk -v k="$_key" -v v="$_value" '
        BEGIN { done=0 }
        {
            if ($0 ~ "^[[:space:]]*#?[[:space:]]*" k "[[:space:]]*=" && !done) {
                print k "=" v
                done=1
                next
            }
            print
        }
        END {
            if (!done) print k "=" v
        }
    ' "$_file" > "$WORK_TMP1"
    cat "$WORK_TMP1" > "$_file"
}

firewalld_add_forward_any_rule() {
    _iface="$1"
    _subnet="$2"
    firewall-cmd --permanent --direct --add-rule ipv4 filter FORWARD 0 -o "$_iface" -s "$_subnet" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 || true
}

firewalld_remove_forward_any_rule() {
    _iface="$1"
    _subnet="$2"
    firewall-cmd --permanent --direct --remove-rule ipv4 filter FORWARD 0 -o "$_iface" -s "$_subnet" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 || true
}

firewalld_add_port_rule() {
    _iface="$1"
    _proto="$2"
    _port="$3"
    _zone="$(get_firewalld_zone_of_if "$_iface")"
    [ -n "$_zone" ] || _zone="public"

    case "$_proto" in
        tcp)
            firewall-cmd --permanent --zone="$_zone" --add-port="${_port}/tcp" >/dev/null 2>&1 || true
            ;;
        udp)
            firewall-cmd --permanent --zone="$_zone" --add-port="${_port}/udp" >/dev/null 2>&1 || true
            ;;
        tcpudp)
            firewall-cmd --permanent --zone="$_zone" --add-port="${_port}/tcp" >/dev/null 2>&1 || true
            firewall-cmd --permanent --zone="$_zone" --add-port="${_port}/udp" >/dev/null 2>&1 || true
            ;;
        icmp)
            firewall-cmd --permanent --zone="$_zone" --add-rich-rule='rule family="ipv4" protocol value="icmp" accept' >/dev/null 2>&1 || true
            ;;
    esac
}

firewalld_remove_port_rule() {
    _iface="$1"
    _proto="$2"
    _port="$3"
    _zone="$(get_firewalld_zone_of_if "$_iface")"
    [ -n "$_zone" ] || _zone="public"

    case "$_proto" in
        tcp)
            firewall-cmd --permanent --zone="$_zone" --remove-port="${_port}/tcp" >/dev/null 2>&1 || true
            ;;
        udp)
            firewall-cmd --permanent --zone="$_zone" --remove-port="${_port}/udp" >/dev/null 2>&1 || true
            ;;
        tcpudp)
            firewall-cmd --permanent --zone="$_zone" --remove-port="${_port}/tcp" >/dev/null 2>&1 || true
            firewall-cmd --permanent --zone="$_zone" --remove-port="${_port}/udp" >/dev/null 2>&1 || true
            ;;
        icmp)
            firewall-cmd --permanent --zone="$_zone" --remove-rich-rule='rule family="ipv4" protocol value="icmp" accept' >/dev/null 2>&1 || true
            ;;
    esac
}

firewalld_apply_default_policy_rule() {
    _chain="$1"
    _plan="$2"
    firewall-cmd --permanent --direct --remove-rule ipv4 filter "$_chain" "$FIREWALLD_POLICY_ALLOW_PRIO" -j ACCEPT >/dev/null 2>&1 || true
    firewall-cmd --permanent --direct --remove-rule ipv4 filter "$_chain" "$FIREWALLD_POLICY_DENY_PRIO" -j DROP >/dev/null 2>&1 || true
    case "$_plan" in
        allow)
            firewall-cmd --permanent --direct --add-rule ipv4 filter "$_chain" "$FIREWALLD_POLICY_ALLOW_PRIO" -j ACCEPT >/dev/null 2>&1 || true
            ;;
        deny)
            firewall-cmd --permanent --direct --add-rule ipv4 filter "$_chain" "$FIREWALLD_POLICY_DENY_PRIO" -j DROP >/dev/null 2>&1 || true
            ;;
    esac
}

apply_firewalld() {
    ensure_package firewall-cmd firewalld || return 1
    start_service firewalld
    enable_service firewalld

    firewalld_apply_default_policy_rule "INPUT" "$FW_INPUT_PLAN"
    firewalld_apply_default_policy_rule "OUTPUT" "$FW_OUTPUT_PLAN"
    firewalld_apply_default_policy_rule "FORWARD" "$FW_FORWARD_PLAN"

    _saved_current_if="$(read_saved_value CURRENT_IF)"
    normalize_snat_file "$SNAT_STORE" "$WORK_TMP1" "${_saved_current_if:-$CURRENT_IF}"
    normalize_port_file "$PORT_STORE" "$WORK_TMP2" "${_saved_current_if:-$CURRENT_IF}"

    while IFS='|' read -r _iface _proto _port; do
        [ -n "$_iface" ] || continue
        firewalld_remove_port_rule "$_iface" "$_proto" "$_port"
    done < "$WORK_TMP2"

    while IFS='|' read -r _iface _subnet; do
        [ -n "$_iface" ] || continue
        _zone="$(get_firewalld_zone_of_if "$_iface")"
        [ -n "$_zone" ] || _zone="public"
        firewall-cmd --permanent --zone="$_zone" --remove-source="$_subnet" >/dev/null 2>&1 || true
        firewalld_remove_forward_any_rule "$_iface" "$_subnet"
        firewall-cmd --permanent --direct --remove-rule ipv4 filter FORWARD 0 -i "$_iface" -d "$_subnet" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 || true
        firewall-cmd --permanent --direct --remove-rule ipv4 nat POSTROUTING 0 -s "$_subnet" -o "$_iface" -j MASQUERADE >/dev/null 2>&1 || true
    done < "$WORK_TMP1"

    while IFS='|' read -r _iface _proto _port; do
        [ -n "$_iface" ] || continue
        firewalld_add_port_rule "$_iface" "$_proto" "$_port"
    done < "$PORT_TMP"

    while IFS='|' read -r _iface _subnet; do
        [ -n "$_iface" ] || continue
        _zone="$(get_firewalld_zone_of_if "$_iface")"
        [ -n "$_zone" ] || _zone="public"
        firewall-cmd --permanent --zone="$_zone" --add-source="$_subnet" >/dev/null 2>&1 || true
        firewall-cmd --permanent --zone="$_zone" --add-forward >/dev/null 2>&1 || true
        firewalld_add_forward_any_rule "$_iface" "$_subnet"
        firewall-cmd --permanent --direct --add-rule ipv4 filter FORWARD 0 -i "$_iface" -d "$_subnet" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 || true
        firewall-cmd --permanent --direct --add-rule ipv4 nat POSTROUTING 0 -s "$_subnet" -o "$_iface" -j MASQUERADE >/dev/null 2>&1 || true
    done < "$SNAT_TMP"

    firewall-cmd --reload >/dev/null 2>&1 || return 1
    return 0
}

strip_marked_block() {
    _begin="$1"
    _end="$2"
    _file="$3"
    awk -v s="$_begin" -v e="$_end" '
        index($0, s) { skip=1; next }
        index($0, e) { skip=0; next }
        !skip { print }
    ' "$_file"
}

build_ufw_nat_block() {
    if [ "$(count_nonempty_lines "$SNAT_TMP")" -eq 0 ]; then
        return 0
    fi

    printf '%s\n' "$UFW_NAT_BEGIN"
    printf '%s\n' '*nat'
    printf '%s\n' ':POSTROUTING ACCEPT [0:0]'
    while IFS='|' read -r _iface _subnet; do
        [ -n "$_iface" ] || continue
        printf '%s\n' "-A POSTROUTING -s ${_subnet} -o ${_iface} -j MASQUERADE"
    done < "$SNAT_TMP"
    printf '%s\n' 'COMMIT'
    printf '%s\n' "$UFW_NAT_END"
}

build_ufw_filter_block() {
    _has_any=0
    if [ "$(count_nonempty_lines "$SNAT_TMP")" -gt 0 ]; then
        _has_any=1
    fi
    if [ "$(count_nonempty_lines "$PORT_TMP")" -gt 0 ]; then
        _has_any=1
    fi
    if [ "$_has_any" -eq 0 ]; then
        return 0
    fi

    printf '%s\n' "$UFW_FILTER_BEGIN"

    while IFS='|' read -r _iface _subnet; do
        [ -n "$_iface" ] || continue
        printf '%s\n' "-A ufw-before-forward -o ${_iface} -s ${_subnet} -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT"
        printf '%s\n' "-A ufw-before-forward -i ${_iface} -d ${_subnet} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
    done < "$SNAT_TMP"

    while IFS='|' read -r _iface _proto _port; do
        [ -n "$_iface" ] || continue
        case "$_proto" in
            tcp)
                printf '%s\n' "-A ufw-before-input -i ${_iface} -p tcp --dport ${_port} -m conntrack --ctstate NEW -j ACCEPT"
                ;;
            udp)
                printf '%s\n' "-A ufw-before-input -i ${_iface} -p udp --dport ${_port} -j ACCEPT"
                ;;
            tcpudp)
                printf '%s\n' "-A ufw-before-input -i ${_iface} -p tcp --dport ${_port} -m conntrack --ctstate NEW -j ACCEPT"
                printf '%s\n' "-A ufw-before-input -i ${_iface} -p udp --dport ${_port} -j ACCEPT"
                ;;
            icmp)
                printf '%s\n' "-A ufw-before-input -i ${_iface} -p icmp -j ACCEPT"
                ;;
        esac
    done < "$PORT_TMP"

    printf '%s\n' "$UFW_FILTER_END"
}

apply_ufw() {
    ensure_package ufw ufw || return 1

    backup_file "$UFW_BEFORE_RULES"
    [ -f "$UFW_BEFORE_RULES" ] || touch "$UFW_BEFORE_RULES"

    case "$FW_INPUT_PLAN" in
        allow) ufw --force default allow incoming >/dev/null 2>&1 || true ;;
        deny) ufw --force default deny incoming >/dev/null 2>&1 || true ;;
    esac
    case "$FW_OUTPUT_PLAN" in
        allow) ufw --force default allow outgoing >/dev/null 2>&1 || true ;;
        deny) ufw --force default deny outgoing >/dev/null 2>&1 || true ;;
    esac
    case "$FW_FORWARD_PLAN" in
        allow) ufw --force default allow routed >/dev/null 2>&1 || true ;;
        deny) ufw --force default deny routed >/dev/null 2>&1 || true ;;
    esac

    strip_marked_block "$UFW_NAT_BEGIN" "$UFW_NAT_END" "$UFW_BEFORE_RULES" > "$WORK_TMP1"
    strip_marked_block "$UFW_FILTER_BEGIN" "$UFW_FILTER_END" "$WORK_TMP1" > "$WORK_TMP2"

    _nat_block="$(build_ufw_nat_block)"
    if [ -n "$_nat_block" ]; then
        awk -v block="$_nat_block" '
            BEGIN { inserted=0 }
            {
                if (!inserted && $0 ~ /^\*filter$/) {
                    print block
                    inserted=1
                }
                print
            }
            END {
                if (!inserted) print block
            }
        ' "$WORK_TMP2" > "$WORK_TMP3"
    else
        cat "$WORK_TMP2" > "$WORK_TMP3"
    fi

    _filter_block="$(build_ufw_filter_block)"
    if [ -n "$_filter_block" ]; then
        awk -v block="$_filter_block" '
            BEGIN { in_filter=0; inserted=0 }
            {
                if ($0 ~ /^\*filter$/) in_filter=1
                if (in_filter && $0 ~ /^COMMIT$/ && !inserted) {
                    print block
                    inserted=1
                    in_filter=0
                }
                print
            }
            END {
                if (!inserted) {
                    print "*filter"
                    print block
                    print "COMMIT"
                }
            }
        ' "$WORK_TMP3" > "$WORK_TMP4"
    else
        cat "$WORK_TMP3" > "$WORK_TMP4"
    fi

    cat "$WORK_TMP4" > "$UFW_BEFORE_RULES"
    if [ "$IP_FORWARD_PLAN" = "permanent" ]; then
        set_sysctl_kv "$UFW_SYSCTL_FILE" "net/ipv4/ip_forward" "1"
    fi

    if command_exists ufw; then
        ufw reload >/dev/null 2>&1 || true
        ufw --force enable >/dev/null 2>&1 || true
    fi
    return 0
}

install_iptables_restore_service() {
    mkdir -p /usr/local/sbin
    cat > "$IPTABLES_APPLY_SCRIPT" <<EOF
#!/bin/sh
[ -f "$IPTABLES_RULES_FILE" ] || exit 0
iptables-restore < "$IPTABLES_RULES_FILE"
exit \$?
EOF
    chmod 700 "$IPTABLES_APPLY_SCRIPT"

    if has_systemd; then
        cat > "$IPTABLES_SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Restore ${PROGRAM_NAME} iptables rules
After=local-fs.target
Before=network-online.target

[Service]
Type=oneshot
ExecStart=${IPTABLES_APPLY_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        enable_service "$(basename "$IPTABLES_SYSTEMD_SERVICE")"
    elif has_openrc; then
        cat > "$IPTABLES_OPENRC_SERVICE" <<'EOF'
#!/sbin/openrc-run
name="vpn-fw-helper-iptables"
description="Restore vpn-fw-helper iptables rules"

depend() {
    need net
    use firewall
}

start() {
    ebegin "Restoring vpn-fw-helper iptables rules"
    /usr/local/sbin/vpn-fw-helper-iptables-restore.sh
    eend $?
}
EOF
        chmod 755 "$IPTABLES_OPENRC_SERVICE"
        enable_service "$(basename "$IPTABLES_OPENRC_SERVICE")"
    fi
}

apply_iptables() {
    ensure_package iptables iptables || return 1

    case "$FW_INPUT_PLAN" in
        allow) iptables -P INPUT ACCEPT ;;
        deny) iptables -P INPUT DROP ;;
    esac
    case "$FW_OUTPUT_PLAN" in
        allow) iptables -P OUTPUT ACCEPT ;;
        deny) iptables -P OUTPUT DROP ;;
    esac
    case "$FW_FORWARD_PLAN" in
        allow) iptables -P FORWARD ACCEPT ;;
        deny) iptables -P FORWARD DROP ;;
    esac

    iptables -N "$IPTABLES_CHAIN_INPUT" 2>/dev/null || true
    iptables -F "$IPTABLES_CHAIN_INPUT"

    iptables -N "$IPTABLES_CHAIN_FORWARD" 2>/dev/null || true
    iptables -F "$IPTABLES_CHAIN_FORWARD"

    iptables -t nat -N "$IPTABLES_CHAIN_POSTROUTING" 2>/dev/null || true
    iptables -t nat -F "$IPTABLES_CHAIN_POSTROUTING"

    iptables -C INPUT -j "$IPTABLES_CHAIN_INPUT" >/dev/null 2>&1 || iptables -I INPUT 1 -j "$IPTABLES_CHAIN_INPUT"
    iptables -C FORWARD -j "$IPTABLES_CHAIN_FORWARD" >/dev/null 2>&1 || iptables -I FORWARD 1 -j "$IPTABLES_CHAIN_FORWARD"
    iptables -t nat -C POSTROUTING -j "$IPTABLES_CHAIN_POSTROUTING" >/dev/null 2>&1 || iptables -t nat -I POSTROUTING 1 -j "$IPTABLES_CHAIN_POSTROUTING"

    while IFS='|' read -r _iface _proto _port; do
        [ -n "$_iface" ] || continue
        case "$_proto" in
            tcp)
                iptables -A "$IPTABLES_CHAIN_INPUT" -i "$_iface" -p tcp --dport "$_port" -m conntrack --ctstate NEW -j ACCEPT
                ;;
            udp)
                iptables -A "$IPTABLES_CHAIN_INPUT" -i "$_iface" -p udp --dport "$_port" -j ACCEPT
                ;;
            tcpudp)
                iptables -A "$IPTABLES_CHAIN_INPUT" -i "$_iface" -p tcp --dport "$_port" -m conntrack --ctstate NEW -j ACCEPT
                iptables -A "$IPTABLES_CHAIN_INPUT" -i "$_iface" -p udp --dport "$_port" -j ACCEPT
                ;;
            icmp)
                iptables -A "$IPTABLES_CHAIN_INPUT" -i "$_iface" -p icmp -j ACCEPT
                ;;
        esac
    done < "$PORT_TMP"

    while IFS='|' read -r _iface _subnet; do
        [ -n "$_iface" ] || continue
        iptables -A "$IPTABLES_CHAIN_FORWARD" -o "$_iface" -s "$_subnet" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
        iptables -A "$IPTABLES_CHAIN_FORWARD" -i "$_iface" -d "$_subnet" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        iptables -t nat -A "$IPTABLES_CHAIN_POSTROUTING" -s "$_subnet" -o "$_iface" -j MASQUERADE
    done < "$SNAT_TMP"

    mkdir -p "$BASE_DIR"
    iptables-save > "$IPTABLES_RULES_FILE" || return 1

    install_iptables_restore_service
    return 0
}

install_nft_apply_service() {
    mkdir -p /usr/local/sbin
    cat > "$NFT_APPLY_SCRIPT" <<EOF
#!/bin/sh
nft delete table inet vpnfwhelper_filter >/dev/null 2>&1 || true
nft delete table ip vpnfwhelper_nat >/dev/null 2>&1 || true
[ -f "$NFT_RULES_FILE" ] || exit 0
nft -f "$NFT_RULES_FILE"
exit \$?
EOF
    chmod 700 "$NFT_APPLY_SCRIPT"

    if has_systemd; then
        cat > "$NFT_SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Apply ${PROGRAM_NAME} nftables rules
After=local-fs.target
Before=network-online.target

[Service]
Type=oneshot
ExecStart=${NFT_APPLY_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        enable_service "$(basename "$NFT_SYSTEMD_SERVICE")"
    elif has_openrc; then
        cat > "$NFT_OPENRC_SERVICE" <<'EOF'
#!/sbin/openrc-run
name="vpn-fw-helper-nftables"
description="Apply vpn-fw-helper nftables rules"

depend() {
    need net
    use firewall
}

start() {
    ebegin "Applying vpn-fw-helper nftables rules"
    /usr/local/sbin/vpn-fw-helper-nft-apply.sh
    eend $?
}
EOF
        chmod 755 "$NFT_OPENRC_SERVICE"
        enable_service "$(basename "$NFT_OPENRC_SERVICE")"
    fi
}

apply_nftables() {
    ensure_package nft nftables || return 1

    mkdir -p "$BASE_DIR"
    _nft_input_policy="accept"
    _nft_output_policy="accept"
    _nft_forward_policy="accept"
    case "$FW_INPUT_PLAN" in
        deny) _nft_input_policy="drop" ;;
        allow) _nft_input_policy="accept" ;;
    esac
    case "$FW_OUTPUT_PLAN" in
        deny) _nft_output_policy="drop" ;;
        allow) _nft_output_policy="accept" ;;
    esac
    case "$FW_FORWARD_PLAN" in
        deny) _nft_forward_policy="drop" ;;
        allow) _nft_forward_policy="accept" ;;
    esac

    {
        printf '%s\n' 'table inet vpnfwhelper_filter {'
        printf '%s\n' '    chain input {'
        printf '        type filter hook input priority 0; policy %s;\n' "$_nft_input_policy"
        while IFS='|' read -r _iface _proto _port; do
            [ -n "$_iface" ] || continue
            case "$_proto" in
                tcp)
                    printf '        iifname "%s" tcp dport %s ct state new accept\n' "$_iface" "$_port"
                    ;;
                udp)
                    printf '        iifname "%s" udp dport %s accept\n' "$_iface" "$_port"
                    ;;
                tcpudp)
                    printf '        iifname "%s" tcp dport %s ct state new accept\n' "$_iface" "$_port"
                    printf '        iifname "%s" udp dport %s accept\n' "$_iface" "$_port"
                    ;;
                icmp)
                    printf '        iifname "%s" ip protocol icmp accept\n' "$_iface"
                    ;;
            esac
        done < "$PORT_TMP"
        printf '%s\n' '    }'
        printf '%s\n' '    chain output {'
        printf '        type filter hook output priority 0; policy %s;\n' "$_nft_output_policy"
        printf '%s\n' '    }'
        printf '%s\n' '    chain forward {'
        printf '        type filter hook forward priority 0; policy %s;\n' "$_nft_forward_policy"
        while IFS='|' read -r _iface _subnet; do
            [ -n "$_iface" ] || continue
            printf '        iifname "%s" ip daddr %s ct state { established, related } accept\n' "$_iface" "$_subnet"
            printf '        oifname "%s" ip saddr %s ct state { new, established, related } accept\n' "$_iface" "$_subnet"
        done < "$SNAT_TMP"
        printf '%s\n' '    }'
        printf '%s\n' '}'
        printf '%s\n' 'table ip vpnfwhelper_nat {'
        printf '%s\n' '    chain postrouting {'
        printf '%s\n' '        type nat hook postrouting priority 100; policy accept;'
        while IFS='|' read -r _iface _subnet; do
            [ -n "$_iface" ] || continue
            printf '        ip saddr %s oifname "%s" masquerade\n' "$_subnet" "$_iface"
        done < "$SNAT_TMP"
        printf '%s\n' '    }'
        printf '%s\n' '}'
    } > "$NFT_RULES_FILE"

    install_nft_apply_service
    sh "$NFT_APPLY_SCRIPT" || return 1
    return 0
}

apply_ip_forward_setting() {
    case "$IP_FORWARD_PLAN" in
        permanent)
            msg "应用 IPv4 转发设置: 永久开启"
            if command_exists sysctl; then
                sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
            fi
            if [ -w /proc/sys/net/ipv4/ip_forward ]; then
                echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
            fi
            mkdir -p /etc/sysctl.d
            printf '%s\n' 'net.ipv4.ip_forward = 1' > "$SYSCTL_FILE"
            if command_exists sysctl; then
                sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
            fi
            if [ "$BACKEND" = "ufw" ]; then
                set_sysctl_kv "$UFW_SYSCTL_FILE" "net/ipv4/ip_forward" "1"
            fi
            ;;
        temporary)
            msg "应用 IPv4 转发设置: 临时开启"
            if command_exists sysctl; then
                sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
            fi
            if [ -w /proc/sys/net/ipv4/ip_forward ]; then
                echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
            fi
            ;;
        nochange|"")
            msg "IPv4 转发设置: 不修改"
            ;;
        *)
            err "未知的 IPv4 转发计划: $IP_FORWARD_PLAN"
            return 1
            ;;
    esac
    return 0
}

apply_backend() {
    case "$BACKEND" in
        firewalld) apply_firewalld ;;
        ufw) apply_ufw ;;
        nftables) apply_nftables ;;
        iptables) apply_iptables ;;
        *)
            err "不支持的防火墙后端: $BACKEND"
            return 1
            ;;
    esac
}

choose_backend_if_needed() {
    BACKEND="$(detect_backend)"
}

apply_and_save_all() {
    print_detailed_config
    if ! confirm "确认开始应用并保存以上全部配置吗"; then
        msg "已取消。"
        return 1
    fi

    apply_ip_forward_setting || return 1
    apply_backend || return 1
    save_current_config || return 1
    detect_firewall_policies

    msg ""
    msg "配置已成功应用并保存。"
    print_detailed_config
    return 0
}

main_menu() {
    while :; do
        show_summary
        msg ""
        msg "===== 主菜单 ====="
        msg "1) 重新检测系统与防火墙后端"
        msg "2) 查看当前网卡列表"
        msg "3) 配置 IPv4 转发"
        msg "4) 配置默认入站/出站/转发策略"
        msg "5) 选择当前配置接口"
        msg "6) 配置当前接口下的 SNAT"
        msg "7) 配置当前接口下的端口放行"
        msg "8) 查看所有已保存配置明细"
        msg "9) 应用并保存全部配置"
        msg "0) 退出脚本"
        msg "00) 更新当前 snat.sh 脚本"
        printf '请选择: ' > "$TTY_IN"
        read_tty

        case "$USER_INPUT" in
            1)
                detect_os
                choose_backend_if_needed
                detect_firewall_policies
                ;;
            2)
                msg "当前网卡列表:"
                list_interfaces "$DEFAULT_WAN_IF"
                pause
                ;;
            3)
                configure_ip_forward_menu
                ;;
            4)
                configure_default_policy_menu
                ;;
            5)
                choose_interface_by_number "选择当前配置接口" "${CURRENT_IF:-${DEFAULT_WAN_IF}}"
                if [ -n "$SELECTED_IF" ]; then
                    CURRENT_IF="$SELECTED_IF"
                    msg "当前配置接口已切换为: $(format_iface_value "$CURRENT_IF")"
                    pause
                fi
                ;;
            6)
                snat_menu
                ;;
            7)
                port_menu
                ;;
            8)
                print_detailed_config
                pause
                ;;
            9)
                if apply_and_save_all; then
                    pause
                else
                    err "应用失败，请检查上方输出。"
                    pause
                fi
                ;;
            00)
                if update_self_script; then
                    pause
                else
                    pause
                fi
                ;;
            0)
                exit 0
                ;;
            *)
                err "无效选项。"
                pause
                ;;
        esac
    done
}

init_defaults() {
    detect_os
    resolve_script_self >/dev/null 2>&1 || true
    load_saved_config

    DEFAULT_WAN_IF="$(get_default_wan_if)"
    [ -n "$CURRENT_IF" ] || CURRENT_IF="$DEFAULT_WAN_IF"
    [ -n "$IP_FORWARD_PLAN" ] || IP_FORWARD_PLAN="nochange"
    [ -n "$FW_INPUT_PLAN" ] || FW_INPUT_PLAN="nochange"
    [ -n "$FW_OUTPUT_PLAN" ] || FW_OUTPUT_PLAN="nochange"
    [ -n "$FW_FORWARD_PLAN" ] || FW_FORWARD_PLAN="nochange"

    choose_backend_if_needed
    detect_firewall_policies
}

require_root
init_colors
init_defaults
main_menu
