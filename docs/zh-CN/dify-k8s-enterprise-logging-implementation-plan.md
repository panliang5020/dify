# Dify 社区版在 Kubernetes 场景下升级为企业级日志体系实施方案（逐步清单）

## 1. 文档目的与范围

本方案用于将 Dify 在 Kubernetes（以下简称 k8s）部署后的日志能力，从“可用”升级到“大型企业可运营、可审计、可治理”的水平。  
范围覆盖：
- `api`（Flask）服务日志
- Celery Worker/Beat 异步任务日志
- 网关/Nginx/Ingress 访问日志
- k8s 平台日志采集、解析、路由、存储、检索、告警、审计
- 与 Trace/Metrics 的联动

不覆盖：
- 业务代码功能改造（仅涉及日志与可观测性）
- 第三方 SIEM 的深度规则定制（可作为后续阶段）

---

## 2. 实施总原则（必须遵守）

1. **容器标准输出优先**：应用日志输出到 `stdout/stderr`，不依赖容器内文件轮转。  
2. **结构化优先**：统一 JSON 日志 schema，禁止自由文本拼接。  
3. **全链路可关联**：日志必须携带 `trace_id/span_id/request_id`。  
4. **默认脱敏**：日志输出默认脱敏，敏感字段白名单机制。  
5. **多租户隔离**：按 tenant 维度可检索、可授权、可审计。  
6. **成本可控**：分层存储 + 生命周期策略（热/温/冷）。

---

## 3. 目标能力与验收门槛（上线判定）

### 3.1 最低上线门槛（MVP）
- API/Worker/Ingress 日志统一进入中心化平台。
- 95% 以上日志满足统一 schema（字段完整率）。
- 关键请求可通过 `trace_id` 从日志跳转到链路追踪。
- 日志平台支持按 `tenant_id/service/trace_id/status_code` 检索。
- 敏感字段（token/password/key）100% 脱敏。

### 3.2 企业级门槛（GA）
- 支持冷热分层与留存策略（按日志类型独立配置）。
- 支持 RBAC 权限控制与审计访问记录。
- 异常告警与 SLO 绑定（延迟、5xx、队列堆积）。
- 支持日志采集链路中断缓冲与重试，具备数据完整性监控。

---

## 4. 当前 Dify 基线（基于仓库现状）

- 已具备：
  - `api/extensions/ext_logging.py`：支持 text/json 输出。
  - `api/core/logging/structured_formatter.py`：结构化 JSON formatter。
  - `api/core/logging/filters.py`：注入 `trace_id/span_id/tenant_id/user_id`。
  - `api/extensions/ext_request_logging.py`：请求起止日志能力。
  - `api/extensions/ext_otel.py`：OTEL trace/metric 导出能力。
- 主要不足：
  - 未形成“企业统一日志 schema 标准 + 落地治理流程”。
  - k8s 侧采集/路由/留存/权限/告警方案未工程化成套。
  - Celery、Ingress、API 的字段一致性与治理策略未完全统一。

---

## 5. 详细实施清单（按阶段执行）

## Phase 0：立项与准备（第 0 周）

### Step 0.1 组织与职责确认
- 产出：RACI（平台、后端、SRE、安全、运维）。
- 要求：每个步骤有唯一负责人。
- 验收：形成责任矩阵文档并评审通过。

### Step 0.2 环境分层与变更窗口定义
- 产出：dev/staging/prod 环境推进计划。
- 要求：先 dev，再 staging，最后 prod，禁止跨级直上。
- 验收：发布计划与回滚窗口明确。

### Step 0.3 目标平台选型冻结
- 选型示例（择一并冻结）：
  - OTel Collector + Loki + Grafana
  - Fluent Bit + OpenSearch/Elasticsearch + Kibana
- 验收：架构评审通过，形成 ADR（Architecture Decision Record）。

---

## Phase 1：日志标准统一（第 1 周）

### Step 1.1 制定统一日志 schema v1
- 必选字段：
  - `ts`, `severity`, `service`, `env`, `namespace`, `pod`, `container`
  - `trace_id`, `span_id`, `request_id`
  - `tenant_id`, `user_id`, `user_type`
  - `path`, `method`, `status_code`, `latency_ms`
  - `message`, `attributes`, `error.stack_trace`
