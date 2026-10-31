# 界面：亮暗、多语言、面板布局、卡片

改界面前读完「原则」；细节按需看后面各节。Pip 的造型与动效见 `docs/mascot.md`，守卫怎么画见 `docs/egress-guard.md`。

## 原则

- **动效**克制、节奏活泼：弹簧和正弦缓动，进场稍慢、退场稍快；「减弱动态效果」只淡入淡出；常驻动画交给 Core Animation，不在主线程逐帧重画。
- **默认不打扰**：空闲收进刘海，悬停或点击展开；红卡挂到恢复，临时卡放完回到它。
- **状态 = 颜色 + 图标 + 文案**：绿 healthy、琥珀 egressMismatch、灰 unknown、红 violated。
- 贴刘海的部分永远黑底白字，只有设置窗口跟随亮暗；只有看得见的形状接收点击，透明区域穿透。
- 文案源语言是简体中文、一句话说清，按钮写动作本身（「重新检测」）；走 String Catalog，同时给 English。
- 照「灵动岛规范」一节；改了界面按「截图」一节附截图。

## 亮色与暗色

**贴着刘海的部分永远黑底白字**（耳朵、面板、所有卡片，外接屏上也画黑块）；只有设置窗口跟随系统（用户定）。

- 依据见「灵动岛规范」1：背景色永远是黑的，不给背景加颜色、图案或光效的变化；要动效就加在内容上（Pip、文字、流星）。黑色形状本身照常用弹簧变形。
- 刘海窗口要设 `appearance = .darkAqua`：只写死黑底白字不够，系统控件、`.secondary`、SF Symbols 分层色、tooltip 跟窗口外观走。设置窗口不设外观，也不设 `NSApp.appearance`。
- 设置页的 Pip 放在黑底「舞台」上：Pip 配色按黑底设计，白底上几乎看不见；这样造型数据不用分亮暗。
- 设置页的状态点在亮暗两种底上都要 ≥ 3:1（WCAG 1.4.11）。

## 多语言

- 简体中文（源语言）和 English，**随系统语言**，App 不自己切；设置页放「在系统设置中更改语言…」跳到系统按 App 设语言的位置（WWDC19 403："do not attempt to set the application language manually in code"）。
- String Catalog 在 `Resources/`：`Localizable.xcstrings`（键就是中文原文，用默认的 `Bundle.main`）和 `InfoPlist.xcstrings`（权限说明）。改了文案跑 `scripts/strings.sh`：和 Xcode 一样靠编译器抽字符串，新的加进来、删掉的标 stale，再补 English。
- 坑：先存成 `String` 再 `Text(someString)` 不会本地化，存之前就用 `String(localized:)` 取出译文（<https://developer.apple.com/documentation/swiftui/text/init(_:tablename:bundle:comment:)>）。
- 坑：`swift build` 不编译 `.xcstrings`，只原样拷贝；由 `scripts/run.sh` 用 `xcrun xcstringstool compile` 编进 `.lproj`（用户同意依赖 Xcode 工具）。
- 坑：Info.plist 写 `CFBundleDevelopmentRegion = zh-Hans`、`CFBundleLocalizations = [zh-Hans, en]`，不写 `CFBundleAllowMixedLocalizations`（实测日文环境下判成 en 却显示中文）。
- 不翻译：出口 IP、项目名；日志、文档、注释、提交说明仍是中文。
- 测试：`swift test` 解析 catalog，要求每个键都有 en 译文、没有 stale 的键（参考 bitchat 的 `LocalizationCoverageTests`）。

## 面板布局

尺寸在 `NotchCore` 的 `NotchLayout`、`PanelShape`，画法在 `Notch.swift` 的 `NotchRoot.corners`、`NotchDashboard`，以代码为准。

