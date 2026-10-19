#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/../deploy/maas-portal/parameters.env"

if [[ $# -gt 1 ]]; then
  printf 'Usage: %s [AITenant-name]\n' "$0" >&2
  exit 1
fi

tenant_name=${1:-models-as-a-service}
patch=$(jq -n \
  --arg issuer_url "$oidcIssuerUrl" \
  --arg client_id "$oidcClientId" '
  {
    spec: {
      oidc: {
        issuerUrl: $issuer_url,
        clientId: $client_id
      }
    }
  }
')

oc patch AITenant "$tenant_name" -n ai-tenants --type=merge --patch "$patch"
printf 'Patched AITenant %s in ai-tenants.\n' "$tenant_name"
