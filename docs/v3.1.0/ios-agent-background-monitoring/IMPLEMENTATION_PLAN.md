# CtrlX 3.1.0 Stage 4：iOS Agent 后台监控

> Historical record: Background Agent Monitoring has been removed. iOS alerts
> now use APNs exclusively. See [current notification delivery](../../services-reference.md#push-notifications).


> Stage 6 的用户意图持久化、下次输入自恢复和 active-turn 生命周期设计，
> 已替代本文中“开关即启动全局租约”“Agent 结束后保留空闲卡片”、
> “租约失效后开关关闭”和“不跨进程持久化”的旧语义。参见
> `docs/v3.1.0/ios-agent-monitoring-reactivation/IMPLEMENTATION_PLAN.md`。

## 问题

CtrlX 当前依赖前台 Relay 连接接收 Agent 状态并触发本地通知。App 进入后台后，
系统只给现有短时后台任务有限的执行窗口，因此刚离开 App 时偶尔还能收到通知，
但不能可靠覆盖一次较长的 Agent 运行。

## 最终设计

Stage 4 最终采用一个**有限期的全局监控会话**，替代此前“每个 Agent turn 一个系统任务”的设计：

1. Settings 的 Agent Input 区域保留唯一的 `Background Agent Monitoring` 会话开关，默认关闭，
   不跨 App 进程持久化。
2. 仅在 iOS 26 及以上启用 `BGContinuedProcessingTask`；旧系统保留现状。
3. 用户开启开关时立即建立一个全局监控会话：
   - 整个 App 同时最多一个系统 request/task；
   - 会话最长两小时，每 10 秒推进一个 monitoring activity unit；
   - 使用 `.fail` 即时策略；系统无法立即运行时显示明确错误，由用户稍后重试；
   - App 启动、回到前台、会话到期或系统取消时均不自动提交；开关同步回到关闭，用户下次
     明确打开时重新建立；
   - 启动失败时开关立即回到关闭，并显示系统错误。
4. Agent prompt、`.working`、完成、等待输入和 `.idle` 只更新同一张全局卡片，不结束监控
   会话。卡片标题固定为 `CtrlX`；没有 Agent 工作时显示 `Agent notifications active`，有
   Agent 工作时显示 `1 Agent working` 或 `N Agents working`。具体 `session name · window name`
   只出现在对应事件的普通通知中，避免全局卡片错误绑定最后一个 window。
5. Agent 完成通知继续走独立的加密通知/本地通知链路。状态帧和快照可提交兜底通知，
   但绝不拥有 continued-processing task 的生命周期。
6. 全局 reporter 维护当前 Viewer manager 中的全部 Host 连接：
   - 每个 Host 共享探活与快照节流；
   - 健康连接最多每 30 秒请求一次 SessionState；
   - Viewer 传输中断触发现有重连，不结束全局监控；
   - Host 离线或解除配对仅移除该 Host 的监控上下文，不影响其他 Host。
7. 关闭开关、两小时预算耗尽、用户取消或系统 expiration 才结束系统任务并清理 reporter。
8. UIKit 的约 30 秒短租约继续桥接前台切后台的调度窗口，与全局 continued-processing
   task 并行，但不建立第二条 Relay WebSocket。
9. 低噪声诊断继续记录 submit/launch/expire、scene phase、连接替换、快照和超过三秒的
   事件/通知延迟；Settings 明确显示 `Starting`、`Active` 或提交失败原因。
10. `BGTaskScheduler` 保持依赖封装；进度、通知去重和终端输入识别保持平台无关纯逻辑，
    便于单元测试。
11. 用户强制终止 App 时，iOS 可能把当时的 continued-processing task 显示为失败；进程已被
    杀死，App 无法改写该系统结果。重新打开 CtrlX 不会自动提交或轮询重试；用户重新开启开关
    后才建立新的有限监控会话。这是
    `BGContinuedProcessingTaskRequest` 要求由用户操作触发的系统边界。
12. iOS App 的 `Info.plist` 显式声明 `NSSupportsLiveActivities = true`。continued-processing
    task 仍由系统生成和管理活动 UI；CtrlX 不引入 ActivityKit Widget 或第二套活动状态机。
13. launch handler 先把系统 task 的 `Progress` 配置为有效的 determinate 值，再调用
    `updateTitle` 触发界面刷新，避免 iOS 首次快照到默认 `0/0` 进度后不呈现活动 UI。

## 迭代记录（已被最终设计替代）

以下逐 turn 方案用于记录 Stage 4 的问题演进，不再定义最终运行时行为。

1. Settings 的 Agent Input 区域增加 `Background Agent Monitoring` 开关，默认关闭。
2. 仅在 iOS 26 及以上启用 `BGContinuedProcessingTask`；旧系统保留现状。
3. 仅当用户从 iOS 提交非空 Agent prompt 时创建后台监控任务：
   - `.prompt`
   - `.replyAfterStop`
   - Agent idle/done/working 状态下通过终端键盘提交的非空输入行
   - Host 尚未完成 Agent 进程校准时，首条非空输入只作为短期待确认提交；首个 `.working`
     状态确认后创建活动，普通 shell 输入不会创建活动
   - 系统请求在 Enter/Send 的前台事件内同步提交，不等待 Relay 回执，也不推迟到异步任务
4. 使用 `.fail` 即时提交策略。卡片必须对应当前这次用户提交；系统无法立即启动时降级为
   既有通知链路，不允许旧轮次排队后在下一次 prompt 中延迟显示。
5. 每个 Host + pane 同时只保留一个监控任务；再次提交会替换旧任务。
6. 用真实 Agent 状态驱动两小时上限的有限监控进度：
   - prompt 已提交：等待 Agent 启动；
   - `.working`：Agent 正在工作；
   - 活跃监控期间：每 10 秒完成一个 monitoring activity unit，总计 720 units；
   - 完成、等待用户输入、失败、Host 断开、用户关闭开关或系统取消：结束任务。
   - 系统卡片标题显示 `session name · window name`，副标题显示 status；旧 Host 缺少 window name 时标题退化为 session name。
7. 继续复用现有 `onAgentNotification` 本地通知链路，不额外发送重复通知。普通通知标题显示 `session name · window name`，副标题显示事件状态，正文移除重复的项目名前缀；无 pane 元数据时保持旧格式。
8. Mac Host 在加密通知中附带可选 subtitle，iOS 实时链路也能使用本地 pane 快照补齐旧 Host 的通知上下文。该字段为可选字段，新旧版本混用时保持兼容。
9. `BGTaskScheduler` 封装为依赖，状态转换保持为平台无关纯逻辑，以便单元测试。
10. continued-processing task 启动、App 进入后台及每个监控 activity unit 都会驱动一次
    有界连接维护：
    - 立即探测现有 Relay WebSocket；
    - 连接不存在时立即进入现有重连流程；
    - 已连接但超过阈值没有入站帧时，用一次 ping 确认，超时后替换半开连接；
    - 连接维护只在至少一个用户提交的 Agent turn 仍受监控时运行，任务结束或过期即停止。
11. Viewer 自身传输中断与 Host 真正离线使用不同生命周期事件：
    - Viewer 网络中断只清理暂时失效的 UI 快照，不结束 Agent 后台监控；
    - Host 明确离线、解除配对或用户关闭开关才结束对应监控。
12. 活跃监控期间最多每 30 秒请求一次现有 `SessionStateMessage`，用于补齐断线期间丢失的
    Agent 完成状态。快照发现完成或等待输入时结束系统活动，并在后台补发一条普通本地通知。
    新提交后的前 5 秒不使用终态快照结束任务，避免把上一轮残留的 `doneWorking` 当成新一轮完成。
13. 增加低噪声诊断：记录 task submit/launch/expire、scene phase、连接替换和快照请求；
    Host 事件到 iOS 收包、本地通知提交、快照往返只有超过 3 秒才记 warning。Relay 无法读取
    E2EE 明文时间戳，因此不为埋点向 Relay 泄露额外元数据。
14. `.doneWorking` 状态帧在结束 continued-processing task 的同一 MainActor 回合内提交本地完成
    通知，避免系统在状态帧与随后独立 notification 帧之间暂停 App。两条路径按 Host/pane 使用
    5 秒去重窗口，先到者生效；带操作按钮的通知始终保留。
15. 连续轮次不依赖上一轮终态先到达：Agent 仍标记为 `.working` 时提交的非空终端输入按
    steer/排队 prompt 启动新监控。终态处理先把本地通知请求交给系统，再结束 continued-processing
    task，避免 iOS 在两步之间暂停进程。
16. 系统 request 与运行中 task 分开收尾：Agent 在 launch callback 前完成时取消 pending request；
    task 已启动时用成功状态完成。App 启动时清理上一个进程遗留的同前缀 request，避免首轮卡片
    被旧 request 占位并延迟到下一条排队消息出队时才显示。
17. 首次启动 Agent 不依赖十秒进程校准先完成：iOS 暂存未分类 pane 的首条非空 Enter，只有同 pane
    在 15 秒内收到真实 `.working` 状态或 Host 进程校准快照才补建活动；已分类 Agent 仍在 Enter
    事件内同步提交。
18. App 进入后台且 Viewer 仍连接 Host 时，始终申请一次约 30 秒的 `MaintainWebSocket` UIKit
    租约，桥接 continued-processing task 尚未获得稳定执行机会的窗口；两者并行而非互斥。
    fallback 租约的 expiration handler 同步结束 UIKit task，禁止异步跳转越过系统 deadline 后拖死 App。
19. launch handler 内同步完成第一个 monitoring activity unit，明确表示系统监控已经启动；不能让
    第一个非零 `completedUnitCount` 等到 App 进入后台后或十秒 reporter 才产生。
20. 终端输入累计器由后台监控服务按 Host/pane 持有，不依赖 SwiftUI View 生命周期；`Up`/`Down`
    表示由终端历史管理的非空输入，`Ctrl-C`/`Ctrl-U`/`Ctrl-W` 清空该状态，保证首轮历史命令也能
    建立监控，同时继续拒绝空 Enter。
21. 完成通知延迟一秒提交并标记为仅后台展示；如果 App 在通知实际展示时已回到前台，则由
    notification delegate 静默抑制，消除“刚切后台”和“刚回前台”的状态竞态。
22. Agent 完成早于 continued-processing launch callback 时，不在系统启动交界立即取消 request；
    保留一秒完成 tombstone，launch 到达即以成功状态结束，确认仍未启动才静默取消，避免 idle 后
    回到主屏幕偶发显示“任务失败”。

## 生命周期

```text
用户明确开启开关
              │
              ▼
     monitoring（最长两小时）
       │       │       │
   working   finished  needs input   ← 仅更新卡片并发送独立通知
       └───────┴───────┘
              │
              └── setting off / two-hour limit / user or system cancel
```

任务具有明确起点和终点。Agent 没有可预知的完成百分比，因此圆环表示两小时
后台监控预算的消耗；活动单位不表示 Agent 工作完成度。一个监控会话可以跨越多个
Host、pane 和 Agent turn，但 CtrlX 不在后台循环续期，也不承诺永久维持 Relay 常驻。

## 系统行为与限制

- 系统会在锁屏和系统界面显示该 continued-processing 活动，并允许用户取消。
- App 包必须声明支持 Live Activities；运行时 `Active` 仅证明后台任务已启动，不足以证明系统
  已为未声明该能力的 App 呈现活动 UI。
- 强制终止 CtrlX 会由系统结束正在运行的活动，系统可能短暂显示“任务失败”；重新打开 App 后
  开关默认关闭，需要重新开启才能建立新的有限监控会话。
- CPU 和网络访问使用基础能力，不依赖 APNs entitlement。
- 任务仍受系统调度和资源策略约束；开关开启不等于永久后台运行。
- 系统无法立即启动活动时不保留不可见的排队 request；Settings 显示提交错误，用户可在系统
  资源恢复后重试。即时策略也避免任务已回调为 `Active`、系统却没有呈现活动 UI 的 iOS 26.6
  真机问题。
- 主动探活和快照补偿可以缩短锁屏后的延迟，但 iOS 仍可暂停或终止后台任务，不能提供 APNs
  等级的实时唤醒保证。
- 此功能不能绕过 Personal Team 描述文件有效期，也不能替代正式 APNs 推送。

## 非目标

- 不实现无限后台保活、定时重启任务或静默自唤醒。
- 不建立第二条 Relay WebSocket；continued-processing task 复用并维护当前 Viewer 连接。
- 不改变 Relay 服务或要求协议版本同步升级。
- 不让 Agent 状态、普通 shell 输入、快捷键或审批按钮创建额外的系统任务。
- 不为 iOS 26 以下系统模拟 continued processing。

## 验收标准

- 开关默认关闭，并能持久化。
- iOS 26 开启开关后会提交且仅提交一个 continued-processing request；关闭开关立即停止。
  单纯启动 App 或回到前台不会提交系统任务。launch callback 到达前显示 `Starting`，到达后显示
  `Active`；即时启动失败、两小时到期、系统取消或下次进程启动时开关为关闭。
- 多个 Agent turn 和多个 Host 复用同一活动；卡片只展示全局监控和工作中的 Agent 数量，
  不绑定具体 window，也不因 Agent 完成或等待用户输入而结束全局会话。
- Viewer 传输短暂中断不会取消监控；continued-processing task 会触发现有连接立即重连。
- 丢失实时终态后，SessionState 快照能在后台生成一次兜底通知，但不结束活动。
- 正常实时终态会提交完成通知，且不与独立 notification 帧重复显示。
- 进入后台后的短任务由 UIKit 租约即时桥接，continued-processing task 继续覆盖较长运行；两者
  不建立额外 Relay 连接。
- 直接输入和终端历史提交可以更新卡片上下文，空 Enter 不会误触发状态变化。
- 健康连接至多每 30 秒请求一次快照，多个 pane 共享同一 Host 的节流状态。
- 普通通知按 `session · window`、状态、Agent 正文分层显示，无 pane 元数据时保持旧格式。
- Host 断开只移除对应上下文；关闭开关、两小时耗尽或系统取消时不会留下后台任务。
- 开关关闭及 iOS 26 以下行为与当前版本一致。
- 状态转换单元测试、iPhoneOS 构建通过，并完成 iPhone 真机验收。
