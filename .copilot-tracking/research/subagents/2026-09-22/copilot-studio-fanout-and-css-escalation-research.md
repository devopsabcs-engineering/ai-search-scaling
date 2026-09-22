<!-- markdownlint-disable-file -->
# Research: Copilot Studio Multi-Knowledge-Source Fan-Out and CSS Escalation

**Research date:** 2026-09-22
**Status:** Complete (with flagged gaps — see "Unverified / Could Not Confirm")
**Scope:** (A) Copilot Studio multi-knowledge-source fan-out behavior and architectural workarounds; (B) Microsoft CSS escalation path for this class of problem.

## Customer Situation (input context)

- One Copilot Studio agent with 7 Azure AI Search indexes registered as knowledge sources (one per team/business unit).
- Every user turn queries all 7 indexes regardless of relevance; each returns top 3 documents; results merged for generative answer synthesis.
- Intermittent HTTP 206 partial semantic responses and empty answers; plus connector 403s surfaced as error 613.
- Search service moved Basic → S1, which largely fixed it. Root cause analysis still wanted.
- Pro-code team has agents exposed enterprise-wide; asking about concurrency limits and ideal replica counts.

Source for this context in the workspace: assets/meetingNotes.md

## Research Questions

### Part A — Copilot Studio multi-knowledge-source behavior
1. How does Copilot Studio query multiple knowledge sources on a single turn? Parallel fan-out or routed selection?
2. Documented limits on knowledge sources per agent.
3. Official guidance on many-knowledge-sources degrading quality/performance.
4. Recommended architectural alternatives.
5. Does generative orchestration select knowledge sources by description?
6. Concurrency/QPS guidance and Azure AI Search replica planning.

### Part B — CSS escalation path
7. Azure support ticket process, plans, severities, SLAs.
8. Power Platform / Copilot Studio support ticket process.
9. Diagnostic data to collect before opening.
10. Semantic ranker 206 partial results — documented as support-ticket-worthy?
11. Draft ticket titles and problem descriptions.

## Findings

---

## TL;DR — The Five Answers That Matter

