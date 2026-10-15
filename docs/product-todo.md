# 产品需求 TODO

记录日期：2026-10-12。核对基线：`aca8d6c`。

状态：以下四项待实现或补齐验证，不代表已发布。按 KISS 原则复用现有能力；
本文件只记录需求、实现边界与验收条件，不授权操作用户的运行中会话、安装或发布。

**当前验收安排（2026-10-12 用户确认）：** 四项已有代码及定向回归，尚不能宣布全部完成。
iPhone 验证延后；本轮以同屏拖出和独立操作验收，不要求接入第二块屏幕。
Mac 自测使用隔离 App，不操作用户会话。用户随后已授权提交本轮修改并覆盖安装本机 Mac；
未授权推送或发布，iPhone 及其他未完成验收仍按原安排保留。
此前按测试安装授权覆盖过一次，原 App 保留完整备份；用户随后明确禁止继续覆盖。
完整 App 交互通过 Computer Use 复核；真机、不同屏幕缩放比例的结果仍不得记作通过。

## 1. Mac 会话 Window 标签拖出为独立窗口

**目标：** 主 CtrlX 留在一个屏幕，将某个 Agent / Terminal Window 拖到另一屏幕，独立放大和操作。

**实现进展：** 已接入独立原生 Scene、Host + 稳定 Window ID 的展示所有权、
独立输入路由、主窗口展示 / Fit 排除，以及带 Host / Session 范围的原生标签拖动。
当前增量将独立窗口改为复用主窗口的多标签工作区：同 Host、同 Session 的
Terminal / Files / Browser 可互移；New Terminal / Agent、Fork 和 Files / Browser
均留在发起窗口。下列旧版验收不代替本次多标签增量验收。
隔离原生视图已验证拖到窗外、栏内放下、Esc 取消和普通点击；隔离完整 App 已验证
Local / Viewer 拖出及菜单打开、重复聚焦、单 / 多 pane 输入、Fit、关闭返回和 Viewer 重连。
Local / Viewer Files 路由、Mac 参数命令交互及两端独立窗口的 Codex Questions 展开按键已验证；
两端当前目录 Fork 的目标路由及新窗口创建已用隔离命令夹具验证。
真实语音、真实 Agent 服务与完整交互矩阵仍待验收。
实际双屏与 iPhone 验证按用户安排延期。

- [x] Mac Local 和 Mac Viewer 都支持将会话中的 tmux Window 标签拖出标签栏，创建可移动、缩放和全屏的 macOS 窗口。（早期完整隔离 App 已核对窗外拖出；标签栏内外的交互回归见后续记录）
- [x] 拖出的是同一个 Window 的展示，不创建新 session、不 Fork、不重启 Agent；保留该 Window 的 pane 分屏。
- [x] 以 Host 身份和稳定 Window ID 标识目标，不以标签名称、可变序号或 pane ID 单独定位。
- [x] 区分标签栏内排序、现有左右分栏和拖出操作，取消拖动不得改变原布局。（原生隔离视图验证；完整 App 手势验收仍待补齐）
- [x] 同一个 Window 在本客户端仅有一个活动终端展示；主窗口与独立窗口分别只列出自己持有的标签，不重复创建终端。
- [x] 关闭独立 macOS 窗口只结束独立展示，并恢复主窗口入口的正常展示；真正关闭 tmux Window 仍走原有明确的关闭操作。
- [ ] 输入焦点、快捷命令、语音、Questions、Files / Fork 等操作绑定独立窗口自己的目标，不跟随主窗口当前选择串台。
- [x] 复用现有终端流和连接服务；明确尺寸控制权，避免主窗口与独立窗口反复竞争 resize。（独立窗口仅显式 Fit；主窗口 Fit 排除已脱离的 Window）
- [x] 独立窗口复用主窗口标签栏、右键菜单和 Fit 按钮，关闭原生窗口会归还标签；同 Host / Session 可互移 Terminal / Files / Browser。Git 保留为各窗口的工具入口，Simulator 暂不互移，不要求跨重启恢复独立窗口。
- [x] 跨 Host / Session 拖入标签栏时保留原标签，在目标窗口轻提示仅支持同主机、同会话合并，约 3 秒后自动消失。此类拒绝会结束拖放，不再进入“拖出新窗口”的回退；同会话合并与栏内排序仍走原流程。

**验收：**

- [x] 本轮同屏分别操作主窗口和独立窗口，输出、输入和焦点互不串台。双屏及不同缩放比例由用户明确延后。
- [x] 独立窗口全屏和关闭后可恢复访问；不终止会话，不重复发送输入。（实际屏幕断开恢复随双屏验收延期）
- [ ] Local / Viewer、普通终端 / Agent、单 pane / 多 pane，以及远程断开重连均验证。

**入口：** `CtrlxServerFeature/Views/MainView.swift`、
`Views/MainViewComponents/WindowTabBar.swift`、`RemoteWindowTabBar.swift`，
以及现有终端流、尺寸和焦点路由。约束见 [流式终端](streaming-architecture.md) 与 [Mac 尺寸](swiftterm-sizing.md)。

## 2. 需要补充参数的 Agent 快捷命令不自动发送

**目标：** Codex、Claude Code 的命令需要用户补充参数时，只填入输入框；例如点击 Codex `/goal` 后由用户填写目标再发送。

**实现进展：** 共用命令目录 `AgentCommandMenu.swift` 按 Agent 声明发送策略；
两个 Agent 的 `/goal` 插入 `/goal `，其余已有命令保持可用的无参执行入口。

- [x] 按 Agent 分别核对现有快捷命令，区分“可直接执行”与“需要补充参数”，记录核对的 CLI 版本；不要假设两种 Agent 的同名命令语义相同。（Codex 0.162.1 / Claude Code 2.1.276）
- [x] 在共用命令模型集中声明发送行为，Mac Local、Mac Viewer 和 iOS 使用同一份规则，不在各端按钮中分别判断命令名称。
- [x] 需要补充参数的命令只插入命令及必要空格，例如 `/goal `，不发送 Enter、不自动补参数。
- [ ] 插入后关闭快捷命令面板并恢复终端输入焦点，用户补完参数后显式发送；保留已有输入，不自动清空。
- [x] 可直接执行的命令保留现有发送行为与有序输入队列；未知或无法确认的条目先明确交互策略，再纳入目录。
- [x] 保留断连、切换目标、输入修订和阻塞表单的有效性检查；不改变快捷短语和自定义按钮已有的发送选项。

**验收：**

