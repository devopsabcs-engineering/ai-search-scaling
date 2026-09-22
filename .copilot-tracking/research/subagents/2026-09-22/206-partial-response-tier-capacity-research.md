<!-- markdownlint-disable-file -->
# Research: Azure AI Search HTTP 206 Partial Semantic Responses and Service Tier Capacity

**Status**: Complete (with explicitly flagged unproven items)
**Date**: 2026-09-22
**Scope**: Deep research only. No code changes were made outside this file.

## Customer Situation Under Investigation

- Copilot Studio agent fans out to **7 Azure AI Search indexes per user turn**, top 3 docs each, through the built-in **Azure AI Search** connector operation `SemanticHybridSearch`, fronted by Azure API Management.
- Intermittent HTTP **206** responses containing `"@search.semanticPartialResponseReason": "Transient"` and `"@search.semanticPartialResponseType": "BaseResults"`.
- Symptom: empty or incomplete agent answers despite populated indexes. Non-deterministic, hits different indexes randomly.
- Started on **Basic**. Adding replicas helped substantially. **Basic → S1** resolved "in large part".
- Load ~7-15 users/hour.
- **Zero HTTP 429** observed.

---

## Q1. What HTTP 206 Means in Azure AI Search

### 1.1 206 is a first-class, documented response status for Search Documents

The `Documents - Search Post` REST reference publishes **two success sample responses for the same operation: status code `200` and status code `206`**. The 206 sample is a fully-formed `SearchDocumentsResult` payload containing `value[]` documents — it is *not* an error envelope.

- https://learn.microsoft.com/en-us/rest/api/searchservice/documents/search-post

The response model `SearchDocumentsResult` defines these annotations:

> | `@search.semanticPartialResponseReason` | SemanticErrorReason | Reason that a partial response was returned for a semantic ranking request. |
> | `@search.semanticPartialResponseType` | SemanticSearchResultsType | Type of partial response that was returned for a semantic ranking request. |

Source: https://learn.microsoft.com/en-us/rest/api/searchservice/documents/search-post

### 1.2 `@search.semanticPartialResponseReason` — complete enum (`SemanticErrorReason`)

EXACT quote from the REST reference definition table:

> ### SemanticErrorReason
>
> Enumeration
>
> Reason that a partial response was returned for a semantic ranking request.
>
> | Value | Description |
> | --- | --- |
> | maxWaitExceeded | If `semanticMaxWaitInMilliseconds` was set and the semantic processing duration exceeded that value. Only the base results were returned. |
> | capacityOverloaded | The request was throttled. Only the base results were returned. |
> | transient | At least one step of the semantic process failed. |

Sources:

- https://learn.microsoft.com/en-us/rest/api/searchservice/documents/search-post
- https://learn.microsoft.com/en-us/dotnet/api/azure.search.documents.models.semanticerrorreason

The .NET SDK struct `Azure.Search.Documents.Models.SemanticErrorReason` publishes the identical three properties (`CapacityOverloaded`, `MaxWaitExceeded`, `Transient`) with identical descriptions.

The **wire values** (camelCase) are confirmed in the Java SDK generated docstrings:

```text
@search.semanticPartialResponseReason: String(maxWaitExceeded/capacityOverloaded/transient) (Optional)
@search.semanticPartialResponseType: String(baseResults/rerankedResults) (Optional)
@search.semanticQueryRewritesResultType: String(originalQueryOnly) (Optional)
```

Source: `Azure/azure-sdk-for-java` → `sdk/search/azure-search-documents/src/main/java/com/azure/search/documents/SearchClient.java` (and `SearchAsyncClient.java`, `implementation/SearchClientImpl.java`)

Canonical schema definition: `Azure/azure-rest-api-specs` → `specification/search/data-plane/Search/models-index.tsp`

```tsp
/** Reason that a partial response was returned for a semantic ranking request. */
@visibility(Lifecycle.Read)
@encodedName("application/json", "@search.semanticPartialResponseReason")
semanticPartialResponseReason?: SemanticErrorReason;
```

> **Note on casing.** The wire/spec value is `transient` (lowercase). The customer reports `"Transient"` (PascalCase). Both casings appear in Microsoft's own published samples — the query-rewrite doc shows `"@search.semanticPartialResponseReason": "Transient"`. Treat them as the same value; the enum is declared `modelAsString: true` in the swagger, so the service may emit either casing and clients must not string-compare case-sensitively.

### 1.3 `@search.semanticPartialResponseType` — complete enum (`SemanticSearchResultsType`)

EXACT quote:

> ### SemanticSearchResultsType
>
> Enumeration
>
> Type of partial response that was returned for a semantic ranking request.
>
> | Value | Description |
> | --- | --- |
> | baseResults | Results without any semantic enrichment or reranking. |
> | rerankedResults | Results have been reranked with the reranker model and will include semantic captions. They will not include any answers, answers highlights or caption highlights. |

Source: https://learn.microsoft.com/en-us/rest/api/searchservice/documents/search-post

### 1.4 What the service actually returns to the caller, per case

| Reason | Type returned | What the caller receives | What is MISSING |
| --- | --- | --- | --- |
| `maxWaitExceeded` | `baseResults` | Documents ranked only by BM25 (text) or RRF (hybrid/vector) | `@search.rerankerScore`, `@search.captions`, `@search.answers` |
| `capacityOverloaded` | `baseResults` | Documents ranked only by BM25/RRF | `@search.rerankerScore`, `@search.captions`, `@search.answers` |
| `transient` | `baseResults` **or** `rerankedResults` (depends which step failed) | If `baseResults`: BM25/RRF only. If `rerankedResults`: reranked docs + captions | If `baseResults`: reranker score, captions, answers. If `rerankedResults`: answers, answer highlights, caption highlights |

The mapping "reason → what you get" is explicitly stated in the `SemanticErrorMode.partial` description:

> **partial** — If the semantic processing fails, partial results still return. **The definition of partial results depends on what semantic step failed and what was the reason for failure.**

Source: https://learn.microsoft.com/en-us/rest/api/searchservice/documents/search-post

### 1.5 Decisive interpretation for the customer's exact pair

`Transient` + `BaseResults` means, per Microsoft's own wording:

1. **`transient`** = "At least one step of the semantic process failed." — the L2 reranker subsystem call failed. This is the *generic failure* bucket, distinct from an explicit wait-timeout (`maxWaitExceeded`) and distinct from an explicit throttle (`capacityOverloaded`).
2. **`baseResults`** = "Results without any **semantic enrichment or reranking**." — the caller got the *L1* BM25/RRF result set, with **no** `@search.rerankerScore`, **no** `@search.captions`, **no** `@search.answers`.

Consequence for a Copilot Studio agent: any downstream logic that reads `@search.captions` or `@search.answers`, or that filters on a `@search.rerankerScore` threshold, will see nulls/empties for that index on that turn. That is the mechanism by which the agent "returns empty answers even though the index has data".

The only prose description Microsoft publishes for `Transient` is on the query-rewrite page:

> - The response includes a `@search.semanticPartialResponseReason` property with a value of "Transient". **This message means that at least one of the queries failed to complete.**

Source: https://learn.microsoft.com/en-us/azure/search/semantic-how-to-query-rewrite (section "Test query rewrites with debug" → "Partial response reasons")

### 1.6 Related annotation worth checking in the customer's payloads

`@search.semanticQueryRewritesResultType` with value `originalQueryOnly` travels alongside `Transient` when **query rewrite (preview)** is enabled and its generative step fails:

```json
{
  "@search.debug": {
    "semantic": null,
    "queryRewrites": { "text": { "rewrites": [] }, "vectors": [] }
  },
  "@search.semanticPartialResponseReason": "Transient",
  "@search.semanticQueryRewriteResultType": "OriginalQueryOnly"
}
```

Source: https://learn.microsoft.com/en-us/azure/search/semantic-how-to-query-rewrite

If the customer's payloads contain this property, query rewrite — not just the reranker — is part of the failure surface.

---

## Q2. Semantic Ranker Timeout and Error-Handling Behavior

### 2.1 `semanticMaxWaitInMilliseconds`

EXACT quote from the request body table:

> | semanticMaxWaitInMilliseconds | integer (int32)<br>minimum: 700 | Allows the user to set an upper bound on the amount of time it takes for semantic enrichment to finish processing before the request fails. |

Source: https://learn.microsoft.com/en-us/rest/api/searchservice/documents/search-post

Facts established:

- **Minimum allowed value: 700 ms.** Confirmed in the TypeSpec source (`@minValue(700)`) and in every swagger version from `2023-07-01-Preview` through `2025-09-01` stable (`"minimum": 700`).
  - `Azure/azure-rest-api-specs` → `specification/search/data-plane/Search/models-index.tsp`
  - `Azure/azure-rest-api-specs` → `specification/search/data-plane/Search/stable/2025-09-01/searchindex.json`
