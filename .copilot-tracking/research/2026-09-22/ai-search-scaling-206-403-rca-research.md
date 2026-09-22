<!-- markdownlint-disable-file -->
# Task Research: Azure AI Search Scaling RCA — 206 Partial Responses, 403 Connector Errors, Copilot Studio Multi-Index Fan-Out

Customer (low-code + pro-code teams) runs a Copilot Studio agent with 7 Azure AI Search indexes as knowledge sources, fronted by API Management. They observe intermittent 206 partial semantic responses, empty agent answers, and 613 connector 403 errors. Moving the search service from Basic to S1 largely resolved the errors. This research establishes the RCA, out-of-box observability assets, workarounds, and the CSS escalation path.

## Headline Answer

**There are TWO independent problems. Do not conflate them.**

1. **The 206s are a documented semantic-ranker concurrency ceiling.** Azure AI Search enforces a per-tier, per-search-unit admission-control limit on the semantic ranker: Basic = 2 concurrent + 4 queued = **6 in flight per SU**; S1 = 3 concurrent + 6 queued = **9 in flight per SU**. The agent issues **7 simultaneous semantic queries per user turn** (one per index). On Basic at 1 SU the workload structurally exceeds capacity on a single turn with zero concurrent users. This is an **arity** problem, not a load problem — which is exactly why "~7-15 users/hour" looked far too small to explain it. Basic → S1 gave +50% semantic slots at identical SU count, and adding replicas multiplied SU. That is the mechanism.
2. **The 403s are NOT explained by the tier change.** Azure AI Search documents `403 Forbidden` as *"Returned when authorization fails"* — quota and low storage return **429**, semantic free-plan exhaustion returns **402**. No documented Search mechanism ties tier to 403. The most likely causes are an IP firewall allow-list that no longer covers Power Platform connector egress prefixes, or an APIM `quota` policy (the only APIM throttling policy that returns 403 rather than 429). The 403s stopping around the same time as the scale-up is most likely **coincidence with another change made in the same window**.

**The strategic fix is to reduce the fan-out, not to keep buying capacity.** Every limit in the path — semantic concurrency, connector throttling, APIM quota — is multiplied by 7 today.

## Task Implementation Requests

* Explain why 206 partial responses occur and why Basic → S1 (and added replicas) largely resolved them — with a defensible RCA, not just "more capacity".
* Explain the 613 × HTTP 403 on the `shared_azureaisearch/SemanticHybridSearch` connector through APIM.
* Recommend out-of-box observability: Azure Monitor workbooks, Azure AI Search diagnostic settings, App Insights/Log Analytics KQL queries the customer can paste in.
* Identify whether this is a known/common Copilot Studio multi-knowledge-source pattern with documented answers.
* Provide the decision criteria and content package for opening a Microsoft CSS support ticket.
* Provide interim workarounds while RCA completes.

## Scope and Success Criteria

* Scope: Azure AI Search capacity/semantic ranker behavior, Copilot Studio knowledge-source fan-out, APIM-to-Search auth/network path, Azure Monitor + App Insights observability assets, CSS escalation.
* Out of scope: rewriting the customer's indexing pipeline (ADF → Function Apps), embedding model selection, index schema redesign beyond consolidation recommendations.
* Assumptions:
  * Search service was Basic, now S1 (search units = replicas × partitions).
  * 7 indexes, each returning top 3 docs, queried on every user turn.
  * Semantic ranker is enabled (response contains `@search.semanticPartialResponseReason`).
  * APIM sits between Copilot Studio connector and Azure AI Search.
  * Observed load: ~7–15 users/hour today; growth expected.
* Success Criteria:
  * Documented mechanism linking tier/replica count to 206 `Transient` partial responses. **MET.**
  * Documented plausible causes for connector 403 with a discriminating test per cause. **MET.**
  * Copy-paste KQL and workbook guidance grounded in current Microsoft Learn docs. **MET.**
  * Clear go/no-go criteria for a CSS ticket plus the exact evidence to attach. **MET.**

## Evidence Baseline (from workspace assets)

Source: assets/meetingNotes.md