- [ ] 三个界面点击 Codex `/goal` 均不产生 Enter；补充参数后只提交一次。
- [ ] Claude Code 参数型命令有对应回归；无参命令仍正常执行，切换 pane 后旧面板不能向新目标发命令。

**入口：** `CtrlxCommon/Models/AgentCommandMenu.swift`、
`CtrlxServerFeature/Views/TerminalQuickActionButtons.swift`、
`CtrlxFeature/Views/TerminalAgentCommandButton.swift`。
更新 [快捷操作契约](terminal-quick-actions.md)，扩展 `AgentCommandMenuTests` 和两端交互测试。

## 3. Mac 启动提示 CtrlX Agent 插件更新，并支持重新安装

**目标：** 启动 Mac CtrlX 时提示安装到 Codex / Claude Code 中的 CtrlX 插件有新版本；设置页提供“重新安装”，成功后提示重启对应 Agent 会话。

**边界：** 此处指 `plugin/codex/ctrlx` 与 `plugin/ctrlx` 提供的 Agent 侧插件，
不是更新 Codex / Claude Code CLI，也不是现有 CtrlX sidecar 插件包更新提示。

- [x] 明确目标版本来源和兼容范围，比较实际安装版本；复用现有安装状态查询及 CLI 安装器，不另做一套插件管理系统。（以当前 App 携带的 Agent 插件 manifest 为准）
- [x] Mac 启动后异步检查本机已启用 Agent 的默认及附加配置目录；不阻塞主窗口，不操作远端 Host 的安装。
- [x] 有更新时显示轻量提示，可跳转对应 Agent 的设置页；同一轮启动去重，检查失败或版本未知不误报“已是最新”。
- [x] 设置页显示安装状态、已安装版本和可用目标版本；已安装时也能点击“重新安装”，不要求用户先手动卸载。
- [x] 核实两种 CLI 的更新 / 强制重装语义；不能把普通安装返回 `alreadyInstalled` 当作已完成重装。（隔离配置目录验证 Codex 0.162.1 / Claude Code 2.1.276）
- [x] 操作期间禁用重复点击并显示进度；失败明确提示原因，不静默破坏原有可用安装；成功后重新查询安装状态。
- [x] 成功提示“请重启对应的 Codex / Claude Code 会话以加载新版 CtrlX 插件”；不自动退出 Agent、关闭 tmux Window 或重启 CtrlX。
- [x] 保留用户的其他插件、配置和登录信息；多个配置目录分别显示状态并明确本次安装目标。

**验收：**

- [x] 两种 Agent 分别覆盖旧版、最新版、未安装、版本未知、CLI 缺失和检查失败。（完整状态矩阵由参数化单元测试覆盖；原生 UI 已核对旧版 / 最新版、Claude 未安装 / CLI 缺失 / 查询失败）
- [x] 同版本重新安装与升级都实际执行并复核结果；失败可重试，成功有会话重启提示。（隔离完整 Mac App、两种真实 CLI、临时配置目录验收）
- [x] 启动检查不阻塞终端使用，提示不重复刷出，不中断正在执行的任务。（提示期间可输入；切换设置后提示逐项消失，测试 pane 进程不变）

**入口：** `CtrlxServerFeature/Views/AgentsSettingsView.swift`、
`Coordinators/AppCoordinator.swift`、`CodexPluginCore/CodexCLIInstaller.swift`、
`ClaudeCodePluginCore/ClaudeCodeCLIInstaller.swift`。
先区分现有 sidecar 更新提示与 Agent CLI 插件安装状态，再扩展对应安装器测试。

## 4. 文件浏览器播放缓存审计与自动清理

**目标：** 明确断点 / 拖动续播是否产生端侧缓存，确保缓存有界且自动清理；覆盖 Mac Host、Mac Viewer 和 iOS。

**已从基线代码核实的现状（不是运行时内存验收；清理机制的新增实现见下方勾选项）：**

- Mac Host 直接用本地文件 URL 播放，不经远程分块下载链路。
- Mac Viewer / iOS 的远程视频每个预览有最多 8 MiB 的 LRU 内存分块缓存；播放器停止时清空，应用没有为该流式链路建立完整的持久视频副本。
- AVFoundation 自身还有播放缓冲；8 MiB 不是播放器总内存上限，不能据此断言系统绝无其他缓存。
- “下载并打开”及使用下载副本的预览会写入应用的 `Caches/CtrlX/FileBrowserDownloads`。当前在新下载开始时清理超过 24 小时的旧副本，跳过活跃下载；不完整下载会丢弃。
- 因此已有基础清理机制，但没有后续下载时，当前代码不会仅因过了 24 小时就主动执行这次清理。

- [x] 分开核查流式播放内存、完整下载 / 外部打开副本，以及播放进度元数据；不要把拖动续播等同于持久断点下载。（当前播放位置仅由 AVPlayer 持有，没有应用侧持久进度记录；系统自身缓冲不由 CtrlX 清理）
- [ ] 验证切换文件、关闭预览、断连和异常退出后的资源释放；多预览同时使用时分别核对资源所有权，不影响仍在播放的窗口。
- [x] 复用下载缓存服务，补充应用启动后的异步过期清理；如需前台恢复时检查，应节流，不在每次滚动、播放或终端输入时扫描目录。（启动 / 恢复前台，进程内一小时节流）
- [x] 明确并测试磁盘缓存总量和低磁盘空间策略，避免 24 小时内的大量下载无限累积；没有可安全清理的副本时明确拒绝新下载。（总量 2 GiB，计入在途预留；磁盘余量至少保留 256 MiB）
- [x] 保护活跃下载、内嵌预览和外部 App 使用所需的副本生命周期；不能播放中删除，不能承诺外部 App 可永久使用临时缓存路径。（独立租约保护；最后一个预览释放后重新计算 24 小时保留期）
- [x] 只清理 CtrlX 拥有的缓存目录，不删除 Host 原文件、用户主动保存的文件或其他 App 的缓存；后台执行，失败可记录并重试。
- [x] 首版不新增离线视频缓存、播放进度跨端同步或独立“缓存管理”设置页；保持播放逻辑简单。

**验收：**

- [ ] 实测三端长视频、反复 seek、暂停 / 恢复和关闭后的内存及磁盘占用，区分应用缓存与系统缓冲。
- [x] 用可控时间测试过期副本、启动清理、异常遗留文件、总量限制、低空间和正在使用的副本。
- [x] 超过保留期后，即使不再发起新下载，也能在下一次启动 / 已定义的维护时机清理；清理在缓存 actor 执行，不扫描或删除 Host 原文件。（完整隔离 Mac App 启动验收通过）

