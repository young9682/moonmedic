# moonmedic 评测集

## 设计

- **集群采集**。E01–E04 从 RKE2 的隔离命名空间采集。注入脚本应用场景 manifest，采集脚本用 `kubectl get -o json` 组装 ClusterSnapshot。
- **离线派生**。E05 在 E01 的基础上把 Pods 源设为 unavailable。R01–R05 为复查反例构造的最小快照。
- **回放**:`moon run cmd/main -- --snapshot <fixture> --json` 离线诊断,
  不需要集群、网络或 API Key。
- **断言**。`assert.py` 校验必需及禁止的规则 ID，并可按规则检查层级、权重、差额文本和证据引用。CI 运行完整回放。缺失 fixture、CLI 失败或断言失败均返回非零退出码。

## 场景

| ID | 场景 | 验证点 |
|---|---|---|
| e01 | ResourceQuota hard pods=0 | quota_exceeded + workload_no_pods |
| e02 | 配额只允许 1 个 Pod(期望 2) | quota_exceeded(部分副本) |
| e03 | LimitRange max 64Mi < 容器 256Mi | limitrange_reject,禁 quota_exceeded |
| e04 | 同 ns 存在健康外来工作负载 | 归属隔离:broken-api 仍报 workload_no_pods |
| e05 | 真实快照 + Pods 源标记 unavailable | insufficient_evidence,禁 workload_no_pods |
| r01 | 配额要求声明 requests/limits | 保留机制，配额根因缺席 |
| r02 | 通用 Invalid value | 保留机制，LimitRange 根因缺席 |
| r03 | Webhook 拒绝与配额饱和 | 饱和只作为 related 提示 |
| r04 | 异名同资源与同名异资源 | 保留明确拒绝，禁止引用不匹配的配额状态或推算差额 |
| r05 | 同名 ReplicaSet 重建，快照保留旧对象的配额拒绝事件 | 拒绝 UID 不匹配的旧事件，保留新对象的通用校验失败与零 Pod 结论 |

## 前置条件

- MoonBit 工具链、项目依赖、Bash 与 Python 3
- kubectl + 有效 kubeconfig(注入与采集);离线回放本身不需要

## 用法

```bash
eval/scripts/inject.sh e01-quota-zero-pods
eval/scripts/capture-snapshot.sh e01-quota-zero-pods payments-api eval/fixtures/e01-quota-zero-pods.snapshot.json
eval/scripts/cleanup.sh          # 删除全部 moonmedic-eval-* namespace
bash eval/scripts/run-all.sh     # 离线回放 + 断言(不需要集群)
```

## 指标口径

本轮单测 54/54，离线回放 10/10。场景来源为真实采集 4 份、完整性派生 1 份、复查反例 5 份。R05 在修复前触发 `quota_exceeded`，修复后只输出当前对象的创建失败和零 Pod 结论。`results/` 保存早期回放输出，当前结果以重跑断言为准。

[外部工具实测](BASELINES.md)使用 E01、E02 和 R01–R04 的同一组快照，记录 kubectl、K8sGPT、HolmesGPT 与 moonmedic 的输出和读取轨迹。
