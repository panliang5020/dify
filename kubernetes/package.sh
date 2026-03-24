#!/usr/bin/env bash
# ==============================================================================
# Dify Kubernetes 部署文件打包脚本
# 将 kubernetes/ 目录打包为可分发的压缩包，方便下载到本地
#
# 用法:
#   bash package.sh                        # 自动读取 git tag 作为版本号
#   bash package.sh v1.13.0               # 指定版本号
#   OUTDIR=/tmp bash package.sh v1.13.0  # 自定义输出目录
# ==============================================================================

set -euo pipefail

# ----------- 配置 -----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${1:-}"
OUTDIR="${OUTDIR:-${SCRIPT_DIR}/..}"   # 默认输出到仓库根目录

# 颜色输出
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ----------- 确定版本号 -----------
if [ -z "$VERSION" ]; then
  if git -C "$SCRIPT_DIR" rev-parse --git-dir &>/dev/null; then
    VERSION=$(git -C "$SCRIPT_DIR" describe --tags --abbrev=0 2>/dev/null \
              || echo "git-$(git -C "$SCRIPT_DIR" rev-parse --short HEAD)")
  else
    VERSION="local-$(date +%Y%m%d)"
  fi
fi

ARCHIVE_BASE="dify-k8s-deployment-${VERSION}"
TAR_FILE="${OUTDIR}/${ARCHIVE_BASE}.tar.gz"
ZIP_FILE="${OUTDIR}/${ARCHIVE_BASE}.zip"
TOP_DIR="dify-k8s-${VERSION}"   # 解压后的顶层目录名

# ----------- 校验 YAML 语法 -----------
validate_yaml() {
  if ! command -v python3 &>/dev/null; then
    log_warn "python3 未安装，跳过 YAML 语法校验"
    return 0
  fi

  # Check if PyYAML is available
  if ! python3 -c "import yaml" 2>/dev/null; then
    log_warn "PyYAML 未安装，跳过 YAML 语法校验"
    log_warn "可通过以下命令安装: pip install pyyaml  或  apt-get install python3-yaml"
    return 0
  fi

  log_info "校验 YAML 语法..."
  python3 - "$SCRIPT_DIR" <<'PYEOF'
import yaml, sys, pathlib

errors = []
k8s_dir = pathlib.Path(sys.argv[1])
for yaml_file in sorted(k8s_dir.rglob("*.yaml")):
    try:
        with open(yaml_file) as f:
            list(yaml.safe_load_all(f.read()))
        print(f"  ✅  {yaml_file.relative_to(k8s_dir.parent)}")
    except yaml.YAMLError as exc:
        errors.append(f"  ❌  {yaml_file}: {exc}")
if errors:
    for e in errors:
        print(e, file=sys.stderr)
    sys.exit(1)
PYEOF
  log_success "YAML 校验通过"
}

# ----------- 构建 tar.gz -----------
build_tar() {
  log_info "正在生成 tar.gz → ${TAR_FILE}"
  tar -czf "$TAR_FILE" \
    --transform "s|^$(basename "$SCRIPT_DIR")|${TOP_DIR}|" \
    --exclude='*.pyc' \
    --exclude='__pycache__' \
    --exclude='.git' \
    --exclude='.gitignore' \
    -C "$(dirname "$SCRIPT_DIR")" \
    "$(basename "$SCRIPT_DIR")"
  log_success "tar.gz 已生成: $(du -sh "$TAR_FILE" | cut -f1)  ${TAR_FILE}"
}

# ----------- 构建 zip (可选) -----------
build_zip() {
  if ! command -v zip &>/dev/null; then
    log_warn "zip 命令未找到，跳过 .zip 包生成"
    return 0
  fi

  log_info "正在生成 zip → ${ZIP_FILE}"

  # Build zip via a temp directory so the archive has a clean top-level name
  TMP_PARENT="$(mktemp -d)"
  TMP_DIR="${TMP_PARENT}/${TOP_DIR}"

  # Copy only tracked/relevant files, excluding git metadata and caches
  if command -v rsync &>/dev/null; then
    rsync -a \
      --exclude='.git/' \
      --exclude='.gitignore' \
      --exclude='*.pyc' \
      --exclude='__pycache__/' \
      "$SCRIPT_DIR/" "$TMP_DIR/"
  else
    cp -r "$SCRIPT_DIR" "$TMP_DIR"
    rm -rf "$TMP_DIR/.git" "$TMP_DIR/__pycache__"
  fi

  (cd "$TMP_PARENT" && zip -rq "$ZIP_FILE" "${TOP_DIR}/") || {
    rm -rf "$TMP_PARENT"
    log_error "zip 生成失败"
  }
  rm -rf "$TMP_PARENT"
  log_success "zip 已生成:    $(du -sh "$ZIP_FILE" | cut -f1)  ${ZIP_FILE}"
}

# ----------- 打印下载说明 -----------
print_summary() {
  echo ""
  echo "============================================================"
  echo -e "${GREEN}  打包完成！${NC}"
  echo "============================================================"
  echo ""
  echo "  版本:     ${VERSION}"
  echo "  解压目录: ${TOP_DIR}/"
  echo ""

  if [ -f "$TAR_FILE" ]; then
    echo "  📦 tar.gz  $(du -sh "$TAR_FILE" | cut -f1)   ${TAR_FILE}"
  fi
  if [ -f "$ZIP_FILE" ]; then
    echo "  📦 zip     $(du -sh "$ZIP_FILE" | cut -f1)   ${ZIP_FILE}"
  fi

  echo ""
  echo "  ---- 本地解压与使用 ----"
  echo ""
  echo "  # Linux / macOS"
  echo "  tar -xzf ${ARCHIVE_BASE}.tar.gz"
  echo "  cd ${TOP_DIR}"
  echo "  export DIFY_DOMAIN=dify.your-company.com"
  echo "  bash deploy.sh"
  echo ""
  echo "  # Windows (PowerShell)"
  echo "  Expand-Archive ${ARCHIVE_BASE}.zip -DestinationPath ."
  echo "  cd ${TOP_DIR}"
  echo "  \$env:DIFY_DOMAIN='dify.your-company.com'"
  echo "  bash deploy.sh"
  echo ""
  echo "============================================================"
}

# ----------- 主流程 -----------
main() {
  log_info "Dify K8s 部署文件打包脚本"
  log_info "版本: ${VERSION} | 输出目录: ${OUTDIR}"
  echo ""

  validate_yaml
  build_tar
  build_zip
  print_summary
}

main
