---
title: Azure AI Search support ticket draft
description: Ready-to-submit Azure support request covering the HTTP 206 partial semantic responses, the seven-index fan-out, and the four questions only Microsoft support can settle.
author: Microsoft
ms.date: 2026-09-22
ms.topic: troubleshooting
keywords:
  - azure ai search
  - semantic ranker
  - support request
  - partial content
  - capacity
estimated_reading_time: 15
---

Microsoft's own documentation instructs customers in this exact situation to file. From [Add semantic ranking, Expected workloads](https://learn.microsoft.com/en-us/azure/search/semantic-how-to-query-request):

> If you anticipate consistent throughput requirements near, at, or higher than this level, please file a support ticket so that we can provision for your workload.

That sentence converts this case from a request for analysis into a documented, in-scope support scenario, and it is the single strongest justification available. Quote it in the case and cite the page.

The same page names the signature the service emits when it is at capacity for semantic ranking: `Operation returned an invalid status 'Partial Content'`, `@search.semanticPartialResponseReason`, and `CapacityOverloaded`. Two of those three match this environment exactly. The third does not, and closing that gap is one of the four asks below.

## How to read this draft

Everything inside a fenced block is submittable text. Fill the placeholders, delete nothing else. Everything outside the fenced blocks is guidance for the person filing and does not belong in the case.

Claims attributed to Microsoft carry an inline Microsoft Learn link. Conclusions drawn from the evidence rather than from documentation begin with **Inferred:** and are presented in the case as observations, never as Microsoft's own position.

## Placeholders to fill in

