---
title: Immediate mitigations while the RCA completes
description: Eight prioritised interim actions for the Azure AI Search 206 partial responses and the connector 403 failures, with confidence ratings, evidence labels, and the operational constraints that bound each one.
author: Microsoft
ms.date: 2026-09-22
ms.topic: troubleshooting
keywords:
  - azure ai search
  - copilot studio
  - semantic ranker
  - capacity planning
estimated_reading_time: 12
---

## Scope and framing

The agent issues seven simultaneous semantic queries on every user turn, one
per index. Every limit in the request path is therefore multiplied by seven:
semantic ranker concurrency, connector throttling, and API Management quota.
This is an arity problem, not a load problem, which is why a reported load of
roughly 7 to 15 users per hour looked far too small to explain the failures
([meeting notes](../assets/meetingNotes.md)).

That framing decides how to read this document. Buying capacity raises the
ceiling those seven requests hit. It does not reduce the number of requests.
Tier and replica scaling is a stopgap. Reducing the fan-out is the strategic
fix, and it is set out in
[fan-out reduction architecture](./fan-out-reduction-architecture.md).

Everything below is interim. These actions buy headroom and remove
confounding variables so the root cause analysis lands on clean telemetry.

## How to read the evidence and confidence labels

Each action carries two labels. They answer different questions.

| Label      | Meaning                                                   |
|------------|-----------------------------------------------------------|
| Documented | Microsoft states the behaviour directly, with a link      |
| Inferred   | Reasoned from documented behaviour plus customer telemetry |

Confidence is high where the action is safe, cheap, and decisive regardless
of which root cause proves dominant. Confidence is medium where the action
is sound but its effect size on this workload is unproven.

## Constraints that bound every action below

Read these before making any change to the search service.

> [!WARNING]
> Update the search service with PATCH, never PUT. Microsoft states that if
> PUT is used to update an existing service, it replaces all properties with
> their defaults when they are not specified in the request, and recommends
> PATCH when enabling semantic ranking on an existing service
> ([enable or disable semantic ranking][semantic-enable]).

Capacity changes carry a second, different hazard.

> [!CAUTION]
> Replica and partition changes cannot be cancelled. Microsoft states the
> operation occurs in the background so the service remains fully operational
> for read and write, but that it can take several hours and that you cannot
> cancel it or monitor its progress ([estimate capacity][capacity]). Plan the
> change window accordingly, and decide the target count before you start.

The service level agreement rule is fixed and worth restating because it sets
a floor under action 3: two or more replicas satisfy the query (read) SLA,
three or more satisfy the query and indexing (read-write) SLA, and the number
of partitions is not an SLA consideration ([estimate capacity][capacity],
[SLA for Azure AI Search][sla]).

## The eight actions in priority order

### 1. Confirm the semantic ranker is on the standard plan

Evidence: inferred. Confidence: high.

The free semantic ranker allowance is 1,000 requests per month, after which
Microsoft states that semantic ranker requests return a billing error
([pricing][pricing], [enable or disable semantic ranking][semantic-enable]).
At seven requests per turn the customer's own load estimate of 7 to 15 users
per hour produces roughly 8,600 to 37,000 semantic requests per month. A
1,000 request allowance is gone within the first one to three days of every
month.

The cap is documented. That this service is affected by it is inferred, and
it has not been confirmed either way. Check it before any further capacity
work, because if the plan is `free` then semantic ranking is failing for a
billing reason for most of each month and every tier or replica change will
look non-deterministic.

Read the current value from the management plane and inspect
`properties.semanticSearch`. It must be `standard`, not `free`.

```http
GET {resource-id}?api-version=2026-03-01-preview
```

To change it, PATCH the service:

```json
{
  "properties": {
    "semanticSearch": "standard"
  }
}
```

> [!NOTE]
> Free plan exhaustion is documented as a billing error, not as a 206
> partial response. It is a separate failure mode that can masquerade as the
> same symptom, not an alternative explanation for the `Transient` reason
> code. Both can be true at once.

### 2. Size search units against concurrent turns, not average QPS

