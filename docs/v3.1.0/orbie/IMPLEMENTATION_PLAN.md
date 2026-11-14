# Orbie 实施计划

日期：2026-11-13。源码基线：`dddc4b0c`（CtrlX 3.0.162）。依据：[Orbie 设计方案](../../global-agent-design.md)。状态：**阶段 1–3 已实现并通过定向单测、Mac 编译及本机隔离验收；阶段 4–6 未开始**。具体完成项、命令与未测边界见 [STAGE1_TODO.md](STAGE1_TODO.md)、[STAGE2_TODO.md](STAGE2_TODO.md) 和 [STAGE3_TODO.md](STAGE3_TODO.md)。

先完成「唤醒 Orbie → 创建任务分身 → 保存结果 → 找回并继续任务」，再增加文件记忆。六个阶段依次交付，每阶段保留可运行、可验证的成果；词库、自动 Dreaming 和自主分派另行推进。

本目录沿用仓库的版本化计划组织方式；`v3.1.0` 不是发版承诺。已完成阶段的清单见 [STAGE1_TODO.md](STAGE1_TODO.md)、[STAGE2_TODO.md](STAGE2_TODO.md)、[STAGE3_TODO.md](STAGE3_TODO.md)，假设与待决策项见 [ISSUES.md](ISSUES.md)。后续阶段开始时再增加对应 TODO，避免提前维护大量重复清单。

## 1. 首版边界与建议默认值

以下是用于安排实施顺序的建议，涉及尚未确认的产品选择时，以待决策表为准。

| 项目 | 首版安排 |
| --- | --- |
| 承载位置 | 先在一台指定 Mac 的 Host 本地实现，显式启用；不自动在其他设备创建第二个 Orbie |
| Agent 类型 | 先用 Codex 验证首条链路，再通过相同能力接口验收 Claude Code；用户选择 Agent／Provider，不改其全局默认设置 |
| 运行方式 | Orbie 和 Orbiters 都是普通 tmux Agent 标签，使用现有 New Agent、Fork、Resume 和 shell 集成 |
| 标签命名 | 主标签为 Orbie；任务分身使用短任务名，同名追加序号，展示名不参与身份验证 |
| 任务创建 | 用户明确选择 New Agent 或原生 Fork；不同 Agent 类型使用 New Agent 交接材料，不转换原生历史 |
| 全局面板 | 输入、简短结果、任务查找和打开标签；完整终端及权限／提问交互使用既有页面 |
| 并发 | Orbie 同时处理一条面板消息；建议试用时最多两个活跃 Orbiter 任务，达到上限保留草稿，不另建自动等待队列 |
| Viewer | 已配对 Mac／iOS 继续查看和操作普通 Agent 标签；首版不增加远端 Orbie 专用面板、跨 Host 调度或记忆同步 |
| 数据与清理 | 使用已有状态根和文件目录；先提供手动归档，不自动删除会话或产物，不另存完整原生聊天历史 |

Orbie 忙碌不影响任务查找、显式导航及新建独立任务。普通 Agent 标签不受 Orbie 的并发限制。关闭面板不终止任务；停止后续投递与中断／退出 Agent 是不同操作，沿用现有语义。

## 2. 实现落点：只增加产品需要的状态

| 关注点 | 已核对的入口 | 计划新增或调整 |
| --- | --- | --- |
| 启动、Provider 与目录 | [SessionLaunchPreparation](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/SessionLaunchPreparation.swift)、[工作流创建入口](../../../CtrlxPackage/Sources/CtrlxServerFeature/Coordinators/AppCoordinator+WorkflowCreation.swift) | 从同一路径创建／绑定 Orbie 和 Orbiter，不拼装另一套启动命令 |
| Fork | [AgentForkService](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/AgentForkService.swift) | 绑定用户确认的源对话和目标目录；保留当前 Provider 默认模型／effort 与快捷按钮行为 |
| 身份与恢复 | [AgentWorkflowInstance](../../../CtrlxPackage/Sources/CtrlxNetworking/Models/AgentWorkflowInstance.swift)、[AgentSessionIdentityClient](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/AgentSessionIdentityClient.swift)、[恢复契约](../../workspace-recovery-design.md) | 持久目标与当前进程／原生对话分开；恢复后重新核验，不增加平行恢复引擎 |
| 投递与结果 | [AgentWorkflowService](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/Workflows/AgentWorkflowService.swift)、[Runner](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/Workflows/AgentWorkflowRunner.swift)、[InputGate](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/Workflows/AgentWorkflowInputGate.swift) | 先以单参与者、单步骤、单轮工作流承载一次面板投递，沿用其账本、输入检查和完成核验 |
| 状态与路径 | [AgentWorkflowStore](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/Workflows/AgentWorkflowStore.swift)、[CtrlxPaths](../../../CtrlxPackage/Sources/CtrlxServerFeature/Plugins/CtrlxPaths.swift) | 增加 Orbie 绑定与任务索引；目录通过 CtrlxPaths 派生，使隔离测试能重定向全部数据 |
| 选区与图片 | [InteractiveTerminalView](../../../CtrlxPackage/Sources/CtrlxServerFeature/Views/InteractiveTerminalView.swift)、[Files](../../../CtrlxPackage/Sources/CtrlxCommon/UI/WorkspaceFileBrowserView.swift)、[Browser](../../../CtrlxPackage/Sources/CtrlxCommon/UI/RemoteBrowserView.swift)、[Simulator](../../../CtrlxPackage/Sources/CtrlxCommon/UI/RemoteSimulatorView.swift) | 在已有文本选择、截图和标注上增加 Orbie 入口，触发时固定来源 |