- **No default is documented.** The swagger property carries `"type": "integer"`, `"x-nullable": true`, `"minimum": 700` and a description — but **no `default` key**. The TypeSpec declares it optional (`semanticMaxWaitInMilliseconds?: int32`) with no default. ⚠️ Therefore the effective server-side timeout when the parameter is omitted is **undocumented**.
- Introduced in API version `2023-07-01-preview`:

  > ## 2023-07-01-preview
  >
  > \+ Adds `semanticErrorHandling`, `semanticMaxWaitInMilliseconds`.

  Source: https://learn.microsoft.com/en-us/azure/search/semantic-code-migration

Published example values in Microsoft docs: `780`, `1000`, `5000`.

### 2.2 `semanticErrorHandling` (`SemanticErrorMode`)

EXACT quote from the request body table:

> | semanticErrorHandling | SemanticErrorMode | Allows the user to choose whether a semantic call should fail completely **(default / current behavior)**, or to return partial results. |

EXACT quote from the enum definition:

> ### SemanticErrorMode
>
> Enumeration
>
> Allows the user to choose whether a semantic call should fail completely, or to return partial results.
>
> | Value | Description |
> | --- | --- |
> | partial | If the semantic processing fails, partial results still return. The definition of partial results depends on what semantic step failed and what was the reason for failure. |
> | fail | If there is an exception during the semantic processing step, the query will fail and return the appropriate HTTP code depending on the error. |

Source: https://learn.microsoft.com/en-us/rest/api/searchservice/documents/search-post

The "(default / current behavior)" parenthetical is attached to **`fail`**, and is reproduced verbatim throughout the .NET SDK:

- `Azure/azure-sdk-for-net` → `sdk/search/Azure.Search.Documents/src/Options/SearchOptions.cs`
- `Azure/azure-sdk-for-net` → `sdk/search/Azure.Search.Documents/src/Options/SemanticSearchOptions.cs` (`public SemanticErrorMode? ErrorMode { get; set; }`)
- `Azure/azure-sdk-for-net` → `sdk/search/Azure.Search.Documents/src/Generated/Models/SearchPostRequest.cs`

### 2.3 How `semanticErrorHandling=partial` CONVERTS a failure into a 206

The causal chain, assembled from the above definitions:

```text
L1 retrieval (BM25 or RRF) succeeds → top 50 candidates
        │
        ▼
L2 semantic ranker invoked (summarize → rerank → captions/answers)
        │
        ├── succeeds ──────────────────► HTTP 200, rerankerScore + captions + answers
        │
        └── fails / times out / throttled
                  │
                  ├── semanticErrorHandling = "fail" (DEFAULT)
                  │      └─► request FAILS. "the query will fail and return the
                  │          appropriate HTTP code depending on the error."
                  │          Caller sees 4xx/5xx. No documents at all.
                  │
                  └── semanticErrorHandling = "partial"
                         └─► HTTP 206 Partial Content.
                             Documents ARE returned (L1 ranking preserved).
                             @search.semanticPartialResponseReason  = why L2 failed
                             @search.semanticPartialResponseType    = how degraded
```

`partial` is a **graceful-degradation switch**. It trades "hard error, zero results" for "soft success, unranked results". The 206 status code *is* the signal that this trade was exercised.

This is also why the customer sees **inconsistent, per-index, random** behavior: each of the 7 index queries independently attempts L2 enrichment, and each independently succeeds (200) or degrades (206).

### 2.4 Concrete REST request bodies (from Microsoft docs)

Minimal, as published on the REST reference page:

```http
POST https://myservice.search.windows.net/indexes('myindex')/docs/search.post.search?api-version=2026-04-01

{
  "count": true,
  "highlightPostTag": "</em>",
  "highlightPreTag": "<em>",
  "queryType": "semantic",
  "search": "how do clouds form",
  "semanticConfiguration": "my-semantic-config",
  "answers": "extractive|count-3",
  "captions": "extractive|highlight-true",
  "semanticErrorHandling": "partial",
  "semanticMaxWaitInMilliseconds": 780
}
```

Full hybrid + semantic example (the `SearchIndexSearchDocumentsSemanticPost` sample), abridged to the relevant fields:

```http
POST https://exampleservice.search.windows.net/indexes('test-index')/docs/search.post.search?api-version=2026-04-01

{
  "count": true,
  "queryType": "semantic",
  "search": "purple",
  "select": "id,name,description,category,ownerId",
  "top": 10,
  "semanticConfiguration": "testconfig",
  "semanticErrorHandling": "partial",
  "semanticMaxWaitInMilliseconds": 5000,
  "semanticQuery": "find all purple",
  "answers": "extractive",
  "captions": "extractive",
  "vectorQueries": [
    {
      "vector": [0,1,2,3,4,5,6,7,8,9],
      "kind": "vector",
      "k": 50,
      "fields": "vector22, vector1b",
      "oversampling": 20,
      "weight": 1
    }
  ],
  "vectorFilterMode": "preFilter"
}
```

Sources (both): https://learn.microsoft.com/en-us/rest/api/searchservice/documents/search-post
Spec copy of the second sample: `Azure/azure-rest-api-specs` → `specification/search/data-plane/Search/stable/2025-09-01/examples/SearchIndexSearchDocumentsPost.json`

.NET SDK equivalent (from the SDK test suite, showing the two knobs together):

```csharp
SemanticSearch = new()
{
    SemanticConfigurationName = "my-semantic-config",
    QueryCaption = new QueryCaption(QueryCaptionType.Extractive) { HighlightEnabled = true, MaxCharLength = 300 },
    ErrorMode = SemanticErrorMode.Partial,
    MaxWait = TimeSpan.FromMilliseconds(1000),
}
```

Source: `Azure/azure-sdk-for-net` → `sdk/search/Azure.Search.Documents/tests/DocumentOperations/SearchTests.cs`

### 2.5 ⚠️ Critical implication for THIS customer

Because the documented default is `fail`, and because the customer is receiving **206**, something in the call path is explicitly setting `semanticErrorHandling: "partial"`.

The Copilot Studio `SemanticHybridSearch` connector operation exposes **no such parameter**. Its complete published parameter list is:

> | Index Name | indexName | True | string |
> | Search Text | searchText | | string |
> | Vectorized Search Fields | vectorizedSearchFields | | array of string |
> | Semantic Configuration | semanticConfiguration | | string |
> | Select Fields | selectFields | | array of string |
> | Filter condition | filterCondition | | string |
> | SessionId | sessionId | | string |
> | Nearest Neighbors | nearestNeighbors | | integer |
> | Top Searches | top | | integer |
> | Skip Searches | skipSearches | | integer |

Source: https://learn.microsoft.com/en-us/connectors/azureaisearch/

There is **no `semanticErrorHandling` and no `semanticMaxWaitInMilliseconds`** exposed. Therefore:

- The customer **cannot** turn the 206 into a hard error (to make failures loud), and **cannot** raise the semantic wait budget, **through the connector**.
- Whatever value the connector's server-side implementation sends is opaque and not user-tunable.
- Getting control over these two parameters requires bypassing the built-in connector — e.g. a custom connector, an HTTP action, or an APIM policy that injects the fields into the request body.

---

## Q3. Why Basic Produces More 206 `Transient` Than S1

This is the highest-value section. There **is** a hard, published, tier-indexed limit that directly explains the behavior.

### 3.1 THE decisive table — semantic ranker throttling limits by tier

EXACT quote:

> #### Semantic ranker throttling limits
>
> Semantic ranker uses a **queuing system** to manage concurrent requests. This system allows search services to get the highest number of queries per second possible. **When the limit of concurrent requests is reached, the system places additional requests in a queue. If the queue is full, the system rejects further requests and they must be retried.**
>
> Total semantic ranker queries per second vary based on the following factors:
>
> - **The tier of the search service. Both queue capacity and concurrent request limits vary by tier.**
> - **The number of search units in the search service.** The simplest way to increase the maximum number of concurrent semantic ranker queries is to add more search units to your search service.
> - The total available semantic ranker capacity in the region.
> - The amount of time it takes to serve a query using semantic ranker. This time varies based on how busy the search service is.
>
> The following table describes the semantic ranker throttling limits by tier, subject to available capacity in the region. You can contact Microsoft support to request a limit increase.
>
> | Resource | Basic | S1 | S2 | S3 | S3 HD | L1 | L2 | Serverless Developer |
> | --- | --- | --- | --- | --- | --- | --- | --- | --- |
> | Maximum concurrent requests (per search unit) | **2** | **3** | 4 | 4 | 4 | 4 | 4 | 4 (per service) |
> | Maximum request queue size (per search unit) | **4** | **6** | 8 | 8 | 8 | 8 | 8 | 8 (per service) |

Source: https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity (section "Throttling limits" → "Semantic ranker throttling limits")

**This is the single most important fact in this research.** It is an explicit, documented, per-tier, per-search-unit concurrency + queue limit on the semantic ranker specifically.

### 3.2 The arithmetic for this customer's fan-out pattern

Semantic-ranker in-flight capacity = `SU × concurrent` + `SU × queue`, where `SU = replicas × partitions`.

