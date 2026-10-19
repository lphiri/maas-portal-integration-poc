# MaaS consumer portal 500 investigation

Date: 2026-10-13

The portal's models request had two separate causes of HTTP 500: copied
identity headers caused an upstream 403, and an expired session token later
caused an upstream 401. The header fix and four-minute refresh configuration
are deployed. Browser refresh-cookie persistence and the BFF's handling of
upstream authentication errors remain unresolved.

## Request path and configuration

Failing URL:

`https://maas.apps.rosa.ai-grid-tenant.ix3r.p3.openshiftapps.com/maas-consumer-portal/maas/api/v1/models`

Request path:

```text
Browser -> MaaS Gateway -> consumer portal -> maas-ui BFF
        -> MaaS Gateway /maas-api/v1/models -> maas-api
```

- Gateway: `openshift-ingress/maas-default-gateway`.
- Consumer HTTPRoute: `redhat-ods-applications/maas-consumer-ui`.
- BFF Deployment: `redhat-ods-applications/maas-ui`.
- API Deployment: `redhat-ai-gateway-infra/maas-api`.
- Issuer: Keycloak's `saas` realm in `grid-sso`; OIDC client: `tenant-demo`.

The live BFF's `MAAS_API_URL` was set to
`https://maas.apps.rosa.ai-grid-tenant.ix3r.p3.openshiftapps.com/maas-api`.
The rollout succeeded, and `/api/v1/gateway-url` returned the configured URL.
The BFF uses `--auth-method=user_token`,
`--auth-token-header=x-forwarded-access-token`, and an empty token prefix.

## Keycloak claims

Configuration source:
`/home/lphiri/saws/keycloak/organizations/openshift`.

The `tenant-demo` groups and organization protocol mappers had
`access.token.claim=false`. Their claims were available in ID tokens/UserInfo,
but missing from the access token forwarded to MaaS. Both flags were changed
to `true` in the live client and in `realms/saas-realm.json`.

A fresh Alice access token then contained:

```json
{
  "groups": [
    "grid-tenant-1:ai-grid-admins",
    "grid-tenant-1:ai-grid-users"
  ],
  "https://redhat.com/maas/orgs": [
    {"tenant_id": "grid-tenant-1", "roles": ["admins"]}
  ]
}
```

`X-MaaS-Roles` is an HTTP header derived by the portal/debug AuthPolicy from
the organization claim; it is not the name of a JWT claim. The auth proxy
already requested `openid email profile`, confirmed in source and live args.

## First cause: identity-header replay

The BFF forwarded the incoming request headers, then set its outbound
`Authorization: Bearer <access token>`. This included the portal's injected
`X-MaaS-Username` and `X-MaaS-Group` headers, alongside organization and role
headers. The access token itself was unchanged.

Relevant source under `/home/lphiri/code/shiftai/odh-dashboard`:

- `packages/maas/bff/internal/api/models_handler.go`: passes `r.Header` to the
  models repository.
- `packages/maas/bff/internal/integrations/maas/maas_client.go`: copies every
  supplied header with `request.Header.Add`, then sets the bearer token.

The API Gateway's `maas-gateway-auth` AuthPolicy has a
`deny-client-identity-headers` rule. Replaying the identity headers triggered
403 even though the same JWT worked on a direct API call. The BFF then tried
to decode the empty error body as JSON and returned 500:

```text
unknown error when invoking maas-api (unmarshall): unexpected end of JSON input
```

Before the fix, a fresh Alice session returned direct API 200 and portal BFF
500; BFF logs recorded upstream 403. An earlier controlled request also showed
that adding only `X-MaaS-Username` changed a successful request into a rejection.

## Deployed header fix

The consumer UI does not need the MaaS identity headers. Its existing
`RequestHeaderModifier.remove` list in [06-httproutes.yaml](06-httproutes.yaml)
was extended with:

```text
x-maas-username
x-maas-group
x-maas-orgid
x-maas-roles
x-maas-keyname
x-maas-subscription-rate-limit-id
```

These headers are removed before requests reach the consumer backend.
`Authorization` and `X-Forwarded-Access-Token` are preserved. The API Gateway
verifies the forwarded token and derives its identity headers again.

