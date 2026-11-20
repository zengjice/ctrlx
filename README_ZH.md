<p align="center">
  <img src="Brand/CtrlX-AppIcon.png" width="80" alt="CtrlX 应用图标" />
</p>

# CtrlX

[English](README.md) · [开始使用](#开始使用) · [使用文档](docs/README.md)

> **AI 在 Mac 上工作，你用电脑或手机接着做。**

CtrlX 让你在 Mac 和 iPhone 上跟进 Codex、Claude Code 等编程 Agent 的工作：
交代需求、回答问题、检查成果，再把反馈交回去。
项目和 Agent 都留在原来的 Mac 上，换设备后继续的是同一段对话、同一份工作。

如果你同时推进几个项目，或经常在等待 AI 时离开工位，CtrlX 可以帮你看清谁在工作、
谁在等你，以及该打开哪段对话继续。

[安装 Mac 版](#开始使用) · [iPhone 安装方式](RELEASE.md#local-overwrite-installation)

## 交代清楚，然后去忙别的

给 Agent 一段需求、一张截图，或者直接说出你的想法。语音输入会尝试结合当前项目的终端上下文
纠正技术词和中英文混合表达，你可以检查文字后再发送。经常重复的要求可以存成快捷短语。

任务开始后，可以离开电脑。Agent 完成工作、提出问题或请求许可时，CtrlX 会提醒你。
从 iPhone 点开通知，回到相应的对话，补充一句话或处理确认，让工作继续。
用手机拍下的照片、从其他 App 分享来的文件，也可以带回项目。

你仍然可以随时打开完整终端，查看过程、补充指令或接手操作。

## 它说「做好了」，你能马上试一试

验收一个结果，往往需要亲自打开它。即使人在外面，也可以从手机查看 Mac 上的成果：

- **做网页时**，打开 Mac 正在运行的本地页面，点按钮、填表单、播放声音，看看实际效果。
  页面沿用 Mac 上的运行环境和登录状态，不需要先把开发服务发布到公网。
- **做 iOS App 时**，查看并操作 Mac 上的模拟器，走一遍用户流程。模拟器仍在 Mac 上运行。
- **写文档或生成文件时**，点开 Agent 给出的文件链接，阅读 Markdown、查看图片和 PDF、播放视频，
  或把文件下载到当前设备。回到 Mac 后，还可以在终端旁查看代码差异。

看到需要调整的地方，直接在截图上圈出来、画箭头，附上一句说明交给 Agent。
它也可以使用 CtrlX 提供的浏览器和模拟器工具自行检查；你可以看到操作过程，并在需要时接管。

## 几件事一起做，也能各自跟进

让一个 Agent 开发，另一个评审，同时保留日常终端。在一个地方查看它们的状态和用量，
按项目整理对话，选择适合各项工作的模型；需要对照时，在 Mac 上分栏或打开独立窗口。

遇到值得试的新方向，可以 **Fork 当前对话**，让新的 Agent 带着已有上下文继续探索，
原来的讨论仍然保留。需要隔离代码改动时，可以把不同工作安排到独立的 Git worktree 中。

对于经常重复的开发、评审、修复，可以把交接关系保存成 **工作流**。
例如让开发结果交给评审 Agent，再把意见交回修复；也可以让多个评审者并行检查，最后汇总。
你决定由谁做哪一步，并可以从电脑或手机暂停、继续或停止流程。
当前一个工作流的 Agent 在同一台 Mac 上运行。

[如何安排 Agent 协作](docs/multi-agent-design.md)

## 换个地方，继续原来的工作

办公室的 Mac、家里的 Mac，可以从同一个入口连接。换设备时回到已有会话，
不用把项目和开发环境搬到手机上。关闭查看窗口或临时断网，Mac 上的终端进程仍会继续运行。

启用工作区恢复后，重启 Mac 可以恢复保存的布局和受支持的 Agent 对话；
需要人工处理时，也能从远端找到恢复入口。

如果你还想有一段随时能唤起的固定对话，可以试用 **Orbie**：在 Mac 上按全局快捷键叫出它，
接着之前的对话讨论，查找相关工作，再回到相应的 Agent 标签。专门的工作可以新建 **Orbiter**，
或者从 Orbie Fork，带上对话上下文后独立继续。Orbie 目前是本机 Mac 上的早期功能。

## 开始使用

先在一台 Mac 上完成第一次对话，再连接其他设备。

### 在 Mac 上试一次

需要 Apple Silicon Mac、**macOS 26 或更新版本**，以及已安装、登录的 Agent CLI。
CtrlX 内置 Codex 和 Claude Code 集成，也可通过插件连接 OpenCode、pi 和 omp；
具体交互能力随 Agent 而异。

安装 tmux 和 CtrlX：

```bash
brew install tmux
curl -fsSL https://ctrlx-1256844776.cos.ap-guangzhou.myqcloud.com/macos/mac.sh | bash
```

打开 CtrlX，在 **Settings → Agents** 配置集成，再从 **New Session → Start in Directory…**
选择项目目录和 Agent，启动第一次对话。可以先交给它一件小事，例如「阅读这个项目的 README，
告诉我该从哪里开始，先不要修改代码」。

已有 tmux 会话会自动显示；在会话的标签栏点击 **+ → New Agent…** 可以增加 Agent，
也可以新建普通终端。

正式 Mac 安装包已签名并经过 Apple 公证。Agent 继续使用你配置的 AI 账号或 API 服务。

### 在手机或另一台 Mac 上接着做

1. 在另一台设备安装 CtrlX。iPhone 需要 **iOS 18 或更新版本**，目前通过
   [本地签名安装](RELEASE.md#local-overwrite-installation)，尚未提供 App Store 下载。
2. 两端使用同一个 Relay（连接设备的中继服务）。可以填写 `wss://ctrlx.zengjice.com:7001`，
   或[自行部署](docs/self-hosting.md)。若所选服务要求访问密钥，请在运行项目的 Mac 上打开
   **Settings → Relay → This Mac · Relay Traffic → Access Key**，填写后点击 **Save Access Key**。
3. 在运行项目的 Mac 上生成配对码，在另一台设备输入。打开刚才的对话，继续下一句话。

远程使用时，运行项目的 Mac 需要保持唤醒、联网并运行 CtrlX。
iOS 后台提醒还需要中继服务配置匹配的 APNs 推送，详见[推送配置](docs/push-notifications-plan.md)。
查看 iOS 模拟器时，运行项目的 Mac 还需要 Xcode 和相应的模拟器运行时。

## 项目和对话放在哪里

项目、开发环境和 Agent 的原生对话历史仍在你的 Mac 上。跨设备的工作区通信采用端到端加密，
中继服务能处理连接元数据，但无法读取终端内容。你可以自行部署中继，默认开放模式无需 CtrlX
账号或订阅，也不需要为 Mac 开放 SSH 入站端口。

如果启用云端语音纠错，语音候选和有限的终端上下文会直接发送给你选择的服务提供方。
更多说明见[连接与加密](docs/architecture.md)和[自托管指南](docs/self-hosting.md)。

## 文档与开源

[文件与分享](docs/file-browser.md) · [浏览网页](docs/agent-browser.md) ·
[测试 iOS App](docs/agent-simulator-design.md) · [语音与快捷操作](docs/terminal-quick-actions.md) ·
[Orbie](docs/global-agent-design.md)

Mac App、iOS App 和中继服务均开源。查看[版本记录](MODIFICATIONS.md)、
[技术文档](docs/README.md)、[贡献指南](CONTRIBUTING.md)和[构建说明](AGENTS.md)。

## 许可证与来源

CtrlX 是基于 [Gallager](https://github.com/gpambrozio/Gallager) 的独立发行版，基线为
2026-08-14 的 commit `919c7772928531d4d0bb266bdf275691d361901e`。CtrlX 由
ZengJice 维护，与 Gallager 项目不存在隶属或官方背书关系。

CtrlX 以 [GNU AGPL-3.0](LICENSE) 发布。已发布二进制和托管中继服务会标识对应的源码 commit，
中继服务通过 `/version` 和 `/source` 提供版本与源码信息。另见 [NOTICE.md](NOTICE.md)、
[MODIFICATIONS.md](MODIFICATIONS.md) 和 [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)。
