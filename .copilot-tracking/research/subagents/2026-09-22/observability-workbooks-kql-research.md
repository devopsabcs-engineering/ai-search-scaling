<!-- markdownlint-disable-file -->
# Observability Research: Azure AI Search + Copilot Studio + APIM + Functions + ADF

**Research document**: `.copilot-tracking/research/subagents/2026-09-22/observability-workbooks-kql-research.md`
**Date**: 2026-09-22
**Status**: Complete (with explicitly flagged UNVERIFIED items)
**Scope**: Out-of-the-box observability assets, platform metrics, resource-log schemas, ready-to-paste KQL, cross-service workbook design, and alert rules for a Copilot Studio agent fanning out to 7 Azure AI Search indexes through API Management.

---

## Executive Summary (read this first)

| Question | Short answer |
| --- | --- |
| Is there a built-in Azure Monitor **Workbook for Azure AI Search**? | **No.** No workbook ships in the Search blade gallery, and there is no Azure AI Search folder in either `microsoft/Application-Insights-Workbooks` or `microsoft/AzureMonitorCommunity`. Search ships **metrics + one resource-log category**, and the docs point you at "Workbooks / Power BI / Grafana" as things *you* build. |
| Is there a built-in workbook for **Copilot Studio**? | **Yes.** `Copilot Studio Dashboard` ships in the Application Insights **Monitoring > Workbooks** gallery. Source of truth: `microsoft/Application-Insights-Workbooks` → `Workbooks/Copilot Studio/CopilotStudioDashboard.workbook`. |
| Is there a built-in workbook for **APIM**? | **Yes.** `Workbooks/Azure API Management/Analytics` in the same gallery repo (includes a "Language models" tab). |
| Does the Azure AI Search resource log record **HTTP 206**? | The log field `resultSignature_d` is documented as "An HTTP result code", so 206 should surface — but **no Microsoft doc shows a 206 example for Search**, and the `@search.semanticPartialResponseReason` value is **NOT** a documented resource-log property. **Treat 206 detection in logs as UNVERIFIED and validate empirically.** |
| Can you see **which knowledge source** was queried and what it returned? | **Yes, three ways** (Copilot Studio Monitor page "Knowledge source use" card with error %; Dataverse `ConversationTranscript` `search_results` field; environment-level App Insights `dependencies` spans with `gen_ai.tool.call.arguments` / `gen_ai.tool.call.result`). |
| Does the customer's observed span shape match the docs? | **No.** Their sample (`type == "Connector"`, `name == "Azure AI Search"`, `attributes.conversationId`, `spanKind`) does **not** match either documented Copilot Studio telemetry schema. See [Section 3.4](#34-critical-the-customers-observed-span-shape-does-not-match-either-documented-schema). |

---

## 1. Azure AI Search built-in monitoring

### 1.1 Out-of-box visual assets — what actually exists

