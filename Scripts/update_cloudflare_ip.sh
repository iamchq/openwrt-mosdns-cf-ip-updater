#!/bin/sh
# Cloudflare IP自动更新脚本（最终稳定版）
# 版本：v3.1 | 最后更新：2025-03-25
# 功能：自动获取Cloudflare优选IP并安全更新mosdns配置

#============================ 用户配置区 ============================#
MAX_IPS=10                      # 期望获取的最大IP数量（最大数量10，超过无效）
MIN_IPS=5                      # 可接受的最小有效IP数量（低于此值将放弃更新）
CF_IP_URL="https://ip.164746.xyz"  # IP数据源地址（必须HTTPS）
UCI_CONFIG="mosdns.config.cloudflare_ip"  # UCI配置节点路径
RETRY_TIMES=3                   # 网络请求最大重试次数（建议3-5次）
CURL_TIMEOUT=30                 # 单次请求超时时间（秒）
LOCK_FILE="/var/run/cf_ip_update.lock"  # 锁文件路径

#============================ 函数定义区 ============================#
# 日志记录函数（确保单行输出）
# $1: 日志级别（INFO/WARN/ERROR）
# $2: 日志内容
log() {
  logger -t "CF-IP-Update" "[$1] ${2}"
  [ "$1" = "ERROR" ] && exit 1
}

# 安全的文件锁机制（防止并发执行）
acquire_lock() {
  # 检查是否存在有效锁文件
  if [ -f "$LOCK_FILE" ]; then
    local pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      log "WARN" "已有实例运行中(PID:$pid)，退出"
      exit 0
    else
      log "WARN" "清理残留锁文件(PID:$pid)"
      rm -f "$LOCK_FILE"
    fi
  fi

  # 创建新锁文件
  if ! echo $$ > "$LOCK_FILE"; then
    log "ERROR" "锁文件创建失败: $LOCK_FILE"
    exit 1
  fi
  
  # 确保锁文件会被清理
  trap 'rm -f "$LOCK_FILE"' EXIT
}

# 基础依赖检查（关键命令验证）
check_deps() {
  for cmd in curl awk uci; do
    if ! command -v "$cmd" >/dev/null; then
      log "ERROR" "系统缺少必需命令: $cmd"
    fi
  done
}

# 严格IP格式验证（IPv4）
# $1: 待验证的IP地址
validate_ip() {
  echo "$1" | awk -F. '
    BEGIN { valid = 1 }
    $0 ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/ {
      if ($1 <= 255 && $2 <= 255 && $3 <= 255 && $4 <= 255) {
        valid = 0
      }
    }
    END { exit valid }'
}

# 获取优选IP列表（带智能重试）
fetch_ips() {
  local ips="" attempts=0 valid_ips=""
  
  # 重试获取直到满足要求或超过重试次数
  while [ $attempts -lt $RETRY_TIMES ]; do
    log "INFO" "开始第$((attempts+1))次尝试获取IP"
    
    # 获取原始IP列表
    ips=$(curl -sk --max-time $CURL_TIMEOUT "$CF_IP_URL" 2>/dev/null | 
          awk -F'[<>]' '
            /<a href="https:\/\/zh-hans\.ipshu\.com\/ipv4\// {
              gsub(/[^0-9.]/,"",$3)
              if ($3 ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/) {
                print $3
                if (++count >= '$MAX_IPS') exit
              }
            }')

    # 验证IP有效性
    valid_ips=""
    local valid_count=0
    for ip in $ips; do
      if validate_ip "$ip"; then
        valid_ips="$valid_ips $ip"
        valid_count=$((valid_count + 1))
        [ $valid_count -ge $MAX_IPS ] && break
      fi
    done
    valid_ips=$(echo "$valid_ips" | xargs)  # 去除首尾空格

    # 检查是否满足最小要求
    if [ $valid_count -ge $MIN_IPS ]; then
      echo "$valid_ips"
      return 0
    fi

    attempts=$((attempts + 1))
    [ $attempts -lt $RETRY_TIMES ] && {
      local wait_time=$((attempts * 5))
      log "WARN" "有效IP不足:$valid_count(要求≥$MIN_IPS)，${wait_time}秒后重试..."
      sleep $wait_time
    }
  done

  log "ERROR" "无法获取足够有效IP（获取:$valid_count 要求≥$MIN_IPS）"
  return 1
}

# 安全更新配置（避免清空原有配置）
# $1: 有效IP列表（空格分隔）
update_config() {
  local ips="$1"
  local ip_count=$(echo "$ips" | wc -w)
  
  # 检查IP数量是否有效
  [ $ip_count -lt $MIN_IPS ] && {
    log "ERROR" "拒绝更新：有效IP数量不足($ip_count < $MIN_IPS)"
    return 1
  }

  # 清空旧配置（仅在确认有新配置时执行）
  while uci -q delete "$UCI_CONFIG" >/dev/null 2>&1; do :; done

  # 添加新IP
  local added=0 failed=0
  for ip in $ips; do
    if uci -q add_list "$UCI_CONFIG=$ip" >/dev/null; then
      added=$((added + 1))
    else
      failed=$((failed + 1))
      log "WARN" "IP添加失败: $ip"
    fi
  done

  # 提交配置变更
  if uci commit mosdns >/dev/null 2>&1; then
    log "INFO" "配置更新成功 新增:$added 失败:$failed"
    echo $added
  else
    log "ERROR" "配置提交失败"
    return 1
  fi
}

# 服务管理（状态感知）
service_ctl() {
  if /etc/init.d/mosdns status >/dev/null 2>&1; then
    log "INFO" "正在重启mosdns服务..."
    /etc/init.d/mosdns restart >/dev/null 2>&1 || {
      log "ERROR" "服务重启失败"
      return 1
    }
  else
    log "INFO" "正在启动mosdns服务..."
    /etc/init.d/mosdns start >/dev/null 2>&1 || {
      log "ERROR" "服务启动失败"
      return 1
    }
  fi
  return 0
}

#============================ 主逻辑 ============================#
main() {
  # 初始化检查
  acquire_lock
  check_deps

  # 获取有效IP列表（失败则直接退出）
  local ips=$(fetch_ips) || exit 1

  # 安全更新配置（失败则保留原有配置）
  local updated_count=$(update_config "$ips") || exit 1

  # 重启服务（仅在配置更新成功时执行）
  service_ctl || exit 1

  # 格式化日志输出（IP列表带引号）
  local formatted_ips=$(echo "$ips" | awk '{for(i=1;i<=NF;i++) printf "\"%s\"%s", $i, (i==NF?"":", ")}')
  log "INFO" "更新完成 数量:$updated_count IP列表:[$formatted_ips]"
}

#============================ 执行入口 ============================#
main "$@"