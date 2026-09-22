<!-- markdownlint-disable-file -->
# Research: Intermittent HTTP 403 on Copilot Studio `shared_azureaisearch` connector behind Azure API Management

Date: 2026-09-22
Status: **Complete** (primary questions answered; three items remain unproven — see Open Questions)
Scope: Deep research only. No code or configuration changed.

---

## 1. Research topics and questions

1. Document the official `shared_azureaisearch` Power Platform connector — auth options, connection parameters, operations (including `SemanticHybridSearch`), and documented throttling limits.
2. Enumerate every plausible cause of an intermittent HTTP 403 on the Copilot Studio → APIM → Azure AI Search path, each with a discriminating test.
3. What does Azure AI Search officially document 403 to mean? Does it use 403 for quota/storage exhaustion?
4. Does the Basic → S1 scale plausibly explain 403s disappearing?
5. What are real reported root causes for Copilot Studio + Azure AI Search 403s?
6. APIM diagnostics — how to tell an APIM-generated 403 from a backend-generated 403.
7. How to correlate a Copilot Studio connector failure → APIM request → Azure AI Search request.

## 2. Customer situation (from workspace inputs)

Source files: assets/usefulScreenshots.md, assets/meetingNotes.md, assets/additionalInfo.md

- Agent "Agent Plateforme Numérique" calls `shared_azureaisearch/SemanticHybridSearch` against **7 indexes per user turn**, top 3 docs each.
- **613** dependency failures with `resultCode` `403`, `type` `Connector`, `target` `shared_azureaisearch/SemanticHybridSearch`.
- Sample failing record attributes: `DesignMode: "True"`, `channelId: "pva-studio"`, `duration: 2566` ms, `serviceName: "Microsoft Copilot Studio"`.
- Azure API Management sits between Copilot Studio and Azure AI Search.
- Errors are **intermittent**. A separate, distinct symptom exists: HTTP 206 semantic partial responses (`@search.semanticPartialResponseReason: "Transient"`, `@search.semanticPartialResponseType: "BaseResults"`).
- Search service recently scaled **Basic → S1**; adding replicas previously improved stability.

Two observations from the telemetry that materially shape the hypothesis ranking:

- **`DesignMode: True` + `channelId: pva-studio`** means these 613 failures came from the **Copilot Studio authoring/test canvas**, not the published channel. Authoring-time traffic can run under a different connection/identity context than runtime traffic.
- **`duration: 2566` ms on a 403.** An APIM inbound policy short-circuit (`ip-filter`, subscription-key check, `validate-jwt`) rejects before any backend call and normally completes in single- or low-double-digit milliseconds. 2.5 s is much more consistent with a full round trip that reached — or attempted to reach — the backend. This is a strong (not conclusive) signal that the 403 is **backend-originated or post-forward**, not an APIM inbound gate.

---

## 3. CRITICAL FINDING — what 403 means for Azure AI Search

