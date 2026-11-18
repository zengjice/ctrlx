# Orbie 阶段 3-Fix：Agent／Workflow 职责收敛

日期：2026-11-14。源码基线：`7d2737e1`。状态：**源码已落地，自动化、私有真实 CLI、隔离 App 启动检查及两端编译通过；实机 UI 边界见文末**。

主线见[实施计划](IMPLEMENTATION_PLAN.md)，决策见 [ISSUES.md](ISSUES.md)。阶段 1–3 的 TODO 保留历史证据；本清单不继承其「已通过」状态。3-Fix 是阶段 4 的前置阶段，覆盖已确认优化方案的全部八项。

2026-11-16 补充：Agent 标签误关闭后的显式原对话恢复，纳入下述第 2／5／6／8 项；本轮已实现，验收记录见文末。

## 完成后的边界

Orbie、Orbiter 都是 tmux 管理的普通 Agent。Orbiter 可自由对话，并先后参与不同 Workflow；一个 Workflow 可由一个或多个 Orbiter 执行。流程结束不结束参与 Agent。产品只保留 Agent 与 Workflow，不增加独立 Task、Orbiter 身份或任务完成／归档状态机。

Orbie／Orbiter 界面与 Workflow 编排分别调用共用 Agent 交互能力。该能力基于既有运行目录、tmux 输入队列和插件事件，保存必要的消息投递与回复事实。Workflow 仅保留配置、参与者、图、循环、步骤完成规则及运行结果。普通消息不生成 Workflow Definition／Run／Node，也不注入流程步骤指令。

本阶段不扩展远端 Orbie 专用界面、跨 Host 调度、原生会话转换、选区派发、文件记忆或自动 Dreaming；既有 Viewer 终端、通知和 Workflow 必须回归。后续能力使用本阶段形成的边界。

## 当前代码落点

| 范围 | 已核对入口 | 调整方向 |
| --- | --- | --- |
| 面板对话 | [OrbieService](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/OrbieService.swift)、[OrbieStore](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/OrbieStore.swift) | 移除每次 `save`／`start` 工作流及通过工作流快照找 Agent 的依赖 |
| Orbiter | [OrbiterService](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/OrbiterService.swift)、[OrbiterStore](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/OrbiterStore.swift) | 移除 `OrbiterTask` 及任务生命周期；保留必要 Agent 关联与创建意图 |
| 误关闭恢复 | [WorkspaceRecoveryController](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/WorkspaceRecovery/WorkspaceRecoveryController.swift)、[AgentSessionIdentityClient](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/AgentSessionIdentityClient.swift) | 沿用主动关闭不自动复活的语义，保留已核验的恢复依据供 Orbie／Orbiter 显式 Resume，不重建一套恢复引擎 |
| 初始化与目录 | [AppCoordinator+Workflows](../../../CtrlxPackage/Sources/CtrlxServerFeature/Coordinators/AppCoordinator+Workflows.swift)、[WorkflowCatalog](../../../CtrlxPackage/Sources/CtrlxServerFeature/Coordinators/AppCoordinator+WorkflowCatalog.swift)、[WorkflowCreation](../../../CtrlxPackage/Sources/CtrlxServerFeature/Coordinators/AppCoordinator+WorkflowCreation.swift) | 提取共用的初始化、运行态观察与创建能力，Orbie 不再等待 Workflow 存储加载成功 |
| 投递与回执 | [Runner](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/Workflows/AgentWorkflowRunner.swift)、[TerminalTransport](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/Workflows/AgentWorkflowTerminalTransport.swift)、[InputGate](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/Workflows/AgentWorkflowInputGate.swift)、[EventRouter](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/Workflows/AgentWorkflowEventRouter.swift)、[CompletionMonitor](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/Workflows/AgentWorkflowCompletionMonitor.swift) | 提取可靠消息交互，保留一份写入保护、事件关联和原生回复核验逻辑；图推进留在 Workflow |
| 查询与 CLI | [OrbieAgentCatalog](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/OrbieAgentCatalog.swift)、[OrbieQueryService](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/OrbieQueryService.swift)、[OrbieCommands](../../../CtrlxPackage/Sources/CtrlxCLI/Commands/OrbieCommands.swift) | 以 Agent／Workflow 查询替换 Task 查询，保留调用方授权、有界输出及目标复核 |
| 界面 | [MacOrbieView](../../../CtrlxPackage/Sources/CtrlxServerFeature/Views/MacOrbieView.swift)、[MacOrbiePanelView](../../../CtrlxPackage/Sources/CtrlxServerFeature/Views/MacOrbiePanelView.swift)、[MacOrbitersView](../../../CtrlxPackage/Sources/CtrlxServerFeature/Views/MacOrbitersView.swift)、[AgentWorkflowsView](../../../CtrlxPackage/Sources/CtrlxCommon/UI/Workflows/AgentWorkflowsView.swift) | Orbiters 列表、普通对话状态及独立 Workflow 列表／标签 |
| 迁移 | [AgentWorkflowStore](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/Workflows/AgentWorkflowStore.swift)、[CtrlxPaths](../../../CtrlxPackage/Sources/CtrlxServerFeature/Plugins/CtrlxPaths.swift) | 按真实关联转换旧内部执行与 Task 索引，保留原生会话、普通流程、附件及材料 |

