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

## 面板 App

主屏上的「UU 远程」是唯一的操作入口，中英双语，跟随系统深色模式和字号。界面采用 28pt 连续圆角卡片与底部居中悬浮胶囊栏：
浅色模式下以暖石灰底配纯白卡片、荧光青柠状态胶囊与纯黑胶囊主按钮；深色模式下以纯碳黑底配电光蓝几何星芒状态主卡、石墨灰卡片与暗红退出胶囊。
快捷键页左侧是动作、右侧是胶囊键帽，Windows / macOS 分段切换。IPA 同时声明支持 iPhone 和 iPad，并分别提供主屏图标；iPhone 的完整真机验收仍未完成。

- **连接**：运行状态主卡（设备名、状态胶囊、状态副行、最近一次连接摘要）、扫码登录、安装宿主服务、圆形头像账号卡与连接记录。摘要与列表同源，没有记录时只保留列表空态，不再两处各说一遍。
- **安全**：自动解锁密码（带状态胶囊与无边框胶囊输入框）、远程结束后锁屏、宿主服务重启与卸载。
- **快捷键**：Windows / macOS 分段切换，另列底边鼠标手势。
- **日志**：宿主与 frida-server 日志（最近 256 KB），可刷新、复制、分享；确认并输入 sudo 密码后可清除当前日志（原地清空，不重启服务）；长日志右侧滚动条可直接拖动，支持辅助功能翻页。日志正文中以 `Z` 结尾的时间及导出标题均为 UTC。导出时附面板/宿主版本、系统版本与越狱类型，不含账号信息。

状态真正改变时整块状态主卡短暂溶解；“正在远控”时状态圆形徽章缓慢呼吸；减少动态效果下缩短或关闭转场。
进入后台停止界面轮询，回到前台立即刷新。

| 卡片 | 作用 |
|---|---|
| 状态 | 新鲜的宿主心跳表示服务运行中、是否已登录及有没有人在远程；心跳不可用时显示「状态不可用」，不推断云端在线状态；未登录时显示扫码二维码 |
| 安装宿主服务 | 没有可见的启动项和新鲜心跳时显示「安装或修复」，输入设备密码安装；操作会重启后台服务（见下面的安装一节） |
| 账号 | 已登录时可退出；退出后自动在 App 内显示新二维码，「扫码登录」可回到二维码，「刷新二维码」可重试 |
| 自动解锁 | 保存锁屏密码，远程连接时自动解锁；显示上次自动解锁成功还是被拒 |
| 远程结束后锁屏 | 最后一个远程连接结束后自动锁屏 |
| 宿主服务 | 在「安全」页确认并输入 sudo 密码后重启（`launchctl kickstart -k`，frida-server 先于宿主）或卸载；服务离线时也可清理残留；卸载后（宿主未运行且无启动项）改为「安装宿主服务」 |
| 日志 | 「日志」页查看 `<越狱根>/var/log/uuremote.log` 与 `frida-server.log`，复制或通过系统分享导出；读不到时重启一次服务即修正权限 |
| 远程快捷键 | 上面那张按键对照表 |
| 连接记录 | 最近 5 次远程连接的时间和时长 |

面板以 `mobile` 用户运行，和宿主（root）只通过文件通信：`/private/var/tmp/uu-status.json`（运行状态）、
`uu-history.jsonl`（连接记录）、`uu-status.txt` / `uu-qr.png`（登录）、`uu-unlock.txt`（解锁结果），
以及 `/var/mobile/Library/UURemote/` 下的 `unlock.key`、`settings.json`、`command`。这些文件都不含密码以外的个人内容，
密码只用于解锁，不写入日志。

## 实验：远控悬浮提示

`ios/hud/` 是独立进程，不注入 SpringBoard。它随面板 IPA 一起打包，由 `install-service.sh` 在装宿主服务时一并安装，卸载宿主服务时一并移除。它通过私有 accessibility window hosting 请求系统托管一个不可交互的悬浮提示，与状态栏同一行、位于时间右侧：

- 刘海机型（屏高/屏宽 > 1.9，如 iPhone X）：刘海约占屏宽 53%，左侧只剩约 20pt，显示为红色圆点并缓慢呼吸（1.3 秒一个来回，缩放 1.0↔1.18、透明度 1.0↔0.72）；开启「减弱动态效果」时静态显示。
- iPad 与非刘海机型：显示文字胶囊「UU 远控中」/「Remote」。
- 无人远控时隐藏；心跳缺失、两份状态来自不同宿主实例或版本冲突时显示琥珀色「状态未知」，不推断为已结束。

文件、终端和端口映射工具连接不计入；短暂断线仍可能保持连接状态。它不证明视频一定正在传输，也不是系统原生的隐私指示器。

