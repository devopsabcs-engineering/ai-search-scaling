---
title: Fan-out reduction architecture
description: The strategic fix for the Azure AI Search 206 failures, consolidating seven indexes into one with a filterable businessUnit field and search.in security trimming, with the full ranked set of alternatives and the reasons each was rejected.
author: Microsoft
ms.date: 2026-09-22
ms.topic: concept
keywords:
  - azure ai search
  - copilot studio
  - fan-out
  - index consolidation
  - security trimming
estimated_reading_time: 15
---

## The problem in one sentence

Every user turn issues seven simultaneous semantic queries, one per index, so
every limit in the request path is multiplied by seven.

This is an arity problem, not a load problem. The mechanics of why Copilot
Studio behaves this way are covered in
[Copilot Studio fan-out](./copilot-studio-fanout.md); the capacity
consequences are covered in
[206 semantic concurrency](./rca-206-semantic-concurrency.md). This document
covers what to change.

## Why capacity purchases defer rather than resolve

Semantic ranker capacity is published per search unit, where a search unit is
replicas multiplied by partitions. On S1 that is 3 concurrent requests and a
queue of 6, so 9 in flight before rejection ([service limits][limits]).

Adding search units raises the ceiling. It leaves the fan-out at seven. The
same is true of the connector throttling limits and of any API Management
quota in the path: each one is consumed seven times faster than the turn rate
suggests. Growth in users therefore hits the ceiling again, and the next
remedy is another capacity purchase.

Reducing the fan-out changes the multiplier instead of the ceiling. That is
the difference between a stopgap and a fix.

### The sizing comparison

Sizing conservatively against concurrent slots alone, without relying on the
queue to absorb bursts, S1 provides 3 semantic slots per search unit.

| Design       | Requests per turn | At 10 concurrent turns | Search units |
|--------------|-------------------|------------------------|--------------|
| Seven index  | 7                 | 70                     | 24           |
| Consolidated | 1                 | 10                     | 4            |

Roughly a six-fold reduction in the search units required to serve the same
conversation volume. Allowing the queue to absorb bursts lowers both figures,
to 8 and 2 search units respectively, and the ratio stays in the same range.
The [immediate mitigations](./immediate-mitigations.md) document sizes on
that queue-inclusive basis because it is costing a stopgap; this document
sizes without the queue because it is costing a target state.

The cost argument is secondary to the reliability argument. At a fan-out of
one, a single user turn can no longer saturate the semantic queue on its own.

## Selected approach: consolidate seven indexes into one

Replace the seven per-business-unit indexes with a single index carrying a
filterable discriminator field, and scope each query with a filter rather
than by choosing a physical index.

Microsoft publishes this advice directly. Its guidance on controlling
agentic retrieval costs says to reduce the number of knowledge sources
(indexes) because consolidating content can lower fan-out and token volume,
and to organise content so the most relevant information can be found with
fewer sources and documents ([agentic retrieval overview][agentic]).

### Before and after

```text
BEFORE: one turn, seven semantic queries

  user turn
    |-- index_hr        semantic query 1
    |-- index_finance   semantic query 2
    |-- index_legal     semantic query 3
    |-- index_ops       semantic query 4
    |-- index_it        semantic query 5
    |-- index_sales     semantic query 6
    `-- index_support   semantic query 7
                        = 7 concurrent semantic requests

AFTER: one turn, one semantic query

  user turn
    `-- consolidated_index   semantic query 1
        filter: businessUnit eq 'hr'
                             = 1 concurrent semantic request
```

### The index fields

Add a filterable discriminator so a single index can serve every business
unit:

```json
{
  "name": "businessUnit",
  "type": "Edm.String",
  "filterable": true,
  "retrievable": true
}
```

Where the seven indexes also carried an access boundary, add a group
collection and apply the security filter pattern
([security filter pattern][trimming]):

```json
{
  "name": "group_ids",
  "type": "Collection(Edm.String)",
  "filterable": true,
  "retrievable": false
}
```