共用实现位于 `Services/AgentInteraction/`：运行目录、输入保护、原生回复核验和普通消息技术记录。Workflow 继续持有图／节点执行记录，普通消息不再持有对应 Workflow。只提取两个真实消费者所需的能力。

## 1. 统一产品模型

- [x] Orbie／Orbiter 使用普通 Agent 的身份、状态和生命周期；Workflow 是独立可选编排。
- [x] 取消 `OrbiterTask`、Task ID、独立完成与归档状态；不将同一模型改名为 Job／Activity 后保留。
- [x] 同一 Orbiter 可继续自由对话、加入流程、流程结束后继续对话或参与另一流程；单次回复结束只更新消息状态。
- [x] Workflow 参与者继续使用现有参与者引用与稳定 Agent target，不用参与者 ID、消息 ID 或创建请求 ID 代替 AgentID。
- [x] 明确消息／回执是技术记录；只保留一份可核对的投递事实，Workflow 节点引用或消费该事实，不复制一套发送状态机。

## 2. 沿用身份与生命周期

- [x] 按[现有身份契约](../../agent-identity.md)关联 `AgentID(hostID, persistentPaneID)`；window／session 是位置，进程、原生对话及请求是操作证据。
- [x] Orbie／Orbiter 仅增加必要的角色与创建来源关联；名称、目录、模型、忙碌状态复用既有 Agent 数据，不维护第二份运行目录或身份注册表。
- [x] New Agent／Fork／Resume、Provider 默认模型／effort 和快捷按钮、Codex 启动参数、shell 包装与 workspace recovery 均使用现有入口。
- [x] Fork 使用创建时核验的原生上下文快照，之后双方独立；跨 Agent 类型使用已有 New Agent 材料交接，不转换原生历史。
- [x] 创建前保留最小创建意图；丢回包先检查已有创建证据，确认后关联 AgentID，不因超时新建第二个标签。
- [x] 保留已有 main／experts 材料目录及实际项目 cwd，不为迁移重命名目录，不按每条消息新建目录。

### 误关闭 Agent 标签后的恢复（Orbie／Orbiter 共用）

- [x] 区分三种情况：关闭 Orbie 面板只隐藏界面；Agent 退出但 pane 存活使用原有 Resume／Use Shell；确认原 pane 已删除后显示「Agent 标签已关闭」及「恢复原对话」。Host 未连接或目录扫描失败只表示暂不可用，不判定标签已删除。
- [x] 复用现有已核验的 Agent 恢复描述，保留原生会话、Agent 类型和必要启动上下文，使主动关闭从工作区快照移除 pane 后仍有恢复依据；不额外复制聊天记录、密钥或登录凭据。仅有旧 pane UUID、标题或工作目录不足以选择对话。
- [x] 主动关闭仍不触发后台复活。用户明确选择「恢复原对话」后，复用现有创建／Resume 路径在新标签恢复指定原生会话；核验恢复成功再将 Orbie／Orbiter 角色关联更新为新 AgentID，不复用已删除 pane 的身份。
- [x] 复用创建意图处理重复点击、启动失败及回包丢失；再次操作先核对已创建标签，不重复创建或启动同一会话。原绑定及恢复依据在成功更新前保留，不先执行破坏性的清空／重设。
- [x] 历史消息、待确认投递及 Workflow 的原绑定／操作证据保持不变，不自动重放、继续或重新授权旧请求；需要改绑的 Workflow 使用既有显式改绑流程。旧消息继续可读，未结束／待确认消息不得永久锁死恢复入口。
- [x] 原生历史缺失、身份无法核验或当前 CLI 无法恢复时显示具体原因；由用户选择新建 Orbie／Orbiter，不自动改用最近会话或把新会话称作恢复成功。新建仍保留旧历史、草稿与材料。

## 3. 提取共用 Agent 交互能力

- [x] 从 Workflow 实现提取必要的运行态观察、输入预检、串行投递、回执关联、原生回复读取及附件支持；先让 Workflow 使用同一实现，再切换普通对话。
- [x] 共用交互只依赖现有 Agent 状态、tmux 与插件能力；不要求存在 Workflow 图、Run 或 Store，不反向调用 Orbie／Orbiter。
- [x] 共用初始化先于 Workflow，普通 Agent 创建与定位不依赖 Workflow 服务；损坏或无法加载 Workflow 数据时，Orbie 仍可打开、查看及对话。
- [x] 普通消息以发送动作捕获的文本／附件为准；之后编辑保留在草稿中，后台确认不能清空新草稿。
- [x] 持久化必要的目标、写入意图、运行态证据、原生轮次、确认状态和回复／附件引用；核验后才能显示为已确认回复，发送结果不明不重发。
- [x] 原生 Hook／转录解析中的轮次和对话证据进入同一关联通道；普通消息不注入 Workflow invocation／步骤完成指令。保留现有插件能力、版本和调用方校验；旧事件或不支持的插件明确处理，不凭 Agent 名称放行。
- [x] 普通消息不创建、隐藏或复用 Workflow Definition／Run／Node；Workflow 才使用图推进、循环及显式步骤完成规则。

