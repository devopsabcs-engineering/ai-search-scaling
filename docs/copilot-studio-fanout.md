---
title: "Why Copilot Studio Queries All Seven Indexes on Every Turn"
description: How generative orchestration selects knowledge sources, why description-based routing does not apply below 25 sources, and the architectural change that makes selective retrieval possible.
author: Azure AI Search Scaling Engagement
ms.date: 2026-09-22
ms.topic: concept
keywords:
  - copilot studio
  - generative orchestration
  - knowledge sources
  - fan-out
  - azure ai search
estimated_reading_time: 11
---

## Summary

The team's reading of the behavior is correct. Every user turn fans out to all seven Azure AI Search indexes regardless of which one could plausibly answer the question, and each returns its top three documents ([assets/meetingNotes.md](../assets/meetingNotes.md), 18:11 and 34:37). There is no routing or selection logic across the knowledge sources ([assets/meetingNotes.md](../assets/meetingNotes.md), 53:05).

That is documented behavior, not a misconfiguration. Copilot Studio applies description-based filtering to knowledge sources only above a threshold of 25, and with seven sources the filter never engages.

One part of the team's conclusion goes further than the evidence supports, and correcting it opens the path to a fix. The belief that selective retrieval is impossible while a single agent uses knowledge sources is accurate **only while the indexes remain knowledge sources**. Re-expressed as tools or as connected agents, the same seven indexes become selectable by name and description. That is the architectural unlock.

### How to read this document

Claims that come from Microsoft carry an inline Microsoft Learn link and are quoted where the exact wording matters. Conclusions drawn from the evidence rather than from documentation begin with **Inferred:** and should not be presented to Microsoft support as Microsoft's own position.

## The documented threshold

From [Knowledge sources summary](https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-copilot-studio), in the section covering generative orchestration:

> Generative orchestration filters knowledge sources by using an internal GPT model when there are more than 25 different knowledge sources.

Seven sources sit well below 25. The pre-filter stage that would narrow the set never runs, so the knowledge-search step executes against the full configured set on every turn where the orchestrator decides to search knowledge.

Two numbers are in play and they mean different things:

