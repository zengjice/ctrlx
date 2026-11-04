# iOS Agent 后台监控 Stage 4 TODO

> Historical record: Background Agent Monitoring has been removed. iOS alerts
> now use APNs exclusively. See [current notification delivery](../../services-reference.md#push-notifications).


## Stage Status

- **Status**: ✅ Completed
- **Progress**: 35/35 tasks
- **Dependencies**: Stage 3 ✅

## Tasks

- [x] 明确有限后台任务边界、状态模型及降级策略
- [x] 增加持久化设置和 iOS 26 可用性提示
- [x] 封装 continued-processing 系统 API
- [x] 接入 Agent prompt 提交与状态生命周期
- [x] 完成状态转换测试和 iPhoneOS 构建
- [x] 完成 code review 并清零 P1/P2/P3
- [x] 统一后台活动卡片和普通 Agent 通知的信息层级
- [x] 区分 Viewer 传输中断与 Host 离线，避免断链提前取消监控
- [x] 将 Relay 探活、立即重连和节流快照绑定到 continued-processing 生命周期
- [x] 用 SessionState 补齐丢失终态并生成后台兜底通知
- [x] 增加延迟诊断、回归测试并通过 iPhoneOS 构建
- [x] 修复终态先结束后台活动导致完成通知丢失的竞态，并增加单 pane 去重
- [x] 修复连续 Agent 轮次因上一轮终态延迟而漏建后台活动
- [x] 区分 pending request 取消与 running task 完成，避免成功任务被系统显示为失败
- [x] 将本地监控租约结束与 Agent 失败解耦，并正确处理完成早于 launch callback 的竞态
- [x] 禁止 Agent turn 排队后跨轮显示，系统无法立即启动时降级为普通通知
- [x] 清理跨进程和完成早于 launch 的 pending request，避免第二条消息出队才显示首轮卡片
- [x] 修复 Host 尚未校准 Agent pane 时首条 prompt 被状态门禁丢弃
- [x] 用 Host 进程校准快照确认未分类 pane 的首次 prompt
- [x] 修复旧 UIKit 后台租约过期未结束导致系统终止 App
- [x] 在 launch handler 同步完成首个 activity unit，避免首轮卡片等待下一条消息才呈现
- [x] 修复终端历史提交依赖 SwiftUI 瞬时状态而漏建首轮监控
- [x] 用 UIKit 短租约桥接 continued-processing 调度窗口，保证后台短任务能及时通知
- [x] 完成 iPhone 真机验收
- [x] 修复快速完成与 launch callback 交界导致的偶发失败卡片
- [x] 将逐 turn request 收敛为单一两小时全局监控会话
- [x] Agent 终态只更新卡片并发通知，不结束全局任务
- [x] 用户操作幂等确保会话，并维护全部 Viewer Host 连接
- [x] 强制终止后通过显式启动或 Agent prompt 恢复系统监控卡片
- [x] 全局监控使用单一即时 request，并在 Settings 区分 Starting、Active 与提交失败
- [x] 显式声明 Live Activities 支持，避免后台任务 Active 但系统活动 UI 不呈现
- [x] 在首次系统 UI 更新前发布有效进度，避免首帧使用默认 0/0 状态
- [x] 将系统卡片改为全局监控状态和工作 Agent 数量，不再绑定具体 window
- [x] 将持久偏好和启动按钮收敛为一个真实反映任务生命周期的会话开关
- [x] 通过聚焦测试、iPhoneOS 构建并完成 iPhone 真机测试

## Blockers

- 当前无阻塞项。