Evidence: documented. Confidence: high.

Semantic ranker capacity is published per search unit, where a search unit is
replicas multiplied by partitions. On S1 the limits are 3 concurrent requests
and a queue of 6 per search unit, giving 9 in flight before rejection
([service limits][limits]).

Average queries per second is the wrong sizing input. Size against the peak
number of turns that overlap, because each turn contributes seven requests at
once.

```text
required_search_units = ceil((7 * peak_concurrent_turns) / 9)
```

| Peak concurrent turns | Semantic requests | Search units on S1 |
|-----------------------|-------------------|--------------------|
| 1                     | 7                 | 1                  |
| 3                     | 21                | 3                  |
| 5                     | 35                | 4                  |
| 10                    | 70                | 8                  |

This formula admits queueing, so it is the floor rather than a comfortable
target. Sizing against concurrent slots alone, without leaning on the queue,
costs three times as much. The fan-out reduction document uses that stricter
basis when it compares the seven-index and consolidated designs, so the two
numbers there and here are not in conflict: they price different tolerances
for added latency.

> [!IMPORTANT]
> Microsoft publishes two different numbers for semantic concurrency. The
> semantic ranking how-to says to expect up to 10 concurrent queries per
> replica ([add semantic ranking][semantic-query]), while the service limits
> table gives 2 to 4 per search unit plus a queue ([service limits][limits]).
> They differ in both magnitude and unit. Ask Microsoft Customer Service and
> Support to confirm the authoritative figure for this tier, region, and
> search unit count before committing to a capacity purchase.

### 3. Hold at least two replicas, three during indexing windows

Evidence: documented. Confidence: high.

Two replicas are the read SLA floor, and they also give transient fault
resilience ([reliability in Azure AI Search][reliability]). Move to three if
indexers write during query hours, because that is the read-write SLA
threshold ([estimate capacity][capacity]).

Microsoft is explicit that replica sizing has no formula: there are no
guidelines on how many replicas a query load needs, and the result is not
strictly linear, so three replicas do not guarantee triple throughput
([estimate capacity][capacity]). Treat added replicas as measured headroom,
not as arithmetic.

### 4. Audit the sessionId the agent sends

Evidence: inferred. Confidence: high.

The connector exposes a `SessionId` parameter. Microsoft documents that as
long as the same sessionId is used, a best-effort attempt is made to target
the same replica set, and warns that reusing the same sessionId values
repeatedly can interfere with load balancing across replicas and adversely
affect performance ([search documents REST reference][search-post]).

A constant or low-cardinality value would pin all traffic to one replica set
and defeat the replica scale-out that was purchased. That mechanism is
documented. That this agent is doing it is inferred, and it is one of the
strongest candidates for why moving to S1 and adding replicas helped in large
part but not completely ([meeting notes](../assets/meetingNotes.md)).

Capture an outbound request body trace at the API Management layer and read
the value the connector actually emits. If it is constant across users or
across the seven per-turn calls, vary it per conversation or remove it.

### 5. Instrument the 206 at the API Management layer

Evidence: documented. Confidence: high.

A 206 is a success status. API Management passes it through, dashboards
bucket it as a 2xx, and retry policies keyed on 429 or 5xx never fire. The
`ThrottledSearchQueriesPercentage` metric will not show it either, because
that metric covers host-level throttling which surfaces as 503
([monitoring data reference][monitor-ref]).

The discriminating field, `@search.semanticPartialResponseReason`, exists
only in the response body. It is not part of the Azure AI Search resource log
schema. Capturing it requires response body logging at the gateway, which is
the single strongest argument for keeping API Management in the path.

Alert on the presence of the annotation, not on status code alone.

### 6. Move indexer schedules out of business hours

Evidence: documented. Confidence: medium.

Indexing and query workloads share the same resources with no prioritisation
between them ([estimate capacity][capacity]). The ingestion pipeline runs on
a daily schedule with a weekly cleanup of deleted sources
([meeting notes](../assets/meetingNotes.md)), so the overlap is controllable.

