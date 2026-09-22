---
title: KQL Query Library
description: Runnable Log Analytics queries that diagnose the Azure AI Search 206 partial responses and the 613 Copilot Studio connector 403 errors
author: Microsoft
ms.date: 2026-09-22
ms.topic: troubleshooting
keywords:
  - azure ai search
  - copilot studio
  - kusto
  - log analytics
  - api management
estimated_reading_time: 8
---

Nine queries, grouped into three tiers. The first tier establishes what your telemetry actually contains, the second quantifies the fan-out and the capacity pressure behind the 206 partial responses, and the third attributes the 403 errors to a specific layer.

Run them in the order below. The discovery tier is not optional: the span shape observed in this environment matches neither documented Copilot Studio telemetry schema, and Azure AI Search has no dedicated Log Analytics table, so the column names every other query depends on have to be confirmed against real data before they can be trusted.

## How to run these

Paste a file into the Logs blade of the Log Analytics workspace that receives this environment's diagnostics, or into the Logs blade of the shared Application Insights component. This engagement uses a single component across Copilot Studio, Azure AI Search, and the Functions ingestion pipeline, so every Search query filters on `ResourceProvider == "MICROSOFT.SEARCH"` to keep other providers out of the result set.

Each file opens with a comment block covering purpose, prerequisites, target table, and how to read the output. Each file also declares a `let lookback = ...;` parameter on its first executable line so no query ever scans unbounded history. Adjust it before running.

Several files carry commented-out companion queries below the main body. Uncomment one at a time; the parameter declarations are repeated inside each companion so they run standalone.

## Run order

| Order | Query                                                                                | Prerequisite                                                 | What it proves or disproves                                                                      |
| ----- | ------------------------------------------------------------------------------------ | ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------ |
| 1     | [00-discover-dependency-types.kql](00-discover-dependency-types.kql)                 | Copilot Studio telemetry export to Application Insights      | Which span shape this environment really emits, and therefore whether files 22 and 23 need edits |
| 2     | [01-discover-search-diagnostic-shape.kql](01-discover-search-diagnostic-shape.kql)   | Search diagnostic setting, `OperationLogs`                   | Which `AzureDiagnostics` columns are populated, and whether Search ever logs a 206               |
| 3     | [23-design-mode-vs-published.kql](23-design-mode-vs-published.kql)                   | Copilot Studio telemetry export                              | Whether the 403s hit production users or only the authoring test canvas                          |
| 4     | [20-apim-403-triage.kql](20-apim-403-triage.kql)                                     | APIM `GatewayLogs`, non-Consumption tier                     | Whether APIM rejected the request or Azure AI Search did                                         |
| 5     | [22-connector-403-by-index.kql](22-connector-403-by-index.kql)                       | Copilot Studio telemetry export plus `OperationLogs`         | Whether the 403s concentrate on a subset of the seven indexes                                    |
| 6     | [10-fan-out-ratio.kql](10-fan-out-ratio.kql)                                         | Search diagnostic setting, `OperationLogs`                   | The per-turn query amplification factor                                                          |
| 7     | [11-search-by-http-result-code.kql](11-search-by-http-result-code.kql)               | Search diagnostic setting, `OperationLogs`                   | The Search-side distribution of 200, 206, 403, 429, and 503                                      |
| 8     | [12-semantic-capacity-headroom.kql](12-semantic-capacity-headroom.kql)               | Search diagnostic setting, `OperationLogs` plus `AllMetrics` | Whether concurrent semantic load reaches the in-flight ceiling for the tier                      |
| 9     | [21-apim-206-semantic-partial-capture.kql](21-apim-206-semantic-partial-capture.kql) | APIM `GatewayLogs` with response-body logging enabled        | Why each 206 occurred: `Transient` or `CapacityOverloaded`                                       |

Start at position 3 rather than position 6 if the priority is the 403s. Start at position 6 if the priority is the 206s. Positions 1 and 2 come first either way.

## Tier 1: discovery

These two exist because the schema cannot be assumed.

