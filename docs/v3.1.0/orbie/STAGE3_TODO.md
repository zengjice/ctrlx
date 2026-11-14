# Orbie 阶段 3：全局面板与任务查找

状态：**已完成实现、定向单测、Mac 编译及 Codex／Claude Code 本机隔离验收**。

基于 `d154c6a9` 及当前工作区的阶段 2／Round 1 修复继续实现；保留尚未提交的既有修改。

## 范围与决定

- 本机可配置快捷键，初始不绑定；注册冲突保留菜单入口，不替换系统绑定。
- 单个轻量浮动窗口；Esc 关闭并合理恢复焦点，重复唤醒不创建 Agent 或重复投递。
- 最近任务、状态及直接打开不依赖模型；复用阶段 2 的持久身份和普通标签导航。
- `ctrlx orbie tasks list/show` 只读，由现有本机 socket peer 证据校验当前 Orbie 进程／原生对话；输出有界，不返回草稿或完整原生日志。
- 已核验回答中的显式 taskID 候选须经程序核对；有歧义供用户选择，不执行模型返回的路径或命令。

## 清单

- [x] 查询服务、CLI 和调用方身份校验。
- [x] 最近任务与 taskID 候选、当前目标导航。
- [x] 快捷键配置、注册冲突及单窗口／焦点生命周期。
- [x] 轻量面板、保留草稿和无后台激活。
- [x] 定向测试、Mac 构建及隔离原生验收。
- [x] 证据、实施计划、决策记录与服务文档更新。

第三阶段完成；不进入阶段 4–6，不安装或发布。


## 验证记录

- `./scripts/unit-tests.sh -- --no-parallel --filter 'Orbie|Orbiter|OrbieCommand'`：54 项测试通过（51 Swift 服务／面板测试、3 CLI 测试），含 Unicode 字节边界、OS peer/PID 复用、空首轮 CID、忙碌只读、过滤／准确 UUID、草稿接续与面板布局。日志 `.build-local/orbie-stage3/initial-tests.log`。
- `python3 scripts/local_build.py run -- bash .build-local/orbie-stage3/build-mac.sh`：按 device-installer → browser → simulator helper 顺序准备后，`Ctrlx.xcworkspace`／`CtrlxServer` Debug arm64 编译通过。只构建 Mac，未安装或发布。
- 修改 Swift 的 SwiftFormat lint、品牌边界、技术边界、`git diff --check` 通过；最终复查同样通过（43 个变更 Swift 文件），见 `.build-local/orbie-stage3/static-checks.log`。
- 隔离 App 使用 `.build-local/upstream-browser-proof.orbie-stage3/CtrlX.app`，ad-hoc 签名与严格校验，私有 HOME、tmux socket、state、CLI 配置及 loopback 模型，无人类活跃任务。真实 Codex 的 list/show 工具结果已返回到同一原生上下文，taskID 候选进入核验工作流结果，点击打开第二个任务标签。
- 修正了产品中创建弹窗与定时扫描竞争、菜单栏模式的前台激活；测试驱动另补上 AX 实际输入值校验与辅助 App 的 Launch Services 激活。私有 Codex 配置允许本机 socket；首次采用默认沙箱时连接被拒绝，如实保留该边界，产品不更改用户沙箱权限。提示词要求通过 Agent 既有审批处理权限。

- 扩展回归：`./scripts/unit-tests.sh -- --no-parallel --filter 'Orbie|Orbiter|AgentForkServiceTests|AgentForkWorktreeTests|AgentSessionIdentityTests|AgentWorkflowInputGateTests|AgentWorkflowRecoveryTests|APISocketWorkflowPeerTests|SettingsSearchTests'`，109 项通过（106 + 3），包含真实 socket peer 的两个新增方法；日志 `.build-local/orbie-stage3/final-tests.log`。负例中损坏 JSON 的警告／错误为预期断言，未作为失败隐去。

- UI 收尾后 `Orbie|Orbiter|OrbieCommand` 54 项复验通过，日志 `.build-local/orbie-stage3/panel-final-tests.log`；最终实现保留简单的 `.onExitCommand`，不新增全局 Esc 拦截。原生驱动须显式清除合成 Esc 的修饰键，避免把上一快捷键的 flags 当作普通 Esc。
- Codex 0.167.1 完整原生验收通过，`.build-local/orbie-stage3/codex/app-report.json`：Main 首条消息实际执行 list/show，普通进程查询被拒绝；第二任务移到同一会话的索引 9 窗口（第二个 Agent 标签），候选打开该非首标签；三次外部 App → 全局键 → Esc 焦点往返及快捷键关闭只保留一个面板；草稿落盘；挂起 Main 模型响应时可搜索并打开任务，无额外工作流提交；释放后台结果不激活 CtrlX；原 pane 关闭后新建同名标签仍拒绝导航；重复打开不创建 Agent／执行记录。原生界面截图 `.build-local/orbie-stage3/codex/panel.png` 已目检。

- 私有模型服务不模拟 Claude Auto 模式的服务端 classifier，因此 Claude 验收显式使用 `--permission-mode default`，仅在私有配置中允许测试 Bash 读查询。产品不改变 Claude 的模式或权限；真实运行中需在既有 Agent 终端完成审批。首次 Auto 夹具停在该原生提示，没有把它记为查询服务成功。

