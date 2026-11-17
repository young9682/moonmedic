# moonmedic 冲刺开发计划

> **用途：** 提供给 ZCode 作为项目开发任务书。\
> **项目仓库：** https://github.com/young9682/moonmedic\
> **项目定位：** MoonBit 原生的 Kubernetes 确定性故障证据引擎\
> **英文定位：** Deterministic Evidence Engine for Kubernetes
> Troubleshooting\
> **计划周期：** 7 个开发日（可按实际进度调整）\
> **核心策略：** 先修复诊断正确性，再完成真实 Kubernetes
> 故障注入与离线回放，最后强化证据系统和项目展示。

------------------------------------------------------------------------

## 0. 给 ZCode 的执行说明

请把本文档作为开发任务基线，按阶段逐项推进。不要一次性大规模重构，也不要为了完成计划而盲目增加功能。

### 0.1 开发前必须完成

1.  检查当前仓库分支、工作区状态和最新提交。
2.  阅读
    `README.md`、`docs/PROPOSAL.md`、`docs/PHASE-A-B-CHECKLIST.md`。
3.  检查下文提及的源文件是否仍存在、函数签名是否变化；以当前代码为准，不要假设文件结构没有变化。
4.  先运行并记录基线：
    -   `moon fmt --check`
    -   `moon check`
    -   `moon test`
5.  记录当前测试数量、失败项和 CI
    状态。若基线本身失败，先定位原因，不要把既有失败归因于本次修改。
6.  开始修改前先给出简短实施方案，列出预计修改文件和新增测试。

### 0.2 开发约束

-   核心诊断逻辑必须由 MoonBit 实现。
-   `core`、`rules`、`snapshot` 不得依赖 LLM、kubemoon 适配层或在线
    Kubernetes 集群。
-   诊断核心保持确定性：同一份输入快照应产生相同诊断结果。
-   Kubernetes 采集层只读；项目不得执行集群写操作。
-   不得把 API 读取失败解释为对象不存在或空列表。
-   不得把普通 `FailedCreate`、HTTP 403 或 `forbidden` 单独当作
    ResourceQuota 耗尽的证据。
-   不得为了让测试通过而放宽断言、删除失败测试或硬编码特定 fixture
    结果。
-   每项修复都必须有正向测试和必要的负向测试。
-   不要在本轮优先开发 Web UI、更多 Agent 工具或大范围控制器类型支持。
-   发现计划与当前代码不符时，先说明差异并提出最小调整，不要擅自进行大规模架构改造。

### 0.3 每项任务的交付格式

每完成一个任务，请汇报：

1.  修改目的与问题根因。
2.  修改的文件和关键函数。
3.  新增或调整的测试。
4.  执行的命令及结果。
5.  尚未覆盖的边界条件。
6.  是否建议独立提交 PR。

每个阶段结束后，更新 `docs/PHASE-A-B-CHECKLIST.md`
或新增相应进度文档，并确保 README 中的测试数量、功能状态与实际一致。

------------------------------------------------------------------------

## 1. 项目目标与核心叙事

moonmedic 不应被描述成一个依赖通用 Agent 的 Kubernetes
命令包装器。它的核心价值应当是：

> 当 Kubernetes 工作负载的 Pod 根本没有被创建时，moonmedic
> 能否通过仍然存在的 Deployment、ReplicaSet、Events 和 ResourceQuota
> 等对象，重建创建失败的原因，并给出可追溯、可回放的证据？

本轮要证明的技术主线：

1.  **Workload causal reconstruction：** 通过 Kubernetes OwnerReference
    / UID 建立 Deployment → ReplicaSet → Pod 对象关系。
2.  **Constraint-aware diagnosis：** 对 ResourceQuota、LimitRange
    等资源约束进行明确区分和计算。
3.  **Deterministic evidence：**
    诊断结论必须绑定可检查的证据，而不是仅依赖关键词和 LLM 猜测。
4.  **Offline replay：**
    将真实集群对象采集为统一快照，在无集群、无网络、无 API Key
    的条件下重复诊断。
5.  **Optional LLM narration：** LLM
    只负责解释已有诊断结果，不负责创造根因或证据。

### 本轮最终交付物

