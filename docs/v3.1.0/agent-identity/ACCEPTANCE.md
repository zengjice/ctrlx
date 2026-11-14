# Agent 身份统一：实现与验收记录

日期：2026-11-14。基线 `c2546a10`，本轮修改尚未提交、安装或发布。

## 实现边界

产品关联统一使用 `AgentID(hostID, persistentPaneUUID)`，位置、运行者、原生对话和单次操作授权分别保留。当前规则见 [Agent identity](../../agent-identity.md)。

- Workflow 参与者和节点引用不随进程更换而重写；正在执行的 invocation 保留原证据，同一 AgentID 的投递继续互斥。
- 新运行者不能发送旧 turn 的 Stop。已经核验的原 Stop 可在同一原生对话恢复后核验原结果；不会生成新投递或自动 Continue。
- 事件保留 socket 内核来源，复用原有串行 ingress。退出事件使用原进程证据；普通状态不能借退出信封改写后继状态。
- native 缓存的保存和失效按 pane 排队；恢复快照的失效也进入同一队列，防止迟到写回。
- 通知导航使用稳定目标；答复额外验证原运行者、原生对话和 request。旧消息或旧客户端不退回裸编号精确定位。
- 资源的持久来源与对话所有者独立于运行 token；窗口快捷配置仍属于窗口，Provider 默认仍属于 Provider。

## 已执行的自动化验证

下列计数为各次测试执行数，彼此有重叠，不相加作为独立测试数。

| 验证 | 结果 | 原始记录 |
| --- | --- | --- |
| 共享模型、服务、工作流、Orbie/Orbiter、通知、资源、模型、恢复和编辑器 UI 定向测试 | 782 项通过 | `.build-local/agent-identity-implementation/integration-tests-3.log` |
| 运行者证据、延迟保存失效、退出/Resume、Codex/Claude 翻译及 tmux 3.6a 兼容补充测试 | 175 项通过 | `.build-local/agent-identity-implementation/supplement-tests-2.log` |
| Simulator 路由/所有权、Browser 关联、通知内容及重复身份缓存请求 | 119 项通过 | `.build-local/agent-identity-implementation/resources-tests.log` |
| 同一进程切换原生对话后，资源请求刷新缓存并能切回原对话 | 31 项通过 | 同目录 `resource-refresh-tests.log` |
| 事件来源、当前 writer 冲突拒绝、输入响应及 Workflow 原生回执最终回归 | 97 项通过 | 同目录 `event-final-tests.log` |
| tmux 3.7b 原生输入、模型及 hook 操作兼容测试 | 11 项通过 | `.build-local/agent-identity-implementation/tmux-3.7b-tests.log` |
| pi / omp / OpenCode sidecar 测试 | 32 / 49 / 57 项通过 | 同目录 `*-sidecar.log` |
| 品牌和技术边界 | 通过 | 同目录 `brand-final.log`、`technical-final.log` |

失败的前置测试日志保留用于追溯。最后通过的记录取代表中对应测试的早期结果，不把早期失败计作通过。

## 本机平台与原生验证

- [x] Mac Debug workspace 最终编译（`mac-build-final.log`）；原生资源验收副本的构建与签名记录为 `mac-build-2.log`、`prepare-acceptance-2.log`。
- [x] iOS device SDK 编译，包含通知扩展（`ios-build-final.log`）；不构建 iOS Simulator App。此为编译检查，未签名安装，也未执行 UIKit 真机 UI。
- [x] 隔离原生 Browser / Simulator 资源接续与隔离套件（`native-resources-4.log`、`native-resources-summary.json`）。11 条检查记录，包含套件完成记录；不是 11 项独立场景。
- [x] 106 个变更 Swift 文件的格式、品牌／技术边界、差异检查；新增验收脚本 Python 语法和方案文档链接检查。

资源套件复现并修复了同一进程切换对话后缓存仍指向旧对话的问题。它使用私有 tmux、状态根、签名 App 和原生进程夹具，顺序执行 Browser 两种引擎与 Simulator。页面 DOM、设备 ID 在同对话重启后保留；旧凭据、另一 pane 和新对话不能继承授权，结束时隔离 Host 已退出。

最后的事件补丁将原生 writer 的冲突证据与“暂时未知”区分，并拒绝前者；97 项最终回归覆盖该改动。它和 iOS 通知消费补丁不在上述无 hooks 的资源夹具执行路径中，按源码影响检查保留该套件证据，不将其冒充真实 Codex/Claude 验收。