The change applies only to `/maas-consumer-portal`. Other backend routes retain
their behavior. The API AuthPolicy and BFF code were not changed. No additional
EnvoyFilter was deployed for this fix; the proposed shared-listener filter was
rejected by automatic approval review, declined by the user, and removed locally.

The route was accepted at generation 2 with `ResolvedRefs=True`. The saved
route manifest passed strict server dry-run using field manager
`maas-consumer-deploy`.

| Verification after the fix | Result |
| --- | --- |
| Fresh Alice token, direct `/maas-api/v1/models` | 200 |
| Fresh Alice session, portal models request | 200 |
| Portal request supplying all six identity headers | 200 |
| Invalid bearer with a valid browser session | 401 |

Successful models responses contained an empty list. These tests established
successful authentication and forwarding, not model availability.

## Second cause: expired browser-session token

When the user reported another 500, the header-removal configuration was still
active. BFF logs at 19:30:40–19:30:48 UTC recorded upstream **401**, whereas the
earlier header failures recorded **403**. The auth proxy accepted Alice's
session at those same times, returning 202 from `/oauth2/auth`.

Observed lifetimes when the expired-token failure was investigated:

- Alice's access token: five minutes (`exp - iat = 300`).
- Auth proxy: `--cookie-refresh=1h0m0s`.
- Auth proxy: `--cookie-expire=24h0m0s`.

The user confirmed the expired-token cause. A fresh-login test again returned
200 for both direct API and portal BFF calls. The automated wait-through-expiry
test was stopped after that confirmation; a complete expiry cycle was not
recorded. At that stage, no session-refresh configuration had been changed.

## Debug endpoint

The separate [debug-httpbin/](debug-httpbin/README.md) bundle was deployed at
`/debug/headers` with OIDC protection. Browser and direct bearer tests confirmed
unchanged tokens and the expected user, group, organization, and role headers.
Proxy cookies were absent from the echoed request. Anonymous access redirected
to login; an invalid bearer returned 401.

Its files and resources are separate from the main bundle. Remove them with:

```bash
context=openshift-ingress/api-ai-grid-tenant-ix3r-p3-openshiftapps-com:443/lphiri
oc --context "$context" delete -k debug-httpbin
```

The endpoint echoes credentials; do not share its full response. This report
contains no passwords, tokens, or session cookies.

## Remaining work

1. Address refreshed cookies: the current Authorino `/oauth2/auth` subrequest
   does not propagate `Set-Cookie` back to the browser. The deployed four-minute
   interval addresses token refresh, but not browser session-cookie persistence.
2. Make the BFF handle upstream 401/403 explicitly instead of attempting JSON
   decoding and reporting 500. This code change has not been implemented.

## Follow-up: refresh and broker logout

The approved configuration update set `--cookie-refresh=4m0s` and increased
consumer/debug AuthPolicy session subrequest timeouts from `100ms` to `2s`.
The proxy rolled out successfully; both policies were accepted and enforced.

A subsequent full expiry test kept Alice's original browser proxy cookie and
waited until the original access token expired. The first portal models request
after expiry returned 200 through the AuthPolicy/BFF path. The debug endpoint
then confirmed a new, valid token with a 300-second lifetime and unchanged
groups. The new token returned direct API 200; the original expired token
returned 401. The browser proxy cookie remained unchanged, confirming the
remaining `Set-Cookie` propagation limitation.

Logout at `/oauth2/sign_out` initially failed with HTTP 400 in
`grid-tenant-1-idp`. Its `saas-broker` client rejected the SaaS broker's
`/realms/saas/broker/grid-tenant-1/endpoint/logout_response` callback. Both
tenant broker clients were missing `post.logout.redirect.uris`.

Each live broker client and tenant realm source file now registers its exact
callback. [configure-broker-logout.sh](configure-broker-logout.sh) applies these
attributes to existing realms. Alice's logout then returned 200, cleared the
proxy session cookie, and left `/oauth2/auth` returning 401. Tenant 2's callback
configuration was verified; an authenticated Bob logout was not tested.

The UI logout link should use browser navigation to:
`https://maas.apps.rosa.ai-grid-tenant.ix3r.p3.openshiftapps.com/oauth2/sign_out`.