-   修复后的 MoonBit 确定性诊断内核。
-   关键误报与漏报的回归测试。
-   kind 真实 Kubernetes 故障注入评测环境。
-   至少 5 个故障场景及其可回放快照。
-   Golden Test / 自动化评测脚本。
-   结构化 Evidence 的第一版实现。
-   更新后的 README、架构说明和 3 分钟 Demo 脚本。

------------------------------------------------------------------------

## 2. 当前基线与已知风险

以下是此前代码审查中发现的风险。ZCode 必须在当前分支重新核实后再修改。

### 2.1 已有基础（此前检查时）

-   已有 `ClusterSnapshot` 统一快照模型。
-   已有 `core`、`rules`、`snapshot`、`tools` 等模块边界。
-   已有 Deployment → ReplicaSet → Pod 工作负载诊断路径。
-   已有 ResourceQuota、LimitRange 和 FailedCreate 相关诊断逻辑。
-   已有 `--deployment`、`--json` 等 CLI 能力。
-   已有 fixture 测试和 CI。
-   此前 main 分支记录为 38
    个测试通过；2026-11-17 Day-1 修复后实际基线为 44 个测试全部通过(0 errors)。
-   已有真实 RKE2 Pod 运行时诊断记录，但它不能替代本轮新增 Deployment
    准入失败场景的真实集群验证。

### 2.2 P0 风险一：跨 Deployment 的 Pod 数量污染

此前检查发现，工作负载诊断在计算 Pod 数量时，可能把整个 Namespace 中的
ReplicaSet 都传给 `count_owned_pods()`。如果该函数统计所有传入
ReplicaSet 的 Pod，就可能把其他 Deployment 的 Pod 算进目标 Deployment。

**期望修复：**

1.  从目标 Deployment 获取 UID。
2.  只保留 `ownerReferences.uid == Deployment.uid` 的 ReplicaSet。
3.  仅通过这些 ReplicaSet 的 UID 统计目标 Pod。
4.  对无法读取 Deployment UID、ReplicaSet 或 Pod
    列表的情况，明确标记证据不完整，不能把缺失数据当成 0。

**回归测试：**

-   目标 Deployment：期望 2 个副本，实际 0 个 Pod。
-   其他 Deployment：有正常 ReplicaSet 和多个 Pod。
-   诊断目标 Deployment 时，目标 Pod 数必须为
    0，并正确触发缺失副本诊断。
-   其他工作负载的 Pod 和事件不得影响目标诊断。

**可能涉及文件：**

-   `core/diagnose.mbt`
-   `core/core_test.mbt`
-   `rules/rules.mbt`
-   `rules/rules_test.mbt`

具体以当前函数和模块边界为准。

### 2.3 P0 风险二：ResourceQuota 与 LimitRange 误归因

此前检查发现，`quota_failure_evidence()` 一类逻辑可能将 `forbidden` 作为
ResourceQuota 证据。这个条件过宽：LimitRange 或其他准入机制也可能导致
Pod 创建请求被拒绝。

**期望修复：**

-   只有明确的配额证据才能触发 `quota_exceeded`。
-   `FailedCreate` 只能证明控制器创建失败，不能单独证明 ResourceQuota
    耗尽。
-   HTTP 403 / `forbidden` 不能单独证明 ResourceQuota。
-   LimitRange 拒绝必须单独归因。
-   Admission Webhook
    或未知准入拒绝应标记为其他/未知，不得猜测为配额问题。
-   允许同一场景存在"创建失败"症状与具体根因，但要避免重复输出互相矛盾的根因。

**回归测试：**

-   ResourceQuota 明确超限：触发 `quota_exceeded`。
-   LimitRange 拒绝：触发对应 LimitRange 发现，且不得触发
    `quota_exceeded`。
-   只有通用 `forbidden`：不得直接触发 `quota_exceeded`。
-   只有 `FailedCreate`：不得直接推断 ResourceQuota。
-   无法确认根因：输出 unknown / insufficient evidence，而不是猜测。

**可能涉及文件：**

-   `rules/rules.mbt`
-   `rules/rules_test.mbt`
-   `core/core_test.mbt`

### 2.4 P0 风险三：Pod 配额统计口径

