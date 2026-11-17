# moonmedic 评测集(真实集群故障注入 + 离线 Golden 回放)

## 设计

- **注入**:每个场景一个隔离 namespace(`moonmedic-eval-*`),kubectl apply
  真实 manifest(ResourceQuota / LimitRange / Deployment),等待故障证据就绪。
- **采集**:`capture-snapshot.sh` 全部来自 `kubectl get -o json`,拼装为
  ClusterSnapshot(非手写 JSON);`data_status` 标记各数据源为 available。
- **回放**:`moon run cmd/main -- --snapshot <fixture> --json` 离线诊断,
  不需要集群、网络或 API Key。
- **断言**:`assert.py` 校验 expect_rule_ids / forbid_rule_ids / evidence_contains,
  不是字符串全等。

## 场景

| ID | 场景 | 预期根因 |
|---|---|---|
| e01 | ResourceQuota hard pods=0 | quota_exceeded + workload_no_pods |
| e02 | 配额只允许 1 个 Pod(期望 2) | quota_exceeded(部分副本) |
| e03 | LimitRange max 64Mi < 容器 256Mi | limitrange_reject,禁 quota_exceeded |
| e04 | 同 ns 存在健康外来工作负载 | 归属隔离:broken-api 仍报 workload_no_pods |
| e05 | 真实快照 + Pods 源标记 unavailable | insufficient_evidence,禁 workload_no_pods |

## 前置条件

- MoonBit 工具链(moon)
- kubectl + 有效 kubeconfig(注入与采集);离线回放本身不需要

## 用法

```bash
eval/scripts/inject.sh e01-quota-zero-pods
eval/scripts/capture-snapshot.sh e01-quota-zero-pods payments-api eval/fixtures/e01-quota-zero-pods.snapshot.json
eval/scripts/cleanup.sh          # 删除全部 moonmedic-eval-* namespace
eval/scripts/run-all.sh          # 离线回放 + 断言(不需要集群)
```

## 指标口径

小样本阶段如实报告分子/分母:e01–e05 共 5 场景,断言项见 expected/*.json。
区分:单元测试(38+4+…)、fixture 回放(本目录)、真实集群注入结果。