**入口：** `CtrlxCommon/Models/FileBrowserVideoReader.swift`、`FileBrowserVideoPlayback.swift`、
`CtrlxCommon/Services/FileBrowserDownloadClient.swift`。
更新 [文件浏览器契约](file-browser.md)，扩展 `FileBrowserVideoTests`、`FileBrowserTransferTests` 和相关预览测试。

## 完成记录

每项完成后再勾选，并补充提交号、实际测试平台和结果。编译通过、原生交互验证、
真机 / 双屏验收与发布分别记录；未执行的验收不能标为通过。

### 2026-10-12：快捷命令与缓存第一轮验证（未提交）

- 定向单元测试：`FileBrowserCacheTests`、`FileBrowserTransferTests`、
  `FileBrowserVideoTests`、`FileBrowserOfficeDocumentTests`、`AgentCommandMenuTests`、
  `MacAgentCommandPresentationTests`、`TerminalQuickActionRouterTests`，共 82 项通过。
- 视频测试在本机 macOS 执行了 AVFoundation 首帧及 seek 回归；这不等于三端长视频资源占用验收。
- iOS：`Ctrlx` Debug、generic iOS device SDK、关闭签名的编译通过；没有启动模拟器、安装或执行真机测试。
- 品牌边界、技术边界与 `git diff --check` 第一轮通过。
- 尚未完成：独立窗口实现；插件检查 / 重装仍在实现验证中；三端交互与双屏验收仍保留未勾选。

### 2026-10-12：插件安装检查与合并回归（未提交）

- 在既有安装器上增加本地可选能力 `AgentPluginMaintenance`；无 sidecar RPC 或 Relay 变更。
- Codex 的 `plugin add` 已用隔离临时配置目录验证同版本缺失 hook 修复及版本升级；不先卸载。
- Claude Code 已用隔离临时配置目录验证 `uninstall --scope user --keep-data` 后安装能补回同版本缺失的 skill；没有操作用户安装。
- 合并定向回归 140 项通过：前述命令 / 缓存 / 播放测试，加上两种安装器、版本资源、启动去重、多目录、失败重试及重入保护测试。
- 品牌边界、技术边界和 `git diff --check` 再次通过；新文件已格式化。全量“已修改 Swift 文件”格式检查仍报告原有大型视图格式问题及 `MainView.swift` 的格式器解析问题，未为清零检查而重排无关代码。
- Mac：先构建原生 Browser 依赖，再完成 `CtrlxServer` Debug / arm64 / macOS 的 App 编译检查，结果通过（关闭 App 签名，未安装）。原生设置界面验收仍未记录为通过。
- iOS：加入插件共用代码后的最新版本再次通过 `Ctrlx` Debug / arm64 / generic iOS device SDK 编译（关闭签名；未使用模拟器、未安装）。新增 10 个 Swift 文件的格式检查通过。
- 独立窗口功能仍待实现，未安装、提交或发布。

### 2026-10-12：独立窗口实现与原生 Local 验证（未提交）

- 新增 `DetachedTerminalScene` 和 `DetachedTerminalWindows`，Mac Local / Viewer 使用相同的 Host + 稳定 Window ID 所有权；每个原生窗口有自己的输入路由。
- 拖动沿用现有 `TabDragPayload`。隔离原生视图的实际 AppKit 事件测试覆盖：窗外释放建立独立展示、栏内有效放下不脱离、Esc 取消、普通点击。
- 隔离签名 App 使用单独 bundle ID、tmux / API socket、内存偏好及临时状态目录。已核对 Local 单 pane / 双 pane 的菜单脱离、从主标签聚焦已有窗口、Cmd-W 关闭和“返回主窗口”后原会话仍在。
- 测试输入只出现在目标 pane；独立窗口打开 Files 使用自身 pane 的目录。双 pane Fit 后仍有两个 pane，另一 Window 的 `200×50` 尺寸不变。没有向用户会话发送测试输入。
- 补充独立窗口状态栏隐藏时的工具栏快捷入口，避免状态栏可见时重复显示按钮；E2E 下载缓存根目录也与用户缓存隔离。
- 最新合并定向回归 **149 项通过**，包括原生窗口关闭、Host 身份隔离、输入路由、命令发送、插件安装器和缓存 / 播放测试；不是未过滤全量测试。
- 最新 Mac `CtrlxServer` Debug / arm64 和 iOS `Ctrlx` Debug / generic device SDK 编译均通过（关闭签名；iOS 未使用模拟器）。新增 / 本轮修改的六个 Swift 核心文件格式检查、品牌 / 技术边界检查和 `git diff --check` 通过。
- 完整 App 的真实拖出手势、双屏 / 不同缩放比例、Viewer 断线重连、Agent 交互及 iPhone 仍未记录为通过。测试会话和隔离 App 已关闭；本机安装、用户插件和运行中会话未替换。
- 隔离 App 副本已移至废纸篓，保留编译产物及测试日志；继续真实安装验收需另行确认。不提交、不发布。

### 2026-10-12：完整 App 拖出回归用例（未提交；交互验收未通过）

- 新增 `Detached Terminal Window` 与 `Detached Terminal Window Mac Viewer` 两个 macOS-only E2E 场景：以真实标签位置拖出、检查独立窗口、核对输入仅进入目标 pane，并在关闭后比较原 tmux Window ID。
- 用例使用独立 API socket；该隔离通过 `isolated-api` 标签显式启用，不改变仍使用固定 socket 的旧 CLI 测试。
- `CtrlxE2E` Debug / arm64 编译通过。Local 场景的两次运行均在执行拖动前失败：旧菜单自动化调用超时；直接查找窗口也超时。Computer Use 同时能读到隔离 App 的 `CtrlX` 窗口与测试会话，说明当前 E2E 进程的 UI 访问存在环境阻碍，不能把这两次失败算作产品拖动已验证或已确认失效。
- Viewer 场景尚未执行；没有启动 iOS 模拟器。两次失败运行均清理了各自的测试 App 进程和私有 tmux 会话，未修改系统自动化权限。
- 尚需在可访问 UI 的测试环境中运行上述场景，并完成前文列出的真机 / 双屏等验收；这些项目仍保持未勾选。

### 2026-10-12：插件多目标隔离回归（未提交）

