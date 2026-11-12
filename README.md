# moonmedic 🥮🩺

> MoonBit 写的 Kubernetes 排障 Agent —— 给你的集群请一位医生。

**2026 MoonBit 黑客松 · 十一月赛 参赛项目**(🚧 设计阶段,开发即将开始)

## 它做什么

把集群里的问题丢给 moonmedic,它自己查、自己想、自己给结论:

```
你  : 这个 Pod 为什么一直重启?
moonmedic: 正在检查……
  ├─ Pod payments-api-7d9f6b-x2k9l 处于 CrashLoopBackOff
  ├─ 上次退出码 137(SIGKILL),重启 12 次
  ├─ 上次终止原因: OOMKilled(内存限制 256Mi,请求 1.8Gi)
  └─ 诊断: 内存限制过低,建议提高 memory limit 至 2Gi,
          或排查是否存在内存泄漏(容器已运行 3 天, RSS 持续上涨)
```

### 计划覆盖的诊断场景

- [ ] `CrashLoopBackOff` / `OOMKilled` —— 退出码、终止原因、资源限制关联分析
- [ ] `Pending` —— 事件、资源配额、亲和性/污点、PV 绑定逐项排查
- [ ] 镜像拉取失败 —— `ImagePullBackOff`、Secret 缺失、仓库可达性
- [ ] 探针失败 —— liveness/readiness 事件与端点状态
- [ ] 资源水位 —— 结合 Prometheus 指标看容量趋势

### 设计原则

- **只读护栏**:诊断工具集只含只读操作(get/describe/logs/events),
  不对集群做任何变更;修复建议只输出,不执行
- **证据优先**:每条结论都附带来自集群的事件、日志或指标引用
- **生态共建**:站在 MoonBit 社区生态上构建 ——
  [`kubemoon`](https://mooncakes.io/docs/cxh04/kubemoon)(集群访问)、
  [`mizchi/llm`](https://mooncakes.io/docs/mizchi/llm)(LLM 调用)、
  [`moon-prometheus-sdk`](https://mooncakes.io/docs/guiqi695/moon-prometheus-sdk)(指标)

## 路线图

| 阶段 | 内容 |
|---|---|
| W1 | MoonBit 环境、仓库骨架、kubemoon 连通(PoC) |
| W2 | 只读工具集 + 诊断循环(单场景: CrashLoopBackOff) |
| W3 | 扩展场景(Pending / 镜像 / 探针)+ 故障注入评测集 |
| W4 | 报告输出、CI、文档打磨、验收演示 |

## 开发

依赖:MoonBit 工具链([moon](https://www.moonbitlang.com/download/))、kubectl + 有效 kubeconfig。

**W1 已达成:kubemoon 只读连通**(MoonBit 客户端成功列出集群 pods)。

```bash
# 终端 1:启动本地代理(kubectl 负责认证;Rancher 类 server 路径必须加 --append-server-path)
kubectl proxy --port=8001 --append-server-path

# 终端 2:运行 PoC(只读列出 kube-system 的 Pod 名)
moon run cmd/main
```

环境变量可切换目标:`MOONMEDIC_SERVER`(默认 `http://127.0.0.1:8001`)、
`MOONMEDIC_TOKEN`、`MOONMEDIC_CA_FILE`(直连 API Server 时)、
`MOONMEDIC_NAMESPACE`(默认 `kube-system`)。

> PoC 全程只发 GET 请求;后续所有诊断工具都将限制在只读白名单内。

## 许可证

[Apache-2.0](LICENSE)
