# Agent 身份统一优化与实施计划

状态：待实施方案；2026-11-14；代码基线 `db45d8c0`。本文件不表示已修改运行行为，也不授权安装、发布或操作用户正在运行的 Agent。

目标：同一个持久 pane 中的 Agent 在切账号、重启 CLI、Resume、tmux 重建和移动 window 后，仍能被任务、界面与通知找到；旧进程、旧问题和旧投递不能操作它当前的运行者。普通 Agent、Orbie 和 Orbiter 使用相同规则。

## 1. 核心决策：一种长期身份，位置与运行状态分开

建议将上轮提出的 `hostID + windowID + paneID` 进一步收敛为 **`hostID + 持久 paneUUID`**。`windowID` 保留为位置，不参与 Agent 身份相等判断。这是本方案相对上轮建议的明确调整。

原因已有代码依据：`WorkspaceRecoverySnapshot.validate()` 检查持久 pane 不属于多个物理 window；`AgentWorkflowStore.reconcile()` 拒绝重复 pane。原生 tmux 可以移动存活 pane，现有 Orbie、资源和事件代码也支持这种移动。把 window 纳入长期身份，会迫使每个调用方另做迁移或进程回退。当前“一标签一 pane”仍是[待定方案](../../single-pane-terminal-tabs-design.md)，本改造不依赖它落地。

拟新增共享值类型，复用现有 UUID，不生成另一份 ID：

```swift
struct AgentID: Codable, Hashable, Sendable {
    let hostID: UUID
    let paneID: UUID
}
```

这里的 Host 是现有工作区状态根的持久身份；pane 是 `@ctrlx-recovery-pane` UUID。`%5`、`@3`、名称、路径、PID、Provider 和原生对话 ID 都不参与这个键。终端暂时只运行 shell 时可以保留目标引用，但当前 Agent 为空。

| 信息 | 唯一职责 | 实现方向 |
| --- | --- | --- |
| `AgentID` | 找到同一个持久 Agent 位置 | 放入共享 wire 模型，替代产品层各自的绑定判断 |
| 当前位置 | session/window UUID、tmux server、`%pane`、展示窗口 | 复用 `WorkspacePaneIdentity` 和目录快照，随移动、恢复更新 |
| 当前运行者 | plugin、PID、启动时间与原生对话证据 | 收敛到现有 `AgentProcessBinding` 等运行快照；用于检查操作对象 |
| 原生对话 | Resume、Fork、历史、用量与结果关联 | 由插件验证；不能把识别到进程等同于识别到对话 |
| invocation／request／lease | 某次投递、提问、控制授权 | 保留原有 ID 和证据，不作为 Agent 的长期身份 |

Viewer 始终先验证 `pairID → Host` 的已认证连接，再解析 `AgentID`；`pairID` 仍是传输隔离边界。多个 session 链接同一个物理 window/pane 时只算一个 Agent，展示位置按当前布局选择，不重复创建运行者。

Host 上的完整、验证过的 pane／进程快照继续是运行状态来源；Workflow 的目录是投影，不拥有另一套 Agent 注册表。公共解析函数只从该快照找唯一目标，不发起磁盘扫描或进程扫描。缺失返回缺失，歧义返回歧义，不使用 `first` 猜测。

## 2. 用户可见行为与状态变更

| 变化 | 保留 | 重新建立／失效 |
| --- | --- | --- |
| 标签重命名、移动 pane、切展示窗口 | AgentID、任务关联、资源来源、用户配置 | 当前位置；具体授权仍检查原授权范围 |
| CLI 重启、退出后 Resume、切登录账号 | AgentID、Orbie／Orbiter 关联、历史结果 | 当前进程和对话证据；旧审批、旧输入授权失效 |
| 同进程 `/new`、`/clear` 或切换原生对话 | AgentID、标签级配置、任务入口 | 对话关联状态、旧问题、旧模型显示与资源授权重新核验 |
| 同 pane 更换插件／Provider | AgentID、任务记录 | 重新计算能力和当前模型；不沿用旧对话或旧审批 |
| App 重启、tmux 存活 | AgentID、任务及配置 | 从当前进程核验运行态，不重启 Agent、不重发任务 |
| tmux 重建、恢复原 pane UUID | AgentID、任务关联、配置 | server、运行编号、进程证据；Resume 沿用原有恢复引擎 |
| New／Fork 新建 pane | 父任务或来源引用（如已有该语义） | 新 AgentID；实际模型与快捷按钮沿用 Provider 默认规则 |
| pane 删除后新建同名标签或复用 `%5` | 原任务历史与未发送草稿 | 新 AgentID，不自动继承旧关联 |
| 扫描暂时失败、复制模式、终端有草稿 | 已验证的身份记录、任务关联 | 显示暂不可输入；不误判为进程退出或能力失效 |

