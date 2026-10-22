# Android 自动化调研、验证记录与后续建议

初始方案：2026-10-14；实测与清理记录截至 2026-10-17；文档汇总：2026-10-18。本次汇总复用已有证据，没有新增登录尝试、启动设备或开通云资源。本文同时保留原始最小验证方案与分阶段记录；历史章节中的“下一步”、预算和环境保留状态只适用于当时，当前状态以本节和[清理记录](#2026-10-17-空间清理与保留环境)为准。

## 当前结论总览

**Android 单设备基础控制已验证；美团完整登录及两次自主加购尚未通过；CtrlX Android 产品集成尚未实现。** 原 Google APIs AVD 和 Podman / redroid 均取得错误 `121118`／“当前有问题，请用手机访问”，具体拒绝规则仍未知。当前只保留原 Google APIs AVD 及其数据，redroid 和 Google Play 对照环境已按用户要求删除。

| 路线或尝试 | 实际完成的验证 | 结论与当前处置 |
|---|---|---|
| Google APIs AVD + ARTEMIS | Android 15 / ARM64；官方美团可安装；截图、层级、点击、滑动、中文输入及模型视觉／工具调用探针通过 | 保留为后续开发验证环境；探针通过不等于 ARTEMIS 自主任务完成 |
| 本机摄像头与网络对照 | 通过 Terminal 的正常摄像头授权取得持续帧；测试 AVD 代理可使系统网络变为 `VALIDATED`，登录仍失败 | 已解决该启动方式下的摄像头黑屏；未解决美团验证。Mac 网络与 CtrlX 安装未替换 |
| Google APIs AVD 错误取证 | 先记录自然失败，再只读提取当前弹窗错误：`121118`／“当前有问题，请用手机访问” | “网络不好”是通用文案；没有查明服务端具体拒绝条件 |
| Google Play 发布镜像 | 实测 `user/release-keys`、`ro.debuggable=0`，相机持续产帧；仍出现同一通用提示与 SDK 分类 `703` | 非调试镜像未解决登录；未取得本环境原始业务错误码。设备、数据及专属镜像已删除 |
| OrbStack / Podman + redroid | OrbStack 当时内核未发现 Binder 支持；改用独立 Podman 虚拟机后，容器、ADB、scrcpy、基础操作及游客页面可用 | 证明本机容器路径可运行 Android；未验收延迟、帧率或多开容量。专用虚拟机与数据卷已删除 |
| redroid 摄像头与登录 | 注册虚拟摄像头因缺少 `GL_EXT_YUV_target` 失败；摄像头为零时，正常登录仍取得原始错误 `121118` | 当前 redroid 配置没有解除业务拒绝；摄像头适配暂缓，接好摄像头不是取得这次失败证据的前提 |
| 云手机、Genymotion、Anbox Cloud | 仅完成官方资料与部分源码调研 | 均未完成本账号的登录／加购实测；云手机保留为候选对照，Genymotion 未部署，未同步完整 AOSP 或部署 Anbox Cloud |

结论边界：

- `121118` 来自已显示弹窗持有的错误对象，并非截获的完整 HTTP 响应。`703` 是 SDK 服务端错误分类，`707` 是相机错误分类；它们都不能当作 HTTP 状态或替代原始业务错误码。
- 美团包含模拟环境识别代码，不等于已证明那段代码导致此次拒绝；两种环境同码也不证明命中同一条规则。账号、设备构建、网络出口及组合条件仍未排除。
- redroid 默认保留自身品牌、硬件和调试构建特征，容器架构不自动提供“无法识别为模拟设备”的能力；审阅范围内没有发现针对美团该错误的专门修复。测试未修改设备身份、认证返回值或注入替代人脸内容。
- 云手机公开案例与摄像头转发能力提供了后续调查线索，不能保证当前账号可通过认证。此前没有合适的 Android 真机，真机对照未执行；未安装微信完成替代验证。

继续工作先读[后续建议与验收边界](#后续建议与验收边界)，复查结论先读[关键证据索引](#关键证据索引)。各次过程、版本、失败及停止情况保留在下方执行记录。

## 目标与范围

以下为 2026-10-14 的原始单设备方案；后续追加调查及预算调整见各日期记录，不表示这些操作仍在运行。

用一台 Android 模拟器运行官方美团 App，让 ARTEMIS 完成“搜索餐品 → 打开商家 → 加入购物车 → 核对商品与数量”，判断是否值得接入 CtrlX。

本轮只验证单台设备、一个应用、一条任务，结束在购物车，不提交订单或付款。CtrlX 集成、多开、远程 Viewer 和性能优化留到验证通过之后。

## 最小环境

| 项目 | 选择 |
|---|---|
| 宿主 | 当前 Apple Silicon Mac；预查剩余约 34.8 GiB，执行前重新检查 |
| 已有工具 | `adb`、`uv`、`ffmpeg`；未发现已安装的 Android SDK、模拟器或 AVD |
| 模拟器 | 官方 Android Emulator，单台 Android 15 / API 35 / `arm64-v8a`，Google APIs 镜像 |
| 初始配置 | 2 核、3 GiB 内存、720p，启用硬件加速；关闭快照，保留设备用户数据 |
| 自动化 | 固定 ARTEMIS 提交，独立 Python 3.12+ 环境，通过 CLI 使用 Flash 模式 |
| 文件位置 | 当前 worktree 的 `.build-local/android-artemis-validation/`，集中保存 SDK、AVD、环境和证据 |

执行前确认 ARTEMIS 所需模型 API 可调用，包括所选路径的视觉模型；密钥通过本地配置提供。只安装命令行 SDK、单份镜像和运行依赖，按需补齐 Java、scrcpy。Android 15 是本轮选定的验证基线，不代表项目已保证其兼容性。

## 执行步骤

排查与操作预算合计 **90 分钟**，下载和等待用户登录的时间单独记录。

| 步骤 | 预算 | 操作与通过条件 |
|---|---|---|
| 1. 准备环境 | 30 分钟 | 确认模型 API，安装最小工具集，创建单台 AVD。硬件加速检查通过，设备启动完成，ADB 可连接并截图。 |
| 2. 确认美团可用 | 15 分钟 | 从官方渠道安装美团 APK，打开外卖页面；需要时由用户完成登录、验证码和位置选择。能浏览商家与商品后再继续。 |
| 3. 验证基础控制 | 20 分钟 | 独立运行 ARTEMIS，验证截图、界面读取、点击、滑动和中文输入。先用默认 Accessibility Helper；失败时仅尝试一次 UIAutomator2 路径，记录实际后端。 |
| 4. 执行实际任务 | 20 分钟 | 运行目标选餐加购流程两次。每次从约定首页开始，恢复本轮测试购物车状态；核对最终商品、数量和截图，并记录耗时及人工介入。 |
| 5. 收尾 | 5 分钟 | 停止任务、辅助进程和模拟器，保存结论与必要证据，清理本轮已无用途的下载压缩包和冗余录像。保留设备数据与可复用环境。 |

## 停止条件与验收

- 每次 AI 任务最多 **30 轮或 5 分钟**，先到即停止；显式设置 `agent.flash.max_turns = 30`，另外执行超时取消与进程回收。上游默认轮数无限，轮数限制不能替代时间限制。
- 同一阻塞最多排查 **15 分钟**；总操作预算或新增磁盘 **15 GiB** 预算到达后停止，提交已有结果。每一阶段通过后才进入下一阶段。
- 登录、验证码或应用拒绝模拟环境造成阻塞时，保留证据并注明原因；基础控制成功与美团任务成功分别报告。
- 两次任务都由 ARTEMIS 完成操作且最终购物车核对一致，才算本轮任务验证通过。预先登录和位置选择单独记录；执行中由人工代替点击或输入的轮次不算自主完成。
- 两次成功仅作为进入 CtrlX 集成评估的依据，不代表长期稳定性、多开容量或跨版本兼容已经通过。

最终记录三个结论：**模拟器控制是否可用、美团是否兼容、ARTEMIS 是否完成目标任务**。附 ARTEMIS 提交、镜像与 APK 版本、模型与观察后端、实际命令、两次结果和关键截图；敏感配置及原始证据留在忽略目录。

## 执行记录

| 验收项 | 当前结论 |
|---|---|
| 模拟器控制 | 通过本机单设备基础控制：截图、层级、点击、滑动、中文输入；不代表长期稳定性或性能验收 |
| 美团兼容性 | ARM64 包可安装启动，游客商家列表可显示；Google APIs AVD 与 redroid 均实测原始错误 `121118`，Google Play AVD 同样未通过账号验证但原始错误码未知；完整购物流程未通过 |
| ARTEMIS 目标任务 | 未验证；模型视觉与工具调用探针通过，但两次自主任务均未开始，不能据此判断模型任务成功或失败 |
| 收尾 | 测试进程、调试服务、转发及私有 ADB 已回收，测试代理恢复原值；按用户要求删除 redroid 虚拟机、其数据卷及 Google Play 对照设备和镜像，仅保留原 Google APIs AVD 及其应用数据，诊断证据保留 |

- ARTEMIS 固定在 `351ca8422f7b5b54e80a9c1ce03a222e02415b6b`，独立 Python 环境安装完成。通过 ARTEMIS 自身 `get_llm` 验证图片识别和工具调用，实际使用火山方舟 `doubao-seed-2-0-lite-260428`，OpenAI 兼容接口，`reasoning_effort = none`。密钥只通过环境变量传入。
- Android Emulator `37.2.12`，Android 15 / API 35 / Google APIs ARM64 镜像 revision 9，硬件加速检查通过；单台 AVD 首次启动约 30 秒。ADB `37.0.1` 在本机 USB 枚举阶段阻塞，通过仅对测试进程设置 `ADB_USB=0` 解决；使用独立 ADB 端口 `5039` 和设备 `emulator-5580`。
- 美团默认官方下载为 32 位包；已取得同一官方 CDN 的 ARM64 包，两个包的签名证书 SHA-256 一致。已安装并启动 `com.sankuai.meituan`，版本 `12.67.203` / versionCode `1200670203`，`arm64-v8a`、minSdk 21、targetSdk 30。
- 本轮计划选择上海静安寺附近的营业商家、普通汉堡一份；用户已确认区域和餐品由执行方选择，仅测试加购。主 App 城市选择不等于外卖配送地址；初始地址搜索返回空结果，后来通过测试 GPS `121.4459,31.2234` 和界面选择，确认外卖页地址显示“静安富民公寓”。启动后需重新核对城市和配送区域，不能直接沿用旧画面的状态。
- ARTEMIS Accessibility Helper `1.2.0` / protocol 2 安装成功，实际观察后端为 `helper`。通过 ARTEMIS driver 取得 720 × 1280 截图、中文 UI 层级，完成点击，并输入“静安寺”、在输入框中核对一致。上滑后“我的”页内容坐标上移 16 px，基础滑动通过；这些是 driver 控制验证，不算自主任务通过。
- 用户完成图形验证码后，游客模式可浏览外卖商家列表；用户配合短信登录后，美团进一步要求账号本人做人脸识别，登录未完成。按用户选择继续处理，保留 userdata 重启并设置 `-camera-front webcam0`，接入 Mac FaceTime 相机；没有替代用户完成身份验证。
- 摄像头黑屏排查发现明确的宿主限制：macOS TCC 将模拟器的摄像头访问归属到启动它的 CtrlX，因当前 App 缺少 `com.apple.security.device.camera` entitlement 而直接拒绝授权。已改由系统 Terminal 启动同一 AVD，走正常摄像头授权；没有重签或替换已安装的 CtrlX。后续若把依赖摄像头的 Android 流程接入 CtrlX，需补充宿主权限配置与真实画面验收，不能仅以 Android 枚举到摄像头作为通过依据。
- Terminal 的摄像头权限已获准；重新打开验证后，Android 摄像头输出从 23 帧增加到 115 帧，间隔约 3 秒，说明视频帧在持续产生。美团仍显示“您的网络状况不好，请稍后再试”。Android 网络已标记 `VALIDATED`；本轮观察到的 40 条模拟器连接无代理层拒绝或失败，美团域名走 `DIRECT`。这些证据不能排除具体接口或业务验证失败，也不足以认定模拟器被风控拒绝；错误根因未确定。官方替代入口提供已绑定微信验证，但本轮 AVD 未安装微信。
- 回到游客外卖页、明确选择测试定位后，页面显示 `H403##3DXTZ5#111134`，随后出现系统无响应。09:02:52 的 ANR 原因为 `Input dispatching timed out (Application does not have a focused window)`；同期两核 CPU 总使用率约 93%，可用内存约 1.3 GiB。一次四核、同样 3 GiB 内存的保留数据重启后，美团约 4.4 秒启动成功、界面操作恢复，但外卖仍显示 `H403##KRUZKK#111134`，搜索“汉堡”明确返回“您还没有登录，请先登录”。系统恢复未解除应用登录门槛；未将此对照当作四核性能已达标。
- 登录验证的排查已到单一阻塞的 15 分钟上限，按计划停止重试。本次未打开商品或加入购物车，未提交订单或付款；没有执行任何计入验收的自主轮次。恢复后仍须完成两次完整任务，不能用手动操作代替。
- 执行前磁盘空闲约 59.3 GiB。SDK 下载曾出现中断，采用分片续传，并依据官方仓库元数据校验完整归档。已清理不再需要的下载文件约 2.38 GiB，以及临时登录、验证码和人脸验证截图等 116 个文件；环境约 9.5 GiB，设备数据和可复用依赖保留。跨夜等待身份验证及每阶段时间记录在 `evidence/stage-times.json`，没有把等待时间计为 AI 任务耗时。
- 原始证据、运行脚本和环境位于 `.build-local/android-artemis-validation/`。关键证据包括 `evidence/artemis-model-probe.json`、`emulator-accel.txt`、`meituan-installed-package.txt`、`basic-controls.json`、`camera-reopen-frames.json`、`network-verification-diagnosis.json`、`android-system-anr.txt`、`four-core-waimai.{json,png,xml}`、`guest-food-results.{json,png,xml}`、`shutdown.json` 与清理记录。手机号、验证码和密钥不写入版本库。

### 2026-10-15 晚间本机复验

- 用户通过已准备的 Terminal 脚本重新启动同一 AVD，四核、3 GiB、`webcam0`，启动约 18.2 秒。美团仍未登录；用户自行确认协议、获取短信并输入验证码，之后进入人脸验证。
- 验证码页出现 Gboard 软键盘未显示的问题：默认输入法和允许显示软键盘的设置正常，IME 报告已显示但键盘内容区为空。重启输入法未解决；关闭该测试 AVD 的 `stylus_handwriting_enabled` 并重新聚焦后，数字键盘显示，用户能够输入。同期用户也在操作，尚未单独隔离根因；未重置输入法或美团数据。
- 人脸验证再次提示“您的网络状况不好，请稍后再试”；美团持有摄像头，输出帧数从 1,296 增至 1,694。当前日志未提取到明确的 DNS、TLS、连接超时等传输异常，不能据此排除具体接口问题，也不能判定是模拟器风控。
- 用户关闭 Surge 增强模式，保留系统代理与原网络。在现有验证页仅重试一次，仍出现相同提示。这个对照只说明关闭增强模式没有解决问题；未做热点或完全停用代理的对照。
- 已退出人脸采集，`Active Camera Clients` 为空。官方“切换验证方式 → 三方账号”明确提供已绑定微信验证；用户不采用需要安装微信的方式，未安装或登录微信。仍未执行任何自主加购轮次。
- 按停止条件结束本轮测试：美团已停止，模拟器 PID 退出，私有 ADB 停止且三个测试端口关闭；设备数据和可复用依赖保留。后续继续美团任务仍需先完成应用允许的账号验证，当前证据不能支持“人脸认证可用”或“自主加购通过”的结论。
- 新证据为 `evidence/local-keyboard-settings.json`、`local-login-network-state.json`、`local-login-camera-followup.json`、`local-face-monitor-events.json`、`local-face-network-retry.json` 和 `local-resume-shutdown.json`。含验证码输入过程的临时截图已删除，不保留人脸画面。

### 2026-10-16 人脸验证深入排查

用户明确要求继续深入排查，重新启动同一设备并亲自复现“网络不好”。本节是对先前停止后的追加诊断，不计为自主加购验收。

- **错误阶段已收窄，根因尚未证实。** 静态检查官方 APK 及其已下载的人脸动态模块后，找到与当前“返回／再试一次”弹窗匹配的 `FaceDetectionSubFragment2.info()` → `AnonymousClass8.onError()` 路径。它获取的是验证参数，调用 `mtgsig/v2/ext_api/{action}/info`；多个错误类别会统一显示“网络不好”。网络回调还会把底层异常转换成 `1210000`，但本次没有读到实际 `error.code` 或异常内容，不能把这个常量当成本次已观测的错误码，也不能据此判定风控拒绝或人脸上传失败。
- **模块加载正常。** 复现日志包含动态模块加载完成、`FaceDetectionFragment` 反射成功及验证页面启动。动态模块主包 MD5 为 `af8d8611cfc32d08a45c6ad4105bdbaf`，与官方 APK 的模块清单一致。静态分析只读提取代码，没有修改或重签美团 APK。使用测试镜像的临时 ADB root 读取代码和日志格式后已恢复普通 shell；这些读取发生在原始复现之后。反编译有两个未完整恢复的方法，本节仅使用已恢复的请求、弹窗和日志处理代码。
- **摄像头输出与业务成功仍分开判断。** 既有持续产帧证据仍有效；新证据将排查重点放在验证参数请求。页面监控里的 `700/703` 是 SDK 监控值，不是 HTTP 状态；`yoda_face_video_end` 也不能证明视频已上传或人脸已验证。
- **验证域名可达，但业务请求未验收。** Android 设备内用系统 Java HTTPS 栈对 `https://verify.meituan.com/` 发出不含账号信息的 `HEAD` 请求：直连约 311 ms、经现有代理约 257 ms，均完成 DNS/TLS 并收到 HTTP 404。Mac 两条路径也能收到响应。404 是公开根路径的响应，只证明该次连接成立，不能代表带签名、会话和业务参数的 `info` 请求成功；探针也没有复用美团自身的网络栈。
- **发现了独立的联网检查差异。** Surge 增强模式关闭后，本次 AVD 的网络为 `PARTIAL_CONNECTIVITY`；抓包可见 Android 联网检查的 HTTPS 连接未建立，同时多个美团域名仍完成 TLS。仅给测试 AVD 设置 Android 系统代理 `10.0.2.2:6152` 后，系统联网检查变为 `VALIDATED`。这是网络状态改善的实测证据，尚不是人脸问题的因果证据：随后美团已回到验证码页，没有完成新会话的人脸对照。Mac 网络、Surge 配置均未更改。还原时同时清除了 Android 派生的全局代理字段，仅删除旧的 `http_proxy` 键不足以完成还原。
- **采样边界已确认。** 第一份模拟器抓包只覆盖虚拟蜂窝接口，美团当时使用虚拟 Wi-Fi，因此不能用它判断美团是否发出请求。临时关闭测试 AVD 的 Wi-Fi 后补采得到实际业务流量，并再次看到相同弹窗；之后恢复 Wi-Fi。HTTPS 内容没有解密，未安装证书或关闭证书校验。关键 SDK 请求日志写入 Logan；当前本地日志为二进制格式，普通 `logcat` 和直接读取都未取得可解读的原始错误。未保存完整应用日志、验证码或人脸画面。
- **诊断中另有一次模拟器失去响应。** 原始人脸复现之后，ADB shell 与模拟器控制端口均超时，已保留宿主线程采样并回收该测试进程。随后关闭摄像头、保留 userdata 启动无窗口诊断实例，完成日志格式检查与设备内连接探针，再正常停止。这个后发生的问题不作为之前人脸报错的根因，也不算模拟器稳定性通过。
- **下一步只有一次完整对照。** 已准备 `scripts/start-camera-proxy-comparison.command`：沿用原 Terminal 摄像头启动方式，给测试 AVD 接入现有代理，再打开美团，由用户完成新短信与人脸验证。脚本不发送短信或记录身份验证内容。复验结束后恢复原代理配置；如果仍失败，继续需要原始 SDK／服务端错误才能区分具体传输、参数或业务拒绝，不再仅凭提示反复调整摄像头。未安装微信，未执行加购、下单或付款。

本节证据集中在 `.build-local/android-artemis-validation/diagnostics/face-network/`：`local-face-attempt.log`、`ethernet-attempt.log`、`ethernet-pcap-summary.json`、`android-proxy-connectivity.txt`、`guest-public-endpoint-probe.txt`、`app-log-format.json`、`proxy-comparison.json`、`emulator-stall.sample.txt` 和 `diagnostic-shutdown.json`。官方 APK、动态模块与反编译代码只保存在忽略目录。以上是故障定位证据，不改变“美团完整流程与 ARTEMIS 自主加购尚未通过”的结论。

### 2026-10-16 上午完整代理对照

- 用户恢复任务时，同一摄像头测试 AVD 已启动。现场检查发现尚未启用代理；已补设测试 AVD 的 Android 系统代理，再打开美团。Wi-Fi 与虚拟蜂窝网络均变为 `VALIDATED`。冷启动后的测试 GPS 已恢复到先前选定的上海区域；实际外卖配送区域仍须在登录后核对。
- 用户自行完成短信步骤、进入人脸验证后再次报告“网络不好”。现场层级确认仍是“您的网络状况不好，请稍后再试／返回／再试一次”，随后返回“身份核实”引导页仍要求人脸识别，因此不能把短信步骤完成记为完整登录成功。失败后的 Wi-Fi 和虚拟蜂窝仍为 `VALIDATED`；启用测试 AVD 的系统代理没有解除这一轮人脸验证阻塞。
- **新增错误分类证据。** 10:46:18 点击报错页的“返回”后，实际捕获 `yoda_face_verify_launch_status, code=703`。官方包中的 `CommonReport` 将 `703` 定义为 `PAGE_LAUNCH_FAIL_SERVER`，将 `704` 定义为 `PAGE_LAUNCH_FAIL_NET`；匹配弹窗的返回回调根据 `BaseFragment.isNetError(error)` 选择两者，而该方法检查 `error.code == 1210000`。结合当前页面和返回时序，更支持此次 `info` 错误走了 SDK 的非网络错误分类，排查重点应转向验证参数或业务响应。`703` 不是 HTTP 状态或原始业务错误码，也不能单独证明模拟器被风控拒绝；仍没有取得具体 `error.code`、错误消息或服务端响应。
- 沿请求回调继续复核，包内原始实现会将传输异常和无法解析的响应都转换成 `1210000`，而已解析 `YodaResult.error` 中的业务错误会原样传递。这进一步支持业务响应方向，但属于代码与监控事件结合的推断，不能替代原始响应。现有诊断文本未补出具体业务错误；官方人脸验证 FAQ 也未给出当前提示的专门处理方法。恢复两次自主加购仍须先完成应用允许的身份核验，不能将其他应用或游客浏览代替验收。
- 最长 5 分钟的事件采集已结束，用户本次验证发生在采集结束后；随后从同一应用进程的 `logcat` 缓冲区补采到了页面启动和返回事件。只保存事件名、监控值、时间或异常类型，不保存短信、人脸画面或原始请求内容。证据为 `diagnostics/face-network/fresh-proxy-comparison.json`、`fresh-proxy-reproduced-events.json`、`fresh-proxy-reproduced-connectivity.txt` 与 `fresh-proxy-return-events.json`。事后代理记录还可见 23 条属于该测试 SDK 模拟器进程的连接，无代理层失败标记，但记录未保留本次验证域名请求，不能据此证明该接口传输成功；该边界记录于 `fresh-proxy-connections.json`。
- 用户随后手动再试，10:48:06 再次进入验证页，并复现相同弹窗。后续 10:49:04 日志记录 `yoda_verify_callback=711`，界面回到验证码页，没有取得第二条 `703` 或具体业务错误码。同期 `yoda_callback_code=720` 仅表示请求标识与回调标识一致，不是超时或业务错误码；总历时约 601 秒本身也不能证明最初报错是会话过期。
- 执行方没有发送新短信或启动新的验证。最新采集结束后确认 `Active Camera Clients` 为空，已恢复四个 Android 全局代理字段至原值，并正常停止模拟器与私有 ADB；测试端口 `5039/5580/5581` 均关闭，userdata 与环境保留。补充证据为 `fresh-proxy-user-retry-return-events.json` 与 `fresh-proxy-shutdown.json`。此次对照已得到结果，继续定位需要可解读的原始 SDK 或服务端业务错误；重复重启、调整摄像头或只检查公开域名不能回答具体拒绝原因。
- 任务监督器补做了两个隔离实测：父进程正常退出、父进程超时；两种情况下，忽略 `SIGTERM` 的子进程都被最终回收。测试执行原 `run-task.py`，只替换启动命令并把等待时间缩短为 1 秒，不访问模拟器或模型。结果在 `diagnostics/supervisor-proof/result.json`。这验证了进程组回收逻辑，不能代替真实 ARTEMIS 运行的退出验收。

### 模拟器识别假设的补充核查

- 用户提出云手机服务的可行性作为继续排查依据。火山引擎云手机官方 SDK 发布记录明确提供客户端摄像头传输，并针对人脸识别提供前置摄像头类型和亮度处理；阿里云无影云手机 FAQ 也说明各客户端支持摄像头重定向。这些资料支持该技术路线具备可行实现，但没有承诺当前美团账号在本地 Google AVD 上可通过认证，不能据此跳过具体错误取证。
- 美团官方《美团 SDK 隐私说明》明确将设备与网络信息用于安全风控、身份验证和设备安全判断，但本轮公开资料检索未找到“所有模拟器均禁止登录”或“该网络提示专指模拟器拒绝”的官方说明。
- 对当前官方 ARM64 APK 做只读静态核查，确认美团自身的 `com.meituan.met.mercury.load.utils.d.j()` 根据 `Build.FINGERPRINT/MODEL/MANUFACTURER/BRAND/DEVICE/PRODUCT` 判断模拟环境；动态资源模块 `com.meituan.met.mercury.load.retrofit.b.a(...)` 将结果写入 `isEmulator`，随 `config/{业务}/checkList` 请求体发送。对应源文件保存在 `diagnostics/face-network/emulator-check-source/`。这是应用包含识别与上报逻辑的证据，尚未观测到本次设备的实际检测值，也未证明该动态资源字段参与了 Yoda 身份验证的拒绝决策。最初检出的 QEMU 字符串还涉及支付宝和地图模块，不能仅凭字符串归因到美团风控。
- 因此，“模拟环境触发验证限制”应列为优先排查假设，现有证据仍不足以将它确认为根因。普通日志未暴露原始错误，并不代表诊断手段已经用尽；追加准备仅提取 `info` 错误对象的 `code/message` 的运行时观测，先保留未插桩的失败现场，再尝试读取，以便评估调试工具对结果的影响。不修改认证返回值或设备识别结果。
- **错误对象采集工具先通过隔离实测。** 静态确认弹窗按钮的 `a0/c0` 回调持有原始 `Error`。采集脚本从当前显示的 `FaceDetectionSubFragment2` 弹窗读取按钮回调，再仅提取其错误码和脱敏消息，不调用重试、认证或点击方法。使用官方 Frida `17.23.3`，下载归档 SHA-256 与官方发布元数据一致；依赖单独安装，不更改 ARTEMIS 环境。先在同一 Android 15 AVD 的独立测试进程验证：动态类加载器中的两个模拟弹窗仅提取当前显示的一条错误，已隐藏的旧错误被排除，消息中的长数字被脱敏。临时调试进程与文件均回收，ADB 恢复普通 UID `2000`，模拟器和四个私有端口关闭。该测试不涉及美团认证；实测证据为 `diagnostics/face-network/error-observer/preflight-result.json`。随后用户按原 Terminal 摄像头启动方式复现，真实取证结果见下节。

### 2026-10-16 原始错误取证

- 用户重新启动后报告美团启动即提示网络失败。现场仍在未登录的“我的”页，测试 AVD 没有设置代理，默认 Wi-Fi 未通过联网检查。恢复测试 AVD 代理 `10.0.2.2:6152` 后，虚拟蜂窝网络变为 `VALIDATED` 并成为默认网络；已打开登录页、按用户要求填写先前提供的手机号，由用户完成短信与人脸步骤。该网络检查改善不能单独证明美团所有接口恢复，也不能与随后的人脸业务错误混为一个结论。
- **11:44 左右捕获了原始错误 `121118`，消息为“当前有问题，请用手机访问”。** 先记录未插桩的自然失败弹窗、普通 ADB UID `2000` 和应用 PID `3023`，再启动短时调试观察。从唯一显示中的 `FaceDetectionSubFragment2` 弹窗取得其负按钮 `a0` 回调持有的原始 `Error`，没有替换方法、修改返回值、点击重试或重发认证请求。附加前后应用 PID 一致，读到的一个活动弹窗与现场 UI 对应。证据为 `diagnostics/face-network/error-observer/meituan-baseline.json`、`meituan-observation.json`、`watch-result.json`。
- 包内 `info.onError` 的 `a0` 分支使用固定的“网络不好”文案，覆盖原始 `error.message`。因此此前通用提示不能当作 DNS、TLS 或摄像头故障的证据；`121118` 也不同于 SDK 对传输／解析异常使用的 `1210000`。结合已审阅的请求回调，当前结果支持验证业务响应拒绝当前访问环境；未截取原始 HTTP 响应，公开资料未查到 `121118` 的完整定义，尚不能断言具体命中了模拟器、调试镜像、账号、网络出口或哪条组合规则。
- 当前运行属性为 `sdk_gphone64_arm64`、`userdebug/dev-keys`、`ro.debuggable=1`、`ro.kernel.qemu=1`。把实际属性代入先前发现的 Mercury 原始启发式规则，结果为 `false`；这只是宿主侧静态计算，不是热补丁后的实际执行值，也不代表其他风控模块不能识别模拟器。相关证据为 `current-avd-detection-properties.json`。不能把先前发现的 Mercury `isEmulator` 字段直接认定为本次拒绝原因。
- 取证后已返回身份核实引导页，摄像头无活动客户端。调试服务、临时目录和端口 `5582` 转发均已独立复核移除，ADB 恢复普通 UID `2000`；回收期间有一次命令报错，复核结果另记在 `meituan-observation.json.cleanup_followup`。未采集验证码、人脸画面、请求令牌或完整错误对象。
- 在原始错误取证后，选择官方 Google Play 发布镜像进行一次干净环境对照。Android 官方文档说明该镜像使用发布签名且不提供 ADB root；对照的运行属性与实际结果如下，不以镜像名称代替兼容性验收。保持官方 App、真实设备标识和正常认证流程，不修改认证结果。
- 已核对 Google 官方仓库的 Android 15 / API 35 / Google Play ARM64 revision 9：下载约 1.67 GiB，解压约 2.15 GiB，元数据与归档目录保存在 `playstore-image-candidate.json`。只顺序运行一台测试设备，保留原 AVD 数据；新实例沿用相同 API、硬件参数、APK 和网络路径，不复制账号数据。原设备代理已恢复，模拟器正常退出；关闭 ADB 后设备端口短暂延后释放，后续复核四个端口均关闭，证据为 `error-observer/capture-shutdown.json`。新镜像准备和登录对照继续遵守本轮 15 GiB 磁盘预算。
- **镜像准备与运行属性。** 归档 SHA-1 与官方元数据 `b01416bc0bca12a85295dad179f9b8a1cae3d1e6` 一致。归档附带的外部 `build.prop` 标为 `user/dev-keys`，不能据此判定实际运行值；启动后通过 ADB 读取的系统属性确认是 `user/release-keys`、`ro.debuggable=0`、普通 UID `2000`，未修改属性或取得 root。新设备 `ctrlx-artemis-api35-playstore` 约 27.4 秒启动，使用相同 API 35、ARM64、四核、3 GiB、720p 和 GPU 设置。原设备是 `userdebug/dev-keys`、`ro.debuggable=1`；两镜像的构建号、设备身份和新建应用数据也有差异，因此这次是整套干净环境的可用性对照，不能单独归因某个属性。已清理约 0.80 GiB 的 `uv-cache` 安装缓存及校验完成的镜像归档，保留已安装环境和原 AVD；启动后整个验证目录约 12.3 GiB。记录见 `evidence/playstore-device-configuration.json`、`release-comparison-cache-cleanup.json` 和 `logs/playstore-image-download.log`。
- 新实例已安装同一份未改动的官方美团 APK，SHA-256 与原始下载记录一致；安装 ARTEMIS Helper `1.2.0` 后，层级、点击、手机号输入及回读均成功。设置测试代理后，默认网络通过 `VALIDATED`，GPS 与 fused provider 为约定的上海坐标；App 城市从初始缓存的硅谷明确切换为上海。首页主体可显示，但部分内容仍出现 `H403`，不能据此认定业务网络或兼容性通过。登录页已打开、手机号已填入并核对，没有请求短信。记录在 `evidence/playstore-baseline.json` 和 `playstore-preparation.json`，不保留手机号输入画面。
- 准备使用无窗口、无摄像头实例完成；准备结束后正常停止，四个私有端口均已关闭，新设备数据与测试代理保留。验证目录约 **13.9 GiB**，尚在 15 GiB 预算内。摄像头窗口的新入口是 `scripts/start-camera-playstore-validation.command`，先验证非调试系统属性，再配置代理、测试定位并打开美团。用户需沿用 Terminal 的摄像头授权手动启动；`evidence/playstore-prepared-shutdown.json` 记录准备阶段收尾。本阶段只是环境就绪，不计为人脸验证成功或自主加购成功。
- 用户按新入口启动摄像头实例。再次核对实际系统为 `user/release-keys`、`ro.debuggable=0`、ADB UID `2000`，默认 Wi-Fi `100` 通过 `VALIDATED`；摄像头服务枚举到一台设备。登录页手机号已补齐，并忽略界面的分隔空格核对一致，未由执行方请求短信。仅进行只读页面观察与普通 ADB 日志读取，没有附加调试器或获取 root，不保存验证码、人脸画面和输入值。证据入口为 `diagnostics/face-network/playstore-camera-start.json`、`playstore-login-ready.json` 和 `playstore-login-observation.json`。
- **发布镜像对照仍失败。** 用户完成短信并进入人脸页面后，12:13 左右再次出现“您的网络状况不好，请稍后再试”。失败现场的默认 Wi-Fi 和虚拟蜂窝网络均为 `VALIDATED`，美团摄像头输出帧数从 `658` 增至 `1401`；点击现有弹窗的“返回”后，记录到 `yoda_face_verify_launch_status=703`，摄像头客户端随之释放。`703` 是已审阅 SDK 的服务端错误分类，不是 HTTP 状态或原始业务错误码。新实例没有读取原始 `Error`，不能将旧实例的 `121118` 直接当作本次已测结果；证据为 `playstore-failure-system-state.json` 与 `playstore-return-events.json`。
- **结论与边界。** 官方非调试镜像本身不足以解决这条登录链路；临时 root／调试器附加不是出现通用失败及该 SDK 分类的必要条件。当前证据支持优先查验验证服务对访问环境的接受条件，但没有证明所有模拟器都被禁止，也没有完全排除账号、网络出口或其他共同因素。两环境仍共用宿主、账号、网络路径、模拟器产品与已启用的 ARTEMIS Helper。仅凭系统联网通过不能证明业务接口被接受，摄像头出帧也不能代替人脸认证通过。后续有区分力的证据是美团对 `121118` 的具体说明，或同账号在已知可正常验证的 Android 设备上的对照；云手机供应商支持摄像头并不保证美团接受其环境。
- 本次对照已结束：强制停止测试美团进程，将四个 Android 代理字段恢复到各自原值，正常关闭模拟器与私有 ADB。四个端口 `5039/5580/5581/5582` 均关闭，摄像头无活动客户端，userdata 保留。验证目录约 **14.11 GiB**，宿主空闲约 **59.0 GiB**。收尾证据为 `diagnostics/face-network/playstore-comparison-shutdown.json`，阶段时间另记在 `evidence/stage-times.json`。尚未登录成功，未执行任何自主加购轮次。

### 2026-10-16 云手机方案补充调研

本节来自公开资料，没有新开云资源或再次登录。两套本机 AVD 失败只说明当前环境未通过，不能据此排除云手机路线。新增证据支持优先进行云手机的单实例兼容性对照，而非继续反复切换同一模拟器的发布／调试镜像。

**最直接的美团案例是 UCloud OrderWise。** [官方项目](https://github.com/ucloud/orderwise-agent)与[演示网站](https://ucloud.github.io/orderwise/)公开了云手机上的美团外卖比价流程、人工接管与 ADB 接入。README 列出的美团版本为 `12.49.202`，本机测试的是 `12.67.203`；项目要求用户预先登录并配置配送地址。公开材料没有说明该账号是否触发过人脸验证、如何完成验证，或可复现的具体云手机镜像。因此它是值得跟进的实际应用案例，不能直接证明本账号或当前 App 版本一定可用。其任务模板还会进入结算页并选择红包，不能直接照搬到本轮“仅加购”的范围。

**远程本人认证已有厂商产品流程。** 火山引擎 MUA 的[手机扫码人脸验证文档](https://www.volcengine.com/docs/6394/2603617)（更新时间 2026-07-24）说明：从控制台打开手机 H5 链接，用手机扫码、登录火山账号、授予摄像头权限；手机接管期间桌面连接暂时中断，完成后桌面重新连接并继续任务。[执行任务文档](https://docs.volcengine.com/docs/Cloudphone/UseAgentService?lang=zh)也明确列出这一流程。文档没有承诺美团 `121118` 能通过，不能把该产品流程当成美团的跨设备认证接口。

| 候选 | 已查到的能力 | 本轮选择前需要核对的条件 |
|---|---|---|
| UCloud UPhone / OrderWise 所用环境 | 有美团 App 的公开实现与演示；云手机经 ADB 控制 | 确认案例对应镜像、App 版本、单实例供应和摄像头支持；[旧版官方 FAQ](https://github.com/UCloudDoc-Team/uphone-server/blob/master/FAQ.md)限制零售 ADB，不能默认所有套餐可用 |
| 火山引擎云手机 | 有手机 H5 扫码接管摄像头流程与多端 SDK | [ADB 文档](https://docs.volcengine.com/docs/Cloudphone/DebugcloudphoneinstanceviaADB?lang=zh)要求认证用户联系技术支持开通，连接默认 24 小时有效且定位为调试；[MUA 资源文档](https://docs.volcengine.com/docs/Cloudphone/step-2-create-cloud-phone-resources?lang=zh)列出的购买单位是云机，还涉及存储、带宽与 EIP，不能按一台廉价模拟器估算 |
| 阿里云无影云手机 | [官方 FAQ](https://help.aliyun.com/zh/ecp/cloud-phone-faq/)明确支持 macOS、Web 等客户端摄像头；移动 Web 包含 iOS/Android 前后摄像头；有 ADB 与 Web SDK | 先启用摄像头重定向；按所查[ADB 文档](https://help.aliyun.com/zh/ecp/how-to-connect-cloud-phone-via-adb)，共享网络仅私网 ADB，VPC 才支持所述公网方案，需要核对网络资源及费用；美团兼容性仍待实测 |
| 华为云 CPH | 提供虚拟摄像头相关能力 | 专门的[人脸识别 FAQ](https://support.huaweicloud.com/cph_faq/cph_faq_0034.html)仍写不支持人脸识别；在厂商明确当前产品支持前，不作为此次首选，不能推广为所有华为云产品的结论 |

云手机与本机 AVD 的差别不能简化为 ARM 对 x86：本机测试本来就是 ARM64。[UCloud 产品介绍](https://www.ucloud.cn/site/product/uphone.html)描述的是原生 ARM 服务器、自研 Android 虚拟化及 GPU 直通；其系统镜像和外设实现与当前 AVD 不同。因此更换设备平台是有区分力的对照，但服务端是否接受仍须实际登录验证。公开资料仍未查到 `121118` 的权威错误码定义。

如果选择云手机对照，最小验证顺序如下；这不代表 CtrlX 已决定依赖云手机服务：

1. 选一台能提供 ADB 和真人实时摄像头接入的国内云手机。优先核对 OrderWise 所用 UCloud 环境；若无法快速取得适配实例，以阿里云无影作为公开接入文档较完整的候选，火山方案保留为摄像头接管流程参考及有现成权限时的候选。具体资源、价格与账号条件确定后再开通，本轮调研没有购买或申请资源。
2. 先使用厂商客户端手动完成同一份官方美团 APK 的登录与外卖页面访问，暂不安装或启用 ARTEMIS Helper。需要人脸时，由本人通过手机浏览器的实时摄像头正常验证。这同时隔离“新增自动化服务”的影响，但不预先认定它是本机失败原因。
3. 登录通过后再连接现有 ARTEMIS，验证截图、输入和 Helper 可用性，再执行原定两次仅加购任务。保留现有模型与任务限制；不为验证复制 OrderWise 的 MongoDB、队列或多平台执行架构。
4. 单个登录阻塞仍以 15 分钟为排查上限；分别记录厂商、镜像、App 版本、正常登录结果、接入自动化后的结果及人脸处理方式。如果厂商案例需要其他 App 版本，应作为单独兼容性变量记录，只使用来源和签名可核验的官方包，不覆盖现有设备数据。

### 2026-10-16 本机与自托管方案补充调研

云手机对照只用于确认另一种设备环境能否完成美团任务，最终部署方式仍可选择本机或自托管。厂商公开了摄像头与 ADB 接口，并不等于公开了可直接移植到 macOS 的 Android 系统镜像。当前仍没有找到能保证解决本次 `121118` 的公开方案。

| 方案 | 官方资料确认的条件 | 对当前 Mac 验证的判断 |
|---|---|---|
| Genymotion Desktop | [产品页](https://www.genymotion.com/product-desktop/)提供 Mac M 系列 ARM64 镜像、ADB 和宿主摄像头；摄像头属于 Pro 功能，官网列出 30 天试用。[安装文档](https://docs.genymotion.com/quickstart/desktop_install/)说明 macOS 使用内置 QEMU / Hypervisor，仍要求 Rosetta，并预留程序 300 MB、每台设备至少 2 GB；[Android 15 镜像](https://docs.genymotion.com/features/root/)默认未 root | 本机更换运行环境时最直接的候选，无须先搭 Linux。需要可用的账号与 Pro 授权；不是开源的内置引擎，美团兼容性尚未验证 |
| redroid | [官方仓库](https://github.com/remote-android/redroid-doc)支持 Linux 宿主上的 ARM64 / AMD64 Android 容器，需要 Binder 等内核支持；可用 ADB / scrcpy，GPU 支持需配置，README 的 WebRTC 接入仍列为计划 | 可研究自托管 Linux 设备；在当前 macOS 上还需 Linux 环境，并验证图形及摄像头路径。依据这些前提，判断其工作量明显高于本轮单实例验证，不能视为直接替换 AVD 的 Mac 库 |
| Anbox Cloud | [当前要求](https://canonical.com/anbox-cloud/docs/reference/requirements/)为 Ubuntu Server / Cloud、对应 Ubuntu Pro token；Appliance 至少 4 核、8 GB 内存、主盘 30 GB 空闲，另有可选的 100 GB 实例存储卷 | 更适合独立 Linux 主机。其环境规模超出本轮 15 GiB 磁盘预算，不在这台 Mac 上追加部署 |

以上仅为公开资料核对，没有下载候选镜像、注册账号或新开云资源。Genymotion 的 ARM64 镜像与 macOS 宿主组件是否需要 Rosetta 是两个层次，不能因镜像为 ARM64 就声称整个安装没有额外依赖；其非 root 状态也不能证明美团一定接受。

Genymotion 原先被列为本机兼容性对照候选，但用户随后指出它不能直接沉淀为当前 CtrlX 方案。因此不继续推进该候选的安装与登录；除非未来明确采用“用户自行安装并授权，CtrlX 经 ADB 接入”的产品路线，否则它成功也只能证明另一套环境可用，不能定位当前失败的具体原因。后续替代环境先核对可集成性，再投入业务验证。上轮环境已约 14.11 GiB，新增设备仍需遵守原 15 GiB 磁盘预算并保留原设备数据及必要证据。

CtrlX 后续集成先复用设备的 ADB 连接与现有 ARTEMIS，不预先增加多厂商管理抽象；某个环境完成业务验证后，再决定是否管理其启动和生命周期。远程摄像头传输与美团是否接受设备环境需要分别验收：前者有云手机产品先例，后者仍需实际认证结果，增加摄像头转发本身不能宣称解决 `121118`。

### 2026-10-16 redroid 源码核查：模拟环境识别与风控

按用户澄清，本轮关注上游是否主动隐藏模拟环境特征。结论：**有可影响简单属性检测的系统配置入口，但审阅范围内未发现完整的模拟器隐藏方案，也未发现针对美团 / Yoda / `121118` 的专门实现。** 这是源码分析，没有运行 redroid 或重新尝试美团认证。

审阅以当前测试所用的 Android 15 为基线：`local_manifests` 的 `15.0.0` 分支固定至 `a116ba2`，`device_redroid` 的 `redroid-15.0.0` 固定至 `9248d0e`，`vendor_redroid` 的 `master` 固定至 `1686c18`，`redroid-patches` 固定至 `a5c70c0`，重点逐项核查 `android-15.0.0_r36` 的补丁。另交叉检查 Android 16 的属性补丁与设备定义（`device_redroid` 的 `f12358e`），并读取 `device_redroid-prebuilts` 的两个产品清单（`6248d6a`）。没有下载或逆向预编译二进制，没有同步完整 AOSP；结论不覆盖第三方定制镜像或云厂商私有改动。

| 源码证据 | 实际实现 | 对风控判断的意义 |
|---|---|---|
| [`allow-override-ro.-prop.patch`](https://github.com/remote-android/redroid-patches/blob/a5c70c0dd89c12b5027c902ab4182f31d38f3bb7/android-15.0.0_r36/system/core/0002-allow-override-ro.-prop.patch#L14-L21) 与 [`fix-booting.patch`](https://github.com/remote-android/redroid-patches/blob/a5c70c0dd89c12b5027c902ab4182f31d38f3bb7/android-15.0.0_r36/system/core/0001-fix-booting.patch#L17-L36) | init 从进程启动参数读取配置，接受 `ro.*` 属性并初始化到系统属性服务；README 将此入口标为调试用途 | 能配置部分 App 可读取的设备信息，因此可能改变仅依赖这些字段的检测结果。代码没有实现按 App 拦截查询、自动选择真实手机配置或保持所有检测面一致；它也不是运行后任意重写只读属性的接口 |
| [`redroid_arm64.mk`](https://github.com/remote-android/device_redroid/blob/9248d0ee4e28241243c241d8e43faa707b13376e/redroid_arm64.mk#L21-L25)、[`redroid.prop`](https://github.com/remote-android/device_redroid/blob/9248d0ee4e28241243c241d8e43faa707b13376e/redroid.prop)、[`AndroidProducts.mk`](https://github.com/remote-android/device_redroid/blob/9248d0ee4e28241243c241d8e43faa707b13376e/AndroidProducts.mk#L23-L27) | 默认品牌 `redroid`、型号 `redroid15_arm64`、硬件 `redroid`；常用构建组合为 `userdebug`。Android 16 对应型号为 `redroid16_arm64`，其余仍相同 | 上游默认配置没有隐藏自身身份；不能把“可定制”当成“默认无法被识别”。源码中的构建目标不代替发布镜像的实际运行属性验收 |
| [`ignore-selinux.patch`](https://github.com/remote-android/redroid-patches/blob/a5c70c0dd89c12b5027c902ab4182f31d38f3bb7/android-15.0.0_r36/external/selinux/0001-ignore-selinux.patch#L47-L79)、[`disable-seccomp.patch`](https://github.com/remote-android/redroid-patches/blob/a5c70c0dd89c12b5027c902ab4182f31d38f3bb7/android-15.0.0_r36/external/minijail/0001-disable-seccomp.patch) | 部分 SELinux 函数短路，`security_getenforce()` 返回 `0`，部分安全上下文返回固定 `HACKED`；minijail 的 syscall filter 安装被禁用 | 这是容器运行适配，并未把环境呈现为常规手机的安全状态。这些差异反而可能成为检测信号；尚未证明美团实际检查这些项，不能据此预测通过率 |
| [`ignore-compatibility-check.patch`](https://github.com/remote-android/redroid-patches/blob/a5c70c0dd89c12b5027c902ab4182f31d38f3bb7/android-15.0.0_r36/system/libvintf/0001-ignore-compatibility-check.patch) | 移除 Android 系统运行信息与 framework compatibility matrix 不兼容时的一处失败返回 | 解决 Android 自身的兼容性检查，不是关闭美团检测，也不是通过 Play Integrity 或硬件可信认证的实现 |

redroid 使用宿主 Linux 内核运行 Android 容器，[产品定义](https://github.com/remote-android/device_redroid/blob/9248d0ee4e28241243c241d8e43faa707b13376e/redroid.mk#L24-L38)不构建独立内核和部分启动镜像。由此推断，一些只针对官方 AVD / QEMU 特征的检测可能不命中，但这是运行架构变化，不是已验证的全面隐藏能力；部署到 Mac 的 Linux 虚拟机后也需要重新验收。上游 [issue #918](https://github.com/remote-android/redroid-doc/issues/918) 中还有用户报告开发模式或模拟器检测导致应用不可用，这只是当事人的兼容性反馈，不能当作美团的根因证据。

对当前任务，值得参考的是系统配置入口及其与应用实际可见信息的关系，暂未找到可直接移植、并有证据解决美团风控的补丁。此前 Mercury `isEmulator` 规则代入本机属性的静态结果已为 `false`，仍不能解释后续 `121118`；因此不应直接把“修改品牌 / 型号”当作修复。下一步若继续风控定位，需要关联具体采集模块、实际执行结果及验证服务响应，才能判断是哪一项环境条件造成拒绝。

只下载了上述小型源码快照和文本清单，集中保存在 `.build-local/android-artemis-validation/research/redroid/`，版本清单为 `revisions.json`。没有执行上游脚本、安装镜像、改写设备属性或认证流程；未新增美团登录尝试。

### 2026-10-16 本机 redroid 部署预检

用户同意尝试在本机 Linux 环境运行 redroid。本轮先验证内核、容器启动与原版美团页面，再决定是否进入用户登录；仍不以修改设备身份或认证结果作为通过条件。

- OrbStack 当前为 ARM64、Linux `7.0.14-orbstack-00380-ga7e0a2dc9535`。用已有镜像启动只读、无网络、无额外权限的临时容器，读取内核配置与设备信息，未发现 Binder 配置、文件系统或模块。该环境还运行着其他服务，因此没有改变其内核或启动特权 Android 容器；预检容器已自动删除。
- 已安装的 Podman `5.3.1` 提供独立 AppleHV 虚拟机。短暂启动原本停止的默认机器，确认 Fedora CoreOS `41.20250105.3.0` / Linux `6.12.7-200.fc41.aarch64` 使用 **4096 字节页**，且 `CONFIG_ANDROID_BINDER_IPC=y`、`CONFIG_ANDROID_BINDERFS=y`、`CONFIG_MEMFD_CREATE=y`、`CONFIG_DMABUF_HEAPS=y`。Binder 内建在内核中，`modinfo` 找不到独立模块不代表缺少支持。只做读取，已恢复停止状态；没有向该机器安装 redroid 或修改其配置。
- 上游要求见 [部署前提](https://github.com/remote-android/redroid-doc/blob/master/deploy/README.md)。上述内核条件满足关键前提，但尚不代表容器启动、图形、摄像头或美团登录通过。下一步使用独立测试虚拟机，只共享测试目录，ADB 仅绑定本机；不复用 OrbStack 的运行中服务环境。
- 已查询官方 `redroid/redroid:15.0.0_64only-latest` 的 ARM64 清单，固定摘要为 `sha256:dc2024a999dd0acb1112a23cddc9537ec8cb60a0dbe5a87ce9fbd75a2f5e94d2`，压缩层合计 `693612895` 字节（约 662 MiB）；尚未下载镜像层。部署依照已安装版本的 [Podman machine 文档](https://docs.podman.io/en/v5.3.1/markdown/podman-machine-init.1.html)，复用本地已有官方虚拟机安装镜像。
- 现有验证目录约 **14.1 GiB**，本轮复核宿主空闲约 **40.6 GiB**。用户在复核空间后确认继续，redroid 对照的总磁盘预算调整为 **22 GiB**，保留原 Google APIs / Google Play 镜像、设备用户数据与证据。独立虚拟机按 2 核、3 GiB 内存创建，配置和磁盘保存在本 worktree 的忽略目录；只挂载专用空目录，不共享用户主目录。启动监督器限制运行一小时，并在验证目录达到 22 GiB 时停止测试虚拟机。

预检证据集中在 `.build-local/android-artemis-validation/diagnostics/redroid/`，包括 `orbstack-kernel-preflight.json`、`podman-combined-preflight.json`、`podman-driver-preflight.json` 与 `image-manifest.json`。Podman 的启动、探测和停止需放在同一个受管进程生命周期内：分开执行时曾出现 CLI 报启动成功、下一次调用机器已停止，合并执行后可正常探测；这里只记录现象，未将进程生命周期推测认定为已确认根因。

### 2026-10-16 本机 redroid 运行对照

已在独立的 `ctrlx-redroid` AppleHV 虚拟机中运行上面固定摘要的官方 ARM64 镜像。虚拟机 2 核、3 GiB 内存、16 GiB 稀疏虚拟盘；Android 容器限制 2 核和 2304 MiB 内存，使用默认 720 × 1280 显示及软件渲染，启用 `androidboot.use_memfd=1`。`/data` 存在专用 Podman 卷中，没有复制旧 AVD 的账号或应用数据。

部署时修正了两个宿主兼容性问题，均只作用于本轮测试虚拟机：

1. 仅把 Fedora SELinux 切到 permissive 时，Android init 报 `Failed to initialize property area` 并退出。按照上游 [Fedora 部署说明](https://github.com/remote-android/redroid-doc/blob/master/deploy/fedora.md)，向该虚拟机加入 `selinux=0` 启动参数并重启、重新创建容器，属性初始化随后通过。
2. 后续 APEX 初始化报缺少 loop / device-mapper 设备。预加载 `nfnetlink`、`loop`、`dm_mod`、`dm_verity` 后，`sys.boot_completed=1`，ADB 可连接。这些是 Linux 容器启动适配，没有修改美团 APK、设备身份属性或认证结果。

| 项目 | 本轮结果与边界 |
|---|---|
| Android / ADB | Android 15 / API 35 启动完成；私有 ADB server 使用本机 5039，设备入口只监听 `127.0.0.1:5590`；默认 shell 为 UID 2000，没有执行 `adb root` |
| 默认身份 | 实测品牌、硬件为 `redroid`，型号 `redroid15_arm64_only`，构建为 `userdebug/test-keys`，`ro.debuggable=1`、`ro.secure=1`、`ro.kernel.qemu` 为空。属性不同不等于 App 无法识别；没有设置 `ro.*` 覆盖参数 |
| 基础观察与操作 | 已验证截图、点击、返回、英文文本输入与 UIAutomator 层级读取；系统 `screenrecord` 可生成 3 秒视频；官方 scrcpy `5.0.1` 已连接并初始化 720 × 1280 视频纹理。未进行帧率、延迟或多开性能验收 |
| 网络 / 美团页面 | 系统 Ethernet 网络为 `VALIDATED`；同一官方 APK 的 SHA-256 复核一致，安装成功。首次打开曾 ANR，主线程等待 Horn 配置初始化；再次正常打开后进入游客首页，可手动切换城市，并显示外卖商家列表。未把第一次 ANR 归因为风控 |
| 地址与业务范围 | 总首页已选上海，但外卖页在没有定位时回落到北京；地址搜索 `jingansi` 无结果。因此当前只证明游客页面与商家列表可加载，尚未完成既定区域的商品浏览、加购或正式自主轮次 |
| 登录 / 风控 | 登录页已打开，手机号按用户此前授权填入并在内存中核对；随后按用户要求先处理摄像头，尚未发送本轮短信。没有安装 ARTEMIS Helper、附加调试器或发起本轮人脸验证。能打开游客页面不证明此前账号验证失败已经解决 |
| 摄像头 | `dumpsys media.camera` 实测普通摄像头与摄像头总数均为 **0**。内置 `virtual_camera` 服务可启动，但注册摄像头因图形扩展缺失失败，详见下一节；真实摄像头采集、传输和 Android camera provider 接入尚未完成 |

scrcpy 从官方发布资产下载，SHA-256 为 `33611e51977a8289e2e124b220f727895181ef2eb9060e0987a4dc2db9cf0d6b`。GUI 窗口为 `CtrlX redroid Validation`；首次使用默认连接方式已解码到视频纹理，后续显式使用 ADB forward 与 `c2.android.avc.encoder`，这不是证明前一种方式失败的对照。安装和启动文件均保存在忽略目录，未安装为 CtrlX 产品功能。

虚拟机安装镜像解压后曾使验证目录超过 22 GiB，监督器自动停止；在仅用于回收空间的短暂启动中执行 `fstrim`，释放约 6 GiB 空闲块后恢复部署。系统镜像与原 AVD 数据均保留。用户随后询问旧文件清理，已检查无进程占用并移除上一轮原 AVD 排查的临时 Frida 虚拟环境和服务二进制，释放 `254396 KiB`（约 248 MiB）；诊断结果、脚本、原设备数据、APK、SDK 及 ARTEMIS 环境保留。重跑旧 Frida 排查需重新安装该临时工具。

主要证据：`diagnostics/redroid/runtime-properties.json`、`container-start.json`、`fedora-container-compatibility.json`、`loop-driver-boot.log`、`camera-capabilities.log`、`meituan-first-main-thread.txt`、`cleanup-old-diagnostic-tools.json`，以及 `evidence/redroid-*.png` 中不含登录凭据的页面。上述路径均相对于本地验证目录；手机号码、验证码和人脸图像不写入诊断产物。

### 2026-10-16 redroid 真实摄像头接入探测

用户要求先接通本机摄像头，再继续登录。**本轮未接通；失败发生在 Android 摄像头注册阶段，尚未启动 Mac 真实摄像头采集。** 当前运行环境是独立 Podman / AppleHV 虚拟机，不是 OrbStack；此前 OrbStack 的 Binder 预检与本次摄像头失败是不同问题，不能合并为“容器不支持摄像头”。

- 当前固定镜像没有外部摄像头 provider、V4L2 camera HAL 或 `/dev/video*`。Mac 摄像头不会自动成为 Linux 容器设备；即使完成视频传输，Android 仍需相应 provider 才能通过普通相机 API 提供给 App。
- 镜像包含 `/system/bin/virtual_camera` 和对应 init service。实际启动后，`cmd virtual_camera help` 正常，cameraserver 也发现了 `android.hardware.camera.provider.ICameraProvider/virtual/0`。随后仅调用内置测试摄像头注册命令，未进入美团人脸页面、未提供认证图像；注册失败，摄像头仍为零。日志明确为 **`VirtualCameraService: GL_EXT_YUV_target not supported`**。
- 当前图形栈实测为 ANGLE / Vulkan SwiftShader。对照 [Android 15 的 VirtualCameraService 源码](https://android.googlesource.com/platform/frameworks/av/+/refs/tags/android-15.0.0_r36/services/camera/virtualcamera/VirtualCameraService.cc)，该扩展属于注册前必须通过的检查。这里需要实际具备图像转换能力；仅跳过检查不能证明后续预览可用。
- 已检查两条替代路径。[ScrcpyOverWebRTC 文档](https://webrtc-phone.com/docs/en/rom-hal.html)描述浏览器摄像头经 TCP 送入 Android HAL，但核查其 `v0.4.1` 发布包与 redroid Dockerfile，没有找到可直接安装的独立 camera HAL，不能据此视为当前镜像的一键修复。[aosp-virtual-camera](https://github.com/jsuppe/aosp-virtual-camera/tree/1635640b4d646f14d6a7182224e816f8d48d605b) 提供自定义 HAL 源码，其文档要求 AOSP 构建及匹配的 VNDK 依赖，没有本机已验证的 ARM64 预编译产物。未运行这些第三方二进制、未替换镜像或下载整套 AOSP。

继续接入需要先取得或构建**兼容当前 Android 15 / ARM64、能够在当前软件渲染环境工作**的摄像头 provider；CPU 处理 YUV 帧是一条候选实现路径，尚未验证。之后再连接 `Mac AVFoundation → 本机专用传输 → camera provider`，依次验收设备枚举、普通相机实时预览、方向和持续产帧，最后由用户本人进入美团验证。改用 OrbStack 或单独安装视频转发软件不能补齐上述 Android 驱动缺口；这也不证明所有 redroid 配置均不支持摄像头。

本机此次复核空闲约 34 GiB，没有为此启动完整 Android 构建。官方 [AOSP 构建要求](https://source.android.com/docs/setup/start/requirements)给出的完整检出与构建空间为至少 400 GB；这不是单个 HAL 必然需要的空间，但当前没有已就绪的独立模块构建环境，因此不能把源码方案表述为可直接部署的修复。

已撤销测试摄像头、停止 `virtual_camera` 服务，确认 `Active Camera Clients` 为空。监督器随后停止专用虚拟机；容器未在 20 秒内响应 SIGTERM，由 Podman 升级为 SIGKILL，见 `machine-stop.json`。私有 ADB 和 scrcpy 已退出，应用数据卷保留。未增加登录或人脸验证次数，也未保存真实摄像头帧。日志为本地验证目录中的 `diagnostics/redroid/camera-stack-preflight.log`、`virtual-camera-service-probe.log`、`virtual-camera-probe-errors.log` 与 `camera-integration-result.json`；源码及替代方案文件清单在 `research/redroid/`。

### 2026-10-17 摄像头开发前的业务拒绝对照

用户要求优先判断容器环境是否仍遭到美团拒绝。本轮暂停摄像头驱动适配，复用原 redroid、官方 APK 和应用数据，只做一次正常登录观察；没有修改设备身份、认证返回值或应用权限检查。

重新核对已有动态模块源码：`FaceDetectionSubFragment2.initCamera()` 中的 `CallBackFaceLivenessInit.initSuccess()` 会调用 `info()`，这里是人脸检测模型初始化成功，并非已取得摄像头帧；`onResume()` 也可能在初始化后调用 `info()`。这说明验证参数请求存在早于人脸上传的入口，值得先测。但 `onCameraError()` 会设置 `verifyFlowBlock`、报告相机错误，可能抢先阻断流程。上述是原 AVD 已下载模块的静态分析，不能当作 redroid 实际请求已经执行，也不能保证 redroid 加载相同动态模块。

| 实际观察 | 可以得出的结论 | 仍不能得出的结论 |
|---|---|---|
| 正常登录完成，商品页面可使用 | 当前账号、版本、环境在这次流程可用，可以继续既定加购验证 | 长期无风控、多开或所有账号可用 |
| 再次取得原始业务拒绝码及对应消息 | 当前配置仍被该业务步骤拒绝，需按实际错误继续定位 | 单凭错误码认定容器架构被封禁，或排除缺摄像头、账号、出口等因素 |
| 只有“网络不好”通用弹窗 | 记录自然失败与 SDK 分类，必要时再取原始错误 | 沿用旧 AVD 的 `121118` 作为本轮实际错误 |
| 进入人脸页面后仅报无摄像头／无法开启相机 | 前面的流程可达，当前被摄像头条件阻塞 | 风控已通过，或此前参数请求一定成功 |
| 尚未完成用户短信操作 | 环境准备完成，业务结论待定 | 登录或环境兼容已通过 |

**本轮结果：已取得相同原始错误 `121118`，无须先接好摄像头即可完成这次业务拒绝对照。**

- 启动后 `sys.boot_completed=1`、ADB UID `2000`，默认 Ethernet 网络通过 `VALIDATED`，摄像头数量为零。美团游客首页和登录页可加载。用户明确开始验证后，执行方通过正常 UI 确认登录协议并请求一次短信，填入用户提供的验证码；未重复发短信或重试认证。Android 弹出相机权限申请时选择“仅限这一次”，没有伪造摄像头设备或帧。
- 随后自然出现“您的网络状况不好，请稍后再试”及“返回／再试一次”弹窗。此时未运行调试服务，应用 PID 为 `1615`，ADB 仍为 UID `2000`，网络为 `VALIDATED`，摄像头总数与普通摄像头数仍均为零。普通日志同时记录了 `yoda_face_verify_launch_status=707`；该相机错误分类本身不足以断言弹窗来源或业务拒绝原因。
- 保留自然失败现场后，复用已通过隔离测试的只读错误提取脚本，取得当前唯一显示的 `FaceDetectionSubFragment2` 弹窗、负按钮 `a0` 回调保存的 `Error`：**`code=121118`，`message=当前有问题，请用手机访问`**。应用 PID 在读取前后保持一致。脚本只读取既有错误对象，不替换方法或返回值、不调用认证或重试接口；没有保存验证码、请求令牌、人脸帧或完整错误对象。
- 第一次临时诊断服务通过容器 exec 启动时，因缺少 Android 的 `BOOTCLASSPATH` / `DEX2OATBOOTCLASSPATH` 而在附加应用前退出。给该诊断进程传入 Android shell 的运行时路径后，原弹窗读取成功；ADB 没有切换 root。旧页面观察器也曾因取不到层级而停止，因此自然失败以随后直接读取的 UI 与基线文件为准，不把观察器空白时段当作连续监测证据。
- 读取后仅点击原弹窗“返回”，日志出现 SDK 服务端错误分类 `703`，然后停止美团。临时调试进程、设备临时目录和本机转发均已核对回收；容器停止等待 20 秒后由 Podman 强制终止，随后专用虚拟机成功停止。私有端口 `5039`、`5582`、`5590` 均已关闭；临时诊断依赖与服务端文件清理约 180 MiB，应用数据保留。收尾证据见 `diagnostics/redroid/pre-camera-shutdown.json`。

这证明当前 redroid 配置**没有解除这条业务拒绝**，摄像头接入不是获取本次失败证据的前置条件。它不证明所有容器或云手机均被禁止，也不能单独归因设备身份、调试构建、账号、网络出口或缺摄像头。原 Google APIs AVD 在摄像头持续产帧时也出现 `121118`；两环境错误相同，仍不代表服务端具体命中的规则相同。当前应优先取得已知可用 Android 环境的同账号对照或美团对该错误的明确说明，再评估自建摄像头的投入；没有完成正常登录与加购验收。

独立虚拟机沿用一小时运行、验证目录总量 22 GiB 的上限。准备时目录约 19 GiB、宿主空闲约 56 GiB，本轮没有新增系统镜像。关键证据为本地忽略目录下的 `diagnostics/redroid/pre-camera-natural-failure.json`、`pre-camera-existing-dialog-error.json` 与 `pre-camera-comparison-result.json`；短信操作仅记录动作与时间，不保存验证码。`pre-camera-raw-error.json` 保留第一次工具连接失败，成功结果见前述独立文件，避免把工具失败当作应用结果。

### 2026-10-17 空间清理与保留环境

用户要求删除虚拟机方案，并将原 Android Emulator 环境收敛为一台。确认测试进程、端口均已停止后，通过隔离配置下的 `podman machine rm --force ctrlx-redroid` 删除专用虚拟机，再删除其剩余目录、专用 scrcpy 与临时路径链接。虚拟机磁盘中的 redroid 镜像和应用数据卷一并删除；未修改全局 Podman 连接配置或其他容器环境。

- 删除 redroid 环境约 **4.91 GiB**、Google Play AVD 及其用户数据约 **2.54 GiB**、专属系统镜像约 **2.15 GiB**，并移除已失效的 Play 对照创建、准备和启动脚本。历史章节中的相关入口不再可用。
- 保留 `ctrlx-artemis-api35`：Android 15 / Google APIs ARM64 镜像、原设备应用数据、SDK、ARTEMIS 环境、官方 APK，以及现有 Terminal 摄像头启动入口。该设备已有基础控制和真实摄像头产帧证据，现有任务脚本也默认使用它；保留并不代表美团登录已经通过。
- 目录由 **18.76 GiB** 降至 **9.17 GiB**，释放约 **9.60 GiB**；宿主可用空间由约 **55.42 GiB** 增至 **65.02 GiB**。诊断结果与小型研究文件保留，重跑 redroid 或 Play 对照需要重新部署。
- 清理后 `emulator -list-avds` 仅列出原 Google APIs 设备；其文件大小、修改时间与 inode 未变化，所需系统镜像、脚本和 ARTEMIS 入口仍存在。本轮没有重新启动设备或重测业务流程。清理和核对记录为 `evidence/environment-consolidation-cleanup.json`。

### 复用环境与未执行任务

在仓库根目录，已执行的本地脚本示例：

```sh
validation_root="$PWD/.build-local/android-artemis-validation"
open -a Terminal "$validation_root/scripts/start-camera-in-terminal.command"
"$validation_root/venv/bin/python" "$validation_root/scripts/device.py" chinese-input text 静安寺
"$validation_root/venv/bin/python" "$validation_root/scripts/device.py" basic-swipe swipe 610 995 610 422 600
```

启动脚本目前配置为四核、3 GiB、`webcam0`；仅在私有端口空闲时启动，并保留 AVD 数据。模型调用脚本从现有环境读取 `VOLCENGINE_ARK_API_KEY` / `VOLCENGINE_ARK_BASE_URL`，不在 Terminal 启动文件中嵌入密钥。

后续先解决美团登录并确认商品页面可用，再回到外卖首页。已准备但**未执行**的限时任务入口为：

```sh
python3 "$validation_root/scripts/run-task.py" cart-run-1 "$validation_root/task-goal.txt"
```

它调用 `artemis run --profile flash --standalone --device-serial emulator-5580 --locked-app com.sankuai.meituan --disable-step-summarizer --without-video-recording-tools`，传入任务文本与运行名称。实际加载配置已核对为 `max_turns=30`；外部监督器在 300 秒后终止并回收该任务进程组。第一轮成功后只恢复测试新增的购物车项，再用 `cart-run-2` 执行第二轮。监督器的隔离进程组回收已通过，真实 ARTEMIS 任务退出、超时与设备辅助服务收尾仍待运行验收。

## 后续建议与验收边界

本节整理最近讨论的建议，尚未选定云服务、购买实例或实施 Android 集成。优先取得一套能正常登录美团、并允许 ADB 接入的对照环境；同时分别记录通用 Android 控制与美团业务兼容性，避免一种能力的成功覆盖另一种能力的失败。

### 先核实可复现的云手机条件

优先核对 [UCloud OrderWise 官方案例](https://github.com/ucloud/orderwise-agent)的实际设备镜像、App 版本、登录与人脸处理方式、单实例供应、ADB 权限及费用。10 月 16–17 日查阅时，项目要求预先登录，列出的美团为 `12.49.202`，不同于本机的 `12.67.203`；公开演示不能替代这些条件。未取得可复现条件前，不追加本机系统镜像或直接采购整套云机资源。

[阿里云无影官方 FAQ](https://help.aliyun.com/zh/ecp/cloud-phone-faq/)已列出 macOS 和手机浏览器摄像头重定向，可作为备选；选型时还需核实 [ADB 网络条件](https://help.aliyun.com/zh/ecp/how-to-connect-cloud-phone-via-adb)和关联资源费用。[火山手机扫码验证流程](https://www.volcengine.com/docs/6394/2603617)可参考真人接管方式，但尚未在本账号实测。供应商能力按资料查阅日期记录，开通前重新核对。

### 用一次有区分力的对照决定是否继续

1. 在选定实例上使用厂商客户端和官方美团 App，先由用户完成正常登录及必要的人脸验证，确认商品页面可用。首次业务对照暂不启用 ARTEMIS Helper；尽量保持同一账号与 App 版本，无法保持的变量单独记录。
2. 登录成功后再接入现有 ARTEMIS，验证截图、输入、层级和辅助服务，然后执行原定两次仅加购任务。人工登录属于前置操作，不计为 Agent 自主完成；不提交订单或付款。
3. 分别保存手动登录、自动化接入前后和两次任务的结果。每项任务沿用 30 轮或 5 分钟限制；同一登录阻塞排查达到 15 分钟后，保留证据并停止该轮，不用连续短信重试替代定位。
4. 若业务对照通过，再评估该设备是否值得接入 CtrlX。若仍失败，优先取得厂商或美团对错误的明确说明；既有证据不足以支持继续盲换镜像、品牌属性或追加摄像头驱动开发。

### CtrlX Android 控制保持可复用

建议首版围绕指定 ADB 设备实现发现／连接、截图、层级观察、点击、滑动、文本输入、返回／Home、应用安装与启动，以及人工接管。`agent-android` 为拟议技能名，本仓库尚未交付该技能或 Android CLI；上述能力清单是实施建议，不能当作现有产品能力。

由 Codex 直接组合控制工具；ARTEMIS 保留为独立任务执行与验证工具，不预先成为每次控制的必需模型循环。先用已保留的本机 AVD 验收通用控制，后续云手机或真机可复用 ADB 操作层；设备启动、授权、画面传输和摄像头分别按实际后端适配，不提前建设多厂商调度框架。

远程摄像头仍是独立能力：Viewer 端需经本人授权采集实时画面，传输至设备侧，再通过相应 Camera HAL/provider 或厂商重定向接口供 App 使用。当前 CtrlX 未实现此链路；本机 AVD 通过 Terminal 使用 Mac 摄像头的结果不能代替远程 Viewer 验收。

如果产品要求完全在 Mac 本地运行，当前美团兼容性仍是未解决风险。通用 Android 控制可以独立验证，但应保留“美团完整登录与自主加购未通过”的状态；显示性能、多开容量、远程 Viewer 和跨机器兼容也尚未验收。

## 关键证据索引

以下路径相对于本 worktree 的 `.build-local/android-artemis-validation/`，均为本地忽略产物，未纳入 Git。文档保存结论、方法与版本，不能保证其他 checkout 拥有这些证据或可直接执行本机脚本；后续清理前应先保留需要的脱敏结果。原始验证码、请求令牌和人脸画面不作为交接材料。

| 要复核的结论 | 证据入口 |
|---|---|
| ARTEMIS 基础控制与模型探针 | `evidence/basic-controls.json`、`evidence/artemis-model-probe.json` |
| 原 AVD 摄像头持续产帧 | `evidence/camera-reopen-frames.json` |
| 原 AVD 自然失败与 `121118` | `diagnostics/face-network/error-observer/meituan-baseline.json`、`diagnostics/face-network/error-observer/meituan-observation.json` |
| Google Play 发布镜像仍失败，但原始错误码未知 | `diagnostics/face-network/playstore-failure-system-state.json`、`diagnostics/face-network/playstore-return-events.json` |
| OrbStack 内核预检与 redroid 摄像头失败 | `diagnostics/redroid/orbstack-kernel-preflight.json`、`diagnostics/redroid/camera-integration-result.json` |
| redroid 摄像头为零时的自然失败及原始错误 | `diagnostics/redroid/pre-camera-natural-failure.json`、`diagnostics/redroid/pre-camera-existing-dialog-error.json` |
| 删除环境、释放空间及保留设备核对 | `evidence/environment-consolidation-cleanup.json` |

## 参考

- [现有 ARTEMIS 调研](ios-simulator-research.md#补充调研google-artemis)
- [ARTEMIS 使用说明](https://github.com/google/artemis)、[执行配置](https://github.com/google/artemis/blob/main/config/artemis.jsonc)
- [Android 命令行工具](https://developer.android.com/tools)、[模拟器硬件加速](https://developer.android.com/studio/run/emulator-acceleration)
- [Android 模拟器代理](https://developer.android.com/studio/run/emulator-networking-proxy)、[网络能力状态](https://developer.android.com/reference/android/net/NetworkCapabilities)
- [Android 官方虚拟设备与发布镜像说明](https://developer.android.com/studio/run/managing-avds)
- [美团官方下载](https://i.meituan.com/client/homemt)
- [美团人脸验证帮助](https://verify.meituan.com/faceHelp)
- [美团 SDK 隐私说明](https://page.meituan.net/html/1696833795514_21186e/index.html)
- [火山引擎云手机 SDK 发布记录](https://www.volcengine.com/docs/6394/171481)、[阿里云无影云手机 FAQ](https://help.aliyun.com/zh/ecp/cloud-phone-faq/)
