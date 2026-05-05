# Staging ConfigMap + Secret Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Materializar os `.env` dos repos `dodo_ai_core`, `dodo_alerts`, `dodo_metric_worker`, `dodo_query_api`, `dodo_otel_worker` e `dodo_portal` como `ConfigMap` + `Secret` Kubernetes versionados em `dodo_helm_charts`, customizados para o ambiente `staging` (DOKS + droplet Docker na mesma VPC DigitalOcean).

**Architecture:** ConfigMap em formato flat `KEY=VALUE` consumido via `envFrom: configMapRef`, substituindo o `config.yaml` montado existente. Secret de staging versionado em `templates/secret-staging.yaml` por chart, com guard `.Values.secretsStaging.enabled` (default `false`, ligado em `values-staging.yaml`). Único value `external.infraHost` por chart consumidor de infra para apontar para o droplet quando o IP/hostname for conhecido. Valores secretos placeholder no padrão `REPLACE_ME_<DESCRIÇÃO>`.

**Tech Stack:** Helm 3.14+, Kubernetes (DOKS), `_library` chart (helpers compartilhados — não modificar), Make + helm CLI para lint/template.

**Spec base:** `docs/superpowers/specs/2026-05-03-staging-configmap-secrets-design.md`

---

## File Structure

### Modificados

```
charts/aegis-ai-core/values.yaml                          ← novo: env, secretsStaging, external
charts/aegis-ai-core/values-staging.yaml                  ← novo: secretsStaging.enabled=true, env overrides
charts/aegis-ai-core/templates/configmap.yaml             ← reescrito: data flat KEY=VALUE
charts/aegis-ai-core/templates/secret-staging.yaml        ← NOVO
charts/aegis-ai-core/templates/deployment.yaml            ← envFrom; mantém volume policies/security se existir

charts/aegis-metric-worker/values.yaml
charts/aegis-metric-worker/values-staging.yaml
charts/aegis-metric-worker/templates/configmap.yaml
charts/aegis-metric-worker/templates/secret-staging.yaml  ← NOVO
charts/aegis-metric-worker/templates/deployment.yaml

charts/aegis-otel-worker/values.yaml
charts/aegis-otel-worker/values-staging.yaml
charts/aegis-otel-worker/templates/configmap.yaml
charts/aegis-otel-worker/templates/secret-staging.yaml    ← NOVO
charts/aegis-otel-worker/templates/deployment.yaml

charts/aegis-query-api/values.yaml
charts/aegis-query-api/values-staging.yaml
charts/aegis-query-api/templates/configmap.yaml
charts/aegis-query-api/templates/secret-staging.yaml      ← NOVO
charts/aegis-query-api/templates/secret-jwt.yaml          ← NOVO (separado, volume-mounted)
charts/aegis-query-api/templates/deployment.yaml

charts/aegis-portal/values.yaml
charts/aegis-portal/values-staging.yaml
charts/aegis-portal/templates/configmap.yaml
charts/aegis-portal/templates/secret-staging.yaml         ← NOVO
charts/aegis-portal/templates/deployment.yaml

README.md                                                 ← seção "Staging deployment workflow"
```

### Novo chart (do zero)

```
charts/aegis-alerts/Chart.yaml
charts/aegis-alerts/values.yaml
charts/aegis-alerts/values-staging.yaml
charts/aegis-alerts/values-prod.yaml
charts/aegis-alerts/templates/configmap.yaml
charts/aegis-alerts/templates/secret-staging.yaml
charts/aegis-alerts/templates/deployment.yaml
charts/aegis-alerts/templates/service.yaml
charts/aegis-alerts/templates/serviceaccount.yaml
charts/aegis-alerts/templates/networkpolicy.yaml
```

### Não tocados

`_library/`, `aegis-agent/`, `aegis-clickhouse/`, `aegis-dashboard/`, `aegis-health-monitor/`, `aegis-ingestor/`, `aegis-kafka/`, `aegis-kong/`, `aegis-log-worker/`, `aegis-postgresql/`, `aegis-redis/`, `aegis-timescaledb/`.

---

## Validation pattern (re-used em cada fase)

**Pré-requisito**: Para cada chart tocado, rodar `helm dependency update charts/<chart>` antes do primeiro `helm lint` (baixa o `_library` em `charts/<chart>/charts/`). Se o `charts/<chart>/charts/` já existir e estiver atualizado, lint funciona sem isso.

**Comandos de validação por chart**:

```bash
# Lint
make lint CHART=<chart-name>

# Render com values-staging
make template CHART=<chart-name> ENV=staging

# Verificar nenhum credencial real foi commitado por engano
grep -RnE "sk-(ant|test|live)|eyJ[A-Za-z0-9]|whsec_[a-zA-Z0-9]" charts/<chart-name>/ \
  | grep -v "REPLACE_ME" \
  | grep -v "_helpers.tpl" \
  || echo "OK: nenhum segredo real encontrado"
```

`make template ... ENV=staging` resolve para `helm template <chart> charts/<chart> -f charts/<chart>/values-staging.yaml` (o Makefile inclui também `values/values-staging.yaml` se existir, que não vamos criar — só usamos o per-chart).

**Inspeção manual do output**: confirmar que o ConfigMap renderizado tem `data:` flat com KEY=VALUE, o Secret renderizado tem `stringData:` com `REPLACE_ME_*`, e o Deployment tem `envFrom:` apontando pra ambos.

---

## Phase 0: Pre-work

### Task 0.1: Verificar dependências dos charts

**Files:** read-only, sem mudanças

- [ ] **Step 1: Verificar versão do Helm**

Run: `helm version --short`
Expected: `v3.14.0+` ou superior. Se inferior, instalar Helm 3.14+ antes de prosseguir.

- [ ] **Step 2: Buildar dependência `_library` em todos os charts a tocar**

Run:
```bash
for c in aegis-ai-core aegis-metric-worker aegis-otel-worker aegis-query-api aegis-portal; do
  echo "--- $c ---"
  helm dependency update charts/$c
done
```
Expected: cada chart imprime `Saving 1 charts ... Deleting outdated charts`. Cria `charts/<chart>/charts/aegis-library-0.1.0.tgz`.

- [ ] **Step 3: Sanidade — rodar lint/template baseline antes de qualquer mudança**

Run:
```bash
for c in aegis-ai-core aegis-metric-worker aegis-otel-worker aegis-query-api aegis-portal; do
  echo "--- $c ---"
  helm lint charts/$c
done
```
Expected: todos passam (`1 chart(s) linted, 0 chart(s) failed`). Se algum falhar, parar e investigar — não é regressão deste plano.

- [ ] **Step 4: Sem commit nessa fase** (tudo read-only)

---

## Phase 1: aegis-otel-worker

Chart mais simples (1 secret entry, 1 ConfigMap pequeno) — usar como referência para o padrão.

### Task 1.1: Atualizar `values.yaml`

**Files:**
- Modify: `charts/aegis-otel-worker/values.yaml`

- [ ] **Step 1: Substituir bloco `worker:` e adicionar `external:`, `secretsStaging:`, `env:`**

Substituir, em `charts/aegis-otel-worker/values.yaml`, o bloco:

```yaml
worker:
  port: 8080
  kafkaTopic: otel-traces
  consumerGroup: aegis-otel-worker
  kafkaBrokers: "aegis-kafka:9092"
  clickhouseConnection: "tcp://aegis-clickhouse:9000/aegisops"
  topologyExtractionEnabled: true

secrets:
  credentials: ""
```

por:

```yaml
worker:
  name: otel-worker
  port: 8080

# Endpoints externos ao cluster (droplet Docker DigitalOcean na mesma VPC).
# Em staging: trocar infraHost para o IP/hostname privado do droplet.
external:
  infraHost: aegis-kafka  # default dev; override em values-staging.yaml
  kafkaPort: 9092
  clickhousePort: 9000
  postgresPort: 5432

# Variáveis de ambiente injetadas via ConfigMap (não-sensíveis).
env:
  KAFKA_TOPICS: otel-traces
  KAFKA_GROUP_ID: otel-worker-group
  CLICKHOUSE_DB: default
  LOG_LEVEL: info
  METRICS_PORT: "9090"
  HEALTH_PORT: "8080"
  CH_BATCH_SIZE: "5000"
  CH_FLUSH_INTERVAL: 5s

# Secret de staging (renderizado apenas se enabled=true).
# DSNs com password ficam aqui (compostas a partir de external.infraHost).
secretsStaging:
  enabled: false
  topologyDbPassword: REPLACE_ME_TOPOLOGY_DB_PASSWORD

# Pattern legacy mantido para backwards-compat com ambientes prod.
secrets:
  credentials: ""
```

- [ ] **Step 2: Salvar e validar YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('charts/aegis-otel-worker/values.yaml'))"`
Expected: sem erro.

### Task 1.2: Reescrever `templates/configmap.yaml`

**Files:**
- Modify: `charts/aegis-otel-worker/templates/configmap.yaml`

- [ ] **Step 1: Substituir conteúdo inteiro**

Substituir o arquivo `charts/aegis-otel-worker/templates/configmap.yaml` por:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "aegis.fullname" . }}
  labels:
    {{- include "aegis.labels" . | nindent 4 }}
data:
  WORKER_NAME: {{ .Values.worker.name | quote }}
  KAFKA_BROKERS: "{{ .Values.external.infraHost }}:{{ .Values.external.kafkaPort }}"
  CLICKHOUSE_ADDRS: "{{ .Values.external.infraHost }}:{{ .Values.external.clickhousePort }}"
  {{- range $k, $v := .Values.env }}
  {{ $k }}: {{ $v | quote }}
  {{- end }}
```

- [ ] **Step 2: Validar template**

Run: `helm template aegis-otel-worker charts/aegis-otel-worker --show-only templates/configmap.yaml`
Expected: ConfigMap rendered sem erro, com `data:` contendo `WORKER_NAME: "otel-worker"`, `KAFKA_BROKERS: "aegis-kafka:9092"` (default dev), `CLICKHOUSE_ADDRS: "aegis-kafka:9000"`, e os campos do `env:` (`KAFKA_TOPICS`, `KAFKA_GROUP_ID`, etc.).

### Task 1.3: Criar `templates/secret-staging.yaml`

**Files:**
- Create: `charts/aegis-otel-worker/templates/secret-staging.yaml`

- [ ] **Step 1: Criar arquivo**

Criar `charts/aegis-otel-worker/templates/secret-staging.yaml`:

```yaml
{{- if .Values.secretsStaging.enabled }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "aegis.fullname" . }}-staging
  labels:
    {{- include "aegis.labels" . | nindent 4 }}