自动重新关联只恢复目标可用性。已进入 writing／已投递／执行结果不明的任务仍走原有核对流程；当前已暂停的工作流不会因为身份恢复而擅自 Continue。当前正在发送的一次操作始终绑定开始时核验的运行者，途中变化就停止该次操作。

## 3. 统一事件入口，修复状态与证据串用

当前普通状态事件丢弃 `PluginIngressPeer`，直接按 `%pane` 调用 `applyState`；进程扫描又可能只替换 runtime，保留旧插件和对话。两处必须在同一阶段修复。

实施流程：

1. socket 收包时保留内核捕获的 peer 进程链及接收序号；解析后仍携带来源证据。插件 JSON 声称的 PID／pane 不构成认证。
2. 从 Host 快照解析 `AgentID` 和当前运行者，验证插件及 PID／启动时间。缓存缺失时复用现有后台刷新；不能把每个高频事件变成全量 `ps` 或文件扫描。
3. 将当前状态更新与历史结果处理分开。当前事件通过核验后，才允许更新状态、通知、自动审批和对话缓存。迟到结果若匹配某个原 invocation，可走该 invocation 的历史证据验证，不能改写当前 Agent。
4. 同进程对话变化由插件明确的会话开始／提交语义结合原生当前对话证据确认；接收顺序或一个自报的 SessionStart 不足以把已经替换的旧对话重新认作当前对话。不能因为对话 ID 不同就永远拒绝新会话，也不能让普通旧事件任意覆盖它。共用验证规则，插件只负责解释自身证据。尚无对话的首次启动允许建立进程状态；无法确认当前对话时不写恢复描述、不执行依赖该对话的操作，不猜测最近历史。
5. 翻译事件或读取证据有 `await` 时，在应用状态前复核运行者及对话条件；写缓存采用相同快照的比较后提交，不能读取新 PID 后搭配旧 session ID 保存。
6. 确认运行者替换后，统一清理旧的 Working、审批／提问、对话关联、telemetry、模型显示和待投递凭据，再建立新运行态。扫描失败不是空扫描；确认替换与暂时不可观测必须区分。

`SessionEnd` 进入同一套来源验证，但保留退出的特殊语义：Host 监视器生成的结束事件携带原运行者证据；进程已退出也可结束它自己的状态，已存在后继运行者则不清理后继。不能要求所有结束事件的旧 PID 仍存活。

统一内部事件信封不允许从 wire 反序列化出“已验证”状态。sidecar／Host 合成事件须附上 Host 已掌握的原运行证据，不能用 `peer == nil` 当豁免。Codex、Claude Code、OpenCode、pi、omp 分别覆盖原生会话格式；共享层不强制所有 conversation ID 为 UUID。

## 4. 各功能的收敛范围