- **版式**（HIG：展开态和收起态元素相对位置不变）：左上 Pip（左耳那只放大），右上出口状态徽章（右耳的位置），刘海正下方是出口标题和 IP，中间各插件的段，底栏左「出口检查于…」、右齿轮。面板、卡片同宽，切换时形状只变高度。
- **按插件分段**（用户 10-31）：出口守卫那一段就是顶上的状态区、徽章和底栏的检查时间，固定在最上面，关掉守卫就都不画。Claude Code 和外部插件各一段（内嵌圆角容器），行用同一个模板 `PanelRow`：图标、标题、可选副标题、状态指示、右侧「距今多久」或短值、点了去哪。用户在设置 › 插件里定每段开不开、顺序、最多露几行；各段合起来至多露 6 行，排在前面的先拿，多的在段里滚。空的段不画，段都空时一行占位；一个插件都没开时是「还没有开启的插件」和「打开插件设置」。
- **外部插件的活动**（照 ActivityKit）：start / update / end，时间戳取新，最长 8 小时，在插件那一段占一行；`alert` 时弹卡，之后的更新原地刷新这张卡，不重放、不响。
- **收起态谁上位**（照灵动岛 relevanceScore）：每个开着的插件报一个紧急程度（平静 / 进行中 / 要你看 / 严重，严重只有守卫能报；外部插件取它开着的活动里最急的）。收起时 Pip 和右耳显示最急的那个，一样急时守卫在前、其余按段的顺序；都平静时显示常驻插件（默认守卫，可选不常驻），不常驻就是空闲的 Pip、右耳空着。设置 › Pip 可以关掉收起时的 Pip：右耳也没东西时就是一块纯黑的刘海（照 boring.notch 的空闲脸）。
- **对齐线**：Pip 按身体圆心和会话图标中心对齐；徽章、齿轮、时间列右缘对齐。
- Pip 和徽章 32pt（用户定：40pt 偏大）。
- **会话行**（Claude Code 那一段）：不垫底色（用户定）；agent 厂商标志 + `cwd` 完整路径（`~` 缩写，太长从前面截）+ 状态指示 + 时间（用户定）。
  - 不显示会话名：它可能从对话推出来。
  - 状态只用指示不写字：工作中三蓝点，等你回答 / 批准用 Pip 这两个造型的装饰；已停止不画、标志和路径变暗，时间不变暗（保住对比度）。不用绿色（绿只表示出口正常）。
  - 时间统一是「状态变化距今多久」，系统相对时间格式。
  - 按进程启动先后排，状态变了不挪位置；点行跳到 Ghostty（`docs/agent-integration.md`「跳转到 Ghostty」）。
- 小字（≤ 17pt）对黑底至少 4.5:1（HIG Accessibility）。

## 卡片

刘海上一次只放一张卡，由 `NotchCore` 的 `CardQueue` 决定放哪张、放多久、响不响。两层：

- **红卡**：违规挂着时的底层（挂不挂由 `ViolationAlert` 判，`docs/egress-guard.md`）。关掉「红卡一直保留」时，红卡放满一次「卡片停留」就收起，算你关掉了这一次。
- **临时卡**：完成卡（Glass）、出错卡（Funk）、介入卡（Ping）、恢复卡（Glass）。按「卡片停留」倒计时，恢复卡固定 4 秒；到时收起，红卡还挂着就回到红卡。

规则：

