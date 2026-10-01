# Shipping it: MTA, approuter, XSUAA on Cloud Foundry

`cloud-sdk-bff.md` covers calling SAP from a BFF. This file covers getting that
BFF and its approuter **deployed and logged into** — the layer where failures are
loudest in effect and quietest in diagnostics, because a broken app here is still
`RUNNING` in `cf apps`.

Every item below is a failure that reached a real environment.

---

## 1. Module name = CF app name = the card in the Cockpit

The MTA module name becomes the Cloud Foundry application name, which becomes the
tile a colleague clicks in the BTP Cockpit.

**Give the plain name to the approuter**, not the API:

```yaml
modules:
  - name: my-app            # approuter — this is what users open
    type: nodejs
    path: approuter
  - name: my-app-backend    # the API
    type: python
```

Reversed, the obvious-looking tile opens a service that answers token-less
requests with 401 and has no login flow of its own. Users conclude the app is
broken.

**Renaming cannot be done in one deploy.** The new route collides with the old
app's route. Sequence: `cf delete` both apps, then deploy.

---

## 2. Two full descriptors beat a base + extensions

`mta.yaml` + `dev.mtaext` + `prod.mtaext` looks DRY and reads badly: you mentally
merge two files to answer "what will actually be deployed", and you cannot see
where a value came from.

The concrete failure: a build command **missing its `-e` flag** shipped DEV
service names to PROD. Nothing rejected it.

Two complete descriptors — `mta-dev.yaml`, `mta-prod.yaml` — same structure, same
order, differences marked in comments:

```bash
mbt build -f mta-dev.yaml  --mtar app-dev.mtar
mbt build -f mta-prod.yaml --mtar app-prod.mtar
```

`mbt build -f` has existed since cloud-mta-build-tool#709.

**Then test for drift.** Duplication only works with a test that forbids
undeclared divergence:

```python
ENV_SPECIFIC_PROPS  = {"my-app-backend": {"SAP_DESTINATION", "AUTH_ENFORCED"}}
ENV_SPECIFIC_PARAMS = {"routes"}
# every other difference between the two files fails the test
```

Keep the allow-list short. The longer it gets, the less the two files resemble
each other and the less a reader can transfer knowledge between them.

**Make the bare commands refuse.** `npm run build` with no environment should
exit non-zero with a message, not pick a default.

---

## 3. MTA does not unset env vars you remove from the descriptor

Delete a `properties:` entry, deploy, and the variable is **still set** on the
app. The deployer applies what the descriptor declares; it does not reconcile
removals.

```bash
cf unset-env my-app TENANT_HOST_PATTERN && cf restart my-app
```

Symptom when you forget: you fixed the config, redeployed, and the old behaviour
persists — so you conclude the fix was wrong and go looking in the wrong place.
Verify with `cf env <app> | grep <VAR>` after any removal.

---

## 4. Pin routes; don't rely on `${default-url}`

`${default-url}` resolves at deploy time from org, space and domain. It works —
and it means the deployed address is **not visible in the descriptor**. Reading
two descriptors side by side, you can only guess what one of them deploys.

```yaml
parameters:
  routes:
    - route: myorg-dev-my-app.cfapps.eu10-004.hana.ondemand.com
provides:
  - name: my-app-api
    properties:
      url: "https://myorg-dev-my-app-backend.cfapps.eu10-004.hana.ondemand.com"
```

The approuter's destination should be the backend's **own pinned route**, not a
placeholder: if the placeholder resolves to something unexpected, the approuter
simply cannot reach the backend and you find out in a browser.

**The cost, stated plainly:** a pinned route is a real, existing route. Changing
it **unmaps the old one** and every bookmark breaks. Pin only addresses you have
confirmed with `cf apps`. A drift test can check the org/space prefix and the
role split; it cannot verify the host exists.

---

## 5. XSUAA `tenant-mode` and the `TENANT_HOST_PATTERN` trap

The nastiest failure in this file, because the app starts.

An XSUAA instance created **without** `-c xs-security.json` gets an auto-generated
`xsappname` and may land in `shared` tenant mode. In shared mode the approuter
refuses to start:

```
Error: UAA tenant mode is shared, but environment variable
       TENANT_HOST_PATTERN is not set
```

