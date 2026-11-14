# Orbie 阶段 2：Orbiter 与任务接续

源码基线：`d154c6a9`。范围依照 [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) 阶段 2；本机 Host、Codex／Claude Code，复用普通 Agent、原生 Fork 和单步工作流。

## 实施与验收

- [x] 任务索引与创建前持久化意图；回包丢失按 tmux 创建标识核对，不自动再次启动。
- [x] New Agent 只携带目标、来源和选中的材料；Fork 固定已核验的 Orbie 原生对话，忙碌或类型不同时拒绝。
- [x] 任务使用实际项目目录；材料位于 `agents/experts/<taskID>/`，后续消息共用目录。
- [x] 列表／详情、名称与项目查找、时间筛选、归档、显式关联已有 Agent。
- [x] 最多两个活跃任务；达到上限保留草稿，无自动队列，普通 Agent 不受限制。
- [x] 初次创建确认后投递；启动待处理时保留草稿，后续投递须显式点击。刷新与重启不执行草稿。
- [x] 只从工作流已核验结果生成 Agent report；索引引用执行记录，保留被引用的工作流历史。
- [x] 交给 Orbie 总结只追加面板草稿，保留已有文字，不自动发送或抢焦点。
- [x] 打开当前持久 pane；恢复使用现有 Resume／Use Shell，重连／关联不等于重发。
- [x] 定向单元／界面／身份与输入回归。
- [x] Mac 编译、格式与仓库边界检查。
- [x] 隔离原生 Agent／签名 App 验收和证据记录。

## 已采用的默认值

- 两个活跃 Orbiter，无自动队列。归档保留任务、终端、材料及工作流历史，不自动删除。
- 每条投递仍是普通单步工作流，Workflows 历史可见；任务引用的 run 拒绝删除，定义可以删除，run 内的原定义快照和结果保留。不增加隐藏工作流或第二套投递账本。
- 一个 Host 级账本变更订阅保存后台报告；任务不分别轮询，关闭面板不停止 Agent。
- 新建后只有当前用户操作等待启动并尝试初次投递；无法确认时保留草稿，重启不自动补发。

## 阶段 2 首次验证记录

- 单测命令：`./scripts/unit-tests.sh -- --no-parallel --filter 'OrbiterTests|OrbieTests|OrbiePanelTests|AgentForkServiceTests|AgentForkWorktreeTests|AgentWorkflowServiceTests|AgentWorkflowInputGateTests|AgentWorkflowRecoveryTests|AgentSessionIdentityTests|AgentModelShortcutDefaultsTests'`。**104 项、10 个套件通过**；日志 `.build-local/orbie-stage2/focused-tests.log`。覆盖 New／Fork 来源、Provider 参数、创建去重／丢回包、上限／同名、草稿／后台报告、占用冲突、进程变化／移动、迟到结果、重启不重发、关联后的显式发送，以及归档／工作流历史保留。最小 740×620 pt 的任务表单控件几何与可访问性通过。真实 Git/tmux 的 12 组 Fork 启动参数回归也核对创建标识只落在新 pane。
- Mac 命令：按 device-installer → agent-browser → agent-simulator helper 顺序构建，再经 `python3 scripts/local_build.py run -- bash .build-local/orbie-stage2/build-mac.sh` 执行 `xcodebuild -workspace Ctrlx.xcworkspace -scheme CtrlxServer -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build-local/DerivedData/macOS -clonedSourcePackagesDirPath .build-local/SourcePackages -onlyUsePackageVersionsFromResolvedFile -skipMacroValidation -skipPackagePluginValidation COMPILER_INDEX_STORE_ENABLE=NO INDEX_ENABLE_DATA_STORE=NO CODE_SIGNING_ALLOWED=NO build`。最终构建通过，日志 `.build-local/orbie-stage2/mac-build.log`。
- 原生 App 命令：`python3 scripts/clean-build.py use-artifact --path .build-local/upstream-browser-proof.orbie-stage2 -- bash .build-local/orbie-stage2/run-app-tests.sh`。使用最新 Debug App 的独立 ad hoc 签名副本，`codesign --verify --deep --strict` 通过；短临时 state root、私有 tmux／HOME／CLI 配置、loopback 模型。测试 API key 仅在私有 Claude 配置中预先批准；没有处理真实任务的权限问题，没有替换安装的 App。
- 真实 Codex **0.167.1** 和 Claude Code **2.1.319** 各完成 **5 次**核验结果：Orbie 首条、New 任务、任务追问、原生 Fork、App 重启后在列表选择原任务并继续。模型请求内容确认 New 不含 Orbie 的源消息，Fork 保留源消息；任务与材料目录使用不同路径。报告交接追加并保留原 Orbie 草稿，不自动投递。
- 同名任务为 Audio／Audio 2，绑定不同 pane。真实移动 Fork pane 后，Open Agent Tab 更新其 window／session 路由，进程／会话和任务 ID 保持不变；重启不增加模型请求或 run，显式继续才产生新 run，仍共用原材料目录。汇总 `.build-local/orbie-stage2/native-report.json`；每种 Agent 的 `app-report.json`、`requests.json`、`app-result-ax.json` 和终端捕获位于 `.build-local/orbie-stage2/codex/`、`claude-code/`；驱动日志为 `codex-driver.log`、`claude-driver.log`。测试 App、私有 tmux 和模型服务均已停止。
- 所改 Swift 的 SwiftFormat lint、两项仓库边界及 `git diff --check` 通过。后台保存／刷新不再禁用编辑区；Fork 标识作为独立 tmux 命令进入同一受保护命令队列，避免被当成 shell argv。这些是首次验收时的修复记录；后续 Round 1 的证据与未测项单列如下。