| 领域 | 目标与删减 |
| --- | --- |
| Orbie／Orbiter／任务查询 | 存储 AgentID；打开、发送前查当前快照。删除 `matchesProcess → isSamePane → 旧 server` 等产品层回退，统一恢复后的可用性；插件变化只触发能力检查 |
| Workflow | 参与者绑定 AgentID，节点仍引用本工作流的参与者。停止因进程更新而重写节点 ID／Agent 选择；运行历史和 invocation 保存原证据。并发投递占用按 AgentID 仲裁，进程重启不绕过尚未完成的投递 |
| 恢复与 native 缓存 | 已验证恢复描述归属 AgentID；新运行者确认前不能重新采用已失效的旧描述。保留失效标记、恢复日志和幂等创建；存活缓存与恢复描述分别按用途校验 |
| 模型／effort | 实际模型读取按 AgentID 查当前运行者，异步回包按运行者／对话核验。Provider 默认配置继续归 Provider；window 级快捷按钮使用持久 Host/window 引用，保持 window 级语义，不借身份改造改为 pane 级 |
| 状态／通知／审批 | 状态归当前 Agent；通知导航携带 AgentID，通知按钮仍带原 request／对话证据。Yolo 按原产品范围保存，实际自动答复必须通过当前请求校验 |
| Files／Browser／Simulator 来源与分组 | 来源 Agent 改为持久引用，位置由当前目录解析。独立的人类资源保留 resourceID，不因没有 Agent 而消失；不把后台资源活动变成前台切换 |
| Browser／Simulator 控制权 | 资源所属 Agent 使用 AgentID；对话授权、运行 token、Viewer lease 和人工接管分别保留，具体规则见下一节 |
| 普通终端输入、布局及关闭 | 继续使用当前服务器／对象身份保护写入和关闭事务；这一运行期检查不改成仅匹配持久 AgentID |

Workflow 参与者 ID、nodeID、taskID、runID、invocationID 都有独立业务含义，应保留。现有随机 `AgentWorkflowInstance.id` 若承担历史行引用，迁移后仅作为历史快照引用；新产品关联不再依赖它。此阶段只重整 Agent 选择与引用，不重做工作流图、投递引擎或结果存储。

## 5. 控制权、恢复和通知的关键边界

### 资源能找到，不代表自动获得控制权

资源来源统一为 AgentID；原有“同一个原生对话才可接续 Agent 资源”的规则继续成立。建议资源所有者使用 `AgentID + pluginID + conversationID`；tmux server 代次移到运行授权证据，不再混入持久所有者键。

原对话恢复后，确认原运行者退出、当前证据有效且不存在人工接管／撤销／竞争授权，才重建新的执行授权。旧 token 永远不复活。新对话、跨插件和 Fork 默认不继承旧对话控制权；用户已有的显式授权入口继续可用。人工资源的 session 范围限制保留，跨 session 移动不自动扩权。

Swift 资源模型与原生 Browser 所有者键同步调整，复用当前 run token 与 grant 机制。本计划只处理现有资源的关联和授权，不扩大浏览器／模拟器自身的重启恢复范围。

### 恢复只启动已确认的对话

AgentID 可跨 tmux 重建找到占位 pane；是否 Resume 仍由恢复描述、插件与历史验证决定。未知新运行者不能使用旧对话描述冒充自身。无可验证对话时保留 Shell／手动恢复入口，不增加“最近对话”回退。

把 `AgentSessionIdentityClient` 的职责表述收敛为“原生对话证据缓存”；消除它与产品身份的混称。现有缓存先加载到内存再比较提交，确认替换为无关运行者时同步使旧缓存与恢复描述失效，防止一个存储清了、另一个又复活旧记录。正常 Resume 则保留恢复日志中的启动意图，核验新进程确实打开原对话后重建证据；不能因 PID 必然变化而删除该次恢复依据。历史描述可以留存，但历史存在本身不证明当前归属。

### 通知从发送到打开都携带稳定目标

链路覆盖 Host 生成、加密 `NotificationContent`、iOS 通知扩展、通知中心持久 `userInfo`、Mac 本地通知、Mac Viewer、iOS deep link 与前台去重。Relay 继续转发密文；不把 Agent 的稳定目标放进明文 APNs 外层。

点击时用当前已认证 Host 目录解析 AgentID，再打开当前 session/window/pane；不使用旧 `%pane` 猜测。目标不存在时打开对应 Host 并说明目标不可用；用户主动切标签或创建新标签会取消待定位，不阻塞用户后续操作。去重按稳定目标，不能因为临时编号复用而删除另一个标签的通知。