单步工作流是内部投递方式，用户无需配置流程图。任务索引引用已有 run／invocation 记录，不再维护一套「已发送、已接收、轮次结束」状态机。第一阶段必须验证这条复用路径可用于日常对话、提问及人为接管；若有缺口，只在原通道补齐必要接口，不先抽象通用 Agent 调度框架。

新增代码主要在 `CtrlxServerFeature`：协调入口和 UI 使用主 actor，持久 I/O 使用 actor 或现有依赖客户端；不增加 ViewModel。确有两端消费者后再下沉到 `CtrlxCommon`，不为尚未开发的 Viewer 提前增加协议。

### 数据职责

| 数据 | 内容与约束 |
| --- | --- |
| Orbie 绑定 | 指定 Host、持久 window／pane 目标、Agent／Provider 选择；当前会话事实从现有实例目录读取 |
| 任务记录 | taskID、标题、创建时间、目标、来源、实际工作目录、New／Fork 来源、目标绑定、执行记录引用、结果／产物链接及归档状态 |
| 创建意图 | 创建前保存 taskID 和请求关联；回包丢失先核对已有证据，无法确认时显示待核对，不因超时再启动一个标签 |
| `TASK.md`／`RESULT.md` | 人和 Agent 可读的任务材料与简短结果；轮次／投递状态仍以工作流账本为准，不靠文件出现判定成功 |
| 长期记忆 | 全局偏好、对应项目的规则、带来源与验证时间的方法；不保存实时忙碌状态或拿旧结论代替当前查询 |

建议产品状态位于 `<stateRoot>/orbie/`，工作材料位于 `<ctrlxRoot>/agents/main/` 和 `experts/<run_id>/`。这里的 run_id 指任务分身实例目录 ID，创建后固定；继续同一任务可以新增工作流执行记录，但不因每条消息创建新目录。名称与格式在第一阶段定稿，文件格式带版本，持久化失败时停止相关新操作并保留原数据。

任务可引用已有任务或标签，但首次仅收录本功能创建或用户明确关联的任务。不导入全部历史、不从同名标签猜原对话。孤立的创建记录由用户关联现有标签或明确重建，不自动接管不明进程。

## 3. 分阶段交付

| 阶段 | 用户可见成果 | 依赖 |
| --- | --- | --- |
| 1. Orbie 绑定与投递 | 在 CtrlX 内打开固定 Orbie，完成一次有结果记录的对话 | 默认值与单步复用验证 |
| 2. Orbiter 与任务接续 | 创建分身、查看结果、重启后找到并继续任务 | 阶段 1 |
| 3. 全局唤醒与查找 | 在其他 App 中唤醒 Orbie，查询并打开正确任务 | 阶段 2 |
| 4. 从选区派发 | 选中文字或标注图片，带原始来源建立任务 | 阶段 2、3 |
| 5. 最小文件记忆 | 显式记住、按项目读取、手动整理候选 | 阶段 2、4 |
| 6. 验收与试用 | 两条核心路径及恢复、资源边界通过验证 | 阶段 1–5 |

### 阶段 1：先证明普通 Agent 能承载 Orbie

- 增加最小绑定存储与「打开 Orbie」应用内入口。首次显式创建，后续打开同一持久目标；创建处理中拒绝重复启动。已有 Orbie 退出或目标失效时展示恢复／重新建立入口，不静默另起一份。
- 复用现有 Agent 启动表单和 Provider 选择。Orbie 在 `agents/main/` 运行，提供最小角色说明；Codex 的既有 `--no-daemon`、退出后的 shell function、模型默认值均不改。
- 通过单步工作流提交第一条消息，并显示本次输入、等待原因和核验后的回答。绑定初次原生会话的规则继续由现有通道负责。
- 主对话忙碌、有未提交草稿、等待提问／授权时保留面板草稿；明确提示打开终端继续处理。不清空终端输入，不通过键盘模拟绕过 InputGate。
- 先验证应用重启且 tmux 存活的接续；涉及 tmux 重建时对接已有恢复目标，不在 Orbie 服务里恢复终端拓扑。