## 4. 对话、流程与人工操作的边界

- [x] 普通对话按原生轮次确认回复；提问、审批和等待用户补充留在普通 Agent 交互中，不要求操作 Workflow Continue。
- [x] Workflow 保留「回复结束」与「明确完成步骤」两种现有规则；事件核验后，由编排层判断是否推进。
- [x] 面板、Workflow、本机终端及 Viewer 共用输入串行化和输入代次保护；后台检查不得清空草稿、抢输入或把临时复制模式误判为能力故障。
- [x] Workflow 占用同一 Agent 时，面板说明原因并提供进入流程或人工接管入口；人工终端仍可使用，接管后按既有规则阻止过期自动写入。
- [x] 普通消息、人工终端输入和不同 Workflow 的回复分别关联原始投递；重复、迟到及错误轮次事件不更新另一条消息或推进另一流程。
- [x] 账号切换、Agent 重启、原生会话切换及 pane 移动后，新消息重新核验当前运行态；历史消息保留其原证据，不因目标仍存在就认领不匹配的结果。
- [x] 区分未发送取消、已发送后的等待／人工中断、流程停止后续投递；面板关闭不停止 Agent。应用重启只核对既有请求，不自动重发。

## 5. 界面、查询和结果

- [x] Tasks／All Tasks 改为 Orbiters；列表展示真实 Agent 名称、项目、最近活动及运行状态，打开后定位现有标签或进入 Resume／Use Shell。
- [x] Orbie 面板／完整对话和 Orbiters 列表使用同一关闭／恢复状态；原 pane 不存在时不继续提示打开失效标签，提供「恢复原对话」及必要的新建入口，明确其操作区别。
- [x] 移除独立任务详情、完成／归档操作；旧归档记录迁移后保留为可查找的历史 Agent 关联，不继续作为发送资格状态。
- [x] Workflow 保留独立列表，增加简单标签字段及编辑／筛选／查询；明确数量／长度边界和空值规则，不建设标签实体、自动派单或权限系统。
- [x] 用 Agent／Workflow 查询替换 `orbie.tasks.list/show` 及 taskID 候选；优先复用已有 CLI 能力，必要的新方法与模型指令一起更新，不声称尚不存在的命令可用。
- [x] 只读查询继续核验本机 ingress peer 和调用方，输出有界；取消 Task 索引不扩大 Orbie 的读取范围。候选由程序重新核对 AgentID／Workflow ID，不执行模型输出的任意路径或命令。
- [x] 忙碌时仍能搜索、定位和查看；非首标签、同名标签、目标缺失及多 Host 场景保持准确。
- [x] 普通回复归属 Agent 对话，流程结果归属 Workflow 执行，文件通过 Files 打开；「交给 Orbie 总结」只追加选中的内容到草稿，不自动发送。
- [x] 保留全局快捷键、单面板、Esc、草稿及后台不抢焦点行为；不新增 Mac Viewer／iOS 专用 Orbie 界面。

## 6. 移除 Task 层并迁移已有数据

- [x] 迁移前备份并验证旧 Orbie 绑定、Orbiter 索引和 Workflow 账本；明确新格式版本、写入切换点及中断后重入规则，失败不覆盖原件或静默新建空数据。
- [x] 以 `runIDs`／`pendingRunID` 等保存的关联识别旧内部记录，并检查其结构；不按 `Orbie`／`Orbiter:` 名字批量删除。用户编辑过或来源不明的记录保留待核对。
- [x] 将确认属于旧单步交互的输入、原生轮次、已核验回复、时间及附件关系迁入消息记录；迁移完成前不移除原记录或释放其附件。
- [x] 旧 Task 转为现有 AgentID 的角色／来源关联，合并同一 Agent 的重复关联并保留各自材料。没有确认 pane 的记录保留创建意图；已关闭目标保留历史引用及可核验恢复依据，迁移本身不分配新 Agent 身份、不按名称认领。原生历史不足的旧记录明确标记不可恢复；后续显式恢复才创建新标签并更新角色关联。
- [x] 切换时防止旧内部执行与新消息通道双重写入；已写出的消息只依据原回执／转录核对，待确认状态不视为未发送。不自动 Resume、继续流程、重新创建或重投递。
- [x] 未开始发送的内容及后续新编辑的草稿都保留，由用户明确发送；重复迁移和重启不增加 Agent、Workflow、消息或模型请求。
- [x] 普通用户 Workflow、手动复制的配置及独立启动的运行保留原有关系。处理旧内部模板／run 的删除和引用保留标记时，检查全部仍有效的引用。
- [x] 旧 TASK.md／RESULT.md、原生会话、材料目录和产物继续保留为普通文件；停止自动维护，不把文件出现用作运行成功的证据。
- [x] 新路径验收后删除 Task 查询／服务／状态推导及旧自动单步投递的运行代码；旧格式读取只用于一次迁移，不维持两套活动实现。

## 7. 资源与实现规模

