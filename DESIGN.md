---
name: UU 远程 iPad 面板
description: 28pt 大圆角卡片与底部悬浮胶囊切换栏：浅色青柠胶囊、深色电光蓝星芒主卡、零说明文案
colors:
  surface-light: "#ECECE7"
  surface-dark: "#0A0A0D"
  card-light: "#FFFFFF"
  card-dark: "#18181C"
  hero-dark-online: "#1D74F5"
  hero-dark-waiting: "#1D61D1"
  hero-dark-offline: "#202127"
  badge-lime: "#D6FF00"
  badge-amber: "#FFE14D"
  badge-offline: "#E5E6E1"
  action-dark-ink: "#0C0C0E"
  field-light: "#F3F3F0"
  field-dark: "#24242A"
  danger-fill-dark: "#391D1F"
  danger-text-dark: "#FF5A4F"
  white: "#FFFFFF"
typography:
  display:
    fontFamily: "system-ui"
    fontWeight: 800
  title:
    fontFamily: "system-ui"
    fontWeight: 700
  body:
    fontFamily: "system-ui"
    fontWeight: 400
  mono:
    fontFamily: "ui-monospace"
    fontWeight: 500
rounded:
  card: "28pt"
  bar: "30pt"
  bar-pill: "24pt"
  button: "25pt"
  field: "22pt"
  pill-secondary: "21pt"
  qr: "18pt"
  badge: "16pt"
  keycap: "10pt"
spacing:
  row: "48pt"
  card-padding: "24pt"
  card-gap: "18pt"
  page-side: "20pt"
  bottom-safe: "104pt"
components:
  hero-card-light:
    backgroundColor: "{colors.card-light}"
    textColor: "{colors.action-dark-ink}"
    rounded: "{rounded.card}"
    padding: "{spacing.card-padding}"
  hero-card-dark:
    backgroundColor: "{colors.hero-dark-online}"
    textColor: "{colors.white}"
    rounded: "{rounded.card}"
    padding: "{spacing.card-padding}"
  status-badge-online:
    backgroundColor: "{colors.badge-lime}"
    textColor: "{colors.action-dark-ink}"
    rounded: "{rounded.badge}"
    padding: "7pt 14pt"
  button-primary-light:
    backgroundColor: "{colors.action-dark-ink}"
    textColor: "{colors.white}"
    rounded: "{rounded.button}"
    padding: "13pt 24pt"
  button-primary-dark:
    backgroundColor: "{colors.hero-dark-online}"
    textColor: "{colors.white}"
    rounded: "{rounded.button}"
    padding: "13pt 24pt"
  input-field:
    backgroundColor: "{colors.field-light}"
    textColor: "{colors.action-dark-ink}"
    rounded: "{rounded.field}"
    height: "52pt"
---

# Design System: UU 远程 iPad 面板

## Overview

**Creative North Star: "高对比胶囊仪表卡"**

这块面板服务于一台常驻待机的越狱 iPad，打开即回答“现在能不能连上它”。界面彻底摒弃旧版贴边墨蓝通栏状态板、默认系统顶栏和带灰框的输入框，改用统一的 28pt 连续大圆角卡片与底部居中悬浮胶囊导航栏。

浅色与深色模式各具鲜明性格：浅色在暖石灰底面（`#ECECE7`）上陈列纯白大圆角卡片，以荧光青柠色（`#D6FF00`）状态胶囊与纯黑（`#0C0C0E`）胶囊主按钮建立视觉焦点；深色在纯碳黑底面（`#0A0A0D`）上以电光蓝（`#1D74F5`）状态主卡配右侧 8 轴几何星芒暗纹领衔，其余卡片采用深石墨灰（`#18181C`）与暗红胶囊退出按钮。全界面严格执行自解释 UI 原则，移除全部解释性段落。

本文记录已实现的 UIKit 视觉体系；生产事实以 `ios/app/main.m` 为准。

