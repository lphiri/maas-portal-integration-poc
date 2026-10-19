# Keycloak on OpenShift

These files deploy Keycloak and PostgreSQL in the `grid-sso` namespace. They import the `saas`, `grid-tenant-1-idp`, and `grid-tenant-2-idp` realms. They do not deploy the FastAPI app. The client ID, home URL, and callback URI come from `KEYCLOAK_CLIENT_ID`, `KEYCLOAK_HOME_URL`, and `KEYCLOAK_REDIRECT_URI` in `components/keycloak/secrets.env` or `components/keycloak/secrets.yaml`.

## Prepare the Secret file

The deploy script reads the apps domain from the active OpenShift context. It uses `spec.appsDomain` if that value is set. If it is not set, the script uses `spec.domain`. For example, if the apps domain is `apps.example.com`, the script uses `keycloak-grid-sso.apps.example.com` as the Route host. It uses `https://keycloak-grid-sso.apps.example.com` as `KEYCLOAK_PUBLIC_URL`. Your account must be able to read the cluster ingress configuration.

Run these commands from the repository root. Choose one Secret file type.

### Env file

Create `components/keycloak/secrets.env` and set the keys listed in `components/keycloak/secret-template.yaml`.

Set the test-user passwords in this file:

- Set `GRID_TENANT_1_TEST_USER_PASSWORD` for `alice` in `grid-tenant-1-idp`.
- Set `GRID_TENANT_2_TEST_USER_PASSWORD` for `bob` in `grid-tenant-2-idp`.

`KEYCLOAK_CLIENT_ID`, `KEYCLOAK_HOME_URL`, and `KEYCLOAK_REDIRECT_URI` configure the client in the `saas` realm. The deploy script reads these values from `components/keycloak/secrets.env` or `components/keycloak/secrets.yaml` and applies them automatically.

### YAML file

```bash
cp components/keycloak/secret-template.yaml components/keycloak/secrets.yaml
chmod 600 components/keycloak/secrets.yaml
```

Open `components/keycloak/secrets.yaml` and replace each `REPLACE_WITH_...` value. Use the same test-user password mapping as above. Git ignores this file too. The deploy script sets `KEYCLOAK_PUBLIC_URL` from the active cluster context.

## Deploy

After you prepare the Secret file, run one of these commands from the repository root:

```bash
./components/keycloak/deploy.sh
# or
./components/keycloak/deploy.sh --env-file components/keycloak/secrets.env
```

The script prints the active cluster and user. It reads the apps domain and sets the Route host and `KEYCLOAK_PUBLIC_URL`. It applies the namespace and Secret. Then it applies the Kustomize bundle. If you use an env file, the script uses `oc` to create the Secret. It does not write a generated Secret manifest to disk. The script waits for PostgreSQL and Keycloak to finish their rollouts. Then it displays the Route.

The script stops before it applies resources if the Secret file is missing, has placeholder values, does not have all required keys, or if the script cannot read the apps domain.

To check the Route and Keycloak rollout later, run:

```bash
oc -n grid-sso get route keycloak
oc -n grid-sso rollout status deployment/keycloak
```

The Route uses edge TLS termination. Keycloak trusts the Route headers because `KC_PROXY_HEADERS=xforwarded` is set. Keycloak publishes the URL in `KEYCLOAK_PUBLIC_URL`.

## Persistence and realm imports

PostgreSQL has one replica. It uses a 2 GiB PVC and the cluster's default storage class. The PVC keeps the database when a pod restarts. These files do not set up database backups or high availability.

Keycloak imports the three JSON files when it starts for the first time. On later starts, Keycloak skips each realm that already exists. Changes to an import file or client value do not change an existing realm. Use the Keycloak Admin Console or a planned export and import to change an existing realm.

The `saas` realm import hides both IdP buttons on the login page. The providers stay enabled for organization domain routing. If the `saas` realm already exists, open **Identity Providers → Grid Tenant 1 → Settings** and **Identity Providers → Grid Tenant 2 → Settings**. Turn on **Hide on login page** for each provider. Save each change. Realm imports do not change existing realms.

The tenant imports create these groups at the top level of the realms: `grid-tenant-1:ai-grid-admins`, `grid-tenant-1:ai-grid-users`, and `grid-tenant-2:ai-grid-users`. Alice belongs to the first two groups. Bob belongs to the Tenant 2 group. The tenant `saas-broker` clients send these names in the `groups` claim. The names do not have a leading slash. The `saas` realm has no tenant group objects. The `maas_groups` attribute carries the incoming claim to the configured client. The SaaS client's groups and organization mappers add their claims to access tokens, ID tokens, and UserInfo.

For an existing persistent realm, open the existing **MaaS tenant groups** and **MaaS organizations** mappers. In the Admin Console or API, turn on **Add to access token** for each mapper. An import file does not change an existing realm. Get a new token after you save these changes.

The tenant `saas-broker` clients allow these post-logout callback URLs:

- `${KEYCLOAK_PUBLIC_URL}/realms/saas/broker/grid-tenant-1/endpoint/logout_response`
- `${KEYCLOAK_PUBLIC_URL}/realms/saas/broker/grid-tenant-2/endpoint/logout_response`

For an existing realm, set **Valid post logout redirect URIs** for each client in the Admin Console or API. Realm imports do not change existing realms.

### Migrate an existing persistent deployment

If the realms already exist in PostgreSQL, rename the groups in the Admin Console. Realm imports skip realms that already exist. Changes to import files do not change live group names. Do not delete the PostgreSQL PVC or create the database again.

1. In `grid-tenant-1-idp`, rename the existing top-level groups to `grid-tenant-1:ai-grid-admins` and `grid-tenant-1:ai-grid-users`. In `grid-tenant-2-idp`, rename the existing group to `grid-tenant-2:ai-grid-users`. Keep Alice's and Bob's group memberships.
2. Apply the OpenShift manifests. Wait for the Keycloak deployment to finish its rollout. The new group names do not need slash escaping.
3. In each tenant realm, open the existing **MaaS tenant groups** **Group Membership** mapper on the `saas-broker` client. Turn **Full group path** off. Keep the claim name `groups`. Add the claim to ID tokens and UserInfo. Do not add it to access tokens. Keep the **MaaS organization transport** mapper. If a realm uses the older User Attribute mapper, replace it with Group Membership. Do not add a second mapper. Make sure exactly one tenant mapper sends the `groups` claim.
4. Check the tenant broker's ID token or UserInfo. It must contain one of these names: `grid-tenant-1:ai-grid-admins`, `grid-tenant-1:ai-grid-users`, or `grid-tenant-2:ai-grid-users`. The name must not start with a slash.
5. Start a new SaaS broker login. Check the SaaS ID token or UserInfo. Its `groups` claim must contain the colon-qualified names. On this login, the force-sync IdP mapper updates the SaaS `maas_groups` attribute.

Keep the SaaS IdP mappers that copy the incoming `groups` claim to the SaaS user's `maas_groups` attribute. Keep the SaaS client mapper that sends `groups`.