* 206 responses = "partial success"; retrieval succeeds but ranking/retrieval components fail (7:11).
* Empty responses despite index containing data (8:55); inconsistent across indexes (14:24).
* Increasing replicas reduced errors and improved stability (10:03).
* Every user query fans out to all 7 indexes regardless of relevance; each returns top 3 (18:11, 34:37).
* No routing/selection logic across knowledge sources (53:05).
* APIM sits between Copilot and Search (55:29); connector is a black box (28:54).
* App Insights shared across Copilot Studio, Search, Function Apps (43:36).
* Ingestion: ADF triggers Function Apps, custom embedding prep, direct document upload, daily schedule + weekly cleanup, upsert semantics (19:11, 19:36, 20:44, 25:02).
* Load today ~7–15 users/hour, growth expected (17:28, 32:26).

Source: assets/usefulScreenshots.md

* 613 × HTTP 403, sample dependency record:
  * `name: "Azure AI Search"`, `type: "Connector"`, `target: "shared_azureaisearch/SemanticHybridSearch"`
  * `serviceName: "Microsoft Copilot Studio"`, `serviceInstance: "Agent Plateforme Numérique"`
  * `attributes.DesignMode: "True"`, `channelId: "pva-studio"`
  * `duration: 2566` ms, `timestamp: 2026-09-18T19:09:27Z`
* Partial-response fields observed: `"@search.semanticPartialResponseReason": "Transient"`, `"@search.semanticPartialResponseType": "BaseResults"`.
* Customer-referenced docs: search-limits-quotas-capacity#throttling-limits, rest/api/searchservice/http-status-codes.

Two details from that record carry disproportionate diagnostic weight:

* **`duration: 2566` ms on a 403.** An APIM inbound policy short-circuit (subscription key, `ip-filter`) rejects in tens of milliseconds. 2.5 seconds points to a request that travelled to a backend and was rejected there.
* **`DesignMode: "True"` and `channelId: "pva-studio"`.** All 613 failures came from the **authoring test canvas**, not the published channel. Production traffic may be entirely healthy. This must be checked before any escalation.

## Research Executed

All investigation was delegated to `Researcher Subagent`. Detailed findings:

* .copilot-tracking/research/subagents/2026-09-22/206-partial-response-tier-capacity-research.md (1200 lines) — 206 semantics, semantic ranker limits, tier comparison, capacity planning, throttling paths.
* .copilot-tracking/research/subagents/2026-09-22/403-connector-apim-research.md (833 lines) — ranked 403 hypotheses, APIM attribution, correlation IDs.
* .copilot-tracking/research/subagents/2026-09-22/observability-workbooks-kql-research.md (1953 lines) — 43 KQL queries, metrics/logs reference, workbook gallery templates, 20 alert rules.
* .copilot-tracking/research/subagents/2026-09-22/copilot-studio-fanout-and-css-escalation-research.md (1381 lines) — fan-out mechanics, architecture alternatives, CSS decision tree and ticket drafts.

## Key Discoveries

### D1. The semantic ranker has a hard, published, tier-indexed concurrency limit

Verbatim from [Service limits — Throttling limits](https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity):

> Semantic ranker uses a **queuing system** to manage concurrent requests... **When the limit of concurrent requests is reached, the system places additional requests in a queue. If the queue is full, the system rejects further requests and they must be retried.**
>
> | Resource | Basic | S1 | S2 | S3 |
> | --- | --- | --- | --- | --- |
> | Maximum concurrent requests (per search unit) | **2** | **3** | 4 | 4 |
> | Maximum request queue size (per search unit) | **4** | **6** | 8 | 8 |

Search units = replicas × partitions. In-flight semantic capacity = `SU × (concurrent + queue)`.

| Configuration | SU | In flight before rejection |
| --- | --- | --- |
| Basic, 1 replica | 1 | **6** ← agent needs 7 |
| Basic, 2 replicas | 2 | 12 |
| Basic, 3 replicas | 3 | 18 |
| S1, 1 replica | 1 | **9** |
| S1, 3 replicas | 3 | **27** |

This explains every reported symptom: the 206s, the randomness across indexes (7 requests racing one shared queue — whichever arrives after saturation degrades), why replicas helped a lot (the limit is per search unit), and why Basic → S1 largely fixed it.

### D2. Microsoft documents 206 as the semantic-capacity signal — and it is not 429 or 503