**Key Characteristics:**
- 大圆角卡片矩阵：所有区块统一采用 28pt 连续圆角卡片（内边距 24pt），首屏直接由状态主卡开篇，无顶部冗余导航栏。
- 双模式高对比语义：浅色用荧光青柠胶囊点亮纯白主卡，深色用电光蓝主卡配几何星芒暗纹与半透明白胶囊。
- 全胶囊交互控件：输入框（22pt 圆角无边框填充）、主操作按钮（全胶囊填充）、次要/危险按钮（胶囊填充）与底部三栏切换器均采用胶囊形态。
- 自解释 UI 纪律：禁绝说明段落、辅助提示文案与气泡，仅保留简短标签、动词按钮、单位与单行状态/错误。

## Colors

### Primary
- **纯黑行动墨色 `action-dark-ink`** (`#0C0C0E`)：浅色模式下的主按钮底色、底部悬浮栏激活胶囊、账号头像底色与状态胶囊文字。
- **电光蓝 `hero-dark-online`** (`#1D74F5`)：深色模式下的在线/远控状态主卡底色、主按钮底色、底部悬浮栏激活胶囊与账号头像底色。
- **荧光青柠 `badge-lime`** (`#D6FF00`)：浅色模式下在线与远控状态的顶部状态胶囊及左下角 44pt 圆形状态徽章底色。

### Secondary
- **待扫码信号黄 `badge-amber`** (`#FFE14D`)：浅色模式下等待扫码状态的胶囊与圆形徽章底色；深色模式待扫码主卡切换为深钴蓝（`#1D61D1`）。
- **暗红退出胶囊 `danger-fill-dark` / `danger-text-dark`** (`#391D1F` / `#FF5A4F`)：深色模式下「退出登录」与「清除」胶囊按钮的底色与文字色。

### Neutral
- **页面底色 `surface-light` / `surface-dark`** (`#ECECE7` / `#0A0A0D`)：浅色为温润暖石灰，深色为纯碳黑。
- **卡片表面 `card-light` / `card-dark`** (`#FFFFFF` / `#18181C`)：承载所有功能分组与底部悬浮导航外框。
- **无边框输入槽与键帽底色 `field-light` / `field-dark`** (`#F3F3F0` / `#24242A`)：用于密码输入框、浅色次要胶囊按钮、自动解锁状态胶囊、锁屏图标圆底与快捷键键帽。
- **二维码白底 `white`** (`#FFFFFF`)：无论浅色或深色模式，二维码始终保持纯白底色静区。

## Typography

使用 UIKit 系统动态字体（SF Pro）与等宽系统字体（SF Mono），通过 `PanelLabel` 与 `UIFontMetrics` 随窗口环境缩放：
- **Display (`LargeTitle` + `Heavy`)**：状态主卡核心状态词（已上线 / 正在远控 / 等待扫码 / 服务未运行）。
- **Title (`Title3` + `Bold`)**：各卡片标题（安装服务、连接记录、自动解锁、远程快捷键）。
- **Headline (`Headline` + `Bold`)**：账号状态值、连接记录时间戳、锁屏开关行标题。
- **Body (`Body` + `Regular` / `Bold`)**：状态副行、快捷键动作名、胶囊主按钮与输入框文本。
- **Label (`Subheadline` / `Footnote` / `Caption1` + `Bold` / `Heavy`)**：设备名眉标、状态胶囊文字、键帽文字與底部悬浮栏标签。
- **Mono (`Footnote` + `Monospaced Medium`)**：服务安装输出行（`$ status: ...`）。

## Layout

三项标签页（连接、安全、快捷键）由底部居中的悬浮胶囊栏切换，隐藏系统顶部导航栏与原生底部标签栏。
页面内容垂直滚动，所有卡片（含状态主卡）通过 `insetSection:` 居中排布，最大宽度 680pt，左右至少留白 20pt；卡片间距 18pt，顶部留白 20pt，底部留白 104pt 以避让悬浮胶囊栏。

```
┌──────────────────────────────────────┐
│  ┌────────────────────────────────┐  │
│  │ IPAD                  [在线就绪] │  │  28pt 状态主卡（≤680pt）
│  │ 已上线                    ✳    │  │  深色带 8 轴几何星芒暗纹
│  │ 等待连接                        │  │
│  │ (→) 最近连接 / 暂无连接记录      │  │
│  └────────────────────────────────┘  │
│  ┌────────────────────────────────┐  │
│  │ (●) 账号 / 已登录     [退出登录] │  │  28pt 账号卡
│  └────────────────────────────────┘  │
│  ┌────────────────────────────────┐  │
│  │ 连接记录                        │  │  28pt 连接记录卡
│  │ 今天 15:02 / 12 分钟          › │  │
│  └────────────────────────────────┘  │
│         ╭──────────────────╮         │
│         │ (连接) 安全 快捷键 │         │  底部居中悬浮胶囊栏
│         ╰──────────────────╯         │
└──────────────────────────────────────┘
```