- 验收：发布 schema 文档，团队签字确认。

### Step 1.2 制定日志分级与分类标准
- 分类：应用日志、访问日志、安全审计、业务审计。
- 等级：DEBUG/INFO/WARN/ERROR 使用场景表。
- 验收：至少完成 20 条真实日志映射样例。

### Step 1.3 制定敏感信息脱敏规则
- 黑名单字段：`password`, `token`, `authorization`, `api_key`, `secret` 等。
- 脱敏规则：全掩码/部分掩码/哈希。
- 验收：安全团队评审通过。

---

## Phase 2：Dify 应用侧改造（第 2-3 周）

### Step 2.1 API 服务默认 JSON stdout
- 调整部署配置：`LOG_OUTPUT_FORMAT=json`。
- 禁止容器内持久日志文件（`LOG_FILE` 留空）。
- 验收：Pod 日志均为单行 JSON，可被采集器直接解析。

### Step 2.2 扩展 Structured Formatter 字段一致性
- 目标：所有必选字段都可稳定输出（缺省值策略统一）。
- 包括：`service/env/deploy/tenant/request` 等上下文字段。
- 验收：抽样 500 条日志，字段完整率 ≥ 95%。

### Step 2.3 统一请求访问日志格式
- 将 `ext_request_logging.py` 输出改为结构化 access 事件。
- 包含 method/path/status/latency/trace_id/client_ip。
- 验收：访问日志不再出现不可机器解析的自由格式行。

### Step 2.4 Celery Worker/Beat 日志统一
- 确保 Worker/Beat 与 API 使用一致 schema。
- 任务上下文补齐：`task_name/task_id/queue/retry_count`。
- 验收：异步任务错误可按 `task_id + trace_id` 完整检索。

### Step 2.5 日志降噪与采样
- 对高频 INFO/DEBUG 事件做采样。
- 对重复错误增加限流（同类错误 N 秒输出一次聚合摘要）。
- 验收：压测下日志量下降且关键错误零丢失。

### Step 2.6 敏感字段治理落地
- 在请求/响应日志路径增加统一脱敏函数。
- 默认不记录 body，必须显式白名单才输出部分字段。
- 验收：安全扫描和人工抽查均无敏感信息泄露。

---

## Phase 3：k8s 采集与传输链路建设（第 3-4 周）

### Step 3.1 部署日志采集代理（DaemonSet）
- 建议：Fluent Bit / Vector / OTel Collector（二选一主方案）。
- 采集源：`/var/log/containers/*.log`。
- 验收：所有 Dify Pod 日志可在采集器输入侧可见。

### Step 3.2 采集侧解析与 enrich
- 解析 JSON，追加 k8s 元数据：namespace/pod/node/container/image。
- 对非 JSON 行标记 `parse_error=true` 并单独路由。
- 验收：平台查询可按 pod/container 精确过滤。

### Step 3.3 采集侧可靠性保障
- 启用缓冲队列、重试、背压处理。
- 明确“不可达后端”时的最大缓存时长与丢弃策略。
- 验收：断链演练 30 分钟后恢复，日志可追补。

### Step 3.4 多目标路由
- 应用日志→检索存储。
- 安全审计→审计存储（高留存）。
- 验收：不同日志类型进入对应索引/流。

---

## Phase 4：存储、索引与权限体系（第 4-5 周）

### Step 4.1 索引与数据流设计
- 维度：按环境/服务/日志类型分索引。
- 关键字段建索引：`trace_id/tenant_id/status_code/service`。
- 验收：关键查询 P95 响应时间达标（按企业目标）。

### Step 4.2 生命周期策略（ILM）
- 热存储：7-15 天（高频检索）。
- 温存储：30-90 天（低频检索）。
- 冷归档：180 天或按合规要求。
- 验收：自动滚动与自动删除策略生效。

### Step 4.3 RBAC 与多租户访问控制
- 定义角色：平台管理员、研发、SRE、安全审计。
- 限制跨租户访问，日志导出需要审批轨迹。
- 验收：越权访问测试全部失败。

