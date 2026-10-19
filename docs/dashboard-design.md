# CtrlX Dashboard 设计

记录日期：2026-10-17。代码核对基线：`c51edbf`。

状态：首版已实现，专项测试、Mac/iOS Simulator 构建及隔离界面验收已通过，尚未发布。数据源支持条件与验收边界见文末；真实 Claude 订阅账号、跨物理 Mac 和 iPhone 真机仍待验收。

## 1. 产品目标

让用户在 Mac 和 iOS 上快速看清：Agent 账号还剩多少额度，哪些 Host 的机器资源吃紧，以及 CtrlX 今天记录了多少使用量。

典型场景是多台 Mac 作为 Host，多台 Mac 或 iPhone 作为 Viewer，同一 Agent 账号可能同时用于多个 Host。首页固定展示当前 Viewer 可见的全局总览；点某个 Host 再进入单机详情。历史用量放在第二层，首页优先展示额度和机器状态。

三类数据分别归属不同对象：

| 数据 | 归属 | 汇总规则 |
| --- | --- | --- |
| Agent 剩余额度 | 服务商账号及其组织、计费空间、额度池 | 同一共享额度只展示一次，不按 Host 相加 |
| CPU、内存、磁盘 | Host | 每个 Host 独立展示 |
| CtrlX 已采集用量 | 实际产生采集数据的 Host | 各 Host 汇总一次，多个 Viewer 查看不会增加用量 |

例如 Office 和 Home 共用同一个 Codex 账号，本周剩余 8%，首页只显示一份 8%，并列出两个 Host。切换到另一台共用该账号的 Host，额度不会增加。

## 2. 首版范围

| 首版包含 | 首版不包含 |
| --- | --- |
| 自动发现已配对 Host 上可可靠识别的 Agent 账号 | 账号登录管理、凭证同步、自动切换账号 |
| Codex、Claude Code 的可信额度展示，其他插件按能力接入 | 非权威来源的额度推算与终端文本抓取 |
| Host 连接状态、内存、磁盘及 CPU 详情 | 进程管理、远程清理、长期资源曲线 |
| 今日已采集用量、近 7 天趋势、Host 和项目明细 | 账号账单、订阅成本推算、历史用量按账号回填 |
| Mac 和 iOS 使用一致的数据口径 | 跨 Viewer 同步筛选和展开偏好 |
| 条目内显示资源或额度异常 | 综合健康评分、告警中心、额外推送 |

不增加云端统计数据库。复用现有 Host 采集、加密连接和 Viewer 聚合能力。

“所有账号”的范围是当前 Viewer 可见的 Host 能够发现并确认的账号，不代表服务商名下或用户其他未配对设备上的所有账号。

## 3. 页面与入口

### 3.1 首页

首页只有账号、Host、用量三块，不设置全页 Host 筛选器，避免让共享账号额度看起来属于某一台机器。

| 区域 | 首页内容 | 展开内容 |
| --- | --- | --- |
| 账号 | 名称、主要额度窗口的剩余量与重置时间、关联 Host | 其他额度限制、各 Host 的登录状态、来源与更新时间 |
| Host | 连接状态、内存使用量及压力、磁盘剩余空间；有数据时显示工作的 Agent 数 | CPU、内存细节、相关磁盘、关联账号及会话入口 |
| 用量 | 今日已采集 tokens、会话数 | 近 7 天趋势，按 Host、项目查看 |

下面是示意数据，不代表真实账号或机器状态：

```text
Dashboard                                  2 / 3 Hosts 在线

账号
  Codex · 个人账号
  5 小时剩余 42% · 2 小时后重置
  本周剩余 8% · 周三重置
  Office、Home 共用

  Claude Code · 工作账号
  5 小时剩余 76% · 3 小时后重置
  本周剩余 53% · 周五重置
  Office

Host
  Office · 在线 · 3 个 Agent 工作中
  内存 24 / 32 GB · 压力正常
  系统卷剩余 18 GB

  Home · 在线
  内存 12 / 24 GB · 压力正常
  系统卷剩余 186 GB

  MacBook · 离线 · 最后更新于 35 分钟前

用量
  今日已采集 27.5M tokens · 12 个会话
  2 / 3 台 Host 已更新                         查看详情
```

