# Official MaaS consumer portal with OIDC

This bundle attaches the existing official portal to
`openshift-ingress/maas-default-gateway` at
`https://<publicHostname>/<portalPathPrefix>/`.

Set `publicHostname` and `portalPathPrefix` in `parameters.env`.

The HTTPRoute sends portal requests to `redhat-ods-applications/maas-portal:8443`
and removes the public prefix before forwarding. The DestinationRule in
`openshift-ingress` enables TLS for `maas-portal:8443`.
The portal's compiled `/maas-consumer-portal` path preserves assets and navigation.

## Resources

- A separate kube-auth-proxy Deployment, Service, and ServiceAccount, using OIDC.
- Protected portal and public `/oauth2` HTTPRoutes and Kuadrant AuthPolicies.
- A NetworkPolicy allowing the Gateway and Authorino to reach the auth proxy
  on TCP port 4180, including across the namespace's default ingress restriction.
- JWT validation against the `grid-sso` Keycloak `saas` realm, bound to
  `azp=tenant-demo`; browser sessions are checked through `/oauth2/auth`.
- Bearer and forwarded access tokens for the BFF. The consumer route removes
  `X-MaaS-*` identity headers before forwarding, preventing their replay to the
  MaaS API. Proxy session cookies are removed; application cookies are preserved.
  The proxy session cookie is named `_maas_consumer_proxy` via `--cookie-name`
  (not the oauth2-proxy default `_oauth2_proxy`); large sessions split into
  `_maas_consumer_proxy_0`, `_1`, etc.
- Route-specific EnvoyFilter exemptions for both inference payload processors.
- Route-specific TokenRateLimitPolicies that replace the Gateway's default
  inference denial with a limit whose condition is always false.
- DestinationRule with `SIMPLE` TLS for backend HTTPS. Certificate verification
  is disabled to match the existing Gateway configuration.

Workload resources use `redhat-ods-applications`. The EnvoyFilter uses
`openshift-ingress` and selects only `maas-default-gateway`. Its route IDs are
`redhat-ods-applications.maas-consumer-ui.{0,1}` and
`redhat-ods-applications.maas-consumer-oauth2.0`; keep these aligned with the
HTTPRoute rule order and verify them after Gateway controller upgrades.

## Prerequisites

The Gateway, portal Deployment/Service, Kuadrant, Istio, and `grid-sso` issuer
must already exist. Enable the authorization code flow and register this exact
callback: `https://<publicHostname>/oauth2/callback`. Set `publicHostname` in
`parameters.env`.

The Secret's client ID must match the AuthPolicy's `azp` predicate. The auth
proxy and Authorino verify the issuer's HTTPS certificate separately. Configure
the Keycloak client and realm outside this bundle. This bundle validates issuer
TLS and uses the auth-proxy image digest currently deployed by the cluster's
platform gateway. The `oidc-ca.crt` file configures the auth proxy only. See
Certificate handling for the separate Authorino trust configuration.

The portal BFF uses `--auth-method=user_token` with
`--auth-token-header=x-forwarded-access-token`. It forwards the access token to
the MaaS API, whose Gateway policy verifies the token and derives identity
headers again. Removing `X-MaaS-*` identity headers on the consumer route keeps
the BFF from replaying them into that policy.

The proxy refresh interval is four minutes, ahead of Keycloak's five-minute
access-token lifetime. Consumer and debug AuthPolicy session subrequests allow
two seconds for token refresh. Refreshed tokens are forwarded by Authorino;
updated proxy cookies are still not propagated back to the browser.
The portal models request was verified at 200 after the original token expired;
the refreshed token worked on the direct API while the old token returned 401.

Use `/oauth2/sign_out` as the UI logout link, with browser navigation. The proxy
clears its cookie and redirects through Keycloak logout. Each tenant IdP's
`saas-broker` client must allow its exact post-logout callback:
`https://<keycloak-host>/realms/saas/broker/<tenant>/endpoint/logout_response`.
Configure these callbacks outside this bundle.

## Deployment parameters

Use `parameters.env.example` as the template. Copy it to `parameters.env`
and edit the values for your cluster. Kustomize and the helper scripts read
the same file.

Before you apply the bundle, also update these local files:

- `components/keycloak/secrets.yaml`, or `components/keycloak/secrets.env`, sets the Keycloak and PostgreSQL credentials.
- `deploy/maas-portal/oidc-ca.crt` contains the ingress signer CA for the OIDC
  issuer route.

Run `oc kustomize deploy/maas-portal` to inspect the rendered objects. The
`oc apply -k deploy/maas-portal` command in the deployment steps renders and
applies the same Kustomize bundle.

## AITenant OIDC settings

Run `bash scripts/patch-aitenant-oidc.sh [AITenant-name]` from the repository root.
The command defaults to the `models-as-a-service` AITenant. It patches
`spec.oidc.issuerUrl` and `spec.oidc.clientId` in the `ai-tenants` namespace
with the values from `parameters.env`.

## Deploy

Run these commands from the repository root.

1. Edit the parameters.

```bash
cp deploy/maas-portal/parameters.env.example deploy/maas-portal/parameters.env
${EDITOR:-vi} deploy/maas-portal/parameters.env
```

2. Generate the auth-proxy Secret.