- [x] 复用一份 Agent 运行目录、输入保护与回执处理；只监测活跃投递，历史分页或按需读取，面板关闭后不保留界面刷新任务。
- [x] 消息存储只包含必要内容和核验／回复引用，不复制完整原生聊天历史；保留运行中及仍被引用的结果，不自动清理用户产物。
- [x] 取消「两个活跃 Orbiter 任务」上限，保留每 Agent 输入互斥及 Workflow 参与者占用；不新增自动等待队列、daemon 或通用额度／计费器。
- [x] 对空闲、多个普通 Agent、活跃对话及历史积累分别记录观察订阅数、CPU／内存、列表加载和存储增长；不能仅以删除 Task 字段宣称性能提升。
- [x] 继续遵守 SwiftUI 原生状态、actor I/O、DI 和有界后台请求规则；查询和文件 I/O 不阻塞 Viewer 键盘接收链路。

## 8. 实施、验收与交付

| 顺序 | 工作 | 退出条件 |
| --- | --- | --- |
| A | 固定契约、建立失败用例和迁移夹具 | 八项范围及以下验收场景均有归属；旧行为和旧格式可复现 |
| B | 提取共用交互，接回 Workflow | 原流程的投递、回执、提问、步骤完成、人工接管和恢复测试通过 |
| C | 切换 Orbie／Orbiter，移除 Task 产品层 | 普通对话不生成任何 Workflow；Agent 创建、定位与消息独立于 Workflow 存储 |
| D | 数据迁移、界面、查询与标签 | 原有对话和产物可找回，未确认消息可核查，候选导航准确 |
| E | 故障、原生及跨端回归，文档和旧代码清理 | 验收证据与未测边界齐全，源码和契约均不再依赖旧 Task／隐式 Workflow 路径 |

- [x] 按 A–E 顺序推进，每段记录实际变更、测试、证据与未测项；3-Fix 的完成范围是全部八项，不能只提交列表过滤作为完成。
- [x] 定向单测覆盖状态迁移、真实输入队列及错误事件；SwiftFormat lint、两项仓库边界检查与 `git diff --check` 通过。
- [x] 编译受影响的 Mac target；涉及共享 UI／wire 的 iOS 消费者时做设备 SDK 编译及协议回归，不额外构建 iOS Simulator。
- [x] 在隔离签名 App、私有 tmux／状态根中分别验证真实 Codex 和 Claude Code，记录 CLI／插件版本；tmux 3.6a 的既有输入支持必须保留。
- [x] 回归 Mac Viewer／iOS 的终端、通知目标、控制权及 Workflow 的共用模型／协议，验证可选标签的旧格式读取及查询授权。当前通过的是自动化回归与设备 SDK 编译；真实跨设备操作尚未执行，不把构建成功算作实机验收。
- [x] 更新 [global-agent-design.md](../../global-agent-design.md)、[services-reference.md](../../services-reference.md)、[agent-identity.md](../../agent-identity.md)、[ctrlx-cli-api.md](../../ctrlx-cli-api.md)、[文档索引](../../README.md)及本目录状态；源码实施前只标记修订方向，不将计划写成现有能力。
- [x] 记录剩余风险与真实未测场景；安装、发布及阶段 4–6 另行执行，不因本阶段计划确认自动开始。

### 必须验收的场景

| 场景 | 通过条件 |
| --- | --- |
| 连续普通对话 | Orbie 和 Orbiter 各至少 20 轮确定性回归；Agent／原生会话按预期复用，Workflow 配置及运行数均不增长 |
| 同一 Orbiter 的不同使用方式 | 自由对话 → 单 Agent Workflow → 对话 → 多 Agent Workflow → 对话均可接续；流程结束不关闭或归档 Agent |
| Workflow 故障隔离 | Workflow 账本缺失或损坏时错误可见，Orbie 普通创建、定位及消息仍可用；不重建或覆盖损坏流程数据 |
| 人工输入与等待 | 本机／Viewer 草稿、复制模式、审批、提问及接管不被覆盖；普通交互不要求 Workflow Continue，流程本身的暂停规则不变 |
| 身份与轮次 | 切账号、重启、Resume、pane 移动、同名替代及迟到 Stop 不串状态／回复；人工消息不推进无关流程 |
| 关闭与重新打开 | 关闭面板不结束 Agent 或创建新标签；Agent 退出但原标签存活时使用原恢复入口；Host 离线／扫描失败不误判标签已删除 |
| Orbie／Orbiter 误关闭恢复 | Codex、Claude Code 分别验证实际 Close Tab 后再打开入口；刷新／重启不自动复活，显式恢复原对话后仅有一个新标签，角色关联更新，历史请求／Workflow 原绑定不变，旧回复及材料仍可读 |
| 恢复失败与待确认消息 | 覆盖原生历史缺失、CLI 拒绝恢复、未结束／待确认消息、重复点击及恢复启动丢回包；入口不永久锁死，不重复创建、不重发旧输入，不静默新建或改用最新会话 |
| 创建和投递不确定 | 创建丢回包、写入后断开／崩溃、结果到达但保存失败均不重复创建或发送；新草稿不会被旧确认清空 |
| 迁移与中断 | 完成／执行中／未确认／未创建成功的旧记录、重复 Agent 关联、附件引用、普通 Workflow 均保留；备份、故障后重入和重复启动不丢失／重复记录 |
| 查询与候选 | Codex／Claude 的授权查询、有界结果、非首标签、多 Host、已关闭目标及同名标签都正确；普通进程或伪造目标不能扩大访问 |
| Workflow 标签 | 无标签旧配置可读取，编辑／复制／筛选行为明确；标签不改变执行对象、身份或完成规则 |
| 资源与前后台 | 空闲与历史积累的开销有证据；关闭面板停止 UI 刷新但保留已发送消息，后台结果不激活窗口，Viewer 输入不被查询阻塞 |

