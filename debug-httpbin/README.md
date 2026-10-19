# Temporary MaaS header debug endpoint

Open `https://<publicHostname><debugPublicPath>`.
It uses the portal's existing Keycloak client and browser session, or a valid
`tenant-demo` bearer token. The response echoes forwarded headers, including
the bearer token; keep it out of logs and shared screenshots. Cookies are removed
before reaching httpbin, and responses use `Cache-Control: no-store`.

This bundle owns only debug resources. It depends on the existing Gateway,
Keycloak, auth proxy, and auth-proxy ingress policy. It is separate from the
parent Kustomization and uses go-httpbin 2.25.0.

Verified on 2026-10-13: browser and bearer requests returned 200 with Alice's
expected groups, organization roles, and unchanged tokens. Anonymous requests redirected to login;
invalid bearer tokens returned 401.

From `maas-consumer-deploy/`:

```bash
context=<your-context>
oc --context "$context" kustomize --load-restrictor LoadRestrictionsNone debug-httpbin |
  oc --context "$context" apply --server-side --dry-run=server --validate=strict -f -
oc --context "$context" kustomize --load-restrictor LoadRestrictionsNone debug-httpbin |
  oc --context "$context" apply --server-side --field-manager=maas-debug-httpbin -f -
namespace=$(grep '^workloadNamespace=' parameters.env | cut -d= -f2)
oc --context "$context" -n "$namespace" rollout status deployment/maas-debug-httpbin
```

Remove every debug resource, including the route-specific payload exemption:

```bash
oc --context "$context" kustomize --load-restrictor LoadRestrictionsNone debug-httpbin |
  oc --context "$context" delete -f -
```
