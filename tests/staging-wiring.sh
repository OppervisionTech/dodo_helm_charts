#!/usr/bin/env bash
# Renderiza os charts de staging e verifica registry, pull secret e wiring dos BFFs.
set -euo pipefail
cd "$(dirname "$0")/.."

CHARTS="aegis-ai-core aegis-alerts aegis-cert-worker aegis-cmdb-worker aegis-dashboard aegis-dashboard-bff \
aegis-health-monitor aegis-ingestor aegis-log-worker aegis-metric-worker aegis-otel-worker aegis-portal \
aegis-portal-bff aegis-query-api aegis-security-orchestrator"
fail=0
render() { helm template t "charts/$1" -f "charts/$1/values.yaml" -f "charts/$1/values-staging.yaml" --set image.tag=test; }

for c in $CHARTS; do
  [ -f "charts/$c/values-staging.yaml" ] || { echo "FALTA values-staging: $c"; fail=1; continue; }
  [ -d "charts/$c/charts" ] || helm dependency build "charts/$c" >/dev/null
  out=$(render "$c")
  bad=$(echo "$out" | yq -N 'select(.kind=="Deployment" or .kind=="Job" or .kind=="StatefulSet") | .spec.template.spec | (.containers + (.initContainers // []))[] | .image' | grep -v '^ghcr.io/oppervisiontech/' || true)
  [ -z "$bad" ] || { echo "IMAGEM FORA DO GHCR em $c: $bad"; fail=1; }
  ps=$(echo "$out" | yq -N 'select(.kind=="Deployment") | .spec.template.spec.imagePullSecrets[].name' | sort -u)
  [ "$ps" = "ghcr-pull" ] || { echo "PULL SECRET errado em $c: '$ps'"; fail=1; }
done

check_env() { # chart var valor — os charts injetam env via envFrom do ConfigMap do release
  v=$(render "$1" | yq -N "select(.kind==\"ConfigMap\") | .data.\"$2\" // \"\"" | grep -v '^$' | head -1 || true)
  [ "$v" = "$3" ] || { echo "ENV $2 em $1 = '$v' (esperado '$3')"; fail=1; }
}
check_egress() { # chart porta
  render "$1" | yq -N 'select(.kind=="NetworkPolicy") | .spec.egress[].ports[].port' | grep -qx "$2" \
    || { echo "EGRESS $2 ausente na NetworkPolicy de $1"; fail=1; }
}
check_env aegis-dashboard DASHBOARD_BFF_INTERNAL_URL "http://aegis-dashboard-bff:8082"
check_env aegis-portal PORTAL_BFF_INTERNAL_URL "http://aegis-portal-bff:8081"
check_egress aegis-dashboard 8082
check_egress aegis-portal 8081

[ $fail -eq 0 ] && echo "STAGING_WIRING_OK" || exit 1
