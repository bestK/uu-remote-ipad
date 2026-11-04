# iPad ipad-v0.1.1

修复 ipad-v0.1.0：面板程序未签入权限，经 TrollStore 安装后在沙盒里运行，读不到宿主状态，也无法安装服务。请改用本版本。

- 越狱 iPad（Dopamine / roothide，iPadOS 16 验证）上运行宿主，官方 UU 远程客户端直接连接。
- 画面与触控跟随横竖屏；新连接按当前前台 App 的方向开始编码。
- 远程终端：打开 iPad 的 zsh（`mobile` 身份，可 `sudo`）。
- 面板：安装 / 卸载宿主服务、扫码登录与刷新二维码、连接记录、自动解锁、远程结束后锁屏。

安装：用 TrollStore 或 SideStore 安装 `UURemotePanel-ipad-v0.1.1.ipa`，打开主屏「UU 远程」，输入设备密码安装服务，
再用手机「网易UU远程」扫码。说明见 [ios/README.md](https://github.com/bestK/uu-remote-ipad/blob/main/ios/README.md)。

- IPA 内的 `frida-server` 取自 Frida 官方 17.25.0 `iphoneos-arm64` 包，脚本按 SHA-256 校验。
- 本包不带图标（不含网易素材），主屏显示系统默认图标。
- 非官方项目，与网易无关。

Fixes ipad-v0.1.0, whose panel binary carried no entitlements and ran sandboxed after a TrollStore install. Built from source by GitHub Actions. Install with TrollStore or SideStore,
open "UU 远程", install the service with the device password and scan the QR code with the UU Remote app.
`frida-server` comes from Frida's official 17.25.0 iphoneos-arm64 package (SHA-256 pinned). No icon is bundled.
