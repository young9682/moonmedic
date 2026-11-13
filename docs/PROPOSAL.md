# moonmedic 项目申报书(2026 MoonBit 黑客松 · 十一月赛)

项目名称:moonmedic:MoonBit 实现的 Kubernetes 只读排障 Agent(集群医生)

项目方向:MoonBit AI 应用 / Kubernetes 运维诊断工具

moonmedic 是一个用 MoonBit 编写的 Kubernetes 排障 Agent:把集群里的故障现象丢给它,它通过只读工具自主取证(Pod 状态、事件、日志),先由确定性规则引擎初筛,再由 LLM 归纳为人类可读的"证据链 + 根因假设 + 修复建议"Markdown 诊断报告。项目面向 K8s 集群管理员、运维工程师,以及用 MoonBit 构建云原生工具链的库作者与应用开发者;同时以真实场景检验 MoonBit 在 AI Agent、异步网络协议与多后端工程化方面的可用性,为 MoonBit 云原生生态提供可复用的只读 K8s 访问层与诊断知识库范式。

- 提供只读 Kubernetes 访问层,基于 cxh04/kubemoon 动态客户端,全程仅 GET 请求,工具白名单注册,从架构上杜绝写操作;

- 提供 Pod 诊断工具集:get_pod(容器状态机/重启数/资源限制)、get_events(按对象过滤、条数上限)、get_logs(自动定位容器、tail 裁剪)与通用 get_object(node/quota 等随规则扩展);

- 提供表驱动诊断知识库,首发 OOMKilled、CrashLoopBackOff(exit 1)、Pending/FailedScheduling、镜像拉取(tag/凭据)、探针失败六条规则,新增场景仅需增加表项与对应单测;

- 提供 LLM 归纳层:兼容 OpenAI 接口(DeepSeek/GLM/Kimi/vLLM 均可配置),采用接地式提示词(事实 + 规则初筛 + 事件 + 日志尾,强制"只依据证据、不足需明示"),基于 moonbitlang/async http 实现原生客户端,无 C stub 依赖;

- 提供 Agent 工具循环:LLM 自主决定下一个取证动作(OpenAI tool-calling 线格式,循环设计参考 mizchi/llm 的 run_json_chat_loop 并适配异步),步数上限与只读白名单强制;

- 提供优雅降级能力:证据读取失败或 LLM 不可用时,自动退回纯规则引擎报告,并在"数据完整性说明"中如实注记,诊断流程永不阻塞;

- 提供 Markdown 诊断报告输出:结论(LLM 归纳)+ 发现(置信度/判断/证据链)+ 数据完整性说明;

- 提供 CLI 工具:一键列出 namespace 下的 Pod,或对指定 Pod 出具诊断报告;集群与 LLM 均以环境变量配置,支持 kubectl proxy 与直连(Token/CA)两种接入方式;

- 提供不少于 20 个 MoonBit 单元测试,覆盖规则引擎、提示词构建、线格式解析与 agent 辅助层,并保持核心回归通过;使用 mock OpenAI 服务完成正常与降级双路径端到端验证;

- 提供故障注入评测计划:基于 kind 集群注入不少于 6 类真实故障(OOMKilled、坏镜像、缺 ConfigMap、探针 404、配额打满、exit 1 崩溃),形成黄金问答评测集与 CI 录制回放;

- 提供 CI 与公开仓库持续开发记录:GitHub Actions 覆盖 moon fmt --check / moon check / moon test,提交、PR 与评审记录全程可追溯。

项目仓库:https://github.com/young9682/moonmedic

本项目为原创 MoonBit 实现(非移植);开源许可证:Apache-2.0;依赖生态:cxh04/kubemoon、moonbitlang/async、mizchi/llm(线格式参考)。