通知上的答复操作还须匹配原 request、插件、对话和当前运行证据。过期操作可引导打开当前标签，不向它发送旧回答。新增字段同时计入 APNs 大小预算，必要时降级为纯点击通知。

## 6. 数据与协议迁移

采用一次明确的存量转换与能力协商，不长期运行两套身份解析器。

- **已有持久字段直接提取。** 从 Orbie／Orbiter binding、Workflow target／instance、恢复快照提取现有 Host 和 pane UUID。位置字段继续用于布局；缺字段或有冲突的关联保留原数据并标为待关联，不按名称、PID、路径或原生对话猜测。
- **按存储原子升级。** 先完整解码、转换、校验，再原子写入对应存储的新 schema；保留升级前文件作回滚依据。AgentID 使用现有 UUID，各存储不需要跨文件分配 ID 或分布式事务。转换应可重复执行，失败不覆盖原数据。
- **历史证据冻结。** 原 invocation 的运行者、原生 turn、结果和写入状态不因新 AgentID 被改写。旧 snapshot UUID 只用于解释历史引用；迁移不能把两个历史进程合并成一个已授权投递。
- **live 缓存不冒充恢复源。** 缺少运行证据的旧缓存可重新采集；已确认失效的恢复记录不能通过迁移重获有效状态。不会为保留缓存而放宽恢复验证。
- **协议能力明确。** 新稳定目标字段按现有 wire 约定增加；涉及 Workflow 参与者引用语义变化的修改命令使用独立能力／版本门控。旧客户端继续支持其已具备的基础功能，不能把新请求无声降级为裸 `%pane`。
- **旧通知保守打开。** 新客户端遇到只有旧编号、无法证明所属运行期的历史通知，只打开 Host。新 Host 对不支持稳定通知目标的客户端降级为无精确目标的通知，避免旧客户端误跳或提交旧操作；兼容测试验证这个降级。
- **回滚不清用户数据。** schema 变化可能使旧程序无法读取新记录；回滚需还原升级前对应存储，升级后新增任务记录先保留。不能承诺仅替换 App 就能无损降级。

优先复用已经存在的工作区 scope、版本字段和协商机制；确有语义变化才新增能力。界面不暴露 PID／generation 等实现术语，只显示“等待 Agent”“目标已关闭”“请求已过期”等可行动状态。

## 7. 实施顺序与交付门槛

分六个可独立 review 的阶段。一次阶段内的相关路径一起迁移；不只改 Orbie 的局部判断后宣称全部完成。每阶段同时完成自身的存储转换、wire 能力门控和兼容测试，不把这些工作推迟到最后验收。开始实施时为当前阶段建立 `STAGE{N}_TODO.md`，未开始阶段不预生成空清单。

| 阶段 | 改动范围 | 完成门槛 |
| --- | --- | --- |
| 1. 稳定引用与公共解析 | AgentID、Host／Viewer 解析规则、现有三元组数据转换函数、重复 pane 校验 | 移动／重建／双 Host／重复 UUID 的纯模型测试通过；现有状态行为不改变 |
| 2. 当前运行态与事件入口 | dispatcher、state sink、进程扫描、native 缓存、SessionEnd、sidecar 证据 | 上轮“旧事件覆盖”“新 runtime 拼旧状态”回归通过；正常开始、退出、同进程换对话不受损 |
| 3. 任务与恢复关联 | Orbie、Orbiter、任务目录、Workflow 参与者选择及占用、恢复描述 | tmux 重建及 pane 移动后无需 Reconnect；旧执行不重发、旧结果不进入新执行；迁移实测通过 |
| 4. 跨端通知 | 加密内容、通知扩展、Mac／iOS 导航、去重与请求校验 | 原始编号复用不串标签；冷启动、目标消失、旧消息与版本混用有明确结果 |
| 5. 资源与模型消费者 | 来源分组、资源所有者键与授权、模型显示缓存、window／Provider 配置引用 | 同对话重启可接续；跨对话不继承权限；标签切换不重新创建资源，旧模型回包不覆盖新 Agent |
| 6. 清理与集成验收 | 删除旧产品匹配路径、完成 schema／wire 兼容、更新当前契约文档 | 全部使用点分类完成；下表验收通过且没有隐藏旧路径；实际运行证据与未验收项分开记录 |