type: Opaque
stringData:
  POSTGRES_DSN: "postgres://dodo:{{ .Values.secretsStaging.topologyDbPassword }}@{{ .Values.external.infraHost }}:{{ .Values.external.postgresPort }}/dodo_topology?sslmode=disable"
{{- end }}
```

- [ ] **Step 2: Verificar guard funciona (NÃO renderiza por default)**

Run: `helm template aegis-otel-worker charts/aegis-otel-worker --show-only templates/secret-staging.yaml`
Expected: vazio ou erro `could not find template ... in chart` (Helm não renderiza arquivos vazios). Aceitável.

- [ ] **Step 3: Verificar guard libera com flag**

Run: `helm template aegis-otel-worker charts/aegis-otel-worker --show-only templates/secret-staging.yaml --set secretsStaging.enabled=true`
Expected: Secret YAML com `name: aegis-otel-worker-staging`, `type: Opaque`, `stringData: POSTGRES_DSN: "postgres://dodo:REPLACE_ME_TOPOLOGY_DB_PASSWORD@aegis-kafka:5432/dodo_topology?sslmode=disable"`.

### Task 1.4: Atualizar `templates/deployment.yaml`

**Files:**
- Modify: `charts/aegis-otel-worker/templates/deployment.yaml`

- [ ] **Step 1: Adicionar `envFrom` e remover volume `config` mountado**

Editar `charts/aegis-otel-worker/templates/deployment.yaml`. Substituir o bloco a partir de `{{- if .Values.secrets.credentials }}` até o final (linhas 49–65 do arquivo atual), por:

```yaml
          envFrom:
            - configMapRef:
                name: {{ include "aegis.fullname" . }}
            {{- if .Values.secretsStaging.enabled }}
            - secretRef:
                name: {{ include "aegis.fullname" . }}-staging
            {{- end }}
            {{- if .Values.secrets.credentials }}
            - secretRef:
                name: {{ .Values.secrets.credentials }}
            {{- end }}
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
```

> Removidos: `volumeMounts.config`, `volumes.config (configMap)`. Container não monta mais `/etc/aegis-worker` — todas as envvars vêm via `envFrom`.

- [ ] **Step 2: Validar template completo**

Run: `helm template aegis-otel-worker charts/aegis-otel-worker --show-only templates/deployment.yaml`
Expected: Deployment renderiza, container `worker` tem `envFrom: - configMapRef: name: aegis-otel-worker`, sem volume `config`, sem `secretRef` (default dev sem secretsStaging).

- [ ] **Step 3: Validar com staging ativado**

Run: `helm template aegis-otel-worker charts/aegis-otel-worker --show-only templates/deployment.yaml --set secretsStaging.enabled=true`
Expected: `envFrom` agora tem 2 entradas: `configMapRef` + `secretRef: name: aegis-otel-worker-staging`.

### Task 1.5: Atualizar `values-staging.yaml`

**Files:**
- Modify: `charts/aegis-otel-worker/values-staging.yaml`

- [ ] **Step 1: Adicionar overrides de staging**

Substituir conteúdo inteiro de `charts/aegis-otel-worker/values-staging.yaml` por:

```yaml
# =============================================================================
# aegis-otel-worker — Staging Environment Values
# =============================================================================
# Infra (Postgres, Kafka, ClickHouse) roda no droplet Docker DigitalOcean na
# mesma VPC do cluster DOKS. Antes de aplicar, trocar `external.infraHost`
# pelo IP/hostname privado do droplet, e os campos `secretsStaging.*` pelos
# valores reais.
# =============================================================================

image:
  repository: registry.digitalocean.com/dodo-aegisops-staging/dodo_otel_worker
  tag: "latest"
  pullPolicy: Always

imagePullSecrets:
  - name: registry-dodo-aegisops-staging

replicaCount: 2

resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi

# Endpoints externos — substituir infraHost pelo IP/hostname privado do droplet
external:
  infraHost: REPLACE_ME_DROPLET_VPC_HOST
  kafkaPort: 9092
  clickhousePort: 9000
  postgresPort: 5432

# Worker-specific configmap entries (overrides do default values.yaml)
env:
  WORKER_NAME: otel-worker
  KAFKA_TOPICS: otel-traces
  KAFKA_GROUP_ID: otel-worker-group
  CLICKHOUSE_DB: default
  LOG_LEVEL: info
  METRICS_PORT: "9090"
  HEALTH_PORT: "8080"
  CH_BATCH_SIZE: "5000"
  CH_FLUSH_INTERVAL: 5s

# Secret de staging — substituir os REPLACE_ME_* pelos valores reais antes do helm install
secretsStaging:
  enabled: true
  topologyDbPassword: REPLACE_ME_TOPOLOGY_DB_PASSWORD

# Network policy — permite egress para o droplet (qualquer host fora do cluster)
networkPolicy:
  enabled: true
  allowDNS: true
  ingress: []
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.169.254/32  # block IMDS
      ports:
        - protocol: TCP
          port: 9092  # Kafka
        - protocol: TCP
          port: 9000  # ClickHouse
        - protocol: TCP
          port: 5432  # Postgres (topologia)
```

### Task 1.6: Validar e commitar

- [ ] **Step 1: Lint**

Run: `make lint CHART=aegis-otel-worker`
Expected: `1 chart(s) linted, 0 chart(s) failed`.

- [ ] **Step 2: Render com staging**

Run: `make template CHART=aegis-otel-worker ENV=staging > /tmp/otel-staging.yaml`
Expected: arquivo gerado, sem erro.

- [ ] **Step 3: Inspecionar manualmente**

Run: `grep -A 30 "kind: Deployment" /tmp/otel-staging.yaml | head -60`
Expected: ver `envFrom` com `configMapRef` + `secretRef: name: aegis-otel-worker-staging`.

Run: `grep -A 5 "kind: Secret" /tmp/otel-staging.yaml`
Expected: Secret com `POSTGRES_DSN: postgres://dodo:REPLACE_ME_TOPOLOGY_DB_PASSWORD@REPLACE_ME_DROPLET_VPC_HOST:5432/dodo_topology?sslmode=disable`.

- [ ] **Step 4: Verificar nenhum segredo real**

Run: `grep -RnE "sk-(ant|test|live)|eyJ[A-Za-z0-9]" charts/aegis-otel-worker/ | grep -v REPLACE_ME || echo "OK"`
Expected: `OK`.

- [ ] **Step 5: Commit**

```bash
git add charts/aegis-otel-worker/
git commit -m "feat(staging): wire aegis-otel-worker configmap and secret-staging

- Replace mounted config.yaml with flat KEY=VALUE ConfigMap consumed via envFrom
- Add templates/secret-staging.yaml gated by secretsStaging.enabled
- Introduce external.infraHost for droplet VPC endpoints
- Update values-staging.yaml with REPLACE_ME placeholders for the staging deploy"
```

---

## Phase 2: aegis-metric-worker

Mesmo padrão da Phase 1, com mais env vars e dois secrets (TIMESCALEDB_DSN com password, REDIS_PASSWORD).

### Task 2.1: Atualizar `values.yaml`

**Files:**
- Modify: `charts/aegis-metric-worker/values.yaml`

- [ ] **Step 1: Substituir bloco `worker:` e `secrets:`**

Substituir as linhas 60–69 (do `worker:` até `credentials: ""`) de `charts/aegis-metric-worker/values.yaml` por:

```yaml
worker:
  name: metric-worker
  port: 8080

external:
  infraHost: aegis-kafka  # default dev
  kafkaPort: 9092
  timescalePort: 5433  # droplet expõe TimescaleDB na 5433
  redisPort: 6379

env:
  KAFKA_TOPICS: raw-metrics
  KAFKA_GROUP_ID: metric-worker-group
  KAFKA_MAX_RETRIES: "3"
  KAFKA_DLQ_ENABLED: "true"
  WORKER_CONCURRENCY: "1"
  HEALTH_PORT: "8081"
  METRICS_PORT: "8080"
  SHUTDOWN_TIMEOUT: 30s
  LOG_LEVEL: info
  AUTO_MIGRATE: "true"
  BATCH_SIZE: "5000"
  FLUSH_INTERVAL: 1s
  LIVE_PUBLISH_ENABLED: "true"
  LIVE_PUBLISH_BUFFER_SIZE: "10000"
  LIVE_PUBLISH_RATE_LIMIT: "0"

secretsStaging:
  enabled: false
  timescalePassword: REPLACE_ME_TIMESCALE_PASSWORD
  redisPassword: ""

secrets:
  credentials: ""
```

> ⚠️ Nota: o chart referenciava `metrics.port: 9090`, mas o `.env` real do worker usa `METRICS_PORT=8080` e `HEALTH_PORT=8081`. Mantemos `metrics.port=9090` no chart (Prometheus annotations apontam pra lá), mas o ConfigMap injeta `METRICS_PORT=8080` para o app. Se isso for inconsistente com o app real, ajustar `metrics.port` em `values-staging.yaml` para `8080`.

- [ ] **Step 2: Validar YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('charts/aegis-metric-worker/values.yaml'))"`
Expected: sem erro.

### Task 2.2: Reescrever `templates/configmap.yaml`

**Files:**
- Modify: `charts/aegis-metric-worker/templates/configmap.yaml`

- [ ] **Step 1: Substituir conteúdo inteiro**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "aegis.fullname" . }}
  labels:
    {{- include "aegis.labels" . | nindent 4 }}
data:
  WORKER_NAME: {{ .Values.worker.name | quote }}
  KAFKA_BROKERS: "{{ .Values.external.infraHost }}:{{ .Values.external.kafkaPort }}"
  REDIS_ADDR: "{{ .Values.external.infraHost }}:{{ .Values.external.redisPort }}"
  {{- range $k, $v := .Values.env }}
  {{ $k }}: {{ $v | quote }}
  {{- end }}
```

- [ ] **Step 2: Validar template**

Run: `helm template aegis-metric-worker charts/aegis-metric-worker --show-only templates/configmap.yaml`
Expected: ConfigMap com `KAFKA_BROKERS: "aegis-kafka:9092"`, `REDIS_ADDR: "aegis-kafka:6379"` (default dev) + todos os campos de `env:`.

### Task 2.3: Criar `templates/secret-staging.yaml`

**Files:**
- Create: `charts/aegis-metric-worker/templates/secret-staging.yaml`

- [ ] **Step 1: Criar arquivo**

```yaml
{{- if .Values.secretsStaging.enabled }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "aegis.fullname" . }}-staging
  labels:
    {{- include "aegis.labels" . | nindent 4 }}