| Configuration | SU | Concurrent | Queue | Total in-flight before rejection |
| --- | --- | --- | --- | --- |
| Basic, 1 replica × 1 partition | 1 | 2 | 4 | **6** |
| Basic, 2 replicas × 1 partition | 2 | 4 | 8 | 12 |
| Basic, 3 replicas × 1 partition | 3 | 6 | 12 | 18 |
| S1, 1 replica × 1 partition | 1 | 3 | 6 | **9** |
| S1, 2 replicas × 1 partition | 2 | 6 | 12 | 18 |
| S1, 3 replicas × 1 partition | 3 | 9 | 18 | **27** |

Observations that match the customer's reported history exactly:

1. **Basic at 1 SU can hold 6 semantic requests in flight. The agent issues 7 per user turn.** A single user turn structurally exceeds the semantic-ranker capacity of a 1-SU Basic service before any second user arrives. This is not a load problem — it is an *arity* problem.
2. **"Adding replicas helped a lot."** Explained: each replica is +1 SU, which is +2 concurrent and +4 queue slots on Basic. Going 1 → 3 replicas triples semantic-ranker in-flight capacity from 6 to 18.
3. **"Basic → S1 resolved it in large part."** Explained: at identical SU count, S1 gives **+50% concurrent slots and +50% queue depth** vs Basic (3/6 vs 2/4). At 3 SU that is 27 in-flight vs 18 — a 50% lift for a pure tier change with no additional replicas.
4. **"In large part" (not fully).** Explained by the remaining documented variables: regional semantic-ranker capacity, and per-query service time under load, neither of which a tier change fully removes. Also `Transient` is *not* the same code as `capacityOverloaded` — see §3.6 and the Unproven section.

### 3.3 Published expected-workload guidance for semantic ranking

EXACT quote:

> ## Expected workloads
>
> **For semantic ranking, you should expect a search service to support up to 10 concurrent queries per replica.**
>
> The service throttles semantic ranking requests if volumes are too high. An error message that includes these phrases indicate the service is at capacity for semantic ranking:
>
> ```json
> Error in search query: Operation returned an invalid status 'Partial Content'`
> @search.semanticPartialResponseReason`
> CapacityOverloaded
> ```
>
> If you anticipate consistent throughput requirements near, at, or higher than this level, please file a support ticket so that we can provision for your workload.

Source: https://learn.microsoft.com/en-us/azure/search/semantic-how-to-query-request (section "Expected workloads")

Two things this establishes:

- Microsoft frames semantic-ranker capacity **per replica**, reinforcing that replicas are the lever.
- Microsoft explicitly documents that **HTTP "Partial Content" (206) is the surfacing mechanism for semantic ranker capacity exhaustion**. Not 429. Not 503.

> ⚠️ Note the tension: this paragraph says 10 concurrent queries per replica, while the limits table says 2 (Basic) / 3 (S1) concurrent *per search unit* plus queue. These are different framings (soft expectation vs hard throttle) published on different pages. The limits table is newer and more specific; prefer it. Flagged in "Unproven" below.

### 3.4 Basic vs S1 — scale ceilings

| Resource | Basic | S1 | Source |
| --- | --- | --- | --- |
| Max partitions | 3 (new services after 2024-04-03) / 1 (older) | 12 | search-limits-quotas-capacity |
| Max replicas | 3 | 12 | search-limits-quotas-capacity |
| Max search units | **3 SU** (subscription table) — up to **9 SU** for post-2024-04-03 services | **36 SU** | search-limits-quotas-capacity |
| Max indexes | 5 or 15 | 50 | search-limits-quotas-capacity |
| Partition storage | 15 GB (post-2024-04-03) / 2 GB (pre) | 160 GB / 25 GB | search-limits-quotas-capacity |
| Vector quota per partition | 5 GB | 35 GB | search-limits-quotas-capacity |
| Semantic concurrent req / SU | **2** | **3** | search-limits-quotas-capacity |
| Semantic queue size / SU | **4** | **6** | search-limits-quotas-capacity |

EXACT quote on the Basic partition/replica footnote:

> ^1^ The Basic tier supports three partitions and three replicas, for a total of nine search units (SU) on new search services created after April 3, 2024. **Older Basic services are limited to one partition and three replicas.**

Source: https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity

Note the customer runs **7 indexes** — inside Basic's 15-index limit *only if* the service was created after December 2017:

> ^1^ Basic services created before December 2017 have lower limits (5 instead of 15) on indexes.

### 3.5 Documented statement that Basic compute per replica is smaller/slower than S1

Two independent, explicit confirmations:

> The physical characteristics of replicas and partitions, such as processing speed and disk IO, vary by service tier. **On a standard search service, the replicas and partitions are faster and larger than those of a basic service.**

Source: https://learn.microsoft.com/en-us/azure/search/search-capacity-planning

> The tier of your search service and the number of replicas/partitions also have a large impact on performance. **Each progressively higher tier provides faster CPUs and more memory**, both of which have a positive impact on performance.

Source: https://learn.microsoft.com/en-us/azure/search/search-performance-tips

And, on the tier-upgrade path:

> Generally, switching to a higher tier increases your storage limit and vector limit, **increases request throughput, and decreases latency**, while switching to a lower tier has the opposite effect.

Source: https://learn.microsoft.com/en-us/azure/search/search-capacity-planning

> An important benefit of added memory is that more of the index can be cached, resulting in **lower search latency, and a greater number of queries per second**.

Source: https://learn.microsoft.com/en-us/azure/search/search-performance-tips

Lower latency matters mechanically here: the documented factor list for semantic ranker QPS includes "**the amount of time it takes to serve a query using semantic ranker**". Faster L1 retrieval frees the semantic queue faster, which raises effective semantic throughput even at identical queue depth.

Corroborating hint that Basic is deliberately given fewer compute resources:

> AI enrichment and image analysis are computationally intensive and consume disproportionate amounts of available processing power. For this reason, **private connections are disabled on lower tiers to ensure the performance and stability of the search service itself. On Basic services, private connections to a Microsoft Foundry resource are unsupported to preserve service stability.**

Source: https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity

### 3.6 Official QPS guidance — and the explicit "not a guarantee" caveat

There is **no published per-tier QPS number.** The general throttling table is deliberately non-numeric for search queries:

> | Search queries (POST /indexes/{index}/docs/search) | **Varies by SU count and query complexity** | 50 queries/sec (aggregate read throttle per index) [Serverless only] |

Source: https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity

The non-guarantee caveat, verbatim:

> Add replicas for high availability or to mitigate slow query performance.
>
> **There are no guidelines on how many replicas are needed to accommodate query loads.** Query performance depends on the complexity of the query and competing workloads. Although adding replicas clearly results in better performance, **the result isn't strictly linear: adding three replicas doesn't guarantee triple throughput.**

Source: https://learn.microsoft.com/en-us/azure/search/search-capacity-planning

And:

> In any large implementation, it's critical to do a performance benchmarking test of your Azure AI Search service before you roll it into production... **Having benchmark numbers helps to validate the proper search tier, service configuration, and expected query latency.**

Source: https://learn.microsoft.com/en-us/azure/search/search-performance-analysis

### 3.7 Semantic ranker billing plans — the FREE allowance is a real risk at this fan-out

EXACT quote of the billing plans table:

> | Plan | Description | Availability |
> | --- | --- | --- |
> | Free (default) | **Provides a monthly free request allowance. After the free allowance is consumed, semantic ranker requests return a billing error.** | Available on all pricing tiers. |
> | Standard | Pay-as-you-go pricing after the monthly free allowance is consumed. | **Requires the Basic tier or higher.** |

Source: https://learn.microsoft.com/en-us/azure/search/semantic-how-to-enable-disable

The **numeric allowance**, from the pricing page:

> | Semantic ranker 1k requests | **First 1k requests free per month** — $1 per 1k requests |

Source: https://azure.microsoft.com/en-us/pricing/details/search/

Billing scope, verbatim:

> Charges for semantic ranker occur when query requests include `queryType=semantic` and the search string isn't empty (for example, `search=pet friendly hotels in New York`). If your search string is empty (`search=*`), you aren't charged, even if the queryType is set to semantic.

Source: https://learn.microsoft.com/en-us/azure/search/semantic-search-overview

**Do the arithmetic for this customer:**

```text
7 indexes/turn × (say) 3 turns/user × 10 users/hour × 8 hours/day × 22 days/month
  = 7 × 3 × 10 × 8 × 22
  = 36,960 semantic ranker requests/month
```

Even at the most conservative reading (7 requests × 7 users/hour × 8h × 22d = 8,624/month), the **1,000/month free allowance is exhausted within the first 1-3 days of every month.**

> ⚠️ **Important distinction, do not conflate these.** Per the docs, exhausting the free allowance produces a **billing error**, *not* a 206 `Transient`. So free-plan exhaustion is a **separate, additional failure mode** the customer may also be hitting, not the established explanation for `Transient`. But it absolutely must be checked: if the service is still on the free semantic plan at this volume, semantic ranking is failing for a completely different reason for most of each month, and any "fix" to tier/replicas will look non-deterministic.

Verify with:

```http
GET https://management.azure.com/subscriptions/{sub}/resourcegroups/{rg}/providers/Microsoft.Search/searchServices/{svc}?api-version=2026-03-01-preview
```

and inspect `properties.semanticSearch` — must be `"standard"`, not `"free"`.