Kubernetes ResourceQuota 对 `pods` 的计量口径与"所有关联 Pod
数量"并不完全相同。需要区分：

-   工作负载关联 Pod 数量：用于判断目标工作负载当前有多少 Pod。
-   占用 `pods` 配额的 Pod 数量：用于配额核对，应按 Kubernetes
    规则排除终态 Pod（例如 Succeeded / Failed）。

不要用一个 `pod_count` 同时承担两个语义。

**期望修复：**

-   明确拆分两个计数指标，命名应体现语义。
-   `desired - workload_pod_count` 用于估算缺失副本。
-   配额使用量优先读取 ResourceQuota 的
    `status.used`；如需自行核验，必须按 Kubernetes 口径计算。
-   不得简单用工作负载 Pod 数覆盖 Namespace ResourceQuota 的实际 used
    值。
-   在报告中标注计量口径与数据来源。

**测试：**

-   Running / Pending 等非终态 Pod 的计数。
-   Succeeded / Failed 终态 Pod 的计数。
-   部分副本创建成功时，缺失副本数正确。
-   ResourceQuota `status.used` 与本地对象列表不一致时，优先保留 API
    状态并说明差异，不得静默覆盖。

### 2.5 P0 风险四：数据缺失与空数据混淆

此前工具采集层在部分 API
读取失败时，会使用空数组继续构造快照。若下游规则只看到空数组，就可能将"读取失败"误判为"确实没有对象"。

**期望修复：**

为关键数据源引入明确的数据状态，例如：

``` moonbit
enum DataStatus {
  Available
  Empty
  Unavailable(String)
  Truncated(Int, Int)
}
```

类型和语法需按当前 MoonBit 版本调整。

至少需要覆盖：

-   Deployment
-   ReplicaSet List
-   Pod List
-   Events List
-   ResourceQuota List
-   LimitRange List

要求：

-   `Available`：读取成功且有数据。
-   `Empty`：读取成功且确实为空。
-   `Unavailable`：请求失败、权限不足或 JSON 解析失败。
-   `Truncated`：采集结果被数量上限截断。
-   下游诊断必须能感知这些状态。
-   关键证据缺失时，不得给出依赖该证据的确定性结论。

------------------------------------------------------------------------

## 3. 七日实施路线

## Day 1：对象关联正确性与准入归因

### 任务 A：修复 Deployment / ReplicaSet / Pod 关联

-   [ ] 检查当前 `count_owned_pods()` 及调用链。
-   [ ] 先按 Deployment UID 筛选 ReplicaSet。
-   [ ] 再按 ReplicaSet UID 统计目标 Pod。
-   [ ] 确认事件只关联目标 Deployment 及其直属 ReplicaSet。
-   [ ] 补充跨 Deployment 干扰测试。
-   [ ] 补充目标 ReplicaSet 缺失、UID 缺失等边界测试。

### 任务 B：修复 ResourceQuota / LimitRange 归因

-   [ ] 检查 `quota_failure_evidence()`。
-   [ ] 移除 `forbidden` 等过宽判断。
-   [ ] 建立 ResourceQuota、LimitRange、通用准入拒绝、未知原因的区分。
-   [ ] 补充负向测试。
-   [ ] 确认一条事件不会造成互相矛盾的根因。

### Day 1 验收

-   [ ] 跨 Deployment 的 Pod 不再污染目标统计。
-   [ ] LimitRange 拒绝不会被错误标记为 ResourceQuota 耗尽。
-   [ ] 通用 Forbidden / FailedCreate 不会直接触发 quota 根因。
-   [ ] `moon fmt --check`、`moon check`、`moon test` 全部通过。

------------------------------------------------------------------------

## Day 2：配额计数、数据完整性与诊断降级

### 任务 A：拆分 Pod 计数语义

-   [ ] 区分目标工作负载关联 Pod 数和配额计量 Pod 数。
-   [ ] 缺失副本计算使用目标工作负载关联 Pod 数。
-   [ ] ResourceQuota 以 API `status.used` 为主要证据。
-   [ ] 终态 Pod 计量口径有明确实现或明确限制说明。
-   [ ] 补充 Running、Pending、Succeeded、Failed 等状态测试。