不预设天数或承诺一轮“大重构”完成。阶段 2 的缺陷修复可先交付；全部阶段达到门槛后才把此计划标为完成。

## 8. 必须覆盖的验收矩阵

| 场景 | 必须观察的结果 |
| --- | --- |
| 旧 Agent 的普通状态／通知／审批事件晚到 | 不改变新 Agent，不自动答复，不保存旧对话为新运行者身份 |
| 旧任务最终结果晚到 | 仅在原 invocation 证据匹配时写原结果；不完成新任务、不驱动当前状态 |
| 同进程换对话，随后旧对话事件到达 | 新会话成功建立；旧事件不能撤回新状态或旧审批重新出现 |
| 进程崩溃无 SessionEnd，新插件已扫描到但 hooks 失败 | 清旧运行态，展示新插件的已知状态；缺失能力可见 |
| PID 复用、原 `%pane` 复用、不同 Host 同编号 | 不串身份、不操作新对象、不因旧通知定位错误 |
| App 重启、tmux 重建、账号切换、Resume | 原任务入口继续定位；无重复启动或隐式重发 |
| pane 移动后继续刷新目录，再收到回执／Stop／下次投递 | 关联、当前状态和后续目标一致；同一 Agent 的投递仍互斥 |
| 多 pane／linked window、重复持久 UUID | 合法共享只对应一个 Agent；歧义明确拒绝，不选第一项 |
| 目标恢复尚未完成、终端草稿／复制模式、扫描暂时失败 | 自动等待；不把临时不可用持久化为能力故障或遗失关联 |
| 通知冷启动／中间标签／目标关闭／用户新建标签 | 正确定位或明确缺失；用户选择能取消待定位 |
| 手动控制 Browser／Simulator、授权撤销、跨对话／Fork | 人工接管有效，旧 token 不复活；资源可展示不等于 Agent 可控制 |
| 模型读取期间进程／对话／Provider 变化 | 丢弃旧回包，重新查询；快捷按钮的既有作用域和 Provider 默认不变 |
| 存储转换中断、坏文件、旧版本消息 | 原数据保留，错误可见；无降级猜测或自动重发 |

Codex 与 Claude Code 验证账号切换、原生 Resume／Fork、提问、停止和任务接续；OpenCode／pi／omp 验证其生命周期、sidecar 来源和原生 ID 格式。tmux 3.6a 与 3.7 系列都覆盖输入门控，避免重复引入版本门槛回归。

性能验证记录改造前后的进程扫描次数、历史文件读取次数、主线程占用和 Viewer 键盘响应；同一批高频事件共享有效观察结果。验收要求不出现逐事件全量扫描、阻塞键盘接收循环、按历史进程数量增长的存活缓存，或为每个产品面板新增常驻轮询。使用同一夹具比较，不虚设尚未测量的毫秒指标。

纯模型／服务用定向单测；跨端 wire 用新旧消息 fixture；Mac 与 iOS 条件代码分别编译 Mac 和 iOS device SDK，通知扩展随 iOS 一起检查。资源授权改动需要隔离签名 App 的原生 Browser／Simulator 套件，顺序执行。真实 UI、Agent 与 tmux 验证使用隔离 App、私有状态根和 socket，不向用户任务发送测试输入。物理设备及跨 Mac 未实际验收时保持未完成标记。

## 9. 删除清单与防止再分叉