**验收门槛：** Codex 和 Claude Code 各完成首条对话；连续打开入口只创建一个 Orbie；手动输入能阻止过期自动投递；进程／会话替换被拒绝；应用重启保留绑定且不重发原消息。新用例及相关身份、输入门控回归通过后进入阶段 2。

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

### 阶段 4：选区与标注派发

- 先接入 Mac Terminal 与 Files 中可选择的文本，再接入 Browser／Simulator 已有截图和标注。各入口复用同一任务草稿，不各造一套发送流程。
- 触发动作时冻结内容、Host、持久标签／资源身份、文件路径或 URL、采集时间。打开面板后即使切换标签，材料与来源仍保持原值。
- 预览允许选择「交给任务分身」「询问 Orbie」；「记住」在阶段 5 可用。目标目录独立选择，其他 Host 的路径仅作为来源，不在本机解析为可用目录。
- 外部 App 首先支持用户主动粘贴；只有显式 paste 才读取剪贴板。macOS Services 选区入口在同阶段后段验证，缺乏可靠来源时明确省略，不抓取任意 App 全文。
- 媒体沿用工作流附件能力和类型／大小限制。图片画面使用截图，不许诺远端 Browser／Simulator 的任意文字都能直接选择。

**验收门槛：** 捕获后切换 Host／标签不会串材料；纯文本、文件来源、Browser 和 Simulator 图片均能送达所选分身；不支持的附件明确拒绝；取消面板不创建任务，结果通知不切换当前标签。

### 阶段 5：最小文件记忆与手动整理

- 按设计建立 `main/` 的角色说明、`MEMORY.md`、`projects/` 和 `inbox/`。只创建缺失文件，不覆盖用户已有内容；Codex／Claude 按各自支持的指令入口接入。
- 显式「记住」可直接记录用户确认的条目、范围和来源。任务结果中的可复用经验先进入候选；普通日志与实时状态留在任务记录。
- New Agent 显式收到相关文件路径或经过选择的内容；不能依赖不在进程工作目录中的 `AGENTS.md` 自动生效。Fork 保留原生快照，但需要最新记忆时单独读取。
- 提供查看、编辑、删除和手动整理入口。材料少时由 Orbie 整理，材料多时新建名为「整理记忆」的维护 Orbiter，只产出候选变更，由统一入口应用。
- 应用前检查原文件是否被用户修改，冲突停止并保留候选；不静默覆盖。无需引入数据库、向量检索、自动周期任务或全面历史扫描。
- 保留原生 CLI 记忆开关和目录；目录划分只是产品约定，不声称隔离了 CLI 原生记忆或构成文件权限沙箱。

**验收门槛：** 新 Orbie 对话能读取明确记忆并接续未完事项；A 项目的规则不会无条件进入 B 项目；并发任务候选互不覆盖；整理可追溯到来源，人工修改与删除不被旧候选静默还原。

### 阶段 6：故障恢复、资源与真实工作验收

- 在隔离 Host 上验证应用重启、tmux 丢失后恢复、Agent 正常退出／更换、目录不存在、创建结果不明和消息写入不明。复用已有恢复策略，不自动重放无法确定是否执行的消息。
- 从现有 Mac Viewer／iOS 查看同一任务标签并处理提问，检查普通标签导航与控制权无回归；不把这项验收当作已有专用 Orbie Viewer UI。
- 验证并发上限、关闭面板、长期空闲和任务积累。记录相对当前空闲 Host 的 CPU／内存、任务列表打开耗时、索引与材料增长；不增加每个任务独立高频轮询。
- 关闭功能时停止快捷键和新投递，保留普通 Agent 标签、运行中的会话、材料与记忆。移除单条任务关联不等于删除会话；不做自动清空或数据降级迁移。
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
| 性能与数据 | 空闲开销、任务积累、附件大小及列表分页；磁盘失败不能继续假装成功 |

代码阶段执行定向 `./scripts/unit-tests.sh -- --filter '<套件过滤表达式>'`、修改文件的 SwiftFormat lint、两项仓库边界检查与 `git diff --check`。Mac 构建遵循 [仓库构建顺序](../../../AGENTS.md#building--testing)；iOS 仅在确实修改目标时做设备 SDK 编译，不额外构建 Simulator。运行验收遵循[隔离 E2E 约定](../../e2e-testing.md)，不把用户的活跃任务当作夹具。

每阶段 TODO 记录源码范围、实际命令／结果、证据路径和未测项。阶段 1–3 的实际命令、隔离原生运行证据及未测项见各自 TODO；未安装或发布 App，也未将用户活跃任务用作夹具。
