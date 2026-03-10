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
8. [各数据库类型功能对照表](#8-各数据库类型功能对照表)
9. [常见问题](#9-常见问题)
10. [变更文件速览](#10-变更文件速览)

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
| SQLAlchemy 方言名称 | `kingbase8` |
| 连接驱动 | `kingbase8+psycopg2`（KingbaseES 官方提供） |
| 默认端口 | `54321` |
| 默认超级用户 | `system` |
| 默认密码 | `manager` |

由于 KingbaseES 与 PostgreSQL 的高度兼容性，所有涉及 PostgreSQL 的方言分支均可直接复用，无需单独实现。

---

## 3. 安装依赖

KingbaseES 的 SQLAlchemy 驱动 `kingbase8` 由人大金仓官方提供，**不在 PyPI 公共仓库**，需从官方渠道获取后手动安装：

```bash
# 方式一：本地 wheel 包安装（官方提供）
pip install kingbase8-<version>-py3-none-any.whl

# 方式二：若官方提供了私有 PyPI 源
pip install kingbase8 --index-url https://your-kingbase-pypi-mirror/simple/
```

> **说明**：`psycopg2-binary` 已包含在 Dify 的主依赖中（见 `api/pyproject.toml`），无需额外安装 PostgreSQL 驱动。

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
kingbase8+psycopg2://system:manager@your-kingbasees-host:54321/dify
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
        return "kingbase8+psycopg2"
    else:
        return "mysql+pymysql"
```

**说明**：
- `DB_TYPE=postgresql` → 方案头为 `postgresql`
- `DB_TYPE=kingbase`   → 方案头为 `kingbase8+psycopg2`（KingbaseES 官方 SQLAlchemy 方言）
- 其余（mysql/oceanbase/seekdb）→ 方案头为 `mysql+pymysql`（保持不变）

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
    assert config.SQLALCHEMY_DATABASE_URI_SCHEME == "kingbase8+psycopg2"
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

## 8. 各数据库类型功能对照表

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
| 连接 URI 前缀 | `postgresql://` | `kingbase8+psycopg2://` | `mysql+pymysql://` |
| `DB_TYPE` 配置值 | `postgresql` | `kingbase` | `mysql` / `oceanbase` / `seekdb` |

---

## 9. 常见问题

**Q1：为什么 `DB_TYPE` 用 `kingbase`，而 SQLAlchemy 方言名是 `kingbase8`？**

> `DB_TYPE` 是 Dify 的配置层抽象，使用简洁的别名 `kingbase`。SQLAlchemy 方言名 `kingbase8` 由 KingbaseES 官方驱动定义，对应 KingbaseES V8 版本。两者之间通过 `SQLALCHEMY_DATABASE_URI_SCHEME` 属性进行映射，开发者无需关心内部方言细节。

**Q2：能否使用 `psycopg2` 直接连接 KingbaseES？**

> 不推荐。KingbaseES 虽然兼容 psycopg2 的部分连接协议，但官方推荐使用 `kingbase8` 驱动以获得最佳兼容性和功能支持（特别是 KingbaseES 特有的扩展功能）。

**Q3：现有的 PostgreSQL 数据能否迁移到 KingbaseES？**

> 可以。KingbaseES 官方提供基于 `pg_dump` / `pg_restore` 的迁移工具链，并支持直接导入 PostgreSQL 的 dump 文件。具体步骤见 [第 7.2 节](#72-从-postgresql-迁移至-kingbasees)。

**Q4：KingbaseES 的 `psycopg2` 驱动与标准 `psycopg2-binary` 有何区别？**

> KingbaseES `kingbase8` 驱动内部使用与 psycopg2 协议兼容的连接器，但针对 KingbaseES 的特性进行了优化。Dify 依赖中已包含 `psycopg2-binary`（用于 PostgreSQL），在安装 `kingbase8` 驱动时请勿卸载 `psycopg2-binary`，两者可共存。

**Q5：`DB_EXTRAS` 参数在 KingbaseES 下如何使用？**

> 与 PostgreSQL 完全相同，支持传入 PostgreSQL 风格的 `options` 参数，例如：
> ```
> DB_EXTRAS=options=-c search_path=myschema
> ```
> Dify 会自动将其与默认的 `timezone=UTC` 参数合并。

---

## 10. 变更文件速览

| 文件路径 | 改动类型 | 关键内容 |
|---------|---------|---------|
| `api/configs/middleware/__init__.py` | 修改 | 新增 `kingbase` 到 `DB_TYPE` 枚举；新增 `kingbase8+psycopg2` URI 方案；引擎选项支持 KingbaseES |
| `api/models/types.py` | 修改 | `StringUUID`、`LongText`、`BinaryData`、`AdjustedJSON`、`adjusted_json_index` 均新增 `kingbase8` 方言支持 |
| `api/libs/helper.py` | 修改 | `convert_datetime_to_date` 函数新增 `kingbase` 支持（复用 PostgreSQL 语法） |
| `api/services/conversation_service.py` | 修改 | 会话变量 JSON 过滤查询新增 `kingbase` 分支（复用 `json_extract_path_text`） |
| `api/services/workflow_draft_variable_service.py` | 修改 | 批量 Upsert 判断条件新增 `kingbase8` 方言（复用 `pg_insert`） |
| `api/controllers/console/datasets/datasets_segments.py` | 修改 | 知识库分段关键词搜索新增 `kingbase8` 分支（复用 JSONB 路径查询） |
| `api/tests/unit_tests/configs/test_dify_config.py` | 修改 | 新增 `test_kingbase_db_type_config` 和 `test_kingbase_db_extras_options_merging` 测试用例 |

---

*文档生成时间：2026-03-10*
*对应 commit：`feat: add KingbaseES (kingbase8) database compatibility support`*