### Step 4.4 查询看板模板化
- 交付标准看板：
  - API 5xx 趋势
  - 高延迟接口 TOP N
  - Celery 失败任务榜
  - 租户级错误分布
- 验收：值班人员无需写 DSL 即可完成常见排障。

---

## Phase 5：日志与 Trace/Metrics 联动（第 5-6 周）

### Step 5.1 Trace-Log 互跳
- 要求日志携带 trace_id，链路系统可反查日志。
- 验收：随机抽样 30 个 trace，均可定位相关日志。

### Step 5.2 SLI/SLO 与日志告警
- SLI：可用性、延迟、错误率、任务成功率。
- 告警：5xx 突增、超时突增、任务堆积、采集延迟。
- 验收：告警触发后 1 分钟内关联日志链接可用。

### Step 5.3 值班 Runbook
- 针对每类告警定义排障步骤、责任人、升级路径。
- 验收：演练中值班人员可独立完成闭环。

---

## Phase 6：安全合规与运营闭环（第 6-7 周）

### Step 6.1 审计日志链路独立化
- 安全事件日志单独流转与留存，不与普通应用日志混存。
- 验收：满足企业内控与审计取证要求。

### Step 6.2 日志访问审计
- 记录“谁在何时查询/导出何种日志”。
- 验收：可按用户追踪历史访问行为。

### Step 6.3 周期性健康检查制度
- 每周：字段完整率、解析错误率、日志延迟、告警有效性。
- 每月：成本复盘、留存策略调整、误报漏报复盘。
- 验收：形成固定运营报表模板。

---

## 6. 逐项交付件清单（必须落地）

1. 日志 schema v1 文档（含样例）  
2. 脱敏规则文档（黑白名单 + 示例）  
3. k8s 采集配置（DaemonSet + ConfigMap）  
4. 存储索引与 ILM 策略文件  
5. RBAC 权限矩阵  
6. 监控告警规则（Prometheus/Grafana/Kibana）  
7. 值班 Runbook  
8. 验收报告（字段完整率、丢失率、查询性能、演练结果）

---

## 7. 风险清单与应对

1. **日志量暴涨导致成本失控**  
   - 对策：采样、降噪、冷热分层、日志级别治理。

2. **敏感信息泄露**  
   - 对策：默认不打 body、统一脱敏中间层、上线前 DLP 扫描。

3. **采集链路中断丢日志**  
   - 对策：本地缓冲 + 重试 + 链路可用性告警。

4. **多团队标准不一致**  
   - 对策：schema 强约束 + CI 校验 + 发布门禁。

---

## 8. 上线切换步骤（生产）

1. 完成 staging 全量压测和故障演练。  
2. 生产灰度：先 10% 工作负载，观察 24 小时。  
3. 检查指标：解析错误率、采集延迟、索引写入失败率、告警误报率。  
4. 扩大至 50%，再全量。  
5. 发布后 72 小时值班增强（on-call 加强巡检）。

---

## 9. 最终验收检查单（可直接打勾）

- [ ] API/Worker/Ingress 日志全部中心化接入完成  
- [ ] 统一 schema 字段完整率 ≥ 95%  
- [ ] 敏感字段脱敏覆盖率 = 100%  
- [ ] trace_id 全链路可检索与互跳  
- [ ] RBAC 多租户权限验证通过  
- [ ] 日志留存与 ILM 策略生效  
- [ ] 告警联动与 Runbook 演练通过  
- [ ] 生产灰度与全量上线复盘完成

---

## 10. 与 Dify 当前代码位置的对应关系（实施定位）

- 日志初始化：`/home/runner/work/dify/dify/api/extensions/ext_logging.py`  
- 结构化格式：`/home/runner/work/dify/dify/api/core/logging/structured_formatter.py`  
- 上下文字段注入：`/home/runner/work/dify/dify/api/core/logging/filters.py`  
- 请求日志：`/home/runner/work/dify/dify/api/extensions/ext_request_logging.py`  
- OTEL 能力：`/home/runner/work/dify/dify/api/extensions/ext_otel.py`  
- 配置项定义：`/home/runner/work/dify/dify/api/configs/feature/__init__.py`、`/home/runner/work/dify/dify/api/configs/deploy/__init__.py`

