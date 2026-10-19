# Deployment options for gateway-specific portal UI

This document compares three `kube-auth-proxy` integration options. The
requirement is one Gateway per tenant, one tenant-specific UI appearance, and
one shared backend UI BFF where possible.

The current APIs in this repository are Gateway API `HTTPRoute` and `Gateway`
`v1`, Kuadrant `AuthPolicy` `v1`, and Istio `EnvoyFilter` `v1alpha3`.

## Summary

| Option | Gateway customization | Team independence | Resource use per tenant | Recommendation |
| --- | --- | --- | --- | --- |
| Current Kuadrant plus one auth proxy per Gateway | Low for normal UI traffic; optional `EnvoyFilter` only for payload bypass | Good: MaaS owns Gateway and auth; UI team owns UI and BFF | One auth-proxy Deployment and Service; shared UI BFF possible | Best fit |
| `EnvoyFilter` without Kuadrant | High: Lua filter, route IDs, vhost names, and cluster names | Fair: MaaS owns a fragile gateway filter; UI team owns UI and BFF | One auth-proxy Deployment and Service; shared UI BFF possible | Use only if Kuadrant is unavailable |
| Auth proxy sidecar in reverse-proxy mode | High: still requires an `EnvoyFilter` for UI traffic | Poor to fair: one UI Deployment per Gateway couples UI and proxy lifecycle | One tenant UI Deployment with two containers; shared BFF possible behind it | Avoid unless deployment isolation is required |

## UI and BFF sharing

Sharing has three separate meanings:

- **Shared code:** all tenants use the same UI repository, image, and BFF image.
- **Shared Deployment:** all tenants use the same UI and BFF pods.
- **Shared BFF Service:** all tenants use one BFF Service, but each tenant can
  use its own UI Deployment.

Tenant-specific CSS does not prevent shared UI code. The UI can load the CSS
from a tenant-specific ConfigMap, object store, or theme path. The BFF does not
need to own the CSS.

| Option | Shared UI and BFF Deployment | Shared BFF Service only | How it works |
| --- | --- | --- | --- |
| Current Kuadrant plus one auth proxy per Gateway | Yes | Yes | Each Gateway uses its own `HTTPRoute`. UI rules point to one shared UI Service. API rules point to one shared BFF Service. Tenant CSS is selected by hostname, path, or runtime configuration. |
| `EnvoyFilter` without Kuadrant | Yes, but fragile | Yes | Each Gateway uses its own filter and `HTTPRoute`. After authentication, UI rules point to one shared UI Service and API rules point to one shared BFF Service. The filter must remain aligned with those routes. |
| Auth proxy sidecar in reverse-proxy mode | No, not cleanly | Yes | Each Gateway uses one tenant UI Deployment with the sidecar. The sidecar forwards API calls to the shared BFF Service. A single shared UI pod cannot hold one tenant-specific sidecar configuration per Gateway. |

For a shared BFF, send a tenant identifier and the authenticated identity to the
BFF. The BFF must use both values for tenant isolation. Use a
`ReferenceGrant` when the `HTTPRoute` references a Service in another namespace.

## Option 1: Current Kuadrant and one auth proxy per Gateway

This option is implemented by the manifests in this repository.

### Gateway configuration

- Use `HTTPRoute` `v1` to attach each tenant UI to its Gateway.
- Use Kuadrant `AuthPolicy` `v1` to authenticate the UI route.
- Deploy one auth-proxy Deployment and Service in each tenant workload namespace.
- Use the optional `EnvoyFilter` only when the tenant profile enables payload
  processing bypass.
- Use `NetworkPolicy` `v1` to allow Gateway traffic to the UI and API pods.

Normal UI login does not require an `EnvoyFilter`. This keeps the main path on
supported Gateway API and Kuadrant resources.

### Team independence

- The MaaS team owns Gateway attachment, authentication, authorization, and
  payload bypass.
- The UI team owns the portal code, BFF code, and CSS.
- The UI can use one shared BFF Service or one tenant-specific BFF Service.
- Tenant-specific CSS requires a tenant-specific static asset or runtime CSS
  configuration. The BFF does not need to change.

This gives the clearest ownership boundary. Both teams can use separate code
repositories and release independently.

### Resource use

- Per Gateway: one auth-proxy Deployment, one pod, and one Service.
- The checked-in auth proxy requests 100m CPU and 128Mi memory.
- The UI BFF can be shared across tenants.
- The optional payload bypass adds no pods.

