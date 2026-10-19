#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/../deploy/maas-portal/parameters.env"

context=${1:-$(oc config current-context)}

oc --context "$context" exec -i "deployment/$keycloakDeployment" -n "$keycloakNamespace" -- \
  sh -s -- "$keycloakRealm" "$brokerTenant1" "$brokerTenant2" "$brokerTenantRealmSuffix" "$brokerClientId" <<'SH'
set -eu
keycloak_realm=$1
broker_tenant_1=$2
broker_tenant_2=$3
broker_tenant_realm_suffix=$4
broker_client_id=$5
kc_config=$(mktemp /tmp/maas-broker-logout.XXXXXX)
trap 'rm -f "$kc_config"' EXIT
kc_cli=/opt/keycloak/bin/kcadm.sh
"$kc_cli" config credentials --config "$kc_config" --server http://localhost:8080 \
  --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" \
  --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null

for tenant in "$broker_tenant_1" "$broker_tenant_2"; do
  tenant_realm="$tenant$broker_tenant_realm_suffix"
  client_id=$("$kc_cli" get clients -r "$tenant_realm" -q clientId="$broker_client_id" \
    --fields id --format csv --noquotes --config "$kc_config")
  callback="$KEYCLOAK_PUBLIC_URL/realms/$keycloak_realm/broker/$tenant/endpoint/logout_response"
  "$kc_cli" update "clients/$client_id" -r "$tenant_realm" --config "$kc_config" \
    -s "attributes.\"post.logout.redirect.uris\"=\"$callback\""
  "$kc_cli" get "clients/$client_id" -r "$tenant_realm" --config "$kc_config" \
    | sed -n '/"post.logout.redirect.uris"/p'
done
SH
