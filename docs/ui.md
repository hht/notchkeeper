# 界面：亮暗、多语言、面板布局

本文定界面里横切的规则。盾盾的造型与动效见 `docs/mascot.md`，守卫怎么画见 `docs/egress-guard.md`。

## 亮色与暗色（用户 10-29）

**贴着刘海的部分永远是黑底白字**：收起的耳朵、展开面板、完成卡、介入卡、红卡、恢复卡。没有刘海的外接屏上也照样画黑块。只有设置窗口跟随系统的亮暗。

- 依据：HIG Live Activities 的「Choosing colors」一节写，"Live Activities in the Dynamic Island use a black opaque background"，而且灵动岛的背景色不能自定义（<https://developer.apple.com/design/human-interface-guidelines/live-activities>）。boring.notch、NotchDrop、DynamicNotchKit、Atoll 四个开源刘海 App 也都把贴刘海的面板写死成黑底。
- 刘海窗口设窗口级 `appearance = NSAppearance(named: .darkAqua)`，照 boring.notch 的 `BoringNotchSkyLightWindow`。光写死黑底白字不够：面板里的系统控件、`.primary` / `.secondary`、SF Symbols 分层色、tooltip 会跟着窗口的外观走（<https://developer.apple.com/documentation/appkit/nsappearancecustomization/appearance>）。
- 设置窗口不设外观，也不用 `preferredColorScheme`，直接跟随系统。不设 `NSApp.appearance`：Apple 说只在设计必需时才改整个 App 的外观（<https://developer.apple.com/documentation/appkit/choosing-a-specific-appearance-for-your-macos-app>）。
- 黑面板和卡片用黑色阴影。展开面板的边缘是一条很淡的白线（不透明度 0.08）；卡片边缘是表达倒计时的流星，常驻红卡和减弱动态效果时换成一条很淡的同色细边（照灵动岛的 `keylineTint`），见「卡片」。
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
  - **状态只用指示，不写字**（用户 10-29）：工作中是右耳那套三蓝点，依次亮；等你回答、等你批准用盾盾这两个造型自己的装饰（带 ? 的气泡、举起的手），带它们的循环动作（`docs/mascot.md` §4、§5）；已停止不画，标志和路径变暗（时间不跟着暗，保住对比度）。行不垫底色（用户 10-29）。不用绿色（绿色只表示出口正常）。状态名留给悬停提示和旁白。
- **列表最多露出 5 行**（用户 10-29：开的会话多了面板不能无限变长）：不到 5 个按内容高度，超过 5 个列表区固定 5 行高，里面滚动。
- **小字的对比度**：时间、底栏、空列表提示都是白色不透明度 0.5，在黑底和会话容器上都不低于 4.5:1（HIG Accessibility：≤17pt 的字至少 4.5:1；原来的 0.4 约 3.7:1）。
- **时间**（用户 10-29）：统一显示「状态变化距今多久」，用系统的相对时间格式（`Date.RelativeFormatStyle`），中英文自动跟着语言走。不再一个地方显示时长、另一个地方显示距今。

## 卡片（用户 10-29）

刘海上一次只放一张卡，由 `NotchCore` 的 `CardQueue` 决定放哪张、放多久、放出来时响不响。卡分两层：

- **红卡**：违规挂着时的底层卡（挂不挂只看当前状态和 `dismissedViolationSince`，`docs/egress-guard.md`）。设置「红卡一直保留，直到恢复」关掉时，红卡放满一次「卡片停留」就自动收起，算你关掉了这一次。
- **临时卡**：完成卡（回合结束，`Glass`）、介入卡（进入需要你介入，`Ping`）、恢复卡（`Glass`）。按「卡片停留」设置倒计时（默认 6 秒，2–10 秒），恢复卡固定 4 秒；鼠标停在卡上暂停。到时收起，红卡还挂着就回到红卡。

- **尺寸**（用户 10-30）：黑底和面板一样宽 408，两张卡、卡和面板之间切换，形状只变高度（HIG Live Activities：展开态之间元素保持相对位置）。卡片内容的左右边距（18）还和面板（28）不一样，盾盾互切时会横移 6pt，待定（`HANDOFF.md`）。

规则：