- 补充 Codex / Claude Code 共用安装状态的参数化测试，以及两种 Agent、多配置目录之间的检查、提示关闭、重装与会话重启提示隔离测试。
- `./scripts/unit-tests.sh -- --no-parallel --filter 'AgentPluginInstallationsTests|AgentPluginResourceTests|AgentsSettingsSupportTests'`：14 项测试通过；未调用用户的 Agent CLI 或修改个人插件安装。
- 原生设置行的进程内 UI 探针无法取得 SwiftUI 辅助功能子节点；最小 Text / Button 对照窗口也出现相同情况。已移除依赖这一不可用测试入口的实验用例，没有将其改成宽松断言或记作 UI 验收通过。
- 本轮仅补充测试与记录，未改动产品代码。完整设置页交互、双屏、Viewer 重连和 iPhone 验收仍待完成；现有 Mac / iOS 编译及上一轮定向回归结果不代替这些验收。

### 2026-10-12：同屏隔离 Host / Viewer 验收与拖动命中修复（未提交）

- Mac Release 签名编译和 DMG 校验通过。早先按测试安装授权覆盖过一次本机 App，
  原 3.0.59 完整备份在 `/tmp/ctrlx-macinput-install.pniUcA`；随后用户明确只允许隔离启动，
  此后未再替换或重启本机正常 App。没有发布。
- 自测副本使用独立 bundle ID、私有 tmux / API socket、临时状态和 Browser 目录；
  测试 Relay 仅监听 `127.0.0.1:19766`，未改动生产 Relay、个人插件安装或用户任务。
- 完整 App 诊断发现 SwiftUI 宿主的 `visibleRect` 可大于单个标签：点击一个标签时，
  相邻标签也记录了按下。拖动起点改为 `bounds ∩ visibleRect`，增加超界和裁剪回归；
  临时诊断日志已从源码移除。独立窗口 / 输入路由 21 项定向测试通过。
- Local / Viewer 均从测试标签拖出正确的 `DETACHED_SOURCE`。Computer Use 的单次快速拖动
  未可靠结束原生拖动，采用“越过阈值 → 继续移到窗外”的分段事件完成验证；
  这不替代用户日常手势的手感验收。
- Viewer 主窗口和独立窗口的输入分别只进入 `%1` 和 `%0`；增加 pane 后，
  `%4` 的输入没有进入其他 pane。Fit 将目标 `@0` 调整为 `130×40`、保留两个 pane，
  另一 Window `@1` 仍是 `120×40`。Host 断开时独立窗口显示等待；重连后原目标恢复可输入。
  独立窗口原生全屏、Cmd-W 关闭、从主入口重复聚焦均验证，tmux Window ID 未改变。
- 用隔离 ingress 的 Codex / Claude 会话夹具和 `cat` 终端检查实际发送行为：
  Local Codex、Viewer 独立窗口 Codex、Local Claude 的 `/goal ` 均没有 Enter，
  面板关闭并恢复终端焦点；已有 `EXISTING_DRAFT ` 未被清空。
  补参数后显式回车提交；Claude `/status` 仍自动回车。
  这是实际 UI / 输入通路测试，不是启动真实 Agent 执行任务；iPhone 尚未测试。
- 完整 Mac App 启动时，未触发下载也自动删除了临时缓存根内的过期 UUID 目录；
  近期 UUID 副本和不归服务管理的非 UUID 目录均保留。未触碰真实缓存或 Host 文件。
- 正常 App 设置页只读核对：Codex 显示已安装 / 随包 `1.1.1`；Claude 显示已安装 `1.3.3`、
  随包 `1.3.2`。两者均有 Reinstall 入口；没有执行个人配置目录重装。
- 新增命中回归及源文件 SwiftFormat 检查、品牌 / 技术边界和 `git diff --check` 通过。
  本轮隔离 Host / Viewer 已正常退出，私有 Relay 和测试 tmux 服务已停止；保留测试日志及原 App 备份。
  剩余未勾选项保留：独立窗口真实语音 / Questions 等交互、完整插件提示 / 重装 UI、
  长视频资源占用，以及用户延期的 iPhone / 双屏验收。

### 2026-10-12：隔离插件维护 UI 与 Questions 补充验收（未提交）

- 在独立 bundle ID、私有 tmux / API socket、临时状态目录中启动完整签名 App。
  `CODEX_HOME` 和 `CLAUDE_CONFIG_DIR` 仅对测试进程指向临时目录；没有改动个人插件。
  普通 E2E 会跳过启动版本检查，因此测试构建临时单独放行了该检查；验证后已从源码撤掉，
  诊断 DMG 移出 `dist`，另行重建不含测试入口的正常产物。未再次覆盖或重启本机安装版。
- 两种真实 CLI 均先安装测试旧版 `0.9.0`。启动提示分别定位 Claude / Codex 设置；
  Claude 升到随包 `1.3.2`，Codex 升到随包 `1.1.1`。两种 Agent 同版本重装均实际补回
  刻意移走的 skill / hook 文件，内容与备份一致；成功后显示重启对应 Agent 会话的提醒。
- Codex 来源不一致时明确失败，旧版仍保留；仅对临时配置用 CLI 对齐来源后，UI 重试成功。
  Claude CLI 缺失时禁用重装，查询 / 重装失败后恢复命令可重试；卸载后显示 Install，
  再次安装成功。所有操作期间私有终端 `cat` 的 PID 不变，提示显示期间输入正常。
- 实测发现无 stderr 的 CLI 查询失败会显示空的 `Check failed:`；两种安装器现在给出
  CLI 名称和退出码，空白 stderr 亦覆盖。插件安装器 / 安装状态 / 资源 / 语音目标相关
  **59 项定向测试通过**；不是未过滤全量测试。
- 用本地编译的假 Codex TUI 在独立 Window 显示 Questions footer；此前输入记录为零，
  独立窗口获得焦点后仅收到一次 `ESC [ 1 ; 2 D`（Shift-Left），显示展开结果。
  其他测试 pane 没收到输入。该测试验证实际 tmux / SwiftTerm / 原生窗口通路，
  不代表真实 Agent 服务、Viewer Questions 或语音录音的完整验收。
- Mac Local 用两分钟、约 18 MiB 的合成 MP4 实测播放、暂停和跳到尾部；播放期间仅打开
  Host 原文件，关闭 Files 后该文件句柄释放，未生成下载缓存目录。
  App RSS 样本约 355 → 375 → 368 MiB，未把未立即归还的系统内存当作应用缓存泄漏或清空证明。
  这不是三端长时间 / 多预览 / 反复 seek 压力验收，该项继续保留未勾选。
- 隔离测试 App 已正常退出（退出码 0），私有 tmux 已停止；临时测试数据和日志保留以供复核。
  品牌边界、技术边界及 `git diff --check` 通过；没有提交、推送或发布。
