# 界面：亮暗、多语言、面板布局

本文定界面里横切的规则。盾盾的造型与动效见 `docs/mascot.md`，守卫怎么画见 `docs/egress-guard.md`。

## 亮色与暗色（用户 10-29）

**贴着刘海的部分永远是黑底白字**：收起的耳朵、展开面板、完成卡、介入卡、红卡、恢复卡。没有刘海的外接屏上也照样画黑块。只有设置窗口跟随系统的亮暗。

- 依据：HIG Live Activities 的「Choosing colors」一节写，"Live Activities in the Dynamic Island use a black opaque background"，而且灵动岛的背景色不能自定义（<https://developer.apple.com/design/human-interface-guidelines/live-activities>）。boring.notch、NotchDrop、DynamicNotchKit、Atoll 四个开源刘海 App 也都把贴刘海的面板写死成黑底。
- 刘海窗口设窗口级 `appearance = NSAppearance(named: .darkAqua)`，照 boring.notch 的 `BoringNotchSkyLightWindow`。光写死黑底白字不够：面板里的系统控件、`.primary` / `.secondary`、SF Symbols 分层色、tooltip 会跟着窗口的外观走（<https://developer.apple.com/documentation/appkit/nsappearancecustomization/appearance>）。
- 设置窗口不设外观，也不用 `preferredColorScheme`，直接跟随系统。不设 `NSApp.appearance`：Apple 说只在设计必需时才改整个 App 的外观（<https://developer.apple.com/documentation/appkit/choosing-a-specific-appearance-for-your-macos-app>）。
- 不加 key line：黑面板和卡片只用阴影，不加描边。
- **设置页里的盾盾放在黑底圆角「舞台」上**。盾盾的配色是按黑底设计的：亮色下身体顶色对白底只有约 1.2:1，睡着的 Z 只有 1.7:1，几乎看不见。用舞台的话，造型数据不用分亮暗。
- 设置页的状态点（`GuardDot`）是表达信息的图形，在亮、暗两种底上都要满足 3:1（WCAG 1.4.11，<https://www.w3.org/WAI/WCAG22/Understanding/non-text-contrast.html>）。

## 多语言（用户 10-29）

- **语言**：简体中文（源语言）和 English。系统按用户的语言列表找第一个支持的语言，一个都没有时用简体中文。
- **默认随系统语言**。要改的话，在系统设置里按 App 单独设，App 不自己切。设置页放一个「在系统设置中更改语言…」按钮，跳到系统设置的对应位置。依据：WWDC19 Session 403 原话 "do not attempt to set the application language manually in code"，并说 macOS 用户在「语言与地区」里给单个 App 设语言（<https://developer.apple.com/videos/play/wwdc2019/403/>）；Apple DTS 也说 `AppleLanguages` "is an implementation detail, not something that's considered API"（<https://developer.apple.com/forums/thread/718512>）。
- **文案的写法**：
  - 用一个 String Catalog `Localizable.xcstrings`，键就是中文原文，例如 `Text("重新检测")`。
  - 代码用默认的 `Bundle.main`，不写 `bundle: .module`。
  - 卡片标题这类先存成 `String` 再显示的文案，`Text(someString)` 不会本地化（<https://developer.apple.com/documentation/swiftui/text/init(_:tablename:bundle:comment:)>）。这类属性改用 `LocalizedStringResource`。
- **构建**：默认的 `swift build` 不编译 `.xcstrings`，只会原样拷贝（实测 Swift 6.3.3）。所以 catalog 不进 SwiftPM 资源，改由 `scripts/run.sh` 用 `xcrun xcstringstool compile` 编进 `Notchkeeper.app/Contents/Resources/<语言>.lproj`。这一步依赖 Xcode 自带的工具，用户 10-29 已同意。
- **Info.plist**：写 `CFBundleDevelopmentRegion = zh-Hans` 和 `CFBundleLocalizations = [zh-Hans, en]`，不写 `CFBundleAllowMixedLocalizations`（实测它在日文环境下判成 en，却显示中文）。
- **范围**：
  - 要翻译：界面文案、卡片、设置页、声音的说明文字。
  - 不翻译：出口 IP 和项目名。
  - 仍是中文：日志、文档、注释、提交说明（CLAUDE.md「汇报」）。
