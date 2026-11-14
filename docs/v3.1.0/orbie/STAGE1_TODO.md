# 阶段 1：Orbie 绑定与投递

状态：阶段 1 已实现并完成下述本机隔离验收。源码基线：`63e110b7`（2026-11-13，`bugfix`，开始时工作区干净）。范围依据：[实施计划](IMPLEMENTATION_PLAN.md)。目标是在现有 CtrlX 内打开一个固定 Orbie，完成一次可核验的对话，并在 App 重启后接续同一目标。

## 开始前

- [x] 核对最新代码、工作树与现有 Agent／工作流契约；实施基线见上。
- [x] 按已授权实施计划采用 O-01、O-02 的本机显式创建、Codex 后 Claude、用户选 Provider 边界；原生运行验收另行记录。
- [x] Codex／Claude 原生私有 tmux 验证单参与者、单步骤、单轮；各两条已核验回复，另验证真实审批等待、人工草稿和停止投递，见证据。
- [x] 冻结最小存储字段及路径：绑定、请求关联、版本；全部通过 CtrlxPaths 重定向，见实现落点。

## 实现落点

- `OrbieStore` / `OrbieRecord`：版本 1，`<stateRoot>/orbie/binding.json`；保存 Host、启用状态、创建 token／Agent／Provider／目录／持久 pane、已核验进程／对话、run 引用及未确认请求的草稿。无第二份投递账本。
- `CtrlxPaths.orbieDirectory`：`<ctrlxRoot>/agents/main/`；只补缺失的 `AGENTS.md`、`CLAUDE.md`，不改 CLI 原生记忆或覆盖用户文件。
- `OrbieService`：主 actor 上的产品状态与操作协调，I/O 交给存储 actor，调用现有 `AgentWorkflowService`／Runner／InputGate。
- `AppCoordinator+Orbie` / `workflowAgentCreation`：复用启动准备和 Provider，原子 tmux 创建链写入 `@ctrlx-creation-id`，回包不明按 token 核对。创建前检查 Host 存储身份，不要求已经存在 tmux 会话；同创建入口复制 Provider 的模型快捷按钮默认值。
- `MacOrbieView`：菜单栏／主窗口工具栏打开同一个 Orbie 窗口。保持窗口草稿，显示输入、原生核验结果及等待原因；普通终端处理问题／审批；同一持久目标更新运行态，无需手动 Reconnect，Set Up Again 不代发旧消息。窗口打开时只对尚未就绪且没有进行中消息的目标重新检查就绪状态，进行中的结果读取现有账本；关闭窗口没有额外 Orbie 轮询。

## 实现

- [x] 增加最小 Orbie 绑定存储和依赖注入；I/O 失败可见，不回退到另一份空绑定继续创建。
- [x] 增加应用内「打开 Orbie」入口，显式创建后重复打开定位同一持久目标。
- [x] 复用现有 New Agent／Provider 选择、目录检查、shell 集成及窗口创建，不新增独立 Agent 启动器。
- [x] 创建前保存意图，创建处理中防止重复；回包不明先核对，无法确认时保留待核对状态。
- [x] 接入单步工作流，引用现有 run／invocation，不复制输入账本、超时恢复或原生完成解析逻辑。
- [x] 区分面板草稿、终端草稿、已发送输入及最终结果；忙碌／提问／授权时不覆盖输入。
- [x] App 重启后解析既有持久目标并核验当前运行态；目标缺失时显示现有恢复入口，单次发送期间进程或原生会话变化仍拒绝过期投递。
- [x] 关闭入口不停止 Agent；停用功能不删除绑定、用户文件或普通标签。

## 验证

- [x] 存储往返、损坏／不可写、同目标重复打开、并发创建、创建成功但回包未确认、投递成功但回包丢失。
- [x] Codex 0.167.1、Claude Code 2.1.319 各完成首条 Orbie 消息及下一轮；Provider 是私有 loopback 模型夹具，不使用用户账号或凭据。
- [x] 原生首次会话尚未确认、手动输入发生在准备与写入之间、已有其他工作流占用；使用原有输入门控／终端输送回归及新增 Orbie 争用用例。
- [x] 私有原生 CLI 审批等待保留草稿且不代答；签名 App 的 Open Agent Tab 可打开普通终端；Orbie 不额外伪造 Enter／Esc。
- [x] 进程替换、复用 pane ID、同名标签、会话切换均不能承接旧投递权限；开始期间发生替换也由 store 原子检查拒绝。同一持久目标的 Orbie 产品关联则随当前已核验运行态更新，见下述修订。
- [x] 签名 App 真正退出后重新启动，原 Agent 的 PID／启动时间保持不变，模型请求数及 run 数不增加；目标失效只显示恢复／重建入口，不自动重建 tmux。
- [x] 下述定向单元回归、SwiftFormat、边界检查及 Mac 编译通过；另做了隔离签名 App 和私有 tmux 验证。
- [x] 本清单和 ISSUES 已更新证据与边界。阶段 1 门槛通过；阶段 2 尚未启动，不提前建立后续 TODO。

