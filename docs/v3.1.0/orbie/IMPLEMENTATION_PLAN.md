# Orbie 实施计划

初版日期：2026-11-13，源码基线：`dddc4b0c`（CtrlX 3.0.162）。阶段 3-Fix 修订：2026-11-14，源码基线：`7d2737e1`。依据：[Orbie 设计方案](../../global-agent-design.md)及本轮已确认的 Agent／Workflow 职责调整。状态：**阶段 1–3 已实现并通过当时的定向单测、Mac 编译及本机隔离验收；阶段 3-Fix 源码已落地，自动化／真实 CLI／隔离启动及 Mac、iOS device 编译通过；实机 UI 边界见执行清单；阶段 4–6 未开始**。历史完成项、命令与未测边界见 [STAGE1_TODO.md](STAGE1_TODO.md)、[STAGE2_TODO.md](STAGE2_TODO.md) 和 [STAGE3_TODO.md](STAGE3_TODO.md)；新增执行清单见 [STAGE3_FIX_TODO.md](STAGE3_FIX_TODO.md)。

先完成「唤醒 Orbie → 创建或 Fork Orbiter → 对话及可选流程 → 找回并继续」，再增加文件记忆。按 **1 → 2 → 3 → 3-Fix → 4 → 5 → 6** 推进；3-Fix 完成后才能进入阶段 4。每阶段保留可运行、可验证的成果；词库、自动 Dreaming 和自主分派另行推进。

2026-11-16 补充：**误关闭 Orbie／Orbiter 的 Agent 标签后的显式恢复**纳入 3-Fix 的生命周期、界面和验收范围；实现与验证见 3-Fix 清单。关闭浮动面板、Agent 退出但标签存活、主动关闭标签三种情况分别处理。

本目录沿用仓库的版本化计划组织方式；`v3.1.0` 不是发版承诺。阶段 1–3 的正文及 TODO 保留历史实现与验收事实；其中的单步 Workflow 投递、独立 Task 索引、归档及双任务上限由 3-Fix 替换，不再作为后续实现要求。下述首版边界、数据职责和阶段 4–6 已按新方向调整，当前完成范围与未测边界以 3-Fix 清单为准。决策记录见 [ISSUES.md](ISSUES.md)。

## 1. 阶段 3-Fix 起采用的产品边界

产品保留 Agent 与 Workflow：Orbie、Orbiter 都是普通 Agent 的角色；一个 Workflow 可由一个或多个 Orbiter 执行，同一 Orbiter 可持续对话并先后参与不同 Workflow。不增加独立 Task 实体或任务状态机。

| 项目 | 首版安排 |
| --- | --- |
| 承载位置 | 先在一台指定 Mac 的 Host 本地实现，显式启用；不自动在其他设备创建第二个 Orbie |
| Agent 类型 | 先用 Codex 验证首条链路，再通过相同能力接口验收 Claude Code；用户选择 Agent／Provider，不改其全局默认设置 |
| 运行方式 | Orbie 和 Orbiters 都是普通 tmux Agent 标签，使用现有 New Agent、Fork、Resume 和 shell 集成 |
| 标签命名 | 主标签为 Orbie；Orbiter 使用便于识别的短名称，复用标签重命名；展示名不参与身份验证 |
| Agent 创建 | 用户明确选择 New Agent 或原生 Fork；不同 Agent 类型使用 New Agent 交接材料，不转换原生历史 |
| 标签误关闭 | 不自动复活已关闭标签；用户选择「恢复原对话」后，复用原生 Resume 在新标签恢复，核验成功再更新角色绑定；历史不足时明确提供新建 |
| 全局面板 | 输入、简短回复、Agent／Workflow 查找和显式导航；完整终端及权限／提问交互使用既有页面 |
| 普通对话 | 通过共用 Agent 交互能力投递，不生成 Workflow Definition／Run／Node |
| Workflow | 只有明确创建流程时才保存配置；简单标签仅用于分类、筛选和检索 |
| 并发 | 每个 Agent 保留输入互斥，Workflow 保留参与者占用规则；取消两个活跃 Orbiter 任务的产品上限，不新增自动等待队列 |
| Viewer | 已配对 Mac／iOS 继续查看和操作普通 Agent 标签；首版不增加远端 Orbie 专用面板、跨 Host 调度或记忆同步 |
| 数据与清理 | 使用已有状态根和文件目录；保存必要的 Agent 关联、投递与回复记录；不另存完整原生聊天历史，不自动删除会话或产物 |

