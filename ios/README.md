# UU 远程 iPad 宿主（越狱）

把 uu-remote-linux 宿主移植到越狱 iPad 上，用官方 UU 远程客户端（Windows / Mac / 手机）控制 iPad。
已在 iPad13,8（M1，iPadOS 16，Dopamine roothide）上验证：H.265、约 23 fps、客户端延迟约 11 ms、丢包 0。

## 工作方式

- **抓屏**：frida 注入 SpringBoard（`agent/screen.js`），`UIWindow.createScreenIOSurface` 编成 JPEG 写文件，宿主读取。
- **编码**：`c_engine/ios_video.m` 在进程内用 VideoToolbox 编 H.264 / H.265（Annex-B + AUD），半分辨率，约 25–30 fps。
- **输入**：frida 注入 backboardd（`agent/hid.js`）。触摸走 `AOPTouchHIDDriver` sender，键盘必须走 accessibility sender。
- **锁屏**：锁屏界面照常抓屏；画面停住时唤醒；面板 App 里保存的密码用于自动解锁；
  面板里的开关可以让最后一个远程连接结束后自动锁屏。
- **键位**（PC 客户端）：Ctrl→Cmd、Win→Ctrl、Alt→Option；Mac 客户端原样透传（Mac 的 Cmd 本来就是 Win 键）。

## 远程操作

电脑上怎么用，iPad 上就是什么效果：

| 操作 | Windows 客户端 | Mac 客户端 |
|---|---|---|
| 复制 / 粘贴 / 全选 / 撤销 | Ctrl+C / V / A / Z | Cmd+C / V / A / Z |
| 切换 App | Alt+Tab（按住 Alt 连按 Tab 选择，松开切换） | Cmd+Tab |
| 切到上一个 App | 鼠标在屏幕最底部左右拖 | 同左 |
| 多任务界面 | Win+Tab | Ctrl+↑ |
| 回桌面 | Win+D 或 Ctrl+H | Cmd+H |
| 切换输入法 | Win+Space | Ctrl+Space |
| Spotlight | Ctrl+Space | Cmd+Space |
| 切换中英文之外的输入法 | 同 Win+Space，在已启用的输入法之间循环 | 同 Ctrl+Space |

鼠标手势（屏幕最下方 4% 以内按下后拖动）：

| 拖动 | 效果 |
|---|---|
| 往上拖一点，直接松开 | 回桌面 |
| 往上拖，停住约 0.3 秒再松开 | 多任务界面 |
| 往左或往右拖 | 切到上一个 App（等同 iPad 上左右滑横条） |
| 只点不拖 | 普通点击（不影响底部按钮） |

- 切换输入法走 SpringBoard 的输入法接口，和按外接键盘的 🌐 键一样，在已启用的输入法之间循环（跳过表情键盘；同一语言装了多个键盘只算一个）。
- 回桌面 / 多任务是发键盘的 Home 键：解锁后系统会忽略合成的“从底边上滑”手势，Cmd+H 在 iPadOS 15 起也不是系统快捷键（改成了 🌐+H）。
- 密码框的屏幕键盘在远程画面里是灰块：iOS 不允许截屏包含安全输入的键盘。用电脑键盘直接打字即可。

## 目录

| 路径 | 作用 |
|---|---|
| `agent/` | 注入 SpringBoard / backboardd 的 frida 脚本（`objc.js` 是 frida 17 去掉的 ObjC bridge） |
| `app/` | 主屏「UU 远程」面板：登录二维码、自动解锁密码（`make-icon.py` 从本机官方 Mac 客户端生成图标，仓库里不放网易素材） |
| `install/` | LaunchDaemon（宿主 + frida-server）、宿主 entitlements、安装脚本（`install-service.sh` 由面板首次运行调用） |
| `frida/fetch-devkit.sh` | 下载 frida-core devkit 17.25.0（约 200 MB，不进仓库） |
| `probe/`、`tweak/` | 早期探针，诊断用 |

## 安装（普通用户，一个 IPA）

1. 设备需要越狱（Dopamine / roothide），frida-server 必须以 root 运行。
2. 用 TrollStore 或 SideStore 安装 `UURemotePanel.ipa`（构建产物在 `ios/app/build/`）。
   IPA 里已经带了宿主服务：`uuremote-server`、`frida-server`、两个 LaunchDaemon 配置和安装脚本。
3. 首次打开「UU 远程」面板，会看到「安装服务」卡片：输入设备密码（Dopamine 默认 `123`），点「安装」。
   面板通过 sudo 调用随包的 `install-service.sh`，把服务装进系统并启动。
4. 装好后卡片消失，状态变成「等待扫码登录」，用手机上的「网易UU远程」扫码即可。

面板里的「账号」卡片可以退出登录，退出后需要重新扫码。

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

面板 App 拷到 `/var/jb/Applications/UURemotePanel.app`，用 `app/entitlements.plist` 签名后 `uicache -p`。

首次运行会在面板上显示登录二维码，用手机「网易 UU 远程」扫码确认即可。
日志：`/var/jb/var/log/uuremote.log`。

## 踩过的坑

- launchd 守护进程默认 jetsam 上限只有 18 MB（致命），客户端一连上就被 SIGKILL，没有崩溃报告，只能 `dmesg` 看到。
  宿主启动时用 `memorystatus_control` 抬到 1024 MB。
- `screen.js` 必须释放 `CGImageDestination`，否则每帧漏一整张屏幕 IOSurface，约 20 秒后 SpringBoard 再也拿不到屏幕。
- iPadOS 16+ 上 `screenIsOn` / `backlightState` / `hasBlankedScreen` 在熄屏时都不可靠，用“锁屏 + 画面连续不变”判断。
- 合成的“从底边上滑”只在锁屏有效，解锁后被忽略；回桌面、多任务要发键盘 Home 键（consumer page 0x0C usage 0x40，按一次回桌面、连按两次开多任务）。
- 输入法切换：`nextInputModeToUseForTraits:updatePreference:` 会返回空，改为在 `enabledInputModeIdentifiers` 里取当前项的下一个。
- 自动解锁密码被拒一次就停，直到重新保存，避免连续输错让 iPad 被停用。
- 面板的密码框不用 `secureTextEntry`（那样系统会把键盘从截屏里去掉，远程只看到灰块），改为自己打圆点。