type: Opaque
stringData:
  TIMESCALEDB_DSN: "postgres://dodo:{{ .Values.secretsStaging.timescalePassword }}@{{ .Values.external.infraHost }}:{{ .Values.external.timescalePort }}/dodo_metrics?sslmode=disable"
  REDIS_PASSWORD: {{ .Values.secretsStaging.redisPassword | quote }}
{{- end }}
```

- [ ] **Step 2: Verificar render com flag**

Run: `helm template aegis-metric-worker charts/aegis-metric-worker --show-only templates/secret-staging.yaml --set secretsStaging.enabled=true`
Expected: Secret com `TIMESCALEDB_DSN: postgres://dodo:REPLACE_ME_TIMESCALE_PASSWORD@aegis-kafka:5433/dodo_metrics?sslmode=disable`, `REDIS_PASSWORD: ""`.

### Task 2.4: Atualizar `templates/deployment.yaml`

**Files:**
- Modify: `charts/aegis-metric-worker/templates/deployment.yaml`

- [ ] **Step 1: Substituir mesmo bloco da Phase 1**

Substituir o bloco a partir de `{{- if .Values.secrets.credentials }}` até o final (linhas 49–65) de `charts/aegis-metric-worker/templates/deployment.yaml` por:

```yaml
          envFrom:
            - configMapRef:
                name: {{ include "aegis.fullname" . }}
            {{- if .Values.secretsStaging.enabled }}
            - secretRef:
                name: {{ include "aegis.fullname" . }}-staging
            {{- end }}
            {{- if .Values.secrets.credentials }}
            - secretRef:
                name: {{ .Values.secrets.credentials }}
            {{- end }}
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
```

- [ ] **Step 2: Validar**

Run: `helm template aegis-metric-worker charts/aegis-metric-worker --show-only templates/deployment.yaml --set secretsStaging.enabled=true`
Expected: `envFrom` com 2 entradas, sem volume `config`.

### Task 2.5: Atualizar `values-staging.yaml`

**Files:**
- Modify: `charts/aegis-metric-worker/values-staging.yaml`

- [ ] **Step 1: Substituir conteúdo inteiro**

```yaml
# =============================================================================
# aegis-metric-worker — Staging Environment Values
# =============================================================================
# Infra no droplet Docker DigitalOcean (mesma VPC). Trocar external.infraHost
# pelo IP/hostname privado do droplet antes de helm install.
# =============================================================================

image:
  repository: registry.digitalocean.com/dodo-aegisops-staging/dodo_metric_worker
  tag: "latest"
  pullPolicy: Always

imagePullSecrets:
  - name: registry-dodo-aegisops-staging

replicaCount: 2

resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi

external:
  infraHost: REPLACE_ME_DROPLET_VPC_HOST
  kafkaPort: 9092
  timescalePort: 5433
  redisPort: 6379

env:
  KAFKA_TOPICS: raw-metrics
  KAFKA_GROUP_ID: metric-worker-group
  KAFKA_MAX_RETRIES: "3"
  KAFKA_DLQ_ENABLED: "true"
  WORKER_CONCURRENCY: "1"
  HEALTH_PORT: "8081"
  METRICS_PORT: "8080"
  SHUTDOWN_TIMEOUT: 30s
  LOG_LEVEL: info
  AUTO_MIGRATE: "true"
  BATCH_SIZE: "5000"
  FLUSH_INTERVAL: 1s
  LIVE_PUBLISH_ENABLED: "true"
  LIVE_PUBLISH_BUFFER_SIZE: "10000"
  LIVE_PUBLISH_RATE_LIMIT: "0"

secretsStaging:
  enabled: true
  timescalePassword: REPLACE_ME_TIMESCALE_PASSWORD
  redisPassword: ""  # preencher se Redis tiver AUTH habilitado

networkPolicy:
  enabled: true
  allowDNS: true
  ingress: []
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.169.254/32
      ports:
        - protocol: TCP
          port: 9092
        - protocol: TCP
          port: 5433
        - protocol: TCP
          port: 6379
```

### Task 2.6: Validar e commitar

- [ ] **Step 1**: `make lint CHART=aegis-metric-worker` → Expected: pass.
- [ ] **Step 2**: `make template CHART=aegis-metric-worker ENV=staging > /tmp/metric-staging.yaml` → Expected: sem erro.
- [ ] **Step 3**: `grep -A 5 "TIMESCALEDB_DSN" /tmp/metric-staging.yaml` → Expected: ver DSN com `REPLACE_ME_DROPLET_VPC_HOST` e `REPLACE_ME_TIMESCALE_PASSWORD`.
- [ ] **Step 4**: `grep -RnE "sk-(ant|test|live)|eyJ[A-Za-z0-9]" charts/aegis-metric-worker/ | grep -v REPLACE_ME || echo OK` → Expected: `OK`.
- [ ] **Step 5: Commit**

```bash
git add charts/aegis-metric-worker/
git commit -m "feat(staging): wire aegis-metric-worker configmap and secret-staging"
```

---

## Phase 3: aegis-ai-core

Chart maior. Mantém PVC `model-cache`, init container, GPU support e tmp volume — só substitui o config.yaml mountado por envFrom.

### Task 3.1: Atualizar `values.yaml`

**Files:**
- Modify: `charts/aegis-ai-core/values.yaml`

- [ ] **Step 1: Substituir bloco `aiCore:` e `secrets:`**

Substituir as linhas 100–118 (do `# AI Core configuration` até `certificates: ""`) de `charts/aegis-ai-core/values.yaml` por:

```yaml
# AI Core configuration
aiCore:
  port: 8080

external:
  infraHost: aegis-postgresql  # default dev (in-cluster pgvector)
  postgresPort: 5432
  redisPort: 6379

# Variáveis de ambiente injetadas via ConfigMap (não-sensíveis).
# Tipos com aspas explícitas garantem string serialization.
env:
  DODO_ENVIRONMENT: development
  DODO_LOG_LEVEL: INFO
  DODO_API_HOST: 0.0.0.0
  DODO_DB_POOL_MIN: "2"
  DODO_DB_POOL_MAX: "10"
  DODO_EMBEDDING_CACHE_TTL: "3600"
  DODO_LLM_PROVIDER: anthropic
  DODO_LLM_MODEL: claude-sonnet-4-6
  DODO_LLM_API_BASE: ""
  DODO_CLAUDE_MODEL: claude-sonnet-4-6
  DODO_CLAUDE_MAX_TOKENS: "4096"
  DODO_CLAUDE_TEMPERATURE: "0.2"
  DODO_CLAUDE_TIMEOUT: "60"
  DODO_CLAUDE_MAX_RETRIES: "3"
  DODO_CLAUDE_RATE_LIMIT_PER_MIN: "30"
  DODO_CB_FAILURE_THRESHOLD: "5"
  DODO_CB_RECOVERY_TIMEOUT: "300"
  DODO_EMBEDDING_DIMENSION: "1536"
  DODO_EMBEDDING_MODEL: text-embedding-3-small
  DODO_CHUNK_MAX_TOKENS: "2000"
  DODO_CHUNK_OVERLAP_TOKENS: "200"
  DODO_SIMILARITY_THRESHOLD: "0.7"
  DODO_SIMILARITY_TOP_K: "5"
  DODO_SIMILARITY_TIMEOUT: "5"
  DODO_POLICY_EVAL_TIMEOUT: "5.0"
  DODO_RISK_WEIGHT_BLAST_RADIUS: "0.30"
  DODO_RISK_WEIGHT_REVERSIBILITY: "0.25"
  DODO_RISK_WEIGHT_EFFICACY: "0.20"
  DODO_RISK_WEIGHT_CONFIDENCE: "0.15"
  DODO_RISK_WEIGHT_SLO_URGENCY: "0.10"
  DODO_RL_EXPLORATION_RATE: "0.3"
  DODO_RL_MIN_EXPLORATION_RATE: "0.05"
  DODO_RL_EXPLORATION_DECAY: "0.01"
  DODO_RETRAIN_IF_INTERVAL_HOURS: "24"
  DODO_RETRAIN_XGB_INTERVAL_HOURS: "48"
  DODO_RETRAIN_EMB_INTERVAL_HOURS: "12"
  DODO_FEEDBACK_DIAGNOSIS_THRESHOLD: "0.7"
  DODO_FEEDBACK_REMEDIATION_THRESHOLD: "0.8"
  DODO_FEEDBACK_ADJUSTMENT_STEP: "0.02"
  DODO_PROMPT_GUARD_ALERT_THRESHOLD: "5"
  DODO_PROMPT_GUARD_ALERT_WINDOW_SECONDS: "3600.0"

# Feature flags consumidas como envvars individuais pelo deployment.yaml
# (mantidas separadas para fácil override via --set)
featureFlags:
  anomalyDetection: true
  ragEnabled: true
  classificationEnabled: true
  remediationEnabled: false

# Secret de staging — habilita em values-staging.yaml.
# DSNs com password/api keys ficam aqui.
secretsStaging:
  enabled: false
  anthropicApiKey: REPLACE_ME_ANTHROPIC_API_KEY
  databasePassword: REPLACE_ME_AICORE_DB_PASSWORD
  databaseName: dodo_ai_core
  databaseUser: dodo

# Pattern legacy mantido para forward-compat
secrets:
  llmApiKeys: ""
  dbCredentials: ""
  certificates: ""
```

- [ ] **Step 2: Validar YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('charts/aegis-ai-core/values.yaml'))"`
Expected: sem erro.

### Task 3.2: Reescrever `templates/configmap.yaml`

**Files:**
- Modify: `charts/aegis-ai-core/templates/configmap.yaml`

- [ ] **Step 1: Substituir conteúdo inteiro**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "aegis.fullname" . }}
  labels:
    {{- include "aegis.labels" . | nindent 4 }}
data:
  DODO_API_PORT: {{ .Values.aiCore.port | quote }}
  DODO_MODELS_PATH: {{ .Values.modelCache.mountPath | quote }}
  ANOMALY_DETECTION_ENABLED: {{ .Values.featureFlags.anomalyDetection | quote }}
  RAG_ENABLED: {{ .Values.featureFlags.ragEnabled | quote }}
  CLASSIFICATION_ENABLED: {{ .Values.featureFlags.classificationEnabled | quote }}
  REMEDIATION_ENABLED: {{ .Values.featureFlags.remediationEnabled | quote }}
  {{- range $k, $v := .Values.env }}
  {{ $k }}: {{ $v | quote }}
  {{- end }}
