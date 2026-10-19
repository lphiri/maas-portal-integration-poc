#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/../deploy/maas-portal/parameters.env"

context=${1:-$(oc config current-context)}
callback_url="https://$publicHostname$oauthPathPrefix/callback"

oc --context "$context" exec -i "deployment/$keycloakDeployment" -n "$keycloakNamespace" -- \
  sh -s -- "$keycloakRealm" "$oidcClientId" "$callback_url" <<'SH'
set -eu
keycloak_realm=$1
oidc_client_id=$2
callback_url=$3
kc_config=$(mktemp /tmp/maas-consumer-kcadm.XXXXXX)
trap 'rm -f "$kc_config"' EXIT
kc_cli=/opt/keycloak/bin/kcadm.sh
"$kc_cli" config credentials --config "$kc_config" --server http://localhost:8080 \
  --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" \
  --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null
client_id=$("$kc_cli" get clients -r "$keycloak_realm" -q clientId="$oidc_client_id" \
  --fields id --format csv --noquotes --config "$kc_config")
"$kc_cli" update "clients/$client_id" -r "$keycloak_realm" --config "$kc_config" \
  -s "redirectUris=[\"$callback_url\"]"
"$kc_cli" get "clients/$client_id" -r "$keycloak_realm" --config "$kc_config" \
  --fields clientId,redirectUris
SH

oc --context "$context" patch secret "$keycloakImportSecretName" -n "$keycloakNamespace" --type=merge \
  --patch "{\"stringData\":{\"$keycloakRedirectUriKeyName\":\"$callback_url\"}}"