### 任务 B：引入数据源完整性

-   [ ] 为关键 List 数据源增加 Available / Empty / Unavailable /
    Truncated 状态。
-   [ ] API 读取失败不得被转换为"空列表"语义。
-   [ ] 快照中保留数据源状态和失败原因。
-   [ ] 规则执行时检查所需数据是否完整。
-   [ ] 对证据不足的诊断降低结论强度或输出 unknown。
-   [ ] 报告中展示数据完整性说明。

### Day 2 验收

-   [ ] API 读取失败不会产生"Pod 数量为 0"的确定性判断。
-   [ ] 部分数据可用时，仍可输出有依据的发现，但必须说明限制。
-   [ ] 配额计数和工作负载计数语义清楚。
-   [ ] 全部单测通过，CI 通过。

------------------------------------------------------------------------

## Day 3：建立 kind 评测环境与核心故障注入

### 任务 A：评测目录与运行脚本

建议建立：

``` text
eval/
├── README.md
├── scenarios/
│   ├── quota-zero-pods/
│   ├── quota-partial-pods/
│   ├── limitrange-reject/
│   ├── foreign-workload/
│   └── incomplete-evidence/
├── fixtures/
├── expected/
├── scripts/
│   ├── create-cluster.sh
│   ├── run-all.sh
│   ├── capture-snapshot.sh
│   └── cleanup.sh
└── results/
```

脚本应支持重复执行，并清理自己创建的测试资源。不要删除或修改用户现有集群资源。

### 任务 B：E01 ResourceQuota 零 Pod 场景

-   [ ] 使用 kind 建立隔离测试集群。
-   [ ] 创建专用 Namespace。
-   [ ] 设置 `pods` ResourceQuota 为 0。
-   [ ] 创建期望副本数为 2 的 Deployment。
-   [ ] 等待 ReplicaSet 产生 FailedCreate。
-   [ ] 采集 Deployment、ReplicaSet、Pod List、Events、ResourceQuota。
-   [ ] 运行 moonmedic 诊断。
-   [ ] 保存真实快照。
-   [ ] 与预期根因及证据进行比较。

**预期：**

-   Deployment desired replicas = 2。
-   目标 ReplicaSet 存在。
-   目标 Pod 数 = 0。
-   ResourceQuota pods hard = 0。
-   事件提供明确的配额拒绝证据。
-   诊断能够给出 ResourceQuota 根因。
-   建议的 pods hard 至少为 2（仅在当前约束和使用量支持此计算时）。

### 任务 C：E02 部分副本场景

-   [ ] 设置 pods 配额只允许部分副本创建。
-   [ ] 创建期望副本数为 2 的 Deployment。
-   [ ] 验证一个 Pod 成功创建，另一个创建失败。
-   [ ] 采集快照并运行诊断。
-   [ ] 验证缺失副本数为 1，而不是 2。
-   [ ] 验证配额建议值考虑已有使用量。

### Day 3 验收

-   [ ] kind 集群可以自动创建和清理。
-   [ ] E01、E02 可重复运行。
-   [ ] 两个场景均保存真实 API 快照。
-   [ ] 诊断结果与预期一致。

------------------------------------------------------------------------

## Day 4：补全故障场景、快照回放与 Golden Test

### 必须实现的场景

  ID    场景                                     主要验证点
  ----- ---------------------------------------- ---------------------------
  E01   ResourceQuota 为 0，Pod 无法创建         零 Pod 根因诊断
  E02   配额只允许部分副本创建                   缺失副本和配额差额
  E03   LimitRange 拒绝创建                      与 ResourceQuota 正确区分
  E04   Namespace 内其他 Deployment 有正常 Pod   对象归属隔离
  E05   Events 或部分 API 不可读                 证据不完整与诊断降级

### 任务

-   [ ] 实现 E03 LimitRange 场景。
-   [ ] 实现 E04 foreign-workload 场景。
-   [ ] 实现 E05 incomplete-evidence 场景。
-   [ ] 将每个真实场景保存为 ClusterSnapshot JSON。
-   [ ] 为每个场景建立 expected diagnosis。
-   [ ] 编写离线 Golden Test。
-   [ ] 确保离线回放不需要集群、网络或 API Key。
-   [ ] 实现 `./eval/scripts/run-all.sh` 或等价命令。
-   [ ] 输出每个场景的 pass/fail、实际根因、预期根因和证据检查结果。

