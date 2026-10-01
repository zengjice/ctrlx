# CtrlX

[English](README.md)

> **Your tmux, Your Agent, everywhere.**

CtrlX 是一个以 tmux 为核心的远程终端，让你从另一台 Mac 或 iPhone 查看并控制任意一台
已配对 Mac 的 tmux 工作区。它直接复用现有 tmux session，不创建专有的会话模型。

<p align="center">
  <img src="docs/assets/ctrlx-architecture.svg" width="100%" alt="CtrlX 让终端持续运行在 tmux 中，并通过端到端加密 Relay 连接 Mac 和 iPhone Viewer。" />
</p>

## 为什么选择 CtrlX

- **原生 tmux：** 直接发现和共享已有 session、window 和 pane；关闭 CtrlX 或网络中断，
  任务仍会继续运行。
- **多 Host 漫游：** 从一台 Mac 或 iPhone 控制家里、办公室或异地 Mac 上的 tmux 工作区。
- **理解 Session 上下文的语音输入：** iPhone 语音输入会结合当前终端 session 的上下文，
  自动纠正你说的话。
- **Agent 感知：** 识别 Claude Code、Codex 及 sidecar plugin 扩展 Agent 的运行、完成、
  权限请求、提问和计划审批状态。
- **安全 Relay：** 所有设备只建立出站连接，终端帧在 Host 和 Viewer 之间保持端到端加密。

即使没有 Agent plugin，CtrlX 仍然是完整的 tmux 远程终端。

## 快速开始

### 安装 macOS 版

CtrlX 目前要求 Apple Silicon、macOS 15 或更新版本，并已安装 tmux：

```bash
brew install tmux
curl -fsSL https://ctrlx.zengjice.com:7001/install/mac.sh | bash
```

安装器会校验安装包并仅替换 `/Applications/CtrlX.app`，已有 tmux session 不会中断。当前
安装包使用 Apple Development 签名，尚未 notarize，也不是 App Store 发行包。

### 复用并共享 tmux session

继续使用标准 tmux 命令：

```bash
tmux new -s coding
tmux attach -t coding
```

打开 CtrlX 后，session 会出现在 Local 下。连接另一台 Mac 或 iPhone：

1. 在 Host Mac 上生成配对码。
2. 让 Viewer 连接同一个 Relay 并输入配对码。
3. 选择 Host、session、window 和 pane。

学习交流可以使用官方提供的 Relay：`wss://ctrlx.zengjice.com:7001`。

iOS App 目前需要使用 Xcode 本地签名安装；只有后台通知需要 Relay 配置与该构建匹配的
APNs 凭据。

## 安全与自托管

- Relay 只处理配对元数据和密文路由，不能解密终端帧。
- Host 不需要公网 IP，也不需要开放 tmux、SSH 或 App 入站端口。
- 自托管不要求 CtrlX 账号、订阅或外部组网服务。
- 启用 BYOK 语音纠错时，语音候选和有界 pane 上下文会直接发送给所选 provider，
  不经过 CtrlX Relay。

参见 [Self-hosting CtrlX Relay](docs/self-hosting.md) 和
[Relay monitoring runbook](docs/monitoring.md)。

## 开发

构建要求近期 Xcode、Swift 6.3 或更新版本，以及 macOS 15 或更新版本。打开
`Ctrlx.xcworkspace`，macOS 使用 `CtrlxServer` scheme，iOS 使用 `Ctrlx`
scheme。内部 Swift 模块统一使用 `Ctrlx*` 前缀，产品名称为 `CtrlX`。

```bash
swift test --package-path CtrlxPackage

./sbin/auto-env.sh
./sbin/start_server.sh
```

仓库约定以及 iOS 构建、打包和真机安装流程见 [AGENTS.md](AGENTS.md)；贡献和发布流程见
[CONTRIBUTING.md](CONTRIBUTING.md) 与 [RELEASE.md](RELEASE.md)。

## 许可证与来源

CtrlX 是基于 [Gallager](https://github.com/gpambrozio/Gallager) 的独立发行版，基线为
2026-08-14 的 commit `919c7772928531d4d0bb266bdf275691d361901e`。CtrlX 由
ZengJice 维护，与 Gallager 项目不存在隶属或官方背书关系。

CtrlX 以 [GNU AGPL-3.0](LICENSE) 发布。已发布二进制和托管 Relay 都会标识对应的不可变
源码 commit，Relay 通过 `/version` 和 `/source` 暴露该信息。另见 [NOTICE.md](NOTICE.md)、
[MODIFICATIONS.md](MODIFICATIONS.md) 和 [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)。
