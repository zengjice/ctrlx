# Relay 接入认证与月度流量额度设计

记录日期：2026-11-01。源码核对基线：`5e678622`。

**状态：首版已实现，隔离环境核心流程验收通过，尚未发布。** 用户已授权按本文实现，并在本机运行隔离版 CtrlX、在 qcloud 部署隔离 Relay 验证；不得影响现有本机 App 和线上 Relay。设计约束见下文，实际进度和证据范围见第 10 节。

本次采用 **管理员发放接入密钥、配对时签发设备凭证、按账户记录月度流量、转发前原子扣量**。用户在 Host 配置一次密钥，Viewer 保留输入配对码的体验；额度不足时三端明确提示，加量或跨月后可恢复连接。

## 1. 已确认需求与建议默认值

用户已确认：

- Relay 提供简单可靠的接入认证，按流量记录额度，超额拒绝并提示。
- 额度每月重置，允许临时加量；初期可由管理员使用脚本操作。
- 按接入账户共享额度。同一账户的多台 Host 共用额度，Viewer 消耗所连接 Host 所属账户的额度。

本次实施采用以下默认值：

| 项目 | 默认行为 |
| --- | --- |
| 账期 | 北京时间自然月，客户端使用服务端提供的重置时间 |
| 临时加量 | 仅指定月份有效，未使用部分不结转 |
| 基础月额度修改 | 默认下月生效；本月增加使用临时加量 |
| 计量口径 | Relay 已接受转发的完整应用消息字节数 |
| 接入体验 | Host 输入账户密钥，Viewer 自动取得配对凭证 |
| 既有配对迁移 | 启用认证计量模式后重新认证、配对一次 |

首版按现有单实例 Relay 部署设计，使用本地持久化数据库。不包含账号注册、支付、套餐商城、跨 Relay 共享额度或多节点计费协调。

## 2. 改造前的约束

| 改造前事实 | 对本需求的影响 |
| --- | --- |
| WebSocket 从请求读取 `pairId/deviceId/deviceType`，先注册连接，再验证配对和订阅 | 必须先验证凭证及权限，再占用路由或替换旧连接 |
| 配对注册、查询和删除缺少本次所需的账户认证；设备 ID 由客户端提供 | 账户不能由客户端填写的 ID 决定，全部配对入口都需校验权限 |
| `MetricsService` 只保存进程内消息条数 | 无法作为按字节计量、跨重启保留的账本 |
| 配对以整份 JSON 保存，保存失败仅记录日志 | 不适合承担扣量、加量与身份绑定的事务一致性 |
| 已有订阅检查使用 Host 设备 ID，并在连接和定时检查时执行 | 可参考提示方式，但不能直接作为账户认证或逐消息额度检查 |
| 终端数据通过每连接 FIFO 按序转发 | 扣量增加异步等待后，仍须保持顺序和旧连接失效规则 |

这些结论来自仓库应用层代码核对，不代表对线上代理配置的完整审计。主要入口见文末。

## 3. 接入认证与配对权限

区分三个对象：**账户是稳定归属，密钥和凭证是可撤销的授权，设备和配对 ID 是标识。** 换密钥、重装客户端、重新配对不会重置账户用量。

1. 管理员创建账户并设置基础月额度，服务端生成高强度随机接入密钥。
2. Host 将密钥保存到 Keychain，按 Relay 地址隔离；首次配置时向 Relay 验证。
3. Host 申请配对。服务端从有效密钥确定账户，创建绑定该账户的待配对记录，并签发仅限本次配对和 Host 角色的凭证。
4. Viewer 使用短期、一次性配对码完成配对，取得仅限本次配对和 Viewer 角色的凭证，自动保存。
5. 后续 WebSocket、配对状态查询、解除配对和设备登记均验证凭证。角色、设备与配对归属必须匹配服务端记录，不能通过请求字段改写。

账户接入密钥只交给拥有账户管理权限的 Host 用户；Viewer 不取得该密钥，也不能用配对凭证创建 Host、领取其他配对权限或修改额度。Mac 同时作为 Host 和 Viewer 时，两种角色分别使用各自凭证。