To switch (PATCH, not PUT — see warning below):

```http
PATCH https://management.azure.com/subscriptions/{{subscription-id}}/resourcegroups/{{resource-group}}/providers/Microsoft.Search/searchServices/{{search-service-name}}?api-version=2026-03-01-preview
Content-Type: application/json
Authorization: Bearer {{management-access-token}}

{
  "properties": {
    "semanticSearch": "standard"
  }
}
```

Source: https://learn.microsoft.com/en-us/azure/search/semantic-how-to-enable-disable

> **Warning from the same page:** "If PUT is used to update an existing service, it replaces all properties in the service with their defaults if they aren't specified in the request... **When enabling semantic ranking on an existing service, it's recommended to use PATCH instead of PUT.**"

Also relevant given the 7-index fan-out — API-version-dependent billing split:

> | `2026-04-01` and later | Semantic ranker billing controlled by `semanticSearch` | Agentic retrieval billing controlled by `knowledgeRetrieval` |
> | `2025-11-01-preview` and earlier | `semanticSearch` controls **both** |

Source: https://learn.microsoft.com/en-us/azure/search/semantic-how-to-enable-disable

### 3.8 Summary answer to Q3

Basic produces more 206 `Transient` than S1 because of **four compounding, all-documented factors**:

1. **Hard semantic-ranker concurrency/queue limits are 33% lower on Basic than S1** (2/4 vs 3/6 per SU). This is the primary, explicitly published mechanism.
2. **Basic's SU ceiling is 3-9 vs S1's 36**, so the headroom to scale out of the problem is far smaller.
3. **Basic replicas run on slower CPUs with less memory**, so each semantic request occupies a queue slot longer, lowering effective throughput beyond the raw slot count.
4. A 7-way parallel fan-out per user turn **structurally exceeds a 1-SU Basic service's 6-slot semantic capacity on a single turn**, before any concurrency between users.

---

## Q4. Official Statements / Known Issues Correlating 206 With Contention, Replicas, or Tier

### 4.1 What EXISTS (direct, official)

**(a) The semantic ranker throttling limits section** — the strongest. It states outright that semantic ranker concurrency and queue capacity **vary by tier** and **by search unit count**, and that exhausting them causes request rejection.

- https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity

**(b) The "Expected workloads" section** — the only place Microsoft explicitly names an HTTP 206 / Partial Content response as the symptom of semantic ranker capacity exhaustion:

> An error message that includes these phrases indicate **the service is at capacity for semantic ranking**: `Operation returned an invalid status 'Partial Content'` / `@search.semanticPartialResponseReason` / `CapacityOverloaded`

- https://learn.microsoft.com/en-us/azure/search/semantic-how-to-query-request

**(c) The `capacityOverloaded` enum description** — "The request was throttled. Only the base results were returned."

- https://learn.microsoft.com/en-us/rest/api/searchservice/documents/search-post

**(d) Transient-fault guidance (reliability)** — explicitly ties transient faults to replica count and maintenance:

> Search services might experience transient faults during standard, unscheduled maintenance operations. Azure AI Search doesn't provide advance notification or allow scheduling of maintenance at specific times. Although every effort is made to minimize downtime, even for single-replica services, brief interruptions can still occur. **To improve resiliency against these transient faults, we recommend that you use two or more replicas.**
>
> If you build any applications that interact with AI Search, they should handle transient faults. **Use a retry strategy with exponential backoffs** for both read and write operations.

- https://learn.microsoft.com/en-us/azure/reliability/reliability-ai-search

This is the closest Microsoft comes to officially connecting the *word* "transient" to *replica count* — and it recommends exactly what the customer empirically discovered (add replicas).

**(e) Agentic retrieval / knowledge base 206 documentation** — 206 Partial Content is used the same way elsewhere in the product, reinforcing the "per-sub-request degradation" model:

> The activity array outputs the query plan... **For a `206 Partial Content` response, the array includes errors for failed knowledge sources.** A `502 Bad Gateway` response might provide failure details only in the top-level error.

- https://learn.microsoft.com/en-us/azure/search/agentic-retrieval-how-to-retrieve

> When a `web` knowledge source is present, `models` is required for web content summarization, and **retrieval can return `206 Partial Content` if summarization fails**.

- https://learn.microsoft.com/en-us/azure/search/agentic-retrieval-how-to-migrate

**(f) SDK changelog** confirming 206 is a deliberately-modeled success path, not an error:

> Added support for **partial content responses (HTTP 206)** in knowledge base operations.

- `Azure/azure-sdk-for-net` → `sdk/search/Azure.Search.Documents/CHANGELOG.md`

### 4.2 What does NOT exist (searched and not found)

- ❌ **No dedicated Azure AI Search troubleshooting page for 206 / partial semantic responses.** Searched `MicrosoftDocs/azure-ai-docs` under `articles/search/` for `CapacityOverloaded`, `semanticPartialResponseReason`, `"Partial Content"`, `206` — only three files reference them at all: `semantic-how-to-query-request.md`, `semantic-how-to-query-rewrite.md`, and the agentic-retrieval pages.
- ❌ **No Azure Update / release-note bulletin** declaring 206 `Transient` a known issue tied to tier.
- ❌ **No GitHub issue** in `Azure/*` or `MicrosoftDocs/azure-ai-docs` correlating `Transient` with tier or replica count. Searches across the `Azure` GitHub org and `Azure/azure-sdk-for-net` for `semanticPartialResponseReason` / `SemanticPartialResponseReason 206 partial` returned **only generated model definitions, serializers, spec files, and changelog entries** — zero bug reports, zero issue threads.
- ❌ **No documentation of what the service does internally when `Transient` fires** (retry count, circuit breaker, backend model endpoint behavior). `Transient` remains a black-box "at least one step failed" bucket.

### 4.3 The honest gap

Microsoft documents a clean causal story for `capacityOverloaded` → capacity. It does **not** document a causal story for `transient` → capacity. The link the customer observed empirically (more Basic contention → more `Transient`) is **plausible and consistent with** the documented factor "the amount of time it takes to serve a query using semantic ranker... varies based on how busy the search service is", but it is **not directly asserted anywhere in Microsoft documentation**. See the Unproven section.

---

## Q5. Capacity Planning

### 5.1 The core model

> - **Search unit (SU)** = replicas × partitions
> - **Replica**: Copies of the search engine. Provides query throughput and high availability.
> - **Partition**: Units of storage. Provides storage and indexing throughput.

> | *Replica* | Instances of the search service, used primarily to load balance query operations. Each replica hosts one copy of an index. If you allocate three replicas, you have three copies of an index available for servicing query requests. |
> | *Partition* | Physical storage and I/O for read/write operations... Each partition has a slice of the total index. If you allocate three partitions, your index is divided into thirds. |

Source: https://learn.microsoft.com/en-us/azure/search/search-capacity-planning

### 5.2 Replicas for QPS, partitions for storage — verbatim

> Scaling guidance:
>
> - **Add replicas to increase query throughput and availability.**
> - **Add partitions to increase storage and indexing performance.**
> - **Query-heavy workloads typically require more replicas.**
> - Large indexes might require extra replicas to maintain performance.

> As a general rule, **search applications tend to need more replicas than partitions, particularly when the service operations are biased toward query workloads.** Each replica is a copy of your index, so the service can load balance requests against multiple copies.

Source: https://learn.microsoft.com/en-us/azure/search/search-capacity-planning

Explicit trigger list for adding capacity:

> Consider adding replicas or partitions when:
>
> - Query latency increases or service-level agreement criteria aren't met.
> - The frequency of **HTTP 503 (Service unavailable)** errors increases.
> - The frequency of **HTTP 429 (Too many requests)** errors increases, indicating request throttling.
> - Large query volumes are expected.
> - Indexing jobs are slow or falling behind.
> - Storage or indexing throughput is insufficient.

Source: https://learn.microsoft.com/en-us/azure/search/search-capacity-planning

> ⚠️ Note that **206 is NOT in this list.** This is precisely why a customer seeing only 206s has no obvious documented prompt to scale. See Q6.

### 5.3 The "2 replicas read / 3 replicas read-write" SLA rule

EXACT quote:

> ### Service-level agreement considerations
>
> Service-level agreements (SLAs) don't cover the Free tier and preview features. For all billable tiers, SLAs take effect when you provision sufficient redundancy for your service.
>
> - **Two or more replicas satisfy query (read) SLAs.**
> - **Three or more replicas satisfy query and indexing (read-write) SLAs.**
>
> **The number of partitions doesn't affect SLAs.**

Source: https://learn.microsoft.com/en-us/azure/search/search-capacity-planning

Restated on the limits page:

> Service-level agreements (SLAs) apply to billable services that have two or more replicas for query workloads, or three or more replicas for query and indexing workloads. The number of partitions isn't an SLA consideration.

Source: https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity

And in the reliability doc:

> In AI Search, the availability SLA applies to search services that:
>
> - Are configured to use a billable tier.
> - **Have at least two replicas for read-only workloads (queries).**
> - **Have at least three replicas for read-write workloads (queries and indexing).**