## 性能与未实测范围

身份解析从现有快照查找，不另建轮询服务。普通匹配事件只验证当前运行者；更换对话才读取原生证据，读取限定在当前进程打开的文件，不扫描全部历史。已保存的同一 native 身份复用缓存；模型显示缓存替换旧运行代次。相关缓存和无重复写回由定向测试覆盖。`writeRetry` 在首次保存失败后执行 1,000 次重复请求，共两次进程扫描和两次保存尝试；重试成功后不再扫描。

尚无同一夹具、同一源码条件下改造前后的完整进程扫描/历史读取计数、主线程占用及跨端键盘时延对照，因此不能宣称性能验收全部完成。

本轮不安装或替换用户 App，不操作真实 Agent 账号。物理 iPhone、另一台 Mac、真实 Codex/Claude 登录切换和完整原生 Resume/Fork/提问链路仍需实际设备验收。私有 tmux、模拟 provider、原生 codex 命名测试进程的通过不等同于这些真实场景通过。

## 工作流交接

### Review 1 修复

三项 P1 均已按最小范围修复：

- OpenCode 用现有 run→conversation 记录将 pane 占位绑定到真实 root。子会话生命周期不参与绑定，迟到完成不重选 root；退出继续使用该 run 的真实原生会话。
- pi／omp／OpenCode bridge 在现有发送链路上携带进程内递增序号，并串行发送；扩展重载不重置序号。Host 仅在内核来源相同且原生 start 更新时允许恢复 retired 对话；普通事件、重放、丢失序号和冲突的 native writer 仍被拒绝。没有新增产品身份或 Host 事件队列。
- Viewer／Relay 临时断线不清除已认证通知能力；换钥、解除配对和下一次已认证 Hello 会更新或清除能力。未知及旧客户端仍无精确导航和旧答复入口。

本轮证据位于 `.build-local/agent-identity-repair/`：

| 检查 | 结果 | 记录 |
| --- | --- | --- |
| 事件身份、运行态、Workflow、通知、连接生命周期和加密传输 | 104 项 Swift 测试通过 | `focused-tests-3.log` |
| pi／omp／OpenCode 真 sidecar 与 bridge | 34／51／58 项通过 | `*-sidecar-final.log` |
| 实际 bridge→sidecar 输出接入当前生产 Host 门控 | OpenCode 真实会话；pi／omp A→B→A 后工作、完成、退出全部接受，重放拒绝 | `event-probe.log`、`bridge-probe.py`、`probe.swift` |
| Mac workspace／iOS device SDK 编译 | 均通过；未安装、未执行真机 UI | `mac-build.log`、`ios-build-2.log` |
| 格式、品牌／技术边界、差异 | 通过 | `format-final.log`、`brand.log`、`technical.log`、`diff-check.log` |

首轮编译发现测试宏不能直接调用 mutating 方法；改为先保存返回值。随后加密传输测试发现测试日志依赖未注入，补齐空实现。两次失败记录保留，最终以 `focused-tests-3.log` 为准。

插件源码／版本为 pi 0.1.1、omp 0.1.2、OpenCode 0.2.3。尚未发布或安装插件；已运行的旧扩展需在更新 bridge 后重启／重载，不能仅靠升级 Host 自动补上序号。未连接生产 APNs、操作真实账号或进行物理设备 UI 验收。

### Review 2 修复

- P2：Agent 步骤选择器复用 `definition.instance(for:in:)` 解析参与者的当前实例；列表过滤、参与者编辑及添加去重不再混用参与者 ID 与运行实例 ID。新增步骤和给未绑定步骤选择 Agent 时，均写回已有参与者 ID。没有新增身份存储或迁移。
- P3：pi／omp 夹具统一设置 `CTRLX_PLUGIN_ID`，未指定合法插件时直接失败；真实 bridge 夹具输出实际调用的原生事件名，测试明确断言 omp 的 `session_switch`、pi 的 `session_start`，同时检查帧中的插件 ID。生产 bridge 和 sidecar 本轮未修改。

本轮证据位于 `.build-local/agent-identity-repair-2/`：