- 撤除临时入口后，正常源代码的 Mac Release 签名构建及 DMG 校验通过，
  构建标识 `20261012-122312`；只生成本地测试产物，没有安装或发布。
- 新增双视频资源所有权回归：两个原生 AVFoundation 解码器各自建立缓存，关闭一个后
  只清空自己的缓存，另一个仍能 seek / 解码，最后关闭才清空第二份缓存。
  `FileBrowserVideoTests|FileBrowserCacheTests` **31 项测试通过**；新测试范围的格式检查通过，
  未顺手重排该文件原有格式。此结果不替代三端真实连接的长期内存验收。

### 2026-10-12：隔离 Viewer Questions 与视频生命周期补充验收（未提交）

- 使用正常 Release 产物的两份签名副本，分别设置独立 bundle ID、临时状态目录、
  私有 tmux / API socket；仅通过本机 `127.0.0.1:19776` 的私有 Relay 配对。
  测试日志保留于 `/tmp/ctrlx-viewer-accept.5otUow`，未替换或重启本机安装版。
- Viewer 将假 Codex TUI 的 QUESTIONS 标签打开为独立窗口后，目标 `%1` 仅收到一次
  `ESC [ 1 ; 2 D` 并显示展开结果；主窗口 `%0` 没收到输入。
  独立窗口的 Open Files 在主窗口打开了该 pane 的测试目录。
  这是实际加密 Viewer / Host / tmux / SwiftTerm 通路验证，不代表真实 Agent 服务验收。
- Mac Viewer 通过 Play Video 播放两分钟、约 18 MiB 的合成 MP4，验证暂停、恢复、
  播放到结尾和从头重播。未使用 Download and Open；Viewer 未持有 Host 视频的本地文件句柄，
  测试状态目录没有生成文件下载缓存。
- Host 断开后视频预览退出，Viewer 显示 Host offline；重连后恢复 Files 和所选文件，
  回到 Play Video，不自动续播。关闭 Files 后正常显示原终端。
  Viewer RSS 样本约 341 MiB（打开 Files）→ 403 MiB（播放后）→ 361 MiB（断连后）；
  这是进程快照，不是应用缓存精确计量，也不足以证明长期内存稳定。
- 进度条的 AX 设置及鼠标自动化未能可靠触发 seek，因此未把本轮 UI seek 记作通过，
  也未仅凭自动化无效将其定为产品缺陷。三端长时间 / 多预览压力验收仍保留未勾选。
- 两份隔离 App 均正常退出（退出码 0），私有 tmux 和 Relay 已停止；
  本机正常 App PID 未变。本轮仅更新验收记录，`git diff --check` 通过，未提交或发布。

### 2026-10-12：原生长视频反复 seek 回归（未提交）

- 新增 `FileBrowserVideoLifecycleTests`，由仓库样例临时合成超过 100 秒、
  大于 8 MiB 缓存容量的 MP4；不依赖网络、用户文件或本机安装版 App。
  原生 AVPlayer 在完整文件到齐前开始播放，依次跳转 80 / 10 / 95 / 25 / 70 / 5 秒。
  首次远距离跳转确认产生新分块读取，避免测试仅命中已有播放缓冲。
- 每次暂停后不继续读取；未缓冲位置在显式恢复后正常播放，符合既有契约。
  最后关闭播放器后 currentItem 释放，读取计数不再增加；临时合成文件自动删除。
  未发现需要修改播放策略的问题。本测试不验证 AVKit 进度条手势，也不代表真实网络 / iPhone 验收。
- `FileBrowserVideoLifecycleTests|FileBrowserVideoTests|FileBrowserCacheTests`：
  **32 项测试通过**。新增测试的 SwiftFormat、品牌 / 技术边界及 `git diff --check` 通过。
  本轮无产品代码变更，不需要重建 App，未安装、提交或发布。

### 2026-10-12：独立窗口 Local / Viewer Fork 路由验收（未提交）

- 使用签名隔离 Host / Viewer、私有 tmux、临时插件设置和本机 Relay。
  Codex 命令替换为本地编译的参数记录程序，历史目录只放测试 UUID；
  不调用真实模型、不消费 Agent 额度，不修改个人插件或真实 tmux 会话。
- Local：从 `source:1` 拖离后的独立窗口打开 Fork，主窗口此前已切换到 `other`。
  Fork 面板显示源目录；确认后在 `source` 创建 `DETACHED_FORK`。
  实际子进程收到测试会话 ID、正确的 `-C` 和临时 `CODEX_HOME`。
- Viewer：独立展示同一源 Window，主窗口切换到远程 `other` 后再次从独立窗口 Fork，
  通过私有 Relay 在原 Host 的 `source` 创建 `VIEWER_DETACHED_FORK`。
  两次启动参数一致；`other` 仍只有原窗口，源 `%0` 输出不变，`other` 的 `%1` 保持空白。
- 该验收覆盖真实 UI → 捕获目标 → Local / 加密 Viewer 命令 → Host → 新 tmux Window，
  不等同于真实 Codex / Claude 服务读取并续接会话历史，也不替代真实语音或 iPhone 验收。
  证据保留在 `/tmp/ctrlx-fork-routing.sTNJ3a/fork-launch.log` 和该目录的 App 日志中。
- 两份隔离 App 正常退出（退出码 0），私有 tmux 和 Relay 已停止；本机安装版仍运行，
  未覆盖或重启。本轮仅补充验收记录，`git diff --check` 通过，未提交、推送或发布。

### 2026-10-12：合入本地 main

- 合并本地 `main` 的 `5b14d79`，合并提交为 `3d9f65a`；仅操作 `macinput` 工作区。
  原有 53 个未提交文件已恢复，四项功能修改仍未提交，合并前 stash 备份保留。
- 冲突处理保留独立的数据流和两边的 UI 入口，并补齐 Viewer 新建浏览器的按需启动路径。
  合并本身 56 项定向测试通过，恢复功能修改后 113 项定向测试通过；品牌 / 技术边界和
  `git diff --check` 通过。SwiftFormat 整文件检查仍有既有告警及 MainView 解析错误，
  原 HEAD 可复现，未做无关全文件重排。
- 该合并轮次未构建安装新 App、未推送或发布。本地 main 不包含已安装 3.0.60 发布提交 `c572379`；
  用户随后明确不以该版本为安装阻碍，授权提交并按当前分支源码覆盖安装，不额外合并发布线。

### 2026-10-13：拖出范围与独立窗口交互收敛（未提交）

