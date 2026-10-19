#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/parameters.env"

if [[ $# != 1 ]]; then
  printf 'Usage: %s <output.json>\n' "$0" >&2
  exit 1
fi

umask 077
client_id=${OAUTH2_PROXY_CLIENT_ID:-$oidcClientId}
client_secret=${OAUTH2_PROXY_CLIENT_SECRET:?Set OAUTH2_PROXY_CLIENT_SECRET to the OIDC client secret}
cookie_secret=$(openssl rand -base64 32 | tr '/+' '_-')
jq -n \
  --arg client_id "$client_id" \
  --arg client_secret "$client_secret" \
  --arg cookie_secret "$cookie_secret" \
  --arg auth_proxy_secret_name "$authProxySecretName" \
  --arg workload_namespace "$workloadNamespace" '
  {
    apiVersion: "v1",
    kind: "Secret",
    metadata: {
      name: $auth_proxy_secret_name,
      namespace: $workload_namespace
    },
    type: "Opaque",
    stringData: {
      OAUTH2_PROXY_CLIENT_ID: $client_id,
      OAUTH2_PROXY_CLIENT_SECRET: $client_secret,
      OAUTH2_PROXY_COOKIE_SECRET: $cookie_secret
    }
  }
' > "$1"
printf 'Credentials written to %s. Keep this file outside Git.\n' "$1"