The sampled 403 record from this environment shows `type: "Connector"`, `name: "Azure AI Search"`, and custom dimensions prefixed `attributes.`. Microsoft's documented Copilot Studio environment-level schema publishes `type: "GenAI"`, `name: "ExecuteTool"`, and dimensions prefixed `gen_ai.`. Neither documented schema matches what was observed, which is tracked as open item U8. Building a dashboard on the wrong naming convention produces an empty dashboard that looks like a healthy one.

On the Search side, the resource logs land in the shared `AzureDiagnostics` table rather than a dedicated one, and the KQL column names carry type suffixes that differ from the logical names in the data reference. Write `resultSignature_d`, not `ResultSignature`.

| File                                                                               | Answers                                                                                       |
| ---------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| [00-discover-dependency-types.kql](00-discover-dependency-types.kql)               | Open item U8. Enumerates the live `(type, name, target)` triples and custom dimension keys    |
| [01-discover-search-diagnostic-shape.kql](01-discover-search-diagnostic-shape.kql) | Open item U6. Lists the populated columns and settles whether 206 reaches `resultSignature_d` |

If either returns zero rows, stop. Telemetry is not flowing, and the most common cause is `DisableLocalAuth` set on the Application Insights component, which makes the Copilot Studio export fail silently. Run `scripts/Enable-DiagnosticSettings.ps1` before going further.

## Tier 2: fan-out and capacity

This tier builds the quantitative case behind the 206 partial responses.

The agent has seven knowledge sources attached. Copilot Studio only filters knowledge sources with an internal model above 25 sources, so below that threshold every user turn queries all seven. Seven concurrent semantic requests per turn is the number that makes the rest of the arithmetic work.

Azure AI Search admits semantic ranking requests through a queue sized per search unit, where search units equal replicas multiplied by partitions:

| Tier  | Max concurrent per SU | Max queue per SU | In flight before rejection |
| ----- | --------------------- | ---------------- | -------------------------- |
| Basic | 2                     | 4                | 6                          |
| S1    | 3                     | 6                | 9                          |
| S2    | 4                     | 8                | 12                         |
| S3    | 4                     | 8                | 12                         |

Basic at one search unit admits 6 in flight. The agent needs 7 for a single turn. That gap is the strongest supported explanation for the 206s and for why the move to S1 helped so much. It remains an explanation rather than a confirmed cause until file 21 shows the reason string.

| File                                                                   | Tests                                                                            |
| ---------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| [10-fan-out-ratio.kql](10-fan-out-ratio.kql)                           | That one user turn produces roughly seven Search queries across seven indexes    |
| [11-search-by-http-result-code.kql](11-search-by-http-result-code.kql) | Which failure modes appear Search-side, keeping 206, 403, 429, and 503 separate  |
| [12-semantic-capacity-headroom.kql](12-semantic-capacity-headroom.kql) | Whether estimated concurrency reaches the in-flight ceiling for the current tier |

Two annotations travel with this tier. The 206 bucket in file 11 is marked unverified, because no Microsoft sample confirms that Search writes 206 into `resultSignature_d`. The concurrency figure in file 12 is an inference from throughput and mean latency, not a counter Microsoft publishes.

There is also a documented conflict worth raising with Microsoft support. The service-limits page states 2 or 3 concurrent requests per search unit plus a queue; the semantic ranking how-to states 10 concurrent queries per replica. Different magnitudes, different units. File 12 implements the limits table.

## Tier 3: 403 and 206 attribution

Azure AI Search returns 403 for authorization and network policy denial. It does not return 403 for quota, and it does not return 403 for storage exhaustion; semantic free-plan exhaustion returns 402. So the 403s and the 206s are two independent problems, and the tier change that helped the 206s cannot explain the 403s.

| File                                                                                 | Tests                                                                                 |
| ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------- |
| [23-design-mode-vs-published.kql](23-design-mode-vs-published.kql)                   | What share of the 403s came from the authoring canvas rather than a published channel |
| [20-apim-403-triage.kql](20-apim-403-triage.kql)                                     | Whether APIM policy or the Search backend originated each 403                         |
| [22-connector-403-by-index.kql](22-connector-403-by-index.kql)                       | Whether a role assignment scoped to six of seven indexes explains the intermittency   |
| [21-apim-206-semantic-partial-capture.kql](21-apim-206-semantic-partial-capture.kql) | Whether the 206 reason is `Transient` or `CapacityOverloaded`                         |

