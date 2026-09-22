---
title: "Root Cause Analysis: 206 Partial Semantic Responses"
description: Why Azure AI Search returns HTTP 206 partial semantic responses to the Copilot Studio agent, why the empty answers follow from them, and why moving from Basic to S1 resolved most of the symptoms.
author: Azure AI Search Scaling Engagement
ms.date: 2026-09-22
ms.topic: troubleshooting
keywords:
  - azure ai search
  - semantic ranker
  - partial response
  - copilot studio
  - capacity planning
estimated_reading_time: 16
---

## Summary

The agent issues **seven concurrent semantic queries on every user turn**, one per knowledge-source index. A Basic search service running at one search unit admits **six semantic requests in flight** before it starts rejecting them. Seven requests arriving against six slots degrades on a single turn, with zero other users on the system.

| Configuration | Search units | Semantic requests in flight before rejection | Agent needs |
| --- | --- | --- | --- |
| Basic, 1 replica, 1 partition | 1 | 6 | 7 |
| Basic, 3 replicas, 1 partition | 3 | 18 | 7 |
| S1, 1 replica, 1 partition | 1 | 9 | 7 |
| S1, 3 replicas, 1 partition | 3 | 27 | 7 |

This is an **arity problem, not a load problem**. The failure is driven by how many indexes one turn touches, not by how many people are talking to the agent. That is precisely why a measured load of roughly 7 to 15 users per hour never looked like a plausible cause ([assets/meetingNotes.md](../assets/meetingNotes.md), 17:28).

> [!IMPORTANT]
> The concurrency ceiling described below is documented by Microsoft. Attributing the specific `Transient` partial responses observed in this environment to that ceiling is the **leading hypothesis**, and it is the strongest explanation the evidence supports. It is not a confirmed cause. The open items at the end of this document list exactly what would confirm it.

### How to read this document

Claims that come from Microsoft carry an inline Microsoft Learn link and are quoted where the exact wording matters. Conclusions drawn from the evidence rather than from documentation begin with **Inferred:** and should not be presented to Microsoft support as Microsoft's own position.

## The mechanism

### Semantic ranking is admission-controlled, not best-effort

Azure AI Search does not queue semantic work indefinitely. It runs an explicit admission-control system with a fixed concurrency limit and a fixed queue depth, both indexed by tier. From [Service limits and quotas, Throttling limits](https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity):

> Semantic ranker uses a queuing system to manage concurrent requests. This system allows search services to get the highest number of queries per second possible. When the limit of concurrent requests is reached, the system places additional requests in a queue. If the queue is full, the system rejects further requests and they must be retried.
>
> | Resource | Basic | S1 | S2 | S3 |
> | --- | --- | --- | --- | --- |
> | Maximum concurrent requests (per search unit) | 2 | 3 | 4 | 4 |
> | Maximum request queue size (per search unit) | 4 | 6 | 8 | 8 |

Two properties of that table drive everything that follows. The limits are **per search unit**, so they scale with the service topology. And the queue is finite, so oversubscription surfaces as a response rather than as added latency.

### Search units multiply the limit

A search unit is `replicas x partitions`. Semantic capacity in flight is therefore:

```text
in-flight capacity = search units x (concurrent limit + queue depth)
```

| Configuration | Search units | Concurrent | Queued | Total in flight |
| --- | --- | --- | --- | --- |
| Basic, 1 replica | 1 | 2 | 4 | 6 |
| Basic, 2 replicas | 2 | 4 | 8 | 12 |
| Basic, 3 replicas | 3 | 6 | 12 | 18 |
| S1, 1 replica | 1 | 3 | 6 | 9 |
| S1, 2 replicas | 2 | 6 | 12 | 18 |
| S1, 3 replicas | 3 | 9 | 18 | 27 |

This is the same lever the team already pulled by hand. Adding replicas reduced errors and improved stability ([assets/meetingNotes.md](../assets/meetingNotes.md), 10:03), which is exactly what the table predicts: each replica adds a search unit, and each search unit adds two concurrent slots plus four queue slots on Basic.

### Seven queries per turn, not seven users per hour

Every user query fans out to all seven indexes regardless of relevance, and each index returns its top three documents ([assets/meetingNotes.md](../assets/meetingNotes.md), 18:11 and 34:37). There is no routing or selection logic across the knowledge sources ([assets/meetingNotes.md](../assets/meetingNotes.md), 53:05).

A single turn therefore presents seven simultaneous semantic requests to a service that, on Basic at one search unit, can hold six. The seventh request has nowhere to go. Under any concurrency above one turn the shortfall compounds.

The randomness the team observed follows from the same mechanism. Seven requests race one shared admission queue; whichever ones arrive after saturation are the ones that degrade. That produces failures scattered unpredictably across indexes rather than a clean per-index pattern, which matches the reported behavior of the issue affecting multiple indexes at random ([assets/meetingNotes.md](../assets/meetingNotes.md), 14:24).