```bash
export OAUTH2_PROXY_CLIENT_SECRET='<OIDC client secret>'
bash scripts/generate-credentials.sh auth-proxy-secret.json
```

3. Patch the default AITenant OIDC settings.

```bash
bash scripts/patch-aitenant-oidc.sh
```

4. Apply the Secret and the bundle.

```bash
oc apply --server-side --field-manager=maas-consumer-deploy -f auth-proxy-secret.json
oc apply --server-side --field-manager=maas-consumer-deploy -k deploy/maas-portal
```

5. Verify the deployment.

```bash
namespace=$(grep '^workloadNamespace=' deploy/maas-portal/parameters.env | cut -d= -f2)
oc rollout status deployment/maas-consumer-auth-proxy -n "$namespace"
gateway_namespace=$(grep '^gatewayNamespace=' deploy/maas-portal/parameters.env | cut -d= -f2)
oc get httproute,authpolicy,tokenratelimitpolicy -n "$namespace"
oc get destinationrule -n "$gateway_namespace"
```

Confirm HTTPRoute `Accepted`/`ResolvedRefs` and AuthPolicy `Accepted`/`Enforced`.
Confirm the DestinationRule exists in the Gateway namespace.

Check browser login, asset loading, deep links, and protected BFF calls.
An invalid bearer must return 401 even when a browser session cookie is present.

## Deploy http-debug

The temporary header debug endpoint lives in `debug/httpbin/`. It is separate
from the parent Kustomization and requires the deployed consumer bundle.
Read the endpoint and token-warning details in `debug/httpbin/README.md`.

Run these commands from the repository root:

```bash
oc kustomize --load-restrictor LoadRestrictionsNone debug/httpbin |
  oc apply --server-side --dry-run=server --validate=strict -f -
oc kustomize --load-restrictor LoadRestrictionsNone debug/httpbin |
  oc apply --server-side --field-manager=maas-debug-httpbin -f -
namespace=$(grep '^workloadNamespace=' deploy/maas-portal/parameters.env | cut -d= -f2)
oc -n "$namespace" rollout status deployment/maas-debug-httpbin
```

## Validation history

Deployed on 2026-10-13 in the original test context: the proxy rolled out, routes and
backend TLS were accepted, and auth/token policies were enforced. The public
portal returned the expected login redirect; `/oauth2/start` selected
`tenant-demo` with the matching callback, and an invalid bearer returned 401.
The Gateway's generated routes confirmed both payload processors were disabled.
The auth-proxy ingress policy is required for browser sessions: the namespace's
default policy blocks Authorino. Its connection check now reaches `/oauth2/auth`
and returns 401 without a session, rather than timing out.

After consumer-route identity-header removal, Alice's portal models request
and direct MaaS API request both returned 200. Caller-supplied `X-MaaS-*`
identity headers were also removed; an invalid bearer with a valid browser
session still returned 401.

## Certificate handling

The DestinationRule sets `insecureSkipVerify: true`. It does not require a
CA refresh.

The auth proxy reads `oidc-ca.crt` from ConfigMap `maas-consumer-oidc-ca`. For
the default OpenShift ingress certificate, fetch the signer CA from Secret
`router-ca`. Use this signer CA instead of the route certificate in
`router-certs-default`.

Run this command from the repository root:

```bash
oc -n openshift-ingress-operator get secret router-ca \
  -o jsonpath='{.data.tls\.crt}' |
  base64 -d > deploy/maas-portal/oidc-ca.crt
oc apply --server-side --field-manager=maas-consumer-deploy -k deploy/maas-portal
```

This bundle updates the auth proxy only. Authorino runs in `kuadrant-system` and
reads `/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt` through
`SSL_CERT_FILE`. Its bundle must contain both the OpenShift service CA and the
ingress signer CA.

Refresh the Authorino ConfigMap after you update `oidc-ca.crt`:

```bash
oc -n kuadrant-system get configmap openshift-service-ca.crt \
  -o jsonpath='{.data.service-ca\.crt}' > /tmp/authorino-service-ca.crt
cat /tmp/authorino-service-ca.crt deploy/maas-portal/oidc-ca.crt > /tmp/authorino-ca-bundle.crt
oc create configmap authorino-oidc-ca-bundle -n kuadrant-system \
  --from-file=service-ca-bundle.crt=/tmp/authorino-ca-bundle.crt \
  --dry-run=client -o yaml | oc apply -f -
```

Add this volume to `Authorino/authorino.spec.volumes.items`:

```yaml
spec:
  volumes:
    defaultMode: 420
    items:
      - name: oidc-ca-bundle
        mountPath: /etc/ssl/certs/openshift-service-ca
        configMaps:
          - authorino-oidc-ca-bundle
        items:
          - key: service-ca-bundle.crt
            path: service-ca-bundle.crt
```

This mount is managed outside this bundle.

API references: [AuthPolicy](https://docs.kuadrant.io/latest/kuadrant-operator/doc/reference/authpolicy/),
[TokenRateLimitPolicy](https://docs.kuadrant.io/latest/kuadrant-operator/doc/reference/tokenratelimitpolicy/),
[DestinationRule](https://istio.io/latest/docs/reference/config/networking/destination-rule/),
[EnvoyFilter](https://istio.io/latest/docs/reference/config/networking/envoy-filter/).
