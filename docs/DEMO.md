# moonmedic 3 分钟演示脚本(Day 7)

> 演示原则:每一步都是**可重复的真实命令**,不是 PPT 截图。
> 前置:moon 工具链 + kubectl(指向演示集群);LLM 叙述层可选。

## 00:00–00:30 项目介绍(口播)

“Deployment 发布后没有生成预期 Pod 时，可以沿 Deployment、ReplicaSet、事件和 ResourceQuota 查找证据。moonmedic 用 MoonBit 关联这些对象，把创建失败、可识别的拒绝和缺失副本写进报告。每条证据保留对象与字段，快照可以离线回放。”

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
根因:创建 Pod 请求超过 ResourceQuota(layer: root_cause,权重 0.98)
  ⌗ ResourceQuota/zero-pods · status.used.pods = 0
  ⌗ ResourceQuota/zero-pods · status.hard.pods = 0
  ⌗ Event/ReplicaSet/payments-api-... · FailedCreate ×N:
      pods is forbidden: exceeded quota: zero-pods...
机制:ReplicaSet 创建 Pod 失败(FailedCreate)
现象:工作负载没有任何 Pod(期望 2,归属 Pod 数 0)
建议:按快照用量估算，配额还差 2 个，需 hard ≥2
```

强调:**每条结论后面的 ⌗ 行就是结构化证据引用**(对象 + 字段路径 + 观测值),JSON 输出可被 CI 直接断言。

## 01:50–02:30 离线回放(证明可复现)

```bash
eval/scripts/cleanup.sh    # 删掉评测 namespace——从此不再需要集群
bash eval/scripts/run-all.sh  # 9 个离线快照及断言
# 输出 pass=9 fail=0
```

口播:"快照刚才是从真实 RKE2 集群采集的;现在集群没了,诊断结果**一字不差**——同一份输入永远产出同一份诊断,这就是确定性引擎的含义。"

## 02:30–03:00 架构说明(口播 + 架构图)

“诊断核心用 MoonBit 实现。snapshot 负责解码，core 输出分层诊断，report 渲染结果。CI 检查核心包的依赖边界。报告可以选择启用模型归纳。”

## 备选:运行时路径(如果时间允许 / 评委追问)

```bash
moon run cmd/main -- prod <pod-name> --json
```

展示 OOMKilled / CrashLoopBackOff 等运行时规则与真 LLM 叙述层(DeepSeek 实测记录见 docs/E2E-REAL-LLM.md)。

---

## 评委问题准备

| 可能问题 | 回答与证据 |
|---|---|
| 为什么不是普通 Agent 的封装? | 关掉 LLM 核心照常诊断(演示第二步就是无 LLM 运行);CI 强制 core/rules/snapshot 不依赖 LLM 与 kubemoon |
| 为什么用 MoonBit? | 用类型建模快照完整性、准入错误与字段证据，诊断核心可离线测试及复用 |
| 怎么证明不是关键词匹配? | UID 对象图归属隔离(e04:外来 2 个健康 Pod 不污染目标计数)、Quantity 数值差额计算、负向测试(forbidden/纯 FailedCreate 不触发配额根因) |
| 没有 Pod 怎么诊断? | E01 真实集群注入:配额=0 → FailedCreate 事件 + status.used/hard → 因果链 |
| 如何避免误报? | e03:LimitRange 拒绝命中 limitrange_reject 的同时 quota_exceeded 正确缺席;裸 forbidden 不再佐证配额(Day-1 收窄) |
| LLM 幻觉怎么办? | LLM 不产生根因只做叙述;e05:Pods 源不可用时输出 insufficient_evidence 而非猜测 |
| 如何证明可复现? | 4 份真实采集快照、1 份派生缺证据快照和 4 份误报回归。CI 校验 9 个场景。 |
| 证据怎么防伪造? | evidence_refs 绑定 API 对象与字段路径,报告 JSON 可被 CI 直接断言(eval/scripts/assert.py) |