正常状态使用简洁文字；额度不足或资源吃紧直接标在对应项旁边。保持列表位置稳定，不因实时数值变化频繁重排。

### 3.2 Host 详情

点 Host 进入单机详情，查看资源、关联账号和该 Host 的用量，并可进入其现有会话。详情内提供 Host 切换入口；切换 Dashboard 的查看对象不改变正在工作的终端连接或选中标签。

Host 详情里出现的账号额度仍是账号共享额度，明确列出其他关联 Host。用量详情可以按 Host 筛选，账号额度不随该筛选变成单机用量。

### 3.3 平台入口

- **iOS**：把 Sessions 顶部现有的在线状态展示（如 `2/3 Online`）变成可点击入口，打开 Dashboard 页面；返回后保留会话现场，不额外增加一个顶部图标。
- **Mac**：提供固定 Dashboard 入口，打开一个可复用的独立窗口，方便与终端并排查看；重复点击激活已有窗口。
- 两端使用同一套信息层级和含义，布局分别适配手机和桌面。

## 4. 账号与共享额度

### 4.1 发现与合并

从 Host 已配置的 Agent 和配置根目录发现账号，支持同一 Host 使用多个账号。同一账号被多个配置目录或 Host 发现时，只有可靠确认其共享额度关系后才合并。

匹配需要考虑服务商、稳定账号身份、组织或计费空间以及额度池；邮箱、显示名、套餐名都不能单独作为合并依据。相同邮箱的个人空间与团队空间可能拥有不同额度。

识别不清时按来源 Host 和配置来源分开展示，并说明身份尚未确认。首版不增加手动合并账号功能，也不通过 Token、API Key 的原文或哈希来充当跨设备账号身份。

关联 Host 表示该 Host 发现了该账号，不自动推断所有正在运行的 Agent 会话都属于它。当前配置切换账号也不能用来重新归属旧会话或历史用量。

### 4.2 额度显示

- 展示服务商实际提供的额度类型、剩余量和重置时间，不强制每个 Agent 都使用“五小时 / 每周”两种窗口。
- 首页优先展示主要限制，其他限制放在详情；存在额外受限项时应有提示，不能藏在正常的主额度后面。
- 不把多个额度窗口换算成一个总百分比，不把订阅额度、额外额度和 API 余额直接相加。
- 同一额度池来自多个 Host 的采样，采用可确认更新的有效快照，保留来源和采样时间，不求和、不取平均，也不挑剩余量最多的一份。
- 服务商的版本或时间信息优先；无法确认跨 Host 样本新旧时明确保留来源和不确定状态，不能仅靠消息到达顺序覆盖更新数据。
- 到达重置时间但还没有新快照时显示“等待更新”，不能直接改成剩余 100%。

### 4.3 登录与可用性

账号额度和 Host 登录状态分别表达。Office 登录失效而 Home 正常时，在 Office 的绑定上显示“需要重新登录”，账号仍可显示 Home 提供的有效额度。

没有数据时区分“等待首次数据”“该来源暂不支持”“本次读取失败”。已有旧数据则保留数值与更新时间，不用 0 或无限额度代替未知。

某 Host 确认换用新账号后，更新其账号关联；离线 Host 的关联标为最近一次观测结果。已经没有当前关联来源的账号不作为活跃账号长期留在首页。

## 5. Host 资源

首页优先帮助用户判断机器是否还能继续承载工作：

| 指标 | 首页 | 详情与口径 |
| --- | --- | --- |
| 连接 | 在线、连接中或离线；离线显示最后更新时间 | 表示当前 Viewer 可见的连接状态 |
| 内存 | 已用 / 总量、系统内存压力 | 展开查看压缩内存、Swap；已用量的系统定义需在实现时验证 |
| 磁盘 | 明确卷名称的剩余空间；多个相关卷时突出空间紧张的卷 | 系统卷和工作目录所在卷，按卷去重，不把同卷的多个目录重复计量 |
| CPU | 不占首页主要位置 | 整机使用率，统一为 0–100% 口径 |
| Agent 活动 | 有可信状态时显示工作的 Agent 数 | 同一运行 Agent 不因多个会话链接或 Viewer 查看而重复计数 |

高 CPU 可能是正常工作；高内存占用也不直接等于内存压力大。资源警示依据明确的系统压力或空间不足条件，阈值在实现时确定，首版不增加阈值设置界面。

