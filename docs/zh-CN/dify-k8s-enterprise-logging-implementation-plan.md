# Dify 社区版在 Kubernetes 场景下升级为企业级日志体系——完整实施方案

> **版本**：v2.0（增强版）  
> **适用对象**：平台架构师、后端研发、SRE、安全合规、运维  
> **最后更新**：2026-04-16

---

## 目录

1. [文档目的与范围](#1-文档目的与范围)
2. [实施总原则](#2-实施总原则必须遵守)
3. [目标能力与验收门槛](#3-目标能力与验收门槛上线判定)
4. [当前 Dify 基线深度分析](#4-当前-dify-基线深度分析基于仓库代码)
5. [详细实施清单（Phase 0–6）](#5-详细实施清单按阶段执行)
6. [关键配置参考（可直接使用）](#6-关键配置参考可直接使用)
7. [逐项交付件清单](#7-逐项交付件清单必须落地)
8. [风险清单与应对](#8-风险清单与应对)
9. [上线切换步骤](#9-上线切换步骤生产)
10. [回滚方案](#10-回滚方案)
11. [最终验收检查单](#11-最终验收检查单可直接打勾)
12. [附录：代码位置速查表](#附录a与-dify-当前代码位置的对应关系实施定位)
13. [附录：术语表](#附录b术语表)

---

## 1. 文档目的与范围

本方案用于将 Dify 在 Kubernetes（以下简称 k8s）部署后的日志能力，从"可用"升级到"大型企业可运营、可审计、可治理"的水平。

### 1.1 覆盖范围

| 组件 | 对应 Pod | 说明 |
|---|---|---|
| API 服务 | `dify-api` | Flask + Gunicorn，MODE=api |
| Celery Worker | `dify-worker` | MODE=worker，处理 dataset/workflow/mail 等队列 |
| Celery Beat | `dify-worker-beat` | MODE=beat，调度周期任务 |
| Web 前端 | `dify-web` | Next.js SSR，需采集 Node 日志 |
| Nginx/Ingress | `nginx` 或 Ingress Controller | 访问日志、WAF 日志 |
| Plugin Daemon | `dify-plugin-daemon` | 插件运行时日志 |
| Sandbox | `dify-sandbox` | 代码执行沙箱日志 |
| 中间件 | Redis/PostgreSQL/向量库 | 可选纳入统一采集 |

### 1.2 不覆盖

- 业务代码功能改造（仅涉及日志与可观测性）。
- 第三方 SIEM 的深度规则定制（可作为后续阶段）。
- 向量数据库、对象存储等中间件内部日志的深度治理。

---

## 2. 实施总原则（必须遵守）

| # | 原则 | 详细说明 |
|---|---|---|
| 1 | **容器标准输出优先** | 应用日志输出到 `stdout/stderr`，不依赖容器内文件轮转。当前 Dify 默认 `LOG_FILE=/app/logs/server.log`（见 `docker/.env.example:78`），k8s 环境**必须**置空。 |
| 2 | **结构化优先** | 统一 JSON 日志 schema，禁止自由文本拼接。当前 `ext_request_logging.py` 的 `_log_request_finished` 使用 `%s %s %s %s %s` 格式化（第 73-80 行），需改造。 |
| 3 | **全链路可关联** | 日志必须携带 `trace_id/span_id/request_id`。当前 `TraceContextFilter` 已支持 OTEL span 提取（`filters.py:34-47`），但 Celery 上下文传播需验证。 |
| 4 | **默认脱敏** | 日志输出默认脱敏，敏感字段白名单机制。当前 `encrypter.py` 已有 `obfuscated_token()` 函数，但未在日志路径统一调用。 |
| 5 | **多租户隔离** | 按 tenant 维度可检索、可授权、可审计。当前 `IdentityContextFilter` 已注入 `tenant_id`（`filters.py:50-94`），需确保采集侧将其作为 label。 |
| 6 | **成本可控** | 分层存储 + 生命周期策略（热/温/冷）。 |
| 7 | **无侵入优先** | 能通过配置/采集侧解决的，不修改业务代码。 |

---

## 3. 目标能力与验收门槛（上线判定）

### 3.1 最低上线门槛（MVP）

| # | 能力 | 量化指标 |
|---|---|---|
| M1 | API/Worker/Ingress 日志统一进入中心化平台 | 100% Pod 已接入 |
| M2 | 统一 schema 字段完整率 | ≥ 95%（抽样 1000 条） |
| M3 | trace_id 全链路可检索 | 随机 30 个请求均可定位 |
| M4 | 多维检索 | 支持 `tenant_id/service/trace_id/status_code/task_id` |
| M5 | 敏感字段脱敏 | token/password/key 脱敏覆盖率 = 100% |
| M6 | 采集延迟 | 日志从产生到可检索 ≤ 30 秒（P95） |

### 3.2 企业级门槛（GA）

| # | 能力 | 量化指标 |
|---|---|---|
| G1 | 冷热分层与留存策略 | 按日志类型独立 ILM 已生效 |
| G2 | RBAC 权限控制 | 越权访问测试全部失败 |
| G3 | 审计日志独立链路 | 审计日志与应用日志物理隔离 |
| G4 | 异常告警与 SLO 绑定 | 5xx/超时/队列堆积告警已上线 |
| G5 | 采集链路韧性 | 断链 30 分钟恢复后日志可追补 |
| G6 | 日志平台自身可观测 | 采集器/存储健康指标有监控 |

---

## 4. 当前 Dify 基线深度分析（基于仓库代码）

### 4.1 日志初始化链路

```
启动入口
  ↓
ext_logging.init_app(app)                          # api/extensions/ext_logging.py:12
  ├─ 创建 StreamHandler(stdout)                     # 第 30-31 行
  ├─ 可选创建 RotatingFileHandler                    # 第 17-27 行（k8s 中应禁用）
  ├─ 挂载 TraceContextFilter()                       # 第 37 行 → core/logging/filters.py
  ├─ 挂载 IdentityContextFilter()                    # 第 38 行 → core/logging/filters.py
  └─ 设置 Formatter（text 或 JSON）                   # 第 41 行 → _create_formatter()
      ├─ JSON: StructuredJSONFormatter               # core/logging/structured_formatter.py
      └─ text: _TextFormatter                        # ext_logging.py:92
```

### 4.2 当前 JSON Formatter 输出字段（`StructuredJSONFormatter._build_log_dict`）

| 字段 | 是否总是输出 | 来源 | 备注 |
|---|---|---|---|
| `ts` | ✅ 总是 | `datetime.now(UTC)` | ISO 8601 毫秒精度 |
| `severity` | ✅ 总是 | `SEVERITY_MAP` | DEBUG/INFO/WARN/ERROR |
| `service` | ✅ 总是 | `dify_config.APPLICATION_NAME` | 默认 `langgenius/dify` |
| `caller` | ✅ 总是 | `record.filename:lineno` | |
| `message` | ✅ 总是 | `record.getMessage()` | |
| `trace_id` | ⚠️ 有时 | `TraceContextFilter` | 仅在 OTEL 启用或请求上下文存在时 |
| `span_id` | ⚠️ 有时 | `TraceContextFilter` | 同上 |
| `identity.tenant_id` | ⚠️ 有时 | `IdentityContextFilter` | 仅认证请求 |
| `identity.user_id` | ⚠️ 有时 | 同上 | |
| `identity.user_type` | ⚠️ 有时 | 同上 | account/end_user |
| `attributes` | ❌ 可选 | 业务代码显式传入 | 极少使用 |
| `stack_trace` | ⚠️ 有时 | `record.exc_info` | 仅 ERROR 且有异常 |

**缺失字段（需补充）：**
- `env`（部署环境）
- `namespace`（k8s 命名空间）
- `pod`（Pod 名称）
- `container`（容器名称）
- `request_id`（请求 ID）
- `path`、`method`、`status_code`、`latency_ms`（访问日志场景）
- `task_name`、`task_id`、`queue`、`retry_count`（Celery 场景）

### 4.3 请求日志现状（`ext_request_logging.py`）

**问题 1**：`_log_request_finished` 使用 `%s` 拼接格式（第 73-80 行）：
```python
logger.info(
    "%s %s %s %s %s",
    req_method, req_path, status_code, duration_ms, trace_id,
)
```
在 JSON 模式下输出为 `"message": "GET /v1/apps 200 12.345 abc123"`，字段全部混在 `message` 中，**无法被采集器按字段解析**。

**问题 2**：DEBUG 模式下 `_log_request_started` 会输出完整请求 body（第 36-46 行），存在敏感信息泄露风险。

### 4.4 Celery 日志现状

- Worker/Beat 使用 `shared-api-worker-env`（`docker-compose.yaml:777,816`），与 API 共享 `LOG_OUTPUT_FORMAT` 配置。
- OTEL 支持：`runtime.py:83-97` 的 `init_celery_worker` 已自动在 Worker 初始化时注入 `CeleryInstrumentor`。
- **缺失**：Celery 任务日志缺少 `task_name/task_id/queue/retry_count` 结构化字段。

### 4.5 Nginx 日志现状

当前 `docker/nginx/nginx.conf.template` 使用标准 combined 格式（第 19-21 行）：
```nginx
log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                  '$status $body_bytes_sent "$http_referer" '
                  '"$http_user_agent" "$http_x_forwarded_for"';
```
**需改造为 JSON 格式**以便机器解析。

### 4.6 OTEL 现状

| 配置项 | 默认值 | 文件位置 |
|---|---|---|
| `ENABLE_OTEL` | `false` | `configs/observability/otel/otel_config.py:10` |
| `OTEL_EXPORTER_TYPE` | `otlp` | 同上:35 |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http` | 同上:40 |
| `OTEL_SAMPLING_RATE` | `0.1` | 同上:45 |
| `OTLP_BASE_ENDPOINT` | `http://localhost:4318` | 同上:25 |

已集成的 Instrumentor：
- FlaskInstrumentor（API 进程）
- CeleryInstrumentor（Worker 进程）
- SQLAlchemyInstrumentor
- RedisInstrumentor
- HTTPXClientInstrumentor

### 4.7 现有脱敏能力

| 函数 | 位置 | 作用 |
|---|---|---|
| `obfuscated_token(token)` | `core/helper/encrypter.py:6` | 前 6 后 2 中间掩码 |
| `full_mask_token()` | `core/helper/encrypter.py:14` | 全掩码 |
| `csv_sanitizer` | `core/helper/csv_sanitizer.py` | CSV 注入防护 |

**缺失**：无统一的日志脱敏中间件，各处手动调用。

---

## 5. 详细实施清单（按阶段执行）

---

### Phase 0：立项与准备（第 0 周）

#### Step 0.1 组织与职责确认

**目标**：明确每个步骤的唯一负责人。

**具体操作**：
1. 召集平台架构、后端研发、SRE、安全、运维代表。
2. 按 RACI 矩阵模板填写所有 Phase 的职责分配。
3. 指定项目 PM 与技术 Lead。

**RACI 模板示例**：

| Step | 平台架构 | 后端研发 | SRE | 安全 | 运维 |
|---|---|---|---|---|---|
| 1.1 日志 schema | A | R | C | C | I |
| 2.1 API JSON stdout | C | R | A | I | I |
| 3.1 采集器部署 | C | I | R | I | A |
| 6.1 审计日志 | C | R | I | A | I |

> R=执行, A=审批, C=咨询, I=知会

**产出**：责任矩阵文档。  
**验收**：评审会议通过，所有干系人签字。

#### Step 0.2 环境分层与变更窗口定义

**目标**：确保变更可控、可回滚。

**具体操作**：
1. 确认 k8s 集群环境：dev / staging / prod。
2. 确认每个环境的变更窗口（如 prod 仅周二/四 10:00-12:00）。
3. 确认回滚策略（见 [第 10 节](#10-回滚方案)）。

**产出**：环境推进计划表。

| 环境 | 开始时间 | 持续 | 变更窗口 | 回滚窗口 |
|---|---|---|---|---|
| dev | W1 D1 | 3 天 | 随时 | 即时 |
| staging | W2 D1 | 5 天 | 工作日 | 2 小时内 |
| prod | W3 D2 | 3 天 | 周二/四 10-12 | 30 分钟内 |

**验收**：计划表经 SRE Lead 审批。

#### Step 0.3 目标平台选型冻结

**目标**：确定日志采集、存储、检索、告警全链路技术栈。

**方案对比**：

| 维度 | 方案 A | 方案 B |
|---|---|---|
| 采集器 | Fluent Bit（DaemonSet） | OTel Collector（DaemonSet） |
| 传输 | Fluent Bit → Kafka（可选）→ 存储 | OTel Collector → 存储 |
| 存储 | OpenSearch / Elasticsearch | Grafana Loki |
| 检索 UI | Kibana / OpenSearch Dashboards | Grafana |
| Trace 存储 | Jaeger / Tempo | Grafana Tempo |
| 告警 | ElastAlert / OpenSearch Alerting | Grafana Alerting |
| 优势 | 全文检索能力强、生态成熟 | 成本低、与 Grafana 生态天然集成 |
| 劣势 | 存储成本高、运维复杂 | 全文检索弱、大规模性能需验证 |

**决策输出**：ADR（Architecture Decision Record）文档，包含：
- 选型结论与理由
- 技术栈版本号
- 容量规划初步估算
- 否决方案的原因

**验收**：架构评审通过。

#### Step 0.4 容量规划

**目标**：预估日志量，指导存储与采集器资源配置。

**估算模板**：

| 组件 | 预估 QPS | 单条大小 | 日产量 | 月产量 |
|---|---|---|---|---|
| API 访问日志 | 500 | 0.5 KB | 21 GB | 630 GB |
| API 应用日志 | 200 | 1 KB | 17 GB | 510 GB |
| Celery Worker | 100 | 1 KB | 8.6 GB | 258 GB |
| Nginx 访问日志 | 500 | 0.3 KB | 13 GB | 390 GB |
| **合计** | | | **~60 GB/天** | **~1.8 TB/月** |

> 以上为示例，需根据实际业务量调整。

**验收**：容量评估报告完成，存储资源采购/申请启动。

---

### Phase 1：日志标准统一（第 1 周）

#### Step 1.1 制定统一日志 schema v1

**目标**：所有组件输出同一 JSON schema，采集侧零解析成本。

**完整字段定义**：

| 字段路径 | 类型 | 必选 | 来源 | 说明 |
|---|---|---|---|---|
| `ts` | string | ✅ | 应用 | ISO 8601 UTC，毫秒精度：`2026-04-16T07:10:46.313Z` |
| `severity` | string | ✅ | 应用 | `DEBUG`/`INFO`/`WARN`/`ERROR` |
| `service` | string | ✅ | 应用/环境变量 | 服务名：`dify-api`/`dify-worker`/`dify-beat`/`dify-web` |
| `env` | string | ✅ | 环境变量 | 部署环境：`dev`/`staging`/`prod` |
| `caller` | string | ✅ | 应用 | 调用位置：`filename:lineno` |
| `message` | string | ✅ | 应用 | 日志消息 |
| `trace_id` | string | ⚠️ | OTEL/ContextVar | 32 位十六进制 |
| `span_id` | string | ⚠️ | OTEL | 16 位十六进制 |
| `request_id` | string | ⚠️ | ContextVar | 10 位十六进制 |
| `identity.tenant_id` | string | ⚠️ | Flask-Login | 租户 ID |
| `identity.user_id` | string | ⚠️ | Flask-Login | 用户 ID |
| `identity.user_type` | string | ⚠️ | Flask-Login | `account`/`end_user` |
| `http.method` | string | 仅访问日志 | Flask request | `GET`/`POST` 等 |
| `http.path` | string | 仅访问日志 | Flask request | 请求路径 |
| `http.status_code` | int | 仅访问日志 | Flask response | HTTP 状态码 |
| `http.latency_ms` | float | 仅访问日志 | 计算 | 请求耗时毫秒 |
| `http.client_ip` | string | 仅访问日志 | Flask request | 客户端 IP |
| `celery.task_name` | string | 仅 Worker | Celery context | 任务全名 |
| `celery.task_id` | string | 仅 Worker | Celery context | 任务 UUID |
| `celery.queue` | string | 仅 Worker | Celery context | 队列名 |
| `celery.retry_count` | int | 仅 Worker | Celery context | 重试次数 |
| `attributes` | object | ❌ | 业务代码 | 自定义扩展字段 |
| `stack_trace` | string | ⚠️ | exc_info | 仅 ERROR 且有异常 |
| `k8s.namespace` | string | ✅ | 采集器 enrich | k8s 命名空间 |
| `k8s.pod` | string | ✅ | 采集器 enrich | Pod 名称 |
| `k8s.node` | string | ✅ | 采集器 enrich | 节点名称 |
| `k8s.container` | string | ✅ | 采集器 enrich | 容器名称 |

**JSON 日志样例——API 访问日志**：
```json
{
  "ts": "2026-04-16T07:10:46.313Z",
  "severity": "INFO",
  "service": "dify-api",
  "env": "prod",
  "caller": "ext_request_logging.py:73",
  "message": "HTTP request completed",
  "trace_id": "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4",
  "span_id": "1234567890abcdef",
  "request_id": "f4e2a1b3c5",
  "identity": {
    "tenant_id": "550e8400-e29b-41d4-a716-446655440000",
    "user_id": "user-123",
    "user_type": "account"
  },
  "http": {
    "method": "POST",
    "path": "/v1/chat-messages",
    "status_code": 200,
    "latency_ms": 1234.567,
    "client_ip": "10.0.1.100"
  }
}
```

**JSON 日志样例——Celery Worker**：
```json
{
  "ts": "2026-04-16T07:11:00.000Z",
  "severity": "ERROR",
  "service": "dify-worker",
  "env": "prod",
  "caller": "dataset_indexing_task.py:42",
  "message": "Dataset indexing failed",
  "trace_id": "b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5",
  "identity": {
    "tenant_id": "550e8400-e29b-41d4-a716-446655440000"
  },
  "celery": {
    "task_name": "schedule.clean_unused_datasets_task",
    "task_id": "d290f1ee-6c54-4b01-90e6-d701748f0851",
    "queue": "dataset",
    "retry_count": 2
  },
  "stack_trace": "Traceback (most recent call last):\n  ..."
}
```

**JSON 日志样例——Nginx**：
```json
{
  "ts": "2026-04-16T07:10:46.000Z",
  "severity": "INFO",
  "service": "nginx",
  "http": {
    "method": "POST",
    "path": "/v1/chat-messages",
    "status_code": 200,
    "latency_ms": 1250,
    "client_ip": "192.168.1.100",
    "user_agent": "Mozilla/5.0",
    "referer": "-",
    "upstream_addr": "10.0.0.5:5001",
    "upstream_response_time": 1.234,
    "bytes_sent": 4096,
    "request_length": 512
  }
}
```

**验收**：
- 发布 schema 文档，团队签字确认。
- 至少 3 种日志类型的样例均通过 JSON Schema 校验。

#### Step 1.2 制定日志分级与分类标准

**目标**：统一日志级别使用规范，避免"全 INFO"或"ERROR 泛滥"。

**日志分类**：

| 类别 | 说明 | 留存策略 | 示例 |
|---|---|---|---|
| 应用日志 | 业务逻辑执行过程 | 热 7 天 / 温 30 天 / 冷 90 天 | 模型调用、RAG 检索 |
| 访问日志 | HTTP 请求/响应 | 热 7 天 / 温 30 天 | API 访问记录 |
| 安全审计日志 | 认证、授权、敏感操作 | 热 30 天 / 温 180 天 / 冷 365 天 | 登录、API Key 管理 |
| 业务审计日志 | 数据变更、配置变更 | 热 30 天 / 温 90 天 | 应用发布、数据集删除 |
| 系统日志 | 健康检查、启动关闭 | 热 3 天 / 温 7 天 | liveness probe |

**日志级别使用场景表**：

| 级别 | 使用场景 | 不应使用的场景 |
|---|---|---|
| `DEBUG` | 开发调试、SQL 详情、请求/响应 body | 生产环境常规运行 |
| `INFO` | 请求完成、任务完成、状态变更 | 循环内逐条处理（应采样） |
| `WARN` | 可恢复的异常、重试、降级 | 正常业务逻辑 |
| `ERROR` | 不可恢复的异常、影响用户体验 | 可忽略的第三方超时 |

**映射样例（至少 20 条）**：

| # | 原始日志场景 | 级别 | 分类 |
|---|---|---|---|
| 1 | API 请求完成 | INFO | 访问日志 |
| 2 | 用户登录成功 | INFO | 安全审计 |
| 3 | 用户登录失败 | WARN | 安全审计 |
| 4 | API Key 创建 | INFO | 安全审计 |
| 5 | 模型调用成功 | INFO | 应用日志 |
| 6 | 模型调用超时 | WARN | 应用日志 |
| 7 | 模型调用失败 | ERROR | 应用日志 |
| 8 | RAG 检索完成 | INFO | 应用日志 |
| 9 | RAG 检索无结果 | WARN | 应用日志 |
| 10 | 数据集索引成功 | INFO | 业务审计 |
| 11 | 数据集索引失败 | ERROR | 应用日志 |
| 12 | Celery 任务超时 | ERROR | 应用日志 |
| 13 | Celery 任务重试 | WARN | 应用日志 |
| 14 | 数据库连接超时 | ERROR | 系统日志 |
| 15 | Redis 连接恢复 | WARN | 系统日志 |
| 16 | 应用发布 | INFO | 业务审计 |
| 17 | 应用删除 | INFO | 业务审计 |
| 18 | 数据集删除 | INFO | 业务审计 |
| 19 | 健康检查请求 | DEBUG | 系统日志 |
| 20 | 服务启动完成 | INFO | 系统日志 |
| 21 | Workflow 节点执行失败 | ERROR | 应用日志 |
| 22 | 插件加载失败 | ERROR | 应用日志 |
| 23 | 文件上传完成 | INFO | 业务审计 |
| 24 | 配置项变更 | INFO | 安全审计 |
| 25 | 租户创建/删除 | INFO | 安全审计 |

**验收**：映射表覆盖 ≥ 20 条真实场景，并经研发团队确认。

#### Step 1.3 制定敏感信息脱敏规则

**目标**：确保日志中不泄露任何凭据、密钥、个人隐私信息。

**脱敏黑名单字段**：

| 字段模式 | 脱敏规则 | 示例 |
|---|---|---|
| `*password*` | 全掩码 `****` | `password=****` |
| `*token*` | 部分掩码（前 6 后 2） | `sk-abc1************ef` |
| `*authorization*` | 部分掩码 | `Bearer sk-abc1****ef` |
| `*api_key*` | 部分掩码（前 6 后 2） | `app-abc1************ef` |
| `*secret*` | 全掩码 | `****` |
| `*cookie*` | 全掩码 | `****` |
| `*credential*` | 全掩码 | `****` |
| 请求/响应 body | 默认不记录 | 需显式白名单才输出 |
| 邮箱地址 | 部分掩码 | `u***@example.com` |
| 手机号 | 部分掩码 | `138****5678` |

**白名单（允许记录的 body 字段）**：
- `inputs`（用户输入的部分字段，排除文件内容）
- `query`（对话查询文本）
- `mode`（应用模式）
- `response_mode`（响应模式）

**验收**：安全团队评审通过，DLP 扫描验证。

---

### Phase 2：Dify 应用侧改造（第 2-3 周）

#### Step 2.1 API 服务切换为 JSON stdout

**目标**：Pod 日志均为单行 JSON，不产生容器内日志文件。

**具体操作**：

1. **修改 k8s Deployment 环境变量**：
   ```yaml
   env:
     - name: LOG_OUTPUT_FORMAT
       value: "json"
     - name: LOG_FILE
       value: ""          # 禁用文件日志
     - name: LOG_LEVEL
       value: "INFO"      # 生产环境默认 INFO
     - name: LOG_TZ
       value: "UTC"       # 统一 UTC
     - name: ENABLE_REQUEST_LOGGING
       value: "True"      # 启用请求日志
   ```

2. **影响范围**：
   - `ext_logging.py:62` 的 `_create_formatter()` 将返回 `StructuredJSONFormatter`。
   - `ext_logging.py:17-27` 的 `RotatingFileHandler` 不会创建（`LOG_FILE` 为空）。
   - 所有通过 `logging.getLogger()` 的日志都走 JSON 格式。

3. **验证命令**：
   ```bash
   # 在 k8s 中验证
   kubectl logs -l app=dify-api --tail=10 | head -5
   # 应看到每行都是合法 JSON
   kubectl logs -l app=dify-api --tail=100 | python3 -c "
   import sys, json
   errors = 0
   for line in sys.stdin:
       try: json.loads(line)
       except: errors += 1; print(f'PARSE_ERROR: {line[:100]}')
   print(f'Total errors: {errors}')
   "
   ```

**验收**：100% Pod 日志行为合法 JSON，解析错误率 = 0。

#### Step 2.2 扩展 StructuredJSONFormatter 字段

**目标**：补齐缺失的 `env`、`request_id` 字段，为 Celery/访问日志扩展做准备。

**需修改文件**：`api/core/logging/structured_formatter.py`

**改造要点**：

1. 在 `_build_log_dict` 中增加 `env` 字段：
   ```python
   # 在 core fields 部分增加
   log_dict["env"] = f"{dify_config.DEPLOY_ENV}-{dify_config.EDITION}"
   ```

2. 增加 `request_id` 字段：
   ```python
   request_id = getattr(record, "req_id", "")
   if request_id:
       log_dict["request_id"] = request_id
   ```

3. 增加 Celery 上下文字段支持：
   ```python
   celery_ctx = self._extract_celery_context(record)
   if celery_ctx:
       log_dict["celery"] = celery_ctx
   ```

4. 增加 HTTP 上下文字段支持：
   ```python
   http_ctx = self._extract_http_context(record)
   if http_ctx:
       log_dict["http"] = http_ctx
   ```

**验收**：抽样 500 条日志，字段完整率 ≥ 95%。

#### Step 2.3 统一请求访问日志格式

**目标**：`ext_request_logging.py` 输出结构化访问事件，而非自由格式文本。

**需修改文件**：`api/extensions/ext_request_logging.py`

**改造要点**：

将 `_log_request_finished` 中的 `logger.info("%s %s %s %s %s", ...)` 改为通过 `extra` 字典传递结构化字段：

```python
def _log_request_finished(_sender, response, **_extra):
    # ... 保留现有的 start_ts / duration_ms 计算逻辑 ...
    
    logger.info(
        "HTTP request completed",
        extra={
            "attributes": {
                "http.method": req_method,
                "http.path": req_path,
                "http.status_code": getattr(response, "status_code", 0),
                "http.latency_ms": duration_ms,
                "http.client_ip": flask.request.remote_addr if has_ctx else "-",
            }
        },
    )
```

**同时**，在 `_log_request_started` 中对 DEBUG 模式下的 body 输出做脱敏处理。

**验收**：访问日志不再出现自由格式行，所有字段可独立检索。

#### Step 2.4 Celery Worker/Beat 日志统一

**目标**：确保 Worker/Beat 与 API 使用一致 schema，并补齐任务上下文。

**需新增文件**：`api/core/logging/celery_context_filter.py`

**实现思路**：

```python
import logging
from celery import current_task

class CeleryTaskContextFilter(logging.Filter):
    """Filter that adds Celery task context to log records."""
    
    def filter(self, record: logging.LogRecord) -> bool:
        task = current_task
        if task and not task.request.called_directly:
            record.celery_task_name = task.name
            record.celery_task_id = task.request.id
            record.celery_queue = task.request.delivery_info.get("routing_key", "")
            record.celery_retry_count = task.request.retries or 0
        else:
            record.celery_task_name = ""
            record.celery_task_id = ""
            record.celery_queue = ""
            record.celery_retry_count = 0
        return True
```

**注册位置**：在 `ext_logging.py:init_app` 中根据 `MODE` 环境变量条件挂载。

**验收**：
- 异步任务错误可按 `celery.task_id + trace_id` 完整检索。
- Worker 日志与 API 日志 schema 一致（通过 JSON Schema 校验）。

#### Step 2.5 日志降噪与采样

**目标**：控制日志量，确保关键错误零丢失。

**具体策略**：

| 策略 | 实现方式 | 适用场景 |
|---|---|---|
| 健康检查降级 | 对 `/health`、`/readiness` 路径日志改为 DEBUG | 高频探活 |
| 同类错误限流 | 自定义 Filter 按 (logger, level, message_hash) 限流，每 60s 输出一次聚合计数 | 数据库连接风暴 |
| DEBUG 日志采样 | 配置 `LOG_LEVEL=INFO` 默认过滤 DEBUG | 全环境 |
| 高频 INFO 采样 | 对特定高频 INFO（如心跳上报）按比例采样 | 压测/大促 |

**验收**：
- 压测（1000 QPS）下日志量 < 基线的 50%。
- ERROR 级别日志零丢失（对比应用异常计数器）。

#### Step 2.6 敏感字段治理落地

**目标**：建立统一脱敏中间件，从日志路径根本杜绝敏感信息泄露。

**需新增文件**：`api/core/logging/sanitizer.py`

**实现思路**：

```python
import re
import logging

# 需脱敏的字段名模式
SENSITIVE_PATTERNS = [
    re.compile(r"(password|passwd|pwd)", re.I),
    re.compile(r"(token|api_key|apikey|secret|credential)", re.I),
    re.compile(r"(authorization|cookie|session)", re.I),
]

# 需脱敏的值模式（正则匹配日志消息中的敏感值）
VALUE_PATTERNS = [
    (re.compile(r"(sk-[a-zA-Z0-9]{20,})"), _partial_mask),
    (re.compile(r"(Bearer\s+[a-zA-Z0-9\-._~+/]+=*)"), _partial_mask),
]

class LogSanitizationFilter(logging.Filter):
    """Filter that sanitizes sensitive information in log messages."""
    def filter(self, record: logging.LogRecord) -> bool:
        record.msg = self._sanitize(record.msg)
        return True
```

**注册位置**：在 `ext_logging.py:init_app` 中挂载到所有 handler。

**验收**：
- 安全扫描工具扫描 1 小时日志输出，零敏感信息。
- 人工抽查 200 条日志，零泄露。

---

### Phase 3：k8s 采集与传输链路建设（第 3-4 周）

#### Step 3.1 部署日志采集代理（DaemonSet）

**目标**：所有节点部署采集器，覆盖全量 Pod 日志。

**方案 A：Fluent Bit DaemonSet**

```yaml
# fluent-bit-daemonset.yaml（参考配置）
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fluent-bit
  namespace: logging
  labels:
    app.kubernetes.io/name: fluent-bit
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: fluent-bit
  template:
    metadata:
      labels:
        app.kubernetes.io/name: fluent-bit
    spec:
      serviceAccountName: fluent-bit
      tolerations:
        - operator: Exists          # 调度到所有节点
      containers:
        - name: fluent-bit
          image: fluent/fluent-bit:3.2
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          volumeMounts:
            - name: varlog
              mountPath: /var/log
              readOnly: true
            - name: containers
              mountPath: /var/lib/docker/containers
              readOnly: true
            - name: config
              mountPath: /fluent-bit/etc/
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
      volumes:
        - name: varlog
          hostPath:
            path: /var/log
        - name: containers
          hostPath:
            path: /var/lib/docker/containers
        - name: config
          configMap:
            name: fluent-bit-config
```

**方案 B：OTel Collector DaemonSet**

```yaml
# otel-collector-daemonset.yaml（参考配置）
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: otel-collector
  namespace: logging
spec:
  selector:
    matchLabels:
      app: otel-collector
  template:
    metadata:
      labels:
        app: otel-collector
    spec:
      serviceAccountName: otel-collector
      tolerations:
        - operator: Exists
      containers:
        - name: collector
          image: otel/opentelemetry-collector-contrib:0.100.0
          resources:
            requests:
              cpu: 200m
              memory: 256Mi
            limits:
              cpu: 1000m
              memory: 1Gi
          volumeMounts:
            - name: varlog
              mountPath: /var/log
              readOnly: true
            - name: config
              mountPath: /etc/otelcol-contrib/
          ports:
            - containerPort: 4317   # gRPC
            - containerPort: 4318   # HTTP
      volumes:
        - name: varlog
          hostPath:
            path: /var/log
        - name: config
          configMap:
            name: otel-collector-config
```

**RBAC 配置**（两种方案通用）：

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: fluent-bit  # 或 otel-collector
  namespace: logging
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: log-collector
rules:
  - apiGroups: [""]
    resources: ["namespaces", "pods", "pods/log"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: log-collector
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: log-collector
subjects:
  - kind: ServiceAccount
    name: fluent-bit  # 或 otel-collector
    namespace: logging
```

**验收**：
- 所有节点均有采集器 Pod 且处于 Running 状态。
- `kubectl logs -l app=dify-api` 的输出能在采集器的输入日志中看到。

#### Step 3.2 采集侧解析与 enrich

**目标**：解析 JSON 日志，追加 k8s 元数据。

**Fluent Bit 配置示例**：

```ini
# fluent-bit.conf
[SERVICE]
    Flush         5
    Log_Level     info
    Daemon        off
    Parsers_File  parsers.conf
    HTTP_Server   On
    HTTP_Listen   0.0.0.0
    HTTP_Port     2020
    storage.path  /var/log/flb-storage/
    storage.sync  normal
    storage.checksum off
    storage.max_chunks_up 128

[INPUT]
    Name              tail
    Tag               kube.*
    Path              /var/log/containers/dify-*.log
    Parser            cri
    DB                /var/log/flb_kube.db
    Mem_Buf_Limit     10MB
    Skip_Long_Lines   On
    Refresh_Interval  5
    storage.type      filesystem

[FILTER]
    Name              kubernetes
    Match             kube.*
    Kube_URL          https://kubernetes.default.svc:443
    Kube_CA_File      /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    Kube_Token_File   /var/run/secrets/kubernetes.io/serviceaccount/token
    Merge_Log         On
    Merge_Log_Key     log_parsed
    K8S-Logging.Parser On
    K8S-Logging.Exclude Off
    Labels            On
    Annotations       Off

[FILTER]
    Name              nest
    Match             kube.*
    Operation         lift
    Nested_under      kubernetes
    Add_prefix        k8s.

# 非 JSON 行标记
[FILTER]
    Name              modify
    Match             kube.*
    Condition         Key_Does_Not_Exist log_parsed
    Set               parse_error true

# 路由：应用日志
[OUTPUT]
    Name              opensearch
    Match             kube.*
    Host              opensearch.logging.svc
    Port              9200
    Index             dify-logs-%Y.%m.%d
    Type              _doc
    Suppress_Type_Name On
    HTTP_User         admin
    HTTP_Passwd       ${OPENSEARCH_PASSWORD}
    tls               On
    tls.verify        Off
    Retry_Limit       5
    storage.total_limit_size 5G
```

**OTel Collector 配置示例**：

```yaml
# otel-collector-config.yaml
receivers:
  filelog:
    include:
      - /var/log/containers/dify-*.log
    operators:
      - type: router
        routes:
          - output: parse_json
            expr: 'body matches "^\\{"'
          - output: parse_text
            expr: 'true'
      - id: parse_json
        type: json_parser
        parse_from: body
      - id: parse_text
        type: noop
    include_file_name: true
    include_file_path: true
    start_at: end

processors:
  k8sattributes:
    auth_type: "serviceAccount"
    extract:
      metadata:
        - k8s.namespace.name
        - k8s.pod.name
        - k8s.node.name
        - k8s.container.name
        - k8s.deployment.name
      labels:
        - key: app
          from: pod
  batch:
    timeout: 5s
    send_batch_size: 1024
  memory_limiter:
    check_interval: 5s
    limit_mib: 800
    spike_limit_mib: 200

exporters:
  otlphttp/loki:
    endpoint: "http://loki.logging.svc:3100/otlp"
  otlphttp/tempo:
    endpoint: "http://tempo.logging.svc:4318"

service:
  pipelines:
    logs:
      receivers: [filelog]
      processors: [k8sattributes, batch, memory_limiter]
      exporters: [otlphttp/loki]
```

**验收**：
- 平台查询可按 `k8s.pod`、`k8s.namespace`、`k8s.container` 精确过滤。
- 非 JSON 行标记 `parse_error=true` 并可单独检索。

#### Step 3.3 采集侧可靠性保障

**目标**：采集链路中断时不丢失日志。

**具体配置（Fluent Bit）**：

| 配置项 | 值 | 说明 |
|---|---|---|
| `storage.path` | `/var/log/flb-storage/` | 文件缓冲目录 |
| `storage.sync` | `normal` | 同步写缓冲 |
| `storage.max_chunks_up` | `128` | 内存中最大 chunk 数 |
| `storage.total_limit_size`（OUTPUT） | `5G` | 磁盘缓冲上限 |
| `Retry_Limit` | `5` | 最大重试次数 |
| `Mem_Buf_Limit`（INPUT） | `10MB` | 输入缓冲上限（背压） |

**具体配置（OTel Collector）**：

| 配置项 | 值 | 说明 |
|---|---|---|
| `memory_limiter.limit_mib` | `800` | 内存限制 |
| `memory_limiter.spike_limit_mib` | `200` | 突发限制 |
| `batch.timeout` | `5s` | 批量发送超时 |
| 持久化队列 | `sending_queue.storage` | 文件级持久化 |

**断链演练步骤**：
1. 人工关闭日志后端（OpenSearch/Loki）30 分钟。
2. 期间持续产生日志（模拟正常流量）。
3. 恢复后端。
4. 验证：恢复后 15 分钟内，断链期间的日志全部补写成功。

**验收**：断链 30 分钟恢复后日志可追补，丢失率 < 0.1%。

#### Step 3.4 多目标路由

**目标**：不同类型日志进入不同存储目标。

**路由规则**：

| 日志类型 | 识别条件 | 目标 | 留存 |
|---|---|---|---|
| 应用日志 | `severity != ""` AND 非审计 | 主索引 `dify-app-{env}-*` | 7+30+90 天 |
| 访问日志 | `http.path != ""` | 访问索引 `dify-access-{env}-*` | 7+30 天 |
| 安全审计 | `category == "security_audit"` 或特定 logger | 审计索引 `dify-audit-*` | 30+180+365 天 |
| 解析错误 | `parse_error == true` | 错误索引 `dify-parse-error-*` | 7 天 |

**Fluent Bit 路由示例**（使用 Rewrite Tag）：
```ini
[FILTER]
    Name          rewrite_tag
    Match         kube.*
    Rule          $category ^(security_audit)$ audit.$TAG false

[OUTPUT]
    Name          opensearch
    Match         audit.*
    Host          opensearch.logging.svc
    Index         dify-audit-%Y.%m
    # ... 高留存配置 ...
```

**验收**：不同日志类型进入对应索引/流。

---

### Phase 4：存储、索引与权限体系（第 4-5 周）

#### Step 4.1 索引与数据流设计

**目标**：优化查询性能，支持高效检索。

**索引策略**：

| 索引模式 | 滚动策略 | 分片数 | 副本数 |
|---|---|---|---|
| `dify-app-prod-YYYY.MM.DD` | 每天 | 3 | 1 |
| `dify-access-prod-YYYY.MM.DD` | 每天 | 2 | 1 |
| `dify-audit-YYYY.MM` | 每月 | 1 | 2 |
| `dify-parse-error-YYYY.MM.DD` | 每天 | 1 | 0 |

**索引映射关键字段**：

```json
{
  "mappings": {
    "properties": {
      "ts": { "type": "date", "format": "strict_date_optional_time" },
      "severity": { "type": "keyword" },
      "service": { "type": "keyword" },
      "env": { "type": "keyword" },
      "trace_id": { "type": "keyword" },
      "span_id": { "type": "keyword" },
      "request_id": { "type": "keyword" },
      "identity.tenant_id": { "type": "keyword" },
      "identity.user_id": { "type": "keyword" },
      "identity.user_type": { "type": "keyword" },
      "http.method": { "type": "keyword" },
      "http.path": { "type": "keyword" },
      "http.status_code": { "type": "integer" },
      "http.latency_ms": { "type": "float" },
      "celery.task_name": { "type": "keyword" },
      "celery.task_id": { "type": "keyword" },
      "celery.queue": { "type": "keyword" },
      "message": { "type": "text", "analyzer": "standard" },
      "stack_trace": { "type": "text", "index": false },
      "k8s.namespace": { "type": "keyword" },
      "k8s.pod": { "type": "keyword" },
      "k8s.node": { "type": "keyword" },
      "k8s.container": { "type": "keyword" }
    }
  }
}
```

**查询性能目标**：

| 查询场景 | P50 | P95 | P99 |
|---|---|---|---|
| 按 trace_id 精确查询 | < 100ms | < 500ms | < 1s |
| 按 tenant_id + 时间范围（1h） | < 500ms | < 2s | < 5s |
| 全文搜索 message | < 1s | < 5s | < 10s |

**验收**：关键查询 P95 响应时间达标。

#### Step 4.2 生命周期策略（ILM）

**目标**：自动管理索引生命周期，控制存储成本。

**OpenSearch/Elasticsearch ILM 策略**：

```json
{
  "policy": {
    "description": "Dify 应用日志生命周期策略",
    "default_state": "hot",
    "states": [
      {
        "name": "hot",
        "actions": [
          { "rollover": { "min_index_age": "1d", "min_size": "30gb" } }
        ],
        "transitions": [
          { "state_name": "warm", "conditions": { "min_index_age": "7d" } }
        ]
      },
      {
        "name": "warm",
        "actions": [
          { "replica_count": { "number_of_replicas": 0 } },
          { "force_merge": { "max_num_segments": 1 } }
        ],
        "transitions": [
          { "state_name": "cold", "conditions": { "min_index_age": "30d" } }
        ]
      },
      {
        "name": "cold",
        "actions": [
          { "read_only": {} }
        ],
        "transitions": [
          { "state_name": "delete", "conditions": { "min_index_age": "90d" } }
        ]
      },
      {
        "name": "delete",
        "actions": [
          { "delete": {} }
        ]
      }
    ]
  }
}
```

**Loki 留存策略**：

```yaml
# loki-config.yaml
limits_config:
  retention_period: 720h    # 30 天全局默认
  per_stream_rate_limit: 3MB
  per_stream_rate_limit_burst: 15MB

compactor:
  working_directory: /tmp/loki/compactor
  retention_enabled: true
  retention_delete_delay: 2h
  delete_request_store: filesystem

# 按标签的细粒度留存
overrides:
  "dify-audit":
    retention_period: 8760h  # 365 天
  "dify-app":
    retention_period: 2160h  # 90 天
```

**验收**：自动滚动与自动删除策略生效（在 staging 验证至少一个完整周期）。

#### Step 4.3 RBAC 与多租户访问控制

**目标**：不同角色只能看到授权范围内的日志。

**角色权限矩阵**：

| 角色 | 访问范围 | 操作权限 | 日志导出 |
|---|---|---|---|
| 平台管理员 | 所有日志 | 读取、检索、导出、配置 | 允许（需审批） |
| SRE 值班 | 所有应用日志 + 访问日志 | 读取、检索 | 允许（需审批） |
| 研发人员 | 本团队服务的应用日志 | 读取、检索 | 仅 dev/staging |
| 安全审计员 | 安全审计日志 + 访问日志 | 只读 | 允许 |
| 租户管理员 | 本租户日志 | 只读 | 不允许 |

**OpenSearch 实现方式**：
- 使用 OpenSearch Security Plugin 的 Document Level Security（DLS）。
- 按 `identity.tenant_id` 字段限制租户访问范围。

**Grafana 实现方式**：
- 使用 Grafana 组织/团队 + 数据源权限。
- Loki 标签级访问控制。

**验收**：
- 越权访问测试：研发人员查询其他团队日志返回空。
- 租户 A 无法查询租户 B 的日志。

#### Step 4.4 查询看板模板化

**目标**：预置常见排障看板，降低值班人员技能门槛。

**看板清单**：

| 看板名称 | 核心面板 | 数据源 |
|---|---|---|
| **API 概览** | 请求量趋势、5xx 趋势、P95 延迟、Top 10 慢接口 | 访问日志 |
| **错误分析** | 错误率趋势、Top 10 错误消息、按租户错误分布 | 应用日志 |
| **Celery 任务** | 任务成功/失败率、队列深度、Top 10 失败任务、平均执行时间 | Worker 日志 |
| **租户洞察** | 按租户请求量、错误率、延迟 | 访问日志 + 应用日志 |
| **日志健康** | 采集延迟、解析错误率、索引写入失败率、存储用量 | 采集器指标 |
| **安全审计** | 登录事件、API Key 操作、异常访问 | 审计日志 |

**Grafana Dashboard JSON 示例（API 5xx 趋势面板）**：

```json
{
  "title": "API 5xx Rate",
  "type": "timeseries",
  "targets": [
    {
      "expr": "sum(rate({service=\"dify-api\"} | json | http_status_code >= 500 [$__interval])) by (http_path)",
      "legendFormat": "{{http_path}}"
    }
  ],
  "fieldConfig": {
    "defaults": {
      "thresholds": {
        "steps": [
          { "value": 0, "color": "green" },
          { "value": 0.01, "color": "yellow" },
          { "value": 0.05, "color": "red" }
        ]
      }
    }
  }
}
```

**验收**：值班人员无需写 DSL/LogQL 即可完成常见排障。

---

### Phase 5：日志与 Trace/Metrics 联动（第 5-6 周）

#### Step 5.1 Trace-Log 互跳

**目标**：从日志直接跳转到对应链路追踪，反之亦然。

**前提条件**：
- Dify 已启用 OTEL（`ENABLE_OTEL=true`）。
- Trace 后端已部署（Tempo/Jaeger）。

**Dify OTEL 配置（k8s 环境变量）**：
```yaml
env:
  - name: ENABLE_OTEL
    value: "true"
  - name: OTEL_EXPORTER_TYPE
    value: "otlp"
  - name: OTEL_EXPORTER_OTLP_PROTOCOL
    value: "grpc"          # 或 "http"
  - name: OTLP_BASE_ENDPOINT
    value: "otel-collector.logging.svc:4317"
  - name: OTEL_SAMPLING_RATE
    value: "1.0"           # 生产建议 0.1-0.5
  - name: APPLICATION_NAME
    value: "dify-api"      # Worker 设为 "dify-worker"
```

**Grafana Trace-Log 联动配置**：
```yaml
# Loki 数据源配置
datasources:
  - name: Loki
    type: loki
    url: http://loki.logging.svc:3100
    jsonData:
      derivedFields:
        - datasourceUid: tempo
          matcherRegex: "\"trace_id\":\"([a-f0-9]+)\""
          name: TraceID
          url: "$${__value.raw}"
  - name: Tempo
    type: tempo
    url: http://tempo.logging.svc:3200
    jsonData:
      tracesToLogs:
        datasourceUid: loki
        filterByTraceID: true
        filterBySpanID: true
```

**验收**：
- 随机抽样 30 个 trace，均可从 Trace UI 跳转到日志。
- 随机抽样 30 条日志（含 trace_id），均可跳转到对应 Trace。

#### Step 5.2 SLI/SLO 与日志告警

**目标**：基于日志数据定义 SLI，配置告警。

**SLI 定义**：

| SLI 名称 | 计算方式 | SLO 目标 |
|---|---|---|
| 可用性 | 1 - (5xx 请求数 / 总请求数) | ≥ 99.9% |
| 延迟 | P95 延迟 | ≤ 2000ms |
| 错误率 | ERROR 日志数 / 总日志数 | ≤ 1% |
| 任务成功率 | 成功任务数 / 总任务数 | ≥ 99% |
| 采集完整性 | 实际采集量 / 预期采集量 | ≥ 99.9% |

**告警规则示例（Prometheus AlertManager）**：

```yaml
groups:
  - name: dify-logging-alerts
    rules:
      # API 5xx 突增
      - alert: DifyAPI5xxSpike
        expr: |
          sum(rate(http_server_response_count{service="dify-api", status_class="5xx"}[5m])) 
          / sum(rate(http_server_response_count{service="dify-api"}[5m])) > 0.05
        for: 2m
        labels:
          severity: critical
          team: backend
        annotations:
          summary: "Dify API 5xx 错误率超过 5%"
          description: "当前 5xx 率: {{ $value | humanizePercentage }}"
          runbook: "https://wiki.internal/runbooks/dify-5xx"
          dashboard: "https://grafana.internal/d/dify-api"

      # 高延迟
      - alert: DifyAPIHighLatency
        expr: |
          histogram_quantile(0.95,
            sum(rate(http_server_duration_milliseconds_bucket{service="dify-api"}[5m])) by (le)
          ) > 5000
        for: 5m
        labels:
          severity: warning
          team: backend
        annotations:
          summary: "Dify API P95 延迟超过 5 秒"
          runbook: "https://wiki.internal/runbooks/dify-latency"

      # Celery 任务堆积
      - alert: DifyCeleryQueueBacklog
        expr: celery_queue_length{queue=~"dataset|workflow|mail"} > 1000
        for: 10m
        labels:
          severity: warning
          team: sre
        annotations:
          summary: "Celery 队列 {{ $labels.queue }} 堆积超过 1000"

      # 日志采集延迟
      - alert: LogCollectionLag
        expr: |
          time() - max(timestamp(fluentbit_input_records_total)) > 120
        for: 5m
        labels:
          severity: warning
          team: sre
        annotations:
          summary: "日志采集延迟超过 2 分钟"

      # ERROR 日志突增
      - alert: DifyErrorLogSpike
        expr: |
          sum(rate({service=~"dify-.*"} | json | severity="ERROR" [5m])) > 10
        for: 3m
        labels:
          severity: warning
          team: backend
        annotations:
          summary: "Dify ERROR 日志频率超过 10/s"
```

**验收**：告警触发后 1 分钟内关联日志链接可用。

#### Step 5.3 值班 Runbook

**目标**：为每类告警提供标准化排障流程。

**Runbook 模板**：

```markdown
## 告警：DifyAPI5xxSpike

### 触发条件
API 5xx 错误率 > 5% 持续 2 分钟

### 影响评估
- 影响范围：所有 API 用户
- 严重程度：Critical

### 排障步骤
1. 打开 Grafana API 概览看板，确认 5xx 趋势。
2. 在日志平台搜索：`severity:ERROR AND service:dify-api AND ts:[now-10m TO now]`
3. 检查 Top 错误消息，定位根因。
4. 如果是数据库相关：
   a. 检查 PostgreSQL 连接数：`kubectl exec -it dify-api -- psql -c "SELECT count(*) FROM pg_stat_activity;"`
   b. 检查慢查询日志。
5. 如果是外部依赖：
   a. 检查模型服务健康状态。
   b. 检查 Redis 连接。
6. 如果需要重启：
   a. `kubectl rollout restart deployment/dify-api -n dify`
   b. 观察 5 分钟确认恢复。

### 升级路径
- 5 分钟未缓解 → 通知后端 Tech Lead
- 15 分钟未缓解 → 通知 CTO
- 30 分钟未恢复 → 启动故障回顾

### 恢复确认
- 5xx 率降至 < 0.1%
- 错误日志频率恢复正常
- 用户反馈渠道无新投诉
```

**需覆盖的告警 Runbook 列表**：
1. DifyAPI5xxSpike
2. DifyAPIHighLatency
3. DifyCeleryQueueBacklog
4. LogCollectionLag
5. DifyErrorLogSpike
6. DifyDatabaseConnectionExhausted
7. DifyRedisConnectionFailure
8. DifyWorkerOOM

**验收**：演练中值班人员可按 Runbook 独立完成排障闭环。

---

### Phase 6：安全合规与运营闭环（第 6-7 周）

#### Step 6.1 审计日志链路独立化

**目标**：安全审计日志物理隔离，满足合规要求。

**具体操作**：
1. 为审计日志创建独立的采集 pipeline。
2. 审计日志存储到独立索引（更高副本数、更长留存）。
3. 审计日志的写入/删除操作需要额外权限。

**审计事件清单**（需 Dify 应用侧产出）：

| 事件类型 | 触发时机 | 记录字段 |
|---|---|---|
| 用户登录 | 登录成功/失败 | user_id, client_ip, method, result |
| 用户登出 | 主动/过期 | user_id |
| API Key 创建 | 创建 Service API Key | key_id(脱敏), creator_id, app_id |
| API Key 删除 | 删除 API Key | key_id(脱敏), operator_id |
| 应用发布 | 发布应用版本 | app_id, version, operator_id |
| 数据集操作 | 创建/删除/更新数据集 | dataset_id, operation, operator_id |
| 成员管理 | 邀请/移除成员 | target_user, operation, operator_id |
| 配置变更 | 修改系统配置 | config_key, old_value(脱敏), new_value(脱敏) |
| 模型密钥管理 | 添加/删除模型提供商密钥 | provider, operation, operator_id |

**验收**：审计日志物理隔离，满足企业内控与审计取证要求。

#### Step 6.2 日志访问审计

**目标**：记录"谁在何时查询/导出了什么日志"。

**实现方式**：
- OpenSearch：启用审计日志功能（`audit.yml`）。
- Grafana：启用审计日志（Grafana Enterprise 功能）或通过 Nginx 代理日志。

**审计内容**：

| 字段 | 说明 |
|---|---|
| `who` | 操作者用户名/ID |
| `when` | 操作时间 |
| `what` | 查询 DSL/LogQL |
| `which_index` | 访问的索引/流 |
| `result_count` | 返回结果数 |
| `export` | 是否导出（是/否） |
| `source_ip` | 操作者 IP |

**验收**：可按用户追踪历史访问行为。

#### Step 6.3 周期性健康检查制度

**目标**：建立日志运营长效机制。

**每周检查项（自动化报表）**：

| 检查项 | 数据来源 | 阈值 |
|---|---|---|
| 字段完整率 | 采样日志分析 | ≥ 95% |
| 解析错误率 | `parse_error=true` 日志计数 | ≤ 1% |
| 采集延迟 P95 | 采集器指标 | ≤ 30s |
| 告警有效性 | 告警触发 vs 确认为真 | 误报率 ≤ 20% |
| 存储用量 | 索引大小趋势 | 不超过预算 |

**每月复盘项（人工会议）**：

| 复盘项 | 参与者 | 产出 |
|---|---|---|
| 成本复盘 | SRE + 运维 | 成本优化建议 |
| 留存策略调整 | SRE + 安全 | 策略更新记录 |
| 误报漏报分析 | 值班 + 研发 | 告警规则调整 |
| 新需求收集 | 全员 | 下季度 backlog |

**验收**：形成固定运营报表模板，首次报告产出。

---

## 6. 关键配置参考（可直接使用）

### 6.1 Dify k8s Deployment 环境变量完整配置

```yaml
# dify-api-deployment.yaml 环境变量片段
env:
  # ===== 日志配置 =====
  - name: LOG_OUTPUT_FORMAT
    value: "json"
  - name: LOG_FILE
    value: ""                      # 禁用文件日志
  - name: LOG_LEVEL
    value: "INFO"
  - name: LOG_TZ
    value: "UTC"
  - name: ENABLE_REQUEST_LOGGING
    value: "True"
  
  # ===== OTEL 配置 =====
  - name: ENABLE_OTEL
    value: "true"
  - name: OTEL_EXPORTER_TYPE
    value: "otlp"
  - name: OTEL_EXPORTER_OTLP_PROTOCOL
    value: "grpc"
  - name: OTLP_BASE_ENDPOINT
    value: "otel-collector.logging.svc:4317"
  - name: OTEL_SAMPLING_RATE
    value: "0.3"                   # 生产建议 0.1-0.5
  - name: OTEL_MAX_QUEUE_SIZE
    value: "4096"
  - name: OTEL_MAX_EXPORT_BATCH_SIZE
    value: "512"
  - name: OTEL_BATCH_EXPORT_SCHEDULE_DELAY
    value: "5000"
  - name: OTEL_BATCH_EXPORT_TIMEOUT
    value: "10000"
  
  # ===== 服务标识 =====
  - name: APPLICATION_NAME
    value: "dify-api"              # Worker 设为 "dify-worker"，Beat 设为 "dify-beat"
  - name: DEPLOY_ENV
    value: "PRODUCTION"
  - name: EDITION
    value: "SELF_HOSTED"
```

### 6.2 Nginx JSON 日志格式改造

**需修改文件**：`docker/nginx/nginx.conf.template`

**改造前（第 19-21 行）**：
```nginx
log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                  '$status $body_bytes_sent "$http_referer" '
                  '"$http_user_agent" "$http_x_forwarded_for"';
```

**改造后**：
```nginx
log_format json_combined escape=json
    '{'
      '"ts":"$time_iso8601",'
      '"severity":"INFO",'
      '"service":"nginx",'
      '"http":{'
        '"method":"$request_method",'
        '"path":"$uri",'
        '"query":"$args",'
        '"status_code":$status,'
        '"bytes_sent":$body_bytes_sent,'
        '"latency_ms":$request_time,'
        '"client_ip":"$remote_addr",'
        '"user_agent":"$http_user_agent",'
        '"referer":"$http_referer",'
        '"x_forwarded_for":"$http_x_forwarded_for",'
        '"upstream_addr":"$upstream_addr",'
        '"upstream_response_time":"$upstream_response_time",'
        '"request_length":$request_length'
      '}'
    '}';

access_log  /var/log/nginx/access.log  json_combined;
```

### 6.3 Ingress Controller JSON 日志（如使用 Ingress 替代 Nginx）

```yaml
# ingress-nginx-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ingress-nginx-controller
  namespace: ingress-nginx
data:
  log-format-upstream: >-
    {"ts":"$time_iso8601","severity":"INFO","service":"ingress-nginx",
     "http":{"method":"$request_method","path":"$uri","status_code":$status,
     "bytes_sent":$body_bytes_sent,"latency_ms":$request_time,
     "client_ip":"$remote_addr","user_agent":"$http_user_agent",
     "upstream_addr":"$upstream_addr","upstream_response_time":"$upstream_response_time"}}
```

---

## 7. 逐项交付件清单（必须落地）

| # | 交付件 | 负责角色 | 完成阶段 | 模板/示例 |
|---|---|---|---|---|
| 1 | 日志 schema v1 文档（含 3 类样例） | 架构师 | Phase 1 | 见 Step 1.1 |
| 2 | 日志分级与分类标准 | 架构师 + 研发 | Phase 1 | 见 Step 1.2 |
| 3 | 脱敏规则文档（黑白名单 + 示例） | 安全 | Phase 1 | 见 Step 1.3 |
| 4 | Dify 代码改造 PR（JSON stdout + 字段扩展 + 脱敏） | 研发 | Phase 2 | 见 Step 2.1-2.6 |
| 5 | k8s 采集器配置（DaemonSet + ConfigMap） | SRE | Phase 3 | 见 Step 3.1-3.2 |
| 6 | 存储索引模板与 ILM 策略文件 | SRE | Phase 4 | 见 Step 4.1-4.2 |
| 7 | RBAC 权限矩阵配置 | SRE + 安全 | Phase 4 | 见 Step 4.3 |
| 8 | Grafana 看板 JSON | SRE | Phase 4 | 见 Step 4.4 |
| 9 | OTEL 配置与 Trace-Log 联动 | SRE + 研发 | Phase 5 | 见 Step 5.1 |
| 10 | 告警规则（Prometheus/AlertManager） | SRE | Phase 5 | 见 Step 5.2 |
| 11 | 值班 Runbook（≥ 8 个场景） | SRE + 研发 | Phase 5 | 见 Step 5.3 |
| 12 | 审计事件清单与独立链路配置 | 安全 + 研发 | Phase 6 | 见 Step 6.1 |
| 13 | 运营报表模板（周报 + 月报） | SRE | Phase 6 | 见 Step 6.3 |
| 14 | 验收报告（全量指标） | PM | Phase 6 | 见第 11 节 |

---

## 8. 风险清单与应对

| # | 风险 | 影响 | 概率 | 对策 | 负责人 |
|---|---|---|---|---|---|
| R1 | 日志量暴涨导致成本失控 | 高 | 中 | 采样、降噪、冷热分层、日志级别治理、设置每日量告警 | SRE |
| R2 | 敏感信息泄露 | 高 | 中 | 默认不打 body、统一脱敏中间层、上线前 DLP 扫描、定期抽检 | 安全 |
| R3 | 采集链路中断丢日志 | 中 | 低 | 本地缓冲 + 重试 + 链路可用性告警 + 断链演练 | SRE |
| R4 | 多团队标准不一致 | 中 | 高 | schema 强约束 + CI 校验 + 发布门禁 + 定期完整率审计 | 架构师 |
| R5 | JSON 格式切换导致现有监控失效 | 中 | 中 | 先在 dev/staging 验证，保留旧监控并行运行 2 周 | SRE |
| R6 | 采集器 OOM 导致节点不稳定 | 高 | 低 | 设置资源 limits、背压处理、PodDisruptionBudget | SRE |
| R7 | 存储后端故障导致日志丢失 | 高 | 低 | 多副本存储、跨 AZ 部署、备份策略 | 运维 |
| R8 | OTEL 启用后性能下降 | 中 | 中 | 采样率控制、BatchSpanProcessor 参数调优、性能压测 | 研发 |

---

## 9. 上线切换步骤（生产）

### 9.1 上线前准备检查（T-1 天）

- [ ] staging 全量压测完成，无异常。
- [ ] 故障演练（断链、OOM、后端宕机）完成。
- [ ] 回滚脚本已测试通过。
- [ ] 值班 Runbook 已分发给值班人员。
- [ ] 告警规则已在 staging 验证。
- [ ] 变更通知已发送给全体相关人员。

### 9.2 灰度上线流程

| 步骤 | 操作 | 观察时间 | 检查项 | 回滚触发条件 |
|---|---|---|---|---|
| 1 | 部署日志采集器到生产集群 | 2h | 采集器 Pod 全部 Running | Pod CrashLoopBackOff |
| 2 | 灰度 10% Dify Pod 切换 JSON 日志 | 24h | 解析错误率、字段完整率 | 解析错误率 > 5% |
| 3 | 扩大至 50% | 12h | 同上 + 查询性能 | 查询 P95 > 10s |
| 4 | 全量 100% | 48h | 全量指标 | 任何 SLO 违规 |
| 5 | 关闭旧日志通道（如有） | 72h | 确认旧通道无数据 | - |

### 9.3 发布后值班增强

- 发布后 72 小时：on-call 每 4 小时巡检一次。
- 重点关注指标：
  - 日志解析错误率（应 < 1%）
  - 采集延迟（应 < 30s）
  - 索引写入失败率（应 = 0）
  - 告警误报率
  - 应用服务 SLI（不应因日志改造而下降）

---

## 10. 回滚方案

### 10.1 应用侧回滚（代码/配置变更）

| 场景 | 回滚操作 | 预计耗时 |
|---|---|---|
| JSON 格式导致解析问题 | 将 `LOG_OUTPUT_FORMAT` 改回 `text` | < 5 分钟 |
| 请求日志改造有 bug | 将 `ENABLE_REQUEST_LOGGING` 设为 `False` | < 5 分钟 |
| OTEL 导致性能问题 | 将 `ENABLE_OTEL` 设为 `false` | < 5 分钟 |
| 代码改动引入异常 | `kubectl rollout undo deployment/dify-api` | < 2 分钟 |

### 10.2 采集侧回滚

| 场景 | 回滚操作 | 预计耗时 |
|---|---|---|
| 采集器 OOM/CrashLoop | `kubectl rollout undo daemonset/fluent-bit -n logging` | < 2 分钟 |
| 采集器配置错误 | `kubectl rollout undo configmap/fluent-bit-config -n logging && kubectl rollout restart daemonset/fluent-bit -n logging` | < 5 分钟 |
| 采集器影响节点稳定性 | `kubectl delete daemonset/fluent-bit -n logging`（紧急摘除） | < 1 分钟 |

### 10.3 存储侧回滚

| 场景 | 回滚操作 | 预计耗时 |
|---|---|---|
| ILM 策略误删数据 | 从快照恢复索引 | 取决于数据量 |
| 索引映射错误 | 重建索引模板 + reindex | 1-4 小时 |

---

## 11. 最终验收检查单（可直接打勾）

### MVP 验收（必须全部通过才可上线）

- [ ] API Pod 日志为 JSON 格式，解析错误率 = 0
- [ ] Worker Pod 日志为 JSON 格式，包含 `celery.task_id`
- [ ] Beat Pod 日志为 JSON 格式
- [ ] Nginx/Ingress 日志为 JSON 格式
- [ ] 统一 schema 字段完整率 ≥ 95%（抽样 1000 条）
- [ ] 敏感字段脱敏覆盖率 = 100%（DLP 扫描通过）
- [ ] trace_id 全链路可检索（随机 30 个请求验证）
- [ ] 日志平台支持按 `tenant_id/service/trace_id/status_code/task_id` 检索
- [ ] 采集延迟 P95 ≤ 30 秒
- [ ] 所有 k8s 节点采集器 Pod 运行正常

### GA 验收（企业级目标）

- [ ] ILM 生命周期策略生效（热→温→冷→删除完整验证）
- [ ] RBAC 多租户权限验证通过（越权访问全部失败）
- [ ] 审计日志独立链路验证通过
- [ ] Trace-Log 互跳验证通过（双向各 30 次）
- [ ] 告警规则已上线并验证（至少模拟触发一次）
- [ ] 值班 Runbook 演练通过（至少 3 个场景）
- [ ] 断链演练通过（30 分钟断链恢复后日志可追补）
- [ ] 日志访问审计功能验证
- [ ] 生产灰度全量上线完成
- [ ] 72 小时值班增强观察期结束，无异常
- [ ] 首次周报/月报产出

---

## 附录A：与 Dify 当前代码位置的对应关系（实施定位）

| 功能模块 | 文件路径 | 关键行/函数 |
|---|---|---|
| 日志初始化 | `api/extensions/ext_logging.py` | `init_app()` :12 |
| JSON Formatter | `api/core/logging/structured_formatter.py` | `StructuredJSONFormatter._build_log_dict()` :52 |
| Trace 上下文 Filter | `api/core/logging/filters.py` | `TraceContextFilter.filter()` :17 |
| 身份上下文 Filter | `api/core/logging/filters.py` | `IdentityContextFilter.filter()` :56 |
| 请求上下文 | `api/core/logging/context.py` | `init_request_context()` :24 |
| 请求日志 | `api/extensions/ext_request_logging.py` | `_log_request_finished()` :49 |
| OTEL 初始化 | `api/extensions/ext_otel.py` | `init_app()` :14 |
| OTEL Instrumentor | `api/extensions/otel/instrumentation.py` | `init_instruments()` :120 |
| OTEL Runtime（Celery） | `api/extensions/otel/runtime.py` | `init_celery_worker()` :83 |
| 日志配置项 | `api/configs/feature/__init__.py` | `LoggingConfig` :607 |
| 部署配置项 | `api/configs/deploy/__init__.py` | `DeploymentConfig` :5 |
| OTEL 配置项 | `api/configs/observability/otel/otel_config.py` | `OTelConfig` :5 |
| Nginx 日志格式 | `docker/nginx/nginx.conf.template` | `log_format main` :19 |
| Docker 环境变量 | `docker/.env.example` | `LOG_*` :74, `ENABLE_OTEL` :1474 |
| Docker Compose | `docker/docker-compose.yaml` | `shared-api-worker-env` :7, `worker` :772, `worker_beat` :811 |
| Token 脱敏函数 | `api/core/helper/encrypter.py` | `obfuscated_token()` :6 |

---

## 附录B：术语表

| 术语 | 说明 |
|---|---|
| ADR | Architecture Decision Record，架构决策记录 |
| DaemonSet | k8s 控制器，确保每个节点运行一个 Pod |
| DLP | Data Loss Prevention，数据防泄漏 |
| ILM | Index Lifecycle Management，索引生命周期管理 |
| LogQL | Grafana Loki 的查询语言 |
| OTEL | OpenTelemetry，可观测性标准 |
| RACI | Responsible-Accountable-Consulted-Informed，职责分配矩阵 |
| RBAC | Role-Based Access Control，基于角色的访问控制 |
| SLI | Service Level Indicator，服务等级指标 |
| SLO | Service Level Objective，服务等级目标 |
| Runbook | 值班手册，标准化排障流程 |
| Trace | 分布式链路追踪 |
| Span | 链路追踪中的最小单元 |