Orbie 忙碌不影响查找、显式导航及新建 Orbiter。关闭面板不停止 Agent 或 Workflow；消息取消、流程停止后续投递与中断／退出 Agent 继续分别表达。Workflow 完成不结束或归档其参与 Agent。

## 2. 实现落点：只增加产品需要的状态

| 关注点 | 已核对的入口 | 计划新增或调整 |
| --- | --- | --- |
| 启动、Provider 与目录 | [SessionLaunchPreparation](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/SessionLaunchPreparation.swift)、[工作流创建入口](../../../CtrlxPackage/Sources/CtrlxServerFeature/Coordinators/AppCoordinator+WorkflowCreation.swift) | 提取必要的共用创建入口，移除普通 Agent 创建对 Workflow 服务初始化的依赖；不拼装另一套启动命令 |
| Fork | [AgentForkService](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/AgentForkService.swift) | 绑定用户确认的源对话和目标目录；保留当前 Provider 默认模型／effort 与快捷按钮行为 |
| 身份与恢复 | [身份契约](../../agent-identity.md)、[AgentSessionIdentityClient](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/AgentSessionIdentityClient.swift)、[恢复契约](../../workspace-recovery-design.md) | 沿用 AgentID(hostID, persistentPaneID)；window 是位置，进程／原生对话是操作证据，不增加身份注册表或平行恢复引擎 |
| 投递与结果 | [AgentWorkflowService](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/Workflows/AgentWorkflowService.swift)、[Runner](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/Workflows/AgentWorkflowRunner.swift)、[InputGate](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/Workflows/AgentWorkflowInputGate.swift) | 从现有实现提取共用 Agent 交互能力；Orbie／Orbiter 与 Workflow 共用运行目录、输入保护、回执和原生回复核验，图编排留在 Workflow |
| 状态与路径 | [OrbieStore](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/OrbieStore.swift)、[OrbiterStore](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/OrbiterStore.swift)、[CtrlxPaths](../../../CtrlxPackage/Sources/CtrlxServerFeature/Plugins/CtrlxPaths.swift) | 移除 Task 层，收敛为 Agent 角色／来源关联、创建意图和必要消息记录；目录保留，迁移不改名或删除材料 |
| 选区与图片 | [InteractiveTerminalView](../../../CtrlxPackage/Sources/CtrlxServerFeature/Views/InteractiveTerminalView.swift)、[Files](../../../CtrlxPackage/Sources/CtrlxCommon/UI/WorkspaceFileBrowserView.swift)、[Browser](../../../CtrlxPackage/Sources/CtrlxCommon/UI/RemoteBrowserView.swift)、[Simulator](../../../CtrlxPackage/Sources/CtrlxCommon/UI/RemoteSimulatorView.swift) | 在已有文本选择、截图和标注上增加 Orbie 入口，触发时固定来源 |

依赖方向为：Orbie／Orbiter 界面和 Workflow 编排分别调用共用 Agent 交互能力，后者使用现有 tmux、插件事件及会话状态。只保留一份投递与回复事实；技术上的消息／请求 ID 不成为新的产品 Task。Workflow 的节点、边、循环和显式步骤完成继续由原编排层负责。普通对话不得通过隐藏、重命名或复用单个 Workflow 模板实现脱钩。

新增代码主要在 `CtrlxServerFeature`：协调入口和 UI 使用主 actor，持久 I/O 使用 actor 或现有依赖客户端；不增加 ViewModel。确有两端消费者后再下沉到 `CtrlxCommon`，不为尚未开发的 Viewer 提前增加协议。

### 数据职责

| 数据 | 内容与约束 |
| --- | --- |
| Agent 关联 | Orbie 指定的 AgentID、Orbiter 的必要角色／来源关联；名称、目录及运行状态从已有 Agent 数据读取，不另分配 Orbiter 身份 |
| 创建意图 | 创建前保存请求关联；回包丢失先核对已有证据，确认后关联 AgentID；无法确认时不重复启动 |
| 原对话恢复依据 | 复用最近核验的恢复描述，保留 Agent 类型、原生会话及必要启动上下文；主动关闭后仍可供显式恢复使用，不以名称／目录推断，不保存登录凭据或完整聊天副本 |
| 消息记录 | 发送时的文本／附件、目标、运行态证据、确认状态和原生轮次／回复引用；结果不明不重发，不复制完整原生聊天历史 |
| Workflow | 用户显式创建的配置、参与者、运行与结果；可有简单分类标签，标签不参与权限、身份或完成判定 |
| 材料与产物 | 继续作为普通文件由 Files 打开；旧 `TASK.md`／`RESULT.md` 保留但停止自动维护，文件出现不代表执行成功 |
| 长期记忆 | 全局偏好、对应项目的规则、带来源与验证时间的方法；不保存实时忙碌状态或拿旧结论代替当前查询 |