- 标签脱离以源标签栏为边界，保留 24 pt 容差；允许松手在主窗口内部，
  不再要求跨过整个原生窗口。已接受的排序 / 分栏 drop、Escape 和小幅移动不触发脱离。
  记录拖拽期间的松手位置，避免 AppKit 延迟结束时把后续 mouseMoved 当作取消或落点。
- 主窗口与独立窗口共享 Fit 按钮及终端标签外观；独立窗口移除 `Window` 工具栏菜单，
  改为单标签右键菜单承载 Files / Fork / 返回主窗口。Fit 仅测量标签栏下方终端区域。
- `DetachedTerminalWindowsTests|TerminalQuickActionRouterTests|TabStripOrderTests`：
  **38 项测试通过**；Mac Release 构建、签名和 DMG 校验通过。
  六个独立修改文件的 SwiftFormat、品牌 / 技术边界及 `git diff --check` 通过；
  MainView 的既有解析错误及 RemoteWindowTabBar 的既有格式告警未做无关整理。
- 签名隔离 App、私有 tmux 的 Local 会话验证：标签拖入主窗口终端区域后脱离；
  独立窗口仅显示同款 Fit 图标和单标签，右键菜单内容正确。
  Fit 将目标 `@0` 从 100×30 调到 130×38，`@1` 保持 120×40；
  返回主窗口后仍为原有 `@0/%0`、`@1/%1`，测试进程未重启。
- 自动化快速拖拽需后续鼠标事件完成 AppKit 的结束回调，隔离探针与完整 App 均核对了
  此时使用实际松手位置。真实连续手势体验、远程 Viewer 本轮未重跑；不以此替代双屏验收。
  隔离 App 已正常退出、私有 tmux 已停止；未覆盖安装、重启本机正常 App，未提交、推送或发布。
- 后续 Accepted 项修复：松手坐标改用事件的 `locationInWindow`，按事件所属窗口转换；
  无窗口事件直接保留屏幕坐标，不再读取处理时刻的全局指针位置。新增栏内 / 栏外释放与
  无窗口负坐标回归，先确认旧实现失败，再确认 **40 项定向测试通过**。
  本轮两个 Swift 文件的格式、品牌 / 技术边界及差异检查通过，未重建完整 App 或重跑 UI 验收。

### 2026-10-13：再次合入本地 main

- 将本地 `main` 的 `823a6ce` 合入 `macinput`；此前拖出范围、独立窗口工具栏及松手坐标修复
  已提交为 `0432d37`，本次保留这些行为，不修改主工作区。
- 浏览器统一使用 main 的按 pane 打开 / 复用流程；独立窗口网页链接携带原始 pane ID
  回到主窗口路由，不使用主窗口当前焦点。去除自动合并产生的重复测试方法，更新旧 Viewer
  启动测试的来源 pane 与复用断言。
- Mac 包编译及 14 个 suite 的 **149 项定向测试通过**，覆盖独立窗口、输入路由、标签排序、
  浏览器启动 / 控制、退出清理、插件安装状态、文件标注 / 视频 / 缓存与相关协议。
  品牌 / 技术边界和差异检查通过。三个独立窗口修改文件的格式检查通过；其他既有文件的
  整文件格式告警及 MainView 格式器解析错误未做无关重排，MainView 原 main 基线同样报错。
- 未重建完整 App、重跑原生 UI / iPhone 验收、安装、推送或发布。

### 2026-10-13：独立窗口多标签增量（未提交）

- 独立 Scene 直接复用主工作区视图，复用 Files、Browser、Fork、创建 Agent / Terminal、
  快捷命令和 Fit；新标签留在发起操作的窗口，Fork 不再跳回主窗口。
- 新增带来源窗口、Host 和 Session 的拖放数据；同范围可互移终端、目录 / 文件和网络
  浏览器标签。各窗口独立选择和排序，快捷键只遍历自己的终端；拖动不更换浏览器的 Agent 所有权。
- 关闭独立原生窗口将其标签及活跃浏览器状态归还主窗口，不关闭 tmux Window 或 CEF 页面。
- 定向回归 116 项通过，覆盖 Host / Session 隔离、过期拖动、双向移入移出、目录 / WebKit
  状态保留、CEF 同页改挂载与归还、只剩 Files 时再创建终端、分组排序、快捷键导航及拖出后的分屏清理。
- 完整隔离 Mac App 已验证：菜单拖出入口、多终端标签、新建 Terminal 留在独立窗口、
  Open Files 并预览隔离文件、Open Browser 留在独立窗口，及关闭独立窗口后在主窗口继续
  查看原 Chromium 页面。首次测试副本名称不符合 CEF helper 路径要求，改回隔离目录内
  的 `CtrlX.app` 后浏览器验证通过；没有覆盖或操作生产 App。
- 自动化鼠标拖动未得到可靠的界面状态变化，不能将跨窗口原生拖拽标记为通过；仍需手动
  验收拖入 / 拖回 / 调序、Mac Viewer 真实连接和真实 Agent Fork。旧版结果不替代本轮验收。
- 既有拖出 E2E 场景同步到会话标题和归还后的标签选择，不再等待已移除的 `Return Here`
  占位入口；没有执行该完整场景，不将脚本更新当成验收通过。
- 最新 Mac Release 构建与本地签名校验通过，仅生成工作区内 App，没有安装。
- 品牌 / 技术边界和差异检查通过；格式化新增文件及修改范围，不对 MainView 既有整文件
  格式告警做无关重排。未安装、提交、推送或发布。

### 2026-10-13：独立窗口选择与 Files-only 状态审查修复（未提交）

- 左侧终端回退统一排除其他原生窗口拥有的终端和右侧标签；重新进入会话、移入分屏、
  关闭标签及 Cmd-W 均遵守窗口归属，不再重复显示右侧终端或误关主窗口终端。
- 独立窗口持有 Session 上下文，不再依赖存活的已选终端；最后一个终端退出后保留
  Files / Browser 标签栏和新建入口，新建终端、同会话标签移入仍归属原独立窗口。
  无左侧终端时按标签顺序选中剩余私有标签，Fit 的测量目标允许仅有右侧终端。
- 新增选择、分屏、终端退出后上下文、私有标签回退和同 Host / Session 迁移回归；
  最新源码 **123 项定向测试通过**，Mac Release 构建和本地签名校验通过。