- **测试**：在 `swift test` 里解析 `Localizable.xcstrings` 的 JSON，要求每个键的 en 译文都是 `state == "translated"`，并且没有 `extractionState == "stale"` 的键。写法参考 bitchat 的 `LocalizationCoverageTests`。
- **第 4 步实机验证**：
  - 系统设置的「按 App 设语言」列表里能不能看到 Notchkeeper，选了以后能不能生效。
  - 跳转按钮用的 URL。
  - 中、英各截一张图。

## 面板布局

展开面板照一套网格排（用户 10-29 看过实机截图定稿，代码在 `Notch.swift` 的 `NotchLayout`、`NotchRoot.corners`、`NotchDashboard`）：

- **版式**（照 HIG Live Activities 的展开态：元素和收起态相对位置不变）：左上是盾盾（左耳那只放大），右上是出口状态徽章（右耳的位置），刘海正下方居中是出口标题和 IP，中间是会话列表，底栏左边是「出口检查于…」、右边是齿轮。
- **尺寸**：黑底宽 408（灵动岛展开态宽），四周边距 14；会话容器圆角 14、四周留 4，面板底角 28。盾盾和徽章都是 32pt（和标题 + IP 两行一样高；用户 10-29 嫌 40pt 偏大），上缘离面板顶 8。
- **左对齐线**：盾盾按**身体圆**对齐，身体中心和会话图标中心在同一条竖线上；底栏文字左缘和会话图标左缘对齐。
- **右对齐线**：徽章右缘、齿轮图形右缘、时间列右缘对齐。时间列固定宽 66；状态指示固定在时间列左边。
- **盾盾的位置**：盾盾在刘海左侧，紧贴刘海、不留「额头」；面板里的盾盾不带告示（`docs/mascot.md` §2）。
- **删掉右上角的「进程 claude 0」**（用户 10-29；已删）。
- **会话列表**：每行是 agent 标志 + 路径 + 状态指示 + 时间。只列 AgentCore 看着的会话（活着的终端 `claude`，`docs/agent-integration.md`），按进程启动先后排，状态变了行不挪位置。
  - **agent 标志**：是哪个 agent 只靠行首的标志表示，不另写一行字，悬停显示名字。标志用 agent 厂商自己的（用户 10-29）：Claude Code 用 Claude 的星芒，路径和颜色 `#D97757` 照抄 Wikimedia Commons 的「Claude AI symbol.svg」（`ClaudeMark.swift`）。依据 CLAUDE.md「品牌」（用户 10-29 改）。
  - **路径**（用户 10-29）：显示 `cwd` 的完整路径，家目录写成 `~`；太长就从前面截成「…」，留住最后几段。悬停显示完整路径。不显示会话名（`docs/agent-integration.md`「不取 `name`」）。
  - **状态只用指示，不写字**（用户 10-29）：工作中是右耳那套三蓝点，依次亮；等你回答、等你批准用盾盾这两个造型自己的装饰（带 ? 的气泡、举起的手），带它们的循环动作（`docs/mascot.md` §4、§5）；已停止不画，整行变暗。行不垫底色（用户 10-29）。不用绿色（绿色只表示出口正常）。状态名留给悬停提示和旁白。
- **列表最多露出 5 行**（用户 10-29：开的会话多了面板不能无限变长）：不到 5 个按内容高度，超过 5 个列表区固定 5 行高，里面滚动。
- **时间**（用户 10-29）：统一显示「状态变化距今多久」，用系统的相对时间格式（`Date.RelativeFormatStyle`），中英文自动跟着语言走。不再一个地方显示时长、另一个地方显示距今。

## 截图

改了界面要附截图：

- 刘海机型亮、暗各一张。贴刘海的部分在两张里都应该是黑的，用来确认没有被亮色带偏。
- 改了文案的，中、英各一张。
- 有外接屏时，再补一张无刘海外接屏的。