原型使用未经验证的私有 API 和 entitlement，在 iOS 16.7 / roothide 真机上的显示、输入穿透、锁屏、旋转及进程异常后的清理**均未验证**。过去在 SpringBoard 内创建窗口曾让设备进入安全模式；独立进程也不能保证无系统风险。实验程序必须带 `--experimental` 参数，60 秒后退出；另有独立线程在 65 秒时强制结束进程，收到 SIGTERM 或 SpringBoard 重启后 2 秒内也会强制退出。系统级卡死时这些措施同样不能保证生效；不要在重要设备上未经确认启动。它还未与服务安装器、面板开关或开机启动集成。

宿主现在以原子替换方式写 `uu-status.json`，并附带 `status_instance` 和递增的 `status_revision`，悬浮提示按版本号而不是秒级时间排序；直连和 `/rootfs` 两份状态来自不同实例或同版本内容冲突时显示「状态未知」。旧版宿主没有这两个字段，悬浮提示会一直显示「状态未知」。

它作为独立 LaunchDaemon `com.uuremote.indicator` 运行，由 IPA 内的 `install-service.sh` 自动安装（单独重装可用 `sh ios/install/install-indicator.sh <越狱根> <service 目录>`，卸载用 `sh ios/install/uninstall-indicator.sh <越狱根>`）。
悬浮提示安装失败只打印警告，不会影响宿主服务。daemon 必须从 `.app` 包内启动，否则 UIKit 拿不到 bundle 标识会直接抛异常退出。

已验证：iPhone X / iOS 16.7.15 / roothide 上悬浮窗能跨应用显示在状态栏同一行、时间右侧、不压刘海；无远控时隐藏。该进程在插件环境里只能读到 `/private/var/tmp/uu-status.json`，
同目录其他文件与 `/rootfs` 一律 ENOENT，所以 `--fixture` 在这台设备上不可用，联调只能靠真实连接。

只构建与运行隔离测试，不连接设备：

```sh
sh ios/hud/tests/check-state.sh
python3 -I ios/hud/tests/check-view.py
sh ios/hud/build-experiment.sh /tmp/uu-indicator-new-build
```

状态检查使用合成数据；视图截图是 UIKit/Mac Catalyst 合成渲染，不是 iPhone 或 iPad 实机截图。构建路径必须不存在。私有 HUD 托管方式参考 TrollSpeed，许可见 `ios/hud/NOTICE.TrollSpeed`。

## 已知限制

- 正式版目前没有跨应用的「正在被远控」提示；上述实验原型不能作为生产功能依赖。
- 剪贴板还没有同步。
- 远控过程中旋转 iPad 或打开竖版 App，画面会立即按新方向输出（主控窗口内可能出现黑边），但官方 Mac 主控只在
  自己发起分辨率变更时调整窗口大小；要得到贴合竖版的窗口，重新连接一次即可。
- 底部左右拖切 App 会先闪一下多任务界面（系统不认合成的手势和 Cmd+Tab，只能走多任务界面点卡片）。
- 密码框弹出的屏幕键盘在远程画面里是灰块（iOS 不允许截屏包含安全输入的键盘），用电脑键盘直接打字。

## 目录

| 路径 | 作用 |
|---|---|
| `agent/` | 注入 SpringBoard / backboardd 的 frida 脚本（`objc.js` 是 frida 17 去掉的 ObjC bridge） |
| `app/` | 主屏「UU 远程」面板：登录二维码、自动解锁密码（`make-icon.py` 从本机官方 Mac 客户端生成图标，仓库里不放网易素材） |
| `install/` | LaunchDaemon（宿主 + frida-server）、宿主 entitlements、安装与卸载脚本（由面板通过 sudo 调用） |
| `frida/fetch-devkit.sh` | 下载 frida-core devkit 17.25.0（约 200 MB，不进仓库） |
| `probe/`、`tweak/` | 早期探针，诊断用 |

## 安装（普通用户，一个 IPA）

1. 设备需要越狱（Dopamine / roothide），frida-server 必须以 root 运行。
2. 用 TrollStore 或 SideStore 安装 `UURemotePanel.ipa`（构建产物在 `ios/app/build/`）。
   IPA 里已经带了宿主服务：`uuremote-server`、同版本的 `frida-server` 与 `frida-agent.dylib`、两个 LaunchDaemon 配置和安装脚本。
   Frida agent 安装到 `<越狱根>/usr/lib/frida-1.0/frida-agent.dylib`，并提供 `<越狱根>/usr/lib/frida-agent.dylib` 兼容路径（在 iPhone X 的 Frida 17.25 环境中实测需要后者）。缺失时服务仍可能启动、枚举进程，却无法附加；服务诊断分别显示 `frida-agent present=yes/no` 和 `frida-agent-direct present=yes/no`。兼容路径已有不同文件时安装会停止，不覆盖可能由其他工具使用的文件。
3. 首次打开「UU 远程」面板，会看到「安装宿主服务」卡片：输入设备密码（Dopamine 默认 `123`），点「安装」。
   面板通过 sudo 调用随包的 `install-service.sh`，把服务装进系统并启动。越狱根目录自动识别：
   Dopamine 用 `/var/jb`，roothide 用 `/var/containers/Bundle/Application/.jbroot-*`（启动项里写入实际路径）。