### Golden Test 检查项

不能只比较报告字符串。至少检查：

-   预期根因是否存在。
-   不应出现的根因是否不存在。
-   关键 Evidence 是否存在。
-   Evidence 是否指向正确对象和字段。
-   证据缺失时是否正确降级。
-   同一快照重复执行是否得到相同结构化结果。

### Day 4 验收

-   [ ] 5 个场景都有可回放快照。
-   [ ] 关键场景来自真实 kind API 采集，而非手写 JSON。
-   [ ] Golden Test 可离线运行。
-   [ ] 所有场景结果和失败原因可读。

------------------------------------------------------------------------

## Day 5：结构化 Evidence 与诊断仲裁

### 任务 A：结构化 Evidence ✅(2026-11-18)

当前 Finding 如果仍主要使用 `Array[String]`
保存证据，应升级为可机器检查的结构化证据。

建议模型：

``` moonbit
pub struct Evidence {
  source : String
  resource_kind : String
  namespace : String
  object_name : String
  field_path : String
  observed_value : String
  observed_at : String
  resource_version : String?
}
```

实际字段类型和可空表达按当前项目风格调整。

要求：

-   [ ] Evidence 可标识来源对象。
-   [ ] Evidence 可标识字段路径。
-   [ ] Evidence 保存观测值。
-   [ ] 有条件时保存采集时间和 resourceVersion。
-   [ ] Finding 引用 Evidence，而不是仅复制拼接后的文本。
-   [ ] Markdown 和 JSON 报告均能输出 Evidence。
-   [ ] 旧报告字段兼容性经过检查。

### 任务 B：诊断仲裁

建议明确诊断层次：

-   Root Cause：有证据支持的根因。
-   Mechanism：导致失败的机制。
-   Symptom：副本不足、Pod 缺失等现象。
-   Related Finding：关联但尚不能确认因果的发现。
-   Insufficient Evidence：证据不足。

建议处理链路：

``` text
Raw Kubernetes Objects
        |
        v
Fact Extraction
        |
        v
Object Relationship Reconstruction
        |
        v
Constraint Analysis
        |
        v
Candidate Findings
        |
        v
Evidence Validation
        |
        v
Root Cause Arbitration
        |
        v
Final Diagnosis
```

要求：

-   [ ] 根因必须有支持证据。
-   [ ] 通用 FailedCreate 不得被自动提升为具体根因。
-   [ ] 症状与根因不应互相重复。
-   [ ] 多个原因同时存在时，允许输出多个有证据支持的发现。
-   [ ] 无法确认时明确输出 unknown / insufficient evidence。
-   [ ] 固定 confidence 值不得被描述为统计校准概率。

### 任务 C：资源约束扩展（有余力再做）

优先实现明确可验证的部分：

-   [ ] ResourceQuota pods 数量约束。
-   [ ] CPU requests / limits 的配额核对。
-   [ ] Memory requests / limits 的配额核对。
-   [ ] LimitRange min / max 基础约束。
-   [ ] 对初始化容器、默认值、scopeSelector 等复杂情况明确支持边界。

**重要：** CPU / Memory 的工作负载需求不能简单用副本数估算。必须读取
PodTemplate 的资源 requests / limits，并正确处理 Kubernetes
资源计算语义。无法完整支持的情况应输出限制说明，不得给出看似精确但错误的结果。

### Day 5 验收

-   [ ] 至少完成结构化 Evidence 第一版。
-   [ ] Finding 能引用 Evidence。
-   [ ] JSON / Markdown 报告能够输出结构化证据。
-   [ ] 关键根因都有证据校验。
-   [ ] Golden Test 全部通过。

------------------------------------------------------------------------

## Day 6：README、架构说明与项目材料

### README 建议结构

