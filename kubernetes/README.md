# Dify Kubernetes 企业级部署指南

> **版本**: Dify v1.13.0  
> **最后更新**: 2024-12  
> **适用场景**: 企业级生产环境部署

---

## 📥 下载部署文件到本地

在开始阅读文档之前，您可以通过以下任一方式将本目录下载到本地：

### 方式一：使用 GitHub Releases（推荐）

前往 [Releases 页面](../../releases)，找到最新的 **Dify K8s Deployment Files** 版本，下载对应平台的压缩包：

| 文件 | 适用平台 |
|------|---------|
| `dify-k8s-deployment-vX.Y.Z.tar.gz` | Linux / macOS |
| `dify-k8s-deployment-vX.Y.Z.zip` | Windows |

```bash
# Linux / macOS 解压并使用
tar -xzf dify-k8s-deployment-v1.13.0.tar.gz
cd dify-k8s-v1.13.0
export DIFY_DOMAIN=dify.your-company.com
bash deploy.sh
```

### 方式二：使用 package.sh 本地打包

如果您已克隆仓库，可以直接运行打包脚本：

```bash
git clone https://github.com/langgenius/dify.git
cd dify

# 打包为 tar.gz 和 zip（版本号可自定义）
bash kubernetes/package.sh v1.13.0

# 输出文件在仓库根目录：
#   dify-k8s-deployment-v1.13.0.tar.gz
#   dify-k8s-deployment-v1.13.0.zip
```

### 方式三：仅下载 kubernetes 文件夹（无需克隆整个仓库）

**方法 A：使用 curl / wget 下载分支 zip 包后解压**

```bash
# Linux / macOS — curl
BRANCH="copilot/create-deployment-documentation"
curl -L "https://github.com/panliang5020/dify/archive/refs/heads/${BRANCH}.zip" \
     -o dify-branch.zip
unzip -q dify-branch.zip \
      "dify-copilot-create-deployment-documentation/kubernetes/*" \
      -d /tmp/dify-extract
mv /tmp/dify-extract/dify-copilot-create-deployment-documentation/kubernetes \
   ./dify-kubernetes
rm dify-branch.zip

# 或者用 wget
wget -q "https://github.com/panliang5020/dify/archive/refs/heads/${BRANCH}.zip" \
     -O dify-branch.zip
```

**方法 B：在 GitHub 网页上直接下载**

