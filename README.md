# Cloudflare IP 自动更新脚本 for OpenWrt

![OpenWrt Logo](https://openwrt.org/lib/tpl/openwrt/images/logo.png)
![Cloudflare Logo](https://www.cloudflare.com/img/logo-cloudflare-dark.svg)

## 项目简介

专为 OpenWrt 设计的自动化脚本，用于：
- 自动获取 Cloudflare 优选 IP 列表
- 更新 mosdns 或类似 DNS 服务的配置
- 智能维护 IP 列表有效性
- 保障服务持续可用

## 功能特性

✅ **智能 IP 获取**  
- 多轮次验证 IP 有效性
- 自动过滤无效/重复 IP
- 支持自定义最小/最大 IP 数量

🔒 **安全更新机制**  
- 原子化配置更新（失败自动回滚）
- 文件锁防止并发执行
- 保留有效配置直至新配置验证通过

📊 **详尽的日志系统**  
- 分级日志输出（INFO/WARN/ERROR）
- 关键操作审计跟踪
- 格式化 IP 列表显示

⚙️ **高度可配置**  
```bash
# 主要配置参数
MAX_IPS=10                      # 最大获取IP数量（最大数量10，超过无效）
MIN_IPS=5                      # 最小有效IP阈值
CF_IP_URL="https://ip.164746.xyz"  # IP数据源
RETRY_TIMES=3                   # 网络请求重试次数
```

## 安装部署

### 前置要求
- OpenWrt 19.07 或更高版本
- 已安装 mosdns 或兼容的 DNS 服务
- 基础依赖：`curl`、`awk`、`uci`

### 安装步骤
1. 上传脚本到路由器：
```bash
scp update_cloudflare_ip.sh root@your-router:/etc/mosdns/
```

2. 设置可执行权限：
```bash
chmod +x /etc/mosdns/update_cloudflare_ip.sh
```

3. 添加定时任务（示例每天3点更新）：
```bash
echo "0 3 * * * /etc/mosdns/update_cloudflare_ip.sh" >> /etc/crontabs/root
service cron restart
```

## 使用方法

### 手动执行
```bash
/etc/mosdns/update_cloudflare_ip.sh
```

### 查看执行日志
```bash
logread -e CF-IP-Update
```

### 验证当前配置
```bash
uci get mosdns.config.cloudflare_ip
```

## 典型日志输出
```
[INFO] 开始第1次尝试获取IP
[WARN] 有效IP不足:10(要求≥11)，5秒后重试...
[INFO] 配置更新成功 新增:12 失败:0
[INFO] 正在重启mosdns服务...
[INFO] 更新完成 数量:12 IP列表:["1.1.1.1", "2.2.2.2", ...]
```

## 故障排查

| 问题现象 | 解决方案 |
|---------|----------|
| 获取IP数量不足 | 1. 检查网络连接<br>2. 调整 MIN_IPS 参数<br>3. 更换数据源 URL |
| 配置提交失败 | 1. 检查 mosdns 是否安装<br>2. 验证 UCI_CONFIG 路径 |
| 服务启动失败 | 1. 检查 mosdns 运行状态<br>2. 查看详细日志 `/var/log/mosdns.log` |

## 贡献指南

欢迎通过 Issue 或 PR 提交：
- 新功能建议
- 问题报告
- 代码改进

请遵循现有代码风格：
- 使用 ShellCheck 验证语法
- 添加详细的注释
- 保持模块化设计

## 开源协议

[MIT License](LICENSE)

Copyright (c) 2024 iamchq
