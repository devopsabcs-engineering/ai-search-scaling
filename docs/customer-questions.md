---
title: Questions for the customer
description: Fourteen questions whose answers change the analysis, the remediation, or the ability to file a support case, each with why it is being asked and what the answer changes.
author: Microsoft
ms.date: 2026-09-22
ms.topic: troubleshooting
keywords:
  - azure ai search
  - copilot studio
  - api management
  - root cause analysis
  - discovery questions
estimated_reading_time: 12
---

Fourteen questions remain open. Every one of them changes something: the headline recommendation, the ranking of a hypothesis, the content of a support case, or whether a support case can be filed at all. None is asked for completeness.

Most cost minutes to answer. Four of them can be answered without leaving the Azure portal and without a support engineer. Work through those first, because two of the four can retire a whole line of investigation.

## How to read this document

Claims that come from Microsoft carry an inline Microsoft Learn link and are quoted where the exact wording matters. Conclusions drawn from the evidence rather than from documentation begin with **Inferred:** and should not be presented to Microsoft support as Microsoft's own position.

## Answer these four first

| Question | Why it is first | Cost to answer |
|---|---|---|
| [1. How are the seven indexes wired](#1-how-are-the-seven-indexes-wired-knowledge-sources-or-tools) | The only question in this list that can change the headline recommendation | Two screenshots |
| [2. Is the semantic ranker on the free plan](#2-is-propertiessemanticsearch-set-to-free-or-standard) | A `free` value is a separate root cause with a self-service fix and no ticket | One script run |
| [3. Are the 206s exclusively `Transient`](#3-are-the-206-reasons-exclusively-transient-or-does-capacityoverloaded-also-appear) | Converts the capacity story from inferred to proven, or breaks it | One query |
| [8. Are the 403s in production or the test canvas](#8-do-the-403s-occur-on-the-published-agent-or-only-in-the-test-canvas) | If authoring only, no published user was ever affected and the severity changes | One query |

Questions 2, 3, and 8 are the highest-value quick wins in the engagement. Question 1 is the one that could change the answer itself.

## 1. How are the seven indexes wired, Knowledge sources or Tools?

Send a screenshot of the agent's Knowledge page and a screenshot of its Tools page.

Why this is being asked: Copilot Studio treats the two attachment models differently, and the difference is the whole fan-out problem.
Knowledge sources are filtered by an internal model only when an agent has more than 25 of them ([Knowledge in Copilot Studio](https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-copilot-studio)).
Below that threshold, every source is queried on every turn, which is exactly the behavior observed here ([assets/meetingNotes.md](../assets/meetingNotes.md), 18:11 and 53:05).
Tools and connected agents are selected by name and description on every turn regardless of count.
Compounding the ambiguity, Azure AI Search does not appear in Copilot Studio's published table of supported knowledge-source types at all, tracked as [U7](./open-items.md#u7-azure-ai-search-is-absent-from-the-supported-knowledge-sources-table).

What the answer changes: everything downstream.
If the indexes are knowledge sources, the recommendation stands as written in [fan-out-reduction-architecture.md](./fan-out-reduction-architecture.md): consolidate seven indexes into one with a filterable `businessUnit` field, or re-express them as tools so the orchestrator can select among them.
If they are already tools and the orchestrator is still querying all seven, the fan-out is a description-quality problem, the fix is rewriting seven tool descriptions rather than rebuilding an index, and the architectural work in that document becomes unnecessary.

This is the single highest-impact open question in the engagement.

## 2. Is `properties.semanticSearch` set to `free` or `standard`?

Read the value from the search service. [scripts/Get-SearchServiceDiagnostics.ps1](../scripts/Get-SearchServiceDiagnostics.ps1) reports it, or read it directly in the portal.

Why this is being asked: the free semantic ranker plan caps semantic ranking at 1,000 requests per month. The agent issues seven semantic requests per user turn. At the reported load of roughly 7 to 15 users per hour ([assets/meetingNotes.md](../assets/meetingNotes.md), 17:28), the monthly allowance is consumed in one to three days of normal use.

What the answer changes: a `free` value introduces a second, independent root cause that has nothing to do with concurrency, produces its own distinct failure mode, and is fixed by switching the plan without opening any support case.
It would also explain a pattern of failures that returns on a monthly cycle rather than a load-driven one.
A `standard` value removes the hypothesis and leaves the concurrency analysis in [rca-206-semantic-concurrency.md](./rca-206-semantic-concurrency.md) as the leading explanation. Tracked as [U5](./open-items.md#u5-the-semantic-ranker-plan-is-unknown).

## 3. Are the 206 reasons exclusively `Transient`, or does `CapacityOverloaded` also appear?

Run [kql/21-apim-206-semantic-partial-capture.kql](../kql/21-apim-206-semantic-partial-capture.kql), which reads `@search.semanticPartialResponseReason` out of captured response bodies and reports the distribution.

Why this is being asked: the samples collected so far all carry `Transient`. Microsoft documents a second value, `CapacityOverloaded`, and describes that one as the throttling signal. No Microsoft source connects `Transient` to concurrency limits or to tier, which is the weakest link in the entire 206 analysis, tracked as [U1](./open-items.md#u1-nothing-links-transient-to-tier-or-capacity).

What the answer changes: a single `CapacityOverloaded` observation converts the capacity narrative from inference to documented fact and strengthens the Azure support case considerably. An exclusively `Transient` population keeps the capacity story as the leading hypothesis while leaving room for a transient backend fault unrelated to admission control, and makes ask 1 in [support/azure-ai-search-ticket.md](../support/azure-ai-search-ticket.md) the priority question for the product group.

## 4. What were the replica and partition counts at failure time and now, and when was the service created?

Give the exact replica by partition topology on Basic during the failures, the topology on S1 today, and the service creation date. [scripts/Get-SearchServiceDiagnostics.ps1](../scripts/Get-SearchServiceDiagnostics.ps1) collects the current values and the creation date.

Why this is being asked: semantic ranker capacity is published per search unit, and a search unit is replicas multiplied by partitions. Every capacity number in this package is a function of that product. The creation date matters independently: services created before 3 April 2024 cap Basic at one partition, giving a maximum of 3 search units, while later services allow 3 by 3 for 9 search units.

What the answer changes: the arithmetic in [rca-206-semantic-concurrency.md](./rca-206-semantic-concurrency.md) becomes specific to this service rather than illustrative. It also determines whether the Basic-tier headroom that was available at failure time was 6, 12, or 18 semantic requests in flight, which decides whether the observed failures are fully explained by the topology or whether something else was also constraining the service.

## 5. Which connector authentication type is configured: admin key, Entra ID integrated, or service principal?

Why this is being asked: Azure AI Search returns HTTP 403 for authorization failures ([HTTP status codes](https://learn.microsoft.com/en-us/rest/api/searchservice/http-status-codes)), and each authentication model fails in a different way. A regenerated admin key produces a total, immediate failure. A role assignment scoped to six of seven indexes produces a clean per-index split. A service principal with an expiring secret produces a failure with a sharp onset and no recovery.

What the answer changes: it reranks the hypothesis list in [rca-403-connector-triage.md](./rca-403-connector-triage.md) and selects which discriminating test to run first. The observed pattern of intermittent, index-agnostic 403s fits none of the key-based models cleanly, which is why the IP allow-list hypothesis currently ranks above them.

## 6. Is Search `publicNetworkAccess` set to Enabled or to Selected IP addresses, and if the latter, what is in `networkRuleSet.ipRules` and when was it last refreshed?

[scripts/Get-SearchServiceDiagnostics.ps1](../scripts/Get-SearchServiceDiagnostics.ps1) reports both fields. [scripts/Compare-ConnectorEgressPrefixes.ps1](../scripts/Compare-ConnectorEgressPrefixes.ps1) compares the allow list against current Power Platform connector egress prefixes.

Why this is being asked: this is the leading 403 hypothesis. Power Platform connector traffic egresses from every `AzureConnectors.<Region>` service tag in the geography, those prefixes change over time, and Microsoft advises refreshing an allow list against them at least every 90 days. Power Platform is not on the Azure AI Search trusted-services list, so no bypass exists.

What the answer changes: a stale allow list produces exactly the reported pattern of intermittent failures that hit no particular index, because which prefix a given request egresses from varies per call. If prefixes are missing, the fix is customer-side, costs one configuration change, and no support case is needed. If the allow list is complete or public access is fully enabled, the hypothesis is eliminated and the investigation moves to API Management.

## 7. What is the full API Management policy XML at all four scopes, and which tier is the instance on?

Run [scripts/Get-ApimPolicyAudit.ps1](../scripts/Get-ApimPolicyAudit.ps1), which collects both. Look specifically for `<quota>`, `<quota-by-key>`, `<ip-filter>`, `<validate-jwt failed-validation-httpcode="403">`, and any `<on-error>` block that rewrites a status code.

Why this is being asked: `quota` and `quota-by-key` are the only API Management throttling policies that return 403 rather than 429, which makes them the only gateway-side mechanism that fits the observed status code.
Any of the other four constructs can also produce a 403 that looks identical to a backend rejection from the connector's point of view.
The tier is a separate and urgent concern: the Consumption tier supports no resource logs, so on Consumption the entire gateway-log half of this package's diagnostic plan cannot run, tracked as [U9](./open-items.md#u9-the-api-management-tier-is-unknown).

What the answer changes: finding a matching policy is the answer rather than a question for support, and the fix is a policy edit. Finding none eliminates the gateway and points the investigation back at Azure AI Search. Finding Consumption redirects the observability plan in [kql/README.md](../kql/README.md) and disables two of the six rules in [alerts/alert-rules.md](../alerts/alert-rules.md).

## 8. Do the 403s occur on the published agent, or only in the test canvas?

Run [kql/23-design-mode-vs-published.kql](../kql/23-design-mode-vs-published.kql).

Why this is being asked: the single 403 record sampled from this environment carries `DesignMode: "True"` and `channelId: "pva-studio"` ([assets/usefulScreenshots.md](../assets/usefulScreenshots.md)). Both values indicate the Copilot Studio authoring test canvas rather than a published channel. One record is not a population, and 613 failures were reported.

What the answer changes: if that pattern holds across all 613, no published user was ever affected. The severity drops, the urgency drops, and the case becomes an authoring-experience issue rather than a production incident. If published-channel traffic is also failing, the severity holds and the Copilot Studio case in [support/copilot-studio-ticket.md](../support/copilot-studio-ticket.md) proceeds as written. This is the cheapest question in the list that can change a support case's severity.

## 9. What else changed in the same window as the Basic to S1 scale?

List every change in that window: firewall or IP rule edits, key regeneration, role assignment changes, API Management policy deployments, connector reconfiguration.

Why this is being asked: the 403s stopped in roughly the same window as the tier change, which invites the conclusion that the tier change fixed them. Azure AI Search documents no mechanism by which service tier produces a 403. Quota pressure returns 429 and semantic free-plan exhaustion returns 402. **Inferred:** a second change made in the same window is a far more plausible cause than the tier change itself.

What the answer changes: identifying that second change most likely identifies the 403 root cause outright, and would retire most of the hypothesis list in [rca-403-connector-triage.md](./rca-403-connector-triage.md) at no cost. Finding nothing else changed makes the coincidence harder to explain and raises the value of the Copilot Studio case.

## 10. What `sessionId` does the agent pass to Azure AI Search?

Why this is being asked: Azure AI Search uses `sessionId` for sticky session routing, which pins a caller's requests to a consistent replica set to keep scoring stable. A constant or absent value applied across all traffic defeats the distribution that adding replicas is supposed to buy.

What the answer changes: it would explain why moving to S1 improved matters substantially without eliminating the problem. If every request carries the same `sessionId`, the added replicas are not absorbing load evenly, and removing or varying the value is a configuration fix that costs nothing. Action 4 in [immediate-mitigations.md](./immediate-mitigations.md) covers the change.

## 11. Is "Allow ungrounded responses" switched off?

Why this is being asked: when that setting is off, Copilot Studio suppresses an answer it cannot ground in a retrieved source. A 206 partial response returns fewer documents than the full result set, which can leave the orchestrator without enough grounding to answer, producing an empty response that looks like a retrieval failure.

What the answer changes: it separates two symptoms currently treated as one. Some share of the empty answers reported may be documented suppression behavior downstream of a successful, if partial, retrieval rather than a retrieval failure. That distinction matters for how the empty-answer symptom is described in [support/copilot-studio-ticket.md](../support/copilot-studio-ticket.md), and it affects how much of the user-visible problem capacity work will actually fix. Covered in [copilot-studio-fanout.md](./copilot-studio-fanout.md).

## 12. Is the Search diagnostic setting enabled with both `OperationLogs` and `AllMetrics`, and is `DisableLocalAuth` set on the shared Application Insights component?

[scripts/Enable-DiagnosticSettings.ps1](../scripts/Enable-DiagnosticSettings.ps1) reports and, with consent, remediates both. Run it with `-WhatIf` first.

Why this is being asked: these are the prerequisites for nearly every query in [kql/README.md](../kql/README.md).
`OperationLogs` carries the per-request records. `AllMetrics` carries `ThrottledSearchQueriesPercentage`, which two of the six alert rules depend on and which has no resource-log equivalent.
The Application Insights question is a separate trap: a component with `DisableLocalAuth` set rejects connection-string ingestion, and the Copilot Studio telemetry export then fails silently, producing an empty workspace that looks like an absence of errors.

What the answer changes: without both, the diagnostic plan cannot execute, and a workbook built on the missing data will show green while the problem continues. This is a prerequisite rather than a hypothesis, which is why it appears in the run order ahead of the analytical queries.

## 13. What is the peak number of concurrent user turns, not users per hour?

Why this is being asked: the load figure available today is roughly 7 to 15 users per hour ([assets/meetingNotes.md](../assets/meetingNotes.md), 17:28), which is a throughput measure and not a concurrency measure. Semantic ranker admission control is governed by requests in flight. Because each turn fans out to seven indexes, the quantity that matters is peak concurrent turns multiplied by seven.

What the answer changes: it converts the capacity sizing in [rca-206-semantic-concurrency.md](./rca-206-semantic-concurrency.md) from an illustration into a specific recommendation, and it sets the threshold for rules AR-03 and AR-04 in [alerts/alert-rules.md](../alerts/alert-rules.md).
Two concurrent turns present 14 simultaneous semantic requests, which exceeds an S1 service at one search unit.
The distinction between throughput and concurrency is the reason a load that looked far too small to matter was in fact sufficient to saturate the service.

## 14. Does the tenant hold a support plan that covers Power Platform?

Confirm in the Power Platform admin center before assembling any evidence for the Copilot Studio case.

Why this is being asked: an Azure Unified Support contract does not automatically extend to Power Platform products, and Copilot Studio is a Power Platform product. This is the only prerequisite in the escalation path that nobody on the engagement can verify from outside the tenant, tracked as [U11](./open-items.md#u11-power-platform-support-entitlement-is-unconfirmed).

What the answer changes: without a qualifying plan, the Copilot Studio case cannot be submitted at all, and that is discovered at the moment of filing rather than before.
Two further constraints follow even when entitlement exists: Power Platform support does not perform root cause analysis for single-tenant issues, so the ask has to be framed as identify and remediate rather than provide an RCA, and performance cases are capped at four hours of engineer time unless the customer holds Unified or Professional Direct for advisory continuation.
The routing and framing guidance is in [support/README.md](../support/README.md). The Azure-side case in [support/azure-ai-search-ticket.md](../support/azure-ai-search-ticket.md) is unaffected by the answer, as are all the free diagnostics.

## Where the answers land

| Answer | Updates |
|---|---|
| 1, 11 | [copilot-studio-fanout.md](./copilot-studio-fanout.md), [fan-out-reduction-architecture.md](./fan-out-reduction-architecture.md) |
| 2, 3, 4, 13 | [rca-206-semantic-concurrency.md](./rca-206-semantic-concurrency.md), [immediate-mitigations.md](./immediate-mitigations.md) |
| 5, 6, 7, 8, 9 | [rca-403-connector-triage.md](./rca-403-connector-triage.md) |
| 7, 12 | [kql/README.md](../kql/README.md), [alerts/alert-rules.md](../alerts/alert-rules.md), [workbooks/README.md](../workbooks/README.md) |
| 10 | [immediate-mitigations.md](./immediate-mitigations.md), action 4 |
| 14 | [support/README.md](../support/README.md), [support/copilot-studio-ticket.md](../support/copilot-studio-ticket.md) |

Open items that these questions do not close are tracked in [open-items.md](./open-items.md), each with the script, query, or support ask that resolves it.
