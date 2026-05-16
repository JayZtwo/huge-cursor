[下载 macOS DMG 安装包](https://github.com/JayZtwo/huge-cursor/releases/latest/download/Shake-Cursor-1.0-1.dmg)

# Shake Cursor

Shake Cursor 是一个 macOS 桌面入口实验：快速晃动鼠标，在当前位置唤起一个轻量浮层，用 Codex 生成签文、回答日常问题，并在识别到明确时间时写入本机日历。

它最初来自 Huge Cursor 的交互探索：第三方 App 无法直接读取 macOS “晃动鼠标指针以定位”产生的系统放大状态，所以项目选择直接监听鼠标轨迹，识别全方向快速晃动，并把这个动作变成一个可复用入口。

## 演示

[查看早期演示视频](media/demo.mp4)

## 当前能力

- 支持全方向快速晃动识别：左右、上下、斜向都可以触发。
- 在晃动位置附近唤起浮层输入框。
- 展示科技签筒和签文结果。
- 连接本机 Codex，生成中文签文和日常助手回复。
- 识别明确时间的日程请求，并写入 macOS 日历。
- 主窗口隐藏到后台后继续监听。

## 使用前准备

1. 安装并登录 Codex Desktop。
2. 打开 Shake Cursor，按启动检查页完成权限确认。
3. 点击「隐藏到后台」。后台运行时，摇动鼠标才能稳定唤起浮层。

需要的系统权限：

- 辅助功能：用于后台监听全局鼠标晃动。
- 日历：用于在你明确要求安排日程时写入 macOS 日历。

## 隐私说明

Shake Cursor 不包含自建后端，也不会把数据上传到开发者服务器。

应用会把你的抽签请求或输入内容交给本机 Codex Bridge，由你本机已登录的 Codex 环境处理。日历写入只发生在本机 macOS Calendar 中。源码仓库不包含 Apple ID、app-specific password、notary 凭据、Keychain 内容或本机构建日志。

## 项目结构

```text
Huge cursor/
  Shake Cursor.xcodeproj
  Shake Cursor/
  scripts/
  DISTRIBUTION.md
```

核心文件：

- `Huge cursor/Shake Cursor/MouseShakeMonitor.swift`：鼠标晃动识别。
- `Huge cursor/Shake Cursor/ShakeInputOverlay.swift`：桌面浮层和抽签 UI。
- `Huge cursor/Shake Cursor/CodexBridge.swift`：本机 Codex Bridge 通信。
- `Huge cursor/Shake Cursor/CalendarEventWriter.swift`：macOS 日历写入。

## 从源码运行

环境要求：

- macOS 15.6 或更新版本
- Xcode 26.5 或兼容版本
- 已安装并登录 Codex Desktop

打开：

```bash
open "Huge cursor/Shake Cursor.xcodeproj"
```

终端构建：

```bash
xcodebuild -project "Huge cursor/Shake Cursor.xcodeproj" \
  -scheme "Shake Cursor" \
  -configuration Debug \
  -destination "generic/platform=macOS" \
  CODE_SIGN_IDENTITY=- \
  build
```

## 打包分发

Developer ID 站外分发流程见 [DISTRIBUTION.md](./Huge%20cursor/DISTRIBUTION.md)。

```bash
cd "Huge cursor"
APPLE_TEAM_ID=YOUR_TEAM_ID ./scripts/package_release.sh
```

生成的 `.dmg` 推荐通过 GitHub Releases 分发，不建议提交到源码仓库。

## License

MIT
