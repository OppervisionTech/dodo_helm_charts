# dodo_helm_charts — Helm Charts para Kubernetes

> **Stack**: Helm 3
> **Fase**: MVP
> **Referência**: Deploy de todos os serviços AegisOps em K8s

---

## Responsabilidade

Charts Helm para deploy de todos os componentes do AegisOps em Kubernetes. Um chart por serviço, com values configuráveis por ambiente (dev, qa, prod).

---

## Charts

| Chart | Serviço | Tipo |
|-------|---------|------|
| `aegis-agent` | DaemonSet do agent | DaemonSet |
| `aegis-ingestor` | Ingestor Node | Deployment + HPA |
| `aegis-ai-core` | AI Core + Decision Engine | Deployment |
| `aegis-query-api` | Query API | Deployment + HPA |
| `aegis-metric-worker` | Metric Worker | Deployment |
| `aegis-log-worker` | Log Worker | Deployment |
| `aegis-health-monitor` | Health Monitor | Deployment |
| `aegis-otel-worker` | OTEL Worker | Deployment |
| `aegis-dashboard` | Dashboard Next.js | Deployment + Ingress |
| `aegis-portal` | Portal SaaS | Deployment + Ingress |
| `aegis-kong` | Kong Ingress | Deployment + Service |
| `aegis-kafka` | Kafka/Redpanda cluster | StatefulSet |
| `aegis-timescaledb` | TimescaleDB | StatefulSet + PVC |
| `aegis-clickhouse` | ClickHouse | StatefulSet + PVC |
| `aegis-postgresql` | PostgreSQL + pgvector | StatefulSet + PVC |
| `aegis-redis` | Redis | StatefulSet |

---

## Convenções

- `helm lint` em CI
- Values separados por ambiente (`values-dev.yaml`, `values-qa.yaml`, `values-prod.yaml`)
- Sem secrets em plain text (usar `secretRef`, sealed-secrets ou external-secrets)
- Resource limits definidos para todo container
- Health checks (liveness + readiness) em todo chart
- Network policies restritivas
- RBAC com ServiceAccounts de mínimo privilégio


---

## Oppervision Flow

Este repo segue o **Oppervision Flow** (6 fases). Documentação completa na raiz do projeto:

- **Metodologia**: `docs/flow/overview.md`
- **Templates**: `docs/templates/` (story file, PR, threat model, review checklist)
- **Referência completa**: `CLAUDE.md` raiz — Seções 5 a 7

### Fases

```
0. REFINE → 1. SPEC → 2. THREAT → 3. IMPLEMENT → 4. REVIEW → 5. DELIVER
```

### Track padrão: Full

HUs deste repo seguem o track Full por padrão:

```
SPEC → THREAT (se aplicável) → IMPLEMENT → REVIEW → DELIVER
```

- Se a HU toca em auth, input do usuário, dados sensíveis ou APIs externas → escalar para **Security-Critical**
- Bug fixes isolados (< 3 arquivos) podem usar track **Quick**

### Regras inegociáveis

- **Toda feature começa com HU no Notion** (formato CQPD: Como/Quero/Para/Deve)
- **Story file obrigatório** antes de escrever código (`docs/templates/story.md`)
- **Threat assessment (STRIDE)** se a HU for Security-Critical
- **PR usa template padrão** (`docs/templates/pr-template.md`)
- **Review checklist** por stack (`docs/templates/review-checklist.md`)
- **Nada fica para "depois"** — cada HU é completa ou não entra no sprint

---

## Git Workflow

### Main-First Strategy

- `main` é **sempre production-ready**
- Features SEMPRE criam branch a partir de `main`
- PR direto para `main` (sem develop, staging, etc.)
- Squash merge para manter histórico limpo

### Branch Naming

```
feat/HU{N}-descricao-curta
fix/HU{N}-descricao-curta
refactor/HU{N}-descricao-curta
```

### Commits

```
tipo(escopo): descrição curta

Corpo opcional com contexto.

Refs: HU{N}
```

Tipos: `feat`, `fix`, `refactor`, `test`, `docs`, `ci`, `chore`

### Antes de abrir PR

1. `git fetch origin && git rebase origin/main`
2. CI passa (lint, test, build)
3. Story file atualizado com decisões técnicas
4. Self-review pelo dev