1. **一个队列**：所有临时卡进同一个先进先出队列，一次放一张。理由：一个设置管所有临时卡；两个会话同时结束，也不会一张顶掉另一张。
2. **同一个会话只留最新**：队列里还没放的、同一个会话的旧卡，被它后来的卡原地替换（例如还没轮到介入卡就已经回合结束，只放完成卡）。恢复卡同理，同时只排一张。理由：只有最新状态有用，队列不会无限变长。
   - **介入卡过期就撤**（agent 推荐，用户 10-29 同意）：介入卡说的是「此刻在等你」。这个会话一不再需要你介入，它的介入卡不论排着还是正在放都撤掉：回到工作中（你批准了）、进程没了、空闲时弹出的对话框关掉了，直接撤；回合里变成已停止（你拒绝了），回合结束的完成卡马上顶替它。完成卡、恢复卡说的是已经发生的事，不撤。
3. **声音跟着卡响**：卡放出来那一刻才响，不在事件到达时响；被打断后重放的卡不再响。理由：`Basso`、`Glass`、`Ping` 永远不叠，听到的和看到的一一对应。
4. **违规开始插到最前**：新违规开始（红卡 + `Basso`）时，正在放的临时卡回到队首；红卡先完整放一次「卡片停留」，再接着放队列。理由：违规刚发生的那一刻最要紧，被打断的提醒也不丢。
5. **之后盖在红卡上**：红卡放过第一次之后，新来的临时卡直接盖在红卡上，放完回到红卡。
6. **介入卡也自动收回**（用户 10-29）：不常驻。之后还在等你，靠收起态的盾盾造型（question / approval）和右耳的点提示。
7. **盾盾**：卡片上的盾盾就是左耳（或面板左上）那只，跟着形状的弹簧飞到卡片左侧，到了换成这张卡自己的造型：完成卡和恢复卡 finished，介入卡 question / approval，红卡 danger（带告示 !!）。卡收起时飞回左耳，造型回到收起态的优先级（`docs/mascot.md` §2、§5）。用户 10-29：卡片的盾盾也要从原来的位置缓动过来。
8. **看不见就不放**（agent 推荐，用户 10-29 同意；CLAUDE.md「看不见就不调度」）：熄屏或锁屏时，台面上的卡停住倒计时，新来的临时卡排着不放、不响，亮屏解锁后接着放。新违规照样把红卡挂上台面（状态要对），但 `Basso` 等回来再响；离开期间已经恢复的，回来不补响。理由：离开电脑时来的卡挨个放完、挨个响，回来什么都看不到。

- **边缘的流星就是倒计时**（用户 10-29 定稿）：两颗流星从顶部左右两端沿边匀速流到底边中间，位置始终对应剩余时间：卡片弹出那一刻倒计时开始，流星在约 0.35 秒后（形状快长好、圆角对得上时）淡入，汇合的那一刻卡片收起。只走一趟，不循环。没有进度条，也没有底轨。
  - 流星的形状：清晰的实体头（直径约 4.4pt 的亮核，往后 16pt 收成水滴，前白后卡片色），外面一层淡光团，后面一条 200pt 长、越往后越淡的 1.5pt 细尾巴，只在靠近头的 80pt 有一层模糊柔光。流星压在卡片边缘正中，光往里外两边晕开；拐弯时贴着圆弧走。
  - 悬停、熄屏锁屏时卡片停住，流星停在原处；卡片一开始收起，流星立刻撤掉，不淡出。
  - 常驻红卡没有倒计时、或开了减弱动态效果：不画流星，只画一条很淡的同色细边。
  - 做法照 Magic UI 的 Border Beam（渐变色块沿边跑、只露边框一圈），全部交给 Core Animation（`CardEdge.swift`）。<https://magicui.design/docs/components/border-beam>
  - 中间试过、用户否掉的：底部进度条（加流光也不行）、沿边整圈亮边往中间退、Apple Intelligence 式彩色泛光、循环播放的流光、只有光晕没有实体头的流星。
- **颜色**（流星和细边）：完成卡低饱和银白，介入卡等你回答青 / 等你批准青柠，恢复卡绿，红卡红。绿色只给出口正常；Claude 橙在黑底上晕开发红，不用。卡片外圈阴影一律黑色。
- **文案**：标题说谁怎么了（「Claude Code 做完了」「Claude Code 在等你回答」「Claude Code 在等你批准」），副标题是会话的路径（同会话行，`~` 缩写）。
- 依据：HIG Live Activities，提醒「light up the screen and by default play the notification sound」，多个活动时常驻的那个不被挤掉（<https://developer.apple.com/design/human-interface-guidelines/live-activities>）；仓里原有的「常驻红卡 + 临时卡插在上面、放完回到红卡」。

## 截图

改了界面要附截图：

- 刘海机型亮、暗各一张。贴刘海的部分在两张里都应该是黑的，用来确认没有被亮色带偏。
- 改了文案的，中、英各一张。
- 有外接屏时，再补一张无刘海外接屏的。
