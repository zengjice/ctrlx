# 单 pane 终端标签收敛方案（暂缓实施）

记录日期：2026-10-28。源码核对基线：`fb4f57ef`。

**状态：设计备忘，尚未实施。** 用户考虑到改动范围较大，决定先独立记录；本文不代表当前产品行为，也不构成实施、迁移现有会话或发布的授权。后续重新启动该需求时，应先核对源码变化和文末待定事项。

建议方向：让每个 Agent／Terminal 标签对应一个 tmux window，且该 window 只有一个 pane；保留 Mac 的标签左右分栏和独立窗口。收益主要是减少标签内部的布局、焦点与操作目标选择，不是删除底层 pane 身份或 Agent 授权机制。

## 1. 目标与体验取舍

当前有两层分屏：

| 分屏层级 | 当前含义 | 候选方案 |
| --- | --- | --- |
| 标签内分屏 | 一个 tmux window 包含多个 pane，CtrlX 按布局树绘制多个终端 | 逐步淘汰，收敛为唯一 pane |
| 工作区分栏 | 左右分别显示完整标签，包括终端和资源标签 | 保留；继续支持把标签移到右侧、返回左侧和拖出独立窗口 |

收敛规则仅适用于 Agent／Terminal 标签。人工创建的 Files、Browser、Simulator 继续是独立资源，不为满足这个规则创建虚拟 pane，也不重新绑定到终端。Agent 创建资源的来源关联和人工授权行为沿用各自身份规则。

以 dev、review、deploy 等独立标签组织任务，以及“左侧 Agent、右侧 Browser”的主要工作流可以保留。下列体验会受影响，不能承诺完全无损：

- 一个标签内同时查看多个终端，尤其是上下分屏、三格或四格布局。
- iOS 查看已有多 pane window 的完整分屏画面。
- 依赖 `ctrlx split-pane`、原生 tmux 分屏或多 pane 布局模板的脚本。
- 接入其他终端创建的多 pane 工作区。

当前 [README](../README.md) 明确支持复用已有 tmux sessions、windows 和 panes。正式落地前，需要确认接受这项产品支持范围的收缩。

## 2. 能简化什么，哪些身份仍要保留

| 范围 | 可减少的复杂度 | 仍需保留 |
| --- | --- | --- |
| 输入与焦点 | 标签内部二次选择 pane、选择遮罩、活动 pane 与客户端焦点协调 | 左右分栏、不同原生窗口的输入焦点 |
| 状态栏与快捷操作 | 首个 pane、活动 pane、Agent pane 等不同目标选择规则 | 当前 Agent 能力、模型与状态探测 |
| 资源来源与返回 | 一个来源 pane 唯一对应一个终端标签 | 独立资源、运行实例所有权、授权与撤销 |
| 终端绘制与 Fit | 标签内布局树、分隔边框、比例分配、最小尺寸和取整 | 终端渲染、滚动、Host／Viewer 共享尺寸协调 |
| 重启恢复 | 每个 window 内多 pane 的创建、排序与布局树还原 | 持久身份、原生对话恢复、草稿、失败重试 |

例如，当前 Files 来源解析依次选择焦点 pane、tmux 活动 pane、首个 pane；单 pane 后可以直接校验并取得唯一目标。多个入口应复用这一明确规则，不能只把各处逻辑改成无条件 `panes.first`，也不能写死 pane 索引为 0。

单 pane 不保证只有一个 Agent 进程，也不保证这个 pane 永远运行同一个 Agent。用户可以退出 Codex 后启动 Claude Code，或在同一个 shell 中运行后台、嵌套进程。仍须区分：

- **标签／window 身份**：展示、排序和窗口归属。
- **pane 身份**：终端输入输出目标，包含 Host 与 tmux 运行实例范围。
- **Agent 进程实例**：PID、启动身份和经验证的调用来源。
- **原生 conversation ID**：Fork、resume 和工作流绑定的对话。

Agent A 退出后，同一个 pane 中的 Agent B 不能继承 A 的 Browser／Simulator 授权。跨 Host 的同名 pane、tmux 重启后的编号复用、请求迟到等校验仍然必要。保留现有持久身份和进程校验，不用标签名、window 索引或 pane 编号替代授权身份。

主要收益是业务路由和展示模型简化。终端和 Agent 数量不变时，不能据此承诺明显降低内存或进程数量。

## 3. 候选落地顺序

以下是后续实施建议，所有步骤当前均未实施。

1. **统一新建规则。** 新建 Agent、Terminal、Fork、工作流创建都只生成单 pane window。保留新建标签、移到右侧和独立窗口入口，收起标签内部的 pane 分屏入口。现有内置工作流创建已使用新 window，可继续复用。
2. **覆盖全部创建入口。** 同时检查本地 UI、Mac／iOS Viewer 请求、CLI、布局模板与恢复逻辑。旧 `split-pane` 请求应给出明确说明及新建标签的替代入口，不悄悄改成另一种命令语义。多 pane 模板应在实际修改工作区之前完成校验。
3. **提供已有布局的显式拆分。** 建议保留当前活动 pane 所在的原 window，其余 pane 拆到同一 session 的相邻新 window。迁移应保留运行任务，并更新标签顺序、选择、资源来源、独立窗口归属、草稿及恢复记录。
4. **处理外部变化。** 其他终端或原生 tmux 命令仍可能产生多 pane。CtrlX 检测后应提供明确提示及迁移入口，不自动终止额外 pane，也不只显示第一个 pane 而隐藏其他任务。最终展示方式和兼容期限待定。
5. **完成迁移后删除旧路径。** 再移除标签内多 pane 的渲染、焦点选择、Fit 分配与恢复分支。初期保留识别旧数据和旧消息所需的字段，避免把本次改造扩大成协议重写。

