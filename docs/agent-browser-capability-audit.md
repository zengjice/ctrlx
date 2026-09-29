# Vercel 引擎能力审计（更新至 2026-09-29）

## 本机覆盖与真实 Codex 复验（2026-09-29）：约定场景通过

最终覆盖版通过严格深度签名验证，进程 **43596** 的 `lsof` 确认主程序与原生
运行库都加载自 `/Applications/CtrlX.app`，不仅检查磁盘文件。主程序 SHA-256：
`e4699ae8a9f03c538be382b57de37fd671e55fc36b466a0c0b2b230614bf65f3`；运行库：
`574afbb1edf378d4dd9ecfb65a75454efe976a864d0a5f9505fb34933894d189`。
回退副本：`.build-local/pre-workspace-install.qnl8Ex/CtrlX.app`。版本号未变，未发布。

真实 Codex 在临时 session 中读取已安装 Skill、运行公共 CLI 验收脚本；不是
原生身份夹具。主操作端通过 computer-use 点击实际按钮/窗口，检查截图：

- A/B 两个源 session 内嵌页；Vercel 与原 CtrlX 引擎输入产生 `trusted=true`。
- 实际 Elements 显示原 DOM；Console 返回 A 的原文档 ID 和 `A-original-tools`；
  Network 记录本地测试请求 HTTP 200；再次点击按钮聚焦已有工具并保留 Console 历史。
- B 首次读回前在后台约 **234 秒**，且尚未启动 B 的 Vercel 引擎。关闭 A 的工具后，
  A/B 顺序与并发读取均成功，原文档 ID、中文临时内容和计数未变化。
- 实际窗口共 **3 次打开/关闭**后，Vercel 与原引擎继续操作 B，最终
  `B-final-original; trusted=true`、`Clicks: 3`。HTTP 日志中 A/B 各只有首次文档请求，
  没有用重新加载恢复内容，也未重放超时写操作。
- 公共 CLI `inspect`、`stream enable`、`dashboard start` 均按预期拒绝。
- 脚本退出 0、`result.json` 为 true；真实 Codex 另行调用 `action tabs` 确认为空。
  没有新增 CtrlX/浏览器崩溃报告。

证据：`/tmp/ctrlx-installed-p7-verified.jVTP93/`，含每条命令完整 stdout/stderr/退出码、
阶段断言、HTTP 日志、Elements/Console/Network 及三轮开关截图。此范围不代表
所有能力再次经真实 Codex 验收，更不等于无限期后台驻留/锁屏休眠保证。

另修复一处工作区注销清理缺陷：原代码先移除 workspace，再异步关闭原生页，
迟到回调找不到接收方，SwiftUI 可能保留已关闭的空白标签。现在同步退役标签状态并
通知 UI，再关闭原生页；迟到回调不重复清理，不影响其他 workspace。新增单测在
旧实现上失败，修复后通过；相关测试合计 **49 项**、Release 构建、签名验证通过。
日志：`/tmp/ctrlx-workspace-close-red.log`、`/tmp/ctrlx-workspace-close-green.log`、
`/tmp/ctrlx-workspace-close-mac-build.log`。按状态生命周期整理清理顺序，未新增 ViewModel。

中途失败/未完成尝试保留，不计入通过：

- `/tmp/ctrlx-installed-p7.8oE4x5/` 关闭工具后读取失败；查明进程 **19316** 实际加载
  备份中的旧运行库（inode 195668985），不是已替换的新库。此后安装验收增加进程
  加载路径/inode 核对，不能仅凭 App 目录 hash 宣称新版本已运行。
- `/tmp/ctrlx-installed-p7-retest.ONxVxM/` 工具打开阶段通过，但 GUI 协作标记超时，
  后续未执行；测试自行清理退出，不能算浏览器动作失败或整轮通过。
- `/tmp/ctrlx-installed-p7-final.bch8mD/` 初始读写通过，等待中看到两页空白、工具按钮
  disabled，后因协作超时退出。由此发现上面的注销清理缺陷；**现场为何触发原生关闭
  尚未确定**，不能断言由锁屏/休眠造成，也不能声称清理修复阻止了所有意外关闭。
  此触发条件保留在 TODO 的 P8，2026-09-29 按用户要求暂缓排查。

临时测试 session 和所属页面已清理，回到原 `ctrlx` session / `%0`，原 Codex 进程仍在；
本地 fixture HTTP 服务已停止，测试证据与可回退 App 保留。只按用户批准删除了
macOS/iOS 的两个 `CompilationCache.noindex` 缓存；构建后磁盘仍有约 11 GiB 可用。
本轮已覆盖本机；本次提交不包含推送或远端发布。此前原生循环和能力隔离回归详见下面历史记录。

## P7 根因与修复：隔离回归记录（安装复验见上节）

隔离夹具稳定复现了安装版的问题：同一 workspace 内 A/B 两页，向 B 输入独有的
临时文本，再切到 A；打开、关闭 A 的 DevTools 后，B 的 `Page.getFrameTree` /
`Runtime.evaluate` 超时。**顺序读取也失败，后台等待 0 秒也失败**，与 Vercel
daemon 无关。失败后打开 B 的工具会重新请求 `/beta`，原临时文本丢失，因此
“打开工具后又能看到默认页面”不能作为未丢失状态的证据。

