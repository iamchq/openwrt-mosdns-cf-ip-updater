# Cloudflare优选IP自动更新脚本 for OpenWrt/mosdns

## 简介

本脚本用于自动从指定数据源获取Cloudflare优选IP，并更新mosdns的UCI配置中的IP列表，同时确保mosdns的Cloudflare功能开关处于启用状态。脚本具备IP去重、配置备份与回滚、锁机制等特性，适合在OpenWrt路由器上通过cron定时执行。

## 功能特点

- ✅ **多源支持**：可配置多个IP数据源，按顺序尝试，提高可用性。
- ✅ **智能IP提取**：从HTML、JSON、纯文本等任意格式中提取IPv4地址，不依赖特定结构。
- ✅ **自动去重**：保证最终IP列表无重复，避免冗余配置。
- ✅ **配置安全**：更新前自动备份完整UCI配置，更新失败时自动回滚。
- ✅ **开关控制**：自动检查并启用mosdns的Cloudflare功能开关（`mosdns.config.cloudflare`）。
- ✅ **服务管理**：根据服务状态自动启动或重启mosdns，不改变开机自启设置。
- ✅ **并发防护**：使用`flock`或PID文件锁，防止脚本同时运行。
- ✅ **日志记录**：同时输出到系统日志（`logger`）和控制台（可开关），便于调试。

## 系统要求

- OpenWrt 19.07 或更高版本（或任何支持ash、uci、curl的环境）
- mosdns 已安装并配置
- 依赖命令：`curl`、`awk`、`uci`、`grep`（通常已预装）

## 安装与配置

1. **下载脚本**  
   将脚本保存到路由器，例如 `/root/update_cf_ip.sh`：
   ```bash
   wget -O /root/update_cf_ip.sh https://your-server/update_cf_ip.sh
   # 或手动创建文件
   ```

2. **赋予执行权限**：
   ```bash
   chmod +x /root/update_cf_ip.sh
   ```

3. **编辑配置**（可选）  
   根据实际情况修改脚本顶部的“用户配置区”：
   - `MAX_IPS`：期望的最大唯一IP数量（默认10）
   - `MIN_IPS`：可接受的最小有效IP数量（默认5）
   - `CF_IP_URLS`：IP数据源URL，空格分隔（支持多个备用）
   - `UCI_IP_NODE`：UCI中存储IP列表的节点（默认 `mosdns.config.cloudflare_ip`）
   - `UCI_ENABLED_NODE`：Cloudflare功能开关节点（默认 `mosdns.config.cloudflare`）
   - `VERBOSE`：是否输出详细信息到控制台（1=开启，0=关闭）
   - `KEEP_BACKUPS`：保留的配置备份数量（默认3）

## 使用方法

### 手动运行测试

```bash
/root/update_cf_ip.sh
```

观察控制台输出（若`VERBOSE=1`），或查看系统日志：
```bash
logread | grep CF-IP-Update
```

### 设置定时任务（cron）

通过cron定期执行脚本，例如每6小时运行一次：

1. 编辑crontab：
   ```bash
   crontab -e
   ```

2. 添加以下行：
   ```cron
   0 */6 * * * /root/update_cf_ip.sh >> /var/log/cf_ip_update.log 2>&1
   ```

3. 保存退出，cron会自动生效。

## 配置选项详解

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `MAX_IPS` | 10 | 期望获取的最大唯一IP数量（超过会被截断） |
| `MIN_IPS` | 5 | 可接受的最小有效IP数量，低于此值放弃更新 |
| `RETRY_TIMES` | 3 | 单个数据源获取失败时的重试次数 |
| `CURL_TIMEOUT` | 30 | curl请求超时时间（秒） |
| `CF_IP_URLS` | `"https://ip.164746.xyz https://example.com"` | IP数据源URL，空格分隔 |
| `UCI_IP_NODE` | `"mosdns.config.cloudflare_ip"` | UCI中存储IP列表的节点 |
| `UCI_ENABLED_NODE` | `"mosdns.config.cloudflare"` | Cloudflare功能开关节点（留空则不检查） |
| `VERBOSE` | `1` | 1=控制台输出详细日志，0=仅系统日志 |
| `LOG_TAG` | `"CF-IP-Update"` | 系统日志标签 |
| `LOCK_DIR` | `"/var/run"` | 锁文件存放目录 |
| `BACKUP_DIR` | `"/tmp"` | 配置备份存放目录 |
| `KEEP_BACKUPS` | `3` | 保留的配置备份数量 |
| `SERVICE_NAME` | `"mosdns"` | 服务名称 |
| `SERVICE_CMD` | `"/etc/init.d/mosdns"` | 服务管理脚本路径 |

## 日志查看

- **系统日志**：`logread | grep CF-IP-Update`
- **控制台输出**（若`VERBOSE=1`）：运行时直接显示
- **cron日志**（若重定向到文件）：`cat /var/log/cf_ip_update.log`

日志示例：
```
[2026-03-25 12:34:56] CF-IP-Update [INFO] 尝试获取 IP: https://ip.164746.xyz (第 1 次)
[2026-03-25 12:34:58] CF-IP-Update [INFO] 检测到 IP 列表变化，开始更新配置
[2026-03-25 12:34:58] CF-IP-Update [INFO] 配置提交成功 (新增:8 失败:0)
[2026-03-25 12:34:58] CF-IP-Update [INFO] Cloudflare 功能开关已启用，无需操作
[2026-03-25 12:34:58] CF-IP-Update [INFO] 服务正在运行，执行 restart...
[2026-03-25 12:35:00] CF-IP-Update [INFO] 服务操作成功
[2026-03-25 12:35:00] CF-IP-Update [INFO] 更新完成 数量:8 IP列表:["104.18.47.135", "162.159.26.91", ...]
```

## 故障排除

### 1. 脚本无法获取足够IP
- 检查网络连接：`curl -v https://ip.164746.xyz`
- 尝试更换数据源（修改`CF_IP_URLS`）
- 增加`MIN_IPS`或减少`MAX_IPS`

### 2. 配置更新失败，提示“缺少必需命令”
- 安装缺失命令，例如`opkg update && opkg install curl`

### 3. mosdns服务无法启动
- 检查mosdns配置文件：`uci show mosdns`
- 查看mosdns日志：`logread | grep mosdns`
- 手动测试：`/etc/init.d/mosdns restart` 并观察输出

### 4. 脚本重复运行（锁文件残留）
- 手动删除锁文件：`rm -f /var/run/cf_ip_update.lock`
- 脚本已内置超时（300秒）清理机制，通常无需干预

### 5. 备份文件过多占用空间
- 调整`KEEP_BACKUPS`为较小值（如2）
- 手动清理：`rm -f /tmp/mosdns_backup_*`

## 注意事项

- **数据源可靠性**：默认数据源可能随时变更，建议使用稳定的源或自建。
- **mosdns配置兼容性**：请确保UCI节点路径与您的mosdns配置一致，可通过`uci show mosdns`确认。
- **服务重启**：脚本执行`restart`或`start`服务，但**不会改变**服务开机自启状态（即不会执行`enable`），适合cron环境。
- **备份文件**：备份存储在`/tmp`目录，重启路由器后丢失。如需持久化，请修改`BACKUP_DIR`为持久存储路径（如`/etc`）。

## 许可证

MIT License

---

Copyright (c) 2024 iamchq