离线不代表 CPU 为 0、内存为空或磁盘已释放。某项采集失败只影响该项，其他资源继续展示。

## 6. 每日用量

首页统一使用“今日已采集”措辞，指 CtrlX 收到并累计的数据。服务商侧的完整账号用量与剩余额度不由这份统计推算。

沿用现有 Host 侧汇总：

- 今日 tokens 和会话数，近 7 天日趋势。
- Host 明细，以及现有最近 7 天的项目汇总；项目区明确标注时间范围，不把 7 天项目数据显示成今日项目用量。
- 项目身份包含 Host 与路径；不同 Host 上同名或同路径的项目不自动认定为同一项目。
- tokens 沿用现有 `SessionTelemetry.tokensUsed` 口径，主计数不包含缓存读取和写入；详情说明口径，不改写历史桶。
- 全局会话数表示各 Host 上采集到的会话数之和，不承诺跨 Host 原生对话去重。

当前持久数据按项目和日期记录，没有可靠账号维度。首版不把历史用量分配给当前登录的账号。

费用不是首页必备指标。只有数据源明确提供且口径已知时才显示；缺失费用显示未提供，不能显示成 `$0.00`，也不估算订阅的单次成本。现有模型的默认 0 无法证明真实零费用，不能直接沿用这个默认值作为完整费用结论。

### 日期与覆盖范围

首版沿用各 Host 本地日期，不迁移历史桶，也不伪装成统一 Viewer 时区的完整自然日。跨时区时明确标注“按各 Host 当地日期”，在明细展示具体日期。

离线或未上报的 Host 不按 0 参与完整性判断。首页显示已更新 Host 数；可以展示仍属于当前统计日期的缓存并标注其时间，过期日期的快照不计入今日。当前日期无法可靠判断时，保留在 Host 明细并排除出今日汇总。

新配对的 Viewer 只能在 Host 可达后取得它提供的历史汇总；首版不承诺从云端取回离线 Host 的数据。

## 7. 多 Host 与多 Viewer

- iOS 和远程 Mac 展示自身已配对的 Host；Mac 总览同时包含本机。
- 同一个 Host 的本机入口与远程配对入口需要按可信 Host 身份去重。配对 ID 用于连接路由，不能当成全局机器身份。
- 优先评估复用现有 `WorkspaceIdentityScope.hostID`；它标识 Host 状态实例，不是硬件序列号。具体聚合身份在实现时确认。
- 多个 Viewer 各自聚合其可见范围，不能从账号共享关系推导出访问其他未配对 Host 的权限。
- Host 负责采集一次并缓存，所有 Viewer 复用同一结果；Viewer 数量不会成倍增加服务商查询或机器采样。
- Viewer 的展开、Host 选择和用量筛选属于本机展示状态，不进行跨设备同步。

## 8. 数据链路与刷新

复用现有加密连接，增加独立的轻量 Dashboard 快照或增量消息；资源更新不应触发整份会话与终端状态重发，也不阻塞键盘输入链路。

| 数据 | 更新方式 |
| --- | --- |
| CPU、内存 | 有客户端（包含本机 Mac）正在查看 Dashboard 时按秒级更新；最后一个订阅关闭后停止高频采样 |
| 磁盘 | 低于 CPU、内存的采样频率，打开详情或手动刷新时可更新 |
| 账号额度 | 优先复用 Agent 提供的事件；支持只读查询的来源使用 Host 统一缓存和限频 |
| 每日用量 | 继续使用现有持续采集和汇总机制 |

手动刷新更新可读取的数据，不保证所有来源都能立即产生新额度。只能随 Agent 活动更新的来源继续显示上次采样时间，不为了刷新 Dashboard 自动发起一次模型请求。

账号、资源和用量分别保留时间与可用状态。某项刚刷新，不代表其余项目也变成最新。保留少量最近快照用于再次打开或离线查看，不引入资源历史数据库。

Agent 特有的身份与额度读取放在插件能力中，公共 UI 使用统一模型。新能力通过协议能力声明和可选字段接入；旧 Host 不支持的部分显示不可用，已有会话查看和用量数据仍正常工作。

凭证继续留在来源 Host。Viewer 只接收显示所需的账号标识、标签、额度及状态，不接收原始 Token、API Key 或认证文件。Relay 继续承担加密路由，不成为账号数据中心。

