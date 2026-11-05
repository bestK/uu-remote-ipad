# iPad ipad-v0.2.1

新增 Sileo / Zebra 源，可以直接在包管理器里安装和升级，不必再手动装 IPA。

在 Sileo 或 Zebra 中添加：

```
https://bestk.github.io/uu-remote-ipad/
```

- 源里的包 `com.uuremote.ipad` 与 IPA 内容一致：面板、宿主、`frida-server` 与 agent、远控状态栏提示。
- 安装后首次打开「UU 远程」面板即可安装宿主服务；卸载包会一并停止并移除服务。
- 其余功能与 ipad-v0.2.0 相同：远控时状态栏显示红色呼吸圆点（刘海机型）或文字胶囊，iPhone 与 iPad 均可安装。

仍然可以继续用 IPA 安装：`UURemotePanel-ipad-v0.2.1.ipa`。

- 悬浮提示使用未公开的系统接口，系统升级后可能失效。
- 源使用 GitHub Pages 托管，包为 rootless（`iphoneos-arm64`，`/var/jb`）。
- 非官方项目，与网易无关。

Adds a Sileo / Zebra source so the package can be installed and upgraded from a package manager.
Add `https://bestk.github.io/uu-remote-ipad/` in Sileo or Zebra; the package `com.uuremote.ipad` carries the same panel, host, Frida server and agent, and status-bar indicator as the IPA.
The IPA is still published for manual installs. Rootless `iphoneos-arm64` package served from GitHub Pages. The indicator relies on undocumented system interfaces and may break on a future iOS release. Unofficial project, not affiliated with NetEase.
