# 自定义触控板（NativeTrackpad）

独立原生手势监听程序：用系统私有 `MultitouchSupport` 读取全局触点，用 `CGEvent` 投递按键。**不依赖 BetterTouchTool、DSH 或任何第三方库**。

本文件夹只放「自定义触控板」本身，不导入或启用 BTT / DSH 配置，也不修改系统触控板偏好。

## 目录结构

| 路径 | 作用 |
| --- | --- |
| `Package.swift` / `Sources/` | Swift 源码（4 个文件），Swift 6.0 / macOS 15+ |
| `bin/TrackpadGestures` | 编译好的可执行文件，放在项目内稳定路径 |
| `control.sh` | 统一控制入口：start / stop / restart / status |
| `启动手势.command` 等 4 个 | 双击即可用的包装脚本 |
| `logs/` | 运行日志和 PID 文件 |

## 手势映射

| 手势 | 动作 |
| --- | --- |
| 双指并拢 | 复制 Command-C |
| 双指分开 | 粘贴 Command-V |
| 三指并拢 | 区域截图，保存 PNG 并写入剪贴板 |
| 三指分开 | 粘贴（紧接上一步可直接贴出图片） |
| 四指轻点 | 退格一次 |
| 四指长按 | 约 0.22 秒首次删除，0.4 秒起每 0.08 秒连续删除；移动或抬起即停 |

取消截图不改变剪贴板。

## 启动与权限

双击 `启动手势.command` 或执行 `./control.sh start`，程序会：

1. 检查二进制、触控设备和辅助功能权限。
2. 清理旧进程以及旧版 `launchd` 注册。
3. 在当前桌面会话中直接后台启动监听，标准输入重定向到 `/dev/null`，日志写入 `logs/`。
4. 等到日志明确出现「手势监听已启动」后才报告成功；启动失败会返回错误并清理进程。

权限检查和实际监听现在都使用同一个桌面会话权限上下文，避免命令行显示已授权、`launchd` 子进程却被系统拒绝的问题。若系统提示授权，请在「系统设置 → 隐私与安全性 → 辅助功能」中允许启动手势程序的桌面应用（例如终端或 Kimi Code），然后重新启动。

`restart` 会完整停止再启动，不会叠加旧实例。`stop` 同时清理旧版 `local.native-trackpad` 注册和项目内生成的 plist。

## 常用命令

| 需求 | 操作 |
| --- | --- |
| 启动 | 双击 `启动手势.command` |
| 停止 | 双击 `停止手势.command` |
| 重启 | 双击 `重启手势.command` |
| 查看状态 | 双击 `查看状态.command` |
| 命令行 | `./control.sh start\|stop\|restart\|status` |
| 只观察不注入 | `./bin/TrackpadGestures observe` |
| 自检 | `./bin/TrackpadGestures self-test`（13 项合成触点与定时器检查） |
| 设备与权限 | `./bin/TrackpadGestures check` |

## 约束

- **仅在当前桌面会话运行**：不安装到 `~/Library/LaunchAgents`，不设置登录自启。
- **异常退出后不自动拉起**：需要时执行 `./control.sh restart`。
- **不碰 BTT / DSH**：不导入备份、不恢复 bundle、不启用触发器。
- **不自动恢复实时听写服务**。
- 自检通过不等于真实触控板验收；复制、粘贴、截图和连续退格仍需在实际使用场景中确认。

## 重新构建

```zsh
cd /Users/zhuanzmima0000/Desktop/自定义触控板
swift build -c release --disable-sandbox --scratch-path /tmp/native-trackpad-build
cp /tmp/native-trackpad-build/release/TrackpadGestures bin/TrackpadGestures
./bin/TrackpadGestures self-test
./control.sh restart
```

`--disable-sandbox` 是必需的：SwiftPM 的 manifest 沙箱在部分自动化环境里会因嵌套沙箱报 `sandbox_apply: Operation not permitted`。

若重新构建后 `check` 显示未授予辅助功能权限，请重新授权再启动。截图还需要 macOS 录屏权限。

仓库附带的 `bin/TrackpadGestures` 是 Apple Silicon（ARM64）构建；其他架构请按上方命令从源码重新构建。本项目使用 macOS 私有 `MultitouchSupport` 框架，系统升级后可能需要适配，不适用于 Mac App Store。

## 开源许可

本项目基于 [MIT License](LICENSE) 开源。