沿用已有状态根及 `agents/main/`、`agents/experts/` 下的材料目录；项目 Agent 继续使用实际项目／worktree。旧目录名不再解释为运行中的 Task 身份，迁移不强制重命名目录，后续消息不新建目录。文件格式带版本，持久化失败时停止相关新操作并保留原数据。

Orbie 只查询本功能创建或用户明确关联的 Agent／Workflow 范围，不因取消 Task 索引扩大读取权限。不导入全部历史、不从同名标签猜原对话。孤立的创建记录保留待核对，不自动接管不明进程。

## 3. 分阶段交付

| 阶段 | 用户可见成果 | 依赖 |
| --- | --- | --- |
| 1. Orbie 绑定与投递 | 在 CtrlX 内打开固定 Orbie，完成一次有结果记录的对话 | 默认值与单步复用验证 |
| 2. Orbiter 与任务接续 | 创建分身、查看结果、重启后找到并继续任务 | 阶段 1 |
| 3. 全局唤醒与查找 | 在其他 App 中唤醒 Orbie，查询并打开正确任务 | 阶段 2 |
| 3-Fix. Agent／Workflow 职责收敛 | 普通对话不创建 Workflow，取消 Task 层，保留 Agent／Workflow 查询及历史 | 阶段 1–3；清单 [STAGE3_FIX_TODO.md](STAGE3_FIX_TODO.md) |
| 4. 从选区派发 | 选中文字或标注图片，带原始来源交给 Agent；明确选择时创建 Workflow | 阶段 3-Fix |
| 5. 最小文件记忆 | 显式记住、按项目读取、手动整理候选 | 阶段 3-Fix、4 |
| 6. 验收与试用 | 两条核心路径及恢复、资源边界通过验证 | 阶段 1–5，包含 3-Fix |

以下阶段 1–3 是已完成的历史实施范围；其 Task／单步投递方案由阶段 3-Fix 替换，验收记录不追溯改写。

### 阶段 1：先证明普通 Agent 能承载 Orbie

- 增加最小绑定存储与「打开 Orbie」应用内入口。首次显式创建，后续打开同一持久目标；创建处理中拒绝重复启动。已有 Orbie 退出或目标失效时展示恢复／重新建立入口，不静默另起一份。
- 复用现有 Agent 启动表单和 Provider 选择。Orbie 在 `agents/main/` 运行，提供最小角色说明；Codex 的既有 `--no-daemon`、退出后的 shell function、模型默认值均不改。
- 通过单步工作流提交第一条消息，并显示本次输入、等待原因和核验后的回答。绑定初次原生会话的规则继续由现有通道负责。
- 主对话忙碌、有未提交草稿、等待提问／授权时保留面板草稿；明确提示打开终端继续处理。不清空终端输入，不通过键盘模拟绕过 InputGate。
- 先验证应用重启且 tmux 存活的接续；涉及 tmux 重建时对接已有恢复目标，不在 Orbie 服务里恢复终端拓扑。

**验收门槛：** Codex 和 Claude Code 各完成首条对话；连续打开入口只创建一个 Orbie；持久 Host／window／pane 不变时，切账号、Resume 或恢复后重新核验当前运行态并自动接续，无需手动 Reconnect。手动输入或发送期间的进程／会话替换仍阻止过期投递；既有请求保留原核验记录，应用重启不重发原消息。新用例及相关身份、输入门控回归通过后进入阶段 2。

### 阶段 2：创建 Orbiter，保存并接续任务