This option has the lowest steady-state pod count when the BFF is shared.

### Main trade-off

The optional payload bypass still uses an `EnvoyFilter`. It depends on the
Gateway data-plane selector and generated route IDs. Keep this feature disabled
unless a tenant requires it.

## Option 2: `EnvoyFilter` without Kuadrant

This option is not implemented in this repository.

### Gateway configuration

- Use `EnvoyFilter` `v1alpha3` to run a Lua filter on the Gateway.
- Match the Gateway-generated vhost and route names.
- Call the auth proxy `/oauth2/auth` endpoint from the filter.
- Copy identity and token headers onto the request.
- Route `/oauth2` to the auth proxy Service.

This option replaces Kuadrant policy with a custom gateway filter. It does not
remove the auth-proxy Deployment.

### Team independence

- The MaaS team owns the `EnvoyFilter`, route IDs, and proxy cluster name.
- The UI team owns the portal and BFF.
- The UI can use one shared BFF Service or one tenant-specific BFF Service.

The code bases can remain separate. However, the filter contains the UI traffic
contract, so a UI route change can break authentication.

### Resource use

- Per Gateway: one auth-proxy Deployment, one pod, and one Service.
- The Lua filter consumes Gateway data-plane CPU; it adds no workloads.
- The UI BFF can be shared across tenants.

The pod count is the same as Option 1. The Gateway filter does more request
processing work.

### Main trade-off

`EnvoyFilter` is a break-glass Istio API. The existing analysis in
`PERFORMANCE-AND-FRAGILITY.md` identifies coupling to generated route names,
vhost names, filter ordering, and Envoy protobuf types. Gateway or Istio
upgrades can break the filter.

## Option 3: Auth proxy sidecar in reverse-proxy mode

This option runs the auth proxy in the same pod as a tenant-specific UI
Deployment.

### Gateway configuration

- Deploy one UI workload per Gateway.
- Add the auth proxy as a second container in each UI pod.
- Run the auth proxy in reverse-proxy mode.
- Send `/oauth2` and UI traffic to the UI Service on the proxy port.
- Use an `EnvoyFilter` to pass UI traffic through the sidecar path.
- Use `NetworkPolicy` `v1` to allow Gateway traffic to the UI pods.

The sidecar handles login locally, but the Gateway still needs custom filter
configuration.

### Team independence

- The UI team can own the tenant UI Deployment and CSS.
- The MaaS team must own or review the sidecar settings, Gateway filter, and
  network policy.
- The UI pod lifecycle is coupled to the proxy container lifecycle.
- A shared BFF can remain separate from the tenant UI Deployment.

Separate code bases are possible, but deployment ownership is less clean than in
Option 1. A proxy update can restart every tenant UI Deployment.

### Resource use

- Per Gateway: one UI Deployment, one pod, and two containers.
- The auth proxy has no standalone Deployment or Service for that Gateway.
- The UI BFF can remain shared.

This option uses one pod per Gateway even when the UI BFF is shared. It has
more containers and more Deployments than Option 1.

### Main trade-off

The option does not remove the `EnvoyFilter`, and it multiplies UI Deployments.
It also combines UI and proxy security contexts in one pod. The current
architecture already separates these concerns.

## Recommendation

Use Option 1. It meets the tenant-specific UI requirement with the least
Gateway customization and the best team boundary.

1. Keep one auth proxy Deployment per tenant Gateway.
2. Use a shared UI BFF Service unless a tenant needs isolation.
3. Serve tenant-specific CSS from a tenant-specific UI asset or configuration.
4. Keep Kuadrant `AuthPolicy` on the UI route.
5. Enable the payload-bypass `EnvoyFilter` only for tenants that require it.

Use Option 2 only when Kuadrant cannot be installed or used. Use Option 3 only
when a tenant requires a separate UI Deployment and accepts the extra
operational cost.

## Evidence

- Current Gateway routes: `06-httproutes.yaml`
- Current auth proxy workload: `04-auth-proxy.yaml`
- Current Kuadrant policy: `08-authpolicies.yaml`
- Current optional payload bypass: `22-payload-processing-bypass.yaml`
- Current network policy: `15-auth-proxy-networkpolicy.yaml`
- `EnvoyFilter` fragility analysis: `PERFORMANCE-AND-FRAGILITY.md`