- 原生 Claude 2.1.319 暴露完成校验差异：Stop 的 `last_assistant_message` 去掉首尾空白，转录保留末尾换行。只在 Claude 转录校验中统一两端首尾空白，保留内部文本、父链／会话／轮次、`end_turn` 和未阻断 Stop 的校验。新增工具轮次、阻断 Stop、内部空白不同及迟到候选回归。原始私有 Stop 证据 `.build-local/orbie-stage3/claude-code/stops.jsonl`，原生转录在该轮报告记录的私有 state/HOME 相邻目录；不使用终端屏幕文字作为结果。
- 完成链路回归：`./scripts/unit-tests.sh -- --no-parallel --filter 'Orbie|Orbiter|ClaudeWorkflow|CodexWorkflowTranscriptTests|AgentWorkflowTranscriptFileTests|AgentWorkflowCompletionMonitorTests|AgentWorkflowEventRouterTests|APISocketWorkflowPeerTests'`，82 项通过（59 + 3 + 7 + 13；与前述回归部分重叠），日志 `.build-local/orbie-stage3/reply-final-tests.log`。

- 最终 Mac 构建通过，仍按三个原生 helper → Mac workspace 顺序，`.build-local/orbie-stage3/mac-build.log`；未构建 iOS。
- Claude Code 2.1.319 在最终构建完整通过与 Codex 相同的一组原生场景，`.build-local/orbie-stage3/claude-code/app-report.json`，包含第一条 Main 消息中的真实 list/show、核验后显示的候选、同会话非首标签、独立调用方拒绝、三轮快捷键／Esc 焦点往返、忙碌导航、后台不抢焦点、关闭原 pane 后同名替代仍拒绝、无重复创建／投递。私有 Agent 分别只留下两条任务和四条执行。截图 `.build-local/orbie-stage3/claude-code/panel.png`。
- 原生命令：`python3 scripts/clean-build.py use-artifact --path .build-local/upstream-browser-proof.orbie-stage3 -- bash .build-local/orbie-stage3/run-app-tests.sh`；Claude 完成校验修复后的重签名复验为同一 wrapper 加 `bash .build-local/orbie-stage3/run-claude-tests.sh`。两份报告记录各自 App 的 SHA-256。Codex 原生报告来自最终 UI／查询代码、Claude 专属首尾空白修复之前；该修复不改变 Codex，相关 Codex 和公共完成通道单测复验后复用其原生证据。最终严格签名校验日志 `.build-local/orbie-stage3/test-signing.log`。
- 验收脚本均已退出，测试 App、辅助焦点 App、私有 tmux 和 loopback Provider 已停止；未替换已安装 App，未向人类活跃任务输入。

## 实际边界

- 真实 CLI＋本地模拟 Provider 验收证明工具／身份／转录／导航链路，不代表真实模型的检索排序质量或公网 Provider 验收。Codex 需有访问本机 socket 的现有权限，Claude 的 Auto 服务端检查及其他审批仍在普通 Agent 标签完成。
- 多窗口已实操；多屏通过正／负坐标和较小可见区域的几何测试，未接实体多显示器验证 Spaces、全屏及屏幕插拔。未跑完整跨平台 E2E、旧 macOS 设备、跨 Host 或外部发布／安装验收。


## 工作流交接状态

实现及验收已完成。已执行本步骤给定的 `ctrlx workflow complete-step --invocation 028BF877-53D5-455B-A5A4-348F24E444B8`，Host 返回 `This caller does not own the workflow invocation.`。只读 `ctrlx identify --json` 确认当前位于 bugfix 的 dev／%18；该 invocation 的自动交接尚未成功，不将命令失败记为步骤完成。

2026-11-14：使用原 invocation 重试成功，Host 返回 `Step completion saved`。完成请求已保存，后续交接等待本轮最终结果验证及工作流未暂停；本轮未重复构建或测试。


## Round 1 修复：发送预检期间保留待发文本

- Accepted P2：轻量面板允许继续编辑，原 `send()` 在异步预检后读取草稿，可能把 Send 时的 A 换成新编辑的 B 并清空 B。
- KISS 修复：只将 `let text = draft` 移到首次 `await` 前；沿用既有发送、按文本清空及持久化逻辑。
- 新增 Codex／Claude Code 参数化回归：在真实预检扫描回调中把 A 改为 B，断言执行输入仍为 A，B 留在内存、磁盘及重新打开的服务中，且仅安排一次执行。修复前回归出现四项断言失败，证据 `.build-local/orbie-stage3-repair/before-fix-tests.log`。
- `./scripts/unit-tests.sh -- --no-parallel --filter 'Orbie|Orbiter'`：55 项通过（52 + 3），新增用例的 Codex／Claude Code 两个参数均通过；`.build-local/orbie-stage3-repair/tests.log`。
- `python3 scripts/local_build.py run -- bash .build-local/orbie-stage3-repair/build-mac.sh`：按规定顺序准备三个原生 helper，Mac workspace 编译通过；`.build-local/orbie-stage3-repair/mac-build.log`。
- 两个修改 Swift 文件的 SwiftFormat lint、品牌边界、技术边界和 `git diff --check` 通过；`.build-local/orbie-stage3-repair/static-checks.log`。未重复完整 E2E；既有 Provider／快捷键／导航原生证据不受这一文本快照调整影响。未提交、安装或发布。