## 9. 当前基础与实现前验证

### 9.1 可复用基础

以下是代码基线上的现状，不代表 Dashboard 已经接入：

| 入口 | 现状与用途 |
| --- | --- |
| [UsageAggregationStore](../CtrlxPackage/Sources/CtrlxServerFeature/Telemetry/UsageAggregationStore.swift) | 持久化项目、日期汇总与会话累计基线，可复用每日增量统计 |
| [UsageOverview](../CtrlxPackage/Sources/CtrlxNetworking/Models/UsageOverview.swift) | 已有今日总量、最近日趋势和项目汇总；目前缺少完整的数据新鲜度、时区及费用覆盖信息 |
| [SessionTelemetry](../CtrlxPackage/Sources/CtrlxNetworking/Models/SessionTelemetry.swift) | 定义现有 tokens、缓存和费用口径 |
| [UsageOverviewViews](../CtrlxPackage/Sources/CtrlxCommon/UI/UsageOverviewViews.swift) | 已有共享格式化和折叠用量展示，可复用适合 Dashboard 的部分 |
| [ViewerConnectionManager](../CtrlxPackage/Sources/CtrlxCommon/Services/ViewerConnectionManager.swift)、[SessionStore](../CtrlxPackage/Sources/CtrlxCommon/Services/SessionStore.swift) | 已支持多 Host 连接及按 Host 保存用量 |
| [WorkspaceIdentity](../CtrlxPackage/Sources/CtrlxNetworking/Models/WorkspaceIdentity.swift) | 提供 Host 状态实例身份，需确认用于 Dashboard 去重的边界 |
| [SimulatorResourceClient](../CtrlxPackage/Sources/CtrlxServerFeature/Services/SimulatorResourceClient.swift) | 已读取部分内存、压力、Swap 和磁盘数据；需要提取适合通用 Host 的能力，不能把可回收内存直接当成完整已用内存指标 |
| [PluginCore](../CtrlxPackage/Sources/CtrlxPluginProtocol/PluginCore.swift) | Agent 插件边界；目前没有 Dashboard 所需的共享账号与额度能力 |
| [iOS SessionListView](../CtrlxPackage/Sources/CtrlxFeature/Views/SessionListView.swift) | 顶部在线状态当前为展示组件，可作为 Dashboard 入口 |

