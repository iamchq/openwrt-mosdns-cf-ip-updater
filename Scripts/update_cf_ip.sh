#!/bin/sh
# Cloudflare IP 自动更新脚本（增强版 v3.2）

#============================ 用户配置区 ============================#
# 基本设置
MAX_IPS=10                      # 期望的最大唯一 IP 数量
MIN_IPS=5                       # 可接受的最小有效 IP 数量
RETRY_TIMES=3                   # 网络请求最大重试次数
CURL_TIMEOUT=30                 # 单次请求超时时间（秒）

# IP 数据源（支持多个备用 URL，空格分隔）
CF_IP_URLS="https://ip.164746.xyz https://example.com"

# UCI 配置路径（根据实际输出修改）
UCI_IP_NODE="mosdns.config.cloudflare_ip"          # 存储 IP 列表的节点
UCI_ENABLED_NODE="mosdns.config.cloudflare"        # Cloudflare 功能开关节点

# 日志与调试
VERBOSE=1                       # 1=控制台输出，0=仅系统日志
LOG_TAG="CF-IP-Update"

# 锁文件路径
LOCK_DIR="/var/run"
LOCK_FILE="${LOCK_DIR}/cf_ip_update.lock"

# 备份设置
BACKUP_DIR="/tmp"
BACKUP_PREFIX="mosdns_backup"
KEEP_BACKUPS=3                  # 保留最近的备份数量

# 服务相关
SERVICE_NAME="mosdns"
SERVICE_CMD="/etc/init.d/${SERVICE_NAME}"

#============================ 函数定义区 ============================#
log() {
    local level="$1"
    local msg="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    logger -t "${LOG_TAG}" "[${level}] ${msg}"
    if [ "${VERBOSE}" = "1" ]; then
        echo "[${timestamp}] ${LOG_TAG} [${level}] ${msg}" >&2
    fi
    [ "${level}" = "ERROR" ] && exit 1
}

acquire_lock() {
    [ -d "${LOCK_DIR}" ] || LOCK_DIR="/tmp"
    LOCK_FILE="${LOCK_DIR}/cf_ip_update.lock"

    if command -v flock >/dev/null 2>&1; then
        exec 200>"${LOCK_FILE}"
        if ! flock -n 200; then
            log "WARN" "已有实例运行中（flock），退出"
            exit 0
        fi
        trap 'flock -u 200 2>/dev/null; rm -f "${LOCK_FILE}"; exit' INT TERM EXIT
        return 0
    fi

    # 回退 PID 文件锁（带超时）
    if [ -f "${LOCK_FILE}" ]; then
        local pid=$(cat "${LOCK_FILE}" 2>/dev/null)
        if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
            log "WARN" "已有实例运行中 (PID:${pid})，退出"
            exit 0
        else
            local now=$(date +%s)
            local file_time=$(stat -c %Y "${LOCK_FILE}" 2>/dev/null)
            if [ -n "${file_time}" ] && [ $((now - file_time)) -gt 300 ]; then
                log "WARN" "强制清除过期锁文件 (PID:${pid})"
                rm -f "${LOCK_FILE}"
            else
                log "WARN" "清理残留锁文件 (PID:${pid})"
                rm -f "${LOCK_FILE}"
            fi
        fi
    fi

    echo $$ > "${LOCK_FILE}" 2>/dev/null || log "ERROR" "无法创建锁文件: ${LOCK_FILE}"
    trap 'rm -f "${LOCK_FILE}"; exit' INT TERM EXIT
}

check_deps() {
    for cmd in curl awk uci grep; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            log "ERROR" "缺少必需命令: ${cmd}"
        fi
    done
    if [ ! -x "${SERVICE_CMD}" ]; then
        log "ERROR" "服务脚本不存在或不可执行: ${SERVICE_CMD}"
    fi
}

validate_ip() {
    echo "$1" | awk -F. '
        BEGIN { valid = 1 }
        NF == 4 && $0 ~ /^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$/ {
            if ($1 <= 255 && $2 <= 255 && $3 <= 255 && $4 <= 255) {
                valid = 0
            }
        }
        END { exit valid }'
}