## Round 1：创建身份与待确认请求草稿

- New 保留 `AgentWorkflowCreatedAgent` 的创建 scope；Fork 使用已核验源的 server 身份构造相同创建结果。最后关联必须同时匹配创建 server 与运行时 pane ID；server 替换／pane ID 复用时保留创建记录和草稿，不绑定、不投递。两种路径共用一处局部匹配，不改变创建标识或恢复协议。
- `pendingRunID` 在账本中被找到后，仅当当前草稿仍等于该 run 保存的原始输入时才清空；已保存的新追问保持不变。不增加持久字段，不拿可编辑的任务草稿当成原投递文本。
- 两组新增回归在修复前复现失败，日志 `.build-local/orbie-stage2-repair/before-fix.log`；修复后覆盖 New／Fork 的替换 server 拒绝、后续刷新／重启不重新错绑，以及原文／新草稿 × 当前服务／重启四种待确认请求恢复组合。内存和磁盘草稿、执行次数均有断言。
- 定向命令：`./scripts/unit-tests.sh -- --no-parallel --filter 'OrbiterTests|OrbieTests|OrbiePanelTests|AgentForkServiceTests|AgentForkWorktreeTests|AgentWorkflowServiceTests|AgentWorkflowInputGateTests|AgentWorkflowRecoveryTests|AgentWorkflowTargetTests|AgentWorkflowTerminalTransportTests'`，**103 项、10 个套件通过**；日志 `.build-local/orbie-stage2-repair/focused-tests.log`。正常创建、实例变化／移动、输入门控和真实 Git/tmux Fork 回归同时通过。
- Mac 构建经 `python3 scripts/local_build.py run -- bash .build-local/orbie-stage2-repair/build-mac.sh` 执行，遵循原 helper 顺序及 workspace／scheme，**BUILD SUCCEEDED**；日志 `.build-local/orbie-stage2-repair/mac-build.log`。SwiftFormat lint、两项仓库边界与 `git diff --check` 通过。本轮未重跑完整 E2E／双 Agent 完整 App 场景；首次验收的原生结果不算作本轮新证据。未提交、安装或发布。

## 验收边界

未跑全量测试／跨平台 E2E、iOS 构建、整机重启或 tmux 拓扑重建；不增加 Viewer 专用功能。普通 Resume／Use Shell 沿用既有恢复流程；本阶段真实 App 验证的是 App 重启且 tmux／Agent 存活的接续。模型来自隔离模拟 Provider，其他 Provider 的模型／快捷按钮默认值有定向回归，但不代表所有真实账号与服务均已验收。未做资源基准或长期任务积累测试，保留给阶段 6。阶段 3–6 未开始；未提交、安装或发布。