> For production workloads, we recommend that you:
>
> - Use a billable tier that has **at least two replicas**. This configuration makes your search service more resilient to transient faults and maintenance operations.

Source: https://learn.microsoft.com/en-us/azure/reliability/reliability-ai-search
SLA document: https://azure.microsoft.com/en-us/support/legal/sla/search/v1_0/

### 5.4 How to estimate required replicas

Microsoft's position is explicitly **empirical, not formulaic**:

> **There are no guidelines on how many replicas are needed to accommodate query loads.** Query performance depends on the complexity of the query and competing workloads. Although adding replicas clearly results in better performance, **the result isn't strictly linear: adding three replicas doesn't guarantee triple throughput.**

The prescribed method (verbatim steps):

> 1. Review service limits at each tier to determine whether lower tiers can support the number of indexes you need.
> 2. Create a service at a billable tier... Start low, at Basic or S1, if you're not sure about the projected load.
> 3. Build an initial index to determine how source data translates to an index. **This is the only way to estimate index size.**
> 4. **Monitor storage, service limits, query volume, and latency in the Azure portal. The Azure portal shows queries per second, throttled queries, and search latency. These values can help you decide if you selected the right tier.**
> 5. **Add replicas for high availability or to mitigate slow query performance.**

> To isolate the effects of a distributed service architecture, try testing on service configurations of **one replica and one partition**.

Sources:

- https://learn.microsoft.com/en-us/azure/search/search-capacity-planning
- https://learn.microsoft.com/en-us/azure/search/search-performance-analysis

For the customer's specific case, the semantic-ranker limits table (§3.1) **does** give a deterministic sizing formula that the general QPS guidance does not:

```text
required_SU >= ceil( peak_concurrent_semantic_requests / (concurrent_per_SU + queue_per_SU) )

where concurrent_per_SU + queue_per_SU = 6 on Basic, 9 on S1
and   peak_concurrent_semantic_requests ~= 7 x concurrent_user_turns
```

### 5.5 Are replica changes online / zero-downtime?

**Yes — online, but slow and non-cancellable.** EXACT quote:

> This operation **can take several hours to complete. It occurs in the background, so your search service remains fully operational and available for read and write operations.**
>
> **You can't cancel the operation or monitor its progress.** However, the following message displays while changes are underway.

Source: https://learn.microsoft.com/en-us/azure/search/search-capacity-planning (appears for **both** "Add or remove partitions and replicas" **and** "Change your pricing tier")

Additional facts:

> Changing capacity isn't instantaneous. Depending on data volume and operation type, **scaling can take from minutes to several hours.**

> When the search service receives a scale request, it:
>
> 1. Checks whether the request is valid.
> 2. **Starts backing up data and system information.**
> 3. Checks whether the service is already in a provisioning state.
> 4. Starts provisioning.

Tier change is supported in-place between Basic and S1/S2/S3:

> The Azure portal and Services - Update (REST API) support changes between Basic and Standard (S1, S2, and S3) tiers. You can upgrade or downgrade tiers, **provided your current service configuration doesn't exceed the limits of the target tier**. Your region also can't have capacity constraints on the target tier.

> You can switch between Basic, S1, S2, and S3, but **you can't switch to or from Free, S3HD, L1, or L2.**

Known scaling errors:

> | "Service update operations aren't allowed at this time because we're processing a previous request." | Another scaling operation is in progress. | ...wait until status becomes "Succeeded" or "Failed". |
> | "Failed to scale search service *servicename*. Error: *Object* count *ActualCount* exceeds allowable limit: *MaximumCount*." | Your current service configuration exceeds the limits of the target pricing tier. | ...**the Basic tier supports up to 15 indexes, so you can't switch from S1 to Basic if you have 16 indexes.** |

Sources: https://learn.microsoft.com/en-us/azure/search/search-capacity-planning