1. 打开 [https://github.com/panliang5020/dify/tree/copilot/create-deployment-documentation/kubernetes](https://github.com/panliang5020/dify/tree/copilot/create-deployment-documentation/kubernetes)
2. 点击页面右上角的 **…** 菜单 → **Download directory** 即可下载整个文件夹的 zip 包

**方法 C：使用 git sparse-checkout（仅检出 kubernetes 目录）**

```bash
git clone --depth=1 --filter=blob:none --sparse \
    https://github.com/panliang5020/dify.git
cd dify
git sparse-checkout set kubernetes
git checkout copilot/create-deployment-documentation
```

### 方式四：通过 GitHub Actions 手动触发打包

1. 打开仓库 → **Actions** → **Package Kubernetes Deployment Files**
2. 点击 **Run workflow**，输入目标版本号
3. 工作流完成后，在该次运行的 **Artifacts** 中下载压缩包

---

## 目录

1. [概述与架构](#1-概述与架构)
2. [先决条件](#2-先决条件)
3. [环境准备](#3-环境准备)
4. [存储规划](#4-存储规划)
5. [命名空间与权限配置](#5-命名空间与权限配置)
6. [密钥与配置管理](#6-密钥与配置管理)
7. [基础设施部署](#7-基础设施部署)
8. [应用服务部署](#8-应用服务部署)
9. [网络与入口配置](#9-网络与入口配置)
10. [弹性扩缩容配置](#10-弹性扩缩容配置)
11. [网络策略（零信任）](#11-网络策略零信任)
12. [监控与可观测性](#12-监控与可观测性)
13. [日志管理](#13-日志管理)
14. [备份与灾难恢复](#14-备份与灾难恢复)
15. [升级与维护](#15-升级与维护)
16. [安全加固](#16-安全加固)
17. [故障排查](#17-故障排查)
18. [生产就绪检查清单](#18-生产就绪检查清单)

**附录**

- [A. 完整部署命令序列](#a-完整部署命令序列)
- [B. 向量数据库切换](#b-向量数据库切换)
- [C. 多云/多集群部署](#c-多云多集群部署)
- [D. 资源规划参考](#d-资源规划参考)
- [**E. 主流云服务商集群接入指南**](#e-主流云服务商集群接入指南)（新用户请优先阅读此章节）

---

## 1. 概述与架构

### 1.1 Dify 组件说明

Dify 是一个开源的 LLM 应用开发平台，在 Kubernetes 中部署时包含以下核心组件：

| 组件 | 镜像 | 说明 | 实例数量 |
|------|------|------|---------|
| **dify-api** | `langgenius/dify-api:1.13.0` | 后端 API 服务（Flask/Gunicorn） | 2+ |
| **dify-worker** | `langgenius/dify-api:1.13.0` | Celery 异步任务工作进程 | 2+ |
| **dify-worker-beat** | `langgenius/dify-api:1.13.0` | Celery Beat 定时任务调度器 | 1（严格） |
| **dify-web** | `langgenius/dify-web:1.13.0` | 前端 Next.js 应用 | 2+ |
| **dify-sandbox** | `langgenius/dify-sandbox:0.2.12` | 代码执行沙箱环境 | 1+ |
| **dify-plugin-daemon** | `langgenius/dify-plugin-daemon:0.5.3-local` | 插件管理守护进程 | 1 |
| **dify-ssrf-proxy** | `ubuntu/squid:latest` | SSRF 安全代理 | 1 |
| **dify-postgres** | `postgres:15-alpine` | 元数据主数据库 | 1（建议 HA） |
| **dify-redis** | `redis:6-alpine` | 缓存与消息队列 | 1（建议 HA） |
| **dify-weaviate** | `semitechnologies/weaviate:1.27.0` | 向量数据库 | 1（建议 HA） |

### 1.2 架构图

```
                    ┌─────────────────────────────────────────────────────┐
                    │                  Kubernetes Cluster                  │
                    │                                                       │
Internet ──► LB ──► │  Ingress Controller (Nginx)                          │
                    │    │                                                  │
                    │    ├──► dify-web (Next.js)      ← /                  │
                    │    │      Port: 3000                                  │
                    │    │                                                  │
                    │    └──► dify-api (Flask/Gunicorn) ← /api /console    │
                    │           Port: 5001                                  │
                    │             │                                         │
                    │             ├──► dify-postgres (PostgreSQL 15)        │
                    │             │      Port: 5432                         │
                    │             │                                         │
                    │             ├──► dify-redis (Redis 6)                 │
                    │             │      Port: 6379                         │
                    │             │    ▲                                    │
                    │             │    │                                    │
                    │    dify-worker ──┘ (Celery Workers)                  │
                    │    dify-worker-beat (Celery Beat)                    │
                    │             │                                         │
                    │             ├──► dify-weaviate (Vector DB)            │
                    │             │      Port: 8080, 50051                  │
                    │             │                                         │
                    │             ├──► dify-sandbox (Code Exec)             │
                    │             │      Port: 8194                         │
                    │             │                                         │
                    │             ├──► dify-plugin-daemon (Plugins)         │
                    │             │      Port: 5002                         │
                    │             │                                         │
                    │             └──► dify-ssrf-proxy (Squid)              │
                    │                    Port: 3128                         │
                    │                                                       │
                    │  ┌─────────────────────────────────────────────────┐ │
                    │  │ Object Storage (S3/OSS) - External or MinIO     │ │
                    │  └─────────────────────────────────────────────────┘ │
                    └─────────────────────────────────────────────────────┘
```

### 1.3 关键设计原则

- **高可用**: API、Worker、Web 服务运行多副本，跨节点分布
- **零信任网络**: 通过 NetworkPolicy 实现最小权限网络访问
- **机密安全**: 使用 Kubernetes Secrets 管理敏感配置，建议集成外部密钥管理系统
- **可观测性**: 集成 Prometheus、Grafana、结构化日志
- **弹性伸缩**: HPA 实现 CPU/内存自动扩缩容
- **持久化存储**: 数据库使用 PVC 持久化，应用文件使用 S3 兼容存储

---

## 2. 先决条件

### 2.1 Kubernetes 集群要求

| 项目 | 最低要求 | 推荐配置 |
|------|---------|---------|
| Kubernetes 版本 | 1.25+ | 1.29+ |
| 节点数量 | 3 | 5+ |
| 每节点 CPU | 4 核 | 8 核 |
| 每节点内存 | 8 GiB | 16 GiB |
| 每节点磁盘 | 100 GiB SSD | 200 GiB NVMe SSD |
| 网络插件 | Calico/Cilium | Cilium（支持 NetworkPolicy） |

### 2.2 必需组件

在开始部署 Dify 之前，需要在集群中安装以下组件：

```bash
# 1. Nginx Ingress Controller
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.0/deploy/static/provider/cloud/deploy.yaml

# 2. cert-manager（自动 TLS 证书管理）
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml

# 3. Metrics Server（HPA 需要）
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# 4. （可选）Prometheus Operator（监控）
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace
```

### 2.3 客户端工具

```bash
# 安装 kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# 验证连接
kubectl cluster-info
kubectl get nodes
```

### 2.4 对象存储准备

Dify 需要对象存储来保存用户上传的文件、知识库文件等。**强烈建议**在生产环境使用外部对象存储：

- **AWS S3**: 创建 S3 Bucket，配置 IAM Role 或 Access Key
- **阿里云 OSS**: 创建 OSS Bucket，配置 RAM 用户和 AccessKey
- **腾讯云 COS**: 创建 COS Bucket，配置 API 密钥
- **MinIO**: 在集群内或集群外部署 MinIO

```bash
# MinIO 快速部署示例（仅供测试，生产应使用 MinIO Operator）
kubectl create namespace minio
helm repo add minio https://charts.min.io/
helm install minio minio/minio \
  --namespace minio \
  --set rootUser=admin \
  --set rootPassword=your-minio-password \
  --set persistence.size=100Gi \
  --set mode=standalone
```

---

## 3. 环境准备

### 3.1 克隆仓库

```bash
git clone https://github.com/langgenius/dify.git
cd dify/kubernetes
```

### 3.2 自定义配置

在部署前，需要根据实际环境修改以下文件：

#### 3.2.1 更新域名

替换所有 `your-domain.com` 为您的实际域名：

```bash
# 批量替换域名（Linux/macOS）
find . -type f -name "*.yaml" | xargs sed -i 's/your-domain.com/your-actual-domain.com/g'
find . -type f -name "*.yaml" | xargs sed -i 's/api.your-domain.com/api.your-actual-domain.com/g'
```

#### 3.2.2 更新邮箱地址（cert-manager）

```bash
sed -i 's/admin@your-domain.com/your-email@example.com/g' \
  manifests/networking/ingress.yaml
```

#### 3.2.3 更新存储配置

在 `manifests/configmaps/configmaps.yaml` 中更新存储配置：

```yaml
# 使用 S3 时
STORAGE_TYPE: "s3"
S3_ENDPOINT: "https://s3.amazonaws.com"  # 或您的 S3 兼容端点
S3_REGION: "us-east-1"
S3_BUCKET_NAME: "your-dify-bucket"

# 使用阿里云 OSS 时
STORAGE_TYPE: "aliyun-oss"
ALIYUN_OSS_ENDPOINT: "https://oss-cn-hangzhou.aliyuncs.com"
ALIYUN_OSS_BUCKET_NAME: "your-dify-bucket"
ALIYUN_OSS_REGION: "cn-hangzhou"
```

---

## 4. 存储规划

### 4.1 StorageClass 配置

根据您的 Kubernetes 集群选择合适的 StorageClass：

```bash
# 查看可用的 StorageClass
kubectl get storageclass
```

#### AWS EKS 示例

编辑 `manifests/storage/pvc.yaml`，将 StorageClass 更新为：

```yaml
# 创建高性能 StorageClass
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: dify-ssd
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "3000"
  throughput: "125"
  encrypted: "true"
reclaimPolicy: Retain
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
```

#### 阿里云 ACK 示例

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: dify-ssd
provisioner: diskplugin.csi.alibabacloud.com
parameters:
  type: cloud_essd
  performanceLevel: "PL1"
reclaimPolicy: Retain
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
```

#### 腾讯云 TKE 示例

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: dify-ssd
provisioner: com.tencent.cloud.csi.cbs
parameters:
  type: CLOUD_PREMIUM
reclaimPolicy: Retain
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
```

### 4.2 ReadWriteMany 存储（API/Worker 共享）

API 和 Worker 服务需要共享访问应用存储目录。如果使用本地文件存储（不推荐），需要支持 `ReadWriteMany` 的存储类。

**推荐方案（按优先级）**:

1. **使用 S3/OSS 对象存储**（最推荐）- 无需共享文件系统
2. **AWS EFS / 阿里云 NAS**（第二选择）- 支持 ReadWriteMany
3. **NFS Server**（第三选择）- 仅用于测试环境

如果使用 S3 存储，需注释掉 `applications.yaml` 中 API 和 Worker 的 volume 挂载：

```yaml
# 如果使用 S3 存储，删除这段 volumeMounts 和 volumes 配置
# volumeMounts:
#   - name: app-storage
#     mountPath: /app/api/storage
# volumes:
#   - name: app-storage
#     persistentVolumeClaim:
#       claimName: dify-api-storage-pvc
```

---

## 5. 命名空间与权限配置

### 5.1 创建命名空间和资源限制

```bash
kubectl apply -f manifests/namespace/namespace.yaml
```

这将创建：
- `dify` 命名空间
- `ResourceQuota`（整体资源限制）
- `LimitRange`（单容器资源限制）

### 5.2 配置 RBAC

```bash
kubectl apply -f manifests/namespace/rbac.yaml
```

### 5.3 验证

```bash
kubectl get namespace dify
kubectl describe resourcequota dify-quota -n dify
kubectl describe limitrange dify-limit-range -n dify
```

---

## 6. 密钥与配置管理

### 6.1 创建应用 Secrets（关键步骤）

**安全警告**: 切勿将包含真实密码的 YAML 文件提交到版本控制系统！

使用 `kubectl create` 命令创建 Secrets：

```bash
# 生成安全的随机密钥
export SECRET_KEY=$(openssl rand -base64 42)
export DB_PASSWORD=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
export REDIS_PASSWORD=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
export WEAVIATE_API_KEY=$(openssl rand -base64 32)
export SANDBOX_API_KEY=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
export PLUGIN_DAEMON_KEY=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
export INIT_PASSWORD="Admin@123456"  # 设置初始管理员密码

# 创建主应用 Secret
kubectl create secret generic dify-app-secrets \
  --namespace dify \
  --from-literal=SECRET_KEY="${SECRET_KEY}" \
  --from-literal=INIT_PASSWORD="${INIT_PASSWORD}" \
  --from-literal=DB_USERNAME="postgres" \
  --from-literal=DB_PASSWORD="${DB_PASSWORD}" \
  --from-literal=REDIS_PASSWORD="${REDIS_PASSWORD}" \
  --from-literal=CELERY_BROKER_URL="redis://:${REDIS_PASSWORD}@dify-redis:6379/1" \
  --from-literal=WEAVIATE_API_KEY="${WEAVIATE_API_KEY}" \
  --from-literal=S3_ACCESS_KEY="your-s3-access-key" \
  --from-literal=S3_SECRET_KEY="your-s3-secret-key" \
  --from-literal=CODE_EXECUTION_API_KEY="${SANDBOX_API_KEY}" \
  --from-literal=PLUGIN_DAEMON_KEY="${PLUGIN_DAEMON_KEY}"

# 创建 PostgreSQL Secret
kubectl create secret generic dify-postgres-secret \
  --namespace dify \
  --from-literal=POSTGRES_USER="postgres" \
  --from-literal=POSTGRES_PASSWORD="${DB_PASSWORD}" \
  --from-literal=POSTGRES_DB="dify"

# 创建 Redis Secret
kubectl create secret generic dify-redis-secret \
  --namespace dify \
  --from-literal=REDIS_PASSWORD="${REDIS_PASSWORD}"

# 将密钥保存到安全位置（如密码管理器）
echo "请安全保存以下密钥："
echo "SECRET_KEY: ${SECRET_KEY}"
echo "DB_PASSWORD: ${DB_PASSWORD}"
echo "REDIS_PASSWORD: ${REDIS_PASSWORD}"
echo "WEAVIATE_API_KEY: ${WEAVIATE_API_KEY}"
echo "INIT_PASSWORD: ${INIT_PASSWORD}"
```

### 6.2 创建 ConfigMap

更新 `manifests/configmaps/configmaps.yaml` 中的域名和配置后：

```bash
kubectl apply -f manifests/configmaps/configmaps.yaml
```

### 6.3 验证配置

```bash
# 验证 Secret 已创建（不显示值）
kubectl get secrets -n dify
kubectl describe secret dify-app-secrets -n dify

# 验证 ConfigMap
kubectl get configmaps -n dify
kubectl describe configmap dify-app-config -n dify
```

### 6.4 企业级方案：外部 Secrets 管理

生产环境强烈建议使用外部密钥管理系统：

#### 使用 HashiCorp Vault

```bash
# 安装 Vault Agent Injector
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install vault hashicorp/vault \
  --namespace vault \
  --create-namespace \
  --set "server.ha.enabled=true" \
  --set "server.ha.replicas=3"

# 将 Dify secrets 写入 Vault
vault kv put secret/dify/app \
  SECRET_KEY="..." \
  DB_PASSWORD="..." \
  REDIS_PASSWORD="..."
```

#### 使用 AWS Secrets Manager + External Secrets Operator

```bash
# 安装 External Secrets Operator
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace

# 创建 SecretStore（指向 AWS Secrets Manager）
kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: aws-secrets-manager
  namespace: dify
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      auth:
        jwt:
          serviceAccountRef:
            name: dify-api
EOF

# 创建 ExternalSecret
kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: dify-app-secrets
  namespace: dify
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: SecretStore
  target:
    name: dify-app-secrets
  data:
    - secretKey: SECRET_KEY
      remoteRef:
        key: dify/production
        property: SECRET_KEY
    - secretKey: DB_PASSWORD
      remoteRef:
        key: dify/production
        property: DB_PASSWORD
EOF
```

---

## 7. 基础设施部署

### 7.1 创建 PVC（持久化存储）

首先确认并更新 `manifests/storage/pvc.yaml` 中的 `storageClassName`：

```bash
kubectl apply -f manifests/storage/pvc.yaml

# 验证 PVC 状态
kubectl get pvc -n dify
```

等待所有 PVC 状态变为 `Bound`（如果 StorageClass 是 `WaitForFirstConsumer` 模式，会在 Pod 调度后绑定）。

### 7.2 部署数据库

```bash
kubectl apply -f manifests/databases/databases.yaml
```

#### 验证数据库状态

```bash
# 等待 PostgreSQL 就绪
kubectl rollout status statefulset/dify-postgres -n dify

# 等待 Redis 就绪
kubectl rollout status statefulset/dify-redis -n dify

# 等待 Weaviate 就绪
kubectl rollout status statefulset/dify-weaviate -n dify

# 验证数据库连接
kubectl exec -it dify-postgres-0 -n dify -- psql -U postgres -d dify -c "\l"
kubectl exec -it dify-redis-0 -n dify -- redis-cli -a YOUR_REDIS_PASSWORD ping
```

### 7.3 数据库初始化验证

```bash
# 检查 PostgreSQL 日志
kubectl logs dify-postgres-0 -n dify

# 检查 Redis 日志
kubectl logs dify-redis-0 -n dify

# 检查 Weaviate 日志
kubectl logs dify-weaviate-0 -n dify
```

---

## 8. 应用服务部署

### 8.1 部署所有应用组件

```bash
kubectl apply -f manifests/applications/applications.yaml
```

### 8.2 部署顺序与验证

应用组件有依赖关系，请按以下顺序验证部署：

```bash
# 1. 验证 SSRF Proxy（最先启动）
kubectl rollout status deployment/dify-ssrf-proxy -n dify

# 2. 验证 Sandbox
kubectl rollout status deployment/dify-sandbox -n dify

# 3. 验证 API（包含数据库迁移）
kubectl rollout status deployment/dify-api -n dify
# 查看 API 启动日志以确认数据库迁移成功
kubectl logs -l app=dify-api -n dify --tail=50

# 4. 验证 Worker
kubectl rollout status deployment/dify-worker -n dify

# 5. 验证 Worker Beat
kubectl rollout status deployment/dify-worker-beat -n dify

# 6. 验证 Plugin Daemon
kubectl rollout status deployment/dify-plugin-daemon -n dify

# 7. 验证 Web 前端
kubectl rollout status deployment/dify-web -n dify
```

### 8.3 验证所有 Pod 状态

```bash
kubectl get pods -n dify -o wide

# 期望输出示例：
# NAME                                    READY   STATUS    RESTARTS   AGE
# dify-api-xxx-xxx                        1/1     Running   0          5m
# dify-api-xxx-yyy                        1/1     Running   0          5m
# dify-postgres-0                         1/1     Running   0          10m
# dify-redis-0                            1/1     Running   0          10m
# dify-weaviate-0                         1/1     Running   0          10m
# dify-worker-xxx-xxx                     1/1     Running   0          5m
# dify-worker-xxx-yyy                     1/1     Running   0          5m
# dify-worker-beat-xxx-xxx                1/1     Running   0          5m
# dify-web-xxx-xxx                        1/1     Running   0          5m
# dify-web-xxx-yyy                        1/1     Running   0          5m
# dify-sandbox-xxx-xxx                    1/1     Running   0          5m
# dify-plugin-daemon-xxx-xxx              1/1     Running   0          5m
# dify-ssrf-proxy-xxx-xxx                 1/1     Running   0          5m
```

### 8.4 快速功能验证

```bash
# 端口转发 API 进行本地测试
kubectl port-forward svc/dify-api 5001:5001 -n dify &

# 测试 API 健康检查
curl http://localhost:5001/health
# 期望输出：{"status": "ok"}

# 测试版本接口
curl http://localhost:5001/console/api/version
```

---

## 9. 网络与入口配置

### 9.1 更新 DNS 解析

在部署 Ingress 之前，需要将域名解析到 Ingress Controller 的 Load Balancer IP：

```bash
# 获取 Ingress Controller 的外部 IP
kubectl get svc -n ingress-nginx ingress-nginx-controller

# 将以下域名解析到获得的 IP：
# your-domain.com -> EXTERNAL-IP
# api.your-domain.com -> EXTERNAL-IP（如果分离部署）
```

### 9.2 部署 Ingress 和 TLS

```bash
# 部署 cert-manager ClusterIssuer 和 Ingress
kubectl apply -f manifests/networking/ingress.yaml

# 验证证书申请状态
kubectl get certificate -n dify
kubectl describe certificate dify-certificate -n dify

# 等待证书就绪（可能需要几分钟）
kubectl wait --for=condition=Ready certificate/dify-certificate -n dify --timeout=300s
```

### 9.3 验证访问

```bash
# 验证 Ingress 规则
kubectl get ingress -n dify
kubectl describe ingress dify-ingress -n dify

# 测试 HTTPS 访问
curl -v https://your-domain.com/health
curl -v https://your-domain.com/console/api/version
```

### 9.4 自定义 TLS 证书（企业内部 CA）

如果使用企业内部 CA 签发的证书，而非 Let's Encrypt：

```bash
# 从文件创建 TLS Secret
kubectl create secret tls dify-tls \
  --cert=path/to/your/certificate.crt \
  --key=path/to/your/private.key \
  --namespace dify

# 修改 ingress.yaml 移除 cert-manager 注解
# 删除: cert-manager.io/cluster-issuer: "letsencrypt-prod"
```

---

## 10. 弹性扩缩容配置

### 10.1 部署 HPA 和 PDB

```bash
kubectl apply -f manifests/autoscaling/autoscaling.yaml

# 验证 HPA 配置
kubectl get hpa -n dify
kubectl describe hpa dify-api-hpa -n dify

# 验证 PDB 配置
kubectl get pdb -n dify
```

### 10.2 手动扩缩容

```bash
# 手动扩展 API 副本数
kubectl scale deployment dify-api --replicas=4 -n dify

# 手动扩展 Worker 副本数
kubectl scale deployment dify-worker --replicas=4 -n dify

# 注意：worker-beat 必须保持 1 个副本
# kubectl scale deployment dify-worker-beat --replicas=1 -n dify
```

### 10.3 HPA 自定义指标（高级）

对于基于任务队列深度的扩缩容，可以使用 KEDA（Kubernetes Event-Driven Autoscaling）：

```bash
# 安装 KEDA
helm repo add kedacore https://kedacore.github.io/charts
helm install keda kedacore/keda --namespace keda --create-namespace

# 创建基于 Redis 队列长度的 ScaledObject
kubectl apply -f - <<EOF
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: dify-worker-scaledobject
  namespace: dify
spec:
  scaleTargetRef:
    name: dify-worker
  minReplicaCount: 2
  maxReplicaCount: 20
  triggers:
    - type: redis
      metadata:
        address: dify-redis:6379
        listName: celery
        listLength: "20"
      authenticationRef:
        name: keda-redis-trigger-auth
EOF
```

---

## 11. 网络策略（零信任）

### 11.1 部署网络策略

```bash
kubectl apply -f manifests/network-policies/network-policies.yaml

# 验证网络策略
kubectl get networkpolicies -n dify
```

### 11.2 测试网络隔离

```bash
# 测试 API Pod 是否可以访问 PostgreSQL（应该成功）
kubectl exec -it $(kubectl get pod -l app=dify-api -n dify -o jsonpath='{.items[0].metadata.name}') \
  -n dify -- nc -zv dify-postgres 5432

# 测试 Web Pod 是否可以访问 PostgreSQL（应该失败，被 NetworkPolicy 阻止）
kubectl exec -it $(kubectl get pod -l app=dify-web -n dify -o jsonpath='{.items[0].metadata.name}') \
  -n dify -- nc -zv dify-postgres 5432
```

---

## 12. 监控与可观测性

### 12.1 部署监控配置

```bash
kubectl apply -f manifests/monitoring/monitoring.yaml
```

### 12.2 访问 Grafana

```bash
# 端口转发 Grafana
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring

# 默认账号：admin / prom-operator
# 访问：http://localhost:3000
```

### 12.3 导入 Dify Dashboard

1. 登录 Grafana
2. 点击 Dashboards → Import
3. 上传 `manifests/monitoring/monitoring.yaml` 中的 Dashboard JSON，或使用 Grafana ID

### 12.4 配置告警通知

```bash
# 配置 AlertManager 发送告警到钉钉/企业微信/Slack
kubectl apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: dify-alertmanager-config
  namespace: dify
spec:
  route:
    groupBy: ['alertname', 'namespace']
    groupWait: 30s
    groupInterval: 5m
    repeatInterval: 4h
    receiver: 'dify-team'
  receivers:
    - name: 'dify-team'
      webhookConfigs:
        - url: 'https://oapi.dingtalk.com/robot/send?access_token=YOUR_TOKEN'
          sendResolved: true
EOF
```

### 12.5 OpenTelemetry 集成

Dify 支持 OpenTelemetry，可以将 Trace 数据发送到 Jaeger 或 Tempo：

```bash
# 在 ConfigMap 中启用 OTEL
kubectl patch configmap dify-app-config -n dify \
  --type merge \
  -p '{"data":{"ENABLE_OTEL":"true","OTLP_BASE_ENDPOINT":"http://otel-collector.monitoring:4318"}}'

# 重启 API 服务以生效
kubectl rollout restart deployment/dify-api -n dify
```

---

## 13. 日志管理

### 13.1 使用 Loki + Promtail 收集日志

```bash
# 安装 Loki Stack
helm repo add grafana https://grafana.github.io/helm-charts
helm install loki grafana/loki-stack \
  --namespace monitoring \
  --set promtail.enabled=true \
  --set loki.persistence.enabled=true \
  --set loki.persistence.size=50Gi
```

### 13.2 结构化日志配置

Dify API 支持 JSON 格式日志，已在 ConfigMap 中配置：

```yaml
LOG_OUTPUT_FORMAT: "json"
LOG_LEVEL: "INFO"
```

### 13.3 查看实时日志

```bash
# 查看所有 API Pod 的日志
kubectl logs -l app=dify-api -n dify -f --max-log-requests=5

# 查看特定 Pod 日志
kubectl logs dify-api-xxx-xxx -n dify -f

# 查看 Worker 日志
kubectl logs -l app=dify-worker -n dify -f

# 查看带时间戳的日志
kubectl logs dify-api-xxx-xxx -n dify --timestamps=true --since=1h
```

---

## 14. 备份与灾难恢复

### 14.1 PostgreSQL 备份

#### 自动备份（CronJob）

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: dify-backup-script
  namespace: dify
data:
  backup.sh: |
    #!/bin/bash
    set -e
    BACKUP_DATE=\$(date +%Y%m%d_%H%M%S)
    BACKUP_FILE="dify_db_backup_\${BACKUP_DATE}.sql.gz"
    
    echo "Starting PostgreSQL backup: \${BACKUP_FILE}"
    pg_dump -h dify-postgres -U postgres -d dify | gzip > /tmp/\${BACKUP_FILE}
    
    # Upload to S3/OSS
    aws s3 cp /tmp/\${BACKUP_FILE} s3://your-backup-bucket/dify/postgres/\${BACKUP_FILE}
    
    # Keep only last 30 days of backups
    aws s3 ls s3://your-backup-bucket/dify/postgres/ | \
      awk '{print \$4}' | sort | head -n -30 | \
      xargs -I{} aws s3 rm s3://your-backup-bucket/dify/postgres/{}
    
    echo "Backup completed: \${BACKUP_FILE}"
    rm -f /tmp/\${BACKUP_FILE}
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: dify-postgres-backup
  namespace: dify
spec:
  schedule: "0 2 * * *"  # 每天凌晨 2 点
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: postgres-backup
              image: postgres:15-alpine
              command: ["/bin/bash", "/scripts/backup.sh"]
              env:
                - name: PGPASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: dify-postgres-secret
                      key: POSTGRES_PASSWORD
                - name: AWS_ACCESS_KEY_ID
                  valueFrom:
                    secretKeyRef:
                      name: dify-app-secrets
                      key: S3_ACCESS_KEY
                - name: AWS_SECRET_ACCESS_KEY
                  valueFrom:
                    secretKeyRef:
                      name: dify-app-secrets
                      key: S3_SECRET_KEY
              volumeMounts:
                - name: backup-scripts
                  mountPath: /scripts
          volumes:
            - name: backup-scripts
              configMap:
                name: dify-backup-script
                defaultMode: 0755
EOF
```

### 14.2 使用 Velero 备份整个命名空间

```bash
# 安装 Velero
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.9.0 \
  --bucket your-velero-bucket \
  --secret-file ./credentials-velero \
  --backup-location-config region=us-east-1

# 创建定时备份
velero schedule create dify-daily \
  --schedule="0 1 * * *" \
  --include-namespaces dify \
  --ttl 720h  # 保留 30 天

# 手动创建备份
velero backup create dify-manual-backup-$(date +%Y%m%d) \
  --include-namespaces dify

# 查看备份列表
velero backup get

# 灾难恢复
velero restore create --from-backup dify-manual-backup-20241201
```

### 14.3 灾难恢复演练

建议每季度进行一次灾难恢复演练：

```bash
# 1. 在测试环境创建新命名空间
kubectl create namespace dify-dr-test

# 2. 从 Velero 备份恢复到测试命名空间
velero restore create dify-dr-test \
  --from-backup dify-manual-backup-latest \
  --namespace-mappings dify:dify-dr-test

# 3. 验证应用功能
kubectl port-forward svc/dify-api 5001:5001 -n dify-dr-test
curl http://localhost:5001/health

# 4. 清理测试命名空间
kubectl delete namespace dify-dr-test
```

---

## 15. 升级与维护

### 15.1 版本升级流程

```bash
# 1. 备份当前版本数据
velero backup create dify-pre-upgrade-$(date +%Y%m%d) --include-namespaces dify

# 2. 查看当前版本
kubectl get deployment dify-api -n dify -o jsonpath='{.spec.template.spec.containers[0].image}'

# 3. 更新镜像版本（以升级到 v1.14.0 为例）
NEW_VERSION="1.14.0"

kubectl set image deployment/dify-api api=langgenius/dify-api:${NEW_VERSION} -n dify
kubectl set image deployment/dify-worker worker=langgenius/dify-api:${NEW_VERSION} -n dify
kubectl set image deployment/dify-worker-beat worker-beat=langgenius/dify-api:${NEW_VERSION} -n dify
kubectl set image deployment/dify-web web=langgenius/dify-web:${NEW_VERSION} -n dify

# 4. 监控滚动更新进度
kubectl rollout status deployment/dify-api -n dify
kubectl rollout status deployment/dify-worker -n dify
kubectl rollout status deployment/dify-web -n dify

# 5. 验证升级后应用健康
curl https://your-domain.com/health
curl https://your-domain.com/console/api/version

# 6. 如果升级失败，回滚
kubectl rollout undo deployment/dify-api -n dify
kubectl rollout undo deployment/dify-worker -n dify
kubectl rollout undo deployment/dify-web -n dify
```

### 15.2 数据库迁移

Dify API 在启动时会自动运行数据库迁移（`MIGRATION_ENABLED: "true"`）。升级时注意：

- 确保在升级前备份数据库
- 新版本 API Pod 启动时会执行 `flask db upgrade`
- 如果迁移失败，检查 API Pod 日志：`kubectl logs -l app=dify-api -n dify --tail=100`

### 15.3 ConfigMap 更新

```bash
# 更新 ConfigMap（使用 apply 而非 replace 以保留注解）
kubectl apply -f manifests/configmaps/configmaps.yaml

# ConfigMap 更新后需要重启相关 Pod
kubectl rollout restart deployment/dify-api -n dify
kubectl rollout restart deployment/dify-worker -n dify
kubectl rollout restart deployment/dify-worker-beat -n dify
```

### 15.4 Secret 轮换

```bash
# 轮换数据库密码
NEW_DB_PASSWORD=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)

# 1. 更新 PostgreSQL 密码
kubectl exec -it dify-postgres-0 -n dify -- psql -U postgres -c \
  "ALTER USER postgres WITH PASSWORD '${NEW_DB_PASSWORD}';"

# 2. 更新 Secrets
kubectl patch secret dify-postgres-secret -n dify \
  --type='json' \
  -p="[{\"op\": \"replace\", \"path\": \"/data/POSTGRES_PASSWORD\", \"value\": \"$(echo -n ${NEW_DB_PASSWORD} | base64)\"}]"

kubectl patch secret dify-app-secrets -n dify \
  --type='json' \
  -p="[{\"op\": \"replace\", \"path\": \"/data/DB_PASSWORD\", \"value\": \"$(echo -n ${NEW_DB_PASSWORD} | base64)\"}]"

# 3. 重启应用
kubectl rollout restart deployment/dify-api -n dify
kubectl rollout restart deployment/dify-worker -n dify
```

---

## 16. 安全加固

### 16.1 Pod 安全策略

Kubernetes 1.25+ 使用 Pod Security Admission：

```bash
# 为 dify 命名空间设置 Pod 安全标准（受限模式）
kubectl label namespace dify \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=v1.29 \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=v1.29
```

注意：sandbox 组件需要特殊权限，可能需要排除或使用 `baseline` 模式。

### 16.2 镜像安全扫描

```bash
# 使用 Trivy 扫描镜像漏洞
trivy image langgenius/dify-api:1.13.0
trivy image langgenius/dify-web:1.13.0

# 集成到 CI/CD 流水线（GitHub Actions 示例）
# 参见 .github/workflows/security-scan.yml
```

### 16.3 运行时安全（Falco）

```bash
# 安装 Falco 运行时安全检测
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm install falco falcosecurity/falco \
  --namespace falco \
  --create-namespace \
  --set falco.grpc.enabled=true \
  --set falco.grpcOutput.enabled=true
```

### 16.4 密钥加密存储

确保集群 etcd 中的 Secrets 数据是加密存储的：

```bash
# 验证 etcd 加密配置（管理员操作）
kubectl get apiserver -o yaml | grep -A10 encryptionConfig

# 如果未启用，参考 Kubernetes 文档配置 Encryption at Rest
```

---

## 17. 故障排查

### 17.1 常见问题排查

#### API Pod 启动失败

```bash
# 查看 Pod 事件
kubectl describe pod -l app=dify-api -n dify

# 查看容器日志
kubectl logs -l app=dify-api -n dify --previous

# 常见原因：
# 1. 数据库连接失败 - 检查 DB_HOST、DB_PASSWORD 配置
# 2. 数据库迁移失败 - 检查 PostgreSQL 是否就绪
# 3. Redis 连接失败 - 检查 REDIS_HOST、REDIS_PASSWORD 配置
# 4. SECRET_KEY 未设置 - 检查 Secret 是否正确创建
```

#### 数据库连接问题

```bash
# 测试从 API Pod 到数据库的连接
kubectl exec -it $(kubectl get pod -l app=dify-api -n dify -o jsonpath='{.items[0].metadata.name}') \
  -n dify -- bash -c "nc -zv dify-postgres 5432 && echo 'PostgreSQL连接正常' || echo 'PostgreSQL连接失败'"

kubectl exec -it $(kubectl get pod -l app=dify-api -n dify -o jsonpath='{.items[0].metadata.name}') \
  -n dify -- bash -c "nc -zv dify-redis 6379 && echo 'Redis连接正常' || echo 'Redis连接失败'"
```

#### 存储访问问题

```bash
# 检查 PVC 状态
kubectl get pvc -n dify
kubectl describe pvc dify-postgres-pvc -n dify

# 检查 PV 状态
kubectl get pv | grep dify
```

#### Ingress 访问问题

```bash
# 检查 Ingress 状态
kubectl describe ingress dify-ingress -n dify

# 检查 Ingress Controller 日志
kubectl logs -l app.kubernetes.io/name=ingress-nginx -n ingress-nginx --tail=100

# 检查证书状态
kubectl describe certificate dify-certificate -n dify
kubectl get certificaterequest -n dify
```

#### Celery Worker 问题

```bash
# 检查 Worker 状态
kubectl exec -it $(kubectl get pod -l app=dify-worker -n dify -o jsonpath='{.items[0].metadata.name}') \
  -n dify -- celery -A app.celery inspect active

# 检查任务队列深度
kubectl exec -it $(kubectl get pod -l app=dify-worker -n dify -o jsonpath='{.items[0].metadata.name}') \
  -n dify -- celery -A app.celery inspect reserved
```

### 17.2 性能问题排查

```bash
# 查看 Pod 资源使用情况
kubectl top pods -n dify --sort-by=cpu
kubectl top pods -n dify --sort-by=memory

# 查看节点资源使用情况
kubectl top nodes

# 查看 HPA 状态
kubectl get hpa -n dify
kubectl describe hpa dify-api-hpa -n dify

# 查看 PostgreSQL 慢查询
kubectl exec -it dify-postgres-0 -n dify -- psql -U postgres -d dify -c \
  "SELECT query, mean_exec_time, calls FROM pg_stat_statements ORDER BY mean_exec_time DESC LIMIT 10;"
```

### 17.3 网络问题排查

```bash
# 使用 netshoot 临时 Pod 进行网络诊断
kubectl run netshoot --rm -i --tty \
  --image=nicolaka/netshoot \
  -n dify \
  --overrides='{"spec":{"hostNetwork":false}}' \
  -- bash

# 在 netshoot Pod 中测试连接
nslookup dify-api.dify.svc.cluster.local
curl -v http://dify-api:5001/health
telnet dify-postgres 5432
```

---

## 18. 生产就绪检查清单

在正式上线前，请逐项检查以下内容：

### 基础设施

- [ ] Kubernetes 集群版本 >= 1.25，节点数量 >= 3
- [ ] 已安装 Nginx Ingress Controller
- [ ] 已安装 cert-manager
- [ ] 已安装 Metrics Server（HPA 需要）
- [ ] StorageClass 已正确配置，支持动态卷分配
- [ ] 对象存储（S3/OSS）已配置完毕

### 安全配置

- [ ] 所有密码已替换为强随机密码（openssl rand）
- [ ] Secrets 中不包含默认占位符值
- [ ] TLS 证书已正确配置和验证
- [ ] NetworkPolicy 已启用，实现服务间最小权限访问
- [ ] RBAC 配置遵循最小权限原则
- [ ] Pod 以非 root 用户运行（sandbox 除外）
- [ ] 已配置 Pod 安全标准（PodSecurityAdmission）
- [ ] etcd 已启用加密存储

### 高可用配置

- [ ] API 部署副本数 >= 2
- [ ] Worker 部署副本数 >= 2
- [ ] Web 部署副本数 >= 2
- [ ] worker-beat 副本数严格等于 1，使用 Recreate 策略
- [ ] PodDisruptionBudget 已配置
- [ ] TopologySpreadConstraints 已配置（跨节点分布）
- [ ] HPA 已配置并可正常工作

### 数据持久化

- [ ] PostgreSQL 数据使用 PVC 持久化存储
- [ ] Redis 数据使用 PVC 持久化存储（appendonly on）
- [ ] Weaviate 数据使用 PVC 持久化存储
- [ ] 应用文件存储使用 S3 兼容存储
- [ ] 自动备份已配置（CronJob）
- [ ] 已进行灾难恢复演练

### 监控与告警

- [ ] Prometheus + Grafana 已部署
- [ ] Dify 应用指标已接入 Prometheus
- [ ] 关键告警规则已配置（API 宕机、高错误率等）
- [ ] 告警通知渠道已配置（钉钉/企业微信/邮件等）
- [ ] 日志收集已配置（Loki/ELK）

### 功能验证

- [ ] 浏览器可正常访问前端 `https://your-domain.com`
- [ ] API 健康检查返回 200：`https://your-domain.com/health`
- [ ] 管理员账号可正常登录控制台
- [ ] 知识库功能正常（文件上传、向量化）
- [ ] 对话功能正常（连接 LLM API）
- [ ] 工作流功能正常
- [ ] 代码执行功能正常（沙箱）

### 性能验证

- [ ] 进行压力测试，确认系统可承载预期并发量
- [ ] 验证 HPA 在负载下能自动扩容
- [ ] 验证 PDB 在节点维护时保证服务可用性

---

## 附录

### A. 完整部署命令序列

```bash
# === 完整部署流程（按顺序执行）===

# 1. 创建命名空间和资源限制
kubectl apply -f manifests/namespace/namespace.yaml
kubectl apply -f manifests/namespace/rbac.yaml

# 2. 创建 ConfigMap
kubectl apply -f manifests/configmaps/configmaps.yaml

# 3. 创建 Secrets（手动执行第6节中的 kubectl create secret 命令）

# 4. 创建 PVC
kubectl apply -f manifests/storage/pvc.yaml

# 5. 部署基础设施（数据库）
kubectl apply -f manifests/databases/databases.yaml

# 6. 等待数据库就绪
kubectl rollout status statefulset/dify-postgres -n dify
kubectl rollout status statefulset/dify-redis -n dify
kubectl rollout status statefulset/dify-weaviate -n dify

# 7. 部署应用组件
kubectl apply -f manifests/applications/applications.yaml

# 8. 等待应用就绪
kubectl rollout status deployment/dify-api -n dify
kubectl rollout status deployment/dify-worker -n dify
kubectl rollout status deployment/dify-web -n dify

# 9. 部署网络和入口
kubectl apply -f manifests/networking/ingress.yaml

# 10. 配置弹性扩缩容
kubectl apply -f manifests/autoscaling/autoscaling.yaml

# 11. 配置网络策略
kubectl apply -f manifests/network-policies/network-policies.yaml

# 12. 部署监控
kubectl apply -f manifests/monitoring/monitoring.yaml

# 13. 验证部署
kubectl get all -n dify
```

### B. 向量数据库切换

如需使用其他向量数据库（如 Milvus、Qdrant、pgvector）：

1. 修改 `manifests/configmaps/configmaps.yaml` 中的 `VECTOR_STORE` 值
2. 部署对应的向量数据库服务
3. 更新对应的连接配置
4. 重启 API 和 Worker 服务

```bash
# 切换到 pgvector（使用 PostgreSQL 扩展）
kubectl patch configmap dify-app-config -n dify \
  --type merge \
  -p '{
    "data": {
      "VECTOR_STORE": "pgvector",
      "PGVECTOR_HOST": "dify-postgres",
      "PGVECTOR_PORT": "5432",
      "PGVECTOR_DATABASE": "dify_vector"
    }
  }'

kubectl rollout restart deployment/dify-api -n dify
kubectl rollout restart deployment/dify-worker -n dify
```

### C. 多云/多集群部署

对于跨区域高可用部署，建议：

1. 使用全局负载均衡（AWS Global Accelerator / 阿里云 GSLB）
2. PostgreSQL 使用主从复制（PostgreSQL Patroni 或 CloudSQL / RDS）
3. Redis 使用 Redis Cluster 或 Sentinel 高可用模式
4. 对象存储使用多地域复制
5. Weaviate 配置多节点集群

### D. 资源规划参考

| 场景 | API 副本 | Worker 副本 | PostgreSQL | Redis | Weaviate |
|------|---------|-----------|-----------|-------|---------|
| 小型（<50用户） | 2×(1C/2G) | 2×(1C/2G) | 1×(2C/4G) | 1×(1C/2G) | 1×(2C/4G) |
| 中型（50-500用户） | 4×(2C/4G) | 4×(2C/4G) | 1×(4C/8G) | 1×(2C/4G) | 1×(4C/8G) |
| 大型（>500用户） | 8×(4C/8G) | 8×(4C/8G) | HA(8C/16G) | Cluster | Cluster |

---

### E. 主流云服务商集群接入指南

> **适用场景**：您已有（或准备创建）托管 Kubernetes 集群，想直接将 `kubernetes/` 目录中的 Manifest 部署到云服务商的集群上。
>
> **阅读顺序**：先按本附录完成"集群创建 → kubectl 连接 → 云原生前置组件安装"，再回到正文第 2 节继续常规部署流程。

本章节以五大主流云服务商为例，提供从零开始的端到端操作示范：

| 云服务商 | 托管 K8s 服务 | 本章节跳转 |
|---------|------------|---------|
| AWS | Amazon EKS | [→ E.1](#e1-aws-eks) |
| Google Cloud | Google GKE | [→ E.2](#e2-google-gke) |
| Microsoft Azure | Azure AKS | [→ E.3](#e3-microsoft-azure-aks) |
| 阿里云 | ACK（容器服务 Kubernetes 版） | [→ E.4](#e4-阿里云-ack) |
| 腾讯云 | TKE（容器服务） | [→ E.5](#e5-腾讯云-tke) |

各云服务商与本文正文章节的对应关系：

| 部署步骤 | 正文章节 | AWS EKS 注意事项 | GKE 注意事项 | AKS 注意事项 | ACK 注意事项 | TKE 注意事项 |
|---------|---------|--------------|------------|------------|------------|------------|
| StorageClass | §4.1 | `ebs.csi.aws.com` gp3 | `pd.csi.storage.gke.io` | `disk.csi.azure.com` | `diskplugin.csi.alibabacloud.com` | `com.tencent.cloud.csi.cbs` |
| 对象存储 | §2.4 | S3 + IAM Role | GCS + Workload Identity | Azure Blob + Pod Identity | OSS + RAM Role | COS + 访问密钥 |
| Ingress | §9 | Nginx / AWS ALB | Nginx / GKE Ingress | Nginx / AGIC | Nginx / ALB Ingress | Nginx / CLB/ALB |
| TLS 证书 | §9.2 | cert-manager | cert-manager / 托管证书 | cert-manager | cert-manager | cert-manager |
| 监控 | §12 | CloudWatch + Prometheus | Cloud Monitoring + Prometheus | Azure Monitor + Prometheus | ARMS + Prometheus | CLS + Prometheus |

---

#### E.1 AWS EKS

**前置工具**

```bash
# 安装 AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install
aws configure   # 填入 Access Key ID / Secret / Region

# 安装 eksctl
curl --silent --location "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin

# 安装 kubectl（若未安装）
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
```

**创建 EKS 集群**

```bash
eksctl create cluster \
  --name dify-prod \
  --region ap-southeast-1 \        # 按实际区域修改
  --version 1.29 \
  --nodegroup-name dify-nodes \
  --node-type m6i.2xlarge \        # 8 vCPU / 32 GiB，可按需调整
  --nodes 3 \
  --nodes-min 3 \
  --nodes-max 10 \
  --managed \
  --with-oidc \                    # 启用 IRSA（IAM Roles for Service Accounts）
  --asg-access                     # 允许 Cluster Autoscaler 控制 ASG
```

> 集群创建约需 15–20 分钟。`eksctl` 会自动更新 `~/.kube/config`。

**验证连接**

```bash
kubectl cluster-info
kubectl get nodes
```

**安装 EBS CSI Driver（持久化存储）**

```bash
# 为 EBS CSI 创建 IAM 服务账号
eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster dify-prod \
  --role-name AmazonEKS_EBS_CSI_DriverRole \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --approve

# 启用 EBS CSI 插件
eksctl create addon \
  --name aws-ebs-csi-driver \
  --cluster dify-prod \
  --service-account-role-arn \
    $(aws iam get-role --role-name AmazonEKS_EBS_CSI_DriverRole --query 'Role.Arn' --output text) \
  --force

# 创建 gp3 StorageClass（在 manifests/storage/pvc.yaml 中使用 storageClassName: dify-ssd）
kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: dify-ssd
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "3000"
  throughput: "125"
  encrypted: "true"
reclaimPolicy: Retain
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
EOF
```

**对象存储（S3）与 IRSA 配置**

```bash
# 1. 创建 S3 Bucket
aws s3api create-bucket \
  --bucket dify-storage-prod \
  --region ap-southeast-1 \
  --create-bucket-configuration LocationConstraint=ap-southeast-1

# 2. 为 Dify API / Worker 创建 IAM 角色（使用 IRSA，无需在代码中硬编码密钥）
eksctl create iamserviceaccount \
  --name dify-s3-sa \
  --namespace dify \
  --cluster dify-prod \
  --attach-policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess \
  --approve

# 3. 在 manifests/applications/applications.yaml 中，为 dify-api 和 dify-worker Deployment
#    添加 serviceAccountName: dify-s3-sa，并在 ConfigMap 中配置：
#    STORAGE_TYPE=s3
#    S3_BUCKET_NAME=dify-storage-prod
#    S3_REGION=ap-southeast-1
#    AWS_DEFAULT_REGION=ap-southeast-1
```

**安装 Nginx Ingress Controller**

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=LoadBalancer \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"=nlb
```

**安装 cert-manager**

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml
```

**安装 Metrics Server**

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

完成以上步骤后，返回正文 **第 3 节** 继续配置。

---

#### E.2 Google GKE

**前置工具**

```bash
# 安装 Google Cloud SDK
curl https://sdk.cloud.google.com | bash
exec -l $SHELL
gcloud init

# 安装 gke-gcloud-auth-plugin（kubectl 认证插件）
gcloud components install gke-gcloud-auth-plugin

# 安装 kubectl（若未安装）
gcloud components install kubectl
```

**创建 GKE Autopilot 集群（推荐，免运维节点）**

```bash
gcloud container clusters create-auto dify-prod \
  --region asia-east1 \            # 按实际区域修改
  --release-channel regular
```

**或创建 Standard 集群（更灵活）**

```bash
gcloud container clusters create dify-prod \
  --region asia-east1 \
  --release-channel regular \
  --machine-type n2-standard-8 \   # 8 vCPU / 32 GiB
  --num-nodes 1 \                  # 每个 Zone 的节点数（3 Zone = 3 节点）
  --min-nodes 1 \
  --max-nodes 5 \
  --enable-autoscaling \
  --workload-pool=$(gcloud config get-value project).svc.id.goog \  # 启用 Workload Identity
  --addons HorizontalPodAutoscaling,HttpLoadBalancing
```

**获取凭据**

```bash
gcloud container clusters get-credentials dify-prod --region asia-east1
kubectl cluster-info
kubectl get nodes
```

**对象存储（GCS）与 Workload Identity 配置**

```bash
PROJECT_ID=$(gcloud config get-value project)

# 1. 创建 GCS Bucket
gsutil mb -l asia-east1 gs://dify-storage-prod-${PROJECT_ID}/

# 2. 创建 IAM Service Account
gcloud iam service-accounts create dify-gcs-sa \
  --display-name "Dify GCS Service Account"

# 3. 绑定权限
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member "serviceAccount:dify-gcs-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role "roles/storage.objectAdmin"

# 4. 将 K8s ServiceAccount 与 GCP IAM SA 绑定
gcloud iam service-accounts add-iam-policy-binding \
  dify-gcs-sa@${PROJECT_ID}.iam.gserviceaccount.com \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:${PROJECT_ID}.svc.id.goog[dify/dify-api-sa]"

# 5. 在 manifests/applications/applications.yaml 中为 dify-api 和 dify-worker 添加：
#    serviceAccountName: dify-api-sa（并在该 SA 上添加 iam.gke.io/gcp-service-account 注解）
#    ConfigMap 中配置：
#    STORAGE_TYPE=google-storage
#    GOOGLE_STORAGE_BUCKET=dify-storage-prod-<project_id>
```

**StorageClass（SSD 持久盘）**

```bash
kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: dify-ssd
provisioner: pd.csi.storage.gke.io
parameters:
  type: pd-ssd
reclaimPolicy: Retain
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
EOF
```

**安装 Nginx Ingress Controller**

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=LoadBalancer
```

**安装 cert-manager 与 Metrics Server**

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

完成以上步骤后，返回正文 **第 3 节** 继续配置。

---

#### E.3 Microsoft Azure AKS

**前置工具**

```bash
# 安装 Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
az login

# 安装 kubectl（若未安装）
az aks install-cli
```

**创建资源组与 AKS 集群**

```bash
RESOURCE_GROUP=dify-prod-rg
CLUSTER_NAME=dify-prod
LOCATION=eastasia   # 按实际区域修改

# 创建资源组
az group create --name ${RESOURCE_GROUP} --location ${LOCATION}

# 创建 AKS 集群（启用 Managed Identity 和 OIDC Issuer）
az aks create \
  --resource-group ${RESOURCE_GROUP} \
  --name ${CLUSTER_NAME} \
  --location ${LOCATION} \
  --kubernetes-version 1.29 \
  --node-count 3 \
  --node-vm-size Standard_D8s_v5 \  # 8 vCPU / 32 GiB
  --enable-managed-identity \
  --enable-oidc-issuer \
  --enable-workload-identity \
  --enable-cluster-autoscaler \
  --min-count 3 \
  --max-count 10 \
  --network-plugin azure \
  --network-policy azure \
  --generate-ssh-keys
```

**获取凭据**

```bash
az aks get-credentials \
  --resource-group ${RESOURCE_GROUP} \
  --name ${CLUSTER_NAME}
kubectl cluster-info
kubectl get nodes
```

**安装 Azure Disk CSI Driver（通常已内置）**

```bash
# 验证 CSI Driver 是否已启用
az aks show \
  --resource-group ${RESOURCE_GROUP} \
  --name ${CLUSTER_NAME} \
  --query "storageProfile.diskCSIDriver"

# 创建 Premium SSD StorageClass
kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: dify-ssd
provisioner: disk.csi.azure.com
parameters:
  skuName: Premium_LRS
  kind: Managed
reclaimPolicy: Retain
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
EOF
```

**对象存储（Azure Blob Storage）与 Workload Identity 配置**

```bash
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

# 1. 创建存储账号和容器
az storage account create \
  --name difystorageprod \
  --resource-group ${RESOURCE_GROUP} \
  --location ${LOCATION} \
  --sku Standard_LRS \
  --kind StorageV2

az storage container create \
  --name dify-files \
  --account-name difystorageprod

# 2. 创建 Managed Identity
az identity create \
  --name dify-blob-identity \
  --resource-group ${RESOURCE_GROUP}

IDENTITY_CLIENT_ID=$(az identity show \
  --name dify-blob-identity \
  --resource-group ${RESOURCE_GROUP} \
  --query clientId -o tsv)

# 3. 赋予 Storage Blob Data Contributor 权限
STORAGE_ACCOUNT_ID=$(az storage account show \
  --name difystorageprod \
  --resource-group ${RESOURCE_GROUP} \
  --query id -o tsv)

az role assignment create \
  --assignee ${IDENTITY_CLIENT_ID} \
  --role "Storage Blob Data Contributor" \
  --scope ${STORAGE_ACCOUNT_ID}

# 4. 在 manifests 的 ConfigMap 中配置：
#    STORAGE_TYPE=azure-blob
#    AZURE_BLOB_ACCOUNT_NAME=difystorageprod
#    AZURE_BLOB_ACCOUNT_KEY=<从门户获取>
#    AZURE_BLOB_CONTAINER_NAME=dify-files
```

**安装 Nginx Ingress Controller**

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=LoadBalancer \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz
```

**安装 cert-manager 与 Metrics Server**

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

完成以上步骤后，返回正文 **第 3 节** 继续配置。

---

#### E.4 阿里云 ACK

**前置工具**

```bash
# 安装阿里云 CLI
curl -Lo aliyun https://aliyuncli.alicdn.com/aliyun-cli-linux-latest-amd64.tgz
tar -xzf aliyun-cli-linux-latest-amd64.tgz
sudo mv aliyun /usr/local/bin/
aliyun configure   # 填入 Access Key ID / Secret / Region

# 安装 kubectl（若未安装）
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
```

**通过控制台创建 ACK 集群（推荐）**

1. 登录 [容器服务控制台](https://cs.console.aliyun.com/)
2. 选择**集群** → **创建集群** → **标准托管集群**（ACK Managed）
3. 建议配置：
   - Kubernetes 版本：1.29+
   - Worker 规格：ecs.g7.2xlarge（8 vCPU / 32 GiB）× 3 节点
   - 操作系统：Alibaba Cloud Linux 3
   - 网络插件：Terway（推荐，支持 NetworkPolicy）
   - 勾选"RRSA 功能"（相当于 IRSA，允许 Pod 无密钥访问 OSS）

**获取 kubeconfig**

```bash
# 通过 CLI 获取（集群 ID 从控制台获取）
aliyun cs DescribeClusterUserKubeconfig --ClusterId <cluster-id> \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['config'])" \
  > ~/.kube/config

kubectl cluster-info
kubectl get nodes
```

**StorageClass（云盘 ESSD）**

```bash
kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: dify-ssd
provisioner: diskplugin.csi.alibabacloud.com
parameters:
  type: cloud_essd
  performanceLevel: "PL1"
reclaimPolicy: Retain
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
EOF
```

**对象存储（OSS）与 RRSA 配置**

```bash
# 1. 创建 OSS Bucket（在控制台或 CLI）
aliyun oss mb oss://dify-storage-prod --region cn-hangzhou

# 2. 在控制台"集群详情 → 安全 → RRSA"中，为命名空间 dify 下的
#    ServiceAccount dify-api-sa 关联 RAM 角色并授予 OSS 权限。
#
# 3. 在 manifests/applications/applications.yaml 中为 dify-api/dify-worker 添加：
#    serviceAccountName: dify-api-sa
#
# 4. 在 ConfigMap 中配置：
#    STORAGE_TYPE=aliyun-oss
#    ALIYUN_OSS_BUCKET_NAME=dify-storage-prod
#    ALIYUN_OSS_ENDPOINT=oss-cn-hangzhou-internal.aliyuncs.com  # 使用内网地址
#    ALIYUN_OSS_REGION=cn-hangzhou
#
# 如不使用 RRSA，也可使用 AccessKey（不推荐用于生产）：
#    ALIYUN_OSS_ACCESS_KEY=<your-ak>
#    ALIYUN_OSS_SECRET_KEY=<your-sk>
```

**安装 Nginx Ingress Controller**

```bash
# ACK 集群可通过控制台"应用市场"一键安装 nginx-ingress-controller
# 或使用 Helm：
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=LoadBalancer \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/alibaba-cloud-loadbalancer-charge-type"=PayByTraffic
```

**安装 cert-manager 与 Metrics Server**

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml
# Metrics Server 通常由 ACK 预装，若缺失：
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

完成以上步骤后，返回正文 **第 3 节** 继续配置。

---

#### E.5 腾讯云 TKE

**前置工具**

```bash
# 安装腾讯云 CLI (tccli)
pip3 install tccli
tccli configure   # 填入 SecretId / SecretKey / Region

# 安装 kubectl（若未安装）
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
```

**通过控制台创建 TKE 集群（推荐）**

1. 登录 [容器服务控制台](https://console.cloud.tencent.com/tke2/cluster)
2. 选择**集群** → **新建** → **标准集群**
3. 建议配置：
   - Kubernetes 版本：1.28+
   - Worker 机型：S6.2XLARGE16（8 vCPU / 16 GiB）× 3 节点，建议配置 32 GiB 内存节点
   - 操作系统：TencentOS Server 3.1
   - 网络插件：VPC-CNI（支持 NetworkPolicy）

**获取 kubeconfig**

```bash
# 在集群详情页 → "基本信息" → "集群APIServer信息" 中下载 kubeconfig 文件
# 或使用 CLI：
tccli tke DescribeClusterKubeconfig --ClusterId <cluster-id> \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['Kubeconfig'])" \
  > ~/.kube/config

kubectl cluster-info
kubectl get nodes
```

**StorageClass（CBS 高性能云硬盘）**

```bash
kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: dify-ssd
provisioner: com.tencent.cloud.csi.cbs
parameters:
  type: CLOUD_PREMIUM
reclaimPolicy: Retain
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
EOF
```

**对象存储（COS）配置**

```bash
# 1. 登录 COS 控制台，创建存储桶（如 dify-storage-prod-1234567890）
# 2. 创建 API 密钥（建议使用子账号 + 策略绑定，仅授予该桶权限）

# 3. 在 ConfigMap 中配置：
#    STORAGE_TYPE=tencent-cos
#    TENCENT_COS_BUCKET_NAME=dify-storage-prod-1234567890
#    TENCENT_COS_REGION=ap-guangzhou
#    TENCENT_COS_SECRET_ID=<your-secret-id>
#    TENCENT_COS_SECRET_KEY=<your-secret-key>
#
# 推荐：将 SecretId/SecretKey 存入 Kubernetes Secret（参见正文 §6.1）而非直接写入 ConfigMap
kubectl create secret generic dify-cos-credentials \
  --namespace dify \
  --from-literal=TENCENT_COS_SECRET_ID=<your-secret-id> \
  --from-literal=TENCENT_COS_SECRET_KEY=<your-secret-key>
```

**安装 Nginx Ingress Controller**

```bash
# TKE 集群可通过控制台"应用市场"一键安装 nginx-ingress-controller，
# 选择"公网 CLB" 或 "内网 CLB" 暴露类型。
# 或使用 Helm：
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=LoadBalancer \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/qcloud-loadbalancer-internal-subnetid"=""
```

**安装 cert-manager 与 Metrics Server**

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml
# Metrics Server 通常由 TKE 预装，若缺失：
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

完成以上步骤后，返回正文 **第 3 节** 继续配置。

---

#### E.6 连接到已有集群（通用步骤）

如果您已经有一个正在运行的 Kubernetes 集群（自建或其他云服务商），请确认以下通用检查清单：

```bash
# 1. 验证 kubectl 已正确连接到目标集群
kubectl cluster-info
kubectl get nodes -o wide

# 2. 确认 Kubernetes 版本 >= 1.25
kubectl version --short

# 3. 确认集群中至少有一个可用的 StorageClass
kubectl get storageclass

# 4. 确认 Ingress Controller 已安装（以 Nginx 为例）
kubectl get pods -n ingress-nginx

# 5. 确认 cert-manager 已安装
kubectl get pods -n cert-manager

# 6. 确认 Metrics Server 已安装（HPA 依赖）
kubectl top nodes

# 7. 确认节点资源充足（建议合计 ≥ 24 vCPU / 48 GiB 内存）
kubectl describe nodes | grep -A 5 "Allocatable:"
```

所有检查通过后，从正文 **第 3 节** 开始正式部署。

---

*本文档由 Dify 社区维护，如有问题请提交 Issue 或 PR。*