extract_ips_from_content() {
    grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' | while read -r ip; do
        if validate_ip "${ip}"; then
            echo "${ip}"
        fi
    done
}

fetch_ips() {
    local attempt=0
    local urls="${CF_IP_URLS}"
    local valid_ips=""
    local valid_count=0

    for url in ${urls}; do
        [ -z "${url}" ] && continue
        attempt=0
        while [ ${attempt} -lt ${RETRY_TIMES} ]; do
            log "INFO" "尝试获取 IP: ${url} (第 $((attempt+1)) 次)"
            content=$(curl -sk --max-time ${CURL_TIMEOUT} "${url}" 2>/dev/null)
            if [ -n "${content}" ]; then
                # 提取所有 IP，去重，保留顺序，再截取前 MAX_IPS 个
                ip_list=$(echo "${content}" | extract_ips_from_content | awk '!seen[$0]++' | head -n ${MAX_IPS})
                valid_ips=""
                valid_count=0
                for ip in ${ip_list}; do
                    if validate_ip "${ip}"; then
                        valid_ips="${valid_ips} ${ip}"
                        valid_count=$((valid_count + 1))
                    fi
                done
                valid_ips=$(echo "${valid_ips}" | xargs)

                if [ ${valid_count} -ge ${MIN_IPS} ]; then
                    echo "${valid_ips}"
                    return 0
                else
                    log "WARN" "有效 IP 不足 (${valid_count}/${MIN_IPS})，重试中..."
                fi
            else
                log "WARN" "获取内容为空，重试中..."
            fi

            attempt=$((attempt + 1))
            [ ${attempt} -lt ${RETRY_TIMES} ] && sleep $((attempt * 5))
        done
        log "WARN" "源 ${url} 尝试 ${RETRY_TIMES} 次后失败，尝试下一个源"
    done

    log "ERROR" "所有数据源均无法获取足够的有效 IP（最少需 ${MIN_IPS} 个）"
    return 1
}

get_current_ips() {
    local list_val
    list_val=$(uci -q get "${UCI_IP_NODE}" 2>/dev/null)
    if [ -n "${list_val}" ]; then
        list_val=$(echo "${list_val}" | sed -e 's/^"//' -e 's/"$//')
        echo "${list_val}" | tr ' ' '\n' | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' | xargs
    else
        echo ""
    fi
}

backup_config() {
    local backup_file="${BACKUP_DIR}/${BACKUP_PREFIX}_$(date +%s).$$"
    if uci export mosdns > "${backup_file}" 2>/dev/null; then
        echo "${backup_file}"
        return 0
    else
        log "ERROR" "备份 UCI 配置失败"
        return 1
    fi
}

restore_config() {
    local backup_file="$1"
    if [ -f "${backup_file}" ]; then
        log "WARN" "正在恢复配置: ${backup_file}"
        uci import mosdns < "${backup_file}" && uci commit mosdns
        rm -f "${backup_file}"
        return 0
    else
        log "ERROR" "备份文件不存在: ${backup_file}"
        return 1
    fi
}

# 检查并启用 Cloudflare 功能开关
enable_cloudflare_switch() {
    # 如果未配置开关节点，跳过
    [ -z "${UCI_ENABLED_NODE}" ] && return 0

    # 获取当前值
    local current_val
    current_val=$(uci -q get "${UCI_ENABLED_NODE}" 2>/dev/null)
    # 判断是否为禁用状态（0/false/disabled）
    case "${current_val}" in
        0|false|disabled|'')
            log "INFO" "Cloudflare 功能开关当前为禁用状态，正在启用..."
            uci set "${UCI_ENABLED_NODE}=1" 2>/dev/null || uci set "${UCI_ENABLED_NODE}=true"
            if uci commit mosdns >/dev/null 2>&1; then
                log "INFO" "已启用 Cloudflare 功能开关"
                return 0
            else
                log "ERROR" "启用 Cloudflare 功能开关失败"
                return 1
            fi
            ;;
        1|true|enabled)
            log "INFO" "Cloudflare 功能开关已启用，无需操作"
            return 0
            ;;
        *)
            log "WARN" "未知的开关状态: ${current_val}，将设置为启用"
            uci set "${UCI_ENABLED_NODE}=1" && uci commit mosdns
            return 0
            ;;
    esac
}