```

- [ ] **Step 2: Validar template**

Run: `helm template aegis-ai-core charts/aegis-ai-core --show-only templates/configmap.yaml`
Expected: ConfigMap com `DODO_API_PORT: "8080"`, `DODO_MODELS_PATH: "/models"`, feature flags, e todos os campos de `env:`.

### Task 3.3: Criar `templates/secret-staging.yaml`

**Files:**
- Create: `charts/aegis-ai-core/templates/secret-staging.yaml`

- [ ] **Step 1: Criar arquivo**

```yaml
{{- if .Values.secretsStaging.enabled }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "aegis.fullname" . }}-staging
  labels:
    {{- include "aegis.labels" . | nindent 4 }}
type: Opaque
stringData:
  DODO_LLM_API_KEY: {{ .Values.secretsStaging.anthropicApiKey | quote }}
  DODO_CLAUDE_API_KEY: {{ .Values.secretsStaging.anthropicApiKey | quote }}
  DODO_DATABASE_URL: "postgresql://{{ .Values.secretsStaging.databaseUser }}:{{ .Values.secretsStaging.databasePassword }}@{{ .Values.external.infraHost }}:{{ .Values.external.postgresPort }}/{{ .Values.secretsStaging.databaseName }}"
  DODO_REDIS_URL: "redis://{{ .Values.external.infraHost }}:{{ .Values.external.redisPort }}/0"
{{- end }}
```

- [ ] **Step 2: Validar com flag**

Run: `helm template aegis-ai-core charts/aegis-ai-core --show-only templates/secret-staging.yaml --set secretsStaging.enabled=true`
Expected: Secret com `DODO_LLM_API_KEY: "REPLACE_ME_ANTHROPIC_API_KEY"`, `DODO_DATABASE_URL: "postgresql://dodo:REPLACE_ME_AICORE_DB_PASSWORD@aegis-postgresql:5432/dodo_ai_core"`, etc.

### Task 3.4: Atualizar `templates/deployment.yaml`

**Files:**
- Modify: `charts/aegis-ai-core/templates/deployment.yaml`

- [ ] **Step 1: Substituir bloco env+envFrom+volumeMounts**

Substituir o bloco a partir da linha `env:` (linha 78) até o fim do `volumes:` (linha 112) por:

```yaml
          envFrom:
            - configMapRef:
                name: {{ include "aegis.fullname" . }}
            {{- if .Values.secretsStaging.enabled }}
            - secretRef:
                name: {{ include "aegis.fullname" . }}-staging
            {{- end }}
            {{- if .Values.secrets.llmApiKeys }}
            - secretRef:
                name: {{ .Values.secrets.llmApiKeys }}
            {{- end }}
            {{- if .Values.secrets.dbCredentials }}
            - secretRef:
                name: {{ .Values.secrets.dbCredentials }}
            {{- end }}
          volumeMounts:
            {{- if .Values.modelCache.enabled }}
            - name: model-cache
              mountPath: {{ .Values.modelCache.mountPath }}
            {{- end }}
            - name: tmp
              mountPath: /tmp
      volumes:
        {{- if .Values.modelCache.enabled }}
        - name: model-cache
          persistentVolumeClaim:
            claimName: {{ include "aegis.fullname" . }}-models
        {{- end }}
        - name: tmp
          emptyDir: {}
```

> Removidos: bloco `env:` com 4 entradas (feature flags), `envFrom` original (que dependia só de `secrets.llmApiKeys`), volume `config` (configmap montado).
> Mantidos: model-cache PVC, init container (não toca), tmp volume.

- [ ] **Step 2: Validar**

Run: `helm template aegis-ai-core charts/aegis-ai-core --show-only templates/deployment.yaml --set secretsStaging.enabled=true`
Expected: container `ai-core` tem `envFrom` com `configMapRef` + `secretRef: aegis-ai-core-staging`. `volumeMounts` tem `model-cache` e `tmp`.

### Task 3.5: Atualizar `values-staging.yaml`

**Files:**
- Modify: `charts/aegis-ai-core/values-staging.yaml`

- [ ] **Step 1: Substituir conteúdo inteiro**

```yaml
# =============================================================================
# aegis-ai-core — Staging Environment Values
# =============================================================================
# pgvector e Redis rodam no droplet Docker DigitalOcean (mesma VPC).
# Trocar external.infraHost pelo IP/hostname privado do droplet,
# anthropicApiKey e databasePassword pelos valores reais.
# =============================================================================

image:
  repository: registry.digitalocean.com/dodo-aegisops-staging/dodo_ai_core
  tag: "latest"
  pullPolicy: Always

imagePullSecrets:
  - name: registry-dodo-aegisops-staging

replicaCount: 1

resources:
  requests:
    cpu: 500m
    memory: 1Gi
  limits:
    cpu: 1000m
    memory: 2Gi

gpu:
  enabled: false

modelCache:
  size: 10Gi

external:
  infraHost: REPLACE_ME_DROPLET_VPC_HOST
  postgresPort: 5432
  redisPort: 6379

env:
  DODO_ENVIRONMENT: staging
  DODO_LOG_LEVEL: INFO
  DODO_API_HOST: 0.0.0.0
  DODO_DB_POOL_MIN: "2"
  DODO_DB_POOL_MAX: "10"
  DODO_EMBEDDING_CACHE_TTL: "3600"
  DODO_LLM_PROVIDER: anthropic
  DODO_LLM_MODEL: claude-sonnet-4-6
  DODO_LLM_API_BASE: ""
  DODO_CLAUDE_MODEL: claude-sonnet-4-6
  DODO_CLAUDE_MAX_TOKENS: "4096"
  DODO_CLAUDE_TEMPERATURE: "0.2"
  DODO_CLAUDE_TIMEOUT: "60"
  DODO_CLAUDE_MAX_RETRIES: "3"
  DODO_CLAUDE_RATE_LIMIT_PER_MIN: "30"
  DODO_CB_FAILURE_THRESHOLD: "5"
  DODO_CB_RECOVERY_TIMEOUT: "300"
  DODO_EMBEDDING_DIMENSION: "1536"
  DODO_EMBEDDING_MODEL: text-embedding-3-small
  DODO_CHUNK_MAX_TOKENS: "2000"
  DODO_CHUNK_OVERLAP_TOKENS: "200"
  DODO_SIMILARITY_THRESHOLD: "0.7"
  DODO_SIMILARITY_TOP_K: "5"
  DODO_SIMILARITY_TIMEOUT: "5"
  DODO_POLICY_EVAL_TIMEOUT: "5.0"
  DODO_RISK_WEIGHT_BLAST_RADIUS: "0.30"
  DODO_RISK_WEIGHT_REVERSIBILITY: "0.25"
  DODO_RISK_WEIGHT_EFFICACY: "0.20"
  DODO_RISK_WEIGHT_CONFIDENCE: "0.15"
  DODO_RISK_WEIGHT_SLO_URGENCY: "0.10"
  DODO_RL_EXPLORATION_RATE: "0.3"
  DODO_RL_MIN_EXPLORATION_RATE: "0.05"
  DODO_RL_EXPLORATION_DECAY: "0.01"
  DODO_RETRAIN_IF_INTERVAL_HOURS: "24"
  DODO_RETRAIN_XGB_INTERVAL_HOURS: "48"
  DODO_RETRAIN_EMB_INTERVAL_HOURS: "12"
  DODO_FEEDBACK_DIAGNOSIS_THRESHOLD: "0.7"
  DODO_FEEDBACK_REMEDIATION_THRESHOLD: "0.8"
  DODO_FEEDBACK_ADJUSTMENT_STEP: "0.02"
  DODO_PROMPT_GUARD_ALERT_THRESHOLD: "5"
  DODO_PROMPT_GUARD_ALERT_WINDOW_SECONDS: "3600.0"

featureFlags:
  anomalyDetection: true
  ragEnabled: true
  classificationEnabled: true
  remediationEnabled: false  # validar antes de habilitar

secretsStaging:
  enabled: true
  anthropicApiKey: REPLACE_ME_ANTHROPIC_API_KEY
  databasePassword: REPLACE_ME_AICORE_DB_PASSWORD
  databaseName: dodo_ai_core
  databaseUser: dodo
```

### Task 3.6: Validar e commitar

- [ ] **Step 1**: `make lint CHART=aegis-ai-core` → pass.
- [ ] **Step 2**: `make template CHART=aegis-ai-core ENV=staging > /tmp/aicore-staging.yaml` → sem erro.
- [ ] **Step 3**: `grep -A 3 "DODO_DATABASE_URL" /tmp/aicore-staging.yaml` → ver DSN com `REPLACE_ME_*`.
- [ ] **Step 4**: `grep -RnE "sk-(ant|test|live)|eyJ[A-Za-z0-9]" charts/aegis-ai-core/ | grep -v REPLACE_ME || echo OK` → `OK`.
- [ ] **Step 5: Commit**

```bash
git add charts/aegis-ai-core/
git commit -m "feat(staging): wire aegis-ai-core configmap and secret-staging"
```

---

## Phase 4: aegis-query-api

Maior número de envvars. Adiciona Secret separado `aegis-query-api-jwt` (volume-mounted) para a chave pública JWT.

### Task 4.1: Atualizar `values.yaml`

**Files:**
- Modify: `charts/aegis-query-api/values.yaml`

- [ ] **Step 1: Substituir blocos `queryApi:` e `secrets:`**

Substituir as linhas 81–91 (`queryApi:` até `dbCredentials: ""`) por:

```yaml
queryApi:
  port: 8080

external:
  infraHost: aegis-timescaledb  # default dev
  timescalePort: 5433
  clickhousePort: 9000
  postgresPort: 5432
  redisPort: 6379