本阶段不包含全局快捷键、选区派发、任务列表和记忆整理。当前不进入阶段 2；不扩大全局入口或任务分身的范围。

## 验收证据（2026-11-13）

- 定向命令：`CTRLX_ORBIE_UI_EVIDENCE="$PWD/.build-local/orbie-stage1" ./scripts/unit-tests.sh -- --no-parallel --filter 'OrbieTests|OrbiePanelTests|AgentWorkflowServiceTests|AgentWorkflowInputGateTests|AgentWorkflowRecoveryTests|AgentSessionIdentityTests|AgentWorkflowTerminalTransportTests|NewTabMenuTests.agentPanelInitialLayout|AgentModelShortcutDefaultsTests'`。76 项、9 个套件通过；日志 `.build-local/orbie-stage1/acceptance-tests.log`。面板在 520／640 pt 的控件几何与可访问性检查通过；离屏缓存图不作为完整像素验收。
- 原生命令：`python3 scripts/verify-orbie-stage1.py --output .build-local/orbie-stage1/native`。真实 Codex 0.167.1／Claude 2.1.319，私有配置、tmux socket 和本地模拟模型。4 条消息各有匹配的原生最终结果；2 次真实审批停留未代答／未执行测试命令，面板草稿保留，停止后续投递不结束 Agent。另验证原生终端草稿阻止投递、重新加载服务不重发。结果在 `native-report.json`、`native-ledger.json`、`native-tests.log`。
- Mac 命令遵循 device-installer → browser → simulator helper 顺序，再经 `python3 scripts/local_build.py run -- …` 执行 `xcodebuild -workspace Ctrlx.xcworkspace -scheme CtrlxServer -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build-local/DerivedData/macOS -clonedSourcePackagesDirPath .build-local/SourcePackages -onlyUsePackageVersionsFromResolvedFile -skipMacroValidation -skipPackagePluginValidation COMPILER_INDEX_STORE_ENABLE=NO INDEX_ENABLE_DATA_STORE=NO CODE_SIGNING_ALLOWED=NO build`。构建通过，日志 `.build-local/orbie-stage1/mac-build.log`；未安装、打包或发布。
- 完整 App：以最新 Debug 构建的独立副本作临时 ad hoc 签名，`codesign --verify --deep --strict` 通过；通过 `clean-build.py use-artifact` 管理。使用短临时 state root、私有 tmux／API／ingress socket、私有 Codex 配置和 loopback 模型，按本 App 的 PID 做原生 AX 操作。实际创建页选择 Current CLI configuration 后创建 Orbie，首条输入与原生结果匹配；重复打开只保留原关联；关闭面板保留草稿；Open Agent Tab 打开普通终端；真正退出／重启 App 后仍是同一个存活进程和启动时间，模型请求数及运行数不增加。证据 `.build-local/orbie-stage1/app-report.json`、`app-driver.log`、`app-creation-ax.json`、`app-result-ax.json`。测试 App、私有 tmux 和模型服务已停止；没有替换安装的 App。完整 App 链路使用 Codex，Claude 的首条／下一轮和审批走上述真实 CLI 服务夹具，不冒称两个完整 App 创建流程都已验收。
- 验收补齐了空 Host 创建入口无需先扫描进程、启动中／人工输入结束后更新就绪状态、保留子控件标识，以及创建时复制 Provider 模型快捷按钮默认值。Unix socket 夹具使用短临时根目录，避免把深工作树路径长度错误当成功能结论。
- 已修改 Swift 文件的 SwiftFormat lint、两项仓库边界、Python 编译和 `git diff --check` 通过。

### 验收边界与既有失败

未跑全量单测／跨平台 E2E、iOS 构建、真实账号／远端 Provider、整机重启或 tmux 拓扑重建；后两者仍遵循已有恢复流程，阶段 6 统一验收。没有把真实模型质量或正式分发签名当作已验证。

