# 阶段 2：当前运行态与事件入口

状态：代码及本机定向测试通过；真实 Agent 的跨设备验证仍待执行。

- [x] 确认插件、PID 或启动时间改变时，清除 hook 拥有的旧状态，再建立新运行态。
- [x] 增加插件替换、PID 替换及 PID 复用的回归测试。
- [x] 统一事件来源验证、应用前复核和历史 invocation 结果分流。
- [x] 当前对话迁移证据与普通迟到事件的边界。
- [x] native 缓存与恢复描述的同步失效，保留正常 Resume 意图。
- [x] sidecar／Host 合成事件证据及 SessionEnd 退出语义。
- [x] Review 1：OpenCode 启动占位切到真实 root；pi／omp 同进程 A→B→Resume A，保留来源序号与迟到事件拒绝。
- [x] 定向测试、格式、边界检查及阶段验收记录。

证据与未实测范围见 [验收记录](ACCEPTANCE.md)。
