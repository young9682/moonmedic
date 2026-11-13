# moonmedic 项目申报书(2026 MoonBit 黑客松 · 十一月赛)

## 1. 项目名称

moonmedic —— MoonBit 实现的 Kubernetes 只读排障 Agent(集群医生)

## 2. 项目简介

moonmedic 是一个用 MoonBit 编写的 Kubernetes 排障 Agent:面对故障 Pod,它通过只读工具自主取证(状态、事件、日志),先由确定性规则引擎初筛,再由 LLM 归纳成"证据链 + 根因假设 + 修复建议"的 Markdown 诊断报告。全程仅发 GET 请求;LLM 不可用时自动降级为纯规则报告。全部实现为 MoonBit(native 后端,零 C stub),已在真实 RKE2 集群上端到端验证。

## 3. 项目方向与通用性说明

方向:AI 应用 / Kubernetes 运维诊断工具。

通用性体现在三个可复用层:① 只读 K8s 访问层(基于 cxh04/kubemoon 动态客户端),任何 MoonBit 云原生工具都可复用;② 表驱动诊断知识库,新增诊断场景只需增加规则表项与单测,知识与引擎解耦;③ OpenAI 兼容 LLM 客户端与 agent 工具循环(OpenAI tool-calling 线格式,异步实现,循环设计参考 mizchi/llm 的 `run_json_chat_loop`),可对接 DeepSeek/GLM/Kimi/vLLM 等任意端点,"LLM + 只读工具白名单"范式可平移到数据库巡检、日志分析等其它运维场景。

## 4. 预期使用场景(3 个)

**场景一|生产 Pod 反复重启**:值班收到告警 → `moon run cmd/main -- prod payments-api-7d9f6b-x2k9l` → Agent 自动 get_pod / get_events / get_logs → 报告:上次终止 OOMKilled(exit 137)、内存 limit 256Mi、已重启 12 次 → 根因"limit 过低或泄漏"→ 建议提高 limit 并排查泄漏。规则 `oomkilled_limit` 兜底,LLM 离线也能出初诊。

**场景二|发版后 Pod 一直 Pending**:CI 部署后新副本未就绪 → moonmedic 读取 FailedScheduling 事件 → 报告"0/6 节点可用:内存不足"(或配额打满)→ 指向扩容节点/调整配额。规则 `sched_insufficient`。

**场景三|发布日镜像拉取失败**:流水线卡在 ImagePullBackOff → moonmedic 区分两类根因:`manifest unknown` → 镜像名/tag 写错;`denied / authentication required` → 缺 imagePullSecrets 或凭据过期 → 分别给出改 tag / 绑定 Secret 的建议。规则 `image_pull_tag` 与 `image_pull_secret`。

以上场景均已被规则引擎单测覆盖;另有探针失败规则 `probe_fail` 与 CrashLoop exit 1 规则 `crash_exit_1` 作为补充场景。

## 5. 拟实现的核心功能

- Agent 工具循环:LLM 自主决定下一个取证动作;工具白名单(get_pod / get_events / get_logs / list_pods)+ 步数上限 + namespace 由 CLI 固定,模型不可控;
- 表驱动规则引擎(6 条规则):OOMKilled、CrashLoop exit 1、FailedScheduling、镜像 tag、镜像凭据、探针失败;
- 只读工具层:get_pod、get_events(按对象过滤、上限 50)、get_logs(自动选首容器、tail≤500)、get_object 通用扩展;
- 优雅降级:证据读取失败或 LLM 不可达 → 纯规则报告 + "数据完整性说明"注记,诊断永不阻塞;
- Markdown 报告 + CLI(列 Pod / 诊断指定 Pod,环境变量配置 kubectl proxy 或直连 Token/CA);
- 18 个单元测试 + GitHub Actions CI(moon fmt --check / check / test);
- 本赛季内补齐:kind 故障注入评测集(≥6 类故障黄金问答,含录制回放),测试增至 20+。

## 6. 项目性质

原创项目:全部 MoonBit 代码为本仓库原创实现,非移植、非 fork。

## 7. 参考项目说明

不适用(原创)。生态依赖与参考:集群访问基于 [cxh04/kubemoon](https://mooncakes.io/docs/cxh04/kubemoon)(Apache-2.0);异步 HTTP 基于 moonbitlang/async;agent 循环的线格式与消息簿记参考 [mizchi/llm](https://github.com/mizchi/llm)(MIT)的 `run_json_chat_loop` 设计并适配异步版,已在 README 注明来源。

## 8. GitHub 仓库链接

https://github.com/young9682/moonmedic

main 分支当前含 14 个有效 commits(W0 计划 → W1 连通 → W2 规则引擎 → W3 LLM 归纳 → W4 Agent 循环 → 规则扩展 → 文档),全部为功能或文档的实质提交,无空提交、无意义拆分或重复提交;所有变更经 PR 合并,提交、评审与 CI 记录完整可追溯。