1. **一个队列**：所有临时卡先进先出，一次放一张。两个会话同时结束也不会互相顶掉。
2. **同一个会话只留最新**：排着的旧卡被同会话后来的卡原地替换；恢复卡同时只排一张；外部插件同组（消息的 `group`）的也一样。**介入卡过期就撤**：它说的是「此刻在等你」，会话一不再需要你介入，排着或正在放都撤；完成卡、恢复卡说的是已经发生的事，不撤。
3. **声音跟着卡响**：卡放出来那一刻才响；被打断后重放不再响。听到的和看到的一一对应。
4. **违规开始插到最前**：正在放的临时卡回到队首，红卡先完整放一次「卡片停留」再接着放队列。
5. **之后盖在红卡上**：红卡放过第一次后，新来的内置插件的临时卡盖在上面，放完回到红卡；外部插件的卡排着，红卡撤了再放（恢复卡排在它们前面）。每个外部插件至多排 3 张，再来就丢它最旧的那张（用户 10-31）。关掉一个插件，它排着的、正在放的卡都撤。
6. **介入卡也自动收回**（用户定）：之后还在等你，靠收起态的 Pip 造型和右耳提示。
7. **Pip**：卡上的 Pip 就是左耳那只，跟形状的弹簧飞到卡片左侧（和面板左上那只在同一条竖线上，面板和卡片互切时只上下走、不横移），换成这张卡的造型（完成、恢复 finished，介入 question / approval，出错 error，红卡 danger）；收起时飞回（用户定：要从原来的位置缓动过来）。
8. **看不见就不放**：熄屏或锁屏时倒计时停住，新卡排着不放不响；新违规照样挂上红卡，Basso 等回来再响；离开期间已恢复的不补响。

- **流星**：卡片弹出时两颗流星从顶部两端沿边流到底边中间，只走一趟，**不代表倒计时**（用户定）。形状和时长在 `CardEdge.swift`（照 Magic UI Border Beam）。常驻红卡、减弱动态效果时只画一条淡的同色细边（灵动岛 `keylineTint`）。用户否掉过：进度条、循环流光、彩色泛光、没有实体头的光晕。
- **分区与内容块**（用户定，照灵动岛展开态分区）：第一行 Pip + 标题 / 副标题 + 右侧短值 + ×；下面至多一个内容块——正文（Markdown 子集）、日志尾巴（等宽，留最后几行）、键值、勾叉列表、进度。块名照 Adaptive Cards（TextBlock、FactSet）。内容按自然大小排（正文可换行、最多 3 行；日志每行截断），App 量出高度，形状用弹簧平滑长过去，不预先算高度（用户定）。正文只认粗体、斜体、行内代码，链接去掉（动作只走点卡片和按钮）。外部插件的卡在副标题前标插件图标和名字。版式不用 HTML：WebView 是另一个进程，接不上 Pip 和形状的动画。
- **点卡片和按钮**：卡片可以带一个点击动作和至多两个按钮，动作只有三种：打开 URL（https 和设置 › 插件「链接白名单」里的 scheme；拦下的只记 scheme）、切换 App、跳回终端。点了都算关掉这张卡。Claude Code 的卡点了跳回 Ghostty 里这个会话；红卡、恢复卡没有动作。
- **颜色**（流星和细边）：完成和普通消息银白、出错浅橙、等你回答和「要你看」青、等你批准青柠、恢复绿、红卡红；普通消息不响。绿色只给出口正常；Claude 橙在黑底上发红，不用。
- **文案**：标题说谁怎么了（「Claude Code 做完了」），副标题是会话路径。弹卡时 VoiceOver 念标题。
- **悬停按卡算**：鼠标在卡上动了才暂停倒计时；卡弹到不动的鼠标底下照常倒计时。

## 灵动岛规范