- 最终签名隔离 App、私有 tmux 验证：A 在左、B 在右、C 留在左栏时，菜单移出 A 后
  返回主窗口正确显示左 C / 右 B；独立窗口分屏只回退本窗口终端，Cmd-W 后主窗口
  B / C 均仍存活；最后一个终端执行 `exit` 后仍可预览 `notes.txt`，从“+”新建终端
  仍留在原独立窗口。测试未触碰安装版或真实会话。
- 本轮没有重跑跨窗口鼠标拖拽、Mac Viewer 真实连接或真实 Agent Fork；菜单移出
  和迁移单元测试不代替这些完整交互验收。MainView 整文件 SwiftFormat 的基线解析
  错误仍存在，未作无关全文件重排；新增模型 / 测试、品牌 / 技术边界及差异检查通过。
- 隔离 App 已正常退出，私有 tmux 已停止。未提交、推送、覆盖安装或发布。

### 2026-10-13：独立窗口焦点与无左侧终端审查修复（未提交）

- 标签切换、搜索和会话菜单使用 Scene 聚焦动作，不再广播给所有 MainView；
  独立窗口禁用会话切换 / 新建会话，避免跨出其固定的 Host / Session。
- Fit 按实际可见终端收集调整请求，不再要求左侧选中终端；标签快捷键使用 Session
  上下文，在仅剩 Files / Browser 时继续工作，并排除右侧标签。
- Viewer 的 Host 浏览器目录移除当前标签时，无论是否折叠分屏，都按现有顺序回退到
  剩余左侧标签；保留有效选择，不选中右侧标签。新增回归先确认旧实现失败，再通过。
- **131 项定向测试通过**，Mac Release 构建和签名校验通过。签名隔离 App、私有 tmux
  验证：主窗口 / 独立窗口双向操作快捷键均不影响另一窗口；左 Files、右终端时 Fit
  将目标从 120×40 调到 80×38，主窗口另外两个终端保持 120×40；最后一个终端退出后，
  两个不同目录的 Files 标签仍可用上一 / 下一标签快捷键双向切换。
- Viewer 关闭浏览器后的回退本轮由模型回归覆盖，未重跑真实远程连接；也未重跑跨窗口
  原生拖拽或真实 Agent Fork。修改范围格式、品牌 / 技术边界和差异检查通过；既有
  MainView 整文件格式器解析错误及其他既有格式告警未做无关整理。
- 隔离 App 正常退出（退出码 0），私有 tmux 已停止。未提交、推送、覆盖安装或发布。

### 2026-10-13：Files-only 的 Git、搜索与 Viewer 关闭审查修复（未提交）

- Git 目录统一解析为左侧终端 cwd、选中 Files 的当前目录、现有 Git store 目录、Home；
  点击和快捷键共用解析器，清空 Files 选择不再把项目目录退回 Home。普通文件预览也使用
  自己的目录，目录标签则读取当前浏览路径，不使用创建时的空占位值。
- Viewer 本地 WebKit 浏览器关闭后才统一修复选择，保留父标签 / 来源终端优先规则，
  不再清掉刚恢复的剩余浏览器；返回左侧父浏览器时同时清除旧 Files 选择。
- 本地 / 远程 Find in Files 先复用当前目录标签；仅新建 Files 时要求存在源终端。
  新增目录保留、目录变化、文件预览目录、Local / Viewer 搜索复用及创建分支回归。
- **47 项定向测试通过**，Mac Release 构建及签名验证通过；修改模型和测试的 SwiftFormat、
  品牌 / 技术边界、`git diff --check` 通过，未重排 MainView 的既有格式问题。
- 签名隔离 App、私有 tmux 实测：终端退出后 ⌘⇧F 切到 Text 搜索并聚焦，`needle` 返回
  隔离项目文件；点击 Git 和快捷键进入 Git 后，Show in File Explorer 均打开原项目的
  `src`，未回退 Home。Git 使用 E2E provider，验证的是目录路由，不是真实仓库查询。
- 本轮没有重跑 Viewer 本地浏览器关闭和远程搜索的真实连接 UI 验收；现有 Host 目录同步
  回归不代替 Viewer 本地关闭路径。隔离 App 正常退出、私有 tmux 停止；未覆盖安装、
  提交、推送或发布。

### 2026-10-13：Files-only 重命名与 Git 刷新选择修复（未提交）

- 重命名同步迁移工作区标签及保留的会话名称，不再要求存在选中终端；Viewer 上下文迁移
  还会核对 Host ID。重复迁移保持幂等，终端退出或全部移走后仍能解析新会话名称。
- Git 选择移入每个工作区的 `SessionFileTabsState`，移除终端 ID / 空字符串键和对应的
  重排、清理逻辑。刷新保留有效 Git 选择；显式选择左侧 Terminal / Files / Browser 才退出
  Git，右侧选择不影响左侧。浏览器延迟打开的选择快照同步读取该状态。
- **79 项定向测试通过**：`WorkbenchContentContextTests`、`WorkspaceTerminalSelectionTests`、
  `DetachedTerminalWindowsTests`、`RemoteBrowserTabSelectionTests`、`TerminalWindowNavigationTests`、
  `SessionRenameTests`、`PaneBrowserOpeningTests`。新回归覆盖无终端重命名、Host 隔离、重复迁移、
  Git 刷新保留、显式切换及无终端浏览器请求的选择快照。
- 最新源码 Mac Release 构建、签名验证通过；一次 CLI 签名因时间戳服务不可用失败，重试成功。
  新增模型 / 测试及本轮修改的 FileBrowserView 区域格式检查、品牌 / 技术边界、diff 检查通过；
  MainView 既有格式器解析问题和其他旧格式差异未作无关重排。
- 签名隔离 App + 私有 tmux 实测：独立窗口最后一个自有终端退出后重命名，标题更新，Files
  保持当前目录并能打开原文件；Git History 经其他终端标题、cwd、活动窗口变化及手动刷新后
  保留；仅右侧有终端的分屏也保持左侧 Git。New Terminal 从 Git 正常切到新终端。
  Git 使用 E2E provider，本轮验证选择状态，不代表真实 Git 查询验收。
- 隔离 App 正常退出、私有 tmux 停止；未跑全量测试、真实 Viewer 连接或 iPhone 验证。
  未覆盖安装、提交、推送或发布。

### 2026-10-13：右侧文件链接、Viewer 重命名与 Git 分屏移动修复（未提交）

- 文件链接解析前后均改为校验当前会话与来源终端的工作区归属，不要求左侧仍有终端；
  来源 pane、Agent 上下文及待处理请求的过期校验保留。
