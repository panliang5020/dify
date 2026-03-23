#!/usr/bin/env bash
# ==============================================================================
# Dify Kubernetes 部署快速启动脚本
# 使用前请先阅读 kubernetes/README.md 完整文档
# ==============================================================================

set -euo pipefail

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
  echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
  exit 1
}

# ==============================================================================
# 配置区域 - 请在部署前修改以下变量
# ==============================================================================

DOMAIN="${DIFY_DOMAIN:-REPLACE-YOUR-DOMAIN.example.com}"
NAMESPACE="${DIFY_NAMESPACE:-dify}"
DIFY_VERSION="${DIFY_VERSION:-1.13.0}"

# ==============================================================================
# 脚本逻辑区域（不需要手动修改）
# ==============================================================================

check_prerequisites() {
  log_info "检查部署先决条件..."

  # 检查 kubectl
  if ! command -v kubectl &>/dev/null; then
    log_error "未找到 kubectl，请先安装 kubectl"
  fi

  # 检查集群连接
  if ! kubectl cluster-info &>/dev/null; then
    log_error "无法连接到 Kubernetes 集群，请检查 kubeconfig 配置"
  fi

  # 检查 Kubernetes 版本
  K8S_VERSION=$(kubectl version --short 2>/dev/null | grep "Server Version" | awk '{print $3}' | sed 's/v//')
  MAJOR=$(echo "$K8S_VERSION" | cut -d. -f1)
  MINOR=$(echo "$K8S_VERSION" | cut -d. -f2)

  if [ "$MAJOR" -lt 1 ] || ([ "$MAJOR" -eq 1 ] && [ "$MINOR" -lt 25 ]); then
    log_error "Kubernetes 版本需要 >= 1.25，当前版本: v${K8S_VERSION}"
  fi

  log_success "Kubernetes 集群连接正常 (v${K8S_VERSION})"

  # 检查 Ingress Controller
  if ! kubectl get deployment -n ingress-nginx ingress-nginx-controller &>/dev/null; then
    log_warning "未检测到 Nginx Ingress Controller，请在部署前安装"
    log_warning "安装命令: kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.0/deploy/static/provider/cloud/deploy.yaml"
  else
    log_success "Nginx Ingress Controller 已安装"
  fi

  # 检查 cert-manager
  if ! kubectl get deployment -n cert-manager cert-manager &>/dev/null; then
    log_warning "未检测到 cert-manager，TLS 证书将无法自动申请"
    log_warning "安装命令: kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml"
  else
    log_success "cert-manager 已安装"
  fi

  # 检查 Metrics Server（HPA 需要）
  if ! kubectl get deployment -n kube-system metrics-server &>/dev/null; then
    log_warning "未检测到 Metrics Server，HPA 自动扩缩容将无法工作"
  else
    log_success "Metrics Server 已安装"
  fi
}

generate_secrets() {
  log_info "生成随机密钥..."

  SECRET_KEY=$(openssl rand -base64 42)
  DB_PASSWORD=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
  REDIS_PASSWORD=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
  WEAVIATE_API_KEY=$(openssl rand -base64 32)
  SANDBOX_API_KEY=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
  PLUGIN_DAEMON_KEY=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
  # Generate a random initial admin password rather than using a hardcoded value
  INIT_PASSWORD=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9!@#' | head -c 20)

  # Save secrets to a temp file with restrictive permissions (owner read-only)
  SECRETS_FILE="$(mktemp "${TMPDIR:-/tmp}/dify-secrets.XXXXXX")"
  chmod 600 "$SECRETS_FILE"
  cat > "$SECRETS_FILE" <<EOF
# Dify 部署密钥 - 请安全保管，部署后删除此文件
# 生成时间: $(date)

SECRET_KEY=${SECRET_KEY}
DB_PASSWORD=${DB_PASSWORD}
REDIS_PASSWORD=${REDIS_PASSWORD}
WEAVIATE_API_KEY=${WEAVIATE_API_KEY}
SANDBOX_API_KEY=${SANDBOX_API_KEY}
PLUGIN_DAEMON_KEY=${PLUGIN_DAEMON_KEY}
INIT_PASSWORD=${INIT_PASSWORD}
EOF

  log_success "密钥已保存到 ${SECRETS_FILE}（权限 600），请安全保管并在部署后删除！"
}