只隐藏分屏按钮、同时长期保留完整多 pane 能力，主要减少 UI 入口，无法获得预期的底层维护收益。是否允许过渡兼容、何时删除兼容路径，应在实施前确定，不默认永久维持两套完整模式。

## 4. 迁移和兼容边界

迁移需要覆盖两类来源：当前仍在运行的多 pane window，以及尚未恢复的历史快照。只转换当前现场，会导致下次恢复再次创建多 pane。

建议以现有 pane 持久身份关联移动前后的任务；移动后重新取得 window 身份和所属关系，再更新客户端展示与保存状态。迁移期间的中间状态不能覆盖完整恢复源；部分完成后再次执行应先核对现状，避免重复创建标签。具体事务边界和失败恢复机制尚未设计或验证。

Host 是终端结构的权威方。新旧 Host／Viewer 混用时，旧客户端的分屏请求、新客户端遇到旧 Host 的多 pane 数据，都需要明确兼容行为。新增远程迁移能力应按 Host 广告能力调用，不能由 Viewer 单方面假设生效。

关闭终端标签、关闭原生展示窗口、结束会话继续区分。资源标签可以独立存在，不因最后一个终端 pane 消失而被错误删除。

## 5. 主要代码入口

以下入口在记录基线中已核对，用于后续重新评估范围；不是已修改文件列表。

| 领域 | 入口 |
| --- | --- |
| Mac 标签内多 pane 渲染和分屏按钮 | [WindowPaneLayoutView](../CtrlxPackage/Sources/CtrlxServerFeature/Views/WindowPaneLayoutView.swift)、[RemoteWindowPaneLayoutView](../CtrlxPackage/Sources/CtrlxServerFeature/Views/RemoteWindowPaneLayoutView.swift) |
| iOS 布局、活动 pane 和输入路由 | [WindowLayoutView](../CtrlxPackage/Sources/CtrlxFeature/Views/WindowLayoutView.swift) |
| Mac 标签左右分栏 | [FileBrowserView](../CtrlxPackage/Sources/CtrlxServerFeature/Views/FileBrowserView.swift) 中的 `SessionFileTabsState` |
| tmux 操作、Viewer 与 CLI 入口 | [TmuxService](../CtrlxPackage/Sources/CtrlxServerFeature/Services/TmuxService.swift)、[TmuxCommandExecutor](../CtrlxPackage/Sources/CtrlxServerFeature/Services/TmuxCommandExecutor.swift)、[PaneCommands](../CtrlxPackage/Sources/CtrlxCLI/Commands/PaneCommands.swift) |
| 模板和恢复 | [LayoutDriver](../CtrlxPackage/Sources/CtrlxServerFeature/Services/Layout/LayoutDriver.swift)、[WorkspaceTmuxClient](../CtrlxPackage/Sources/CtrlxServerFeature/Services/WorkspaceRecovery/WorkspaceTmuxClient.swift) |
| 资源分组与身份边界 | [PaneLinkedTabs](../CtrlxPackage/Sources/CtrlxCommon/Models/PaneLinkedTabs.swift)、[AgentSessionIdentityClient](../CtrlxPackage/Sources/CtrlxServerFeature/Services/AgentSessionIdentityClient.swift)、[Browser Ownership](../CtrlxPackage/AgentBrowser/Ownership.h) |

后续同时核对 [CLI 文档](ctrlx-cli-api.md)、Agent 侧 `ctrlx-cli` 技能、[布局持久化](folder-layout-persistence-plan.md)和[恢复设计](workspace-recovery-design.md)，避免入口说明或旧快照行为遗漏。

## 6. 已有验证及其限制

2026-10-28 在本机 **tmux 3.7b** 上完成一次隔离验证。测试通过临时目录中的私有 socket 启动 tmux，以 `sleep` 进程作为夹具，没有操作用户已有会话。

测试顺序：`new-session` 创建 window → `split-window` 创建第二个 pane → 给第二个 pane 设置 `@ctrlx-recovery-pane` UUID → 用 `break-pane -d` 拆到新 window → 比较前后身份 → 停止私有 tmux 并清理临时目录。

| 检查 | 结果 |
| --- | --- |
| 被移动 pane 的运行 ID | 保持不变 |
| 被移动 pane 的进程 PID | 保持不变 |
| `@ctrlx-recovery-pane` UUID | 保持不变 |
| 所属 window ID | 变化 |
| 拆分后的结构 | 两个 window，各有一个 pane |

这只证明 tmux 提供保留进程与 pane 身份的迁移基础。尚未验证真实 Agent 的尺寸变化反应、CtrlX 标签和资源迁移、跨端同步、历史快照转换、中途失败或重启恢复。不能把这次底层检查当作产品级无损迁移验收。

后续至少需要覆盖：

- Mac Host、Mac Viewer、iOS 的创建、切换、输入、Fit 和关闭。
- 左右分栏、独立窗口、资源来源返回及独立资源生命周期。
- 迁移前后进程与原生对话连续性，资源权限不串用、不错误继承。
- 活动任务迁移、用户同时切换标签、迟到请求及断线重连。
- 历史多 pane 快照、迁移中断后重试，以及新旧 Host／Viewer 组合。
- CLI、模板、插件技能和测试夹具同步调整。

## 7. 重新启动需求前需要确认

1. 是否正式淘汰标签内多 pane，而不只是默认新建单 pane。
2. 外部及历史多 pane 的展示方式、迁移交互与兼容期限。
3. 新旧版本混用的支持边界，以及实施和发布安排。

当前决定仅为保留本文，暂不改动产品代码或迁移任何用户工作区。