update_uci_config() {
    local new_ips="$1"
    # 再次去重
    new_ips=$(echo "${new_ips}" | tr ' ' '\n' | awk '!seen[$0]++' | xargs)
    local ip_count=$(echo "${new_ips}" | wc -w)

    [ ${ip_count} -lt ${MIN_IPS} ] && {
        log "ERROR" "拒绝更新：有效 IP 数量不足 (${ip_count} < ${MIN_IPS})"
        return 1
    }

    local current_ips=$(get_current_ips)
    if [ "${current_ips}" = "${new_ips}" ]; then
        log "INFO" "IP 列表无变化，跳过更新"
        return 2
    fi

    log "INFO" "检测到 IP 列表变化，开始更新配置"

    local backup_file=$(backup_config) || return 1

    # 清空旧列表
    while uci -q delete "${UCI_IP_NODE}" >/dev/null 2>&1; do :; done

    local added=0 failed=0
    for ip in ${new_ips}; do
        if uci add_list "${UCI_IP_NODE}=${ip}" >/dev/null 2>&1; then
            added=$((added + 1))
        else
            failed=$((failed + 1))
            log "WARN" "添加 IP 失败: ${ip}"
        fi
    done

    if uci commit mosdns >/dev/null 2>&1; then
        log "INFO" "配置提交成功 (新增:${added} 失败:${failed})"
        echo "${backup_file}" > "${BACKUP_DIR}/.last_backup"
        return 0
    else
        log "ERROR" "配置提交失败，恢复备份"
        restore_config "${backup_file}"
        return 1
    fi
}

# 服务控制：仅启动/重启，不改变开机自启状态
service_ctl() {
    if ${SERVICE_CMD} status >/dev/null 2>&1; then
        log "INFO" "服务正在运行，执行 restart..."
        ${SERVICE_CMD} restart >/dev/null 2>&1
    else
        log "INFO" "服务未运行，执行 start..."
        ${SERVICE_CMD} start >/dev/null 2>&1
    fi

    sleep 2
    if ${SERVICE_CMD} status >/dev/null 2>&1; then
        log "INFO" "服务操作成功"
        return 0
    else
        log "ERROR" "服务操作后状态异常"
        return 1
    fi
}

cleanup_old_backups() {
    ls -t ${BACKUP_DIR}/${BACKUP_PREFIX}_* 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -f
}

#============================ 主逻辑 ============================#
main() {
    acquire_lock
    check_deps

    # 1. 获取新 IP
    local new_ips=$(fetch_ips) || exit 1

    # 2. 更新 IP 配置（若无变化则跳过后续开关检查）
    update_uci_config "${new_ips}"
    local update_ret=$?
    if [ ${update_ret} -eq 2 ]; then
        log "INFO" "IP 列表无变化，继续检查开关状态"
    elif [ ${update_ret} -ne 0 ]; then
        exit 1
    fi

    # 3. 确保 Cloudflare 功能开关启用
    if ! enable_cloudflare_switch; then
        log "ERROR" "启用 Cloudflare 开关失败，回滚配置"
        local last_backup=$(cat "${BACKUP_DIR}/.last_backup" 2>/dev/null)
        [ -f "${last_backup}" ] && restore_config "${last_backup}"
        exit 1
    fi

    # 4. 重启服务（不改变开机自启）
    if ! service_ctl; then
        log "ERROR" "服务重启失败，执行回滚"
        local last_backup=$(cat "${BACKUP_DIR}/.last_backup" 2>/dev/null)
        [ -f "${last_backup}" ] && restore_config "${last_backup}"
        service_ctl
        exit 1
    fi

    # 5. 清理
    rm -f "${BACKUP_DIR}/.last_backup"
    cleanup_old_backups

    local formatted_ips=$(echo "${new_ips}" | awk '{for(i=1;i<=NF;i++) printf "\"%s\"%s", $i, (i==NF?"":", ")}')
    log "INFO" "更新完成 数量:$(echo "${new_ips}" | wc -w) IP列表:[${formatted_ips}]"
}

main "$@"