4. 装好后卡片消失，状态变成「等待扫码登录」，用手机上的「网易UU远程」扫码即可。

也可以从 Sileo / Zebra 源安装（rootless `iphoneos-arm64`，包名 `com.uuremote.ipad`）：

```
https://bestk.github.io/uu-remote-ipad/
```

源里的包内容与 IPA 相同，由 `.github/workflows/ipad-release.yml` 在打 `ipad-v*` 标签时构建并发布到 GitHub Pages；
`postinst` 调用随包的 `install-service.sh`，`prerm` 调用 `uninstall-service.sh`，与面板的安装按钮走同一条路径。

面板里的「账号」卡片可以退出登录。面板等待后台确认退出后，自动在「连接」页显示新的登录二维码，
用手机上的「网易UU远程」扫码并确认即可重新登录；「账号」卡片此时改为「扫码登录」，点击回到二维码。
等待扫码或手机确认期间，以及二维码加载失败或失效时，均可点「刷新二维码」，无需 SSH、重装服务或重新打开 App。
退出或刷新期间不显示旧二维码；登录完成后隐藏并清理二维码。
iPad 的扫码状态长轮询在 60 秒超时后继续查询同一个二维码；有效期以服务器返回的状态为准，不把请求超时视为二维码过期。服务器确认过期时面板提示刷新，生成新码后独立查询新票据。
二维码只以 `mobile` 所有、`0600` 权限原子写入，root 宿主不再生成面板读不到的二维码。

## 卸载宿主服务

在「安全 → 宿主服务」点击「卸载宿主服务」，确认并输入设备 sudo 密码（留空使用默认 `123`）。
当前远程连接会断开；安装和卸载不能同时执行。服务已离线时也可以卸载，失败或超时后可重试。

- 停止 `com.uuremote.host` 和 `com.uuremote.frida`，确认启动项已卸载后再删除两个 LaunchDaemon 配置与宿主程序。
- 清理运行状态、登录二维码、解锁结果与待执行命令，避免面板误报在线或重新安装后执行旧命令。
- 保留登录凭据、自动解锁密码、设置、连接记录与日志；不删除面板 App，也不解绑云端设备。
- 保留可能被其他工具共用的 `frida-server` 程序，不操作其他 Frida 启动项。
- 再次使用时回到「连接」页重新安装服务，无需重新安装 IPA。

也可在 iPad 上以 root 执行：`sh ios/install/uninstall-service.sh`。

## 构建（Mac）

```sh
ios/frida/fetch-devkit.sh
# frida-server 取自 Frida 官方 iphoneos-arm64 包（按 SHA-256 校验，不进仓库）
ios/frida/fetch-server.sh
# Homebrew 的 cargo 没有 iOS std，用 rustup 工具链
export PATH="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$PATH"
IPHONEOS_DEPLOYMENT_TARGET=16.0 SDKROOT=$(xcrun --sdk iphoneos --show-sdk-path) UU_NO_GTK=1 \
  cargo build --release --target aarch64-apple-ios --bin uuremote-server
ios/app/build.sh   # 面板 App + 带服务的 IPA（约 43 MB，含 frida-agent.dylib）
```

面板界面的隔离检查（Apple Silicon Mac，Xcode）：

```sh
python3 "ios/app/tests/prepare-native-check.py" --run
python3 "ios/app/tests/prepare-native-check.py" --language en --run
python3 -I ios/app/tests/test-uninstall-service.py
python3 -I ios/app/tests/test-install-agent.py
python3 -I ios/app/tests/test-clear-log.py
# 已生成图标的 IPA：检查 iPhone / iPad 声明、图标及其像素尺寸
python3 -I ios/app/tests/test-panel-package.py ios/app/build/UURemotePanel.ipa
```

先以 iOS 15 arm64 编译链接，再使用同一视图的 UIKit/Mac Catalyst 检查程序验证状态、控件与布局。
每个检查进程限时 60 秒，数据全部来自临时目录，不读取真实账号或密码；安装与卸载进程替换为合成结果，不执行提权。
中英各 227 项断言，涵盖心跳新鲜度与 rootfs 备用视图、退出等待、App 内重新扫码与刷新、不同视图的旧二维码隔离、登录/退出失败与超时、状态不可用时的安装和版本提示，以及卸载确认、忙碌互斥、成功/失败/超时与重新安装、Frida 组件冲突提示、日志 UTC 提示、日志查看与清除、滚动条拖动与辅助功能翻页；结果和合成数据截图在 `.impeccable/review/`，不进入发布包。
服务脚本另有隔离测试：11 项覆盖卸载、安装和重启；7 项覆盖 Frida agent 双路径、重装更新、其他工具已有文件保护与诊断；6 项覆盖清除日志。测试使用临时目录和模拟命令，不操作真实服务。
大字号仅覆盖环境类别，不能证明字体放大。
iPad 的真实字号缩放、安全区、键盘、触摸、VoiceOver 与动态效果仍需模拟器或实机验收。

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
