# 灵动岛 / Live Activities 设计调研：对照 Notchkeeper 的刘海界面

调研日期 2026-10-29，子 agent 调研的草稿，结论交用户挑选后再写进 `docs/ui.md` 等正式文档；这里不是已定规则。「Mac 上的系统灵动岛（2026-10-28 发布）」一条已核实：<https://www.macrumors.com/2026/10/28/apple-brings-dynamic-island-to-mac/>。原始资料当时缓存在 `/tmp/nk-research/raw/`（HIG 的 DocC JSON、WWDC 字幕，临时目录、已不保证存在），开源实现源码在 `/tmp/nk-research/src/`（boring.notch `23e7705`，2026-10-18；DynamicNotchKit `cd0b3e5`，2026-02-18）。

标注约定：
- 「原文」：一手资料逐字引用。
- 「推断」：我的推论，没有一手资料直接证实。
- 「查不到」：找过，没有可靠出处。

---

## 0. 先看这几条（结论速览）

1. **Mac 有了系统级灵动岛（2026-10-28 发布），这是本仓最大的变量。** Apple 2026-10-28 发布了 MacBook Pro（PROLED XDR），原文是 "The Dynamic Island now comes to Mac, serving as the home for Spotlight, Live Activities, and Siri AI"。Tech Talk「Bring Live Activities to Mac」也说 Mac App 可以直接创建 Live Activity。在这类机器上，我们画在刘海位置的覆盖层会和系统灵动岛抢同一块地方。Mac 版的尺寸、悬停行为和安全区 API 目前都查不到。建议先定产品策略：新机器上要不要退让、改成什么形态（§1.6）。
2. **形态模型我们基本对上了。** 收起两只耳朵 ≈ compact 的 leading / trailing，面板 ≈ expanded，卡片 ≈ alert 时短暂弹出的 expanded。面板宽 408 正好是 iOS 展开态宽。卡片高 84（32pt 刘海时）正好是展开态高度区间 84–160 的下限。面板底角 28、边距 14、会话容器圆角 14，满足 HIG「内圆角 = 外圆角 − 边距」的同心规则。
3. **灵动岛的 alert 没有看得见的倒计时（推断：文档和 WWDC 都没提任何倒计时指示）。** 系统只是展开一下，过「a couple of seconds」自己收回；具体秒数官方查不到。我们的边缘流光倒计时是灵动岛没有的额外动效，而且会持续 2–10 秒。HIG 的 Live Activity 动画上限是 2 秒，Motion 一章要求「purposeful」。建议交用户在三条路里选一条：减弱、换成静态细边、或者保留（§6）。
4. **keyline 有一手依据，但我们的文档写的是「不加描边」，代码却已经加了。** HIG 原文是 "Tint your Live Activity's key line color so that it matches your content"。代码里面板有白色 0.08 的描边（`Notch.swift:644-647`），常驻红卡有同色细边（`CardEdge.swift:9,128`）。`docs/ui.md` 和 `CLAUDE.md` 却都写「只用阴影，不加描边」。要先改文档、请用户确认（§3、§9）。
5. **字重和对比度有几处不达标。** HIG 原文是 "Use large, heavier-weight text — a medium weight or higher"，对比度要求 ≤17pt 的文字至少 4.5:1。我们的时间列（11pt）、底栏（10.5pt）、空列表提示（12pt）都是白色 0.4 不透明度，按 sRGB 合成算约 3.7:1。已停止的行再乘 0.55，更低。卡片副标题是 12pt regular（§3）。
6. **展开时元素要连续，不要消失再进场。** HIG 原文是 "preserve as much of the existing layout as possible by animating existing elements to their new positions"。盾盾从左耳飞到面板或卡片、右耳变成徽章，我们已经照这条做了。还差两处：卡片宽 400 和面板宽 408 不一致；卡片右侧没有承接右耳的位置，只有一个 ×（§1、§2）。
7. **收起态应当紧贴摄像头、没有空白，左右两侧读起来是同一条信息。** HIG 原文："snug against the TrueDepth camera … don't add padding"，"as narrow as possible with no wasted space"。我们的右耳固定 44pt，空闲时整只是空的黑块，指示也偏向外侧（中心离外缘 17.5）。改动要用户定（§1.3）。
8. **弹簧参数：文档和代码对不上。** `docs/mascot.md` §5 写 ζ 0.85、展开 0.45、收起 0.35；`Common.swift:19-23` 实际是展开 0.5 / 0.7、收起 0.38 / 0.88，弹卡又是 0.4 / 0.8（`Notch.swift:334`）。WWDC23 建议 bounce（≈ 1 − ζ）不要超过约 0.4，拿不准时用 0。我们的展开 bounce 0.3 在范围内，但要统一成一个 owner（§2）。
9. **提醒的策略已经和灵动岛一致。** 一次只展开一个；重要的常驻、不重要的自己消失；声音跟着卡响。灵动岛同样一次只展开一个 Live Activity，只在「essential updates」时提醒，提醒时亮屏加默认通知音。不用改。只有一处不同：我们熄屏时不亮屏、不放卡，这是有意的设计（`docs/ui.md`「卡片」8）。
10. **无障碍还差两处。** 盾盾只有标签「盾盾」，没有状态值（`MascotView.swift:41-42`）；卡片弹出时没有 VoiceOver 播报。Apple 新的 Mac Live Activity 示例里出现了 `alertConfiguration: .announcement("Ready")`，Tech Talk 111467 的示例代码；文档里查不到这个 API，推断它用于播报。AppKit 这边可以用 `NSAccessibility.Notification.announcementRequested`（§8）。

