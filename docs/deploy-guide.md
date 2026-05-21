# Deploy Guide — AegisOps K8s (DOKS)

## Overview

Serviços AegisOps rodam no cluster DigitalOcean Kubernetes `do-sfo3-dodo-aegisops-k8s`, namespace `dodo`.
Há dois caminhos de deploy:

- **CI/CD (normal)** — push para `develop` → CI builds image → promove para `staging` → CD faz Helm deploy
- **Manual** — `scripts/deploy.sh` direto do seu terminal (útil para hotfixes e configurações)

A infra em si (cluster, droplet de banco, VPC) é gerenciada pelo Terraform em `dodo_terraform`. Mudanças de infra seguem um fluxo separado via GitHub Actions.

---

## 1. Pré-requisitos locais

```bash
# Helm 3
helm version  # deve mostrar v3.x

# kubectl apontando para o cluster correto
kubectl config current-context  # do-sfo3-dodo-aegisops-k8s

# DOCR login (para inspecionar imagens)
doctl registry login
```

Se o Helm não estiver no PATH:
```bash
export PATH=$PATH:~/.local/bin
```

---

## 2. Deploy via CI/CD (fluxo normal)

### 2.1 Fluxo completo

```
push para develop
    ↓
CI (lint + test + build + push imagem para DOCR)
    ↓
job "promote" cria tag staging/<sha> no repo
    ↓
CD trigger (workflow_dispatch em staging)
    ↓
reusable-build-push-deploy.yml (dodo_devops_templates@main)
    → helm upgrade --install via scripts/deploy.sh
```

### 2.2 O que o CI/CD espera de cada repo

Cada repo de serviço precisa de dois workflows em `.github/workflows/`:

**`ci.yml`** — roda em push para `develop`:
- Checkout do repo de serviço **em subpath nomeado** (ex: `path: dodo_ingestor`)
- Checkout dos repos de dependência no mesmo nível (ex: `path: dodo_proto`, `path: dodo_worker_lib`)
- Isso é necessário porque os `go.mod` usam `replace ... => ../dodo_proto/gen/go`
- Jobs: `lint` → `test` → `build` → `promote`
- O job `promote` cria a tag de staging sem precisar do código de app (só Git)

**`cd.yml`** — trigger por workflow_dispatch (chamado pelo promote):
```yaml
uses: OppervisionTech/dodo_devops_templates/.github/workflows/reusable-build-push-deploy.yml@main
with:
  image-name: dodo_<service>               # nome do repo
  chart: charts/aegis-<service>            # path relativo no dodo_helm_charts
  release-name: aegis-<service>            # nome do Helm release
  environment: staging
```

### 2.3 Segredos obrigatórios no GitHub

| Secret | Descrição |
|--------|-----------|
| `GH_PAT` | Personal Access Token para checkout de repos privados |
| `DIGITALOCEAN_ACCESS_TOKEN` | Para push no DOCR e deploy no DOKS |

---

## 3. Deploy manual

Use o `scripts/deploy.sh` para deploys pontuais sem passar pelo CI/CD.

```bash
cd /path/to/dodo_helm_charts

# Sintaxe
./scripts/deploy.sh <environment> <chart-name> <namespace>

# Exemplo: deploy do ingestor em staging
./scripts/deploy.sh staging aegis-ingestor dodo

# Exemplo: deploy com override de valores inline
./scripts/deploy.sh staging aegis-portal dodo \
  --set portal.supabase.projectUrl=https://abc.supabase.co \
  --set portal.supabase.publishableKey=sb_publishable_xxx
```

O script resolve automaticamente os values files em ordem de precedência:
1. `charts/<chart>/values-<env>.yaml` (override por chart/env)
2. `values/values-<env>.yaml` (override global — legacy)
3. `charts/<chart>/values.yaml` (defaults do chart)

---

## 4. Estrutura de um chart

Cada serviço tem seu chart em `charts/aegis-<service>/`:

```
charts/aegis-ingestor/
├── Chart.yaml          # metadados e dependência da _library
├── values.yaml         # defaults (resource limits, ports, etc.)
├── values-staging.yaml # overrides de staging (image, replicas, ingress)
├── values-prod.yaml    # overrides de prod
└── templates/
    ├── deployment.yaml
    ├── service.yaml
    ├── configmap.yaml
    ├── hpa.yaml
    └── ...
```

Todos os charts dependem do chart de biblioteca `_library` (file dependency local):
```yaml
# Chart.yaml
dependencies:
  - name: aegis-library
    version: "0.1.0"
    repository: "file://../_library"
```

---

## 5. Injeção de credenciais de banco (`dodo-db-credentials`)

O secret `dodo-db-credentials` no namespace `dodo` contém host, porta e senha de todos os bancos (PostgreSQL, Redis, ClickHouse, TimescaleDB, Kafka). Ele é criado manualmente uma única vez e não muda entre deploys.

Para injetar as credenciais no container, use o helper `aegis.dbCredsEnv` no `deployment.yaml`:

```yaml
env:
  # injeta REDIS_HOST, REDIS_PORT, REDIS_PASSWORD do secret
  {{- include "aegis.dbCredsEnv" (dict "components" (list "redis" "pg" "kafka")) | nindent 12 }}
  # compõe a DSN usando substituição de variáveis Kubernetes
  - name: MY_REDIS_URL
    value: "redis://:$(REDIS_PASSWORD)@$(REDIS_HOST):$(REDIS_PORT)"
  - name: MY_POSTGRES_DSN
    value: "postgres://dodo_app:$(PG_PASSWORD)@$(PG_HOST):$(PG_PORT)/dodo_mydb?sslmode=disable"
```

