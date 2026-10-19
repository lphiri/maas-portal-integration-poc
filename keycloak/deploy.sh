#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE=grid-sso
SECRET_FILE="$SCRIPT_DIR/secrets.yaml"
ROUTE_FILE="$SCRIPT_DIR/route.yaml"
ENV_FILE=

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --env-file)
      (($# >= 2)) || fail "Usage: $0 [--env-file PATH]"
      ENV_FILE="$2"
      shift 2
      ;;
    *)
      fail "Usage: $0 [--env-file PATH]"
      ;;
  esac
done

command -v oc >/dev/null 2>&1 || fail "oc is required. Install the OpenShift CLI and try again."
[[ -f "$ROUTE_FILE" ]] || fail "Missing $ROUTE_FILE."

if [[ -n "$ENV_FILE" ]]; then
  [[ "$ENV_FILE" == /* ]] || ENV_FILE="$PWD/$ENV_FILE"
  [[ -f "$ENV_FILE" ]] || fail "Missing env file: $ENV_FILE"
  secret_input="$ENV_FILE"
  required_keys=(
    POSTGRESQL_USER
    POSTGRESQL_PASSWORD
    POSTGRESQL_DATABASE
    KC_BOOTSTRAP_ADMIN_USERNAME
    KC_BOOTSTRAP_ADMIN_PASSWORD
    KEYCLOAK_CLIENT_ID
    KEYCLOAK_HOME_URL
    KEYCLOAK_REDIRECT_URI
    KEYCLOAK_CLIENT_SECRET
    GRID_TENANT_1_BROKER_CLIENT_SECRET
    GRID_TENANT_2_BROKER_CLIENT_SECRET
    GRID_TENANT_1_TEST_USER_PASSWORD
    GRID_TENANT_2_TEST_USER_PASSWORD
  )
  for key in "${required_keys[@]}"; do
    grep -Eq "^${key}=.+$" "$ENV_FILE" || fail "Missing or empty $key in $ENV_FILE."
  done
else
  [[ -f "$SECRET_FILE" ]] || fail "Missing $SECRET_FILE. Copy secret-template.yaml to secrets.yaml and fill in its values."
  secret_input="$SECRET_FILE"
fi

if [[ -n "$ENV_FILE" ]]; then
  if grep -v '^KEYCLOAK_PUBLIC_URL=' "$secret_input" | grep -q 'REPLACE_WITH_'; then
    fail "Replace all REPLACE_WITH_ values in $secret_input before deploying."
  fi
else
  if sed '/^[[:space:]]*KEYCLOAK_PUBLIC_URL:/d' "$secret_input" | grep -q 'REPLACE_WITH_'; then
    fail "Replace all REPLACE_WITH_ values in $secret_input before deploying."
  fi
fi

oc whoami >/dev/null 2>&1 || fail "No active OpenShift login. Log in to the target cluster and try again."
cluster_server="$(oc whoami --show-server)"
cluster_user="$(oc whoami)"
apps_domain="$(oc get ingresses.config/cluster -o jsonpath='{.spec.appsDomain}' 2>/dev/null)" || fail "Could not read the apps domain from the active cluster context."
if [[ -z "$apps_domain" ]]; then
  apps_domain="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null)" || fail "Could not read the apps domain from the active cluster context."
fi
[[ "$apps_domain" =~ ^[A-Za-z0-9.-]+$ ]] || fail "The active cluster returned an empty or invalid apps domain."
route_host="keycloak-grid-sso.$apps_domain"
public_url="https://$route_host"
printf 'Deploying namespace %s to %s as %s\n' "$NAMESPACE" "$cluster_server" "$cluster_user"
printf 'Using cluster apps domain %s\n' "$apps_domain"

oc apply -f "$SCRIPT_DIR/namespace.yaml"
if [[ -n "$ENV_FILE" ]]; then
  oc create secret generic keycloak-secrets \
    --namespace="$NAMESPACE" \
    --from-env-file="$ENV_FILE" \
    --dry-run=client -o yaml | oc apply -f -
else
  oc apply -f "$SECRET_FILE"
fi
oc -n "$NAMESPACE" set data secret/keycloak-secrets "KEYCLOAK_PUBLIC_URL=$public_url"
oc kustomize "$SCRIPT_DIR" | sed "s|^  host: .*|  host: $route_host|" | oc apply -f -
oc -n "$NAMESPACE" rollout status statefulset/keycloak-postgresql
oc -n "$NAMESPACE" rollout status deployment/keycloak
oc -n "$NAMESPACE" get route keycloak