刘海上的东西照 iPhone 灵动岛的规矩做。Apple 还没有 Mac 灵动岛的章节，等出了再对一遍（`HANDOFF.md`）。出处：[HIG Live Activities](https://developer.apple.com/design/human-interface-guidelines/live-activities)（下称 HIG）、[Displaying live data](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)、[HIG Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)、[HIG Motion](https://developer.apple.com/design/human-interface-guidelines/motion)、WWDC23 10194「Design dynamic Live Activities」、WWDC23 10158「Animate with springs」、WWDC18 803「Designing Fluid Interfaces」。

| # | 规矩（出处） | 我们怎么做 |
|---|---|---|
| 1 | 背景纯黑不透明，不能改（HIG："use a black opaque background"） | 贴刘海的部分永远黑底；背景色不变，动效加在内容上 |
| 2 | 深色时有一圈 keyline，颜色和内容一致（HIG、`keylineTint`） | 面板白 0.08 细边；常驻红卡和减弱动态效果时卡片画同色细边 |
| 3 | 换形态时现有元素移到新位置，不消失再进场；列表里只让真正移动的那一行动（HIG："animating existing elements to their new positions"） | Pip 从左耳飞到面板 / 卡片，右耳变徽章；面板和卡片同宽，只变高度；会话行状态变了不挪位置 |
| 4 | 自定义动画最长 2 秒；动效要有目的，经常出现的交互少加（HIG、HIG Motion） | 形状、内容进场、流星 2 秒内放完；流星只走一趟，不循环 |
| 5 | 文本内容变化用模糊过渡，数字用 `numericText`，符号用 Replace（Displaying live data） | 卡片内容模糊淡入；IP 数字滚动；徽章图标 Replace |
| 6 | 弹簧拿不准用 bounce 0，不超过约 0.4；没有向外动量的收起用 100% 阻尼（WWDC23 10158、WWDC18 803） | 展开和弹卡用同一组弹簧（用户定），带轻微弹性；收起几乎不回弹（`NotchSpring`） |
| 7 | 只提醒要紧的事；提醒时展开、响通知音；强调触发提醒的那一项（HIG、WWDC23 10194） | 卡片标题说谁怎么了，Pip 换成这张卡的造型；卡片右侧不另放状态指示、不额外弹图标 |
| 8 | 一次只展开一个；不重要的自己消失（HIG） | 一次一张卡，临时卡自动收回，红卡常驻 |
| 9 | 点按打开 App 里相关的位置；展开态的交互尽量只有一个（HIG） | 点卡片跳到 Ghostty 里这个会话；卡上唯一的按钮是 × |
| 10 | 收起态左右平衡、紧贴摄像头（HIG compact） | 右耳指示在耳朵可见部分正中，和左耳 Pip 对称；不随内容收窄（三点常亮常灭，宽度跟着变反而打扰） |
| 11 | 字用 medium 以上，小字少用；≤ 17pt 对比度至少 4.5:1；macOS 最小字号 10pt（HIG、HIG Accessibility、HIG Typography） | 小字 medium、白 0.5 以上；× 的 10pt 已在下限 |
| 12 | 减弱动态效果：位移、缩放换成淡入淡出，不做模糊进出，收紧弹簧（HIG Accessibility） | 内容、Pip、徽章只淡入淡出；黑色形状的弹簧收紧到不回弹（`NotchSpring`） |
| 13 | VoiceOver 能读到状态；动效不能是传达重要信息的唯一途径（HIG Accessibility、HIG Motion） | Pip 有 `accessibilityValue`，弹卡时播报标题；状态 = 颜色 + 图标 + 文案 + 声音 |
| 14 | 同心：内圆角 = 外圆角 − 边距；内容紧贴顶部，不留「额头」（HIG、WWDC23 10194） | 面板满足（外圆角 28、边距 14、会话容器 14）；卡片左右边距按 Pip 对齐线定，不按这条；面板里的 Pip 在刘海左侧、紧贴刘海 |

有意偏离：

- 熄屏时不亮屏，卡压着等回来再放（「卡片」8，用户定）。
- 面板比展开态的 84–160pt 高：它是用户主动唤出的详情。
- 出口 IP 完整显示（用户定，只在悬停面板上）；卡片副标题是完整路径，不按「精度低一点」缩成项目名（用户定）。
- Pip 和右耳指示保留常驻循环（星星转、!! 跳、三蓝点）：Pip 是角色，不是一次性的动画。
- 收起态的耳朵没贴紧摄像头：耳朵宽度固定，指示在可见部分正中。
- 会话行的厂商标志带一层淡底（HIG 说 logo 不放容器）。
- 流星是灵动岛 alert 没有的额外动效（用户定要，只走一趟）。
- 悬停就展开，不像 Apple 在 Mac 上用点击：没出现误触，出现了再按实测调延迟。

## 截图

改了界面要附截图：刘海机型亮、暗各一张（贴刘海部分两张都应是黑的）；改了文案的中、英各一张；有外接屏时补一张无刘海的。