create_namespace() {
  log_info "创建命名空间和资源限制..."
  kubectl apply -f manifests/namespace/namespace.yaml
  kubectl apply -f manifests/namespace/rbac.yaml
  log_success "命名空间 ${NAMESPACE} 创建成功"
}

create_configmaps() {
  log_info "应用 ConfigMap 配置..."

  if [ "$DOMAIN" = "REPLACE-YOUR-DOMAIN.example.com" ]; then
    log_error "请先设置环境变量 DIFY_DOMAIN 或修改 manifests/configmaps/configmaps.yaml 中的域名配置\n  示例: DIFY_DOMAIN=dify.your-company.com ./deploy.sh"
  fi

  kubectl apply -f manifests/configmaps/configmaps.yaml
  log_success "ConfigMap 创建成功"
}

create_secrets() {
  log_info "创建 Kubernetes Secrets..."

  # 检查 Secret 是否已存在
  if kubectl get secret dify-app-secrets -n "$NAMESPACE" &>/dev/null; then
    log_warning "dify-app-secrets 已存在，跳过创建"
    return
  fi

  kubectl create secret generic dify-app-secrets \
    --namespace "$NAMESPACE" \
    --from-literal=SECRET_KEY="${SECRET_KEY}" \
    --from-literal=INIT_PASSWORD="${INIT_PASSWORD}" \
    --from-literal=DB_USERNAME="postgres" \
    --from-literal=DB_PASSWORD="${DB_PASSWORD}" \
    --from-literal=REDIS_PASSWORD="${REDIS_PASSWORD}" \
    --from-literal=CELERY_BROKER_URL="redis://:${REDIS_PASSWORD}@dify-redis:6379/1" \
    --from-literal=WEAVIATE_API_KEY="${WEAVIATE_API_KEY}" \
    --from-literal=S3_ACCESS_KEY="" \
    --from-literal=S3_SECRET_KEY="" \
    --from-literal=CODE_EXECUTION_API_KEY="${SANDBOX_API_KEY}" \
    --from-literal=PLUGIN_DAEMON_KEY="${PLUGIN_DAEMON_KEY}"

  kubectl create secret generic dify-postgres-secret \
    --namespace "$NAMESPACE" \
    --from-literal=POSTGRES_USER="postgres" \
    --from-literal=POSTGRES_PASSWORD="${DB_PASSWORD}" \
    --from-literal=POSTGRES_DB="dify"

  kubectl create secret generic dify-redis-secret \
    --namespace "$NAMESPACE" \
    --from-literal=REDIS_PASSWORD="${REDIS_PASSWORD}"

  log_success "Secrets 创建成功"
}

deploy_storage() {
  log_info "创建持久化存储..."
  kubectl apply -f manifests/storage/pvc.yaml
  log_success "PVC 创建完成"
}

deploy_databases() {
  log_info "部署数据库服务..."
  kubectl apply -f manifests/databases/databases.yaml

  log_info "等待数据库就绪（最多等待 5 分钟）..."

  kubectl rollout status statefulset/dify-postgres -n "$NAMESPACE" --timeout=300s
  kubectl rollout status statefulset/dify-redis -n "$NAMESPACE" --timeout=300s
  kubectl rollout status statefulset/dify-weaviate -n "$NAMESPACE" --timeout=300s

  log_success "所有数据库服务已就绪"
}