- 增加任务列表／详情及 New Agent、Fork 两种明确操作。标题遵循任务命名规则，目录默认值可修改；代码任务使用实际项目／worktree，材料目录不冒充代码目录。
- New Agent 只交接目标、来源和选中的材料。Fork 使用已核验的 Orbie 原生对话；忙碌时不猜 Fork 边界，等待可核验时机或让用户选择 New Agent。
- 创建成功后等待实例确认，再按现有通道投递；失败保留任务草稿及已创建的标签／工作目录，重试前核对创建记录。
- 收到当前 invocation 的原生最终结果后保存简短摘要、证据、产物与待办。标明这是 Agent 报告；轮次结束不自动等于业务目标已验证。未完成任务可继续跟进，不需要伪装成成功。
- 提供显式「交给 Orbie 总结」入口；Orbie 忙碌时保留待处理结果，不自动把整段日志或迟到结果塞进它的输入区。
- 按任务名、项目、时间查找，显式关联已有标签。打开任务先解析当前持久目标；需要恢复时进入现有 Resume／Use Shell 流程。恢复原对话与重新投递任务分开处理。

**验收门槛：** New 与 Fork 的上下文边界符合预期；选择其他 Provider 后沿用其模型和快捷按钮默认值；同名任务不串绑定；重复点击、创建回包丢失、迟到结果及重启均不重复执行。已有其他工作流占用该实例时明确拒绝，不争抢其投递权限。

### 阶段 3：全局面板与自然语言查找

- 增加可配置的全局快捷键、菜单入口和轻量面板；前台其他 App 可以唤醒，Esc 关闭并恢复合理焦点。关闭面板保留草稿与后台任务，收到结果只更新状态／通知。
- 面板直接展示最近任务、当前状态和「打开标签」。这些操作调用程序逻辑，不等待 Orbie 的模型回答。
- 增加最小只读任务查询入口供 Orbie 使用，例如拟新增的 `ctrlx orbie tasks list/show`；通过现有本机 ingress 校验调用方，只返回已关联任务的有界摘要、来源和引用。当前 CLI 没有该能力，不能仅写提示词声称支持。
- 用户说「继续昨天那个音频问题」时，Orbie 查询真实任务记录并返回候选；候选携带 taskID，由程序重新验证并打开。有歧义时供用户选择，未收录时明确说明；不自动执行回答里的任意命令或路径。
- 主对话的简短回答取自已核验结果，不在新面板再次实现终端渲染或第二套模型连接；需要完整过程时打开普通标签。

**验收门槛：** 切换 App、多个窗口／显示器、面板重复开关不重复启动或抢焦点；Orbie 忙碌时仍能查询及打开任务；自然语言候选能定位非首个标签，目标已删除时不误打开同名标签。查询和文件 I/O 不占用终端键盘消息接收链路。

### 阶段 3-Fix：Agent／Workflow 职责收敛

状态：**实施中；源码切换与回归验收正在进行**。本阶段覆盖本轮确认的八项优化；执行项、源码入口和验收矩阵见 [STAGE3_FIX_TODO.md](STAGE3_FIX_TODO.md)。先完成本阶段，再进入选区、记忆及后续自动化。

1. **统一产品模型。** Orbie／Orbiter 都是普通 Agent；Workflow 可由一个或多个 Orbiter 执行，Agent 完成流程后仍可继续对话或参与其他流程。移除独立 Task 身份、完成与归档状态，不把 Task 改名后保留。
2. **沿用身份与生命周期。** 复用稳定 AgentID、New Agent／Fork／Resume、Provider 默认值、shell 集成及现有目录；创建意图只用于防重复创建。进程与原生对话用于单次操作核验，不能成为新的长期关联键。误关闭 Agent 标签后提供显式「恢复原对话」：依据核验过的原生恢复信息在新标签 Resume，成功后更新 Orbie／Orbiter 的 AgentID 关联；历史请求不改绑、不重发，证据不足时明确提供新建。
3. **提取共用交互。** 从现有 Workflow 实现迁出运行目录、输入检查、串行投递、回执和回复核验；普通消息不生成 Definition／Run／Node，Workflow 调用同一交互能力。启动及存储依赖分开，Workflow 加载失败不阻断 Orbie。
4. **明确交互边界。** 普通消息使用原生轮次确认回复，提问／审批留在普通 Agent 交互中；Workflow 保留现有步骤完成规则。自动投递共享占用与输入保护，人工接管阻止过期写入，手动回复不会误算成流程结果，未确认消息不自动重发。
5. **收敛界面与查询。** Tasks 入口改为 Orbiters，查询／候选使用 AgentID 或 Workflow ID；Workflow 列表支持简单标签。保持有界查询、调用方核验及显式导航；报告交接只追加 Orbie 草稿，不自动发送。
6. **移除 Task 层并迁移。** 按保存的关联 ID 识别旧内部记录，迁移输入、回复、附件和 Agent 关联；保留未确认投递、创建意图、普通 Workflow 及文件材料。备份并校验后切换，失败保留原数据，不按名字批量删除。
7. **控制资源和复杂度。** 复用一份运行目录和投递实现，只监测活跃消息，历史按需加载；取消双任务上限，保留每 Agent 输入互斥及 Workflow 占用。不新增 daemon、通用调度平台或完整聊天历史副本。
8. **分步验收并交付。** 依次完成契约／测试、共用交互、Orbie／Orbiter 切换、迁移／界面／查询和故障验收；覆盖 Codex、Claude Code 及已有 Mac Viewer／iOS 终端、通知和 Workflow 入口。更新设计、服务契约、CLI 及本目录状态，源码与文档收敛后才标记完成。

