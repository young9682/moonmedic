# moonmedic 🥮🩺

> MoonBit 写的 Kubernetes 故障证据引擎 —— 给集群请一位会取证的医生。

**2026 MoonBit 黑客松 · 十一月赛参赛项目** · [申报书](docs/项目申报书.md) · [验收与复现](docs/ACCEPTANCE.md)

[![ci](https://github.com/young9682/moonmedic/actions/workflows/ci.yml/badge.svg)](https://github.com/young9682/moonmedic/actions/workflows/ci.yml)

## 它做什么

面对故障,先判断 Pod 是否真的存在,再沿对象图取证:

```
你  : prod/payments-api 发布后一个 Pod 都没有
moonmedic:
  ├─ Pod 不存在,已切换为同名 Deployment 诊断
  ├─ Deployment 期望 2 个副本,归属 Pod 数 0
  ├─ ReplicaSet/payments-api-7d9f6b: FailedCreate · exceeded quota: compute, requested: pods=1
  ├─ ResourceQuota/compute: pods used=10, hard=10(100%)
  └─ 结论: 配额耗尽,Pod 根本没被创建
          按快照用量估算还差 2 个 pods 配额，需 hard ≥12
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
   字段路径 / 观测值 / 可用时间戳),JSON 契约含诊断分层
   (`root_cause` / `mechanism` / `symptom` / `insufficient` / `related`),供 CI 断言与审计。
5. **LLM 叙述层(可选)** —— 兼容任意 OpenAI 接口端点,只负责把已有证据
   归纳成人话;LLM 不可用时自动降级为纯规则报告。

### 两条诊断路径

| 路径 | 触发条件 | 证据源 | 典型结论 |
|---|---|---|---|
| 运行时 | Pod 存在 | Pod status、containerStatuses、Events、日志 | OOM、CrashLoop、探针、镜像拉取、Pending |
| 工作负载 | 指定 Deployment，包括零 Pod 与部分副本 | Deployment/RS 条件、FailedCreate 事件、ResourceQuota、归属 Pod 列表 | 配额超限、LimitRange 拒绝、控制器创建失败 |

### 设计原则

- **只读护栏**:工具集只含 GET,不对集群做任何变更;修复建议只输出,不执行
- **证据优先**：报告绑定对象、字段与观测值。配额差额基于明确拒绝、同名同资源的状态及可信的归属 Pod 计数。
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
| Phase B | RKE2 采集 E01–E04、缺证据派生 E05、反例 R01–R05 离线回放 | ✅ |
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
moon test          # 55 个测试
bash eval/scripts/run-all.sh
```

CI 在 main 推送和 PR 上运行以上检查，并检查 `core`、`rules`、`snapshot` 的依赖边界。

## 评测

15 个离线案例包括 4 份 RKE2 采集、1 份缺证据派生、5 份误报回归和 5 份滚动发布对照。[场景和断言](eval/README.md)

| 场景 | 注入 | 验证点 | 结果 |
|---|---|---|---|
| e01 | ResourceQuota `pods=0` | quota_exceeded + workload_no_pods + deployment_stalled | PASS |
| e02 | 配额 1 / 期望副本 2 | 部分副本,workload_no_pods 正确缺席 | PASS |
| e03 | LimitRange 64Mi < 256Mi | limitrange_reject 命中,quota_exceeded 正确缺席 | PASS |
| e04 | 同 ns 存在健康外来工作负载 | 归属隔离:目标 Pod 计数仍为 0 | PASS |
| e05 | Pods 源标记 unavailable | insufficient_evidence 降级 | PASS |

R01–R05 覆盖缺资源声明、通用校验、Webhook 与配额饱和共存、配额名称或资源项不匹配，以及同名 ReplicaSet 重建后的旧事件误归因。

`--deployment` 和 `--snapshot` 会对符合模型条件的新旧 ReplicaSet 搜索替换路径。`projection` 层区分受阻、存在完成路径、必须等待外部 Pod 释放名额。可行路径附一组从当前状态到完成状态的动作。现场状态变化的速度取决于调度、就绪与删除进度。

路径分析支持整数和百分比发布参数，并显示生效值。例如目标为 3 个副本时，Kubernetes 默认的两个 `25%` 分别折算为 `maxSurge=1` 和 `maxUnavailable=0`。[模型范围与回归](eval/README.md#指标口径)

## 限制

- LimitRange 依据支持的上游拒绝句式归因。插件参数复算、跨版本验证和事件时间一致性校验为后续范围。
- CPU/内存配额差额需 PodTemplate requests 求和,暂未实现(pods 计数已实现)
- 快照为单 namespace 视角;调度器级节点资源分析未覆盖
- sched_insufficient / probe_fail 暂为文本证据(v1 限制,已标注)
- 只读边界:诊断永不写集群;修复建议只输出,不执行

## 许可证与依赖

[Apache-2.0](LICENSE) · 生态依赖:[cxh04/kubemoon](https://mooncakes.io/docs/cxh04/kubemoon)(快照适配器)、
moonbitlang/async、[mizchi/llm](https://github.com/mizchi/llm)(agent 循环线格式参考)。
AI 使用说明:开发过程使用 AI 辅助(官方允许),诊断内核为确定性 MoonBit 代码;
产品内 LLM 仅为可选叙述层,不产生根因或证据。
