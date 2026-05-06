# Design — ConfigMap + Secret de staging para charts AegisOps

> **Data**: 2026-05-03
> **Repo**: `dodo_helm_charts`
> **Ambiente alvo**: `staging` (DOKS + droplet Docker na mesma VPC DigitalOcean)

---

## 1. Contexto

Os repos de aplicação (`dodo_ai_core`, `dodo_alerts`, `dodo_metric_worker`, `dodo_query_api`, `dodo_otel_worker`, `dodo_portal`) já têm `.env` definidos para dev/local. Falta materializar esses `.env` como `ConfigMap` + `Secret` Kubernetes versionados em `dodo_helm_charts`, customizados para o ambiente `staging`.

Topologia do staging:

- **DOKS (cluster Kubernetes)** — apps. Comunicação app↔app via DNS in-cluster (`aegis-<svc>:<port>`).
- **Droplet Docker (mesma VPC DO)** — data layer (Postgres, TimescaleDB, ClickHouse, Kafka, Redis). IP/hostname privado **ainda desconhecido**; será descoberto quando o droplet for provisionado.
- **Externos** — Anthropic API (LLM), Supabase (DB do `dodo_portal`), Stripe.

`dodo_alerts` ainda **não tem chart** no repo — será criado nesta entrega.

## 2. Decisões de design

| # | Decisão | Justificativa |
|---|---|---|
| D1 | ConfigMap em formato flat `KEY=VALUE` consumido via `envFrom: configMapRef` | Casa 1:1 com o `.env`; padrão mais comum em apps cloud-native. Substitui o `config.yaml` montado existente, que era resíduo de scaffold. |
| D2 | Secret manifesto versionado em `templates/secret-staging.yaml` por chart, com guard `.Values.secretsStaging.enabled` (default `false` em `values.yaml`, `true` em `values-staging.yaml`) | Centraliza segredos do staging em arquivo único por chart. Default `false` impede vazamento para prod/qa/dev. Padrão `secrets.<name>` antigo (referência externa por nome) é mantido para forward-compat com prod. |
| D3 | Valores secretos placeholder no padrão `REPLACE_ME_<DESCRIÇÃO>` | Garante que nenhum credencial real é commitado. Falha óbvia se aplicado sem substituição. |
| D4 | Único value `external.infraHost` por chart consumidor de infra, default `REPLACE_ME_DROPLET_VPC_HOST` | Usuário troca uma linha quando souber o IP/hostname privado do droplet, em vez de editar cada DSN. Portas externalizadas em `external.<svc>Port` para flexibilidade. |
| D5 | DSNs com password compostas inteiras dentro do Secret (não no ConfigMap) | DSN com `user:password@host` é credencial — não pode vazar via ConfigMap. |
| D6 | JWT public key (`aegis-query-api`) como Secret separado `aegis-query-api-jwt`, volume-mounted | É um arquivo (`.pem`), não env var. Separar permite rotação independente da DSN. |
| D7 | Portal: `NEXT_PUBLIC_*` setadas no pod (servem ao SSR + API routes), com comentário no chart explicando que o **client bundle** precisa ter sido buildado com os mesmos valores via build-args do Dockerfile | Next.js inlina `NEXT_PUBLIC_*` em build time; setar no pod sozinho não atualiza o JS do browser. Rebuild da imagem é responsabilidade do repo `dodo_portal`, fora do escopo deste chart. |
| D8 | `aegis-alerts` lê `dodo_portal` direto do Postgres do droplet (não via Supabase) | O `.env` do alerts mostra `localhost:5435` (droplet), distinto do Supabase usado pelo frontend portal. Suposição: backend interno conversa com o Postgres do droplet, frontend portal usa Supabase. Confirmar com a equipe ao primeiro `helm install`. |
| D9 | Redis sem auth no staging (Secret tem `REDIS_PASSWORD=""` com comentário) | Default DigitalOcean Redis em VPC pode rodar sem AUTH. Se ativar, troca o valor no Secret. |
| D10 | Charts de infra (`aegis-postgresql`, `aegis-timescaledb`, `aegis-clickhouse`, `aegis-kafka`, `aegis-redis`) **não** são instalados no staging | Infra roda no droplet via Docker. Documentar no `README.md` que esses charts são reservados para outros ambientes (ou mover para `dodo_helm_charts_infra` no futuro split). |

## 3. Estrutura de arquivos

Cada chart afetado segue a mesma estrutura:

```
charts/<chart>/
├── Chart.yaml
├── templates/
│   ├── configmap.yaml          ← REESCRITO: data: KEY=VALUE flat
│   ├── secret-staging.yaml     ← NOVO: stringData REPLACE_ME_*, guard secretsStaging.enabled
│   ├── deployment.yaml         ← MODIFICADO: dropa volumeMount /etc/aegis-*, usa envFrom
│   └── (outros arquivos inalterados)
├── values.yaml                 ← MODIFICADO: secretsStaging.enabled=false; nova seção env (KEY=VALUE)
└── values-staging.yaml         ← MODIFICADO: secretsStaging.enabled=true, external.infraHost, secrets.* placeholders
```

Convenção de nomes:

- ConfigMap: `{{ include "aegis.fullname" . }}` (mantém nome atual)
- Secret de staging: `{{ include "aegis.fullname" . }}-staging`
- Secret JWT (apenas query-api): `{{ include "aegis.fullname" . }}-jwt`

## 4. Padrão `envFrom` no deployment

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
  {{- if .Values.secrets.llmApiKeys }}
  - secretRef:
      name: {{ .Values.secrets.llmApiKeys }}
  {{- end }}
```

A ordem importa: `secretsStaging` sobrescreve `configMapRef`; `secrets.*` (pattern legacy) sobrescreve ambos. Em prod, `secretsStaging.enabled=false` e o pattern `secrets.dbCredentials` continua funcionando.

## 5. Padrão `external.infraHost`

`values-staging.yaml` (charts consumidores de infra):

```yaml
external:
  infraHost: REPLACE_ME_DROPLET_VPC_HOST  # IP/hostname privado VPC, ex.: 10.110.0.5
  postgresPort: 5432
  timescalePort: 5433
  clickhousePort: 9000
  kafkaPort: 9092
  redisPort: 6379
```

`templates/secret-staging.yaml` exemplo (metric-worker):

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

`values-staging.yaml` correspondente:

```yaml
secretsStaging:
  enabled: true
  timescalePassword: REPLACE_ME_TIMESCALE_PASSWORD
  redisPassword: ""  # preencher se Redis tiver AUTH habilitado
