# UU 远程 iPad 宿主（越狱）

把 uu-remote-linux 宿主移植到越狱 iPad 上，用官方 UU 远程客户端（Windows / Mac / 手机）控制 iPad。
已在 iPad13,8（M1，iPadOS 16，Dopamine roothide）上验证。

## 工作方式

- **抓屏**：frida 注入 SpringBoard（`agent/screen.js`），`UIWindow.createScreenIOSurface` 编成 JPEG 写文件，宿主读取。
- **编码**：`c_engine/ios_video.m` 在进程内用 VideoToolbox 编 H.264 / H.265（Annex-B + AUD），半分辨率，约 25–30 fps。
- **输入**：frida 注入 backboardd（`agent/hid.js`）。触摸走 `AOPTouchHIDDriver` sender，键盘必须走 accessibility sender。
- **锁屏**：锁屏界面照常抓屏；画面冻结时上滑唤醒（只在锁屏时）；面板 App 里保存的密码用于自动解锁。
- **键位**（PC 客户端）：Ctrl→Cmd、Win→Ctrl、Alt→Option；Mac 客户端原样透传。

## 目录

| 路径 | 作用 |
|---|---|
| `agent/` | 注入 SpringBoard / backboardd 的 frida 脚本（`objc.js` 是 frida 17 去掉的 ObjC bridge） |
| `app/` | 主屏「UU 远程」面板：登录二维码、自动解锁密码 |
| `install/` | LaunchDaemon（宿主 + frida-server）、宿主 entitlements、安装脚本 |
| `frida/fetch-devkit.sh` | 下载 frida-core devkit 17.25.0（约 200 MB，不进仓库） |
| `probe/`、`tweak/` | 早期探针，诊断用 |

## 构建（Mac）

```sh
ios/frida/fetch-devkit.sh
# Homebrew 的 cargo 没有 iOS std，用 rustup 工具链
export PATH="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$PATH"
IPHONEOS_DEPLOYMENT_TARGET=16.0 SDKROOT=$(xcrun --sdk iphoneos --show-sdk-path) UU_NO_GTK=1 \
  cargo build --release --target aarch64-apple-ios --bin uuremote-server
ios/app/build.sh   # 面板 App
```

## 安装（iPad，root）

设备上需要 frida-server、`ldid`、`uiopen`。

```sh
# 二进制先拷到临时名再 mv，运行中的文件不能直接覆盖
ldid -Sios/install/entitlements.plist uuremote-server
sh ios/install/install.sh ./uuremote-server
```

面板 App 拷到 `/var/jb/Applications/UURemotePanel.app`，用 `app/entitlements.plist` 签名后 `uicache`。

首次运行会在面板上显示登录二维码，用手机「网易 UU 远程」扫码确认即可。
日志：`/var/jb/var/log/uuremote.log`。

## 踩过的坑

- launchd 守护进程默认 jetsam 上限只有 18 MB（致命），客户端一连上就被 SIGKILL，没有崩溃报告，只能 `dmesg` 看到。
  宿主启动时用 `memorystatus_control` 抬到 1024 MB。
- `screen.js` 必须释放 `CGImageDestination`，否则每帧漏一整张屏幕 IOSurface，约 20 秒后 SpringBoard 再也拿不到屏幕。
- iPadOS 16+ 上 `screenIsOn` / `backlightState` / `hasBlankedScreen` 在熄屏时都不可靠，用“锁屏 + 画面连续不变”判断。
- 自动解锁密码被拒一次就停，直到重新保存，避免连续输错让 iPad 被停用。