1. **The customer is correct that all knowledge sources are queried per turn — but only because they have fewer than 26 of them.** Copilot Studio's generative orchestration applies description-based *filtering* to knowledge sources **only when there are more than 25 different knowledge sources**. Below that threshold, no per-source routing occurs. Source: [Knowledge sources summary — Generative orchestration](https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-copilot-studio).
2. **Descriptions DO drive selection — for topics, tools, and connected/child agents.** They do **not** narrow the knowledge-source set below 25. Source: [Orchestrate agent behavior with generative AI](https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-generative-actions).
3. **Root cause of the 206s is almost certainly the semantic ranker concurrency limit, and it is precisely documented.** On Basic, Azure AI Search allows **2 concurrent semantic ranker requests per search unit** (queue 4). On S1 it is **3 per SU** (queue 6). A single user turn fanning out to 7 indexes issues ~7 concurrent semantic requests — which exceeds a 1-SU Basic service on its own. Source: [Service limits — Semantic ranker throttling limits](https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity#throttling-limits).
4. **Microsoft explicitly documents that this condition warrants a support ticket.** The `CapacityOverloaded` / `@search.semanticPartialResponseReason` / `Partial Content` signature is named in the docs with the instruction *"please file a support ticket so that we can provision for your workload."* Source: [Add semantic ranking — Expected workloads](https://learn.microsoft.com/en-us/azure/search/semantic-how-to-query-request).
5. **Two tickets, two portals.** Azure AI Search 206/semantic-capacity → **Azure portal**. Copilot Studio connector 613/403 and knowledge-source orchestration behavior → **Power Platform admin center**. Neither portal can route to the other product's engineering team.

---

# PART A — Copilot Studio Multi-Knowledge-Source Fan-Out

## A1. How Copilot Studio Queries Multiple Knowledge Sources on a Single Turn

### A1.1 Generative orchestration (default for new agents)

Primary doc: [Orchestrate agent behavior with generative AI — Microsoft Copilot Studio](https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-generative-actions)

Verbatim, from the section *"Selecting the right topics, tools, other agents, and knowledge sources"*:

> "When a user sends a message, your agent selects one or more tools, topics, other agents, or knowledge sources to prepare its response. Multiple factors determine the selection. The most important factor is the description of the topics, tools, agents, and knowledge sources. Other factors include the name of a topic, tool, agent, or knowledge source, any input or output parameters, and their names and descriptions."

And:

> "If the agent selects multiple tools, agents, or topics, it calls them **in sequence**, after generating any questions to ask the user for missing information."

Note the asymmetry: sequencing is described for **tools, agents, and topics** — knowledge is not named in that sentence.

From *"Responding to user input or event triggers"*:

> "The agent takes the information returned from **all** knowledge sources, tools, agents, and topics that it selected in response to user input or to an event trigger, and summarizes an answer to any originating user query."

### A1.2 The decisive statement on knowledge-source fan-out

Primary doc: [Knowledge sources summary — Microsoft Copilot Studio](https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-copilot-studio), section *"Knowledge search in classic and generative modes" → "Generative orchestration"*:

> "Generative orchestration **filters knowledge sources by using an internal GPT model when there are more than 25 different knowledge sources.**"
>
> Note: "[Files uploaded](https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-add-file-upload) to the agent aren't part of the 25 knowledge source search limit."

**Interpretation (high confidence):** The 25-source threshold is the trigger for a knowledge-source *pre-filter* stage. Below 25 configured knowledge sources, that GPT-based filter does not engage, so the knowledge-search step runs against the full configured set. With 7 sources, the customer sits well below the threshold — hence uniform fan-out on every turn where the orchestrator decides to search knowledge.

**Caveat / precision limit:** Microsoft does not publish the internal execution model (parallel vs. sequential, per-source top-K, merge/rerank algorithm) for the knowledge-search step. The docs describe the *set* of sources searched, not the concurrency of the calls. The customer's observed behavior (7 near-simultaneous index hits, top 3 each) is consistent with parallel fan-out but is **empirically observed, not documented**. Flagged as unverified below.

### A1.3 Parallelism is documented for at least one case

From [Knowledge sources summary — "Use information from the web"](https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-copilot-studio):

> "This type of search happens **in parallel** with any searches of public websites you added as knowledge sources. Results from **Use information from the web**/**Web Search** are **interleaved** with results from your configured public website knowledge sources."

This is the only place in the current Copilot Studio docs that explicitly uses the word "parallel" for knowledge retrieval. It supports (but does not prove) a parallel fan-out model generally.

### A1.4 Classic orchestration (the alternative behavior)

From the same doc, *"Classic orchestration"*:

- Knowledge is searched from the **Conversational boosting** system topic, and functions as a **fallback** when no topic trigger phrases match.
- Per-type caps apply (table reproduced in A2.2).
- You can embed a generative answers node in a topic so knowledge search runs only for a specific intent.

From [advanced-generative-actions — comparison table](https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-generative-actions):

| Behavior | Generative orchestration | Classic orchestration |
| --- | --- | --- |
| Knowledge | "The agent can choose to **proactively search knowledge** to answer a user's query." | "Knowledge can be used as a **fallback** when no topics match a user's query (or called explicitly from within a topic)." |
| Use of multiple topics, tools, knowledge sources | "The agent can use a **combination** of topics, tools, and knowledge." | "The agent tries to select a **single topic** to respond to the user, falling back to knowledge if configured." |

### A1.5 Known limitation worth flagging to the customer

From [advanced-generative-actions — Known limitations → Knowledge](https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-generative-actions):

> "With generative orchestration turned on, an agent **doesn't use the Conversational boosting system topic** when it searches knowledge sources. Therefore, the agent doesn't use any modifications you make to this system topic to customize how it searches knowledge."

This means: **any attempt to customize knowledge retrieval by editing Conversational boosting is silently ignored while generative orchestration is on.** If the customer has tried that as a workaround, it explains why it had no effect.

### A1.6 Recent changes — release notes check

I checked the Copilot Studio docs' own change metadata rather than a release-notes page:

| Doc | `ms.date` | `updated_at` |
| --- | --- | --- |
| knowledge-copilot-studio | 2026-07-21 | 2026-08-27 |
| advanced-generative-actions | 2026-08-26 | 2026-08-28 |
| requirements-quotas | 2026-06-18 | 2026-08-04 |
| guidance/plan-agent-throughput-rate-limits | 2026-09-17 | 2026-09-17 |

The 25-source filtering behavior is present in the current (Aug 2026) revision of the knowledge doc. **I could not retrieve a Copilot Studio "What's new" / release-plan page to confirm when the 25-source filter was introduced or whether description-based routing below 25 is on a roadmap.** Flagged as unverified.

---

## A2. Documented Limits on Knowledge Sources per Agent

Primary doc: [Quotas and limits — Microsoft Copilot Studio](https://learn.microsoft.com/en-us/microsoft-copilot-studio/requirements-quotas)

### A2.1 Hard ceiling

From *"Copilot Studio web app limits"*:

| Feature | Limit |
| --- | --- |
| **Knowledge sources per agent** | **500 across all types** |
| Instructions for a Copilot agent | 8,000 characters |
| Connector payload | 5 MB (450 KB on GCC) |
| File upload (size) | 512 MB |
| Files uploaded (number) | 500 |
| Skills | 100 per agent |
| Topics | 1,000 per agent (Dataverse environments) |
| Trigger phrases | 200 per topic |

**Critical nuance:** 500 is the *configuration* ceiling. The *behavioral* threshold that matters for fan-out is **25** — above it, GPT-based filtering kicks in; at or below it, it does not. These are different numbers with different meanings and the customer should be told both.

### A2.2 Per-source-type inputs

From [Knowledge sources summary — Supported knowledge sources](https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-copilot-studio):

| Name | Generative mode | Classic mode |
| --- | --- | --- |
| Public website | 25 websites | 4 public URLs |
| Documents (Dataverse upload) | All documents | Limited by Dataverse file storage |
| SharePoint | 25 URLs | 4 URLs per generative answers node |
| Dataverse | Unlimited | 2 sources, up to 15 tables each |
| Enterprise data using connectors | Unlimited | 2 per custom agent |

Classic-orchestration caps in the **Conversational boosting** topic:

| Type of knowledge source | Limit |
| --- | --- |
| Azure OpenAI Service connection | 5 |
| Bing Custom Search Custom Configuration IDs | 2 |
| Custom data sources | 3 |
| Dataverse knowledge sources | 2 sources, up to 15 tables each |
| SharePoint URLs | 4 |
| Uploaded files | Unlimited |
| Website URLs | 4 |

### A2.3 Max documents returned

**Not documented by Microsoft for Copilot Studio.** The observed "top 3 documents per index" is a behavior of the customer's retrieval layer, not a published Copilot Studio parameter. Flagged as unverified.

Related documented caps that could bite:

- Teams channel shows **at most 20 citations**; title ~80 chars, snippet ~480 chars. ([knowledge-copilot-studio — How citations appear on different channels](https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-copilot-studio))
- Azure AI Search semantic ranker reranks **only the top 50** initial results; summary string per document capped at **2,048 tokens**; semantic config field budget ~2,000 tokens / ~20,000 chars. ([Semantic ranking overview](https://learn.microsoft.com/en-us/azure/search/semantic-search-overview))
- Copilot Studio `TooMuchDataToHandle` error fires when the assembled request exceeds the model's max request size. ([Understand error codes](https://learn.microsoft.com/en-us/troubleshoot/power-platform/copilot-studio/authoring/error-codes))

### A2.4 Throughput quotas (relevant to the pro-code team's question)

From [requirements-quotas — Quotas](https://learn.microsoft.com/en-us/microsoft-copilot-studio/requirements-quotas):

| Quota | Value |
| --- | --- |
| Messages to an agent (paid plan, per Dataverse environment) | 8,000 RPM |
| Generative AI messages — 1–10 prepaid message packs | 50 RPM / 1,000 RPH |
| Generative AI messages — 11–50 packs | 80 RPM / 1,600 RPH |
| Generative AI messages — 51–150 packs | 100 RPM / 2,000 RPH |
| Generative AI messages — each extra 10 packs above 150 | +1 RPM / +20 RPH |
| Generative AI messages — trial/developer environments | 10 RPM / 200 RPH |
| Generative AI messages — pay-as-you-go environments | 100 RPM / 2,000 RPH |
| Generative AI messages — Microsoft 365 Copilot users | 100 RPM / 2,000 RPH |

> "When the system reaches the quota, the user chatting with the agent sees a failure notice when they try to send a message."

**These are scoped per Dataverse environment, not per agent.** All agents in the environment share them. This is directly relevant to the pro-code team's enterprise-wide agents.

---

## A3. Official Guidance That Many Knowledge Sources Degrades Quality/Performance

### A3.1 The 30–40 choices rule of thumb

From [Add other agents overview — When to consider breaking your agent into multiple connected agents](https://learn.microsoft.com/en-us/microsoft-copilot-studio/authoring-add-other-agents):

> "You should consider breaking your agent into multiple connected agents when the ability for your agent to differentiate between the available tools, based on their name and description, **starts to degrade**.
>
> As a rule of thumb, this degradation in performance can happen when your main agent has **more than 30-40 choices of action** (tools, topics, and other agents). However, degraded performance can also happen in an agent with a smaller number of tools with **similar descriptions**."

### A3.2 Overlapping descriptions cause unpredictable selection

From [advanced-generative-actions — Best practices](https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-generative-actions):

> "If multiple topics have similar descriptions, your agent selects a single topic to respond rather than invoking all of them, and the overlap makes that selection **unpredictable**. To prevent this behavior, test your agent thoroughly and revise any overlapping descriptions."

Directly applicable: 7 per-business-unit indexes almost certainly have overlapping descriptions ("HR policy documents", "Finance policy documents", …). Even if the customer migrates them to tools or child agents, **description differentiation is the gating factor**.

### A3.3 The explicit consolidate-your-indexes recommendation

This is the strongest and most quotable statement, from [Agentic retrieval overview — Tips for controlling costs](https://learn.microsoft.com/en-us/azure/search/agentic-retrieval-overview):

> - "**Reduce the number of knowledge sources (indexes); consolidating content can lower fan-out and token volume.**"
> - "Lower the reasoning effort to reduce LLM usage during query planning and query expansion (iterative search)."
> - "Organize content so the most relevant information can be found with **fewer sources and documents** (for example, curated summaries or tables)."

Note this is Azure AI Search guidance (about agentic retrieval / Foundry IQ), not Copilot Studio guidance, but it is Microsoft's most direct published statement that index fan-out is a cost and performance problem and that consolidation is the fix.

### A3.4 Multi-agent latency warning

From [Add other agents overview — Potential impacts of multi-agent solutions](https://learn.microsoft.com/en-us/microsoft-copilot-studio/authoring-add-other-agents):

> "Having your solution split across multiple agents can:
>
> - **Increase latency** due to the extra orchestration hops that are introduced. For example, the main agent orchestration identifies a connected agent that can handle the query. The connected agent then runs using *its own* orchestration layer to determine how to handle the query with its available tools.
> - Increase the testing, management, and governance surface area for a solution."

### A3.5 General performance guidance

From [Best practices for improving conversational agent performance](https://learn.microsoft.com/en-us/microsoft-copilot-studio/guidance/conversational-agents-performance-improvement):

- Place API/connector calls strategically to avoid stacking waits.
- Cache retrieved information in variables instead of repeated calls.
- Prefer direct connector calls or the **Send HTTP Request** node over Power Automate cloud flows (flows add latency).
- "Generative AI models handle a wider range of inputs but **can introduce latency**."

---

## A4. Recommended Architectural Alternatives — Comparison

### A4.0 Scoring criterion

"Reduces per-turn fan-out?" = does this option reduce the number of distinct Azure AI Search *semantic* query operations issued per user turn? That is the metric that maps to the semantic ranker concurrency ceiling identified in A6, which is the actual scaling constraint.

### A4.1 Comparison table

| # | Option | Reduces per-turn fan-out? | Effort | Key risk | Primary reference |
| --- | --- | --- | --- | --- | --- |
| 1 | **Consolidate 7 indexes → 1 index + filterable `businessUnit` field + `$filter` / security trimming** | **YES — 7 → 1.** Strongest single lever. | High (re-index, re-ingest, re-permission) | Requires the caller to know which BU to filter on; loses per-index isolation; ingestion pipeline rework | [Security filter pattern](https://learn.microsoft.com/en-us/azure/search/search-security-trimming-for-azure-search) |
| 2 | **Convert knowledge sources → Tools (custom connector actions), selected by description** | **YES — orchestrator invokes tools selectively by name/description.** | Medium | Description quality is the gate; loses built-in citation rendering; "citations returned from a knowledge source can't be used as inputs to other tools" | [advanced-generative-actions](https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-generative-actions), [Add tools to custom agents](https://learn.microsoft.com/en-us/microsoft-copilot-studio/add-tools-custom-agent) |
| 3 | **Child agents / connected agents — one per business unit, parent routes by description** | **YES per hop** — parent picks one child; that child holds 1 index. But each child runs its *own* orchestration → extra latency. | Medium–High | Added latency; auth must match across agents; no multi-level chaining; governance surface grows | [Add other agents overview](https://learn.microsoft.com/en-us/microsoft-copilot-studio/authoring-add-other-agents) |
| 4 | **Explicit topic + conditional logic → single generative answers node with one source** | **YES — deterministic, 1 source per branch.** | Low–Medium | Requires classic orchestration OR a topic with `The agent chooses` trigger; brittle to new intents; loses generative flexibility | [Add a generative answers node](https://learn.microsoft.com/en-us/microsoft-copilot-studio/nlu-boost-node) |
| 5 | **Azure AI Search agentic retrieval / Foundry IQ** | **PARTIAL / CONDITIONAL.** `minimal` reasoning effort **uses all knowledge sources** (bypasses LLM planning). `low`/`medium` do LLM-based source selection. Also *increases* subqueries per turn. | High (new API surface, preview features) | `minimal` = no routing at all; token-based billing; preview features have no SLA | [Agentic retrieval overview](https://learn.microsoft.com/en-us/azure/search/agentic-retrieval-overview), [Service limits — Agentic retrieval limits](https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity#agentic-retrieval-limits) |
| 6 | **Scale Azure AI Search (replicas / tier)** — what they already did | **NO.** Fan-out is unchanged; capacity to absorb it grows. | Low | Cost scales as replicas × partitions; masks the design problem; breaks again as users grow | [Estimate capacity](https://learn.microsoft.com/en-us/azure/search/search-capacity-planning) |
| 7 | **Disable semantic ranker on some/all indexes** | **NO** to fan-out, **YES** to the specific 206 failure mode (removes the semantic concurrency ceiling). | Low | Relevance regression — semantic L2 reranking is the main quality lever | [Semantic ranking overview](https://learn.microsoft.com/en-us/azure/search/semantic-search-overview) |
| 8 | **Move to >25 knowledge sources to trigger GPT filtering** | Technically yes but **do not do this.** | — | Perverse incentive; adds latency and cost; contradicts the 30–40 choices guidance | [knowledge-copilot-studio](https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-copilot-studio) |

### A4.2 Ranked recommendation

**Rank 1 — Consolidate to a single index with a filterable `businessUnit` field.**
Directly attacks the root cause (7 semantic queries → 1). Aligns with Microsoft's own published advice ("consolidating content can lower fan-out and token volume"). Enables `search.in()` security trimming so a user only sees their BU's content without needing 7 physical indexes.

Implementation pattern from [Security filter pattern](https://learn.microsoft.com/en-us/azure/search/search-security-trimming-for-azure-search):

```jsonc
// Index field
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

Microsoft's own note on why `search.in` and not `or`-chains:

> "There are several ways to achieve security filtering. One way is through a complicated disjunction of equality expressions… This approach is error-prone, difficult to maintain, and in cases where the list contains hundreds or thousands of values, **slows down query response time by many seconds**. A better solution is using the `search.in` function… you can expect **subsecond** response times."

Also note the caveat Microsoft added:

> "Setting `retrievable` to `false` prevents `group_ids` from being returned as part of a document in search results. It **isn't a content-obfuscation or field-level security mechanism.** In this pattern, document-level authorization is enforced by applying the security filter to **every** query."

Alternative to hand-rolled trimming: Azure AI Search now has [built-in document-level access control](https://learn.microsoft.com/en-us/azure/search/search-document-level-access-overview) (ACL support), which is preferable where the source system supports it.

**Rank 2 — Convert per-BU retrieval into Tools, not knowledge sources.**
This is the answer to the customer's stated blocker ("technically it's not possible while we keep a single agent with knowledge sources"). It is not possible *with knowledge sources*. It **is** possible with tools, because tools are explicitly description-selected by the orchestrator. Cheapest path to description-driven routing without an index rebuild. Can be combined with Rank 1 later.

**Rank 3 — Child/connected agents, one per BU.**
Right answer if the 7 BUs genuinely have different owners, lifecycles, auth, or need to be independently publishable. Microsoft's own criteria from [authoring-add-other-agents](https://learn.microsoft.com/en-us/microsoft-copilot-studio/authoring-add-other-agents): use **child agents** when one team owns everything and the subagents need no separate settings/auth/deployment; use **connected agents** when multiple teams manage agents independently, agents need separate ALM, or reuse across parents is required. Accept the latency cost.

**Rank 4 — Explicit topic + conditional logic.**
Deterministic and cheap, but it hard-codes intent routing and regresses the generative UX. Good as a targeted fix for a few high-volume intents, not as the whole architecture.

**Rank 5 — Agentic retrieval / Foundry IQ (pro-code team).**
Worth evaluating for the pro-code team but **note the trap**: from [Service limits — Knowledge source selection during retrieval](https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity#agentic-retrieval-limits), *"The `minimal` reasoning effort uses **all** knowledge sources in the knowledge base because it bypasses LLM-based query planning."* And agentic retrieval *adds* subqueries: *"Runs subqueries in parallel. Each subquery is semantically reranked."* So naïve adoption can make the semantic concurrency problem **worse**, not better.

Agentic retrieval limits worth recording:

| Resource | Free | Basic | S1 | S2 | S3 | L1 | L2 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Max knowledge sources per service | 3 | 5 or 15 | 50 | 200 | 200 | 10 | 10 |
| Max knowledge bases per service | 3 | 5 or 15 | 50 | 200 | 200 | 10 | 10 |
| Max knowledge sources per knowledge base | 3 | 5 or 10 | 10 | 10 | 10 | 10 | 10 |
| Sources selectable during retrieval (`minimal`/`low`/`medium`, API `2026-05-01-preview`+) | 3 | 5 or 10 | 10 | 10 | 10 | 10 | 10 |

`maxRuntimeInSeconds`: min 10 / default 90 / max 600.

---

## A5. DEFINITIVE ANSWER — Does Copilot Studio Route to Knowledge Sources by Description?

**Answer: Partially — and for this customer's configuration, effectively NO.**

Broken into three precise claims:

| Claim | Verdict | Evidence |
| --- | --- | --- |
| The orchestrator decides **whether** to search knowledge at all on a given turn | **TRUE** | "The agent can choose to **proactively search knowledge** to answer a user's query." — [advanced-generative-actions](https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-generative-actions) |
| Descriptions drive selection of **topics, tools, and other agents** | **TRUE** | "The most important factor is the description of the topics, tools, agents, and knowledge sources." — [advanced-generative-actions](https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-generative-actions) |
| Descriptions narrow **which knowledge sources** are searched when there are ≤25 | **FALSE** | "Generative orchestration filters knowledge sources by using an internal GPT model **when there are more than 25 different knowledge sources**." — [knowledge-copilot-studio](https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-copilot-studio) |

**What to tell the customer, verbatim-safe:**

> Your observation is correct and it is expected, documented behavior — not a bug and not a misconfiguration. Copilot Studio's generative orchestration only applies GPT-based filtering to knowledge sources once an agent has **more than 25** of them. With 7, all configured knowledge sources participate in the knowledge search on every turn where the orchestrator decides to search knowledge.
>
> Your statement that it is "technically not possible while we keep a single agent with knowledge sources" is accurate **as long as they remain knowledge sources**. It becomes possible the moment you express them as **tools** or as **child/connected agents**, both of which the orchestrator selects by name and description. That is the core architectural correction.

**Nuance to add:** the orchestrator uses conversation history and context, so the same question can behave differently in a fresh test session versus a long Teams thread:

> "When your agent determines how to respond to a user message or event, it can use previous conversation history and context to influence its decisions. This behavior explains that you might see different responses for the same query between a fresh conversation and an ongoing conversation." — [advanced-generative-actions](https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-generative-actions)

This may be part of what the customer perceives as "inconsistent / random across indexes."

---

## A6. Concurrency, QPS, and Replica Sizing — THE ROOT CAUSE SECTION

### A6.1 The semantic ranker concurrency ceiling (primary root cause)

From [Service limits for tiers and SKUs — Throttling limits → Semantic ranker throttling limits](https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity#throttling-limits):

> "Semantic ranker uses a **queuing system** to manage concurrent requests… When the limit of concurrent requests is reached, the system places additional requests in a **queue**. If the **queue is full**, the system **rejects** further requests and they must be retried."

| Resource | Basic | S1 | S2 | S3 | S3 HD | L1 | L2 | Serverless Dev |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **Max concurrent requests (per search unit)** | **2** | **3** | 4 | 4 | 4 | 4 | 4 | 4 (per service) |
| **Max request queue size (per search unit)** | **4** | **6** | 8 | 8 | 8 | 8 | 8 | 8 (per service) |

> "The following table describes the semantic ranker throttling limits by tier, subject to available capacity in the region. **You can contact Microsoft support to request a limit increase.**"

Total semantic QPS varies by: tier, number of search units, total available semantic ranker capacity **in the region**, and how long each query takes.

### A6.2 The arithmetic that explains the customer's symptoms

Assumptions: 7 indexes queried per turn, semantic ranking enabled on each, one semantic request per index per turn.

| Configuration | Concurrent capacity | Queue | Total in-flight | Verdict for a **single** 7-index turn |
| --- | --- | --- | --- | --- |
| Basic, 1 replica × 1 partition = 1 SU | 2 | 4 | **6** | **FAILS** — 7 > 6. One user alone can trip it. |
| Basic, 3 replicas × 1 partition = 3 SU | 6 | 12 | 18 | 1 user OK; ~2 concurrent users marginal |
| S1, 1 SU | 3 | 6 | 9 | 1 user OK; 2 users fail |
| S1, 3 replicas × 1 partition = 3 SU | 9 | 18 | 27 | ~3 concurrent turns OK |
| S1, 6 replicas × 1 partition = 6 SU | 18 | 36 | 54 | ~7 concurrent turns OK |
| S1, 12 replicas × 1 partition = 12 SU | 36 | 72 | **108** | ~15 concurrent turns OK |

This explains, in order, every symptom reported:

| Symptom | Explanation |
| --- | --- |
| "206 partial success — retrieval succeeds but ranking components fail" | Exactly the documented semantic-ranker rejection path. Base BM25/RRF retrieval succeeds; the L2 semantic rerank is rejected → partial content. |
| "Empty responses even when index contains data" | When the semantic stage is dropped, captions/answers are absent; the Copilot Studio synthesis layer has degraded or missing grounding → no grounded answer. Compounded by the citation requirement (see A6.6). |
| "Inconsistent, affects multiple indexes randomly" | The 7 fan-out requests race for the same shared semantic queue. Which of the 7 gets rejected is nondeterministic. |
| "Increasing replicas fixed it" | Replicas increase search units; the semantic concurrency limit is **per search unit**, so capacity scales linearly with SU. |
| "Basic → S1 largely fixed it" | Per-SU concurrent limit went 2 → 3 (+50%), queue 4 → 6, **and** the replica ceiling went from 3 (older Basic) to 12. |
| "Concern about future scaling from ~7–15 users/hour" | 7–15 users/hour is not the metric that matters. **Concurrent turns** is. 3 simultaneous users on S1/3SU = 21 concurrent semantic requests vs. 27 capacity — already at ~78%. |

**Present this arithmetic to the customer.** It converts "increasing replicas seemed to help" into a defensible capacity model.

### A6.3 A documentation conflict to flag

There are **two different published numbers** for semantic ranker concurrency and they do not agree:

| Source | Statement | Doc date |
| --- | --- | --- |
| [Add semantic ranking — Expected workloads](https://learn.microsoft.com/en-us/azure/search/semantic-how-to-query-request) | "For semantic ranking, you should expect a search service to support up to **10 concurrent queries per replica**." | `ms.date` 2026-04-24 |
| [Service limits — Semantic ranker throttling limits](https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity#throttling-limits) | Basic **2** / S1 **3** / S2+ **4** concurrent **per search unit** | `ms.date` 2026-09-16 |

These differ in both magnitude (10 vs 2–4) and unit (per **replica** vs per **search unit**). The limits page is newer, tier-specific, and includes the queue dimension, so it is the more likely current truth — but **this discrepancy is itself a legitimate, high-value question for the support ticket.** Ask CSS to confirm the authoritative number for the customer's exact tier, region, and SU configuration. Put it in the ticket explicitly.

### A6.4 The documented error signature (quote this in the ticket)

From [Add semantic ranking — Expected workloads](https://learn.microsoft.com/en-us/azure/search/semantic-how-to-query-request):

> "The service throttles semantic ranking requests if volumes are too high. An error message that includes these phrases indicate the service is at capacity for semantic ranking:
>
> ```json
> Error in search query: Operation returned an invalid status 'Partial Content'
> @search.semanticPartialResponseReason
> CapacityOverloaded
> ```
>
> If you anticipate consistent throughput requirements near, at, or higher than this level, **please file a support ticket so that we can provision for your workload.**"

**`Partial Content` is HTTP 206.** This is the customer's exact symptom, named in the docs, with Microsoft's own instruction to open a ticket.

### A6.5 Replica/partition sizing — what Microsoft does and does not commit to

From [Estimate capacity for query and index workloads](https://learn.microsoft.com/en-us/azure/search/search-capacity-planning):

- Search unit (SU) = replicas × partitions. Billing = SU.
- **Replicas → query throughput and availability. Partitions → storage and indexing throughput.**
- "As a general rule, search applications tend to need **more replicas than partitions**, particularly when the service operations are biased toward query workloads."
- Add capacity when: latency rises, SLA missed, 503s increase, 429s increase, large query volumes expected, indexing slow.
- **The explicit non-answer on replica counts:** "There are **no guidelines** on how many replicas are needed to accommodate query loads. Query performance depends on the complexity of the query and competing workloads. Although adding replicas clearly results in better performance, the result **isn't strictly linear**: adding three replicas doesn't guarantee triple throughput."
- SLA: **2+ replicas** satisfy query (read) SLA; **3+ replicas** satisfy query and indexing (read-write) SLA. Partition count does not affect SLA. ([SLA for Azure AI Search](https://azure.microsoft.com/support/legal/sla/search/v1_0/))
- Adding replicas/partitions "can introduce slight variations in how results are ordered."
- Scaling takes minutes to hours, cannot be cancelled or progress-monitored.

Tier ceilings from [Service limits](https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity):

| Resource | Basic | S1 | S2 | S3 |
| --- | --- | --- | --- | --- |
| Partitions | 3 (1 if created before 2024-04-03) | 12 | 12 | 12 |
| Replicas | 3 | 12 | 12 | 12 |
| Max SU | 3 (9 on post-2024-04-03 Basic) | 36 | 36 | 36 |
| Max indexes | 5 or 15 | 50 | 200 | 200 |
| Max services per region per subscription | 16 | 16 | 8 | 6 |

**Note on the customer's 7 indexes:** Basic supports 15 indexes (5 if created before Dec 2017), so index count was never the constraint — but it is worth recording in the ticket that the service was on Basic with 7 indexes, because it bounds the SU math.

Also note the relevant tier-switch constraint they already exercised:

> "You can switch between Basic, S1, S2, and S3, but you can't switch to or from Free, S3HD, L1, or L2."

And the downgrade trap: "the Basic tier supports up to 15 indexes, so you can't switch from S1 to Basic if you have 16 indexes."

### A6.6 A second, independent cause of "empty answers" worth ruling out

From [Knowledge sources summary — Why the agent sometimes doesn't return a grounded answer](https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-copilot-studio):

> "When you turn off **Allow ungrounded responses**, the agent returns an answer from a knowledge source only when the answer includes an **in-text citation** to that source… Occasionally, the model generates a correct answer from a knowledge source but **doesn't include a citation** for it. When that happens, the agent **withholds the answer** and responds as though it didn't find any information. Because models don't always include citations, this behavior can be **intermittent**. For example, asking the same question again might return the answer."

This is a *separate, non-capacity* explanation for intermittent empty answers. Mitigations Microsoft recommends:

- Add citation instructions to agent instructions ("Always include an in-text citation to the source document for every statement").
- Avoid instructions that suppress citations (e.g. "respond only in JSON", "omit references").
- For custom data sources, populate `ContentLocation` (URL) and `Title`.

**Action:** check whether **Allow ungrounded responses** is off. If it is, some fraction of the "empty answers" may not be search-capacity related at all. Rule this out before or alongside the ticket so CSS doesn't chase the wrong signal.

### A6.7 Copilot Studio-side concurrency guidance for the pro-code team

From [Plan Copilot Studio agent deployments for throughput and rate limits](https://learn.microsoft.com/en-us/microsoft-copilot-studio/guidance/plan-agent-throughput-rate-limits) (published 2026-09-17 — very current):

Key principles:

- **Rate provisioning ≠ license provisioning.** Two separate workstreams.
- "Monthly volume is useful for estimating total demand, but it isn't enough for rate provisioning. Convert expected usage into **smaller time windows** — per minute, per five minutes, per 10 minutes, per hour, per day."
- "The **lowest limit in the runtime path** determines the user experience. A Copilot Studio agent can be within its own limits while a flow, connector, Dataverse call, language service, or **external API** is throttled."
- Limits apply at environment, tool, API, connector, channel, and downstream-service level — not just per agent.
- Design first, scale second: "Don't make rate increases your first design response. First, review the agent design and optimize efficiency… keep external calls intentional, optimize API calls, and **avoid unnecessary request volume**."
- Environment segmentation: "consider splitting agents across multiple environments… to keep high-volume agents, business units, regions, or autonomous workloads from competing with unrelated workloads for the same environment-scoped limits." ← **Directly relevant to the pro-code team's enterprise-wide agents.**

**Pilot requirement (hard gate for any limit-increase request):**

> "Throughput increase requests are reviewed against **observed usage**. Projected volumes, estimates produced during design, small user acceptance testing (UAT) runs, and **synthetic load tests aren't accepted as justification on their own**. Run a pilot phase and submit the measured results."

Pilot design per Microsoft:

| Attribute | Guidance |
| --- | --- |
| Audience | Large, representative section of the intended audience — not a project team |
| Duration | At least one week, covering a complete business cycle including peaks |
| Configuration | Keep the **production runtime path** — same channels, topics, generative AI config, knowledge sources, actions, flows, connectors |
| Telemetry | Turn on analytics, Application Insights, admin center reporting **before** the pilot starts |

Metrics to capture during pilot:

- Messages per minute and per hour, average and peak
- Sessions, **concurrent sessions**, session length, messages per session
- Generative AI calls per turn and per session
- Power Automate actions, connector calls, Dataverse requests per agent turn
- Throttling events, usage limit errors, retries, latency during peak
- Pilot audience size as a share of full intended audience

**Answer to "how many replicas per N concurrent users":** Microsoft publishes **no such formula**, and explicitly declines to ("There are no guidelines on how many replicas are needed to accommodate query loads"). The defensible substitute is the SU arithmetic in A6.2:

```text
required_SU ≈ ceil( (concurrent_turns × indexes_per_turn) / concurrent_semantic_per_SU )
```

With headroom (target ≤60% of concurrent capacity, relying on the queue only for burst):

```text
S1: concurrent_semantic_per_SU = 3
7 indexes/turn, 10 concurrent turns → 70 concurrent semantic requests
70 / 3 = 23.3 SU → 24 SU (e.g. 12 replicas × 2 partitions)
```

vs. consolidated to 1 index:

```text
1 index/turn, 10 concurrent turns → 10 concurrent semantic requests
10 / 3 = 3.3 SU → 4 SU
```

**A 6× reduction in required search units.** This is the business case for Rank 1 in A4.2, and it should be the headline slide for the customer.

---

# PART B — CSS Escalation Path

## B0. Decision Tree — Which Portal for Which Symptom

```text
Symptom observed
│
├─ HTTP 206 / "Partial Content" from Azure AI Search
├─ @search.semanticPartialResponseReason = CapacityOverloaded
├─ HTTP 503 / 429 from search.windows.net
├─ Semantic ranker concurrency limit increase request
├─ Search latency / replica-partition sizing advice
├─ APIM gateway 403/5xx between Copilot Studio and Search
│      → AZURE PORTAL
│        portal.azure.com > Help + support > Create a support request
│        Service: "Azure AI Search"  (separate ticket for "API Management")
│
├─ Copilot Studio error 613 / connector 403
├─ "All 7 knowledge sources queried every turn" orchestration behavior
├─ Empty generative answers / missing citations
├─ Copilot Studio RPM/RPH quota increase (generative AI messages)
├─ Connector "black box" — no visibility into request payloads
│      → POWER PLATFORM ADMIN CENTER
│        admin.powerplatform.microsoft.com > Support > Support requests > Get support
│        Product: "Microsoft Copilot Studio"
│
└─ Issue spans both and you can't isolate
       → OPEN BOTH, cross-reference case numbers in each description.
         Neither portal can transfer a case to the other product's engineering team.
```

**Recommended sequencing for this customer:**

1. **Open the Azure AI Search ticket first.** It has the strongest documented basis (Microsoft's own docs say to file it), the clearest ask (confirm/raise semantic concurrency limit), and it is the actual root cause.
2. **Open the Copilot Studio ticket second**, referencing the Azure case number, for (a) the 613/403 connector errors and (b) confirmation of knowledge-source fan-out behavior and any roadmap for sub-25 description routing.
3. If APIM is confirmed as the 403 source, that is a **third** Azure ticket under service "API Management" — or fold it into the AI Search ticket only if you can demonstrate the 403 originates at the search service, not the gateway.

---

## B7. Opening an Azure Support Ticket

Primary doc: [How to create an Azure support request](https://learn.microsoft.com/en-us/azure/azure-portal/supportability/how-to-create-azure-support-request)

### B7.1 Portal and entry points

- Commercial: `https://portal.azure.com`
- US Government: `https://portal.azure.us`
- Direct link: `https://portal.azure.com/#create/Microsoft.Support`

Three entry points:

1. **Global header** — select `?` > describe issue > **Create a support request**
2. **Resource menu** — on the search service, **Help** > **Support + Troubleshooting** (pre-fills resource context — **use this one**, it attaches the resource)
3. Programmatically — [Azure support ticket REST API](https://learn.microsoft.com/en-us/rest/api/support) or [Azure CLI `az support`](https://learn.microsoft.com/en-us/cli/azure/support)

### B7.2 RBAC required

> "You must have the [Owner], [Contributor], or [Support Request Contributor] role, or a custom role with [Microsoft.Support/*], **at the subscription level**."

For read-only participation on a multi-subscription case: Reader / Support Request Contributor, or a custom role with `Microsoft.Support/supportTickets/read`.

> "If the issue applies to multiple subscriptions, you can mention additional subscriptions in your description… However, the support engineer will only be able to work on subscriptions to which **you** have access."

### B7.3 Support plan requirement

> "Azure provides **unlimited** support for subscription management, which includes billing, quota adjustments, and account transfers. For **technical support, you need a support plan**."

Plan comparison: <https://azure.microsoft.com/support/plans>

To link a plan requiring Access ID / Contract ID: **Help + Support** > **Support** > **Support Plans** > **Link support benefits**.

### B7.4 Severity and initial response times

Source: [Support scope and responsiveness](https://azure.microsoft.com/en-us/support/plans/response/)

| Severity | Business impact | Developer | Standard | ProDirect | Unified Enterprise | Azure Rapid Response |
| --- | --- | --- | --- | --- | --- | --- |
| **A** | Critical — significant loss/degradation, immediate attention | **N/A** | < 1 hr | < 1 hr | < 1 hr | < 15 min |
| **B** | Moderate — loss/degradation, work continues impaired | **N/A** | < 4 hr | < 2 hr | < 2 hr | < 2 hr |
| **C** | Minimum — minor impediments | < 8 hr | < 8 hr | < 4 hr | < 4 hr | < 4 hr |

Key constraints:

- **Maximum severity for Developer support is Severity C.** A and B are unavailable.
- Sev A/B: 24×7 access. Sev C: business hours only.
- Business hours: generally 9:00–17:00 weekdays; **North America 6:00–18:00 Pacific Mon–Fri**; Japan 9:00–17:30.
- "Microsoft may downgrade the severity level if the customer is not able to provide adequate resources or responses."
- 24×7 in English for Sev A/B (and Japanese for Sev A). Local-language support during local business hours: English, Spanish, French, German, Italian, Portuguese, Traditional Chinese, Korean, Japanese.
- Unified Support response times: <https://www.microsoft.com/microsoft-unified/plan-details>

**Severity recommendation for this customer:** **Severity B**. Service is functioning post-mitigation (S1 + replicas) so it is not a Sev A critical outage, but there is unresolved intermittent degradation with a known scaling cliff ahead. Sev B also buys < 2 hr response on ProDirect/Unified. Do not inflate to Sev A — the docs warn of automatic downgrade and it burns credibility.

### B7.5 The five-step wizard

| Step | What it does | What to do |
| --- | --- | --- |
| **Problem description** | Issue type, service, problem type/subtype, subscription | Issue type **Technical**; Service **Azure AI Search**; select the subscription where the search service lives. "Selecting an unrelated service **may result in delays**." |
| **Recommended solution** | Auto-suggested fixes, sometimes auto-diagnostics | Read them; they can auto-resolve. Then **Return to support request** > **Next**. |
| **Additional details** | Problem details, **one** file upload (use a .zip), advanced diagnostic consent, support plan, severity, contact method, language | Upload the evidence bundle as a single .zip. Set **Advanced diagnostic information = Yes**. Set severity. |
| **Review + create** | Final review | Verify contact country/region — it determines which business hours apply. |
| — | — | "Be sure **not to include any personal or confidential information**" in problem details. |

### B7.6 Advanced diagnostics

> "Selecting **Yes** allows Azure support to gather [advanced diagnostic information](https://azure.microsoft.com/support/legal/support-diagnostic-information-collection/) from your Azure resources."

Say yes. It materially shortens time-to-resolution and there is a published data-handling policy.

### B7.7 Azure AI Search docs that explicitly direct you to file a ticket

These are useful citations to include so the case is routed as a known, documented scenario:

| Scenario | Doc |
| --- | --- |
| Semantic ranker at capacity / `CapacityOverloaded` / Partial Content | [semantic-how-to-query-request — Expected workloads](https://learn.microsoft.com/en-us/azure/search/semantic-how-to-query-request) |
| Semantic ranker concurrency **limit increase** | [search-limits-quotas-capacity — Semantic ranker throttling limits](https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity#throttling-limits) |
| More services per subscription than the tier allows | [search-limits-quotas-capacity — Subscription limits](https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity) |
| Quota/capacity failure that persists | "open an Azure support request that includes the **subscription, region, tier, requested configuration, full error text, UTC time, and any correlation or operation ID**." — [search-limits-quotas-capacity — Diagnose quota, capacity, or limit failures](https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity) |
| Unexpected/unknown skill failure | [cognitive-search-common-errors-warnings](https://learn.microsoft.com/en-us/azure/search/cognitive-search-common-errors-warnings) |

That last quote is effectively Microsoft's own minimum evidence list for an Azure AI Search capacity ticket. It is reproduced in the evidence checklist below.

---

## B8. Opening a Power Platform / Copilot Studio Support Ticket

Primary docs:

- [Get support in the Power Platform admin center](https://learn.microsoft.com/en-us/power-platform/admin/get-help-support)
- [Support for Microsoft Power Platform and Dynamics 365 apps](https://learn.microsoft.com/en-us/power-platform/admin/support-overview)
- [Find community help and support — Copilot Studio](https://learn.microsoft.com/en-us/microsoft-copilot-studio/fundamentals-support)

### B8.1 Path

1. Sign in to <https://admin.powerplatform.microsoft.com>
2. Navigation pane > **Support**
3. **Support** pane > **Support requests**
4. **Get support**

Manage existing cases: <https://admin.powerplatform.microsoft.com/support/requests>

**This is a different portal, a different permission model, a different support-plan entitlement, and a different engineering org from Azure.** An Azure Unified contract may or may not cover Power Platform — verify before filing.

### B8.2 Permission required (critical blocker to check first)

You must hold one of these roles. **End users cannot open cases.**

Billing Admin · Company Admin · Compliance Admin · CRM Organization Admin · CRM Service Admin · **Environment Admin (or System Admin in Dataverse)** · Exchange Admin · Helpdesk Admin · LCS User · Microsoft Entra Role Admin · Partner Delegated Admin · Power Apps Environment Admin · Power Apps Full Admin · Fabric Admin · **Power Platform Admin** · Security Admin · Service Admin · SharePoint Admin · Teams Admin

> "End users can't open support requests and must have their permissions elevated within the tenant to do this. **There's no alternative to this experience.**"

### B8.3 Support plan requirement

> "You can access self-help resources in the **Support** experience without a support plan. However, **to create a support request, you must have an active support plan.**"

Accepted plans: **Subscription support**, **Professional Direct support**, **Unified support**.

Failure modes Microsoft calls out:

- Issue with Unified/Premier contract → contact incident manager or CSAM.
- Expired subscription → renew.
- Plan not found → for Unified/Premier contact CSAM; otherwise verify the plan is active.

Adding a plan: **Support plans** button on any Support page > enter **Access ID** + **Password** > **Save**. "It might take **up to an hour** to appear."

> "The **Contract ID**/**Password** defaults to the Unified or Premier contract ID. If you changed the password when registering online in the Unified/Premier portal, use the updated password instead of the contract ID."

### B8.4 Two UX flows

| Flow | When | Notes |
| --- | --- | --- |
| **Support agent** (AI virtual agent) | Default for most tenants | Chat-driven: describe issue > confirm product > answer clarifying questions > review generative answers > create request. "AI-generated content might be incorrect." |
| **Backup support experience** (web form) | Agent unavailable/crashed/slow, or policy | Select **Switch to web form** at top of panel. A crash triggers an **8-hour cooldown** where the web form loads by default. |

### B8.5 Product selection — routing trap

> **Important:** "Selecting **Dynamics 365 Customer Service** for customer service with another product **misroutes and delays a request**."
>
> "For administration issues or if you encountered an issue in Power Platform admin center, select **Power Platform Administration** as the product."

**Select product = "Microsoft Copilot Studio".** Not Power Apps, not Power Automate, not Dataverse — unless you specifically need a **support environment**, in which case:

> "Currently, you can't create support environments for the Power Apps or Power Automate product options… To create a support request that includes a support environment for Power Platform issues, select the **Microsoft Dataverse** product."

### B8.6 Severity and initial response times

Source: [support-overview — Severity and responsiveness](https://learn.microsoft.com/en-us/power-platform/admin/support-overview)

| Severity | Business impact | Standard | ProDirect | Unified Enterprise | Access |
| --- | --- | --- | --- | --- | --- |
| **A** | Critical — significant loss/degradation | < 1 hr | < 1 hr | < 1 hr | 24×7 |
| **B** | Moderate — loss/degradation, work continues impaired | < 4 hr | < 2 hr | < 2 hr | Business hours (24×7 available) |
| **C** | Minimum — minor impediments | < 8 hr | < 4 hr | < 4 hr | Business hours |

Warnings straight from the doc:

> - "Submitting a **Severity A** request means you can engage with Microsoft until the issue is resolved. If you can't do so, file your case at a lower severity to avoid downgrade."
> - "Selecting **Severity A** for a low priority issue results in **automatic downgrade**."
> - "Selecting **Technical** in order to submit an **Advisory** request results in **closure** of your request."

### B8.7 Technical vs Advisory — pick correctly

> - "**Technical support** involves ***break-fix*** issues, which are technical problems you experience while using services."
> - "Understanding **how functionality works** isn't a break-fix issue but is related to **training**. These ***how-to*** questions, or **advisory services**, involve knowledge transfer."

Mapping for this customer:

| Question | Type |
| --- | --- |
| Connector 613 / repeated 403s at runtime | **Technical (break-fix)** |
| Empty answers despite populated indexes | **Technical (break-fix)** |
| "Can the orchestrator route to one knowledge source by description?" | **Advisory** — and it's already answered in A5, so don't spend a case on it |
| Architecture review of 7-index → 1-index consolidation | **Advisory** (ProDirect / Unified only) |

**Some support plans do not include Advisory.** Mixing an advisory question into a technical case risks closure.

### B8.8 Advanced diagnostic consent

> "Microsoft **can't access or run diagnostics** on data in your tenant or environment **without consent**. If you don't provide consent when it's required, a Microsoft support representative will contact you to update the consent before proceeding."

Grant it up front. See [Support environment](https://learn.microsoft.com/en-us/power-platform/admin/support-environment).

### B8.9 Environment identification

> "If the affected environment isn't listed, select **My environment is not listed** and provide the **URL of the environment**."

Have the **Environment ID** and environment URL ready.

### B8.10 Two things Power Platform support will NOT do

> **RCA:** "Technical support **doesn't conduct RCAs** as part of any support experience… RCAs are only provided to **published service-related incidents when multiple customers or services aren't available**… Any other request for an RCA to a specific scenario impacting your tenant **won't be honored** by the engineering team."

**This directly affects the customer's stated goal.** They want "root cause analysis." They will not get a formal RCA document from Power Platform support for a single-tenant issue. Frame the ask as *"identify and remediate the cause of these errors"*, not *"provide an RCA."* The Azure AI Search side is the one that can actually give a technical causal explanation, which is another reason to lead with that ticket.

> **Performance issues, 4-hour cap:** "The Microsoft Dynamics support team invests **up to four hours** of time on a break-fix case to assist. If after four hours the issue isn't resolved, consult a partner or the community forums for further investigation. The technical support incident is then closed. Premier and Unified Support customers may be able to continue via an **advisory case**."

So: bring excellent evidence, or have Unified/ProDirect to continue via advisory.

### B8.11 Reporting an outage / throughput increase

- **Report outage** button next to **Get support** (if enabled in tenant) raises a high-priority request.
- **Throughput increase**: follow [Plan Copilot Studio agent deployments for throughput and rate limits — What to do if default rate limits aren't enough](https://learn.microsoft.com/en-us/microsoft-copilot-studio/guidance/plan-agent-throughput-rate-limits). Requires pilot data (see A6.7). Required fields listed in B9.4.

  > "A throughput increase **isn't guaranteed**. Microsoft Support reviews requests based on the scenario, environment, requested date range, observed pilot traffic, eligibility, current limits, and service capacity."

### B8.12 Self-help to exhaust first (and cite in the case)

- **Service health**: <https://admin.powerplatform.microsoft.com/support/serviceHealth> — active and recently resolved disruptions; you can flag that you're seeking support for a listed issue.
- **Known issues**: Support > Known Issues page — product-team-published bugs and workarounds.
- **Generative answers**: real-time answers from Microsoft docs + community. "AI-generated content might be incorrect."

---

## B9. Diagnostic Evidence Checklist — Collect BEFORE Filing

Microsoft's own minimum for an Azure AI Search capacity ticket, verbatim from [search-limits-quotas-capacity](https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity):

> "…open an Azure support request that includes the **subscription, region, tier, requested configuration, full error text, UTC time, and any correlation or operation ID**."

Everything below expands on that.

### B9.1 Azure AI Search service facts

- [ ] Search service **name** and full **resource ID** (`/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Search/searchServices/{name}`)
- [ ] **Subscription ID** and **tenant ID**
- [ ] **Region**
- [ ] **Tier** now (S1) and **tier at time of failure** (Basic) — plus the date of the tier change
- [ ] **Replica count** and **partition count** now and at failure time → compute **search units (R × P)** for both
- [ ] **Service creation date** — determines Basic partition ceiling (1 vs 3) and storage/vector limits. Check via [search-how-to-upgrade](https://learn.microsoft.com/en-us/azure/search/search-how-to-upgrade#check-your-service-creation-or-upgrade-date)
- [ ] **Number of indexes** (7) and index names
- [ ] **Semantic ranker billing plan** — free plan vs standard plan ([semantic-how-to-enable-disable](https://learn.microsoft.com/en-us/azure/search/semantic-how-to-enable-disable))
- [ ] Semantic configuration JSON per index (title/keywords/content field assignment and order)
- [ ] Whether queries use `queryType=semantic` or `semanticQuery`, and whether `captions`/`answers` are requested
- [ ] Network posture: public endpoint, private endpoint, IP firewall rules, shared private links

### B9.2 Failure evidence

- [ ] **Exact UTC timestamps** of at least 3–5 failure instances (start and end of each window)
- [ ] **`x-ms-request-id`** response header for failing requests (Azure AI Search correlation ID)
- [ ] **`request-id`** header where present
- [ ] **`elapsed-time`** response header (search service processing ms) vs. client round-trip ms — see [Measure individual queries](https://learn.microsoft.com/en-us/azure/search/search-performance-analysis)
- [ ] **Raw 206 response body**, unredacted, including `@search.semanticPartialResponseReason` and `@search.semanticPartialResponseType`
- [ ] **Full request body** of a reproducing query (search text, queryType, semanticConfiguration, filter, top, select)
- [ ] A **minimal reproducible query** CSS can run
- [ ] Copilot Studio **conversation ID** / session ID for the corresponding turns
- [ ] Copilot Studio **error codes** surfaced to users (613, HTTP403Forbidden, etc.)
- [ ] Evidence that the index **does** contain matching data for the failing query (a successful non-semantic query against the same index/terms)

### B9.3 Telemetry exports

Enable **diagnostic settings** on the search service first if not already: portal > search service > **Diagnostic settings** > send to Log Analytics. ([Monitor your search service](https://learn.microsoft.com/en-us/azure/search/monitor-azure-cognitive-search))

- [ ] **Log Analytics export** of `AzureDiagnostics` for the failure windows
- [ ] **Azure Monitor metrics**: Search Latency, Throttled search queries percentage, Search queries per second
- [ ] **Application Insights** export covering Copilot Studio → connector → APIM → Search for the same UTC windows
- [ ] **APIM gateway logs** for the failure windows (status codes, backend latency, subscription key / identity used, `X-Forwarded-For`)
- [ ] **Function App / Data Factory** indexing job timings — confirm whether indexing overlapped the query failures (indexing and queries share the same resources; see [Impact of indexing on queries](https://learn.microsoft.com/en-us/azure/search/search-performance-analysis))

Ready-to-run KQL (from [Analyze performance](https://learn.microsoft.com/en-us/azure/search/search-performance-analysis)):

```kusto
// HTTP response breakdown over 7 days — shows throttling ratio
AzureDiagnostics
| where TimeGenerated > ago(7d)
| summarize count() by resultSignature_d
| render barchart
```

```kusto
// Throttled queries per minute in a specific window
let intervalsize = 1m;
AzureDiagnostics
| where TimeGenerated > ago(7d)
| where resultSignature_d != 403 and resultSignature_d != 404
  and OperationName in ("Query.Search","Query.Suggest","Query.Lookup","Query.Autocomplete")
| summarize ThrottledQueriesPerMinute =
    bin(countif(resultSignature_d == 503)/(intervalsize/1m), 0.01)
  by bin(TimeGenerated, intervalsize)
| render timechart
```

```kusto
// QPM, average duration, average doc count returned
AzureDiagnostics
| where OperationName == "Query.Search" and TimeGenerated > ago(1d)
| extend MinuteOfDay = substring(TimeGenerated, 0, 16)
| project MinuteOfDay, DurationMs, Documents_d, IndexName_s
| summarize QPM=count(), AvgDurationMs=avg(DurationMs), AvgDocCountReturned=avg(Documents_d)
  by MinuteOfDay
| order by MinuteOfDay desc
| render timechart
```

```kusto
// Indexing operations per minute — correlate with query latency spikes
let intervalsize = 1m;
AzureDiagnostics
| where TimeGenerated > ago(1d)
| summarize IndexingOpsPerMinute =
    bin(countif(OperationName == "Indexing.Index")/(intervalsize/1m), 0.01)
  by bin(TimeGenerated, intervalsize)
| render timechart
```

**Add a per-index breakdown** (not in the Microsoft samples but essential here, since the whole question is fan-out):

```kusto
AzureDiagnostics
| where OperationName == "Query.Search" and TimeGenerated > ago(1d)
| summarize Queries=count(), AvgMs=avg(DurationMs), Errors=countif(resultSignature_d >= 400)
  by IndexName_s, bin(TimeGenerated, 1m)
| render timechart
```

**Caveat carried over from prior operational experience:** if Application Insights is workspace-based (`IngestionMode: LogAnalytics`), `az monitor app-insights query --app <name> -g <rg>` returns **empty** even when data exists. Query the Log Analytics workspace directly instead, using the `AppRequests` / `AppTraces` / `AppDependencies` / `AppExceptions` tables. Note this in the evidence-gathering runbook so the team doesn't wrongly conclude "no telemetry."

### B9.4 Copilot Studio facts

- [ ] **Environment ID** and environment URL
- [ ] **Agent name / schema name / agent ID**
- [ ] Orchestration mode: **generative** or **classic**
- [ ] **Number of knowledge sources** (7) and how each is wired (native knowledge source vs. tool vs. custom connector vs. Azure OpenAI classic data) ← **see unverified item U1**
- [ ] **Allow ungrounded responses** setting (on/off) — see A6.6
- [ ] **Tenant graph grounding with semantic search** setting (on/off)
- [ ] Content **moderation level** (default is High)
- [ ] Model the agent is configured to use
- [ ] Agent **snapshot or solution export**
- [ ] Custom connector definition + APIM policy (sanitized)
- [ ] Prepaid message pack count or PAYG status (determines the generative-AI RPM/RPH quota tier)
- [ ] Channels in use (Teams / web / custom)
- [ ] Observed peak: messages/min, messages/hr, **concurrent sessions**, generative AI calls per turn

For a **throughput increase** request specifically, Microsoft's required fields ([plan-agent-throughput-rate-limits](https://learn.microsoft.com/en-us/microsoft-copilot-studio/guidance/plan-agent-throughput-rate-limits)):

| Field | Content |
| --- | --- |
| Environment ID | Dataverse environment where the agent runs |
| Agent name/identifier | Affected agent |
| Business impact | Critical impact if default limits insufficient |
| Known information | Scenario, channel, launch context, business criticality; B2C / autonomous / employee-facing / internal |
| Agent snapshot | Export helping reviewers understand config |
| Agent design | Topics, generative AI usage, knowledge sources, actions, flows, connectors, Dataverse calls, external APIs |
| Pilot summary | Dates, duration, audience size, audience as share of full intended audience |
| Observed average traffic | Measured, by minute/hour/day |
| Observed peak traffic | Measured peaks during peak windows |
| Extrapolated peak requirement | At full audience, with method and assumptions |
| Evidence | Pilot telemetry, session IDs, errors, correlation IDs, logs, throttling events |
| Mitigations | What you already tried (design review, optimized external calls, environment segmentation, batching, queueing) |

### B9.5 Pre-flight checks that may pre-empt the ticket

- [ ] Check [Azure Service Health](https://portal.azure.com/#view/Microsoft_Azure_Health/AzureHealthBrowseBlade) for Azure AI Search incidents in the region during the failure windows
- [ ] Check [Azure status history](https://azure.status.microsoft/status/history/)
- [ ] Check Power Platform **Service health**: <https://admin.powerplatform.microsoft.com/support/serviceHealth>
- [ ] Check Power Platform **Known issues** page
- [ ] Confirm **Allow ungrounded responses** and the citation behavior in A6.6 are not the cause of the empty answers
- [ ] Confirm the 403s: is the `x-ms-request-id` present on the 403 response? If absent, the 403 likely originated at **APIM**, not at Search → different ticket

---

## B10. Is the 206 / Semantic Partial Result Documented as Ticket-Worthy?

**YES. Twice, explicitly.**

### B10.1 Direct instruction to file a ticket

[Add semantic ranking — Expected workloads](https://learn.microsoft.com/en-us/azure/search/semantic-how-to-query-request):

> "For semantic ranking, you should expect a search service to support up to 10 concurrent queries per replica.
>
> The service throttles semantic ranking requests if volumes are too high. An error message that includes these phrases indicate the service is at capacity for semantic ranking:
>
> ```json
> Error in search query: Operation returned an invalid status 'Partial Content'
> @search.semanticPartialResponseReason
> CapacityOverloaded
> ```
>
> If you anticipate consistent throughput requirements near, at, or higher than this level, **please file a support ticket so that we can provision for your workload.**"

### B10.2 Limit-increase path

[Service limits — Semantic ranker throttling limits](https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity#throttling-limits):

> "The following table describes the semantic ranker throttling limits by tier, subject to available capacity in the region. **You can contact Microsoft support to request a limit increase.**"

### B10.3 Known service-side issue?

**No known, currently-published service-side issue found.** I did not locate an entry in Azure status history, Azure Updates, or a Learn troubleshooting page describing a service-wide semantic ranker degradation matching this symptom.

Documented behaviors that could *look* like a service issue but are by design:

| Behavior | Doc |
| --- | --- |
| Only the **top 50** initial results are semantically reranked | [semantic-search-overview](https://learn.microsoft.com/en-us/azure/search/semantic-search-overview) |
| `@search.rerankerScore` distribution varies "due to conditions at the infrastructure level"; ranking-model updates can shift it — "don't make the limits too granular" | [semantic-search-overview — How results are scored](https://learn.microsoft.com/en-us/azure/search/semantic-search-overview) |
| `search=*` or empty search string → **no semantic ranking applied** and no charge | [semantic-how-to-query-request](https://learn.microsoft.com/en-us/azure/search/semantic-how-to-query-request) |
| `orderBy` on specific fields + semantic ranking → **HTTP 400** | [semantic-how-to-query-request — Avoid features that bypass relevance scoring](https://learn.microsoft.com/en-us/azure/search/semantic-how-to-query-request) |
| Answers only returned when verbatim answer-like content exists AND the query looks like a question | [semantic-answers](https://learn.microsoft.com/en-us/azure/search/semantic-answers) |
| Semantic ranker is a **premium, regionally-available** feature — check region support | [search-region-support](https://learn.microsoft.com/en-us/azure/search/search-region-support) |
| Short latency bursts from background **shard merge** operations | [search-performance-analysis — Background service processing](https://learn.microsoft.com/en-us/azure/search/search-performance-analysis) |
| Adding replicas/partitions "can introduce slight variations in how results are ordered" | [search-capacity-planning](https://learn.microsoft.com/en-us/azure/search/search-capacity-planning) |

**Worth asking CSS explicitly:** "Is regional semantic ranker capacity a contributing factor in our region?" The limits doc says the tier limits are "**subject to available capacity in the region**" and lists "the total available semantic ranker capacity **in the region**" as one of the four factors determining semantic QPS. That is a factor entirely outside the customer's control and only Microsoft can answer it.

### B10.4 On the connector 613 / 403

`613` is **not** in the current Copilot Studio error-code reference ([Understand error codes](https://learn.microsoft.com/en-us/troubleshoot/power-platform/copilot-studio/authoring/error-codes)). The modern web-app error list is **string-based** (`HTTP403Forbidden`, `HTTP429TooManyRequests`, …); the numeric codes (2000–3003) belong to the **Classic/Teams** tab and top out at 3003. **Flagged as unverified — see U3.**

What the docs do say about `HTTP403Forbidden`:

> "**Resolution:** This error can be caused by missing permissions in the target system. To resolve the problem:
>
> 1. Verify that the user or app has the required roles and permissions.
> 2. Check app registration permissions and admin consent requirements.
> 3. Verify resource-level sharing and delegation settings.
> 4. Confirm that tenant and environment scoping are correct."

Given the architecture (Copilot Studio → custom connector → APIM → Azure AI Search), candidate 403 sources, in order of likelihood:

1. **APIM** rejecting the request (subscription key missing/expired/wrong product, IP restriction, policy rejection)
2. **Azure AI Search RBAC** — if key auth is disabled, the calling identity needs `Search Index Data Reader`
3. **Search service network rules** — public network access disabled, or caller IP not in the firewall allowlist
4. **Expired/rotated API key** in the connector's connection
5. **Conditional Access / tenant policy** on the service principal

**Discriminator:** an Azure AI Search 403 carries `x-ms-request-id`. An APIM-originated 403 typically does not. Capture full response headers on a failing 403 — that alone determines which ticket it belongs in.

Also relevant from the error-code doc: `DataLossPreventionViolation` fires when "One or more connectors that you use in the agent aren't in the same data group" or "The tenant administrator blocked one or more connectors." Worth checking DLP policy if the 403s are connector-scoped rather than request-scoped.

---

## B11. Copy-Paste Ticket Drafts

> Replace every `<ANGLE_BRACKET>` placeholder. Remove any confidential content before submission — Microsoft's guidance: *"Be sure not to include any personal or confidential information here."*

---

### B11.1 TICKET 1 — Azure AI Search (Azure portal)

**Portal:** <https://portal.azure.com> > search service > **Help** > **Support + Troubleshooting** > **Create a support request**
**Issue type:** Technical
**Service:** Azure AI Search
**Subscription:** `<SUBSCRIPTION_ID>`
**Severity:** B — Moderate business impact
**Advanced diagnostic information:** Yes

**Title:**

```text
Intermittent HTTP 206 semantic partial responses (CapacityOverloaded) from 7-index fan-out; request semantic ranker concurrency limit review and sizing guidance
```

**Problem description:**

```text
SUMMARY
Our Azure AI Search service returns intermittent HTTP 206 "Partial Content" responses with
@search.semanticPartialResponseReason = CapacityOverloaded. When this occurs, semantic captions
and answers are absent and our downstream Microsoft Copilot Studio agent produces empty or
ungrounded responses even though the indexes contain matching content.

Per https://learn.microsoft.com/en-us/azure/search/semantic-how-to-query-request ("Expected
workloads"), this signature indicates the service is at capacity for semantic ranking, and that
doc instructs customers to file a support ticket to have the workload provisioned. That is the
purpose of this request.

ENVIRONMENT
- Search service name: <SEARCH_SERVICE_NAME>
- Resource ID: /subscriptions/<SUB_ID>/resourceGroups/<RG>/providers/Microsoft.Search/searchServices/<NAME>
- Subscription ID: <SUB_ID>
- Tenant ID: <TENANT_ID>
- Region: <REGION>
- Service creation date: <CREATION_DATE>
- Tier AT TIME OF FAILURE: Basic, <R> replicas x <P> partitions = <SU> search units
- Tier NOW: S1, <R> replicas x <P> partitions = <SU> search units (changed on <DATE_UTC>)
- Number of indexes: 7 (one per business unit)
- Semantic ranker billing plan: <free | standard>
- Network: <public endpoint | private endpoint | IP firewall>

QUERY PATTERN (this is the crux)
A single end-user turn in our Copilot Studio agent fans out to ALL 7 indexes. Each index is
queried with semantic ranking enabled and returns top 3 documents; results are merged for
generative answer synthesis. Therefore ONE user turn issues approximately 7 concurrent semantic
ranker requests against this single search service.

Cross-referencing
https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity#throttling-limits
(Semantic ranker throttling limits):
  - Basic: 2 concurrent semantic requests per search unit, queue size 4  -> 6 in flight at 1 SU
  - S1:    3 concurrent semantic requests per search unit, queue size 6  -> 9 in flight at 1 SU

A single 7-index turn therefore exceeds the total in-flight capacity of a 1-SU Basic service on
its own, with zero concurrent users. This is consistent with every symptom we observed, including
the fact that the failures were intermittent and appeared to affect different indexes at random
(the 7 parallel requests race for the same shared semantic queue).

WHAT WE OBSERVED
- Intermittent HTTP 206 with CapacityOverloaded across all 7 indexes, nondeterministically
- Empty downstream answers despite the indexes containing matching content
- Load was low in absolute terms: approximately 7-15 users per hour
- Scaling up replicas measurably reduced the failures
- Moving Basic -> S1 largely resolved it

MITIGATION ALREADY APPLIED
- Increased replica count from <OLD_R> to <NEW_R>
- Upgraded tier Basic -> S1 on <DATE_UTC>
- Errors are substantially reduced but we do not consider the issue closed

FAILURE EVIDENCE (all times UTC)
1. <YYYY-MM-DDTHH:MM:SSZ> - x-ms-request-id: <GUID> - index: <INDEX> - raw 206 body attached
2. <YYYY-MM-DDTHH:MM:SSZ> - x-ms-request-id: <GUID> - index: <INDEX> - raw 206 body attached
3. <YYYY-MM-DDTHH:MM:SSZ> - x-ms-request-id: <GUID> - index: <INDEX> - raw 206 body attached

REPRODUCIBLE QUERY
POST https://<SERVICE>.search.windows.net/indexes/<INDEX>/docs/search?api-version=<API_VERSION>
{
  "search": "<QUERY_TEXT>",
  "queryType": "semantic",
  "semanticConfiguration": "<SEMANTIC_CONFIG_NAME>",
  "captions": "extractive|highlight-true",
  "answers": "extractive|count-3",
  "top": 3,
  "select": "<FIELDS>"
}
Issuing this against all 7 indexes concurrently reproduces the 206 at <OLD_TIER/SU>.

WHAT WE ARE ASKING FOR
1. Confirm the authoritative semantic ranker concurrency and queue limits for our exact tier,
   region, and search-unit configuration. The docs currently publish two different figures and we
   need to know which governs our service:
     - semantic-how-to-query-request ("Expected workloads") states "up to 10 concurrent queries
       per REPLICA"
     - search-limits-quotas-capacity ("Semantic ranker throttling limits") states 2 (Basic) /
       3 (S1) / 4 (S2+) concurrent requests per SEARCH UNIT
   These differ in both magnitude and unit. Please confirm which applies to us.

2. Confirm whether regional semantic ranker capacity in <REGION> was a contributing factor during
   the failure windows listed above. The limits doc states the tier limits are "subject to
   available capacity in the region."

3. Advise whether a semantic ranker concurrency limit increase is available for this service, and
   what evidence you need to approve it.

4. Provide replica/search-unit sizing guidance for our target load of <N> concurrent user turns,
   each issuing 7 concurrent semantic requests. We understand from
   https://learn.microsoft.com/en-us/azure/search/search-capacity-planning that there are no
   published replica guidelines and that scaling is not linear; we are asking for a review of our
   specific fan-out pattern.

5. Confirm whether consolidating the 7 indexes into a single index with a filterable businessUnit
   field (reducing to 1 semantic request per turn) is the architecturally recommended remediation.
   The agentic retrieval guidance at
   https://learn.microsoft.com/en-us/azure/search/agentic-retrieval-overview advises to "reduce
   the number of knowledge sources (indexes); consolidating content can lower fan-out and token
   volume," and we would like that confirmed for the classic (non-agentic) pipeline as well.

ATTACHED (single .zip)
- Raw 206 response bodies (unredacted)
- Log Analytics AzureDiagnostics export for all failure windows
- Azure Monitor metrics: Search Latency, Throttled search queries percentage, SearchQueriesPerSecond
- Semantic configuration JSON for all 7 indexes
- Index schema (field names, types, attributes) for a representative index
- Application Insights export correlating Copilot Studio turn -> connector -> APIM -> Search
- Indexing job schedule (Azure Data Factory / Function App) for the same windows, to rule out
  indexing/query resource contention

RELATED CASE
Copilot Studio / connector-side case in Power Platform admin center: <PP_CASE_NUMBER>
```

---

### B11.2 TICKET 2 — Copilot Studio / Connector (Power Platform admin center)

**Portal:** <https://admin.powerplatform.microsoft.com> > **Support** > **Support requests** > **Get support**
**Product:** Microsoft Copilot Studio
**Request type:** Technical (break-fix)
**Severity:** B — Moderate business impact
**Advanced diagnostic consent:** Yes

**Title:**

```text
Copilot Studio agent: recurring connector 403 (error 613) and empty grounded answers; confirm knowledge-source fan-out behavior with 7 Azure AI Search sources
```

**Problem description:**

```text
SUMMARY
A production Copilot Studio agent that grounds on 7 Azure AI Search indexes is producing two
recurring failures:
  (a) Connector errors surfaced to users as error code 613 / HTTP 403 Forbidden
  (b) Empty or ungrounded answers even when the underlying indexes contain matching content

We have a parallel Azure support case for the Azure AI Search side (see RELATED CASE). This case
covers the Copilot Studio and connector layer.

ENVIRONMENT
- Environment ID: <ENVIRONMENT_ID>
- Environment URL: <ENVIRONMENT_URL>
- Agent name: <AGENT_NAME>
- Agent schema name / ID: <AGENT_SCHEMA_NAME>
- Orchestration mode: <generative | classic>
- Model configured: <MODEL>
- Channels: <Teams | web | custom>
- Allow ungrounded responses: <on | off>
- Content moderation level: <Lowest | Low | Medium | High | Highest>
- Tenant graph grounding with semantic search: <on | off>
- Licensing: <N prepaid message packs | pay-as-you-go | M365 Copilot>
- Knowledge/tool wiring: 7 Azure AI Search indexes surfaced via <custom connector | tool |
  Azure OpenAI classic data | other> behind Azure API Management

ISSUE A - CONNECTOR 403 / ERROR 613
Users intermittently receive error 613 with an underlying HTTP 403 Forbidden from the connector
that reaches Azure AI Search through Azure API Management.

Note: error code 613 does not appear in the current Copilot Studio error-code reference at
https://learn.microsoft.com/en-us/troubleshoot/power-platform/copilot-studio/authoring/error-codes
(the modern web-app list is string-based, e.g. HTTP403Forbidden, and the numeric Classic/Teams
list ends at 3003). Please confirm what 613 maps to in the current runtime and where it is
emitted.

Occurrences (UTC):
1. <YYYY-MM-DDTHH:MM:SSZ> - conversation ID: <CONVERSATION_ID>
2. <YYYY-MM-DDTHH:MM:SSZ> - conversation ID: <CONVERSATION_ID>
3. <YYYY-MM-DDTHH:MM:SSZ> - conversation ID: <CONVERSATION_ID>

Already checked / ruled out:
- Connector connection is valid and the credential has not been rotated: <yes/no, detail>
- Service principal / app registration has admin consent: <yes/no>
- Azure AI Search RBAC role assignment (Search Index Data Reader) present: <yes/no>
- Search service network rules allow the caller: <yes/no>
- DLP policy: all connectors used by the agent are in the same data group and none are blocked:
  <yes/no>
- APIM subscription key / product assignment valid: <yes/no>
- x-ms-request-id header present on the 403 response: <yes/no>
  (If absent, this suggests the 403 originates at APIM rather than at the search service - please
  confirm how to definitively attribute it from the Copilot Studio side, since the connector is a
  black box to us.)

ISSUE B - EMPTY GROUNDED ANSWERS
The agent returns no grounded answer despite matching content existing in the indexes. Two
candidate causes we would like help separating:
  1. Azure AI Search returns HTTP 206 with @search.semanticPartialResponseReason =
     CapacityOverloaded, so semantic captions/answers are missing from the grounding data.
     (Tracked in the Azure case - see RELATED CASE.)
  2. The behavior documented at
     https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-copilot-studio
     ("Why the agent sometimes doesn't return a grounded answer"), where a correct answer is
     withheld because the model did not emit an in-text citation.

Our "Allow ungrounded responses" setting is <on | off>. Please advise how to determine, from
Copilot Studio telemetry, which of these two paths caused a given empty response.

ISSUE C - KNOWLEDGE-SOURCE FAN-OUT (confirmation request)
Every user turn queries all 7 knowledge sources regardless of relevance to the question. Our
reading of
https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-copilot-studio is that this
is expected, because generative orchestration "filters knowledge sources by using an internal GPT
model when there are more than 25 different knowledge sources" - and we have 7, i.e. below that
threshold.

Please confirm:
  1. That with fewer than 26 knowledge sources, no description-based knowledge-source routing
     occurs and all configured sources participate in the knowledge search.
  2. Whether knowledge sources are queried in parallel or sequentially, and whether there is any
     per-source result cap we can configure.
  3. Whether converting these 7 sources into TOOLS (which
     https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-generative-actions states
     the orchestrator selects based on name and description) is the supported way to obtain
     description-driven routing without exceeding 25 knowledge sources.
  4. Whether child agents or connected agents are the recommended alternative for our 7-business-
     unit topology, given the latency caveat in
     https://learn.microsoft.com/en-us/microsoft-copilot-studio/authoring-add-other-agents.

OBSERVED LOAD
- Approximately <N> users per hour; peak approximately <N> concurrent sessions
- Messages per minute (peak): <N>
- Generative AI calls per turn: <N>
- We are within the published quotas at
  https://learn.microsoft.com/en-us/microsoft-copilot-studio/requirements-quotas, but expect
  growth and want to validate headroom before it becomes an incident.

BUSINESS IMPACT
<Describe: user-facing agent, N business units, users receive errors or no answer, trust impact.>

ATTACHED
- Agent solution export / snapshot
- Custom connector definition (sanitized)
- APIM policy XML (sanitized)
- Application Insights export for the listed UTC windows
- Screenshots of the 613 error as users see it
- Full response headers for a failing 403

RELATED CASE
Azure support case for the Azure AI Search 206 / semantic ranker capacity issue:
<AZURE_CASE_NUMBER>
```

---

# Unverified / Could Not Confirm

| # | Item | Status | Impact | How to close |
| --- | --- | --- | --- | --- |
| **U1** | **How the 7 Azure AI Search indexes are actually wired into Copilot Studio.** Azure AI Search does **not** appear in the supported knowledge-sources table at [knowledge-copilot-studio](https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-copilot-studio) (which lists only Public website, Documents, SharePoint, Dataverse, Enterprise data via connectors). `knowledge-add-azure-ai-search` and `knowledge-add-advanced` returned no content. Possible mechanisms: custom connector as a **tool**; Azure OpenAI "on your data" via **Classic data** in a generative answers node; Foundry IQ; or a Microsoft Graph connector. | **UNVERIFIED — highest-impact gap** | Changes the answer to A5 materially. If they are already **tools**, description-based routing *should* apply and the fan-out is a description-quality problem, not a platform limit. If they are Azure OpenAI classic-data sources, the classic-orchestration cap of **5 Azure OpenAI connections** applies and 7 may be over limit. | Ask the customer to screenshot the agent's **Knowledge** page and **Tools** page, and confirm whether the agent is in generative or classic orchestration. |
| **U2** | **Whether Copilot Studio queries knowledge sources in parallel or sequentially, and the per-source top-K.** Docs state which sources are searched, not the concurrency or result cap. "Top 3 per index" is the customer's observation. | UNVERIFIED | Affects the precision of the concurrency arithmetic in A6.2 — though the arithmetic holds directionally either way (7 requests within one turn will overlap enough to contend for the semantic queue). | Ask in Ticket 2 (Issue C, question 2). Also observable in the Copilot Studio **activity map** during testing and in App Insights dependency timings. |
| **U3** | **What error code 613 maps to.** Not present in the current [Understand error codes](https://learn.microsoft.com/en-us/troubleshoot/power-platform/copilot-studio/authoring/error-codes) reference. Modern web-app codes are string-based; numeric Classic/Teams codes end at 3003. | UNVERIFIED | Cannot pre-diagnose the 403 root cause from docs alone. | Asked directly in Ticket 2. Meanwhile capture full response headers to attribute APIM vs Search. |
| **U4** | **Authoritative semantic ranker concurrency number.** Two published values conflict: "10 concurrent per replica" vs "2/3/4 concurrent per search unit." | **CONFLICT IN OFFICIAL DOCS** | Directly affects sizing math. The newer, tier-specific limits page is the more likely truth but this must be confirmed. | Asked as question 1 in Ticket 1. |
| **U5** | **When the 25-knowledge-source filtering threshold was introduced, and whether sub-25 description routing is on the roadmap.** Could not retrieve a Copilot Studio "What's new" or release-plan page. | UNVERIFIED | Affects whether to architect around the limitation permanently or wait. | Check <https://learn.microsoft.com/en-us/microsoft-copilot-studio/whats-new> and the Dynamics 365 / Power Platform release plans; ask in Ticket 2. |
| **U6** | **Whether a known service-side semantic ranker issue existed in the customer's region during the failure windows.** No matching entry found in status history or Azure Updates. | UNVERIFIED (likely none, but regional capacity is not publicly visible) | Could shift the answer from "customer design issue" to "Microsoft capacity issue." | Asked as question 2 in Ticket 1. Only Microsoft can answer. |
| **U7** | **Whether the customer's Azure support plan and Power Platform support plan are both active.** Two separate entitlements; an Azure Unified contract does not automatically confer Power Platform support. | UNVERIFIED | A blocked filing path wastes days. | Verify **before** drafting: Azure = **Help + Support** > **Support Plans**; Power Platform = **Support plans** button in PPAC. |
| **U8** | **Copilot Studio Application Insights configuration guidance.** `analytics-application-insights` returned no content; could not verify the exact setup steps or the schema of Copilot Studio telemetry. | UNVERIFIED | Affects the quality of the App Insights evidence bundle. | Search Learn for the current Copilot Studio Application Insights article; the throughput-planning doc confirms App Insights is expected for pilot telemetry. |
| **U9** | **Exact per-turn semantic request count.** Assumed 1 semantic request per index per turn. If the retrieval layer issues sub-queries, or if hybrid + semantic counts as more than one, the multiplier is higher. | ASSUMPTION | Makes the A6.2 arithmetic conservative (i.e. reality may be worse, not better). | Count `Query.Search` operations per Copilot Studio conversation ID in the per-index KQL query in B9.3. |

---

# Clarifying Questions for the User / Customer

1. **(Blocking for A5 precision)** How are the 7 Azure AI Search indexes registered in Copilot Studio — as native knowledge sources, as custom-connector **tools**, as Azure OpenAI "Classic data" in a generative answers node, or via Foundry IQ? A screenshot of the agent's **Knowledge** and **Tools** pages settles it.
2. Is the agent using **generative** or **classic** orchestration?
3. Is **Allow ungrounded responses** on or off? (If off, some of the "empty answers" may be the citation-suppression behavior in A6.6, not search capacity.)
4. What were the **exact replica and partition counts** on Basic at the time of failure, and what are they now on S1? This turns the A6.2 table from illustrative into a defensible capacity model for the ticket.
5. What is the **search service creation date**? Pre-2024-04-03 Basic services are capped at 1 partition / 3 replicas (3 SU); later ones allow 3 × 3 (9 SU). It changes the failure math.
6. Does the customer hold an **active Azure support plan** AND an **active Power Platform support plan** (Subscription / ProDirect / Unified)? They are separate entitlements.
7. Who holds **Power Platform Admin** or **Environment Admin** in the tenant? End users cannot open Power Platform cases and there is no workaround.
8. Are the **403s** carrying an `x-ms-request-id` header? This is the single fastest discriminator between an APIM-originated and a Search-originated 403, and determines whether a third (API Management) ticket is needed.
9. What is the target scale — **concurrent user turns at peak**, not users per hour? The whole capacity model keys off concurrency.
10. Is re-indexing into a **single consolidated index** feasible given the existing Azure Data Factory → Function App → custom-embedding ingestion pipeline, and are the per-BU access boundaries **security** boundaries (requiring trimming) or merely **relevance** boundaries (requiring only a filter)?
11. For the pro-code team: are their agents in the **same Dataverse environment** as this one? The generative-AI RPM/RPH quotas are environment-scoped and shared.

---

# Recommended Next Research (not completed in this session)

- [ ] Retrieve the Copilot Studio **"What's new"** / release-plan pages to date the 25-source filtering threshold and check for planned sub-25 knowledge routing.
- [ ] Locate the current **Copilot Studio Application Insights** article and document the telemetry schema for correlating a conversation turn to downstream connector/search calls.
- [ ] Determine definitively how **Azure AI Search** is surfaced as a Copilot Studio knowledge source in the current product (resolves U1 from the product side rather than the customer side).
- [ ] Confirm the current **Azure AI Search request/response headers** reference (`x-ms-request-id`, `request-id`, `elapsed-time`, `client-request-id`) from the REST API reference, to give the customer an exact header-capture list.
- [ ] Research **Azure API Management** diagnostic logging and correlation-ID propagation so APIM-originated 403s can be attributed without guesswork.
- [ ] Evaluate **Foundry IQ / agentic retrieval** in depth as the pro-code team's target architecture, including the `retrievalReasoningEffort` trade-off (`minimal` = no routing, uses all sources; `low`/`medium` = LLM planning but more subqueries).
- [ ] Check **Azure AI Search document-level access control (ACL)** support as a modern alternative to hand-rolled `search.in()` security trimming for the consolidated-index design.
- [ ] Confirm whether **Copilot Studio agents can pass a dynamic `$filter`** to an Azure AI Search tool at runtime (required for the Rank 1 consolidated-index design to route by business unit).

---

# Appendix — Full Source URL Index

## Copilot Studio

- Knowledge sources summary — <https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-copilot-studio>
- Orchestrate agent behavior with generative AI — <https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-generative-actions>
- Quotas and limits — <https://learn.microsoft.com/en-us/microsoft-copilot-studio/requirements-quotas>
- Plan agent deployments for throughput and rate limits — <https://learn.microsoft.com/en-us/microsoft-copilot-studio/guidance/plan-agent-throughput-rate-limits>
- Best practices for improving conversational agent performance — <https://learn.microsoft.com/en-us/microsoft-copilot-studio/guidance/conversational-agents-performance-improvement>
- Add other agents overview — <https://learn.microsoft.com/en-us/microsoft-copilot-studio/authoring-add-other-agents>
- Understand error codes — <https://learn.microsoft.com/en-us/troubleshoot/power-platform/copilot-studio/authoring/error-codes>
- Find community help and support — <https://learn.microsoft.com/en-us/microsoft-copilot-studio/fundamentals-support>
- Connect your data to Azure OpenAI for generative answers (preview) — <https://learn.microsoft.com/en-us/microsoft-copilot-studio/nlu-generative-answers-azure-openai>
- Boost conversations with generative answers — <https://learn.microsoft.com/en-us/microsoft-copilot-studio/nlu-boost-conversations>
- Resolve usage limit errors in agents — <https://learn.microsoft.com/en-us/troubleshoot/power-platform/copilot-studio/licensing/throttling-errors-agents>
- Multi-agent orchestration patterns and best practices — <https://learn.microsoft.com/en-us/microsoft-copilot-studio/guidance/multi-agent-patterns>

## Azure AI Search

- Service limits for tiers and SKUs — <https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity>
- Semantic ranker throttling limits (anchor) — <https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity#throttling-limits>
- Agentic retrieval limits (anchor) — <https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity#agentic-retrieval-limits>
- Estimate capacity for query and index workloads — <https://learn.microsoft.com/en-us/azure/search/search-capacity-planning>
- Analyze performance — <https://learn.microsoft.com/en-us/azure/search/search-performance-analysis>
- Add semantic ranking (incl. "Expected workloads") — <https://learn.microsoft.com/en-us/azure/search/semantic-how-to-query-request>
- Semantic ranking overview — <https://learn.microsoft.com/en-us/azure/search/semantic-search-overview>
- Semantic answers — <https://learn.microsoft.com/en-us/azure/search/semantic-answers>
- Enable or disable semantic ranker billing — <https://learn.microsoft.com/en-us/azure/search/semantic-how-to-enable-disable>
- Security filter pattern (security trimming) — <https://learn.microsoft.com/en-us/azure/search/search-security-trimming-for-azure-search>
- Document-level access control overview — <https://learn.microsoft.com/en-us/azure/search/search-document-level-access-overview>
- Agentic retrieval overview — <https://learn.microsoft.com/en-us/azure/search/agentic-retrieval-overview>
- Monitor your search service — <https://learn.microsoft.com/en-us/azure/search/monitor-azure-cognitive-search>
- Indexer errors and warnings — <https://learn.microsoft.com/en-us/azure/search/cognitive-search-common-errors-warnings>
- Choose a pricing model and service tier — <https://learn.microsoft.com/en-us/azure/search/search-sku-tier>
- Region support — <https://learn.microsoft.com/en-us/azure/search/search-region-support>
- Upgrade your search service — <https://learn.microsoft.com/en-us/azure/search/search-how-to-upgrade>
- Reliability in Azure AI Search — <https://learn.microsoft.com/en-us/azure/search/search-reliability>
- SLA for Azure AI Search — <https://azure.microsoft.com/support/legal/sla/search/v1_0/>
- Azure AI Search pricing — <https://azure.microsoft.com/pricing/details/search/>

## Support / CSS

- How to create an Azure support request — <https://learn.microsoft.com/en-us/azure/azure-portal/supportability/how-to-create-azure-support-request>
- Azure support scope and responsiveness (severity SLAs) — <https://azure.microsoft.com/en-us/support/plans/response/>
- Compare Azure support plans — <https://azure.microsoft.com/support/plans>
- Azure support diagnostic information collection — <https://azure.microsoft.com/support/legal/support-diagnostic-information-collection/>
- Azure support ticket REST API — <https://learn.microsoft.com/en-us/rest/api/support>
- Azure CLI `az support` — <https://learn.microsoft.com/en-us/cli/azure/support>
- Get support in the Power Platform admin center — <https://learn.microsoft.com/en-us/power-platform/admin/get-help-support>
- Support for Power Platform and Dynamics 365 apps (severity, advisory vs technical, RCA policy) — <https://learn.microsoft.com/en-us/power-platform/admin/support-overview>
- Power Platform support environment / advanced diagnostics — <https://learn.microsoft.com/en-us/power-platform/admin/support-environment>
- Power Platform admin center — <https://admin.powerplatform.microsoft.com>
- Power Platform support requests — <https://admin.powerplatform.microsoft.com/support/requests>
- Power Platform service health — <https://admin.powerplatform.microsoft.com/support/serviceHealth>
- Unified Support plan details — <https://www.microsoft.com/microsoft-unified/plan-details>
- Azure status history — <https://azure.status.microsoft/status/history/>
- Create Azure support request (direct link) — <https://portal.azure.com/#create/Microsoft.Support>

## Related platform limits (for the pro-code team)

- Power Platform requests limits and allocations — <https://learn.microsoft.com/en-us/power-platform/admin/api-request-limits-allocations>
- Dataverse service protection API limits — <https://learn.microsoft.com/en-us/power-apps/developer/data-platform/api-limits>
- Power Automate — understand limits and avoid throttling — <https://learn.microsoft.com/en-us/power-automate/guidance/coding-guidelines/understand-limits>