deploy_applications() {
  log_info "部署应用服务..."
  kubectl apply -f manifests/applications/applications.yaml

  log_info "等待应用服务就绪（最多等待 10 分钟）..."

  kubectl rollout status deployment/dify-ssrf-proxy -n "$NAMESPACE" --timeout=120s
  kubectl rollout status deployment/dify-sandbox -n "$NAMESPACE" --timeout=120s
  kubectl rollout status deployment/dify-api -n "$NAMESPACE" --timeout=600s
  kubectl rollout status deployment/dify-worker -n "$NAMESPACE" --timeout=300s
  kubectl rollout status deployment/dify-worker-beat -n "$NAMESPACE" --timeout=120s
  kubectl rollout status deployment/dify-plugin-daemon -n "$NAMESPACE" --timeout=300s
  kubectl rollout status deployment/dify-web -n "$NAMESPACE" --timeout=300s

  log_success "所有应用服务已就绪"
}

deploy_networking() {
  log_info "部署网络和入口配置..."
  kubectl apply -f manifests/networking/ingress.yaml
  log_success "Ingress 配置完成"
}

deploy_autoscaling() {
  log_info "配置弹性扩缩容..."
  kubectl apply -f manifests/autoscaling/autoscaling.yaml
  log_success "HPA 和 PDB 配置完成"
}

deploy_network_policies() {
  log_info "配置网络安全策略..."
  kubectl apply -f manifests/network-policies/network-policies.yaml
  log_success "NetworkPolicy 配置完成"
}

verify_deployment() {
  log_info "验证部署状态..."

  echo ""
  echo "=== Pod 状态 ==="
  kubectl get pods -n "$NAMESPACE" -o wide

  echo ""
  echo "=== 服务状态 ==="
  kubectl get services -n "$NAMESPACE"

  echo ""
  echo "=== Ingress 状态 ==="
  kubectl get ingress -n "$NAMESPACE"

  echo ""
  echo "=== HPA 状态 ==="
  kubectl get hpa -n "$NAMESPACE"

  # 测试 API 健康检查
  log_info "测试 API 健康检查..."
  kubectl port-forward svc/dify-api 15001:5001 -n "$NAMESPACE" &
  PF_PID=$!
  sleep 3

  if curl -sf http://localhost:15001/health > /dev/null 2>&1; then
    log_success "API 健康检查通过！"
  else
    log_warning "API 健康检查失败，请检查日志：kubectl logs -l app=dify-api -n ${NAMESPACE}"
  fi

  kill $PF_PID 2>/dev/null || true
}

print_summary() {
  echo ""
  echo "============================================================"
  echo -e "${GREEN}  Dify 部署完成！${NC}"
  echo "============================================================"
  echo ""
  echo "  访问地址:   https://${DOMAIN}"
  echo "  管理后台:   https://${DOMAIN}/install  (首次访问设置管理员)"
  echo "  API 文档:   https://${DOMAIN}/console/api"
  echo ""
  echo "  初始管理员密码已随机生成，保存在: ${SECRETS_FILE:-未生成}"
  echo "  （请查阅该文件中的 INIT_PASSWORD 字段，登录后立即修改密码！）"
  echo ""
  echo "  密钥备份文件: ${SECRETS_FILE:-未生成}"
  echo "  ⚠️  请将该文件复制到安全位置后立即删除！"
  echo ""
  echo "  查看所有 Pod 状态:"
  echo "    kubectl get pods -n ${NAMESPACE}"
  echo ""
  echo "  查看 API 日志:"
  echo "    kubectl logs -l app=dify-api -n ${NAMESPACE} -f"
  echo ""
  echo "============================================================"
}

# ==============================================================================
# 主流程
# ==============================================================================

main() {
  echo ""
  echo "============================================================"
  echo "  Dify Kubernetes 部署脚本 v${DIFY_VERSION}"
  echo "  目标域名: ${DOMAIN}"
  echo "  命名空间: ${NAMESPACE}"
  echo "============================================================"
  echo ""

  # 切换到脚本所在目录
  cd "$(dirname "$0")"

  check_prerequisites
  generate_secrets
  create_namespace
  create_configmaps
  create_secrets
  deploy_storage
  deploy_databases
  deploy_applications
  deploy_networking
  deploy_autoscaling
  deploy_network_policies
  verify_deployment
  print_summary
}

# 捕获中断信号
trap 'log_error "部署被中断"' INT TERM

main "$@"
