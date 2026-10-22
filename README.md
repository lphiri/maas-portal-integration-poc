# MaaS portal integration

This repository deploys the [Models as a Service](https://opendatahub-io.github.io/models-as-a-service) consumer portal behind an attached MaaS Tenant Gateway. The portal uses an OIDC login flow on its UI paths. Keycloak is a reusable component, and the portal deployment depends on it.

## Layout

- `components/keycloak/` contains the reusable Keycloak component.
- `deploy/maas-portal/` contains the MaaS portal deployment.
- `docs/` contains the architecture and flow notes.
- `scripts/` contains the helper scripts.
- `debug/httpbin/` contains the temporary debug endpoint.

## Before you apply

Copy each example file, then replace its placeholder values:

- `deploy/maas-portal/parameters.env` sets the cluster, Gateway, portal, OIDC, and debug values.
- `components/keycloak/secrets.yaml` or `components/keycloak/secrets.env` sets the Keycloak and PostgreSQL credentials.
- `deploy/maas-portal/oidc-ca.crt` holds the ingress signer CA for the OIDC route.
  The bundle mounts this CA in the auth proxy. Authorino trust uses a separate
  config; see the deployment README.

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