env:
  DODO_QUERY_READ_TIMEOUT: 30s
  DODO_QUERY_WRITE_TIMEOUT: 30s
  DODO_QUERY_SHUTDOWN_TIMEOUT: 30s
  DODO_QUERY_GRAPHQL_MAX_DEPTH: "10"
  DODO_QUERY_GRAPHQL_MAX_COMPLEXITY: "1000"
  DODO_QUERY_GRAPHQL_PLAYGROUND_ENABLED: "false"
  DODO_QUERY_WS_MAX_CONNECTIONS: "10000"
  DODO_QUERY_WS_PING_INTERVAL: 30s
  DODO_QUERY_WS_PONG_TIMEOUT: 10s
  DODO_QUERY_TIMESCALEDB_MAX_OPEN_CONNS: "25"
  DODO_QUERY_TIMESCALEDB_MAX_IDLE_CONNS: "10"
  DODO_QUERY_TIMESCALEDB_CONN_MAX_LIFETIME: 5m
  DODO_QUERY_CLICKHOUSE_MAX_OPEN_CONNS: "10"
  DODO_QUERY_CLICKHOUSE_MAX_IDLE_CONNS: "5"
  DODO_QUERY_POSTGRESQL_MAX_OPEN_CONNS: "25"
  DODO_QUERY_POSTGRESQL_MAX_IDLE_CONNS: "10"
  DODO_QUERY_POSTGRESQL_CONN_MAX_LIFETIME: 5m
  DODO_QUERY_REDIS_DB: "0"
  DODO_QUERY_REDIS_POOL_SIZE: "20"
  DODO_QUERY_REDIS_MIN_IDLE_CONNS: "5"
  DODO_QUERY_JWT_PUBLIC_KEY_PATH: /etc/aegis-query-api/certs/jwt-public.pem
  DODO_QUERY_JWT_ISSUER: dodo_portal
  DODO_QUERY_JWT_AUDIENCE: dodo_query_api
  DODO_QUERY_RATELIMIT_ENABLED: "true"
  DODO_QUERY_RATELIMIT_REQUESTS_PER_SECOND: "100"
  DODO_QUERY_RATELIMIT_BURST_SIZE: "200"
  DODO_QUERY_CACHE_DEFAULT_TTL: 30s
  DODO_QUERY_CACHE_METRICS_TTL: 0s
  DODO_QUERY_CACHE_TOPOLOGY_TTL: 30s
  DODO_QUERY_LOG_LEVEL: info
  DODO_QUERY_LOG_FORMAT: json
  DODO_AI_CORE_URL: http://aegis-ai-core:8080

secretsStaging:
  enabled: false
  timescalePassword: REPLACE_ME_TIMESCALE_PASSWORD
  clickhousePassword: REPLACE_ME_CLICKHOUSE_PASSWORD
  cmdbPassword: REPLACE_ME_CMDB_DB_PASSWORD
  redisPassword: ""
  # JWT público — base64 do conteúdo do PEM. Gerar com: base64 -i jwt-public.pem -o -
  jwtPublicKeyB64: REPLACE_ME_JWT_PUBKEY_BASE64

secrets:
  dbCredentials: ""
```

- [ ] **Step 2**: `python3 -c "import yaml; yaml.safe_load(open('charts/aegis-query-api/values.yaml'))"` → sem erro.

### Task 4.2: Reescrever `templates/configmap.yaml`

**Files:**
- Modify: `charts/aegis-query-api/templates/configmap.yaml`

- [ ] **Step 1: Substituir conteúdo inteiro**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "aegis.fullname" . }}
  labels:
    {{- include "aegis.labels" . | nindent 4 }}
data:
  DODO_QUERY_HTTP_PORT: {{ .Values.queryApi.port | quote }}
  DODO_QUERY_REDIS_ADDRESS: "{{ .Values.external.infraHost }}:{{ .Values.external.redisPort }}"
  {{- range $k, $v := .Values.env }}
  {{ $k }}: {{ $v | quote }}
  {{- end }}
```

- [ ] **Step 2**: `helm template aegis-query-api charts/aegis-query-api --show-only templates/configmap.yaml` → ver `DODO_QUERY_HTTP_PORT: "8080"`, `DODO_QUERY_REDIS_ADDRESS: "aegis-timescaledb:6379"` (default dev), todos os env.

### Task 4.3: Criar `templates/secret-staging.yaml`

**Files:**
- Create: `charts/aegis-query-api/templates/secret-staging.yaml`

- [ ] **Step 1: Criar arquivo**

```yaml
{{- if .Values.secretsStaging.enabled }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "aegis.fullname" . }}-staging
  labels:
    {{- include "aegis.labels" . | nindent 4 }}
type: Opaque
stringData:
  DODO_QUERY_TIMESCALEDB_DSN: "postgres://dodo:{{ .Values.secretsStaging.timescalePassword }}@{{ .Values.external.infraHost }}:{{ .Values.external.timescalePort }}/dodo_metrics?sslmode=disable"
  DODO_QUERY_CLICKHOUSE_DSN: "clickhouse://dodo:{{ .Values.secretsStaging.clickhousePassword }}@{{ .Values.external.infraHost }}:{{ .Values.external.clickhousePort }}/dodo"
  DODO_QUERY_POSTGRESQL_DSN: "postgres://dodo:{{ .Values.secretsStaging.cmdbPassword }}@{{ .Values.external.infraHost }}:{{ .Values.external.postgresPort }}/dodo_cmdb?sslmode=disable"
  DODO_QUERY_REDIS_PASSWORD: {{ .Values.secretsStaging.redisPassword | quote }}
{{- end }}
```

- [ ] **Step 2**: validar com `--set secretsStaging.enabled=true` → ver as 4 DSNs com `REPLACE_ME_*`.

### Task 4.4: Criar `templates/secret-jwt.yaml`

**Files:**
- Create: `charts/aegis-query-api/templates/secret-jwt.yaml`

- [ ] **Step 1: Criar arquivo**

```yaml
{{- if .Values.secretsStaging.enabled }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "aegis.fullname" . }}-jwt
  labels:
    {{- include "aegis.labels" . | nindent 4 }}
type: Opaque
data:
  jwt-public.pem: {{ .Values.secretsStaging.jwtPublicKeyB64 | quote }}
{{- end }}
```

- [ ] **Step 2**: `helm template aegis-query-api charts/aegis-query-api --show-only templates/secret-jwt.yaml --set secretsStaging.enabled=true` → ver Secret com `data.jwt-public.pem: REPLACE_ME_JWT_PUBKEY_BASE64`.

### Task 4.5: Atualizar `templates/deployment.yaml`

**Files:**
- Modify: `charts/aegis-query-api/templates/deployment.yaml`

- [ ] **Step 1: Substituir bloco `envFrom` + `volumeMounts` + `volumes`**

Substituir o bloco a partir de `{{- if .Values.secrets.dbCredentials }}` (linha 55) até o fim de `volumes:` (linha 71) por:

```yaml
          envFrom:
            - configMapRef:
                name: {{ include "aegis.fullname" . }}
            {{- if .Values.secretsStaging.enabled }}
            - secretRef:
                name: {{ include "aegis.fullname" . }}-staging
            {{- end }}
            {{- if .Values.secrets.dbCredentials }}
            - secretRef:
                name: {{ .Values.secrets.dbCredentials }}
            {{- end }}
          volumeMounts:
            {{- if .Values.secretsStaging.enabled }}
            - name: jwt-certs
              mountPath: /etc/aegis-query-api/certs
              readOnly: true
            {{- end }}
            - name: tmp
              mountPath: /tmp
      volumes:
        {{- if .Values.secretsStaging.enabled }}
        - name: jwt-certs
          secret:
            secretName: {{ include "aegis.fullname" . }}-jwt
            defaultMode: 0444
        {{- end }}
        - name: tmp
          emptyDir: {}
```

> Removidos: volume `config` (configmap mount) e seu volumeMount.

- [ ] **Step 2**: `helm template aegis-query-api charts/aegis-query-api --show-only templates/deployment.yaml --set secretsStaging.enabled=true` → ver `envFrom` com 2 entradas, `volumeMounts.jwt-certs` em `/etc/aegis-query-api/certs`, volume `jwt-certs` referenciando `aegis-query-api-jwt`.

### Task 4.6: Atualizar `values-staging.yaml`

**Files:**
- Modify: `charts/aegis-query-api/values-staging.yaml`

- [ ] **Step 1: Substituir conteúdo inteiro**

```yaml
# =============================================================================
# aegis-query-api — Staging Environment Values
# =============================================================================
# Bancos no droplet Docker DigitalOcean (mesma VPC). JWT público em Secret
# separado (volume-mounted como arquivo). Trocar external.infraHost,
# secretsStaging.* e gerar jwtPublicKeyB64 (`base64 -i jwt-public.pem -o -`).
# =============================================================================

image:
  repository: registry.digitalocean.com/dodo-aegisops-staging/dodo_query_api
  tag: "latest"
  pullPolicy: Always

imagePullSecrets:
  - name: registry-dodo-aegisops-staging

replicaCount: 2

hpa:
  enabled: true
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 70

resources:
  requests:
    cpu: 200m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi

external:
  infraHost: REPLACE_ME_DROPLET_VPC_HOST
  timescalePort: 5433
  clickhousePort: 9000
  postgresPort: 5432
  redisPort: 6379

env:
  DODO_QUERY_READ_TIMEOUT: 30s
  DODO_QUERY_WRITE_TIMEOUT: 30s
  DODO_QUERY_SHUTDOWN_TIMEOUT: 30s
  DODO_QUERY_GRAPHQL_MAX_DEPTH: "10"
  DODO_QUERY_GRAPHQL_MAX_COMPLEXITY: "1000"
  DODO_QUERY_GRAPHQL_PLAYGROUND_ENABLED: "false"
  DODO_QUERY_WS_MAX_CONNECTIONS: "10000"
  DODO_QUERY_WS_PING_INTERVAL: 30s
  DODO_QUERY_WS_PONG_TIMEOUT: 10s
  DODO_QUERY_TIMESCALEDB_MAX_OPEN_CONNS: "25"
  DODO_QUERY_TIMESCALEDB_MAX_IDLE_CONNS: "10"
  DODO_QUERY_TIMESCALEDB_CONN_MAX_LIFETIME: 5m
  DODO_QUERY_CLICKHOUSE_MAX_OPEN_CONNS: "10"
  DODO_QUERY_CLICKHOUSE_MAX_IDLE_CONNS: "5"
  DODO_QUERY_POSTGRESQL_MAX_OPEN_CONNS: "25"
  DODO_QUERY_POSTGRESQL_MAX_IDLE_CONNS: "10"
  DODO_QUERY_POSTGRESQL_CONN_MAX_LIFETIME: 5m
  DODO_QUERY_REDIS_DB: "0"
  DODO_QUERY_REDIS_POOL_SIZE: "20"
  DODO_QUERY_REDIS_MIN_IDLE_CONNS: "5"
  DODO_QUERY_JWT_PUBLIC_KEY_PATH: /etc/aegis-query-api/certs/jwt-public.pem
  DODO_QUERY_JWT_ISSUER: dodo_portal
  DODO_QUERY_JWT_AUDIENCE: dodo_query_api
  DODO_QUERY_RATELIMIT_ENABLED: "true"
  DODO_QUERY_RATELIMIT_REQUESTS_PER_SECOND: "100"
  DODO_QUERY_RATELIMIT_BURST_SIZE: "200"
  DODO_QUERY_CACHE_DEFAULT_TTL: 30s
  DODO_QUERY_CACHE_METRICS_TTL: 0s
  DODO_QUERY_CACHE_TOPOLOGY_TTL: 30s
  DODO_QUERY_LOG_LEVEL: info
  DODO_QUERY_LOG_FORMAT: json
  DODO_AI_CORE_URL: http://aegis-ai-core:8080

secretsStaging:
  enabled: true
  timescalePassword: REPLACE_ME_TIMESCALE_PASSWORD
  clickhousePassword: REPLACE_ME_CLICKHOUSE_PASSWORD
  cmdbPassword: REPLACE_ME_CMDB_DB_PASSWORD
  redisPassword: ""
  jwtPublicKeyB64: REPLACE_ME_JWT_PUBKEY_BASE64

queryApi:
  corsAllowedOrigins: "https://dashboard.staging.aegisops.io,https://portal.staging.aegisops.io"

networkPolicy:
  enabled: true
  allowDNS: true
  ingress:
    - ports:
        - protocol: TCP
          port: 8080
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.169.254/32
      ports:
        - protocol: TCP
          port: 5432
        - protocol: TCP
          port: 5433
        - protocol: TCP
          port: 9000
        - protocol: TCP
          port: 6379
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: aegis-ai-core
      ports:
        - protocol: TCP
          port: 8080
```