| 检查 | 结果 | 记录 |
| --- | --- | --- |
| Workflow 目标／请求及真实 SwiftUI 编辑器操作 | 31 项 Swift 测试通过；包含重启、移动、刷新后新增／绑定步骤并保存原参与者 ID，及目标缺失／无关实例过滤 | `focused-tests-2.log` |
| pi／omp sidecar 和真实 bridge | 34／51 项通过；包含原生切换分支断言 | `pi-tests.log`、`omp-tests.log` |
| Mac workspace／iOS device SDK 编译 | 均通过；未安装、未执行 iOS 真机 UI | `mac-build.log`、`ios-build.log` |
| 格式、品牌／技术边界、差异 | 通过 | `format-final.log`、`brand.log`、`technical.log`、`diff-check.log` |

初次测试编译发现未绑定 Agent 节点夹具错误地向非可选构造参数传入 nil，已按现有复制后解绑语义构造夹具；失败日志保留。未安装、提交或发布，未执行物理设备 UI 验收。

### Review 3 修复

- P2：新增参与者不再复用运行实例 ID；新增与去重逻辑移入已有 `AgentWorkflowEditing`，所有编辑器入口共用。改绑后重新添加原 Agent 会保存不同的参与者引用和各自 target。刷新／保存保留尚未绑定步骤的参与者 target，移除参与者后清理失去引用的 target；运行占用检查只使用步骤引用的目标。
- P3：参与者总览的不可用提示统一调用 `instance(for:in:)`；目标暂时缺失时提示，重启后的实例恢复到目录后提示消失。

本轮证据位于 `.build-local/agent-identity-repair-3/`：

| 检查 | 结果 | 记录 |
| --- | --- | --- |
| Workflow 编辑、目标／存储／请求、wire 和真实 SwiftUI 编辑器操作 | 73 项 Swift 测试通过；覆盖旧／新参与者引用、改绑后重新添加、无步骤时刷新／持久化、移除后的 target 清理、未使用目标不占用，以及重启后提示变化 | `focused-tests-2.log` |
| Mac workspace／iOS device SDK 编译 | 均通过；未安装、未执行 iOS 真机 UI | `mac-build.log`、`ios-build.log` |
| 格式、品牌／技术边界、差异 | 通过 | `format-final.log`、`brand.log`、`technical.log`、`diff-check.log` |

首次测试的两项 UI 断言按独立元素查找提示文字，但 SwiftUI 将其合并到折叠按钮的辅助功能标签中；改为检查实际按钮标签后通过，失败日志保留为 `focused-tests.log`。生产修复不增加辅助功能标记或额外 UI 状态。sidecar 与事件桥本轮未修改、未重跑；未安装、提交或发布，未执行 iOS 真机 UI 验收。

### Review 4 修复

- P2：启动冲突查询改用 `definition.instance(for:in:)` 解析未结束运行中的参与者，保留原冲突展示顺序。有 target 时只匹配稳定身份，不再把参与者引用同时当成运行实例 ID；无 target 的旧记录沿用已有解析器的实例 ID 回退。未新增状态、迁移或匹配规则。

本轮证据位于 `.build-local/agent-identity-repair-4/`：

| 检查 | 结果 | 记录 |
| --- | --- | --- |
| 修复前回归 | 旧参与者改绑到 B 后仍被 A 占用误拦截，B 占用时冲突列表也错误包含 A；缺少 target 的旧记录保护通过 | `before-tests.log` |
| Workflow 请求、存储和稳定目标 | 40 项 Swift 测试通过；新增回归覆盖 B 空闲／被占用与 B 原进程／重启的四种组合，以及从旧存储加载无 target 记录后的占用保护 | `after-tests.log` |
| 格式、品牌／技术边界、差异 | 通过 | `format-final.log`、`brand.log`、`technical.log`、`diff-check.log` |

本轮仅改 Host 工作流的纯 Swift 查询；定向测试已编译生产模块，未重跑整包 App 构建、sidecar 或真机 UI。未安装、提交或发布；上一轮构建记录不作为本轮新构建结果。

### 首轮实现交接

实现和本机验证完成后，首次调用 `ctrlx workflow complete-step --invocation 785735C6-50C2-48A9-9025-B3ACEE4FBC78` 被 Host 以缺少当前已接受 turn 拒绝。用户继续本步骤后重试成功，退出码 0，Host 返回 `Step completion saved.`。完成请求已保存；下游交接仍由 Host 核验本轮最终结果及工作流暂停状态。未修改运行中的任务记录或绕过当前 turn 校验。
