Gost Forward Manager 一键卸载脚本 — 完整使用说明

| **适用系统** | OpenWrt（需 LuCI 支持） |
| **执行权限** | 需要 root 权限 |

### 🚀 使用方法
一：### 🚀 一键安装命令 (install-gost-forward.sh)

### 请复制以下整行命令并在终端中执行。此命令将自动下载并运行您的安装脚本：
```bash
bash <(curl -fsSL https://github.soloplus.xyz/https://raw.githubusercontent.com/WilsonBryanz/normal_shell/main/network/gost-forward/install-gost-forward.sh)
 ```

二：### 🗑️ 一键卸载命令 (uninstall-gost-forward.sh)

### 当您需要清理环境、停止服务并卸载该 GOST 转发配置时，请执行以下命令：

```bash
bash <(curl -fsSL https://ghproxy.com/https://raw.githubusercontent.com/WilsonBryanz/normal_shell/main/network/gost-forward/uninstall-gost-forward.sh)
 ```


三：###  🔄 卸载流程（8 步完整清理）

| 步骤 | 操作内容 | 说明 |
|------|----------|------|
| **第 1 步** | 权限检查 | 验证当前用户是否为 root，非 root 则拒绝执行 |
| **第 2 步** | 停止并禁用服务 | 执行 `/etc/init.d/gost-forward stop` 并禁用开机自启 |
| **第 3 步** | 删除 11 个部署路径 | 清理所有安装时创建的文件和目录 |
| **第 4 步** | 清理 4 项 cron 标记 | 从 crontab 中移除 gost-forward 和 uu 相关的定时任务标记 |
| **第 5 步** | 清理 6 个 sysupgrade 持久化路径 | 从 `/etc/sysupgrade.conf` 中移除持久化配置 |
| **第 6 步** | 终止残留进程 + 清理临时文件 | kill 相关进程，删除临时目录 |
| **第 7 步** | 刷新 LuCI 缓存 | 执行 `rm -rf /tmp/luci-*` 清除 LuCI 模块缓存 |
| **第 8 步** | 完成提示 | 输出卸载完成信息 |

四：#### 🔮 卸载后建议

1. **重启路由器**（可选）：`reboot` 确保所有内存中的进程完全释放。
2. **验证清理结果**：检查以下路径是否已删除：
   ```bash
   ls /etc/gost-forward/ 2>&1    # 应提示不存在
   ls /usr/bin/gost 2>&1         # 应提示不存在
   ls /etc/init.d/gost-forward 2>&1  # 应提示不存在
   ```
3. **📁 清理的部署路径清单（11 项）
   ```
   /etc/gost-forward/              # 主配置目录
   /usr/bin/uu                     # uu 工具
   /usr/sbin/uu                    # uu 工具（sbin）
   /usr/bin/gost-forward           # gost-forward 主程序
   /usr/bin/gost                   # gost 二进制
   /usr/libexec/gost-forward-web   # Web 管理后端
   /usr/libexec/gost-forward-tcping # TCPing 检测工具
   /etc/init.d/gost-forward        # init.d 服务脚本
   /usr/lib/lua/luci/controller/gost-forward.lua   # LuCI 控制器
   /usr/lib/lua/luci/view/gost-forward/            # LuCI 视图目录
   ```
