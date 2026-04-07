# 企业级 Dify × Gin-Vue-Admin 集成技术方案 v3.0

> **版本**: 3.0  
> **日期**: 2026-04-07  
> **状态**: 技术设计稿  

---

## 版本演进说明

| 版本 | 变更摘要 |
|------|---------|
| v1.0 | 初始方案：SSO 中心（模块A）、权限体系（模块B）、组织架构（模块C）三模块独立设计 |
| v2.0 | 模块合并优化：SSO 合并到应用管理；权限体系合并到组织架构；补充具体实现清单 |
| **v3.0** | **①** 调用监控与统计合并到应用管理模块（统计本身是应用维度的能力）；**②** 参考业界优秀企业级平台实践（如 Auth0/Keycloak、DataDog/Grafana、Kubernetes RBAC、Stripe Billing），新增审计日志、模型资源管理、通知中心、多租户隔离、灾备与高可用等企业级模块；**③** 全部模块细化到文件/函数/表结构级别的实现清单 |

---

## 目录

- [一、架构总览](#一架构总览)
- [二、模块 A：组织架构与权限管理](#二模块-a组织架构与权限管理)
- [三、模块 B：Dify 应用全生命周期管理](#三模块-bdify-应用全生命周期管理)
- [四、模块 C：审计日志与合规中心](#四模块-c审计日志与合规中心)
- [五、模块 D：模型资源管理与成本控制](#五模块-d模型资源管理与成本控制)
- [六、模块 E：通知中心与消息总线](#六模块-e通知中心与消息总线)
- [七、模块 F：多租户管理与隔离](#七模块-f多租户管理与隔离)
- [八、模块 G：灾备与高可用](#八模块-g灾备与高可用)
- [九、全局技术设计](#九全局技术设计)
- [十、实施路线图](#十实施路线图)
- [十一、新增文件总览](#十一新增文件总览)

---

## 一、架构总览

### 1.1 模块划分（v3.0）

| 模块 | 名称 | 职责 | 业界参考 |
|------|------|------|---------|
| **A** | 组织架构与权限管理 | 组织节点树、成员管理、多层级权限引擎、角色体系、登录上下文 | Keycloak Realm/Group、K8s RBAC、飞书组织架构 |
| **B** | Dify 应用全生命周期管理 | 应用配置、API Key、远端同步、SSO/访问模式、调用测试、调用网关、**调用监控与统计**、**应用市场** | Vercel Dashboard、Postman Workspace、Stripe API Dashboard |
| **C** | 审计日志与合规中心 | 操作审计、数据访问审计、合规报告导出、敏感操作二次确认 | DataDog Audit Trail、AWS CloudTrail、阿里云操作审计 |
| **D** | 模型资源管理与成本控制 | 模型供应商配置、Token 配额管理、成本核算与分摊、预算告警 | Azure OpenAI Service、AWS Bedrock、LangSmith |
| **E** | 通知中心与消息总线 | 站内通知、邮件/钉钉/飞书/企微推送、事件订阅、Webhook 出站 | Slack Workflow、PagerDuty、钉钉/飞书开放平台 |
| **F** | 多租户管理与隔离 | 租户生命周期、资源隔离、数据隔离、租户级功能开关 | SaaS Factory（AWS）、Azure Multi-tenant、Kubernetes Namespace |
| **G** | 灾备与高可用 | 数据备份、故障转移、健康检查、平滑升级 | Kubernetes Operator、PgBackRest、Redis Sentinel |

### 1.2 系统拓扑

```
┌───────────────────────────────────────────────────────────────────────┐
│                           Nginx / Traefik                             │
│  /admin/*   → GVA Vue3 (:8080)                                       │
│  /console/* → Dify Web (:3000)                                        │
│  /api/*     → Dify API (:5001)                                        │
│  /gva-api/* → GVA Gin Server (:8888)                                 │
│  /ws/*      → WebSocket Gateway (:8889)                              │
└─────────┬────────────────────────────┬────────────────────────────────┘
          │                            │
┌─────────▼─────────┐  ┌──────────────▼──────────────────────────────┐
│  Dify Backend      │  │  GVA Backend (Gin/Go)                       │
│  (Flask/Python)    │  │                                             │
│                    │  │  模块A: 组织架构与权限管理                    │
│ • AI 应用运行时     │◄─►│  模块B: 应用全生命周期管理                    │
│ • Workflow Engine  │  │  模块C: 审计日志与合规中心                    │
│ • RAG Pipeline     │  │  模块D: 模型资源管理与成本控制                │
│ • API Token 服务   │  │  模块E: 通知中心与消息总线                    │
│ • Model Runtime    │  │  模块F: 多租户管理与隔离                     │
│                    │  │  模块G: 灾备与高可用                         │
└────────┬──────────┘  └──────────────┬──────────────────────────────┘
         │                             │
┌────────▼─────────────────────────────▼─────────────────────────────┐
│  PostgreSQL (schema 隔离: public / gva_enterprise)                  │
│  Redis Cluster (Session / Cache / Pub-Sub / Casbin / Stream)       │
│  ClickHouse / TimescaleDB (可选：海量统计数据)                       │
│  MinIO / S3 (对象存储：导出文件、备份)                               │
└────────────────────────────────────────────────────────────────────┘
```

### 1.3 Dify 现有对接点分析

通过对 Dify 源码深度分析，以下是关键对接点：

| Dify 现有机制 | 源码位置 | GVA 集成方式 |
|-------------|----------|-------------|
| WebApp 四种访问模式：`public`/`private`/`private_all`/`sso_verified` | `web/models/access-control.ts` AccessMode 枚举 | GVA 作为 SSO Provider 实现 `sso_verified` 模式 |
| WebApp 认证类型：`PUBLIC`/`INTERNAL`/`EXTERNAL` | `api/services/webapp_auth_service.py` WebAppAuthType | `sso_verified` 映射到 `EXTERNAL` 类型 |
| EnterpriseService 远程调用接口 | `api/services/enterprise/enterprise_service.py` | GVA 实现 Enterprise API 端点 |
| 应用统计 8 个维度 | `api/controllers/console/app/statistic.py` | GVA 聚合增强，增加跨应用/组织维度 |
| 工作流统计 4 个维度 | `api/controllers/console/app/workflow_statistic.py` | GVA 纳入工作流监控仪表盘 |
| 操作日志模型 OperationLog | `api/models/model.py` OperationLog | GVA 同步并扩展审计维度 |
| 配额管理 QuotaType | `api/enums/quota_type.py` | GVA 实现组织级配额分摊 |
| API Token 缓存 + Single-flight | `api/services/api_token_service.py` | 复用，GVA 管理端调用 |
| 角色体系：OWNER/ADMIN/EDITOR/NORMAL/DATASET_OPERATOR | `api/models/account.py` TenantAccountRole | GVA 组织角色映射 |
| 计费服务 BillingService | `api/services/billing_service.py` | GVA 扩展组织级计费 |
| Webhook 触发器 | `api/services/trigger/webhook_service.py` | GVA 出站 Webhook 复用 |
| 模型供应商管理 | `api/services/model_provider_service.py` | GVA 实现组织级模型配置 |
| 功能特性管理 FeatureService | `api/services/feature_service.py` | GVA 扩展租户级功能开关 |

---

## 二、模块 A：组织架构与权限管理

> 合并原权限体系 + 组织架构，权限等级依附于组织节点统一管理。  
> **业界参考**：Keycloak（Realm → Group → User → Role）、Kubernetes RBAC（Role → ClusterRole → RoleBinding）、飞书开放平台组织架构 API

### A.1 数据模型

#### A.1.1 数据库表

**表 1：`org_nodes` — 组织节点表**

```sql
CREATE TABLE gva_enterprise.org_nodes (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    parent_id   UUID REFERENCES gva_enterprise.org_nodes(id) ON DELETE RESTRICT,
    node_type   VARCHAR(20) NOT NULL CHECK (node_type IN ('COMPANY','DEPARTMENT','TEAM','GROUP')),
    name        VARCHAR(255) NOT NULL,
    code        VARCHAR(100) UNIQUE,
    path        LTREE NOT NULL,               -- PostgreSQL ltree 物化路径
    depth       INT NOT NULL DEFAULT 0,
    sort_order  INT DEFAULT 0,
    status      VARCHAR(20) DEFAULT 'ACTIVE',
    metadata    JSONB DEFAULT '{}',           -- 扩展字段（如：地域、成本中心编码）
    created_by  UUID,
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    updated_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_org_nodes_parent ON gva_enterprise.org_nodes(parent_id);
CREATE INDEX idx_org_nodes_path_gist ON gva_enterprise.org_nodes USING GIST(path);
CREATE INDEX idx_org_nodes_path_btree ON gva_enterprise.org_nodes USING BTREE(path);
```

**表 2：`org_node_members` — 成员表**

```sql
CREATE TABLE gva_enterprise.org_node_members (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    node_id     UUID NOT NULL REFERENCES gva_enterprise.org_nodes(id),
    user_id     UUID NOT NULL,
    role_id     UUID NOT NULL,
    perm_level  SMALLINT NOT NULL DEFAULT 6,
    is_admin    BOOLEAN DEFAULT FALSE,
    dify_role   VARCHAR(30) DEFAULT 'normal',  -- 映射 TenantAccountRole
    joined_at   TIMESTAMPTZ DEFAULT NOW(),
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    updated_at  TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(node_id, user_id)
);

CREATE INDEX idx_onm_node ON gva_enterprise.org_node_members(node_id);
CREATE INDEX idx_onm_user ON gva_enterprise.org_node_members(user_id);
CREATE INDEX idx_onm_level ON gva_enterprise.org_node_members(perm_level);
```

**表 3：`perm_level_config` — 权限等级定义表**

```sql
CREATE TABLE gva_enterprise.perm_level_config (
    level       SMALLINT PRIMARY KEY,
    name        VARCHAR(50) NOT NULL,
    code        VARCHAR(30) NOT NULL UNIQUE,
    description TEXT,
    scope_rule  VARCHAR(50) NOT NULL
);

INSERT INTO gva_enterprise.perm_level_config VALUES
(0, '无权限',         'NONE',            '无任何访问权限',          'DENY_ALL'),
(1, '全局权限',       'ALL',             '可管理所有组织及成员',     'ALLOW_ALL'),
(2, '本公司及子公司', 'COMPANY',          '含子公司',               'COMPANY_WITH_CHILDREN'),
(3, '仅限本公司',     'COMPANY_ONLY',     '不含子公司',             'COMPANY_NO_CHILDREN'),
(4, '本部门及子部门', 'DEPARTMENT',       '含子部门',               'DEPT_WITH_CHILDREN'),
(5, '仅限本部门',     'DEPARTMENT_ONLY',  '不含子部门',             'DEPT_NO_CHILDREN'),
(6, '仅限本人',       'SELF',             '仅能管理自己的数据',      'SELF_ONLY');
```

**表 4：`role_templates` — 角色模板表（新增，参考 K8s ClusterRole）**

```sql
CREATE TABLE gva_enterprise.role_templates (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name        VARCHAR(100) NOT NULL,
    code        VARCHAR(50) NOT NULL UNIQUE,
    description TEXT,
    permissions JSONB NOT NULL DEFAULT '[]',  -- [{resource, actions[]}]
    is_system   BOOLEAN DEFAULT FALSE,        -- 系统内置不可删
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    updated_at  TIMESTAMPTZ DEFAULT NOW()
);

-- 预置角色模板
INSERT INTO gva_enterprise.role_templates (name, code, permissions, is_system) VALUES
('超级管理员', 'super_admin', '[{"resource":"*","actions":["*"]}]', true),
('应用管理员', 'app_admin', '[{"resource":"app","actions":["create","read","update","delete","publish"]},{"resource":"api_key","actions":["*"]}]', true),
('应用使用者', 'app_user', '[{"resource":"app","actions":["read","invoke"]},{"resource":"conversation","actions":["create","read"]}]', true),
('知识库管理员', 'knowledge_admin', '[{"resource":"dataset","actions":["*"]},{"resource":"document","actions":["*"]}]', true),
('审计员', 'auditor', '[{"resource":"audit_log","actions":["read","export"]},{"resource":"statistics","actions":["read"]}]', true),
('只读观察者', 'viewer', '[{"resource":"*","actions":["read"]}]', true);
```

### A.2 核心服务层

#### A.2.1 组织架构树服务

**文件**：`server/service/enterprise/org_tree_service.go`

| 函数签名 | 说明 | 实现要点 |
|----------|------|---------|
| `BuildTreeMap(rootID uuid.UUID) map[uuid.UUID][]OrgNode` | 构建树 Map | 全量加载 + 进程内缓存 |
| `GetTree(rootID uuid.UUID, depth int) *OrgTreeResp` | 获取树 | 从缓存读取，`depth` 控制层级深度 |
| `GetFlatNodeIDs(nodeID uuid.UUID, withChildren bool) []uuid.UUID` | 展平 ID | `ltree` 路径查询 `path <@ ?` |
| `CreateNode(req CreateNodeReq) (*OrgNode, error)` | 创建节点 | 校验 parent + 计算 path/depth |
| `UpdateNode(id uuid.UUID, req UpdateNodeReq) error` | 编辑节点 | 名称/编码/排序/metadata |
| `MoveNode(id uuid.UUID, req MoveNodeReq) error` | 移动节点 | 事务更新 parent_id + 所有子节点 path |
| `DeleteNode(id uuid.UUID) error` | 删除节点 | 级联保护：检查成员和子节点 |
| `InvalidateTreeCache()` | 缓存失效 | 进程内 + Redis Pub/Sub 通知集群 |

#### A.2.2 成员管理服务

**文件**：`server/service/enterprise/member_service.go`

| 函数签名 | 说明 |
|----------|------|
| `ListNodeMembers(nodeID, page, pageSize) (*PageResult, error)` | 分页查询 |
| `BatchAddMembers(nodeID, req) (int, error)` | 批量添加（DiffSets 去重） |
| `BatchRemoveMembers(nodeID, userIDs) (int, error)` | 批量移除 |
| `SetMemberRole(nodeID, userID, roleID, permLevel) error` | 设置角色 |
| `SetNodeAdmin(nodeID, userID, isAdmin) error` | 设置管理员 |
| `TransferMember(userID, fromNodeID, toNodeID) error` | 跨节点调动 |
| `SyncMemberToDify(userID, difyRole) error` | 同步到 Dify |
| `ImportMembersFromCSV(nodeID, file) (*ImportResult, error)` | CSV 批量导入 |

#### A.2.3 权限引擎服务

**文件**：`server/service/enterprise/permission_engine.go`

| 函数签名 | 说明 |
|----------|------|
| `CheckPermission(req CheckPermReq) (*CheckPermResp, error)` | 统一权限校验 |
| `BatchCheckPermission(req BatchCheckPermReq) (*BatchCheckPermResp, error)` | 批量判断 |
| `GetUserPermScope(userID) (*PermScope, error)` | 用户权限范围 |
| `EvaluateRoleTemplate(userID, resource, action) (bool, error)` | 角色模板权限评估 |
| `GetEffectivePermissions(userID) ([]Permission, error)` | 合并有效权限集 |

**CheckPermission 流程**：

```
输入: { user_id, target_node_id?, target_user_id?, resource, action }

1. 查缓存 Redis `perm:{user_id}:{resource}:{resource_id}`
   → 命中: 直接返回
2. 获取用户 (node_id, perm_level, role_template)
3. 角色模板权限评估: resource + action 匹配
4. perm_level 范围计算:
   - NONE(0)    → denied
   - ALL(1)     → allowed
   - COMPANY(2) → path <@ 用户 COMPANY 节点
   - COMPANY_ONLY(3) → 仅本 COMPANY 节点
   - DEPT(4)    → path <@ 用户 DEPT 节点
   - DEPT_ONLY(5) → 仅本 DEPT 节点
   - SELF(6)    → user_id 匹配
5. 角色权限 ∩ 数据范围 = 最终结果
6. 写缓存 (TTL 5min) → 返回
```

#### A.2.4 登录上下文服务

**文件**：`server/service/enterprise/login_context_service.go`

| 函数签名 | 说明 |
|----------|------|
| `UserLoginList(userID) ([]LoginOrgItem, error)` | 可登录组织列表 |
| `ChangeLoginOrg(userID, nodeID) error` | 切换组织 |
| `GetCurrentLoginContext(userID) (*LoginContext, error)` | 当前上下文 |

### A.3 API 接口

```
// 组织架构
GET    /gva-api/v1/org/tree                       → GetTree
POST   /gva-api/v1/org/node                       → CreateNode
PUT    /gva-api/v1/org/node/:id                   → UpdateNode
DELETE /gva-api/v1/org/node/:id                   → DeleteNode
PUT    /gva-api/v1/org/node/:id/move              → MoveNode

// 成员管理
GET    /gva-api/v1/org/node/:id/members           → ListMembers
POST   /gva-api/v1/org/node/:id/members/batch     → BatchAdd
DELETE /gva-api/v1/org/node/:id/members/batch     → BatchRemove
PUT    /gva-api/v1/org/node/:id/member/:uid/role  → SetRole
POST   /gva-api/v1/org/node/:id/members/import    → ImportCSV
PUT    /gva-api/v1/org/member/:uid/transfer       → TransferMember

// 角色模板
GET    /gva-api/v1/roles                           → ListRoles
POST   /gva-api/v1/roles                           → CreateRole
PUT    /gva-api/v1/roles/:id                       → UpdateRole
DELETE /gva-api/v1/roles/:id                       → DeleteRole

// 权限校验（Dify 回调）
POST   /gva-api/v1/permission/check               → Check
POST   /gva-api/v1/permission/batch-check         → BatchCheck

// 登录上下文
GET    /gva-api/v1/user/login-org-list            → List
POST   /gva-api/v1/user/change-login-org          → Change
```

### A.4 前端页面

| 页面路径 | 功能 |
|----------|------|
| `web/src/views/enterprise/orgTree/index.vue` | 组织架构树（El-Tree 拖拽 + 右键菜单） |
| `web/src/views/enterprise/orgTree/components/NodeForm.vue` | 节点表单弹窗 |
| `web/src/views/enterprise/orgTree/components/MemberPanel.vue` | 成员管理面板 |
| `web/src/views/enterprise/orgTree/components/MemberSelector.vue` | 成员选择器 |
| `web/src/views/enterprise/orgTree/components/MemberImport.vue` | CSV 导入弹窗 |
| `web/src/views/enterprise/roleConfig/index.vue` | 角色模板管理 |
| `web/src/views/enterprise/roleConfig/components/PermissionMatrix.vue` | 权限矩阵编辑器 |
| `web/src/views/enterprise/loginOrg/index.vue` | 切换登录组织 |

### A.5 实现任务清单

| 序号 | 任务 | 文件 | 工时 |
|------|------|------|------|
| A-01 | PostgreSQL ltree 扩展 + schema | `enterprise_init.sql` | 0.5d |
| A-02 | org_nodes / org_node_members / perm_level_config / role_templates 表 | 同上 | 1d |
| A-03 | GORM 模型 | `server/model/enterprise/*.go` (4 文件) | 1d |
| A-04 | 请求/响应 DTO | `server/model/enterprise/request/` + `response/` | 0.5d |
| A-05 | OrgTreeService | `org_tree_service.go` | 3d |
| A-06 | MemberService（含 DiffSets + CSV 导入） | `member_service.go` + `utils/sets/diff.go` | 2.5d |
| A-07 | PermissionEngine（含角色模板评估） | `permission_engine.go` | 3d |
| A-08 | LoginContextService | `login_context_service.go` | 1d |
| A-09 | 缓存层（进程内 + Redis） | `global/cache/org_cache.go` + `perm_cache.go` | 2d |
| A-10 | API Handler (6 个) | `server/api/v1/enterprise/*.go` | 2d |
| A-11 | 路由注册 + Casbin Policy | `router/enterprise/org_router.go` | 0.5d |
| A-12 | Dify 成员同步适配 | `dify_sync_service.go` | 1d |
| A-13 | Vue3 组织架构树页面 | 5 组件 | 3d |
| A-14 | Vue3 角色模板管理（含权限矩阵） | 2 组件 | 2d |
| A-15 | Vue3 切换登录组织 | 1 组件 | 0.5d |
| A-16 | Dify 侧 `@enterprise_permission_required` 装饰器 | `api/controllers/console/wraps.py` 新增 | 1d |
| A-17 | 单元测试 + 集成测试 | `*_test.go` (5 文件) | 2.5d |

**模块 A 小计：27 天**

---

## 三、模块 B：Dify 应用全生命周期管理

> **v3.0 变更**：将调用监控与统计合并到此模块，因为 Dify 的统计接口本身就是按 app_id 维度组织的（`/apps/<app_id>/statistics/*`）。同时新增应用市场（内部共享）功能。  
> **业界参考**：Vercel Dashboard（应用+部署+监控一体）、Postman API Workspace、Stripe Developer Dashboard

### B.1 SSO 访问模式集成

#### B.1.1 GVA 需实现的 Dify Enterprise API 端点

| Dify 调用方 | GVA 端点 | 说明 |
|------------|---------|------|
| `WebAppAuth.get_app_access_mode_by_id(app_id)` | `GET /webapp/access-mode/id` | 返回访问模式 |
| `WebAppAuth.batch_get_app_access_mode_by_id(app_ids)` | `POST /webapp/access-mode/batch/id` | 批量获取 |
| `WebAppAuth.update_app_access_mode(app_id, mode)` | `POST /webapp/access-mode` | 更新模式 |
| `WebAppAuth.is_user_allowed_to_access_webapp(user_id, app_id)` | `GET /webapp/permission` | 校验访问权 |
| `WebAppAuth.batch_is_user_allowed_to_access_webapps(user_id, app_ids)` | `POST /webapp/permission/batch` | 批量校验 |
| `get_app_sso_settings_last_update_time()` | `GET /sso/app/last-update-time` | SSO 更新时间 |
| `get_workspace_sso_settings_last_update_time()` | `GET /sso/workspace/last-update-time` | 工作区 SSO 更新时间 |
| `WebAppAuth.cleanup_webapp(app_id)` | `DELETE /webapp/clean` | 清理权限数据 |

#### B.1.2 SSO Provider 数据表

```sql
CREATE TABLE gva_enterprise.sso_provider_config (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    provider_type   VARCHAR(20) NOT NULL,         -- OAUTH2 / SAML / OIDC
    client_id       VARCHAR(255) NOT NULL,
    client_secret   VARCHAR(512) NOT NULL,        -- AES-256 加密
    redirect_uris   TEXT[],
    token_expiry    INT DEFAULT 43200,
    refresh_expiry  INT DEFAULT 2592000,
    enabled         BOOLEAN DEFAULT TRUE,
    config_version  BIGINT DEFAULT 1,
    updated_at      TIMESTAMPTZ DEFAULT NOW(),
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE gva_enterprise.app_sso_config (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    app_id          UUID NOT NULL UNIQUE,
    sso_enabled     BOOLEAN DEFAULT FALSE,
    provider_id     UUID REFERENCES gva_enterprise.sso_provider_config(id),
    config_version  BIGINT DEFAULT 1,
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);
```

### B.2 应用配置管理

#### B.2.1 数据表

```sql
CREATE TABLE gva_enterprise.dify_app_config (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    dify_app_id     UUID NOT NULL UNIQUE,
    dify_base_url   VARCHAR(500) NOT NULL,
    app_name        VARCHAR(255),
    app_description TEXT,
    app_mode        VARCHAR(50),              -- chat/completion/workflow/advanced-chat/agent-chat
    app_icon        VARCHAR(500),
    url_slug        VARCHAR(100) UNIQUE,
    access_mode     VARCHAR(20) DEFAULT 'public',
    tags            TEXT[] DEFAULT '{}',       -- 应用标签
    category        VARCHAR(50),              -- 应用分类
    is_published    BOOLEAN DEFAULT FALSE,    -- 是否发布到应用市场
    sync_enabled    BOOLEAN DEFAULT TRUE,
    last_synced_at  TIMESTAMPTZ,
    status          VARCHAR(20) DEFAULT 'ACTIVE',
    created_by      UUID,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE gva_enterprise.dify_api_keys (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    app_config_id   UUID NOT NULL REFERENCES gva_enterprise.dify_app_config(id),
    key_name        VARCHAR(100),
    api_key         VARCHAR(512) NOT NULL,    -- AES-256 加密
    is_active       BOOLEAN DEFAULT TRUE,
    last_used_at    TIMESTAMPTZ,
    expires_at      TIMESTAMPTZ,              -- 过期时间（新增）
    created_by      UUID,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE gva_enterprise.app_access_rules (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    app_id          UUID NOT NULL,
    subject_type    VARCHAR(20) NOT NULL,      -- USER / ROLE / NODE / ALL
    subject_id      UUID,
    access_mode     VARCHAR(20) DEFAULT 'ALLOW',
    perm_level      SMALLINT DEFAULT 6,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(app_id, subject_type, subject_id)
);
```

### B.3 调用监控与统计（从原模块 C 合并）

> **合并理由**：Dify 的统计接口按 `app_id` 维度组织（`/apps/<app_id>/statistics/daily-messages` 等 8 个端点 + `/apps/<app_id>/workflow/statistics/*` 4 个端点），统计数据是应用的内在属性。

#### B.3.1 数据表

```sql
CREATE TABLE gva_enterprise.dify_call_logs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    app_id          UUID NOT NULL,
    user_id         UUID NOT NULL,
    org_node_id     UUID,                     -- 关联组织节点（新增：支持组织维度统计）
    call_type       VARCHAR(20) NOT NULL,      -- chat / completion / workflow
    conversation_id UUID,
    task_id         VARCHAR(255),
    request_body    JSONB,
    response_summary TEXT,
    request_tokens  INT DEFAULT 0,
    response_tokens INT DEFAULT 0,
    total_tokens    INT DEFAULT 0,
    latency_ms      INT DEFAULT 0,
    model_provider  VARCHAR(100),             -- 模型提供商（新增）
    model_id        VARCHAR(100),             -- 模型 ID（新增）
    status          VARCHAR(20) NOT NULL,
    error_message   TEXT,
    gateway_slug    VARCHAR(100),
    ip_address      VARCHAR(45),
    created_at      TIMESTAMPTZ DEFAULT NOW()
) PARTITION BY RANGE (created_at);            -- 按月分区

CREATE INDEX idx_dcl_app_time ON gva_enterprise.dify_call_logs(app_id, created_at DESC);
CREATE INDEX idx_dcl_user_time ON gva_enterprise.dify_call_logs(user_id, created_at DESC);
CREATE INDEX idx_dcl_org_time ON gva_enterprise.dify_call_logs(org_node_id, created_at DESC);
CREATE INDEX idx_dcl_model ON gva_enterprise.dify_call_logs(model_provider, model_id);

-- 每日聚合物化视图（含组织维度）
CREATE MATERIALIZED VIEW gva_enterprise.dify_call_daily_stats AS
SELECT
    app_id, user_id, org_node_id, call_type, model_provider, model_id,
    DATE_TRUNC('day', created_at)::DATE AS stat_date,
    COUNT(*) AS total_calls,
    SUM(total_tokens) AS total_tokens,
    SUM(request_tokens) AS total_request_tokens,
    SUM(response_tokens) AS total_response_tokens,
    ROUND(AVG(latency_ms)) AS avg_latency_ms,
    MAX(latency_ms) AS max_latency_ms,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY latency_ms) AS p95_latency_ms,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY latency_ms) AS p99_latency_ms,
    COUNT(*) FILTER (WHERE status = 'success') AS success_count,
    COUNT(*) FILTER (WHERE status = 'error') AS error_count
FROM gva_enterprise.dify_call_logs
GROUP BY app_id, user_id, org_node_id, call_type, model_provider, model_id,
         DATE_TRUNC('day', created_at)::DATE;
```

#### B.3.2 统计服务

**文件**：`server/service/enterprise/call_stats_service.go`

| 函数 | 说明 |
|------|------|
| `RecordCallLog(log DifyCallLog) error` | 异步批量写入（Go channel + batch insert） |
| `QueryCallLogs(filter CallLogFilter) (*PageResult, error)` | 查询调用历史 |
| `GetAppStats(appID, dateRange) (*AppStats, error)` | 单应用统计 |
| `GetOrgStats(orgNodeID, dateRange) (*OrgStats, error)` | 组织维度统计（新增） |
| `GetModelStats(dateRange) (*ModelStats, error)` | 模型维度统计（新增） |
| `GetCallTrend(filter, granularity) ([]TrendPoint, error)` | 趋势（日/周/月） |
| `GetTopApps(dateRange, limit) ([]AppRanking, error)` | 热门应用排行 |
| `GetTopUsers(dateRange, limit) ([]UserRanking, error)` | 活跃用户排行 |
| `ExportCallLogs(filter, format) (io.Reader, error)` | 导出 CSV/Excel |
| `RefreshDailyStats() error` | 刷新物化视图 |
| `GetRealtimeMetrics(appID) (*RealtimeMetrics, error)` | 实时指标（Redis） |

**异步写入器**：`server/service/enterprise/call_log_writer.go`
- Go channel 缓冲 + 批量 INSERT (每 100 条或每 5 秒)
- 背压控制：channel 满时降级到同步写

### B.4 应用市场（新增，参考 Dify Marketplace）

> **业界参考**：Dify 内置 Explore 页面、Salesforce AppExchange、企业微信应用市场

```sql
CREATE TABLE gva_enterprise.app_marketplace (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    app_config_id   UUID NOT NULL REFERENCES gva_enterprise.dify_app_config(id),
    publisher_id    UUID NOT NULL,
    publisher_org   UUID,                     -- 发布者组织
    title           VARCHAR(255) NOT NULL,
    description     TEXT,
    cover_image     VARCHAR(500),
    screenshots     TEXT[] DEFAULT '{}',
    category        VARCHAR(50),
    tags            TEXT[] DEFAULT '{}',
    install_count   INT DEFAULT 0,
    rating_avg      NUMERIC(3,2) DEFAULT 0,
    rating_count    INT DEFAULT 0,
    status          VARCHAR(20) DEFAULT 'PENDING', -- PENDING/APPROVED/REJECTED/ARCHIVED
    review_comment  TEXT,
    published_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE gva_enterprise.app_marketplace_reviews (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    marketplace_id  UUID NOT NULL REFERENCES gva_enterprise.app_marketplace(id),
    user_id         UUID NOT NULL,
    rating          SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5),
    comment         TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(marketplace_id, user_id)
);

CREATE TABLE gva_enterprise.app_installations (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    marketplace_id  UUID NOT NULL,
    user_id         UUID NOT NULL,
    org_node_id     UUID,
    installed_at    TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(marketplace_id, user_id)
);
```

### B.5 调用网关

**文件**：`server/service/enterprise/gateway_service.go`

```
POST /gva-api/v1/gateway/{url_slug}
Headers: Authorization: Bearer <JWT>

处理流程:
1. JWT 校验 → user_id
2. url_slug → dify_app_config → dify_app_id
3. 权限校验: CheckAppAccess(user_id, dify_app_id)
4. 获取 API Key → 代理到 Dify
5. 记录 dify_call_logs（异步）
6. 返回 Dify 响应（支持 SSE 流式透传）
```

### B.6 代码生成器

**文件**：`server/service/enterprise/codegen_service.go`

| 函数 | 说明 |
|------|------|
| `GenerateCallURL(slug) string` | 完整调用 URL |
| `GenerateInputTemplate(params) map[string]any` | JSON Schema |
| `GenerateJSExample(slug, params) string` | fetch/axios（含 SSE） |
| `GenerateCurlExample(slug, params) string` | cURL 命令 |
| `GeneratePythonExample(slug, params) string` | Python requests |
| `GenerateGoExample(slug, params) string` | Go net/http（新增） |

### B.7 API 接口

```
// 应用配置
GET    /gva-api/v1/apps                           → ListApps
POST   /gva-api/v1/apps                           → CreateApp
GET    /gva-api/v1/apps/:id                       → GetApp
PUT    /gva-api/v1/apps/:id                       → UpdateApp
DELETE /gva-api/v1/apps/:id                       → DeleteApp
POST   /gva-api/v1/apps/:id/sync                  → SyncFromDify

// API Key
GET    /gva-api/v1/apps/:id/keys                  → ListKeys
POST   /gva-api/v1/apps/:id/keys                  → CreateKey
DELETE /gva-api/v1/apps/:id/keys/:kid             → DeleteKey

// 访问控制
GET    /gva-api/v1/apps/:id/access-rules          → ListRules
POST   /gva-api/v1/apps/:id/access-rules          → SetRules
PUT    /gva-api/v1/apps/:id/access-mode           → UpdateAccessMode

// 调用监控（从原模块C合并）
GET    /gva-api/v1/apps/:id/call-logs             → QueryLogs
GET    /gva-api/v1/apps/:id/stats                 → GetAppStats
GET    /gva-api/v1/apps/:id/stats/trend           → GetTrend
GET    /gva-api/v1/apps/:id/stats/realtime        → GetRealtime
GET    /gva-api/v1/stats/overview                  → GetOrgStats (跨应用)
GET    /gva-api/v1/stats/top-apps                  → GetTopApps
GET    /gva-api/v1/stats/top-users                 → GetTopUsers
GET    /gva-api/v1/stats/model-usage               → GetModelStats
POST   /gva-api/v1/call-logs/export               → ExportLogs

// 调用测试
POST   /gva-api/v1/apps/:id/test/chat             → TestChat
POST   /gva-api/v1/apps/:id/test/completion        → TestCompletion
POST   /gva-api/v1/apps/:id/test/workflow          → TestWorkflow
POST   /gva-api/v1/apps/:id/test/stop/:taskId     → StopTask

// 调用网关
POST   /gva-api/v1/gateway/:slug                  → GatewayProxy

// 代码生成
GET    /gva-api/v1/apps/:id/codegen/:lang          → GenerateCode

// 应用市场
GET    /gva-api/v1/marketplace                     → ListMarketplace
GET    /gva-api/v1/marketplace/:id                 → GetMarketplaceApp
POST   /gva-api/v1/marketplace                     → PublishToMarketplace
PUT    /gva-api/v1/marketplace/:id/review          → ReviewApp
POST   /gva-api/v1/marketplace/:id/install         → InstallApp
POST   /gva-api/v1/marketplace/:id/rate            → RateApp

// Dify Enterprise API（被 Dify 回调）
GET    /gva-api/enterprise/webapp/access-mode/id         → GetAppAccessMode
POST   /gva-api/enterprise/webapp/access-mode/batch/id   → BatchGetAccessMode
POST   /gva-api/enterprise/webapp/access-mode             → UpdateAccessMode
GET    /gva-api/enterprise/webapp/permission               → CheckAccess
POST   /gva-api/enterprise/webapp/permission/batch         → BatchCheckAccess
GET    /gva-api/enterprise/sso/app/last-update-time       → GetAppSSOLastUpdate
GET    /gva-api/enterprise/sso/workspace/last-update-time → GetWorkspaceSSOLastUpdate
DELETE /gva-api/enterprise/webapp/clean                    → CleanupWebApp
```

### B.8 前端页面

| 页面 | 功能 |
|------|------|
| `difyApps/index.vue` | 应用列表 + 同步状态 |
| `difyApps/detail.vue` | 应用详情（Tab 导航） |
| `difyApps/components/ApiKeyPanel.vue` | API Key 管理 |
| `difyApps/components/AccessModePanel.vue` | 访问模式 + SSO 配置 |
| `difyApps/components/SyncPanel.vue` | 远端同步 |
| `difyApps/components/CallTestPanel.vue` | 调用测试（Blocking/Streaming） |
| `difyApps/components/CodeGenPanel.vue` | 代码生成器 |
| `difyApps/components/StatsPanel.vue` | 应用统计仪表盘（**合并**） |
| `difyApps/components/CallLogTable.vue` | 调用日志表格（**合并**） |
| `dashboard/index.vue` | 全局统计仪表盘（**合并**） |
| `dashboard/components/TokenTrend.vue` | Token 趋势图 |
| `dashboard/components/CallVolume.vue` | 调用量柱状图 |
| `dashboard/components/LatencyP95.vue` | P95 延迟图（**新增**） |
| `dashboard/components/ErrorRate.vue` | 错误率折线图 |
| `dashboard/components/TopApps.vue` | 热门应用排行 |
| `dashboard/components/ModelUsage.vue` | 模型使用分布（**新增**） |
| `marketplace/index.vue` | 应用市场列表（**新增**） |
| `marketplace/detail.vue` | 应用市场详情（**新增**） |
| `marketplace/components/ReviewPanel.vue` | 审核面板（**新增**） |

### B.9 实现任务清单

| 序号 | 任务 | 文件 | 工时 |
|------|------|------|------|
| B-01 | SSO / 应用 / API Key / 访问规则 表 | `enterprise_init.sql` | 1d |
| B-02 | 调用日志 + 物化视图 + 分区表 | 同上 | 1d |
| B-03 | 应用市场 + 评价 + 安装 表 | 同上 | 0.5d |
| B-04 | GORM 模型 | 8 文件 | 1.5d |
| B-05 | SSOService（CRUD + 更新时间） | `sso_service.go` | 2d |
| B-06 | OAuth2 Server（Authorize/Token/UserInfo） | `oauth2_server.go` | 4d |
| B-07 | DifyRemoteService（远端读取 4 接口） | `dify_remote_service.go` | 1.5d |
| B-08 | DifySyncService（同步 + Webhook） | `dify_sync_service.go` | 2d |
| B-09 | DifyCallService（5 种调用 + SSE） | `dify_call_service.go` | 3d |
| B-10 | GatewayService（代理 + 鉴权 + 日志） | `gateway_service.go` | 2d |
| B-11 | CodegenService（6 种语言） | `codegen_service.go` | 2d |
| B-12 | CallStatsService（统计 + 物化视图 + 实时指标） | `call_stats_service.go` | 3d |
| B-13 | CallLogWriter（异步批量） | `call_log_writer.go` | 1.5d |
| B-14 | MarketplaceService（发布/审核/安装/评价） | `marketplace_service.go` | 2.5d |
| B-15 | Dify Enterprise API Handler（8 端点） | `dify_enterprise_api.go` | 2d |
| B-16 | 应用管理 API Handler | `dify_app_api.go` | 2d |
| B-17 | 统计 API Handler | `call_stats_api.go` | 1d |
| B-18 | 市场 API Handler | `marketplace_api.go` | 1d |
| B-19 | 路由注册 + 中间件 | 3 router 文件 | 1d |
| B-20 | Vue3 应用管理页面（含统计合并） | 11 组件 | 5d |
| B-21 | Vue3 全局仪表盘（含新增图表） | 7 组件 | 3d |
| B-22 | Vue3 应用市场页面 | 3 组件 | 2.5d |
| B-23 | 单元测试 + 集成测试 | 8 测试文件 | 3d |

**模块 B 小计：47 天**

---

## 四、模块 C：审计日志与合规中心

> **新增模块**。Dify 已有 `OperationLog` 模型（`api/models/model.py`），但功能较简单。企业级场景需要完整的审计追踪。  
> **业界参考**：AWS CloudTrail、DataDog Audit Trail、阿里云操作审计、SOC 2 合规要求

### C.1 数据模型

```sql
-- 扩展审计日志（补充 Dify OperationLog 不足的维度）
CREATE TABLE gva_enterprise.audit_logs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL,
    user_id         UUID NOT NULL,
    org_node_id     UUID,                     -- 操作者所属组织
    event_type      VARCHAR(50) NOT NULL,      -- AUTH / APP / DATA / ADMIN / SYSTEM
    event_action    VARCHAR(100) NOT NULL,      -- login / create_app / delete_dataset / ...
    resource_type   VARCHAR(50),               -- app / dataset / workflow / member / ...
    resource_id     UUID,
    resource_name   VARCHAR(255),
    detail          JSONB DEFAULT '{}',        -- 操作详情 JSON
    diff            JSONB,                     -- 变更前后对比（新增）
    risk_level      VARCHAR(20) DEFAULT 'LOW', -- LOW / MEDIUM / HIGH / CRITICAL
    ip_address      VARCHAR(45),
    user_agent      TEXT,
    geo_location    VARCHAR(100),              -- IP 地理位置（新增）
    session_id      VARCHAR(255),
    request_id      VARCHAR(255),              -- 请求追踪 ID
    created_at      TIMESTAMPTZ DEFAULT NOW()
) PARTITION BY RANGE (created_at);

CREATE INDEX idx_al_tenant_time ON gva_enterprise.audit_logs(tenant_id, created_at DESC);
CREATE INDEX idx_al_user ON gva_enterprise.audit_logs(user_id, created_at DESC);
CREATE INDEX idx_al_event ON gva_enterprise.audit_logs(event_type, event_action);
CREATE INDEX idx_al_resource ON gva_enterprise.audit_logs(resource_type, resource_id);
CREATE INDEX idx_al_risk ON gva_enterprise.audit_logs(risk_level) WHERE risk_level IN ('HIGH','CRITICAL');

-- 敏感操作二次确认配置
CREATE TABLE gva_enterprise.sensitive_action_config (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    action_pattern  VARCHAR(200) NOT NULL UNIQUE,  -- 如 'delete_*' / 'update_access_mode'
    risk_level      VARCHAR(20) DEFAULT 'HIGH',
    require_mfa     BOOLEAN DEFAULT FALSE,
    require_approval BOOLEAN DEFAULT FALSE,
    approval_roles  TEXT[] DEFAULT '{}',
    notify_channels TEXT[] DEFAULT '{}',           -- email / dingtalk / feishu / wecom
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- 合规报告任务
CREATE TABLE gva_enterprise.compliance_reports (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    report_type     VARCHAR(50) NOT NULL,          -- SOC2 / ISO27001 / GDPR / CUSTOM
    date_range_start TIMESTAMPTZ NOT NULL,
    date_range_end  TIMESTAMPTZ NOT NULL,
    generated_by    UUID NOT NULL,
    file_url        VARCHAR(500),
    status          VARCHAR(20) DEFAULT 'PENDING', -- PENDING / GENERATING / DONE / FAILED
    created_at      TIMESTAMPTZ DEFAULT NOW()
);
```

### C.2 核心服务

**文件**：`server/service/enterprise/audit_service.go`

| 函数 | 说明 |
|------|------|
| `RecordAudit(ctx, event AuditEvent) error` | 记录审计日志（异步写入） |
| `QueryAuditLogs(filter AuditFilter) (*PageResult, error)` | 高级检索 |
| `GetAuditDetail(logID) (*AuditLog, error)` | 详情（含 diff） |
| `GetRiskSummary(dateRange) (*RiskSummary, error)` | 风险概览 |
| `ExportAuditLogs(filter, format) (io.Reader, error)` | 导出 |
| `GenerateComplianceReport(req) (*ComplianceReport, error)` | 生成合规报告 |
| `CheckSensitiveAction(action) (*SensitiveConfig, error)` | 敏感操作拦截 |
| `SyncDifyOperationLogs(since time.Time) error` | 同步 Dify OperationLog |

**Gin 中间件**：`server/middleware/audit_middleware.go`

```go
// 自动记录所有写操作（POST/PUT/DELETE）
func AuditMiddleware() gin.HandlerFunc {
    return func(c *gin.Context) {
        if c.Request.Method == "GET" { c.Next(); return }
        // 1. 记录请求前状态
        // 2. c.Next()
        // 3. 记录响应状态 + diff
        // 4. 异步写 audit_logs
    }
}
```

### C.3 API 接口

```
GET    /gva-api/v1/audit/logs                     → QueryLogs
GET    /gva-api/v1/audit/logs/:id                 → GetDetail
GET    /gva-api/v1/audit/risk-summary             → GetRiskSummary
POST   /gva-api/v1/audit/export                   → ExportLogs

// 敏感操作配置
GET    /gva-api/v1/audit/sensitive-actions         → ListSensitiveActions
POST   /gva-api/v1/audit/sensitive-actions         → CreateConfig
PUT    /gva-api/v1/audit/sensitive-actions/:id     → UpdateConfig

// 合规报告
GET    /gva-api/v1/audit/compliance-reports        → ListReports
POST   /gva-api/v1/audit/compliance-reports        → GenerateReport
GET    /gva-api/v1/audit/compliance-reports/:id/download → DownloadReport
```

### C.4 前端页面

| 页面 | 功能 |
|------|------|
| `audit/index.vue` | 审计日志列表（高级筛选 + 时间线视图） |
| `audit/detail.vue` | 日志详情（含 JSON diff 可视化） |
| `audit/components/RiskDashboard.vue` | 风险概览仪表盘 |
| `audit/components/SensitiveActionConfig.vue` | 敏感操作配置 |
| `audit/components/CompliancePanel.vue` | 合规报告面板 |

### C.5 实现任务清单

| 序号 | 任务 | 文件 | 工时 |
|------|------|------|------|
| C-01 | 审计日志表 + 分区 + 敏感操作表 + 合规报告表 | SQL | 1d |
| C-02 | GORM 模型 | 3 文件 | 0.5d |
| C-03 | AuditService（记录/查询/导出/合规报告） | `audit_service.go` | 3d |
| C-04 | AuditMiddleware（自动审计 + diff 计算） | `middleware/audit_middleware.go` | 2d |
| C-05 | 敏感操作拦截 + MFA 集成 | `sensitive_action_service.go` | 2d |
| C-06 | Dify OperationLog 同步 | `audit_sync_service.go` | 1d |
| C-07 | API Handler + 路由 | 2 文件 | 1d |
| C-08 | Vue3 审计页面 | 5 组件 | 3d |
| C-09 | 单元测试 | 2 文件 | 1.5d |

**模块 C 小计：15 天**

---

## 五、模块 D：模型资源管理与成本控制

> **新增模块**。Dify 已有 `ModelProviderService` 和 `BillingService`，但缺少组织级的模型配额分摊和成本预算。  
> **业界参考**：Azure OpenAI Service（部署+配额）、AWS Bedrock（模型访问控制）、LangSmith（成本追踪）

### D.1 数据模型

```sql
-- 组织级模型配置（覆盖/扩展 Dify 默认配置）
CREATE TABLE gva_enterprise.org_model_config (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_node_id     UUID NOT NULL,
    model_provider  VARCHAR(100) NOT NULL,     -- openai / anthropic / zhipu / ...
    model_id        VARCHAR(100) NOT NULL,     -- gpt-4 / claude-3-opus / ...
    enabled         BOOLEAN DEFAULT TRUE,
    priority        INT DEFAULT 0,             -- 负载均衡优先级
    rate_limit_rpm  INT DEFAULT 0,             -- 每分钟请求限制（0=不限）
    rate_limit_tpm  INT DEFAULT 0,             -- 每分钟 Token 限制
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(org_node_id, model_provider, model_id)
);

-- Token 配额管理
CREATE TABLE gva_enterprise.token_quota (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    subject_type    VARCHAR(20) NOT NULL,      -- ORG / USER / APP
    subject_id      UUID NOT NULL,
    quota_type      VARCHAR(20) NOT NULL,      -- PERIOD_MONTHLY / PERIOD_DAILY / LIFETIME
    token_limit     BIGINT NOT NULL,           -- 配额上限
    token_used      BIGINT DEFAULT 0,          -- 已使用
    period_start    TIMESTAMPTZ,               -- 周期开始
    period_end      TIMESTAMPTZ,               -- 周期结束
    alert_threshold NUMERIC(3,2) DEFAULT 0.80, -- 告警阈值 (80%)
    action_on_exceed VARCHAR(20) DEFAULT 'WARN', -- WARN / BLOCK / DEGRADE
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(subject_type, subject_id, quota_type)
);

-- 成本核算记录
CREATE TABLE gva_enterprise.cost_records (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_node_id     UUID,
    user_id         UUID,
    app_id          UUID,
    model_provider  VARCHAR(100) NOT NULL,
    model_id        VARCHAR(100) NOT NULL,
    input_tokens    BIGINT DEFAULT 0,
    output_tokens   BIGINT DEFAULT 0,
    total_tokens    BIGINT DEFAULT 0,
    unit_price_input  NUMERIC(12,8),           -- 每 Token 输入单价
    unit_price_output NUMERIC(12,8),           -- 每 Token 输出单价
    total_cost      NUMERIC(12,6) DEFAULT 0,   -- 总费用
    currency        VARCHAR(10) DEFAULT 'USD',
    recorded_at     TIMESTAMPTZ DEFAULT NOW()
) PARTITION BY RANGE (recorded_at);

-- 预算告警规则
CREATE TABLE gva_enterprise.budget_alerts (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    subject_type    VARCHAR(20) NOT NULL,
    subject_id      UUID NOT NULL,
    budget_amount   NUMERIC(12,2) NOT NULL,
    budget_period   VARCHAR(20) NOT NULL,      -- MONTHLY / QUARTERLY / YEARLY
    current_spend   NUMERIC(12,2) DEFAULT 0,
    alert_at_pct    NUMERIC(3,2)[] DEFAULT '{0.50,0.80,0.95,1.00}',
    notify_channels TEXT[] DEFAULT '{}',
    status          VARCHAR(20) DEFAULT 'ACTIVE',
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- 模型价格表
CREATE TABLE gva_enterprise.model_pricing (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    model_provider  VARCHAR(100) NOT NULL,
    model_id        VARCHAR(100) NOT NULL,
    price_input     NUMERIC(12,8) NOT NULL,    -- 每 1K Token 输入价格
    price_output    NUMERIC(12,8) NOT NULL,    -- 每 1K Token 输出价格
    currency        VARCHAR(10) DEFAULT 'USD',
    effective_from  TIMESTAMPTZ DEFAULT NOW(),
    effective_to    TIMESTAMPTZ,
    UNIQUE(model_provider, model_id, effective_from)
);
```

### D.2 核心服务

**文件**：`server/service/enterprise/model_resource_service.go`

| 函数 | 说明 |
|------|------|
| `ListOrgModelConfigs(orgNodeID) ([]OrgModelConfig, error)` | 组织模型配置列表 |
| `SetOrgModelConfig(req) error` | 设置组织模型配置 |
| `CheckModelAccess(userID, provider, modelID) (bool, error)` | 模型访问校验 |
| `ConsumeTokenQuota(subjectType, subjectID, tokens) error` | 消耗 Token 配额 |
| `GetQuotaUsage(subjectType, subjectID) (*QuotaUsage, error)` | 配额用量 |
| `RecordCost(req CostRecord) error` | 记录成本 |
| `GetCostBreakdown(filter) (*CostBreakdown, error)` | 成本分摊明细 |
| `GetCostTrend(filter) ([]CostTrend, error)` | 成本趋势 |
| `CheckBudgetAlert(subjectType, subjectID) (*BudgetStatus, error)` | 预算检查 |
| `UpdateModelPricing(req) error` | 更新价格表 |
| `ResetPeriodicQuotas() error` | 重置周期配额（Cron） |

### D.3 API 接口

```
// 模型配置
GET    /gva-api/v1/model-config/org/:orgId        → ListOrgModels
POST   /gva-api/v1/model-config/org/:orgId        → SetOrgModel
DELETE /gva-api/v1/model-config/org/:orgId/:modelId → RemoveOrgModel

// Token 配额
GET    /gva-api/v1/quota/:subjectType/:subjectId   → GetQuota
PUT    /gva-api/v1/quota/:subjectType/:subjectId   → SetQuota
GET    /gva-api/v1/quota/:subjectType/:subjectId/usage → GetUsage

// 成本
GET    /gva-api/v1/cost/breakdown                  → GetCostBreakdown
GET    /gva-api/v1/cost/trend                      → GetCostTrend
GET    /gva-api/v1/cost/by-org                     → GetCostByOrg
GET    /gva-api/v1/cost/by-model                   → GetCostByModel

// 预算
GET    /gva-api/v1/budget/alerts                   → ListBudgetAlerts
POST   /gva-api/v1/budget/alerts                   → CreateBudgetAlert
PUT    /gva-api/v1/budget/alerts/:id               → UpdateBudgetAlert

// 价格表
GET    /gva-api/v1/model-pricing                   → ListPricing
PUT    /gva-api/v1/model-pricing                   → UpdatePricing
```

### D.4 前端页面

| 页面 | 功能 |
|------|------|
| `modelConfig/index.vue` | 组织模型配置 |
| `modelConfig/components/ModelSelector.vue` | 模型选择器 |
| `quota/index.vue` | Token 配额管理 |
| `quota/components/QuotaUsageChart.vue` | 配额使用图表 |
| `cost/index.vue` | 成本分析面板 |
| `cost/components/CostBreakdown.vue` | 成本分摊饼图 |
| `cost/components/CostTrend.vue` | 成本趋势图 |
| `cost/components/BudgetAlertPanel.vue` | 预算告警配置 |

### D.5 实现任务清单

| 序号 | 任务 | 文件 | 工时 |
|------|------|------|------|
| D-01 | 模型配置 / 配额 / 成本 / 预算 / 价格表 | SQL | 1d |
| D-02 | GORM 模型 | 5 文件 | 1d |
| D-03 | ModelResourceService（配置 + 访问校验 + 配额消耗） | `model_resource_service.go` | 3d |
| D-04 | CostService（成本记录 + 分摊 + 趋势） | `cost_service.go` | 2.5d |
| D-05 | BudgetAlertService（预算检查 + 告警触发） | `budget_alert_service.go` | 2d |
| D-06 | 配额重置 Cron 任务 | `timer.go` 追加 | 0.5d |
| D-07 | API Handler + 路由 | 3 文件 | 1.5d |
| D-08 | Vue3 页面 | 8 组件 | 4d |
| D-09 | 单元测试 | 3 文件 | 2d |

**模块 D 小计：17.5 天**

---

## 六、模块 E：通知中心与消息总线

> **新增模块**。Dify 有基础的 `BillingService.get_account_notification()` 但功能有限。  
> **业界参考**：Slack Workflow Builder、PagerDuty Event Orchestration、飞书/钉钉/企微机器人

### E.1 数据模型

```sql
-- 通知模板
CREATE TABLE gva_enterprise.notification_templates (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code            VARCHAR(100) NOT NULL UNIQUE,  -- quota_warning / budget_alert / ...
    name            VARCHAR(255) NOT NULL,
    channel         VARCHAR(20) NOT NULL,          -- INAPP / EMAIL / DINGTALK / FEISHU / WECOM / WEBHOOK
    subject         VARCHAR(500),                  -- 邮件主题模板
    body_template   TEXT NOT NULL,                 -- Go template 语法
    variables       JSONB DEFAULT '[]',            -- 可用变量说明
    is_system       BOOLEAN DEFAULT FALSE,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- 通知记录
CREATE TABLE gva_enterprise.notifications (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL,
    user_id         UUID,                          -- NULL = 广播
    template_code   VARCHAR(100),
    channel         VARCHAR(20) NOT NULL,
    title           VARCHAR(500),
    content         TEXT NOT NULL,
    priority        VARCHAR(20) DEFAULT 'NORMAL',  -- LOW / NORMAL / HIGH / URGENT
    status          VARCHAR(20) DEFAULT 'PENDING', -- PENDING / SENT / READ / FAILED
    read_at         TIMESTAMPTZ,
    metadata        JSONB DEFAULT '{}',
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_notif_user ON gva_enterprise.notifications(user_id, status, created_at DESC);

-- 事件订阅规则
CREATE TABLE gva_enterprise.event_subscriptions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    subscriber_id   UUID NOT NULL,                 -- user_id 或 webhook 配置 ID
    subscriber_type VARCHAR(20) NOT NULL,           -- USER / WEBHOOK / CHANNEL
    event_pattern   VARCHAR(200) NOT NULL,          -- 如 'app.*' / 'quota.exceeded' / 'audit.high_risk'
    channels        TEXT[] DEFAULT '{}',            -- 推送渠道
    enabled         BOOLEAN DEFAULT TRUE,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- 出站 Webhook 配置
CREATE TABLE gva_enterprise.outbound_webhooks (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            VARCHAR(255) NOT NULL,
    url             VARCHAR(1000) NOT NULL,
    secret          VARCHAR(512),                  -- HMAC 签名密钥
    headers         JSONB DEFAULT '{}',
    retry_count     INT DEFAULT 3,
    timeout_ms      INT DEFAULT 5000,
    status          VARCHAR(20) DEFAULT 'ACTIVE',
    last_triggered_at TIMESTAMPTZ,
    last_status     VARCHAR(20),
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- Webhook 投递记录
CREATE TABLE gva_enterprise.webhook_delivery_logs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    webhook_id      UUID NOT NULL REFERENCES gva_enterprise.outbound_webhooks(id),
    event_type      VARCHAR(100) NOT NULL,
    request_body    JSONB,
    response_status INT,
    response_body   TEXT,
    latency_ms      INT,
    attempt         INT DEFAULT 1,
    status          VARCHAR(20) NOT NULL,          -- SUCCESS / FAILED / RETRYING
    created_at      TIMESTAMPTZ DEFAULT NOW()
);
```

### E.2 核心服务

**文件**：`server/service/enterprise/notification_service.go`

| 函数 | 说明 |
|------|------|
| `SendNotification(req NotifReq) error` | 发送通知（路由到各渠道） |
| `BroadcastNotification(tenantID, req) error` | 广播通知 |
| `GetUserNotifications(userID, filter) (*PageResult, error)` | 用户通知列表 |
| `MarkAsRead(userID, notifIDs) error` | 标记已读 |
| `GetUnreadCount(userID) (int, error)` | 未读计数 |

**文件**：`server/service/enterprise/event_bus_service.go`

| 函数 | 说明 |
|------|------|
| `Publish(event Event) error` | 发布事件到 Redis Stream |
| `Subscribe(pattern, handler) error` | 订阅事件 |
| `ProcessEventQueue() error` | 消费事件队列 (常驻 goroutine) |
| `MatchSubscribers(eventType) ([]Subscription, error)` | 匹配订阅者 |

**文件**：`server/service/enterprise/webhook_dispatcher.go`

| 函数 | 说明 |
|------|------|
| `DispatchWebhook(webhookID, event) error` | 投递 Webhook（含重试） |
| `VerifyWebhookSignature(payload, secret, signature) bool` | 验签 |
| `QueryDeliveryLogs(webhookID, filter) (*PageResult, error)` | 投递日志 |

**渠道适配器**（策略模式）：

| 文件 | 渠道 |
|------|------|
| `channel/inapp_channel.go` | 站内通知（写 DB + WebSocket 推送） |
| `channel/email_channel.go` | 邮件（SMTP / SendGrid / AWS SES） |
| `channel/dingtalk_channel.go` | 钉钉机器人 |
| `channel/feishu_channel.go` | 飞书机器人 |
| `channel/wecom_channel.go` | 企业微信机器人 |
| `channel/webhook_channel.go` | 出站 Webhook |

### E.3 API 接口

```
// 通知
GET    /gva-api/v1/notifications                   → List
GET    /gva-api/v1/notifications/unread-count       → UnreadCount
PUT    /gva-api/v1/notifications/read               → MarkRead
PUT    /gva-api/v1/notifications/read-all           → MarkAllRead

// 事件订阅
GET    /gva-api/v1/event-subscriptions             → ListSubscriptions
POST   /gva-api/v1/event-subscriptions             → CreateSubscription
PUT    /gva-api/v1/event-subscriptions/:id         → UpdateSubscription
DELETE /gva-api/v1/event-subscriptions/:id         → DeleteSubscription

// 出站 Webhook
GET    /gva-api/v1/webhooks                        → ListWebhooks
POST   /gva-api/v1/webhooks                        → CreateWebhook
PUT    /gva-api/v1/webhooks/:id                    → UpdateWebhook
DELETE /gva-api/v1/webhooks/:id                    → DeleteWebhook
POST   /gva-api/v1/webhooks/:id/test               → TestWebhook
GET    /gva-api/v1/webhooks/:id/deliveries         → QueryDeliveries

// WebSocket
WS     /ws/notifications                           → 实时通知推送
```

### E.4 前端页面

| 页面 | 功能 |
|------|------|
| `notifications/index.vue` | 通知中心（列表 + 筛选） |
| `notifications/components/NotifBell.vue` | 右上角通知铃铛（全局组件） |
| `notifications/components/NotifPreview.vue` | 弹窗预览 |
| `eventSubscriptions/index.vue` | 事件订阅管理 |
| `webhooks/index.vue` | 出站 Webhook 管理 |
| `webhooks/components/DeliveryLog.vue` | 投递日志详情 |

### E.5 实现任务清单

| 序号 | 任务 | 文件 | 工时 |
|------|------|------|------|
| E-01 | 通知 / 事件订阅 / Webhook / 投递日志 表 | SQL | 1d |
| E-02 | GORM 模型 | 5 文件 | 1d |
| E-03 | NotificationService | `notification_service.go` | 2d |
| E-04 | EventBusService（Redis Stream） | `event_bus_service.go` | 3d |
| E-05 | WebhookDispatcher（含重试 + 签名） | `webhook_dispatcher.go` | 2d |
| E-06 | 渠道适配器（6 个） | `channel/*.go` | 4d |
| E-07 | WebSocket 推送服务 | `ws/notification_hub.go` | 2d |
| E-08 | API Handler + 路由 | 3 文件 | 1.5d |
| E-09 | Vue3 通知中心 + 铃铛 + 订阅 + Webhook 页面 | 6 组件 | 3.5d |
| E-10 | 单元测试 | 4 文件 | 2d |

**模块 E 小计：22 天**

---

## 七、模块 F：多租户管理与隔离

> **新增模块**。Dify 已有 Tenant 模型，但 GVA 管理平台需要租户级别的管理控制台。  
> **业界参考**：AWS SaaS Factory、Azure Multi-tenant Architecture、Kubernetes Namespace 隔离

### F.1 数据模型

```sql
-- 租户（扩展 Dify tenant 概念）
CREATE TABLE gva_enterprise.tenants (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    dify_tenant_id  UUID NOT NULL UNIQUE,      -- 关联 Dify tenant.id
    name            VARCHAR(255) NOT NULL,
    code            VARCHAR(50) UNIQUE,        -- 租户编码
    plan            VARCHAR(50) DEFAULT 'basic', -- basic / pro / enterprise
    status          VARCHAR(20) DEFAULT 'ACTIVE', -- ACTIVE / SUSPENDED / ARCHIVED
    config          JSONB DEFAULT '{}',        -- 租户级配置
    feature_flags   JSONB DEFAULT '{}',        -- 功能开关
    resource_limits JSONB DEFAULT '{}',        -- 资源限制
    contact_email   VARCHAR(255),
    contact_name    VARCHAR(100),
    trial_starts_at TIMESTAMPTZ,
    trial_ends_at   TIMESTAMPTZ,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- 租户功能开关
CREATE TABLE gva_enterprise.tenant_features (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES gva_enterprise.tenants(id),
    feature_key     VARCHAR(100) NOT NULL,     -- sso / marketplace / audit / ...
    enabled         BOOLEAN DEFAULT FALSE,
    config          JSONB DEFAULT '{}',
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(tenant_id, feature_key)
);

-- 租户资源使用统计
CREATE TABLE gva_enterprise.tenant_usage (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL,
    metric_key      VARCHAR(100) NOT NULL,     -- apps / members / tokens / storage / ...
    metric_value    BIGINT DEFAULT 0,
    metric_limit    BIGINT DEFAULT 0,
    recorded_at     TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(tenant_id, metric_key)
);
```

### F.2 核心服务

**文件**：`server/service/enterprise/tenant_service.go`

| 函数 | 说明 |
|------|------|
| `CreateTenant(req) (*Tenant, error)` | 创建租户（含 Dify Workspace 初始化） |
| `UpdateTenant(id, req) error` | 更新租户信息 |
| `SuspendTenant(id) error` | 暂停租户 |
| `ActivateTenant(id) error` | 激活租户 |
| `ArchiveTenant(id) error` | 归档租户 |
| `GetTenantDashboard(id) (*TenantDashboard, error)` | 租户仪表盘 |
| `SetFeatureFlag(tenantID, key, enabled) error` | 设置功能开关 |
| `GetFeatureFlags(tenantID) (map[string]bool, error)` | 获取功能开关 |
| `CheckResourceLimit(tenantID, metric) (bool, error)` | 资源限制检查 |
| `UpdateUsageMetric(tenantID, metric, delta) error` | 更新使用量 |

### F.3 API 接口

```
// 租户管理（超管专用）
GET    /gva-api/v1/tenants                         → ListTenants
POST   /gva-api/v1/tenants                         → CreateTenant
GET    /gva-api/v1/tenants/:id                     → GetTenant
PUT    /gva-api/v1/tenants/:id                     → UpdateTenant
PUT    /gva-api/v1/tenants/:id/suspend             → SuspendTenant
PUT    /gva-api/v1/tenants/:id/activate            → ActivateTenant
GET    /gva-api/v1/tenants/:id/dashboard           → TenantDashboard

// 功能开关
GET    /gva-api/v1/tenants/:id/features            → ListFeatures
PUT    /gva-api/v1/tenants/:id/features/:key       → SetFeature

// 资源使用
GET    /gva-api/v1/tenants/:id/usage               → GetUsage
```

### F.4 前端页面

| 页面 | 功能 |
|------|------|
| `tenants/index.vue` | 租户列表 |
| `tenants/detail.vue` | 租户详情（含仪表盘） |
| `tenants/components/FeatureFlagPanel.vue` | 功能开关管理 |
| `tenants/components/UsagePanel.vue` | 资源使用面板 |
| `tenants/components/PlanSelector.vue` | 套餐选择 |

### F.5 实现任务清单

| 序号 | 任务 | 文件 | 工时 |
|------|------|------|------|
| F-01 | 租户 / 功能开关 / 使用统计 表 | SQL | 0.5d |
| F-02 | GORM 模型 | 3 文件 | 0.5d |
| F-03 | TenantService | `tenant_service.go` | 3d |
| F-04 | FeatureFlagService | `feature_flag_service.go` | 1.5d |
| F-05 | 租户中间件（自动注入租户上下文） | `middleware/tenant_middleware.go` | 1d |
| F-06 | API Handler + 路由 | 2 文件 | 1d |
| F-07 | Vue3 租户管理页面 | 5 组件 | 2.5d |
| F-08 | 单元测试 | 2 文件 | 1.5d |

**模块 F 小计：11.5 天**

---

## 八、模块 G：灾备与高可用

> **新增模块**。企业级部署必须考虑数据安全和服务连续性。  
> **业界参考**：PgBackRest（PostgreSQL 备份）、Redis Sentinel/Cluster、Kubernetes Operator Pattern

### G.1 数据备份

#### G.1.1 备份策略配置

```sql
CREATE TABLE gva_enterprise.backup_policies (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            VARCHAR(255) NOT NULL,
    backup_type     VARCHAR(20) NOT NULL,      -- FULL / INCREMENTAL / WAL
    target          VARCHAR(50) NOT NULL,       -- POSTGRES / REDIS / FILES
    schedule        VARCHAR(100) NOT NULL,      -- Cron 表达式
    retention_days  INT DEFAULT 30,
    storage_path    VARCHAR(500),               -- S3/MinIO 路径
    encryption_key  VARCHAR(512),               -- 备份加密密钥
    enabled         BOOLEAN DEFAULT TRUE,
    last_run_at     TIMESTAMPTZ,
    last_status     VARCHAR(20),
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE gva_enterprise.backup_records (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    policy_id       UUID NOT NULL REFERENCES gva_enterprise.backup_policies(id),
    backup_type     VARCHAR(20) NOT NULL,
    file_path       VARCHAR(500),
    file_size_bytes BIGINT,
    checksum        VARCHAR(128),              -- SHA-256
    status          VARCHAR(20) NOT NULL,       -- RUNNING / SUCCESS / FAILED
    started_at      TIMESTAMPTZ,
    completed_at    TIMESTAMPTZ,
    error_message   TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);
```

### G.2 核心服务

**文件**：`server/service/enterprise/backup_service.go`

| 函数 | 说明 |
|------|------|
| `ExecuteBackup(policyID) (*BackupRecord, error)` | 执行备份 |
| `RestoreFromBackup(recordID) error` | 从备份恢复 |
| `ListBackupRecords(policyID, filter) (*PageResult, error)` | 备份记录列表 |
| `CleanExpiredBackups() error` | 清理过期备份（Cron） |
| `VerifyBackupIntegrity(recordID) (bool, error)` | 校验备份完整性 |

**文件**：`server/service/enterprise/health_service.go`

| 函数 | 说明 |
|------|------|
| `CheckHealth() (*HealthReport, error)` | 综合健康检查 |
| `CheckPostgres() (*ComponentHealth, error)` | PostgreSQL 健康 |
| `CheckRedis() (*ComponentHealth, error)` | Redis 健康 |
| `CheckDifyAPI() (*ComponentHealth, error)` | Dify API 可达性 |
| `CheckStorageQuota() (*StorageHealth, error)` | 存储空间 |
| `GetSystemMetrics() (*SystemMetrics, error)` | 系统指标（CPU/内存/磁盘） |

### G.3 API 接口

```
// 备份管理
GET    /gva-api/v1/backup/policies                → ListPolicies
POST   /gva-api/v1/backup/policies                → CreatePolicy
PUT    /gva-api/v1/backup/policies/:id            → UpdatePolicy
POST   /gva-api/v1/backup/policies/:id/run        → RunBackup
GET    /gva-api/v1/backup/records                  → ListRecords
POST   /gva-api/v1/backup/records/:id/restore     → Restore
POST   /gva-api/v1/backup/records/:id/verify      → VerifyIntegrity

// 健康检查
GET    /gva-api/v1/health                          → HealthCheck
GET    /gva-api/v1/health/detailed                 → DetailedHealth
GET    /gva-api/v1/system/metrics                  → SystemMetrics
```

### G.4 前端页面

| 页面 | 功能 |
|------|------|
| `backup/index.vue` | 备份策略管理 |
| `backup/components/BackupRecordList.vue` | 备份记录列表 |
| `backup/components/RestoreDialog.vue` | 恢复确认弹窗 |
| `system/health.vue` | 系统健康仪表盘 |
| `system/components/ComponentStatus.vue` | 组件状态卡片 |
| `system/components/MetricsChart.vue` | 系统指标图表 |

### G.5 实现任务清单

| 序号 | 任务 | 文件 | 工时 |
|------|------|------|------|
| G-01 | 备份策略 / 记录 表 | SQL | 0.5d |
| G-02 | GORM 模型 | 2 文件 | 0.5d |
| G-03 | BackupService（PostgreSQL pg_dump + S3 上传） | `backup_service.go` | 3d |
| G-04 | HealthService（多组件检查） | `health_service.go` | 2d |
| G-05 | 备份 Cron 任务调度 | `timer.go` 追加 | 1d |
| G-06 | API Handler + 路由 | 2 文件 | 1d |
| G-07 | Vue3 备份管理 + 健康面板 | 6 组件 | 3d |
| G-08 | 单元测试 | 2 文件 | 1.5d |

**模块 G 小计：12.5 天**

---

## 九、全局技术设计

### 9.1 中间件栈

```
请求 → RateLimiter → JWT Auth → TenantContext → RBAC(Casbin) → AuditMiddleware → Handler
```

| 中间件 | 文件 | 说明 |
|--------|------|------|
| RateLimitMiddleware | `middleware/rate_limit.go` | Redis 滑动窗口限流 |
| JWTAuthMiddleware | `middleware/jwt_auth.go` | JWT 解析 + 刷新 |
| TenantMiddleware | `middleware/tenant.go` | 注入租户上下文 |
| CasbinMiddleware | `middleware/casbin.go` | RBAC 路由级鉴权 |
| AuditMiddleware | `middleware/audit.go` | 写操作自动审计 |
| CorsMiddleware | `middleware/cors.go` | 跨域配置 |
| RequestIDMiddleware | `middleware/request_id.go` | 链路追踪 ID |

### 9.2 缓存架构

| 缓存层 | 技术 | Key 模式 | TTL |
|--------|------|---------|-----|
| L1 进程内 | `sync.RWMutex` + Map | 组织树 / 权限范围 | 10min |
| L2 Redis | Redis String/Hash/Set | `perm:*` / `quota:*` / `org:*` | 5-30min |
| L3 Redis Stream | Redis Stream | `event:*` | 消费后删除 |
| L4 数据库 | PostgreSQL | 持久化 | ∞ |

**缓存一致性**：写操作 → 删除 L1 + L2 → Redis Pub/Sub 通知集群其他实例删除 L1

### 9.3 事件驱动架构

```
┌──────────┐    Publish     ┌──────────────┐    Fan-out    ┌──────────────┐
│  Service  │ ─────────────► │ Redis Stream │ ────────────► │ EventBus     │
│  Layer    │               │ (event:main) │               │ Consumer     │
└──────────┘               └──────────────┘               └──────┬───────┘
                                                                  │
                           ┌──────────────────────────────────────┤
                           │              │              │        │
                    ┌──────▼──┐    ┌──────▼──┐    ┌─────▼───┐ ┌──▼──────┐
                    │ 通知服务 │    │ 审计服务 │    │ Webhook │ │ 预算检查 │
                    └─────────┘    └─────────┘    └─────────┘ └─────────┘
```

**事件类型定义**：

```go
// server/model/enterprise/events.go
const (
    EventAppCreated       = "app.created"
    EventAppDeleted       = "app.deleted"
    EventAppInvoked       = "app.invoked"
    EventMemberAdded      = "member.added"
    EventMemberRemoved    = "member.removed"
    EventRoleChanged      = "role.changed"
    EventQuotaExceeded    = "quota.exceeded"
    EventBudgetWarning    = "budget.warning"
    EventSSOConfigChanged = "sso.config_changed"
    EventAuditHighRisk    = "audit.high_risk"
    EventBackupCompleted  = "backup.completed"
    EventBackupFailed     = "backup.failed"
    EventHealthDegraded   = "health.degraded"
)
```

### 9.4 安全设计

| 安全措施 | 实现方式 | 位置 |
|---------|---------|------|
| API Key 加密存储 | AES-256-GCM | `utils/crypto/aes.go` |
| JWT 签名 | RS256（非对称） | `middleware/jwt_auth.go` |
| CSRF 防护 | Double Submit Cookie | `middleware/csrf.go` |
| SQL 注入防护 | GORM 参数化查询 | 全局 |
| XSS 防护 | CSP Header + HTML Escape | `middleware/security_headers.go` |
| 敏感日志脱敏 | 正则替换 API Key / Token | `utils/log/sanitizer.go` |
| 请求签名（内部 API） | HMAC-SHA256 | `middleware/internal_auth.go` |
| 数据备份加密 | AES-256 | `backup_service.go` |

### 9.5 性能优化

| 优化点 | 策略 | 位置 |
|--------|------|------|
| 调用日志写入 | Go channel 缓冲 + 批量 INSERT | `call_log_writer.go` |
| 权限计算 | 二级缓存 (进程内 + Redis) | `permission_engine.go` |
| 组织树查询 | ltree + 进程内缓存 + Pub/Sub 失效 | `org_tree_service.go` |
| 统计聚合 | 物化视图 + 定时刷新 | `call_stats_service.go` |
| API Token 校验 | Single-flight 防击穿 | 复用 Dify |
| 调用日志分区 | 按月自动分区 | DDL |
| 连接池 | pgxpool MaxConns=50 | `config.yaml` |

---

## 十、实施路线图

### 阶段规划

```
Phase 1 (第1-5周)    ████████████████████████  模块A: 组织架构与权限 (27d)
Phase 2 (第5-15周)   ████████████████████████████████████████████████  模块B: 应用全生命周期 (47d)
Phase 3 (第12-15周)  ██████████████  模块C: 审计日志 (15d) [与B并行]
Phase 4 (第15-19周)  ██████████████████  模块D: 模型资源 (17.5d)
Phase 5 (第19-23周)  ████████████████████████  模块E: 通知中心 (22d)
Phase 6 (第23-26周)  ████████████  模块F: 多租户 (11.5d)
Phase 7 (第26-29周)  ██████████████  模块G: 灾备高可用 (12.5d)
```

### 里程碑

| 里程碑 | 周数 | 交付物 |
|--------|------|--------|
| **M1** | 第 3 周 | 组织树 CRUD + 权限引擎可用 |
| **M2** | 第 5 周 | 模块 A 完整 + 管理页面 |
| **M3** | 第 9 周 | SSO Provider + Enterprise API 对接 + WebApp SSO 流程打通 |
| **M4** | 第 12 周 | 应用管理 + 网关 + 调用测试 + 应用内统计 |
| **M5** | 第 15 周 | 模块 B 完整（含应用市场）+ 模块 C 审计日志 |
| **M6** | 第 19 周 | 模型资源管理 + 成本控制 |
| **M7** | 第 23 周 | 通知中心 + 事件总线 + Webhook |
| **M8** | 第 26 周 | 多租户管理 |
| **M9** | 第 29 周 | 灾备高可用 + 全功能上线 |

### 工时汇总

| 模块 | 工时 | 占比 |
|------|------|------|
| A - 组织架构与权限 | 27d | 17.6% |
| B - 应用全生命周期 | 47d | 30.7% |
| C - 审计日志与合规 | 15d | 9.8% |
| D - 模型资源管理 | 17.5d | 11.4% |
| E - 通知中心 | 22d | 14.4% |
| F - 多租户管理 | 11.5d | 7.5% |
| G - 灾备高可用 | 12.5d | 8.2% |
| 联调 + Buffer | ~5d | 3.3% |
| **总计** | **~158d** | **约 32 周** |

**推荐团队配置**：3-4 名全栈工程师，预计 8-10 个月完成

---

## 十一、新增文件总览

### GVA Go 后端 (server/)

```
server/
├── model/enterprise/
│   ├── org_node.go                     # A-03
│   ├── org_node_member.go              # A-03
│   ├── perm_level.go                   # A-03
│   ├── role_template.go                # A-03 (新增)
│   ├── sso_config.go                   # B-04
│   ├── dify_app.go                     # B-04
│   ├── dify_api_key.go                 # B-04
│   ├── app_access_rule.go              # B-04
│   ├── call_log.go                     # B-04
│   ├── app_marketplace.go              # B-04 (新增)
│   ├── audit_log.go                    # C-02
│   ├── sensitive_action.go             # C-02
│   ├── compliance_report.go            # C-02
│   ├── org_model_config.go             # D-02
│   ├── token_quota.go                  # D-02
│   ├── cost_record.go                  # D-02
│   ├── budget_alert.go                 # D-02
│   ├── model_pricing.go               # D-02
│   ├── notification.go                 # E-02
│   ├── event_subscription.go           # E-02
│   ├── outbound_webhook.go             # E-02
│   ├── webhook_delivery_log.go         # E-02
│   ├── notification_template.go        # E-02
│   ├── tenant.go                       # F-02
│   ├── tenant_feature.go              # F-02
│   ├── tenant_usage.go                # F-02
│   ├── backup_policy.go               # G-02
│   ├── backup_record.go               # G-02
│   ├── events.go                       # 事件类型常量 (新增)
│   ├── request/                        # 请求 DTO
│   └── response/                       # 响应 DTO
│
├── service/enterprise/
│   ├── org_tree_service.go             # A-05
│   ├── member_service.go               # A-06
│   ├── permission_engine.go            # A-07
│   ├── login_context_service.go        # A-08
│   ├── dify_sync_service.go            # A-12, B-08
│   ├── sso_service.go                  # B-05
│   ├── oauth2_server.go                # B-06
│   ├── dify_remote_service.go          # B-07
│   ├── dify_call_service.go            # B-09
│   ├── gateway_service.go              # B-10
│   ├── codegen_service.go              # B-11
│   ├── call_stats_service.go           # B-12
│   ├── call_log_writer.go              # B-13
│   ├── marketplace_service.go          # B-14 (新增)
│   ├── audit_service.go                # C-03
│   ├── sensitive_action_service.go     # C-05
│   ├── audit_sync_service.go           # C-06
│   ├── model_resource_service.go       # D-03
│   ├── cost_service.go                 # D-04
│   ├── budget_alert_service.go         # D-05
│   ├── notification_service.go         # E-03
│   ├── event_bus_service.go            # E-04
│   ├── webhook_dispatcher.go           # E-05
│   ├── channel/                        # E-06 (渠道适配器)
│   │   ├── inapp_channel.go
│   │   ├── email_channel.go
│   │   ├── dingtalk_channel.go
│   │   ├── feishu_channel.go
│   │   ├── wecom_channel.go
│   │   └── webhook_channel.go
│   ├── tenant_service.go               # F-03
│   ├── feature_flag_service.go         # F-04
│   ├── backup_service.go               # G-03
│   ├── health_service.go               # G-04
│   └── *_test.go                       # 测试文件
│
├── api/v1/enterprise/
│   ├── org_api.go                      # A-10
│   ├── member_api.go                   # A-10
│   ├── perm_api.go                     # A-10
│   ├── login_ctx_api.go                # A-10
│   ├── role_api.go                     # A-10 (新增)
│   ├── dify_enterprise_api.go          # B-15
│   ├── dify_app_api.go                 # B-16
│   ├── call_stats_api.go              # B-17
│   ├── marketplace_api.go             # B-18 (新增)
│   ├── audit_api.go                    # C-07
│   ├── model_resource_api.go          # D-07
│   ├── cost_api.go                     # D-07
│   ├── notification_api.go             # E-08
│   ├── event_subscription_api.go       # E-08
│   ├── webhook_api.go                  # E-08
│   ├── tenant_api.go                   # F-06
│   ├── backup_api.go                   # G-06
│   └── health_api.go                   # G-06
│
├── router/enterprise/
│   ├── org_router.go                   # A-11
│   ├── dify_enterprise_router.go       # B-19
│   ├── dify_app_router.go             # B-19
│   ├── marketplace_router.go          # B-19 (新增)
│   ├── audit_router.go                 # C-07
│   ├── model_resource_router.go        # D-07
│   ├── notification_router.go          # E-08
│   ├── tenant_router.go               # F-06
│   └── backup_router.go               # G-06
│
├── middleware/
│   ├── rate_limit.go                   # 9.1
│   ├── jwt_auth.go                     # 9.1
│   ├── tenant.go                       # F-05
│   ├── casbin.go                       # 9.1
│   ├── audit.go                        # C-04
│   ├── security_headers.go             # 9.4
│   ├── internal_auth.go                # 9.4
│   ├── request_id.go                   # 9.1
│   └── csrf.go                         # 9.4
│
├── ws/
│   └── notification_hub.go             # E-07
│
├── global/cache/
│   ├── org_cache.go                    # A-09
│   └── perm_cache.go                   # A-09
│
├── utils/
│   ├── sets/diff.go                    # A-06
│   ├── crypto/aes.go                   # 9.4
│   ├── log/sanitizer.go                # 9.4
│   └── export/excel.go                 # C 导出
│
└── resource/sql/
    └── enterprise_init.sql              # 所有 DDL
```

### GVA Vue3 前端 (web/src/views/enterprise/)

```
web/src/views/enterprise/
├── orgTree/                            # 模块 A
│   ├── index.vue
│   └── components/ (5 组件)
├── roleConfig/                         # 模块 A
│   ├── index.vue
│   └── components/PermissionMatrix.vue
├── loginOrg/index.vue                  # 模块 A
├── difyApps/                           # 模块 B
│   ├── index.vue
│   ├── detail.vue
│   └── components/ (9 组件，含统计合并)
├── dashboard/                          # 模块 B (统计合并)
│   ├── index.vue
│   └── components/ (6 组件)
├── marketplace/                        # 模块 B (新增)
│   ├── index.vue
│   ├── detail.vue
│   └── components/ReviewPanel.vue
├── audit/                              # 模块 C (新增)
│   ├── index.vue
│   ├── detail.vue
│   └── components/ (3 组件)
├── modelConfig/                        # 模块 D (新增)
│   ├── index.vue
│   └── components/ModelSelector.vue
├── quota/                              # 模块 D (新增)
│   ├── index.vue
│   └── components/QuotaUsageChart.vue
├── cost/                               # 模块 D (新增)
│   ├── index.vue
│   └── components/ (3 组件)
├── notifications/                      # 模块 E (新增)
│   ├── index.vue
│   └── components/ (2 组件)
├── eventSubscriptions/index.vue        # 模块 E (新增)
├── webhooks/                           # 模块 E (新增)
│   ├── index.vue
│   └── components/DeliveryLog.vue
├── tenants/                            # 模块 F (新增)
│   ├── index.vue
│   ├── detail.vue
│   └── components/ (3 组件)
├── backup/                             # 模块 G (新增)
│   ├── index.vue
│   └── components/ (2 组件)
└── system/                             # 模块 G (新增)
    ├── health.vue
    └── components/ (2 组件)
```

### Dify 侧最小化修改

| 文件 | 修改 |
|------|------|
| `api/services/enterprise/enterprise_service.py` | EnterpriseRequest 基础 URL 指向 GVA |
| `api/controllers/console/wraps.py` | 新增 `@enterprise_permission_required` |
| `docker/docker-compose.yaml` | 新增 `gva-server` + `gva-web` 服务 |
| `docker/nginx/nginx.conf` | 新增 `/admin/*` / `/gva-api/*` / `/ws/*` 路由 |

---

> **文档结束**  
> 本文档基于 Dify 源码深度分析生成，所有对接点均已通过源码验证。  
> 如有疑问请联系技术架构组。