Componentes disponíveis: `redis`, `pg`, `tsdb`, `clickhouse`, `kafka`

---

## 6. Secrets específicos por serviço

Além do `dodo-db-credentials`, alguns serviços precisam de secrets próprios criados manualmente no cluster antes do primeiro deploy.

Criar um secret de app:
```bash
kubectl create secret generic aegis-<service>-app-secrets \
  --from-literal=MY_KEY=my_value \
  -n dodo
```

Referenciar no `values-staging.yaml`:
```yaml
secrets:
  appCredentials: aegis-<service>-app-secrets
```

O template `deployment.yaml` injeta via `envFrom: secretRef`.

Exemplos de secrets existentes:
- `aegis-query-api-jwt` — chave pública RSA para validação de JWT
- `aegis-portal-app-secrets` — DATABASE_URL, SUPABASE_SERVICE_ROLE_KEY, STRIPE keys

---

## 7. Adicionando um novo serviço

### 7.1 Criar o chart

```bash
# Copie um chart existente como base
cp -r charts/aegis-health-monitor charts/aegis-<newservice>

# Edite Chart.yaml com o novo nome
# Ajuste values.yaml com as configurações do serviço
# Crie values-staging.yaml com image, replicas, ingress
# Ajuste deployment.yaml com as env vars necessárias
```

### 7.2 Criar CI/CD no repo do serviço

No repo `dodo_<newservice>/.github/workflows/`:

1. **`ci.yml`** — baseie em `dodo_health_monitor/.github/workflows/ci.yml`
   - Ajuste os repos de dependência (dodo_proto? dodo_worker_lib?)
   - Ajuste o `working-directory` nos steps

2. **`cd.yml`** — baseie em `dodo_health_monitor/.github/workflows/cd.yml`
   - Substitua `image-name`, `chart`, `release-name`

### 7.3 Criar secrets necessários no cluster

```bash
kubectl create secret generic aegis-<newservice>-app-secrets \
  --from-literal=KEY=value \
  -n dodo
```

### 7.4 Primeiro deploy

Após o CI/CD rodar pela primeira vez (push para develop), ou manualmente:
```bash
./scripts/deploy.sh staging aegis-<newservice> dodo
```

---

## 8. Alterações de infraestrutura (Terraform)

Mudanças no cluster, VPC, droplet de banco, DOCR ou outros recursos DigitalOcean são feitas no repo `dodo_terraform`.

**Nunca rode `terraform apply` localmente contra staging/prod.** O workflow de deploy está em `.github/workflows/terraform-deploy.yml` e é acionado via GitHub Actions → workflow_dispatch:

1. Vá em **Actions** → **Terraform Deploy** no repo `dodo_terraform`
2. Clique em **Run workflow**
3. Escolha:
   - `environment`: staging ou prod
   - `project`: `dodo-aegisops-staging` ou `dodo-aegisops-prod`
   - `action`: `plan` (ver o que vai mudar) ou `apply` (aplicar)

**Fluxo recomendado:** sempre rode `plan` primeiro, revise o output, depois rode `apply`.

### Estrutura do Terraform

```
environments/
└── dodo-aegisops-staging/
    ├── kubernetes.tf       # DOKS cluster + node pools
    ├── databases.tf        # Droplet all-in-one (PG + Redis + CH + TSDB)
    ├── container_registry.tf  # DOCR
    ├── vpc.tf
    └── variables.tf
modules/
└── digitalocean/
    ├── kubernetes/
    ├── databases/
    └── container_registry/
```

---

## 9. Inspecionar o estado do cluster

```bash
# Ver todos os pods no namespace dodo
kubectl get pods -n dodo

# Ver logs de um serviço
kubectl logs -n dodo deployment/aegis-ingestor --tail=50

# Ver Helm releases (incluindo estados problemáticos)
helm list --all -n dodo

# Limpar Helm release com estado corrompido (pending-install)
kubectl delete secret sh.helm.release.v1.aegis-<service>.v1 -n dodo
# depois fazer novo deploy via deploy.sh ou CI/CD

# Ver eventos do namespace (útil para debugar ImagePullBackOff, OOMKill, etc.)
kubectl get events -n dodo --sort-by='.lastTimestamp' | tail -20
```

---

## 10. Troubleshooting comum

| Sintoma | Causa provável | Fix |
|---------|---------------|-----|
| `ImagePullBackOff` | Imagem não existe no DOCR ou `imagePullSecrets` ausente | Verificar se CI rodou; checar `imagePullSecrets` no values |
| Pod em `CrashLoopBackOff` | App falhando na inicialização | `kubectl logs -n dodo <pod> --previous` |
| Helm deploy cancelado | Secret pré-requisito ausente | Criar o secret antes de rodar deploy.sh |
| `pending-install` no helm list | Deploy anterior foi cancelado | Deletar o secret do Helm release e redeployar |
| Pods Pending sem nó disponível | Cluster com nodes cheios | Deletar pods antigos crashando; autoscaler provisiona novo node |
| CI falha com "cannot find module" | `replace` no go.mod precisa de repo irmão | Verificar que ci.yml faz checkout de dodo_proto no mesmo nível |