```

## 6. Mapping `.env` → ConfigMap/Secret por chart

> Nas tabelas abaixo, `<infraHost>` é abreviação de `{{ .Values.external.infraHost }}` (e portas idem com `<infraHost>:{{ .Values.external.<svc>Port }}`). Ports literais são vars do próprio chart e ficam templated no manifesto real.

### 6.1 `aegis-ai-core`

**ConfigMap** (`data:`):
```
DODO_ENVIRONMENT: staging
DODO_LOG_LEVEL: INFO
DODO_API_HOST: 0.0.0.0
DODO_API_PORT: "{{ .Values.aiCore.port }}"   # templated — fonte única (default 8080)
DODO_MODELS_PATH: "{{ .Values.modelCache.mountPath }}"   # templated (default /models)
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
```

> **Omitidas intencionalmente** do ConfigMap: `DODO_POLICIES_PATH` e `DODO_PROMPT_GUARD_PATTERNS_PATH`. Esses paths são internos à imagem Docker (relativos ao WORKDIR do app, ex.: `./src/dodo_ai_core/policies`). A app deve usar os defaults compilados — sobrescrever via env só se a imagem mudar a estrutura interna.

**Secret** (`stringData:`):
```
DODO_LLM_API_KEY: REPLACE_ME_ANTHROPIC_API_KEY
DODO_CLAUDE_API_KEY: REPLACE_ME_ANTHROPIC_API_KEY
DODO_DATABASE_URL: postgresql://dodo:REPLACE_ME_AICORE_DB_PASSWORD@<infraHost>:5432/dodo_ai_core
DODO_REDIS_URL: redis://<infraHost>:6379/0
```

### 6.2 `aegis-alerts` (chart novo)

Estrutura completa (espelha `aegis-otel-worker`):
- `Chart.yaml` (apiVersion v2, type application, version 0.1.0, appVersion conforme imagem)
- `templates/`: `configmap.yaml`, `secret-staging.yaml`, `deployment.yaml`, `service.yaml`, `serviceaccount.yaml`, `networkpolicy.yaml`
- `values.yaml`, `values-staging.yaml`, `values-prod.yaml`

**ConfigMap**:
```
KAFKA_BROKERS: <infraHost>:9092
KAFKA_TOPIC: alert-events
KAFKA_GROUP_ID: alert-worker-group
REDIS_ADDR: <infraHost>:6379
HTTP_ADDR: ":8084"
LOG_LEVEL: info
```

**Secret**:
```
POSTGRES_DSN: postgres://dodo:REPLACE_ME_CMDB_DB_PASSWORD@<infraHost>:5432/dodo_cmdb?sslmode=disable
PORTAL_POSTGRES_DSN: postgres://dodo:REPLACE_ME_PORTAL_DB_PASSWORD@<infraHost>:5432/dodo_portal?sslmode=disable
```

### 6.3 `aegis-metric-worker`

**ConfigMap**:
```
WORKER_NAME: metric-worker
KAFKA_BROKERS: <infraHost>:9092
KAFKA_TOPICS: raw-metrics
KAFKA_GROUP_ID: metric-worker-group
KAFKA_MAX_RETRIES: "3"
KAFKA_DLQ_ENABLED: "true"
WORKER_CONCURRENCY: "1"
HEALTH_PORT: "8081"
METRICS_PORT: "8080"
SHUTDOWN_TIMEOUT: 30s
LOG_LEVEL: info
REDIS_ADDR: <infraHost>:6379
AUTO_MIGRATE: "true"
BATCH_SIZE: "5000"
FLUSH_INTERVAL: 1s
LIVE_PUBLISH_ENABLED: "true"
LIVE_PUBLISH_BUFFER_SIZE: "10000"
LIVE_PUBLISH_RATE_LIMIT: "0"
```

**Secret**:
```
TIMESCALEDB_DSN: postgres://dodo:REPLACE_ME_TIMESCALE_PASSWORD@<infraHost>:5433/dodo_metrics?sslmode=disable
REDIS_PASSWORD: ""
```

### 6.4 `aegis-query-api`

**ConfigMap**:
```
DODO_QUERY_HTTP_PORT: "{{ .Values.queryApi.port | default 8080 }}"   # templated, fonte única
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
DODO_QUERY_REDIS_ADDRESS: <infraHost>:6379
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
```

> Nota: `DODO_QUERY_GRAPHQL_PLAYGROUND_ENABLED=false` em staging (era `true` em dev). Log format `json` em staging (era `text` em dev). Log level `info` (era `debug`).

**Secret-staging**:
```
DODO_QUERY_TIMESCALEDB_DSN: postgres://dodo:REPLACE_ME_TIMESCALE_PASSWORD@<infraHost>:5433/dodo_metrics?sslmode=disable
DODO_QUERY_CLICKHOUSE_DSN: clickhouse://dodo:REPLACE_ME_CLICKHOUSE_PASSWORD@<infraHost>:9000/dodo
DODO_QUERY_POSTGRESQL_DSN: postgres://dodo:REPLACE_ME_CMDB_DB_PASSWORD@<infraHost>:5432/dodo_cmdb?sslmode=disable
DODO_QUERY_REDIS_PASSWORD: ""
```

**Secret-jwt** (separado, volume-mounted):
```yaml
{{- if .Values.secretsStaging.enabled }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "aegis.fullname" . }}-jwt
type: Opaque
data:
  jwt-public.pem: {{ .Values.secretsStaging.jwtPublicKeyB64 | default "UkVQTEFDRV9NRV9KV1RfUFVCS0VZX0JBU0U2NA==" | quote }}
{{- end }}
```

Mount no deployment:
```yaml
volumeMounts:
  - name: jwt-certs
    mountPath: /etc/aegis-query-api/certs
    readOnly: true
volumes:
  - name: jwt-certs
    secret:
      secretName: {{ include "aegis.fullname" . }}-jwt
