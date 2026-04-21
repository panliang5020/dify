# Python / Go Backend-Dev — Specialist Agent Guide

> **Scope**: This guide is the single authoritative reference for any agent working on Python or Go backend code.  
> Read it completely before touching backend files.

---

## 0. Quick-Start Checklist

Before writing a single line of code, confirm you have done all of the following:

- [ ] Read the surrounding module/class/function docstrings in the area you will touch.
- [ ] Verified the layered architecture boundaries you must respect.
- [ ] Understood how tests are run (`make test` / `go test ./...`).
- [ ] Confirmed you are not starting any long-running service processes.

---

## 1. Repository Orientation

| Layer | Directory | Runtime |
|---|---|---|
| HTTP controllers / routes | `api/controllers/` | Python / Flask |
| Domain services | `api/services/` | Python |
| Core domain / models | `api/core/` | Python |
| Async tasks | `api/tasks/` | Celery / Redis |
| Database models | `api/models/` | SQLAlchemy |
| Go services (if present) | `*/cmd/`, `*/internal/` | Go |

Layered flow (must not be violated):

```
HTTP handler / controller
    ↓  (DTO validation)
Service layer
    ↓  (domain logic)
Core / Domain
    ↓  (persistence)
Repository / Model
```

---

## 2. Before You Start Working

1. **Read all docstrings** in the files you will modify. They encode invariants, edge cases, and trade-offs that are part of the spec.
2. If a docstring conflicts with code, **the code wins**; update the docstring to match reality.
3. Add missing docstrings only when the intent or invariant is genuinely non-obvious.

---

## 3. Python Coding Standards

### 3.1 Formatting & Linting

```bash
make format       # Ruff auto-format
make lint         # Ruff lint + auto-fix
make type-check   # basedpyright / mypy
make test         # pytest unit suite
```

- Use **Ruff** (configured in `.ruff.toml`); line limit **120 characters**.
- Never commit with lint or type errors.
- CI runs `make lint && make type-check && make test`; all must pass.

### 3.2 Naming

| Construct | Convention |
|---|---|
| Variables / functions | `snake_case` |
| Classes | `PascalCase` |
| Constants / enums | `UPPER_CASE` |
| Private helpers | `_leading_underscore` |

### 3.3 Type Annotations

- Every public function and method **must** have full type annotations.
- Prefer modern forms: `list[str]`, `dict[str, int]`, `str | None`.
- Avoid `Any`; if unavoidable, add a comment explaining why.
- Use `TypedDict` for structured dictionaries with known keys:

```python
from typing import NotRequired, TypedDict

class CreateWorkflowPayload(TypedDict):
    name: str
    tenant_id: str
    description: NotRequired[str]
```

- Use `NotRequired[...]` (or `total=False`) for optional fields.
- Keep `dict[str, ...]` / `Mapping[str, ...]` only for truly dynamic key spaces.

### 3.4 Class Layout

Declare **all member variables with types at the top** of the class body:

```python
from datetime import datetime


class WorkflowExecution:
    workflow_id: str
    tenant_id: str
    started_at: datetime
    status: str

    def __init__(self, workflow_id: str, tenant_id: str, started_at: datetime) -> None:
        self.workflow_id = workflow_id
        self.tenant_id = tenant_id
        self.started_at = started_at
        self.status = "pending"
```

- Implement `__repr__` and `__str__` when the class is a domain object.
- Avoid unnecessary dunder methods.

### 3.5 Pydantic v2 (DTOs & Config)

- All request/response DTOs use **Pydantic v2** with `extra="forbid"`.
- Use `@field_validator` / `@model_validator` for domain constraints.
- Never access `.dict()` (deprecated); use `.model_dump()`.

```python
from pydantic import BaseModel, ConfigDict, field_validator


class TriggerConfig(BaseModel):
    endpoint: str
    secret: str

    model_config = ConfigDict(extra="forbid")

    @field_validator("secret")
    @classmethod
    def ensure_prefix(cls, v: str) -> str:
        if not v.startswith("dify_"):
            raise ValueError("secret must start with 'dify_'")
        return v
```

### 3.6 Protocols & Generics

- Use `typing.Protocol` to define behavioural contracts (cache, storage, provider interfaces).
- Apply `TypeVar` + `Generic[T]` for reusable utilities (caches, repositories).
- Validate dynamic inputs at runtime when generics alone cannot enforce safety.