- 每个 Mac Viewer Scene 根据 Host 快照中的 pane / session / window 结构推断重命名，
  先迁移自己的选择与标签再清理旧状态，移除仅在发起命令的主窗口执行迁移的路径。
  复用完整 pane 集合匹配规则，隔离 Host；标题、cwd、尺寸与 Agent 状态刷新不触发迁移。
- Git 分屏移动复用已有 store，缺少 store 才走统一目录解析，删除空 window ID → Home
  的旧目录函数。
- 最新源码 **82 项 / 8 个 suite 定向测试通过**，覆盖上轮七个 suite 与新增
  `RemoteSessionStructureTests`。新测试使用真实 `SessionStore` 更新与多个挂载的
  SwiftUI 视图验证快照传播、先迁移后清理、Files-only、Host 隔离、元数据刷新、断开和局部移动。
- Mac Release 构建、签名验证、品牌 / 技术边界、`git diff --check` 通过；本轮模型、
  modifier 和测试格式检查通过。MainView 仍有既有 SwiftFormat `redundantSelf` 解析错误，
  未为此重排整个文件。
- 签名隔离 App + 私有 tmux 验证：左侧 Files、右侧唯一终端时，点击显式文件标记成功
  打开真实 `notes.txt` 并显示内容；Git 右移再左移后，Show in File Explorer 仍打开原项目
  的 `src`。Agent 上下文来自隔离 ingress 夹具，Git 为 E2E provider，不代表真实 Agent
  生命周期或 Git 查询验收。后续源码仅前移远程快照观察器的执行顺序，不改变上述 Local 路径；
  该最终源码另行完成全部定向测试与构建。
- 隔离 App 正常退出、私有 tmux 已停止。未跑全量测试、真实 Host / Viewer 连接或 iPhone
  验证；未覆盖安装、提交、推送或发布。

### 2026-10-13：Viewer 重命名后的 Host 浏览器目录修复（未提交）

- 将远程目录监听与结构迁移合并到同一个 SwiftUI observer：先迁移工作区，再用当前会话
  同步浏览器目录，最后清理旧键；移除详情页捕获旧会话名的目录回调。
- 目录和 pane 路由不同步时暂缓目录清理，后续任一快照变化都会重试；避免重命名中间态
  误删左右浏览器标签。两侧浏览器视图 identity 包含描述符的会话名，晚到的目录会重新
  建立正确的远程请求上下文；标签 ID、排序、分屏比例和选中项保持不变。
- **102 项 / 11 个 suite 定向测试通过**。新增挂载 SwiftUI 的回归覆盖主 / 独立窗口、
  左右浏览器、目录先到 / pane 先到 / 同时更新，并用真实 `RemoteBrowserSession` 搭配
  注入 Host 验证新会话名的画面与控制请求。另覆盖 Host 隔离、空目录的正常关闭清理。
- 最新源码 Mac Release 构建及签名验证通过；品牌 / 技术边界、差异检查和本轮模型、
  modifier、测试的 SwiftFormat 检查通过。MainView 仍有既有 `redundantSelf` 格式器解析
  错误，未为此重排整个文件。
- 本轮未跑完整 App 的真实加密 Host / Viewer 连接、全量测试或 iPhone 验证；未覆盖安装、
  提交、推送或发布。上述请求验证是原生 SwiftUI 夹具，不是完整远程 UI 验收。

### 2026-10-13：跨窗口移动浏览器后的重命名归属修复（未提交）

- Local / Viewer 重命名统一先调用共享窗口管理器，在同一次 MainActor 同步操作中迁移
  主窗口及匹配 Host / Session 的所有独立窗口标签键、保留会话名，再由各 Scene 更新
  私有选择与目录；不再让目录同步看到一半新名、一半旧名的归属表。
- 保留现有 Host / Session 隔离、显式浏览器归属优先及来源终端 fallback；不增加缓存、
  轮询或延迟。重复迁移幂等，标签对象、左右选中状态、排序与分屏比例保持不变。
- 新双窗口 SwiftUI 回归通过实际 transfer、结构 observer、browserOwner 与目录同步
  复现了修复前 A 先迁移导致的错误认领 / 右栏丢失。修复后 A 先 / B 先、浏览器在左 / 右
  四种组合均通过；另验证浏览器移回主窗口、Local / Viewer、Host / Session 隔离和重复迁移。
- 最新源码 **104 项 / 12 个 suite 定向测试通过**；品牌 / 技术边界与差异检查通过。
  本轮模型和测试格式检查通过；MainView 既有 SwiftFormat `redundantSelf` 解析错误未作
  无关重排。Mac Release 构建与签名验证通过。
- 本轮未跑完整真实 Host / Viewer 加密连接、全量测试或 iPhone；原生窗口夹具不等同于
  完整远程 UI 验收。未覆盖安装、提交、推送或发布。

### 2026-10-13：合入本地 main

- 合入本地 `main` 的 `841d7bd`，保留本分支已提交的独立多标签工作区及审查修复。
  版本号采用主线 `3.0.62`；历史分支构建记录分别保留，不代表本次发布。
- 主线 API Key 显示 / 隐藏功能接入两端共用的语音设置，凭据回归迁到 Common 测试；
  Host 模拟器目录纳入统一的迁移 / 同步观察器，保持主窗口专属、不跨工作区拖动，
  重命名后重建正确的请求上下文，移除当前预览后恢复剩余标签选择。
- 合并回归发现新快捷按钮布局加上语音入口后会挤宽窄分屏；缩小图标模式的最小宽度
  和按钮间距，保持原高度、可访问性名称及同一组有状态控件。
- 最终 **160 项 / 24 个 suite 定向测试通过**，包含窄分屏、共享语音凭据、独立窗口、
  重命名、浏览器 / 模拟器目录与新建会话回归；不以此代替全量或真实设备验收。
- Mac Release 构建及严格签名校验、品牌 / 技术边界、差异检查通过；本轮共享设置、
  模型、modifier、快捷按钮和测试格式检查通过，未重排 MainView / FileBrowserView 的既有格式问题。
- 未启动模拟器、操作用户会话、安装、推送或发布。iPhone 与完整交互验收继续延期。

### 剩余验收条件

- iPhone 真机仍按用户安排延后，不使用模拟器替代。快捷命令和视频的三端验收项因此保持未勾选。
- 独立窗口真实语音需要用户确认隔离 App 的系统权限并试说；不自动接受麦克风 / 语音识别授权。
- 视频原生播放器的 seek 已通过自动化回归，但完整 AVKit 进度条手势及长期资源占用仍需补充实测。
- 以上是验收缺口，不是发布许可；四项的整体完成状态不得由定向单元测试或夹具结果替代。
