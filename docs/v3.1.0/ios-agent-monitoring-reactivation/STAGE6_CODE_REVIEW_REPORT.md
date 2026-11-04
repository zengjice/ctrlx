# CtrlX 3.1.0 Stage 6 Code Review Report

> Historical record: Background Agent Monitoring has been removed. iOS alerts
> now use APNs exclusively. See [current notification delivery](../../services-reference.md#push-notifications).


## Review Scope

- Agent 后台监控用户意图与运行租约的状态所有权
- 租约到期、系统取消、用户关闭和下一次 Agent 输入的转换
- Settings 持久化、状态文案及 Apple continued-processing 系统边界

## Findings

- P1：无
- P2：无
- P3：无

## Resolved During Review

- 移除 `MonitoringStatus.inactive` 向用户开关的反向回写，避免系统租约失效
  永久关闭功能。
- 开关改为持久化用户意图；当前租约状态继续由
  `AgentBackgroundMonitoringService` 单独拥有。
- 租约到期和两小时预算用尽后清理 pane phase、输入累计和连接
  节流状态，新租约不会继承过期 `working` 数据。
- 关闭开关时无条件执行完整清理，不依赖租约是否尚存在。
- 自恢复仅由开启开关或提交 Agent 输入等前台用户操作触发；没有
  在 App 启动、回到前台或后台计时器中违反 Apple 约束地提交新 request。
- 已归档失败卡片没有可用的 dismiss API；保留系统原生行为，不引入
  无效的 request 取消或第二套 ActivityKit 状态机。

## Verification

- Agent 后台监控定向测试：11 项通过
- `CtrlxPackage` 完整测试：1756 项通过
- iPhoneOS Debug 构建、签名和深度校验：通过
- iPhone 真机 build `20260818-003000`：安装、启动和租约自恢复通过
- `git diff --check`：通过

## Decision

Approved. Stage 6 没有剩余 P1、P2 或 P3 问题，可合入 `develop/v3.1.0`。
