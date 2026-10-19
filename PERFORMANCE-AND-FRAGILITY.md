# EnvoyFilter performance & fragility notes

Analysis of the `/ui` external-auth EnvoyFilter on `reasearch-tenant-gateway`.
Covers two variants:

- **Global** = `07-envoyfilter.yaml` (active): one Lua filter on the whole
  gateway, path check (`/ui`) done inside Lua.
- **LuaPerRoute** = `07-envoyfilter-luaperroute.yaml` (reference, not applied):
  Lua scoped to only the `/ui` route via `LuaPerRoute`.

---

## 1. Performance impact

The filter is attached to the whole gateway (`workloadSelector` on the gateway
label), so with the **global** version the Lua entry cost is paid on every
request. Two regimes:

### Non-`/ui` requests (the hot path: `/v1/*`, `/maas-api`, inference)

The Lua runs `envoy_on_request` and early-returns. Cost breakdown:

1. **Coroutine setup (dominant).** Envoy runs each request's script in a fresh
   Lua coroutine, allocated per stream regardless of what the script does. Paid
   even on the immediate-return path.
2. **One C++ -> Lua boundary crossing** for `headers():get(":path")`.
3. **Two small string allocations** from the `:match`/`find` patterns -> minor
   Lua GC pressure.
4. Return.

Purely CPU: no network, no locks, no blocking, no effect on concurrency.

**Magnitude:** a few microseconds to low-tens of microseconds per request,
dominated by (1). Versus inference latencies (ms to seconds) this is noise
(well under 0.1% per request). The only real caveat: it applies to **100% of
gateway traffic**, so at very high QPS it is a small constant CPU tax on the
gateway pods (plus minor GC), not user-visible latency.

### `/ui` requests

Each triggers a blocking `httpCall` to `research-auth-proxy` `/oauth2/auth`:

- Adds **one in-cluster network round trip** per request (sub-ms to a few ms)
  plus oauth2-proxy's work.
- Authenticated case: oauth2-proxy just **decrypts/validates the cookie locally**
  (AES) - cheap, no external call. A `TokenReview` API call happens only if a
  *bearer token* is presented (not the cookie flow), which is slower.
- The `httpCall` is **async in Envoy** - it yields the Lua coroutine and does not
  block the worker thread, so it will not starve other connections. It does hold
  *that* request until the auth response returns.

### Things worth watching for `/ui`

1. **No auth caching, per-asset multiplication.** Every `/ui*` request re-calls
   `/oauth2/auth`. A page pulling 30 assets = 30 ext-auth calls per load. Each is
   cheap (cookie decrypt) but linear in asset count. Kuadrant's own auth path
   caches; ours does not. Mitigations if `/ui` serves heavy static traffic:
   cache the decision in Envoy dynamic metadata keyed on the cookie; serve assets
   from a path excluded from the gate; or set browser cache headers.
2. **Lua vs native `ext_authz`.** Functionally equivalent to Envoy's built-in
   `ext_authz`, with marginal extra interpreter overhead. `inline_code` compiles
   once per worker at config load, not per request. Lua was chosen to get
   path-scoping + redirect-to-login in one resource, which native `ext_authz`
   cannot express.

### Bottom line (performance)

- MaaS/non-`/ui` traffic: negligible (a path check).
- `/ui` browser traffic: one lightweight in-cluster auth round trip per request;
  fine for interactive use, worth caching only if `/ui` serves high-volume assets.

---

## 2. Eliminating non-`/ui` cost (LuaPerRoute)

`07-envoyfilter-luaperroute.yaml` makes the Lua run **only** on the `/ui` route,
so non-`/ui` traffic never enters Lua (no coroutine, no header fetch). How:
install the script as a named `source_codes` entry with **no** default/inline
code (global pass-through), then attach it to the `/ui` route via `LuaPerRoute`.

This removes the (already tiny) non-`/ui` Lua cost at the price of extra
fragility - see below.

---

## 3. Fragility comparison

