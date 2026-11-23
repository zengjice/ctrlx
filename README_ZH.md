# CtrlX

[English](README.md) · [功能清单](#功能清单) · [在 Mac 上试一次](#在-mac-上打开第一个项目) · [使用文档](docs/README.md)

CtrlX 是一款 AI 工作台，让你在自己的 Mac 上同时使用 Codex、Claude Code、Traex 等 Agent。换到 iPhone 或另一台 Mac，你仍能回到同一个会话，任务继续在原机上运行。写邮件时想查个术语，可以一键唤起 Mac 上的全局 Agent Orbie。我们还计划让同事 Mac 上的 Agent 加入你的项目。

## 已经在用 Codex 或 Claude Code？先试这四件事

- **让 Codex 开发，Claude Code 评审。** 在同一台 Mac 上，用 Workflow 的「开发／评审／修复」模板选好两个 Agent 标签。Codex 明确完成后，Claude Code 开始评审，意见自动交回原来的 Codex 对话。[试用这个模板](docs/multi-agent-design.md#developer--reviewer先开发再评审判断修复)
- **给临时任务换一家模型服务。** 在 Mac 版 CtrlX 的 Codex 或 Claude Code 标签按 ⌘F，从 **Target Provider** 选同一款 CLI 已配置的另一家服务。新 Agent 带着已有讨论去查 bug，你在原对话继续开发。
- **在 iPhone 上亲手验收。** 接管 Agent 在 Mac 上打开的 `localhost` 网页或 iOS 模拟器，点一下刚改的按钮。发现位置偏了，就在截图上圈出来，发回原对话。[看一次完整验收](#比如给报表加一个导出按钮)
- **一起看两家的账号额度。** Dashboard 把 Codex 和 Claude Code 提供的剩余额度和重置时间列在一起。办公室和家里的 Mac 共用同一份额度时，只显示一次。

## 连贯的上下文

| 你能做什么 |
| --- |
| **带现场上下文的语音输入。** 中英文混着说需求时，CtrlX 会参考你当前的项目名和终端输出，帮你写对分支名和文件名。 |
| **跨操作区人机协作。** 在文件预览、网页或模拟器里圈出问题，把标注图发回原对话，让 Agent 照着改。 |
| **跨设备控制。** 换到 iPhone 或另一台 Mac，仍能打开开发机上的同一个终端标签，继续输入命令或答复 Agent。 |
| **快速 Fork。** 临时要开发另一个需求或排查 bug 时，从当前对话分出一个 Agent。它带着已有的项目背景接手，你在原对话继续手头的工作。 |
| **跨用户 Agent 协作（规划中）。** 你的开发 Agent 和同事的测试 Agent 各自在本机运行，也能加入同一个 Room 一起联调接口。 |

## 可靠的长程任务

| 你能做什么 |
| --- |
| **把经验编成可靠的 Workflow。** 你可以亲自编排，也可以和 Orbie 一起设计步骤。启动前，由你确认哪个 Agent 负责哪一步、要交付什么、何时交接。 |
| **按约定自动交接。** 比如，等 Codex 明确完成开发，再让两个 Agent 分别检查实现和测试。两份评审意见到齐后，Workflow 才把问题交回 Codex 修复。 |
| **任务持续运行。** iPhone 断开后，Agent 仍在开发机上工作。任务要跑一整晚时，可开启「保持 Mac 唤醒」。 |
| **提问与审批通知。** Agent 需要你答复时，点 iPhone 上的通知就能回到对应标签。 |
| **重启后接着做。** 开发机重启后，查看已完成步骤的结果，点 **Continue** 继续工作流。[工作流说明](docs/multi-agent-design.md) |

## 产品架构

全局 Agent **Orbie** 和 **Workflow** 都运行在你自己的 **Host Mac** 上。你可以从 Orbie 的对话中分出 **Orbiter** 处理支线，也可以请 Orbie 查看关联工作流的进展。目前由你在 Workflow 里确认分工并启动流程。下图中 Orbie 指向 Workflow 的箭头表示未来可由 Orbie 直接控制工作流。

![CtrlX 目标架构。Orbie 和 Workflow 位于你的 Host 上，两者之间的箭头表示规划中的直接控制。Room 内的开发 Agent 使用 Codex，测试 Agent 使用 Claude Code。Lin、Mia 和 Sam 的 Agent 将经 Relay 从各自的 Host 加入。已配对的 iPhone 和 Mac 也通过 Relay 接入，Android Viewer 在规划中。](docs/assets/ctrlx-architecture.svg)

- **远程控制。** iOS 和 macOS **Viewer** 已支持通过 **Relay** 端到端加密接入你的 Host。Android Viewer 在规划中。
- **跨 Host 协作。** 目前，同一工作流的 Agent 在同一台 Host 上执行任务。规划中的 **Room** 把做同一件事的 Agent 聚在一起，同事的 Agent 可以经 Relay 加入，仍在各自的 Mac 上工作。

## 比如，给报表加一个导出按钮

1. **在 Mac 上提需求。** 附上报表截图，口述「在筛选器旁边加一个导出 PDF 的按钮，保留列顺序」。看一眼草稿再发。[上下文语音输入](docs/terminal-quick-actions.md#context-aware-voice-input)
2. **在 iPhone 试一次导出。** 点提问通知，答「导出所有符合筛选条件的记录」。在 **Browser** 接手 Agent 打开的 `localhost` 页面，点导出，从下载记录进入 **Files** 查看 PDF。[浏览器下载](docs/agent-browser.md#human-downloads)
3. **把问题指给原 Agent。** 发现最右边的长列名被截断，就在 PDF 上圈出来，把标注图放进原 Agent 的草稿，加一句「请显示完整列名」再发。[文件标注](docs/file-browser.md#in-place-preview-annotation)
4. **修完再验收。** 在 Workflow 里让 Claude Code 评审筛选条件和列顺序，把问题交回 Codex 修复。回到 iPhone 再导出一次，确认记录符合筛选条件、长列名显示完整、列顺序正确。

## 开始使用

### 在 Mac 上打开第一个项目

在运行 **macOS 26 或更新版本的 Apple Silicon Mac** 上安装 tmux 和 CtrlX。

```bash
brew install tmux
curl -fsSL https://ctrlx-1256844776.cos.ap-guangzhou.myqcloud.com/macos/mac.sh | bash
```

打开 CtrlX 就能看到已有的 tmux 会话，只用普通终端也可以。要使用 Agent，先在这台 Mac 上安装并登录它的 CLI，在 **Settings → Agents** 配置集成，然后选 **New Session → Start in Directory…** 打开项目。已有会话里用 **+ → New Agent…** 添加标签。

第一次可以点麦克风问「这个项目怎么在本地跑起来？」再点一下结束录音，核对草稿后发送。

CtrlX 内置 Codex、Claude Code 和 Traex 集成，另有 OpenCode、pi 和 omp 插件。提问和 Fork 等操作取决于所用 Agent。正式 Mac 安装包经过 Developer ID 签名和 Apple 公证。

### 从 iPhone 或另一台 Mac 连接

1. **安装 Viewer。** 在另一台 Mac 或 iPhone（**iOS 18 或更新版本**）上安装 CtrlX。
2. **选择同一 Relay。** 两端都使用托管中继 `wss://ctrlx.zengjice.com:7001`，或都填入你的自建中继地址。
3. **输入配对码。** 在运行 Agent 的 Mac（Host）上生成配对码，在 Viewer 输入，打开原来的会话即可继续工作。

如果已有适用于这台 iPhone 的 CtrlX 签名 IPA，用 USB 把 iPhone 连到 Mac，在 Mac 版 CtrlX 中选择 **File → Install IPA on iPhone…** 即可安装。也可以用 Xcode 本地构建并签名。[本地签名安装](RELEASE.md#local-overwrite-installation)

远程使用期间，Host 需保持唤醒、联网并运行 CtrlX。如果 Relay 要求访问密钥，请在 Host 的 **Settings → Relay** 保存密钥。自建 Relay 如需向 iPhone 推送通知，还需配置 APNs。[Relay 访问密钥](docs/self-hosting.md#optional-account-authentication-and-traffic-quotas) · [推送配置](docs/self-hosting.md#apns)

## 隐私与开源

两端都主动连接 Relay，Host 无需开放入站端口。工作区内容只有配对设备能解密。自托管 Relay 的默认开放模式无需 CtrlX 账号或订阅。[架构与加密](docs/architecture.md) · [自托管指南](docs/self-hosting.md)

Agent 使用你配置的 AI 服务。若开启云端语音纠错，候选文本和当前终端的一小段上下文会直接发送到你选择的服务。[语音与快捷操作](docs/terminal-quick-actions.md)

Mac App、iOS App 和 Relay 均开源。[技术文档](docs/README.md) · [贡献指南](CONTRIBUTING.md) · [构建说明](AGENTS.md)

## 许可证与来源

CtrlX 是基于 [Gallager](https://github.com/gpambrozio/Gallager) 的独立发行版，基线为
2026-08-14 的 commit `919c7772928531d4d0bb266bdf275691d361901e`。CtrlX 由
ZengJice 维护，与 Gallager 项目不存在隶属或官方背书关系。

CtrlX 以 [GNU AGPL-3.0](LICENSE) 发布。已发布二进制和托管中继服务会标识对应的源码 commit，
中继服务通过 `/version` 和 `/source` 提供版本与源码信息。另见 [NOTICE.md](NOTICE.md)、
[MODIFICATIONS.md](MODIFICATIONS.md) 和 [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)。

## 功能清单

| 场景 | 功能 | 你能做什么 |
| --- | --- | --- |
| **工作区** | 项目终端 | 在项目目录打开终端，或接着使用 Mac 上已有的 tmux 会话。 |
| | 多种 Agent | 在同一项目里使用 Codex、Claude Code、Traex，或通过插件接入 OpenCode、pi、omp。 |
| | 标签与分屏 | 把 Agent 和它打开的工具标签放在一组，分屏对照终端与运行结果。 |
| | 跨设备接续 | 从 iPhone 或另一台 Mac 回到同一标签继续输入，断开后 Agent 仍在 Host 上运行。 |
| | 工作区恢复 | 启用后，Mac 重启也能找回标签、分屏和 CtrlX 编辑器里的草稿。 |
| | 对话续接 | 受支持的 Codex 和 Claude Code 版本可自动恢复已核实的对话，也可从恢复面板手动点 **Resume**。 |
| **输入与反馈** | 上下文语音输入 | 口述需求时，语音纠错可参考终端里的分支名和路径，核对草稿后再发。 |
| | 提示词编辑器 | 在 Codex 或 Claude Code 中按 Ctrl-G 打开配置好的编辑器，写完多行需求再送回终端。 |
| | 快捷指令 | 从当前 Agent 的指令菜单选常用命令，例如在 Codex 里选 `/diff` 查看改动。 |
| | 快捷短语 | 把常用要求存成一键可插入的短语，两台配对设备都启用同步后即可共用。 |
| | iPhone 自定义按键 | 把常用文本、Tab 或 Ctrl-C 放在终端键盘上方，按一下即可输入。 |
| | iPhone 系统分享 | 从其他 App 分享后，可把照片加入所选 Agent 的草稿，或把文件上传到当前 Files 目录。 |
| | 远程剪贴板 | 复制 Host 文件里的文字或图片到当前设备，也可把剪贴板图片粘贴到 Host 目录。 |
| | 截图标注 | 在文件预览、网页或模拟器里圈出问题，把标注图放进所选 Agent 的输入框。 |
| **Agent 协作** | 全局 Agent · Orbie | 在本机启用 Orbie，到 **Settings → General → Orbie** 设好快捷键，就能从任意 Mac App 唤起同一段对话。 |
| | 任务分身 · Orbiter | 从 Orbie 的对话分出一个 Orbiter，让它带着已有上下文独立处理支线。 |
| | 快速 Fork | 在 Mac 的 Codex 或 Claude Code 标签按 ⌘F 可在当前目录分出新对话。要隔离两项任务的代码改动，可从 Fork 菜单新建 Git worktree。 |
| | 模型与推理强度 | 在支持模型切换的 Agent 标签里，把常用模型和推理强度放到状态栏，等 Agent 空闲时点选切换。 |
| | 账号切换 | 使用 Codex 或 Claude Code 官方账号时，可登出 Host 上该 CLI 配置共用的账号，再回到原对话手动登录。 |
| **长程任务** | Workflow 编排 | 保存常用流程，下次仍可让同一台 Mac 上的 Agent 按你设定的分工和交接条件执行。 |
| | 工作流续跑 | Host 重启后查看已完成步骤的结果，点 **Continue** 接着执行。 |
| | 提问与审批通知 | 在 iPhone 锁屏上点通知，直接回到等待你答复的 Agent 标签。 |
| | 用量与额度 | 在 Dashboard 查看 Host 资源用量，以及服务商提供的账号额度和重置时间。 |
| | 保持 Mac 唤醒 | 长任务运行期间可阻止 Host 因空闲而睡眠。 |
| **查看与验收** | 项目文件 · Files | 浏览、搜索和传输 Host 文件，点开 Markdown 链接读文档，也能直接播放视频。 |
| | 终端文件链接 | 点开 Agent 输出里的文件链接，直接预览图片、Markdown 或 Mermaid 图。 |
| | Git 改动 | 在 Mac 的 Git 标签查看文件差异，在 worktree 列表查看各分支还有多少提交未合入本地主分支。 |
| | Host 浏览器 | 从配对设备操作 Host 上的 Chromium，包括打开 `localhost`、听网页音频和下载文件。 |
| | iOS 模拟器 | 从配对设备查看和操作 Mac 上的模拟器，或让 Agent 录下复现过程。 |
| | 工具控制权 | 在网页或模拟器上接手操作，完成后把控制权交还给 Agent。 |
| | iPhone 真机安装 | 在 Mac 上选择本地 IPA，直接安装到通过 USB 连接的 iPhone。 |
| **连接与隐私** | 加密配对与自托管 | 通过托管或自建的 Relay 端到端加密连接设备，Host 无需开放入站端口。 |
| **规划中** | 跨用户 Room | 邀请同事的 Agent 加入同一个 Room 协作，各自在自己的 Host 上运行。 |
| | Android Viewer | 从 Android 设备连接已有的 Mac 工作区。 |
