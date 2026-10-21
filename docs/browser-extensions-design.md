# 浏览器扩展安装与管理设计

记录日期：2026-10-16。代码核对基线：`42636bd`。

2026-10-21 补充：原有 ENV 请求头验收只覆盖同源请求；跨域注入已复现
CEF 兼容问题，候选内核补丁尚未编译和接入产品，见
[Cross-origin header compatibility](#cross-origin-header-compatibility)。

状态：本分支的 Mac Host、Mac Viewer 和 iOS 实现已完成，关键路径本机验收通过，尚未提交或发布。覆盖商店下载／安装／手动替换、ZIP／CRX 导入与校验、更新恢复、真实 ENV 请求头切换及持久化、远端原生窗口输入与控制租约。Mac Release 与 iOS Simulator 构建通过。用户删除 Surge 中匹配 CtrlX 的 DIRECT 规则后，完整 App 的商店安装和更新流程成功，原网络阻塞解除，见第 9.19 节。iOS 界面证据来自 Simulator；所有扩展通用兼容、ENV native messaging、真实跨机器／设备发布验收不在本次通过结论内。使用方式和边界见[浏览器文档](agent-browser.md#browser-extensions)。

## 1. 目标与推荐方向

用户已确认两个需求：从 Chrome Web Store 安装扩展；导入自定义 `.zip` 和 `.crx`。首个重点兼容对象是 [ENV-Plugin](https://chromewebstore.google.com/detail/env-plugin/imebogohheacbbmhfiiddakclhifpbde)，扩展 ID 为 `imebogohheacbbmhfiiddakclhifpbde`。

推荐以 **Host 的 CtrlX 浏览器 profile** 为安装与管理单位。扩展在来源 Host 运行，Mac Host、Mac Viewer 和 iOS 查看同一份安装状态，页面效果也来自同一个 Host。首轮兼容性验证以 ENV-Plugin 的实际操作和页面效果为准。

建议分三阶段推进：隔离原型验证、Mac Host 产品化、Mac Viewer／iOS 接入。分阶段是实施建议，不代表远端需求已被取消。首版优先支持 Manifest V3，不承诺兼容所有 Chrome 扩展；Chrome 的 Manifest V2 淘汰情况见[官方时间线](https://developer.chrome.com/docs/extensions/develop/migrate/mv2-deprecation-timeline)。

## 2. 当前基础与关键限制

### 2.1 设计起点（基线 `42636bd`）

| 当前实现 | 对扩展方案的影响 |
| --- | --- |
| [构建脚本](../scripts/build-agent-browser.sh)固定 CEF `152.0.8+g1ce985c+chromium-152.0.7977.134` | 兼容性必须在这份运行时验证，不能直接套用系统 Chrome 或最新 CDP 文档的能力 |
| [EmbeddedBrowser.mm](../CtrlxPackage/AgentBrowser/EmbeddedBrowser.mm) 使用 AppKit 子视图与 Alloy runtime | 现有内嵌网页没有完整 Chrome 窗口、工具栏和扩展弹窗环境 |
| [AgentBrowserService](../CtrlxPackage/Sources/CtrlxServerFeature/Services/AgentBrowserService.swift) 使用 Host 持久 profile | 可沿用安装和设置的持久化范围；扩展持久化与临时浏览器标签的恢复是两件事 |
| [原生桥接](../CtrlxPackage/Sources/CtrlxBrowserBridge/include/CtrlxBrowserBridge.h)已有页面与 DevTools 生命周期 | 尚无扩展安装、枚举、启停、弹窗等管理能力，需要按原型结果补最小接口 |
| [EngineBridge.inc](../CtrlxPackage/AgentBrowser/EngineBridge.inc)限制 Agent 的 CDP 页面权限 | 不能为了安装扩展，把页面权限扩大成整个浏览器的管理权限 |
| [远端浏览器控制](../CtrlxPackage/Sources/CtrlxServerFeature/Services/AgentBrowserRemoteControl.swift)共享页面画面与输入 | 原生 Chrome 菜单和扩展弹窗不在现有页面截图中，不能自动获得远端交互能力 |

切换 `vercel`／`ctrlx` 自动化后端不会更换底层 CEF 或 profile，不能解决运行时扩展兼容性。

### 2.2 已确认的上游边界

Alloy 并非完全不能运行扩展。CEF 维护者说明，部分 RequestContext 层能力（例如网络拦截）可以工作，但 Chrome 工具栏等 UI 不由 Alloy 提供；窗口式 Chrome runtime 可以承载 `chrome://extensions`。见 [CEF 扩展支持说明](https://github.com/chromiumembedded/cef/issues/3859)。

当前固定版本的 [macOS CEF 头文件](https://github.com/chromiumembedded/cef/blob/1ce985c/include/internal/cef_types_mac.h)明确：设置外部 `parent_view` 或使用 windowless 模式会使用 Alloy。因此，不能只把现有内嵌页面的 runtime 枚举改成 Chrome 就完成迁移。

还需避免依赖两个不成立的捷径：

- 旧版 `CefRequestContext::LoadExtension` 已在 M128 的 Alloy 扩展 API 移除过程中退出；不能沿用旧教程。见 [CEF #3685](https://github.com/chromiumembedded/cef/issues/3685)。
- 现有页面级 CDP 通道不能直接充当扩展管理器。固定 Chromium 版本中的加载能力受浏览器目标权限约束，`getExtensions`／`uninstall` 也限定于 unpacked 扩展；触发扩展 action 还依赖浏览器窗口环境。见 [ExtensionsHandler](https://github.com/chromium/chromium/blob/152.0.7977.134/chrome/browser/devtools/protocol/extensions_handler.cc)与 [ChromeDevToolsSession](https://github.com/chromium/chromium/blob/152.0.7977.134/chrome/browser/devtools/chrome_devtools_session.cc)。

CEF 对 Alloy tab 的部分适配不等于完整 Chrome tab/window 语义。初始分析结合 [CEF 扩展补丁](https://github.com/chromiumembedded/cef/blob/1ce985c/patch/patches/chrome_browser_extensions.patch)和 [Chromium tabs 实现](https://github.com/chromium/chromium/blob/152.0.7977.134/chrome/browser/extensions/api/tabs/tabs_api.cc)，将 `active/currentWindow` 列为优先验证风险；第 9 节的隔离原型已实际复现该限制。

## 3. ENV-Plugin 的验证范围

2026-10-16 从 Google 官方扩展更新服务取得的包为 **ENV-Plugin 3.4.12、Manifest V3、CRX3**，大小 `4,265,252` 字节，SHA-256：

```text
157630bff1eda23757bd87502ea6ff6cddc0b9a8a60f1b6de72aeff7dbd5f5a2
```

初始设计检查只覆盖 CRX 头、manifest 和包内源码；后续签名、安装、popup、请求头切换及重启恢复记录见第 9 节。debugger API 共存已完成一项隔离验证，ENV 高级功能、native messaging 和多端验收尚未完成。版本、大小和哈希用于标识本次分析样本，不代表商店未来版本；不把第三方扩展包或源码提交到仓库。

| 包内声明或调用 | 需要证明的实际效果 |
| --- | --- |
| `action.default_popup = popup.html`、options 页面 | 用户能打开并操作原有界面，扩展能识别发起操作的网页 |
| `tabs`、`activeTab`，以及 `tabs.query({active: true, currentWindow: true})` 等调用 | 选择的是当前 CtrlX 网页；切换会话、分栏、独立窗口后不会误操作另一页 |
| `declarativeNetRequest`、`webRequest`、`cookies` | 修改请求、环境切换等核心功能确实生效，关闭规则后能恢复 |
| Service Worker、`storage`、content scripts、`scripting` | 后台逻辑、页面注入和设置持久化正常；重启后仍可工作 |
| `debugger` | 扩展调试能力与 CtrlX Agent CDP、DevTools 的共存和错误处理可接受 |
| `nativeMessaging`，连接 `net.bytedance.env_plugin_mcp_server` | 若启用相关高级功能，需要单独验证 native host 的安装、发现与授权 |
| 可选 `alarms`、`tabGroups` | 单独记录支持结果，不把可选能力与核心安装验收混为一谈 |

这些 API 的静态出现不代表每个功能都必须调用它们。尤其 native messaging 是独立兼容项，不能据此认定基本环境切换一定依赖外部助手。Chrome 的[调试 API](https://developer.chrome.com/docs/extensions/reference/api/debugger)与 [native messaging 文档](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)用于确定测试边界，不能替代当前 CEF 的实测。

## 4. 归属与多端行为

| 场景 | 目标行为 |
| --- | --- |
| 同一 Host 的不同会话、pane、网页 | 共用该 Host 的扩展安装和配置；规则的作用范围由扩展权限与自身规则决定，不假设按 CtrlX 会话隔离 |
| Mac Viewer 或 iOS 打开这个 Host 的网页 | 看到 Host 执行扩展后的页面效果；管理操作发送给来源 Host |
| 一台 Mac 同时作为本地 Host 和远端 Viewer | 管理界面明确显示目标 Host，不能误把远端扩展装到本机 |
| 不同 Host | 安装和设置各自独立，不自动同步包、配置或登录数据 |
| 系统 Chrome、旧设备本地 WK 浏览器 | 与 CtrlX Host profile 分离，不读取或修改它们的扩展 |

扩展是 profile 级能力。ENV 的网络规则可能影响多个会话，应在管理界面清楚显示“作用于此 Host 的浏览器”。扩展安装或设置持久化，不意味着浏览器标签、控制租约或未提交表单也会恢复。

远端有两个独立交付点：**页面效果共享**与**扩展界面可操作**。看到请求已被改写，不等于 iOS 已能操作扩展 popup；验收必须分别记录。

## 5. 产品交互与安装流程

### 5.1 入口

建议在浏览器地址栏旁加入扩展按钮，打开已安装扩展列表，提供“从 Chrome Web Store 安装”“导入 ZIP／CRX”和“管理扩展”。列表内可打开扩展 action／设置，并进入启用、停用、更新和卸载操作。

安装前展示名称、版本、来源、请求权限和目标 Host。安装成功必须由运行时确认，不能把“文件上传完成”“解压完成”当成已安装。失败给出具体原因；仍需刷新页面或授权时，直接显示下一步。

扩展 action 绑定用户点击按钮时的来源网页，后续异步操作不能因用户切换标签而改用另一页。直接把 `popup.html` 当作普通网页打开，不能保证正确的当前标签语义，不作为通用实现。

### 5.2 三种来源

| 来源 | 推荐安装方式 | 更新方式与约束 |
| --- | --- | --- |
| Chrome Web Store | 当前接线从 Google 更新服务下载 CRX3，校验签名和请求 ID，预览权限后走已验证的 unpacked 加载路径 | 首版手动检查更新、重新确认；不声称具备 Chrome 原生商店安装标记或自动更新，见第 9.7 节 |
| ZIP | 检查 manifest、安全解压到 Host 管理的稳定目录，再以 unpacked 方式加载 | 用户手动导入新包更新；原始 ZIP 被移走后仍可使用 |
| CRX | 首版处理 CRX3，验证签名与扩展 ID 后走已验证的运行时安装路径 | 本地导入默认手动更新；不能仅去掉 CRX 头便宣称完成验证或原生安装 |

Chrome 对 macOS／Windows 的商店外分发有专门限制，见[分发文档](https://developer.chrome.com/docs/extensions/how-to/distribute)。这些限制不能直接证明 CEF 的行为相同；CRX 在当前运行时的原生安装或经验证后解包加载路径，必须在原型中确定。如果只能用后者，应明确标识本地导入，不假装具备商店信任或更新机制。

CRX3 验签可参考固定版本的 [Chromium verifier](https://github.com/chromium/chromium/blob/152.0.7977.134/components/crx_file/crx_verifier.cc)。有效开发者签名证明包与签名身份的关系，不等于通过商店审核；ZIP 的 manifest `key` 也不是签名。[Manifest key](https://developer.chrome.com/docs/extensions/reference/manifest/key)与稳定目录需要共同纳入 ID 稳定性验证。

### 5.3 存储、更新与失败处理

- 沿用 Host profile 保存运行时数据，额外只保存必要的来源、受管理包路径和更新信息；已安装／已启用状态以运行时为准，不另建一套推测状态。
- 解包前限定包大小、解压后大小和文件数，拒绝越界路径及逃逸链接；具体限额在实现时依据包样本确定，不直接继承通用文件上传的较大上限。
- 更新时保持扩展 ID 和已有数据；先验证新包，再替换可用版本。失败保留旧版本，不先卸载再尝试安装。
- 同 ID 的商店版与本地包出现冲突时，明确告知来源变化，不静默覆盖；本地更新也不能因换了暂存路径而生成新 ID。
- 停用与卸载遵循运行时语义，向用户说明是否删除扩展数据；取消或失败不显示成功。权限增加走运行时相应的授权流程。

## 6. 技术落点与原型决策

### 6.1 初始验证路径

先验证 **现有 profile ＋ 独立的 Chrome-style 扩展管理窗口 ＋ 现有 Alloy 网页**。管理窗口承载运行时原生安装／权限／管理 UI，现有网页继续内嵌。

这条路径只是假设成本最低的候选方案。即使能打开 `chrome://extensions`，也不能据此认定商店安装、原生 action、当前标签识别或 ENV 全部可用。原型必须分别验证，尤其要证明管理窗口不会被误认为 ENV 应操作的当前网页。

管理窗口应作为浏览器工具窗口管理，不混入 Agent 拥有的网页集合。复用现有 DevTools 生命周期经验，保持 CEF 的原生 AppKit 消息循环；关闭最后一个工具窗口不能提前结束整个 runtime，退出时必须等待页面、工具窗口、传输和 Cookie flush 完成后再 shutdown。

安装管理只通过专用入口调用。保留普通页面的 URL 与 CDP 权限边界，不全局放开 `chrome://`、`chrome-extension://` 或浏览器级调试能力来绕过缺口。

### 6.2 原型不通过时

如果网络规则能工作，但 ENV 的当前标签识别或 popup 不能正确工作，不能宣称目标扩展已兼容。需要评估由 Chrome-style 窗口同时承载实际网页和扩展 UI 的路线。

这会影响现有内嵌标签、分栏和独立窗口体验，属于需要重新评审的产品变化。2026-10-16 用户已选择新增 CtrlX 扩展兼容窗口，见第 9 节。不修改第三方扩展源码、不补一套 Chrome API 仿真层，也不静默转到用户的系统 Chrome。

### 6.3 多端接入

Mac Viewer 和 iOS 通过带 Host 身份的类型化命令管理扩展，并按 Host 宣告的能力显示入口。旧 Host 不显示可用安装操作，返回错误时不回退到 Viewer 本地安装。

本地包复用现有加密文件上传机制，传输完成后由 Host 校验并安装，参见 [HostFileUploads](../CtrlxPackage/Sources/CtrlxServerFeature/Services/HostFileUploads.swift)。Viewer 的本地文件路径不能当成 Host 路径使用。安装／解包不得阻塞终端键盘的消息处理。

页面控制租约不自动授予整个 profile 的扩展管理权限。管理操作需要明确的 Host 管理入口和来源校验；扩展界面的远端交互还需定义其所属页面与控制租约，避免多个 Viewer 同时操作同一个 popup。

原生扩展 UI 需要单独的远端表面传输或经过验证的嵌入方案，不能复用页面 JPEG 后宣称已支持。原型未证明这一路径前，多端完整操作保持待办。是否需要 Relay 行为变化在消息方案确定后核对，不预先承诺只改客户端。

## 7. 实施阶段与验收门槛

| 阶段 | 交付 | 通过条件 |
| --- | --- | --- |
| A：运行时原型 | 在固定 CEF、隔离签名 App 和私有 profile 中验证管理窗口、三种安装来源及 ENV | 安装之外，核心页面效果、当前标签绑定和生命周期都成立；输出实际支持／失败矩阵再确定实现路线 |
| B：Mac Host 产品化 | 地址栏入口、安装预览、列表、启停、设置、手动更新、卸载和持久化 | 三种来源能完成全流程；取消、损坏包、更新失败保持一致状态；重启不丢扩展配置或改变 ID |
| C：Mac Viewer／iOS | Host 能力协商、上传安装、管理状态同步及扩展界面操作 | 操作落到正确 Host 与网页，多个 Viewer 的状态一致；断线和旧版本兼容正确；分别通过页面效果与 UI 交互验收 |

阶段 A 的必要检查：

1. 使用可观测请求的测试页面／服务，实际检查 ENV 的请求头修改、重定向或环境切换；停用规则后验证恢复，不能只看扩展提示。
2. 同时打开多个会话、分栏和独立窗口中的网页，验证扩展当前标签、刷新、跳转、消息发送均命中发起页。
3. 验证 Service Worker、内容脚本、设置和 ID 在关闭窗口及重启后保持正确；关闭管理窗口不退出正在使用的浏览器。
4. 分别验证商店安装与更新、ZIP 导入与更新、CRX 验签与导入；损坏签名和错误 manifest 给出明确失败。
5. 验证 ENV debugger 与 Agent 自动化／DevTools 的共存；native messaging 单独记录，不能把缺少外部助手记成已支持。
6. 验证远端能否承载并正确操作扩展 UI，记录 Mac Viewer 和 iOS 各自限制，避免阶段 B 完成后才发现整体路线无法满足阶段 C。

原生验收遵循[隔离 E2E 规则](e2e-testing.md)，使用专用测试页面、私有 profile 和隔离签名 App，不把用户已安装的 CtrlX、系统 Chrome profile 或运行中的任务当作测试环境。

## 8. 当前结论与未决项

已按用户确认的独立 Chrome-style 窗口路线完成三端接入。安装、更新、失败恢复、ENV 核心请求头效果、持久化、debugger API 共存、远端窗口画面／输入及控制隔离的本机证据见第 9 节；最后的商店网络阻塞及完整 App 复验见第 9.19 节。后续记录是逐步实施历史，早期“尚未完成”不覆盖后面的验证结果。

首版范围是 Manifest V3、官方商店 CRX3 和自定义 ZIP／CRX3、手动更新及 Host 共享 profile。没有自动更新、系统 Chrome profile 复用或所有扩展兼容承诺。ENV native messaging 外部助手和真实跨机器／设备发布验收仍未覆盖；既有 CEF 初始化／AppKit 异常按第 9.16 节保留，不由本次通过的操作路径推断为已修复。

本文记录新提出的浏览器扩展需求。[旧浏览器 TODO](agent-browser-todo.md)中 U8“本轮不纳入”描述的是此前页面能力迭代的范围，不代表本需求已实现，也不排除这次单独设计。

## 9. 实施记录：2026-10-16

### 9.1 已验证的运行时边界

在代码基线 `42636bd` 加本次原型的工作区上，使用固定 CEF SDK、Apple Development 签名的独立 App、专用测试扩展和私有 profile，完成以下检查。测试使用 mock keychain，不读取用户浏览器的凭据；生产 App 与系统 Chrome 未改动。

| 检查 | Alloy ＋ Chrome 管理窗口 | 关闭管理窗口后的 Alloy | Chrome-style 对照页 |
| --- | --- | --- | --- |
| MV3 content script 与 Service Worker 消息 | 通过 | 通过 | 通过 |
| DNR 实际修改测试服务收到的请求头 | 通过 | 通过 | 通过 |
| `tabs.query({})` 包含正在看的网页 | 否，只包含管理页 | 否，返回空列表 | 是 |
| `active/currentWindow` 正确匹配网页 | 否，匹配管理页 | 否，返回空列表 | 是 |
| `chrome.action.openPopup()` | 无活动浏览器窗口错误 | 无活动浏览器窗口错误 | 成功，popup 内查询命中来源页 |

Alloy 的 `sender.tab` 与 `tabs.get(id)` 可取得网页，但其 `windowId/index` 为 `-1`、`active` 为 `false`。因此不能依靠显示／聚焦现有 NSView 修复扩展的当前标签查询。

原型还通过 Host 私有 CDP 附着到已打开的真实 popup，获取了可读 PNG，并人工检查其内容与来源页一致。这证明了 popup 画面采集的基础路径，尚不等于远端输入、控制租约或多端产品已实现。没有向 Agent 的页面网关开放全局 target discovery。

可复现入口为 [ExtensionProbe.mm](../experiments/cef-browser-probe/ExtensionProbe.mm)、[专用扩展](../experiments/cef-browser-probe/extension-fixture/)和[验证脚本](../experiments/cef-browser-probe/test_extensions.py)；构建／运行方式见[原型说明](../experiments/cef-browser-probe/README.md#browser-extension-characterization-2026-10-16)。本机证据在 `.build-local/diagnostics/browser-extensions-tm8jp7l6/`，含 `report.json`、`native.log` 与 `popup.png`。临时路径不是跨机器证明，应以脚本重新验证。

### 9.2 用户确认的路线与剩余工作

用户已选择：“新增 CtrlX 扩展兼容窗口，需要扩展的网页在独立窗口中打开”。继续保留现有内嵌模式，在扩展入口显式打开 CtrlX 自有的 Chrome-style 窗口；两者使用同一 Host profile。独立窗口保留来源会话／pane 关联，不调用系统 Chrome。

- [x] 复现 Alloy 的当前标签与 popup 限制，并取得 Chrome-style 对照结果。
- [x] 验证真实 popup 能被 Host 私有通道采集为页面图像。
- [x] 完成 Mac 扩展窗口、管理入口与正常关闭／退出的隔离验证；既有异常记录保留。
- [x] 完成商店安装与手动替换、ZIP／CRX 导入校验、稳定 ID 和失败回滚。
- [x] 验证真实 ENV 核心请求头效果和 debugger API 共存；native messaging 未安装／未验收。
- [x] 完成 Mac Viewer／iOS 的能力协商、上传管理、popup 画面与输入、控制租约。
- [x] 完成 Mac Host／Viewer 与 iOS Simulator 的关键路径验证、旧 Host 协议／能力回归；不等于真实设备和跨机器发布验收。

基础原型运行成功只表示采集到了有效证据，不表示阶段 A 全部通过，更不表示整个功能完成。

### 9.3 当前实现与检查

已接入 Mac 地址栏的扩展菜单、按来源页打开／复用独立窗口、管理窗口入口与退出等待。原生接口使用可选 selector，旧运行时缺少能力时报告不可用；服务拒绝关闭、过期、其他 Host 服务或正在被 Viewer 控制的页面。旧 Host 对应的 Viewer 本地浏览器隐藏并拒绝该入口，不能将远端操作落到本机 profile。原有内嵌页继续保留。

当前检查：原生实现针对固定 SDK 的 Objective-C++ 语法检查通过；`AgentBrowserDevToolsTests`、`PaneBrowserOpeningTests`、`RemoteBrowserControlTests`、`AgentBrowserRoutingTests` 共 48 项定向 Swift 测试通过；既有原型的 21 项 Python 测试及品牌／技术边界检查通过。产品 App 的原生交互、打包和三端安装管理尚未验收，这些检查不能替代它们。

另已使用固定 Chromium CRX3 格式构造签名覆盖的数据，通过 OpenSSL 验证上述 ENV 包携带的两份 RSA 和一份 ECDSA 签名，并核对开发者公钥哈希与扩展 ID 一致。证据为 `.build-local/diagnostics/browser-extension-source/crx-verification.json`；这是对样本的独立验证，不等于商店审核结论。随后完成的产品内校验和损坏包回归见第 9.4 节。

### 9.4 导入包校验

已新增 [CRX3 校验](../CtrlxPackage/Sources/CtrlxServerFeature/Services/BrowserExtensions/BrowserExtensionCRX.swift)与 [ZIP 解包／权限预览](../CtrlxPackage/Sources/CtrlxServerFeature/Services/BrowserExtensions/BrowserExtensionPackage.swift)。解压使用固定版本 ZIPFoundation 0.9.20，依赖和许可证已登记。

- 压缩包上限 64 MiB，解包总量 256 MiB，单文件 64 MiB，manifest 1 MiB，条目数 10,000。实际流式解压也检查大小及 CRC，不能仅信任 ZIP 声明。
- 拒绝路径穿越、绝对路径、链接、重复／大小写冲突路径、文件与目录冲突、加密或截断条目；当前不接收 ZIP64 和分卷 ZIP。失败清理本次新建的暂存目录，不覆盖已有目录。
- 支持根目录 manifest 或单层外包目录；首版要求 Manifest V3。预览包括版本、来源、哈希、必需／可选权限、站点权限及 content script 匹配范围；本地化名称读取 default locale。
- CRX3 用系统 Security API 验证 RSA PKCS#1 SHA-256／ECDSA P-256 SHA-256，验证全部证明，并核对开发者公钥哈希与扩展 ID。导入暂存副本补入已验证的 manifest `key`，让 unpacked 加载保持 CRX 的 ID；不修改脚本，不赋予商店来源或自动更新语义。ZIP 的声明 key 仍不等于签名。

新增 [包回归测试](../CtrlxPackage/Tests/CtrlxServerFeatureTests/BrowserExtensionPackageTests.swift)覆盖损坏签名、错误身份、多个证明、非法路径、符号链接、解压超限、伪造大小／CRC、加密条目、已有文件保留和权限预览。13 项测试已通过，其中额外通过显式环境变量提供上述真实 ENV 样本，产品校验器确认版本 `3.4.12`、签名、ID 和解包结果。正常无样本的运行会跳过该可选样本检查，不下载或提交第三方扩展包。

Host 的暂存／确认流程已开始接入，见第 9.6 节；多端上传流程尚未接入。包验证通过不是安装完成，更新失败和超时必须以运行时确认结果处理。

### 9.5 运行中加载路径

隔离原型确认：`developerPrivate.loadUnpacked` 的原生目录选择器不经过 CEF `CefDialogHandler`，不能依赖该回调自动选择已校验目录。该失败记录在 `.build-local/diagnostics/browser-extensions-2qhnie5h/`。

已验证的替代路径是在专用 `chrome://extensions/` WebContents 的原生拖放目标中放入一个 Host 管理目录，使用独立 NSPasteboard，不改动系统剪贴板，然后通过该页面的 `notifyDragInstallInProgress`／`loadUnpacked(useDraggedPath: true)` 完成加载。实际原型 `.build-local/diagnostics/browser-extensions-jhojyhyz/` 验证了运行中安装、内容脚本、实际请求头改写及 Chrome-style 页的当前标签／popup；未使用 `--load-extension` 启动加载。

产品原生管理接口位于 [BrowserExtensions.inc](../CtrlxPackage/AgentBrowser/BrowserExtensions.inc)，与 Agent 页面 CDP 隔离，限制安装目录为当前 Host profile 下 `CtrlXExtensions/packages`。管理请求串行执行；超过等待期限但 Chromium 尚未完成时，保留操作占用并明确报告结果未知，不能把超时等同于安装失败或回滚成功。管理窗口关闭／退出会结束等待。Swift 安装事务和 UI 接线见第 9.6 节。

实际产品管理实现已在隔离原型中完成安装、列表、启停、reload、页面／popup 和确认后卸载检查，最新证据为 `.build-local/diagnostics/browser-extensions-98iq174n/`，runner 及受管理产物包装均成功退出。`management.uninstall` 的 `showConfirmDialog: false` 不会取消卸载其他扩展时的原生确认要求，因此不将它视作无界面的卸载 API。CDP 消息编号使用 CEF 返回值，结果处理移到新的 UI task，兼容同步返回并避免重入 DevTools observer。

### 9.6 Host 包存储与本地管理界面

新增 [BrowserExtensionStore](../CtrlxPackage/Sources/CtrlxServerFeature/Services/BrowserExtensions/BrowserExtensionStore.swift)、[服务接线](../CtrlxPackage/Sources/CtrlxServerFeature/Services/BrowserExtensions/AgentBrowserExtensions.swift)和 [Mac 管理界面](../CtrlxPackage/Sources/CtrlxServerFeature/Views/BrowserExtensionsView.swift)，当前仍处于定向测试和原生验收阶段。

- 每次导入使用新的不可变包目录，另存安装凭据，不根据磁盘目录推断已安装状态。无 key 的 ZIP 生成公共 manifest key，更新时沿用它；这只稳定 ID，不把 ZIP 标为已签名。
- 预览确认后，再向运行时读取当前 ID、版本、路径和启用状态，拒绝未确认的同 ID 覆盖或已经变化的更新目标。提交前将凭据持久化，防止进程退出或超时后误删仍在加载的包。
- 成功由运行时的 ID、版本、路径和状态共同确认，再清理该事务的旧包。确定的更新失败会尝试恢复保留的旧包；原生操作仍在执行时拒绝重叠恢复，报告结果未知并保留文件。
- 本地管理界面提供商店链接、ZIP／CRX 导入、权限预览、列表、启停、更新、卸载和原生设置入口。Viewer／iOS 管理界面尚未完成。

包校验、存储及来源授权的定向测试已通过，包括 store 对象重建后恢复身份、无 key ZIP 更新保持 ID、拒绝未确认覆盖、拒绝伪造运行时路径和失败保留旧包。成功安装后的旧包清理与安装失败恢复分开处理，清理失败不得回滚已经确认的新版本；该补充已通过后续定向回归，未重复已通过的真实网络下载检查。

卸载测试曾因立即点击原生确认窗口、以及解除 popup 调试附着时迟于命令登记回调而超时。`.build-local/diagnostics/browser-extensions-ozmbq3pl/` 保留早期失败；修正测试顺序、等待确认窗口稳定后，对当前隔离进程中精确匹配的 fixture 弹窗发送点击，最终以运行时列表不再包含扩展确认成功。测试专用点击代码不进入产品，不代替用户确认真实扩展卸载。

### 9.7 商店下载与手动更新

[商店下载入口](../CtrlxPackage/Sources/CtrlxServerFeature/Services/BrowserExtensions/BrowserExtensionWebStore.swift)接受当前 Chrome Web Store 详情链接或扩展 ID。Host 原生运行时返回实际 Chromium 版本，下载端据此向 Google 更新服务请求 CRX3。使用不共享 Cookie、凭据或缓存的 URLSession；只跟随允许的 Google HTTPS 下载域名，按实际流量限制 64 MiB，并设置请求／资源超时。

包下载后仍须经过完整 CRX3 验签、开发者 ID 检查、解包校验和用户权限确认。若下载的签名身份与原始商店链接不匹配，拒绝导入。商店包与本地包互相替换时，预览明确显示来源变化。

首版复用已验证的受管理 unpacked 加载通道，因此 UI 明确提供手动“Update → Check Chrome Web Store”。这不等于 Chrome 原生商店安装信任标记，也不启用后台自动更新。原生商店安装按钮／自动更新保持未验收，不把取得 CRX 当成运行时安装成功。

通过显式 `CTRLX_EXTENSION_DOWNLOAD_TEST=1` 运行真实网络检查，下载上述 ENV-Plugin，取得 4,265,252 字节并通过产品验签器确认 ID；该轮共 31 项测试、4 个 suite 通过。正常 CI 不自动联网；需要运行该检查时显式开启。该下载检查本身不证明运行时功能；后续真实 ENV 的 popup 证据与验收状态见第 9.8 节。

### 9.8 真实 ENV 运行时验收进度

使用产品 CRX3 校验器导出的 ENV-Plugin `3.4.12`，在隔离签名 App 与新建私有 profile 中，通过实际产品管理接口安装。运行时返回正确 ID `imebogohheacbbmhfiiddakclhifpbde`、版本和启用状态；真实 action popup 能打开，其 `active/currentWindow` 查询命中本次来源网页。已采集并查看 popup 截图。基础证据为 `.build-local/diagnostics/browser-extensions-b1ickvic/`，后续 DOM 检查为 `browser-extensions-t83de77x/`。

原生验收脚本现支持通过真实 popup 配置请求头，逐项检查服务器收到的启用／暂停／恢复结果，以及在完整 CEF 退出后以同一测试 profile 重启、检查保存配置和规则效果。脚本不会直接改写第三方扩展的 storage 或源码，也不会修改生产浏览器或系统 Chrome。最新证据 `.build-local/diagnostics/browser-extensions-lkxvnypv/` 中，规则启用／暂停／恢复均由本机 HTTP 服务收到的请求头确认，重启后的 ID、配置和请求头效果也通过，两个进程均正常关闭 CEF；重启 popup 截图已查看。native messaging 助手未安装或授权，debugger 共存、多网页来源切换和远端交互仍未验收，不能外推为 ENV 全功能兼容。

新增的 ZIP 更新原型从产品 `BrowserExtensionStore` 导出两版测试包，验证生成的 manifest key 是否被 Chromium 解释为同一 ID，以及运行时能否在不可变目录间升级／恢复。导出检查的 5 项存储测试已通过；原生证据 `.build-local/diagnostics/browser-extensions-2tw1ba0z/` 确认生成 ID 一致、版本 1 → 2 → 1 → 2 及各次目录正确，随后内容脚本、实际请求头、popup 与确认卸载也通过。这验证了原生升级／恢复机制，服务层自动失败恢复的单独回归见第 9.10 节。可复现命令见 [原型说明](../experiments/cef-browser-probe/README.md#browser-extension-characterization-2026-10-16)。

最新完整定向回归为 32 项测试、4 个 suite 通过，包含真实 ENV 包校验与 TERMINATED 状态不能当作停用成功的回归。一次初始运行因传入相对样本路径而失败，改为绝对路径后通过；这不是跳过失败测试。可选真实网络下载未重复运行。

### 9.9 远端原生窗口表面的原型

已完成当前进程窗口采集的独立原型：使用 macOS 14.4+ 的 `SCShareableContent.currentProcess`，只选取与来源 Chrome 窗口的 `windowNumber`、本进程 PID 一致的窗口，再用 ScreenCaptureKit 的 `includeChildWindows` 采集。未请求整个桌面或其他应用的窗口。原型证据 `.build-local/diagnostics/browser-extensions-xnha4_bh/` 中，ENV popup 的原生 `parentWindow` 精确指向来源 Chrome 窗口；`native-popup.png` 已人工检查，包含 Chrome 工具栏、来源网页和真实 ENV popup。

后续原型 `.build-local/diagnostics/browser-extensions-sew1jmno/` 已通过原生鼠标输入检查：从来源窗口及其 `childWindows` 定位 ENV popup，发送原生点击到“暂停”按钮，扩展的暂停状态和测试 HTTP 服务收到的请求头同时确认生效；`native-popup-paused.png` 已查看。输入没有经过全局桌面事件，也没有通过 JavaScript 修改规则状态。

原生管理窗口的确认框单独通过了检查：`.build-local/diagnostics/browser-extensions-xbb37obh/` 确认卸载弹窗属于精确的管理窗口，采集包含该弹窗的画面，并通过同一窗口树点击测试扩展的 Remove；运行时返回扩展已不存在，CEF 正常退出。测试只确认本次私有 fixture，不替用户确认真实扩展的卸载。

这仍是原型能力，不是远端产品已接入。产品必须为扩展／profile 操作单独取得控制权，不能把已有页面控制租约升级为整个浏览器的管理授权。旧 Viewer、过期画面、来源窗口变化、Host 收回控制、断线、文本和按键等情况仍需实现与验收。该方向沿用已批准的 CtrlX 独立扩展窗口，不向 Agent 页面网关开放全局 CDP、任意目标发现或其他应用输入。

### 9.10 Mac 构建与安装事务回归

`./scripts/package-local-macos.sh --app-only` 已完成 Release Mac App 编译、原生浏览器链接和签名验证；未安装或替换生产 App。实际界面验收使用独立 bundle ID、私有 profile 与 tmux socket 的测试副本，尚待完成。

补充运行 `./scripts/unit-tests.sh -- --filter AgentBrowserDevToolsTests`，13 项测试通过，其中失败更新恢复分别覆盖原扩展启用／停用两种状态；另覆盖原生超时结果未知时不并发回滚，以及旧包清理失败时保留已经确认的新版本。这些是服务层事务回归，和第 9.8 节的实际 Chromium 升级／恢复验证分别记录。

### 9.11 管理窗口焦点、双窗口与 debugger

实际 Mac UI 检查发现：第一次请求扩展列表会把原生 `chrome://extensions` 窗口放到 SwiftUI 管理面板前方；新建扩展窗口也可能被随后选中的主窗口覆盖。原生管理窗口现在在创建后明确隐藏；安装所需的原生拖放要求窗口可见，因此安装期间在面板后方显示，结束后恢复隐藏。启用和卸载可能需要原生确认，临时显示后恢复原窗口。`CefWindowInfo.hidden` 仅控制视图，实测不能隐藏 Chrome 顶层窗口。Swift 服务在新建窗口的选择回调结束后再次显示对应窗口，相关服务测试通过。

隔离原型 `.build-local/diagnostics/browser-extensions-fo5be9mn/` 已验证创建管理器、安装、禁用、启用、重载结束后管理窗口隐藏且来源窗口保持焦点；卸载确认仍可见且可操作，退出完整。两个 Chrome 窗口分别打开 `/chrome-other`、`/chrome`，扩展查询、popup 回报与实际请求头均命中各自来源页面。`popup.png` 已查看：从顶层窗口采集、包含正确 popup；直接采集子窗口会把父窗口画面缩入子窗口尺寸，因此原型已禁止该用法。

真实 ENV 的 `.build-local/diagnostics/browser-extensions-chs9gpq3/` 验证 `chrome.debugger.attach` 与既有 CEF 页面 CDP 同时工作；等待原生 DevTools 窗口真正加载且可见后，扩展调试连接及页面 CDP 仍可访问精确来源页，退出完整。这只是 API 级共存验证，不等于 ENV 的 Data Mock、MCP 或 native messaging 全部可用。

实际 App UI 还完成 ZIP 选择、权限预览、安装确认、禁用、独立窗口关联与 Show Window。首次测试副本出现网页加载超时；保留签名元数据并使用独立 mock-keychain profile 的第二轮能加载并显示 Chrome 窗口测试页，尚未证明普通 Keychain 配置下不存在问题。部分原型仍记录 CEF `browser_info_manager` 超时，即使检查最终通过也保留为待定位现象。上述原生焦点修正尚需在重新编译的完整 App 内复验；Mac 产品及多端验收继续保持未完成。

### 9.12 远端页面控制的兼容边界

`RemoteBrowserTab` 增加可选 `isExtensionWindow` 标记；旧 Host 缺少该字段仍可解码。新 Viewer 不会为扩展兼容窗口自动申请普通网页控制，Host 拒绝这类窗口的旧 `.takeControl` 请求，仍允许读取页面画面。这避免旧版 Viewer 的页面 Fit 改动 Chrome 原生窗口，也避免把普通页面租约当作 profile 管理授权；专用扩展控制尚未接入。

`./scripts/unit-tests.sh -- --filter 'RemoteBrowser(Control|Protocol|Session)Tests'` 的三个 suite 共 31 项测试通过，覆盖新增字段往返／旧字段缺省、Viewer 不自动接管、Host 拒绝旧控制且保留只读画面。品牌与技术边界检查通过，原型目录的 21 项 Python 测试通过。未据此宣称 iOS 已编译或远端扩展 UI 已可用。

### 9.13 原生弹窗文字与编辑输入

`.build-local/diagnostics/browser-extensions-d7n7t38o/` 已完成真实 ENV popup 的原生输入检查：点击 Search Env 输入框，等待 DOM 确认该字段获得焦点，通过所属窗口的 `NSTextInputClient` 插入 `CtrlX 中文输入`，再全选并删除；运行时读取字段确认每步结果，同时验证另一个来源窗口无法向当前 popup 写入。`native-popup-keyboard.png` 已查看，CEF 完整退出。暂停按钮及实际请求头恢复检查也包含在同次运行中。

原型发现不能只在发送鼠标事件后立即写入文字：Chromium 的字段焦点更新是异步的。也不能把没有 Edit 菜单的探针 App 中的合成 Cmd+A 当作全选已执行；全选现在向同一输入 responder 发送 `doCommandBySelector(selectAll:)`。这与固定版本的 [Chromium 原生编辑命令路径](https://github.com/chromium/chromium/blob/152.0.7977.134/content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm)一致，实际效果由测试字段验证。当前证据覆盖点击、Unicode 插入和全选／删除，不包括所有修饰键、拖动或滚轮组合。

### 9.14 远端接入基础（仍未开放）

已增加 `RemoteBrowserOperation.extensions` 的类型化命令、独立能力字段 `supportsBrowserExtensions`、无 Host 路径的扩展列表／权限预览响应，以及每控制 grant 一份的私有包上传 actor。上传复用 `HostFileUploads` 的分块、校验和与原子发布检查，将压缩包限制为 64 MiB，Viewer 文件名只用于识别 ZIP／CRX，不作为 Host 路径使用。

新增上传与 wire 检查已运行：`BrowserExtensionUploadTests` 4 项、`RemoteBrowserProtocolTests` 12 项全部通过，覆盖包大小、错误 token、校验和失败、取消清理及新旧协议往返。首次 wire 测试因测试夹具遗漏旧协议必需的 `homeDirectory` 字段失败，补齐夹具后重跑通过。

这一部分仍是接入中的代码：Host 尚未宣告新能力，尚无完整扩展 grant 处理器、原生表面传输或 Mac Viewer／iOS 管理 UI。不能将新 wire 类型或上传单测当作多端功能已完成。原生桥接的专用控制／表面方法已声明为可选，只有实现并通过兼容检查后才可宣告支持。

### 9.15 扩展窗口控制与远端界面接入（待完整验收）

在第 9.14 节基础上已接入独立的扩展控制租约：绑定 Viewer、界面 ID、来源标签和控制 ID，20 秒过期；原有网页租约不能升级成此权限。来源关闭、断线、过期和 Host 收回控制会释放租约。包上传及权限预览绑定本次租约，断线清理未提交的包，已提交 Chromium 的目录保留以核实真实结果。Host 收回控制后，原生层首先拒绝旧请求，Swift 注册表在下次请求同步释放。

原生 `ExtensionSurface.inc` 使用当前进程窗口采集，只接受精确来源窗口及其子窗口的输入；画面绑定窗口几何版本。窗口移动、表面切换或租约改变后的旧请求不能用于新窗口。原生键盘仅允许文字及有限编辑按键，不把 Cmd+V 转发到 Host 剪贴板，不转发应用退出等菜单快捷键。采集回调纳入关闭屏障。

`.build-local/diagnostics/browser-extensions-533lrmys/` 使用实际产品表面代码，通过真实 ENV 的截图、点击、Unicode 输入、全选删除、错误租约、移动前画面和撤销后输入检查；`product-native-surface.jpg` 已查看。之后增加“其他窗口成为 key window”的检查时，发现输入调用可以返回成功但字段无变化，记录在 `.build-local/diagnostics/browser-extensions-f39yg69n/`。已调整为恢复明确点击的所属窗口并直接向该窗口发送按键。首次复验 `.build-local/diagnostics/browser-extensions-cj0humif/` 在管理页初始化阶段出现既有 CEF browser-info 超时，未进入新增输入检查，最终由隔离测试的进程组超时清理；不能算输入修正通过。随后使用同一原生行为版本、全新私有 profile 复验，`.build-local/diagnostics/browser-extensions-3czo20nl/` 完成了该焦点切换检查以及完整产品表面检查，CEF 正常退出；先前初始化失败的证据仍保留。

Swift Host 定向检查已通过 15 项（`BrowserExtensionControlTests` 与原网页控制 suite）；随后 shared UI 的 Mac 条件代码编译通过，并运行 20 项 Host／共享会话／包存储检查。覆盖不同 Viewer／界面隔离、独立权限、Host 收回、过期、断线中的迟到截图、来源关闭，以及旧租约的上传预览不可用于新租约。最新补充的检查也已通过：Host 扩展控制 5 项，共享原网页与扩展会话 13 项；包含显式接管、切换原生页面后保持来源 ID、Host 收回后重新接管，以及旧租约迟到画面不能释放新租约。

Mac Viewer 与 iOS 共用管理界面已接入商店链接、ZIP／CRX 文件上传、权限确认、更新、启停、卸载及原生窗口切换，复用既有画面解码和输入组件。Host 能力字段已接入运行时可选方法检查。**代码接入和 Mac 条件编译不代表多端产品验收完成**：iOS Simulator 的 Debug 构建现已通过（arm64 与 x86_64）；首次依赖解析因 GitHub 连接失败中止，改用本 worktree 已有 SourcePackages、锁定版本并跳过远端更新后成功。完整 Mac App 焦点／生命周期、iOS 界面、实际多端控制及原生滚动／拖动仍需验证。

### 9.16 完整 Mac App 与私有 Relay 的界面验证

完整 Release App 编译与签名验证通过。使用独立 bundle ID、私有 tmux、mock-keychain profile 和临时本地 Relay，第四轮界面验证完成 ZIP 选择、权限预览、安装、管理面板焦点保持，以及扩展窗口自动前置。真实 Mac Viewer 配对后，能够显式申请扩展控制、列出 Host 扩展、获取完整原生窗口画面、调整窗口尺寸，并通过画面打开 Chromium 工具栏扩展菜单及 popup。两份测试 App 均正常退出；仍有失败项，本轮没有标记为完整验收通过。记录位于 `.build-local/diagnostics/browser-extension-source/ui-review-fourth.json`。

真实输入发现：地址栏自动补全会改变子窗口布局，原来的统一画面代次校验因此拒绝后续文字并释放控制。原生层现将文字／编辑键绑定到明确点击的所属窗口；仅在来源根窗口及其位置尺寸仍一致、代次来自本次有效窗口时允许继续输入。坐标点击仍要求完整子窗口布局一致；过期的无按钮悬停直接丢弃，不中断控制。根窗口移动、切换、关闭或租约撤销仍拒绝旧输入。`.build-local/diagnostics/browser-extensions-ej7i9xdn/` 已验证真实 ENV 字段在新增子窗口后仍可写入中文、全选删除，旧点击被拒绝、旧悬停被忽略，原生退出完成。第五轮完整 App 已通过地址栏输入、自动补全展开和 Return 导航，控制没有再次中断。

第三轮在尚未打开扩展管理界面时发生 AppKit `NSGenericException`／工具栏约束布局循环，崩溃报告为 `CtrlX-2026-10-16-144152.ips`。第四轮相同构建能打开浏览器并完成上述路径，但不能据此证明崩溃已修复。普通 Alloy 内嵌页空白与 CEF `browser_info_manager` 超时也继续保留为待定位现象；原生 Chrome 窗口和远端窗口画面正常不等于这些问题已消失。

第五轮使用同一修复后的 Release App 与私有 Relay，另验证 Mac Viewer 的原生窗口 Fit、聚焦后的文字输入及页面 `isTrusted` 事件；独立 iOS Simulator 完成配对、获取扩展控制、读取列表、显示 Chromium 设置与扩展页面，并成功插入中文。Host 接管后，原 Mac Viewer 明确退出控制。单击在 Mac Viewer 上没有切换焦点、双击可以，仍在定位；不能据此认定点击体验通过。iOS 发起真实商店下载遇到 TLS 连接失败，错误已展示，在线安装尚未通过。初次 Mac 列表曾返回管理页已关闭，后续 iOS 列表成功，生命周期仍需复查。

第五轮检查记录为 `.build-local/diagnostics/browser-extension-source/ui-review-fifth.json`，真实输入证据为相邻 `ui-fifth-input-events.jsonl`。本轮测试达到 harness 的 20 分钟上限后退出，保留失败标记；两份隔离 App 随后通过正常退出操作关闭，私有 Relay、tmux 和自有 Simulator 均已清理或关闭，未标记完整验收成功。

第六轮完整 App 中，Mac Viewer 成功上传官方 ENV CRX、显示签名／权限预览并安装 3.4.12；原生工具栏可打开 ENV popup，页面记录了完整的可信拖动事件。本轮 Host 处于 active 时单击正常，临时记录确认 clickCount=1；第五轮间歇焦点现象仍需覆盖 Host 非前台。发现两项明确问题：内层滚动误作用到整页；popup 超出小根窗口后，截图自动调整输出图像，原有根窗口尺寸坐标映射失配。这两项未修复前不能宣告远端原生窗口体验完成。临时输入日志已从产品源码移除。

商店下载在完整 App 中仍失败；CFNetwork 日志显示现有系统 HTTP/SOCKS 代理分别在 TLS 握手等待约 10 秒后关闭连接（-9816/-1200）。同机独立 Foundation 请求和显式使用同一 HTTP 代理的 curl 均曾成功，因此继续保留 App 路径失败证据，不降低 TLS 校验或修改用户代理设置。第六轮为部分验收，未写入成功标记；隔离 App 与相关进程均已结束。记录为 `.build-local/diagnostics/browser-extension-source/ui-review-sixth.json`。

### 9.17 弹窗边界与滚轮坐标回归

滚轮诊断 `.build-local/diagnostics/browser-extensions-ifakprc8/` 确认：直接创建 CG 滚轮事件后转换的 NSEvent，其 windowNumber 为 0，locationInWindow 是屏幕位置；设置 WindowUnderMousePointer 并不能绑定 AppKit 窗口。产品改用携带目标窗口／局部坐标的 NSEvent 生成 CGEvent，再改为滚轮事件并设置像素增量，仅发送到所属视图，不向系统投递事件。参见 [Apple 坐标说明](https://developer.apple.com/documentation/appkit/nsevent/locationinwindow)。

原生截图尺寸与输入坐标现统一采用根窗口和可见子窗口的并集，避免 popup 超出根窗口后发生图像缩放与坐标失配。并集中的空白区域不接收输入。新增 `SurfaceGeometryProbe.inc` 使用自有 AppKit 窗口验证超界子窗口的截图像素位置、字段输入及内层滚动；真实 ENV 产品表面回归仍一并执行。

`.build-local/diagnostics/browser-extensions-uj0qw0mj/` 已完成上述回归，内层滚动从 0 移到 100，超界窗口像素与点击匹配，真实 ENV 请求头启停及原有租约／键盘检查通过，原生正常结束。首次新增检查 `.build-local/diagnostics/browser-extensions-9u0v8__j/` 因要求 App 保持 inactive 失败；桌面在 deactivate 后仍显示 active。因此测试仅验证实际覆盖的几何、输入和滚动，另返回 `inactiveBeforeInput`，本机值为 false，不能据此宣告后台焦点通过。完整 App 的小窗口 ENV popup 和滚动复验仍待执行。

### 9.18 完整 App 输入复验与进程相关下载阻塞

第七轮完整 App 复验确认内层滚动修复生效，测试页记录可信的 scrollTop 0 → 625；同时再次复现 Host 非前台时首次点击被用于窗口激活，输入框和扩展工具栏没有收到操作。原生层现先使已授权的精确目标窗口成为 key window，再直接向该窗口派发鼠标事件，沿用既有输入范围和租约校验，不向系统投递全局事件。

原生回归 `.build-local/diagnostics/browser-extensions-a5evyaa5/` 通过真实 ENV、焦点恢复、租约隔离、超界 popup 和滚动检查，CEF 完整退出。随后重新构建的 Release App 在第八轮中通过首次单击输入（页面记录 `isTrusted`）、单击打开扩展菜单、ENV popup 超出 720×401 根窗口后的字段点击与输入、全选删除／Escape，以及内层滚动。重用私有 profile 后 ENV 3.4.12 仍启用。记录为 `.build-local/diagnostics/browser-extension-source/ui-review-eighth.json`，弹窗截图和真实输入事件在同目录。两份隔离 App、私有 Relay 和 tmux 均已正常结束；整轮仍不标记验收成功，因为在线商店安装未通过。

用户开启 Surge 增强模式后，16:12:48–16:13:08 的完整 App 请求仍经本地 6152／6153 代理失败，日志包含 utun9，最终为 -1200／-9816。用户在对应时段的 Surge 请求查看器中未找到 clients2 域名。独立 Foundation 请求使用相同的异步重定向委托能够下载完整 4,265,252 字节包，排除了单纯由委托导致失败的假设。

进一步将独立下载检查编译一次，再复制为 `CtrlX` 与 `NetworkCheck` 两个文件，二者 SHA-256 均为 `6f1bebcf803b7daa3744892c0580cc0ce25aa8b3ac09c4ad391897a312fc5448`。按 CtrlX → NetworkCheck → CtrlX → NetworkCheck 顺序运行，前者均超时，后者均取得官方重定向及 HTTP 200。证据在 `.build-local/diagnostics/browser-extension-source/network-process-check/`。这将问题缩小到进程身份相关的本机网络处理，但尚未确认具体 Surge 规则或其他实现原因；没有修改用户代理配置，也没有降低 TLS 校验。需要排除该环境差异后，再用正常 CtrlX App 完成商店下载、预览和安装验收。

最新 Mac Release 构建及签名检查、iOS Simulator 双架构编译均通过。上述本机证据不等于所有扩展兼容、真实跨机器发布验收或 ENV native messaging 验收；第 9.16 节保留的既有 CEF 初始化／AppKit 异常也没有据此被标记为已修复。

### 9.19 删除进程 DIRECT 规则后的商店验收

用户确认 Surge 存在匹配进程名 Ctrlx 的 DIRECT 规则并自行删除。随后原名 `CtrlX` 的独立程序取得官方重定向及 HTTP 200；未改动下载实现、TLS 校验或系统代理设置。

继续使用第八轮同一份已签名 Release App、全新私有 profile，在实际 Mac 界面完成：商店链接下载 ENV 3.4.12 → CRX3 验签与权限预览 → Install → 运行时列表显示 Enabled；随后 Update → Check Chrome Web Store → 再次下载／预览 → Update → Enabled。商店当前仍提供 3.4.12，因此本轮证明同版本替换，不冒充新版本升级；跨版本 ZIP 更新和失败恢复证据见第 9.8、9.10 节。最终只保留一份受管理 receipt，来源为 `webStore`、扩展 ID 正确。

证据位于 `.build-local/diagnostics/browser-extension-source/ui-review-store.json`、`ui-store-preview.jpg`、`ui-store-installed.jpg` 和 `ui-store-final-receipt.json`。App 正常退出、私有 Relay 和 tmux 已停止，受管理验收命令退出码为 0。至此解除商店在线安装的网络验收阻塞；生产 App 和用户 profile 未被替换。

最终品牌／技术边界和 diff 空白检查通过。32 份变更 Swift 文件的格式检查中，30 份通过；`RemoteBrowserView.swift` 和 `ConnectedViewer.swift` 沿用原有未格式化风格，基线文件用相同配置检查也失败，未为清除告警而整文件重排。构建、定向测试和界面证据按前述分项记录，不将格式检查描述为全通过，也未重跑与本次环境修正无关的全量测试。

## Cross-origin header compatibility

2026-10-21，产品基线 `7d1d9dd`，CEF
`152.0.8+g1ce985c+chromium-152.0.7977.134`。使用同一官方 ENV-Plugin
3.4.12 样本，通过真实 popup 配置 `x-maas-env: ark-chat-dev`。
隔离服务器确认同源注入成功，但跨域 GET、JSON POST、script 和重定向的
预检携带 `x-maas-env`，因服务端未允许该头而失败；Alloy 与 Chrome-style
均受影响。没有修改用户 profile、第三方扩展或 CORS 安全设置。

CEF 的 `ChromeContentBrowserClientCef::WillCreateURLLoaderFactory` 向 Chrome
传入空 `header_client`，随后安装自己的 header client；Chrome 扩展因此无法
使用 trusted header 回调。Chromium 在这一回调不可用时，将扩展请求头修改
提前到启动网络请求之前，触发额外的 CORS 检查。诊断对照普通 Chrome 的部分
来自用户反馈；本轮原生实测对照是两种 CEF 窗口，并非系统 Chrome。

候选补丁为
[`extension-header-client.patch`](../CtrlxPackage/AgentBrowser/cef-patches/extension-header-client.patch)，
基于完整 CEF commit `1ce985cb23056548b9cc51483bbef4faf68b1cd3`：

- 保留并串接 Chrome 的 factory／request header client，跨 UI／IO 线程传递
  pending remote，每次 network loader 创建时重新绑定。
- 普通请求先由 Chrome 扩展处理，再让 CEF 看到最终请求／响应头；保留响应头
  修改、重定向参数、扩展错误及断开回调，不以默认成功覆盖失败。
- 预检回调转交 Chrome；没有 Chrome header client 时保持 CEF 原路径。
  CEF 自定义响应也沿用相同的回调绑定。没有关闭 CORS 或增加网站白名单。

补丁尚未编译；**不是已生效的产品修复**。当前构建脚本仍下载原来的预编译
CEF SDK，仅重新构建 CtrlX 或原型 App 不会使补丁生效。准备完整且版本匹配的
CEF/Chromium 源码构建树后，从本仓库根目录执行：

```bash
CTRLX_ROOT="$PWD"
CEF_SOURCE='/path/to/chromium/src/cef'
test "$(git -C "$CEF_SOURCE" rev-parse HEAD)" = '1ce985cb23056548b9cc51483bbef4faf68b1cd3'
git -C "$CEF_SOURCE" apply --check "$CTRLX_ROOT/CtrlxPackage/AgentBrowser/cef-patches/extension-header-client.patch"
git -C "$CEF_SOURCE" apply "$CTRLX_ROOT/CtrlxPackage/AgentBrowser/cef-patches/extension-header-client.patch"
```

随后依照 [CEF 官方构建流程](https://github.com/chromiumembedded/cef/blob/master/docs/master_build_quick_start.md)
生成 arm64 runtime。接入前须使用该 runtime 重建隔离原型并通过 `--cors`
门槛，随后完成嵌入生命周期、扩展管理和产品原生构建验收；最后才更新产品
与原型共用的 SDK 来源及完整性校验。不能把候选补丁与旧 SDK 一起发布为修复版。

本轮证据：

| 检查 | 结果 |
| --- | --- |
| 补丁对固定版本源文件 `git apply --check` | 通过；不等于 C++ 编译 |
| 更新后的原型可执行文件构建、签名验证 | 通过；仍链接原 SDK |
| 原有 `--production-admin` 扩展验收（无 `--cors`） | 通过 |
| 最小 DNR 扩展 `--production-admin --cors` | 按预期失败，暴露旧 runtime 缺陷；同源和管理检查通过 |
| 真实 ENV `--env-scenario … --cors` | 按预期失败；popup 配置、启用／暂停／恢复通过 |
| 修复版 CEF 编译及上述用例转绿 | 未完成：缺少可容纳完整源码构建的环境 |

可复现命令见[原型说明](../experiments/cef-browser-probe/README.md)。失败证据位于
`.build-local/diagnostics/browser-extensions-7hma1dg0/` 和
`.build-local/diagnostics/browser-extensions-dvn3bb2s/`。`--cors` 会校验服务器
实际收到的头和预检列表，验证需要的 POST 预检仍存在、普通网页无授权的跨域
请求仍被拒绝（包括网页自己添加 `x-maas-env`）；失败会使进程退出码非零，
不再把“观察完成”当作此项兼容通过。