现有测试入口包括 `OrbieTests`、`OrbiterTests`、`OrbiePanelTests`、`OrbieCommandTests` 及 `AgentWorkflow`、Fork、身份、恢复、通知相关套件。实际过滤表达式以实施时的源码及拆分结果为准；不能用旧阶段的测试数量代替本阶段运行结果。

### 验证记录

2026-11-16，当前工作区：

- A／B：提取 `AgentRuntimeCatalog`、`AgentInputWriter`、`AgentReplyEvidence` 和 `AgentReplyMonitor`，Workflow transport／monitor 已接入。普通消息与 Workflow 各保存自身必要记录，不为同一次普通投递重复建立 Workflow。
- C：`AgentMessageStore` 每条消息独立落盘；Orbie／Orbiter 普通投递不调用 Workflow save/start，取消 Task 完成／归档及双任务上限。确定性 Codex／Claude 参数化测试各覆盖 Orbie、Orbiter 连续 20 轮；真实 Runner 测试覆盖对话、单／多 Agent 流程、再对话。
- D：schema 2 角色关联、旧索引合并、明确关联 ID 的消息迁移、附件独立保留、失败后重入、用户编辑模板保留。查询改为 `orbie agents/workflows list/show`，内核 peer 身份及当前原生调用方继续核验；Files 预览材料／附件；Workflow 标签不参与执行身份。
- D：`AgentRoleRecovery` 保留原生描述和核验进程证据，主动 Close 前复用工作区采集；已关闭目标只允许显式恢复。创建意图先落盘，丢回包不再启动第二次，核验后才变更角色 AgentID。运行历史、旧消息证据及 Workflow 绑定不变。扫描失败、历史缺失、CLI 退出及无法核验均显示具体原因。
- 扩展回归 `regression-2.log` 共 581 项：580 通过；唯一失败是旧 socket 测试仍检查已删除的 `orbie.tasks.*`。夹具改为四个 Agent／Workflow 查询方法后，`final-targeted.log` 的 10 项测试全部通过，含真实 OS peer、共享流程接续、恢复证据和 Claude 普通消息拒绝解析。
- 资源：`final-targeted.log` 为串行测试进程采样，空闲／5 个空闲 Agent／完成／255 条历史均无消息观察任务；5 条待回执消息仅保留 5 个确认计时器。各状态 200 ms 区间 CPU 为 0.000146–0.000315 s；进程峰值 RSS 约 96–100 MB（包含测试框架，不是 App 内存）。255 条记录 375685 bytes，读取最近 100 条约 7.38 ms。只说明该组件的观察与存储边界，不作为整 App 的性能对比。
- 原生：私有 HOME、配置、tmux 3.6a socket 与 loopback 模型，不使用用户账号或活跃任务。Codex 0.169.0／Claude Code 2.1.319 的首轮、续聊、空草稿预检、人工草稿保护、审批等待和停止等待通过，Workflow Definition／Run 数量均为 0；证据 `native/native-report.json`、`native/native-tests.log`、`native/native-ledger.json`。
- 迁移补充 `migration-tests-2.log`：4 项测试通过（包含四种投递状态、失败后重入、旧 Task 合并与备份原字节核对）。共用 Hook 证据改为只在独立目录保存成功后发布内存状态，移除生产链路向 Workflow 账本的重复写入；`final-services.log` 的 50 项服务／CLI 测试通过。
- Mac 最终增量构建通过（`mac-final-build.log`）；iOS device SDK 编译通过（`ios-device-build.log`）。没有额外构建 iOS Simulator，也没有安装这些未签名的编译产物。
- 本轮使用源树 Codex／Claude hooks 1.0.0。最终 `native-final/native-report.json`、`native-final/native-tests.log` 记录真实 CLI 对话和恢复复验通过：实际关闭私有旧 tmux window 后，指定同一原生 CID 在新 pane 恢复并读取原回复；不是找最近会话。该实验不等同于在 App 中点击 Close／Restore 的整条 UI 链路。
- SwiftFormat lint（最终 59 个受影响 Swift 文件）、品牌边界、技术边界和 `git diff --check` 均通过，见 `final-lint.log` 及边界检查日志。

所有新证据位于仓库忽略的 `.build-local/orbie-3fix/`。阶段 1–3 原验收记录仅作为历史，不冒充本轮结果。未执行新版本安装、发布、真实远端 Mac Viewer／iPhone 操作及阶段 4–6；没有把单元测试或设备 SDK 编译称作真机 UI 验收。

#### 隔离 App 与未测边界