### 3.7 Logging & Errors

```python
import logging

logger = logging.getLogger(__name__)
```

- **Never** use `print`; always use the module-level logger.
- Include `tenant_id`, `app_id`, `workflow_id` in log messages where relevant.
- Log retryable events at `WARNING`, terminal failures at `ERROR`.
- Raise **domain-specific exceptions** (`services/errors`, `core/errors`).
- Translate domain exceptions into HTTP responses **only in controllers** — never deeper.

### 3.8 SQLAlchemy Patterns

- Models inherit from `models.base.TypeBase`.
- Always open sessions with context managers:

```python
from sqlalchemy.orm import Session

with Session(db.engine, expire_on_commit=False) as session:
    stmt = select(Workflow).where(
        Workflow.id == workflow_id,
        Workflow.tenant_id == tenant_id,   # Always scope by tenant
    )
    workflow = session.execute(stmt).scalar_one_or_none()
```

- Prefer **SQLAlchemy expressions** over raw SQL.
- Always scope queries with `tenant_id`; never expose cross-tenant data.
- Use `SELECT … FOR UPDATE` on write paths that require row-level locking.
- Add repository abstractions only for very large tables or when alternative storage is required.

### 3.9 Async Tasks (Celery)

- Queue async work via `services/async_workflow_service`.
- Implement task handlers under `tasks/` with explicit queue selection.
- Tasks **must be idempotent** — assume they can be retried.
- Log relevant object identifiers at task start and completion.

### 3.10 Storage & External I/O

- Access object storage via `extensions.ext_storage.storage`.
- All outbound HTTP calls must go through `core.helper.ssrf_proxy` (SSRF protection).
- Never make raw `urllib` / `requests` calls directly to external hosts.

### 3.11 Configuration

- Read all config via `configs.dify_config` — **never** read `os.environ` directly.
- Maintain `tenant_id` end-to-end through every layer that touches shared resources.

### 3.12 Controllers vs Services

| Layer | Responsibility |
|---|---|
| **Controller** | Parse + validate input (Pydantic), call service, serialise response. Zero business logic. |
| **Service** | Coordinate domain objects, repositories, tasks. Side effects must be explicit and documented. |
| **Core/Domain** | Pure business logic, no framework dependencies. |

### 3.13 General Rules

- Keep files **≤ 800 lines**; split when necessary.
- Prefer **simple functions** over utility classes for lightweight helpers.
- Reuse existing helpers in `core/`, `services/`, `libs/` before creating new abstractions.
- Experimental scripts go under `dev/`; never ship them in production builds.
- Never start long-running services (`flask run`, `uv run app.py`) as part of agent work.

---

## 4. Go Coding Standards

### 4.1 Project Layout (Standard)

```
cmd/
  server/main.go        # entry point; only wires deps and starts server
internal/
  domain/               # pure domain types, interfaces, business rules
  service/              # use-case orchestration
  repository/           # persistence adapters (DB, cache)
  handler/              # HTTP / gRPC handlers (thin, parse → service → respond)
  middleware/           # auth, logging, tracing middleware
pkg/                    # shared, importable packages
configs/                # config structs loaded at startup
```

### 4.2 Formatting & Linting

```bash
go fmt ./...            # standard formatting
go vet ./...            # static analysis
golangci-lint run       # full lint suite (configured in .golangci.yml)
go test ./...           # full test suite
go test -race ./...     # race detector (mandatory before PR)
```

### 4.3 Naming

| Construct | Convention |
|---|---|
| Packages | `lowercase`, single noun (`user`, `workflow`) |
| Exported symbols | `PascalCase` |
| Unexported symbols | `camelCase` |
| Interfaces | Describe behaviour: `Reader`, `WorkflowRunner`, `TokenProvider` |
| Error types | `ErrXxx` (sentinel) or `XxxError` (struct) |
| Test files | `*_test.go`; test funcs `TestXxx(t *testing.T)` |

### 4.4 Error Handling

- **Always** handle errors explicitly; never `_` away a non-trivial error.
- Wrap errors with context: `fmt.Errorf("create workflow: %w", err)`.
- Define domain sentinel errors at the package level:

```go
var (
    ErrWorkflowNotFound = errors.New("workflow not found")
    ErrTenantMismatch   = errors.New("tenant mismatch")
)
```

- Translate errors to HTTP status codes **only in handlers** — never deeper.
- Use `errors.Is` / `errors.As` to inspect wrapped errors.

### 4.5 Interfaces & Dependency Injection

- Define interfaces **at the consumer site** (not the producer):

```go
// internal/service/workflow.go
type WorkflowRepository interface {
    FindByID(ctx context.Context, id string) (*domain.Workflow, error)
    Save(ctx context.Context, wf *domain.Workflow) error
}

type WorkflowService struct {
    repo WorkflowRepository
}

func NewWorkflowService(repo WorkflowRepository) *WorkflowService {
    return &WorkflowService{repo: repo}
}
```

- Accept interfaces, return concrete types.
- Inject all dependencies through constructors; avoid global state.

### 4.6 Context & Cancellation

- Pass `context.Context` as the **first argument** to every function that does I/O.
- Respect context cancellation: check `ctx.Err()` in loops, propagate to downstream calls.
- Never store a context in a struct; pass it per-call.
- Add tenant/trace IDs to context using typed keys (never raw `string` keys):

```go
type contextKey string
const tenantIDKey contextKey = "tenant_id"

func WithTenantID(ctx context.Context, id string) context.Context {
    return context.WithValue(ctx, tenantIDKey, id)
}
```

### 4.7 Concurrency

- Prefer channels and goroutines for fan-out; avoid shared mutable state.
- Use `sync.Mutex` / `sync.RWMutex` only when channels are impractical.
- Always run tests with `-race`; fix every race condition before merging.
- Use `errgroup.Group` for parallel fan-out with error propagation:

```go
g, gctx := errgroup.WithContext(ctx)
g.Go(func() error { return doA(gctx) })
g.Go(func() error { return doB(gctx) })
if err := g.Wait(); err != nil {
    return err
}
```

### 4.8 Logging

- Use a structured logger (e.g., `log/slog` stdlib, `zap`, or `zerolog`).
- Log key-value pairs: `logger.Info("workflow created", "workflow_id", id, "tenant_id", tenantID)`.
- Never use `fmt.Println` in production code.
- Log at `Info` for normal events, `Warn` for retryable failures, `Error` for terminal failures.

### 4.9 HTTP Handlers

- Handlers are thin: parse input → call service → write response.
- Validate request payloads early; return `400` with a clear message on invalid input.
- Never put business logic in handlers.
- Use middleware for cross-cutting concerns (auth, rate-limiting, tracing).

### 4.10 Database (Go)

- Scope every query by `tenant_id`; treat missing `tenant_id` as a programming error.
- Use parameterised queries; **never** format SQL with `fmt.Sprintf`.
- Prefer `database/sql` with `pgx` driver or `sqlc`-generated code over ORMs for complex queries.
- Wrap related DB operations in explicit transactions:

```go
tx, err := db.BeginTx(ctx, nil)
if err != nil { return err }
defer tx.Rollback()
// ... operations ...
return tx.Commit()
```

### 4.11 Testing (Go)

- Table-driven tests for all non-trivial logic:

```go
func TestCreateWorkflow(t *testing.T) {
    cases := []struct {
        name    string
        input   CreateInput
        wantErr bool
    }{
        {"valid input", CreateInput{Name: "test"}, false},
        {"empty name", CreateInput{}, true},
    }
    for _, tc := range cases {
        t.Run(tc.name, func(t *testing.T) {
            // Arrange, Act, Assert
        })
    }
}
```

- Use `testify/assert` or stdlib `testing`; avoid heavy test frameworks.
- Mock interfaces with `mockery` or hand-written fakes; never mock concrete types.
- Integration tests live in `*_integration_test.go` files with a build tag:
  ```go
  //go:build integration
  ```

---

## 5. Security Standards (Python & Go)

| Concern | Rule |
|---|---|
| **SQL injection** | Always use parameterised queries / ORM expressions. |
| **SSRF** | Route all outbound HTTP via `ssrf_proxy` (Python) or an allowlist middleware (Go). |
| **Secrets in code** | Zero tolerance — use environment/config; fail CI with secret scanners. |
| **Tenant isolation** | Every query scoped by `tenant_id`; cross-tenant access is a critical bug. |
| **Input validation** | Validate at the API boundary (Pydantic / handler); reject unknowns. |
| **Auth** | Auth enforcement in middleware/controller; never deep in domain code. |
| **Sensitive logs** | Never log credentials, tokens, or PII. |