### Task 4.7: Validar e commitar

- [ ] **Step 1**: `make lint CHART=aegis-query-api` → pass.
- [ ] **Step 2**: `make template CHART=aegis-query-api ENV=staging > /tmp/queryapi-staging.yaml` → sem erro.
- [ ] **Step 3**: `grep -A 5 "DODO_QUERY_TIMESCALEDB_DSN\|DODO_QUERY_CLICKHOUSE_DSN\|DODO_QUERY_POSTGRESQL_DSN" /tmp/queryapi-staging.yaml` → ver as 3 DSNs com `REPLACE_ME_*`.
- [ ] **Step 4**: `grep -B 2 -A 5 "name: aegis-query-api-jwt" /tmp/queryapi-staging.yaml` → ver Secret JWT.
- [ ] **Step 5**: `grep -RnE "sk-(ant|test|live)|eyJ[A-Za-z0-9]" charts/aegis-query-api/ | grep -v REPLACE_ME || echo OK` → `OK`.
- [ ] **Step 6: Commit**

```bash
git add charts/aegis-query-api/
git commit -m "feat(staging): wire aegis-query-api configmap, secret-staging and JWT secret"
```

---

## Phase 5: aegis-portal

Caso especial: Next.js inlina `NEXT_PUBLIC_*` em build time. Variáveis no pod servem só para SSR/API routes.

### Task 5.1: Atualizar `values.yaml`

**Files:**
- Modify: `charts/aegis-portal/values.yaml`

- [ ] **Step 1: Substituir bloco `portal:`**

Substituir as linhas 79–83 (`portal:` até `analyticsConfig: {}`) por:

```yaml
portal:
  port: 3000

external:
  infraHost: aegis-redis  # default dev
  redisPort: 6379

# Variáveis de ambiente injetadas via ConfigMap (não-sensíveis).
# Atenção Next.js: NEXT_PUBLIC_* aqui só atendem o SSR / API routes do Node.
# O bundle JS do client foi inlinado em build time pelo Dockerfile do dodo_portal —
# o repo `dodo_portal` precisa publicar imagem com os build-args corretos para staging
# (ARG NEXT_PUBLIC_*). Override aqui sozinho NÃO atualiza o bundle do browser.
env:
  NEXT_PUBLIC_APP_URL: http://localhost:3000
  ALLOWED_ORIGINS: http://localhost:3000
  NEXT_PUBLIC_API_URL: http://localhost:4000
  PORTAL_QUERY_API_URL: http://aegis-query-api:8080

secretsStaging:
  enabled: false
  supabaseProjectUrl: REPLACE_ME_SUPABASE_PROJECT_URL
  supabasePublishableKey: REPLACE_ME_SUPABASE_PUBLISHABLE_KEY
  supabaseServiceRoleKey: REPLACE_ME_SUPABASE_SERVICE_ROLE_KEY
  stripeSecretKey: REPLACE_ME_STRIPE_SECRET_KEY
  stripePublishableKey: REPLACE_ME_STRIPE_PUBLISHABLE_KEY
  stripeWebhookSecret: REPLACE_ME_STRIPE_WEBHOOK_SECRET
  stripePriceProMonthly: REPLACE_ME_STRIPE_PRICE_PRO_MONTHLY
  stripePriceProYearly: REPLACE_ME_STRIPE_PRICE_PRO_YEARLY
  databaseUrl: REPLACE_ME_SUPABASE_POOLER_URL
  redisPassword: ""
```

- [ ] **Step 2**: `python3 -c "import yaml; yaml.safe_load(open('charts/aegis-portal/values.yaml'))"` → sem erro.

### Task 5.2: Reescrever `templates/configmap.yaml`

**Files:**
- Modify: `charts/aegis-portal/templates/configmap.yaml`

- [ ] **Step 1: Substituir conteúdo inteiro**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "aegis.fullname" . }}
  labels:
    {{- include "aegis.labels" . | nindent 4 }}
data:
  PORT: {{ .Values.portal.port | quote }}
  NEXT_PUBLIC_SUPABASE_URL: {{ .Values.secretsStaging.supabaseProjectUrl | quote }}
  NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: {{ .Values.secretsStaging.supabasePublishableKey | quote }}
  {{- range $k, $v := .Values.env }}
  {{ $k }}: {{ $v | quote }}
  {{- end }}
```

> Nota: `NEXT_PUBLIC_SUPABASE_URL` e `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` são considerados públicos no Supabase (publishable key foi feita pra ser exposta no client), por isso ficam no ConfigMap mesmo. Os service role keys e Stripe secrets vão pro Secret.

- [ ] **Step 2**: `helm template aegis-portal charts/aegis-portal --show-only templates/configmap.yaml` → sem erro.

### Task 5.3: Criar `templates/secret-staging.yaml`

**Files:**
- Create: `charts/aegis-portal/templates/secret-staging.yaml`

- [ ] **Step 1: Criar arquivo**

```yaml
{{- if .Values.secretsStaging.enabled }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "aegis.fullname" . }}-staging
  labels:
    {{- include "aegis.labels" . | nindent 4 }}
type: Opaque
stringData:
  SUPABASE_SERVICE_ROLE_KEY: {{ .Values.secretsStaging.supabaseServiceRoleKey | quote }}
  STRIPE_SECRET_KEY: {{ .Values.secretsStaging.stripeSecretKey | quote }}
  STRIPE_PUBLISHABLE_KEY: {{ .Values.secretsStaging.stripePublishableKey | quote }}
  STRIPE_WEBHOOK_SECRET: {{ .Values.secretsStaging.stripeWebhookSecret | quote }}
  STRIPE_PRICE_PRO_MONTHLY: {{ .Values.secretsStaging.stripePriceProMonthly | quote }}
  STRIPE_PRICE_PRO_YEARLY: {{ .Values.secretsStaging.stripePriceProYearly | quote }}
  DATABASE_URL: {{ .Values.secretsStaging.databaseUrl | quote }}
  REDIS_URL: "redis://{{ .Values.external.infraHost }}:{{ .Values.external.redisPort }}"
{{- end }}
```

- [ ] **Step 2**: `helm template aegis-portal charts/aegis-portal --show-only templates/secret-staging.yaml --set secretsStaging.enabled=true` → ver Secret com `STRIPE_SECRET_KEY: REPLACE_ME_STRIPE_SECRET_KEY`, etc.

### Task 5.4: Atualizar `templates/deployment.yaml`

**Files:**
- Modify: `charts/aegis-portal/templates/deployment.yaml`

- [ ] **Step 1: Adicionar `envFrom` e remover volume `config`**

Substituir, em `charts/aegis-portal/templates/deployment.yaml`, o bloco a partir de `{{- include "aegis.containerSecurityContext" . | nindent 10 }}` (linha 46) até o fim do `volumes:` (linha 62), por:

```yaml
          {{- include "aegis.containerSecurityContext" . | nindent 10 }}
          envFrom:
            - configMapRef:
                name: {{ include "aegis.fullname" . }}
            {{- if .Values.secretsStaging.enabled }}
            - secretRef:
                name: {{ include "aegis.fullname" . }}-staging
            {{- end }}
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: nextjs-cache
              mountPath: /app/.next/cache
      volumes:
        - name: tmp
          emptyDir: {}
        - name: nextjs-cache
          emptyDir: {}
```

> Removidos: volumeMount `config` (`/etc/aegis-portal`), volume `config` (configMap mount).

- [ ] **Step 2**: `helm template aegis-portal charts/aegis-portal --show-only templates/deployment.yaml --set secretsStaging.enabled=true` → ver `envFrom` + 2 volumeMounts (`tmp`, `nextjs-cache`), sem volume `config`.

### Task 5.5: Atualizar `values-staging.yaml`

**Files:**
- Modify: `charts/aegis-portal/values-staging.yaml`

- [ ] **Step 1: Substituir conteúdo inteiro**

```yaml
# =============================================================================
# aegis-portal — Staging Environment Values
# =============================================================================
# Portal Next.js: NEXT_PUBLIC_* aqui valem para SSR/API routes. O bundle JS
# do client foi inlinado em build time pelo Dockerfile do dodo_portal —
# certifique-se que a imagem em registry.digitalocean.com foi buildada com
# build-args ARG NEXT_PUBLIC_API_URL=https://api.staging.aegisops.io etc.
#
# Redis roda no droplet Docker (mesma VPC). DB do portal usa Supabase externo.
# =============================================================================

image:
  repository: registry.digitalocean.com/dodo-aegisops-staging/dodo_portal
  tag: "latest"
  pullPolicy: Always

