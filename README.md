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