- `app-smoke-report.json`：最新 Mac 构建复制到 `.build-local/upstream-browser-proof.orbie-3fix/CtrlX.app`，独立 bundle ID，ad-hoc 重签并严格校验；私有 HOME、state、API socket、tmux socket，E2E 内存偏好／密钥，Relay 指向 loopback。正常及故意损坏 Workflow 账本两次启动均通过；Orbie 查询服务可用、无授权调用被拒绝、损坏文件原文保留。进程与私有 tmux 已停止；没有替换已安装 App。
- 原生 CLI 实验覆盖真实会话／转录、输入及原生恢复；服务单测覆盖角色重绑、创建意图、回包丢失、未完成消息及历史证据不变。尚未执行新界面中实际点击 Close Tab → Restore 的整条链路、用户真实 Provider／账号切换、远端 Mac Viewer／iPhone 上的人工交互、真实弱网与长期 App 资源采样。这些不能由编译或本机 fixture 代替。
- 旧阶段与本轮的失败日志都保留：旧 socket 测试夹具已修正；两次新增迁移／接续测试的编译拼写修正后均已重新通过。首次 Mac 编译准备使用了额外依赖目录，已停止并改用仓库共用 SourcePackages；最终构建成功记录为准。
- 本阶段实现范围完成，后续实机验收与阶段 4–6 分开推进；本轮未提交、未安装、未发布。

#### Review round 1 修复

- [x] P1：普通消息核验主动刷新共用运行目录，成功扫描后间隔 10 秒再刷新，冷启动不依赖面板或 Workflow。缺失运行实例超时后保留待确认记录；刷新 Orbie／Orbiters 可重启原证据核验，不重新写入终端。重复刷新不重置已有 reader 的游标或超时。
- [x] P2：通过 peer、原生会话、轮次、转录路径及运行绑定校验的原生失败直接保存 `.failed`、原始原因及结束时间，取消回复监测；重启也可完成已保存失败事件，继续发送不再被该消息阻止。
- [x] P2：完整 Orbie／Orbiter 会话增加更早／更新／最新记录入口，每页 100 条，按消息 ID 固定页边界；新消息不挤走正在阅读的旧页。紧凑面板和可发送状态仍读取最新记录，旧回复及迁移附件保留访问入口。
- 验证记录位于 `.build-local/orbie-3fix-repair-1/`：`regression.log` 本轮 96 项测试通过，包含冷目录启动、无人刷新时延迟出现的 Agent、超时后刷新重验、错误身份／轮次失败拒绝、保存失败事件的重启恢复、250 条历史前后翻页／附件／新增消息不移动旧页，以及共用 Workflow 核验、迁移和既有离屏面板测试。首轮 `tests.log` 24 项通过，与该轮存在重叠，不合并计数。
- SwiftFormat（11 个本轮变更文件）、品牌边界、技术边界及 `git diff --check` 通过；按顺序准备三个 native helper 后，Mac Debug workspace 编译通过（`mac-build.log`）。本轮未重跑真实 Codex／Claude CLI 场景，未执行已安装 App 或跨设备人工 UI 验收，未提交、未安装、未发布。

#### 临时目录扫描故障补充修复

- [x] 将目录状态读取纳入 `AgentReplyMonitor` 现有的临时检查失败处理，复用 200 ms 重试间隔和 60 秒预算；预算耗尽才转为待确认并退出监测，非临时错误仍直接失败。
- [x] 仅成功扫描推进 10 秒刷新间隔；失败后继续主动扫描，不能将旧缓存视为恢复成功。不新增后台队列或重新投递路径。
- 修复前 `before.log` 已复现冷／热缓存监测提前退出及无重试；修复后 `after.log` 的 74 项消息／Workflow 核验、恢复及转录回归通过。记录保存在 `.build-local/orbie-3fix-repair-2/`；新用例覆盖扫描恢复后无需面板／Hook 自动确认、持续故障预算耗尽、非临时错误直接退出、退出后显式刷新重验及不重发输入。
- 清理测试捕获警告后，`final-targeted.log` 两项新增参数化测试（共四个场景）复验通过；SwiftFormat（4 个文件）、两项仓库边界检查及 `git diff --check` 通过。
- 本轮为核验控制流修复，未重跑 App 整包构建、真实 CLI 或人工 UI 验收；未提交、未安装、未发布。

#### 生产扫描入口错误分类补充

- [x] `scanWorkflowInstances` 对 tmux／ps 快照不可用抛出 `AgentWorkflowInspectionUnavailable`，进入已有重试路径；正常空快照保持成功，不将任意其他错误一并转为可重试。
- 新增用例通过 `ProcessRunner` 模拟 tmux／ps 命令失败，调用生产扫描入口后接回消息监测，覆盖错误类型、无需面板／新 Hook 自动恢复、正常空快照和不重发输入。修复前 `.build-local/orbie-3fix-repair-3/before.log` 已复现两种命令故障导致监测提前退出；修复后 `after.log` 的 77 项消息、进程扫描及 Workflow 原生事件回归通过。
- SwiftFormat（2 个文件）、两项仓库边界检查及 `git diff --check` 通过。本轮未重跑 App 整包构建或真实 CLI／人工 UI 验收；未提交、未安装、未发布。

#### 正常退出到 shell 后的角色恢复修复

