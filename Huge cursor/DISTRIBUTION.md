# Shake Cursor 外部分发流程

本项目不上架 App Store，正式给外部用户使用时需要走 Apple 的 Developer ID 分发链路。不要使用 Xcode Organizer 里的 `App Store Connect` 上传/校验流程；那是 Mac App Store 校验，会要求 App Sandbox，并不适合当前这个需要启动本机 Codex Bridge 的 App。

1. 使用 `Developer ID Application` 证书签名 `.app` 和 `.dmg`
2. 使用 `Developer ID Installer` 证书签名 `.pkg`
3. 提交 Apple notarization
4. stapler 写入公证票据
5. 用 Gatekeeper 校验产物

## 重要限制

当前 App 不启用 App Sandbox。原因是核心能力需要：

- 监听全局鼠标晃动
- 启动本机 Codex Bridge 进程
- 与本机日历权限协作

Developer ID 站外分发不要求 App Sandbox，但 Mac App Store 要求。因此如果你看到下面这类错误，说明走错了分发通道：

```text
App sandbox not enabled
Info.plist must contain a LSApplicationCategoryType key
Submitting your Mac apps to the App Store
```

正确通道是 `xcrun notarytool submit ...`，也就是本仓库的 `./scripts/package_release.sh`。

## 本机准备

需要 Apple Developer Program 账号。

在 Xcode 中安装证书：

1. 打开 Xcode
2. 进入 `Settings > Accounts`
3. 选择团队
4. 打开 `Manage Certificates`
5. 创建或导入：
   - `Developer ID Application`
   - `Developer ID Installer`

构建时需要显式传入你的 Apple Developer Team ID：

```bash
APPLE_TEAM_ID=TEAMID ./scripts/package_release.sh
```

## Notary 凭证

推荐使用 App Store Connect API Key：

```bash
xcrun notarytool store-credentials shake-cursor-notary \
  --key /path/AuthKey_XXXXXXXXXX.p8 \
  --key-id KEY_ID \
  --issuer ISSUER_ID
```

也可以使用 Apple ID + app-specific password：

```bash
xcrun notarytool store-credentials shake-cursor-notary \
  --apple-id name@example.com \
  --team-id TEAM_ID \
  --password APP_SPECIFIC_PASSWORD
```

## 生成正式安装包

```bash
./scripts/package_release.sh
```

产物会输出到：

```text
dist/Shake-Cursor-版本号-构建号.dmg
dist/Shake-Cursor-版本号-构建号.pkg
```

其中 `.dmg` 是推荐分发形式，用户拖到 Applications 即可安装；`.pkg` 是标准安装器形式。

## 可选环境变量

```bash
APPLE_TEAM_ID=TEAMID
NOTARY_PROFILE=shake-cursor-notary
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)"
DEVELOPER_ID_INSTALLER="Developer ID Installer: Your Name (TEAMID)"
```

`SKIP_NOTARIZE=1` 只用于本机打包调试，不能给外部用户分发。