> [!IMPORTANT]
> Microsoft is explicit that setting `retrievable` to `false` prevents the
> field from being returned in results but is not a content-obfuscation or
> field-level security mechanism. Document-level authorization is enforced
> only by applying the security filter to every query
> ([security filter pattern][trimming]).

### The filtered query

```http
POST /indexes/consolidated/docs/search?api-version=2026-04-01
```

```json
{
  "search": "<user query>",
  "queryType": "semantic",
  "semanticConfiguration": "semantic-config",
  "filter": "group_ids/any(g:search.in(g, 'hr-group, finance-group'))"
}
```

### Why search.in rather than an or-chain

Use `search.in` for the identifier list. Microsoft compares the two
approaches directly: a complicated disjunction of equality expressions is
error-prone, difficult to maintain, and where the list contains hundreds or
thousands of values it slows down query response time by many seconds,
whereas `search.in` yields subsecond response times
([security filter pattern][trimming], [OData filter syntax][odata]).

That performance gap matters more here than it would elsewhere. Faster
retrieval frees the semantic queue sooner, which raises effective semantic
throughput at an unchanged queue depth. An or-chain would give back part of
the benefit the consolidation just bought.

### Where built-in access control is the better option

Hand-rolled trimming is the right pattern when permissions live outside the
source system. Where the source system supports it, prefer the newer
[built-in document-level access control][acl], which carries the access
control lists through indexing instead of requiring the caller to assemble
and pass the group list on every request.

## Ranked alternatives

All options considered, ordered by how directly they reduce per-turn fan-out.

| # | Option                              | Cuts fan-out | Effort   |
|---|-------------------------------------|--------------|----------|
| 1 | Consolidate 7 indexes into 1        | Yes, 7 to 1  | High     |
| 2 | Convert knowledge sources to Tools  | Yes          | Medium   |
| 3 | Child or connected agents per unit  | Yes per hop  | Med-high |
| 4 | Explicit topic with conditions      | Yes          | Low-med  |
| 5 | Agentic retrieval or Foundry IQ     | Conditional  | High     |
| 6 | Scale replicas or service tier      | No           | Low      |
| 7 | Disable semantic ranker on some     | No           | Low      |
| 8 | Exceed 25 sources to force filter   | Technically  | n/a      |

### 1. Consolidate seven indexes into one

Attacks the root cause directly, taking seven semantic queries to one, and
matches Microsoft's own published consolidation advice ([agentic retrieval
overview][agentic]).

The risk is effort and blast radius. It requires a re-index, an ingestion
pipeline rework, and a re-permissioning exercise, and it gives up the
isolation that seven physical indexes provided. The caller must also know
which business unit to filter on, so intent-to-unit resolution moves into the
agent rather than being implied by index selection.

### 2. Convert knowledge sources to Tools

Copilot Studio filters knowledge sources with an internal GPT model only when
there are more than 25 different knowledge sources
([knowledge sources summary][knowledge]). With seven, that filter never
engages and all seven are queried every turn. The customer's read of this is
correct as long as they remain knowledge sources.

It stops being true the moment the same retrieval is expressed as Tools. The
orchestrator selects tools by name and description, so description-driven
routing becomes available without touching the indexes
([orchestrate agent behavior][orchestration], [add tools][tools]).

The risk is that description quality becomes the gate. Seven per-unit sources
almost certainly carry overlapping descriptions, and overlapping descriptions
make selection unpredictable. This option also gives up built-in citation
rendering, and citations returned from a knowledge source cannot be used as
inputs to other tools.

### 3. Child or connected agents per business unit

The parent routes to one child by description, and that child holds a single
index, so the fan-out drops to one per hop
([add other agents overview][agents]).

The risk is latency and surface area. Microsoft warns that splitting a
solution across multiple agents increases latency because of the extra
orchestration hops, since the connected agent runs its own orchestration
layer, and increases the testing, management, and governance surface
([add other agents overview][agents]). There is no multi-level chaining, and
authentication has to line up across agents.

Choose this when the seven units genuinely have different owners, lifecycles,
or release cadences, and accept the latency cost knowingly.