Both variants share a fragility baseline (inherent to `EnvoyFilter`); the
LuaPerRoute variant adds one more coupling on top.

### Shared by both (inherent to using EnvoyFilter)

- **Envoy internals / upgrades.** Both patch by Envoy filter names
  (`http_connection_manager`, `router`), the `INSERT_BEFORE` point, and `v3`
  `@type` URLs. Istio treats `EnvoyFilter` as a break-glass API tied to Envoy
  internals; a major Istio/Envoy upgrade can rename things or bump the API
  version and break either file.
- **Auth-proxy cluster string**
  `outbound|4180||research-auth-proxy.research-ui-test.svc.cluster.local`.
  Renaming the service, moving its namespace, or changing its port breaks both.
  Normal, visible service coupling.

### Where the global `07` is robust

Targeting is **path-based and semantic**: `workloadSelector` on the stable
gateway label + a `path == "/ui"` check in Lua. It does **not** depend on the
generated route name, HTTPRoute rule ordering, or vhost/namespace layout. Reorder
rules, rename the route, or add routes - it still gates `/ui`, because it keys off
the request path (the thing being protected). Its only hardcoded bits (`/ui`, the
proxy address) are under your direct control.

### The extra coupling in LuaPerRoute

It targets Istio's **generated** route name `research-ui-test.ui-route.1`
(format `<namespace>.<httproute-name>.<ruleIndex>`; index 1 = the `/ui` rule).
That identifier:

- **changes** if you reorder rules, rename the route, or move namespaces;
- **fails silently** (no error; per-route config just stops applying);
- has a bad failure mode: `/ui` stops being gated, and because
  `08-authpolicy-ui-bypass.yaml` already made the route anonymous to Kuadrant,
  `/ui` becomes **open** rather than 401.

Re-derive the current route name any time:

```bash
POD=$(kubectl get pod -n openshift-ingress \
  -l gateway.networking.k8s.io/gateway-name=reasearch-tenant-gateway \
  -o name | head -1 | cut -d/ -f2)
istioctl proxy-config route "$POD.openshift-ingress" -o json \
  | python3 -c 'import json,sys;
[print(vh["name"], r["name"], r.get("match"))
 for rc in json.load(sys.stdin) for vh in rc.get("virtualHosts",[])
 for r in vh.get("routes",[]) if "/ui" in str(r.get("match"))]'
```

### Summary table

| Aspect | Global `07` (active) | LuaPerRoute `07` (reference) |
|---|---|---|
| Envoy-internals / upgrade risk | yes | yes |
| Service cluster-name coupling | yes | yes |
| Generated route-name coupling | no | yes (silent; can open `/ui`) |
| Matching basis | request path (semantic) | generated route id (impl detail) |
| Non-`/ui` per-request Lua cost | tiny (~µs) | none |

**The global version is the more robust of the two.** Neither is upgrade-proof,
because both are EnvoyFilters.

---

## 4. The only way to shed the baseline EnvoyFilter fragility

Use the native path-scoped route instead of an EnvoyFilter: an Istio
`AuthorizationPolicy` with `action: CUSTOM` referencing an ext_authz
`extensionProvider`, with `to.operation.paths: ["/ui", "/ui/*"]`. Paths are
first-class and survive upgrades. Cost: it requires a **cluster-wide mesh-config
edit** (adding the `extensionProvider` to the `Istio` CR), which affects all
gateways - the blast-radius reason we set it aside for this test. It also cannot
natively do the browser redirect-to-login (`302` to `/oauth2/start`) that the Lua
does; unauthenticated requests get whatever oauth2-proxy returns (typically 401).

---

## Recommendation

Keep the active **global `07`**. Its non-`/ui` overhead is already negligible and
it avoids the silent-failure route-name coupling. Switch to LuaPerRoute only if
you later measure the gateway CPU-bound at high QPS and trace it to the Lua
filter. Consider the native `AuthorizationPolicy` CUSTOM approach only if you want
to move off EnvoyFilter entirely and can accept the mesh-config change.