```

### 6.5 `aegis-otel-worker`

**ConfigMap**:
```
WORKER_NAME: otel-worker
KAFKA_BROKERS: <infraHost>:9092
KAFKA_TOPICS: otel-traces
KAFKA_GROUP_ID: otel-worker-group
CLICKHOUSE_ADDRS: <infraHost>:9000
CLICKHOUSE_DB: default
LOG_LEVEL: info
METRICS_PORT: "9090"
HEALTH_PORT: "8080"
CH_BATCH_SIZE: "5000"
CH_FLUSH_INTERVAL: 5s
```

**Secret**:
```
POSTGRES_DSN: postgres://dodo:REPLACE_ME_TOPOLOGY_DB_PASSWORD@<infraHost>:5432/dodo_topology?sslmode=disable
```

### 6.6 `aegis-portal`

**ConfigMap**:
```
NEXT_PUBLIC_APP_URL: https://portal.staging.aegisops.io
ALLOWED_ORIGINS: https://portal.staging.aegisops.io
NEXT_PUBLIC_API_URL: https://api.staging.aegisops.io
NEXT_PUBLIC_SUPABASE_URL: REPLACE_ME_SUPABASE_PROJECT_URL
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: REPLACE_ME_SUPABASE_PUBLISHABLE_KEY
```

> Atenção: `NEXT_PUBLIC_*` aqui só atende SSR/API routes. O bundle JS do client foi inlinado em build time — o repo `dodo_portal` precisa publicar imagem com os build-args corretos para staging. Comentário equivalente vai no `values-staging.yaml`.

**Secret**:
```
SUPABASE_SERVICE_ROLE_KEY: REPLACE_ME_SUPABASE_SERVICE_ROLE_KEY
STRIPE_SECRET_KEY: REPLACE_ME_STRIPE_SECRET_KEY
STRIPE_PUBLISHABLE_KEY: REPLACE_ME_STRIPE_PUBLISHABLE_KEY
STRIPE_WEBHOOK_SECRET: REPLACE_ME_STRIPE_WEBHOOK_SECRET
STRIPE_PRICE_PRO_MONTHLY: REPLACE_ME_STRIPE_PRICE_PRO_MONTHLY
STRIPE_PRICE_PRO_YEARLY: REPLACE_ME_STRIPE_PRICE_PRO_YEARLY
DATABASE_URL: REPLACE_ME_SUPABASE_POOLER_URL
REDIS_URL: redis://<infraHost>:6379
```

## 7. Fora de escopo

- Charts `aegis-agent`, `aegis-dashboard`, `aegis-health-monitor`, `aegis-ingestor`, `aegis-kong`, `aegis-log-worker` (sem `.env` fornecido).
- Charts de infra (`aegis-postgresql`, `aegis-clickhouse`, `aegis-kafka`, `aegis-redis`, `aegis-timescaledb`) — não instalados no staging (substituídos pelo droplet Docker).
- Split do repo em `dodo_helm_charts_infra` (memória `project_helm_charts_split.md`) — escopo separado.
- Rebuild da imagem `dodo_portal` com novos build-args — responsabilidade do repo `dodo_portal`.

## 8. Critérios de sucesso

1. `helm lint charts/<chart>` passa para os 6 charts (5 modificados + 1 novo).
2. `helm template charts/<chart> -f charts/<chart>/values-staging.yaml` renderiza ConfigMap + Secret + Deployment com `envFrom` correto e sem erros.
3. Nenhum credencial real commitado: `grep -RnE "sk-(ant|test|live)|eyJ|password=[^R]" charts/` retorna vazio.
4. Documentação no `README.md` do repo descreve workflow staging:
   - Como definir `external.infraHost` quando o droplet existir.
   - Como substituir cada `REPLACE_ME_*` antes do `helm install`.
   - Quais charts **não** devem ser instalados em staging (infra do droplet).
5. Charts de prod/qa/dev continuam renderizando idênticos (não há regressão em ambientes existentes).

## 9. Riscos & mitigações

| Risco | Mitigação |
|---|---|
| Alguém faz `helm install -f values-staging.yaml` sem trocar `REPLACE_ME_*` → app starta com credencial inválida e crash loop | App falha rápido (DSN inválida → erro claro nos logs). README destaca obrigação. |
| Engano fazendo `kubectl apply` direto no `secret-staging.yaml` renderizado e commitado em outro ambiente | Guard `secretsStaging.enabled` default `false` impede render fora do staging via Helm. Aplicar manifesto raw é fora do fluxo padrão. |
| Portal `NEXT_PUBLIC_*` no pod ≠ build-args da imagem → frontend chama URLs erradas | Comentário no `values-staging.yaml` + nota no README explicando o requisito de rebuild. |
| Senha do Postgres/Redis vaza no Git via DSN composta | DSNs com password só existem no `secret-staging.yaml`. Guard + naming `*-staging` deixa óbvio. CI pode rodar `gitleaks` no futuro. |
| Mudança breaking nos charts existentes derruba ambientes prod/qa/dev | Pattern legacy `secrets.dbCredentials`/`secrets.llmApiKeys` preservado. ConfigMap muda formato (de mounted file para envFrom) — **isso requer que as apps já leiam do env, não do `/etc/aegis-*/config.yaml`**. Como prod ainda não existe e os `.env` dos repos confirmam consumo via env var, o risco é baixo; validar em dev antes de PR mesmo assim. |
| Drift de porta entre ConfigMap e containerPort/service | Vars de porta no ConfigMap são templated a partir do mesmo `.Values.<chart>.port` usado pelo deployment/service. Mudar a porta exige editar um único campo. |

## 10. Fora deste documento (próximos passos)

- Plano de implementação detalhado (issue/PR breakdown) → fica no plan file gerado pela skill `writing-plans`.
- Execução por chart, com validação `helm lint` e `helm template` a cada um → executor.
