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

单测 55 项，离线 CLI 回放 15 项。除表中十项外，rollout A–E 使用无拒绝消息的配对快照，每次只变更一项。A 满额受阻，B 增加 surge 仍受阻，C 允许先退旧后可行，D 增加一个 Pod 名额后可行，E 依赖外部终止 Pod 释放名额。可行案例按顺序断言完整动作序列。另有 7 项输入边界检查及 148 组健康起始状态的可达性校验。

滚动模型限两个归属 RS、健康的旧副本、整数策略与单一无作用域 pods 配额，假定其他常驻用量固定、新 Pod 可变为可用、缩容后名额最终释放。搜索达到 10,000 个状态时报告未判定。CI 使用一次性 Kubernetes v1.33.1 kind 集群运行 [控制器实测脚本](scripts/rollout-kind.sh)，保存变更前、阻塞、恢复快照和反事实预测。

[外部工具实测](BASELINES.md)覆盖六份准入快照和五份滚动发布快照。后者逐例对照 kubectl 的字段输出、K8sGPT 的告警、HolmesGPT 的回答和 moonmedic 的路径判断。[五例对照及复现方法](BASELINES.md#滚动发布同场对照)
