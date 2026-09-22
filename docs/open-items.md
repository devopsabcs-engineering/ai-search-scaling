---
title: Open items and unverified claims
description: The eleven facts this package could not verify from documentation or telemetry, why each one matters to the conclusions drawn, and the specific script, query, or support ask in this package that resolves it.
author: Microsoft
ms.date: 2026-09-22
ms.topic: troubleshooting
keywords:
  - azure ai search
  - copilot studio
  - api management
  - root cause analysis
  - open items
estimated_reading_time: 13
---

Every analysis in this package rests on a mixture of Microsoft documentation, telemetry sampled from this environment, and inference that bridges the two. This document isolates the bridges.

Eleven facts could not be confirmed from either Microsoft's published documentation or the evidence available at the time of writing. Each one is listed below with what remains unknown, what the uncertainty costs the conclusion it supports, and the named artifact in this package that closes it. An open item without a resolution path is a defect in the package, so every entry ends with a runnable script, a `.kql` file, or a specific question to put to Microsoft support.

None of these items invalidates the recommendations. They bound them.

## How to read this document

Claims that come from Microsoft carry an inline Microsoft Learn link and are quoted where the exact wording matters. Conclusions drawn from the evidence rather than from documentation begin with **Inferred:** and should not be presented to Microsoft support as Microsoft's own position.

## What is documented and what is inferred

The distinction matters most for the 206 analysis, because the strength of that case varies sharply between its parts.