| Placeholder | What it is | Where to find it |
|-------------|------------|------------------|
| `<SUBSCRIPTION_ID>` | Subscription holding the search service | Azure portal, search service Overview blade, or `subscriptionId` in the script output |
| `<TENANT_ID>` | Microsoft Entra tenant identifier | `az account show --query tenantId` |
| `<RESOURCE_GROUP>` | Resource group holding the search service | Azure portal, Overview blade |
| `<SEARCH_SERVICE_NAME>` | Name of the search service | Azure portal, Overview blade |
| `<REGION>` | Region the service runs in | Azure portal Overview blade, or `location` in the script output |
| `<CREATION_DATE>` | Service creation or upgrade date | [Check your service creation or upgrade date](https://learn.microsoft.com/en-us/azure/search/search-how-to-upgrade), or the `createdDate` finding in the script output |
| `<BASIC_REPLICAS>` and `<BASIC_PARTITIONS>` | Replica and partition counts in force when the failures occurred | Activity log for the service, or the team's own change record. Not recoverable from the current configuration |
| `<BASIC_SU>` | `<BASIC_REPLICAS>` multiplied by `<BASIC_PARTITIONS>` | Arithmetic |
| `<S1_REPLICAS>` and `<S1_PARTITIONS>` | Current replica and partition counts | `replicaCount` and `partitionCount` in the script output |
| `<S1_SU>` | `<S1_REPLICAS>` multiplied by `<S1_PARTITIONS>` | Arithmetic |
| `<TIER_CHANGE_DATE_UTC>` | Date the service moved from Basic to S1 | Activity log for the service |
| `<SEMANTIC_PLAN>` | `free` or `standard` | `properties.semanticSearch` in the script output |
| `<NETWORK_POSTURE>` | Public endpoint, private endpoint, or IP firewall | `publicNetworkAccess` and `networkRuleSet.ipRules` in the script output |
| `<API_VERSION>` | REST API version the connector calls with | API Management gateway logs, or the connector configuration |
| `<SEMANTIC_CONFIG_NAME>` | Semantic configuration name on a representative index | Index definition JSON |
| `<QUERY_TEXT>` | A search string that reproduces the failure | A conversation that failed, from the Copilot Studio conversation history |
| `<SELECT_FIELDS>` | Fields the connector requests | Connector configuration, or a captured request body |
| `<FAILURE_TIMESTAMP_1>` through `<FAILURE_TIMESTAMP_5>` | UTC timestamps of individual failures | [kql/11-search-by-http-result-code.kql](../kql/11-search-by-http-result-code.kql) or the Application Insights dependency records |
| `<REQUEST_ID_1>` through `<REQUEST_ID_5>` | `x-ms-request-id` response header per failure | Captured response headers, or API Management gateway logs |
| `<INDEX_NAME_1>` through `<INDEX_NAME_5>` | Index each failure targeted | `IndexName_s` in `AzureDiagnostics` |
| `<PEAK_CONCURRENT_TURNS>` | Peak simultaneous conversational turns, not users per hour | [kql/12-semantic-capacity-headroom.kql](../kql/12-semantic-capacity-headroom.kql) |
| `<TARGET_CONCURRENT_TURNS>` | Concurrent turns the service must sustain after growth | The team's own projection |
| `<PP_CASE_NUMBER>` | Power Platform case number | Leave as `not yet filed` if the Copilot Studio case comes later |

Run [scripts/Get-SearchServiceDiagnostics.ps1](../scripts/Get-SearchServiceDiagnostics.ps1) before filling this table. It produces most of these values in one pass and writes them to a JSON file that attaches to the case:

```powershell
./scripts/Get-SearchServiceDiagnostics.ps1 `
  -ResourceGroupName '<RESOURCE_GROUP>' `
  -ServiceName '<SEARCH_SERVICE_NAME>' `
  -ConcurrentTurnTarget <TARGET_CONCURRENT_TURNS> `
  -OutputPath './evidence/search-capacity.json'
```

## Where to file this

| Field | Value |
|-------|-------|
| Portal | <https://portal.azure.com> |
| Entry point | The search service, then Help, then Support plus Troubleshooting. This attaches the resource context to the case |
| Issue type | Technical |
| Service | Azure AI Search |
| Subscription | `<SUBSCRIPTION_ID>` |
| Severity | B, moderate business impact |
| Advanced diagnostic information | Yes |
| File uploads | One file, so bundle everything into a single archive |

[How to create an Azure support request](https://learn.microsoft.com/en-us/azure/azure-portal/supportability/how-to-create-azure-support-request) states that the filer needs Owner, Contributor, or Support Request Contributor at the subscription level, and that technical support requires a support plan. Confirm both before starting the wizard.

## What is known and what is being asked

This case does not ask Microsoft to diagnose from scratch. The mechanism is already narrowed. Presenting it that way shortens the case and keeps the engineer working on the part only Microsoft can answer.

| Established | Basis |
|-------------|-------|
| The agent issues seven concurrent semantic requests on every user turn | Copilot Studio filters knowledge sources with an internal model only above 25 sources ([knowledge in Copilot Studio](https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-copilot-studio)), and this agent has seven |
| Basic at one search unit admits six semantic requests in flight | Two concurrent plus four queued per search unit ([Service limits and quotas](https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity)) |
| Seven requests against six slots degrades on a single turn with no other users | Arithmetic on the two rows above |
| S1 raises the same figure to nine in flight per search unit | Three concurrent plus six queued per search unit |
| A 206 is invisible to standard monitoring | It is a 2xx, so gateways, dashboards, and retry policies keyed on 429 or 5xx treat it as success |
| The observed partial responses report `Transient` and `BaseResults` | Captured from the response bodies in this environment |

| Being asked | Why only Microsoft can answer |
|-------------|-------------------------------|
| Which published concurrency figure governs this service | Two Microsoft pages state different magnitudes in different units |
| Whether the semantic concurrency allocation can be raised | The limits page directs customers to contact support for a limit increase and describes the limits as subject to regional capacity |
| Whether `Transient` is emitted under capacity pressure | No Microsoft source links `Transient`, as distinct from `CapacityOverloaded`, to tier or capacity |
| What sets `semanticErrorHandling` to `partial` | The documented default is to fail, and the connector does not expose the parameter |

**Inferred:** the capacity ceiling is the strongest supported explanation for the observed partial responses, and the tier and replica changes behaved exactly as the published limits predict. It remains an explanation rather than a confirmed cause until the third ask below is answered. The full reasoning is in [docs/rca-206-semantic-concurrency.md](../docs/rca-206-semantic-concurrency.md).

## Case title

```text
Intermittent HTTP 206 semantic partial responses under a 7-index fan-out; request authoritative semantic ranker concurrency limits, a limit review, and sizing guidance
```

## Problem description

```text
SUMMARY
Our Azure AI Search service returns intermittent HTTP 206 Partial Content responses carrying
@search.semanticPartialResponseReason. When this occurs the response contains no rerankerScore,
no captions, and no answers, so our downstream Microsoft Copilot Studio agent produces empty or
ungrounded answers even though the indexes contain matching content.

Per https://learn.microsoft.com/en-us/azure/search/semantic-how-to-query-request ("Expected
workloads"), this signature indicates the service is at capacity for semantic ranking, and that
page instructs customers anticipating throughput at or above that level to file a support ticket
so the workload can be provisioned. That is the purpose of this request.

ENVIRONMENT
- Search service name: <SEARCH_SERVICE_NAME>
- Resource ID: /subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<RESOURCE_GROUP>/providers/Microsoft.Search/searchServices/<SEARCH_SERVICE_NAME>
- Subscription ID: <SUBSCRIPTION_ID>
- Tenant ID: <TENANT_ID>
- Region: <REGION>
- Service creation date: <CREATION_DATE>
- Tier AT TIME OF FAILURE: Basic, <BASIC_REPLICAS> replicas x <BASIC_PARTITIONS> partitions = <BASIC_SU> search units
- Tier NOW: S1, <S1_REPLICAS> replicas x <S1_PARTITIONS> partitions = <S1_SU> search units (changed <TIER_CHANGE_DATE_UTC>)
- Number of indexes: 7, one per business unit
- Semantic ranker billing plan (properties.semanticSearch): <SEMANTIC_PLAN>
- Network posture: <NETWORK_POSTURE>

QUERY PATTERN, WHICH IS THE CRUX OF THIS CASE
A single end-user turn in our Copilot Studio agent fans out to ALL 7 indexes. Each index is
queried with semantic ranking enabled and returns its top 3 documents, and the results are merged
for generative answer synthesis. One user turn therefore issues approximately 7 concurrent
semantic ranker requests against this single search service.

This is fixed behavior on the Copilot Studio side. Per
https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-copilot-studio, generative
orchestration filters knowledge sources using an internal model only when there are more than 25
knowledge sources. We have 7, so no filtering occurs and all 7 are queried every turn.

Cross-referencing the semantic ranker throttling limits at
https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity :
  - Basic: 2 concurrent semantic requests per search unit, queue size 4 -> 6 in flight at 1 SU
  - S1:    3 concurrent semantic requests per search unit, queue size 6 -> 9 in flight at 1 SU

A single 7-index turn therefore exceeds the total in-flight semantic capacity of a 1-SU Basic
service on its own, with zero concurrent users. This is consistent with every symptom we
observed, including the fact that failures were intermittent and appeared to affect different
indexes at random, since the 7 parallel requests race for the same shared admission queue.

WHAT WE OBSERVED
- Intermittent HTTP 206 responses across all 7 indexes, nondeterministically
- The partial-response fields we captured read:
      "@search.semanticPartialResponseReason": "Transient"
      "@search.semanticPartialResponseType": "BaseResults"
  We have NOT observed the "CapacityOverloaded" reason named in the Expected workloads doc.
  Question 3 below asks about this specifically.
- Empty downstream answers despite the indexes containing matching content
- Measured load was low in absolute terms, approximately 7 to 15 users per hour
- Increasing the replica count measurably reduced the failures
- Moving Basic -> S1 resolved the failures in large part, but not entirely

MITIGATION ALREADY APPLIED
- Increased replica count from <BASIC_REPLICAS> to <S1_REPLICAS>
- Upgraded the tier Basic -> S1 on <TIER_CHANGE_DATE_UTC>
- Verified properties.semanticSearch is <SEMANTIC_PLAN>
- Reviewed the sessionId the caller passes, since reusing a constant value is documented to
  interfere with load balancing across replicas
- Failures are substantially reduced but we do not consider the issue closed, and we have growth
  ahead of us

FAILURE EVIDENCE, ALL TIMES UTC
1. <FAILURE_TIMESTAMP_1> - x-ms-request-id: <REQUEST_ID_1> - index: <INDEX_NAME_1>
2. <FAILURE_TIMESTAMP_2> - x-ms-request-id: <REQUEST_ID_2> - index: <INDEX_NAME_2>
3. <FAILURE_TIMESTAMP_3> - x-ms-request-id: <REQUEST_ID_3> - index: <INDEX_NAME_3>
4. <FAILURE_TIMESTAMP_4> - x-ms-request-id: <REQUEST_ID_4> - index: <INDEX_NAME_4>
5. <FAILURE_TIMESTAMP_5> - x-ms-request-id: <REQUEST_ID_5> - index: <INDEX_NAME_5>
Raw 206 response bodies for each are in the attached archive.

REPRODUCIBLE QUERY
POST https://<SEARCH_SERVICE_NAME>.search.windows.net/indexes/<INDEX_NAME_1>/docs/search?api-version=<API_VERSION>
{
  "search": "<QUERY_TEXT>",
  "queryType": "semantic",
  "semanticConfiguration": "<SEMANTIC_CONFIG_NAME>",
  "captions": "extractive|highlight-true",
  "answers": "extractive|count-3",
  "top": 3,
  "select": "<SELECT_FIELDS>"
}
Issuing this concurrently against all 7 indexes reproduces the 206 at Basic with <BASIC_SU>
search units.

WHAT WE ARE ASKING FOR

1. WHICH PUBLISHED CONCURRENCY FIGURE IS AUTHORITATIVE FOR OUR SERVICE?
   Two Microsoft pages state different numbers in different units and we cannot size against both:
     - https://learn.microsoft.com/en-us/azure/search/semantic-how-to-query-request
       ("Expected workloads") states "up to 10 concurrent queries per REPLICA"
     - https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity
       ("Semantic ranker throttling limits") states 2 (Basic) / 3 (S1) / 4 (S2 and S3) concurrent
       requests per SEARCH UNIT, plus a queue of 4 / 6 / 8
   These differ in both magnitude and unit of measure. Please confirm which governs our tier,
   region, and search-unit configuration, and whether the two describe different things.

2. CAN THE SEMANTIC RANKER CONCURRENCY ALLOCATION FOR THIS SERVICE BE CONFIRMED OR RAISED?
   The limits page states the semantic ranker throttling limits are "subject to available capacity
   in the region" and that customers can contact Microsoft support to request a limit increase.
   Given a fixed fan-out of 7 concurrent semantic requests per user turn, please confirm:
     a. The concurrency and queue allocation currently in force for this specific service
     b. Whether an increase is available for this service and region
     c. What evidence you need in order to approve one
     d. Whether regional semantic ranker capacity in <REGION> contributed during the failure
        windows listed above, which is a factor we cannot observe

3. IS "Transient" EMITTED UNDER CAPACITY PRESSURE, OR ONLY "CapacityOverloaded"?
   Every partial response we captured reports reason "Transient" and type "BaseResults". The
   Expected workloads doc names "CapacityOverloaded" as the capacity signature, and
   https://learn.microsoft.com/en-us/rest/api/searchservice/documents/search-post defines
   "transient" only as "At least one step of the semantic process failed."
   Please confirm whether semantic admission-queue rejection can surface as "Transient" rather
   than "CapacityOverloaded", and if so under what conditions. This determines whether our
   capacity analysis is confirmed or remains a strong correlation.

4. WHAT SETS semanticErrorHandling TO "partial" ON OUR REQUESTS?
   https://learn.microsoft.com/en-us/rest/api/searchservice/documents/search-post documents the
   default for semanticErrorHandling as failing the request completely. Partial responses only
   occur under "partial". Yet we receive partial responses, and the Azure AI Search connector at
   https://learn.microsoft.com/en-us/connectors/azureaisearch/ exposes neither
   semanticErrorHandling nor semanticMaxWaitInMilliseconds, so we cannot set or read either one.
   Please confirm what is setting "partial" on our requests, and what effective value of
   semanticMaxWaitInMilliseconds applies when the parameter is omitted. The documented minimum is
   700 ms and no default is published.

SECONDARY QUESTIONS, IF CASE TIME PERMITS

5. Please review our sizing model. We need to sustain <TARGET_CONCURRENT_TURNS> concurrent user
   turns, each issuing 7 concurrent semantic requests. We understand from
   https://learn.microsoft.com/en-us/azure/search/search-capacity-planning that there are no
   published replica guidelines and that scaling is not linear. We are asking for a review of this
   specific fan-out pattern rather than a general rule.

6. Please confirm whether consolidating the 7 indexes into a single index with a filterable
   business-unit field, reducing the workload to 1 semantic request per turn, is the
   architecturally recommended remediation for this pattern on the classic, non-agentic pipeline.

ATTACHED, AS A SINGLE ARCHIVE
- Raw 206 response bodies for each listed failure
- Search service configuration and capacity audit (JSON)
- Log Analytics AzureDiagnostics export covering the failure windows
- Azure Monitor metrics: Search Latency, Throttled search queries percentage, Search queries per second
- Semantic configuration JSON for all 7 indexes
- Index schema for a representative index
- Application Insights export correlating Copilot Studio turn -> connector -> API Management -> Search
- API Management gateway log export for the same windows
- Indexing job schedule for the same windows, to rule out indexing and query resource contention

RELATED CASE
Copilot Studio and connector case in the Power Platform admin center: <PP_CASE_NUMBER>
```

## Evidence checklist

Work through this before filing. Microsoft's minimum for an Azure AI Search capacity case, from [Service limits and quotas](https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity), is the subscription, region, tier, requested configuration, full error text, UTC time, and any correlation or operation ID. Everything below expands on that.

### Service configuration

* [ ] Search service name and full resource ID
* [ ] Subscription ID and tenant ID
* [ ] Region
* [ ] Tier now, and tier at the time of failure, with the date of the change
* [ ] Replica count and partition count now, and at the time of failure, with search units computed for both
* [ ] Service creation date. Basic services created before 2024-04-03 cap at one partition and three search units, which changes the capacity ceiling and therefore the sizing answer
* [ ] `properties.semanticSearch` value, `free` or `standard`
* [ ] Index count and index names
* [ ] Semantic configuration JSON for each index
* [ ] Network posture: `publicNetworkAccess`, `networkRuleSet.ipRules`, private endpoints, shared private links

All of these appear in the JSON file produced by [scripts/Get-SearchServiceDiagnostics.ps1](../scripts/Get-SearchServiceDiagnostics.ps1). Attach that file rather than retyping the values.

### Failure evidence

* [ ] Exact UTC timestamps for at least three and preferably five failure instances
* [ ] `x-ms-request-id` response header for each, and `request-id` where present
* [ ] Raw 206 response body for each, unredacted, showing both `@search.semanticPartialResponseReason` and `@search.semanticPartialResponseType`
* [ ] Full request body of a query that reproduces the failure
* [ ] A minimal reproducible query a support engineer can run
* [ ] Copilot Studio `conversationId` for the corresponding turns
* [ ] Evidence that the index does hold matching content, such as a successful non-semantic query against the same index and terms
* [ ] The observed fan-out, seven concurrent semantic requests per turn, measured rather than asserted

> [!WARNING]
> `@search.semanticPartialResponseReason` is not in the Azure AI Search resource-log schema. The documented `Properties` sub-schema carries only `Description_s`, `Documents_d`, `IndexName_s`, and `Query_s`.
> The reason string exists solely in the HTTP response body, and API Management with response-body logging enabled is the only component in the path that can capture it. Use [kql/21-apim-206-semantic-partial-capture.kql](../kql/21-apim-206-semantic-partial-capture.kql). Without it the case cannot answer its own third question.

### Telemetry exports

* [ ] `AzureDiagnostics` export for the failure windows, from [kql/11-search-by-http-result-code.kql](../kql/11-search-by-http-result-code.kql)
* [ ] Fan-out measurement from [kql/10-fan-out-ratio.kql](../kql/10-fan-out-ratio.kql)
* [ ] Concurrency headroom estimate from [kql/12-semantic-capacity-headroom.kql](../kql/12-semantic-capacity-headroom.kql)
* [ ] Partial-response reason capture from [kql/21-apim-206-semantic-partial-capture.kql](../kql/21-apim-206-semantic-partial-capture.kql)
* [ ] Azure Monitor metrics: Search Latency, Throttled search queries percentage, Search queries per second
* [ ] API Management gateway logs for the same windows
* [ ] Indexing job timings for the same windows, since indexing and queries share resources with no prioritization

If the diagnostic settings are not yet in place, run [scripts/Enable-DiagnosticSettings.ps1](../scripts/Enable-DiagnosticSettings.ps1) with `-WhatIf` first. Collect at least one failure window after enabling, because a case filed with empty exports spends its first round trip asking for them.

### Pre-flight

* [ ] Azure Service Health checked for Azure AI Search incidents in the region across the failure windows
* [ ] Support plan confirmed active, and the filer holds Owner, Contributor, or Support Request Contributor at subscription scope
* [ ] Attachments reviewed for personal or confidential content, including query text and user identifiers
* [ ] Advanced diagnostic information set to Yes

## What to expect

The engineer will most likely open by validating the capacity arithmetic against the service's actual configuration, which is why the configuration audit is the first attachment. Expect the first two questions to be answered from internal documentation within the first response or two, since they are matters of record rather than investigation.

Questions three and four are harder. Both require the product group to comment on behavior that is not publicly documented, and both may take several exchanges. Keep the case open for them rather than accepting a general capacity recommendation as a complete answer, because the third question is what moves this analysis from a strong correlation to a confirmed cause.

The limit increase in question two is not guaranteed. [Service limits and quotas](https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity) describes the semantic ranker limits as subject to available capacity in the region, so a regional constraint can produce a refusal that no amount of evidence changes.
If that happens, the fan-out reduction in [docs/fan-out-reduction-architecture.md](../docs/fan-out-reduction-architecture.md) becomes the only durable remedy, which is the outcome this package already recommends on its own merits.

## Related material

| Document | Contribution |
|----------|--------------|
| [README.md](README.md) | Routing, sequencing, severity, and the free diagnostics to run before filing |
| [docs/rca-206-semantic-concurrency.md](../docs/rca-206-semantic-concurrency.md) | The full capacity analysis behind this case, including open items U1 through U4 |
| [docs/immediate-mitigations.md](../docs/immediate-mitigations.md) | The mitigations reported in the case as already applied |
| [docs/fan-out-reduction-architecture.md](../docs/fan-out-reduction-architecture.md) | The remedy if the limit increase is refused |
| [copilot-studio-ticket.md](copilot-studio-ticket.md) | The companion case, which cross-references this one |
| [assets/usefulScreenshots.md](../assets/usefulScreenshots.md) | The observed `Transient` and `BaseResults` field values quoted in the case |