## What a 206 actually returns

The two field values captured from the failing responses decode precisely. From the [Documents - Search POST REST reference](https://learn.microsoft.com/en-us/rest/api/searchservice/documents/search-post):

| Field | Observed value | Documented meaning |
| --- | --- | --- |
| `@search.semanticPartialResponseReason` | `Transient` | At least one step of the semantic process failed |
| `@search.semanticPartialResponseType` | `BaseResults` | Results without any semantic enrichment or reranking |

The caller receives keyword and vector matches with **no `@search.rerankerScore`, no `@search.captions`, and no `@search.answers`**. The document set is technically non-empty, but every field the grounding layer reads for a quotable, citable passage is absent.

That is the mechanism behind the symptom the team found most confusing: empty responses even when the index contains data ([assets/meetingNotes.md](../assets/meetingNotes.md), 8:55). The search succeeded. The ranking stage that produces the answer text did not.

> [!NOTE]
> A second, independent cause of empty answers exists on the Copilot Studio side and should be ruled out in parallel. See [copilot-studio-fanout.md](copilot-studio-fanout.md) for the ungrounded-responses check.

## Why no 429 ever appeared

The team expected throttling to show up as 429 responses and saw none ([assets/additionalInfo.md](../assets/additionalInfo.md), 6:28). The absence is expected, and it is not evidence against a capacity constraint. Azure AI Search has three architecturally separate pressure paths, and they surface differently:

| Pressure path | Surfaces as | Counted by a metric |
| --- | --- | --- |
| Search host resource throttle (CPU, memory, disk) | 503 | Yes, `ThrottledSearchQueriesPercentage` |
| Indexing partial failure | 207 | Partially |
| Semantic ranker queue overflow | 206 plus a response-body annotation | No |

HTTP 206 is a 2xx. API Management passes it through as success, dashboards bucket it as success, and retry policies keyed on 429 or 5xx never fire. The monitoring in place was structurally blind to this failure mode rather than reporting its absence.

This also explains why the connector black box was so hard to see through ([assets/meetingNotes.md](../assets/meetingNotes.md), 28:54). Nothing in the path was configured to treat a 206 as a failure.

## Two anomalies that need answers

### The documented default does not match the observed behavior

The [Search POST REST reference](https://learn.microsoft.com/en-us/rest/api/searchservice/documents/search-post) documents the default for `semanticErrorHandling` as failing the request completely. Partial responses only occur under the `partial` setting. Yet partial responses are arriving.

The [Azure AI Search connector reference](https://learn.microsoft.com/en-us/connectors/azureaisearch/) exposes neither `semanticErrorHandling` nor `semanticMaxWaitInMilliseconds` in its parameter list, so this is not a setting the team can reach.

**Inferred:** either the connector sets `partial` in its server-side implementation, or API Management is injecting it into the outbound body. Resolving this requires an API Management trace of the request body sent to `search.windows.net`. Until it is resolved, the precise trigger for the partial path is unknown even though the capacity pressure is well evidenced.

### Microsoft publishes two different semantic concurrency limits

From [Add semantic ranking, Expected workloads](https://learn.microsoft.com/en-us/azure/search/semantic-how-to-query-request):

> For semantic ranking, you should expect a search service to support up to 10 concurrent queries per replica.
>
> The service throttles semantic ranking requests if volumes are too high. An error message that includes these phrases indicate the service is at capacity for semantic ranking: `Operation returned an invalid status 'Partial Content'`, `@search.semanticPartialResponseReason`, `CapacityOverloaded`
>
> If you anticipate consistent throughput requirements near, at, or higher than this level, please file a support ticket so that we can provision for your workload.

Read that against the limits table quoted earlier and the two do not reconcile.

> [!WARNING]
> That page says **10 concurrent queries per replica**. The limits table says **2 or 3 concurrent per search unit** plus a queue. Different magnitudes, different units of measure. Both cannot be literally true. This is the first question to put to Azure support, because capacity sizing math depends on which one governs.

The same passage carries the strongest justification for escalating. Microsoft instructs customers at or near this throughput to file a support ticket so the workload can be provisioned for. That converts a request for analysis into a documented, in-scope support scenario. See [rca-403-connector-triage.md](rca-403-connector-triage.md) for the separate escalation path covering the connector errors.

## Why moving from Basic to S1 resolved most of the symptoms

The answer is arithmetic, not narrative. At an identical search-unit count, S1 raises the concurrent limit from 2 to 3 and the queue depth from 4 to 6. That is **50 percent more semantic capacity in flight for a pure tier change**, with no extra replicas:

| Search units | Basic in flight | S1 in flight | Gain |
| --- | --- | --- | --- |
| 1 | 6 | 9 | +50 percent |
| 2 | 12 | 18 | +50 percent |
| 3 | 18 | 27 | +50 percent |

Combined with the replicas already added, the service moved from a configuration that could not absorb one turn to one that absorbs several. The symptoms receded because the workload finally fit inside the envelope.

The tier change bought headroom. It did not change the shape of the workload.

## Why it resolved them only in large part

Two candidate explanations account for the residual failures. Both are unconfirmed and must be verified against the customer environment before either is acted on.

### Candidate one: a constant session identifier pins traffic to one replica set

The connector exposes a `SessionId` parameter ([Azure AI Search connector reference](https://learn.microsoft.com/en-us/connectors/azureaisearch/)). The [Search POST REST reference](https://learn.microsoft.com/en-us/rest/api/searchservice/documents/search-post) warns:

> As long as the same sessionId is used, a best-effort attempt will be made to target the same replica set. [...] reusing the same sessionID values repeatedly can interfere with the load balancing of the requests across replicas.

**Inferred:** if the agent passes a constant `SessionId`, every semantic request lands on the same replica set, and the added replicas contribute nothing to the semantic admission pool that this traffic can reach. The service would show ample aggregate capacity while one replica set stays saturated. This is a high-value check because it is cheap to run and would fully explain a partial fix.

### Candidate two: the semantic ranker is on the free plan

The semantic ranker free allowance is 1,000 requests per month, after which requests return a billing error rather than results. At seven indexes multiplied by roughly 10 users per hour across a working day, this fan-out generates somewhere between 8,600 and 37,000 semantic requests per month.

**Inferred:** a 1,000-request free allowance is exhausted within one to three days at this volume. If `properties.semanticSearch` reads `free` rather than `standard`, a second and entirely separate root cause is in play, and no amount of tier or replica scaling will address it.

Verify the plan value before any further capacity work. Use `PATCH` rather than `PUT` when changing it, so the rest of the service definition is preserved.

## Why the root cause still matters after the tier change

The service is stable today, so it is fair to ask why this warrants further work. Three reasons.

The fix is capacity applied to an architectural problem. Seven concurrent semantic requests per turn is a fixed property of the design. S1 at three search units absorbs 27 requests in flight, which covers roughly three concurrent turns. The team already expects growth beyond the current 7 to 15 users per hour ([assets/meetingNotes.md](../assets/meetingNotes.md), 17:28 and 32:26), and concurrency pressure returns as soon as concurrent turns exceed that ceiling.

Every limit in the path is multiplied by seven. Semantic concurrency, connector throttling, and any API Management quota all see seven calls where the user made one. Buying capacity defers the ceiling; it does not move the multiplier. The strategic remedy is to reduce the fan-out, which is covered in [copilot-studio-fanout.md](copilot-studio-fanout.md).

The failure mode is still invisible. A 206 is counted nowhere. Without explicit instrumentation at the API Management layer, the next recurrence will present exactly as this one did: empty answers with no error signal anywhere in the dashboards.

## Open items carried into the support ticket

These gaps are unresolved. Each is stated here so that no downstream document treats an inference as settled fact.

| ID | Open question | Why it matters |
| --- | --- | --- |
| U1 | No Microsoft source links `Transient` specifically, as opposed to `CapacityOverloaded`, to tier or capacity | The correlation is strong but the attribution remains inferred |
| U2 | Who sets `semanticErrorHandling` to `partial`, given the documented default is to fail | Blocks a precise statement of the trigger |
| U3 | The effective value of `semanticMaxWaitInMilliseconds` when omitted is undocumented, with only a 700 ms minimum published | Affects how long a request waits before degrading |
| U4 | The published conflict between 10 concurrent per replica and 2 or 3 concurrent per search unit | Capacity sizing math is uncertain until resolved |

Two data points would move U1 from inferred to proven. Capture whether the partial responses are exclusively `Transient` or whether `CapacityOverloaded` also appears, since only the latter is explicitly documented as throttling. And capture the exact replica and partition counts in force at the time of failure, alongside the service creation date, because Basic services created before 2024-04-03 cap at one partition.

## Evidence sources

| Source | Contribution |
| --- | --- |
| [assets/meetingNotes.md](../assets/meetingNotes.md) | Fan-out behavior, replica effects, load profile, empty-answer symptom, API Management placement |
| [assets/usefulScreenshots.md](../assets/usefulScreenshots.md) | The observed `Transient` and `BaseResults` field values |
| [assets/additionalInfo.md](../assets/additionalInfo.md) | Expected-throttling context and the systemic retrieval-layer insight |
| [Service limits and quotas](https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity) | Semantic ranker concurrency and queue limits per search unit |
| [Add semantic ranking](https://learn.microsoft.com/en-us/azure/search/semantic-how-to-query-request) | Expected workloads and the instruction to file a support ticket |
| [Documents - Search POST](https://learn.microsoft.com/en-us/rest/api/searchservice/documents/search-post) | Partial-response enum meanings, `semanticErrorHandling` default, `sessionId` warning |
| [Azure AI Search connector reference](https://learn.microsoft.com/en-us/connectors/azureaisearch/) | The connector parameter surface and its omissions |
