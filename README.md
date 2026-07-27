# dodo_helm_charts — Helm Charts for DoDo AegisOps AI

Helm charts for deploying all AegisOps components on Kubernetes.

## Prerequisites

- Helm 3.14+
- kubectl configured for your cluster
- helm-unittest plugin: `helm plugin install https://github.com/helm-unittest/helm-unittest`

## Structure

```text
charts/                  # One directory per chart
  _library/              # Shared helpers (library chart)
  aegis-agent/           # Agent DaemonSet
  aegis-ingestor/        # Ingestor Deployment + HPA
  aegis-ai-core/         # AI Core Deployment
  aegis-query-api/       # Query API Deployment + HPA
  aegis-metric-worker/   # Metric Worker Deployment
  aegis-log-worker/      # Log Worker Deployment
  aegis-health-monitor/  # Health Monitor Deployment
  aegis-otel-worker/     # OTEL Worker Deployment
  aegis-alerts/          # Alerts Worker Deployment
  aegis-dashboard/       # Dashboard Deployment + Ingress
  aegis-portal/          # Portal Deployment + Ingress
  aegis-kong/            # Kong API Gateway
  aegis-kafka/           # Kafka StatefulSet
  aegis-timescaledb/     # TimescaleDB StatefulSet
  aegis-clickhouse/      # ClickHouse StatefulSet
  aegis-postgresql/      # PostgreSQL StatefulSet
  aegis-redis/           # Redis StatefulSet
values/                  # Environment-specific values
  values-dev.yaml
  values-qa.yaml
  values-prod.yaml
scripts/                 # Deploy helpers
tests/                   # Chart test structure
docs/                    # Chart documentation
```

## Usage

```bash
# Lint all charts
make lint-all

# Render templates for a chart
make template CHART=aegis-agent ENV=dev

# Run unit tests
make test

# Deploy a chart
helm install aegis-agent charts/aegis-agent -f values/values-dev.yaml -n aegisops

# Deploy with environment values
./scripts/deploy.sh dev aegis-agent
```

## Adding a New Chart

1. Create directory `charts/<chart-name>/`
2. Add `Chart.yaml` (apiVersion: v2, type: application)
3. Add `_library` as dependency in `Chart.yaml`
4. Create `templates/` with your resources using `_library` helpers
5. Create `values.yaml` with defaults
6. Add tests in `charts/<chart-name>/tests/`
7. Run `make lint CHART=<chart-name>` to validate

## Staging deployment

Staging usa o cluster DOKS para apps e um droplet Docker (mesma VPC DigitalOcean) para a infra (Postgres, TimescaleDB, ClickHouse, Kafka, Redis). Charts de infra (`aegis-postgresql`, `aegis-clickhouse`, `aegis-kafka`, `aegis-redis`, `aegis-timescaledb`) **não devem ser instalados em staging** — substituídos pelo droplet.

### Cluster pré-requisitos

Cada namespace alvo precisa do Secret compartilhado **`dodo-db-credentials`** com 14 chaves:

```
tsdb-host, tsdb-port, tsdb-password
pg-host, pg-port, pg-password
clickhouse-host, clickhouse-http-port, clickhouse-native-port, clickhouse-password
redis-host, redis-port, redis-password
kafka-bootstrap
```

Esse Secret é provisionado fora destes charts (manualmente ou via outro pipeline) e referenciado por todos os charts via `valueFrom.secretKeyRef`. Ver helper `aegis.dbCredsEnv` em `charts/_library/templates/_helpers.tpl`.

### Padrão de deploy

Pipeline de cada repo de aplicação roda algo como:

```bash
helm upgrade --install aegis-<svc> charts/aegis-<svc> \
  -f charts/aegis-<svc>/values-staging.yaml \
  --set image.tag=<sha> \
  -n dodo
```

Os charts compõem as DSNs (postgres://...) em runtime usando `$(VAR)` substitution do Kubernetes a partir das variáveis de ambiente que vêm do `dodo-db-credentials`. O chart **não** cria Secrets de DB — apenas os referencia.

### Secrets adicionais por aplicação

Apps que precisam de credenciais não-DB (Anthropic, Stripe, Supabase, JWT pubkey) consomem um Secret próprio criado pelo pipeline do repo da aplicação:

| App | Secret name (default em values-staging.yaml) | Conteúdo esperado |
|---|---|---|
| `aegis-ai-core` | `aegis-ai-core-app-secrets` | `DODO_LLM_API_KEY`, `DODO_CLAUDE_API_KEY` |
| `aegis-portal` | `aegis-portal-app-secrets` | `SUPABASE_SERVICE_ROLE_KEY`, `STRIPE_*`, `DATABASE_URL` |
| `aegis-query-api` | `aegis-query-api-jwt` | key `jwt-public.pem` (PEM bytes — montado como arquivo) |
| `aegis-alerts`, `aegis-metric-worker`, `aegis-otel-worker` | — | (sem segredos não-DB) |

Pipeline cria via, ex.:

```bash
kubectl -n dodo create secret generic aegis-ai-core-app-secrets \
  --from-literal=DODO_LLM_API_KEY="$ANTHROPIC_KEY" \
  --from-literal=DODO_CLAUDE_API_KEY="$ANTHROPIC_KEY"
```

```bash
kubectl -n dodo create secret generic aegis-query-api-jwt \
  --from-file=jwt-public.pem=/path/to/jwt-public.pem
```

### Charts cobertos por staging

`aegis-ai-core`, `aegis-alerts`, `aegis-metric-worker`, `aegis-otel-worker`, `aegis-portal`, `aegis-query-api`.

### Limitação Next.js (aegis-portal)

`NEXT_PUBLIC_*` configuradas no `values-staging.yaml` valem **apenas para SSR/API routes do Node**. O bundle JS do client foi inlinado em build time pelo Dockerfile de `dodo_portal` — a imagem em `registry.digitalocean.com/dodo-aegisops-staging/dodo_portal` precisa ser publicada com `ARG NEXT_PUBLIC_API_URL=https://api.staging.oppervision.com.br` etc. Override no Helm sozinho não atualiza o JS do browser.

## Instalação pública (OCI)

O chart `aegis-agent` também é publicado publicamente como artefato OCI no Docker Hub
(via o workflow `helm-publish.yml`, disparado manualmente). Para instalar sem clonar este
repositório:

```bash
helm install aegis-agent oci://registry-1.docker.io/oppervisiontech/aegis-agent \
  --version 0.1.0 \
  --set tls.secretName=<seu-secret-mtls>
```

A imagem default (`image.repository`) já aponta para `oppervisiontech/dodo-agent` no
Docker Hub, público. Para publicar uma nova versão, dispare o workflow `helm-publish.yml`
(GitHub Actions → Helm Publish (OCI) → Run workflow) depois de dar bump no `version` do
`Chart.yaml`.

## Conventions

- One chart per service (no umbrella chart)
- All charts depend on `_library` for shared helpers
- Values separated by environment (`values-dev.yaml`, `values-qa.yaml`, `values-prod.yaml`)
- No secrets in plain text (use `secretRef`, sealed-secrets, or external-secrets)
- Resource limits defined for every container
- Health checks (liveness + readiness) in every chart
- Network policies are restrictive (deny-all default)
- RBAC with minimum-privilege ServiceAccounts
- Labels follow Kubernetes recommended labels (`app.kubernetes.io/*`)
