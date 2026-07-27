# SAP Cloud SDK for JavaScript in a BFF

Pattern: a small Node/Express backend-for-frontend resolves a BTP destination and
proxies OData calls to the SAP backend server-to-server, so the browser never
holds SAP credentials and CORS/auth stay server-side. Packages:
`@sap-cloud-sdk/connectivity` (`getDestination`) and `@sap-cloud-sdk/http-client`
(`executeHttpRequest`). This is the JS SDK — not the Java one; the APIs differ, so
don't cross-reference Java docs.

## Baseline GET

```ts
import { getDestination } from '@sap-cloud-sdk/connectivity';
import { executeHttpRequest } from '@sap-cloud-sdk/http-client';

const DESTINATION_NAME = 'MY_DEST';

export async function odataGet<T>(path: string): Promise<T> {
  const destination = await getDestination({ destinationName: DESTINATION_NAME });
  if (!destination) throw new Error(`Destination "${DESTINATION_NAME}" not found.`);
  if (!destination.url) throw new Error(`Destination "${DESTINATION_NAME}" has no URL.`);
  const res = await executeHttpRequest(
    { ...destination, url: destination.url },
    { method: 'get', url: path },
  );
  return res.data as T;
}
```

`odataPost`/`odataPatch`/`odataDelete` are the same with `method` and a `data`
body. `path` is relative to the destination URL (the service root).

## THE most important thing: extract the real error

`executeHttpRequest` throws an axios-style error on non-2xx. Its `.message` is the
useless `"Request failed with status code 400"`. The actual SAP reason — the thing
that tells you exactly what's wrong — is in the response *body* as an OData V4
error object `{ error: { code, message } }`, reachable via `.response.data` (and
sometimes nested under `.cause.response.data`).

**Wire this before anything else.** Every hour spent guessing at a 400 is an hour
this function would have saved:

```ts
export function extractODataError(err: unknown): string {
  const e = err as {
    response?: { data?: unknown; status?: number };
    cause?: { response?: { data?: unknown } };
    message?: string;
  };
  const data = e?.response?.data ?? e?.cause?.response?.data;
  if (data && typeof data === 'object' && 'error' in data) {
    const odErr = (data as { error?: { message?: unknown } }).error;
    if (odErr?.message) {
      return typeof odErr.message === 'string' ? odErr.message : JSON.stringify(odErr.message);
    }
  }
  if (typeof data === 'string' && data) return data;
  return e?.message ?? 'Unknown error';
}
```

Use it in every route's catch block and forward the result to the client:

```ts
} catch (err) {
  res.status(502).json({ error: extractODataError(err) });
}
```

Once this is in place, SAP tells you precisely what it wants ("field X mandatory",
"item 000 does not exist", the semantic-pairing message, etc.). Debugging goes
from archaeology to reading the error.

## Following `@odata.nextLink` (server-side pagination)

Reference/value-help entity sets often paginate server-side even with no `$top` —
the response carries `"@odata.nextLink": "Entity?$skiptoken=100"`. If you read only
the first page, dropdowns are silently truncated. Follow every page for
reference data:

```ts
interface ODataPage<T> { value: T[]; '@odata.nextLink'?: string }

export async function odataGetAllPages<T>(path: string): Promise<T[]> {
  const out: T[] = [];
  let next: string | undefined = path;
  let pages = 0;
  const MAX = 50; // guard against a malformed/cyclic nextLink
  while (next && pages < MAX) {
    const page: ODataPage<T> = await odataGet<ODataPage<T>>(next);
    out.push(...page.value);
    next = page['@odata.nextLink'] ? normalize(page['@odata.nextLink']) : undefined;
    pages++;
  }
  return out;
}
const normalize = (p: string) => (p.startsWith('/') ? p : `/${p}`);
```

Scope this to reference/value-help endpoints. Do NOT auto-follow on a paginated
*list report* that has its own `$top`/`$skip` UI — you'd override the user's paging.

## CSRF

The SDK auto-fetches a CSRF token for write methods (POST/PUT/PATCH/DELETE) by
default (`fetchCsrfToken: true`). You normally do nothing. Don't disable it unless
you have a reason. If you ever hand-roll HTTP, do a GET with header
`x-csrf-token: fetch`, read the returned token, and send it on the write.

## Destination auth types

The destination (configured in the BTP cockpit) determines auth; your code usually
doesn't change per type:

- **Basic Authentication** — a technical/communication user's credentials live on
  the destination. No end-user identity flows. Simplest; common for demos and
  service-to-service. `getDestination` + `executeHttpRequest` just works.
- **OAuth2SAMLBearerAssertion / principal propagation** — the *end user's* identity
  is forwarded. This needs the user's JWT (`retrieveJwt` from the incoming request)
  passed to `getDestination({ destinationName, jwt })`. Only relevant when
  end-user login is enabled and the backend must know who the user is.

Don't infer the auth type from the destination *name*. Confirm what the
destination is actually configured as; a name containing "SAML" doesn't guarantee
principal propagation is set up, and vice versa.

## BTP wiring notes

- The BFF needs a `destination` service binding (to call the Destination service)
  and, for its own service-to-service auth, an `xsuaa` binding. That XSUAA is
  separate from end-user login — don't conflate them.
- In an approuter + BFF MTA, route `/api/*` to the BFF via sibling-module routing
  (`requires`/`provides` in `mta.yaml`), which is a plain internal route, not a
  Destination-service hop.
- Local dev usually has no reachable backend (no deployed destination). Keep a
  fixtures/mock path gated behind an env flag and default to it locally; exercise
  the real path only when explicitly enabled or once deployed. This means some
  failures only reproduce after a deploy — surface errors well so that round-trip
  is productive.
