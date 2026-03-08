#!/usr/bin/env bash
set -euo pipefail

USAGE="Usage: $0 <environment> <chart-name> [namespace] [extra-helm-args...]
  environment: dev | qa | prod
  chart-name:  e.g. aegis-agent, aegis-ingestor
  namespace:   Kubernetes namespace (default: aegisops)"

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
VALUES_FILE="$REPO_ROOT/values/values-${ENV}.yaml"

if [ ! -d "$CHART_PATH" ]; then
  echo "ERROR: Chart not found at $CHART_PATH"
  exit 1
fi

if [ ! -f "$VALUES_FILE" ]; then
  echo "ERROR: Values file not found at $VALUES_FILE"
  exit 1
fi

if ! echo "$ENV" | grep -qE '^(dev|qa|prod)$'; then
  echo "ERROR: Invalid environment '$ENV'. Must be dev, qa, or prod."
  exit 1
fi

echo "Deploying $CHART to $ENV (namespace: $NAMESPACE)..."

helm dependency build "$CHART_PATH" 2>/dev/null || true

helm upgrade --install "$CHART" "$CHART_PATH" \
  -f "$VALUES_FILE" \
  -n "$NAMESPACE" \
  --create-namespace \
  "$@"

echo "Deploy complete: $CHART → $ENV"