imagePullSecrets:
  - name: registry-dodo-aegisops-staging

replicaCount: 2

hpa:
  enabled: true
  minReplicas: 2
  maxReplicas: 5

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

ingress:
  className: kong
  hostname: portal.staging.aegisops.io
  tls:
    enabled: true
    secretName: portal-staging-tls
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-staging
    konghq.com/protocols: "https"
    konghq.com/https-redirect-status-code: "301"

external:
  infraHost: REPLACE_ME_DROPLET_VPC_HOST
  redisPort: 6379

env:
  NEXT_PUBLIC_APP_URL: https://portal.staging.aegisops.io
  ALLOWED_ORIGINS: https://portal.staging.aegisops.io
  NEXT_PUBLIC_API_URL: https://api.staging.aegisops.io
  PORTAL_QUERY_API_URL: http://aegis-query-api:8080

secretsStaging:
  enabled: true
  supabaseProjectUrl: REPLACE_ME_SUPABASE_PROJECT_URL
  supabasePublishableKey: REPLACE_ME_SUPABASE_PUBLISHABLE_KEY
  supabaseServiceRoleKey: REPLACE_ME_SUPABASE_SERVICE_ROLE_KEY
  stripeSecretKey: REPLACE_ME_STRIPE_SECRET_KEY
  stripePublishableKey: REPLACE_ME_STRIPE_PUBLISHABLE_KEY
  stripeWebhookSecret: REPLACE_ME_STRIPE_WEBHOOK_SECRET
  stripePriceProMonthly: REPLACE_ME_STRIPE_PRICE_PRO_MONTHLY
  stripePriceProYearly: REPLACE_ME_STRIPE_PRICE_PRO_YEARLY
  databaseUrl: REPLACE_ME_SUPABASE_POOLER_URL
  redisPassword: ""
```

### Task 5.6: Validar e commitar

- [ ] **Step 1**: `make lint CHART=aegis-portal` → pass.
- [ ] **Step 2**: `make template CHART=aegis-portal ENV=staging > /tmp/portal-staging.yaml` → sem erro.
- [ ] **Step 3**: `grep -A 8 "kind: Secret" /tmp/portal-staging.yaml | head -20` → ver Secret com `STRIPE_*`, `SUPABASE_SERVICE_ROLE_KEY`, `DATABASE_URL` todos `REPLACE_ME_*`.
- [ ] **Step 4**: `grep -RnE "sk-(ant|test|live)|whsec_[a-zA-Z0-9]|eyJ[A-Za-z0-9]" charts/aegis-portal/ | grep -v REPLACE_ME || echo OK` → `OK`.
- [ ] **Step 5: Commit**

```bash
git add charts/aegis-portal/
git commit -m "feat(staging): wire aegis-portal configmap and secret-staging

NEXT_PUBLIC_* envs in pod serve SSR/API routes only — client bundle
must be rebuilt with build-args matching staging URLs."
```

---

## Phase 6: aegis-alerts (NEW chart)

Chart novo, modelado em cima de `aegis-otel-worker`.

### Task 6.1: Criar diretório e `Chart.yaml`

**Files:**
- Create: `charts/aegis-alerts/Chart.yaml`

- [ ] **Step 1: Criar diretório**

Run: `mkdir -p charts/aegis-alerts/templates`

- [ ] **Step 2: Criar `charts/aegis-alerts/Chart.yaml`**

```yaml
apiVersion: v2
name: aegis-alerts
description: DoDo AegisOps Alerts Worker — Consumes alert events from Kafka, persists to Postgres
type: application
version: 0.1.0
appVersion: "0.1.0"
dependencies:
  - name: aegis-library
    version: "0.1.0"
    repository: "file://../_library"
```

### Task 6.2: Criar `values.yaml`

**Files:**
- Create: `charts/aegis-alerts/values.yaml`

- [ ] **Step 1: Criar arquivo**

```yaml
nameOverride: ""
fullnameOverride: ""
component: alerts
gitSha: ""

image:
  repository: ghcr.io/oppervisiontech/aegis-alerts
  tag: ""
  pullPolicy: IfNotPresent

replicaCount: 1

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

health:
  type: http
  liveness:
    path: /healthz
    port: http
    initialDelay: 10
    period: 20
    timeout: 5
    failureThreshold: 3
  readiness:
    path: /readyz
    port: http
    initialDelay: 5
    period: 10
    timeout: 3
    failureThreshold: 3

serviceAccount:
  create: true
  name: ""
  annotations: {}

podSecurityContext:
  runAsUser: 65534
  runAsGroup: 65534
  fsGroup: 65534

containerSecurityContext:
  readOnlyRootFilesystem: true

metrics:
  enabled: true
  port: 9090
  path: /metrics

service:
  type: ClusterIP
  port: 8084

worker:
  name: alerts-worker
  port: 8084

external:
  infraHost: aegis-kafka  # default dev
  kafkaPort: 9092
  postgresPort: 5432
  redisPort: 6379

env:
  KAFKA_TOPIC: alert-events
  KAFKA_GROUP_ID: alert-worker-group
  HTTP_ADDR: ":8084"
  LOG_LEVEL: info

secretsStaging:
  enabled: false
  cmdbPassword: REPLACE_ME_CMDB_DB_PASSWORD
  portalPassword: REPLACE_ME_PORTAL_DB_PASSWORD

secrets:
  credentials: ""

networkPolicy:
  enabled: true
  allowDNS: true
  ingress:
    - ports:
        - protocol: TCP
          port: 8084
  egress:
    - ports:
        - protocol: TCP
          port: 9092
    - ports:
        - protocol: TCP
          port: 5432
    - ports:
        - protocol: TCP
          port: 6379

tolerations: []
nodeSelector: {}
extraAnnotations: {}
```

### Task 6.3: Criar `templates/configmap.yaml`

**Files:**
- Create: `charts/aegis-alerts/templates/configmap.yaml`

- [ ] **Step 1: Criar arquivo**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "aegis.fullname" . }}
  labels:
    {{- include "aegis.labels" . | nindent 4 }}
data:
  KAFKA_BROKERS: "{{ .Values.external.infraHost }}:{{ .Values.external.kafkaPort }}"
  REDIS_ADDR: "{{ .Values.external.infraHost }}:{{ .Values.external.redisPort }}"
  {{- range $k, $v := .Values.env }}
  {{ $k }}: {{ $v | quote }}
  {{- end }}
```

### Task 6.4: Criar `templates/secret-staging.yaml`

**Files:**
- Create: `charts/aegis-alerts/templates/secret-staging.yaml`

- [ ] **Step 1: Criar arquivo**

```yaml
{{- if .Values.secretsStaging.enabled }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "aegis.fullname" . }}-staging
  labels:
    {{- include "aegis.labels" . | nindent 4 }}
type: Opaque
stringData:
  POSTGRES_DSN: "postgres://dodo:{{ .Values.secretsStaging.cmdbPassword }}@{{ .Values.external.infraHost }}:{{ .Values.external.postgresPort }}/dodo_cmdb?sslmode=disable"
  PORTAL_POSTGRES_DSN: "postgres://dodo:{{ .Values.secretsStaging.portalPassword }}@{{ .Values.external.infraHost }}:{{ .Values.external.postgresPort }}/dodo_portal?sslmode=disable"
{{- end }}
```

### Task 6.5: Criar `templates/deployment.yaml`

**Files:**
- Create: `charts/aegis-alerts/templates/deployment.yaml`