**Primary doc**: [Monitor your search service — Azure AI Search](https://learn.microsoft.com/en-us/azure/search/monitor-azure-cognitive-search)
**Data reference**: [Monitoring data reference — Azure AI Search](https://learn.microsoft.com/en-us/azure/search/monitor-azure-cognitive-search-data-reference)
**Performance analysis**: [Analyze performance in Azure AI Search](https://learn.microsoft.com/en-us/azure/search/search-performance-analysis)

The Monitor doc lists the visualization tools available, and it is explicit that these are **build-your-own**, not prebuilt for Search:

> Tools that allow more complex visualization include:
> - Dashboards ... - Workbooks, customizable reports that you can create in the Azure portal. Workbooks can include text, metrics, and log queries.
> - Grafana ... - Power BI ...
>
> — <https://learn.microsoft.com/en-us/azure/search/monitor-azure-cognitive-search>

**What the Search blade DOES give you out of the box:**

| Asset | Location | Notes |
| --- | --- | --- |
| Metrics explorer with Search metric namespace | Search service > **Monitoring > Metrics** | All metrics in [1.2](#12-platform-metrics) are available with no configuration. |
| Portal **Overview** monitoring tiles | Search service > **Overview** | Docs state the portal "shows queries per second, throttled queries, and search latency" ([capacity planning](https://learn.microsoft.com/en-us/azure/search/search-capacity-planning)). |
| **Logs** blade (Log Analytics, resource-scoped) | Search service > **Monitoring > Logs** | Requires a diagnostic setting first. |
| Recommended alert rules | Search service > **Monitoring > Alerts** | See [Section 6](#6-alerting-recommendations). |
| **Workbooks** blade | Search service > **Monitoring > Workbooks** | Present as a blade (it is on every Azure resource), but **it contains no Search-specific gallery template** — only generic/empty templates. Verified by the absence of any Search folder in the gallery repo ([Section 5](#5-published-workbook-gallery-templates-and-github-repos)). |

> **Conclusion for the customer**: their request for "native workbook-style dashboards" for Azure AI Search cannot be satisfied by importing a Microsoft-published template — one does not exist. The realistic out-of-box path is: (a) import the **Copilot Studio Dashboard** and **APIM Analytics** workbooks that *do* exist, and (b) build **one** custom workbook for the Search tier using the KQL in [Section 2](#2-ready-to-paste-kql-queries) — which is a ~1-day build, not a platform gap.

### 1.2 Platform metrics

Source: <https://learn.microsoft.com/en-us/azure/search/monitor-azure-cognitive-search-data-reference> (section "Supported metrics for Microsoft.Search/searchServices").

| Metric (REST API name) | Portal display name | Unit | Default aggregation | Dimensions | Grain | DS Export | What it reveals |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `SearchLatency` | Search Latency | Seconds | Average | *none* | PT1M | Yes | Average query duration. Service-wide only — **no index dimension**. |
| `SearchQueriesPerSecond` | Search queries per second | CountPerSecond | Average | *none* | PT1M | Yes | QPS. Min/Max/Avg/Sum all meaningful within a 1-minute bucket. |
| `ThrottledSearchQueriesPercentage` | Throttled search queries percentage | Percent | Average | *none* | PT1M | Yes | **← This is the capacity-pressure metric.** |
| `DocumentsProcessedCount` | Document processed count | Count | Total (Sum), Count | `DataSourceName`, `Failed`, `IndexerName`, `IndexName`, `SkillsetName` | PT1M | Yes | Indexer throughput; `Failed` dimension isolates ingestion failures. |
| `DocumentsProcessedBytes` | Indexer Processed Files (bytes) | Bytes | Total (Sum), Average | `DataSourceName`, `IndexerName`, `IndexName` | PT1M | Yes | Source-data volume from file-based data sources. |
| `SkillExecutionCount` | Skill execution invocation count | Count | Total (Sum), Count | `DataSourceName`, `Failed`, `IndexerName`, `SkillName`, `SkillsetName`, `SkillType` | PT1M | Yes | Enrichment pipeline health. |
| `IndexStorageUsage` | Storage usage | Bytes | Average, Maximum, Minimum | `IndexName` | PT1M | Yes | **Per-index** storage — one of the few index-dimensioned metrics. |
| `IndexVectorUsage` | Vector Storage usage | Bytes | Average, Maximum, Minimum | `IndexName` | PT1M | Yes | Per-index vector footprint. |
| `PerRequestComputeConsumption` | Compute units used | Count (micro-CU-hours) | Total (Sum), Average | `Status`, `IndexName`, `ResourceKind`, `EventType` | PT1M | Yes | Serverless/consumption model. `Status` filter is **deprecated**. Divide total by 1,000,000 for CU-hours. |

#### Which metric reveals capacity pressure

**`ThrottledSearchQueriesPercentage`** is the primary capacity-pressure signal. From the data reference:

> Throttling occurs when the number of requests in execution exceed capacity. You might see an increase in throttled requests when a replica is taken out of rotation or during indexing. Both query and indexing requests are handled by the same set of resources.
> The service determines whether to drop requests based on resource consumption. The percentage of resources consumed across memory, CPU, and disk IO are averaged over a period of time. If this percentage exceeds a threshold, all requests to the index are throttled until the volume of requests is reduced.
>
> — <https://learn.microsoft.com/en-us/azure/search/monitor-azure-cognitive-search-data-reference>

Note for this customer specifically: **"Both query and indexing requests are handled by the same set of resources"** is exactly the mechanism behind their mixed ingestion/query failure picture, and it is also why the customer's ask to *split* ingestion from query dashboards is correct at the presentation layer but must not be split at the *root-cause* layer — the two contend for the same replicas/partitions.

Secondary pressure signals: `SearchLatency` (rising p95 while QPS is flat ⇒ contention), `PerRequestComputeConsumption` (serverless), and `IndexStorageUsage` approaching tier limits.

**Capacity-planning cross-reference** — <https://learn.microsoft.com/en-us/azure/search/search-capacity-planning> lists when to add capacity:

> - Query latency increases or service-level agreement criteria aren't met.
> - The frequency of HTTP 503 (Service unavailable) errors increases.
> - The frequency of HTTP 429 (Too many requests) errors increases, indicating request throttling.
> - Large query volumes are expected.
> - Indexing jobs are slow or falling behind.
>
> Add **replicas** to increase query throughput and availability. Add **partitions** to increase storage and indexing performance.

### 1.3 Resource logs and diagnostic setting categories

**There is exactly ONE resource-log category for Azure AI Search: `OperationLogs`.**

| Category | Log table | Basic log plan | Ingestion-time transform |
| --- | --- | --- | --- |
| `OperationLogs` | **`AzureDiagnostics`** | No | No |

> — <https://learn.microsoft.com/en-us/azure/search/monitor-azure-cognitive-search-data-reference> (section "Supported resource logs for Microsoft.Search/searchServices")

**There is NO dedicated / resource-specific table** (no `SearchQueryLogs`, no `AISearchOperationLogs`). Confirmed twice in the same doc:

> In Azure Monitor, logs are collected in the **AzureDiagnostics** table under the resource provider name of `Microsoft.Search`.
>
> | Category | String | "OperationLogs". This value is a constant. **OperationLogs is the only category used for resource logs.** |

Tables relevant to `Microsoft.Search/searchServices`:

| Table | Content |
| --- | --- |
| `AzureDiagnostics` | Logged query and indexing operations (the `OperationLogs` category). |
| `AzureMetrics` | Platform metrics routed via diagnostic setting (`Send to Log Analytics` + AllMetrics). |
| `AzureActivity` | Control-plane operations (scale replicas/partitions, "Get Admin Key", "Get Query Key"). |

> **Practical implication**: because everything lands in the shared `AzureDiagnostics` table, in a workspace shared across Copilot Studio, Search and Functions you **must** filter by `ResourceProvider == "MICROSOFT.SEARCH"` (or `ResourceType == "SEARCHSERVICES"` / `_ResourceId`) or you will mix APIM, Search and other providers into the same result set. Every query in [Section 2](#2-ready-to-paste-kql-queries) does this.

### 1.4 Resource-log schema — field-by-field

**Top-level (common resource log) schema**, from <https://learn.microsoft.com/en-us/azure/search/monitor-azure-cognitive-search-data-reference>:

| Field | Type | Description / example |
| --- | --- | --- |
| `TimeGenerated` | datetime | `2021-12-07T00:00:43.6872559Z` |
| `Resource` | string | `/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Search/searchServices/<svc>` |
| `Category` | string | Constant `"OperationLogs"` |
| `OperationName` | string | e.g. `Query.Search` |
| `OperationVersion` | string | api-version used, e.g. `2026-04-01` |
| `ResultType` | string | `Success` or `Failure` |
| `ResultSignature` | int | **An HTTP result code.** Example given: `200` |
| `DurationMS` | int | Duration of the operation in milliseconds |
| `Properties` | object | Search-specific payload — see below |

**`Properties` sub-schema (the Search-specific fields):**

| Name | Type | Description / example |
| --- | --- | --- |
| `Description_s` | String | The operation's endpoint. e.g. `GET /indexes('content')/docs` |
| `Documents_d` | Int | **Number of documents processed** (i.e. returned/indexed) |
| `IndexName_s` | String | **Name of the index** associated with the operation |
| `Query_s` | String | **The query parameters used in the request**, e.g. `?search=beach access&$count=true&api-version=2026-04-01` |

> **This directly answers the customer's "the connector is a black box, we cannot see request payloads" pain point for the Search tier**: `Query_s` contains the actual query string, and `IndexName_s` tells you which of the 7 indexes was hit. This is the single highest-value field set in this entire research document for their scenario.

#### Actual KQL column names (as used in Microsoft's own published queries)

The data-reference table above documents the *logical* names; the **Azure Diagnostics dynamic-column names** that you type in KQL are different (they carry type suffixes). These are **VERIFIED** because they appear verbatim in Microsoft's published KQL samples at <https://learn.microsoft.com/en-us/azure/search/search-performance-analysis>:

| KQL column | Verified by | Notes |
| --- | --- | --- |
| `resultSignature_d` | `\| summarize count() by resultSignature_d \| render barchart` | **lowercase `r`, `_d` suffix** — do not write `ResultSignature`. |
| `OperationName` | `\| where OperationName == "Query.Search"` | Fixed AzureDiagnostics column, PascalCase, no suffix. |
| `DurationMs` | `\| project MinuteOfDay, DurationMs, Documents_d, IndexName_s` | **Note casing**: KQL samples use `DurationMs`; the schema table calls it `DurationMS`/`DurationMilliseconds`. Microsoft's own working queries use `DurationMs`. |
| `Documents_d` | `avg(Documents_d)` | |
| `IndexName_s` | `project ... IndexName_s` | |
| `Query_s` | Documented in Properties schema only | ⚠️ Not exercised in a published sample query — see UNVERIFIED list. |
| `Description_s` | Documented in Properties schema only | ⚠️ Not exercised in a published sample query — see UNVERIFIED list. |
| `TimeGenerated` | Used throughout | Standard. |

#### `OperationName` values — the query/index split

From <https://learn.microsoft.com/en-us/azure/search/monitor-azure-cognitive-search-data-reference> ("OperationName values (logged operations)"):

**QUERY-side operations:**

| OperationName | Description |
| --- | --- |
| `Query.Search` | A full-text search request against an index |
| `Query.Suggest` | Type-ahead query against an index |
| `Query.Lookup` | A lookup query against an index |
| `Query.Autocomplete` | An autocomplete query against an index |

**INDEXING / ingestion-side operations:**

| OperationName | Description |
| --- | --- |
| `Indexing.Index` | A call to Index Documents (push indexing) |
| `Indexers.*` | Applies to an indexer — Create, Delete, Get, List, Status |
| `Indexes.*` | Applies to a search index — Create, Delete, Get, List |
| `Skillsets.*` | Applies to a skillset — Create, Delete, Get, List |
| `DataSources.*` | Applies to indexer data sources — Create, Delete, Get, List |
| `DebugSessions.*` | Debug session operations |

**Control / noise operations** (exclude from both dashboards): `ServiceStats`, `Metadata.GetMetadata`, `CORS.Preflight`, `Indexes.ListIndexStatsSummaries`, `Indexes.Stats`, `Indexes.Prototype`, `Indexers.Warmup`.

> The canonical query-operation set used by Microsoft's own performance queries is exactly:
> `OperationName in ("Query.Search", "Query.Suggest", "Query.Lookup", "Query.Autocomplete")`
> — reused in every query-side KQL in [Section 2](#2-ready-to-paste-kql-queries).

### 1.5 CRITICAL — HTTP 206 / semantic partial responses

**What Microsoft documents about the 206 itself**

From [Add semantic ranking — "Expected workloads"](https://learn.microsoft.com/en-us/azure/search/semantic-how-to-query-request):

> For semantic ranking, you should expect a search service to support up to **10 concurrent queries per replica**.
>
> The service throttles semantic ranking requests if volumes are too high. An error message that includes these phrases indicate the service is at capacity for semantic ranking:
>
> ```json
> Error in search query: Operation returned an invalid status 'Partial Content'
> @search.semanticPartialResponseReason
> CapacityOverloaded
> ```
>
> If you anticipate consistent throughput requirements near, at, or higher than this level, please file a support ticket so that we can provision for your workload.

> ### 🔴 This is the smoking gun for the customer's 206s.
> 7 indexes × top-3 docs per user turn = **7 concurrent semantic queries per turn**. The documented semantic-ranker ceiling is **10 concurrent semantic queries per replica**. At ~1.5 concurrent users the agent saturates a single replica's semantic-ranking budget, producing intermittent `206 Partial Content` with `@search.semanticPartialResponseReason: CapacityOverloaded`. The fix is architectural (reduce fan-out / add replicas / file a support ticket for provisioning), not a dashboard — but the dashboard is how you *prove* it and how you set the proactive threshold.

**What is and is not available in the resource log**

| Signal | In Azure AI Search resource logs? | Confidence |
| --- | --- | --- |
| HTTP status code generally | **Yes** — `resultSignature_d` is documented as "An HTTP result code" | **VERIFIED** (field exists and is queried in official samples) |
| Value `206` specifically appearing in `resultSignature_d` | Not shown in any doc example | ⚠️ **UNVERIFIED** — highly likely given the field semantics, but must be validated empirically in the customer's workspace |
| `@search.semanticPartialResponseReason` | **NO** — the documented `Properties` schema is only `Description_s`, `Documents_d`, `IndexName_s`, `Query_s` | **VERIFIED ABSENT** from documented schema |
| `CapacityOverloaded` reason string | **NO** — not a documented log field | **VERIFIED ABSENT** from documented schema |

**Implication / recommended mitigation**: the *reason* for a partial semantic response is only visible in the **response body returned to the caller**, not in Azure Monitor. To get it into a dashboard, the customer must capture it at the **APIM layer**, where `ResponseBody` is available in `ApiManagementGatewayLogs` (see [Section 2h](#2h-apim--apim-generated-errors-vs-backend-errors) and the APIM body-logging caveat). This is the single strongest argument for routing the connector through APIM with response-body sampling enabled.

**Also note the 207 case** (indexing side), from <https://learn.microsoft.com/en-us/azure/search/search-performance-analysis>:

> From the client side, an API call results in a 503 HTTP response when it has been throttled. **During indexing, there's also the possibility of receiving a 207 HTTP response, which indicates that one or more items failed to index. This error is an indicator that the search service is getting close to capacity.**

So for this workload the multi-status codes to watch are: **206 (query-side semantic partial)**, **207 (indexing-side partial failure)**, **429 (throttle)**, **503 (throttle/unavailable)**, **403 (auth/network)**.

### 1.6 What a 403 from Azure AI Search means

The customer reports 613 connector 403s. Azure AI Search returns 403 for authorization or network-policy denial. Relevant documented causes:

- **Key-based auth disabled / wrong key.** The Copilot Studio connection supports four auth types: *Access Key*, *Client Certificate Auth*, *Service principal (Microsoft Entra ID application)*, *Microsoft Entra ID Integrated* — <https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-azure-ai-search>. Microsoft's own recovery guidance in that article says: *"When re-adding Azure AI Search, use **Data sources → Azure AI Search** with **Entra ID authentication**, not API keys."*
- **Private endpoint / VNet policy.** Copilot Studio supports Search behind a private endpoint, but it requires Power Platform VNet support to be configured: <https://learn.microsoft.com/en-us/power-platform/admin/vnet-support-setup-configure>. A missing/partial VNet configuration produces 403 "Public access is disabled" style failures.
- **Broken/duplicate data connection.** Same article: *"If you create an unsupported Azure AI Search connection, Copilot Studio might store a faulty data connection... Because data connections are managed at the environment level, this issue can affect all agents."*

> **Diagnostic split to build into the dashboard**: a 403 seen in `AzureDiagnostics` (`resultSignature_d == 403`) means the request **reached** Search and was rejected — an auth/RBAC/network-policy problem. A 403 seen in the Copilot Studio connector span or APIM log with **no matching** Search-side record means the request never reached Search — a connector/APIM/gateway problem. Query [Q2](#2b-azure-ai-search-queries-by-http-result-code-isolating-206-and-403) plus [Q8](#2h-apim--apim-generated-errors-vs-backend-errors) together give you that split.

---

## 2. Ready-to-paste KQL queries

**Conventions used in every query below**

- Data source is stated above each block.
- Search queries filter `ResourceProvider == "MICROSOFT.SEARCH"` so they are safe in a **shared** Log Analytics workspace (which this customer has).
- Unverified field names are marked inline with `// UNVERIFIED`.
- Time ranges use `ago()` so they work standalone; in a workbook, replace with `{TimeRange}`.

---

### 2a. Azure AI Search query volume per index over time (proves the 7× fan-out)

**Runs against**: `AzureDiagnostics` (Log Analytics workspace receiving the Search `OperationLogs` diagnostic category).
**Field verification**: `OperationName`, `IndexName_s`, `TimeGenerated` — VERIFIED (all three appear in Microsoft's published samples at <https://learn.microsoft.com/en-us/azure/search/search-performance-analysis>).

```kusto
// Q1-SearchVolumeByIndex
// Proves the 7x fan-out: one user turn should produce ~1 Query.Search per index.
AzureDiagnostics
| where TimeGenerated > ago(24h)
| where ResourceProvider == "MICROSOFT.SEARCH"
| where OperationName in ("Query.Search", "Query.Suggest", "Query.Lookup", "Query.Autocomplete")
| summarize Queries = count() by IndexName_s, bin(TimeGenerated, 5m)
| render timechart
```

**Fan-out ratio variant** — this is the one to put on the dashboard, because it turns "we think it fans out 7×" into a number:

```kusto
// Q1b-FanOutRatio
// Total query volume vs. distinct indexes hit, per minute.
// FanOutFactor ~= 7 confirms every turn hits all 7 indexes.
AzureDiagnostics
| where TimeGenerated > ago(24h)
| where ResourceProvider == "MICROSOFT.SEARCH"
| where OperationName == "Query.Search"
| summarize
    TotalQueries      = count(),
    DistinctIndexes   = dcount(IndexName_s),
    QueriesPerIndex   = round(count() * 1.0 / todouble(dcount(IndexName_s)), 2)
    by bin(TimeGenerated, 1m)
| extend FanOutFactor = TotalQueries / QueriesPerIndex
| project TimeGenerated, TotalQueries, DistinctIndexes, QueriesPerIndex, FanOutFactor
| render timechart with (ytitle = "Queries / Indexes")
```

**Per-index breakdown table** (grid visualization, shows which index is the outlier):

```kusto
// Q1c-PerIndexProfile
AzureDiagnostics
| where TimeGenerated > ago(24h)
| where ResourceProvider == "MICROSOFT.SEARCH"
| where OperationName == "Query.Search"
| summarize
    Queries        = count(),
    AvgDurationMs  = round(avg(DurationMs), 1),
    P95DurationMs  = round(percentile(DurationMs, 95), 1),
    AvgDocsReturned= round(avg(Documents_d), 2),
    Failures       = countif(ResultType == "Failure")
    by IndexName_s
| extend FailurePct = round(100.0 * Failures / Queries, 2)
| order by Queries desc
```

---

### 2b. Azure AI Search queries by HTTP result code (isolating 206 and 403)

**Runs against**: `AzureDiagnostics`.
**Field verification**: `resultSignature_d` — **VERIFIED**; it is used verbatim in Microsoft's published query:
`AzureDiagnostics | where TimeGenerated > ago(7d) | summarize count() by resultSignature_d | render barchart`
(<https://learn.microsoft.com/en-us/azure/search/search-performance-analysis>)
⚠️ **The presence of the value `206` in this column is UNVERIFIED** (see [1.5](#15-critical--http-206--semantic-partial-responses)).

```kusto
// Q2-SearchByHttpResultCode
// Query-side HTTP outcome distribution over time, with 206 / 403 broken out.
AzureDiagnostics
| where TimeGenerated > ago(24h)
| where ResourceProvider == "MICROSOFT.SEARCH"
| where OperationName in ("Query.Search", "Query.Suggest", "Query.Lookup", "Query.Autocomplete")
| extend StatusCode = toint(resultSignature_d)
| extend StatusBucket = case(
      StatusCode == 200, "200 OK",
      StatusCode == 206, "206 Partial Content (semantic capacity)",   // UNVERIFIED that 206 is emitted here
      StatusCode == 403, "403 Forbidden (auth / network policy)",
      StatusCode == 404, "404 Not Found",
      StatusCode == 429, "429 Too Many Requests (throttle)",
      StatusCode == 503, "503 Service Unavailable (throttle)",
      StatusCode >= 500, strcat(tostring(StatusCode), " Server Error"),
      StatusCode >= 400, strcat(tostring(StatusCode), " Client Error"),
      strcat(tostring(StatusCode), " Other"))
| summarize Requests = count() by StatusBucket, bin(TimeGenerated, 5m)
| render timechart
```

**Summary/KPI variant** (tiles at the top of the workbook):

```kusto
// Q2b-SearchStatusKpi
AzureDiagnostics
| where TimeGenerated > ago(24h)
| where ResourceProvider == "MICROSOFT.SEARCH"
| where OperationName in ("Query.Search", "Query.Suggest", "Query.Lookup", "Query.Autocomplete")
| extend StatusCode = toint(resultSignature_d)
| summarize
    Total        = count(),
    Ok200        = countif(StatusCode == 200),
    Partial206   = countif(StatusCode == 206),   // UNVERIFIED
    Forbidden403 = countif(StatusCode == 403),
    Throttled429 = countif(StatusCode == 429),
    Unavail503   = countif(StatusCode == 503)
| extend
    Partial206Pct   = round(100.0 * Partial206   / Total, 3),
    Forbidden403Pct = round(100.0 * Forbidden403 / Total, 3),
    ThrottlePct     = round(100.0 * (Throttled429 + Unavail503) / Total, 3)
```

**206 / 403 drill-down with payload** — this is the query that ends the "black box" complaint, because it shows the actual query string and index for each failure:

```kusto
// Q2c-FailureDrilldownWithPayload
// NOTE: Query_s and Description_s are documented in the Properties schema but are
// NOT exercised in any Microsoft sample query -> treat column names as UNVERIFIED.
AzureDiagnostics
| where TimeGenerated > ago(24h)
| where ResourceProvider == "MICROSOFT.SEARCH"
| where OperationName in ("Query.Search", "Query.Suggest", "Query.Lookup", "Query.Autocomplete")
| extend StatusCode = toint(resultSignature_d)
| where StatusCode in (206, 403, 429, 503)        // 206 emission UNVERIFIED
| project
    TimeGenerated,
    StatusCode,
    IndexName_s,
    OperationName,
    DurationMs,
    DocumentsReturned = Documents_d,
    QueryString       = column_ifexists("Query_s", ""),        // UNVERIFIED column name
    Endpoint          = column_ifexists("Description_s", ""),  // UNVERIFIED column name
    ApiVersion        = column_ifexists("OperationVersion", ""),
    ResultType
| order by TimeGenerated desc
| take 200
```

> `column_ifexists()` is used deliberately so the query degrades gracefully instead of erroring if the column name differs in the customer's workspace — this is Microsoft's own recommended workbook-robustness pattern (<https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-create-workbook>, "Protect against missing columns").

**Schema-discovery query — RUN THIS FIRST in the customer's workspace** to resolve every UNVERIFIED column name empirically:

```kusto
// Q0-DiscoverSearchLogSchema
// Run once. Confirms the exact column names AND whether 206 ever appears.
AzureDiagnostics
| where TimeGenerated > ago(7d)
| where ResourceProvider == "MICROSOFT.SEARCH"
| getschema
| project ColumnName, ColumnType
| order by ColumnName asc
```

```kusto
// Q0b-DoesSearchEmit206
// Definitive empirical answer to the 206-in-logs question.
AzureDiagnostics
| where TimeGenerated > ago(7d)
| where ResourceProvider == "MICROSOFT.SEARCH"
| summarize Count = count(), FirstSeen = min(TimeGenerated), LastSeen = max(TimeGenerated)
    by StatusCode = toint(resultSignature_d), OperationName
| order by Count desc
```

---

### 2c. p50 / p95 / p99 search latency per index

**Runs against**: `AzureDiagnostics`.
**Field verification**: `DurationMs` — **VERIFIED** (`project MinuteOfDay, DurationMs, Documents_d, IndexName_s` and `avgif(DurationMs, OperationName in (...))` both appear at <https://learn.microsoft.com/en-us/azure/search/search-performance-analysis>).

> **Why this beats the `SearchLatency` metric**: the `SearchLatency` platform metric has **no dimensions** (`<none>`) and only supports `Average` — it cannot be split by index and cannot give percentiles. The resource log is the *only* way to get p95/p99 **per index**, which is exactly what is needed to find which of the 7 indexes is the slow one.

```kusto
// Q3-SearchLatencyPercentilesPerIndex
AzureDiagnostics
| where TimeGenerated > ago(24h)
| where ResourceProvider == "MICROSOFT.SEARCH"
| where OperationName in ("Query.Search", "Query.Suggest", "Query.Lookup", "Query.Autocomplete")
| summarize
    Queries = count(),
    p50 = round(percentile(DurationMs, 50), 1),
    p95 = round(percentile(DurationMs, 95), 1),
    p99 = round(percentile(DurationMs, 99), 1),
    Max = max(DurationMs)
    by IndexName_s
| order by p95 desc
```

**Time-series version** (p95 per index over time — the proactive-monitoring chart):

```kusto
// Q3b-SearchLatencyP95Trend
AzureDiagnostics
| where TimeGenerated > ago(24h)
| where ResourceProvider == "MICROSOFT.SEARCH"
| where OperationName in ("Query.Search", "Query.Suggest", "Query.Lookup", "Query.Autocomplete")
| summarize p95 = percentile(DurationMs, 95) by IndexName_s, bin(TimeGenerated, 5m)
| render timechart with (ytitle = "p95 latency (ms)")
```

**Service-wide percentile band** (single chart, all three percentiles):

```kusto
// Q3c-SearchLatencyBand
AzureDiagnostics
| where TimeGenerated > ago(24h)
| where ResourceProvider == "MICROSOFT.SEARCH"
| where OperationName in ("Query.Search", "Query.Suggest", "Query.Lookup", "Query.Autocomplete")
| summarize
    p50 = percentile(DurationMs, 50),
    p95 = percentile(DurationMs, 95),
    p99 = percentile(DurationMs, 99)
    by bin(TimeGenerated, 5m)
| render timechart with (ytitle = "Latency (ms)")
```

---

### 2d. Throttled query percentage over time

There are **two** valid sources. Use both — the metric is authoritative, the log is diagnosable.

#### 2d-i. From the platform metric (authoritative)

**Runs against**: `AzureMetrics` (requires the diagnostic setting to also route **AllMetrics** to Log Analytics — `ThrottledSearchQueriesPercentage` has `DS Export = Yes`).
**Field verification**: `AzureMetrics` columns `MetricName`, `Average`, `Total`, `Count`, `Maximum`, `Minimum` — VERIFIED via Microsoft's sample `AzureMetrics | project MetricName, Total, Count, Maximum, Minimum, Average` at <https://learn.microsoft.com/en-us/azure/search/monitor-azure-cognitive-search>.

```kusto
// Q4-ThrottledQueryPercentFromMetric
AzureMetrics
| where TimeGenerated > ago(24h)
| where ResourceProvider == "MICROSOFT.SEARCH"
| where MetricName == "ThrottledSearchQueriesPercentage"
| summarize ThrottledPct = avg(Average) by bin(TimeGenerated, 5m)
| render timechart with (ytitle = "Throttled search queries %")
```

> Per the data reference: *"For Throttled Search Queries Percentage, minimum, maximum, average and total, all have the same value: the percentage of search queries that were throttled, from the total number of search queries during one minute."* So `avg(Average)` is correct and any aggregation gives the same answer.

**Throttle % overlaid with QPS and latency** — the "is it capacity?" chart:

```kusto
// Q4b-CapacityPressureTriplet
AzureMetrics
| where TimeGenerated > ago(24h)
| where ResourceProvider == "MICROSOFT.SEARCH"
| where MetricName in ("ThrottledSearchQueriesPercentage", "SearchQueriesPerSecond", "SearchLatency")
| summarize Value = avg(Average) by MetricName, bin(TimeGenerated, 5m)
| evaluate pivot(MetricName, any(Value))
| render timechart
```

#### 2d-ii. From the resource log (diagnosable — tells you *which index*)

Microsoft's own published throttling query (<https://learn.microsoft.com/en-us/azure/search/search-performance-analysis>) is reproduced and hardened below. Note Microsoft's original uses **503** as the throttle signal; the capacity-planning doc additionally names **429**, so this version counts both.

```kusto
// Q4c-ThrottledQueriesPerMinuteFromLogs
// Derived from the Microsoft sample at search-performance-analysis,
// extended to also count 429 (per search-capacity-planning) and to split by index.
let intervalsize = 1m;
AzureDiagnostics
| where TimeGenerated > ago(24h)
| where ResourceProvider == "MICROSOFT.SEARCH"
| where OperationName in ("Query.Search", "Query.Suggest", "Query.Lookup", "Query.Autocomplete")
| extend StatusCode = toint(resultSignature_d)
| summarize
    TotalQueries     = count(),
    ThrottledQueries = countif(StatusCode in (429, 503))
    by IndexName_s, bin(TimeGenerated, intervalsize)
| extend ThrottledPct = round(100.0 * ThrottledQueries / TotalQueries, 2)
| project TimeGenerated, IndexName_s, ThrottledPct
| render timechart with (ytitle = "Throttled %")
```

---

### 2e. Separating INDEXING/ingestion operations from QUERY operations

**Runs against**: `AzureDiagnostics`.
**Field verification**: the operation-name split is VERIFIED — Microsoft's own samples use `countif(OperationName == "Indexing.Index")` for the indexing rate and `countif(OperationName in ("Query.Search", ...))` for the query rate, side by side, precisely to correlate them (<https://learn.microsoft.com/en-us/azure/search/search-performance-analysis>, section "Impact of indexing on queries").

> **This is the customer's explicit ask** ("ingestion failures and query failures are mixed together in the same dashboards"). The pattern below gives them one classifier column they can reuse on every tile, rather than maintaining two separate dashboards that then can't be correlated.

```kusto
// Q5-IngestionVsQuerySplit
// Single classifier column -> reuse as a workbook parameter/filter on every tile.
AzureDiagnostics
| where TimeGenerated > ago(24h)
| where ResourceProvider == "MICROSOFT.SEARCH"
| extend Workload = case(
      OperationName startswith "Query.",                                        "Query",
      OperationName == "Indexing.Index",                                        "Ingestion (push)",
      OperationName startswith "Indexers.",                                     "Ingestion (indexer)",
      OperationName startswith "Skillsets.",                                    "Ingestion (enrichment)",
      OperationName startswith "DataSources.",                                  "Ingestion (data source)",
      OperationName startswith "Indexes.",                                      "Index management",
      OperationName startswith "DebugSessions.",                                "Debug",
      OperationName in ("ServiceStats", "Metadata.GetMetadata", "CORS.Preflight"), "Control / noise",
      "Other")
| where Workload !in ("Control / noise", "Debug")
| extend StatusCode = toint(resultSignature_d)
| summarize
    Operations = count(),
    Failures   = countif(ResultType == "Failure"),
    p95Ms      = round(percentile(DurationMs, 95), 1)
    by Workload, bin(TimeGenerated, 5m)
| render timechart
```

**Side-by-side failure comparison** (answers "are these the same incident?"):

```kusto
// Q5b-IngestionVsQueryFailureCorrelation
let win = 5m;
let Search =
    AzureDiagnostics
    | where TimeGenerated > ago(24h)
    | where ResourceProvider == "MICROSOFT.SEARCH"
    | extend StatusCode = toint(resultSignature_d)
    | extend Workload = iff(OperationName startswith "Query.", "Query",
                        iff(OperationName == "Indexing.Index" or OperationName startswith "Indexers.", "Ingestion", "Other"))
    | where Workload != "Other";
Search
| summarize
    QueryOps          = countif(Workload == "Query"),
    QueryFailures     = countif(Workload == "Query"     and ResultType == "Failure"),
    QueryP95Ms        = percentile(iff(Workload == "Query", DurationMs, real(null)), 95),
    IngestionOps      = countif(Workload == "Ingestion"),
    IngestionFailures = countif(Workload == "Ingestion" and ResultType == "Failure"),
    Throttled         = countif(StatusCode in (429, 503))
    by bin(TimeGenerated, win)
| extend
    QueryFailurePct     = round(100.0 * QueryFailures     / iff(QueryOps     == 0, 1, QueryOps), 2),
    IngestionFailurePct = round(100.0 * IngestionFailures / iff(IngestionOps == 0, 1, IngestionOps), 2)
| project TimeGenerated, QueryOps, QueryFailurePct, QueryP95Ms, IngestionOps, IngestionFailurePct, Throttled
| render timechart
```

**Indexing operations per minute** (Microsoft's own pattern, verbatim structure — the chart that proves "indexing caused the latency spike"):

```kusto
// Q5c-IndexingOperationsPerMinute
// Structure taken from the Microsoft sample "Indexing Operations Per Minute (OPM)".
let intervalsize = 1m;
AzureDiagnostics
| where TimeGenerated > ago(24h)
| where ResourceProvider == "MICROSOFT.SEARCH"
| summarize
    IndexingOperationsPerMinute = bin(countif(OperationName == "Indexing.Index") / (intervalsize / 1m), 0.01),
    QueriesPerMinute            = bin(countif(OperationName in ("Query.Search","Query.Suggest","Query.Lookup","Query.Autocomplete")) / (intervalsize / 1m), 0.01),
    AvgQueryLatencyMs           = avgif(DurationMs, OperationName in ("Query.Search","Query.Suggest","Query.Lookup","Query.Autocomplete"))
    by bin(TimeGenerated, intervalsize)
| render timechart
```

> Microsoft's documented interpretation of this chart: *"it took about 3 minutes for the search service to become busy enough for indexing to affect query latency... after indexing completed, it took another 3 minutes for the search service to complete all the work from the newly indexed content, and for query latency to resolve."* Build a **±5 minute** correlation window into any alert that tries to attribute query degradation to ingestion.

---

### 2f. App Insights — Copilot Studio connector dependency failures

**Runs against**: Application Insights `dependencies` table.

> ⚠️ **Read [Section 3.4](#34-critical-the-customers-observed-span-shape-does-not-match-either-documented-schema) before using these.** The customer's sample record (`type == "Connector"`, `name == "Azure AI Search"`, `attributes.conversationId`, `attributes.channelId`, `spanKind`) does **not** match either documented Copilot Studio schema. Two variants are therefore provided: **(A)** matching the customer's observed shape (UNVERIFIED against docs), and **(B)** matching Microsoft's documented environment-level schema (VERIFIED). Run the discovery query first, then keep whichever variant returns rows.

#### Discovery first — resolve the schema empirically

**Field verification**: both discovery queries below are **Microsoft-published verbatim** at <https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-environment-level-agent-telemetry> ("Discover the current schema").

```kusto
// Q6-0a-DiscoverDependencyColumns  (Microsoft-published)
dependencies
| getschema
| project ColumnName, ColumnType
| order by ColumnName asc
```

```kusto
// Q6-0b-DiscoverCustomDimensionKeys  (Microsoft-published)
// Live source of truth for available attributes. Confirms whether the customer's
// environment emits gen_ai.* keys or attributes.* keys.
dependencies
| where timestamp > ago(7d)
| mv-expand Key = bag_keys(customDimensions) to typeof(string)
| summarize Events = make_set(name), SampleValue = take_any(tostring(customDimensions[Key])) by Key
| order by Key asc
```

```kusto
// Q6-0c-DiscoverDependencyTypes
// What distinct (type, name, target) triples exist? Tells you immediately whether
// "Connector" / "Azure AI Search" or "GenAI" / "ExecuteTool" is the live shape.
dependencies
| where timestamp > ago(7d)
| summarize
    Calls     = count(),
    Failures  = countif(success == false),
    SampleRc  = take_any(resultCode),
    FirstSeen = min(timestamp),
    LastSeen  = max(timestamp)
    by type, name, target
| order by Calls desc
```

#### Variant A — matching the customer's observed record shape

**Field verification**: ⚠️ **ALL of `type == "Connector"`, `name == "Azure AI Search"`, `attributes.conversationId`, `attributes.channelId`, `spanKind` are UNVERIFIED** — they do not appear in any Microsoft documentation located during this research. They are taken solely from the customer's sample record. `name`, `duration`, `success`, `resultCode`, `target`, `type` are standard App Insights `dependencies` columns and are safe; `spanKind` is **not** a standard column (likely a `customDimensions` key).

```kusto
// Q6A-ConnectorDependencyFailures  (customer-observed shape -- UNVERIFIED)
dependencies
| where timestamp > ago(24h)
| where type == "Connector"                  // UNVERIFIED
| where name == "Azure AI Search"            // UNVERIFIED
| extend
    ConversationId = tostring(customDimensions["attributes.conversationId"]),  // UNVERIFIED
    ChannelId      = tostring(customDimensions["attributes.channelId"]),       // UNVERIFIED
    SpanKind       = tostring(customDimensions["spanKind"])                    // UNVERIFIED
| summarize
    Calls          = count(),
    Failures       = countif(success == false),
    Conversations  = dcount(ConversationId),
    AvgDurationMs  = round(avg(duration), 1),
    P95DurationMs  = round(percentile(duration, 95), 1)
    by resultCode, target, bin(timestamp, 5m)
| extend FailurePct = round(100.0 * Failures / Calls, 2)
| order by timestamp desc
```

**Time chart by resultCode** (the 403-rate chart the customer asked for):

```kusto
// Q6A-b-ConnectorResultCodeTimechart  (customer-observed shape -- UNVERIFIED)
dependencies
| where timestamp > ago(24h)
| where type == "Connector"                  // UNVERIFIED
| where name == "Azure AI Search"            // UNVERIFIED
| extend ResultBucket = case(
      resultCode == "200" or toupper(resultCode) == "OK", "Success",
      resultCode == "206", "206 Partial Content",
      resultCode == "403", "403 Forbidden",
      resultCode == "429", "429 Throttled",
      resultCode == "503", "503 Unavailable",
      isempty(resultCode), "(empty)",
      strcat(resultCode, " Other"))
| summarize Calls = count() by ResultBucket, bin(timestamp, 5m)
| render timechart with (title = "Copilot Studio -> Azure AI Search connector calls by result code")
```

**Grouped by resultCode AND target** (grid, for the 403 investigation):

```kusto
// Q6A-c-ConnectorFailuresByTarget  (customer-observed shape -- UNVERIFIED)
dependencies
| where timestamp > ago(24h)
| where type == "Connector"                  // UNVERIFIED
| where name == "Azure AI Search"            // UNVERIFIED
| where success == false
| extend
    ConversationId = tostring(customDimensions["attributes.conversationId"]),  // UNVERIFIED
    ChannelId      = tostring(customDimensions["attributes.channelId"])        // UNVERIFIED
| summarize
    Failures              = count(),
    DistinctConversations = dcount(ConversationId),
    Channels              = make_set(ChannelId, 10),
    FirstSeen             = min(timestamp),
    LastSeen              = max(timestamp),
    SampleOperationId     = take_any(operation_Id)
    by resultCode, target
| order by Failures desc
```

#### Variant B — matching Microsoft's documented environment-level schema

**Field verification**: **VERIFIED** against <https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-environment-level-agent-telemetry>. Documented values: `name` ∈ {`InvokeAgent`, `ExecuteTool`, `OutputMessages`}; `type` = `GenAI`; `target` = `GenAI`; `resultCode` ∈ {`OK`, `ERROR`}; `itemType` = `dependency`. `customDimensions` keys documented: `gen_ai.conversation.id`, `gen_ai.agent.name`, `gen_ai.agent.id`, `gen_ai.tool.name`, `gen_ai.tool.type`, `gen_ai.tool.call.id`, `gen_ai.tool.call.arguments`, `gen_ai.tool.call.result`, `gen_ai.operation.name`, `gen_ai.request.model`, `error.type`, `Status.code`, `Status.message`, `microsoft.channel.name`, `env.id`, `microsoft.tenant.id`, `user.id`, `user.email`, `user.name`.

```kusto
// Q6B-ToolExecutionFailures  (documented environment-level schema -- VERIFIED)
dependencies
| where timestamp > ago(24h)
| where name == "ExecuteTool"
| extend
    ToolName       = tostring(customDimensions["gen_ai.tool.name"]),
    ToolType       = tostring(customDimensions["gen_ai.tool.type"]),
    ConversationId = tostring(customDimensions["gen_ai.conversation.id"]),
    AgentName      = tostring(customDimensions["gen_ai.agent.name"]),
    ChannelName    = tostring(customDimensions["microsoft.channel.name"]),
    ErrorType      = tostring(customDimensions["error.type"]),
    StatusCode     = tostring(customDimensions["Status.code"]),
    StatusMessage  = tostring(customDimensions["Status.message"])
| where ToolName has "search" or ToolType has "Search" or ToolName has "azureaisearch"
| summarize
    Calls          = count(),
    Failures       = countif(resultCode == "ERROR" or success == false),
    Conversations  = dcount(ConversationId),
    P95DurationMs  = round(percentile(duration, 95), 1),
    ErrorTypes     = make_set(ErrorType, 10)
    by ToolName, ToolType, resultCode, bin(timestamp, 5m)
| extend FailurePct = round(100.0 * Failures / Calls, 2)
| render timechart
```

**Full tool payload inspection — this is the direct answer to "we cannot see request payloads":**

```kusto
// Q6B-b-ToolPayloadInspection  (documented schema -- VERIFIED)
// gen_ai.tool.call.arguments / .result require "Log conversation details" to be ON.
dependencies
| where timestamp > ago(24h)
| where name == "ExecuteTool"
| extend
    ToolName       = tostring(customDimensions["gen_ai.tool.name"]),
    ConversationId = tostring(customDimensions["gen_ai.conversation.id"]),
    ToolArguments  = tostring(customDimensions["gen_ai.tool.call.arguments"]),
    ToolResult     = tostring(customDimensions["gen_ai.tool.call.result"]),
    ErrorType      = tostring(customDimensions["error.type"]),
    StatusMessage  = tostring(customDimensions["Status.message"])
| where resultCode == "ERROR" or success == false
| project timestamp, ConversationId, ToolName, resultCode, ErrorType, StatusMessage, ToolArguments, ToolResult, operation_Id, id
| order by timestamp desc
| take 100
```

> **Prerequisite** — per <https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-bot-framework-composer-capture-telemetry>: *"**Log conversation details**: Includes user ID, user name, and message text (for Message activities). **When OpenTelemetry tracing is enabled, this setting also controls tool input arguments and tool output results captured in spans.**"* Without this toggle, `gen_ai.tool.call.arguments` and `gen_ai.tool.call.result` are empty — and the customer's "black box" complaint stands. **Turning this on is probably the single highest-impact configuration change in this whole engagement.** Note the privacy/DLP review it implies.

#### Excluding test traffic (`DesignMode`)

**Field verification**: **VERIFIED** — Microsoft-published query at <https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-bot-framework-composer-capture-telemetry>.

```kusto
// Q6C-ExcludeDesignModeTraffic  (Microsoft-published pattern)
// Agent-level telemetry writes to customEvents, and every event carries designMode.
customEvents
| where timestamp > ago(24h)
| extend isDesignMode = customDimensions['designMode']
| where isDesignMode == "False"        // "False" = real production traffic; "True" = Copilot Studio test canvas
| summarize Events = count() by name, bin(timestamp, 5m)
| render timechart
```

> `designMode` semantics, from the documented Custom Dimensions table: **`designMode` = "Conversation happened within the test canvas", values `True` / `False`.** So `designMode == "True"` is a maker testing in the Copilot Studio authoring test pane, and `"False"` is real channel traffic. **Every production KPI and every alert must filter `designMode == "False"`**, otherwise maker testing inflates volume and error rates.
>
> On the environment-level (`dependencies`) side there is **no documented `designMode` key**; the closest documented equivalent is `microsoft.channel.name`, which takes the value `Copilot Studio Test Pane` for test traffic. Filter with `where tostring(customDimensions["microsoft.channel.name"]) != "Copilot Studio Test Pane"`. ⚠️ Treat that exact string match as **UNVERIFIED as an exhaustive test-traffic filter** — it is documented as a sample value, not as a guaranteed enum.

---

### 2g. App Insights — correlate a failing conversation across its dependency spans

**Runs against**: Application Insights `dependencies`.
**Field verification**: **VERIFIED** — the trace/span model and the ordering idiom below are Microsoft-published at <https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-environment-level-agent-telemetry>:

> - Each agent turn is its own **trace**, identified by a shared `operation_Id`.
> - The `InvokeAgent` span is the **root** of its turn's trace. Its `ExecuteTool` and connected `OutputMessages` spans nest beneath it, each carrying `operation_ParentId` = the `InvokeAgent` span's `id`.
> - A conversation spans **multiple turns**, each emitted as a separate trace. **Group or filter by `gen_ai.conversation.id`** to thread the turns of one conversation back together.

```kusto
// Q7-ConversationFullTrace  (Microsoft-published query, lightly annotated)
// Find the conversation ID in the agent with: /debug conversationid
let LatestConvo = "<Conversation ID>";
dependencies
| where tostring(customDimensions["gen_ai.conversation.id"]) == LatestConvo
| order by operation_Id asc, iff(name == "InvokeAgent", 0, 1) asc, timestamp asc
| project timestamp, name, id, operation_Id,
          operation_ParentId, duration, target, type, cloud_RoleName,
          resultCode, customDimensions
```

**Find the worst recent conversations first, then drill in** (the practical entry point — the customer will not have a conversation ID to hand):

```kusto
// Q7b-WorstConversationsThenDrill
let Window = 24h;
let WorstConvos =
    dependencies
    | where timestamp > ago(Window)
    | extend ConversationId = tostring(customDimensions["gen_ai.conversation.id"])
    | where isnotempty(ConversationId)
    | summarize
        Spans      = count(),
        Failures   = countif(resultCode == "ERROR" or success == false),
        Turns      = dcount(operation_Id),
        TotalMs    = sum(duration),
        LastSeen   = max(timestamp)
        by ConversationId
    | where Failures > 0
    | order by Failures desc, TotalMs desc
    | take 20;
WorstConvos
```

```kusto
// Q7c-DrillOneConversationFlattened
// Same trace as Q7 but with the gen_ai.* keys flattened into columns.
let TargetConvo = "<paste ConversationId from Q7b>";
dependencies
| where timestamp > ago(7d)
| extend ConversationId = tostring(customDimensions["gen_ai.conversation.id"])
| where ConversationId == TargetConvo
| extend
    OperationName = tostring(customDimensions["gen_ai.operation.name"]),
    AgentName     = tostring(customDimensions["gen_ai.agent.name"]),
    Model         = tostring(customDimensions["gen_ai.request.model"]),
    ToolName      = tostring(customDimensions["gen_ai.tool.name"]),
    ToolType      = tostring(customDimensions["gen_ai.tool.type"]),
    ToolCallId    = tostring(customDimensions["gen_ai.tool.call.id"]),
    ToolArguments = tostring(customDimensions["gen_ai.tool.call.arguments"]),
    ToolResult    = tostring(customDimensions["gen_ai.tool.call.result"]),
    ErrorType     = tostring(customDimensions["error.type"]),
    StatusMessage = tostring(customDimensions["Status.message"]),
    ChannelName   = tostring(customDimensions["microsoft.channel.name"])
| extend
    InputMessages  = parse_json(tostring(customDimensions["gen_ai.input.messages"])),
    OutputMessages = parse_json(tostring(customDimensions["gen_ai.output.messages"]))
| extend
    UserInput   = tostring(InputMessages[0].parts[0].content),
    AgentOutput = tostring(OutputMessages[0].parts[0].content)
| order by operation_Id asc, iff(name == "InvokeAgent", 0, 1) asc, timestamp asc
| project timestamp, name, OperationName, id, operation_Id, operation_ParentId,
          duration, resultCode, ErrorType, StatusMessage,
          ToolName, ToolType, ToolCallId, ToolArguments, ToolResult,
          UserInput, AgentOutput, AgentName, Model, ChannelName
```

**Fan-out proof from the agent side** — counts tool calls per turn, which should equal 7:

```kusto
// Q7d-ToolCallsPerTurn
// Each operation_Id == one agent turn. ToolCalls should be ~7 for this customer.
dependencies
| where timestamp > ago(24h)
| extend ConversationId = tostring(customDimensions["gen_ai.conversation.id"])
| where isnotempty(ConversationId)
| summarize
    ToolCalls      = countif(name == "ExecuteTool"),
    FailedTools    = countif(name == "ExecuteTool" and (resultCode == "ERROR" or success == false)),
    DistinctTools  = dcountif(tostring(customDimensions["gen_ai.tool.name"]), name == "ExecuteTool"),
    TurnDurationMs = sum(duration)
    by operation_Id, ConversationId, bin(timestamp, 1h)
| summarize
    Turns               = count(),
    AvgToolCallsPerTurn = round(avg(ToolCalls), 2),
    MaxToolCallsPerTurn = max(ToolCalls),
    AvgFailedPerTurn    = round(avg(FailedTools), 2),
    P95TurnMs           = round(percentile(TurnDurationMs, 95), 0)
    by timestamp
| render timechart
```

---

### 2h. APIM — APIM-generated errors vs backend errors

**Runs against**: `ApiManagementGatewayLogs` (requires the **`GatewayLogs`** diagnostic category on `Microsoft.ApiManagement/service`).
**Field verification**: **ALL columns below are VERIFIED** against the table reference <https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/apimanagementgatewaylogs>: `ApiId`, `ApimSubscriptionId`, `ApiRevision`, `BackendId`, `BackendMethod`, `BackendProtocol`, `BackendRequestBody`, `BackendRequestHeaders`, `BackendResponseBody`, `BackendResponseCode` (int), `BackendResponseHeaders`, `BackendTime` (long), `BackendUrl`, `Cache`, `CacheTime`, `CallerIpAddress`, `ClientProtocol`, `ClientTime`, `ClientTlsVersion`, `CorrelationId`, `Errors` (dynamic), `IsRequestSuccess` (bool), `LastErrorElapsed`, `LastErrorMessage`, `LastErrorReason`, `LastErrorScope`, `LastErrorSection`, `LastErrorSource`, `Method`, `OperationId`, `OperationName`, `ProductId`, `Region`, `RequestBody`, `RequestHeaders`, `RequestSize`, `ResponseBody`, `ResponseCode` (int), `ResponseHeaders`, `ResponseSize`, `TimeGenerated`, `TotalTime`, `TraceRecords` (dynamic), `Url`, `UserId`, `WorkspaceId`.

> **Key semantic**: `ResponseCode` is what APIM returned **to the caller (Copilot Studio)**; `BackendResponseCode` is what **Azure AI Search returned to APIM**. Divergence between the two is the definitive APIM-vs-backend attribution. `LastErrorSource` tells you *which APIM component* raised the error.

```kusto
// Q8-ApimGatewayVsBackendErrors
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| where ResponseCode >= 400 or BackendResponseCode >= 400 or IsRequestSuccess == false
| extend Attribution = case(
      // APIM answered with an error but never got a backend error -> APIM-generated
      ResponseCode >= 400 and (isnull(BackendResponseCode) or BackendResponseCode == 0), "APIM-generated (no backend call)",
      // Backend errored and APIM passed it through unchanged
      BackendResponseCode >= 400 and ResponseCode == BackendResponseCode,                "Backend error (passed through)",
      // Backend errored but APIM rewrote the status
      BackendResponseCode >= 400 and ResponseCode != BackendResponseCode,                "Backend error (rewritten by APIM)",
      // Backend succeeded but APIM still failed the request (policy, transform, timeout)
      BackendResponseCode  < 400 and ResponseCode >= 400,                                "APIM post-processing failure",
      "Other")
| summarize
    Requests        = count(),
    DistinctApis    = dcount(ApiId),
    AvgBackendMs    = round(avg(BackendTime), 1),
    P95TotalMs      = round(percentile(TotalTime, 95), 1),
    SampleErrorMsg  = take_any(LastErrorMessage)
    by Attribution, ResponseCode, BackendResponseCode, LastErrorSource, LastErrorReason
| order by Requests desc
```

**Time chart of the attribution split** (the "is it us or Search?" chart):

```kusto
// Q8b-ApimAttributionTimechart
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| extend Attribution = case(
      ResponseCode < 400 and (BackendResponseCode < 400 or isnull(BackendResponseCode)), "Success",
      ResponseCode >= 400 and (isnull(BackendResponseCode) or BackendResponseCode == 0),  "APIM-generated",
      BackendResponseCode >= 400,                                                         "Backend (Azure AI Search)",
      "APIM post-processing")
| summarize Requests = count() by Attribution, bin(TimeGenerated, 5m)
| render timechart with (title = "APIM: request outcome attribution")
```

**403-specific APIM triage** (targeting the customer's 613 connector 403s):

```kusto
// Q8c-Apim403Triage
ApiManagementGatewayLogs
| where TimeGenerated > ago(7d)
| where ResponseCode == 403 or BackendResponseCode == 403
| extend Origin403 = case(
      BackendResponseCode == 403, "403 from Azure AI Search backend",
      ResponseCode == 403 and (isnull(BackendResponseCode) or BackendResponseCode == 0), "403 raised by APIM policy",
      "403 rewritten by APIM")
| summarize
    Count          = count(),
    FirstSeen      = min(TimeGenerated),
    LastSeen       = max(TimeGenerated),
    Apis           = make_set(ApiId, 10),
    Operations     = make_set(OperationName, 10),
    Subscriptions  = make_set(ApimSubscriptionId, 10),
    CallerIps      = make_set(CallerIpAddress, 10),
    SampleMessage  = take_any(LastErrorMessage),
    SampleBackend  = take_any(BackendUrl)
    by Origin403, LastErrorSource, LastErrorReason, LastErrorScope, LastErrorSection
| order by Count desc
```

**206 capture at the APIM layer — the ONLY documented place to see `semanticPartialResponseReason`:**

```kusto
// Q8d-Apim206SemanticPartialCapture
// ResponseBody / BackendResponseBody are only populated when body logging is enabled
// on the APIM diagnostic setting (and bodies are truncated to the configured byte limit).
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| where ResponseCode == 206 or BackendResponseCode == 206
| extend
    BodySnippet   = tostring(BackendResponseBody),
    PartialReason = extract(@"semanticPartialResponseReason""\s*:\s*""([^""]+)""", 1, tostring(BackendResponseBody))
| summarize
    Count          = count(),
    Reasons        = make_set(PartialReason, 10),
    Apis           = make_set(ApiId, 10),
    AvgBackendMs   = round(avg(BackendTime), 1),
    FirstSeen      = min(TimeGenerated),
    LastSeen       = max(TimeGenerated)
    by bin(TimeGenerated, 1h)
| order by TimeGenerated desc
```

> ⚠️ **UNVERIFIED**: the `extract()` regex above assumes the response body literally contains `"semanticPartialResponseReason":"CapacityOverloaded"`. The docs show the *phrases* `@search.semanticPartialResponseReason` and `CapacityOverloaded` in an error message but do **not** publish the exact JSON body shape. Validate against one captured body and adjust the pattern. Also note body logging must be explicitly enabled and has size limits and PII implications.

**Correlating APIM to Copilot Studio** — `CorrelationId` is the join key candidate:

```kusto
// Q8e-ApimCorrelationIdLookup
// UNVERIFIED that APIM CorrelationId is propagated from / to the Copilot Studio
// connector span. Run this to test whether the IDs ever line up.
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| where ResponseCode >= 400
| project TimeGenerated, CorrelationId, ApiId, OperationName, ResponseCode, BackendResponseCode,
          LastErrorSource, LastErrorReason, BackendUrl, TotalTime, BackendTime
| order by TimeGenerated desc
| take 100
```

**APIM capacity metric** (matches the Search-side throttle story):

```kusto
// Q8f-ApimCapacityAndRequests
AzureMetrics
| where TimeGenerated > ago(24h)
| where ResourceProvider == "MICROSOFT.APIMANAGEMENT"
| where MetricName in ("Capacity", "Requests", "BackendDuration", "Duration")
| summarize Value = avg(Average) by MetricName, bin(TimeGenerated, 5m)
| evaluate pivot(MetricName, any(Value))
| render timechart
```

> APIM metric dimensions available for splitting `Requests` (VERIFIED at <https://learn.microsoft.com/en-us/azure/api-management/monitor-api-management-reference>): `Location`, `Hostname`, `LastErrorReason`, `BackendResponseCode`, `GatewayResponseCode`, `BackendResponseCodeCategory`, `GatewayResponseCodeCategory`, `ApiId`. Use `GatewayResponseCodeCategory` vs `BackendResponseCodeCategory` in a **metric chart** for a zero-cost version of Q8b.

---

### 2i. Functions / ADF ingestion pipeline failures correlated with query-time failures

**Runs against**: `ADFPipelineRun`, `ADFActivityRun` (resource-specific tables — require the `PipelineRuns` / `ActivityRuns` diagnostic categories on `Microsoft.DataFactory/factories`) + `FunctionAppLogs` and App Insights `requests` / `exceptions`.

**Field verification**:
- ADF tables and categories: **VERIFIED** — `PipelineRuns` → `ADFPipelineRun`, `ActivityRuns` → `ADFActivityRun`, `TriggerRuns` → `ADFTriggerRun` (<https://learn.microsoft.com/en-us/azure/data-factory/monitor-data-factory-reference>).
- ADF column names: the doc documents the **Azure Monitor** JSON attributes (`status`, `pipelineName`, `activityName`, `activityType`, `start`, `end`, `runId`, `activityRunId`, `pipelineRunId`, `correlationId`) and states the Log Analytics transformation rule: *"The first letter in each column name is capitalized... There's no Level column"*, plus an explicit mapping table giving `ErrorCode` (int), `ErrorMessage` (string), `Error` (dynamic), `Input` (dynamic), `Output` (dynamic). So `Status`, `PipelineName`, `ActivityName`, `ActivityType`, `Start`, `End`, `RunId`, `CorrelationId`, `ErrorCode`, `ErrorMessage` are **VERIFIED by documented transformation rule** (⚠️ derived rather than shown in a sample query — see UNVERIFIED list).
- `FunctionAppLogs`: **VERIFIED** as the Functions-specific table (<https://learn.microsoft.com/en-us/azure/azure-functions/monitor-functions-reference>: *"The log specific to Azure Functions is **FunctionAppLogs**"*).

```kusto
// Q9-AdfIngestionFailures
ADFPipelineRun
| where TimeGenerated > ago(24h)
| where Status in ("Failed", "Cancelled")
| project TimeGenerated, PipelineName, RunId, Status, Start, End,
          ErrorCode  = column_ifexists("ErrorCode", 0),
          ErrorMessage = column_ifexists("ErrorMessage", ""),
          CorrelationId = column_ifexists("CorrelationId", "")
| order by TimeGenerated desc
```

```kusto
// Q9b-AdfActivityFailureDetail
ADFActivityRun
| where TimeGenerated > ago(24h)
| where Status == "Failed"
| summarize
    Failures      = count(),
    FirstSeen     = min(TimeGenerated),
    LastSeen      = max(TimeGenerated),
    SampleError   = take_any(column_ifexists("ErrorMessage", "")),
    SampleRunId   = take_any(column_ifexists("PipelineRunId", ""))
    by PipelineName, ActivityName, ActivityType = column_ifexists("ActivityType", "")
| order by Failures desc
```

**THE correlation query** — ingestion activity vs Search query health in one timeline. This is the query that answers the customer's core question: *"did the ingestion run cause the query failures?"*

```kusto
// Q9c-IngestionToQueryCorrelation
// Single timeline joining ADF pipeline activity, Search indexing ops, Search query
// health, and Function failures. Designed as the hero tile of the workbook.
let win = 5m;
let lookback = 24h;
//
let AdfRuns =
    ADFPipelineRun
    | where TimeGenerated > ago(lookback)
    | summarize
        AdfRunsStarted = countif(Status == "InProgress" or Status == "Queued"),
        AdfRunsFailed  = countif(Status == "Failed"),
        AdfRunsOk      = countif(Status == "Succeeded")
        by bin(TimeGenerated, win);
//
let SearchIngestion =
    AzureDiagnostics
    | where TimeGenerated > ago(lookback)
    | where ResourceProvider == "MICROSOFT.SEARCH"
    | where OperationName == "Indexing.Index" or OperationName startswith "Indexers."
    | summarize
        IndexingOps      = count(),
        IndexingFailures = countif(ResultType == "Failure"),
        IndexingP95Ms    = percentile(DurationMs, 95)
        by bin(TimeGenerated, win);
//
let SearchQueries =
    AzureDiagnostics
    | where TimeGenerated > ago(lookback)
    | where ResourceProvider == "MICROSOFT.SEARCH"
    | where OperationName in ("Query.Search", "Query.Suggest", "Query.Lookup", "Query.Autocomplete")
    | extend StatusCode = toint(resultSignature_d)
    | summarize
        QueryOps       = count(),
        QueryP95Ms     = percentile(DurationMs, 95),
        Query206       = countif(StatusCode == 206),   // UNVERIFIED that 206 is emitted
        Query403       = countif(StatusCode == 403),
        QueryThrottled = countif(StatusCode in (429, 503))
        by bin(TimeGenerated, win);
//
let FunctionErrors =
    FunctionAppLogs
    | where TimeGenerated > ago(lookback)
    | where Level in ("Error", "Critical")
    | summarize FunctionErrors = count() by bin(TimeGenerated, win);
//
AdfRuns
| join kind=fullouter SearchIngestion on TimeGenerated
| join kind=fullouter SearchQueries   on TimeGenerated
| join kind=fullouter FunctionErrors  on TimeGenerated
| extend Bucket = coalesce(TimeGenerated, TimeGenerated1, TimeGenerated2, TimeGenerated3)
| project Bucket,
    AdfRunsFailed    = coalesce(AdfRunsFailed, 0),
    IndexingOps      = coalesce(IndexingOps, 0),
    IndexingFailures = coalesce(IndexingFailures, 0),
    QueryOps         = coalesce(QueryOps, 0),
    QueryP95Ms       = coalesce(QueryP95Ms, 0.0),
    Query206         = coalesce(Query206, 0),
    Query403         = coalesce(Query403, 0),
    QueryThrottled   = coalesce(QueryThrottled, 0),
    FunctionErrors   = coalesce(FunctionErrors, 0)
| order by Bucket asc
| render timechart
```

**Function App failures via Application Insights** (if the Function Apps send to App Insights rather than `FunctionAppLogs`):

```kusto
// Q9d-FunctionFailuresFromAppInsights
requests
| where timestamp > ago(24h)
| where success == false
| summarize
    Failures    = count(),
    P95Ms       = round(percentile(duration, 95), 1),
    SampleOpId  = take_any(operation_Id)
    by name, resultCode, cloud_RoleName, bin(timestamp, 5m)
| order by timestamp desc
```

```kusto
// Q9e-FunctionExceptionsGrouped
exceptions
| where timestamp > ago(24h)
| summarize
    Occurrences = count(),
    Operations  = dcount(operation_Id),
    FirstSeen   = min(timestamp),
    LastSeen    = max(timestamp),
    SampleMsg   = take_any(outerMessage)
    by type, method, cloud_RoleName
| order by Occurrences desc
```

**Function App HTTP 403 metric** (cheap signal, no log ingestion cost):

```kusto
// Q9f-FunctionHttpStatusMetrics
AzureMetrics
| where TimeGenerated > ago(24h)
| where ResourceProvider == "MICROSOFT.WEB"
| where MetricName in ("Http403", "Http4xx", "Http5xx", "FunctionExecutionCount", "HttpResponseTime")
| summarize Value = sum(Total) by MetricName, bin(TimeGenerated, 5m)
| evaluate pivot(MetricName, any(Value))
| render timechart
```

---

## 3. Copilot Studio native analytics and telemetry

### 3.1 The two telemetry scopes (this distinction drives everything)

**Source**: [Telemetry with Application Insights overview](https://learn.microsoft.com/en-us/microsoft-copilot-studio/telemetry-overview)

| Area | Agent-level telemetry | Environment-level telemetry (preview) |
| --- | --- | --- |
| Configuration scope | Per agent | Once for the whole environment |
| Configured by | Maker / dev team | Power Platform admin / CoE (tenant-level admin privileges) |
| Telemetry model | **Event-based** | **Trace/span-based, OpenTelemetry-aligned** |
| Primary App Insights table | **`customEvents`** | **`dependencies`** |
| OpenTelemetry alignment | **No** | **Yes** |
| Best suited for | Message activity, topic events, custom events, single-agent troubleshooting | **Agent invocations, tool execution, outputs, dependencies, cross-agent monitoring** |
| Harness support | Standard harness only | Standard **and** GitHub Copilot harness |
| Environment requirement | Any | **Managed environments only** |

> **Recommendation for this customer**: environment-level telemetry is the right scope — it is the only one that emits tool-execution spans with tool arguments/results, which is what "see inside the connector" actually requires. Microsoft explicitly warns: *"To simplify reporting and troubleshooting, **avoid sending both agent-level and environment-level telemetry to the same Application Insights instance.**"* The customer currently shares one App Insights across Copilot Studio, Search and Functions — worth checking whether both scopes are already double-writing.

### 3.2 How to enable, and what is captured

**Agent-level** — <https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-bot-framework-composer-capture-telemetry>:

1. Agent > **Settings** > **Advanced** > **Application Insights** section.
2. Enter the **Connection string**.
3. Optional toggles:
   - **Enable logging** — logs details of incoming and outgoing messages and events.
   - **Log conversation details** — user ID, user name, message text; **and when OpenTelemetry tracing is enabled, tool input arguments and tool output results in spans**.
   - **Log sensitive Activity properties** — values of properties considered sensitive.
   - **Node execution events** — log an event each time a node within a topic executes.

**Documented `customEvents.customDimensions` fields:**

| Field | Description | Sample values |
| --- | --- | --- |
| `type` | Type of activity | `message`, `conversationUpdate`, `event`, `invoke` |
| `channelId` | Channel identifier | `emulator`, `directline`, `msteams`, `webchat` |
| `fromId` | From identifier | `<id>` |
| `fromName` | Username from client | |
| `locale` | Client origin locale | `en-us`, `de-de` |
| `recipientId` / `recipientName` | Recipient | |
| `text` | Text in message | `find a coffee shop` |
| **`designMode`** | **Conversation happened within the test canvas** | **`True` / `False`** |

**Environment-level** — <https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-environment-level-agent-telemetry>: configured via Power Platform admin center "Export data to Application Insights" with export type **Copilot Studio** (see <https://learn.microsoft.com/en-us/power-platform/admin/set-up-export-application-insights>). Validation: *"Telemetry delivery can take up to 24 hours on new configurations."*

### 3.3 The OpenTelemetry schema (environment-level)

> Copilot Studio agent events are written to the `dependencies` table as spans. Each exported event (`InvokeAgent`, `ExecuteTool`, and `OutputMessages`) is a single span row (`itemType` = `dependency`).
>
> — <https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-environment-level-agent-telemetry>

Aligned to the [OpenTelemetry GenAI agent span semantic conventions](https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/gen-ai-agent-spans.md).

**Native `dependencies` columns (documented sample values):**

| Column | Sample value |
| --- | --- |
| `name` | `InvokeAgent` / `ExecuteTool` / `OutputMessages` |
| `resultCode` | `OK`, `ERROR` |
| **`type`** | **`GenAI`** |
| **`target`** | **`GenAI`** |
| `data` | `invoke_agent` / `execute_tool` / `output_messages` |
| `success` | `True` |
| `duration` | `0` ⚠️ *(see limitations)* |
| `itemType` | `dependency` |
| `operation_Id` | `trace-<guid>` — shared by every span in the turn |
| `operation_ParentId` | The turn's `InvokeAgent` `id` for child spans |
| `performanceBucket` | `<250ms` |

**`customDimensions` keys present on EVERY span:**

`SpanId`, `error.type` (e.g. `404`), `Status.code` (`1`, `2`), `Status.message`, `gen_ai.agent.id`, `gen_ai.agent.name`, `gen_ai.conversation.id`, `gen_ai.request.model`, `gen_ai.operation.name`, `env.id`, `microsoft.tenant.id`, `microsoft.a365.agent.blueprint.id`, `microsoft.a365.agent.platform.id`, `microsoft.channel.name` (e.g. `Copilot Studio Test Pane`), `resource.provider` (`copilot studio`), `signal.category`, `a365.enabled`, `appinsights.enabled`, `user.id`, `user.email`, `user.name`, `client.address`, `telemetry.sdk.name` (`A365ObservabilitySDK`), `telemetry.sdk.language`, `telemetry.sdk.version`.

**Event-specific `customDimensions` keys:**

| Key | InvokeAgent | ExecuteTool | OutputMessages | Description |
| --- | --- | --- | --- | --- |
| `gen_ai.input.messages` | ✔️ | – | – | JSON array `{role, parts:[{content, type}]}` — the user prompt |
| `gen_ai.output.messages` | – | – | ✔️ | JSON array — the agent's reply |
| **`gen_ai.tool.name`** | – | ✔️ | – | e.g. `workiqsharepoint:mcp_SharePointRemoteServer` |
| **`gen_ai.tool.type`** | – | ✔️ | – | e.g. `MCP - Power Platform Connector` |
| `gen_ai.tool.call.id` | – | ✔️ | – | Tool invocation identifier |
| **`gen_ai.tool.call.arguments`** | – | ✔️ | – | **JSON payload sent to the tool** |
| **`gen_ai.tool.call.result`** | – | ✔️ | – | **JSON payload returned by the tool** |

> 🔑 **`gen_ai.tool.call.arguments` and `gen_ai.tool.call.result` are the direct answer to "the connector is a black box; we cannot see request payloads."** For an Azure AI Search tool call these should carry the search request and the search response, including — plausibly — the `@search.semanticPartialResponseReason` on a 206. ⚠️ **UNVERIFIED** that a Copilot Studio *knowledge source* (as opposed to a *tool*) emits `ExecuteTool` spans at all; the docs describe tools generically and do not state whether knowledge-source retrieval is modelled as a tool call.

**What `spanKind` is**: **not a documented native column** in `dependencies` and **not a documented `customDimensions` key** in the Copilot Studio schema. The documented span-kind-like field is `gen_ai.operation.name` (`invoke_agent` / `execute_tool` / `output_messages`). ⚠️ The customer's `spanKind` field is **UNVERIFIED**.

**Documented limitations that materially affect dashboard design:**

> - This feature doesn't support unauthenticated or multi-tenant agent configuration scenarios.
> - Currently available only in Microsoft public cloud environments.
> - For certain connected agent scenarios, the parent-child relationship between traces isn't mapped correctly.
> - **The `duration` value isn't available for traces of agents powered by the standard harness.**
> - **Make sure to turn on the `Local authentication` property in the target Application Insights resource.**
> - Telemetry export isn't transactional. During transient service events, small amounts of data loss can occur.
> - **This feature doesn't capture topic-related events such as `TopicStart`, `TopicAction`, and `TopicEnd`.**
> - Trace and span IDs currently use a GUID-based representation instead of the OpenTelemetry-standard 32-char/16-char hex formats.
> - Only logs for agents built in Copilot Studio, **excluding declarative agents**.
>
> — <https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-environment-level-agent-telemetry>

> ⚠️ **`duration` unavailable on standard harness** is a serious gotcha: any latency KPI built on `dependencies.duration` will be all zeros for standard-harness agents. Latency for this customer must come from the **Search resource log `DurationMs`** and **APIM `BackendTime`/`TotalTime`** instead. Flag this early.
>
> ⚠️ **"Local authentication" must be ON** on the App Insights resource. If the customer has hardened App Insights with `DisableLocalAuth: true` (common in locked-down tenants), Copilot Studio environment-level telemetry will **silently** fail to arrive.

### 3.4 CRITICAL: the customer's observed span shape does NOT match either documented schema

The customer's sample record:

```text
name, duration, success, resultCode, target, type, spanKind,
attributes.conversationId, attributes.channelId
with type == "Connector" and name == "Azure AI Search"
```

Compared against Microsoft's documentation:

| Customer field | Documented environment-level equivalent | Status |
| --- | --- | --- |
| `type == "Connector"` | Documented `type` value is **`GenAI`** | ❌ **UNVERIFIED / mismatch** |
| `name == "Azure AI Search"` | Documented `name` values are `InvokeAgent` / `ExecuteTool` / `OutputMessages` | ❌ **UNVERIFIED / mismatch** |
| `attributes.conversationId` | Documented key is **`gen_ai.conversation.id`** | ❌ **UNVERIFIED / mismatch** |
| `attributes.channelId` | Documented key is **`microsoft.channel.name`** | ❌ **UNVERIFIED / mismatch** |
| `spanKind` | Not documented; closest is `gen_ai.operation.name` | ❌ **UNVERIFIED** |
| `name`, `duration`, `success`, `resultCode`, `target`, `type` | Standard App Insights `dependencies` columns | ✅ VERIFIED as columns (values differ) |

**Most likely explanations (to confirm with the customer):**

1. They are on an **earlier preview build** of environment-level telemetry. The docs explicitly warn: *"Data inconsistencies might occur as schema-related ingestion updates roll out"* and *"Following the private preview, root agent invocations (`invoke_agent`) are now emitted as `dependencies`, rather than `requests`. As a result, **older agent root invocation traces might still appear in the `requests` table**."*
2. The spans originate from **Power Platform connector telemetry** (a different export path) rather than the Copilot Studio agent export.
3. Custom instrumentation in a middle tier.

**Action**: run `Q6-0b` and `Q6-0c` in their workspace before finalizing any dashboard. Do not ship queries against an assumed schema.

### 3.5 Out-of-box Copilot Studio analytics (no Azure required)

**Monitor page** — <https://learn.microsoft.com/en-us/microsoft-copilot-studio/analytics-overview>

- Monitoring available in all geographies. **Monitor data retained up to 360 days**; **session details and transcripts for the last 28 days**. UTC timestamps.
- **Does not show analytics for test-panel activity.**
- Access control: share the agent with the **Analytics Viewer** role; add **Bot Transcript Viewer** for transcript content.

**Sections relevant to this customer** — <https://learn.microsoft.com/en-us/microsoft-copilot-studio/analytics-improve-agent-effectiveness>:

| Section | What it gives you |
| --- | --- |
| **Knowledge source use** ⭐ | Top 5 knowledge sources by use, with **type, total questions, response quality, and reactions**. Click a source → all user questions that referenced it. **"See details" → Source use trend chart + Errors chart** = *"the percentage of sessions that used each knowledge source type that resulted in an error."* |
| **Generated answer rate and quality** | Answered vs unanswered counts; AI-assessed **Good/Poor** quality with a reason per Poor answer; click a bar segment → filtered question list. |
| **Tool use** | Top 5 tools, invocation counts, success rate, trend indicators. |
| **Conversation outcomes** | Resolved (confirmed/implied) / Escalated (system intended, system unintended, user requested) / Abandoned / Unengaged. CSV download. |
| **Agents** | For connected/child agents: **Calls**, **Success rate**, **Status**. |
| **Reactions / CSAT / Sentiment (preview)** | User feedback signals. |

> ⚠️ The **Knowledge source use → Errors** chart is documented as *"the percentage of sessions that used each **knowledge source type** (for example, SharePoint) that resulted in an error"* — i.e. aggregated by **type**, not necessarily per individual index. For 7 separate Azure AI Search indexes this may collapse to a single "Azure AI Search" bucket. ⚠️ **UNVERIFIED** whether the error breakdown resolves to individual index-backed sources.

### 3.6 Dataverse `ConversationTranscript` — and the `search_results` field

**Source**: <https://learn.microsoft.com/en-us/microsoft-copilot-studio/analytics-transcripts-powerapps>

**Can you query transcripts for failed knowledge-source lookups? Partially — yes, with an important caveat**, stated verbatim in the docs:

> Agent responses that use SharePoint as a knowledge source aren't included in conversation transcripts. When SharePoint is used as a knowledge source, conversation transcripts include the question and **the content of the source documents used to generate the response (the `search_results` field)**. However, the answer isn't included, and is marked as `REDACTED`.

> 🔑 **`search_results` is the documented field containing the content of the source documents used to generate the response.** For Azure AI Search knowledge sources this is the most direct "what did the knowledge source return?" artifact available outside App Insights. ⚠️ **UNVERIFIED**: the doc introduces `search_results` only in the SharePoint context; whether it is populated identically for **Azure AI Search** knowledge sources is not stated.

**Table facts:**

| Property | Value |
| --- | --- |
| Table | `ConversationTranscript` (Dataverse, via Power Apps > Tables > All) |
| Export | Table > **Export > Export data** → ZIP |
| Key fields | `Content` (full transcript JSON), `ConversationStartTime`, `ConversationTranscript` (row GUID), `Metadata` (`BotId`, `AADTenantId`, `BotName`, `BatchId`), `Name` (`<ConversationId>_<BotId>`), `Bot_ConversationTranscript`, `Created on` |
| Write trigger | Saved after **30 minutes of inactivity** (3 min after *End Conversation* for Telephony) |
| Size limit | **1 MB per record**; larger transcripts split across records with same `Name` + `ConversationStartTime`, different `Metadata.BatchId`. Merge by sorting on `BatchId`. |
| Default retention | Bulk-delete job removes transcripts **older than 30 days**; cancellable/replaceable |
| Copilot Studio storage retention | **28 days** |
| Not written for | Dataverse for Teams environments, Microsoft 365 Copilot agents, **developer environments** |

**`Content` JSON key fields**: `ID`, `valueType`, `timestamp` (Epoch), `type` (`message` / `event` / `trace`), `replyToId`, `from` (`id`, `role`: 0 = agent, 1 = user), `channelId`, `textFormat`, `attachments`, `text`, **`value`** (*"this field is where most of the useful information exists"*), `channeldata` (incl. `DialogTraceDetail`, `DialogErrorDetail`, `VariableDetail`, `CurrentMessageDetail`, `cci_trace_id`, `traceHistory`, `enableDiagnostics`), `name`.

**Activity value types**: `ConversationInfo` (incl. **`isDesignMode`**), `CSATSurveyRequest/Response`, `DialogRedirect`, `ImpliedSuccess`, `IntentRecognition`, `PRRSurveyRequest/Response`, `SessionInfo` (type, outcome, `startTimeUtc`, `endTimeUtc`, turn count), `VariableAssignment`.

**Enhanced transcripts** (Settings > Advanced > **Enhance Transcripts** > *Include node-level details in transcripts*) add a `nodeTraceData` activity per node with: `nodeID`, **`nodeType`** *(e.g. `SendActivity` or **`SearchAndSummarizeContent`**)*, `startTime`, `endTime`, `topicDisplayName`.

> 🔑 **`nodeType == "SearchAndSummarizeContent"` is the generative-answers/knowledge-lookup node.** With enhanced transcripts on, you get per-node start/end timestamps for every knowledge lookup — i.e. **per-lookup latency** for the 7-index fan-out, straight from the transcript, with no Azure dependency.

**Custom analytics path** (for Power BI, which they already use): *"customers can ingest the raw transcripts into their data pipelines or use an add-on, like the [Copilot Agent Kit](https://learn.microsoft.com/en-us/microsoft-copilot-studio/guidance/kit-overview). The [Conversation KPIs](https://learn.microsoft.com/en-us/microsoft-copilot-studio/guidance/kit-conversation-kpi) solution in Copilot Agent Kit automatically parses transcripts and populates aggregated data into Dataverse tables."*

### 3.7 Summary: which knowledge source was queried and what it returned

| Method | Granularity | Shows the query? | Shows the result? | Shows errors? | Setup |
| --- | --- | --- | --- | --- | --- |
| Monitor page → **Knowledge source use** | Per source (possibly per *type*) | No | No | ✅ error % | None |
| Monitor page → drill to user questions | Per question | ✅ question text | No | Indirectly | None |
| Dataverse `ConversationTranscript` → **`search_results`** | Per turn | ✅ | ✅ source-document content | Via `DialogErrorDetail` | Bot Transcript Viewer role |
| Enhanced transcripts → `nodeTraceData` (`SearchAndSummarizeContent`) | Per node | Node identity + timing | No | Node-level | Settings toggle |
| App Insights `dependencies` → `gen_ai.tool.call.arguments` / `.result` | Per tool call | ✅ full payload | ✅ full payload | ✅ `error.type`, `Status.message` | Env-level export + "Log conversation details" |
| **Azure AI Search `AzureDiagnostics` → `Query_s` + `IndexName_s`** | Per search request | ✅ query params | Doc count only (`Documents_d`) | ✅ `resultSignature_d` | Diagnostic setting |

> **Best combined answer**: App Insights `dependencies` (agent's intent + payload) **joined by time** to `AzureDiagnostics` (what Search actually did per index). This pairing is the observability backbone to recommend.

---

## 4. Cross-service correlation in ONE Azure Monitor Workbook

### 4.1 The operators

**Source**: [Query across resources with Azure Monitor](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/cross-workspace-query)

| Operator | Purpose | Identifier forms |
| --- | --- | --- |
| `workspace(Identifier)` | Query another **Log Analytics workspace** | Workspace **GUID** or full **Azure Resource ID** |
| `app(Identifier)` | Query a **classic Application Insights** resource | App **GUID** or full **Azure Resource ID** |
| `resource(Identifier)` | Correlate from a **resource-scoped** query to other resources | Resource ID, or a resource group / subscription ID |

> **Important for this customer**: *"If you're using a **workspace-based Application Insights resource**, telemetry is stored in a Log Analytics workspace with all other log data. Use the `workspace()` expression to query data from applications in multiple workspaces. **You don't need a cross-workspace query to query data from multiple applications in the same workspace.**"*
>
> Since the customer **already shares one Application Insights across Copilot Studio, Azure AI Search and Function Apps**, and modern App Insights is workspace-based, they very likely need **no cross-resource operators at all** — a plain `union` across `dependencies`, `AzureDiagnostics`, `AzureMetrics`, `ApiManagementGatewayLogs`, `ADFPipelineRun` and `FunctionAppLogs` in the single workspace will work. **Verify this first**; it dramatically simplifies the workbook.

**Documented constraints:**

> - Cross-resource and cross-service queries **don't support parameterized functions** and functions whose definition includes other cross-workspace or cross-service expressions, including `adx()`, `arg()`, `resource()`, `workspace()`, and `app()`.
> - You can include **up to 100** Log Analytics workspaces or classic Application Insights resources in a single query.
> - Querying across a large number of resources can substantially slow down the query.
> - **References to a cross resource ... should be explicit and can't be parameterized.**
> - Cross-resource queries in log search alerts are only supported in the current `scheduledQueryRules` API.

> ⚠️ **"References to a cross resource ... can't be parameterized"** directly constrains workbook design: you **cannot** drive a `workspace("{MyWorkspaceParam}")` call from a workbook resource picker. If multiple workspaces are genuinely in play, use **one query step per workspace** with hardcoded IDs, or a saved **function** (with the caveat that functions used this way break log search alerts).

**Permissions**: `Microsoft.OperationalInsights/workspaces/query/*/read` on every workspace queried (Log Analytics Reader).

### 4.2 Cross-service union — the unified incident timeline

```kusto
// Q10-UnifiedIncidentTimeline
// Single-workspace variant (recommended - validate with Q10-pre below).
// Normalizes five services into one schema for a single "what broke when" tile.
let win = 5m;
let lookback = 6h;
union isfuzzy=true
(
    AzureDiagnostics
    | where TimeGenerated > ago(lookback) and ResourceProvider == "MICROSOFT.SEARCH"
    | where OperationName in ("Query.Search","Query.Suggest","Query.Lookup","Query.Autocomplete")
    | extend Layer = "3-AzureAISearch(query)",
             Failed = iff(ResultType == "Failure" or toint(resultSignature_d) >= 400, 1, 0),
             Detail = strcat(IndexName_s, " / ", tostring(resultSignature_d)),
             LatencyMs = todouble(DurationMs)
    | project TimeGenerated, Layer, Failed, Detail, LatencyMs
),
(
    AzureDiagnostics
    | where TimeGenerated > ago(lookback) and ResourceProvider == "MICROSOFT.SEARCH"
    | where OperationName == "Indexing.Index" or OperationName startswith "Indexers."
    | extend Layer = "5-AzureAISearch(ingest)",
             Failed = iff(ResultType == "Failure", 1, 0),
             Detail = strcat(OperationName, " / ", IndexName_s),
             LatencyMs = todouble(DurationMs)
    | project TimeGenerated, Layer, Failed, Detail, LatencyMs
),
(
    ApiManagementGatewayLogs
    | where TimeGenerated > ago(lookback)
    | extend Layer = "2-APIM",
             Failed = iff(ResponseCode >= 400 or IsRequestSuccess == false, 1, 0),
             Detail = strcat(ApiId, " / gw:", tostring(ResponseCode), " be:", tostring(BackendResponseCode)),
             LatencyMs = todouble(TotalTime)
    | project TimeGenerated, Layer, Failed, Detail, LatencyMs
),
(
    dependencies
    | where timestamp > ago(lookback)
    | extend TimeGenerated = timestamp,
             Layer = "1-CopilotStudio",
             Failed = iff(success == false or resultCode == "ERROR", 1, 0),
             Detail = strcat(name, " / ", tostring(customDimensions["gen_ai.tool.name"]), " / ", resultCode),
             LatencyMs = todouble(duration)
    | project TimeGenerated, Layer, Failed, Detail, LatencyMs
),
(
    ADFPipelineRun
    | where TimeGenerated > ago(lookback)
    | extend Layer = "6-ADF",
             Failed = iff(Status == "Failed", 1, 0),
             Detail = strcat(PipelineName, " / ", Status),
             LatencyMs = real(null)
    | project TimeGenerated, Layer, Failed, Detail, LatencyMs
),
(
    FunctionAppLogs
    | where TimeGenerated > ago(lookback)
    | extend Layer = "4-Functions",
             Failed = iff(Level in ("Error","Critical"), 1, 0),
             Detail = strcat(column_ifexists("FunctionName",""), " / ", Level),
             LatencyMs = real(null)
    | project TimeGenerated, Layer, Failed, Detail, LatencyMs
)
| summarize
    Events   = count(),
    Failures = sum(Failed),
    P95Ms    = round(percentile(LatencyMs, 95), 0)
    by Layer, bin(TimeGenerated, win)
| extend FailurePct = round(100.0 * Failures / Events, 2)
| order by TimeGenerated asc, Layer asc
```

```kusto
// Q10-pre-ConfirmSingleWorkspace
// Run first. If all six tables return rows, no workspace()/app() operators are needed.
union isfuzzy=true
    (AzureDiagnostics           | where TimeGenerated > ago(1d) | summarize n = count() | extend T = "AzureDiagnostics"),
    (AzureMetrics               | where TimeGenerated > ago(1d) | summarize n = count() | extend T = "AzureMetrics"),
    (ApiManagementGatewayLogs   | where TimeGenerated > ago(1d) | summarize n = count() | extend T = "ApiManagementGatewayLogs"),
    (dependencies               | where timestamp      > ago(1d) | summarize n = count() | extend T = "dependencies"),
    (requests                   | where timestamp      > ago(1d) | summarize n = count() | extend T = "requests"),
    (customEvents               | where timestamp      > ago(1d) | summarize n = count() | extend T = "customEvents"),
    (ADFPipelineRun             | where TimeGenerated > ago(1d) | summarize n = count() | extend T = "ADFPipelineRun"),
    (ADFActivityRun             | where TimeGenerated > ago(1d) | summarize n = count() | extend T = "ADFActivityRun"),
    (FunctionAppLogs            | where TimeGenerated > ago(1d) | summarize n = count() | extend T = "FunctionAppLogs")
| project Table = T, Rows = n
| order by Rows desc
```

**Explicit cross-workspace variant** (only if `Q10-pre` shows tables live in different workspaces):

```kusto
// Q10b-CrossWorkspaceUnion
// Workspace/app IDs MUST be literals -- they cannot be workbook parameters.
let lookback = 6h;
union isfuzzy=true
(
    workspace("00000000-0000-0000-0000-000000000001").AzureDiagnostics
    | where TimeGenerated > ago(lookback) and ResourceProvider == "MICROSOFT.SEARCH"
    | extend Source = "Search"
),
(
    workspace("00000000-0000-0000-0000-000000000002").ApiManagementGatewayLogs
    | where TimeGenerated > ago(lookback)
    | extend Source = "APIM"
)
| summarize Events = count() by Source, bin(TimeGenerated, 5m)
| render timechart
```

### 4.3 Workbook structure to build

**Docs**: [Create or edit an Azure Workbook](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-create-workbook) · [Workbook data sources](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-data-sources) · [Workbook parameters](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-parameters)

Workbooks support **Logs**, **Metrics**, **Azure Resource Graph**, **Azure Resource Health** and more as data sources — so a **single workbook can mix a Search metric chart, an App Insights log query, and an APIM log query on one page**. That is the whole answer to research question 4.

**Recommended tab layout** (use the **Tabs** link style, each tab setting a `selectedTab` parameter, with content groups made conditionally visible — Microsoft's documented pattern):

| Tab | Content | Data source |
| --- | --- | --- |
| **0 · Health overview** | KPI tiles: connector failure %, Search 206 %, Search 403 %, throttle %, p95 latency, ADF failed runs. Unified timeline `Q10`. | Logs + Metrics |
| **1 · Copilot Studio** | `Q6A`/`Q6B`, `Q6C` (designMode filter), `Q7b` worst conversations, `Q7d` tool-calls-per-turn. | Logs (App Insights) |
| **2 · APIM** | `Q8b` attribution timechart, `Q8` grid, `Q8c` 403 triage, `Q8d` 206 body capture, `Q8f` capacity. | Logs + Metrics |
| **3 · Search — QUERY** | `Q1` volume per index, `Q1b` fan-out ratio, `Q2` status codes, `Q3b` p95 per index, `Q4` throttle %. | Logs + Metrics |
| **4 · Search — INGESTION** | `Q5c` indexing OPM, `DocumentsProcessedCount` metric split by `Failed` + `IndexName`, `SkillExecutionCount` split by `Failed`. | Logs + Metrics |
| **5 · Pipeline (ADF / Functions)** | `Q9`, `Q9b`, `Q9c` correlation, `Q9d`–`Q9f`. | Logs + Metrics |
| **6 · Correlation** | `Q9c` hero tile, `Q5b` ingestion-vs-query, `Q8e` correlation-ID lookup. | Logs |

**Parameters to define** (top of workbook, merged into every tab):

| Parameter | Type | Source |
| --- | --- | --- |
| `TimeRange` | Time range picker | Built-in |
| `Subscription` | Resource picker | Built-in |
| `SearchService` | Resource picker, type `Microsoft.Search/searchServices` | ARG |
| `AppInsights` | Resource picker, type `microsoft.insights/components` | ARG |
| `ApimService` | Resource picker, type `Microsoft.ApiManagement/service` | ARG |
| `IndexName` | Dropdown, multi-select, **with "All"** | KQL: see below |
| `selectedTab` | Hidden, set by tab links | Link action |

```kusto
// Q11-IndexPickerParameter
// Drives the IndexName dropdown. Add an "All" special value in the parameter settings.
AzureDiagnostics
| where TimeGenerated > ago(7d)
| where ResourceProvider == "MICROSOFT.SEARCH"
| where isnotempty(IndexName_s)
| summarize Queries = count() by IndexName_s
| project value = IndexName_s, label = strcat(IndexName_s, " (", tostring(Queries), ")"), selected = true
| order by label asc
```

```kusto
// Q12-SearchServiceResourcePicker  (Azure Resource Graph data source)
Resources
| where type =~ 'microsoft.search/searchServices'
| project value = id, label = name, selected = true, group = resourceGroup
```

**Robustness patterns Microsoft explicitly recommends for shared/multi-tenant workbooks** (<https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-create-workbook>, "Best practices for querying logs"):

- **Predefine summary rules** to aggregate data instead of querying raw tables over long ranges (<https://learn.microsoft.com/en-us/azure/azure-monitor/logs/summary-rules>). Strongly advised here — 7× fan-out means high `AzureDiagnostics` row volume.
- **Use the smallest possible time ranges.**
- **Use the "All" special value in dropdowns.**
- **Protect against missing columns** with `column_ifexists()` — already applied above.
- **Protect against a missing table** with a fuzzy union:

```kusto
// Q13-TableExistenceGuard  (Microsoft-published pattern)
// Returns 1 if AzureDiagnostics does not exist in this workspace, else 0.
// Bind to a parameter and use it to conditionally hide dependent steps.
let MissingTable = view () { print isMissing = 1 };
union isfuzzy=true MissingTable, (AzureDiagnostics | getschema | summarize c = count() | project isMissing = iff(c > 0, 0, 1))
| top 1 by isMissing asc
```

- **Split into subtemplates** loaded by groups in **lazy** mode so unopened tabs never execute their queries (documented under "Splitting a large template into many templates"). With 7 tabs this materially improves load time.

---

## 5. Published workbook gallery templates and GitHub repos

### 5.1 What EXISTS and is directly importable

| Asset | Repo path | Direct URL | Relevance |
| --- | --- | --- | --- |
| **Copilot Studio Dashboard** ⭐ | `Workbooks/Copilot Studio/CopilotStudioDashboard.workbook` | <https://github.com/microsoft/Application-Insights-Workbooks/tree/master/Workbooks/Copilot%20Studio> | **Ships in the App Insights Workbooks gallery.** Exactly the "native workbook-style dashboard" the customer asked for. |
| **Azure API Management / Analytics** | `Workbooks/Azure API Management/Analytics` | <https://github.com/microsoft/Application-Insights-Workbooks/tree/master/Workbooks/Azure%20API%20Management/Analytics> | APIM gateway analytics; includes a "Language models" tab (last updated ~1 yr ago). |
| **Azure Machine Learning / AI Studio** | `Workbooks/Azure Machine Learning/AI Studio` | <https://github.com/microsoft/Application-Insights-Workbooks/tree/master/Workbooks/Azure%20Machine%20Learning/AI%20Studio> | Token-usage patterns adaptable to AI workloads. |
| **Azure Monitor – Applications** | `Workbooks/Azure Monitor - Applications` | <https://github.com/microsoft/Application-Insights-Workbooks/tree/master/Workbooks/Azure%20Monitor%20-%20Applications> | OTel metrics patterns. |
| **Copilot Studio KQL queries (community)** | `Azure Services/Power Platform/Copilot Studio/Queries/Analytics` and `Azure Services/Power Platform/Microsoft Copilot Studio` | <https://github.com/microsoft/AzureMonitorCommunity/tree/master/Azure%20Services/Power%20Platform> | Copilot Studio usage KQL, added ~3 weeks before this research. |
| **Power Platform Connectors / DLP / Dataverse queries** | `Azure Services/Power Platform/{Connectors,DLP,Dataverse}/Queries/Analytics` | <https://github.com/microsoft/AzureMonitorCommunity/tree/master/Azure%20Services/Power%20Platform> | Connector-level analytics — relevant to the `shared_azureaisearch` connector. |
| **API Management community queries** | `Azure Services/API Management services` | <https://github.com/microsoft/AzureMonitorCommunity/tree/master/Azure%20Services> | |
| **Data factories community queries/alerts** | `Azure Services/Data factories` | <https://github.com/microsoft/AzureMonitorCommunity/tree/master/Azure%20Services> | Includes 3 prebuilt ADF alerts. |
| **App Services community queries** | `Azure Services/App Services` | <https://github.com/microsoft/AzureMonitorCommunity/tree/master/Azure%20Services> | Function Apps run on `Microsoft.Web/sites`. |
| **OpenAI community queries** | `Azure Services/OpenAi` | <https://github.com/microsoft/AzureMonitorCommunity/tree/master/Azure%20Services> | Added ~3 weeks before this research. |
| **Azure Monitor Baseline Alerts (AMBA)** | — | <https://aka.ms/amba> | Referenced from the Search monitor doc: *"provides a semi-automated method of implementing important platform metric alerts, dashboards, and guidelines."* |

**How to import a `.workbook` file**: Azure portal → any resource (or Azure Monitor) → **Workbooks** → **New** → **</> Advanced Editor** → paste the JSON → **Apply** → **Save**.

### 5.2 What does NOT exist (confirmed absent)

❌ **No Azure AI Search / Azure Cognitive Search workbook template exists.**

Evidence:
- The `Workbooks/` directory listing of `microsoft/Application-Insights-Workbooks` contains **no** Search/Cognitive Search folder (verified against the full folder list: ADXCluster, AKS, Activity Log, App Hub, App Services…, Azure API Management/Analytics, …, Copilot Studio, CosmosDb, …, KeyVault, …, RedisCache, ServiceBus, SqlDatabase, Storage…, Synapse, …).
- `microsoft/AzureMonitorCommunity/Azure Services/` contains **no** Azure AI Search / Cognitive Search folder (verified against the full listing: API Management services, App Services, …, Cosmos DB, Data factories, Dataverse, …, OpenAi, Power Platform, …).
- Neither `microsoft/Application-Insights-Workbooks` text search for `Microsoft.Search/searchServices` nor for `path:Workbooks/Search` returned results.

❌ **No dedicated Azure AI Search Log Analytics table** (`AzureDiagnostics` only).
❌ **No `semanticPartialResponseReason` resource-log field.**
❌ **No index dimension on `SearchLatency` or `SearchQueriesPerSecond`.**

### 5.3 The other out-of-box Copilot Studio assets in the portal

**Built-in monitoring workbook** — <https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-bot-framework-composer-capture-telemetry> (preview):

> The Copilot Studio dashboard view uses signals from Azure Monitor Application Insights. It queries Application Insights through Azure Workbooks and creates visualizations. These views bring key metrics, such as **total conversations, latency, exceptions, tool usage, and topic analytics**, into a single view.
>
> 1. Go to your Application Insights resource.
> 2. Select the **Monitoring** tab from the left navigation pane.
> 3. Under the **Monitoring** tab, select **Workbooks**. Open **Copilot Studio Dashboard** from the workbooks gallery.

It opens as an **editable** workbook: *"you can add a tile that uses KQL to track a custom attribute you're collecting that the built-in view doesn't show."* → **This is the recommended host for the Azure AI Search tiles from [Section 2](#2-ready-to-paste-kql-queries)**: start from the shipped Copilot Studio Dashboard, add Search/APIM tabs, save as a new shared workbook. That keeps the "out-of-box first" principle the customer asked for. Sharing requires at least **Reader** on the connected App Insights resource.

**Agents (preview) blades** — <https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-environment-level-agent-telemetry>:

> In addition to **Logs**, Application Insights provides built-in **Agents (preview)** views that visualize the exported GenAI telemetry without writing Kusto queries...
> - **Agent Runs**: Lists agent invocations built from the `InvokeAgent` spans, with their duration, success, and the conversation each run belongs to.
> - **Tools**: Aggregates the `ExecuteTool` spans to show which tools the agents call, how often, and how they perform.
> - **Models**: Summarizes model usage across runs.

> 🔑 **The "Tools" blade is a zero-build, zero-KQL view of exactly what the customer says they cannot see** — which tools are called, how often, and how they perform. Demo this before writing a single query.

---

## 6. Alerting recommendations

### 6.1 Microsoft's documented alert rules for Azure AI Search

From <https://learn.microsoft.com/en-us/azure/search/monitor-azure-cognitive-search> ("Azure AI Search alert rules"):

> On a search service, **throttling or query latency that exceeds a given threshold are the most commonly used alerts**, but you might also want to be notified if a search service is deleted.

| Alert type | Condition |
| --- | --- |
| Search Latency (metric alert) | Whenever the average search latency is greater than a user-specified threshold (in seconds) |
| Throttled search queries percentage (metric alert) | Whenever the total throttled search queries percentage is ≥ a user-specified threshold |
| Storage Usage | When total storage usage exceeds a user-defined threshold. Use the index name dimension. |
| Compute Usage | When compute consumed exceeds the threshold. Use operation name and index name dimensions. |

Alert types available (<https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-types>): metric alerts, log alerts, activity log alerts, smart detection, Prometheus, recommended alert rules.

### 6.2 Recommended rule set for THIS workload

> **Threshold rationale**: no Microsoft doc publishes numeric thresholds for these — the docs consistently say "user-specified threshold". The values below are **engineering recommendations derived from the documented behaviour** (notably the *10 concurrent semantic queries per replica* ceiling and the *~3-minute* indexing→latency lag), **not** Microsoft-published numbers. **Tune against 2 weeks of the customer's own baseline before enabling paging.**

| # | Name | Type | Signal | Condition (recommended) | Window / freq | Severity | Rationale |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **A1** | Search throttling — warning | Metric | `ThrottledSearchQueriesPercentage` (Avg) | `> 1 %` | 5 min avg / 5 min | Sev 3 | Documented primary capacity signal; >1 % means real user impact at 7× fan-out. |
| **A2** | Search throttling — critical | Metric | `ThrottledSearchQueriesPercentage` (Avg) | `> 5 %` | 5 min avg / 1 min | Sev 1 | Sustained drop-rate; scale replicas now. |
| **A3** | Search latency p95 regression | Log (scheduled query) | `AzureDiagnostics` `DurationMs` | `percentile(DurationMs, 95) > 1000 ms` on query ops | 15 min / 5 min | Sev 2 | Log-based because the metric has no percentile/index dimension. |
| **A4** | Search latency — metric backstop | Metric | `SearchLatency` (Avg) | `> 0.5 s` | 5 min avg / 5 min | Sev 3 | Cheap, no log dependency; Microsoft's documented rule. |
| **A5** | **Semantic partial response (206) rate** | Log | `AzureDiagnostics` `resultSignature_d == 206` | `count() > 0` over 15 min, **or** `> 0.5 %` of query ops | 15 min / 5 min | Sev 2 | ⚠️ Depends on the UNVERIFIED 206 emission — **validate with `Q0b` before enabling.** Fallback: APIM-side rule A6. |
| **A6** | **206 at APIM (fallback for A5)** | Log | `ApiManagementGatewayLogs` `BackendResponseCode == 206` | `count() > 0` over 15 min | 15 min / 5 min | Sev 2 | Works regardless of whether Search logs 206. |
| **A7** | **Connector 403 rate** | Log | `dependencies` where tool ≈ Search and `resultCode == "403"` | `> 1 %` of calls **or** `count() > 10` | 15 min / 5 min | Sev 1 | 403 is auth/network — never transient-benign. Customer saw 613. |
| **A8** | Search-side 403 | Log | `AzureDiagnostics` `resultSignature_d == 403` | `count() > 5` | 15 min / 5 min | Sev 1 | Distinguishes "reached Search and was rejected" from connector-side 403. |
| **A9** | APIM backend failure rate | Metric | `Requests` split by `BackendResponseCodeCategory` | `4xx + 5xx > 5 %` | 5 min / 5 min | Sev 2 | Zero log-ingestion cost. |
| **A10** | APIM-generated errors | Log | `ApiManagementGatewayLogs` `ResponseCode >= 400 and BackendResponseCode is null/0` | `count() > 10` | 15 min / 5 min | Sev 2 | Isolates gateway-origin failures. |
| **A11** | APIM capacity | Metric | `Capacity` (Avg) | `> 70 %` | 15 min / 5 min | Sev 3 | Premium-tier only for `Max` aggregation. |
| **A12** | Indexer document failures | Metric | `DocumentsProcessedCount` split by `Failed == true` | `Sum > 0` | 15 min / 5 min | Sev 2 | Dimension-based; clean ingestion/query separation. |
| **A13** | Skill execution failures | Metric | `SkillExecutionCount` split by `Failed == true` | `Sum > 0` | 15 min / 5 min | Sev 3 | Enrichment-pipeline health. |
| **A14** | ADF pipeline failure | Metric | `PipelineFailedRuns` (Sum) | `> 0` | 5 min / 5 min | Sev 2 | Documented ADF metric with `Name`/`FailureType` dimensions. |
| **A15** | ADF activity failure | Metric | `ActivityFailedRuns` (Sum) | `> 0` | 5 min / 5 min | Sev 3 | Dimensions `ActivityType`, `PipelineName`, `FailureType`, `Name`. |
| **A16** | Function App 5xx | Metric | `Http5xx` (Sum) | `> 5` | 5 min / 5 min | Sev 2 | |
| **A17** | Function App 403 | Metric | `Http403` (Sum) | `> 0` | 5 min / 5 min | Sev 2 | Auth misconfiguration on the ingestion tier. |
| **A18** | Search storage approaching limit | Metric | `IndexStorageUsage` split by `IndexName` | `> 80 %` of tier limit | 1 h / 1 h | Sev 3 | Microsoft-documented rule. |
| **A19** | Search service deleted | Activity log | `Microsoft.Search/searchServices/delete` | Any | — | Sev 0 | Microsoft-documented recommendation. |
| **A20** | **Ingestion↔query contention (composite)** | Log | `Q5b`-style query | indexing ops > 0 **AND** query p95 > 2× 24 h baseline in same 5 min bucket | 15 min / 5 min | Sev 2 | Encodes the documented ~3-min indexing→latency lag. The proactive rule the customer actually wants. |

### 6.3 Alert query bodies

```kusto
// A3 - Search latency p95 regression (log alert)
// Alert logic: Number of results > 0
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.SEARCH"
| where OperationName in ("Query.Search", "Query.Suggest", "Query.Lookup", "Query.Autocomplete")
| summarize p95 = percentile(DurationMs, 95), Queries = count() by IndexName_s
| where Queries >= 20          // avoid firing on tiny samples
| where p95 > 1000             // TUNE against the customer's baseline
```

```kusto
// A5 - Semantic partial response (206) rate (log alert)
// PREREQ: confirm with Q0b that Search actually emits 206 into resultSignature_d.
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.SEARCH"
| where OperationName in ("Query.Search", "Query.Suggest", "Query.Lookup", "Query.Autocomplete")
| extend StatusCode = toint(resultSignature_d)
| summarize Total = count(), Partial206 = countif(StatusCode == 206) by IndexName_s
| extend Partial206Pct = round(100.0 * Partial206 / Total, 3)
| where Partial206 > 0 and Partial206Pct > 0.5
```

```kusto
// A6 - 206 detected at APIM (fallback that does not depend on Search logging 206)
ApiManagementGatewayLogs
| where BackendResponseCode == 206 or ResponseCode == 206
| summarize Count = count(), Apis = make_set(ApiId, 5)
| where Count > 0
```

```kusto
// A7 - Connector 403 rate (log alert)
// Variant B (documented schema). For Variant A swap in type=="Connector" / name=="Azure AI Search".
dependencies
| where name == "ExecuteTool"
| extend
    ToolName   = tostring(customDimensions["gen_ai.tool.name"]),
    ErrorType  = tostring(customDimensions["error.type"]),
    ChannelName= tostring(customDimensions["microsoft.channel.name"])
| where ChannelName != "Copilot Studio Test Pane"       // exclude maker test traffic
| where ToolName has "search" or ToolName has "azureaisearch"
| summarize Calls = count(), Forbidden = countif(resultCode == "403" or ErrorType == "403")
| extend ForbiddenPct = round(100.0 * Forbidden / Calls, 2)
| where Forbidden > 10 or ForbiddenPct > 1.0
```

```kusto
// A8 - Search-side 403 (log alert)
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.SEARCH"
| extend StatusCode = toint(resultSignature_d)
| where StatusCode == 403
| summarize Count = count(), Indexes = make_set(IndexName_s, 10), Ops = make_set(OperationName, 10)
| where Count > 5
```

```kusto
// A10 - APIM-generated errors (log alert)
ApiManagementGatewayLogs
| where ResponseCode >= 400
| where isnull(BackendResponseCode) or BackendResponseCode == 0
| summarize Count = count(), Reasons = make_set(LastErrorReason, 10), Sources = make_set(LastErrorSource, 10)
| where Count > 10
```

```kusto
// A20 - Ingestion vs query contention (composite log alert)
// Fires when indexing is active AND query p95 is >2x the 24h baseline in the same window.
let win = 5m;
let Baseline = toscalar(
    AzureDiagnostics
    | where TimeGenerated between (ago(24h) .. ago(1h))
    | where ResourceProvider == "MICROSOFT.SEARCH"
    | where OperationName in ("Query.Search","Query.Suggest","Query.Lookup","Query.Autocomplete")
    | summarize percentile(DurationMs, 95));
let Ingestion =
    AzureDiagnostics
    | where TimeGenerated > ago(30m)
    | where ResourceProvider == "MICROSOFT.SEARCH"
    | where OperationName == "Indexing.Index" or OperationName startswith "Indexers."
    | summarize IndexingOps = count() by bin(TimeGenerated, win);
let Queries =
    AzureDiagnostics
    | where TimeGenerated > ago(30m)
    | where ResourceProvider == "MICROSOFT.SEARCH"
    | where OperationName in ("Query.Search","Query.Suggest","Query.Lookup","Query.Autocomplete")
    | summarize QueryP95 = percentile(DurationMs, 95), QueryOps = count() by bin(TimeGenerated, win);
Ingestion
| join kind=inner Queries on TimeGenerated
| extend BaselineP95 = Baseline
| where IndexingOps > 0 and QueryOps >= 20 and QueryP95 > 2 * BaselineP95
| project TimeGenerated, IndexingOps, QueryOps, QueryP95, BaselineP95
```

### 6.4 Alerting notes

- **Cross-resource queries in log alerts** are only supported via the current `scheduledQueryRules` API, and **saved functions used for resource scoping break alerting** (*"the access validation of the alert rule resources ... is performed at alert creation time. Adding new resources to the function after the alert creation isn't supported"*). Keep alert queries single-workspace and inline. — <https://learn.microsoft.com/en-us/azure/azure-monitor/logs/cross-workspace-query>
- **Always filter test traffic** out of alert queries (`designMode == "False"` for `customEvents`; `microsoft.channel.name != "Copilot Studio Test Pane"` for `dependencies`) or maker testing will page the on-call.
- **Prefer metric alerts** where a metric exists (A1, A2, A4, A9, A11–A19): near-real-time, cheaper, and no log-ingestion dependency. Reserve log alerts for percentile/index-dimension/composite logic that metrics cannot express (A3, A5, A7, A8, A10, A20).
- **Common alert schema** should be enabled for consistent downstream automation — <https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-common-schema>.
- **AMBA** (<https://aka.ms/amba>) offers a semi-automated baseline for platform metric alerts and is referenced directly from the Search monitor doc.

---

## 7. Field names that could NOT be verified from documentation

Every item below is marked inline in the relevant query. **Run `Q0`, `Q0b`, `Q6-0a`, `Q6-0b`, `Q6-0c` and `Q10-pre` in the customer's workspace before shipping anything.**

### 7.1 Azure AI Search

| Item | Status | Detail |
| --- | --- | --- |
| `resultSignature_d == 206` | ⚠️ **UNVERIFIED** | Field documented as "An HTTP result code"; **no doc example shows 206 for Search**. The semantic-ranker doc describes the 206 only as a client-visible error. **Highest-priority item to validate.** |
| `Query_s` | ⚠️ **PARTIALLY VERIFIED** | Documented in the `Properties` schema table; **not used in any published sample query**, so the exact Log Analytics column name (suffix/casing) is inferred. Guarded with `column_ifexists()`. |
| `Description_s` | ⚠️ **PARTIALLY VERIFIED** | Same as above. |
| `DurationMs` vs `DurationMS` | ⚠️ **CASING CONFLICT** | Schema table says `durationMS` / `DurationMilliseconds` / `DurationMS`; Microsoft's own published KQL uses **`DurationMs`**. Queries use `DurationMs` (follows the working samples). |
| `ResourceProvider == "MICROSOFT.SEARCH"` | ⚠️ **INFERRED** | Standard `AzureDiagnostics` column, but the value string is not shown in a Search doc example. The `AzureDiagnostics` table reference page failed to render during this research. Alternative filters: `ResourceType == "SEARCHSERVICES"` or `_ResourceId contains "/searchservices/"`. |
| `@search.semanticPartialResponseReason` in logs | ❌ **VERIFIED ABSENT** | Not a documented resource-log property. Must be captured at APIM. |
| Throttle status code: 429 vs 503 | ⚠️ **DOC CONFLICT** | Performance article: *"an API call results in a 503 HTTP response when it has been throttled"*. Capacity article names **both** 503 and 429. Queries count both. |

### 7.2 Copilot Studio / Application Insights

| Item | Status | Detail |
| --- | --- | --- |
| `type == "Connector"` | ⚠️ **UNVERIFIED** | Documented value is `GenAI`. From customer sample only. |
| `name == "Azure AI Search"` | ⚠️ **UNVERIFIED** | Documented values are `InvokeAgent` / `ExecuteTool` / `OutputMessages`. |
| `attributes.conversationId` | ⚠️ **UNVERIFIED** | Documented key is `gen_ai.conversation.id`. |
| `attributes.channelId` | ⚠️ **UNVERIFIED** | Documented key is `microsoft.channel.name`. |
| `spanKind` | ⚠️ **UNVERIFIED** | Not a documented native column or `customDimensions` key. Closest documented: `gen_ai.operation.name`. |
| `microsoft.channel.name != "Copilot Studio Test Pane"` as an exhaustive test filter | ⚠️ **UNVERIFIED** | Documented as a *sample value*, not a guaranteed enum. |
| Whether a **knowledge source** (vs a tool) emits `ExecuteTool` spans | ⚠️ **UNVERIFIED** | Docs describe tools generically; knowledge-source retrieval modelling is not stated. |
| `search_results` for **Azure AI Search** knowledge sources | ⚠️ **UNVERIFIED** | Documented only in the SharePoint caveat. |
| Whether Knowledge-source-use **Errors** resolve per index vs per type | ⚠️ **UNVERIFIED** | Doc says *"per knowledge source type (for example, SharePoint)"*. |
| `dependencies.duration` usability | ❌ **VERIFIED LIMITATION** | *"The `duration` value isn't available for traces of agents powered by the standard harness."* Do not build latency KPIs on it. |

### 7.3 APIM

| Item | Status | Detail |
| --- | --- | --- |
| All `ApiManagementGatewayLogs` columns used | ✅ **VERIFIED** | Full column list confirmed at <https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/apimanagementgatewaylogs>. |
| `BackendResponseBody` populated by default | ⚠️ **UNVERIFIED** | Column exists; body logging must be explicitly enabled on the diagnostic setting and is size-limited. |
| `semanticPartialResponseReason` regex in `Q8d` | ⚠️ **UNVERIFIED** | Exact JSON body shape not published. |
| `CorrelationId` propagating to/from Copilot Studio | ⚠️ **UNVERIFIED** | Column exists; end-to-end propagation across the connector is not documented. |

### 7.4 ADF / Functions

| Item | Status | Detail |
| --- | --- | --- |
| `ADFPipelineRun` / `ADFActivityRun` table + category names | ✅ **VERIFIED** | |
| `Status`, `PipelineName`, `ActivityName`, `ActivityType`, `RunId`, `CorrelationId` | ⚠️ **VERIFIED BY RULE** | Derived from the documented Azure Monitor → Log Analytics transformation (*"The first letter in each column name is capitalized"*), not shown in a sample query. Guarded with `column_ifexists()` where riskiest. |
| `ErrorCode` (int), `ErrorMessage` (string), `Error` / `Input` / `Output` (dynamic) | ✅ **VERIFIED** | Explicit mapping table in the ADF monitoring data reference. |
| `FunctionAppLogs` as the Functions table | ✅ **VERIFIED** | |
| `FunctionAppLogs.Level` values `Error` / `Critical` | ⚠️ **UNVERIFIED** | Standard log-level convention; the enum is not published on that page. |
| `FunctionAppLogs.FunctionName` | ⚠️ **UNVERIFIED** | Guarded with `column_ifexists()`. |

---

## 8. Complete source list

**Azure AI Search**
- <https://learn.microsoft.com/en-us/azure/search/monitor-azure-cognitive-search>
- <https://learn.microsoft.com/en-us/azure/search/monitor-azure-cognitive-search-data-reference>
- <https://learn.microsoft.com/en-us/azure/search/search-performance-analysis>
- <https://learn.microsoft.com/en-us/azure/search/search-capacity-planning>
- <https://learn.microsoft.com/en-us/azure/search/semantic-how-to-query-request>
- <https://learn.microsoft.com/en-us/azure/search/semantic-search-overview>
- <https://learn.microsoft.com/en-us/azure/search/search-monitor-queries>
- <https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity>
- <https://learn.microsoft.com/en-us/azure/search/search-security-api-keys>
- <https://learn.microsoft.com/en-us/azure/search/service-create-private-endpoint>

**Copilot Studio**
- <https://learn.microsoft.com/en-us/microsoft-copilot-studio/telemetry-overview>
- <https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-bot-framework-composer-capture-telemetry>
- <https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-environment-level-agent-telemetry>
- <https://learn.microsoft.com/en-us/microsoft-copilot-studio/analytics-overview>
- <https://learn.microsoft.com/en-us/microsoft-copilot-studio/analytics-improve-agent-effectiveness>
- <https://learn.microsoft.com/en-us/microsoft-copilot-studio/analytics-improve-agent-health>
- <https://learn.microsoft.com/en-us/microsoft-copilot-studio/analytics-transcripts-powerapps>
- <https://learn.microsoft.com/en-us/microsoft-copilot-studio/analytics-transcripts-studio>
- <https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-azure-ai-search>
- <https://learn.microsoft.com/en-us/microsoft-copilot-studio/guidance/kit-overview>
- <https://learn.microsoft.com/en-us/microsoft-copilot-studio/guidance/kit-conversation-kpi>
- <https://learn.microsoft.com/en-us/power-platform/admin/set-up-export-application-insights>
- <https://learn.microsoft.com/en-us/power-platform/admin/vnet-support-setup-configure>
- <https://learn.microsoft.com/en-us/connectors/azureaisearch>
- <https://github.com/open-telemetry/semantic-conventions-genai>

**API Management**
- <https://learn.microsoft.com/en-us/azure/api-management/monitor-api-management-reference>
- <https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/apimanagementgatewaylogs>
- <https://learn.microsoft.com/en-us/azure/azure-monitor/reference/queries/apimanagementgatewaylogs>

**Data Factory / Functions**
- <https://learn.microsoft.com/en-us/azure/data-factory/monitor-data-factory-reference>
- <https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/adfpipelinerun>
- <https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/adfactivityrun>
- <https://learn.microsoft.com/en-us/azure/azure-functions/monitor-functions-reference>
- <https://learn.microsoft.com/en-us/azure/azure-functions/functions-monitoring>
- <https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/functionapplogs>

**Azure Monitor / Workbooks / KQL**
- <https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-overview>
- <https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-create-workbook>
- <https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-data-sources>
- <https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-parameters>
- <https://learn.microsoft.com/en-us/azure/azure-monitor/logs/cross-workspace-query>
- <https://learn.microsoft.com/en-us/azure/azure-monitor/logs/summary-rules>
- <https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/create-diagnostic-settings>
- <https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/resource-logs-schema>
- <https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-types>
- <https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-log-alert-query-samples>
- <https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-common-schema>
- <https://aka.ms/amba>

**GitHub**
- <https://github.com/microsoft/Application-Insights-Workbooks>
- <https://github.com/microsoft/Application-Insights-Workbooks/tree/master/Workbooks>
- <https://github.com/microsoft/Application-Insights-Workbooks/tree/master/Workbooks/Copilot%20Studio>
- <https://github.com/microsoft/Application-Insights-Workbooks/tree/master/Workbooks/Azure%20API%20Management/Analytics>
- <https://github.com/microsoft/Application-Insights-Workbooks/tree/master/Workbooks/Azure%20Machine%20Learning/AI%20Studio>
- <https://github.com/microsoft/AzureMonitorCommunity>
- <https://github.com/microsoft/AzureMonitorCommunity/tree/master/Azure%20Services>
- <https://github.com/microsoft/AzureMonitorCommunity/tree/master/Azure%20Services/Power%20Platform>

---

## 9. Recommended next steps (in order)

1. **Run the discovery queries** (`Q0`, `Q0b`, `Q6-0a`, `Q6-0b`, `Q6-0c`, `Q10-pre`) — resolves every UNVERIFIED field name and answers the 206-in-logs question definitively.
2. **Demo the two workbooks that already exist**: `Copilot Studio Dashboard` (App Insights > Monitoring > Workbooks) and `Azure API Management / Analytics`, plus the **Agents (preview) > Tools** blade.
3. **Turn on "Log conversation details"** on the Copilot Studio agent (with DLP/privacy review) so `gen_ai.tool.call.arguments` / `.result` populate — this is the single change that most directly closes the "black box" gap.
4. **Confirm the Search diagnostic setting** sends `OperationLogs` **and** `AllMetrics` to the shared workspace.
5. **Enable APIM `GatewayLogs`** with sampled response-body capture — the only documented route to `semanticPartialResponseReason`.
6. **Fork the Copilot Studio Dashboard workbook** and add tabs 2–6 from [Section 4.3](#43-workbook-structure-to-build).
7. **Baseline for 2 weeks**, then enable alerts A1–A20 with tuned thresholds.
8. **Address the root cause in parallel**: 7 concurrent semantic queries per turn against a documented ceiling of 10 per replica. Options: reduce fan-out, consolidate indexes, disable semantic ranking on low-value indexes, add replicas, or file the support ticket the docs invite.

---

## 10. Clarifying questions for the user / customer

1. **Which Copilot Studio telemetry scope is actually configured** — agent-level (`customEvents`), environment-level preview (`dependencies`), or both? Their sample record matches neither documented schema, which suggests a preview build or a different export path.
2. **Is the environment a Managed Environment?** Environment-level telemetry is Managed-Environments-only.
3. **Is `DisableLocalAuth` set to `true`** on the shared Application Insights resource? If so, Copilot Studio environment-level export will silently fail (docs require "Local authentication" ON).
4. **Is the Application Insights resource workspace-based**, and do Search / APIM / ADF / Functions all write to that **same** Log Analytics workspace? Determines whether `workspace()`/`app()` are needed at all.
5. **Is the Azure AI Search diagnostic setting already enabled**, and does it include `OperationLogs` *and* `AllMetrics`? Without it, roughly half of these queries return nothing.
6. **Is APIM `GatewayLogs` enabled, and is response-body logging on?** Required for the only documented 206-reason capture path.
7. **What is the Search tier and current replica/partition count?** Needed to evaluate the 7-concurrent-semantic-queries-vs-10-per-replica ceiling.
8. **Is semantic ranking enabled on all 7 indexes, or only some?** Changes the effective concurrency math and offers a cheap mitigation.
9. **Which connection auth type is in use** (Access Key / Client Cert / Service Principal / Entra ID Integrated)? Central to the 403 diagnosis — Microsoft's own guidance recommends Entra ID over API keys.
10. **Is Azure AI Search behind a private endpoint with Power Platform VNet support configured?** A partial VNet configuration is a documented 403 source.
11. **Is "Log conversation details" currently ON?** If off, tool arguments/results are absent regardless of everything else.
12. **Are the 613 403s concentrated in time** (one incident) **or spread evenly** (persistent misconfiguration)? Changes the whole investigation path.
13. **Are enhanced transcripts enabled** (node-level `nodeTraceData`)? Free per-lookup latency for the fan-out if so.
14. **Which Power BI reports exist today**, and should this workbook replace or complement them?
15. **Preferred deliverable**: a ready-to-import `.workbook` JSON, an ARM/Bicep template for workbook + alerts, or the KQL library only?