Verbatim from [Add semantic ranking — Expected workloads](https://learn.microsoft.com/en-us/azure/search/semantic-how-to-query-request):

> **For semantic ranking, you should expect a search service to support up to 10 concurrent queries per replica.**
>
> The service throttles semantic ranking requests if volumes are too high. An error message that includes these phrases indicate the service is at capacity for semantic ranking: `Operation returned an invalid status 'Partial Content'`, `@search.semanticPartialResponseReason`, `CapacityOverloaded`
>
> If you anticipate consistent throughput requirements near, at, or higher than this level, **please file a support ticket so that we can provision for your workload.**

That last sentence converts "we would like an RCA" into a **documented, in-scope support scenario**. This is the single strongest justification for the CSS ticket.

> ⚠️ **Documentation conflict.** This page says *10 concurrent per **replica***; the limits table says *2/3/4 per **search unit*** plus queue. Different magnitude, different unit. They cannot both be literal. Raise this as question #1 in the Azure ticket.

### D3. The exact enum pair the customer observed means "L1 results only, no enrichment"

From the [Search POST REST reference](https://learn.microsoft.com/en-us/rest/api/searchservice/documents/search-post):

* `@search.semanticPartialResponseReason: "transient"` — *"At least one step of the semantic process failed."*
* `@search.semanticPartialResponseType: "baseResults"` — *"Results without any semantic enrichment or reranking."*

So the caller receives BM25/RRF documents with **no `@search.rerankerScore`, no `@search.captions`, no `@search.answers`**. Copilot Studio's grounding surface goes empty → **"empty answer despite data in the index."** That symptom is fully explained.

### D4. Why zero 429s is expected, and is not evidence against resource constraint

Three architecturally separate paths:

| Path | Surfacing | Counted by a metric? |
| --- | --- | --- |
| Search host throttle (CPU/mem/disk) | **503** | Yes — `ThrottledSearchQueriesPercentage` |
| Indexing partial failure | **207** | Partially |
| **Semantic ranker queue overflow** | **206 + body annotation** | **No — counted nowhere** |

206 is a 2xx. APIM passes it through, dashboards bucket it as success, and retry policies keyed on 429/5xx never fire. The customer's monitoring was structurally blind to this failure mode.

### D5. `semanticErrorHandling` default is `fail` — something is forcing `partial`

The REST reference documents the default as *"fail completely (default / current behavior)"*. Yet the customer is receiving 206 partials, which only happens under `partial`. The [Copilot Studio Azure AI Search connector](https://learn.microsoft.com/en-us/connectors/azureaisearch/) **exposes neither `semanticErrorHandling` nor `semanticMaxWaitInMilliseconds`** — so the customer cannot tune them. Either the connector sets `partial` internally, or APIM is injecting it. Resolving this requires an APIM outbound body trace. `semanticMaxWaitInMilliseconds` has a documented **minimum of 700 ms** and **no published default**.

### D6. Azure AI Search 403 means authorization — not quota, not storage

Verbatim from [HTTP status codes](https://learn.microsoft.com/en-us/rest/api/searchservice/http-status-codes):

> `403 Forbidden` — **Returned when authorization fails.**
>
> `429 Too Many Requests` — "...If you get this error code on an active index, it usually means that you're **running low on storage**..."

Semantic free-plan exhaustion returns **402**. **Therefore the Basic → S1 storage theory is dead as a 403 explanation.** Ranked hypotheses:

| # | Cause | Likelihood | Discriminating test |
| --- | --- | --- | --- |
| 1 | **Search IP firewall allow-list misses some connector egress prefixes.** Docs: *"requests from IP addresses outside the allowed list are rejected with a 403 Forbidden response."* Connector egress spans every `AzureConnectors.<Region>` service tag in the geo and **changes** — Microsoft advises refreshing at least every 90 days. Power Platform is **not** on Search's trusted-services list. Intrinsically intermittent. | **High** | Check `publicNetworkAccess` and `networkRuleSet.ipRules`; compare to current service tags; check last edit date |
| 2 | **APIM `quota` / `quota-by-key` exceeded.** The *only* APIM throttling policy returning 403: *"When the quota is exceeded, the caller receives a 403 Forbidden."* `rate-limit` returns 429. A 7-call burst per turn is exactly the shape that trips it. | **High** | Inspect policy XML at all four scopes for `<quota>` |
| 3 | **APIM `ip-filter`** — `CallerIpNotAllowed` / `CallerIpBlocked` | **High** | Policy XML inspection |
| 4 | **Per-index RBAC scoping** — role assigned on 6 of 7 indexes. Looks intermittent in aggregate, deterministic per index. | **Med-High** | Group the 403s by index name — cheapest to disprove |
| 5 | **Multiple connection instances.** The connector's key and OAuth modes are documented **"not shareable"**; each maker gets their own connection. Fits `DesignMode: True` + `pva-studio` precisely. | **Med-High** | Audit environment connections |
| … | APIM subscription key | **Low — ruled out** | Docs: missing/invalid key → **401**, not 403 |
| … | Search storage/index quota | **Very low — contradicted** | See above |

**Highest-value first diagnostic:** enable APIM `GatewayLogs` and run the attribution query (Q8c below). It branches on `BackendResponseCode` and answers the one question that bisects everything — *did APIM reject it, or did the backend?* — collapsing 13 hypotheses to about 4. A close second, requiring no setup: check whether 100% of the 403s carry `DesignMode == True`.

### D7. Copilot Studio does NOT route among ≤25 knowledge sources by description

The customer's belief is **correct**, and now has a citation. From [knowledge-copilot-studio](https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-copilot-studio):

> Generative orchestration filters knowledge sources by using an internal GPT model **when there are more than 25 different knowledge sources**.

With 7 sources that filter never engages — all 7 are queried every turn.

**But one correction matters.** They said "it's not possible while we keep a single agent with knowledge sources." That is accurate *as long as they remain knowledge sources*. It becomes possible immediately if the same retrieval is re-expressed as **Tools** or **child/connected agents** — both of which the orchestrator explicitly selects by name and description ([advanced-generative-actions](https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-generative-actions)). **That is the architectural unlock.**

Microsoft also publishes the consolidation advice directly: *"Reduce the number of knowledge sources (indexes); consolidating content can lower fan-out and token volume."*

### D8. A second, independent cause of "empty answers" worth ruling out

If **"Allow ungrounded responses" is off**, Copilot Studio suppresses answers it cannot cite. Some "empty answers despite data in the index" may be this documented behavior rather than capacity. Rule it out before CSS chases the wrong signal.

### D9. The semantic ranker free plan is plausibly exhausted

Pricing: *"First 1k requests free per month"*. Docs: *"After the free allowance is consumed, semantic ranker requests return a billing error."* At 7 indexes × ~10 users/hr × 8h × 22d ≈ **8,600–37,000 requests/month**, a 1,000-request free allowance is gone in 1–3 days. **Verify `properties.semanticSearch == "standard"` before any further capacity work.** Use PATCH, never PUT.

### D10. `sessionId` can silently defeat replica scale-out

From the REST reference: *"As long as the same sessionId is used, a best-effort attempt will be made to target the same replica set... reusing the same sessionID values repeatedly can interfere with the load balancing."* The connector exposes `SessionId`. A constant value would pin all traffic to one replica set — a strong candidate for why S1 fixed it only **"in large part."**

### D11. Out-of-box observability assets — what exists and what does not

| Asset | Status | URL |
| --- | --- | --- |
| **Copilot Studio Dashboard** workbook | **Exists, importable** | https://github.com/microsoft/Application-Insights-Workbooks/tree/master/Workbooks/Copilot%20Studio |
| **APIM Analytics** workbook | **Exists, importable** | https://github.com/microsoft/Application-Insights-Workbooks/tree/master/Workbooks/Azure%20API%20Management/Analytics |
| **Power Platform KQL pack** | **Exists** | https://github.com/microsoft/AzureMonitorCommunity/tree/master/Azure%20Services/Power%20Platform |
| App Insights **"Agents (preview)"** blades | Exists, portal-only | Azure portal |
| **Azure AI Search workbook template** | **Does not exist** — confirmed absent from both Microsoft gallery repos | — |
| Dedicated Search log table | **Does not exist** — Search logs land in `AzureDiagnostics` | — |

**Critical schema limitation:** `@search.semanticPartialResponseReason` is **NOT** in the Azure AI Search resource-log schema (documented `Properties` are only `Description_s`, `Documents_d`, `IndexName_s`, `Query_s`). The reason string exists **only in the response body**. The one place to capture it is **APIM response-body logging**. This is the single strongest argument for keeping APIM in the path.

## Technical Scenarios

### Scenario 1 — Reduce per-turn fan-out (SELECTED as the strategic fix)

Every limit in this architecture is multiplied by 7. Scaling capacity treats the symptom; reducing fan-out treats the cause. At 10 concurrent turns, the 7-index design needs roughly **24 search units**; a consolidated design needs about **4** — a **6× reduction in required SU**.

**Preferred approach: consolidate 7 indexes into 1 with a filterable `businessUnit` field.**

```jsonc
// Index field addition
{ "name": "group_ids", "type": "Collection(Edm.String)", "filterable": true, "retrievable": false }
```

```http
POST https://[service].search.windows.net/indexes/consolidated/docs/search?api-version=2026-04-01
{
  "search": "<user query>",
  "queryType": "semantic",
  "semanticConfiguration": "semantic-config",
  "filter": "group_ids/any(g:search.in(g, 'hr-group-id, finance-group-id'))"
}
```

Microsoft's note on why `search.in()` rather than `or`-chains: a disjunction of equality expressions *"slows down query response time by many seconds"*, whereas `search.in` yields *"subsecond"* response times. Reference: [Security filter pattern](https://learn.microsoft.com/en-us/azure/search/search-security-trimming-for-azure-search). Where the source system supports it, prefer the newer [built-in document-level access control](https://learn.microsoft.com/en-us/azure/search/search-document-level-access-overview).

```text
BEFORE                                  AFTER
user turn                               user turn
  ├── index_hr        (semantic)          └── consolidated_index (semantic)
  ├── index_finance   (semantic)                filter: businessUnit eq 'hr'
  ├── index_legal     (semantic)
  ├── index_ops       (semantic)          7 concurrent semantic reqs -> 1
  ├── index_it        (semantic)
  ├── index_sales     (semantic)
  └── index_support   (semantic)
  = 7 concurrent semantic requests
```

#### Considered Alternatives

| # | Option | Reduces fan-out? | Effort | Key risk |
| --- | --- | --- | --- | --- |
| **1** | **Consolidate to 1 index + filter** | **YES — 7 → 1** | High | Re-index/re-permission; loses per-index isolation |
| **2** | **Convert knowledge sources → Tools** | **YES — description-selected** | Medium | Description quality is the gate; loses built-in citation rendering |
| **3** | Child / connected agents per BU | YES per hop | Med-High | Added latency; no multi-level chaining |
| **4** | Explicit topic + conditional logic | YES, deterministic | Low-Med | Brittle to new intents; regresses generative UX |
| **5** | Agentic retrieval / Foundry IQ | **CONDITIONAL — trap** | High | `minimal` reasoning effort *uses all sources* and **adds** parallel subqueries — can make it worse |
| 6 | Scale replicas / tier (what they did) | **NO** | Low | Masks the design problem; breaks again as users grow |
| 7 | Disable semantic ranker on some indexes | NO to fan-out, YES to the 206 | Low | Relevance regression |
| 8 | Add sources to exceed 25 and trigger GPT filtering | Technically yes | — | **Do not do this** — perverse incentive, adds latency and cost |

Rank 2 is the cheapest path to description-driven routing **without an index rebuild**, and it is the direct answer to the customer's stated blocker. Rank 1 and Rank 2 compose — do Rank 2 first, Rank 1 later.

### Scenario 2 — Immediate mitigations while RCA completes

| # | Action | Basis | Confidence |
| --- | --- | --- | --- |
| 1 | Verify `properties.semanticSearch == "standard"`, not `"free"` | 1,000 free semantic req/month exhausts in days at this fan-out | High |
| 2 | Size SU against `ceil(7 × peak_concurrent_turns / 9)` on S1 — **not** against average QPS | Semantic limits table | High |
| 3 | Keep **≥2 replicas** (read SLA); **≥3** if indexers write during query hours | reliability-ai-search; search-capacity-planning | High |
| 4 | Audit the `sessionId` the agent passes — a constant value pins traffic to one replica set | search-post REST reference | High |
| 5 | Instrument 206 explicitly at the **APIM layer** — `ThrottledSearchQueriesPercentage` will never show it | monitor data reference | High |
| 6 | Move indexer schedules out of business hours — indexing and queries share resources with no prioritization | search-capacity-planning | Medium |
| 7 | Confirm whether the 403s are **design-mode only**; if so, production may be healthy and the engagement reframes | Customer telemetry `DesignMode: True` | High |
| 8 | If explicit `semanticErrorHandling` control is needed, bypass the built-in connector (custom connector / HTTP action / APIM `set-body`) | connectors/azureaisearch parameter list | High |

**Replica scaling is online.** Docs: *"It occurs in the background, so your search service remains fully operational"* — but it *"can take several hours"* and *"you can't cancel the operation."* SLA rule: **2 replicas for read, 3 for read-write; partitions do not affect SLA.**

### Scenario 3 — Observability build-out

**Step 0 — enable what is missing.** Search diagnostic setting with **both** `OperationLogs` and `AllMetrics`; APIM `GatewayLogs` with **response-body logging** (the only way to see the 206 reason); Copilot Studio → App Insights with "Log conversation details" **on**.

> ⚠️ If App Insights has `DisableLocalAuth` set, Copilot Studio telemetry export **fails silently**. Check this first.
> ⚠️ APIM **Consumption tier supports no resource logs at all** — confirm the tier before planning around gateway logs.

**Proving the 7× fan-out:**

```kusto
// Q1b-FanOutRatio — AzureDiagnostics
AzureDiagnostics
| where TimeGenerated > ago(24h)
| where ResourceProvider == "MICROSOFT.SEARCH"
| where OperationName == "Query.Search"
| summarize
    TotalQueries    = count(),
    DistinctIndexes = dcount(IndexName_s),
    QueriesPerIndex = round(count() * 1.0 / todouble(dcount(IndexName_s)), 2)
    by bin(TimeGenerated, 1m)
| extend FanOutFactor = TotalQueries / QueriesPerIndex
| render timechart with (ytitle = "Queries / Indexes")
```

**Isolating 206 and 403 on the Search side:**

```kusto
// Q2-SearchByHttpResultCode — AzureDiagnostics
AzureDiagnostics
| where TimeGenerated > ago(24h)
| where ResourceProvider == "MICROSOFT.SEARCH"
| where OperationName in ("Query.Search", "Query.Suggest", "Query.Lookup", "Query.Autocomplete")
| extend StatusCode = toint(resultSignature_d)
| extend StatusBucket = case(
      StatusCode == 200, "200 OK",
      StatusCode == 206, "206 Partial Content (semantic capacity)",   // UNVERIFIED that Search logs 206
      StatusCode == 403, "403 Forbidden (auth / network policy)",
      StatusCode == 429, "429 Too Many Requests (throttle)",
      StatusCode == 503, "503 Service Unavailable (throttle)",
      strcat(tostring(StatusCode), " Other"))
| summarize Requests = count() by StatusBucket, bin(TimeGenerated, 5m)
| render timechart
```

**The 403 attribution query — run this first:**

```kusto
// Q8c-Apim403Triage — ApiManagementGatewayLogs (all columns VERIFIED)
ApiManagementGatewayLogs
| where TimeGenerated > ago(7d)
| where ResponseCode == 403 or BackendResponseCode == 403
| extend Origin403 = case(
      BackendResponseCode == 403, "403 from Azure AI Search backend",
      ResponseCode == 403 and (isnull(BackendResponseCode) or BackendResponseCode == 0), "403 raised by APIM policy",
      "403 rewritten by APIM")
| summarize
    Count         = count(),
    FirstSeen     = min(TimeGenerated),
    LastSeen      = max(TimeGenerated),
    Operations    = make_set(OperationName, 10),
    Subscriptions = make_set(ApimSubscriptionId, 10),
    CallerIps     = make_set(CallerIpAddress, 10),
    SampleMessage = take_any(LastErrorMessage)
    by Origin403, LastErrorSource, LastErrorReason, LastErrorScope, LastErrorSection
| order by Count desc
```

`ResponseCode` is what APIM returned **to Copilot Studio**; `BackendResponseCode` is what **Search returned to APIM**. Divergence is the definitive attribution.

**Capturing the 206 reason — the only documented place it exists:**

```kusto
// Q8d-Apim206SemanticPartialCapture — ApiManagementGatewayLogs (requires body logging)
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| where ResponseCode == 206 or BackendResponseCode == 206
| extend PartialReason = extract(@"semanticPartialResponseReason""\s*:\s*""([^""]+)""", 1, tostring(BackendResponseBody))
| summarize Count = count(), Reasons = make_set(PartialReason, 10), AvgBackendMs = round(avg(BackendTime), 1)
    by bin(TimeGenerated, 1h)
| order by TimeGenerated desc
```

**Connector telemetry — discovery first.** The customer's span shape (`type == "Connector"`, `attributes.conversationId`) matches **neither** documented Copilot Studio schema (docs show `GenAI`/`ExecuteTool` and `gen_ai.conversation.id`). Run discovery before shipping any dashboard:

```kusto
// Q6-0c-DiscoverDependencyTypes — Application Insights
dependencies
| where timestamp > ago(7d)
| summarize Calls = count(), Failures = countif(success == false),
            SampleRc = take_any(resultCode), FirstSeen = min(timestamp), LastSeen = max(timestamp)
    by type, name, target
| order by Calls desc
```

**Priority alert rules** (thresholds are engineering recommendations — Microsoft publishes none; tune against 2 weeks of baseline):

| Rule | Signal | Condition | Sev |
| --- | --- | --- | --- |
| Semantic partial (206) at APIM | `ApiManagementGatewayLogs` `BackendResponseCode == 206` | `count() > 0` / 15 min | 2 |
| Connector 403 rate | `dependencies` `resultCode == "403"` | `> 1%` of calls or `count() > 10` / 15 min | 1 |
| Search throttling critical | `ThrottledSearchQueriesPercentage` | `> 5%` / 5 min | 1 |
| Search throttling warning | `ThrottledSearchQueriesPercentage` | `> 1%` / 5 min | 3 |
| Search latency p95 | `AzureDiagnostics` `DurationMs` | `percentile(DurationMs, 95) > 1000 ms` | 2 |
| Ingestion↔query contention | composite | indexing ops > 0 AND query p95 > 2× baseline in same bucket | 2 |

### Scenario 4 — CSS escalation

**Open BOTH tickets. Lead with Azure.** Neither portal can transfer a case to the other product's engineering team.

```text
Symptom observed
│
├─ 206 / CapacityOverloaded / semantic concurrency / replica sizing / APIM 403
│      -> AZURE PORTAL > Help + support > Create a support request
│         Service: "Azure AI Search"  (separate ticket for "API Management")
│
├─ Error 613 / connector 403 / fan-out behavior / Copilot Studio quotas
│      -> POWER PLATFORM ADMIN CENTER > Support > Get support
│         Product: "Microsoft Copilot Studio"
│
└─ Cannot isolate -> open both, cross-reference case numbers
```

**Sequencing:**

1. **Azure AI Search ticket first.** Strongest documented basis (Microsoft's own docs instruct customers to file), clearest ask (confirm/raise the semantic concurrency limit and resolve the 10-per-replica vs 3-per-SU contradiction), and it addresses the actual root cause.
2. **Copilot Studio ticket second**, referencing the Azure case number, covering the 613/403 connector errors and fan-out behavior.
3. If APIM is confirmed as the 403 source, that is a **third** Azure ticket under "API Management".

**Two traps to warn the customer about:**

* **Power Platform support does not perform RCAs** for single-tenant issues — documented policy. Frame the ask as *"identify and remediate"*, not *"provide an RCA."* Causal analysis happens on the Azure side.
* **Power Platform performance cases are capped at 4 hours** of engineer time before closure, unless the customer holds Unified/Professional Direct for advisory continuation.

Recommended severity: **B on both.** Sev A risks automatic downgrade since the service is functioning post-mitigation.

**Evidence to attach (collect before filing):**

* Search service name, region, tier, and **replica × partition counts at failure time and now**.
* `properties.semanticSearch` value (`free` vs `standard`).
* Service **creation date** — pre-2024-04-03 Basic caps at 1 partition (3 SU); later allows 3×3 (9 SU).
* Exact **UTC timestamps** of failures plus `request-id` / `x-ms-request-id` response headers.
* **Raw 206 response body** showing `@search.semanticPartialResponseReason` and `...Type`.
* App Insights / Log Analytics exports, APIM gateway logs, Copilot Studio `conversationId` values.
* A **reproducible query** and the observed fan-out (7 concurrent semantic requests per turn).

## Potential Next Research

* **Confirm how the 7 indexes are wired** (Knowledge page vs Tools page screenshots). If they are already Tools, description routing *should* apply and this becomes a description-quality problem — a materially different answer. **Highest-impact open gap.**
* **Determine whether the 206s are exclusively `Transient` or whether `CapacityOverloaded` also appears.** `CapacityOverloaded` is the only reason Microsoft explicitly documents as throttling; `Transient` is not. This single data point decides whether the capacity story is *proven* or *inferred*.
* **Capture an APIM trace of the outbound request body** to `search.windows.net` — resolves who sets `semanticErrorHandling: partial` and what `semanticMaxWaitInMilliseconds` is in effect.
* **Establish what else changed in the same window as the Basic → S1 scale** (firewall edits, key regeneration, APIM policy changes). If the 403s stopped then, coincidence is far more likely than causation.
* **Validate empirically whether `resultSignature_d` ever emits `206`** in the customer's workspace — half the Search-side 206 tooling depends on it and no doc example confirms it.
* Confirm the connector's documented **200 calls / 60 s** limit and which status code it returns (not published; convention says 429).
* Determine whether Front Door / WAF / Application Gateway sits in the path — WAF blocks on *content*, plausible given French free-text search input.

## Unverified / Open Items

| ID | Gap | Impact |
| --- | --- | --- |
| U1 | No Microsoft source links `Transient` (as opposed to `CapacityOverloaded`) to tier or capacity | Correlation is real but inferred |
| U2 | Who sets `semanticErrorHandling: "partial"` — default is `fail`, connector does not expose it | Blocks precise mechanism |
| U3 | Effective `semanticMaxWaitInMilliseconds` when omitted — undocumented | Minor |
| U4 | Doc contradiction: "10 concurrent per replica" vs "2/3 per search unit" | Sizing math uncertainty — ask CSS |
| U5 | Semantic ranker plan (`free` vs `standard`) unknown | Could be an entirely separate root cause |
| U6 | Whether Search emits `206` into `resultSignature_d` | Determines whether Search-side 206 alerting is viable |
| U7 | Azure AI Search does not appear in Copilot Studio's supported knowledge-sources table | Cannot confirm the wiring model |
| U8 | Customer span shape matches neither documented Copilot Studio telemetry schema | Discovery queries required before dashboards |
| U9 | APIM tier unknown — Consumption supports no resource logs | Could invalidate the gateway-log diagnostic plan |
| U10 | Whether Search returns `request-id` on 403 responses | Correlation may lose its key on exactly the failing requests |
| U11 | Support-plan entitlements — an Azure Unified contract does **not** automatically cover Power Platform | Could block ticket filing |

## Questions to Put to the Customer

1. How are the 7 indexes wired — Knowledge sources or Tools? (Changes the headline answer.)
2. Is `properties.semanticSearch` set to `free` or `standard`?
3. Are the 206s exclusively `Transient`, or does `CapacityOverloaded` also appear?
4. Exact replica × partition counts on Basic at failure time, and now on S1? Search service creation date?
5. Which connector auth type — admin key, Entra ID Integrated, or service principal?
6. Is Search `publicNetworkAccess` = Enabled or Selected IP addresses? If the latter, what is in `networkRuleSet.ipRules` and when was it last refreshed?
7. Full APIM policy XML at all four scopes — any `<quota>`, `<ip-filter>`, `<validate-jwt failed-validation-httpcode="403">`, `<on-error>`? Which APIM tier?
8. Do the 403s occur on the published agent, or only in the test canvas?
9. Did anything else change in the same window as the Basic → S1 scale?
10. What `sessionId` does the agent pass?
11. Is "Allow ungrounded responses" off?
12. Is the Search diagnostic setting enabled with `OperationLogs` AND `AllMetrics`? Is `DisableLocalAuth` set on the shared App Insights?
13. Peak **concurrent user turns** (not users/hour)?

## Project Conventions

* Research artifacts under `.copilot-tracking/` use plain-text workspace-relative paths (not markdown links); external URLs use markdown link syntax.
* `<!-- markdownlint-disable-file -->` present — `.copilot-tracking/**` is exempt from repository lint rules.
