# iPad ipad-v0.2.0

被远控时，状态栏会出现提示；同一个 IPA 现在也能装在 iPhone 上。

- **远控提示**：有远程桌面连接时，状态栏时间右侧出现红色呼吸圆点（刘海机型，避开刘海）或「UU 远控中」文字胶囊（iPad 与非刘海机型）；最后一个连接结束自动消失。开启「减弱动态效果」时改为静态显示。
- **iPhone 支持**：面板声明 iPhone 与 iPad 两种设备族，分别带主屏图标。
- **面板状态更准确**：宿主状态读不到时改为「状态不可用」，不再断言「未安装 / 服务离线」；有启动项但心跳陈旧时也不再显示安装卡。
- **日志时间统一 UTC**：日志页标明末尾 `Z` 表示 UTC，导出标题同样使用 UTC。
- **宿主状态更可靠**：状态文件改为加锁原子替换，带实例标识和递增版本号，并发心跳不会覆盖正在进行的会话计数。
- **服务脚本**：支持 roothide 路径、Frida agent 双路径，并能升级旧版本安装留下的 agent 对（其他工具安装的文件仍然不覆盖）。
- 悬浮提示随服务一起安装和卸载；它安装失败只提示，不影响远控。

安装：用 TrollStore 或 SideStore 安装 `UURemotePanel-ipad-v0.2.0.ipa`，打开主屏「UU 远程」，输入设备密码安装服务，
再用手机「网易UU远程」扫码。说明见 [ios/README.md](https://github.com/bestK/uu-remote-ipad/blob/main/ios/README.md)。

- IPA 内的 `frida-server` 与 `frida-agent.dylib` 取自 Frida 官方 17.25.0 `iphoneos-arm64` 包，脚本按 SHA-256 校验。
- 悬浮提示使用未公开的系统接口，在 iPhone X / iOS 16.7.15（roothide）与 iPad 上验证；系统升级后可能失效。
- 本包不带图标（不含网易素材）。
- 非官方项目，与网易无关。

A status-bar indicator appears while a viewer is connected — a pulsing red dot on notched phones (clear of the notch) or a text pill elsewhere — and the same IPA now installs on an iPhone.
The panel reports "status unavailable" instead of guessing, log times are UTC, and the host publishes its status file atomically with a revision so a concurrent heartbeat cannot hide a live session.
The indicator is a separate process using undocumented system interfaces; it was verified on iPhone X / iOS 16.7.15 (roothide) and on iPad, and may break on a future iOS release.
`frida-server` and its agent come from Frida's official 17.25.0 iphoneos-arm64 package (SHA-256 pinned). No icon is bundled. Built from source by GitHub Actions.