- 产品关联不再调用 `matchesProcess`、`matchesBinding`、比较 tmux server 或原生 session；它们只出现在运行验证、历史证据和授权边界。
- 删除 Workflow 因运行进程变化而替换 Agent 选择 ID 的路径；参与者到 AgentID 的绑定只有一处。
- 删除 Orbie／Orbiter／任务查询各自的目标回退；共用快照解析，普通 Agent 不依赖启用 Workflow 才能有身份。
- 移除通知、任务关联中的“旧原始编号继续可用”假设；基础流式传输的临时路由仍保留且带 Host scope。
- 缓存按当前 Agent／window／Provider 的真实作用域保留，不另建与 pane 状态并行的通用 Agent 注册服务；关闭／确认替换时明确失效，不因暂时失联删除历史。
- 不全局改写 `WorkspacePaneIdentity.isSamePane`：它现有的 server 运行期语义仍用于输入、关闭和 stream。只有长期关联改用 AgentID，避免弱化 tmux 命令边界。
- 当前文档在对应阶段完成后更新；`claudeSessionID` 等跨插件字段可随触及路径统一为 conversation 命名，wire 的旧键只留在编解码边界，不单独开展无关的全仓改名。

最终 review 对每一处进程／会话／pane 比较标注用途：产品定位、运行验证、历史关联或授权。只有职责不清或重复的分支需要删改；完成标准不是“所有地方只剩一个字符串比较”。

## 10. 基线证据与代码入口

本方案承接 `db45d8c0` 的全面 review：109 项定向测试、13 个套件通过。另用该版本编译产物做隔离调用，确认旧事件覆盖新 Agent、进程替换保留旧状态、Orbiter 跨 tmux 重建失联、通知原始编号复用误定位。移动 pane 的 Workflow 后续定位也存在策略不一致。上述是改造前证据，不是本方案已实现或已通过验收。

主要入口，实施时以当前代码再次核对：

| 领域 | 入口与当前契约 |
| --- | --- |
| 持久引用与目录 | [WorkspaceIdentity](../../../CtrlxPackage/Sources/CtrlxNetworking/Models/WorkspaceIdentity.swift)、[ViewerWorkspaceCatalog](../../../CtrlxPackage/Sources/CtrlxCommon/Models/ViewerWorkspaceCatalog.swift)、[AgentWorkflowInstance](../../../CtrlxPackage/Sources/CtrlxNetworking/Models/AgentWorkflowInstance.swift) |
| 事件与进程状态 | [PluginEventDispatcher](../../../CtrlxPackage/Sources/CtrlxServerFeature/Plugins/PluginEventDispatcher.swift)、[MirrorWindowManager](../../../CtrlxPackage/Sources/CtrlxServerFeature/Managers/MirrorWindowManager.swift)、[AgentProcessBinding](../../../CtrlxPackage/Sources/CtrlxServerFeature/Models/AgentProcessBinding.swift) |
| 原生身份与恢复 | [AgentSessionIdentityClient](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/AgentSessionIdentityClient.swift)、[WorkspaceAgentCapture](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/WorkspaceRecovery/WorkspaceAgentCapture.swift)、[恢复契约](../../workspace-recovery-design.md) |
| 任务 | [OrbieStore](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/OrbieStore.swift)、[OrbiterService](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/OrbiterService.swift)、[OrbieTaskCatalog](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/OrbieTaskCatalog.swift)、[AgentWorkflowStore](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/Workflows/AgentWorkflowStore.swift)、[Orbie 计划](../orbie/IMPLEMENTATION_PLAN.md) |
| 通知 | [PushModels](../../../CtrlxPackage/Sources/CtrlxNetworking/Models/PushModels.swift)、[TerminalNotificationService](../../../CtrlxPackage/Sources/CtrlxServerFeature/Services/TerminalNotificationService.swift)、[iOS 通知扩展](../../../CtrlxNotificationExtension/NotificationService.swift)、[SessionNavigation](../../../CtrlxPackage/Sources/CtrlxFeature/Models/SessionNavigation.swift) |
| 资源、模型与展示 | [AgentResourceIdentity](../../../CtrlxPackage/Sources/CtrlxServerFeature/Models/AgentResourceIdentity.swift)、[Browser Ownership](../../../CtrlxPackage/AgentBrowser/Ownership.h)、[AgentModelPreferences](../../../CtrlxPackage/Sources/CtrlxServerFeature/Models/AgentModelPreferences.swift)、[PaneLinkedTabs](../../../CtrlxPackage/Sources/CtrlxCommon/Models/PaneLinkedTabs.swift)、[服务契约](../../services-reference.md) |