---

## 6. Observability

- **Structured logging**: key-value pairs, consistent field names (`tenant_id`, `workflow_id`, `app_id`, `duration_ms`, `error`).
- **Tracing**: propagate trace/span IDs from inbound requests through all downstream calls.
- **Metrics**: expose counters and histograms for key operations (request rate, error rate, latency).
- **Health checks**: expose `/healthz` (liveness) and `/readyz` (readiness) endpoints.
- **Error context**: include enough identifiers in error messages to reproduce the issue from logs alone.

---

## 7. Testing Standards

### Arrange-Act-Assert (AAA)

```python
def test_create_workflow_raises_on_duplicate_name():
    # Arrange
    repo = FakeWorkflowRepository(existing=["my-workflow"])
    service = WorkflowService(repo)

    # Act & Assert
    with pytest.raises(DuplicateWorkflowError):
        service.create(tenant_id="t1", name="my-workflow")
```

### Rules

- Unit tests must run in **< 1 second** each with zero external I/O.
- Integration tests are CI-only; tag them appropriately (Go build tags / pytest markers).
- Aim for **100% branch coverage** on domain/service layers; controllers and I/O adapters can use integration tests.
- Tests are part of the spec — do not delete or weaken them.
- Use factories / builders for test fixtures; avoid large `setUp` blobs.

---

## 8. Documentation Standards

### What to document

| Location | What to write |
|---|---|
| **Module / file docstring** | Purpose, boundaries, key invariants, cross-links to collaborators. |
| **Class docstring** | Responsibility, lifecycle, concurrency assumptions, how (not) to use. |
| **Function / method docstring** | Args, return type, side effects (DB, I/O, task dispatch), raised exceptions. |
| **Inline comment** | *Why*, not *what* — trade-offs, historical constraints, surprising edge cases. |

### Rules

- Keep docstrings **coherent**: integrate findings; never append changelog entries.
- Delete or rewrite stale comments immediately.
- Code is truth; docstrings describe the *intent* and *contract*, not an alternative description of the code.

---

## 9. Git & PR Hygiene

- Commits must be **atomic**: one logical change per commit.
- Commit messages: imperative mood, ≤ 72 chars subject line.
  - Good: `Add tenant-scoped workflow deletion`
  - Bad: `fixed stuff` / `WIP`
- PR description must explain *what* and *why*, not just *what*.
- No secrets, credentials, or PII in commits.
- All CI checks (`lint`, `type-check`, `test`) must pass before requesting review.

---

## 10. Architecture Anti-Patterns (Do Not Do)

| Anti-pattern | Why it's harmful |
|---|---|
| Business logic in controllers/handlers | Untestable, mixes concerns |
| Direct `os.environ` / `os.Getenv` in business code | Bypasses config validation, hard to test |
| Cross-layer exceptions leaking | Exposes internals, breaks encapsulation |
| Unscoped DB queries (no `tenant_id`) | Data leak, critical security bug |
| Raw SQL with string formatting | SQL injection vector |
| Outbound HTTP without SSRF proxy | SSRF vulnerability |
| Mutable global state / singletons | Race conditions, test pollution |
| `print` / `fmt.Println` in production code | Unstructured, unfiltered output |
| Files > 800 lines | Hard to navigate and review |
| Importing `internal/` packages from outside | Violates Go module boundaries |

---

## 11. Quick-Reference Commands

### Python (Dify API)

```bash
uv run --project api pytest                         # all unit tests
uv run --project api pytest tests/unit_tests/       # unit tests only
make format                                          # format
make lint                                            # lint + auto-fix
make type-check                                      # basedpyright
make test                                            # full test suite
```

### Go

```bash
go fmt ./...            # format
go vet ./...            # vet
golangci-lint run       # full lint
go test ./...           # unit tests
go test -race ./...     # race-condition detection
go test -tags=integration ./...  # integration tests
```

---

*This guide is a living document. Update it when you discover new invariants, change architecture decisions, or add new tooling. Keep it accurate — it is the first thing the next agent will read.*