曾扩展运行整个 `NewTabMenuTests`：未改动的 `keyboardSelection(mode: 0/1/2)` 离屏键盘事件未触发选择，三个参数失败；其源码与本次基线相同，未改为通过，也不计入上述定向通过数。日志 `.build-local/orbie-stage1/final-unit-tests.log`、`panel-tests.log` 的早期失败记录；当前 `panel-tests.log` 已由修正后的 Orbie 面板几何回归覆盖，保留完整扩展失败的是 `final-unit-tests.log`。原因仍待单独排查。

## Round 1 修复：移动 pane 后保持 Orbie 关联

以下记录当时的验收。进程／对话变化需手动 Reconnect 的产品策略已由下述「持久目标关联」修订取代；移动中单次请求的核验继续保留。

- 已修复 P2：`OrbieService.reconcile` 优先复用 `matchesProcess` 定位同一 Host、插件、进程实例和持久 pane，更新绑定中的当前 window／session 路由；已有原生会话 ID 不被新值自动替换。原来的同目标显式 Reconnect 路径保留，不新增身份层或存储格式。
- Open Agent Tab 先刷新已有 tmux／PaneState 布局，再刷新并使用已验证的 Orbie 绑定。即使普通终端窗口尚未打开，也能导航到移动后的窗口。
- 新回归在修复前复现失败；修复后覆盖 Codex／Claude 的移动、持久化／重新打开和继续发送、会话变化必须显式 Reconnect，以及进程／pane／server／插件替换拒绝。执行 `./scripts/unit-tests.sh -- --no-parallel --filter 'OrbieTests|OrbiePanelTests|AgentWorkflowInputGateTests|AgentWorkflowServiceTests|AgentWorkflowTargetTests|AgentWorkflowRecoveryTests|AgentWorkflowTerminalTransportTests'`，64 项、7 个套件通过。证据：`.build-local/orbie-move-repair/before-fix.log`、`focused-tests.log`。
- Mac Debug 编译及修改 Swift 的格式、两项边界和 `git diff --check` 通过；构建日志 `.build-local/orbie-move-repair/mac-build.log`。
- 最新构建的隔离 ad hoc 签名 App 中，用真实 Codex 0.167.1 和私有 loopback Provider 完成首条消息，将同一 pane 实际移入另一 tmux window；点击 Open Agent Tab 更新路由并打开普通终端，继续消息收到原生核验结果。进程启动身份和原生会话不变，App 退出／重启保留移动后的路由和原进程，没有新增模型请求。证据：`.build-local/orbie-move-repair/app-report.json`、`app-driver.log`、`app-result-ax.json`。测试 App、tmux 和模型服务均已停止。
- 本轮未重跑完整双 CLI 场景、全量单测、跨平台 E2E 或 iOS 构建；不把此前的原生证据当作本轮新结果。未提交、安装或发布。

## tmux 3.6a 兼容修复（2026-11-14）

- Workflow／Orbie 共用输入检测与发送路径允许旧 tmux 缺少 `bracket_paste_flag`，仍核验原生空输入框、进程和输入归属；用同一受保护命令队列执行 `paste-buffer -p` 与一次 Enter。明确报告粘贴模式关闭、复制模式、前台命令／光标／尺寸变化仍拒绝发送。附件暂存继续核验完整图片序列，既有草稿不会被覆盖。
- 有效旧版输入框不再因缺少字段重复等待重绘；输入不可用时显示具体原因。Open Agent Tab 不再随后台扫描禁用，也不等待完整 Agent 扫描，只刷新普通 pane 布局后导航；同一存活 pane 移动后的导航继续支持，绑定更新仍由原有核验路径负责。
- `CTRLX_TMUX_COMPAT_EXECUTABLE` 分别指定隔离的 tmux 3.6a 和 3.7b，配合 `CTRLX_TMUX_COMPAT_EXPECT_UNKNOWN=1/0` 运行定向测试。3.6a：67 项、7 个套件通过；3.7b：22 项、3 个套件通过。覆盖多行中文／特殊字符原样粘贴并仅提交一次、状态变化拒绝、草稿识别及扫描挂起时 Open Agent Tab 的 AX 可用状态。日志：`.build-local/orbie-tmux-36/compat-36-tests.log`、`compat-37-tests.log`。
- `python3 scripts/verify-orbie-stage1.py --tmux .build-local/hook-trust-tmux-compat/tmux-3.6a/tmux --output .build-local/orbie-tmux-36/native` 通过。真实 Codex 0.169.0 和 Claude Code 2.1.319 使用私有 tmux／配置及 loopback 模型，均完成首轮与下一轮，审批等待未代答，保留草稿，重开服务不重发；证据为该目录下的 `native-report.json`、`native-ledger.json`、`native-tests.log`。
- Mac Debug 构建通过，遵循三个 native helper 的构建顺序，使用 workspace `CtrlxServer` 和 managed build lock；日志 `.build-local/orbie-tmux-36/mac-build.log`。修改的 Swift 文件格式、两项仓库边界、Python 语法和 `git diff --check` 均通过。
- 本轮没有替换已安装 App、操作用户终端或访问真实 Provider；尚未在报告问题的另一台 Mac 上验收，也未运行全量单测、跨平台 E2E 或 iOS 构建。