``` text
1. What is moonmedic?
2. The Problem
3. Why Pod-centric Troubleshooting Is Not Enough
4. Core Innovations
   4.1 Deterministic Evidence Engine
   4.2 Workload Causal Reconstruction
   4.3 Constraint-aware Diagnosis
   4.4 Offline Snapshot Replay
5. Architecture
6. Quick Start
7. Demo
8. Evaluation
9. Limitations
10. Roadmap
11. License
```

### 项目介绍建议

**moonmedic --- A Deterministic Evidence Engine for Kubernetes
Troubleshooting**

moonmedic 是一个以 MoonBit 实现的 Kubernetes 确定性故障证据引擎。它通过
Kubernetes
控制器对象关系、事件和资源约束，对工作负载创建失败进行诊断；即使目标 Pod
尚未创建，也可以从 Deployment、ReplicaSet、ResourceQuota
等现存对象中重建故障证据链。核心诊断逻辑不依赖
LLM，并支持统一快照、离线回放和自动化评测。LLM
仅作为可选的自然语言解释层。

### 必须准备的材料

-   [ ] 总体架构图。
-   [ ] Snapshot → Core → Evidence → Diagnosis 数据流图。
-   [ ] E01 零 Pod 场景截图或终端录屏。
-   [ ] E02 部分副本场景截图。
-   [ ] 离线回放演示。
-   [ ] 测试结果和评测汇总。
-   [ ] 明确的功能支持范围与已知限制。
-   [ ] MoonBit 实现占比和依赖说明。
-   [ ] License、第三方依赖和 AI 使用说明。

### README 写作原则

不要只罗列"支持多少条规则"。重点解释：

1.  为什么传统从 Pod 状态出发的排障方式无法覆盖 Pod 未创建场景。
2.  moonmedic 如何从控制器对象关系重建因果链。
3.  为什么它不是通用 Agent 的简单封装。
4.  如何通过快照回放和 Golden Test 证明诊断可复现。

------------------------------------------------------------------------

## Day 7：最终验收与三分钟演示

### 3 分钟 Demo 流程

  -----------------------------------------------------------------------------------
  时间                    内容                    展示重点
  ----------------------- ----------------------- -----------------------------------
  00:00--00:30            项目介绍                Pod 未创建时的诊断难题

  00:30--01:00            故障注入                Deployment + ResourceQuota

  01:00--01:50            运行 moonmedic          Deployment → ReplicaSet →
                                                  FailedCreate → Quota 证据链

  01:50--02:30            离线回放                无集群情况下重复诊断

  02:30--03:00            架构说明                MoonBit
                                                  Core、Evidence、Rules、Evaluation
                                                  Harness
  -----------------------------------------------------------------------------------

### 评委问题准备

  可能问题                   回答应提供的证据
  -------------------------- ----------------------------------------------
  为什么不是普通 Agent？     关闭 LLM 后核心仍可独立诊断
  为什么需要 MoonBit？       MoonBit 原生核心、类型与模块设计、可运行代码
  怎么证明不是关键词匹配？   UID 对象图关联、约束计算、负向测试
  没有 Pod 怎么诊断？        E01 真实 kind 故障注入
  如何避免误报？             LimitRange / Quota 负向测试和证据校验
  LLM 幻觉怎么办？           LLM 不产生根因，只解释确定性诊断结果
  如何证明可复现？           真实快照和离线 Golden Test

### 最终验收命令

``` bash
moon fmt --check
moon check
moon test
./eval/scripts/run-all.sh
```

如果评测脚本依赖 Docker /
kind，应在文档中明确前置条件；核心单测和快照回放仍应保持离线可运行。

### Day 7 验收

-   [ ] 格式检查通过。
-   [ ] 类型检查通过。
-   [ ] 所有单元测试通过。
-   [ ] 所有可运行的 kind 场景通过。
-   [ ] 离线 Golden Test 通过。
-   [ ] README 与实际功能一致。
-   [ ] Demo 可以从干净环境重复执行。
-   [ ] 没有未说明的集群写操作。
-   [ ] 版本号、测试数量、CI 状态和文档一致。

------------------------------------------------------------------------

## 4. 总任务清单

### P0：必须完成

