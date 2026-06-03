# ssh-back

`ssh-back` 是一个 macOS 菜单栏工具，用来解决 SSH 远程开发时 OAuth、SSO、CLI 登录等流程需要拉起本地浏览器的问题。

它会管理 SSH 会话和端口转发，在远端开发机注入一个 `BROWSER` shim。远端程序尝试打开浏览器时，请求会被转发回本机；`ssh-back` 解析登录回调端口，先建立 callback 隧道，再打开本机浏览器。

## 功能

- **macOS 菜单栏工具**
  - 无需 Dock 窗口，常驻菜单栏。
  - 空闲、连接中、已连接、错误状态会显示在菜单里。
  - 已连接时菜单栏图标显示绿点。

- **读取 `~/.ssh/config`**
  - 自动加载 OpenSSH `Host` 别名。
  - 菜单里可以直接选择 SSH Config Hosts 连接。
  - 连接时仍把别名交给 `ssh` 解析，避免重复实现 OpenSSH 配置语义。

- **自动启动 SSH 控制隧道**
  - 连接后创建远端到本机的 control bridge。
  - 远端 Browser shim 通过这个 bridge 把浏览器打开请求发回本机。
  - Remote Agent 端口默认自动随机选择，也可以在菜单里固定为自定义端口。

- **自动注入 Browser shim**
  - shim 安装到远端 `~/.ssh-back/browser`。
  - 根据远端默认 shell 选择 `~/.zshrc` 或 `~/.bashrc`。
  - 当 rc 文件里已经有用户自己的 `BROWSER` 配置时，不重复追加。
  - 否则写入一段 ssh-back 管理的 `export BROWSER="$HOME/.ssh-back/browser"`。

- **自动解析 callback 并建隧道**
  - 支持从登录 URL 或嵌套 `redirect_uri` 中解析 loopback callback 端口。
  - 只接受 `localhost`、`127.0.0.1` 等 loopback callback。
  - 打开本机浏览器前，先建立本机到远端的 callback tunnel。

- **浏览器打开确认 Hook**
  - 菜单里提供 Browser Requests 列表。
  - 每次远端请求打开本机浏览器前，先进入待审批列表，用户可以选择 Approve 或 Deny。
  - 用户未审批或拒绝时不会创建 callback tunnel，也不会打开浏览器。
  - 菜单里保留最近的跳转请求记录，可以查看状态、callback 和复制 URL。

- **手动联通性验证**
  - 菜单提供 `Copy Test Command`。
  - 在远端执行复制出来的 `curl http://127.0.0.1:<port>/test` 可以验证 control bridge 是否联通。
  - `/test` 不会触发浏览器打开，也不会创建 callback tunnel。

- **GitHub Release 自动构建**
  - 推送 `v*` tag 后 GitHub Actions 会在 macOS runner 上运行测试。
  - 测试通过后签名并打包 `SSH Back.app` 为 zip。
  - 同时生成 `.sha256` checksum 并上传到 GitHub Release。

## 本地运行

构建 macOS app bundle：

```bash
scripts/build-app-bundle.sh
```

启动菜单栏 app：

```bash
open ".build/release/SSH Back.app"
```

运行测试：

```bash
swift test
```

## 本地打包 Release

```bash
SSH_BACK_RELEASE_VERSION=v0.1.0 scripts/package-release.sh
```

产物会写到：

```text
.build/release-artifacts/
```

包括：

- `ssh-back-v0.1.0-macos.zip`
- `ssh-back-v0.1.0-macos.zip.sha256`

## 下载后提示已损坏

未配置 Developer ID 签名和 Apple notarization 时，Release 包只做 ad-hoc 签名。macOS 下载后可能因为 quarantine 隔离属性提示 `SSH Back.app` 已损坏。

如果你已经把 app 放到 `/Applications`，可以执行：

```bash
xattr -dr com.apple.quarantine "/Applications/SSH Back.app"
```

然后重新打开 app。

## 发布 GitHub Release

推送版本 tag：

```bash
git tag v0.1.0
git push origin main v0.1.0
```

GitHub Actions 会自动创建或更新对应的 Release，并上传 macOS zip 和 checksum。

### Release 签名和公证

打包脚本默认会对 `.app` 做 ad-hoc 签名，避免 bundle 因签名不完整被 macOS 判定为“已损坏”。如果要让用户下载后无需手动移除 quarantine，需要在 GitHub Actions 配置 Developer ID 签名和 Apple notarization secrets：

- `MACOS_CERTIFICATE_P12_BASE64`: Developer ID Application 证书 `.p12` 的 base64 内容。
- `MACOS_CERTIFICATE_PASSWORD`: `.p12` 证书密码。
- `MACOS_KEYCHAIN_PASSWORD`: CI 临时 keychain 密码。
- `MACOS_CODESIGN_IDENTITY`: 证书身份名，例如 `Developer ID Application: Your Name (TEAMID)`。
- `MACOS_NOTARY_APPLE_ID`: Apple ID。
- `MACOS_NOTARY_TEAM_ID`: Apple Developer Team ID。
- `MACOS_NOTARY_PASSWORD`: app-specific password 或 notarytool 可用密码。

## 当前边界

- 目前目标平台是 macOS 13+。
- 本地打包未配置 Developer ID 时只做 ad-hoc 签名，用户仍可能需要通过右键打开或手动移除 quarantine。
- callback 自动隧道只支持 loopback 地址，非 loopback callback 会被拒绝。