### Why file 20 is the highest-value query here

`ResponseCode` is what APIM returned to Copilot Studio. `BackendResponseCode` is what Azure AI Search returned to APIM. Divergence between the two is the definitive attribution, and it bisects the entire hypothesis space in one pass:

* A backend 403 points at Search authorization: RBAC scoping, key-based auth disabled, or an IP firewall allow-list that no longer covers the current connector egress prefixes.
* An APIM-originated 403 points at policy. Quota and quota-by-key are the only APIM throttling policies that return 403; rate-limit returns 429. An ip-filter denial lands here too. A missing or invalid subscription key returns 401, which rules that cause out entirely.

One query collapses roughly thirteen candidate causes to about four.

### Why file 21 has a hard prerequisite

`@search.semanticPartialResponseReason` is not in the Azure AI Search resource-log schema. The documented `Properties` sub-schema contains four fields: `Description_s`, `Documents_d`, `IndexName_s`, and `Query_s`. The reason string exists only in the HTTP response body returned to the caller.

APIM is the only component in the path that can capture that body, and only when response-body logging is explicitly enabled on the `GatewayLogs` diagnostic setting. Without it, `BackendResponseBody` is empty and file 21 returns nothing useful. Bodies are truncated to a configured byte limit, and body logging carries privacy and data-loss-prevention implications that need review before production use.

This constraint is the strongest argument for keeping APIM in the request path.

### Why file 23 runs first among the 403 queries

It needs no new diagnostic settings, and it answers a severity question in about thirty seconds. The sampled 403 carries `DesignMode: "True"` and `channelId: "pva-studio"`, both of which say the failure happened while a maker was testing in the authoring canvas rather than while a customer was using the published agent.
If that pattern holds across all 613 errors, production is unaffected and the investigation narrows to maker-scoped connection instances, which the connector documents as not shareable. If it does not hold, real users are being failed.

## Prerequisites by diagnostic category

| Diagnostic setting                                            | Enables                    | Needed by                |
| ------------------------------------------------------------- | -------------------------- | ------------------------ |
| Search service, `OperationLogs`                               | `AzureDiagnostics` rows    | Files 01, 10, 11, 12, 22 |
| Search service, `AllMetrics`                                  | `AzureMetrics` rows        | File 12 companion B      |
| APIM, `GatewayLogs`                                           | `ApiManagementGatewayLogs` | Files 20, 21             |
| APIM, `GatewayLogs` with response-body logging                | `BackendResponseBody`      | File 21                  |
| Copilot Studio export to Application Insights                 | `dependencies` rows        | Files 00, 22, 23         |
| Copilot Studio export with "Log conversation details" enabled | Tool arguments and results | File 22 section 3        |

Two conditions block this plan outright. APIM on the Consumption tier supports no resource logs at all, which removes files 20 and 21. An Application Insights component with `DisableLocalAuth` set makes the Copilot Studio export fail silently, which removes files 00, 22, and 23. Check both before enabling anything.

Run `scripts/Enable-DiagnosticSettings.ps1` to close these gaps. It performs both pre-flight checks.

## Open items these queries resolve

| Item | Gap                                                        | Resolved by                              |
| ---- | ---------------------------------------------------------- | ---------------------------------------- |
| U1   | No source links the `Transient` reason to tier or capacity | File 21, if `CapacityOverloaded` appears |
| U2   | Who sets `semanticErrorHandling` to `partial`              | File 21, companion B                     |
| U3   | Effective `semanticMaxWaitInMilliseconds` when omitted     | File 21, companion B                     |
| U6   | Whether Search emits 206 into `resultSignature_d`          | File 01, section 3                       |
| U8   | Observed span shape matches neither documented schema      | File 00                                  |
| U9   | APIM tier, and whether gateway logs are available at all   | Checked before files 20 and 21           |

Open items U4, U5, U7, U10, and U11 cannot be closed with a query. They are carried into the support escalation instead.

## A note on thresholds

Microsoft publishes no threshold for an acceptable 206 rate, no threshold for a connector 403 rate, and no guidance on what constitutes normal fan-out. Every numeric threshold suggested in these files is an engineering recommendation. Collect two weeks of baseline before committing any of them to an alert rule.