- [x] 正常退出仍清理工作区自动恢复状态，但保留 Orbie／Orbiter 已核验的原对话描述；确认替换 Agent／原生会话时才使旧角色恢复证据失效。即使工作区快照已经变成 shell，也会检查独立保留的角色证据。
- [x] 原标签存活时显示 Resume Original Conversation，经用户确认后复用现有输入队列、shell 启动及持久 pane／进程守卫恢复，AgentID 不变；原标签已关闭时通过现有创建路径恢复，核验同一原生对话后关联新 AgentID。终端仍有程序运行时拒绝重启；恢复意图和 pane token 防止丢回包后重复启动。
- [x] 旧版本已清空描述的记录可在显式恢复时，通过角色保存的准确会话 ID 和原生插件历史校验重建描述；不按目录、标题或最近会话猜测。新记录明确标记的替换失效不走旧数据补救。缺少历史或插件时保留具体错误，不重发旧消息。
- `.build-local/orbie-resume-fix/regression-4.log` 的 52 项定向测试通过，包含 Codex／Claude 退出到 shell 后关闭最后一个标签再恢复、旧记录修复、替换拒绝、同 pane 恢复、丢回包及原生历史缺失。隔离 tmux 覆盖实际 shell respawn、保持持久身份、忙碌进程保护和 pane 身份改变拒绝。离屏 UI 检查覆盖完整窗口／唤醒面板的两类入口，并实际触发关闭标签后的恢复动作、核对角色更新和草稿保留。
- 扩展回归发现旧 `publishesProcessIncarnation` 断言仍要求新进程继承旧进程的 working 状态；单独运行同样失败。按既有身份规则修正测试，未修改对应生产状态逻辑。初期测试编译和夹具错误日志保留，以 `regression-4.log` 最终通过记录为准。
- SwiftFormat（15 个 Swift 文件）、品牌边界、技术边界及差异检查通过；按顺序准备三个 native helper 后，Mac Debug workspace 编译通过（`mac-build.log`）。本轮未重跑真实 Codex／Claude CLI 对话或另一台 Mac 的用户数据恢复；隔离 tmux／离屏 UI 不能代替这些验收。未提交、未安装、未发布。

#### 恢复意图结算与明确拒绝重试

- [x] P1：复用工作区采集和 Orbie／Orbiter 主动目录刷新，在核验同 pane、同插件及同原生会话已运行后结算原地恢复意图。普通缓存读取不结算；并发 `restore()` 不再写回已结算意图，后续正常退出可以再次 Resume。已关闭标签的新建意图仍保留防重复创建记录。
- [x] P2：仅 tmux 明确返回进程或持久身份守卫拒绝标记时归类为 `NotLaunched`，重置尝试状态并允许重新检查。超时、丢回包及其他无法确认是否执行的错误仍保留意图。
- 证据位于 `.build-local/orbie-resume-review-fix/`：`before.log` 的新增回归复现两项问题；`after.log` 的 49 项定向测试通过。覆盖三种后续确认入口、仅有缓存不得确认、启动／检查期间并发结算、再次退出后第二次启动，以及真实隔离 tmux 在预检后改变进程／pane 身份、拒绝时未启动、重试成功。既有丢回包、关闭后恢复及恢复入口离屏 UI 回归也通过。
- 本轮 6 个 Swift 文件的格式检查、品牌／技术边界及 `git diff --check` 通过；顺序准备 native helper 后，Mac Debug workspace 编译通过（`mac-build.log`）。未在已安装 App 或另一台 Mac 上进行人工恢复操作；未提交、未安装、未发布。

#### 延迟启动后的自动恢复关联（2026-11-17）

- [x] Orbie／Orbiter 复用面板现有刷新，检查已明确发起的持久恢复意图；原标签关闭后，新标签延迟启动也会在核验原 Host、pane、插件及原生对话后自动接回，无需第二次点击。观察路径只核验／定位现有标签，不启动进程、不补发输入，App 重启或启动回包丢失后也保持这一规则。
- [x] 启动等待显示普通“正在恢复”状态；终端关闭、身份改变、扫描失败仍显示实际错误。完整对话有旧的待确认消息时仍继续恢复核验；草稿、历史、材料及 Orbiter 当前选择随角色关联保留，历史消息的原 AgentID 不变。
- `.build-local/orbie-restore-refresh/tests-3.log`：30 项测试／7 个套件通过，包含 Codex／Claude 延迟核验、持久意图重载、丢回包复用同一标签、仅缓存不得接回、错误身份／失效记录／未启动意图／扫描错误、原地恢复意图结算及已有 Orbie／Orbiter 消息回归。离屏 SwiftUI 验证两个 Orbie 窗口的恢复状态，完整对话实际通过现有刷新定时器自动接回。
- 初次测试的 `try` 遗漏、夹具目录未创建和静态文本无障碍属性断言已修正，早期日志保留，以上最终结果为准。9 个 Swift 文件格式检查、两项仓库边界检查和差异检查通过。未安装、未发布；未使用用户运行中的 Agent 做测试。
- 顺序准备三个 native helper 后，Mac Debug workspace 编译通过（同目录 `mac-build.log`，未签名编译检查）；未执行真实 Codex／Claude CLI 恢复或安装后人工验收。源码未提交。

#### 自动恢复的错误隔离补充