根因是 CEF 152 的应用生命周期衔接：旧 external timer pump 没有进入
[`CefMainRunner::RunMessageLoop`](https://github.com/chromiumembedded/cef/blob/1ce985c/libcef/browser/main_runner.cc#L132)
所持有的 `APP_CONTROLLER` keep-alive。最后一个 Chrome-style DevTools 窗口关闭时，
[`Browser::OnWindowCloseComplete`](https://github.com/chromium/chromium/blob/152.0.7977.134/chrome/browser/ui/browser.cc#L895)
认为应结束浏览器，触发全局 renderer fast shutdown；Alloy 内嵌页不算 Chrome 窗口。
失败夹具的 FastShutdown 总计数从 2 增到 6，B 原生页面命令失去响应；切换原生循环
后只从 2 增到 3（工具自身关闭），B 的文档和临时文本均保留。对照证据：
`cx-upstream-39xbq0gv`（失败）及 `cx-upstream-c5zcsdyv`（通过），均在系统临时目录。

修复：从 AppKit 的延后回调进入 `CefRunMessageLoop`，由其原生 macOS pump 继续
处理 AppKit 事件和 RunLoop sources；不占住 Swift main-actor job。退出先等待
页面/工具、传输和 Cookie flush，调用 `CefQuitMessageLoop`，循环返回后再
`CefShutdown`。删除外部定时器及临时排查代码；没有刷新页面、重放写操作、禁用沙箱、
保留隐藏工具窗口或扩大 CDP 权限。测试新增 `tests/background_tabs.py`。

已完成的验证（检查点数不代表上游能力数）：

- 同 workspace 后台回归 **28 个检查点**通过，含 120 秒后台停留、首次关闭及
  8 次重复开关、文档 ID/临时 DOM 保留、原生顺序/并发读取、公共 CLI 双引擎操作、
  其他 workspace、关闭源页、新建页面、工具开着时正常退出。日志
  `/tmp/ctrlx-background-tabs-fixed.log`；摘要 `cx-upstream-i2tyrsut/summary.json`，
  `hostExitCode=0`、`idleSeconds=120`。不是无界长期稳定性或真实 Codex 验收。
- 原 `devtools.py` 生命周期回归通过（另含 8 次开关、重复打开、源页关闭竞态、
  inspect/stream/dashboard 仍拒绝）；正常退出，无新增浏览器崩溃报告。日志
  `/tmp/ctrlx-background-devtools-regression.log`；摘要 `cx-upstream-7px5q_gj/summary.json`。
- 48 项相关 Swift 测试通过：`/tmp/ctrlx-background-unit.log`。
- 使用不带测试探针的运行库及当前 Release 主程序，完整运行
  `expanded_capabilities.py`，**36 个页面/工作流检查点**通过，包含输入、iframe/OOPIF、
  截图/下载、网络、批量操作、录像、React/init 和 WebMCP；未扩大原有能力边界。
  日志 `/tmp/ctrlx-background-capabilities.log`；摘要
  `cx-upstream-029u0kaz/summary.json`，`hostStopped=true`。
- 公共 CLI 参数/身份拒绝回归通过：`/tmp/ctrlx-background-cli.log`。
- 双引擎/归属/录制到期回归 **18 个检查点**通过，含共享登录态、关闭单页、
  切换引擎和 owner 退出不影响另一实例；日志 `/tmp/ctrlx-background-dual-engine.log`，
  摘要 `cx-upstream-2lrlfnlk/summary.json`，`hostStopped=true`。
- 原生运行库与 macOS Release workspace 构建、App 深度严格签名验证通过：
  `/tmp/ctrlx-background-native-build-final.log`、`/tmp/ctrlx-background-mac-build-final.log`。

上述 `cx-upstream-*` 目录均位于本机 `$TMPDIR`，保留失败与通过证据；夹具均使用
原生 Codex 命名身份测试进程，不是真实 Codex。验证结束后测试宿主正常退出。

本节记录的隔离验证当时未覆盖安装；后续安装复验见上节。以下旧版失败记录保留，
不将它们改写为通过。

## 修复前本机覆盖后的真实界面验收：部分通过，仍有失败项

已将当前工作区的 Release App 覆盖到 `/Applications/CtrlX.app`，签名深度严格校验通过。
主程序 SHA-256 为 `321ce0165a5767293313adb9bf4e5eb2a3ef19da29b65ffbb90095890a4330bc`，
原生运行库为 `d3c6e305c82946d7c19f4b951a0b9e5e9ebfaa8771d3c65ad0e1f61eeac78f75`，
均与构建产物一致；这不是发布或新版本号。旧 App 可从
`.build-local/installed-app-backup.RYvQHH/CtrlX.app` 恢复。

经用户授权，新建临时 tmux session 并启动真实 Codex 实例；浏览器操作全部通过
安装版公共 CLI。主操作端使用 computer-use 实际点击地址栏按钮、原生窗口关闭按钮，
查看 DOM、输入 Console 表达式、检查 Network 请求，而不是调用测试探针。

已通过：

- 两个新测试标签正确嵌入源 session；在 A 输入/点击后 B 初始内容未改变。
- Developer Tools 按钮打开对应 A 的前端；Elements 显示正确 DOM，Console 返回
  `?tab=A | Initial-Vercel-A; trusted=true`，Network 显示本机 fixture 请求的 200 响应。
- 重复点击聚焦已存在的工具，Console 历史仍保留。
- 工具打开期间，Vercel 与原 CtrlX 引擎的输入/点击/读取都通过，实际结果包含
  `trusted=true`；关闭工具后 A 的读取、Vercel snapshot 和再次输入/点击仍通过。

**未通过：**工具关闭后的 A/B 独立并发读取中，A 成功，后台 B 在约 9.93 秒后返回
`Operation timed out; outcome unknown, not retried.`。测试按约定停止，没有重放写操作。
主操作端随后选择 B 时先看到空白；打开 B 的 DevTools 后，Console 能读取
`?tab=B | No test input yet`，关闭工具后页面可见且 `Clicks: 0`。这只证明默认页面可见，
不能证明原文档仍在；后续独有临时文本夹具确认这里可能已经重新加载，详见上节。
后续 CLI inspect/stream/dashboard 拒绝检查没有在此轮执行，上一节隔离回归记录仍保留。
不能用先前的自动化通过覆盖这次安装版失败。

证据目录：`/tmp/ctrlx-installed-devtools.G1dUqe/`，含 `ready.json`、`engines-done.md`、
`failure.md`。测试 Codex 已退出；测试 session、两个页面及工具窗口已清理，本机 fixture
HTTP 服务已停止。原有三个本地 session 保留，Relay 已重连，没有新增 CtrlX 崩溃报告。

另确认现有边界：CtrlX 重启后旧 Codex 的浏览器授权不自动续期，当前父会话最初因此
无法连接已删除的旧 socket。未修改授权文件；上述测试使用用户批准的新 Codex 实例。
本轮只覆盖安装、验证和更新记录，没有修复代码、提交或发布。

## 本地人工开发者工具：当前增量

按 KISS 只增加 Agent Browser 地址栏的 Developer Tools 按钮：打开当前页面的
CEF 原生工具窗口，重复点击聚焦已有窗口。不是透传上游 `inspect`；没有新增
调试监听端口、系统浏览器启动或 agent 授权。WebKit New Browser 不变，
`stream` / 独立 dashboard 继续关闭并留 TODO。

新增 `AgentBrowserDevToolsTests` 覆盖精确标签、过期/伪造状态、另一宿主服务、
退出时拒绝打开。`tests/devtools.py` 在隔离签名 App 内调用与 SwiftUI 按钮相同的
原生方法，并检查真实 DevTools 前端加载/显示；不是实际工具栏点击或真实 Codex 推理验收。
DevTools 有独立生命周期，不注册到 agent 标签列表；关闭工具保留页面，关闭源页面
清理对应工具，导航不换 inspector，退出等待工具创建/关闭完成。

最终验证：

- 48 项相关 Swift 测试通过（35 CLI/身份/工作流＋13 路由/开发者工具）：
  `/tmp/ctrlx-devtools-final-unit.log`。
- 两轮独立测试均通过，**每轮含连续 8 次打开/关闭**，关闭后原引擎及 Vercel
  都可读取既有 DOM；同时覆盖跨页面隔离、重复打开、源页面创建/关闭竞态、
  工具打开时正常退出，以及 CLI inspect/stream/dashboard 仍拒绝、stream 仍关闭。
  最后一轮去除了临时诊断日志：`/tmp/ctrlx-devtools-final-native.log`；摘要
  `/var/folders/lj/k5dn64f52psc95qksnhl53cr0000gn/T/cx-upstream-4enyh8w2/summary.json`，
  `hostExitCode=0`，未出现新的浏览器崩溃报告。前一轮：`/tmp/ctrlx-devtools-stress2.log`。
- 最新原生运行库构建与 macOS Release 工作区构建通过：
  `/tmp/ctrlx-devtools-final-build-native.log`、`/tmp/ctrlx-devtools-final-build-mac.log`。

失败尝试保留：最初给 DevTools 强制 Alloy 样式，CEF 报不支持，已改用其默认样式；
早期测试在 CEF socket/pump 回调内同步 `performClose`，出现关闭后读取超时，压力测试
还在关闭后访问已销毁工具的 frame 导致夹具崩溃（`/tmp/ctrlx-devtools-stress.log`）。
探针已改成关闭前采集状态，并从 AppKit run loop 的原生事件边界关闭窗口；随后两轮
均通过。没有把测试探针修正称为生产 CDP 故障修复，也没有修改生产 CDP 消息编号逻辑。

未覆盖安装、提交或发布；此增量不代表所有 Vercel 调试/预览能力已接入。

## 第四轮内嵌工作流补齐：当前状态

用户明确保持现有“本机内嵌浏览器＋CLI”边界。外部／云浏览器、MCP server、
第三方插件及上游独立工具只留 TODO，本轮没有接入。以下在第三轮基础上补齐
P2、P4、P6 的约定工作流，不代表全局授权类能力、长录像或移动 OOPIF 已完成。

| 新增 | 效果证据及边界 |
|---|---|
| batch 对象步骤/产物/显式继续失败 | 真实 PNG/PDF 文件签名；逐步 success 与非零退出码；失败不重试；整批新路径验证阻止先前步骤执行。单测覆盖重复路径（包括卷上的大小写别名）、覆盖拒绝、跳过产物与默认失败即停。保留 32 步/48 KB，导出非原子 |
| `init add/list/remove` | 两个独立脚本导航后生效；删一个后另一个及 setup/React 保留；跨 owner 拒绝；setup 重启后旧 UUID 被拒绝。复用上游 typed action，不暴露任意 daemon/CDP；动态 ID 生命周期为当前 tab engine，持久配置仍用 setup |
| WebMCP 自动目录提示 | 普通 wait/get 后自动出现；重复查询不重复提示；页面 AbortController 撤销工具后目录更新；导航离开后清空旧工具。返回有界 untrusted 摘要，不自动调用；显式工具调用/取消/result 回归。仅 command（除 init/WebMCP）和 action snapshot 触发，非后台推送 |

WebMCP 方案保持 `--no-webmcp` 的固定上游启动参数，在页面操作完成后直接向
同一个私有 daemon 请求 typed `webmcp_list`，绕开 CLI 丢弃内部 launch 响应的问题。
目录查询使用 2 秒 socket 超时；失败只附 unavailable 元数据，不把已完成动作标成
失败，更不重放。目录摘要最多 16 项/4 KiB，完整 schema 仍须显式 list。

验证过程中两次夹具问题均留档：

- `/tmp/ctrlx-browser-workflows-focused.log`：新能力通过至 init；工具移除错误使用了
  此 CEF 没有的 `unregisterTool`。按上游 context fixture 改用注册时的 AbortSignal。
- `/tmp/ctrlx-browser-workflows-full.log`：原生按钮文字两次重绘有 1.65% 像素差，不能
  当作“页面无变化”的严格夹具。改用固定大小纯色色块，保持阈值 0 与精确相同断言；
  元素/JPEG 截图仍覆盖真实按钮，没有放松产品判断。

最终页面回归：`/tmp/ctrlx-browser-workflows-full2.log`；36 个检查点通过，
`hostStopped=true`。产物/摘要：
`/var/folders/lj/k5dn64f52psc95qksnhl53cr0000gn/T/cx-upstream-khu9js1j/`。
44 项相关 Swift 测试通过（35 CLI/身份/工作流＋9 宿主路由），见
`/tmp/ctrlx-browser-workflows-unit-final.log`；CLI 构建见
`/tmp/ctrlx-browser-workflows-build-final.log`。CLI 拒绝测试、Skill 校验及隔离 App
深度签名校验通过。使用真实 CEF/CDP 与原生身份夹具，**不是真实 Codex 推理验收**。
双引擎/隔离/生命周期回归另有 18 个检查点通过，`hostStopped=true`：
`/tmp/ctrlx-browser-workflows-dual.log`；摘要
`/var/folders/lj/k5dn64f52psc95qksnhl53cr0000gn/T/cx-upstream-k3o5t0gt/summary.json`。
没有替换生产安装、提交或发布。

## 第三轮缺口补齐：历史记录

对应 [TODO 的 I/II 剩余清单](agent-browser-todo.md)，本轮完成 **U5 及 P1/P3/P4/P6 的部分子项**，
不是全部补齐。固定 Vercel/CEF 版本及共享 profile、归属校验、原 CtrlX 引擎保持不变。
下面的第二轮与历史审计保留当时的范围和证据，新增支持以本节及
[当前用法](agent-browser-engines.md) 为准。

| 本轮新增 | 实际验收 | 仍有限制 |
|---|---|---|
| `network request <id>`、HAR `--content all/text/none` | 读取真实 JSON 响应正文，三种 HAR 内容策略，跨 owner 拒绝 | 保留上游二进制正文摘要/正文不可用行为，非所有子帧/响应类型保证 |
| `--input-file` / `--input-stdin` → `eval`、`webmcp invoke` | JS 文件实际执行；工具 JSON 文件参数改变 DOM；输入互斥、UTF-8/大小/JSON/管道解析拒绝测试 | 文件/stdin 在 `--` 前，48 KB 上限；stdin 页面效果未单独验收；init 按 ID 管理未实现 |
| `diff url … --screenshot` | 同一所属标签两次导航，文本差异及真实像素变化，相同内容不生成文件，最终仍在第二个 URL | 上游 native handler 忽略该选项，由 CtrlX 组合原语；PNG/6 MiB/拒绝覆盖边界保留 |
| `record --format mp4 --fps … --cursor --contact-sheet …` | ffprobe 确认 H.264/12 fps、解码帧，PNG 联系表/帧数、拒绝覆盖；原 WebM 动态帧回归 | 支持 1–60 fps，但未穷举；cursor 开启可录制，未单独断言光标像素；仍限 1–10 秒、15 秒租约、合计 6 MiB；双文件导出非原子 |

**失败尝试也保留**：取消 `--no-webmcp` 后，11 次操作结果未收到预期的自动工具目录。
源码显示上游每次调用会先发送 provider `launch`，再丢弃成功响应；这可能提前消耗
一次性目录提示。该尝试已撤回，保留显式 `webmcp list/invoke/result/cancel`，
不将自动发现标为已完成。失败日志：`/tmp/ctrlx-browser-gap-e2e2.log`，
摘要：`/var/folders/lj/k5dn64f52psc95qksnhl53cr0000gn/T/cx-upstream-g_rzxsub/summary.json`。

本轮验收使用隔离签名 App、真实 CEF/CDP、公共 CtrlX CLI 和原生身份夹具，
**不是真实 Codex 推理验收**，没有替换生产 App。结果：

- CLI 构建、签名校验、CLI 参数/拒绝回归、Skill 校验通过。
- 38 项相关 Swift 测试（29 项 CLI/身份 + 9 项宿主路由）通过：
  `/tmp/ctrlx-browser-gap-unit-final.log`、`/tmp/ctrlx-browser-gap-routing.log`。
- 32 个公共页面效果检查点通过，`hostStopped=true`：
  `/tmp/ctrlx-browser-gap-e2e-final.log`；产物及摘要位于
  `/var/folders/lj/k5dn64f52psc95qksnhl53cr0000gn/T/cx-upstream-70ln6g_k/`。
- 18 个双引擎、归属/生命周期与录屏到期检查点通过，`hostStopped=true`：
  `/tmp/ctrlx-browser-gap-dual-engine.log`；摘要位于
  `/var/folders/lj/k5dn64f52psc95qksnhl53cr0000gn/T/cx-upstream-osd8xza5/summary.json`。
- PNG 录屏联系表经目视检查，包含连续帧、时间戳与光标；没有用成功响应代替视频解码验证。

这些数字是测试/检查点，不是上游能力总数。全局 Tracing、auth/state/clipboard、
预览服务、策略/确认、外部运行环境及上游独立工具仍未实现；batch 扩展、长录制、
自动 WebMCP、移动模拟 OOPIF 指针、init 按 ID 管理仍有缺口，见 TODO。
未安装、提交、推送或发布。

## 第二轮能力扩展：历史记录

本轮实现的是“上游现有能力的入口/产物开放”和“需要 CtrlX 适配的页面能力”，
不是录制生成 Skill、人机接管、页面上下文选择或外部浏览器产品功能。
仍使用未修改的固定 Vercel **0.38.1**、CEF **152.0.8** / Chromium **152.0.7977.134**；
原 CtrlX 引擎与 `action` 契约保留。当前用法见 [双引擎说明](agent-browser-engines.md)。

| 能力及公共入口 | CtrlX 额外处理 | 效果验收与边界 |
|---|---|---|
| `command … screenshot --selector/--format/--quality/--if-changed/--threshold` | 显式区分 selector 与文件路径，固定格式参数、独占文件导出、跳过产物契约 | JPEG 魔数、元素 PNG 宽高、真实像素变化和未变化无文件；不是全部参数笛卡尔积 |
| `diff snapshot/screenshot --baseline` | 1 MiB UTF-8 / 6 MiB PNG 普通文件，拒绝符号链接、PNG 尺寸限制、私有基线副本 | 文本变化/未变化、图像不同像素、相同图跳过文件、尺寸不符返回结构化结果 |
| `diff url` / `browser batch` | 同一所属标签两次导航；1–32 步预校验、整批同锁、失败即停 | URL 内容差异、字面量参数、非法后续命令阻止前面的执行、失败后后续未执行、跨实例拒绝；不回滚已经执行的步骤 |
| `frame` CSS/main/`--name`/`--url` | iframe-only 自动附着、已观察到的子会话归属、分散 frame tree 合并；name/URL 使用引擎既有私有类型化 action | 桌面跨站及嵌套 OOPIF 填写/读取、可信点击、返回主页面；不开放任意 Target/worker |
| `browser setup` / `react tree/inspect/renders/suspense` | 显式停止旧 tab daemon 后替换配置；有界 init 文件、React hook、手动 reload、断线清理 | React 18.3.1 真组件树/inspect、状态变化与 render 记录；导航后 init 仍生效、清空 setup 后 reload 不再注入；suspense 空夹具查询通过，未覆盖全部 React 版本/挂起边界 |
| `webmcp list/invoke/result/cancel` | CEF 对应 feature、页面级方法/事件、仅 inline JSON | 真实网页工具修改 DOM、长工具 detach/cancel/result；预览端口仍关闭。网页工具描述不构成授权 |
| `browser record` | 精确根标签的单一临时捕获会话、15 秒原生上限、私有 ffmpeg PATH、有界 WebM 导出 | ffprobe 读取帧数、ffmpeg 解码多帧且帧哈希变化；归属/重复附着拒绝、原生到期和旧会话拒绝。需预装 Homebrew ffmpeg，非 MP4/contact sheet/无界录制 |
| `trace` / `profiler` | **未开放** | 已核对 [0.38.1 tracing.rs](https://github.com/vercel-labs/agent-browser/blob/v0.38.1/cli/src/native/tracing.rs)：两者都使用 `Tracing.start/end`；不能当作单页 CPU Profiler，需另做全局采集授权/隔离或页面级替代 |

真实回归还发现并明确保留以下差异，不能写成“全部能力已跑通”：

- 手机模拟后对 OOPIF 的鼠标点击可能返回成功但没命中。现在原生网关明确拒绝该组合，
  `set viewport W H` 恢复桌面后再操作；同源/桌面 OOPIF 不受此限制。
- 上游 `eval` 仍在顶层文档执行，不跟随 `frame`；子页面读取使用 `get/snapshot`。
  上游 CLI 的 frame name/URL 缺口已由固定私有 action 补齐，不暴露任意 daemon 命令。
- 地理权限、完整设备/触摸、Shadow DOM/worker 全场景仍不属于本轮完整验收。
  全局 Cookie/profile 导出、外部/云端/iOS runtime、扩展管理继续排除。
- 短录屏不是“录制人工操作生成 Skill”；WebMCP 不是给 Codex 新增 MCP 服务。

验收方式：`expanded_capabilities.py` 默认包含前一轮公共页面回归，使用隔离签名 App、
真实 CEF/CDP 和原生 Codex 命名身份夹具；**不是真实 Codex 推理验收**，没有替换生产 App。
测试站点仅 loopback。React 测试资源来自固定 18.3.1 UMD development 包，不进入产品：

- `react.js` SHA-256：`28348fef6cb0ed8b2ceeb22deaf824428fd13875d84c73d38f77dd216fc24e7f`
- `react-dom.js` SHA-256：`f9044a5e9c39db8bb1a204dff924e526ec0a621e695bb69de1035811be8709e4`

最终验证：34 项相关 Swift 测试（25 项 CLI/身份 + 9 项宿主路由）、CLI 参数/拒绝回归、
Skill 校验、`git diff --check` 通过；原生 CEF 库与 CLI 构建、隔离 App 签名校验通过。
公共页面扩展 28 个检查点、双引擎/归属与录制到期 18 个检查点通过；两个摘要均为
`hostStopped=true`，数字是检查点数量，不是上游独立能力总数。

- 页面回归：`/tmp/ctrlx-browser-expansion-final2.log`；产物及摘要
  `/var/folders/lj/k5dn64f52psc95qksnhl53cr0000gn/T/cx-upstream-nwizad7n/`。
- 双引擎最终回归（包含非法模拟参数不崩溃）：`/tmp/ctrlx-browser-expansion-dual-final.log`；摘要
  `/var/folders/lj/k5dn64f52psc95qksnhl53cr0000gn/T/cx-upstream-payht1tq/summary.json`。
- Swift：`/tmp/ctrlx-browser-all-unit.log`；原生构建：`/tmp/ctrlx-browser-expansion-native.log`。
- JPEG 裁剪经目视检查；视频经 ffprobe/ffmpeg 解码断言。没有提交、推送、发布或覆盖生产安装。

下列章节保留前两次验收过程和 177 条历史审计，**其中“未接入/仍未纳入”等是当时状态，
不是当前支持列表**。当前状态以上表及双引擎说明为准。

## 补齐后的公共入口验收

后续实现已增加 `ctrlx browser command --tab ID -- …`，旧 `action` 用法、原
CtrlX 引擎、内嵌位置和共享登录态保持不变。**下方 177 条是修改前的历史审计，
不要将其中“未接入”当作当前状态。** 当前边界见 [引擎说明](agent-browser-engines.md)。

新增 `tests/page_capabilities.py` 通过公共 CtrlX CLI，而不是直接调用上游二进制：

- 已验证：输入/拖放/语义定位/多选、get/is、滚动/鼠标、延迟等待/快照差异、存储。
- 已验证：上传的真实文件内容、下载字节、全页标注 PNG、PDF、已有文件拒绝覆盖。
- 已验证：真实 console/error/network 事件、拦截/恢复响应、HAR 中的请求、headers/HTTP auth。
- 已验证：viewport/media/device/offline 的页面效果、同源 iframe、prompt/confirm 回答。
- 已验证：当前域 Cookie 读写、异域写入拒绝、其他域 Cookie 不泄漏、历史/刷新、Vitals/axe。
- 已验证：跨 owner 拒绝、另一实例继续可用、预览端口保持关闭、测试 App 正常退出。

本轮修复了两处仅看成功响应会漏掉的问题：directPage 事件缺少空 `sessionId` 导致
上游忽略事件；默认 CEF JavaScript 弹窗被 CDP 回答后仍残留 AppKit 模态状态。
现分别补齐事件标识与按标签页的 CEF 弹窗回调；下载也使用按标签页的 CEF 回调，
不向共享浏览器上下文转发全局下载设置。

证据：`/tmp/ctrlx-page-capabilities-9.log`；对应目录
`/var/folders/lj/k5dn64f52psc95qksnhl53cr0000gn/T/cx-upstream-212vqkdm/`
保存 `summary.json`、PNG、PDF、下载文件和 HAR。使用真实 CEF、原生身份夹具，
**不是本轮真实 Codex 推理验收**，也不是上游全平台/全参数穷举。

仍未纳入：跨进程 iframe、录像/ffmpeg、全局 trace/profiler、整份登录状态导出、
React 启动 hook、WebMCP、外部/云端/iOS runtime、插件管理、部分截图/diff 选项。
地理位置设置的权限闭环尚未验收；手机模拟按上游仅改变 viewport/UA。
这些边界没有标成“全部支持”。

最终收尾：21 项 Swift 测试（2 个测试组）、既有 CLI 解析/拒绝测试、skill 校验与
`git diff --check` 通过。扩展页面验收 20 个检查点、双引擎回归 17 个检查点通过，
两个摘要均为 `hostStopped=true`。双引擎最终日志为
`/tmp/ctrlx-engine-expanded-final-regression.log`，摘要目录
`/var/folders/lj/k5dn64f52psc95qksnhl53cr0000gn/T/cx-upstream-_5jt6scv/`。
标注截图经目视检查；PDF 经 PDFKit 校验包含夹具标题文本。未覆盖安装、提交、推送或发布。

## 结论与口径

**没有“全部能力验证通过”。** Vercel 0.38.1 已作为无保存偏好时的默认引擎，
原 CtrlX 引擎和已有实例的显式偏好保留。选择引擎不等于开放上游全部命令。

本次按固定版本的 [README](https://github.com/vercel-labs/agent-browser/blob/v0.38.1/README.md)
和官方二进制 `--help` 盘点命令族，并在隔离签名 App 的真实 CEF 内嵌页、**产品原生
CDP 网关**上执行能力探测。不是 Python 模拟 CDP，不是系统 Chrome；使用原生 Codex
命名的身份夹具，不是真实 Codex 推理验收。没有替换正在使用的 /Applications/CtrlX.app。

177 条记录 = 165 条执行/检查记录 + 12 组明确未测事项。它们不是 177 个独立功能，
也不表示穷举了所有参数、平台、站点、帧类型及错误组合。结果分布：

| 结果 | 数量 | 含义 |
|---|---:|---|
| 实际断言通过 | 77 | 页面状态、返回内容、文件签名或边界断言符合预期；不等于全部参数已覆盖 |
| 仅成功响应 | 32 | 命令返回成功，但缺少足以证明该功能的完整效果断言；不能计为验收通过 |
| 报错 | 52 | 包括网关不支持、依赖/前置条件缺失和特意测试的负例；不能全部归咎于上游缺陷 |
| 成功响应但效果缺失 | 4 | console、errors、network requests、HAR 没有采到明确产生的测试事件/请求 |
| 明确未测 | 12 | 外部浏览器、系统剪贴板、云端/模拟器、账号凭据、安装升级等另列原因 |

这些测试直接调用上游二进制是**隔离验收夹具专用**。用户/agent 仍应使用
`ctrlx browser`，不能把表中上游原生命令的通过误报为公共 CLI 已开放。
公共入口目前只有 16 个 action，其中 8 个由 Vercel 实现，另外 8 个保留 CtrlX 的
生命周期/兼容语义。测试还确认了 59 个上游命令名被公共入口显式拒绝。

## 主要能力与缺口

| 能力族 | 上游在当前网关的实测 | CtrlX 公共入口 |
|---|---|---|
| AX snapshot、refs、click/type/fill/press/select/check、截图 | 基本路径通过；PNG/JPEG、全页/标注截图另有夹具覆盖 | 已开放基础子集，不开放所有截图/快照选项 |
| 双击、hover/focus、键盘按下/松开、拖放、鼠标、语义定位器、get/is | 多项页面效果通过；部分只有响应检查 | 尚未开放 |
| read、scroll、wait | 页面/URL 文本与容器滚动可用；延迟等待有断言 | 继续用 CtrlX 原契约，不是上游全选项 |
| tab/open/navigate/show/close、实例和子页归属 | 产品双引擎回归通过 | CtrlX 管理；上游 Target/窗口创建不开放 |
| storage local/session、eval、SPA pushstate、历史前进/后退 | 夹具通过 | 尚未开放 |
| snapshot/screenshot diff、batch、highlight | batch 有内容断言；diff/highlight 仅成功响应 | 尚未开放 |
| upload/download/PDF | 分别被 DOM.setFileInputFiles、Browser.setDownloadBehavior、Page.printToPDF 拒绝 | 未接入 |
| console/errors、请求记录、HAR | 返回成功但缺少测试事件或请求；网关未转发这些事件 | 未接入，不能宣称可用 |
| 路由拦截、headers、HTTP credentials、offline | Fetch/Network 方法被拒绝 | 未接入 |
| Cookie 读写/清除、认证状态导出 | 全局/存储相关方法被拒绝；共享网站登录态仍由 CEF profile 保持 | 不等于“没有登录态”，是没有这些自动化接口 |
| viewport/device/geo/media | Emulation 方法被拒绝 | 未接入 |
| frame | 选择帧返回成功，实际读取帧内容在 DOM.getFrameOwner 失败 | 未接入，选择成功不能代替可用性证明 |
| dialog | 无弹窗状态可查询；处理方法被拒绝，未做真实弹窗回答验收 | 未接入 |
| trace/profiler/record | Tracing 不开放；受控 PATH 中无 ffmpeg，录制失败 | 未接入 |
| React、vitals、a11y、init scripts、WebMCP | 缺 hook 或 CDP 方法；不是完整可用 | 未接入 |
| skills | 发行二进制没有附带上游 skills 目录 | CtrlX 自己的 agent-browser skill 仍可用 |
| session/plugin 管理 | 仅查询响应检查 | 由适配层管理，不向 agent 透传管理命令 |
| MCP/chat/dashboard、cloud/iOS/Appium/Lightpanda、外部 Chrome、凭据仓库 | 未执行完整工作流，不能宣称通过 | 不属于当前嵌入页接口 |

另外，固定版本存在需区分于 CtrlX 网关的文档/实现差异：
`wait --state hidden` 在已隐藏元素上超时；
`addinitscript` 被二进制判为未知命令。该版本
[命令解析源码](https://github.com/vercel-labs/agent-browser/blob/v0.38.1/cli/src/commands.rs)
的默认 selector wait 分支也没有读取 state。这里记录观测，不修改上游 fork。

## 本轮修正与验证

- 默认值改为 Vercel；原引擎显式选择、已有保存偏好和单次覆盖保留。
- 每次调用都固定相同 provider/启动参数，避免上游因参数变化重启后启动独立空白 Chrome。
  审计器也先断言当前 URL 确实是授权的内嵌夹具页；中途测试脚本参数造成的空白页结果已废弃，
  没有混入本报告。
- 双引擎原生回归 17 个检查点通过，包括 product daemon 的 streaming 关闭状态、
  共享登录、跨实例拒绝、子页归属、旧 refs 拒绝和进程退出撤销。
- Swift 两组相关测试共 19 项通过；既有 CLI 测试、skill 校验、diff 格式检查通过。
- skill 按 skill-creator 收紧说明：Vercel 默认不等于完整上游能力；字段限制/快照脱敏也不能
  与原引擎混为一谈。没有为让测试变绿而扩大 CDP 白名单或开放任意透传。
- 两个隔离测试 App 均正常退出，已确认 `hostStopped=true`。未安装、提交、推送或发布。

## 复跑

先按 [引擎集成说明](agent-browser-engines.md) 准备正常原生库、最新 CLI、固定上游二进制的
隔离签名 App（bundle ID `com.ctrlx.embedded-acceptance`）和 native identity 夹具，
**不要覆盖已安装 App**。两项验收共用隔离 E2E socket，顺序运行：

```sh
python3 CtrlxPackage/AgentBrowser/tests/managed_engine.py '<test.app>' '<test.app>/Contents/Resources/AgentBrowserEngine/agent-browser' '<fixture-codex>'
python3 CtrlxPackage/AgentBrowser/tests/engine_capabilities.py '<test.app>' '<test.app>/Contents/Resources/AgentBrowserEngine/agent-browser' '<fixture-codex>'
```

能力审计是采集器，不是全绿回归门：保留错误/跳过，逐项写 `capabilities.json`。
进程成功退出表示完成采集和边界检查，**不表示所有功能通过**。网页只访问自建 loopback
fixture；文件只在隔离测试目录生成，凭据不打印；未触碰系统剪贴板或真实登录凭据。
录制探测可能初始化上游预览端口，夹具会随后显式关闭并核验。

本轮最终证据（前面中断/脚本修正过程的记录不计入）：

- 默认与隔离回归：`/tmp/ctrlx-managed-final-default.log`
- 能力采集日志：`/tmp/ctrlx-engine-capabilities-final.log`
- 完整机器记录：`/var/folders/lj/k5dn64f52psc95qksnhl53cr0000gn/T/cx-upstream-5od06rvx/capabilities.json`
- 原生回归摘要：`/var/folders/lj/k5dn64f52psc95qksnhl53cr0000gn/T/cx-upstream-5racjde3/summary.json`

## 逐项记录

“公共入口”仅表示存在相应基础功能，不承诺该行的全部上游选项可透传。
负例（如 nonexistent confirmation、无录制时 stop）报错属预期，不能计作正向通过。

| 检查项 | 结果 | 公共入口 |
|---|---|---|
| snapshot interactive | 实际断言通过 | 已有等价公共入口 |
| snapshot full | 实际断言通过 | 上游测试专用／未开放 |
| snapshot -c | 实际断言通过 | 上游测试专用／未开放 |
| snapshot -d 2 | 实际断言通过 | 上游测试专用／未开放 |
| snapshot -s article | 实际断言通过 | 上游测试专用／未开放 |
| fill | 实际断言通过 | 已有等价公共入口 |
| type | 实际断言通过 | 已有等价公共入口 |
| click | 实际断言通过 | 已有等价公共入口 |
| double click | 实际断言通过 | 上游测试专用／未开放 |
| focus | 实际断言通过 | 上游测试专用／未开放 |
| keyboard type | 实际断言通过 | 上游测试专用／未开放 |
| keyboard inserttext | 实际断言通过 | 上游测试专用／未开放 |
| press | 实际断言通过 | 已有等价公共入口 |
| keydown | 实际断言通过 | 上游测试专用／未开放 |
| keyup | 实际断言通过 | 上游测试专用／未开放 |
| hover | 实际断言通过 | 上游测试专用／未开放 |
| check | 实际断言通过 | 已有等价公共入口 |
| uncheck | 实际断言通过 | 已有等价公共入口 |
| select value | 实际断言通过 | 已有等价公共入口 |
| select label | 实际断言通过 | 上游测试专用／未开放 |
| select multiple | 实际断言通过 | 上游测试专用／未开放 |
| drag drop | 实际断言通过 | 上游测试专用／未开放 |
| scroll container | 实际断言通过 | 上游测试专用／未开放 |
| scroll into view | 实际断言通过 | 上游测试专用／未开放 |
| mouse move | 实际断言通过 | 上游测试专用／未开放 |
| mouse down | 实际断言通过 | 上游测试专用／未开放 |
| mouse up | 实际断言通过 | 上游测试专用／未开放 |
| mouse wheel | 仅成功响应 | 上游测试专用／未开放 |
| eval | 实际断言通过 | 上游测试专用／未开放 |
| get text | 实际断言通过 | 上游测试专用／未开放 |
| get html | 实际断言通过 | 上游测试专用／未开放 |
| get value | 实际断言通过 | 上游测试专用／未开放 |
| get attr | 实际断言通过 | 上游测试专用／未开放 |
| get title | 实际断言通过 | 上游测试专用／未开放 |
| get url | 实际断言通过 | 上游测试专用／未开放 |
| get count | 实际断言通过 | 上游测试专用／未开放 |
| get box | 实际断言通过 | 上游测试专用／未开放 |
| get styles | 实际断言通过 | 上游测试专用／未开放 |
| get cdp-url | 实际断言通过 | 上游测试专用／未开放 |
| is visible #apply | 实际断言通过 | 上游测试专用／未开放 |
| is visible #hidden | 实际断言通过 | 上游测试专用／未开放 |
| is enabled #disabled | 实际断言通过 | 上游测试专用／未开放 |
| is checked #check | 实际断言通过 | 上游测试专用／未开放 |
| find role | 实际断言通过 | 上游测试专用／未开放 |
| find text | 实际断言通过 | 上游测试专用／未开放 |
| find label | 实际断言通过 | 上游测试专用／未开放 |
| find placeholder | 实际断言通过 | 上游测试专用／未开放 |
| find alt | 仅成功响应 | 上游测试专用／未开放 |
| find title | 实际断言通过 | 上游测试专用／未开放 |
| find testid | 实际断言通过 | 上游测试专用／未开放 |
| find first | 实际断言通过 | 上游测试专用／未开放 |
| find last | 实际断言通过 | 上游测试专用／未开放 |
| find nth | 实际断言通过 | 上游测试专用／未开放 |
| wait #apply | 仅成功响应 | 上游测试专用／未开放 |
| wait 20 | 仅成功响应 | 上游测试专用／未开放 |
| wait --text Overview | 仅成功响应 | 上游测试专用／未开放 |
| wait --url **/audit | 仅成功响应 | 上游测试专用／未开放 |
| wait --fn true | 仅成功响应 | 上游测试专用／未开放 |
| wait --load load | 仅成功响应 | 上游测试专用／未开放 |
| wait --load domcontentloaded | 仅成功响应 | 上游测试专用／未开放 |
| wait --load networkidle | 仅成功响应 | 上游测试专用／未开放 |
| wait #hidden --state hidden | 报错／前置条件未满足 | 上游测试专用／未开放 |
| read DOM  | 实际断言通过 | 上游测试专用／未开放 |
| read DOM --filter Overview | 实际断言通过 | 上游测试专用／未开放 |
| read DOM --outline | 实际断言通过 | 上游测试专用／未开放 |
| read fetch  | 实际断言通过 | 上游测试专用／未开放 |
| read fetch --raw | 实际断言通过 | 上游测试专用／未开放 |
| read fetch --require-md | 实际断言通过 | 上游测试专用／未开放 |
| read fetch --llms index | 实际断言通过 | 上游测试专用／未开放 |
| read fetch --llms full | 实际断言通过 | 上游测试专用／未开放 |
| screenshot | 实际断言通过 | 已有等价公共入口 |
| screenshot full | 实际断言通过 | 上游测试专用／未开放 |
| screenshot annotate | 实际断言通过 | 上游测试专用／未开放 |
| screenshot jpeg | 实际断言通过 | 上游测试专用／未开放 |
| screenshot if-changed | 仅成功响应 | 上游测试专用／未开放 |
| diff snapshot | 仅成功响应 | 上游测试专用／未开放 |
| diff screenshot | 仅成功响应 | 上游测试专用／未开放 |
| batch | 实际断言通过 | 上游测试专用／未开放 |
| highlight | 仅成功响应 | 上游测试专用／未开放 |
| wait delayed text | 实际断言通过 | 上游测试专用／未开放 |
| wait negative timeout (expected) | 报错／前置条件未满足 | 上游测试专用／未开放 |
| storage local set | 实际断言通过 | 上游测试专用／未开放 |
| storage local get | 实际断言通过 | 上游测试专用／未开放 |
| storage local list | 实际断言通过 | 上游测试专用／未开放 |
| storage local clear | 实际断言通过 | 上游测试专用／未开放 |
| storage session set | 实际断言通过 | 上游测试专用／未开放 |
| storage session get | 实际断言通过 | 上游测试专用／未开放 |
| storage session list | 实际断言通过 | 上游测试专用／未开放 |
| storage session clear | 实际断言通过 | 上游测试专用／未开放 |
| upload | 报错／前置条件未满足 | 上游测试专用／未开放 |
| download | 报错／前置条件未满足 | 上游测试专用／未开放 |
| pdf | 报错／前置条件未满足 | 上游测试专用／未开放 |
| console | 成功响应但效果缺失 | 上游测试专用／未开放 |
| errors | 成功响应但效果缺失 | 上游测试专用／未开放 |
| network requests | 成功响应但效果缺失 | 上游测试专用／未开放 |
| cookies get | 报错／前置条件未满足 | 上游测试专用／未开放 |
| cookies set | 报错／前置条件未满足 | 上游测试专用／未开放 |
| cookies clear | 报错／前置条件未满足 | 上游测试专用／未开放 |
| set viewport | 报错／前置条件未满足 | 上游测试专用／未开放 |
| set device | 报错／前置条件未满足 | 上游测试专用／未开放 |
| set geo | 报错／前置条件未满足 | 上游测试专用／未开放 |
| set media | 报错／前置条件未满足 | 上游测试专用／未开放 |
| set headers | 报错／前置条件未满足 | 上游测试专用／未开放 |
| set headers reset | 报错／前置条件未满足 | 上游测试专用／未开放 |
| set credentials | 报错／前置条件未满足 | 上游测试专用／未开放 |
| set offline | 报错／前置条件未满足 | 上游测试专用／未开放 |
| set online | 报错／前置条件未满足 | 上游测试专用／未开放 |
| network route | 报错／前置条件未满足 | 上游测试专用／未开放 |
| network unroute | 报错／前置条件未满足 | 上游测试专用／未开放 |
| network har start | 仅成功响应 | 上游测试专用／未开放 |
| network har stop | 仅成功响应 | 上游测试专用／未开放 |
| HAR captures actual fixture request | 成功响应但效果缺失 | 上游测试专用／未开放 |
| trace start | 报错／前置条件未满足 | 上游测试专用／未开放 |
| trace stop | 报错／前置条件未满足 | 上游测试专用／未开放 |
| profiler start | 报错／前置条件未满足 | 上游测试专用／未开放 |
| profiler stop | 报错／前置条件未满足 | 上游测试专用／未开放 |
| record start | 报错／前置条件未满足 | 上游测试专用／未开放 |
| record stop | 报错／前置条件未满足 | 上游测试专用／未开放 |
| frame select | 仅成功响应 | 上游测试专用／未开放 |
| frame content read | 报错／前置条件未满足 | 上游测试专用／未开放 |
| frame main | 仅成功响应 | 上游测试专用／未开放 |
| dialog status | 仅成功响应 | 上游测试专用／未开放 |
| dialog accept | 报错／前置条件未满足 | 上游测试专用／未开放 |
| dialog dismiss | 报错／前置条件未满足 | 上游测试专用／未开放 |
| webmcp list | 报错／前置条件未满足 | 上游测试专用／未开放 |
| webmcp invoke | 报错／前置条件未满足 | 上游测试专用／未开放 |
| webmcp result | 报错／前置条件未满足 | 上游测试专用／未开放 |
| webmcp cancel | 报错／前置条件未满足 | 上游测试专用／未开放 |
| react tree | 报错／前置条件未满足 | 上游测试专用／未开放 |
| react inspect | 报错／前置条件未满足 | 上游测试专用／未开放 |
| react renders start | 报错／前置条件未满足 | 上游测试专用／未开放 |
| react renders stop | 报错／前置条件未满足 | 上游测试专用／未开放 |
| react suspense | 报错／前置条件未满足 | 上游测试专用／未开放 |
| vitals | 报错／前置条件未满足 | 上游测试专用／未开放 |
| a11y | 报错／前置条件未满足 | 上游测试专用／未开放 |
| remove init script | 报错／前置条件未满足 | 上游测试专用／未开放 |
| add init script | 报错／前置条件未满足 | 上游测试专用／未开放 |
| state save | 报错／前置条件未满足 | 上游测试专用／未开放 |
| state list | 仅成功响应 | 上游测试专用／未开放 |
| tab list | 仅成功响应 | 上游测试专用／未开放 |
| tab switch | 仅成功响应 | 上游测试专用／未开放 |
| tab new | 报错／前置条件未满足 | 上游测试专用／未开放 |
| window new | 报错／前置条件未满足 | 上游测试专用／未开放 |
| back | 仅成功响应 | 上游测试专用／未开放 |
| forward | 仅成功响应 | 上游测试专用／未开放 |
| reload | 报错／前置条件未满足 | 上游测试专用／未开放 |
| open/navigation | 报错／前置条件未满足 | 上游测试专用／未开放 |
| diff url | 报错／前置条件未满足 | 上游测试专用／未开放 |
| pushstate | 实际断言通过 | 上游测试专用／未开放 |
| back with history | 实际断言通过 | 上游测试专用／未开放 |
| forward with history | 实际断言通过 | 上游测试专用／未开放 |
| session | 仅成功响应 | 上游测试专用／未开放 |
| session list | 仅成功响应 | 上游测试专用／未开放 |
| session info | 仅成功响应 | 上游测试专用／未开放 |
| session id | 仅成功响应 | 上游测试专用／未开放 |
| stream status | 仅成功响应 | 上游测试专用／未开放 |
| plugin list | 仅成功响应 | 上游测试专用／未开放 |
| plugin show ctrlx | 仅成功响应 | 上游测试专用／未开放 |
| skills list | 报错／前置条件未满足 | 上游测试专用／未开放 |
| skills get core | 报错／前置条件未满足 | 上游测试专用／未开放 |
| skills path core | 报错／前置条件未满足 | 上游测试专用／未开放 |
| auth list | 仅成功响应 | 上游测试专用／未开放 |
| confirm nonexistent-fixture | 报错／前置条件未满足 | 上游测试专用／未开放 |
| deny nonexistent-fixture | 报错／前置条件未满足 | 上游测试专用／未开放 |
| clipboard read/write/copy/paste | 明确未测 | 上游测试专用／未开放 |
| inspect | 明确未测 | 上游测试专用／未开放 |
| connect / auto-connect / profiles | 明确未测 | 上游测试专用／未开放 |
| stream enable / dashboard | 明确未测 | 上游测试专用／未开放 |
| install / upgrade / doctor --fix | 明确未测 | 上游测试专用／未开放 |
| auth save/login/show/delete, credential-provider | 明确未测 | 上游测试专用／未开放 |
| state load/show/rename/clear/clean/restore | 明确未测 | 上游测试专用／未开放 |
| plugin add/run | 明确未测 | 上游测试专用／未开放 |
| MCP / AI chat | 明确未测 | 上游测试专用／未开放 |
| iOS/Appium, cloud providers, Lightpanda | 明确未测 | 上游测试专用／未开放 |
| launch flags, extensions, init scripts, proxy, TLS, profile | 明确未测 | 上游测试专用／未开放 |
| security policy/confirmation configuration | 明确未测 | 上游测试专用／未开放 |
| public CLI unsupported command boundary | 实际断言通过 | 上游测试专用／未开放 |