---

## 1. 资料与可信度

| 级别 | 来源 | 用到的内容 |
|---|---|---|
| 一手 | HIG「Live Activities」，Change log 最新是 2026-10-13，经 DocC JSON 取到全文：<https://developer.apple.com/design/human-interface-guidelines/live-activities>（JSON：<https://developer.apple.com/tutorials/data/design/human-interface-guidelines/live-activities.json>） | 形态、边距、同心、颜色、keyline、动画上限 2s、alert、尺寸表 |
| 一手 | HIG 旧版（2025-12-16 版，appguidelines.com 存档）：<https://appguidelines.com/human-interface-guidelines/version/24/live-activities/> | "The Dynamic Island uses a corner radius of 44 points"，各机型岛宽 230 / 250。**现行版已删掉这两句** |
| 一手 | WWDC23 10194「Design dynamic Live Activities」字幕：<https://developer.apple.com/videos/play/wwdc2023/10194/> | 「像有生命的有机体」、同心、模糊法对位、不留额头、多会话轮播、alert 时强调触发原因 |
| 一手 | WWDC23 10184「Meet ActivityKit」：<https://developer.apple.com/videos/play/wwdc2023/10184/> | alert 在 iPhone 上就是展开态加声音；minimal 的选择 |
| 一手 | WWDC26 223「Live Activities essentials」：<https://developer.apple.com/videos/play/wwdc2026/223/> | 展开的两种触发（alert、长按）；iOS 27 横屏受限宽度 |
| 一手 | WWDC25 278「What's new in widgets」：<https://developer.apple.com/videos/play/wwdc2025/278/> | macOS Tahoe 菜单栏里的 Live Activity：选中时弹出锁屏样式，点击启动 iPhone 镜像 |
| 一手 | Tech Talk 111467「Bring Live Activities to Mac」：<https://developer.apple.com/videos/play/tech-talks/111467/> | Mac 原生 Live Activity、Mac 灵动岛；页面只有示例代码，字幕没取到，台词转引自 blakecrosley.com |
| 一手 | Apple Newsroom 2026-10-28：<https://www.apple.com/newsroom/2026/10/apple-unveils-groundbreaking-macbook-pro-with-proled-xdr-display/>；产品页 <https://www.apple.com/ca/macbook-pro/proled-xdr-display/> | Mac 灵动岛的定位；唯一描述的交互是手指点按 |
| 一手 | ActivityKit / WidgetKit 文档：[Displaying live data](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)、[Creating custom views](https://developer.apple.com/documentation/activitykit/creating-custom-views-for-live-activities)、[DynamicIsland](https://developer.apple.com/documentation/widgetkit/dynamicisland)、[DynamicIslandExpandedRegion](https://developer.apple.com/documentation/widgetkit/dynamicislandexpandedregion)、[contentMargins](https://developer.apple.com/documentation/widgetkit/dynamicisland/contentmargins(_:_:for:))、[AlertConfiguration](https://developer.apple.com/documentation/activitykit/alertconfiguration)、[relevanceScore](https://developer.apple.com/documentation/activitykit/activitycontent/relevancescore)、[Animating data updates](https://developer.apple.com/documentation/widgetkit/animating-data-updates-in-widgets-and-live-activities) | 区域划分、边距、keyline、alert、优先级、动画限制 |
| 一手 | SwiftUI：[Text(timerInterval:…)](https://developer.apple.com/documentation/swiftui/text/init(timerinterval:pausetime:countsdown:showshours:))、[ProgressView(timerInterval:…)](https://developer.apple.com/documentation/swiftui/progressview/init(timerinterval:countsdown:label:currentvaluelabel:))、[numericText(countsDown:)](https://developer.apple.com/documentation/swiftui/contenttransition/numerictext(countsdown:))、[ContainerRelativeShape](https://developer.apple.com/documentation/swiftui/containerrelativeshape)、[isLuminanceReduced](https://developer.apple.com/documentation/swiftui/environmentvalues/isluminancereduced) | 倒计时、同心形状 |
| 一手 | WWDC23 10158「Animate with springs」：<https://developer.apple.com/videos/play/wwdc2023/10158/>；WWDC18 803「Designing Fluid Interfaces」：<https://developer.apple.com/videos/play/wwdc2018/803/> | 弹簧参数怎么选 |
| 一手 | HIG [Motion](https://developer.apple.com/design/human-interface-guidelines/motion)、[Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)、[Typography](https://developer.apple.com/design/human-interface-guidelines/typography)、[SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols) | 减弱动态效果、对比度、最小字号 |
| 一手 | Apple 支持文档「View Live Activities in the Dynamic Island on iPhone」：<https://support.apple.com/guide/iphone/view-live-activities-in-the-dynamic-island-iph28f50d10d/ios> | 用户侧手势 |
| 一手（访谈） | Apple Developer「Spotlight on: The Dynamic Island」（2022-10-28，开发者访谈）：<https://developer.apple.com/news/?id=mis6swzt> | 一眼可读、按重要程度决定多坚持 |
| 二手 | boring.notch 源码 <https://github.com/TheBoredTeam/boring.notch>，DynamicNotchKit 源码 <https://github.com/MrKai77/DynamicNotchKit> | macOS 上的弹簧、悬停延迟、尺寸 |
| 二手 | Alcove 官网 <https://tryalcove.com>（只有标语：「Fluid transitions」「Swipe gestures」，没有可核对的数字）；blakecrosley.com 对 Tech Talk 的转述 <https://blakecrosley.com/blog/touch-on-mac-for-developers> | 参考，不作依据 |

Apple 设计团队的公开访谈：Alan Dye 和 Craig Federighi 接受过 Axis Magazine 采访，二手报道见 Notebookcheck；原文没取到，所以本文不引。「像有生命的有机体」这句出自 WWDC23 10194 里 Chan Karunamuni 的讲解，不是访谈。

---

## 2. 我们现在的界面（速写，带出处）

- **收起**：刘海加左右各 44pt 的耳朵，外翻 4，底角 8。
  - 左耳是 20pt 的盾盾（面板里 32pt 那只缩小）；右耳是指示：三蓝点、青点、青柠点、灰色空心环，或告示图标。空闲、完成时右耳没有东西。
  - 出处：`docs/mascot.md` §1、§2；`Notch.swift` 的 `NotchLayout`（`earWidth = 44`，`earDotInset = 17.5`）。
- **面板**：黑底宽 408，四周边距 14，底角 28。
  - 左上是盾盾 32pt，右上是出口徽章 32pt，上缘都离面板顶 8。
  - 刘海正下方是标题（15pt semibold rounded）和 IP（11pt medium mono）。
  - 中间是会话容器（圆角 14、内边距 4、行高 38、最多 5 行）。底栏是「出口检查于…」（10.5pt，白 0.4）和齿轮。
  - 5 行、32pt 刘海时面板高 = 32 + 42 + 10 + 198 + 30 + 4 = **316pt**（按 `NotchLayout.size` 算）。
- **卡片**：宽 400，高 = cardTop（刘海高 − 2）+ 38 + 16，32pt 刘海时 **84pt**。
  - 左边是盾盾 32pt，标题 14pt semibold，副标题 12pt regular 白 0.65，右边是 × 按钮（24pt 圆）。
  - 边缘流光就是倒计时，2–10 秒，默认 6 秒（`CardEdge.swift`）。
- **动效**：
  - 展开用 `spring(0.5, 0.7)`，收起用 `spring(0.38, 0.88)`，弹卡用 `spring(0.4, 0.8)`（`Common.swift:19-23`、`Notch.swift:334`）。
  - 内容进场是模糊 8 + 从 0.96 放大 + 淡入，`.smooth(0.35)`、延迟 0.06；退场是 0.1s 淡出（`Notch.swift:745-752`）。
  - 悬停 0.12s 后展开，离开 0.35s 后收起（`Notch.swift:533,543`）。

---

## 3. 逐题对照

### Q1 形态与尺寸

**灵动岛的做法**

- **三态的关系**
  - compact：只有一个 Live Activity 时，分在摄像头两侧，左右两块。
  - minimal：同时有多个时，一个贴在岛上、一个（或两个）分离出去，「circular or oval」。
  - expanded：长按 compact 或 minimal 时，或者 alert 时出现。
  - 原文："The expanded presentation is an enlarged version of the compact or minimal presentation. Ensure information and layouts expand predictably"（HIG）。
  - iPhone 18 Pro 可以同时显示最多 3 个：用缩窄的 compact，滑动切换（[Displaying live data](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)、[Apple 支持](https://support.apple.com/guide/iphone/view-live-activities-in-the-dynamic-island-iph28f50d10d/ios)）。
- **尺寸**（HIG Specifications，pt）：

  | 屏幕 | compact（每侧） | minimal | expanded | 受限宽度 |
  |---|---|---|---|---|
  | 430×932 | 62.33×36.67 | 36.67–45×36.67 | 408×84–160 | 28×28 |
  | 393×852 | 52.33×36.67 | 36.67–45×36.67 | 371×84–160 | 28×28 |

  - macOS 一行写的是「Use the provided iOS dimensions」。
  - 2025-12 版 HIG 还写过「corner radius of 44 points」，以及各机型 compact / minimal 时岛宽 230 / 250；现行版删了。
  - 锁屏样式超过 160pt 可能被截断（Displaying live data 原文 "The system may truncate a Live Activity if its height exceeds 160 points"）。
- **展开态的区域**（[DynamicIslandExpandedRegion](https://developer.apple.com/documentation/widgetkit/dynamicislandexpandedregion)）：
  - `center`：在摄像头正下方。
  - `leading` / `trailing`：在摄像头两侧，多出来的内容折到下方。
  - `bottom`：在以上三者之下。
  - 系统先按 leading / trailing 的最小宽度算出 center 的宽度；左右默认等宽。可以用 `priority` 让某个区域占满整宽，或者用 `verticalPlacement: .belowIfTooWide` 把它放到下方。
- **边距与同心**
  - HIG 原文："Use consistent margins and concentric placement … use ContainerRelativeShape to match the corner radius … instead of hard-coding"。
  - 2025-12 版的写法更具体："match its corner radius to the outer corner radius of the Live Activity by subtracting the margin"。
  - 分隔内容块用「inset container shape or a thick line」，不要画到岛的边缘。
  - WWDC23 10194 补充：非圆形的内容也要按「视觉质心」对位，可以把内容模糊后看它的轮廓是不是和外缘同心。
  - 锁屏的标准边距是 14pt（HIG）。灵动岛的默认 content margin，官方没有给数字（**查不到**）。文档只给了用 `contentMargins` 覆盖的例子（8pt、20pt），并且说 "Avoid placing content too close to the edges"。
- **compact 怎么摆**
  - HIG 原文："Keep content as narrow as possible and ensure it's snug against the TrueDepth camera … don't add padding between content and the TrueDepth camera. Maintain a balanced layout with similarly sized views for both leading and trailing"。
  - 两侧要读成同一条信息，颜色和字体一致。
  - 受限宽度时，可以只给 leading，trailing 留空，系统会自动藏起空的 trailing。
- **展开态怎么摆**
  - 不留「额头」，内容紧紧包住摄像头（WWDC23 10194："avoid having a 'forehead' at the top"）。
  - 高度要么是高的，要么是药丸状的矮条，"avoid a height right on the edge between them"。
  - 高度随内容动态变化（HIG："Dynamically change the height … in the expanded presentation"）。

**对我们的建议**

1. **同心规则已经满足，不用改。**
   - 面板：外圆角 28、边距 14 → 会话容器 14 = 28 − 14 ✓。
   - 行内图标：容器 14、竖向边距 7 → 7 ✓。
   - 卡片：× 按钮半径 12，卡片 28 − 18 = 10，差 2pt，基本可以。
   - 要改的话，可以照 HIG 用 `ContainerRelativeShape` 推导，不写死。SwiftUI 在普通视图里，需要外层用 `.containerShape(...)` 声明容器形状；macOS 14 可用（推断，未实测）。改动：小。
2. **卡片宽改成 408，和面板一致。** 理由：HIG 的展开态宽度在同一设备上是固定的；卡片 ↔ 面板切换时，宽度不跳，只变高。现在是 400 对 408。改动：小。
3. **面板高 316，超出灵动岛 84–160 的范围。**
   - 面板是用户主动唤出的，更像「进 App 看详情」。用户已经定了最多 5 行，可以保留。
   - 建议在 `docs/ui.md` 写明这是有意偏离：Mac 屏幕大，菜单栏下方空间富余（推断）。
   - 卡片 84 在区间内，不用动。
4. **收起态右耳**：见 §1.3 的表格条目。灵动岛要求紧贴摄像头、两侧平衡、不浪费宽度；我们右耳的指示偏向外侧，空闲时整只耳朵是空的。可以选：
   - (a) 指示往刘海一侧靠，紧贴，中心离刘海约 10–12pt（推断数字，要实机看）；
   - (b) 右耳没东西时，两只耳朵一起收窄到只容下盾盾。HIG 也允许只有 leading，但左右不对称在 Mac 刘海上观感待验。
   - 都要改 `docs/mascot.md` §1，交用户定。改动：中。

### 1.6 Mac 上的系统灵动岛（新）

- Newsroom（2026-10-28）："The Dynamic Island now comes to Mac, serving as the home for Spotlight, Live Activities, and Siri AI … Just like on iPhone, the Dynamic Island provides a quick, intuitive way to see and interact with important information."
- 产品页只描述了「with a tap of your finger」（这台机器有触屏）。指针点击、悬停、尺寸都**查不到**。
- Tech Talk 111467，转引自 blakecrosley.com：
  - "On a Mac with Dynamic Island, Live Activities blend in seamlessly into the top edge of the device. On other devices and displays, they are shown in the menu bar."
  - "Only a single Live Activity can be expanded at a time."
  - 展开只发生在 "when interacted with or if explicitly triggered through an alert request"。
- 同一篇转述说：macOS 27.0 / 27.2 SDK 把 ActivityKit 标成 `@available(macOS, unavailable)`；HIG 也还没有 Mac 灵动岛的章节。

**建议**：先不改代码，在 `HANDOFF.md` 记一条待定。
- 问题一：在有系统灵动岛的 Mac 上，Notchkeeper 是退让，还是改用系统 Live Activity？后者等 SDK 开放，而且我们是 SwiftPM、没有 widget extension，推断要大改。
- 问题二：用哪个 API 判断「这台 Mac 有系统灵动岛」？查不到。
- 等 HIG 出了 Mac 灵动岛的章节，再按它重对一遍本文。改动：大（产品决策）。

### Q2 动效

**灵动岛的做法**

- **性格**：WWDC23 10194 原文是 "Inspired by biological form and motion, the Dynamic Island is designed to feel like a living organism, with a deliberate elasticity that serves as a playful contrast to the fixed nature of the hardware"。App 进入后台时「swoops up into the Dynamic Island」，像 App 真的住进了那块地方。
- **弹簧参数**：Apple 没有公开灵动岛自己的弹簧参数（**查不到**）。系统通用的指引：
  - WWDC23 10158：拿不准就用 bounce 0；约 15% 显得利落；30% 能感到弹；"cautious about using values higher than around 0.4"。duration 是感知时长，不等于 settling 时长。
  - WWDC18 803：调弹性行为从 100% 阻尼开始；有朝某个方向的动量时用 80%。原文举的例子是 Now Playing：呈现用 100%，下滑关闭用 80%。
  - SwiftUI 里 `dampingFraction = 1 − bounce`（bounce ≥ 0 时，推断自 10158 给的换算式）。
- **内容进场和退场**
  - Live Activity 的自定义动画最长 2 秒（HIG 原文 "maximum duration of two seconds"）。
  - 文本默认用模糊式内容过渡（"Text views animate content changes with blurred content transitions"）；图片和 SF Symbols 有默认过渡；加减视图时淡入淡出。
  - 推荐的过渡：`opacity`、`move(edge:)`、`slide`、`push(from:)`；数字用 `numericText(countsDown:)`（Displaying live data）。
- **连续性**
  - HIG 原文："preserve as much of the existing layout as possible by animating existing elements to their new positions rather than removing and animating them back in"。
  - 避免元素重叠：列表里只让真正移动的那一行动，其他行淡入淡出。
- **alert 时**
  - 系统展开成 expanded，亮屏，响默认通知音（HIG）。WWDC23 10194 原文："Make sure to emphasize the information that caused the alert in your layout during this transition"。
  - 展开停留多久：官方**查不到**。二手说法是「a couple of seconds」（[Sparrow Code](https://sparrowcode.io/en/tutorials/live-activities)）。开发者论坛确认 App 没法让它常驻展开（<https://developer.apple.com/forums/thread/780678>）。
- **macOS 刘海 App 的实测参数**（源码）：

  | | 展开 | 收起 | 内容进场 | 其他 |
  |---|---|---|---|---|
  | boring.notch | `spring(0.42, 0.8)` | `spring(0.45, 1.0)` | `.smooth` | 悬停至少 0.3s 才展开（可调 0–1s），离开 100ms 收起；sneak peek（类 alert）默认 1.5s；`ContentView.swift:41,123-124,531`；`BoringViewCoordinator.swift:233` |
  | DynamicNotchKit | `.bouncy(0.4)` | `.smooth(0.4)` | 模糊 10 + scale（compact 横向从 0，expanded 纵向从 0.6，锚在顶部）+ 淡入 | compact ↔ expanded 默认先缩回再长开（`skipIntermediateHides` 可关）；悬停加深阴影 0.5 → 0.8；`DynamicNotchStyle.swift:66-80`、`NotchView.swift:112-145` |

**对我们的建议**

1. **统一弹簧的 owner，并同步文档。**
   - 现在：展开 0.5 / 0.7（bounce 0.3），收起 0.38 / 0.88，弹卡 0.4 / 0.8；`docs/mascot.md` 写的是 0.45 / 0.35、ζ 0.85。
   - 建议的参数：展开保留轻微弹性（bounce 0.15–0.3，符合「deliberate elasticity」，不超过 0.4）；收起用 ζ ≈ 1（照 WWDC18 和 boring.notch，收起没有朝外的动量，不该回弹）；弹卡和展开用同一组。
   - 先改文档、请用户确认，再改代码。改动：小。
2. **alert 时强调触发原因。** 卡片标题已经说清「谁怎么了」，盾盾也换了造型。可以照 WWDC23，让卡上真正变化的那一项（状态图标）做一次 SF Symbols 的 Replace 式弹出。`docs/mascot.md` 的「新装饰」已经照 Replace 写了，可以复用这套参数。改动：小。
3. **数字和文本变化用系统过渡。** IP 变化、徽章文字变化加 `.contentTransition(.numericText())` 或 `.contentTransition(.interpolate)`；徽章图标变化用 `.contentTransition(.symbolEffect(.replace))`（macOS 14+）。改动：小。
4. **悬停延迟 0.12s 偏短。**
   - boring.notch 默认 0.3s；Apple 在 Mac 菜单栏上的 Live Activity 用点击，不用悬停（WWDC25 278）。
   - 推断：0.12s 在鼠标去菜单栏的路上容易误开。
   - 建议先实测误触率，再决定要不要提到 0.25–0.3s。改动：小。

### Q3 颜色与材质

**灵动岛的做法**

- **背景**：纯黑、不透明、不能自定义。
  - HIG 原文："Live Activities in the Dynamic Island use a black opaque background"。
  - Creating custom views 原文："use a black background color with white text … You can't change the background color"。
- **keyline**
  - [`keylineTint(_:)`](https://developer.apple.com/documentation/widgetkit/dynamicisland) 的说明是 "Applies a subtle tint color to the surrounding border"。
  - HIG 原文："When the background is dark — for example, in Dark Mode — a key line appears around the Dynamic Island to distinguish it from other content. Choose a key line color that's consistent with the color of other elements"。
- **颜色**：用大胆的颜色表达身份，"Consider using bold colors for text and objects"。颜色也可以随内容变化（WWDC23 10194）。
- **字**：HIG 原文 "Use large, heavier-weight text — a medium weight or higher. Use small text sparingly"；WWDC23 原文 "extra rounded, thicker shapes, as well as large, heavier weight, easy-to-read text"。
- **logo**：不放容器，不用整个 App 图标（HIG："display it without a container"）。
- **SF Symbols**：九种字重和系统字体一一对应，可以和相邻文字匹配字重；变化用 Replace 动画；variable color 用来表达变化，不用来表达层级（HIG SF Symbols）。
- **对比度**（HIG Accessibility）：≤17pt 至少 4.5:1；18pt 以上或粗体至少 3:1。**macOS 最小字号 10pt，默认 13pt**（HIG Typography）。

**对我们的建议**

1. **keyline**：一手依据支持加一条和内容同色的细边；我们的文档写的是不加，代码却加了（见 §9）。
   - 建议改成：面板的细边用出口状态色（低透明度），卡片的细边用卡片色，和 HIG「consistent with the color of other elements」一致。
   - 先改 `docs/ui.md` 和 `CLAUDE.md`「界面准则·点击范围」那句「不加描边」，经用户确认后再改。改动：小。
2. **低透明度文字提亮。**
   - 白 0.4 ≈ 3.66:1 < 4.5:1，涉及时间列 `Notch.swift:949`、底栏 `:829`、空列表 `:856`。白 0.5 ≈ 5.28:1，0.55 ≈ 6.27:1（按 sRGB 合成计算，推断，没用取色器实测）。
   - 已停止的行整行 ×0.55，时间列就只剩 0.22（约 1.9:1）。建议整行变暗时只暗文字主体，时间保持 ≥ 0.5；或者直接改用 `.secondary` / `.tertiary`，跟随 darkAqua 和「增强对比度」。
   - 改动：小。
3. **卡片副标题** 12pt regular 改成 medium；底栏 10.5pt 已经贴着 macOS 最小 10pt，HIG 说小字「sparingly」，可以提到 11pt。改动：小。
4. **颜色只做点缀、按状态变化，这点我们已经做到**（`docs/ui.md`：绿 / 琥珀 / 灰 / 红，卡片色）。不用改。

### Q4 信息密度

**灵动岛的做法**

- HIG 原文："Focus on important information that people need to see at a glance. Your Live Activity doesn't need to display everything"。
- compact 原文："show dynamic, up-to-date information that's essential"。minimal 原文："display updated information rather than just a logo"，例子是 Timer 在 minimal 里显示剩余时间。
- 文案要短：用缩写、简写单位、精度低一点的数据保持宽度（HIG、WWDC23）。
- 不显示敏感信息（HIG "Avoid displaying sensitive information"）。
- 开发者访谈（Spotlight on，2022）：
  - Citymapper 只放「图标 + 倒计时」，原话 "We didn't want it to get in your way"。
  - Apollo 在 compact 只放一个数字，详情放 expanded。
  - Wakeout 原话 "The healthy moments are passive; if you don't pay attention, they dismiss themselves"。

**对我们的建议**

1. **基本吻合。** 收起态的盾盾造型本身就在传达状态，不是静态 logo，符合 minimal 的原则。
2. **IP 会完整显示在面板上**，`CLAUDE.md` 有用户 10-28 的决定。HIG 的敏感信息条款主要针对锁屏和 Always-On。我们的面板只在悬停时出现，可以接受。只是提示：录屏、共享屏幕时会露出 IP（推断）。不改。
3. **卡片副标题是完整路径（`~` 缩写）**：在 400pt 宽里会被截断。灵动岛的做法是「精度低一点」，可以考虑只显示最后一两段（项目名），完整路径放悬停提示。和用户 10-29 的决定（显示完整路径）冲突，交用户定。改动：小。

### Q5 提醒（alert）

**灵动岛的做法**

- **何时提醒**：HIG 原文 "Alert people only for essential updates that require their attention. Live Activity alerts light up the screen and by default play the notification sound … show the expanded presentation in the Dynamic Island"。不要同一件事又发推送又发 Live Activity alert。
- **声音**：`AlertConfiguration.sound` 用 `.default` 或 `.named(_:)` 自定义；title / body 只在 Apple Watch 上显示（[AlertConfiguration](https://developer.apple.com/documentation/activitykit/alertconfiguration)、Meet ActivityKit）。
- **多个同时存在时**
  - 同一个 App 的多个 Live Activity，`relevanceScore` 最高的进灵动岛；分数相同时，先开始的那个进（[relevanceScore](https://developer.apple.com/documentation/activitykit/activitycontent/relevancescore)）。
  - 不同 App 之间由系统决定。
  - HIG 原文："prefer a single Live Activity that uses a dynamic layout and rotates through events"；WWDC23 原文："consider ticking between the display of them"。
  - Mac 上，Tech Talk 转述："Only a single Live Activity can be expanded at a time"。
- **结束**：结束后立刻从灵动岛移除；锁屏上默认最多再留 4 小时，大多数情况 15–30 分钟就够了（HIG）。
- **按重要程度决定多坚持**：见 Wakeout 的原话。

**对我们的建议**

- 一次一张、红卡常驻、临时卡自动收、声音跟着卡响，和上面的原则一致，**不改**。
- 我们不轮播多个会话，用优先级只显示最高的（`docs/mascot.md`「优先级」）。这相当于灵动岛的 relevanceScore，合理。
- 不同点：灵动岛 alert 会亮屏；我们熄屏时把卡压住，回来再放。这是用户 10-29 同意的有意偏离，`docs/ui.md` 已经写了理由。

### Q6 倒计时 / 进度

**灵动岛的做法**

- 文本倒计时用 `Text(timerInterval:pauseTime:countsDown:showsHours:)`，由系统驱动、自动刷新。在 widget 里它会横向撑满可用宽度，要用 `frame` 约束。
- 进度用 `ProgressView(timerInterval:countsDown:)`。原文："Date-relative progress views … don't support custom styles"。
- 数字变化加 `numericText(countsDown:)`。
- Timer 的 minimal 显示剩余时间（HIG）；Flighty 的 minimal 是一圈航程进度（Spotlight on）。
- **alert 自动收回本身没有可见的倒计时**（推断：HIG、ActivityKit 文档、WWDC23 10194 / 10184 / WWDC26 223 都没提）。
- 熄屏常亮（Always-On）时系统不做动画（Animating data updates 原文 "the system doesn't perform animations"）。

**对我们的建议**

- 我们的流光是「停留时间」的可视化，在灵动岛里找不到对应的东西。2–10 秒的连续沿边动画，也超出了 HIG 给 Live Activity 动画的 2 秒上限（推断：这条上限原本针对内容更新动画，用在这里是类比）。HIG Motion 原文："Add motion purposefully … avoid adding motion to UI interactions that occur frequently"。完成卡一天会弹很多次。
- 交用户选：
  - (a) **保留，但收敛**：去掉柔光晕、降低亮度，只留一条细的亮线。
  - (b) **照灵动岛**：不画倒计时，卡片只有静态的同色细 keyline，到时间自己收（「悬停暂停」照旧，用户靠鼠标就能留住卡）。
  - (c) **把倒计时缩到一个小元素上**：例如 × 按钮外一圈进度环（类似 Timer 的环）。`ProgressView(timerInterval:)` 不能自定义样式，要自己画，用 Core Animation 的 `strokeEnd` 动画，和现在的流光同一套机制。
  - 我的倾向是 (b) 或 (c)，因为它们更接近「克制」（推断）。改动：中。
- 减弱动态效果时现在不流动、改成静态细边（`CardEdge.swift:149`），这点已经符合 HIG。

### Q7 交互

**灵动岛的做法**

- 点按 compact / minimal：打开 App，并且直接到相关详情（HIG："opens your app at the right location"）。左右两块点了要去同一个界面。
- 长按：展开（HIG、Meet ActivityKit）。用户手势还有：上滑收起展开态；点另一个活动切换；iPhone 18 Pro 上横滑在多个活动之间切换（Apple 支持文档）。
- 展开态里的按钮：HIG 原文 "Focus on simple, direct actions … prefer limiting it to a single element"。
- Mac：
  - macOS Tahoe 菜单栏里，选中会弹出锁屏样式，再点启动 iPhone 镜像（WWDC25 278）；HIG 原文 "Clicking the Live Activity launches iPhone Mirroring"。
  - Mac 灵动岛的指针行为**查不到**；产品页只写了手指点按。
- App 不要画指向灵动岛的界面（HIG、WWDC23："Apps shouldn't draw UI that points to the island"）。

**对我们的建议**

1. **透明区域穿透、只有看得见的形状接收点击**：已经符合，`CLAUDE.md` 有这条。
2. **卡片的唯一交互是 ×**，符合「single element」。可选：点卡片主体跳到对应的终端会话，相当于灵动岛的「opens your app at the right location」。但这是没出现过的需求，`CLAUDE.md`「不为没出现的需求写代码」，只记录，不建议主动做。
3. **悬停展开对应长按**。Mac 上 Apple 自己用点击。保留悬停（用户设置里可以关），延迟见 Q2-4。

### Q8 无障碍与减弱动态效果

**灵动岛的做法 / 一手指引**

- HIG Accessibility 原文：开了「减弱动态效果」要 "reducing automatic and repetitive animations, including zooming, scaling, and peripheral motion"。具体做法：
  - 收紧弹簧、减少回弹；
  - 把 x / y / z 方向的过渡换成淡入淡出；
  - **"Avoiding animating into and out of blurs"**。
- HIG Motion 原文："Make motion optional … avoid using it as the only way to communicate important information"，要用声音、触觉补充。
- 灵动岛本身是否响应「减弱动态效果」：Apple 没写（**查不到**）。用户反馈说系统的 Face ID 动画在开了减弱动态效果后照样播放（MacRumors、MPU Talk，二手）。
- VoiceOver：灵动岛可以像普通元素一样被选中和朗读（二手：Six Colors、AppleVis）；早期版本有内容更新后重复朗读的 bug（[Apple 论坛 719235](https://developer.apple.com/forums/thread/719235)）。
- 新的 Mac 示例代码出现了 `alertConfiguration: .announcement("Ready")`（Tech Talk 111467），文档里查不到这个 API，推断是给播报用的。
- Always-On 时降亮度、不做动画（`isLuminanceReduced`）。

**对我们的建议**

1. 减弱动态效果时，内容进场已经只用淡入（`Notch.swift:747`），符合「不要模糊」的要求 ✓。盾盾和徽章原地淡出、新位置淡入（`docs/mascot.md` §5）✓。HANDOFF 记着这部分还没实机验。
2. **盾盾加状态值**：`MascotView` 现在只有 `accessibilityLabel("盾盾")`，建议加 `accessibilityValue`（造型名，例如「等你批准」）。改动：小。
3. **卡片弹出时播报**：`NSAccessibility.post(element:notification: .announcementRequested, userInfo: [.announcement: 标题])`。原文："If VoiceOver is enabled, it's presented via speech and/or braille. Otherwise, it does nothing"（<https://developer.apple.com/documentation/appkit/nsaccessibility-swift.struct/notification/announcementrequested>）。改动：小。
4. **「增强对比度」**：改用 `.secondary` 这类语义色以后会自动适配，见 Q3-2。

---

## 4. 总表：我们现状 vs 灵动岛做法 vs 建议（按影响从大到小）

| # | 方面 | 我们现状 | 灵动岛做法（出处） | 建议 | 改动 |
|---|---|---|---|---|---|
| 1 | Mac 系统灵动岛 | 自己画在刘海位置 | 2026-10-28 起 MacBook Pro 有系统灵动岛，承载 Spotlight / Live Activities / Siri（Newsroom、Tech Talk 111467） | 记入 HANDOFF 待定：新机器上退让还是迁移；等 HIG 的 Mac 章节和 SDK | 大（产品决策） |
| 2 | 卡片倒计时 | 边缘流光，2–10s 连续沿边流 | alert 自动收回，没有可见的倒计时（推断）；动画 ≤2s；Motion 要求 purposeful（HIG） | 三选一：收敛 / 去掉只留 keyline / 改成 × 外的小进度环 | 中 |
| 3 | 收起态宽度与紧贴 | 两耳固定 44；右耳指示中心离外缘 17.5；空闲时右耳空着 | 紧贴摄像头、不留 padding、尽量窄、左右平衡；trailing 空就藏（HIG compact） | 指示往刘海靠；或右耳没东西时收窄；改 mascot.md §1 | 中 |
| 4 | 对比度与字重 | 白 0.4 小字（≈3.7:1）；已停止的行 ×0.55；副标题 12 regular；底栏 10.5 | ≤17pt 至少 4.5:1；medium 以上字重；小字少用（HIG） | 不透明度 ≥0.5 或改用语义色；副标题 medium；底栏 11 | 小 |
| 5 | keyline | 文档写不加；代码里面板有白 0.08 描边，红卡有同色细边 | 深色时有 keyline，颜色和内容一致（HIG、keylineTint） | 改文档采纳 keyline：面板用状态色，卡片用卡片色；经用户确认 | 小 |
| 6 | 弹簧 | 代码三组参数，和文档不一致 | 拿不准用 bounce 0，不超过约 0.4；没有朝外动量时 100% 阻尼（WWDC23 10158、WWDC18 803） | 统一一个 owner：展开 bounce 0.15–0.3，收起 ζ≈1，弹卡同展开；先改文档 | 小 |
| 7 | 卡片 ↔ 面板连续性 | 卡宽 400、面板 408；卡片右侧只有 × | 展开态等宽；元素保持相对位置（HIG） | 卡宽改 408；卡片 trailing 可放状态指示，承接右耳位置（交用户定） | 小 / 中 |
| 8 | alert 强调触发原因 | 标题文案 + 盾盾换造型 | 「emphasize the information that caused the alert」（WWDC23 10194） | 状态图标做一次 Replace 式弹出 | 小 |
| 9 | 内容更新过渡 | IP、徽章直接替换 | 文本用模糊 / 数字过渡，符号用 Replace（Displaying live data） | `.contentTransition(.numericText())`、`.symbolEffect(.replace)` | 小 |
| 10 | 无障碍 | 盾盾无状态值；卡片无播报 | VoiceOver 可读；新 API 有 announcement（Tech Talk 示例） | 加 `accessibilityValue`；`announcementRequested` | 小 |
| 11 | 悬停延迟 | 0.12s 展开 | Mac 菜单栏 Live Activity 用点击（WWDC25 278）；boring.notch 0.3s | 实测误触后考虑 0.25–0.3s | 小 |
| 12 | 卡片副标题 | 完整路径 | 文案短、精度低一点（HIG、WWDC23） | 只显示项目名，完整路径放悬停（和用户 10-29 决定冲突，交用户） | 小 |
| 13 | 面板高度 | 最高 316 | 展开态 84–160（HIG） | 保留（用户唤出的详情），在 ui.md 写明有意偏离 | 文档 |
| 14 | 同心与边距 | 28 / 14 / 14，已同心 | 内圆角 = 外圆角 − 边距；ContainerRelativeShape（HIG） | 不改；可选改用 ContainerRelativeShape 推导 | 不改 |
| 15 | 提醒策略 | 一次一张、红卡常驻、声音跟着卡 | 一次只展开一个；只提醒 essential；不重要的自己消失（HIG、Spotlight on） | 不改 | 不改 |
| 16 | 背景与亮暗 | 贴刘海的部分永远黑底白字 | 黑色不透明，不能改（HIG） | 不改 | 不改 |

---

## 9. 顺带发现：文档和代码不一致（没改，留给主会话处理）

1. **描边**：`CLAUDE.md`「界面准则」写「卡片只用阴影，不加描边」，`docs/ui.md`「亮色与暗色」写「不加 key line：黑面板和卡片只用阴影，不加描边」。但是：
   - `Notch.swift:644-647` 给面板画了 `white.opacity(0.08)` 的描边；
   - `CardEdge.swift:9,128` 给常驻红卡画了同色、0.5 透明度的细边，注释写的是「灵动岛的 keylineTint」。
2. **弹簧**：`docs/mascot.md` §5「收起与展开」写 ζ 0.85、展开 response 0.45、收起 0.35；`Common.swift:19-23` 是 `notchOpen = spring(0.5, 0.7)`、`notchClose = spring(0.38, 0.88)`；`Notch.swift:334` 弹卡另用 `spring(0.4, 0.8)`。
3. **左耳盾盾的位置**：`docs/mascot.md` §1 写「画布左缘 = 收起形状的左外边 + 外翻 4 + 6」，代码里画布是 28×28（`NotchLayout.earCanvas`），注释说「离刘海也是 6pt」。两边描述的画布尺寸不同，要不要以哪个为准，请主会话核对。

---

## 10. 查不到的

- 灵动岛展开、收起的弹簧参数（Apple 没公开）。
- alert 时展开态停留的具体秒数（只有二手的「a couple of seconds」）。
- 灵动岛默认的 content margin 数值（文档只说用默认值、给了覆盖示例）。
- 现行 HIG 里灵动岛的圆角（2025-12 版写 44pt，现行版删了）。
- 灵动岛是否响应「减弱动态效果」（只有用户反馈说不响应）。
- Mac 灵动岛的尺寸、指针 / 悬停行为、怎么检测、安全区 API。
- Alcove 的任何具体参数（官网只有标语，闭源）。