- [ ] **Step 1: Criar arquivo**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "aegis.fullname" . }}
  labels:
    {{- include "aegis.labels" . | nindent 4 }}
  annotations:
    {{- include "aegis.annotations" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      {{- include "aegis.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "aegis.labels" . | nindent 8 }}
      annotations:
        {{- include "aegis.prometheusAnnotations" . | nindent 8 }}
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
    spec:
      serviceAccountName: {{ include "aegis.serviceAccountName" . }}
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- include "aegis.podSecurityContext" . | nindent 6 }}
      {{- with .Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: alerts
          {{- include "aegis.image" . | nindent 10 }}
          ports:
            - name: http
              containerPort: {{ .Values.worker.port }}
              protocol: TCP
            - name: metrics
              containerPort: {{ .Values.metrics.port }}
              protocol: TCP
          {{- include "aegis.healthCheck" . | nindent 10 }}
          {{- include "aegis.resourceLimits" . | nindent 10 }}
          {{- include "aegis.containerSecurityContext" . | nindent 10 }}
          envFrom:
            - configMapRef:
                name: {{ include "aegis.fullname" . }}
            {{- if .Values.secretsStaging.enabled }}
            - secretRef:
                name: {{ include "aegis.fullname" . }}-staging
            {{- end }}
            {{- if .Values.secrets.credentials }}
            - secretRef:
                name: {{ .Values.secrets.credentials }}
            {{- end }}
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
```

### Task 6.6: Criar `templates/service.yaml`, `serviceaccount.yaml`, `networkpolicy.yaml`

**Files:**
- Create: `charts/aegis-alerts/templates/service.yaml`
- Create: `charts/aegis-alerts/templates/serviceaccount.yaml`
- Create: `charts/aegis-alerts/templates/networkpolicy.yaml`

- [ ] **Step 1: `service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "aegis.fullname" . }}
  labels:
    {{- include "aegis.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: http
      protocol: TCP
      name: http
  selector:
    {{- include "aegis.selectorLabels" . | nindent 4 }}
```

- [ ] **Step 2: `serviceaccount.yaml`**

```yaml
{{- if .Values.serviceAccount.create }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "aegis.serviceAccountName" . }}
  labels:
    {{- include "aegis.labels" . | nindent 4 }}
  {{- with .Values.serviceAccount.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
automountServiceAccountToken: false
{{- end }}
```

- [ ] **Step 3: `networkpolicy.yaml`**

```yaml
{{- if .Values.networkPolicy.enabled }}
{{ include "aegis.networkPolicy" . }}
{{- end }}
```

### Task 6.7: Criar `values-staging.yaml`

**Files:**
- Create: `charts/aegis-alerts/values-staging.yaml`

- [ ] **Step 1: Criar arquivo**

```yaml
# =============================================================================
# aegis-alerts — Staging Environment Values
# =============================================================================
# Postgres (CMDB + Portal) e Kafka rodam no droplet Docker DigitalOcean.
# Trocar external.infraHost e secretsStaging.* pelos valores reais.
# =============================================================================

image:
  repository: registry.digitalocean.com/dodo-aegisops-staging/dodo_alerts
  tag: "latest"
  pullPolicy: Always

imagePullSecrets:
  - name: registry-dodo-aegisops-staging

replicaCount: 1

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

external:
  infraHost: REPLACE_ME_DROPLET_VPC_HOST
  kafkaPort: 9092
  postgresPort: 5432
  redisPort: 6379

env:
  KAFKA_TOPIC: alert-events
  KAFKA_GROUP_ID: alert-worker-group
  HTTP_ADDR: ":8084"
  LOG_LEVEL: info

secretsStaging:
  enabled: true
  cmdbPassword: REPLACE_ME_CMDB_DB_PASSWORD
  portalPassword: REPLACE_ME_PORTAL_DB_PASSWORD

networkPolicy:
  enabled: true
  allowDNS: true
  ingress:
    - ports:
        - protocol: TCP
          port: 8084
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.169.254/32
      ports:
        - protocol: TCP
          port: 9092
        - protocol: TCP
          port: 5432
        - protocol: TCP
          port: 6379
```

### Task 6.8: Criar `values-prod.yaml` (placeholder)

**Files:**
- Create: `charts/aegis-alerts/values-prod.yaml`

- [ ] **Step 1: Criar arquivo**

```yaml
# =============================================================================
# aegis-alerts — Production Environment Values
# =============================================================================
# Placeholder. Preencher antes de habilitar prod.
# =============================================================================

image:
  repository: ghcr.io/oppervisiontech/aegis-alerts
  tag: "latest"
  pullPolicy: IfNotPresent

replicaCount: 2

resources:
  requests:
    cpu: 200m
    memory: 256Mi
  limits:
    cpu: 1000m
    memory: 1Gi

# Em prod, segredos virão de external-secrets-operator via secrets.credentials
secrets:
  credentials: aegis-alerts-credentials

secretsStaging:
  enabled: false
```

### Task 6.9: Validar e commitar

- [ ] **Step 1**: Build dependency: `helm dependency update charts/aegis-alerts` → Expected: `Saving 1 charts ...`
- [ ] **Step 2**: `make lint CHART=aegis-alerts` → pass.
- [ ] **Step 3**: `make template CHART=aegis-alerts ENV=staging > /tmp/alerts-staging.yaml` → sem erro.
- [ ] **Step 4**: `grep -A 5 "POSTGRES_DSN\|PORTAL_POSTGRES_DSN" /tmp/alerts-staging.yaml` → ver as 2 DSNs com `REPLACE_ME_*`.
- [ ] **Step 5**: `grep -A 30 "kind: Deployment" /tmp/alerts-staging.yaml | head -40` → confirmar `envFrom` com `configMapRef` + `secretRef`.
- [ ] **Step 6**: `grep -RnE "sk-(ant|test|live)|eyJ[A-Za-z0-9]" charts/aegis-alerts/ | grep -v REPLACE_ME || echo OK` → `OK`.
- [ ] **Step 7: Commit**

```bash
git add charts/aegis-alerts/
git commit -m "feat(staging): create aegis-alerts chart with configmap and secret-staging

New chart for the dodo_alerts service. Wires Kafka, Postgres CMDB and
Postgres portal endpoints to the droplet via external.infraHost."
```

---

## Phase 7: README documentation

### Task 7.1: Atualizar `README.md`

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Adicionar `aegis-alerts` na lista de charts (linha ~24)**

Editar `README.md`. Substituir:

```text
  aegis-otel-worker/     # OTEL Worker Deployment
  aegis-dashboard/       # Dashboard Deployment + Ingress
```

por:

```text
  aegis-otel-worker/     # OTEL Worker Deployment
  aegis-alerts/          # Alerts Worker Deployment
  aegis-dashboard/       # Dashboard Deployment + Ingress
```

- [ ] **Step 2: Adicionar seção "Staging deployment" antes de "Conventions"**

Adicionar antes da seção `## Conventions` (que começa em torno da linha 70):

```markdown
## Staging deployment

Staging usa o cluster DOKS para apps e um droplet Docker (mesma VPC DigitalOcean) para a infra (Postgres, TimescaleDB, ClickHouse, Kafka, Redis). Charts de infra (`aegis-postgresql`, `aegis-clickhouse`, `aegis-kafka`, `aegis-redis`, `aegis-timescaledb`) **não devem ser instalados em staging** — substituídos pelo droplet Docker.

### Charts cobertos por staging

`aegis-ai-core`, `aegis-alerts`, `aegis-metric-worker`, `aegis-otel-worker`, `aegis-portal`, `aegis-query-api`.

### Como aplicar

Cada chart traz `values-staging.yaml` com placeholders. Antes de `helm install`, substituir:

1. **`external.infraHost`** — IP/hostname privado do droplet Docker (ex.: `10.110.0.5` ou `dodo-infra.internal`). É a única porta de entrada para os DSNs.
2. **`secretsStaging.*`** — todos os campos com prefixo `REPLACE_ME_` (passwords de DB, API keys da Anthropic, Stripe keys, Supabase service role, JWT public key em base64).

Exemplo (chart `aegis-metric-worker`):

```bash
# Opção 1: editar values-staging.yaml localmente (não commitar com valores reais)
$EDITOR charts/aegis-metric-worker/values-staging.yaml

# Opção 2: --set inline (preferido — não toca o arquivo)
helm install aegis-metric-worker charts/aegis-metric-worker \
  -f charts/aegis-metric-worker/values-staging.yaml \
  --set external.infraHost=10.110.0.5 \
  --set secretsStaging.timescalePassword="$(op read 'op://staging/timescale/password')" \
  -n aegisops
```

### Como o secret é gerado

O template `secret-staging.yaml` em cada chart é renderizado **apenas se** `secretsStaging.enabled=true`. Os valores em `stringData:` são strings — o Helm não os codifica em base64 (Kubernetes faz no apply).

Para o JWT public key do `aegis-query-api`:

```bash
# Gerar base64 do PEM (uma linha, sem quebras)
JWT_PUB=$(base64 -i /path/to/jwt-public.pem | tr -d '\n')
helm install aegis-query-api charts/aegis-query-api \
  -f charts/aegis-query-api/values-staging.yaml \
  --set external.infraHost=10.110.0.5 \
  --set secretsStaging.jwtPublicKeyB64="$JWT_PUB" \
  ...
```

### Verificação anti-vazamento

Antes de commitar, verificar que nenhum credencial real foi adicionado por engano:

```bash
grep -RnE "sk-(ant|test|live)|eyJ[A-Za-z0-9]|whsec_[a-zA-Z0-9]" charts/ \
  | grep -v REPLACE_ME \
  | grep -v _helpers.tpl \
  || echo "OK: nenhum segredo real"
```

### Limitação Next.js (aegis-portal)

`NEXT_PUBLIC_*` configuradas no `values-staging.yaml` valem **apenas para SSR/API routes do Node**. O bundle JS do client foi inlinado em build time pelo Dockerfile de `dodo_portal` — a imagem em `registry.digitalocean.com/dodo-aegisops-staging/dodo_portal` precisa ser publicada com `ARG NEXT_PUBLIC_API_URL=https://api.staging.aegisops.io` etc. Override no Helm sozinho não atualiza o JS do browser.
```

- [ ] **Step 3: Validar Markdown render localmente** (opcional)

Run: `which mdcat && mdcat README.md | head -100 || head -100 README.md`
Expected: render visual ou conteúdo plano legível.

### Task 7.2: Commitar

- [ ] **Step 1: Commit**

```bash
git add README.md
git commit -m "docs: add staging deployment section explaining REPLACE_ME workflow"
```

---

## Phase 8: Final repo-wide validation

### Task 8.1: Lint todos os charts tocados

- [ ] **Step 1**: Lint conjunto

```bash
for c in aegis-ai-core aegis-alerts aegis-metric-worker aegis-otel-worker aegis-portal aegis-query-api; do
  echo "--- $c ---"
  helm lint charts/$c
done
```
Expected: todos passam.

### Task 8.2: Render staging para os 6 charts

- [ ] **Step 1**: Render conjunto

```bash
mkdir -p /tmp/staging-render
for c in aegis-ai-core aegis-alerts aegis-metric-worker aegis-otel-worker aegis-portal aegis-query-api; do
  echo "--- $c ---"
  helm template $c charts/$c -f charts/$c/values-staging.yaml > /tmp/staging-render/$c.yaml || echo "FAILED: $c"
done
ls -la /tmp/staging-render/
```
Expected: 6 arquivos não-vazios, sem `FAILED`.

### Task 8.3: Verificar nenhum segredo real commitado

- [ ] **Step 1**: Scan global

```bash
grep -RnE "sk-(ant|test|live)|eyJ[A-Za-z0-9]|whsec_[a-zA-Z0-9]" charts/ \
  | grep -v REPLACE_ME \
  | grep -v _helpers.tpl
```
Expected: vazio (sem matches). Se aparecer algo, investigar e remover antes de seguir.

### Task 8.4: Lint baseline em charts não-tocados

- [ ] **Step 1**: Confirmar que charts fora de escopo continuam linting (sem regressão indireta)

```bash
make lint-all
```
Expected: todos os charts passam (incluindo `aegis-agent`, `aegis-dashboard`, infra charts, etc.).

### Task 8.5: Tag final commit (opcional)

- [ ] **Step 1**: Se há trabalho pendente neste branch, push para PR. Se feature branch já estiver criada, este é apenas o final do escopo do plan; não há tag aqui.

---

## Self-Review Checklist (antes de mergear)

- [ ] Todos os 6 charts (5 modificados + 1 novo) lintam.
- [ ] `make template ENV=staging` renderiza cada chart sem erro.
- [ ] Nenhum credencial real (`sk-`, `eyJ`, `whsec_`) commitado fora de `REPLACE_ME_*`.
- [ ] `external.infraHost` é a **única** referência ao hostname do droplet (sem hardcode em DSN).
- [ ] Secrets em `templates/secret-staging.yaml` têm guard `{{- if .Values.secretsStaging.enabled }}`.
- [ ] Deployments têm `envFrom: [configMapRef, secretRef (gated), secretRef legacy (gated)]`.
- [ ] README documenta o workflow `REPLACE_ME_*` → real values.
- [ ] Charts de prod/qa/dev (não-tocados) continuam linting.
- [ ] aegis-portal tem o aviso sobre NEXT_PUBLIC_* + build-args.
- [ ] aegis-query-api tem Secret JWT separado, volume-mounted em `/etc/aegis-query-api/certs`.