### 4. Explicit topic with conditional logic

Deterministic and cheap: a topic routes to a single generative answers node
bound to one source ([add a generative answers node][boost]).

The risk is brittleness. It hard-codes intent routing, so every new intent is
a change request, and it regresses the generative experience the agent was
built for. Useful as a targeted fix for a few high-volume intents, not as the
whole architecture.

### 5. Agentic retrieval or Foundry IQ

> [!WARNING]
> This option is a trap at the default setting. Microsoft states that the
> `minimal` reasoning effort uses all knowledge sources in the knowledge base
> because it bypasses LLM-based query planning
> ([agentic retrieval limits][agentic-limits]). Agentic retrieval also runs
> subqueries in parallel, each semantically reranked
> ([agentic retrieval overview][agentic]). Adopted naively it leaves the
> fan-out at seven and adds parallel subqueries on top, making the semantic
> concurrency problem worse rather than better.

The `low` and `medium` reasoning efforts do perform source selection, so the
option is conditional rather than disqualified. It is worth evaluating for
the pro-code team, with the reasoning effort set deliberately and the
resulting request count measured before and after. Note that preview features
carry no SLA and billing is token-based.

### 6. Scale replicas or service tier

This is what has already been done, and it worked in large part
([meeting notes](../assets/meetingNotes.md)). It does not reduce fan-out. It
buys capacity to absorb it.

The risk is that it masks the design problem while cost scales with replicas
multiplied by partitions, and the failure returns as users grow. Keep it as
the stabiliser described in
[immediate mitigations](./immediate-mitigations.md), not as the answer.

### 7. Disable semantic ranker on some indexes

Removes the semantic concurrency ceiling for the indexes it is applied to, so
it addresses the 206 without touching the fan-out.

The risk is relevance. Semantic L2 reranking is the main quality lever
([semantic ranking overview][semantic]), and removing it trades one visible
failure for a quieter one. Consider it only for indexes whose content does
not benefit from reranking.

### 8. Exceed 25 sources to force GPT filtering

> [!CAUTION]
> Do not do this. Crossing the 25-source threshold would technically engage
> the internal GPT filter ([knowledge sources summary][knowledge]), but
> inflating the source count to trigger a filter is a perverse incentive. It
> adds latency and cost, and it runs directly against Microsoft's guidance
> that selection quality degrades beyond roughly 30 to 40 choices of action
> ([add other agents overview][agents]).

Listed here only so the option is visibly considered and visibly rejected.

## Recommended sequencing

Do option 2 first, then option 1. They compose rather than compete.

Option 2 delivers description-driven routing without an index rebuild, which
makes it the cheapest first step and the direct answer to the stated blocker.
It can ship while the consolidation work is still being scoped.

Option 1 then removes the fan-out at its source and unlocks the six-fold
search unit reduction. Once both are in place, the agent selects a single
tool by description and that tool issues a single filtered semantic query
against one index.

Treat options 3 and 4 as situational overlays: option 3 where organisational
boundaries demand separate agents, option 4 where a small number of
high-volume intents justify deterministic routing.

[acl]: https://learn.microsoft.com/en-us/azure/search/search-document-level-access-overview
[agentic]: https://learn.microsoft.com/en-us/azure/search/agentic-retrieval-overview
[agentic-limits]: https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity#agentic-retrieval-limits
[agents]: https://learn.microsoft.com/en-us/microsoft-copilot-studio/authoring-add-other-agents
[boost]: https://learn.microsoft.com/en-us/microsoft-copilot-studio/nlu-boost-node
[knowledge]: https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-copilot-studio
[limits]: https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity
[odata]: https://learn.microsoft.com/en-us/azure/search/search-query-odata-filter
[orchestration]: https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-generative-actions
[semantic]: https://learn.microsoft.com/en-us/azure/search/semantic-search-overview
[tools]: https://learn.microsoft.com/en-us/microsoft-copilot-studio/add-tools-custom-agent
[trimming]: https://learn.microsoft.com/en-us/azure/search/search-security-trimming-for-azure-search