| Number | What it governs | Source |
| --- | --- | --- |
| 500 | The hard configuration ceiling on knowledge sources per agent | [Quotas and limits](https://learn.microsoft.com/en-us/microsoft-copilot-studio/requirements-quotas) |
| 25 | The behavioral threshold above which description-based filtering engages | [Knowledge sources summary](https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-copilot-studio) |

> [!CAUTION]
> Do not add knowledge sources to push the count past 25 in order to trigger the GPT filter. It would work in the narrow sense and it is the wrong move. The filter adds a model call to every turn, adding latency and token cost, and padding an agent with sources it does not need to reach a threshold is an incentive working backwards. The remedy is fewer retrieval targets per turn, not more configured sources.

**Inferred:** Microsoft does not publish the internal execution model for the knowledge-search step, so the documentation establishes which sources are searched without establishing whether the calls run in parallel.
The near-simultaneous arrival of seven index queries per turn is observed behavior in this environment rather than documented behavior. The distinction matters because the capacity analysis in [rca-206-semantic-concurrency.md](rca-206-semantic-concurrency.md) depends on the requests being concurrent.

## Descriptions do drive selection, just not for knowledge sources

This is the point where the team's conclusion needs adjusting. From [Orchestrate agent behavior with generative AI](https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-generative-actions):

> The most important factor is the description of the topics, tools, agents, and knowledge sources.

Descriptions are how the orchestrator picks **topics, tools, and other agents**. They do not narrow the knowledge-source set below the threshold of 25. The same page describes the selection behavior for tools and agents explicitly:

> If the agent selects multiple tools, agents, or topics, it calls them in sequence, after generating any questions to ask the user for missing information.

Note the asymmetry. Sequencing and selection are described for tools, agents, and topics. Knowledge is not named in that sentence.

| Statement | Accurate | Why |
| --- | --- | --- |
| All seven knowledge sources are queried on every turn | Yes | Description filtering engages only above 25 sources |
| Descriptions select among topics, tools, and connected agents | Yes | Documented as the most important selection factor |
| Descriptions narrow which knowledge sources are searched at seven sources | No | The filter is not active below the threshold |
| Selective retrieval is impossible for a single agent | No | It is impossible for knowledge sources, not for tools or agents |

## The architectural unlock

Expressing the seven indexes as tools or as connected agents moves them into the surface the orchestrator already routes across by description. The retrieval work is identical. What changes is that the orchestrator picks one or two targets instead of issuing seven.

| Approach | Reduces fan-out | Effort | Main trade-off |
| --- | --- | --- | --- |
| Convert each index into a tool with a precise description | Yes, the orchestrator selects by description | Medium | Description quality becomes the gate, and built-in citation rendering is lost |
| Split into child or connected agents by business domain | Yes, one hop per domain | Medium-High | Added latency per hop, and multi-level chaining is not supported |
| Consolidate the seven indexes into one with a filterable field | Yes, seven calls become one | High | Requires re-indexing and re-permissioning, and per-index isolation is lost |
| Add replicas or raise the service tier | No | Low | Buys headroom without changing the multiplier |

Microsoft publishes the consolidation advice directly in the same guidance: reducing the number of indexes and consolidating content lowers both fan-out and token volume.

Converting knowledge sources to tools is the cheapest route to description-driven routing because it needs no index rebuild, and it answers the specific blocker the team raised. Consolidation and tool conversion compose rather than compete: tool conversion first, consolidation later if the index count still warrants it.

> [!NOTE]
> One approach looks attractive and carries a trap. Agentic retrieval with the `minimal` reasoning effort setting bypasses LLM-based query planning, uses all configured sources, and adds parallel subqueries of its own, which can increase the request count rather than reduce it. The `low` and `medium` settings do perform source selection. Evaluate any of them against measured fan-out before adopting it. See [Fan-out reduction architecture](fan-out-reduction-architecture.md) for the full evaluation.

## A second cause of empty answers to rule out

Not every empty answer is a retrieval failure. From [Knowledge sources summary](https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-copilot-studio):

> When you turn off Allow ungrounded responses, the agent returns an answer from a knowledge source only when the answer includes an in-text citation to that source. [...] Occasionally, the model generates a correct answer from a knowledge source but doesn't include a citation for it. When that happens, the agent withholds the answer and responds as though it didn't find any information. Because models don't always include citations, this behavior can be intermittent.

That produces exactly the reported symptom of empty responses even when the index contains data ([assets/meetingNotes.md](../assets/meetingNotes.md), 8:55), and it produces it intermittently, which is the characteristic that made the issue hard to pin down.

Check whether **Allow ungrounded responses** is turned off. If it is, some share of the empty answers may have nothing to do with search capacity, and a support case that chases capacity alone will be chasing the wrong signal for that share.

## Two behaviors worth knowing about

Editing the Conversational boosting system topic has no effect while generative orchestration is on. From [Orchestrate agent behavior with generative AI](https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-generative-actions):

> With generative orchestration turned on, an agent doesn't use the Conversational boosting system topic when it searches knowledge sources. Therefore, the agent doesn't use any modifications you make to this system topic to customize how it searches knowledge.

If anyone on the team has tried to tune retrieval there, that explains why nothing changed.

Conversation history also influences responses. The same page notes that an agent uses previous conversation history and context when deciding how to respond, so the same query can produce different responses in a fresh conversation versus an ongoing one. Factor that into any reproduction attempt, because a test that fails once and succeeds on retry is not necessarily evidence of an intermittent backend fault.

## Open items

| ID | Open question | Why it matters |
| --- | --- | --- |
| U7 | Azure AI Search does not appear in the documented table of supported knowledge sources for Copilot Studio | The wiring model cannot be confirmed from documentation alone, so whether the seven indexes are configured as knowledge sources or already as tools needs visual confirmation from the agent configuration |

That single question is the highest-impact gap in this analysis. If the indexes are already configured as tools, description-based routing should already apply and the problem becomes one of description quality rather than of architecture. Confirm the wiring before committing to any of the approaches above.

## Evidence sources

| Source | Contribution |
| --- | --- |
| [assets/meetingNotes.md](../assets/meetingNotes.md) | Fan-out across all seven indexes, top three documents each, absence of routing logic, the empty-answer symptom |
| [assets/additionalInfo.md](../assets/additionalInfo.md) | The systemic insight that retrieval and ranking layers dominate over index size |
| [Knowledge sources summary](https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-copilot-studio) | The 25-source filtering threshold and the ungrounded-responses behavior |
| [Orchestrate agent behavior with generative AI](https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-generative-actions) | Description-driven selection of topics, tools, and agents, plus the Conversational boosting limitation |
| [Quotas and limits](https://learn.microsoft.com/en-us/microsoft-copilot-studio/requirements-quotas) | The 500-source configuration ceiling |

For the capacity consequences of this fan-out, see [rca-206-semantic-concurrency.md](rca-206-semantic-concurrency.md). For the independent connector authorization failures, see [rca-403-connector-triage.md](rca-403-connector-triage.md).