建议使用至少 32 字节的密码学随机密钥，服务端保存摘要。通过 HTTPS/WSS 的 `Authorization: Bearer` 请求头传输，日志不得记录密钥、配对码或完整凭证；切换 Relay 地址不能自动把旧密钥发送到新服务。此传输方式遵循 [RFC 6750](https://www.rfc-editor.org/rfc/rfc6750.html#section-2.1) 对请求头的建议。

**认证和配对权限检查必须在 `ConnectionHub.register` 之前完成。** 等待期间沿用有界入站队列，未通过验证的连接不得替换有效连接。长连接转发时仍检查账户和凭证是否有效，使停用和撤销作用于已有连接。

配对码保持短期、一次性，并增加尝试频率、待配对数量和连接数量限制。免费控制消息采用固定白名单及大小限制，触发业务输出的请求不能仅因属于“控制消息”就绕过额度检查。

密钥轮换保留账户和用量。普通轮换可保留既有配对；泄漏处置需显式支持同时撤销相关配对凭证。停用账户后，其下所有凭证停止获准转发。

## 4. 月度账本与流量口径

```text
当月总额度 = 当月基础额度快照 + 当月临时加量
当月剩余额度 = 当月总额度 − 当月已计量字节数
```

每个账户、每个月只有一份账期记录。基础额度在账期创建时固定下来，历史记录保留；客户端只展示服务端结果。内部统一使用整数 bytes，界面与脚本明确标注 GiB。

服务端在查询和扣量时确定当前账期，按需创建新记录。跨月不依赖准时执行的清零任务；服务停机后恢复也能进入正确账期。加量命令明确指定月份，新加量仅允许当前账期；已成功请求跨月重试仍返回原账期结果，避免重复加量，也避免提前冻结未来账期的基础额度。首版部署确定账期时区后，不在运行中随意切换。

| 流量 | 计量规则 |
| --- | --- |
| Host → Viewer、Viewer → Host | 各次获准转发计一次，不把接收和发送同一消息重复扣量 |
| 同一内容发给多个 Viewer | 每个目标分别计量，汇总到账户 |
| 终端、文件、Browser 画面与音频、Simulator | 统一按外层完整加密消息的字节长度计量，包含加密、Base64、JSON 开销 |
| APNs 业务推送 | 走同一账户额度检查，按获准提交给 APNs 的序列化通知正文计量 |
| 心跳、认证、额度查询和限额提示 | 免费，使用固定结构并限制频率和大小 |
| 未认证、格式无效、目标不存在而未获准转发的消息 | 不扣量，按协议拒绝或结束连接 |

Relay 无需解密业务内容，也不依赖客户端上报流量。账本统计应用层转发量，不包含 TCP/TLS 等网络开销，不能声称与云厂商网卡账单完全一致。客户端重新提交且再次获准转发的业务数据重新计量，底层网络重传不重复计量。

**计量成立点是持久化扣量成功、Relay 接受转发。** 此后发生断线或发送失败，可能已经扣量但对端没有收到。首版明确接受这一边界，不承诺按对端实际展示量计费，也不引入交付确认、自动退款或任意业务重放协议。

## 5. 持久化与转发一致性

建议将权威数据放入同一个 SQLite 数据库，并保持明确的存储职责：

| 记录 | 必要内容 |
| --- | --- |
| 账户 | 稳定 ID、显示名称、启用状态、基础月额度配置 |
| 凭证与配对 | 凭证摘要、账户、配对、角色、设备关联、撤销状态及原有配对元数据 |
| 月度用量 | 账户、账期起止、基础额度快照、临时加量、已用字节 |
| 管理调整记录 | 唯一请求 ID、目标账期、加量值、原因、时间与结果 |

只保存必要的聚合用量和管理记录，不为计量保存业务消息内容。配对完成与权限绑定必须一致提交；失败不能返回可用凭证。现有 `pairs.json` 的迁移需要单独验证，不能静默把导入失败当作空数据库继续服务。

正常转发顺序为：

```text
验证当前连接与权限 → 检查目标连接 → 原子检查并扣量
→ 持久化提交成功 → 按现有 FIFO 转发
```

- **原子扣量：** 余额检查和用量增加在同一事务完成，多 Host、多 Viewer 并发也不能超扣。记录所属账期由服务端本次准入时间确定。
- **完整消息边界：** 不足以容纳下一条消息时整条拒绝，不扣成负数、不截断消息。还存在余额时保留真实数值，只停止受影响的数据流；不能因一条大消息失败就把整个账户余额清零。
- **连接顺序：** 沿用每连接单一消费者；等待持久化期间发生重连，发送前重新校验连接身份，旧连接不能重新取得路由。已接受但未送达的数据遵循上一节计量边界。
- **失败处理：** 数据库不可读、不可写或事务结果无法确定时，停止相关准入并返回服务异常，不能放行或重新初始化额度。账本错误与余额不足使用不同状态。
- **并发管理：** 加量与转发共用数据库事务规则。运行中的 Relay 必须读取权威额度和账户状态，不能只依赖启动时缓存。

SQLite 建议使用 WAL 与 `synchronous=FULL`，数据库置于持久化本地卷。[SQLite 官方说明](https://www.sqlite.org/wal.html#performance_considerations)指出 FULL 在提交时同步 WAL。备份和恢复要覆盖一致的数据库状态，不能只复制一个可能遗漏 WAL 内容的文件；具体迁移、备份和恢复命令需在实施时验证。

数据库 I/O 不应阻塞网络事件循环。先实现正确的事务路径并压测终端延迟、Browser 和音频吞吐；若每消息提交成为瓶颈，可在有界等待内合并提交，仍需提交成功才放行。不能用“先转发、几秒后补账”替代持久化准入。

## 6. 超额提示和恢复

建议使用共享状态模型，让 HTTP 状态查询与 WebSocket 通知表达相同原因。拟议状态包括认证缺失或失效、账户停用、`QUOTA_EXCEEDED`、单条消息额度不足、账本服务异常；具体协议名称在实施时确定。

额度状态至少包含账期、基础额度、临时加量、已用、剩余和下一次重置时间。新旧状态响应必须有明确顺序，避免迟到响应覆盖加量或跨月后的结果。Viewer 仅能查询其配对所属账户的额度摘要。

1. 转发被拒绝时，Relay 使用自身控制消息通知两端。提示本身不占业务额度。
2. 停止受影响的数据流；账户额度归零时，所有关联配对停止业务转发。已获准的数据可能仍在发送中，后续消息不得继续获准。
3. 结束相应数据连接并保留配对；客户端停止流订阅、清理音频和远程控制状态，避免丢帧后继续使用旧流。
4. Mac Host、Mac Viewer、iOS 保留明确的限额状态，不能被普通断线清理覆盖，也不能因此自动解除配对。
5. 暂停普通快速重连。用户可“检查并重连”；前台可低频检查，应用回到前台或跨月时重新查询。加量成功后无需重启 Relay。
6. 恢复连接时重新建立终端快照和画面。已经发出但未确认的命令显示结果未知，不自动重放输入、粘贴、安装或其他写操作。

鉴权失败或握手阶段被拒绝时，也要能经 HTTP 查询获得可展示的原因，不能只留下 URLSession 网络错误。额度查询与解除配对在额度耗尽时仍可使用，但必须认证。

Host 本地终端与 Agent 任务继续运行。远程请求若已在 Host 执行，只是响应被额度限制拦住，不能向用户声称操作未执行。

界面建议在 Relay 设置页显示下面的示意信息，并在连接受限时持续显示简短原因：

```text
本月已用：42.6 / 60 GiB
基础额度：50 GiB   临时加量：10 GiB
下次重置：12 月 1 日 00:00（北京时间）
```

同一账户在多个 Host 下出现时，应标明“共享额度”，避免相加。Relay 流量额度与现有 Agent 服务商额度分别展示；不必为正常状态增加一套复杂告警界面。

## 7. 管理脚本

首版管理入口已加入 Relay 可执行文件，以 `CtrlxExternalServer relay-admin` 调用。先设置该隔离实例的 `DATA_DIRECTORY`；命令操作同一账本，不开放公网管理 API。以下示例额度不代表产品默认值：

```bash
CtrlxExternalServer relay-admin account create --name alice --monthly-quota 50GiB
CtrlxExternalServer relay-admin usage show --account alice

CtrlxExternalServer relay-admin quota add --account alice --month 2026-11 \
  --amount 20GiB --request-id support-20261101-001 \
  --reason "临时加量"

CtrlxExternalServer relay-admin account disable --account alice
CtrlxExternalServer relay-admin key rotate --account alice
```

加量请求 ID 在第一次执行前确定，重试复用同一个 ID。同 ID、同参数返回原结果，不重复加量；同 ID、不同参数明确报冲突。调整记录与额度增加同事务提交，命令输出结果及调整后的额度。金额参数只接受有效、无溢出的整数换算结果，加量不覆盖已用流量。

入口同时提供 `account set`、`pair revoke` 和 `account enable`，分别调整下月基础额度、撤销配对凭证及恢复账户。密钥明文只在生成时交付，不写入普通日志。管理员操作审计记录保留原因和结果。

## 8. 实施顺序与兼容

1. **账本与管理操作：** 引入账户、凭证、月度用量与幂等加量，验证崩溃恢复和并发事务。
2. **认证与逐消息准入：** 覆盖配对、WebSocket、双向加密转发、APNs 及免费控制消息边界，保留 FIFO 和重连身份校验。
3. **三端接入与提示：** 更新 Host、Mac Viewer、iOS 的凭证保存、HTTP/WS 请求、后台连接、额度展示和恢复路径。
4. **隔离验收后切换模式：** 先提供兼容客户端，再显式启用认证计量模式并处理旧配对迁移。实施完成不自动构成生产部署授权。

运行模式通过 `RELAY_ACCESS_MODE=open|metered` 显式区分开放模式与认证计量模式，默认 `open`。自建 Relay 可继续使用开放模式；选择认证计量后，缺少配置、存储损坏或未知凭证必须明确失败，不能自动退回开放。现有订阅授权与新模式首版互斥，避免两套放行条件叠加。

旧配对没有可信账户归属，不能仅凭旧 `pairId/deviceId` 换取新凭证。建议首次切换时重新认证、配对，界面明确解释；本地任务无需因此结束。旧客户端需获得升级或认证提示，版本号只能用于兼容提示，真正的访问限制必须依赖凭证验证。

旧配对数据导入、失败回滚和保留工作区展示状态需要专项验证，不承诺无感迁移。回滚应用前确认数据库兼容性或停止服务；不能通过恢复旧用量文件、清零或开放访问来掩盖故障。

认证入口按已验证凭证限流，额度状态查询按已验证账户限流；未认证失败使用独立桶，不能耗尽有效凭证的桶。无需凭证的配对完成入口按客户端地址限流。反代部署需通过 `RELAY_TRUSTED_PROXY_IPS` 显式指定可信代理的 socket IP；默认不信任转发头，配置后仅沿可信代理链从右向左解析 `X-Forwarded-For`。Docker 部署使用容器实际看到的代理地址，详见自建文档。

## 9. 验收标准与当前验证状态

| 验收范围 | 必须覆盖 |
| --- | --- |
| 身份与权限 | 无凭证、错误账户、角色冒用、旧凭证和撤销凭证被拒绝；错误连接不能替换正常连接 |
| 接入覆盖 | 配对注册/完成/查询/删除、HTTP 与 WS、设备登记、APNs、免费消息大小和频率限制 |
| 共享额度 | 多 Host、多 Viewer 同时争用最后额度，恰好够用与不足一条消息，整数边界 |
| 计量口径 | 双向转发、多 Viewer、编码开销、目标离线、业务推送、发送失败与重试 |
| 持久化 | 提交前后进程崩溃、重启、数据库不可写、存储恢复；不能漏掉已提交扣量或重复加量 |
| 月度切换 | 持续连接跨月、月初停机、临时加量到期、月末加量重试、迟到状态响应 |
| 客户端体验 | 三端持续提示、有限重试、配对保留、加量后恢复、快照重建、未确认写操作不自动重放 |
| 性能与兼容 | 终端有序低延迟、Browser/音频吞吐、入站背压、新旧客户端、开放模式与旧数据迁移 |

上表为完整验收矩阵，首版核心流程已通过专项测试和三端隔离验收。真实 APNs 投递、Browser/音频的专项性能及跨机器长期运行仍不在本次通过范围内。证据和实际边界见第 10 节。

主要代码与资料入口：

- [WebSocketController](../CtrlxPackage/Sources/CtrlxExternalServerLib/Routes/WebSocketController.swift)、[PairingController](../CtrlxPackage/Sources/CtrlxExternalServerLib/Routes/PairingController.swift)：认证入口、握手及配对。
- [PairingService](../CtrlxPackage/Sources/CtrlxExternalServerLib/Services/PairingService.swift)、[Pair](../CtrlxPackage/Sources/CtrlxExternalServerLib/Models/Pair.swift)：配对归属与持久化。
- [ConnectionHub](../CtrlxPackage/Sources/CtrlxExternalServerLib/Services/ConnectionHub.swift)、[RelayService](../CtrlxPackage/Sources/CtrlxExternalServerLib/Services/RelayService.swift)、[RelayInboundQueue](../CtrlxPackage/Sources/CtrlxExternalServerLib/Services/RelayInboundQueue.swift)：转发准入、连接替换、顺序和背压。
- [MetricsService](../CtrlxPackage/Sources/CtrlxExternalServerLib/Services/MetricsService.swift)、[APNsService](../CtrlxPackage/Sources/CtrlxExternalServerLib/Services/APNsService.swift)、[configure](../CtrlxPackage/Sources/CtrlxExternalServerLib/configure.swift)：监控、推送和运行模式。
- [ConnectedViewer](../CtrlxPackage/Sources/CtrlxServerFeature/Services/ConnectedViewer.swift)、[ViewerRelayClient](../CtrlxPackage/Sources/CtrlxCommon/Services/ViewerRelayClient.swift)、[PairingAPIClient](../CtrlxPackage/Sources/CtrlxServerFeature/Services/PairingAPIClient.swift)：Host/Viewer 凭证传输与错误恢复；另需覆盖 Mac/iOS 配对和删除入口。
- [WebSocketMessage](../CtrlxPackage/Sources/CtrlxNetworking/Models/WebSocketMessage.swift)、[PairingModels](../CtrlxPackage/Sources/CtrlxNetworking/Models/PairingModels.swift)：共享状态与兼容字段。
- [Streaming](streaming-architecture.md)、[Self-hosting](self-hosting.md)、[Monitoring](monitoring.md)：顺序、运维和可观测性约束。
- [原订阅设计](superpowers/specs/2026-07-13-hosted-relay-monetization-design.md)、[试用期触发修订](superpowers/specs/2026-07-15-trial-status-badge-and-pairing-trial-start-design.md)：历史机制参考，不作为本次账户认证或流量计量的既有实现。


## 10. 实施进度（2026-11-01）

| 范围 | 当前状态 |
| --- | --- |
| SQLite 月度账本与管理入口 | 已加入 WAL/FULL、事务扣量、月度快照、幂等加量、撤销与账户停用；7 项账本及管理测试通过。新加量只允许当前账期；已提交的旧账期请求可幂等重试 |
| Relay 接入与转发 | 已加入 `RELAY_ACCESS_MODE=open|metered`、配对凭证、HTTP 状态、双向转发和 APNs 准入；4 项真实 HTTP/WS 测试通过，包含角色、设备、配对范围、零额度配对、后台推送及超额关闭 |
| 客户端 | 已加入 Relay/配对/角色隔离的凭证存储、保存前验证、WS 认证、持续提示、前台及 30 秒额度恢复检查；Mac 与 iOS 编译通过。签名隔离 Mac Host、Mac Viewer 和独立 iOS 模拟器已通过真实云端配对、共享额度、超额提示、加量后自动恢复和终端快照/输入验收 |
| 专项及兼容回归 | 本轮 41 项测试通过：34 项 Relay 测试、5 项共享凭证/恢复测试、2 项 Host 配对测试；包含既有开放模式、订阅及旧连接替换回归。这不是全仓测试结果 |
| 真实进程故障与传输 | Debug Relay 实际转发 200 条约 128 KiB 的加密包，共 26,233,000 bytes，逐包顺序和扣量一致；耗时 3.02 秒，约 8.29 MiB/s，往返中位数 28.4 ms。提交后 SIGKILL 重启保留用量；写锁等待中终止不增加用量、不重放；真实 SQLite 写锁导致准入失败时未扣量，健康检查耗时 1.34 ms。这是本机并发构建时的单次测量，不代表 qcloud 或完整 Browser/音频性能 |
| qcloud | Linux/amd64 镜像已在本机构建并通过容器烟测；已部署独立容器 `ctrlx-relay-quota-20261101`，仅绑定 `127.0.0.1:18841`，使用独立数据库和 0.5 CPU / 384 MiB 资源上限。生产容器、Nginx、网络和数据未修改 |
| 云端协议验收 | 实际 HTTP/WS 验证两组配对共享额度、错误角色不能替换连接、整包拒绝、幂等加量后恢复、离线目标不扣量、撤销即时生效；80 条约 128 KiB 双向包逐包顺序及扣量一致，共 10,493,200 bytes。SSH 隧道下逐条等待响应耗时 17.72 秒，往返中位数 437.6 ms；这不是 Browser/音频并发吞吐测试 |
| 原生 App 验收 | 1 项 opt-in Mac E2E 场景通过（296 秒），包含错误密钥不覆盖有效密钥、真实 E2EE 终端输入、超额保留配对、幂等加量及自动重连。iOS 原生 UI 完成同账户第二 Viewer 配对、正余额不足一条消息的持续提示、32 MiB 加量幂等、自动恢复、终端新内容及输入到达 Host。隔离云容器重启前后已提交用量均为 13,596,675 bytes，随后 iOS 自动重连并显示新输出 |
| 文档与配置 | 已加入自建运维命令、迁移边界、存储备份注意事项和 `RELAY_ACCESS_MODE` 示例；Compose 显式传递该配置，默认开放模式 |

本次验证使用独立 App 标识、私有 tmux socket、假 Keychain/偏好存储和独立 iOS 模拟器，不替换已安装 CtrlX。云端测试容器使用独立数据库、镜像和端口；线上 `ctrlx-relay` 与 `happy-nginx` 的容器 ID、镜像、启动时间、配置摘要及挂载均与基线一致。本机已安装 App 文件哈希一致。

验收完成后已退出隔离 Mac App、停止私有 tmux 和本次 iOS 模拟器、关闭 SSH 隧道，并停止云端测试容器。测试账户已停用；保留隔离容器、镜像、数据库和验证产物供后续核对，不保持后台测试流量。

验证日志和截图位于本工作树忽略的 `.build-local/relay-access/` 与 `.build-local/upstream-browser-proof.relay-quota-20261101/evidence/`；主要记录为 `release-candidate-regression.log`、`mac-acceptance-build.log`、`ios-acceptance-build.log`、`cloud-wire-summary.json`、`native-cloud-title-fix.log`、原生验收的 `summary.json` 和 `ios-summary.json`。

APNs 使用隔离日志验证序列化正文的准入与计量，未使用真实推送凭证向设备投递。传输压测使用合成不透明加密信封，不代表完整 Browser/音频吞吐保证；未运行全仓无过滤测试或跨机器长期稳定性测试。首版核心验收通过不构成生产启用授权，默认仍为开放模式。尚未推送或发布。

后续评审修复：额度限制关闭 Viewer 连接时同时清理 Host 在线状态并通知流中断，使已打开的 Mac 终端能在重连后重新订阅；认证请求与匿名请求分桶，并加入显式可信代理 IP 配置；取消中的账本请求不再报告账本故障，拒绝通知在执行前复核源连接；连接与重连测试全程注入内存凭证。45 项专项测试通过（32 项 Relay、13 项共享连接/凭证/恢复测试），记录为 `.build-local/relay-access/review-fixes-regression-verified.log`。这批修复未重新安装原生 App 或部署 qcloud；上面的原生界面和云端镜像证据来自修复前构建，不作为本轮新验证。

补充 Host 测试修复：为 Host 生命周期及文件请求、终端流、粘贴、快捷短语五组真实连接夹具注入完整作用域的内存密钥与凭证。Host 半开连接自动重连用例及相关 Host/Viewer 共 17 项测试通过，记录为 `.build-local/relay-access/host-credentials-regression.log`。