### Review P2：临时输入诊断不能暂停工作流

- 输入检查的具体提示改为可选 `inputIssue`，仅用于展示，`readiness` 继续表达等待状态；`capabilityIssue` 保留给原有能力／身份故障。重新检查和读取旧快照时清除失效的输入提示，不改变工作流暂停／继续状态机。
- 回归通过实际 composer 检查、catalog 刷新和后台调度验证两种状态：tmux 复制模式、编辑草稿时光标离开起点。修复前均会暂停且无法自动恢复；修复后保持运行、等待期间不投递、恢复后自动重新调度，无需 Continue。既有真实能力故障暂停回归继续通过。
- 在 tmux 3.6a 下，`AgentWorkflowServiceTests|AgentWorkflowStoreTests|AgentWorkflowRunnerTests|AgentWorkflowComposerTests|OrbieTests|OrbiePanelTests|AgentModelTmuxCompatibilityTests|AgentWorkflowTmuxSubmissionTests|AgentWorkflowRequestTests` 共 99 项、9 个套件通过；`AgentWorkflowWireTests` 的 5 项测试通过，覆盖可选字段往返和旧消息解码。另验证 Orbie 展示临时提示且恢复后清除。修复前后日志：`.build-local/orbie-input-issue/before.log`、`after.log`。
- Mac Debug 构建、SwiftFormat、两项仓库边界及 `git diff --check` 通过，构建日志 `.build-local/orbie-input-issue/mac-build.log`。本轮未重跑真实双 CLI 模型夹具、全量单测或跨平台 E2E，未安装或发布。

## 持久目标关联（2026-11-14）

- Orbie 以 `AgentWorkflowTarget(hostID, windowID, paneID)` 为产品身份，复用现有持久 UUID；`binding` 保留为最近核验的运行态快照，不另建存储格式。原创建记录仅描述初始启动，当前支持的 Agent／Provider 从现有运行态获取。
- 同一目标切换账号、原生对话、受支持 Agent 或 workspace recovery 后自动采用已核验的当前运行态，移除手动 Reconnect 流程。存活 pane 的窗口移动继续更新路由；另一个目标、同名标签、无法证明的跨目标替换不会被接管。刷新不发送消息，也不创建新的 Agent。
- 任务只读查询共用相同目标解析，随后核验当前 socket peer／进程／原生 writer；新进程无需先打开面板，旧进程不能保留权限。关联已有任务的列表也按当前目标排除 Orbie。
- 未完成／未确认消息仍需处理；既有 invocation 的运行态和结果核验保持不变，发送期间发生替换仍由 `expectedInstances` 拒绝。此次修改不扩展 Orbiter 自身的持久关联策略，也不改工作流投递状态机。
- 定向命令：`./scripts/unit-tests.sh -- --no-parallel --filter 'OrbieTests|OrbieTaskQueryTests|OrbiePanelTests|AgentWorkflowTargetTests|AgentWorkflowInputGateTests|AgentWorkflowRunnerTests|AgentWorkflowTerminalTransportTests'`，67 项、7 个套件通过。覆盖 Codex／Claude 重启、对话切换、tmux 恢复和插件切换、持久化重开、查询新旧进程授权、移动 pane、发送期间替换，以及已接受任务不改绑／不接收新对话结果。日志 `.build-local/orbie-stable-target/focused-tests.log`。
- Mac Debug 构建通过，遵循三个 native helper 的构建顺序，使用 workspace `CtrlxServer` 和 managed build lock；日志 `.build-local/orbie-stable-target/mac-build.log`。修改 Swift 的 SwiftFormat、两项仓库边界及 `git diff --check` 通过。
- 本轮验证为服务夹具、定向 UI 测试和 Mac 编译，未使用真实账号切换或整机恢复验证，也未重跑原生双 CLI 夹具、全量单测、跨平台 E2E 或 iOS 构建。未安装或发布，另一台 Mac 的实际场景仍需更新后验证。