## Elevation & Depth

界面主要依靠暖石灰/纯白（浅色）与纯碳黑/石墨灰/电光蓝（深色）的色阶对比建立层级。仅底部悬浮胶囊栏使用柔和环境阴影（`opacity: 0.08, radius: 20pt, offset: 0 6pt`）与 1px 细边与滚动内容分离。

## Shapes

- **卡片**：统一 `28pt` 连续圆角（`kCACornerCurveContinuous`）。
- **悬浮底栏**：外框 `30pt` 连续圆角，内部三枚切换胶囊 `24pt` 连续圆角（高度 ≥48pt）。
- **按钮与输入框**：主按钮采用系统全胶囊（`UIButtonConfigurationCornerStyleCapsule`，高度 ≥50pt），次要按钮 `21pt` 胶囊（高度 ≥44pt），密码输入框 `22pt` 连续圆角无边框（高度 ≥52pt）。
- **圆形徽章**：状态主卡左下角徽章与锁屏图标徽章为 `44×44pt` 正圆（`22pt` 圆角），账号头像为 `48×48pt` 正圆（`24pt` 圆角）。
- **二维码与键帽**：二维码 `200×200pt`、`18pt` 连续圆角；键帽与手势标签 `10pt` 连续圆角。

## Components

- **状态主卡**：顶部左列大写设备名、右列状态胶囊（`在线就绪` / `实时连接` / `扫码登录` / `服务离线`）；中部为 Heavy 大字状态词与副行；深色模式右侧绘制 8 轴几何星芒（`HeroAsteriskView`）；待扫码时居中展开 `200×200pt` 二维码；底部为 44pt 圆形符号徽章与「最近连接」双行摘要。状态变化时整卡做 0.22s 交叉溶解，“正在远控”时圆形徽章缓慢呼吸。
- **安装服务卡**：仅 `HostDown` 或安装刚结束时显示；标题 + 无边框胶囊密码框 + 占满整行的胶囊安装按钮 + 等宽字体 `$ status:` 结果行。
- **账号卡**：48pt 圆形人像徽章 + 「账号 / 已登录」双行文字 + 右侧「退出登录」胶囊按钮（点击弹出二次确认）。
- **自动解锁卡**：顶部左列标题、右列单行状态胶囊（含符号与「已保存 / 未保存 / 已解锁 / 密码被拒，请重存」）；中部为手动遮罩胶囊密码框；底部右对齐「清除」与「保存」胶囊按钮。
- **远程结束后锁屏卡**：44pt 圆形锁标 + 粗体标题 + 右侧开关。
- **远程快捷键卡**：标题 + `Windows / macOS` 分段控件 + 9 项动作与胶囊键帽行 + 细线分隔的 3 项底边手势行。
- **连接记录卡**：最近 5 次连接，左侧为粗体时间与次要时长双行堆叠，右侧为 `chevron.right` 指示符，行高 ≥56pt。
- **底部悬浮胶囊栏**：固定在安全区底部上方 16pt，最大宽度 420pt，点击切换连接、安全、快捷键并自动收起键盘。

## Do's and Don'ts

### Do:
- **Do** 保持所有卡片 28pt 连续圆角与 24pt 内边距，让状态主卡、输入框与按钮共享胶囊家族语言。
- **Do** 严格遵守自解释 UI 原则：只使用短标签、动词按钮、单位与单行状态/错误。
- **Do** 在浅色模式使用荧光青柠状态胶囊配纯黑主按钮，在深色模式使用电光蓝星芒主卡配半透明白徽章与暗红退出胶囊。

### Don't:
- **Don't** 添加任何说明性段落、辅助提示文案、操作指导句子或气泡说明。
- **Don't** 使用贴边无圆角通栏横幅或 `UITextBorderStyleRoundedRect` 旧式带框输入框。
- **Don't** 展示真实密码、令牌、二维码链接或将测试二维码当作发布素材。