Confidence is medium rather than high because the effect size on this
workload has not been measured. Separating the schedules is cheap and removes
a variable from the RCA even if it turns out not to be a major contributor.

### 7. Check whether the 403s are design mode only

Evidence: documented. Confidence: high.

Every one of the 613 captured connector failures carries `DesignMode: True`
and `channelId: pva-studio`, which means they originated in the authoring
test canvas rather than a published channel
([screenshots](../assets/usefulScreenshots.md)).

Run the grouping before anything else, because it is free and it can reframe
the entire engagement. If production traffic is clean, the 403 workstream
changes from a production incident to an authoring-experience issue, and the
severity assigned to any support ticket should change with it.

Note that 403 from Azure AI Search means authorization failed. Quota and low
storage return 429, and semantic free plan exhaustion returns 402
([HTTP status codes][status-codes]). The tier change does not explain the
403s. The triage paths are set out in
[403 connector triage](./rca-403-connector-triage.md).

### 8. Bypass the connector if you need error-mode control

Evidence: documented. Confidence: high.

The REST reference documents the default for `semanticErrorHandling` as
failing completely, yet the service is returning 206 partials, which only
happens under `partial` ([search documents REST reference][search-post]). The
built-in Azure AI Search connector exposes neither `semanticErrorHandling`
nor `semanticMaxWaitInMilliseconds` ([connector reference][connector]), so
the behaviour cannot be tuned from Copilot Studio.

Three ways to regain control, in ascending order of effort:

* Inject the fields with an API Management `set-body` policy on the inbound
  request.
* Call the search endpoint from a Send HTTP Request node instead of the
  built-in connector.
* Publish a custom connector that surfaces the parameters explicitly.

`semanticMaxWaitInMilliseconds` has a documented minimum of 700 ms and no
published default, so set it deliberately if you take this path.

## Summary

| # | Action                                        | Confidence | Evidence   |
|---|-----------------------------------------------|------------|------------|
| 1 | Confirm the semantic plan is standard         | High       | Inferred   |
| 2 | Size search units by concurrent turns         | High       | Documented |
| 3 | Hold two or more replicas                     | High       | Documented |
| 4 | Audit the sessionId the agent sends           | High       | Inferred   |
| 5 | Instrument 206 at API Management              | High       | Documented |
| 6 | Move indexer schedules off business hours     | Medium     | Documented |
| 7 | Check whether the 403s are design mode only   | High       | Documented |
| 8 | Bypass the connector for error-mode control   | High       | Documented |

## What these actions do not fix

None of the eight reduces the fan-out. Actions 2 and 3 raise the ceiling that
seven concurrent requests hit, which defers the failure rather than removing
it. At the customer's own expected growth the ceiling returns
([meeting notes](../assets/meetingNotes.md)).

Sequence the work accordingly. Run actions 1, 4, and 7 first because they are
free, decisive, and remove confounding variables. Use actions 2, 3, and 5 to
hold the service stable while the architecture changes land. Then move to
[fan-out reduction architecture](./fan-out-reduction-architecture.md), which
is where the problem is actually solved.

[capacity]: https://learn.microsoft.com/en-us/azure/search/search-capacity-planning
[connector]: https://learn.microsoft.com/en-us/connectors/azureaisearch/
[limits]: https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity
[monitor-ref]: https://learn.microsoft.com/en-us/azure/search/monitor-azure-cognitive-search-data-reference
[pricing]: https://azure.microsoft.com/en-us/pricing/details/search/
[reliability]: https://learn.microsoft.com/en-us/azure/reliability/reliability-ai-search
[search-post]: https://learn.microsoft.com/en-us/rest/api/searchservice/documents/search-post
[semantic-enable]: https://learn.microsoft.com/en-us/azure/search/semantic-how-to-enable-disable
[semantic-query]: https://learn.microsoft.com/en-us/azure/search/semantic-how-to-query-request
[sla]: https://azure.microsoft.com/en-us/support/legal/sla/search/v1_0/
[status-codes]: https://learn.microsoft.com/en-us/rest/api/searchservice/http-status-codes
