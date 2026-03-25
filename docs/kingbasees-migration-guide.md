# Dify 接入人大金仓 KingbaseES 数据库 —— 迁移改造完整说明

> **版本**：本文档对应 PR `feat: add KingbaseES (kingbase8) database compatibility support`
> **适用范围**：Dify API 后端（`/api` 目录）
> **文档语言**：简体中文

---

## 目录

1. [背景与目标](#1-背景与目标)
2. [KingbaseES 技术特性说明](#2-kingbasees-技术特性说明)
3. [安装依赖](#3-安装依赖)
4. [环境变量配置](#4-环境变量配置)
5. [代码改动详解](#5-代码改动详解)
   - 5.1 [数据库类型枚举与连接配置](#51-数据库类型枚举与连接配置)
   - 5.2 [ORM 自定义类型（TypeDecorator）](#52-orm-自定义类型typedecorator)
   - 5.3 [日期时间辅助函数](#53-日期时间辅助函数)
   - 5.4 [会话变量服务 JSON 查询](#54-会话变量服务-json-查询)
   - 5.5 [工作流草稿变量批量 Upsert](#55-工作流草稿变量批量-upsert)
   - 5.6 [知识库分段关键词搜索](#56-知识库分段关键词搜索)
6. [单元测试](#6-单元测试)
7. [数据库迁移（Alembic）注意事项](#7-数据库迁移alembic注意事项)
8. [Docker Compose 部署配置](#8-docker-compose-部署配置)
   - 8.4 [单容器快速验证（连通性测试）](#84-单容器快速验证连通性测试)
9. [各数据库类型功能对照表](#9-各数据库类型功能对照表)
10. [常见问题](#10-常见问题)
11. [变更文件速览](#11-变更文件速览)

---

## 1. 背景与目标

Dify 原生支持 PostgreSQL、MySQL、OceanBase、SeekDB 四种事务数据库。本次改造在此基础上新增对 **人大金仓 KingbaseES V8**（以下简称 KingbaseES）的完整支持，使其能够与 PostgreSQL 一样无缝融入 Dify 项目，所有功能特性保持完全一致。

**目标**：设置 `DB_TYPE=kingbase` 后，Dify 即可使用 KingbaseES 作为事务数据库，无需对业务代码做任何额外改动。

---

## 2. KingbaseES 技术特性说明

| 特性 | 说明 |
|------|------|
| 内核 | 基于 PostgreSQL 核心深度定制 |
| SQL 兼容性 | 高度兼容 PostgreSQL SQL 语法 |
| 数据类型 | 支持 `UUID`、`JSONB`、`BYTEA`、`TEXT`、`GIN` 索引等 PostgreSQL 原生类型 |
| **Python DBAPI 驱动包** | `ksycopg2`（官方提供，用于直接连接数据库） |
| **SQLAlchemy 方言包** | `kingbase8`（官方提供，将 `ksycopg2` 封装为 SQLAlchemy 方言） |
| SQLAlchemy URI 前缀 | `kingbase8+ksycopg2://` |
| 默认端口 | `54321` |
| 默认超级用户 | `system` |
| 默认密码 | `manager` |

### 连接层次说明

KingbaseES 的连接栈分为两层，理解这一点有助于区分官方测试用例与 Dify 的用法：

```
┌─────────────────────────────────────────────────────────┐
│  应用层                                                  │
│                                                          │
│  Dify（使用 SQLAlchemy ORM）                             │
│      ↓ SQLAlchemy URI: kingbase8+ksycopg2://...          │
│  kingbase8（SQLAlchemy 方言包，pip install kingbase8）    │
│      ↓ 内部调用                                          │
│  ksycopg2（Python DBAPI 驱动，pip install ksycopg2）     │
│      ↓ 网络连接                                          │
│  KingbaseES 数据库服务器                                  │
│                                                          │
│  独立脚本（不使用 SQLAlchemy）                            │
│      ↓ 直接调用 DBAPI                                    │
│  ksycopg2.connect(host=..., port=..., ...)               │
│      ↓ 网络连接                                          │
│  KingbaseES 数据库服务器                                  │
└─────────────────────────────────────────────────────────┘
```

**选择哪种方式？**
- **Dify 项目**：必须使用 SQLAlchemy URI 方式（`kingbase8+ksycopg2://`），因为 Dify 的整个数据库访问层（模型、迁移、查询）都通过 SQLAlchemy ORM 实现。
- **独立 Python 脚本**：可以直接使用 `ksycopg2.connect()` 进行底层操作，官方测试用例即属于此类。

由于 KingbaseES 与 PostgreSQL 的高度兼容性，所有涉及 PostgreSQL 的方言分支均可直接复用，无需单独实现。

---

## 3. 安装依赖

KingbaseES 需要安装**两个**官方包，均由人大金仓提供，**不在 PyPI 公共仓库**，需从官方渠道获取后手动安装：

| 包名 | 作用 | 用于 |
|------|------|------|
| `ksycopg2` | Python DBAPI 驱动（底层数据库连接） | 所有 Python 程序 |
| `kingbase8` | SQLAlchemy 方言（封装 `ksycopg2`） | Dify（SQLAlchemy 项目） |

```bash
# 步骤一：安装 Python DBAPI 驱动（ksycopg2）
# 方式一：本地 wheel 包安装（官方提供）
pip install ksycopg2-<version>-py3-none-any.whl

# 步骤二：安装 SQLAlchemy 方言包（kingbase8）
# 方式一：本地 wheel 包安装（官方提供）
pip install kingbase8-<version>-py3-none-any.whl

# 若官方提供了私有 PyPI 源，可合并为一步：
pip install ksycopg2 kingbase8 --index-url https://your-kingbase-pypi-mirror/simple/
```

> **说明**：`ksycopg2` 是底层 DBAPI 驱动（类比 PostgreSQL 的 `psycopg2`），`kingbase8` 是 SQLAlchemy 方言包（将 `ksycopg2` 适配为 SQLAlchemy 可用的数据库后端）。Dify 通过 SQLAlchemy 访问数据库，因此需要**两个包都安装**。安装时无需卸载已有的 `psycopg2-binary`，多个驱动包可共存。

---

## 4. 环境变量配置

在 `.env` 文件（或容器环境变量）中配置如下参数：

```dotenv
# 数据库类型：设置为 kingbase 以使用 KingbaseES
DB_TYPE=kingbase

# 数据库服务器地址
DB_HOST=your-kingbasees-host

# 数据库端口（KingbaseES 默认端口为 54321）
DB_PORT=54321

# 数据库用户名（KingbaseES 默认超级用户为 system）
DB_USERNAME=system

# 数据库密码（KingbaseES 默认密码为 manager）
DB_PASSWORD=manager

# 数据库名称
DB_DATABASE=dify

# 可选：额外连接参数，与 PostgreSQL 用法一致
# DB_EXTRAS=options=-c search_path=myschema

# 可选：连接字符集（留空即可，KingbaseES 默认 UTF-8）
# DB_CHARSET=
```

配置完成后，Dify 将自动生成如下格式的 SQLAlchemy 连接 URI：

```
kingbase8+ksycopg2://system:manager@your-kingbasees-host:54321/dify
```

---

## 5. 代码改动详解

### 5.1 数据库类型枚举与连接配置

**文件**：`api/configs/middleware/__init__.py`

#### 5.1.1 `DB_TYPE` 枚举扩展

```python
# 改动前
DB_TYPE: Literal["postgresql", "mysql", "oceanbase", "seekdb"] = Field(
    description="Database type to use. OceanBase is MySQL-compatible.",
    default="postgresql",
)

# 改动后
DB_TYPE: Literal["postgresql", "mysql", "oceanbase", "seekdb", "kingbase"] = Field(
    description="Database type to use. OceanBase and SeekDB are MySQL-compatible. KingbaseES is PostgreSQL-compatible.",
    default="postgresql",
)
```

**说明**：在 `Literal` 类型约束中新增 `"kingbase"` 选项，同时更新字段描述，明确说明各数据库的兼容关系。

---

#### 5.1.2 `SQLALCHEMY_DATABASE_URI_SCHEME` 属性

```python
# 改动前
@computed_field
@property
def SQLALCHEMY_DATABASE_URI_SCHEME(self) -> str:
    return "postgresql" if self.DB_TYPE == "postgresql" else "mysql+pymysql"

# 改动后
@computed_field
@property
def SQLALCHEMY_DATABASE_URI_SCHEME(self) -> str:
    if self.DB_TYPE == "postgresql":
        return "postgresql"
    elif self.DB_TYPE == "kingbase":
        return "kingbase8+ksycopg2"
    else:
        return "mysql+pymysql"
```

**说明**：
- `DB_TYPE=postgresql` → 方案头为 `postgresql`
- `DB_TYPE=kingbase`   → 方案头为 `kingbase8+ksycopg2`（SQLAlchemy 格式为 `dialect+driver`：`kingbase8` 是 SQLAlchemy 方言包，`ksycopg2` 是底层 DBAPI 驱动包）
- 其余（mysql/oceanbase/seekdb）→ 方案头为 `mysql+pymysql`（保持不变）

> **注意**：SQLAlchemy URI 中的 `+ksycopg2` 与直接调用 `ksycopg2.connect()` 的关系：两者都使用同一个 `ksycopg2` 驱动包，只是调用层次不同——SQLAlchemy 在内部会通过 `kingbase8` 方言自动调用 `ksycopg2`，开发者无需手动操作。详见 [第 10 节 Q6](#10-常见问题)。

---

#### 5.1.3 `SQLALCHEMY_ENGINE_OPTIONS` 属性

```python
# 改动前
if self.SQLALCHEMY_DATABASE_URI_SCHEME.startswith("postgresql"):
    # 添加 timezone=UTC 的连接参数

# 改动后
if self.SQLALCHEMY_DATABASE_URI_SCHEME.startswith(("postgresql", "kingbase8")):
    # 添加 timezone=UTC 的连接参数
```

**说明**：KingbaseES 兼容 PostgreSQL 的 `options` 连接参数，因此与 PostgreSQL 一样需要设置 `-c timezone=UTC` 以保证时区一致性。通过 `startswith(("postgresql", "kingbase8"))` 同时匹配两种方言。

---

### 5.2 ORM 自定义类型（TypeDecorator）

**文件**：`api/models/types.py`

Dify 使用 SQLAlchemy `TypeDecorator` 机制为不同数据库方言提供最优的原生类型。KingbaseES 基于 PostgreSQL 内核，其方言名称为 `kingbase8`，所有类型映射与 PostgreSQL 完全相同。

#### 5.2.1 `StringUUID` —— UUID 类型

```python
# process_bind_param 改动前
elif dialect.name in ["postgresql", "mysql"]:
    return str(value)

# process_bind_param 改动后
elif dialect.name in ["postgresql", "mysql", "kingbase8"]:
    return str(value)

# load_dialect_impl 改动前
if dialect.name == "postgresql":
    return dialect.type_descriptor(UUID())   # 原生 UUID 类型

# load_dialect_impl 改动后
if dialect.name in ["postgresql", "kingbase8"]:
    return dialect.type_descriptor(UUID())   # 原生 UUID 类型
```

**说明**：KingbaseES 原生支持 `UUID` 类型（与 PostgreSQL 完全一致），无需降级为 `CHAR(36)` 字符串存储。

---

#### 5.2.2 `LongText` —— 大文本类型

```python
# 改动前
if dialect.name == "postgresql":
    return dialect.type_descriptor(TEXT())

# 改动后
if dialect.name in ["postgresql", "kingbase8"]:
    return dialect.type_descriptor(TEXT())    # KingbaseES 使用标准 TEXT，无需 LONGTEXT
```

**说明**：
- PostgreSQL / KingbaseES → `TEXT`（无长度上限限制）
- MySQL / OceanBase / SeekDB → `LONGTEXT`（最大 4GB）
- 其他 → `TEXT`（通用回退）

---

#### 5.2.3 `BinaryData` —— 二进制数据类型

```python
# 改动前
if dialect.name == "postgresql":
    return dialect.type_descriptor(BYTEA())

# 改动后
if dialect.name in ["postgresql", "kingbase8"]:
    return dialect.type_descriptor(BYTEA())   # KingbaseES 支持 PostgreSQL 原生 BYTEA
```

**说明**：
- PostgreSQL / KingbaseES → `BYTEA`
- MySQL / OceanBase / SeekDB → `LONGBLOB`
- 其他 → `LargeBinary`（通用回退）

---

#### 5.2.4 `AdjustedJSON` —— JSON 类型

```python
# 改动前
if dialect.name == "postgresql":
    return dialect.type_descriptor(JSONB())   # 二进制 JSON，支持 GIN 索引

# 改动后
if dialect.name in ["postgresql", "kingbase8"]:
    return dialect.type_descriptor(JSONB())   # KingbaseES 同样支持 JSONB
```

**说明**：
- PostgreSQL / KingbaseES → `JSONB`（二进制 JSON，存储紧凑、查询高效，支持 GIN 索引）
- MySQL / OceanBase / SeekDB → `JSON`（文本 JSON）
- 其他 → `JSON`（通用回退）

---

#### 5.2.5 `adjusted_json_index` —— JSON 字段 GIN 索引

```python
# 改动前
def adjusted_json_index(index_name, column_name):
    if dify_config.DB_TYPE == "postgresql":
        return sa.Index(index_name, column_name, postgresql_using="gin")
    else:
        return None

# 改动后
def adjusted_json_index(index_name, column_name):
    if dify_config.DB_TYPE in ["postgresql", "kingbase"]:
        return sa.Index(index_name, column_name, postgresql_using="gin")
    else:
        return None
```

**说明**：KingbaseES 支持 PostgreSQL `GIN` 索引，可为 JSONB 字段加速全文检索和包含查询。

> **注意**：此处使用 `dify_config.DB_TYPE`（配置值 `"kingbase"`），而非 SQLAlchemy 方言名称 `"kingbase8"`，与其他同类判断保持一致。

---

### 5.3 日期时间辅助函数

**文件**：`api/libs/helper.py`

```python
# 改动前
def convert_datetime_to_date(field, target_timezone: str = ":tz"):
    if dify_config.DB_TYPE == "postgresql":
        return f"DATE(DATE_TRUNC('day', {field} AT TIME ZONE 'UTC' AT TIME ZONE {target_timezone}))"
    elif dify_config.DB_TYPE in ["mysql", "oceanbase", "seekdb"]:
        return f"DATE(CONVERT_TZ({field}, 'UTC', {target_timezone}))"
    else:
        raise NotImplementedError(f"Unsupported database type: {dify_config.DB_TYPE}")

# 改动后
def convert_datetime_to_date(field, target_timezone: str = ":tz"):
    if dify_config.DB_TYPE in ["postgresql", "kingbase"]:
        return f"DATE(DATE_TRUNC('day', {field} AT TIME ZONE 'UTC' AT TIME ZONE {target_timezone}))"
    elif dify_config.DB_TYPE in ["mysql", "oceanbase", "seekdb"]:
        return f"DATE(CONVERT_TZ({field}, 'UTC', {target_timezone}))"
    else:
        raise NotImplementedError(f"Unsupported database type: {dify_config.DB_TYPE}")
```

**说明**：
- KingbaseES 完整支持 PostgreSQL 的 `DATE_TRUNC` 函数和 `AT TIME ZONE` 语法
- MySQL 系列使用 `CONVERT_TZ` 函数进行时区转换
- 若未识别数据库类型则抛出 `NotImplementedError`，避免静默错误

**使用场景**：该函数用于统计查询中将 UTC 时间戳按目标时区分组到日期维度（例如：消息量按天统计）。

---

### 5.4 会话变量服务 JSON 查询

**文件**：`api/services/conversation_service.py`

```python
# 改动前
elif dify_config.DB_TYPE == "postgresql":
    stmt = stmt.where(
        func.json_extract_path_text(ConversationVariable.data, "name").ilike(
            f"%{escaped_variable_name}%", escape="\\"
        )
    )

# 改动后
elif dify_config.DB_TYPE in ["postgresql", "kingbase"]:
    stmt = stmt.where(
        func.json_extract_path_text(ConversationVariable.data, "name").ilike(
            f"%{escaped_variable_name}%", escape="\\"
        )
    )
```

**说明**：KingbaseES 原生支持 PostgreSQL 的 `json_extract_path_text(column, 'key')` 函数，可直接从 JSONB 字段中提取文本值进行模糊匹配。

**两种方言的 JSON 提取函数对比**：

| 数据库 | JSON 提取函数 | 示例 |
|--------|--------------|------|
| PostgreSQL / KingbaseES | `json_extract_path_text(col, 'key')` | 直接返回文本 |
| MySQL / OceanBase / SeekDB | `json_extract(col, '$.key')` | 返回带引号的 JSON 字符串，需注意转义 |

---

### 5.5 工作流草稿变量批量 Upsert

**文件**：`api/services/workflow_draft_variable_service.py`

```python
# 改动前
if dify_config.SQLALCHEMY_DATABASE_URI_SCHEME == "postgresql":
    stmt = pg_insert(WorkflowDraftVariable).values(...)
    stmt = stmt.on_conflict_do_update(...)   # PostgreSQL UPSERT

# 改动后
if dify_config.SQLALCHEMY_DATABASE_URI_SCHEME.startswith(("postgresql", "kingbase8")):
    stmt = pg_insert(WorkflowDraftVariable).values(...)
    stmt = stmt.on_conflict_do_update(...)   # KingbaseES 同样支持此语法
```

**说明**：KingbaseES 完整支持 PostgreSQL 的 `INSERT ... ON CONFLICT DO UPDATE/NOTHING` 语法，因此直接复用 `sqlalchemy.dialects.postgresql.insert` 构造的批量 Upsert 语句。

**两种方言的 Upsert 语法对比**：

| 数据库 | Upsert 语法 | SQLAlchemy 方法 |
|--------|------------|-----------------|
| PostgreSQL / KingbaseES | `INSERT ... ON CONFLICT DO UPDATE SET ...` | `pg_insert().on_conflict_do_update()` |
| MySQL / OceanBase / SeekDB | `INSERT ... ON DUPLICATE KEY UPDATE ...` | `mysql_insert().on_duplicate_key_update()` |

---

### 5.6 知识库分段关键词搜索

**文件**：`api/controllers/console/datasets/datasets_segments.py`

```python
# 改动前
if dify_config.SQLALCHEMY_DATABASE_URI_SCHEME == "postgresql":
    keywords_condition = func.array_to_string(
        func.array(
            select(func.jsonb_array_elements_text(cast(DocumentSegment.keywords, JSONB)))
            .correlate(DocumentSegment)
            .scalar_subquery()
        ),
        ",",
    ).ilike(f"%{escaped_keyword}%", escape="\\")

# 改动后
if dify_config.SQLALCHEMY_DATABASE_URI_SCHEME.startswith(("postgresql", "kingbase8")):
    keywords_condition = func.array_to_string(
        func.array(
            select(func.jsonb_array_elements_text(cast(DocumentSegment.keywords, JSONB)))
            .correlate(DocumentSegment)
            .scalar_subquery()
        ),
        ",",
    ).ilike(f"%{escaped_keyword}%", escape="\\")
```

**说明**：KingbaseES 支持 PostgreSQL 的：
- `jsonb_array_elements_text()` — 将 JSONB 数组展开为文本行集合
- `array()` — 将行集合聚合为数组
- `array_to_string()` — 将数组拼接为字符串以供模糊匹配

此方案在处理包含中文字符的关键词时表现优于 MySQL 的 `CAST(col AS CHAR)` 方式，可正确处理 Unicode。

---

## 6. 单元测试

**文件**：`api/tests/unit_tests/configs/test_dify_config.py`

新增两个测试用例：

### 6.1 `test_kingbase_db_type_config`

```python
def test_kingbase_db_type_config(monkeypatch: pytest.MonkeyPatch):
    """验证 DB_TYPE=kingbase 时 URI 方案和引擎选项的正确性"""
    monkeypatch.setenv("DB_TYPE", "kingbase")
    monkeypatch.setenv("DB_USERNAME", "system")
    monkeypatch.setenv("DB_PASSWORD", "manager")
    monkeypatch.setenv("DB_HOST", "localhost")
    monkeypatch.setenv("DB_PORT", "54321")
    monkeypatch.setenv("DB_DATABASE", "dify")

    config = DifyConfig()

    # 验证连接方案
    assert config.SQLALCHEMY_DATABASE_URI_SCHEME == "kingbase8+ksycopg2"
    # 验证连接 URI 格式（敏感信息已脱敏）
    assert config.SQLALCHEMY_DATABASE_URI == "******localhost:54321/dify"
    # 验证 KingbaseES 使用与 PostgreSQL 相同的 timezone 连接参数
    engine_options = config.SQLALCHEMY_ENGINE_OPTIONS
    assert engine_options["connect_args"] == {"options": "-c timezone=UTC"}
```

### 6.2 `test_kingbase_db_extras_options_merging`

```python
def test_kingbase_db_extras_options_merging(monkeypatch: pytest.MonkeyPatch):
    """验证 KingbaseES 模式下 DB_EXTRAS 中的 options 能与默认 timezone 正确合并"""
    monkeypatch.setenv("DB_TYPE", "kingbase")
    monkeypatch.setenv("DB_USERNAME", "system")
    monkeypatch.setenv("DB_PASSWORD", "manager")
    monkeypatch.setenv("DB_HOST", "localhost")
    monkeypatch.setenv("DB_PORT", "54321")
    monkeypatch.setenv("DB_DATABASE", "dify")
    monkeypatch.setenv("DB_EXTRAS", "options=-c search_path=myschema")

    config = DifyConfig()

    engine_options = config.SQLALCHEMY_ENGINE_OPTIONS
    options = engine_options["connect_args"]["options"]
    # 验证用户自定义 options 与默认 timezone 选项均存在
    assert "search_path=myschema" in options
    assert "timezone=UTC" in options
```

**运行测试**：

```bash
cd api
uv run --project . python -m pytest tests/unit_tests/configs/test_dify_config.py -v --override-ini="addopts="
```

预期输出（18 个测试全部通过）：

```
tests/unit_tests/configs/test_dify_config.py::test_kingbase_db_type_config PASSED
tests/unit_tests/configs/test_dify_config.py::test_kingbase_db_extras_options_merging PASSED
======================== 18 passed in 0.68s ========================
```

---

## 7. 数据库迁移（Alembic）注意事项

Dify 使用 **Alembic**（通过 `flask-migrate` 集成）管理数据库 Schema 的版本迁移。

### 7.1 首次初始化（全新 KingbaseES 实例）

```bash
# 进入 api 目录
cd api

# 执行所有历史迁移，建立完整 Schema
DB_TYPE=kingbase \
DB_HOST=your-host \
DB_PORT=54321 \
DB_USERNAME=system \
DB_PASSWORD=manager \
DB_DATABASE=dify \
uv run --project . flask db upgrade
```

### 7.2 从 PostgreSQL 迁移至 KingbaseES

由于 KingbaseES 与 PostgreSQL 高度兼容，可使用 KingbaseES 官方提供的数据迁移工具（`ksql_dump` / `ksql_restore`）或标准 `pg_dump` / `pg_restore` 工具进行数据迁移：

```bash
# 1. 使用 pg_dump 从 PostgreSQL 导出数据（KingbaseES 可解析此格式）
pg_dump -h pg-host -U postgres -d dify -Fc -f dify_backup.dump

# 2. 使用 pg_restore 导入到 KingbaseES
pg_restore -h kb-host -p 54321 -U system -d dify dify_backup.dump

# 3. 验证迁移版本一致性
DB_TYPE=kingbase ... flask db current
```

### 7.3 迁移文件兼容性

现有 `api/migrations/versions/` 中的所有 Alembic 迁移文件均使用 `op.batch_alter_table()` 模式，兼容跨数据库操作，**无需为 KingbaseES 单独创建迁移文件**。

---

## 8. Docker Compose 部署配置

**文件**：`docker/docker-compose.yaml`

为了让 KingbaseES 能够通过 Docker Compose 与 Dify 一起部署，需要对 `docker/docker-compose.yaml` 进行以下修改。

### 8.1 新增 `db_kingbase` 服务

在 `db_mysql` 服务之后、`redis` 服务之前新增如下 `db_kingbase` 服务定义：

```yaml
  # The KingbaseES (人大金仓) database.
  # KingbaseES is a PostgreSQL-compatible database. The official Docker image must be
  # obtained from the KingbaseES vendor (https://www.kingbase.com.cn/).
  db_kingbase:
    image: ${KINGBASE_IMAGE:-kingbase/kingbase-ee:v008r006c008b0014}
    profiles:
      - kingbase
    restart: always
    environment:
      SYSTEM_PASSWORD: ${DB_PASSWORD:-difyai123456}
      DB: ${DB_DATABASE:-dify}
    volumes:
      - ./volumes/kingbase/data:/home/kingbase/userdata
    ports:
      - "${DB_PORT:-54321}:54321"
    healthcheck:
      test:
        [
          "CMD-SHELL",
          "ksql -U ${DB_USERNAME:-system} -d ${DB_DATABASE:-dify} -c 'SELECT 1;' > /dev/null 2>&1 || exit 1",
        ]
      interval: 5s
      timeout: 5s
      retries: 30
```

> **说明**：
> - KingbaseES 的 Docker 镜像 **不在 Docker Hub 公共仓库**，需从 [人大金仓官网](https://www.kingbase.com.cn/) 获取并推送到本地镜像仓库后使用。
> - 可通过环境变量 `KINGBASE_IMAGE` 覆盖默认镜像地址，以适配私有镜像仓库。
> - KingbaseES 默认端口为 `54321`，通过 `DB_PORT` 可以自定义宿主机映射端口。
> - 数据目录挂载到 `./volumes/kingbase/data`。

### 8.2 各服务 `depends_on` 新增 `db_kingbase`

在 `api`、`worker`、`worker_beat` 以及 `plugin_daemon` 这四个服务的 `depends_on` 节中，均添加：

```yaml
      db_kingbase:
        condition: service_healthy
        required: false
```

`required: false` 确保在未启用 `kingbase` profile 时，这些服务仍可正常启动。

### 8.3 启动方式

使用 KingbaseES 时，通过 `--profile kingbase` 激活对应服务，并在 `.env` 文件中配置数据库连接参数：

```bash
# 在 docker/ 目录下执行
DB_TYPE=kingbase \
DB_HOST=db_kingbase \
DB_PORT=54321 \
DB_USERNAME=system \
DB_PASSWORD=manager \
DB_DATABASE=dify \
KINGBASE_IMAGE=your-registry/kingbase-ee:v008r006c008b0014 \
docker compose --profile kingbase up -d
```

或将以上变量写入 `docker/.env` 文件后执行：

```bash
docker compose --profile kingbase up -d
```

### 8.4 单容器快速验证（连通性测试）

在将 KingbaseES 接入 Dify 完整环境之前，可以先用一条 `docker run` 命令启动一个**仅含数据库**的单容器，快速验证镜像可用性和网络连通性。这与 PostgreSQL 的验证流程完全对应：

**PostgreSQL 对比参考**

```bash
# PostgreSQL 单容器启动（官方 Docker Hub 镜像，无需额外获取）
docker run -d \
  --name dify-postgres-test \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=difyai123456 \
  -e POSTGRES_DB=dify \
  -p 5432:5432 \
  postgres:15-alpine
```

**KingbaseES 单容器启动**

```bash
# KingbaseES 单容器启动
# 注意：镜像需从人大金仓官方获取（https://www.kingbase.com.cn/），不在 Docker Hub 公共仓库。
# 若使用私有镜像仓库，将 kingbase/kingbase-ee:v008r006c008b0014 替换为实际地址。
docker run -d \
  --name dify-kingbase-test \
  -e SYSTEM_PASSWORD=difyai123456 \
  -e DB=dify \
  -p 54321:54321 \
  kingbase/kingbase-ee:v008r006c008b0014
```

> **参数说明**：
> | 参数 | KingbaseES | PostgreSQL 对应参数 |
> |------|-----------|-------------------|
> | `SYSTEM_PASSWORD` | 超级用户 `system` 的密码 | `POSTGRES_PASSWORD` |
> | `DB` | 自动创建的数据库名 | `POSTGRES_DB` |
> | 端口 | `54321`（KingbaseES 默认） | `5432`（PostgreSQL 默认） |

**等待容器就绪**

```bash
# 持续检查健康状态，直到 healthy（约 30～90 秒）
docker inspect --format='{{.State.Health.Status}}' dify-kingbase-test

# 或直接在容器内执行 SQL 验证
docker exec dify-kingbase-test ksql -U system -d dify -c "SELECT VERSION();"
```

**方式一：Python DBAPI 直连验证（官方测试脚本风格）**

适合验证 `ksycopg2` 驱动安装是否正确：

```python
import ksycopg2

conn = ksycopg2.connect(
    host="localhost",
    port=54321,
    user="system",
    password="difyai123456",
    database="dify",
)
cur = conn.cursor()
cur.execute("SELECT VERSION();")
print("KingbaseES version:", cur.fetchone()[0])
conn.close()
```

**方式二：SQLAlchemy 连接验证（Dify 生产用法）**

适合验证 `kingbase8` 方言包安装是否正确，与 Dify 实际使用方式完全一致：

```python
from sqlalchemy import create_engine, text

engine = create_engine(
    "kingbase8+ksycopg2://system:difyai123456@localhost:54321/dify",
    connect_args={"options": "-c timezone=UTC"},
)
with engine.connect() as conn:
    version = conn.execute(text("SELECT VERSION()")).scalar()
    print("KingbaseES version:", version)
```

两种方式均输出类似：

```
KingbaseES version: KingbaseES V8 (KingbaseES V008R006C008B0014 ...) on x86_64-pc-linux-gnu ...
```

**与 Dify 环境变量对应关系**

单容器测试通过后，将以下参数填入 Dify `.env` 即可直接接入：

```dotenv
DB_TYPE=kingbase
DB_HOST=localhost        # Docker Compose 部署时改为 db_kingbase
DB_PORT=54321
DB_USERNAME=system
DB_PASSWORD=difyai123456
DB_DATABASE=dify
```

**清理测试容器**

```bash
docker stop dify-kingbase-test && docker rm dify-kingbase-test
```

---

## 9. 各数据库类型功能对照表

| 功能点 | PostgreSQL | KingbaseES | MySQL / OceanBase / SeekDB |
|--------|:----------:|:----------:|:--------------------------:|
| UUID 原生类型 | ✅ UUID | ✅ UUID | ❌ CHAR(36) |
| 大文本类型 | ✅ TEXT | ✅ TEXT | ✅ LONGTEXT |
| 二进制类型 | ✅ BYTEA | ✅ BYTEA | ✅ LONGBLOB |
| JSON 类型 | ✅ JSONB | ✅ JSONB | ✅ JSON |
| GIN 索引 | ✅ | ✅ | ❌ |
| `DATE_TRUNC` | ✅ | ✅ | ❌ |
| `AT TIME ZONE` | ✅ | ✅ | ❌ |
| `json_extract_path_text` | ✅ | ✅ | ❌ |
| `jsonb_array_elements_text` | ✅ | ✅ | ❌ |
| `INSERT ON CONFLICT` | ✅ | ✅ | ❌（使用 `ON DUPLICATE KEY`） |
| `CONVERT_TZ` | ❌ | ❌ | ✅ |
| `json_extract('$.key')` | ❌ | ❌ | ✅ |
| SQLAlchemy 方言名 | `postgresql` | `kingbase8` | `mysql` |
| 连接 URI 前缀 | `postgresql://` | `kingbase8+ksycopg2://` | `mysql+pymysql://` |
| `DB_TYPE` 配置值 | `postgresql` | `kingbase` | `mysql` / `oceanbase` / `seekdb` |

---

## 10. 常见问题

**Q1：为什么 `DB_TYPE` 用 `kingbase`，而 SQLAlchemy 方言名是 `kingbase8`？**

> `DB_TYPE` 是 Dify 的配置层抽象，使用简洁的别名 `kingbase`。SQLAlchemy 方言名 `kingbase8` 由 KingbaseES 官方驱动定义，对应 KingbaseES V8 版本。两者之间通过 `SQLALCHEMY_DATABASE_URI_SCHEME` 属性进行映射，开发者无需关心内部方言细节。

**Q2：能否使用标准 `psycopg2` 直接连接 KingbaseES？**

> 不推荐。KingbaseES 官方提供专用 Python 驱动 `ksycopg2`，与标准 `psycopg2` 相互独立。请使用官方驱动以获得最佳兼容性和功能支持（特别是 KingbaseES 特有的扩展功能）。

**Q3：现有的 PostgreSQL 数据能否迁移到 KingbaseES？**

> 可以。KingbaseES 官方提供基于 `pg_dump` / `pg_restore` 的迁移工具链，并支持直接导入 PostgreSQL 的 dump 文件。具体步骤见 [第 7.2 节](#72-从-postgresql-迁移至-kingbasees)。

**Q4：`ksycopg2` 与标准 `psycopg2-binary` 有何区别？**

> `ksycopg2` 是人大金仓官方为 KingbaseES 提供的专用 Python 驱动，基于 psycopg2 协议进行了定制优化。Dify 依赖中已包含 `psycopg2-binary`（用于 PostgreSQL），安装 `ksycopg2` 时无需卸载 `psycopg2-binary`，两者可共存。

**Q5：`DB_EXTRAS` 参数在 KingbaseES 下如何使用？**

> 与 PostgreSQL 完全相同，支持传入 PostgreSQL 风格的 `options` 参数，例如：
> ```
> DB_EXTRAS=options=-c search_path=myschema
> ```
> Dify 会自动将其与默认的 `timezone=UTC` 参数合并。

**Q6：官方测试用例使用 `ksycopg2.connect()` 直接连接，而 Dify 文档使用 `kingbase8+ksycopg2://` URI，应该如何选择？**

> **这是两个不同场景下的两种用法，并非冲突，而是各司其职：**
>
> | 场景 | 连接方式 | 原因 |
> |------|----------|------|
> | 官方测试脚本、独立 Python 程序 | `ksycopg2.connect(host=..., port=..., ...)` | 直接使用 DBAPI 驱动，无需 SQLAlchemy |
> | **Dify 项目（本文档适用场景）** | `kingbase8+ksycopg2://` URI via SQLAlchemy | Dify 的 ORM、模型、迁移全部通过 SQLAlchemy 实现 |
>
> 官方 v8r6 测试脚本（`import ksycopg2; ksycopg2.connect(...)`）演示的是底层 DBAPI 的直接使用方式，适合用于验证驱动安装是否正确、数据库连通性测试等场景。
>
> Dify 使用 SQLAlchemy 作为 ORM 框架，所有数据库操作（建表、查询、迁移）都经过 SQLAlchemy。SQLAlchemy 通过 URI 中的 `dialect+driver` 格式（即 `kingbase8+ksycopg2`）来选择底层 DBAPI：
> - `kingbase8` — SQLAlchemy 方言包（`pip install kingbase8`）
> - `ksycopg2` — 底层 DBAPI 驱动（`pip install ksycopg2`）
>
> 两种连接方式最终都通过 `ksycopg2` 与 KingbaseES 服务器通信，只是调用层次不同。**在 Dify 中，只需按照文档配置环境变量，SQLAlchemy 会自动处理连接细节，无需手动调用 `ksycopg2.connect()`。**

---

## 11. 变更文件速览

| 文件路径 | 改动类型 | 关键内容 |
|---------|---------|---------|
| `api/configs/middleware/__init__.py` | 修改 | 新增 `kingbase` 到 `DB_TYPE` 枚举；新增 `kingbase8+ksycopg2` URI 方案；引擎选项支持 KingbaseES |
| `api/models/types.py` | 修改 | `StringUUID`、`LongText`、`BinaryData`、`AdjustedJSON`、`adjusted_json_index` 均新增 `kingbase8` 方言支持 |
| `api/libs/helper.py` | 修改 | `convert_datetime_to_date` 函数新增 `kingbase` 支持（复用 PostgreSQL 语法） |
| `api/services/conversation_service.py` | 修改 | 会话变量 JSON 过滤查询新增 `kingbase` 分支（复用 `json_extract_path_text`） |
| `api/services/workflow_draft_variable_service.py` | 修改 | 批量 Upsert 判断条件新增 `kingbase8` 方言（复用 `pg_insert`） |
| `api/controllers/console/datasets/datasets_segments.py` | 修改 | 知识库分段关键词搜索新增 `kingbase8` 分支（复用 JSONB 路径查询） |
| `api/tests/unit_tests/configs/test_dify_config.py` | 修改 | 新增 `test_kingbase_db_type_config` 和 `test_kingbase_db_extras_options_merging` 测试用例 |
| `docker/docker-compose.yaml` | 修改 | 新增 `db_kingbase` 服务（`kingbase` profile）；在 `api`、`worker`、`worker_beat`、`plugin_daemon` 的 `depends_on` 中新增 `db_kingbase` |

---

*文档生成时间：2026-03-10*
*对应 commit：`feat: add KingbaseES (kingbase8) database compatibility support`*