当前用量链路说明见 [Services 的 telemetry 章节](services-reference.md#retrospective-telemetry-consumers-issue-598)。

### 9.2 先验证数据源

正式实现前，先用真实但不含凭证的样本确认以下事项：

1. **账号身份**：同一账号在两台 Host 上能否得到可关联的稳定身份；个人和团队空间能否区分；同 Host 的多个配置目录能否正确归属。
2. **Codex 额度**：核对已安装 CLI 的账号与限额接口、登录方式限制、窗口和额度池标识、时间语义；不能把官方示例字段视为所有版本都具备的能力。调研入口：[Codex App Server](https://learn.chatgpt.com/docs/app-server#authentication-endpoints)。
3. **Claude Code 额度**：核对账号状态与 statusline 数据的实际可用条件、首次数据时机和空闲更新能力；接入方式必须与用户已有 statusline 共存。调研入口：[CLI reference](https://code.claude.com/docs/en/cli-reference)、[Rate limit usage](https://code.claude.com/docs/en/statusline#rate-limit-usage)。
4. **资源口径**：验证整机 CPU、内存已用量、系统内存压力、磁盘可用空间的定义与采集成本。
5. **日期与旧数据**：明确补充哪些时间、覆盖信息；旧 Host 或旧统计缺少这些字段时如何显示不完整状态。

验证结果应给出可用字段、支持版本与登录方式、采样触发方式、缺失时的展示，以及共享账号去重样例。只有通过验证的数据源才能被标为支持；暂不支持某个额度来源不影响 Host 资源和已有用量功能。

## 10. 首版验收场景

| 场景 | 预期 |
| --- | --- |
| 两个 Host 共用同一账号和额度池 | 账号只显示一次，关联两个 Host；额度不相加 |
| 相同邮箱、不同组织或额度池 | 独立展示，不误合并 |
| 一个 Host 配置多个账号 | 正确区分来源，不将旧会话归到新登录账号 |
| 一个来源登录失效、另一个仍正常 | 只标记失效来源，账号仍可展示有效额度 |
| 新旧额度快照交错到达 | 不由晚到的旧值覆盖新值；不确定时保留来源说明 |
| 重置时间已到但没有新数据 | 显示等待更新，不凭空恢复为 100% |
| Host 离线或部分采集失败 | 保留最后时间，逐项显示不可用，不显示虚假的 0 |
| 多个 Viewer 同时打开 Dashboard | Host 共享采样与查询；用量不重复累计 |
| 本机与配对入口指向同一 Host | 总览只计一次，连接仍按正确配对路由 |
| 跨时区、跨日后查看缓存 | 日期口径明确；过期今日快照不混入当前汇总 |
| 缺少费用或账号归属 | 不显示虚假零费用，不给历史用量猜账号 |
| Mac 与 iOS 查看同一批 Host | 数据口径一致；切换 Dashboard 不扰动终端现场 |
| 旧 Host 或插件不支持额度 | 对应区域说明不可用，已有功能正常 |
| 已有自定义 Claude statusline | 接入后原显示与命令继续工作 |

实现后的测试与验收记录应附带实际版本和结果，不能用本节的目标场景代替通过证据。

## 11. 实现与验证结果

2026-10-17，基于 `c51edbf` 开始实现：

- 已验证 Codex CLI 0.162.1 的 `initialize`、`account/read`、`account/rateLimits/read` 只读调用；未创建对话或发起模型请求。实际返回包含 `accountId` 与 `rateLimitsByLimitId`，本次主要窗口是 10080 分钟，说明窗口时长必须由数据驱动。认证元数据包含账号与用户标识；跨两台真实 Host 的去重仍待验证。
- 本机 Claude Code 2.1.276 的 `auth status` 返回 `api_key`，没有订阅账号信息；不能用它证明 Claude 订阅额度已通过真账号验收。订阅路径已实现并通过隔离样本测试，不写入或覆盖自定义 statusline；真实订阅账号验收仍未完成。
- 已实现共享数据模型、样本新旧判断、Host/账号去重、日期口径和离线缓存。`ReadDashboard` 通过独立命令响应返回，`supportsDashboard` 显式声明能力；旧 Host 不接收新命令。
- 已实现 Host 按需资源采集与统一额度缓存：资源请求共享 5 秒缓存，磁盘通常 60 秒更新，账号查询至多每分钟一次；首版关闭页面后不继续轮询；后续快览监测见 11.2。首次 CPU 采样只建立基线，长时间未查看后重新建立基线。
- 磁盘改为独立的单任务后台刷新，快照不等待磁盘；读取期间返回旧磁盘数据与原采样时间，首次读取显示等待状态。无响应的文件系统调用可能仍在后台等待，但不会阻塞其余 Dashboard 数据或因轮询反复创建任务。Codex stdin 写端设置 `F_SETNOSIGPIPE`，子进程断开输入时返回可捕获错误。
- 已接入 Mac 独立窗口和 iOS 在线状态入口，共用账号、Host、用量界面；账号明细保留每个来源的登录状态和采样时间。详情进入会话才改变工作对象。
- Codex 实际服务端 `accountId` 与本机认证配置匹配已核实。Claude 使用其 CLI 同样读取的只读 `/api/oauth/profile`、`/api/oauth/usage`，不修改 statusline；仅支持可读取凭证的标准 claude.ai 登录，不自动刷新或写入凭证，其他方式明确不可用。只读接口属于 CLI 实现细节，服务商变更时可能需要更新适配。
- 29 项专项测试通过，覆盖账号窗口、身份变化、共享采样、离线缓存、关闭后的晚到响应、协议兼容及本机资源读取；品牌和技术边界检查通过。Mac 与 iOS Simulator 的 Debug 完整构建通过。以上均不代表已发布。

### 11.1 本地界面与链路验收

- 使用隔离的 Mac App、私有 tmux socket、私有 Relay 和 Agent iOS 私有 iPhone 18 Pro / iOS 27 模拟器；没有替换 `/Applications/CtrlX.app`，没有向用户运行中的会话发送测试输入。
- Mac 本地 Dashboard 实际显示 Codex 的 7 天窗口与重置时间、CPU、内存压力、压缩内存、Swap、磁盘和本地日期。Claude 的 API Key 登录显示不支持订阅额度。
- iOS 与测试 Host 实际配对后，通过加密 `ReadDashboard` 读到相同来源的账号与机器数据；进入 Host 详情、点击测试会话进入终端成功。退出测试 Host 后，页面保留最后额度、资源与时间并标记离线。
- Mac Host/Viewer 自动化场景的 57 步全部通过，覆盖隔离配对、创建测试会话、两端打开 Dashboard 和机器资源展示。测试使用 AX 按钮动作，并为测试会话采用无歧义名称。真实共享账号的跨物理机器展示尚未验收；账号合并规则由专项测试覆盖。
- 实时额度和资源数值会变化，界面截图仅作人工检查证据，不执行固定像素基线比较。运行此场景时，截图与基线目录均应指向 `.build-local/` 下的验收目录，避免把真实账号观测图提交到仓库。
- 收尾修正了 Codex 读取失败时的登录状态：保留原额度和采样时间，同时将当前登录状态标为未知；5 项 Codex 测试已再次通过。平台构建与界面验收在此调整之前完成，未因这项状态赋值重复执行。
- 本轮审查修复的 13 项专项测试通过（`CodexAccountTests`、`DashboardResourceTests`、`HostDashboardTests`）：在独立进程的默认 SIGPIPE 行为下，子进程关闭 stdin 后写入得到 EPIPE、Host 存活且子进程已回收；磁盘阻塞期间账号和资源快照继续返回，旧磁盘时间保留，取消请求及多个 Viewer 不新增并行磁盘读取。相关 Mac 模块随测试重新编译；未重跑整包构建、完整测试集或 UI 验收。日志为 `.build-local/dashboard-review-fixes-tests.log`。
- 本地证据保存在 `.build-local/dashboard-full-tests.log`、`.build-local/dashboard-macos-build.log`、`.build-local/dashboard-ios-build.log` 和 `.build-local/dashboard-acceptance/`，不进入 Git。

尚未覆盖：真实 Claude 订阅账号、两台物理 Mac 的共享账号，以及 iPhone 真机。已通过的模型/协议测试与同机隔离实例不能代替这些环境的验收。未运行包含 Apple Intelligence 评估的完整未过滤测试集。

### 11.2 菜单快览与低额度提醒（2026-10-18）

- Mac 菜单顶部显示待处理 pane，点击沿用本地／远程 Host 的精确定位；其后按账号显示额度最低的窗口、剩余百分比和来源 Host，点击打开 Dashboard。其他会话收进 All Sessions。
- 菜单栏保留待处理数量；有新鲜、可信的低额度账号时增加警示图标。账号未知、来源冲突或旧观测不会冒充当前低额度。
- 每个客户端共享一个 DashboardStore。Mac 常驻每 30 秒读取快照，iOS 仅前台读取；打开 Dashboard 时仍按 5 秒更新资源。Host 的账号查询缓存保持每分钟至多一次。
- 剩余额度从高于 10% 跨到 10% 或更低时通知。同账号多 Host 合并、同一窗口同周期只提示一次、同次多个窗口合成一条；首次读取、换账号及首次读到已低额度的新周期不提示。断线、失败、过期、冲突及过旧数据不参与触发。
- Dashboard 增加本客户端 Low quota alerts 开关，默认开启；使用已有系统通知授权，点击通知进入 Dashboard。本版不新增 Relay 推送或 iOS 挂起后的额度采样。
- 参考 Agent HUD Open 的信息分层和提醒语义，未引入其依赖或 UI 框架。
- Claude `get_usage` 只读探测：本机 CLI 2.1.276 在禁用 hooks、不发送 prompt 的独立临时工作目录中，约 4.19 秒返回成功控制响应；字段包含 `rate_limits`、`rate_limits_available`、`subscription_type`。当前 API Key 登录返回 `rate_limits_available: false`，不足以验收订阅数据及账号身份绑定，因此本版保留原 HTTP 查询实现。没有读取或输出凭证，也未改变用户 CLI 配置。
- 专项测试 `Dashboard|ClaudeAccountTests` 共 36 项通过，覆盖跨阈值、周期去重、共享账号、离线／过期／冲突观测、开关重建基线，以及 Host 时钟偏差与服务商绝对重置时间。Mac 与 iOS Simulator Debug 完整构建通过；SwiftFormat、差异空白检查、品牌和技术边界检查通过。
- 隔离的 Mac Host／Viewer 自动化验收 58 步通过，实际检查菜单的 Needs attention、Accounts、All Sessions，并从两端菜单打开 Dashboard、显示提醒开关与机器资源。截图人工检查；不以动态账号数据执行像素基线比较。运行证据在 `.build-local/dashboard-quicklook-acceptance/`，专项测试与构建日志在 `.build-local/dashboard-quicklook-*.log`，不进入 Git。
- 本轮未验证 iPhone 真机、真实系统通知投递或 Claude 订阅账号；iOS 前台提醒规则与两端共享同一模型并由专项测试覆盖。本轮没有替换用户安装的 App，也未发布。
- 审查修复：iOS 从 Dashboard 切换会话时显式清空旧通知的 pane 去重标记，避免导航深度不变时遗漏清理；仅关闭 Dashboard 保留标记。`test_dashboard_notification_navigation` 将生产导航回调载入离屏 SwiftUI，验证通知 A → Dashboard B → 通知 A、无选择关闭、重复通知及返回列表；旧回调对照失败，修复后通过。该验证不等同于真实 iOS 系统通知投递。

### 11.3 额度刷新停滞修复（2026-10-18）

- 3.0.81 运行现场两次采样均停在 `CodexAccountClient` 的子进程退出清理 `waitUntilExit()`；该同步等待在 20 秒 RPC 超时之外。资源快照持续更新，账号额度仍停留在一个多小时前。
- Codex 改为启动前注册退出回调，异步等待子进程退出；通信与退出等待共用 20 秒时限，超时和取消均终止本次子进程，不再同步阻塞执行器。超时保留旧额度及采样时间，并明确显示刷新失败。
- Host 按插件分别管理查询任务与一分钟限频，避免 Codex 卡住后连带阻止 Claude 刷新。单个来源查询超过一分钟时标记失败，但不重复创建仍未返回的调用；来源移除或服务停止后忽略晚到结果。
- Claude 登录方式的支持范围保持不变；API Key 登录不提供订阅额度，与刷新停滞是不同问题。
- `CodexAccountTests|ClaudeAccountTests|HostDashboardTests|DashboardResourceTests` 共 21 项测试通过，覆盖多轮查询、默认 SIGPIPE 行为、超时与取消后的子进程回收、失败保留采样时间、慢来源隔离及停止／移除后的晚到响应。相关 Mac 模块随测试重新编译；SwiftFormat、品牌／技术边界和差异空白检查通过。
- 使用本轮编译的 Codex reporter 对真实 CLI 进行两次只读查询，中间等待 61 秒；分别约 7.5 秒和 9.1 秒完成，采样时间从 22:07:43 前进到 22:08:56（Asia/Shanghai）。未创建对话或发起模型请求，记录不含账号凭证。本地证据在 `.build-local/dashboard-refresh-tests.log` 和 `.build-local/diagnostics/dashboard-refresh-20261018/`。
- 未替换运行中的 App，未打包或发布；未重跑整包构建、iPhone／远程 Mac UI 或真实 Claude 订阅账号验收。此修复位于 Host 侧，更新 Mac Host 后由现有 Dashboard 协议供各 Viewer 使用。

### 11.4 Mac 标题栏额度快览（2026-10-19）

- 在工作台标题与右侧连接／终端操作之间显示账号图标与 28pt 剩余额度环；本地、远程与独立工作台共用组件。原 Dashboard 入口保留。
- 使用 Dashboard 的可信账号／额度池身份去重；同一服务商的不同账号分别展示，按身份稳定排序，不随额度、选中会话或 Host 到达顺序重排。
- API 等登录方式明确不支持额度查询（`unsupported`）的账号仅在 Dashboard 保留，不显示标题栏图标，也不计入 `+N`；没有可展示账号时隐藏这组额度控件。暂时读取失败、离线或数据过期仍沿用灰色状态提示。
- 同一账号以所有有效窗口中的最低剩余百分比表示当前限制：大于 20% 绿色、大于 10% 至 20% 橙色、10% 及以下红色；已耗尽显示完整红色轮廓。窗口缺失、过期、未知、离线、来源冲突或采样过旧时显示灰色虚线，详情保留上次读数。不会在重置时自行补到 100%。
- 悬停约 450ms 显示账号、各额度窗口和采样时间；点击固定详情，显示进度、重置时间、来源 Host 与 Dashboard 入口。直接点击另一账号切换卡片，点击外部或 Escape 关闭。
- 常规宽度最多四个图标，其他账号进入 `+N`；随窗口缩窄逐步减少图标，空间不足时保留额度入口。额度区域有界，剩余空间继续使用原生工具栏 spacer，保留窗口拖动与系统双击行为。
- 每个窗口仅读取共享 `DashboardStore`；15 秒展示时钟用于更新过期状态和相对时间，不发起查询。沿用 Mac 每 30 秒快照监控及 Host 的一分钟账号查询限频，悬停、打开卡片和新增独立窗口不增加查询。
- 本版不增加账号历史图，也不将现有 Host／项目 token 历史归给当前账号。当前协议没有套餐字段，因此不推断或编造套餐名。
- 图标资源仅用于识别来源服务：[OpenAI 官方开发者站点图标](https://developers.openai.com/favicon.svg)、[Claude 官方站点的品牌符号](https://claude.com/)。商标归各自所有者；未使用 Agent HUD 的代码或资源。
- `DashboardToolbarAccountTests|DashboardQuotaAlertTests|DashboardOverviewTests|DashboardStoreTests` 共 28 项专项测试通过，覆盖阈值、全部额度约束、身份去重与稳定顺序、离线／过期／冲突状态，以及现有提醒与共享缓存规则。Mac Debug 完整构建通过。
- 原生 SwiftUI／AppKit 隔离验收四组通过：主窗口与独立窗口、明暗主题、实时账号更新、一次点击切换详情、Escape／外部关闭、溢出列表与窄窗口，以及系统 Maximize／Minimize／None 双击行为。另用实际弹层组件检查显示摘要前后 key window 与文本输入 first responder 均保持。
- 隔离 Mac Host／Viewer 的 74 步验收通过，包含真实鼠标悬停摘要、两端窄窗口额度入口、进入 Dashboard 与加密机器数据请求；截图人工检查，不对动态额度进行像素比较。日志和截图在 `.build-local/diagnostics/titlebar-quotas-20261019/`，不进入 Git。未替换用户安装的 App，也未打包发布。

### 11.5 iOS 会话列表状态入口（2026-10-19）

- 顶部 Dashboard 入口以紧凑图标替换 Connected／All Connected 长文字；点击仍打开现有 Dashboard，不新增设置或轮询。
- 连接状态独立显示：全部连接为绿点，部分连接为橙点及 `1/2` 比例；正在连接显示橙色刷新图标，全部断开显示红色断线图标，尚未配对显示灰色断线图标。
- 复用 Mac 菜单的 `pendingSessionCount`：未处理的完成、Questions、审批及手动等待状态参与计数。按 Host 分别聚合，避免同名会话或相同 pane ID 跨 Host 合并；移除配对后不再计入。数量超过 99 显示 `99+`，辅助功能保留完整计数。
- 复用 `DashboardQuotaSummary.isLow`，只为新鲜、可信、无冲突且剩余额度不超过 10% 的账号显示橙色警示；同账号多 Host 去重。待处理数量与额度告警同时存在时一起显示，连接状态不被覆盖。实时断线立即排除该 Host 的额度告警，缓存待处理信息仍可保留。
- 状态随现有会话推送及 Dashboard 前台快照更新；保留原有 30 秒监控和 Host 侧一分钟账号查询限频。Low quota alerts 开关控制系统通知，不隐藏入口上的状态。
- `IOSDashboardStatusTests|PendingSessionCountTests|DashboardQuotaAlertTests` 共 19 项专项测试通过，覆盖跨 Host 同名会话、已处理状态、共享账号去重、阈值、断线／移除配对及失效额度；iOS Simulator Debug 完整构建通过。
- 使用生产按钮组件的隔离 SwiftUI App 验证正常、待处理、低额度、两种告警并存、部分连接、断线、连接中及未配对状态，并检查明暗主题、较大字号、`99+` 和 Dashboard 打开回调。聚合逻辑使用生产模型运行专项测试；UI fixture 提供受控状态，不代表真实多 Host 链路或 iPhone 真机验收。证据在 `.build-local/diagnostics/ios-dashboard-status-20261019/`，未替换用户安装的 App，也未打包发布。