- [x] P1：Orbiter 将单个终端检查／恢复核验错误保存在对应 AgentID 下，详情页保留原因，仅阻止该 Agent 的输入；继续处理其他 Agent 的刷新、发送、新建和关联。缓存读取不清除错误，重新核验成功后清除；取消仍向外传播，共享目录／存储错误仍按原路径报告。
- [x] P2：原生恢复测试中，守卫拒绝后的第二次启动已执行但尚待原生会话核验，预期改为 `AgentRoleRecovery.Starting`；首次明确拒绝仍预期原错误并检查未启动。
- `.build-local/orbie-restore-review-fix/tests.log`：32 项测试／8 个套件通过，包括单 Agent 终端关闭、会话不符、终端检查失败时健康 Agent 的三类操作与后续恢复，及隔离 tmux 的 shell／busy／changed／process-race／identity-race 五个场景。3 个本轮 Swift 文件格式、两项边界和差异检查通过。本轮未重复 App 构建；未提交、未安装，未向用户运行中的终端发送测试输入。


### 2026-11-17：全局浮窗交互重设计

- [x] 按已确认的 [浮窗方案](PANEL_REDESIGN.md) 实现原生标题切换器、最近三轮对话、底部输入及操作菜单；窗口按有界内容调整，完整历史继续使用原有分页。
- [x] 根据现有消息证据和 readiness 显示阻塞原因，直接打开终端／重新检查／明确结束等待；发送、恢复和工作流占用规则继续由原 Service 执行。
- [x] Orbie／Orbiter 草稿和撤销隔离；复用现有创建表单，支持从选中的已验证 Orbiter Fork，不自动发送初始消息。
- [x] `.build-local/orbie-panel-redesign/tests-final.log`：22 项定向测试／5 个套件通过，包含原生切换器点击、输入法与换行、窄窗口／浅深色渲染、恢复及 Fork 身份回归。格式、两项仓库边界、差异检查及 Mac Debug workspace 编译通过。
- [x] 修复发送后撤销崩溃和 Orbiter 轮询的空态收缩；24 项定向测试通过，包括原生发送／撤销、延迟刷新高度稳定及失败保留消息。记录：`.build-local/orbie-panel-redesign/review-fixes-tests-final.log`。Mac Debug 编译、格式及边界检查通过。
- [x] 补齐打开／切换会话时定位最新内容、底部跟随和上翻保留位置；恢复启动错误展示及手动重试。32 项定向测试通过，记录：`.build-local/orbie-panel-redesign/followup-tests-final.log`；Mac Debug 编译、格式及边界检查通过。
- 验证使用隔离消息数据和离屏原生控件；未安装、未提交，未执行安装后全局唤醒、多显示器、真实输入法及真实 CLI Fork 人工验收。原型网页的加载故障不等于原生界面验收结果；原生截图与边界见方案文档。

### 2026-11-18：普通消息漏 Stop／重启后的回复核验

- [x] Orbie／Orbiter 已收到可信投递回执的普通消息，复用原生解析器和增量 reader，在漏 Stop 时核验同一会话／轮次的持久完成记录。读到完整记录边界并重新核验运行绑定后保存回复、解除发送阻塞；App 重启不重发输入，不依赖面板保持打开。
- [x] 显式后续工作、错误身份／轮次、缺少回执和未完成记录均不得完成消息；迟到回调不覆盖已保存回复，保存期间到达的新 Stop 仍保留核验。Workflow 自动交接继续要求 Stop，普通消息恢复不推进流程。
- `.build-local/agent-message-recovery/tests.log`：114 项测试／10 个套件通过。新增回归使用生产 Codex／Claude 解析器，覆盖重启期间完成、重启后完成、运行中漏 Stop、持久结果重载、迟到／并发 Stop、错误会话／轮次、半条记录、缺少回执及 pending work；既有消息、资源回收、Workflow、Orbie／Orbiter 和转录解析回归通过。
- 4 个 Swift 文件的 SwiftFormat、品牌／技术边界及差异检查通过。本轮执行包测试编译，未重复 App 整包构建、真实 CLI 对话或安装后人工验收；未提交、未安装。

#### 原生恢复与已入队 Stop 的时序修复

- [x] P1：原生恢复落盘前等待现有 ingress FIFO，再等待该消息已排队的校验；候选被 Stop 更新后重新进入核验，不使用旧 `.submitted` 的完成结果绕过 pending work。同步只用于回复恢复，不放入事件消费或终端输入路径。
- [x] 入站服务启动期间暂不可用时复用有界重试，成功的中间进程检查不再重置整次核验的失败预算；同步后仍复核当前身份与候选。
- `.build-local/agent-message-recovery-review/targeted-2.log` 的 25 项测试及 `regression.log` 的 97 项测试通过，共 122 项／12 个套件。新增隔离 socket 回归通过生产 Claude 事件解析、消息服务和转录 reader，分别阻塞完成度分类和消息内部校验：ACK／原生 summary 先到时仍保持等待，pending Stop 不结束消息，最终回复正常保存且只投递一次。分类与进程检查使用可控夹具，不调用真实 Apple Intelligence 或用户 Agent。
- 7 个 Swift 文件的格式、品牌／技术边界和差异检查通过。包测试编译通过，未重复 App 整包构建或真实 CLI／App E2E；未提交、未安装。
