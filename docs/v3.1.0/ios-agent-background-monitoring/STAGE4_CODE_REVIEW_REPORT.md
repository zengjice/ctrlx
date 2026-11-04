# Stage 4 Code Review Report

> Historical record: Background Agent Monitoring has been removed. iOS alerts
> now use APNs exclusively. See [current notification delivery](../../services-reference.md#push-notifications).


## Review scope

- iOS 26 `BGContinuedProcessingTask` 封装和系统生命周期
- Agent prompt 识别、状态转换和任务结束条件
- 设置持久化、可用性提示及关闭开关后的清理
- Host 断连、系统到期和系统拒绝任务时的降级路径
- 普通 Agent 通知的 tmux 上下文、兼容降级和 actionable notification 延续性
- 锁屏期间的 Viewer Relay 探活、重连和 SessionState 终态补偿
- Viewer 传输中断与 Host 离线的生命周期边界

## Findings

- P1：无
- P2：无
- P3：无

## Resolved during review

- 真机崩溃报告显示 launch handler 在 BGTaskScheduler 私有队列触发了 Swift 6 actor 隔离检查。显式指定 main queue，使 handler 与 `@MainActor` runtime 的执行器一致。
- 每轮用户提交使用唯一动态任务标识，避免系统拒绝重复提交已经完成的 continued-processing request。
- 真机 120 秒静默测试证明 indeterminate progress 即使改变 `completedUnitCount` 仍会被系统判定为 stalled。改为两小时有限监控预算，每 10 秒完成一个 activity unit；圆环表示监控预算而非 Agent 完成百分比。
- 连续两轮真机提交一轮有卡片、一轮无卡片，定位到前台提交竞态：终端 Enter 路径把系统请求推迟到 unstructured Task，结构化回复路径更是在等待 Relay 回执后才提交。两条路径均改为在用户输入事件内同步提交；发送失败再显式结束任务。
- 卡片标题由固定产品名改为 `session · window`，副标题仅显示 status。window name 直接取当前 `TmuxWindow` 快照，不增加查询或轮询；空名称时标题自动退化为 session。
- 普通通知同步改为标题 `session · window`、副标题状态、正文 Agent 回复。Mac Host 将可选 subtitle 放入既有 E2EE payload；iOS 实时链路用本地 `PaneState` 为旧 Host 补齐上下文，无 pane 元数据时保留旧文案。
- 标题和副标题分别按 120 UTF-8 bytes 截断，最坏 actionable notification 仍低于 APNs 4096-byte 上限；按 bytes 而非字符限制，覆盖中文和 emoji。
- 修正文档和代码注释，使终端键盘提交路径与结构化 Agent response 的边界一致。
- Viewer 自身 WebSocket 中断不再伪装成 Host 离线；iOS 保留有限监控并触发现有重连，macOS 仍清理失效的远程 UI 快照。
- continued-processing task 启动、App 转入后台和十秒 activity tick 复用现有 Viewer 连接做 Host 级探活；半开连接只替换当前 generation，不建立第二条 socket。
- 活跃监控最多每 30 秒请求一次 SessionState。新提交前 5 秒拒绝旧终态，随后可用快照补齐丢失的完成/等待输入事件并生成本地兜底通知。
- 快照发送结果贯穿 Relay client、单 Host connection 和 manager；WebSocket 写失败不会误占 30 秒节流窗口。
- 增加 task submit/launch/expire、scene phase、连接替换及超过 3 秒的状态/通知/快照延迟诊断；E2EE Relay 不新增明文时间戳。
- 真机三轮测试暴露终态状态帧先结束后台活动、独立通知帧随后被系统暂停的竞态。完成状态现在同步生成本地通知；状态、快照和原通知帧按 pane 去重，actionable notification 不会因去重丢失按钮。
- 连续轮次测试暴露上一轮回复已可见、但最终 `.doneWorking` 尚未到达时，终端 prompt 被 `.working` 门禁误判并跳过后台任务。非阻塞 working 输入现在按 steer/排队 prompt 处理；完成路径也改为先提交本地通知、再结束系统活动。
- 真机测试发现正常完成、pending cancel 和系统 expiration 都可能被系统展示为“任务失败”；同时 `.queue` 会让旧 Agent turn 在后续 prompt 中延迟显示。最终语义统一为：运行中、提前完成和本地监控租约到期都成功完成 task；提交使用 `.fail`，只有能立即运行的当前轮次才创建卡片，否则降级为正常通知。
- 真机连续消息测试进一步定位到 pending request 没有 launch 时只留待回调完成，导致它跨轮占用系统槽位。现在仅对已启动 task 调用成功完成；尚未启动的 request 直接取消，并在 App 启动时清理上个进程遗留的同前缀 request。
- 真机测试确认更早的首轮缺口来自 Agent pane 分类：Host 的进程校准最长十秒，首条 prompt 在 `AgentSession` 建立前被 iOS 状态门禁丢弃；首轮执行随后建立状态，造成第二条及以后全部正常。iOS 现在短暂保留未分类 pane 的非空提交，只接受同 pane 的新鲜 `.working` 事件作为确认；普通 shell 不会误建活动。
- 真机控制台进一步证明部分 Agent 的首个 live 状态不会在确认窗口内到达，但十秒进程校准快照已能证明 pane 类型；快照现在也可确认这条 pending prompt。同轮日志还发现旧 `MaintainWebSocket` UIKit task 的 expiration handler 通过 unstructured Task 延迟收尾，系统因此终止 App 并把已 launch 的活动标成失败；expiration 改为同步结束。
- 新版真机日志证明首轮 request 已提交且 5ms 内 launch，但系统仍未绘制卡片；第二轮才产生系统 UI 和触觉反馈。scene background 再刷新一次仍无法改变结果，说明更新时机必须早于离开前台。现在 launch handler 同步完成第一个 activity unit，后续仍由十秒 reporter 有界推进。
- 首轮 `Up` + `Enter` 复现证明终端历史文本由 shell 管理，本地累计器不能仅检查可见字符；累计器迁移到按 Host/pane 持有的后台监控服务，并显式处理历史键和清空键，避免 SwiftUI View 重建丢失输入状态。
- 完成通知直到 App 回前台才被调度，证明 continued-processing task 不能替代前后台切换时的即时运行租约。进入后台时现在始终并行申请一次 UIKit 短租约；连续两轮即时回复和两轮延迟 30 秒回复均在真机同时显示活动与完成通知。
- 强制终止后仅靠 App 重开无法可靠重建活动。Apple 要求 continued-processing request 由明确用户操作触发；删除前台自动提交和退避重试，改为开启开关、显式启动按钮或提交 Agent prompt 时幂等建立全局会话。
- 全局会话不再绑定单个 Agent turn，旧版 `.fail` 的防串轮理由已经消失。系统并发槽位不足时改用默认 `.queue` 保留唯一 request，并在 Settings 区分排队、已启动和同步提交失败。
- iOS 26.6 真机进一步证明 `.queue` 可能已经回调 `Active` 却不呈现系统活动 UI。最终恢复 `.fail`：显式用户操作要么立即建立可见活动，要么把调度错误展示给用户重试，不保留不可见队列。
- 系统 task 的默认进度是 `0/0`。运行时原先先 `updateTitle`、后配置 progress，首个系统 UI 快照可能仍是 indeterminate；现调整为先写入有效进度、再触发标题刷新，与 Apple 示例的发布顺序一致。
- 全局两小时监控卡片不再展示最后一个 `session · window`，因为它可能跨多个 Host 和 Agent turn 并长期过期。卡片固定显示 `CtrlX` 和当前工作 Agent 数量；具体上下文只保留在事件通知中。
- 删除持久化“已启用”偏好和独立 Start 按钮。唯一开关现在直接映射系统任务：开启即启动，关闭即停止，启动失败、到期、系统取消或新进程启动时均为关闭，避免 UI 显示开启但任务不存在。

## Maintainer assessment

- 开关默认关闭，升级不会改变现有后台行为。
- 一个有限全局任务可覆盖多轮 Agent 工作和多个 Host，最长两小时；不会在启动、回前台或后台自动续期。
- 使用 `.fail` 策略。系统活动必须立即对应当前用户提交；系统繁忙时直接降级到正常通知，不保留会串轮的排队任务。
- Agent 完成、等待输入和单 Host 断连只更新上下文；关闭开关、两小时上限和系统到期有明确结束路径。
- 复用既有 Agent 状态和本地通知链路；Relay 无需变化，新增 subtitle 为可选字段，新旧 Host/Viewer 可混用。
- 后台维护严格绑定由用户操作建立的有限全局会话；会话不存在时不探活、不拉快照。
- 多 pane 共用 Host 级节流，避免每个 pane 重复 ping 或请求完整状态。
- 该补偿缩短系统仍授予后台执行时间时的延迟，但不声称替代 APNs 的远程唤醒保证。

## Verification

- Agent 后台监控、通知展示、wire compatibility 和 push model：24 tests passed
- 新增快照、完成通知去重策略与 Viewer 半开连接回归：14 tests passed
- 最坏 actionable notification APNs envelope：低于 4096 bytes
- iPhoneOS generic destination build with code signing disabled：passed
- macOS arm64 app build：passed
- iPhone 真机 build `20260816-163349`：直接输入、历史提交、连续即时回复及 30 秒延迟回复通过
- `git diff --check`：passed

## Decision

Approved for physical-iPhone acceptance. Stage 4 remains unmerged until the user verifies the enabled and disabled paths on a real device.