Source: [HTTP status codes — Azure AI Search](https://learn.microsoft.com/en-us/rest/api/searchservice/http-status-codes)

Exact quote from the Common HTTP status codes table:

> | 403 Forbidden | Returned when authorization fails. |

Adjacent codes, quoted exactly, because they disprove the storage-quota theory:

> | 401 Unauthorized | Returned when credentials are missing. If you're using role-based access control, you or the search service are missing a role assignment. […] |

> | 402 Payment Required | Returned when the monthly allocation of free semantic ranker requests is exhausted. You might also see this error: "Free Query Semantic Usage exceeded for the month. Please enable semantic billing to continue using semantic search […]". To resolve the error, switch from the free plan to standard billing. |

> | 429 Too Many Requests | If you get this status code during object creation, it means you have the maximum number of objects allowed for your service tier. If you get this error code on an active index, it usually means that you're running low on storage. As you near storage limits, the service can enter a state where you can't add or update until you delete some documents. […] |

**Conclusions:**

- Azure AI Search **does not** use 403 for quota or storage exhaustion. It uses **429** for both "max objects for your tier" and "running low on storage".
- Azure AI Search **does not** use 403 for semantic ranker free-tier exhaustion. It uses **402**.
- For Azure AI Search, 403 means exactly one thing: **authorization failed**. In practice that resolves to either (a) credential/RBAC authorization failure, or (b) **network authorization failure** — the IP firewall rejecting the caller. See §5.

---

## 4. The `shared_azureaisearch` connector — official reference

Source: [Azure AI Search — Power Platform connector reference](https://learn.microsoft.com/en-us/connectors/azureaisearch/)

### 4.1 Availability

| Service | Class | Regions |
| --- | --- | --- |
| Copilot Studio | Premium | All Power Automate regions except GCC High, China (21Vianet), DoD |
| Logic Apps | Standard | All Logic Apps regions except Azure China, DoD |
| Power Apps / Power Automate | Premium | All regions except GCC High, China (21Vianet), DoD |

### 4.2 Authentication types (exact from the connector reference)

| Display name | Auth ID | Applicable | Shareable | Parameters |
| --- | --- | --- | --- | --- |
| (Access key, default display) | `adminkey` | All regions except Azure Gov / GCC | **Not shareable** | `Azure AI Search Endpoint URL` (string, required), `Azure AI Search Admin Key` (securestring, required) |
| Access Key | `adminkey` | Azure Gov + GCC only | Not shareable | Same two parameters |
| Client Certificate Auth | `certOauth` | All regions | **Shareable** | Endpoint URL, Tenant, Client ID, Client certificate secret (PFX + password) |
| Managed Identity | `managedIdentityAuth` | **LOGICAPPS only** | Shareable | Managed Identity, Endpoint URL |
| Microsoft Entra ID Integrated | `oauth` | All regions | Not shareable | Endpoint URL only |
| Service principal (Entra ID application) | `oauthSP` | All regions | Not shareable | Endpoint URL, Tenant, Client ID, Client Secret |
| Default `[DEPRECATED]` | — | All regions | Not shareable | Endpoint URL, Admin Key. "This option is only for older connections without an explicit authentication type, and is only provided for backward compatibility." |

Facts that matter for this investigation:

- The key-based modes require the **Admin Key**, not a query key. The connector reference field is literally `Azure AI Search Admin Key`.
- **Managed Identity is Logic Apps only** — it is *not* available to a Copilot Studio connection. So in Copilot Studio the only choices are admin key, Entra ID Integrated (user delegated), service principal, or client certificate.
- Non-shareable connection types mean **each maker/user can end up with their own connection instance**. Different connection instances can carry different credentials and can drift independently — a first-class explanation for "some calls succeed, some 403".
- `Microsoft Entra ID Integrated` (`oauth`) binds to the **signed-in user**. In `DesignMode: True` / `pva-studio` traffic, that user is the maker. A maker without a `Search Index Data Reader` role assignment produces a deterministic 403 for their own test traffic while published runtime traffic (on a different connection) succeeds.

### 4.3 Documented throttling limit

Exact from the connector reference:

> ## Throttling Limits
>
> | Name | Calls | Renewal Period |
> | --- | --- | --- |
> | API calls per connection | 200 | 60 seconds |

Arithmetic for this workload: 7 indexes = **7 connector calls per user turn**. 200 calls / 60 s ÷ 7 calls per turn ≈ **28 user turns per minute per connection** before the connector-level throttle engages. At the stated 7–15 users/hour this is far from the limit in steady state, but a burst (multiple simultaneous users, or a maker hammering the test pane) can transiently exceed it.

**Important caveat:** the connector reference does **not** document which HTTP status code is returned when the 200/60 s limit is hit. It is not stated to be 403. Treat "connector throttle surfacing as 403" as **unproven** (see Open Questions).

### 4.4 Operations (actions) exposed by the connector

`KnowledgeAgentRetrieval` (Agentic Search, preview), `DeleteDocument`, `DeleteDocuments`, `GetIndexStatistics`, `GetIndexesSchema`, `IndexDocument`, `IndexDocuments`, `MergeDocument`, `VectorSearch`, `IntegratedVectorSearch`, **`SemanticHybridSearch`**.

`SemanticHybridSearch` — "Semantic hybrid search with filter." Parameters:

| Name | Key | Required | Type |
| --- | --- | --- | --- |
| Index Name | `indexName` | **True** | string |
| Search Text | `searchText` | | string |
| Vectorized Search Fields | `vectorizedSearchFields` | | array of string |
| Semantic Configuration | `semanticConfiguration` | | string |
| Select Fields | `selectFields` | | array of string |
| Filter condition | `filterCondition` | | string |
| SessionId | `sessionId` | | string |
| Nearest Neighbors | `nearestNeighbors` | | integer |
| Top Searches | `top` | | integer |
| Skip Searches | `skipSearches` | | integer |

Returns: `response` — array of Object.

Note: `SemanticHybridSearch` maps to [Documents - Search Post](https://learn.microsoft.com/en-us/rest/api/searchservice/documents/search-post) with `queryType: semantic` plus `vectorQueries`. That REST operation accepts an `x-ms-client-request-id` request header ("An opaque, globally-unique, client-generated string identifier for the request") — but the connector surfaces **no parameter to set it**, which is central to the correlation problem in §9.

### 4.5 Connector egress IPs — do they change?

Source: [Managed connectors outbound IP addresses](https://learn.microsoft.com/en-us/connectors/common/outbound-ip-addresses)

Exact quotes:

> The preferred way to obtain the most current up-to-date lists of outbound IP addresses and service tags is to programmatically utilize the Service Tag Discovery API.

> **Note**: It is recommended to update the IP addresses allow listed in your inbound firewalls at least every 90 days.

> **Important**: To minimize impact from future changes, please allow-list your regional **PowerPlatformPlex** service tag along with the existing **AzureConnectors** tags.

> **Important**: All service tags associated with a **flow's Geo** must be allow-listed - regardless of the location of the target resource(s).

Power Platform geo → service tag mapping (subset, exact from the doc):

| Geo (multi-tenant region) | Service tags |
| --- | --- |
| Canada | `AzureConnectors.CanadaCentral`, `AzureConnectors.CanadaEast` |
| Europe | `AzureConnectors.NorthEurope`, `AzureConnectors.WestEurope` |
| France | `AzureConnectors.FranceCentral`, `AzureConnectors.FranceSouth` |
| United States | `AzureConnectors.NorthCentralUS`, `AzureConnectors.SouthCentralUS`, `AzureConnectors.CentralUS`, `AzureConnectors.EastUS`, `AzureConnectors.EastUS2`, `AzureConnectors.WestUS`, `AzureConnectors.WestUS2`, `AzureConnectors.WestUS3` |
| United Kingdom | `AzureConnectors.UKNorth`, `AzureConnectors.UKSouth`, `AzureConnectors.UKSouth2`, `AzureConnectors.UKWest` |

Also relevant: [Power Platform URLs and IP address ranges](https://learn.microsoft.com/en-us/power-platform/admin/online-requirements):

> **Important**: Don't rely on an individual environment's currently resolved IP addresses to allow list firewalls, because those addresses can change over time. Instead, allow the IP ranges published for the applicable Azure service tags, and refresh your allow list regularly from the service tag files.

**This is the single most important architectural fact for an intermittent 403.** Connector egress is **not a stable set of a few IPs**. It spans *every* `AzureConnectors.<Region>` prefix in the geo (two regions minimum, eight for US), and those prefixes change. An allow-list built by observing a handful of source IPs once, or by adding only one of the geo's two regions, produces **exactly** the observed symptom: most requests succeed, a stable minority get 403 whenever load balancing lands them on a non-allow-listed prefix.

---

## 5. APIM: which policies return 403 vs 429 vs 401

This was a specific research question. Answers, each with an exact quote.

### 5.1 Policies that return **403 Forbidden**

**`quota`** — [quota policy reference](https://learn.microsoft.com/en-us/azure/api-management/quota-policy):

> The `quota` policy enforces a renewable or lifetime call volume and/or bandwidth quota, on a per subscription basis. **When the quota is exceeded, the caller receives a `403 Forbidden` response status code**, and the response includes a `Retry-After` header whose value is the recommended retry interval in seconds.

Usage notes from the same page: "This policy can be used only once per policy definition." / "This policy is only applied when an API is accessed using a subscription key." Scope: **product** only. Sections: inbound.

**`quota-by-key`** — [quota-by-key policy reference](https://learn.microsoft.com/en-us/azure/api-management/quota-by-key-policy):

> The `quota-by-key` policy enforces a renewable or lifetime call volume and/or bandwidth quota, on a per key basis. […] **When the quota is exceeded, the caller receives a `403 Forbidden` response status code**, and the response includes a `Retry-After` header whose value is the recommended retry interval in seconds.

Scopes: global, workspace, product, API, operation. Minimum `renewal-period` is 300 seconds. Applies to Developer | Basic | Standard | Premium (not Consumption).

Both pages carry the same caveat:

> **Note**: When underlying compute resources restart in the service platform, API Management might continue to handle requests for a short period after a quota is reached.

**`ip-filter`** — [Error handling in Azure API Management policies](https://learn.microsoft.com/en-us/azure/api-management/api-management-error-handling-policies), Predefined errors for policies table:

> | ip-filter | Caller IP isn't in allowed list | `CallerIpNotAllowed` | Caller IP address {ip-address} is not allowed. Access denied. |
> | ip-filter | Caller IP is in blocked list | `CallerIpBlocked` | Caller IP address is blocked. Access denied. |
> | ip-filter | Failed to parse caller IP from request | `FailedToParseCallerIP` | Failed to establish IP address for the caller. Access denied. |

The [ip-filter policy reference](https://learn.microsoft.com/en-us/azure/api-management/ip-filter-policy) does not print the numeric status code on the page, but the behavior is a deny ("Access denied") and the conventional surfaced code is 403. Critically it also documents:

> If `action` is set to `allow`, requests that don't match any `address` or `address-range` are **denied**. If `action` is set to `forbid`, requests that don't match any `address` or `address-range` are allowed.

> If you configure this policy at more than one scope, IP filtering is applied in the order of policy evaluation in your policy definition.

### 5.2 Policy that returns **429 Too Many Requests** (not 403)

**`rate-limit`** — [rate-limit policy reference](https://learn.microsoft.com/en-us/azure/api-management/rate-limit-policy):

> The `rate-limit` policy prevents API usage spikes on a per subscription basis by limiting the call rate to a specified number per a specified time period. **When the call rate is exceeded, the caller receives a `429 Too Many Requests` response status code.**

Error-handling table confirms:

> | rate-limit | Rate limit exceeded | `RateLimitExceeded` | Rate limit is exceeded |

`rate-limit-by-key` behaves the same way (429).

**Therefore: rate limiting is ruled out as a source of 403. Quota is not.** This is the single most commonly misunderstood distinction in this failure mode.

### 5.3 What APIM returns for a missing / invalid subscription key — **401, not 403**

[Subscriptions in Azure API Management](https://learn.microsoft.com/en-us/azure/api-management/api-management-subscriptions):

> 3. Otherwise, API Management denies access (**401 Access denied** error).

and, for a request without a key:

> 3. If no configured product or API is found, then API Management denies access (**401 Access denied** error).

Error-handling table:

> | authorization | Subscription key not supplied | `SubscriptionKeyNotFound` | Access denied due to missing subscription key. Make sure to include subscription key when making requests to this API. |
> | authorization | Subscription key value is invalid | `SubscriptionKeyInvalid` | Access denied due to invalid subscription key. Make sure to provide a valid key for an active subscription. |

**Conclusion: `Ocp-Apim-Subscription-Key` problems produce 401, not 403.** The observed 403s are not caused by a missing/rotated/suspended subscription key. (Note: this makes a *constant* 401 the expected signature of a key problem, and neither matches the reported symptom.)

### 5.4 `validate-jwt` and `check-header`

From the error-handling reference, all `validate-jwt` failures (`TokenNotPresent`, `TokenSignatureInvalid`, `TokenAudienceNotAllowed`, `TokenIssuerNotAllowed`, **`TokenExpired`**, `TokenSignatureKeyNotFound`, `TokenClaimNotFound`, `TokenClaimValueNotAllowed`, `JwtInvalid`) and `check-header` failures (`HeaderNotFound`, `HeaderValueNotAllowed`) all end with "Access denied."

`validate-jwt` has configurable `failed-validation-httpcode`; its **default is 401**, and it is frequently set to 403 in hardened policies. `check-header` likewise has a configurable `failed-check-httpcode`. So both *can* produce 403 in this environment — you must read the actual policy XML, not assume.

### 5.5 APIM with no `on-error` section

> If there's no `on-error` section, callers receive 400 or 500 HTTP response messages if an error condition occurs.

This means an un-instrumented APIM will give you nothing useful on the wire. Adding `on-error` (§8.3) is the cheapest instrumentation available.

---

## 6. Azure AI Search IP firewall: the documented 403

Source: [Configure Network Access — Azure AI Search](https://learn.microsoft.com/en-us/azure/search/service-configure-firewall)

Exact quote:

> After you enable the IP access control policy, **requests from IP addresses outside the allowed list are rejected with a 403 Forbidden response**.

Supporting facts from the same page:

> Network rules are scoped to data plane operations against the search service's public endpoint, which include creating indexes, **querying indexes**, and all other actions described in the Search Service REST APIs.

> It can take several minutes for changes to take effect. **Wait at least 15 minutes before you troubleshoot problems related to network configuration.**

> To get the public IP addresses of Azure services, see Azure IP Ranges and Service Tags.

> Firewall configuration isn't supported on the Free tier. (Basic tier or higher required.)

Trusted-services exception — note carefully what it covers:

> The trusted service list for Azure AI Search includes:
> - `Microsoft.CognitiveServices` for Azure OpenAI and Foundry Tools.
> - `Microsoft.MachineLearningServices` for Azure Machine Learning.

**Power Platform / Copilot Studio managed connectors are NOT on the Azure AI Search trusted services list.** Ticking "Allow Azure services on the trusted services list" will not exempt connector traffic. Only explicit IP/CIDR allow-listing (or a private endpoint with a VNet-resident proxy) works.

### 6.1 Azure AI Search RBAC — how it produces 403 vs 401

Source: [Connect Using Azure Roles — Azure AI Search](https://learn.microsoft.com/en-us/azure/search/search-security-rbac), Troubleshooting section:

> The default configuration for a search service is key-based authentication. **If you don't change this setting to Both or Role-based access control, all requests that use role-based authentication are automatically denied, regardless of the underlying permissions.**

> If your request includes an API key alongside role-based credentials, **the service authenticates using the key**. Remove the API key from your request headers to use role-based authentication.

> If the authorization token comes from a managed identity and you recently assigned the appropriate permissions, **it might take several hours for the permissions assignments to take effect**.

Role IDs for the data plane (for the discriminating tests):

| Role | ID |
| --- | --- |
| Search Index Data Reader | `1407120a-92aa-4202-b7e9-c0e197c71c8f` |
| Search Index Data Contributor | `8ebe5a00-799e-43f5-93ac-243d3dce84a7` |
| Search Service Contributor | `7ca78c08-252a-4471-8644-bb5ff32d4ba0` |

Also relevant: **per-index role scoping is supported** (`.../searchServices/<svc>/indexes/<index-name>` scope). With 7 indexes, an identity granted at index scope on 6 of 7 indexes produces a *pattern-looking* intermittent 403 that is actually deterministic per index. This is a high-value, cheap-to-check hypothesis.

Conditional Access is also documented here:

> If you need to enforce organizational policies, such as multifactor authentication, use Microsoft Entra Conditional Access. […] Under **Cloud apps or actions**, add **Azure AI Search** as a cloud app.

> **Important**: If your search service has a managed identity assigned to it, the specific search service appears as a cloud app. However, selecting that specific search service doesn't enforce the policy. Instead, select the general **Azure AI Search** cloud app.

A CA policy scoped to the Azure AI Search cloud app that requires compliant device / MFA / named location will block the connector's non-interactive token and produce an authorization failure. This only applies to the `oauth` / `oauthSP` / `certOauth` connection modes.

---

## 7. Does Basic → S1 explain the 403s disappearing?

Short answer: **No, not by any documented mechanism.** Here is the evidence.

Source: [Service Limits for Tiers and SKUs — Azure AI Search](https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity)

### 7.1 Partition storage (GB)

| Service creation date | Basic | S1 |
| --- | --- | --- |
| Before April 3, 2024 | **2** | **25** |
| April 3, 2024 through May 17, 2024 | **15** | **160** |
| After May 17, 2024 | 15 | 160 |
| After February 10, 2025 | 15 | 160 |

Partitions: Basic = 3 (new services after Apr 3 2024; **older Basic services are limited to 1 partition** and 3 replicas). S1 = 12 partitions, 12 replicas.

So a pre-April-2024 Basic service has a **2 GB total storage ceiling**. That is genuinely tiny and easy to hit with 7 vector-bearing indexes. **But the documented failure code for hitting it is 429, not 403** (§3). And the failure mode is described as "you can't add or update until you delete some documents" — i.e. it degrades **writes**, not reads.

### 7.2 Vector index size quota

| Service creation date | Basic | S1 |
| --- | --- | --- |
| Before July 1, 2023 | 0.5 | 1 |
| July 1, 2023 – April 3, 2024 | 1 | 3 |
| April 3, 2024 – May 17, 2024 | **5** | **35** |
| After May 17, 2024 | 5 | 35 |

> This quota is a hard limit to ensure your service remains healthy. **Further indexing attempts once the limit is exceeded result in failure.**

Again: **indexing attempts**, i.e. writes. Not query-time 403.

### 7.3 Index count limits

| Resource | Basic | S1 |
| --- | --- | --- |
| Maximum indexes | 5 or 15 (5 for services created before December 2017) | 50 |

7 indexes exceeds the Basic limit **only if the service was created before December 2017**. And per §3, exceeding max objects returns **429 during object creation** — not a query-time 403.

### 7.4 Semantic ranker throttling — the real thing Basic → S1 fixed

| Resource | Basic | S1 | S2 | S3 |
| --- | --- | --- | --- | --- |
| Maximum concurrent requests (per search unit) | **2** | **3** | 4 | 4 |
| Maximum request queue size (per search unit) | **4** | **6** | 8 | 8 |

> Semantic ranker uses a queuing system to manage concurrent requests. […] When the limit of concurrent requests is reached, the system places additional requests in a queue. **If the queue is full, the system rejects further requests and they must be retried.**

**This is the mechanism that Basic → S1 actually improves: +50 % concurrent semantic requests and +50 % queue depth per search unit.** And it maps precisely onto the *other* symptom the customer reported — the 206 partial responses. From [Documents - Search Post](https://learn.microsoft.com/en-us/rest/api/searchservice/documents/search-post), `SemanticErrorReason` enum:

| Value | Description |
| --- | --- |
| `maxWaitExceeded` | `semanticMaxWaitInMilliseconds` was set and the semantic processing duration exceeded that value. Only the base results were returned. |
| `capacityOverloaded` | **The request was throttled.** Only the base results were returned. |
| `transient` | At least one step of the semantic process failed. |

And 206 itself, from the HTTP status codes page:

> | 206 Partial Content | Partial success on GET or POST for knowledge base retrieval in agentic retrieval workflows. Returned when the request succeeded but certain noncritical components of the retrieval or ranking process failed, leading to incomplete results or rankings that might not reflect the full relevance scoring. |

With 7 indexes fanned out per turn, each turn issues **7 concurrent semantic requests**. On Basic at 1 SU that is 2 concurrent + 4 queued = capacity 6 — **a single user turn alone can overflow the Basic semantic queue**. On S1 at 1 SU it is 3 + 6 = 9, which absorbs one turn. That is a clean, quantitative explanation for the 206s and for why adding replicas helped.

### 7.5 Verdict on Q4

- Basic → S1 **fully and quantitatively explains the 206 partial-response improvement** (semantic ranker concurrency/queue) and the earlier replica-count improvement.
- Basic → S1 **does not explain a 403** by any documented Azure AI Search mechanism. Storage exhaustion is 429, object-count exhaustion is 429, semantic free-tier exhaustion is 402.
- **Caution on a common reasoning error:** the 403s and the tier change may simply be **coincidental in time**. Scaling a service is an ARM control-plane operation; it is also the kind of change that is frequently accompanied by *other* edits in the same maintenance window (firewall rule edits, key regeneration, policy edits). If the 403s stopped when the tier changed, the far more likely cause is **something else changed in the same window**. Check the Activity Log for that window before attributing the fix to the SKU.

---

## 8. Ranked hypothesis table

Ranking weights: (a) does the documented mechanism actually produce **403** (not 429/401/402)?; (b) does it produce an **intermittent** pattern?; (c) does it fit `duration: 2566 ms`?; (d) does it fit `DesignMode: True` / `pva-studio`?

| # | Hypothesis | Likelihood | Why it fits / doesn't | Discriminating test | Fix |
| --- | --- | --- | --- | --- | --- |
| **1** | **Azure AI Search IP firewall (`Selected IP addresses`) allow-list does not cover the full set of connector egress prefixes** — or covers only part of the geo's `AzureConnectors.<Region>` tags, or has gone stale | **High** | Documented to return exactly `403 Forbidden`. Intrinsically intermittent: egress load-balances across many prefixes across ≥2 regions per geo, and prefixes change. Fits a *minority* failure rate against a majority of successes. Note this applies to APIM's outbound IP too if APIM is the caller | `az search service show -n <svc> -g <rg> --query "{pna:publicNetworkAccess, rules:networkRuleSet.ipRules}"`. Compare against the current `AzureConnectors.<Region>` + `PowerPlatformPlex.<Region>` prefixes from the Service Tag Discovery API for **every** region in the Power Platform geo. Then check Search resource logs for `ResultSignature == 403` — **if the 403s appear in the Search logs, the search service is the rejecter**; if they don't, Search never saw the request | Allow-list the full service-tag prefix set for the geo and refresh ≥ every 90 days; better, restrict Search to only APIM's outbound IPs and let APIM be the single ingress point (see also Fix Option B in §11) |
| **2** | **APIM `quota` / `quota-by-key` policy exceeded** | **High** | The *only* APIM throttling construct that returns **403** (`rate-limit` returns 429). Intermittent by design — trips inside a renewal window, clears at window reset. The 7-calls-per-turn fan-out is exactly the burst shape that trips a call-volume quota. Response carries a `Retry-After` header — a free, decisive fingerprint | Read the policy XML at global/product/API/operation scope for `<quota` or `<quota-by-key`. Then run the KQL in §8.2 filtering `LastErrorSource == "quota"` / `LastErrorReason == "QuotaExceeded"`. On the wire, look for `Retry-After` on a 403 response | Raise or remove the quota; or switch the intent to `rate-limit` (429 + client retry) if the goal is burst smoothing rather than billing-style volume capping |
| **3** | **APIM `ip-filter` policy denying a subset of connector egress prefixes** | **High** | Same root shape as #1 but enforced at APIM instead of Search. Documented errors `CallerIpNotAllowed` / `CallerIpBlocked` / `FailedToParseCallerIP`, all "Access denied" | KQL in §8.2 filtering `LastErrorSource == "ip-filter"`. Cross-check `CallerIpAddress` on failing vs succeeding `ApiManagementGatewayLogs` rows — see the §8.4 query, which is the highest-signal single query in this document | Replace hand-maintained IP literals with the full geo service-tag prefix set, refreshed on a schedule; or move the allow decision to NSG/service-tag-aware controls |
| **4** | **Per-index RBAC scoping — identity lacks a data-plane role on a subset of the 7 indexes** | **Medium-High** | Produces 403 ("authorization fails"). *Looks* intermittent in aggregate but is deterministic per index. Would show a strong skew toward specific `indexName` values. Cheap to rule in/out | Group the 613 failures by index. If the connector telemetry doesn't carry `indexName`, group Search resource-log 403s by `IndexName_s`. **If the 403s cluster on 1–2 indexes, this is your answer.** Then `az role assignment list --scope .../searchServices/<svc>` and compare with the per-index scopes | Assign `Search Index Data Reader` at **service scope** rather than per-index, or add the missing index-scoped assignments |
| **5** | **Multiple connection instances with divergent credentials** (non-shareable connector + `DesignMode: True` maker traffic) | **Medium-High** | The connector's key/OAuth modes are explicitly **"not shareable"** — each maker gets their own connection. A maker with a stale admin key or without a Search role assignment 403s in the test canvas while runtime succeeds. Squarely fits `DesignMode: True` + `channelId: pva-studio` | In the Power Platform admin center, list all `shared_azureaisearch` connections in the environment and their owners/status. Compare the 613 failures' `user_Id` values (`pva-studio89450329-…`) — if they concentrate on one or two makers, this is it. Also test: does the **published** agent 403? | Consolidate onto a single service-principal connection; if using Entra ID Integrated, grant every maker `Search Index Data Reader` |
| **6** | **Azure AI Search `authOptions` / `disableLocalAuth` mismatch with the connection's auth mode** | **Medium** | Documented: with key-only auth configured, "all requests that use role-based authentication are automatically denied". Conversely `disableLocalAuth: true` kills admin-key connections. Usually **constant**, not intermittent — unless mixed connection modes coexist (see #5) | `az search service show -n <svc> -g <rg> --query "{authOptions:authOptions, disableLocalAuth:disableLocalAuth}"`. Compare with the auth type on every connection instance | Set the service to `Both` while migrating, then to RBAC-only once all connections use Entra |
| **7** | **APIM `validate-jwt` / `check-header` with `failed-validation-httpcode="403"`** (incl. token expiry) | **Medium** | `TokenExpired` is a real intermittent 403 source *if* the policy is configured to 403 rather than the 401 default. Fits a periodic burst pattern aligned to token lifetime | Read the policy XML for `failed-validation-httpcode`. KQL filter `LastErrorSource == "validate-jwt"` / `LastErrorReason == "TokenExpired"` | Fix token acquisition/caching upstream; leave the policy's own code at 401 so the distinction stays legible |
| **8** | **Conditional Access policy on the "Azure AI Search" cloud app** (only if connection uses `oauth`/`oauthSP`/`certOauth`) | **Medium-Low** | Produces authorization failure. Would correlate with maker identity / named location / device compliance — plausibly intermittent across users. Not applicable to `adminkey` connections | Entra ID → Conditional Access → sign-in logs filtered to the Azure AI Search resource and the connection's service principal / maker users. Look for `Failure` with a CA policy name | Exclude the service principal, or scope the CA policy to exclude non-interactive workload identities |
| **9** | **APIM behind Front Door / WAF / App Gateway, or APIM VNet NSG asymmetry** | **Medium-Low** | WAF can emit 403 on a rule match — and WAF rules fire on **content**, which makes it look random but is actually query-text-dependent. Very plausible given search text is user-supplied French free text | If a WAF fronts APIM, query WAF logs (`AzureDiagnostics` / `AGWFirewallLogs`) for blocks in the same window. Test: replay one failing `searchText` verbatim vs a benign one | Tune/disable the offending managed rule for this route |
| **10** | **Connector-level throttle (200 calls / 60 s per connection) surfacing as 403** | **Low-Medium** | Mechanism is real and documented; **the returned status code is not documented** and is conventionally 429. 7 calls/turn makes the limit reachable in bursts. Cannot be confirmed from docs | Count connector dependency calls per minute per connection in App Insights (§8.5 query). If 403 bursts coincide with minutes where the count approaches 200, this is live | Reduce fan-out (route to 1–2 relevant indexes instead of all 7) and/or shard across multiple connections |
| **11** | **APIM subscription key missing / invalid / suspended** | **Low** | **Documented as 401, not 403.** Only reaches 403 if an `on-error` block rewrites it | KQL filter `LastErrorSource == "authorization"` and `LastErrorReason in ("SubscriptionKeyNotFound","SubscriptionKeyInvalid")`, then compare `ResponseCode` | Fix the key; remove any `on-error` code-rewriting that masks 401 as 403 |
| **12** | **Search storage / vector / index-count quota exhaustion (the Basic→S1 theory)** | **Very Low — contradicted by docs** | Azure AI Search documents **429** for storage and object-count exhaustion and **402** for semantic free-tier exhaustion. **403 is documented solely as "authorization fails."** Also, quota exhaustion degrades **writes**, not queries | Check the `IndexStorageUsage` / `IndexVectorUsage` metrics historically for the pre-scale window. Even if they were near the ceiling, the code would have been 429 | Not the 403 fix. It *is* relevant to indexing-pipeline health and to the 206s |
| **13** | **APIM tier capacity exhaustion / self-hosted gateway health** | **Very Low** | Capacity pressure manifests as 429/500/503 and latency, not 403. Self-hosted gateway rate-limit counters don't sync with the managed gateway, but that affects 429 accuracy, not 403 | `Capacity` metric (classic) or CPU/memory metrics (v2) for the window. Cross-check `ApiManagementGatewayLogs` `Region` / gateway dimension | Scale units; not a 403 remedy |

---

### 8.1 Enable the diagnostics first

Per [Tutorial - Monitor APIs in Azure API Management](https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-use-azure-monitor):

> To configure a diagnostic setting for collection of resource logs: […] Under **Categories**: Select one or more categories. For example, select **Logs related to ApiManagement Gateway** […] If you select a Log Analytics workspace, you can choose to store the data in a resource-specific table (for example, an ApiManagementGatewayLogs table) or store in the general AzureDiagnostics table. **We recommend using the resource-specific table** for log destinations that support it.

> **Note**: The Consumption tier doesn't support the collection of resource logs.

> Default settings do not include details of requests or responses such as request or response bodies. You can adjust the logging settings for all APIs, or override them for individual APIs. […] adjust the sampling rate or the verbosity of the gateway log data

> **Important**: API Management enforces a 32 KB limit for the size of log entries sent to Azure Monitor. […] Logged request or response payloads in a log entry, if collected, can be up to 8,192 bytes each.

Actions required before any KQL below returns useful rows:

1. Diagnostic setting on the APIM instance → category **Logs related to ApiManagement Gateway** → destination Log Analytics, **resource-specific table** (`ApiManagementGatewayLogs`).
2. APIs → All APIs → Settings → Diagnostic Logs → Azure Monitor → set **sampling to 100 %** and **verbosity to Error or Information**, and enable **headers** (and optionally response body, bounded at 8 KB) at least temporarily for the search API.
3. Diagnostic setting on the Azure AI Search service → category **OperationLogs** → same workspace. (Search logs land in `AzureDiagnostics`, not a resource-specific table.)

### 8.2 KQL — split APIM-generated 403s from backend-generated 403s

`ApiManagementGatewayLogs` columns used here are all from the [table reference](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/apimanagementgatewaylogs): `ResponseCode`, `BackendResponseCode`, `LastErrorSource`, `LastErrorReason`, `LastErrorMessage`, `LastErrorScope`, `LastErrorSection`, `CorrelationId`, `CallerIpAddress`, `BackendUrl`, `Url`, `ApiId`, `OperationId`, `ApimSubscriptionId`, `IsRequestSuccess`, `TotalTime`, `BackendTime`, `Errors`, `ResponseHeaders`, `BackendResponseHeaders`, `BackendResponseBody`.

**This is the highest-value query in this document.** `BackendResponseCode` is `0`/empty when APIM never forwarded the request — that is the clean discriminator.

```kusto
// ============================================================
// Q1 — Who returned the 403: APIM policy, or the backend?
// ============================================================
ApiManagementGatewayLogs
| where TimeGenerated between (datetime(2026-09-18T00:00:00Z) .. datetime(2026-09-19T00:00:00Z))
| where ResponseCode == 403
| extend Verdict = case(
      isnotempty(LastErrorSource) and LastErrorSource in ("quota","ip-filter","validate-jwt","check-header","authorization","rate-limit","configuration"),
          strcat("APIM POLICY: ", LastErrorSource, " / ", LastErrorReason),
      BackendResponseCode == 403,
          "BACKEND (Azure AI Search) returned 403",
      isnull(BackendResponseCode) or BackendResponseCode == 0,
          "APIM short-circuited before forwarding (no backend call)",
      strcat("OTHER — backend code ", tostring(BackendResponseCode)))
| summarize
      Failures        = count(),
      FirstSeen       = min(TimeGenerated),
      LastSeen        = max(TimeGenerated),
      DistinctCallers = dcount(CallerIpAddress),
      SampleCaller    = any(CallerIpAddress),
      SampleMessage   = any(LastErrorMessage),
      MedianTotalMs   = percentile(TotalTime, 50),
      MedianBackendMs = percentile(BackendTime, 50)
  by Verdict, ApiId, OperationId, LastErrorSource, LastErrorReason, LastErrorScope, LastErrorSection
| order by Failures desc
```

Interpreting `MedianTotalMs` against the observed `duration: 2566` ms:

- `MedianTotalMs` in the tens of ms + `BACKEND…` absent → APIM inbound short-circuit. **Does not match the 2.5 s observation.**
- `MedianBackendMs` in the hundreds-to-thousands of ms and `BackendResponseCode == 403` → backend rejected after a real round trip. **Matches the 2.5 s observation.** This points at hypotheses #1, #4, #6, #8.

```kusto
// ============================================================
// Q2 — Confirm / deny the APIM quota hypothesis (403 + Retry-After)
// ============================================================
ApiManagementGatewayLogs
| where TimeGenerated > ago(7d)
| where ResponseCode == 403
| extend RetryAfter = tostring(ResponseHeaders["Retry-After"])
| extend IsQuota = (LastErrorSource == "quota" or LastErrorReason == "QuotaExceeded" or isnotempty(RetryAfter))
| summarize Count = count(), SampleRetryAfter = any(RetryAfter), SampleMsg = any(LastErrorMessage)
    by IsQuota, LastErrorSource, LastErrorReason, ApimSubscriptionId, bin(TimeGenerated, 1h)
| order by TimeGenerated asc, Count desc
// A populated Retry-After on a 403, or LastErrorMessage starting
// "Out of call volume quota. Quota will be replenished in xx:xx:xx"
// is conclusive proof of hypothesis #2.
```

```kusto
// ============================================================
// Q3 — Separate rate-limit (429) from quota (403); prove they are different populations
// ============================================================
ApiManagementGatewayLogs
| where TimeGenerated > ago(7d)
| where ResponseCode in (403, 429)
| summarize Count = count() by ResponseCode, LastErrorSource, LastErrorReason
| order by Count desc
// Expect: 429 <-> rate-limit/RateLimitExceeded ; 403 <-> quota/QuotaExceeded or ip-filter/CallerIpNotAllowed
```

### 8.3 Make APIM tell you the truth on the wire — `on-error` instrumentation

From the [error handling reference](https://learn.microsoft.com/en-us/azure/api-management/api-management-error-handling-policies). Add to the search API policy; it costs nothing and turns an opaque 403 into a labelled one that even the connector's response body will carry.

```xml
<policies>
  <inbound><base /></inbound>
  <backend><base /></backend>
  <outbound><base /></outbound>
  <on-error>
    <set-header name="X-Diag-ErrorSource" exists-action="override">
      <value>@(context.LastError.Source)</value>
    </set-header>
    <set-header name="X-Diag-ErrorReason" exists-action="override">
      <value>@(context.LastError.Reason)</value>
    </set-header>
    <set-header name="X-Diag-ErrorMessage" exists-action="override">
      <value>@(context.LastError.Message)</value>
    </set-header>
    <set-header name="X-Diag-ErrorScope" exists-action="override">
      <value>@(context.LastError.Scope)</value>
    </set-header>
    <set-header name="X-Diag-ErrorSection" exists-action="override">
      <value>@(context.LastError.Section)</value>
    </set-header>
    <set-header name="X-Diag-ErrorPolicyId" exists-action="override">
      <value>@(context.LastError.PolicyId)</value>
    </set-header>
    <set-header name="X-Diag-StatusCode" exists-action="override">
      <value>@(context.Response.StatusCode.ToString())</value>
    </set-header>
    <set-header name="X-Diag-CorrelationId" exists-action="override">
      <value>@(context.RequestId.ToString())</value>
    </set-header>
    <base />
  </on-error>
</policies>
```

Caveat, exact from the doc: *"The `on-error` section isn't present in policies by default."* And: *"If there's no `on-error` section, callers receive 400 or 500 HTTP response messages if an error condition occurs."* Note the `on-error` section must not change the status code unless you intend to — the headers above are additive only.

Also add, in the **inbound** section, an echo of the backend request identity so the Search-side correlation in §9 becomes possible:

```xml
<!-- inbound: stamp a correlation id the backend will echo back -->
<set-header name="x-ms-client-request-id" exists-action="skip">
  <value>@(context.RequestId.ToString())</value>
</set-header>
```

`exists-action="skip"` preserves any caller-supplied value. Because the connector does not set one, APIM's own `context.RequestId` becomes the shared key between the APIM log and the Azure AI Search response.

### 8.4 KQL — is the 403 correlated with caller IP? (tests hypotheses #1 and #3 directly)

```kusto
// ============================================================
// Q4 — Success vs failure by caller IP. If specific IPs are 100% failing
//      while others are 100% succeeding, it is an allow-list gap.
// ============================================================
ApiManagementGatewayLogs
| where TimeGenerated > ago(7d)
| where ApiId has "search" or BackendUrl has "search.windows.net"
| summarize
      Total      = count(),
      Forbidden  = countif(ResponseCode == 403),
      Success    = countif(ResponseCode between (200 .. 299))
  by CallerIpAddress
| extend ForbiddenPct = round(100.0 * Forbidden / Total, 1)
| where Total > 5
| order by ForbiddenPct desc, Total desc
// Bimodal output (a set of IPs at ~100% and a set at ~0%) == allow-list gap.
// Uniform output (every IP failing at a similar low rate) == time-window effect
//   (quota) or content-dependent effect (WAF), NOT an IP allow-list problem.
```

```kusto
// ============================================================
// Q5 — Temporal shape. Quota trips look like sawtooth resets; allow-list gaps look flat.
// ============================================================
ApiManagementGatewayLogs
| where TimeGenerated > ago(7d)
| where ApiId has "search" or BackendUrl has "search.windows.net"
| summarize Total = count(), Forbidden = countif(ResponseCode == 403) by bin(TimeGenerated, 5m)
| extend ForbiddenPct = round(100.0 * Forbidden / Total, 1)
| render timechart
// Sawtooth aligned to a renewal-period boundary  -> quota (#2)
// Flat constant percentage                       -> IP allow-list gap (#1/#3) or per-index RBAC (#4)
// Bursts aligned to token lifetime (e.g. ~60 min) -> validate-jwt TokenExpired (#7)
```

### 8.5 KQL — Azure AI Search side, and the connector side

Azure AI Search resource logs land in `AzureDiagnostics` (per the [monitoring data reference](https://learn.microsoft.com/en-us/azure/search/monitor-azure-cognitive-search-data-reference)), with `OperationName` values including `Query.Search`, `ResultSignature` = HTTP status, and properties `IndexName_s`, `Query_s`, `Description_s`, `Documents_d`.

```kusto
// ============================================================
// Q6 — Did the search service itself see and reject these requests?
//      Empty result for 403 == the search service never saw them (APIM or firewall rejected first).
// ============================================================
AzureDiagnostics
| where TimeGenerated > ago(7d)
| where ResourceProvider == "MICROSOFT.SEARCH"
| where Category == "OperationLogs"
| where OperationName == "Query.Search"
| summarize Count = count(), MedianMs = percentile(DurationMs, 50)
    by ResultSignature, IndexName_s, bin(TimeGenerated, 1h)
| order by TimeGenerated asc, Count desc
```

```kusto
// ============================================================
// Q7 — Per-index skew: tests hypothesis #4 (per-index RBAC scoping)
// ============================================================
AzureDiagnostics
| where TimeGenerated > ago(7d)
| where ResourceProvider == "MICROSOFT.SEARCH" and OperationName == "Query.Search"
| summarize Total = count(), Forbidden = countif(ResultSignature == "403") by IndexName_s
| extend ForbiddenPct = round(100.0 * Forbidden / Total, 1)
| order by ForbiddenPct desc
// If 1-2 of the 7 indexes carry ~all the 403s, it is per-index authorization, not networking.
```

```kusto
// ============================================================
// Q8 — Connector side (App Insights). Rate vs the documented 200-calls/60s connector limit.
//      Tests hypothesis #10.
// ============================================================
dependencies
| where timestamp > ago(7d)
| where type == "Connector" and target == "shared_azureaisearch/SemanticHybridSearch"
| summarize
      Calls      = count(),
      Forbidden  = countif(resultCode == "403"),
      P50Ms      = percentile(duration, 50),
      P95Ms      = percentile(duration, 95)
  by bin(timestamp, 1m)
| extend ApproachingConnectorLimit = Calls > 160   // 80% of the documented 200/60s
| where Forbidden > 0 or ApproachingConnectorLimit
| order by timestamp asc
```

```kusto
// ============================================================
// Q9 — Are the 403s concentrated on specific makers / design-mode traffic?
//      Tests hypothesis #5.
// ============================================================
dependencies
| where timestamp > ago(7d)
| where type == "Connector" and target == "shared_azureaisearch/SemanticHybridSearch"
| extend DesignMode = tostring(customDimensions["DesignMode"]),
         ChannelId  = tostring(customDimensions["channelId"])
| summarize Total = count(), Forbidden = countif(resultCode == "403")
    by user_Id, DesignMode, ChannelId, cloud_RoleInstance
| extend ForbiddenPct = round(100.0 * Forbidden / Total, 1)
| order by Forbidden desc
// If 100% of 403s are DesignMode==True / pva-studio and the published channel is clean,
// this is a maker-connection / maker-identity problem, not an infrastructure problem.
```

```kusto
// ============================================================
// Q10 — Cross-service time-window join (see §9 for why this is time-based, not ID-based)
// ============================================================
let window = 2s;
let apim =
    ApiManagementGatewayLogs
    | where TimeGenerated > ago(1d) and ResponseCode == 403
    | project ApimTime = TimeGenerated, CorrelationId, CallerIpAddress, Url,
              BackendResponseCode, LastErrorSource, LastErrorReason, TotalTime, BackendTime;
let search =
    AzureDiagnostics
    | where TimeGenerated > ago(1d)
    | where ResourceProvider == "MICROSOFT.SEARCH" and OperationName == "Query.Search"
    | project SearchTime = TimeGenerated, ResultSignature, IndexName_s, DurationMs, Query_s;
apim
| extend joinKey = 1
| join kind=inner (search | extend joinKey = 1) on joinKey
| where abs(datetime_diff('millisecond', SearchTime, ApimTime)) <= 2000
| project ApimTime, SearchTime, CorrelationId, CallerIpAddress, BackendResponseCode,
          LastErrorSource, LastErrorReason, ResultSignature, IndexName_s, DurationMs, TotalTime
| order by ApimTime asc
// Heavy for large windows. Narrow the time range before running.
```

---

## 9. Correlation-ID walkthrough: Copilot Studio → APIM → Azure AI Search

### 9.1 What identifiers exist at each hop

| Hop | Identifier | Where it appears | Notes |
| --- | --- | --- | --- |
| Copilot Studio agent | `operation_Id`, `spanId` (`158837a6e0cc84f5`), `session_Id`, `user_Id`, `conversationId` (`2131a873-…`) | App Insights `dependencies` / `requests` / `traces` | Copilot Studio's own OpenTelemetry trace context |
| Copilot Studio → connector | *(none propagated)* | — | **The managed connector does not expose a parameter to set `x-ms-client-request-id`, and Copilot Studio's trace context is not forwarded into the connector's outbound HTTP request.** This is the correlation break. |
| Connector → APIM | `CallerIpAddress`, `Ocp-Apim-Subscription-Key` (if used), `Url`, `Method` | `ApiManagementGatewayLogs` | The only "identity" the connector supplies is its egress IP and subscription key |
| APIM (internal) | `CorrelationId`, and `context.RequestId` | `ApiManagementGatewayLogs.CorrelationId`; response header (commonly surfaced as `x-ms-request-id` / `Request-Id`) | **APIM generates this; it does not inherit from Copilot Studio** |
| APIM → Search | `x-ms-client-request-id` (request) | `ApiManagementGatewayLogs.BackendRequestHeaders` (requires headers logging enabled) | Documented on [Documents - Search Post](https://learn.microsoft.com/en-us/rest/api/searchservice/documents/search-post): "An opaque, globally-unique, client-generated string identifier for the request." **Only present if APIM stamps it** (see §8.3) |
| Search → APIM | `request-id` response header | `ApiManagementGatewayLogs.BackendResponseHeaders` | Azure AI Search echoes/returns a service-side request id |
| Search resource logs | `OperationName`, `ResultSignature`, `DurationMs`, `IndexName_s`, `Query_s` | `AzureDiagnostics` (`ResourceProvider == "MICROSOFT.SEARCH"`) | **The documented Azure AI Search resource-log schema exposes no correlation-id / request-id column.** See the limitation below. |

### 9.2 The two correlation breaks — state these plainly to the customer

1. **Copilot Studio → APIM is not ID-correlatable out of the box.** The connector is a black box that does not propagate Copilot Studio's trace context. You correlate by **timestamp + caller IP + URL/operation**.
2. **APIM → Azure AI Search resource logs is not ID-correlatable out of the box either.** Azure AI Search's `AzureDiagnostics` schema (per the [monitoring data reference](https://learn.microsoft.com/en-us/azure/search/monitor-azure-cognitive-search-data-reference)) documents only `TimeGenerated`, `Resource`, `Category`, `OperationName`, `OperationVersion`, `ResultType`, `ResultSignature`, `DurationMs`, and `Properties` (`Description_s`, `Documents_d`, `IndexName_s`, `Query_s`). There is no documented request-id field. You correlate by **timestamp + index name + duration**.

This is the technical substance behind the meeting note "connector behaves as a black box, limiting visibility into request payloads and intermediate failures" (assets/meetingNotes.md).

### 9.3 Working walkthrough for a single failing request

Given the sample failure at `2026-09-18T19:09:27.2278467Z`, duration 2566 ms:

1. **Anchor in Copilot Studio telemetry.** Record `timestamp`, `duration`, `spanId`, `conversationId`, `user_Id`. The Copilot Studio timestamp marks the **end** of the connector call in most SDK emissions — so the upstream APIM request started roughly `timestamp - duration` ≈ `19:09:24.66`. Search a window of `[timestamp - duration - 2s, timestamp + 2s]`.
2. **Find the APIM row.**

   ```kusto
   ApiManagementGatewayLogs
   | where TimeGenerated between (datetime(2026-09-18T19:09:22Z) .. datetime(2026-09-18T19:09:30Z))
   | where ResponseCode == 403
   | project TimeGenerated, CorrelationId, CallerIpAddress, Method, Url,
             ResponseCode, BackendResponseCode, BackendUrl,
             LastErrorSource, LastErrorReason, LastErrorMessage,
             TotalTime, BackendTime, ApimSubscriptionId, ApiId, OperationId,
             BackendRequestHeaders, BackendResponseHeaders
   ```

   Disambiguate by `Url` (should contain the index name) and by `TotalTime` ≈ 2566 ms minus connector overhead.
3. **Read the verdict directly.**
   - `BackendResponseCode` empty/0 **and** `LastErrorSource` populated → APIM rejected it. `LastErrorSource` + `LastErrorReason` name the exact policy. Done.
   - `BackendResponseCode == 403` → Azure AI Search rejected it. Continue to step 4.
4. **Pull the Search-side request id** out of `BackendResponseHeaders["request-id"]` (requires headers logging enabled per §8.1). Also read `BackendResponseBody` if body logging is on — Azure AI Search returns an `ErrorResponse` with `error.code` / `error.message`, which distinguishes an RBAC denial from a firewall denial in plain text.
5. **Confirm in Search resource logs** by time + index:

   ```kusto
   AzureDiagnostics
   | where TimeGenerated between (datetime(2026-09-18T19:09:22Z) .. datetime(2026-09-18T19:09:30Z))
   | where ResourceProvider == "MICROSOFT.SEARCH" and OperationName == "Query.Search"
   | project TimeGenerated, ResultType, ResultSignature, DurationMs, IndexName_s, Query_s, Description_s
   ```

   **If nothing appears here for the failing request but APIM says `BackendResponseCode == 403`, the search service's IP firewall rejected it at the network edge before the data-plane operation was logged.** That is a decisive result for hypothesis #1.
6. **After applying the §8.3 policy**, steps 4–5 collapse: `x-ms-client-request-id` stamped inbound by APIM becomes a single key visible in `BackendRequestHeaders` and echoed by Search, and `X-Diag-*` headers appear in the connector's own error payload inside Copilot Studio — making the black box translucent without a Log Analytics query at all.

---

## 10. Community / known-issue evidence (Q5)

Searched Microsoft Learn Q&A, Power Platform Community, GitHub, and general web. Findings are thin and mostly about *configuration-time* 403s, not steady-state intermittent ones.

| Source | Reported symptom | Reported cause / outcome |
| --- | --- | --- |
| [Persistent 403 Forbidden when Copilot Studio Tries to Discover Azure AI Search Indexes (Service Principal Auth)](https://learn.microsoft.com/en-us/answers/questions/5449057/persistent-403-forbidden-when-copilot-studio-tries) | 403 on internal call `GET /api/scopes/user/azureAISearch/discoverIndexes`. Service principal shows **"Connected"**; `Search Index Data Reader`, then `Search Index Data Contributor` and `Contributor` assigned at service scope; Search firewall set to **"All networks"** | **Unresolved in public.** Moderators attributed it to "various backend issues of Copilot" and routed to paid support. **No published root cause.** Important negative evidence: RBAC at service scope + open firewall did **not** fix it, which weakens a naive "just add the role" conclusion |
| [Error when connect Azure AI Search to Copilot Studio](https://learn.microsoft.com/en-us/answers/questions/5789331/error-when-connect-azure-ai-search-to-copilot-stud) | "Access denied" in Copilot Studio while the **same Search API call succeeds in Postman** | Microsoft staff answer: the identity used by Copilot Studio differs from the identity used in Postman; verify the auth method matches, assign the role in IAM, re-check endpoint/key/client ID, and **remove and re-add the connection**. This is direct support for hypotheses #5 and #6 |
| [Solved: Can't get Azure AI Search to work as a knowledge source in Copilot Studio](https://community.powerplatform.com/forums/thread/details/?threadid=750841fa-383a-f011-b4cc-7c1e520dbb77) | Native Azure AI Search knowledge source stopped working; tutorials a few months old no longer match behavior | Community thread reporting **behavioral drift in the native integration over time** — relevant because the connector is a first-party component that changes without customer deployment |
| [nestordiaz24/azure-ai-search-proxy-for-copilot-studio](https://github.com/nestordiaz24/azure-ai-search-proxy-for-copilot-studio) | Copilot Studio cannot reach Azure AI Search over a Private Endpoint | Workaround pattern: a Function App with a public HTTPS endpoint (function-key secured) inside the VNet forwards to the network-locked search service **using its managed identity**. Confirms the community consensus that **connector egress cannot reach a network-restricted search service directly** |
| [Azure-Samples/Copilot-Studio-with-Azure-AI-Search](https://github.com/Azure-Samples/Copilot-Studio-with-Azure-AI-Search) | — | Microsoft sample for Copilot Studio + Azure AI Search "through a private virtual network infrastructure", focused on network isolation. Same architectural conclusion: a VNet-resident relay is the supported pattern for locked-down search |
| [Integrating Azure AI Search with Copilot Studio Using a Custom Connector](https://cognicoast.com/blogs/copilot_studio_azure_ai_search_custom_connector.html) | — | Third-party post advocating a custom connector "without relying on the native connector restrictions" — evidence that practitioners hit limits on the built-in connector |
| [Copilot Studio: Azure AI Search Complete Setup Guide](https://www.matthewdevaney.com/copilot-studio-azure-ai-search-complete-setup-guide/) | — | Reference walkthrough; useful for comparing a known-good configuration against the customer's |

**Honest assessment of Q5:** there is **no published, confirmed root cause** for intermittent (as opposed to persistent) 403s on `shared_azureaisearch/SemanticHybridSearch`. The public corpus covers persistent configuration-time 403s. The recurring theme across every source is **identity mismatch between the connection and the Search resource**, plus the near-universal use of a VNet-resident relay when network restrictions exist. Do not present any community item to the customer as a confirmed root cause.

---

## 11. Recommended action sequence

**Single highest-value first diagnostic** — enable APIM resource logs to `ApiManagementGatewayLogs` (100 % sampling, verbosity Information, headers on for the search API) and run **Q1** in §8.2. It answers the one question that bisects the entire hypothesis space — *did APIM reject it, or did the backend?* — and collapses 13 hypotheses into roughly 4 in a single query. Everything else is downstream of that answer.

Then, in order:

1. Run **Q1**. Branch on `Verdict`.
2. If **APIM POLICY**: run **Q2** (quota + `Retry-After`) and **Q4** (caller-IP bimodality). One of them will name the policy.
3. If **BACKEND**: run **Q6** first. *No 403 rows in the Search logs* → the Search IP firewall rejected it pre-logging → hypothesis #1. *403 rows present* → run **Q7** for per-index skew (#4), then inspect `authOptions` / `disableLocalAuth` (#6) and Entra sign-in logs (#8).
4. Regardless of branch, run **Q9**. If 100 % of the 613 failures are `DesignMode == True`, the production channel may be entirely healthy and the urgency profile changes completely. **Establish this early — it is a 30-second query and it can reframe the whole engagement.**
5. Deploy the §8.3 `on-error` + `x-ms-client-request-id` policy so future failures are self-describing.
6. Independently of the 403 work, address the 206s: they are a **semantic ranker concurrency** problem (§7.4), addressed by search units and by reducing the 7-index fan-out. Do not conflate the two issues.

Longer-term architecture options, once the root cause is known:

- **Option A — keep public Search, fix the allow-list properly.** Automate the allow-list from the Service Tag Discovery API for **every** `AzureConnectors.<Region>` and `PowerPlatformPlex.<Region>` in the Power Platform geo, refreshed on a schedule (docs recommend ≤ 90 days). Fragile but no new components.
- **Option B — single ingress.** Lock the Search IP firewall to **only APIM's outbound IPs**, and allow-list the connector service tags at APIM instead. One allow-list to maintain, one enforcement point, one log table. Strongly preferred.
- **Option C — private endpoint + VNet relay.** Disable public network access on Search, private-endpoint it, and let APIM (VNet-integrated) or a Function App relay with managed identity. This is the pattern both the Microsoft sample repo and the community proxy converge on. Highest isolation, highest complexity.
- **Reduce fan-out.** Querying all 7 indexes on every turn — regardless of relevance (assets/meetingNotes.md, assets/additionalInfo.md) — multiplies exposure to *every* rate/quota/concurrency limit by 7×. Index routing/selection logic is a force multiplier on every fix above.

---

## 12. Open questions / unproven items

1. **The status code returned when the connector's documented 200-calls-per-60-seconds limit is exceeded is not published.** The connector reference states the limit but not the code. Convention says 429. Unverified.
2. **No published root cause exists for intermittent `SemanticHybridSearch` 403s.** The public Q&A case with an identical error shape was closed without resolution. This is a genuine evidence gap, not a search failure.
3. **The `ip-filter` policy reference page does not print the numeric status code.** The behavior is documented as deny / "Access denied" via `CallerIpNotAllowed`; 403 is the conventional surfaced code but is inferred, not quoted, from that page.
4. **Whether the `duration: 2566 ms` reflects the APIM round trip or includes connector-runtime overhead is unknown**, so the "backend-originated" inference in §2 is directional, not conclusive. Q1's `TotalTime` / `BackendTime` settles it empirically.
5. **APIM tier and gateway type are unknown.** Consumption tier does not support resource logs at all, which would invalidate the entire §8 diagnostic plan and require Application Insights integration instead.
6. **Whether Azure AI Search returns a `request-id` response header on a 403** (as opposed to on success) is not documented; the §9 correlation may lose its key on exactly the requests that matter most.

## 13. Clarifying questions for the customer

1. **Which connector authentication type is the connection using** — admin key, Microsoft Entra ID Integrated, or service principal? This alone eliminates 4 of the 13 hypotheses.
2. **How many `shared_azureaisearch` connection instances exist in the environment, and who owns each?** (Directly tests #5.)
3. **Is `publicNetworkAccess` on the search service set to `Enabled` or `Selected IP addresses`?** If the latter, what is the current `networkRuleSet.ipRules` list and when was it last updated?
4. **Can we see the full APIM policy XML** at global, product, API, and operation scope for the search API? Specifically: is there a `<quota>` / `<quota-by-key>`, an `<ip-filter>`, a `<validate-jwt>` with `failed-validation-httpcode`, and an `<on-error>` section?
5. **What APIM tier** (Consumption / Developer / Basic / Standard / Premium / v2) and is a self-hosted gateway, Front Door, WAF, or Application Gateway in the path?
6. **Do the 403s occur on the published agent, or only in the Copilot Studio test canvas?** The `DesignMode: True` / `channelId: pva-studio` attributes suggest test-canvas only, which would materially change both severity and root cause.
7. **What is the Power Platform environment's geo, and what Azure region hosts APIM and the search service?**
8. **What was the exact search service creation date?** It determines whether the Basic tier storage ceiling was 2 GB or 15 GB and whether the index limit was 5 or 15.
9. **Did anything else change in the same maintenance window as the Basic → S1 scale** — firewall rules, admin key regeneration, APIM policy edits, role assignments? (§7.5.)
10. **Are Azure AI Search resource logs (`OperationLogs`) currently enabled and flowing to a Log Analytics workspace?** Without them, §8.5 and step 3 of §11 are not runnable.

---

## 14. Full reference list

Azure AI Search:

- [HTTP status codes - Azure AI Search](https://learn.microsoft.com/en-us/rest/api/searchservice/http-status-codes)
- [Service Limits for Tiers and SKUs - Azure AI Search](https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity)
- [Configure Network Access - Azure AI Search](https://learn.microsoft.com/en-us/azure/search/service-configure-firewall)
- [Connect Using Azure Roles - Azure AI Search](https://learn.microsoft.com/en-us/azure/search/search-security-rbac)
- [Monitoring Data Reference - Azure AI Search](https://learn.microsoft.com/en-us/azure/search/monitor-azure-cognitive-search-data-reference)
- [Documents - Search Post (REST)](https://learn.microsoft.com/en-us/rest/api/searchservice/documents/search-post)
- [Create a private endpoint for a secure connection](https://learn.microsoft.com/en-us/azure/search/service-create-private-endpoint)
- [Plan and manage capacity](https://learn.microsoft.com/en-us/azure/search/search-capacity-planning)

Power Platform / connectors:

- [Azure AI Search - Power Platform connector reference](https://learn.microsoft.com/en-us/connectors/azureaisearch/)
- [Managed connectors outbound IP addresses](https://learn.microsoft.com/en-us/connectors/common/outbound-ip-addresses)
- [Power Platform URLs and IP address ranges](https://learn.microsoft.com/en-us/power-platform/admin/online-requirements)
- [Virtual network service tags](https://learn.microsoft.com/en-us/azure/virtual-network/service-tags-overview)

Azure API Management:

- [Azure API Management policy reference (index)](https://learn.microsoft.com/en-us/azure/api-management/api-management-policies)
- [quota policy](https://learn.microsoft.com/en-us/azure/api-management/quota-policy)
- [quota-by-key policy](https://learn.microsoft.com/en-us/azure/api-management/quota-by-key-policy)
- [rate-limit policy](https://learn.microsoft.com/en-us/azure/api-management/rate-limit-policy)
- [ip-filter policy](https://learn.microsoft.com/en-us/azure/api-management/ip-filter-policy)
- [validate-jwt policy](https://learn.microsoft.com/en-us/azure/api-management/validate-jwt-policy)
- [check-header policy](https://learn.microsoft.com/en-us/azure/api-management/check-header-policy)
- [Error handling in Azure API Management policies](https://learn.microsoft.com/en-us/azure/api-management/api-management-error-handling-policies)
- [Subscriptions in Azure API Management](https://learn.microsoft.com/en-us/azure/api-management/api-management-subscriptions)
- [Tutorial - Monitor APIs in Azure API Management](https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-use-azure-monitor)
- [Advanced request throttling with Azure API Management](https://learn.microsoft.com/en-us/azure/api-management/api-management-sample-flexible-throttling)

Azure Monitor:

- [ApiManagementGatewayLogs table reference](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/apimanagementgatewaylogs)
- [AzureDiagnostics table reference](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/azurediagnostics)

Community / third-party (unverified, do not present as authoritative):

- [Persistent 403 Forbidden when Copilot Studio Tries to Discover Azure AI Search Indexes](https://learn.microsoft.com/en-us/answers/questions/5449057/persistent-403-forbidden-when-copilot-studio-tries)
- [Error when connect Azure AI Search to Copilot Studio](https://learn.microsoft.com/en-us/answers/questions/5789331/error-when-connect-azure-ai-search-to-copilot-stud)
- [Can't get Azure AI Search to work as a knowledge source in Copilot Studio](https://community.powerplatform.com/forums/thread/details/?threadid=750841fa-383a-f011-b4cc-7c1e520dbb77)
- [nestordiaz24/azure-ai-search-proxy-for-copilot-studio](https://github.com/nestordiaz24/azure-ai-search-proxy-for-copilot-studio)
- [Azure-Samples/Copilot-Studio-with-Azure-AI-Search](https://github.com/Azure-Samples/Copilot-Studio-with-Azure-AI-Search)
- [Integrating Azure AI Search with Copilot Studio Using a Custom Connector](https://cognicoast.com/blogs/copilot_studio_azure_ai_search_custom_connector.html)
- [Copilot Studio: Azure AI Search Complete Setup Guide](https://www.matthewdevaney.com/copilot-studio-azure-ai-search-complete-setup-guide/)

Workspace inputs consulted: assets/meetingNotes.md, assets/additionalInfo.md, assets/usefulScreenshots.md