**验收门槛：** Orbie／Orbiter 连续普通对话不增加 Workflow 配置或执行；同一 Orbiter 能在自由对话、单 Agent／多 Agent Workflow 及之后的对话间接续；Workflow 存储故障不拖垮普通交互；新旧消息的身份、轮次和结果不串用；迁移中断、创建丢回包、账号切换和重启均不重发或丢历史。只有隐藏列表、增加内部 Workflow 类型或保留平行 Task 状态机不算完成。

误关闭恢复必须覆盖 Orbie 和 Orbiter：仅关面板不新建，原标签存活时复用原恢复入口，标签已删除时不因刷新／重启自动重建；显式恢复原会话只创建一个新标签，保留旧消息及材料。无可核验历史时不自动切换到最新会话或新建；未结束／待确认消息不永久锁死恢复入口，也不因恢复而重放或重新授权。

### 阶段 4：选区与标注派发

- 先接入 Mac Terminal 与 Files 中可选择的文本，再接入 Browser／Simulator 已有截图和标注。各入口复用 Agent 消息草稿和共用交互能力，不各造一套发送流程。
- 触发动作时冻结内容、Host、持久标签／资源身份、文件路径或 URL、采集时间。打开面板后即使切换标签，材料与来源仍保持原值。
- 预览允许选择「交给 Orbiter」「询问 Orbie」；只有用户明确选择流程时创建 Workflow，「记住」在阶段 5 可用。目标目录独立选择，其他 Host 的路径仅作为来源，不在本机解析为可用目录。
- 外部 App 首先支持用户主动粘贴；只有显式 paste 才读取剪贴板。macOS Services 选区入口在同阶段后段验证，缺乏可靠来源时明确省略，不抓取任意 App 全文。
- 媒体使用 3-Fix 提取的共用附件能力及现有类型／大小限制。图片画面使用截图，不许诺远端 Browser／Simulator 的任意文字都能直接选择。

**验收门槛：** 捕获后切换 Host／标签不会串材料；纯文本、文件来源、Browser 和 Simulator 图片均能送达所选 Agent；不支持的附件明确拒绝；取消派发不创建 Agent 或 Workflow，结果通知不切换当前标签。

### 阶段 5：最小文件记忆与手动整理

- 按设计建立 `main/` 的角色说明、`MEMORY.md`、`projects/` 和 `inbox/`。只创建缺失文件，不覆盖用户已有内容；Codex／Claude 按各自支持的指令入口接入。
- 显式「记住」可直接记录用户确认的条目、范围和来源。Agent 回复或 Workflow 结果中的可复用经验先进入候选；普通日志与实时状态留在各自既有记录。
- New Agent 显式收到相关文件路径或经过选择的内容；不能依赖不在进程工作目录中的 `AGENTS.md` 自动生效。Fork 保留原生快照，但需要最新记忆时单独读取。
- 提供查看、编辑、删除和手动整理入口。材料少时由 Orbie 整理，材料多时新建名为「整理记忆」的维护 Orbiter，只产出候选变更，由统一入口应用。
- 应用前检查原文件是否被用户修改，冲突停止并保留候选；不静默覆盖。无需引入数据库、向量检索、自动周期任务或全面历史扫描。
- 保留原生 CLI 记忆开关和目录；目录划分只是产品约定，不声称隔离了 CLI 原生记忆或构成文件权限沙箱。

**验收门槛：** 新 Orbie 对话能读取明确记忆并接续未完事项；A 项目的规则不会无条件进入 B 项目；并发任务候选互不覆盖；整理可追溯到来源，人工修改与删除不被旧候选静默还原。