| Claim | Status |
|---|---|
| Semantic ranking is admission-controlled with a fixed concurrency limit and queue depth per search unit | Documented ([Service limits and quotas](https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity)) |
| Basic admits 6 semantic requests in flight per search unit, S1 admits 9 | Documented (same table) |
| Copilot Studio filters knowledge sources with an internal model only above 25 sources | Documented ([Knowledge in Copilot Studio](https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-copilot-studio)) |
| The agent issues seven concurrent semantic queries per user turn | Observed ([assets/meetingNotes.md](../assets/meetingNotes.md), 18:11 and 34:37) |
| HTTP 403 from Azure AI Search is an authorization failure, not a capacity one | Documented ([HTTP status codes](https://learn.microsoft.com/en-us/rest/api/searchservice/http-status-codes)) |
| The specific `Transient` partial responses seen here were caused by that concurrency ceiling | **Inferred** (U1) |
| The 403s stopping near the Basic to S1 scale is coincidence rather than causation | **Inferred** (U1 context, tested by the hypotheses in [rca-403-connector-triage.md](./rca-403-connector-triage.md)) |

The two inferred rows are the load-bearing ones. U1, U3, U4, and U5 below all attach to the first of them.

## The eleven items at a glance

| ID | Gap | Impact | Resolved by |
|---|---|---|---|
| [U1](#u1-nothing-links-transient-to-tier-or-capacity) | No Microsoft source links `Transient` (as opposed to `CapacityOverloaded`) to tier or capacity | Correlation is real but inferred | [kql/21-apim-206-semantic-partial-capture.kql](../kql/21-apim-206-semantic-partial-capture.kql), ask 1 in [support/azure-ai-search-ticket.md](../support/azure-ai-search-ticket.md) |
| [U2](#u2-who-sets-semanticerrorhandling-to-partial) | Who sets `semanticErrorHandling: "partial"`, given the default is `fail` and the connector does not expose it | Blocks precise mechanism | [scripts/Get-ApimPolicyAudit.ps1](../scripts/Get-ApimPolicyAudit.ps1), [kql/21-apim-206-semantic-partial-capture.kql](../kql/21-apim-206-semantic-partial-capture.kql) |
| [U3](#u3-the-effective-semantic-wait-timeout-when-omitted) | Effective `semanticMaxWaitInMilliseconds` when the caller omits it | Minor | Ask 3 in [support/azure-ai-search-ticket.md](../support/azure-ai-search-ticket.md) |
| [U4](#u4-two-incompatible-concurrency-numbers-in-the-documentation) | Documentation contradiction: "10 concurrent per replica" against "2 or 3 per search unit" | Sizing math uncertainty | Ask 2 in [support/azure-ai-search-ticket.md](../support/azure-ai-search-ticket.md), bounded empirically by [kql/12-semantic-capacity-headroom.kql](../kql/12-semantic-capacity-headroom.kql) |
| [U5](#u5-the-semantic-ranker-plan-is-unknown) | Semantic ranker plan is `free` or `standard`, unknown | Could be an entirely separate root cause | [scripts/Get-SearchServiceDiagnostics.ps1](../scripts/Get-SearchServiceDiagnostics.ps1), field `properties.semanticSearch` |
| [U6](#u6-whether-search-writes-206-into-resultsignature_d) | Whether Azure AI Search emits `206` into `resultSignature_d` | Determines whether Search-side 206 alerting is viable | [kql/01-discover-search-diagnostic-shape.kql](../kql/01-discover-search-diagnostic-shape.kql) |
| [U7](#u7-azure-ai-search-is-absent-from-the-supported-knowledge-sources-table) | Azure AI Search does not appear in Copilot Studio's supported knowledge-sources table | Cannot confirm the wiring model | Question 1 in [customer-questions.md](./customer-questions.md) |
| [U8](#u8-the-observed-span-shape-matches-no-documented-schema) | The customer span shape matches neither documented Copilot Studio telemetry schema | Discovery queries required before dashboards | [kql/00-discover-dependency-types.kql](../kql/00-discover-dependency-types.kql) |
| [U9](#u9-the-api-management-tier-is-unknown) | API Management tier unknown, and Consumption supports no resource logs | Could invalidate the gateway-log diagnostic plan | [scripts/Get-ApimPolicyAudit.ps1](../scripts/Get-ApimPolicyAudit.ps1), SKU check |
| [U10](#u10-whether-search-returns-a-request-id-header-on-403) | Whether Azure AI Search returns `request-id` on 403 responses | Correlation may lose its key on exactly the failing requests | [kql/20-apim-403-triage.kql](../kql/20-apim-403-triage.kql), ask 4 in [support/azure-ai-search-ticket.md](../support/azure-ai-search-ticket.md) |
| [U11](#u11-power-platform-support-entitlement-is-unconfirmed) | Support-plan entitlements, because an Azure Unified contract does not automatically cover Power Platform | Could block ticket filing outright | Question 14 in [customer-questions.md](./customer-questions.md), routing in [support/README.md](../support/README.md) |

## U1. Nothing links `Transient` to tier or capacity

Unverified: the failing responses carry `@search.semanticPartialResponseReason: "Transient"`. Microsoft documents a second value, `CapacityOverloaded`, and describes that one as the throttling signal. No published Microsoft source states that `Transient` is produced by exhausting the semantic ranker's concurrency limit or its request queue.

Why it matters: this is the single weakest link in the 206 analysis.
The concurrency ceiling itself is documented, the fan-out to seven indexes is observed, and the improvement after adding replicas matches the arithmetic.
Attributing these particular `Transient` responses to that ceiling is still an inference. If `Transient` turns out to signal a transient backend fault unrelated to admission control, the capacity narrative in [rca-206-semantic-concurrency.md](./rca-206-semantic-concurrency.md) becomes a coincidence and the remediation priority shifts.

How this package resolves it: run [kql/21-apim-206-semantic-partial-capture.kql](../kql/21-apim-206-semantic-partial-capture.kql), which reads the captured response bodies out of `ApiManagementGatewayLogs` and reports the distribution of reason values across every 206.
A population that is exclusively `Transient` keeps the item open. Any appearance of `CapacityOverloaded` converts the capacity story from inferred to proven on the spot.
Where the reason population stays ambiguous, ask 1 in [support/azure-ai-search-ticket.md](../support/azure-ai-search-ticket.md) puts the question to the product group directly: under what conditions does the service emit `Transient` rather than `CapacityOverloaded`.

## U2. Who sets `semanticErrorHandling` to `partial`

Unverified: a 206 is only possible when the request sets `semanticErrorHandling: "partial"`. The documented default is `fail`, which would have produced a 5xx instead. The Copilot Studio Azure AI Search connector does not expose this parameter in its published operation surface, so some component in the path is setting it without the agent author choosing to.

Why it matters: the answer decides whether anyone on the customer side can change the behavior.
If API Management injects it, a policy edit can flip the failure mode from silent degradation to a loud error that the agent can retry. If the connector hard-codes it, the only lever is the Copilot Studio side.
Without knowing which, the mitigation list in [immediate-mitigations.md](./immediate-mitigations.md) cannot recommend a definitive fix for the empty-answer symptom, only the capacity work that reduces how often it triggers.

How this package resolves it: [scripts/Get-ApimPolicyAudit.ps1](../scripts/Get-ApimPolicyAudit.ps1) dumps the policy XML at all four scopes, which exposes any `set-body` or rewrite that injects the parameter.
If the policies are clean, the injection happens upstream in the connector, and [kql/21-apim-206-semantic-partial-capture.kql](../kql/21-apim-206-semantic-partial-capture.kql) confirms it by showing the parameter present on the inbound request body that API Management received.
That evidence belongs in the Copilot Studio case, because the connector is a Power Platform component.

## U3. The effective semantic wait timeout when omitted

Unverified: `semanticMaxWaitInMilliseconds` bounds how long the semantic ranker waits before it gives up and returns partial results. Microsoft documents a minimum accepted value of 700 milliseconds. It does not document what the service uses when the caller omits the parameter, and the connector omits it.

Why it matters: low. The timeout influences how quickly a queued request converts into a 206 rather than whether it queues at all. Knowing the value would sharpen the latency budget in [fan-out-reduction-architecture.md](./fan-out-reduction-architecture.md) but changes no recommendation.

How this package resolves it: ask 3 in [support/azure-ai-search-ticket.md](../support/azure-ai-search-ticket.md). Treat it as a supplementary question on a case opened for U1, never as the reason to open one.

## U4. Two incompatible concurrency numbers in the documentation

Unverified: Microsoft's throttling-limits table gives a maximum of 2 concurrent semantic requests per search unit on Basic and 3 on S1. Elsewhere Microsoft has described a limit of 10 concurrent semantic requests per replica. Those two statements cannot both describe the same quantity, and no published note reconciles them.

Why it matters: every capacity table in this package uses the per-search-unit numbers, because they appear in the current service-limits reference and they match the observed behavior. If the per-replica figure is the operative one, a Basic service at one replica would have admitted 10 requests and seven concurrent queries would never have saturated it. The sizing guidance would then be wrong in the conservative direction, recommending more capacity than the workload needs.

How this package resolves it: ask 2 in [support/azure-ai-search-ticket.md](../support/azure-ai-search-ticket.md) requests an authoritative reconciliation. Pending that answer, [kql/12-semantic-capacity-headroom.kql](../kql/12-semantic-capacity-headroom.kql) bounds the question empirically by plotting observed concurrent semantic requests against both candidate ceilings, which shows which one the service is actually enforcing.

## U5. The semantic ranker plan is unknown

Unverified: `properties.semanticSearch` on the search service is either `free` or `standard`. Nobody on the engagement has read the value.

Why it matters: the free plan caps semantic ranking at 1,000 requests per month. At seven semantic requests per user turn, a modest conversation volume exhausts that allowance within days. An exhausted free plan is a completely separate root cause from concurrency, it produces its own failure mode, and it has a self-service fix that needs no support case at all. Leaving this unread risks building an entire capacity argument on top of a billing setting.

How this package resolves it: run [scripts/Get-SearchServiceDiagnostics.ps1](../scripts/Get-SearchServiceDiagnostics.ps1) and read `properties.semanticSearch` from the console report or the JSON evidence file. The check is read-only, takes under a minute, and is listed first in the free-diagnostics gate in [support/README.md](../support/README.md) for exactly this reason.

## U6. Whether Search writes 206 into `resultSignature_d`

Unverified: Azure AI Search resource logs land in the shared `AzureDiagnostics` table with an HTTP status column exposed as `resultSignature_d`. No Microsoft example shows a 206 value in that column, and a partial response is a successful response from the service's own point of view.

Why it matters: roughly half the Search-side 206 tooling depends on it. If the service records partial responses as 200, then no query or alert reading `resultSignature_d` can ever detect a 206, and detection has to move to the API Management gateway logs where the backend response code is preserved.

How this package resolves it: [kql/01-discover-search-diagnostic-shape.kql](../kql/01-discover-search-diagnostic-shape.kql) enumerates the distinct values present in `resultSignature_d` over the lookback window and settles the question against real data. The package already hedges the outcome: rule AR-01 in [alerts/alert-rules.md](../alerts/alert-rules.md) is built on `ApiManagementGatewayLogs` with `BackendResponseCode == 206` rather than on the Search log, so 206 alerting works either way.

## U7. Azure AI Search is absent from the supported knowledge-sources table

Unverified: Copilot Studio publishes a table of supported knowledge-source types. Azure AI Search is not in it. The agent nevertheless queries seven Azure AI Search indexes on every turn, which means the indexes are attached through some mechanism, and this package cannot confirm which one from documentation alone.

Why it matters: this is the uncertainty behind the single highest-value question in the engagement.
Knowledge sources below the threshold of 25 receive no description-based filtering, so all seven are always queried. Tools and connected agents are selected by name and description, so the same seven indexes become individually addressable.
If the indexes are already wired as tools, the fan-out is a description-quality problem rather than an architectural one, and the headline recommendation in [fan-out-reduction-architecture.md](./fan-out-reduction-architecture.md) changes.

How this package resolves it: question 1 in [customer-questions.md](./customer-questions.md) asks for screenshots of the agent's Knowledge page and its Tools page. Two screenshots settle it definitively, and no telemetry or script can substitute for them.

## U8. The observed span shape matches no documented schema

Unverified: the sampled 403 record from this environment carries `type: "Connector"`, `name: "Azure AI Search"`, and custom dimensions prefixed `attributes.` ([assets/usefulScreenshots.md](../assets/usefulScreenshots.md)). Microsoft's documented Copilot Studio environment-level telemetry schema publishes `type: "GenAI"`, `name: "ExecuteTool"`, and dimensions prefixed `gen_ai.`. The observed shape matches neither the documented environment-level schema nor the documented agent-level one.

Why it matters: every 403 attribution query and every Copilot Studio dashboard panel in this package names columns. Built against the wrong naming convention, they return zero rows, and a dashboard showing zero errors is indistinguishable from a healthy one. This is the failure mode most likely to waste an afternoon.

How this package resolves it: [kql/00-discover-dependency-types.kql](../kql/00-discover-dependency-types.kql) enumerates the live `(type, name, target)` triples and the custom dimension keys actually present in the workspace. It is position 1 in the run order in [kql/README.md](../kql/README.md) and it is not optional. Its output tells you whether files 22 and 23 need edits before they will run.

## U9. The API Management tier is unknown

Unverified: nobody has read the SKU on the API Management instance in the request path.

Why it matters: the Consumption tier supports no resource logs at all. Three of the nine queries in the library and two of the six alert rules read `ApiManagementGatewayLogs`. On Consumption, that table is permanently empty, the gateway-log half of the diagnostic plan cannot be executed, and the 403 attribution has to fall back to correlating Copilot Studio spans against Search operation logs by timestamp. Discovering this after enabling diagnostics wastes the enablement work.

How this package resolves it: [scripts/Get-ApimPolicyAudit.ps1](../scripts/Get-ApimPolicyAudit.ps1) reports the SKU and tier as its first audit area, specifically so the constraint surfaces before any other API Management work begins. [scripts/Enable-DiagnosticSettings.ps1](../scripts/Enable-DiagnosticSettings.ps1) also detects the condition and reports it rather than attempting a configuration that cannot succeed.

## U10. Whether Search returns a `request-id` header on 403

Unverified: Azure AI Search returns a `request-id` correlation header on successful responses. Whether it also returns one on a 403 rejection is not documented, and an authorization failure may be rejected before the request ever reaches the stage that assigns the identifier.

Why it matters: the correlation strategy for the 403 investigation joins the Copilot Studio connector span to the Search-side operation log on that identifier. If the header is absent on exactly the requests that failed, the join loses its key precisely where it is needed, and correlation falls back to timestamp proximity, which is far weaker when seven requests fire within milliseconds of each other.

How this package resolves it: [kql/20-apim-403-triage.kql](../kql/20-apim-403-triage.kql) is written to degrade gracefully. It first attributes each 403 by whether API Management or the backend produced it, which requires no Search-side join at all, and only then attempts correlation. Where the identifier proves unavailable, ask 4 in [support/azure-ai-search-ticket.md](../support/azure-ai-search-ticket.md) requests the correlation mechanism Microsoft expects customers to use for rejected requests.

## U11. Power Platform support entitlement is unconfirmed

Unverified: whether the tenant holds a support plan that covers Power Platform. An Azure Unified Support contract does not automatically extend to Power Platform products, and Copilot Studio is a Power Platform product.

Why it matters: this is the only prerequisite in the escalation path that nobody on the engagement can verify from outside the tenant, and it fails late.
The 403 case belongs in the Power Platform admin center, as set out in [support/README.md](../support/README.md). If no qualifying plan is attached, the case cannot be submitted at all, and that is discovered at the moment of filing, after the evidence package has been assembled.
Two further constraints compound it: Power Platform support does not perform root cause analysis for single-tenant issues, and performance cases are capped at four hours of engineer time unless the customer holds Unified or Professional Direct for advisory continuation.

How this package resolves it: question 14 in [customer-questions.md](./customer-questions.md) asks the customer to confirm the entitlement before any evidence is assembled for the Copilot Studio case. The check takes minutes in the Power Platform admin center. Where no qualifying plan exists, the sequencing in [support/README.md](../support/README.md) still holds, because the free diagnostics and the Azure-side case are unaffected.

## Related reading

* [rca-206-semantic-concurrency.md](./rca-206-semantic-concurrency.md) for the analysis that U1 through U6 bound.
* [rca-403-connector-triage.md](./rca-403-connector-triage.md) for the analysis that U9 and U10 bound.
* [copilot-studio-fanout.md](./copilot-studio-fanout.md) and [fan-out-reduction-architecture.md](./fan-out-reduction-architecture.md) for the recommendation that U7 could change.
* [customer-questions.md](./customer-questions.md) for the questions that close U5, U7, and U11.
* [support/README.md](../support/README.md) for the free diagnostics that close U5, U8, and U9 without a support case.
