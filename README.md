# moonmedic 🥮🩺

> MoonBit 写的 Kubernetes 排障 Agent —— 给你的集群请一位医生。

**2026 MoonBit 黑客松 · 十一月赛 参赛项目**(W1–W4 已交付,真集群端到端验证)

[![ci](https://github.com/young9682/moonmedic/actions/workflows/ci.yml/badge.svg)](https://github.com/young9682/moonmedic/actions/workflows/ci.yml)

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

### 工作方式(三层,层层可降级)

1. **只读工具层** —— 基于 [`kubemoon`](https://mooncakes.io/docs/cxh04/kubemoon)
   动态客户端,白名单工具(get_pod / get_events / get_logs / list_pods),
   全程仅 GET,从架构上杜绝写操作
2. **规则引擎层** —— 表驱动诊断知识库(OOMKilled / CrashLoop exit 1 /
   FailedScheduling 等规则),纯 MoonBit、确定性、可单测;
   没有LLM 也能给出初诊
3. **Agent 循环层**(LLM)—— 兼容任意 OpenAI 接口端点
   (DeepSeek / GLM / Kimi / vLLM / OpenAI),模型自主决定下一步取证
   (OpenAI tool-calling 线格式,循环设计参考
   [`mizchi/llm`](https://mooncakes.io/docs/mizchi/llm) 的
   `run_json_chat_loop`),最后归纳为带证据引用的 Markdown 报告;
   LLM 不可用时自动降级为纯规则报告,永不阻塞

### 设计原则

- **只读护栏**:工具集只含只读操作,不对集群做任何变更;
  修复建议只输出,不执行
- **证据优先**:每条结论都附带来自集群的状态、事件或日志引用;
  提示词强制"只依据证据、不足需明示"
- **优雅降级**:任一层失败都在报告"数据完整性说明"中如实注记
- **生态共建**:站在 MoonBit 社区生态上构建(kubemoon / moonbitlang/async /
  mizchi/llm 线格式),回报可复用的诊断范式

### 计划覆盖的诊断场景

- [x] `CrashLoopBackOff` / `OOMKilled` —— 退出码、终止原因、资源限制关联分析
- [x] `Pending` —— 事件与调度失败消息排查
- [ ] 镜像拉取失败 —— `ImagePullBackOff`、Secret 缺失、仓库可达性
- [ ] 探针失败 —— liveness/readiness 事件与端点状态
- [ ] 资源水位 —— 结合 Prometheus 指标看容量趋势

## 路线图

| 阶段 | 内容 | 状态 |
|---|---|---|
| W1 | MoonBit 骨架、kubemoon 只读连通 PoC | ✅ |
| W2 | 只读工具集 + 表驱动规则引擎 + Markdown 报告 | ✅ |
| W3 | LLM 单轮归纳(OpenAI 兼容,可降级) | ✅ |
| W4 | Agent 工具循环 + CI + 文档打磨 | ✅ |
| 下赛季 | kind 故障注入评测集、Prometheus 指标工具、镜像/探针规则 | 🚧 |

## 开发

依赖:MoonBit 工具链([moon](https://www.moonbitlang.com/download/))、
kubectl + 有效 kubeconfig;LLM 归纳需任一 OpenAI 兼容端点(可选)。

```bash
# 终端 1:启动本地代理(kubectl 负责认证;Rancher 类 server 路径必须加 --append-server-path)
kubectl proxy --port=8001 --append-server-path

# 终端 2a:列出 kube-system 的 Pod 名(不依赖 LLM)
moon run cmd/main

# 终端 2b:对指定 Pod 出具诊断报告(配置 LLM 后走 Agent 循环)
MOONMEDIC_LLM_BASE_URL="https://api.deepseek.com/v1" \
MOONMEDIC_LLM_MODEL="deepseek-chat" \
MOONMEDIC_LLM_KEY="sk-..." \
moon run cmd/main -- kube-system <pod-name>
```

### 环境变量

| 变量 | 说明 | 默认 |
|---|---|---|
| `MOONMEDIC_SERVER` | 集群入口 | `http://127.0.0.1:8001`(kubectl proxy) |
| `MOONMEDIC_TOKEN` | Bearer Token(直连时) | 无 |
| `MOONMEDIC_CA_FILE` | API Server CA 的 PEM 文件(直连时) | 系统信任根 |
| `MOONMEDIC_NAMESPACE` | list 模式的默认 namespace | `kube-system` |
| `MOONMEDIC_LLM_BASE_URL` | OpenAI 兼容端点(如 `https://api.deepseek.com/v1`) | 未配置 = 关闭 LLM |
| `MOONMEDIC_LLM_MODEL` | 模型名(如 `deepseek-chat`) | 未配置 = 关闭 LLM |
| `MOONMEDIC_LLM_KEY` | API Key(本地端点可空) | 空 |

> 所有诊断工具只发 GET 请求;agent 的工具面由代码内白名单决定,
> namespace 由 CLI 参数固定,LLM 不可控。

## 测试与 CI

```bash
moon fmt --check   # 格式
moon check         # 类型检查
moon test          # 15 个单元测试(规则引擎 / 提示词 / 线格式解析)
```

CI(`.github/workflows/ci.yml`,Ubuntu)在每次 push 与 PR 上运行以上三步。

## 许可证

[Apache-2.0](LICENSE)
