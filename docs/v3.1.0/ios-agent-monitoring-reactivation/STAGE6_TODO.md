# iOS Agent 监控自恢复 Stage 6 TODO

> Historical record: Background Agent Monitoring has been removed. iOS alerts
> now use APNs exclusively. See [current notification delivery](../../services-reference.md#push-notifications).


## Stage Status

- **Status**: ✅ Completed
- **Progress**: 6/6 tasks
- **Dependencies**: Stage 4 ✅

## Tasks

- [x] 完成租约与用户意图状态审计
- [x] 持久化 Agent 后台监控偏好
- [x] 移除租约失效后的开关回写
- [x] 清理跨租约的过期 pane 和连接状态
- [x] 更新 Settings 状态和说明
- [x] 完成测试、iPhoneOS 构建和真机验收

## Blockers

- 当前无阻塞项。

## Verification

- Agent 后台监控定向测试：11 项通过。
- `CtrlxPackage` 完整测试：1756 项通过。
- iPhoneOS Debug 构建、签名、深度校验通过。
- 已覆盖安装并启动到 `ZengJice iPhone`，build `20260818-003000`。
- 真机验收通过：旧租约到期后开关保持开启，下一次 Agent 输入
  成功创建新系统卡片。
- 已失败的旧卡片由 iOS 系统管理，`BGContinuedProcessingTask` 没有
  dismiss API；不为此增加无效清理逻辑。
