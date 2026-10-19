# MaaS portal integration

This repository contains the Keycloak component and the MaaS portal deployment.

## Layout

- `components/keycloak/` contains the reusable Keycloak component.
- `deploy/maas-portal/` contains the MaaS portal deployment.
- `docs/` contains the architecture and flow notes.
- `scripts/` contains the helper scripts.
- `debug/httpbin/` contains the temporary debug endpoint.

## Build

Render the full stack:

```bash
oc kustomize .
```

Render only Keycloak:

```bash
oc kustomize components/keycloak
```

Render only the MaaS portal:

```bash
oc kustomize deploy/maas-portal
```

Render the debug endpoint:

```bash
oc kustomize --load-restrictor LoadRestrictionsNone debug/httpbin
```