### 阶段 6：故障恢复、资源与真实工作验收

- 在隔离 Host 上验证应用重启、tmux 丢失后恢复、Agent 正常退出／更换、目录不存在、创建结果不明和消息写入不明。复用已有恢复策略，不自动重放无法确定是否执行的消息。
- 从现有 Mac Viewer／iOS 查看同一 Agent 标签并处理提问，检查普通标签导航与控制权无回归；不把这项验收当作已有专用 Orbie Viewer UI。
- 验证每 Agent 输入互斥、Workflow 占用、关闭面板、长期空闲及历史积累。记录相对当前空闲 Host 的 CPU／内存、Agent／Workflow 列表打开耗时、记录与材料增长；不增加每个 Agent 独立高频轮询。
- 关闭功能时停止快捷键和新投递，保留普通 Agent 标签、运行中的会话、材料与记忆。移除 Orbie／Orbiter 角色关联不删除会话；不做自动清空或数据降级迁移。
- 完成功能验收后再建议连续试用一周：比较补充背景的次数、找回旧任务的时间及误定位、记忆的实际复用与错误引用。每条结论关联任务和证据，不预设收益百分比。

**验收门槛：** 两条核心路径「昨天的任务今天继续」「选区派发后结果可找回」都通过，且无身份串用、重复投递或后台抢焦点。尚未验证的硬件／跨设备场景逐项列明，不用构建成功代替运行证据。

## 4. 首版之后，按收益逐项开启

| 后续工作 | 进入条件 | 最小下一步 |
| --- | --- | --- |
| 词库小试验 | 有明确收集需求，不阻塞阶段 1–6 | 手动收词与去重；接入既有语音输入快照，比较真实识别效果；需要时才让 Orbiter 整理 |
| 自动 Dreaming | 手动整理确有收益且候选持续积累 | 基于新增材料触发，空材料跳过，同类不并发，离线后至多补一次；再决定是否需要日历调度 |
| 经验沉淀 | 多个任务已验证同一种方法 | 提炼可检查的说明、Skill 或脚本，先手动复用 |
| 自主派发与持续职责 | 手动任务闭环可靠且资源边界可控 | 单独设计创建权限、范围、停止条件和运行额度，不给 Orbie 默认无限分身能力 |
| Viewer 专用入口／跨 Host | 本地首版有真实使用收益 | 新能力声明、旧端兼容和远端路径语义；跨设备原生会话复制仍单独搁置 |

## 5. 验证与交付规则

每阶段先做针对失败风险的测试，再编译实际受影响的平台；不为纯展示文案增加镜像实现的测试。

| 层次 | 重点 |
| --- | --- |
| 单元／服务 | 幂等创建、持久绑定、重启核对、输入代次、候选过滤、项目范围、原子保存与人工修改冲突 |
| 现有回归 | `AgentForkServiceTests`、`AgentSessionIdentityTests`、`AgentWorkflowInputGateTests`、`AgentWorkflowRecoveryTests`，按阶段影响增加相关套件 |
| 原生 Agent | 私有 tmux／状态根和隔离签名 App 中验证真实 Codex、Claude 的首轮、Fork、提问、完成与恢复；记录 CLI 版本 |
| UI 与输入 | 全局唤醒、草稿、来源捕获、非首标签跳转、后台不抢焦点；分别记录离屏检查和实际操作 |
| 性能与数据 | 空闲开销、消息／Workflow 历史积累、附件大小及列表分页；磁盘失败不能继续假装成功 |

代码阶段执行定向 `./scripts/unit-tests.sh -- --filter '<套件过滤表达式>'`、修改文件的 SwiftFormat lint、两项仓库边界检查与 `git diff --check`。Mac 构建遵循 [仓库构建顺序](../../../AGENTS.md#building--testing)；iOS 仅在确实修改目标时做设备 SDK 编译，不额外构建 Simulator。运行验收遵循[隔离 E2E 约定](../../e2e-testing.md)，不把用户的活跃任务当作夹具。

每阶段 TODO 记录源码范围、实际命令／结果、证据路径和未测项。阶段 1–3 的历史命令、隔离原生运行证据及未测项见各自 TODO，不能作为 3-Fix 的新验收结果。3-Fix 的当前实现与验证进度见阶段 TODO；未安装或发布 App。
