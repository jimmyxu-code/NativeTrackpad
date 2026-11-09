# NativeTrackpad

原生 macOS 触控板手势工具。使用私有 `MultitouchSupport` 读取触点，用 `CGEvent` 投递键盘动作，不依赖 BetterTouchTool、DSH 或其他第三方库。

## 手势映射

| 手势 | 动作 |
| --- | --- |
| 双指并拢 | 复制 Command-C |
| 双指分开 | 粘贴 Command-V |
| 三指并拢 | 区域截图，保存 PNG 并复制到剪贴板 |
| 三指分开 | 粘贴 Command-V |
| 三指轻点 | 回车 |
| 四指轻点 | 退格一次 |
| 四指长按 | 约 0.22 秒首次退格，0.4 秒起每 0.08 秒连续退格；移动或抬起即停 |
| 五指轻点（不超过 0.5 秒） | 空格 |

取消截图不会改变剪贴板。双指短按保留系统右键，不注入回车。引擎对触点帧设置 150ms 超时：丢失抬起帧时安全结束当前会话并清理过期触点，避免重复触发和手势卡死。

## 登录自启

项目使用 LaunchAgent `local.native-trackpad`：

- 用户登录后自动启动应用。
- 应用退出后，LaunchAgent 按 5 秒间隔重新拉起。
- 触点回调超过 10 秒没有新帧时，自动刷新设备列表并重新注册监听，覆盖睡眠唤醒和设备状态变化后的失效场景。
- `control.sh stop` 会停止应用并移除自启注册；下次 `start` 会重新注册。
- 运行副本安装在 `~/Library/Application Support/NativeTrackpad`，避免中文路径影响 LaunchAgent。
- 日志位于 `~/Library/Application Support/NativeTrackpad/logs/`。

已验证 `launchctl` 注册、启动以及结束后自动重新拉起。自启是**用户登录自启**，不是登录窗口出现前的系统级启动。

## 常用命令

```zsh
./control.sh start    # 启动并注册登录自启
./control.sh stop     # 停止并移除自启注册
./control.sh restart  # 重新构建运行副本并重启
./control.sh status   # 查看进程、自启注册和权限
```

也可以双击 `启动手势.command`、`停止手势.command`、`重启手势.command` 或 `查看状态.command`。

其他命令：

```zsh
./bin/TrackpadGestures check
./bin/TrackpadGestures observe --verbose
./bin/TrackpadGestures self-test
./bin/TrackpadGestures action-check copy
./bin/TrackpadGestures action-check paste
./bin/TrackpadGestures action-check delete
./bin/TrackpadGestures action-check hold
```

## 权限

- **辅助功能**：用于读取触控板和投递键盘动作。若系统提示，请在「系统设置 → 隐私与安全性 → 辅助功能」中允许 `TrackpadGestures`。
- **录屏**：三指并拢区域截图需要该权限。
- **稳定签名**：自启应用使用本机 `NativeTrackpadLocal` 代码签名身份，避免 ad hoc 重签后代码哈希变化导致权限失效。签名证书只保存在登录钥匙串，不进入仓库。
- **权限初始化**：程序启动时先初始化 `NSApplication`，再检查辅助功能权限，确保系统能够展示授权提示。

## 构建

```zsh
cd /Users/zhuanzmima0000/Desktop/自定义触控板
swift build -c release --disable-sandbox --scratch-path /tmp/native-trackpad-build
cp /tmp/native-trackpad-build/release/TrackpadGestures bin/TrackpadGestures.new
mv bin/TrackpadGestures.new bin/TrackpadGestures
cp bin/TrackpadGestures TrackpadGestures.app/Contents/MacOS/TrackpadGestures
codesign --force --sign NativeTrackpadLocal TrackpadGestures.app
./bin/TrackpadGestures self-test
./control.sh restart
```

`--disable-sandbox` 用于避免部分自动化环境中的 SwiftPM 嵌套沙箱错误。仓库附带 Apple Silicon（ARM64）构建；其他架构请从源码重新构建。

项目使用私有框架，系统升级后可能需要适配，不适用于 Mac App Store。

## 项目结构

- `Sources/TrackpadGestures/`：4 个 Swift 源文件，只包含设备监听、手势识别、系统动作和入口自检。
- `TrackpadGestures.app/`：标准应用包及 `Info.plist`。
- `LaunchAgents/local.native-trackpad.plist`：自启模板。
- `control.sh`：启动、停止、重启和状态检查。
- `bin/TrackpadGestures`：编译后的命令行可执行文件。

## 开源

基于 [MIT License](LICENSE) 开源。

仓库：[github.com/jimmyxu-code/NativeTrackpad](https://github.com/jimmyxu-code/NativeTrackpad)