The obvious workaround is to set it. **Don't** — understand what it does first.
The approuter applies the regex to the request host and treats the **first
capture group as the tenant subdomain**:

```
host:     myorg-dev-my-app.cfapps.eu10-004.hana.ondemand.com
pattern:  ^(.*).cfapps.eu10-004.hana.ondemand.com
tenant:   myorg-dev-my-app
redirect: https://myorg-dev-my-app.authentication.eu10.hana.ondemand.com/oauth/authorize
result:   "The URL does not reference a valid account."
```

No such subaccount exists. The variable **starts the approuter and breaks login**
— `cf apps` shows `RUNNING`, health checks pass, and the only symptom is an SAP
error page after redirect. In one case this sat unnoticed for months because
everyone used the backend URL directly in dev.

For a single-tenant app the correct mode is `dedicated`. `tenant-mode` and
`xsappname` are both **immutable after creation**, so the fix is recreation:

```bash
cf unbind-service my-app-backend my-xsuaa
cf unbind-service my-app          my-xsuaa
cf delete-service my-xsuaa
cf create-service xsuaa application my-xsuaa -c xs-security.json
```

**Order matters:** recreate the service *first*, then remove
`TENANT_HOST_PATTERN` from the descriptor, then deploy, then `cf unset-env`
(see §3). Remove it while the instance is still shared and the approuter will not
start at all.

Also: `TENANT_HOST_PATTERN: ""` is rejected (`String is too short (0 chars)`).
It is a valid pattern or it is absent.

Do this early. While no roles are assigned there is nothing to lose; later,
recreating the instance drops every role assignment.

---

## 6. A backend auth flag does not disable the approuter's login

A flag like `AUTH_ENFORCED=0` that makes your backend skip JWT validation does
**not** stop the approuter from running OAuth. That flow comes from `xs-app.json`:

```json
{ "source": "^/(.*)$", "target": "/$1",
  "destination": "my-app-api",
  "authenticationType": "xsuaa",
  "identityProvider": "sap.custom" }
```

So in a "no auth in dev" setup the approuter still redirects to IAS and still
fails if XSUAA is misconfigured — you just never notice, because the convenient
URL is the backend's.

**Pin `identityProvider` when more than one IdP is available for user logon.**
Otherwise users get an IdP picker and can choose the wrong one. The value is the
Origin Key from the subaccount's Trust Configuration, not the display name.

---

## 7. Cloud Connector and destinations

- **Use the `:443` virtual host.** An `:8000` entry produced an HTTP 307 redirect
  loop that looks like an application bug.
- **Scope the exposed path** to the service prefix
  (`/sap/opu/odata4/sap/<binding>/`, "Path and all sub-paths") rather than opening
  the host.
- **The path must match the service binding name exactly.** A binding renamed
  after the Cloud Connector entry was approved (`ZSB_MY_SRV` vs `ZMY_SB_SRV` —
  same letters, different order)
  gives a 404 that looks like an unpublished service.
- **A missing `sap-client` on the destination** silently falls back to the
  system's default client — the most common DEV-vs-QA difference, and it presents
  as "the data is different" rather than as a config error.

---

## 8. "Not authorized" on push is usually the token, not the role

```
You are not authorized to perform the requested action
```

with SpaceDeveloper genuinely assigned is almost always a **stale token or an IdP
origin mismatch**, not a missing role. Re-login (`cf login --sso`) and confirm the
token's origin matches where the role sits (e.g. `sap.ids` vs a custom IdP).

Chasing the role assignment first costs an afternoon.

---

## 9. Never package `.env`

Secrets reach the archive through the build, not through git.

```yaml
build-parameters:
  ignore:
    - ".env"
    - ".env.*"
```

Verify after every build — one command, no excuse:

```bash
unzip -l mta_archives/app-dev.mtar | grep -i "\.env"
```

Related: don't ignore `node_modules` for a `builder: npm` module. Installing
dependencies and then excluding them pays the install cost and discards the
benefit.

---

## 10. Multi-client landscapes: confirm the target before every deploy

A consultancy space often hosts several customers' orgs. `cf deploy` against the
wrong target is a customer-visible incident, and the command gives no second
chance.

Make `cf target` (display — read-only) a required step before any deploy, and
keep `cf target -o/-s` (switching) out of scripts. If an agent or automation runs
your deploys, this belongs in its instructions, not in your memory.