One caveat relevant to result stability (worth telling the customer, since they're comparing answers across turns):

> Adding more replicas or partitions increases the cost of running the service, and **can introduce slight variations in how results are ordered.**

Source: https://learn.microsoft.com/en-us/azure/search/search-capacity-planning

### 5.6 Replica placement / zone redundancy side-effects

> AI Search attempts to place replicas across different availability zones. However, there are occasionally situations where **all of the replicas of a search service might be placed into the same availability zone. This situation can happen when replicas are removed from your service**... **Replica removal doesn't trigger the remaining replicas to rebalance across the availability zones.**
>
> To reduce the likelihood... you can manually trigger a scale-out operation immediately after a scale-in operation.

Zone redundancy requirements: Basic tier or higher, **at least two replicas**, supported region.

Source: https://learn.microsoft.com/en-us/azure/reliability/reliability-ai-search

---

## Q6. Throttling — 503 vs 429 vs 207, and Why Zero 429s With Real Resource Constraint

### 6.1 Documented throttling status codes

EXACT quote:

> ## Throttling behaviors
>
> Throttling occurs when the search service is at capacity. Throttling can occur during queries or indexing. **From the client side, an API call results in a 503 HTTP response when it has been throttled. During indexing, there's also the possibility of receiving a 207 HTTP response, which indicates that one or more items failed to index. This error is an indicator that the search service is getting close to capacity.**

Source: https://learn.microsoft.com/en-us/azure/search/search-performance-analysis

The Kusto samples on that page filter on **`resultSignature_d == 503`** to count throttled queries — confirming 503, not 429, is the query-throttle signal in resource logs:

```kusto
AzureDiagnostics
| where TimeGenerated > ago(7d)
| where resultSignature_d != 403 and resultSignature_d != 404
    and OperationName in ("Query.Search", "Query.Suggest", "Query.Lookup", "Query.Autocomplete")
| summarize
  ThrottledQueriesPerMinute=bin(countif(OperationName in ("Query.Search", "Query.Suggest", "Query.Lookup", "Query.Autocomplete")
      and resultSignature_d == 503)/(intervalsize/1m), 0.01)
  by bin(TimeGenerated, intervalsize)
| render timechart
```

### 6.2 What the `ThrottledSearchQueriesPercentage` metric actually measures

EXACT quote:

> #### Throttled search queries percentage
>
> This metric refers to queries that are **dropped instead of processed**. Throttling occurs when the number of requests in execution exceed capacity...
>
> **The service determines whether to drop requests based on resource consumption. The percentage of resources consumed across memory, CPU, and disk IO are averaged over a period of time. If this percentage exceeds a threshold, all requests to the index are throttled** until the volume of requests is reduced.
>
> Depending on your client, a throttled request is indicated in these ways:
>
> - A service returns an error `"You are sending too many requests. Please try again later."`
> - **A service returns a 503 error code indicating the service is currently unavailable.**
> - If you're using the Azure portal (for example, Search Explorer), the query is dropped silently.

Source: https://learn.microsoft.com/en-us/azure/search/monitor-azure-cognitive-search-data-reference

Note the metric is driven by **memory / CPU / disk IO averages** — i.e. it measures *host-level* resource saturation of the search engine itself. It does not observe the semantic-ranker queue at all.

### 6.3 Where 429 does appear

429 appears in two documented contexts, neither of which is this customer's path:

1. **Capacity-planning trigger list** — "The frequency of HTTP 429 (Too many requests) errors increases, indicating request throttling." (https://learn.microsoft.com/en-us/azure/search/search-capacity-planning)
2. **Downstream service quota during enrichment** — "Indexer, skill, or vectorizer reports a 429 from another service | Azure OpenAI or other service quota | Follow the quota guidance for the service that issued the error." (https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity)

Case (2) is an indexer/skillset path, irrelevant to query-time semantic ranking.

### 6.4 ⭐ Why the customer sees ZERO 429s yet IS resource-constrained

The semantic ranker runs its **own separate admission-control system** that is architecturally independent of the query-engine throttle:

```text
┌──────────────────────────────────────────────────────────────────────────┐
│ PATH A - search engine host resources (CPU / memory / disk IO)           │
│   Saturation -> request DROPPED -> HTTP 503                              │
│   Observable via: ThrottledSearchQueriesPercentage metric                │
│                  AzureDiagnostics resultSignature_d == 503               │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│ PATH B - semantic ranker concurrency slots + queue (per SU, per tier)    │
│   Saturation -> L2 SKIPPED, L1 results still returned -> HTTP 206        │
│   Observable via: @search.semanticPartialResponseReason in the BODY      │
│   NOT counted by ThrottledSearchQueriesPercentage                        │
│   NOT logged as 503 or 429                                               │
└──────────────────────────────────────────────────────────────────────────┘
```

This is the answer to the customer's question. Verbatim support:

> Semantic ranker uses a queuing system to manage concurrent requests... **When the limit of concurrent requests is reached, the system places additional requests in a queue. If the queue is full, the system rejects further requests and they must be retried.**
> — https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity

> **The service throttles semantic ranking requests if volumes are too high.** An error message that includes these phrases indicate the service is at capacity for semantic ranking: `Operation returned an invalid status 'Partial Content'` ... `CapacityOverloaded`
> — https://learn.microsoft.com/en-us/azure/search/semantic-how-to-query-request

**Microsoft calls it "throttling", but it is surfaced as a 206 body annotation, not an HTTP throttle status code.** Consequences:

- ❌ `ThrottledSearchQueriesPercentage` stays at 0%.
- ❌ No 429. No 503. No `resultSignature_d` anomaly — resource logs record **206**, a 2xx, which most dashboards bucket as success.
- ❌ APIM in front will pass 206 through as a success (it is a 2xx); APIM retry/backoff policies keyed on 429/5xx will not fire.
- ❌ Copilot Studio sees a successful connector call that simply returned documents without captions/answers → renders an empty or thin answer.
- ✅ The **only** place the degradation is visible is inside the JSON body, in `@search.semanticPartialResponseReason`.

This is a textbook **silent graceful degradation** path. The customer's "no 429s in the logs" observation is fully expected and is *not* evidence against resource constraint.

### 6.5 Additional throttle layer specific to this architecture — the connector itself

The Power Platform / Copilot Studio Azure AI Search connector has its own documented throttle:

> ## Throttling Limits
>
> | Name | Calls | Renewal Period |
> | --- | --- | --- |
> | API calls per connection | **200** | **60 seconds** |

Source: https://learn.microsoft.com/en-us/connectors/azureaisearch/

At 7 calls per user turn, 200 calls/60s = **~28 user turns per minute per connection** before the *connector* throttles — a ceiling entirely separate from anything in Azure AI Search. Worth ruling in/out, as connector-level throttling would surface as yet another distinct error shape.

---

## Q7. Interaction Between Concurrent Queries and Semantic Partial Results

### 7.1 Direct documented interaction

The semantic ranker capacity model is expressed **purely in terms of concurrency**, not request rate:

> | Maximum **concurrent requests** (per search unit) | Basic: 2 | S1: 3 | S2/S3/S3HD/L1/L2: 4 |
> | Maximum **request queue size** (per search unit) | Basic: 4 | S1: 6 | S2/S3/S3HD/L1/L2: 8 |

> **For semantic ranking, you should expect a search service to support up to 10 concurrent queries per replica.**

Sources:

- https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity
- https://learn.microsoft.com/en-us/azure/search/semantic-how-to-query-request

This is the strongest possible documentary link between **concurrency** (not volume) and semantic partial results. A workload that issues 7 simultaneous semantic queries per user turn is a **concurrency-shaped** workload, which is exactly the dimension the semantic ranker limits.

### 7.2 Why "~7-15 users/hour" is misleading as a load metric

Average QPS is near-zero. But the limits are on **instantaneous concurrency**:

| Concurrent user turns | Simultaneous semantic requests | Basic 1 SU cap (6) | Basic 3 SU cap (18) | S1 3 SU cap (27) |
| --- | --- | --- | --- | --- |
| 1 | 7 | ❌ **exceeded** | ✅ | ✅ |
| 2 | 14 | ❌ | ✅ | ✅ |
| 3 | 21 | ❌ | ❌ **exceeded** | ✅ |
| 4 | 28 | ❌ | ❌ | ❌ **exceeded** |

The customer's entire reported history — Basic broken, +replicas much better, S1 largely fixed — falls out of this table directly. It also explains the **randomness**: whichever of the 7 parallel sub-queries happens to arrive after the slots and queue are full is the one that degrades, and that is nondeterministic across turns.

### 7.3 Why semantic ranking is expensive enough to make concurrency limits tight

> **Semantic ranking uses a lot of resources and time.** To finish processing within the expected latency of a query operation, the system consolidates and reduces inputs to the semantic ranker.

> 1. The semantic ranker starts with a BM25-ranked result... **only the top 50 results progress to semantic ranking.**
> 2. For each document in the search result, the summarization model accepts **up to 2,000 tokens**...
> 4. ...**the maximum length of each generated summary string passed to the semantic ranker is 2,048 tokens.**

Source: https://learn.microsoft.com/en-us/azure/search/semantic-search-overview

Per semantic query: up to 50 documents × ~2,000-token summarization + a deep-learning rerank pass. Seven of those fired simultaneously is a substantial burst of ML inference.

### 7.4 Secondary concurrency factors that can push a 206

**Indexing competes for the same resources:**

> **An important factor to consider when looking at performance is that indexing uses the same resources as search queries.** If you're indexing a large amount of content, you can expect to see latency grow as the service tries to accommodate both workloads.

> A single service must have sufficient resources to handle all workloads (indexing and queries). **Neither workload runs in the background. You can schedule indexing for times when query requests are naturally less frequent, but the service doesn't otherwise prioritize one task over another.**

Sources:

- https://learn.microsoft.com/en-us/azure/search/search-performance-analysis
- https://learn.microsoft.com/en-us/azure/search/search-capacity-planning

If indexers run on a schedule against any of the 7 indexes, they will transiently degrade semantic capacity.

**Background shard merges:**

> It's common to see **occasional spikes** in query or indexing latency... Search indexes are stored in chunks — or shards. Periodically, the system merges smaller shards into large shards... **Merging shards is fast, but also resource intensive and thus has the potential to degrade service performance.** If you notice short bursts of query latency, and those bursts coincide with recent changes to indexed content, you can assume the latency is due to shard merge operations.

Source: https://learn.microsoft.com/en-us/azure/search/search-performance-analysis

**Unscheduled maintenance / replica rotation:**

> You might see an increase in throttled requests **when a replica is taken out of rotation** or during indexing. Both query and indexing requests are handled by the same set of resources.

Source: https://learn.microsoft.com/en-us/azure/search/monitor-azure-cognitive-search-data-reference

### 7.5 `sessionId` — a concurrency-relevant knob the connector DOES expose

The connector exposes `SessionId`. Its documented behavior:

> | sessionId | string | A value to be used to create a sticky session, which can help getting more consistent results. **As long as the same sessionId is used, a best-effort attempt will be made to target the same replica set.** Be wary that **reusing the same sessionID values repeatedly can interfere with the load balancing of the requests across replicas and adversely affect the performance of the search service.** The value used as sessionId cannot start with a `_` character. |

Source: https://learn.microsoft.com/en-us/rest/api/searchservice/documents/search-post

⚠️ **Actionable risk.** If the Copilot Studio agent passes a **constant or low-cardinality `sessionId`** across all 7 index calls and/or across users, it is pinning traffic to one replica set and **defeating the replica load balancing** the customer paid for. That would explain why "adding replicas helped a lot" but not completely. This should be audited — it is one of the very few levers the connector actually exposes.

---

## Why Basic → S1 Fixed It — The Mechanism

Putting the documented facts in causal order:

```text
STEP 1 - WORKLOAD SHAPE
  Copilot Studio issues 7 SIMULTANEOUS semantic hybrid queries per user turn.
  This is a CONCURRENCY burst, not a throughput load.
  Average QPS ~= 0. Instantaneous concurrency = 7 (x concurrent users).

STEP 2 - THE BINDING CONSTRAINT
  Semantic ranker admission control is defined PER SEARCH UNIT, PER TIER:
      Basic : 2 concurrent + 4 queued = 6 in flight per SU
      S1    : 3 concurrent + 6 queued = 9 in flight per SU
  Source: search-limits-quotas-capacity -> Throttling limits -> Semantic ranker

STEP 3 - WHY BASIC AT 1 SU ALWAYS FAILED
  7 simultaneous semantic requests > 6 in-flight capacity.
  Structural overflow on a SINGLE user turn. No second user required.

STEP 4 - WHY ADDING REPLICAS "HELPED A LOT"
  Each replica = +1 SU = +2 concurrent, +4 queue on Basic.
  1 -> 3 replicas: 6 -> 18 in-flight capacity (3x).
  Also satisfies the >=2-replica transient-fault / SLA recommendation, removing
  single-replica maintenance blips.
  Sources: search-capacity-planning; reliability-ai-search

STEP 5 - WHY Basic -> S1 "RESOLVED IN LARGE PART"
  (a) +50% semantic slots at identical SU count (3/6 vs 2/4).
  (b) 12 replicas x 12 partitions (36 SU ceiling) vs Basic's 3-9 SU ceiling,
      so headroom exists to scale further.
  (c) "Each progressively higher tier provides faster CPUs and more memory."
      Faster L1 + more cache -> each semantic request holds its slot for LESS
      TIME -> higher effective semantic throughput beyond the raw slot math.
      Documented factor: "the amount of time it takes to serve a query using
      semantic ranker... varies based on how busy the search service is."
  Sources: search-limits-quotas-capacity; search-performance-tips;
           search-capacity-planning

STEP 6 - WHY IT LOOKED LIKE A DATA PROBLEM, NOT A CAPACITY PROBLEM
  semanticErrorHandling = "partial" converts an L2 failure into HTTP 206
  instead of a hard error. The caller receives L1 (BM25/RRF) documents but:
      NO @search.rerankerScore
      NO @search.captions
      NO @search.answers
  Copilot Studio's grounding surface goes empty -> "empty answer despite data
  in the index."
  Source: REST SemanticErrorMode / SemanticSearchResultsType definitions

STEP 7 - WHY ZERO 429s
  Semantic ranker queue overflow is a SEPARATE admission-control path from the
  search-engine host throttle. Host throttle -> 503 + ThrottledSearchQueries
  metric. Semantic queue overflow -> 206 + a body annotation, counted nowhere.
  206 is a 2xx: APIM passes it, dashboards bucket it as success, retry policies
  keyed on 429/5xx never fire.
  Sources: search-performance-analysis; monitor-...-data-reference;
           search-limits-quotas-capacity

STEP 8 - WHY IT WAS RANDOM ACROSS INDEXES
  Each of the 7 sub-queries independently contends for slots. Whichever arrives
  after saturation degrades. Nondeterministic per turn, per index.

STEP 9 - WHY "IN LARGE PART" AND NOT "ENTIRELY"
  Remaining documented variables a tier change does NOT eliminate:
    - regional semantic ranker capacity ("subject to available capacity in the
      region")
    - per-query service time under load
    - indexing / shard-merge contention on the same resources
    - unscheduled maintenance, replica rotation
    - POSSIBLE: semantic ranker FREE plan exhausted (1,000 req/month) - this
      workload burns that in ~1-3 days/month
    - POSSIBLE: constant/low-cardinality sessionId pinning traffic to one
      replica set, defeating load balancing
```

### Highest-confidence recommended verifications and mitigations

| # | Action | Evidence basis | Confidence |
| --- | --- | --- | --- |
| 1 | Confirm `properties.semanticSearch == "standard"` (not `"free"`). 1,000 free semantic requests/month is exhausted in days at this fan-out. Use **PATCH**, never PUT. | semantic-how-to-enable-disable; pricing page | High |
| 2 | Size SU against `ceil(7 × peak_concurrent_turns / 9)` on S1, not against average QPS. | search-limits-quotas-capacity semantic table | High |
| 3 | Keep ≥2 replicas (read SLA + transient-fault resilience); ≥3 if indexers write during query hours. | reliability-ai-search; search-capacity-planning | High |
| 4 | Audit the `sessionId` the agent passes. A constant value pins requests to one replica set and defeats replica scale-out. | search-post REST reference | High |
| 5 | Instrument for 206 explicitly — inspect the response **body** for `@search.semanticPartialResponseReason`. `ThrottledSearchQueriesPercentage` will never show this. Add an APIM trace/log policy that captures the annotation. | monitor-...-data-reference; search-performance-analysis | High |
| 6 | Reduce the fan-out: consolidate 7 indexes into fewer indexes (use a filterable discriminator field), or query fewer per turn. Cuts the concurrency burst at the source. | Semantic limits are per-request-concurrency | High |
| 7 | Consider agentic retrieval / a knowledge base over multiple knowledge sources instead of 7 parallel connector calls, so the service orchestrates the fan-out internally. | agentic-retrieval docs; agentic retrieval limits | Medium |
| 8 | If explicit control of `semanticErrorHandling` / `semanticMaxWaitInMilliseconds` is required, bypass the built-in connector (custom connector, HTTP action, or an APIM `set-body` policy injecting the fields). | connectors/azureaisearch parameter list | High |
| 9 | Move indexer schedules out of query hours. Indexing and queries share the same resources with no prioritization. | search-capacity-planning; search-performance-analysis | Medium |
| 10 | If sustained concurrency is near/above documented levels, **file a support ticket** — Microsoft explicitly invites this for semantic ranker provisioning and limit increases. | semantic-how-to-query-request; search-limits-quotas-capacity | High |

---

## What Is Still Unproven / Needs Customer Telemetry to Confirm

### U1. `Transient` is not documented as capacity-caused

Microsoft documents `capacityOverloaded` → throttling. It documents `transient` only as "At least one step of the semantic process failed" / "at least one of the queries failed to complete." **No Microsoft source states that `Transient` is caused by tier, replica count, or contention.** The correlation the customer observed is real but the causal link is inferred, not documented.

**Needed:** the full 206 response bodies. Specifically, is there a mix of `Transient` *and* `CapacityOverloaded` in their logs? If `CapacityOverloaded` appears at all, the capacity story is directly proven by Microsoft's own text. If it is exclusively `Transient`, the capacity link remains circumstantial and a support ticket should ask Microsoft what `Transient` maps to internally.

### U2. Who sets `semanticErrorHandling: "partial"`?

The documented default is `fail`, which would produce a hard error, not a 206. The customer gets 206, so `partial` is in effect. The connector does not expose the parameter. Three possibilities, none verified:

1. The connector's backend implementation hardcodes `partial`.
2. The runtime default differs from the documented default (docs stale — note the phrasing "default / **current behavior**" hints this was written when `partial` was newly introduced).
3. Something in the APIM policy chain injects it.

**Needed:** an APIM trace capturing the **outbound request body** to `search.windows.net`. This single artifact resolves it.

### U3. Effective `semanticMaxWaitInMilliseconds` when omitted

No default is published in the REST reference, the swagger (no `default` key), or the TypeSpec. Only `minimum: 700`. If the connector sends a low value (or the service default is low), `maxWaitExceeded` would be the expected reason — but the customer reports `Transient`, which argues against a pure timeout. Still unverified.

**Needed:** same APIM outbound-body trace as U2.

### U4. Contradiction between the two published concurrency figures

- "up to **10 concurrent queries per replica**" (semantic-how-to-query-request)
- "**2** (Basic) / **3** (S1) concurrent requests **per search unit**" + queue (search-limits-quotas-capacity)

These cannot both be literally true for a 1-replica/1-partition service. The limits table is more specific and appears on the canonical limits page (`ms.date: 2026-09-16`); the "10 per replica" line reads as older, softer guidance. **All capacity arithmetic in this document uses the limits table.** If the customer's sizing hinges on the difference, confirm with Microsoft support.

### U5. Semantic ranker free-plan exhaustion

Unknown whether the service is on `free` or `standard`. If `free`, the workload blows the 1,000/month allowance within days and semantic ranking fails for most of each month — for a **completely different reason** (billing error, per docs) than the 206. This would make the tier/replica improvements look partial and erratic. **Must be checked before any further capacity work.** Not yet confirmed either way.

### U6. Whether the documented "billing error" for free-plan exhaustion can surface as 206 `Transient`

The docs say exhausting the free allowance produces "a billing error." They do not say what HTTP shape it takes, and they do not say whether `semanticErrorHandling=partial` also degrades a billing failure into a 206 with `Transient` (which would be entirely consistent with "at least one step of the semantic process failed"). **This is a plausible and untested alternative root cause for the exact symptom.** No Microsoft documentation confirms or denies it.

### U7. How APIM handles 206

Not investigated. APIM could be transforming, buffering, or stripping the response. Since 206 is a 2xx, default policies pass it through — but a `validate-content` policy, response schema validation, or a body transform could mangle the partial payload and contribute to the "empty answer" symptom independently of Azure AI Search.

### U8. Copilot Studio's handling of 206 from the connector

Unknown whether the connector runtime treats 206 as success, and whether it preserves `@search.semanticPartialResponseReason`. The connector's declared return type is a bare `array of Object` — the top-level `@search.*` annotations may be **discarded entirely** before Copilot Studio ever sees them. If so, the customer is only seeing these annotations because they instrumented APIM, and the agent itself is blind to the degradation.

### U9. Service creation date

Determines whether Basic was capped at **1 partition / 3 replicas (3 SU max)** or **3 partitions / 3 replicas (9 SU max)**, and whether the index limit is 5 or 15. Changes the §3.2 arithmetic materially.

**Needed:** service creation date per https://learn.microsoft.com/en-us/azure/search/search-how-to-upgrade

### U10. Regional semantic ranker capacity

The limits table is explicitly "subject to available capacity in the region," and the factor list includes "the total available semantic ranker capacity in the region." This is **not observable by the customer at all** and could account for the residual failures after the S1 move.

### U11. Query rewrite enabled?

If `queryRewrites` (preview) is on, the generative rewrite step is an **additional** failure surface that produces `Transient`, as shown verbatim in the query-rewrite doc. The connector doesn't expose it, but the index/semantic config or connector backend might.

**Needed:** check payloads for `@search.semanticQueryRewriteResultType: "OriginalQueryOnly"`.

### U12. No published Microsoft known-issue

Exhaustive searches across `MicrosoftDocs/azure-ai-docs` (`articles/search/`), the `Azure` GitHub org, and `Azure/azure-sdk-for-net` found **zero** issues, bug reports, or Azure Update bulletins linking 206 `Transient` to tier/replicas/contention. Only generated SDK models, serializers, spec files, and changelog lines. **Absence of a known-issue is not evidence there is no issue** — but it does mean no public Microsoft acknowledgment exists to cite to the customer.

---

## Consolidated Source Index

### Microsoft Learn — Azure AI Search

| Topic | URL |
| --- | --- |
| Service limits, tiers, **semantic ranker throttling limits table**, general throttling limits | https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity |
| Capacity planning, replicas vs partitions, **SLA replica rules**, online scaling, tier change | https://learn.microsoft.com/en-us/azure/search/search-capacity-planning |
| Add semantic ranking, **"Expected workloads"** (10 concurrent/replica, Partial Content + CapacityOverloaded) | https://learn.microsoft.com/en-us/azure/search/semantic-how-to-query-request |
| Semantic ranking overview, L2 pipeline, token limits, top-50 cap, billing scope | https://learn.microsoft.com/en-us/azure/search/semantic-search-overview |
| Query rewrite (preview), **`Transient` prose description**, `OriginalQueryOnly` | https://learn.microsoft.com/en-us/azure/search/semantic-how-to-query-rewrite |
| **Semantic ranker billing plans** (free vs standard), PATCH vs PUT warning | https://learn.microsoft.com/en-us/azure/search/semantic-how-to-enable-disable |
| Performance analysis, **throttling = 503 / 207**, Kusto queries, indexing contention, shard merges | https://learn.microsoft.com/en-us/azure/search/search-performance-analysis |
| Performance tips, **"each progressively higher tier provides faster CPUs and more memory"**, S1→S2 case study | https://learn.microsoft.com/en-us/azure/search/search-performance-tips |
| Pricing model and tier selection, partition size/speed, tier changes | https://learn.microsoft.com/en-us/azure/search/search-sku-tier |
| Monitoring data reference, **`ThrottledSearchQueriesPercentage` semantics** (CPU/mem/IO based), metric list, log schema | https://learn.microsoft.com/en-us/azure/search/monitor-azure-cognitive-search-data-reference |
| Monitor queries, QPS metric, latency, throttled queries, alerting | https://learn.microsoft.com/en-us/azure/search/search-monitor-queries |
| Semantic code migration (`semanticErrorHandling` added in `2023-07-01-preview`) | https://learn.microsoft.com/en-us/azure/search/semantic-code-migration |
| Agentic retrieval — 206 for failed knowledge sources | https://learn.microsoft.com/en-us/azure/search/agentic-retrieval-how-to-retrieve |
| Agentic retrieval migration — 206 if summarization fails | https://learn.microsoft.com/en-us/azure/search/agentic-retrieval-how-to-migrate |
| Check service creation/upgrade date | https://learn.microsoft.com/en-us/azure/search/search-how-to-upgrade |

### Microsoft Learn — REST / SDK / Reliability / Connectors / Pricing

| Topic | URL |
| --- | --- |
| **Documents - Search Post** — `semanticErrorHandling`, `semanticMaxWaitInMilliseconds` (min 700), `SemanticErrorMode`, **`SemanticErrorReason`**, **`SemanticSearchResultsType`**, 200 + **206** samples, `sessionId` | https://learn.microsoft.com/en-us/rest/api/searchservice/documents/search-post |
| .NET SDK `SemanticErrorReason` struct | https://learn.microsoft.com/en-us/dotnet/api/azure.search.documents.models.semanticerrorreason |
| **Reliability in Azure AI Search** — transient faults, ≥2 replicas, zone redundancy, SLA | https://learn.microsoft.com/en-us/azure/reliability/reliability-ai-search |
| **Azure AI Search connector** (`SemanticHybridSearch` params, 200 calls/60s throttle) | https://learn.microsoft.com/en-us/connectors/azureaisearch/ |
| **Pricing** — semantic ranker "First 1k requests free per month, $1 per 1k requests"; per-tier SU pricing | https://azure.microsoft.com/en-us/pricing/details/search/ |
| SLA for Azure AI Search | https://azure.microsoft.com/en-us/support/legal/sla/search/v1_0/ |

### GitHub (spec and SDK source of truth)

| Artifact | Repo → Path |
| --- | --- |
| TypeSpec model: `@minValue(700)`, `@encodedName` for partial-response annotations | `Azure/azure-rest-api-specs` → `specification/search/data-plane/Search/models-index.tsp` |
| Swagger (stable 2025-09-01): `"minimum": 700`, **no `default`**; `SemanticPartialResponseReason` definition | `Azure/azure-rest-api-specs` → `specification/search/data-plane/Search/stable/2025-09-01/searchindex.json` |
| Request sample with `semanticErrorHandling: "partial"` + `semanticMaxWaitInMilliseconds: 5000` | `Azure/azure-rest-api-specs` → `specification/search/data-plane/Search/stable/2025-09-01/examples/SearchIndexSearchDocumentsPost.json` |
| **Wire enum values** `String(maxWaitExceeded/capacityOverloaded/transient)` and `String(baseResults/rerankedResults)` | `Azure/azure-sdk-for-java` → `sdk/search/azure-search-documents/src/main/java/com/azure/search/documents/SearchClient.java` |
| "(default / current behavior)" attached to `fail` | `Azure/azure-sdk-for-net` → `sdk/search/Azure.Search.Documents/src/Options/SearchOptions.cs` |
| `SemanticSearchOptions.ErrorMode` / `MaxWait` public surface | `Azure/azure-sdk-for-net` → `sdk/search/Azure.Search.Documents/src/Options/SemanticSearchOptions.cs` |
| Usage example: `ErrorMode = SemanticErrorMode.Partial`, `MaxWait = TimeSpan.FromMilliseconds(1000)` | `Azure/azure-sdk-for-net` → `sdk/search/Azure.Search.Documents/tests/DocumentOperations/SearchTests.cs` |
| Changelog: "Added support for partial content responses (HTTP 206)" | `Azure/azure-sdk-for-net` → `sdk/search/Azure.Search.Documents/CHANGELOG.md` |
| JSON key constant `@search.semanticPartialResponseReason` | `Azure/azure-sdk-for-net` → `sdk/search/Azure.Search.Documents/src/Utilities/Constants.cs` |
| Python model with known values `"maxWaitExceeded"`, `"capacityOverloaded"`, `"transient"` | `Azure/azure-sdk-for-python` → `sdk/search/azure-search-documents/azure/search/documents/models/_models.py` |
| Docs source for `Transient` prose | `MicrosoftDocs/azure-ai-docs` → `articles/search/semantic-how-to-query-rewrite.md` |
| Docs source for `CapacityOverloaded` / Expected workloads | `MicrosoftDocs/azure-ai-docs` → `articles/search/semantic-how-to-query-request.md` |

---

## Recommended Next Research (not completed in this session)

- [ ] Capture and analyze the **full 206 response bodies** from APIM logs — determine whether `CapacityOverloaded` ever appears alongside `Transient` (resolves U1 decisively).
- [ ] Capture an **APIM outbound request-body trace** to `*.search.windows.net` to see exactly which `semanticErrorHandling` / `semanticMaxWaitInMilliseconds` / `sessionId` values the connector emits (resolves U2, U3, and the sessionId question).
- [ ] Query the Search **management API** for `properties.semanticSearch` and confirm free vs standard plan (resolves U5).
- [ ] Pull `AzureDiagnostics` for `Query.Search` filtered on `resultSignature_d == 206`, correlated by `IndexName_s` and `DurationMs`, to quantify degradation rate per index and test the concurrency-burst hypothesis against wall-clock.
- [ ] Correlate 206 timestamps against **indexer run windows** to test the indexing-contention factor.
- [ ] Determine the search **service creation date** to pin down the true Basic SU ceiling (resolves U9).
- [ ] Investigate whether the Power Platform connector runtime **preserves or strips** the `@search.*` top-level annotations before handing the payload to Copilot Studio (resolves U8).
- [ ] Research **agentic retrieval / knowledge bases** as an architectural replacement for the 7-way client-side fan-out, including its own 206 semantics and tier limits.
- [ ] Review the **APIM policy chain** for response validation/transformation that could mangle a 206 body (resolves U7).
- [ ] Open a **Microsoft support ticket** asking specifically: what internal conditions map to `Transient` (vs `capacityOverloaded`), and what the effective default `semanticMaxWaitInMilliseconds` is.

## Clarifying Questions for the Customer

1. **Are the 206 responses exclusively `Transient`, or does `CapacityOverloaded` also appear?** This single data point determines whether the capacity explanation is documented-proven or inferred.
2. **Is the semantic ranker billing plan `free` or `standard`?** At this fan-out the 1,000/month free allowance is exhausted in days, which is a separate root cause that would masquerade as the same symptom.
3. **What `sessionId` does the agent pass?** A constant or low-cardinality value pins traffic to one replica set and defeats replica scale-out — which would explain why adding replicas helped but did not fully fix it.
4. **When was the search service created?** Pre-2024-04-03 Basic services are capped at 1 partition (3 SU max), which changes the capacity arithmetic materially.
5. **What is the current S1 replica × partition configuration?** Needed to compute actual semantic-ranker in-flight capacity against their peak concurrency.
6. **Do indexers run during business hours against any of the 7 indexes?** Indexing shares the same resources with no prioritization.
7. **Does the APIM policy chain do any response validation or body transformation?** A 206 with a partial body could be mangled independently of Azure AI Search.
8. **Can they capture an APIM trace of the outbound request body to `search.windows.net`?** This resolves the `semanticErrorHandling` / `semanticMaxWaitInMilliseconds` question that the connector documentation cannot.
9. **Is the 7-index fan-out architecturally required,** or could the indexes be consolidated behind a filterable discriminator field? Reducing fan-out attacks the root cause rather than the symptom.
10. **What are the observed peak concurrent user turns** (not users/hour)? Concurrency, not throughput, is the dimension the semantic ranker limits.
