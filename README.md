# moonmedic 🥮🩺

> MoonBit 写的 Kubernetes 故障证据引擎 —— 给集群请一位会取证的医生。

**2026 MoonBit 黑客松 · 十一月赛参赛项目**(W1–W4 + Phase A + Phase B 评测集已交付;MoonBit 实现占比 96.7%:5034 行 MoonBit,评测胶水仅 169 行脚本)

[![ci](https://github.com/young9682/moonmedic/actions/workflows/ci.yml/badge.svg)](https://github.com/young9682/moonmedic/actions/workflows/ci.yml)

## 它做什么

面对故障,先判断 Pod 是否真的存在,再沿对象图取证:

```
你  : prod/payments-api 发布后一个 Pod 都没有
moonmedic:
  ├─ Pod 不存在,已切换为同名 Deployment 诊断
  ├─ Deployment 期望 2 个副本,归属 Pod 数 0
  ├─ ReplicaSet/payments-api-7d9f6b: FailedCreate ×3
  ├─ ResourceQuota/compute: pods used=10, hard=10(100%)
  └─ 结论: 配额耗尽,Pod 根本没被创建
          还差 2 个 pods 配额;将 hard 提高到 ≥12,或缩容 2 个现有 Pod
```

如果是已经在运行的 Pod,则走运行时路径:

```
你  : 这个 Pod 为什么一直重启?
moonmedic:
  ├─ Pod payments-api-7d9f6b-x2k9l 处于 CrashLoopBackOff
  ├─ 上次退出码 137(SIGKILL),重启 12 次
  ├─ 上次终止原因: OOMKilled(内存限制 256Mi)
  └─ 诊断: 内存限制过低或存在泄漏
```

### 工作方式

```
                 ┌─────────────────────────────┐
ClusterSnapshot →│ core(确定性证据引擎)       │→ Diagnosis
                 │ 对象图 / 准入重建 / 因果链   │
                 └─────────────────────────────┘
                        ↑                  ↑
                 tools(kubemoon)      fixture(JSON)
```

1. **快照层** —— `ClusterSnapshot` 把 Pod、Deployment、ReplicaSet、Event、
   ResourceQuota、LimitRange 归一为声明式 JSON。实时集群、`kubectl` 导出、
   录制文件都只是它的来源。
2. **确定性引擎 `core`** —— 对象图遍历(ownerReferences)、准入失败重建、
   K8s Quantity 算术、因果链与规则仲裁。**不 import kubemoon,也不 import LLM**,
   无集群、无网络即可单测。
3. **运行时规则** —— 6 条 Pod 规则(OOMKilled / CrashLoop exit 1 /
   FailedScheduling / 镜像 tag / 镜像凭据 / 探针失败)。
4. **结构化证据引用** —— 每条 Finding 附 `evidence_refs`(source / 对象 /
   字段路径 / 观测值 / 时间戳),JSON 契约含诊断分层
   (`root_cause` / `mechanism` / `symptom` / `insufficient`),供 CI 断言与审计。
5. **LLM 叙述层(可选)** —— 兼容任意 OpenAI 接口端点,只负责把已有证据
   归纳成人话;LLM 不可用时自动降级为纯规则报告。

### 两条诊断路径

| 路径 | 触发条件 | 证据源 | 典型结论 |
|---|---|---|---|
| 运行时 | Pod 存在 | Pod status、containerStatuses、Events、日志 | OOM、CrashLoop、探针、镜像拉取、Pending |
| 准入 | Pod 不存在或归属 Pod 数 0 | Deployment/RS 条件、FailedCreate 事件、ResourceQuota、LimitRange | 配额耗尽、LimitRange 拒绝、控制器创建失败 |

### 设计原则

- **只读护栏**:工具集只含 GET,不对集群做任何变更;修复建议只输出,不执行
- **证据优先**:每条结论绑定 API 路径、字段与时间戳;建议由数值差额计算,
  不是固定模板
- **确定性内核**:LLM 不产生证据;没有 LLM 也能得到完整因果链
- **优雅降级**:数据源不可读时在“数据完整性说明”中明确标注,不静默丢失
- **可回放**:快照 + 期望诊断可离线复现,便于回归与评测

### 覆盖场景

- [x] 配额超限导致 Pod 未创建 —— `quota_exceeded` / `replicaset_create_failed` /
  `workload_no_pods` 因果链(**真实 RKE2 集群注入采集验证**,见评测节)
- [x] `CrashLoopBackOff` / `OOMKilled` —— 退出码、终止原因、资源限制关联分析
- [x] `Pending` —— 事件与调度失败消息排查
- [x] 镜像拉取失败 —— 镜像名/tag 无法解析(`image_pull_tag`)与凭据/Secret 问题
  (`image_pull_secret`)
- [x] 探针失败 —— kubelet Unhealthy / probe failed 事件(`probe_fail`)
- [ ] kind 故障注入评测集与基准(Phase B)

## 路线图

| 阶段 | 内容 | 状态 |
|---|---|---|
| W1 | MoonBit 骨架、kubemoon 只读连通 PoC | ✅ |
| W2 | 只读工具集 + 表驱动规则引擎 + Markdown 报告 | ✅ |
| W3 | LLM 单轮归纳(OpenAI 兼容,可降级) | ✅ |
| W4 | Agent 工具循环 + CI + 文档打磨 | ✅ |
| Phase A | 快照 IR、对象图、配额数值重建 + LimitRange 识别、`--deployment`、`--json` | ✅ |
| Phase B | 评测集:真实集群(RKE2)注入 E01–E05 采集 + golden 离线回放 | ✅ |
| Phase C | StatefulSet/DaemonSet、节点容量、上一容器日志、日志签名 | 可选 |

## 开发

依赖:MoonBit 工具链([moon](https://www.moonbitlang.com/download/))、
kubectl + 有效 kubeconfig;LLM 归纳需任一 OpenAI 兼容端点(可选)。

```bash
# 0) 离线回放(最快上手:无集群、无网络、无 LLM)
moon run cmd/main -- --snapshot eval/fixtures/e01-quota-zero-pods.snapshot.json

# 终端 1:启动本地代理(kubectl 负责认证;Rancher 类 server 路径必须加 --append-server-path)
kubectl proxy --port=8001 --append-server-path

# 终端 2a:列出 kube-system 的 Pod 名(不依赖 LLM)
moon run cmd/main

# 终端 2b:诊断 Pod;Pod 不存在时自动尝试同名 Deployment
moon run cmd/main -- kube-system csi-nfs-controller-86c986f847-b9spg

# 终端 2c:直接诊断工作负载
moon run cmd/main -- --deployment prod payments-api

# 终端 2d:机器可读输出(供评测脚本断言)
moon run cmd/main -- --deployment prod payments-api --json

# 启用 LLM 叙述层
MOONMEDIC_LLM_BASE_URL="https://api.deepseek.com/v1" \
MOONMEDIC_LLM_MODEL="deepseek-chat" \
MOONMEDIC_LLM_KEY="sk-..." \
moon run cmd/main -- prod payments-api
```

`--agent` 可显式启用 LLM 工具循环(Pod 路径);默认走确定性的
`诊断目标 → 快照 → core → 可选归纳` 路径。

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
moon test          # 51 个测试(规则 / Quantity / 事件 / 快照 / core / agent / 报告)
```

CI(`.github/workflows/ci.yml`,Ubuntu)在每次 push 与 PR 上运行以上三步,
并额外检查 `core`、`rules`、`snapshot` 不得依赖 kubemoon 或 LLM。

## 评测

评测集见 [eval/README.md](eval/README.md):**5 个真实集群注入场景**
(隔离 namespace + `kubectl -o json` 采集为 ClusterSnapshot,非手写 JSON)
+ 离线 golden 回放(`run-all.sh`,无集群/无网络/无 LLM):

| 场景 | 注入 | 验证点 | 结果 |
|---|---|---|---|
| e01 | ResourceQuota `pods=0` | quota_exceeded + workload_no_pods + deployment_stalled | PASS |
| e02 | 配额 1 / 期望副本 2 | 部分副本,workload_no_pods 正确缺席 | PASS |
| e03 | LimitRange 64Mi < 256Mi | limitrange_reject 命中,quota_exceeded 正确缺席 | PASS |
| e04 | 同 ns 存在健康外来工作负载 | 归属隔离:目标 Pod 计数仍为 0 | PASS |
| e05 | Pods 源标记 unavailable | insufficient_evidence 降级 | PASS |

指标口径如实报告分子/分母:场景通过率 5/5;单元测试 51/51;
e05 基于 e01 真实快照派生(Pods 源标记 unavailable)。

## 限制

- LimitRange 完整约束回放(min/max 逐项)为后续计划;当前由事件措辞识别
- CPU/内存配额差额需 PodTemplate requests 求和,暂未实现(pods 计数已实现)
- 快照为单 namespace 视角;调度器级节点资源分析未覆盖
- sched_insufficient / probe_fail 暂为文本证据(v1 限制,已标注)
- 只读边界:诊断永不写集群;修复建议只输出,不执行

## 许可证与依赖

[Apache-2.0](LICENSE) · 生态依赖:[cxh04/kubemoon](https://mooncakes.io/docs/cxh04/kubemoon)(快照适配器)、
moonbitlang/async、[mizchi/llm](https://github.com/mizchi/llm)(agent 循环线格式参考)。
AI 使用说明:开发过程使用 AI 辅助(官方允许),诊断内核为确定性 MoonBit 代码;
产品内 LLM 仅为可选叙述层,不产生根因或证据。