-   [ ] 修复跨 Deployment 的 Pod 统计污染。
-   [ ] 修复 ResourceQuota / LimitRange 错误归因。
-   [ ] 区分工作负载 Pod 数与配额 Pod 数。
-   [ ] 引入数据完整性状态，避免空数据与读取失败混淆。
-   [ ] 完成 kind 测试环境。
-   [ ] 完成 E01 ResourceQuota 零 Pod 场景。
-   [ ] 完成 E02 部分副本场景。
-   [ ] 完成 E03 LimitRange 拒绝场景。
-   [ ] 完成 E04 跨工作负载干扰场景。
-   [ ] 完成 E05 数据不完整场景。
-   [ ] 保存真实快照并建立 Golden Test。
-   [ ] 更新 README、架构图和 Demo。
-   [ ] 所有基础检查与验收测试通过。

### P1：高分强化

-   [ ] 结构化 Evidence。
-   [ ] Finding 对 Evidence 的引用。
-   [ ] 诊断根因 / 机制 / 症状分层。
-   [ ] Evidence Validation。
-   [ ] ResourceQuota CPU / Memory 约束计算。
-   [ ] LimitRange min / max 约束重建。
-   [ ] 诊断误报率、漏报率、证据完整率统计。
-   [ ] 诊断耗时和快照规模性能基准。

### 暂缓

-   Web 管理后台。
-   更多通用 Agent 工具。
-   StatefulSet / DaemonSet 全面支持。
-   大规模关键词规则扩张。
-   自研大模型。
-   与核心诊断无关的复杂 UI。

------------------------------------------------------------------------

## 5. 评测指标与统计口径

不要只报告测试数量。建议在 `eval/README.md` 中记录：

  指标                    说明
  ----------------------- ----------------------------------
  Scenario Pass Rate      通过的场景数 / 总场景数
  Root Cause Precision    被判定为根因的结果中，正确的比例
  Root Cause Recall       已知真实根因中，被正确识别的比例
  False Positive Rate     不应触发的根因规则被触发的比例
  Evidence Completeness   预期关键证据中实际提供的比例
  Replay Consistency      同一快照重复诊断结果一致的比例
  Diagnosis Latency       核心离线诊断耗时
  Snapshot Size           快照大小与对象数量

小样本阶段必须同时报告分子、分母和场景数，不得将少量场景的结果包装成普遍准确率。区分单元测试、fixture
测试和真实集群故障注入结果。

------------------------------------------------------------------------

## 6. 最终目标与边界

### 建议目标

  项目                                                                     目标
  ------------------------------------- ---------------------------------------
  核心测试数量                            50+（以有效覆盖为准，不为数量堆测试）
  真实故障注入场景                                                    至少 5 个
  可回放快照                                                          至少 5 组
  负向测试                                                     覆盖关键误报场景
  Core / Rules / Snapshot 的 LLM 依赖                                         0
  核心离线诊断的集群依赖                                                      0
  Kubernetes 采集写操作                                                       0
  离线回放                                                     可重复、结果一致
  演示                                                           3 分钟完整演示

### 重要边界

-   50+ 测试是目标，不是为了达到数量而牺牲测试质量。
-   5 个场景必须包含真实 kind 采集的场景；不能全部用手写 JSON
    冒充真实集群测试。
-   离线回放和真实集群采集是两种不同的验证，应分别报告。
-   ResourceQuota、LimitRange 和其他准入机制必须区分。
-   证据不足时允许输出"不确定"，不允许为了看起来智能而猜测根因。
-   不得宣称尚未实现或未经验证的功能已经完成。

------------------------------------------------------------------------

## 7. 开发优先级总结

按以下顺序执行，不要颠倒：

1.  **正确性：** 修复对象关联、错误归因、配额计数和数据完整性。
2.  **真实性：** 使用 kind 真实注入故障，验证 Pod 未创建场景。
3.  **可复现性：** 录制快照，构建离线回放和 Golden Test。
4.  **技术深度：** 结构化 Evidence、约束分析和诊断仲裁。
5.  **竞赛表达：** README、架构图、实验结果和 Demo。

最终要证明的不是"moonmedic 有多少条规则"，而是：

> moonmedic 能够在 Pod 尚未创建的情况下，利用 Kubernetes
> 控制器对象图和资源约束，重建可追溯、可验证、可离线复现的故障证据链。

这就是本轮开发的最高优先级。
