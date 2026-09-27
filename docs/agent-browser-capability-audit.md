# Vercel 引擎能力审计（2026-09-28）

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
