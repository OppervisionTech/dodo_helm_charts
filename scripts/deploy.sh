#!/usr/bin/env bash
set -euo pipefail

USAGE="Usage: $0 <environment> <chart-name> [namespace] [extra-helm-args...]
  environment: staging | prod
  chart-name:  e.g. aegis-agent, aegis-ingestor, aegis-kong, aegis-cert-manager
  namespace:   Kubernetes namespace (default: aegisops)

Values precedence (maior → menor):
  1. charts/<chart-name>/values-<env>.yaml  (per-chart env override)
  2. values/values-<env>.yaml               (global env override, retrocompat)
  3. charts/<chart-name>/values.yaml        (chart defaults)"

if [ $# -lt 2 ]; then
  echo "$USAGE"
  exit 1
fi

ENV="$1"
CHART="$2"
NAMESPACE="${3:-aegisops}"
shift 3 2>/dev/null || shift 2

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
CHART_PATH="$REPO_ROOT/charts/$CHART"

# Values globais por ambiente (retrocompat)
GLOBAL_VALUES_FILE="$REPO_ROOT/values/values-${ENV}.yaml"
# Values por chart por ambiente (novo padrão)
CHART_VALUES_FILE="$CHART_PATH/values-${ENV}.yaml"

if [ ! -d "$CHART_PATH" ]; then
  echo "ERROR: Chart not found at $CHART_PATH"
  exit 1
fi

if ! echo "$ENV" | grep -qE '^(staging|prod)$'; then
  echo "ERROR: Invalid environment '$ENV'. Must be staging or prod."
  exit 1
fi

echo "Deploying $CHART to $ENV (namespace: $NAMESPACE)..."

# Resolve dependências (kong/ingress, _library, etc.)
helm dependency build "$CHART_PATH" 2>/dev/null || true

# Monta argumentos de values
VALUES_ARGS=""
if [ -f "$GLOBAL_VALUES_FILE" ]; then
  VALUES_ARGS="$VALUES_ARGS -f $GLOBAL_VALUES_FILE"
fi
if [ -f "$CHART_VALUES_FILE" ]; then
  VALUES_ARGS="$VALUES_ARGS -f $CHART_VALUES_FILE"
fi

if [ -z "$VALUES_ARGS" ]; then
  echo "WARN: Nenhum values file encontrado para $CHART/$ENV — usando apenas defaults."
fi

# shellcheck disable=SC2086
helm upgrade --install "$CHART" "$CHART_PATH" \
  $VALUES_ARGS \
  -n "$NAMESPACE" \
  --create-namespace \
  "$@"

echo "Deploy complete: $CHART → $ENV (namespace: $NAMESPACE)"
