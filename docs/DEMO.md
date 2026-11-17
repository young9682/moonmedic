# moonmedic 3 分钟演示脚本(Day 7)

> 演示原则:每一步都是**可重复的真实命令**,不是 PPT 截图。
> 前置:moon 工具链 + kubectl(指向演示集群);LLM 叙述层可选。

## 00:00–00:30 项目介绍(口播)

"K8s 里最常见的故障,不是 Pod 崩溃,而是 **Pod 根本没有被创建**——配额耗尽、LimitRange 拒绝、准入拦截。这时 `kubectl get pods` 只会说'没有 Pod'。moonmedic 用 MoonBit 实现了一个**确定性故障证据引擎**:从 Deployment、ReplicaSet、ResourceQuota 这些'遗物'里重建因果证据链,每条结论绑定对象与字段,可离线回放。"

## 00:30–01:00 故障注入(真实集群,隔离 namespace)

```bash
eval/scripts/inject.sh e01-quota-zero-pods
# ResourceQuota hard pods=0 + Deployment 期望 2 副本
# 等待 FailedCreate 事件就绪(脚本自动等待)
```

亮点:namespace 完全隔离(`moonmedic-eval-*`),不碰集群任何现有资源。

## 01:00–01:50 运行 moonmedic(证据链展示)

```bash
eval/scripts/capture-snapshot.sh e01-quota-zero-pods payments-api eval/fixtures/e01.snapshot.json
moon run cmd/main -- --snapshot eval/fixtures/e01.snapshot.json
```

终端展示报告的因果链(逐条念):

```text
根因:命名空间配额耗尽(layer: root_cause,置信 0.98)
  ⌗ ResourceQuota/zero-pods · status.pods = used=0, hard=0
  ⌗ Event/ReplicaSet/payments-api-... · FailedCreate ×N:
      pods is forbidden: exceeded quota: zero-pods...
机制:ReplicaSet 创建 Pod 失败(FailedCreate)
现象:工作负载没有任何 Pod(期望 2,归属 Pod 数 0)
建议:配额还差 2 个;将 hard 提高到 ≥2,或缩容现有 Pod
```

强调:**每条结论后面的 ⌗ 行就是结构化证据引用**(对象 + 字段路径 + 观测值),JSON 输出可被 CI 直接断言。

## 01:50–02:30 离线回放(证明可复现)

```bash
eval/scripts/cleanup.sh    # 删掉评测 namespace——从此不再需要集群
eval/scripts/run-all.sh    # 5 个场景全部离线回放 + golden 断言
# 输出:PASS e01 ... PASS e05,pass=5 fail=0
```

口播:"快照刚才是从真实 RKE2 集群采集的;现在集群没了,诊断结果**一字不差**——同一份输入永远产出同一份诊断,这就是确定性引擎的含义。"

## 02:30–03:00 架构说明(口播 + 架构图)

"MoonBit 实现占比 96.7%。三层:`snapshot`(统一 IR)→ `core`(确定性引擎,不 import kubemoon、不 import LLM,CI 强制检查)→ `report`。可选 LLM 叙述层只解释已有证据,不产生根因;LLM 挂了诊断照常输出。"

## 备选:运行时路径(如果时间允许 / 评委追问)

```bash
moon run cmd/main -- --deployment prod payments-api --json
```

展示 OOMKilled / CrashLoopBackOff 等运行时规则与真 LLM 叙述层(DeepSeek 实测记录见 docs/E2E-REAL-LLM.md)。

---

## 评委问题准备

| 可能问题 | 回答与证据 |
|---|---|
| 为什么不是普通 Agent 的封装? | 关掉 LLM 核心照常诊断(演示第二步就是无 LLM 运行);CI 强制 core/rules/snapshot 不依赖 LLM 与 kubemoon |
| 为什么用 MoonBit? | 全仓库 96.7% MoonBit(5034 行);K8s Quantity 算术、快照 IR、agent HTTP 客户端均为原生实现,native 后端零 C stub |
| 怎么证明不是关键词匹配? | UID 对象图归属隔离(e04:外来 2 个健康 Pod 不污染目标计数)、Quantity 数值差额计算、负向测试(forbidden/纯 FailedCreate 不触发配额根因) |
| 没有 Pod 怎么诊断? | E01 真实集群注入:配额=0 → FailedCreate 事件 + status.used/hard → 因果链 |
| 如何避免误报? | e03:LimitRange 拒绝命中 limitrange_reject 的同时 quota_exceeded 正确缺席;裸 forbidden 不再佐证配额(Day-1 收窄) |
| LLM 幻觉怎么办? | LLM 不产生根因只做叙述;e05:Pods 源不可用时输出 insufficient_evidence 而非猜测 |
| 如何证明可复现? | 5 份真实集群快照 + golden 断言,离线重复执行结果一致 |
| 证据怎么防伪造? | evidence_refs 绑定 API 对象与字段路径,报告 JSON 可被 CI 直接断言(eval/scripts/assert.py) |
