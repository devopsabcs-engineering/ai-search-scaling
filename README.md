---
title: Azure AI Search scaling engagement
description: Root cause analysis, diagnostics, telemetry, and support escalation material for the Azure AI Search 206 partial semantic responses and the Copilot Studio connector 403 errors.
author: Microsoft
ms.date: 2026-09-22
ms.topic: overview
keywords:
  - azure ai search
  - copilot studio
  - api management
  - semantic ranker
  - root cause analysis
estimated_reading_time: 10
---

A Copilot Studio agent queries seven Azure AI Search indexes through an API Management gateway. Two failure modes were reported: HTTP 206 partial semantic responses that surface to users as empty answers, and 613 HTTP 403 rejections on the Azure AI Search connector.

This repository holds the analysis of both, the runnable diagnostics that confirm or eliminate each hypothesis, the telemetry to detect recurrence, and the material needed to escalate to Microsoft support with evidence already attached.

## Two independent problems

They share a timeline and an architecture, and nothing else. Treating them as one incident sends the investigation, and any support case, in the wrong direction.

| Aspect | 206 partial semantic responses | 613 connector 403 errors |
|---|---|---|
| Owner | Azure AI Search | Copilot Studio, or API Management if the gateway logs say so |
| Mechanism | Semantic ranker admission control saturated by concurrent requests | Authorization or network denial |
| Status | Leading hypothesis, strongly supported, not confirmed | Ranked hypothesis list, no single cause established |
| Primary document | [docs/rca-206-semantic-concurrency.md](docs/rca-206-semantic-concurrency.md) | [docs/rca-403-connector-triage.md](docs/rca-403-connector-triage.md) |
| Escalation path | [support/azure-ai-search-ticket.md](support/azure-ai-search-ticket.md) | [support/copilot-studio-ticket.md](support/copilot-studio-ticket.md), [support/apim-ticket.md](support/apim-ticket.md) |

Azure AI Search documents HTTP 403 as an authorization failure. Quota pressure returns 429 and semantic free-plan exhaustion returns 402 ([HTTP status codes](https://learn.microsoft.com/en-us/rest/api/searchservice/http-status-codes)). No documented mechanism ties service tier to a 403, so the Basic to S1 scale cannot explain the 403s even though they stopped in the same window.

## The headline answer, in brief

The agent issues seven concurrent semantic queries on every user turn, one per index, because Copilot Studio filters knowledge sources with an internal model only above a threshold of 25 ([Knowledge in Copilot Studio](https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-copilot-studio)).
A Basic search service at one search unit admits six semantic requests in flight before it rejects them ([Service limits and quotas](https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity)).
Seven requests against six slots degrades on a single turn, with nobody else on the system.

This is an arity problem, not a load problem. The failure is driven by how many indexes one turn touches, not by how many people are talking to the agent, which is why a measured load of roughly 7 to 15 users per hour never looked like a plausible cause.

Buying capacity raises the ceiling those seven requests hit. It does not reduce the number of requests. Tier and replica scaling is a stopgap; reducing the fan-out is the fix, and [docs/fan-out-reduction-architecture.md](docs/fan-out-reduction-architecture.md) sets out how.

> [!IMPORTANT]
> The concurrency ceiling is documented. Attributing the specific `Transient` partial responses observed in this environment to that ceiling is the leading hypothesis and the strongest explanation the evidence supports. It is not a confirmed cause. [docs/open-items.md](docs/open-items.md) lists exactly what would confirm it.

## Start here

Everything in this section is free, needs no support case, and in most cases needs no configuration change. Two of these checks can retire an entire line of investigation, and three of them resolve to a customer-side fix rather than a Microsoft defect. Work through them before filing anything.

1. Read the semantic ranker plan. Run [scripts/Get-SearchServiceDiagnostics.ps1](scripts/Get-SearchServiceDiagnostics.ps1) and check `properties.semanticSearch`. A `free` value caps semantic ranking at 1,000 requests per month, which at seven requests per turn is exhausted in days. That is a separate root cause with a self-service fix.
2. Answer question 1. Send screenshots of the agent's Knowledge page and Tools page ([docs/customer-questions.md](docs/customer-questions.md)). This is the only question in the engagement that can change the headline recommendation.
3. Audit the API Management policies. Run [scripts/Get-ApimPolicyAudit.ps1](scripts/Get-ApimPolicyAudit.ps1). `quota` and `quota-by-key` are the only API Management throttling policies that return 403. Finding one is the answer, not a question for support. The same run reports the SKU, and the Consumption tier supports no resource logs at all.
4. Compare the Search allow list against connector egress. Run [scripts/Compare-ConnectorEgressPrefixes.ps1](scripts/Compare-ConnectorEgressPrefixes.ps1). Missing prefixes produce exactly the intermittent, index-agnostic 403 pattern reported, and refreshing the list is a customer-side fix.
5. Enable the telemetry the rest of the package depends on. Run [scripts/Enable-DiagnosticSettings.ps1](scripts/Enable-DiagnosticSettings.ps1) with `-WhatIf` first. It is the only script here that writes to Azure.
6. Confirm the telemetry schema. Run [kql/00-discover-dependency-types.kql](kql/00-discover-dependency-types.kql) and [kql/01-discover-search-diagnostic-shape.kql](kql/01-discover-search-diagnostic-shape.kql). The span shape observed in this environment matches neither documented Copilot Studio schema, so column names have to be confirmed before any other query can be trusted.
7. Establish whether the 403s reached production. Run [kql/23-design-mode-vs-published.kql](kql/23-design-mode-vs-published.kql). The sampled failure carries `DesignMode: "True"`. If that holds across all 613, no published user was ever affected and the severity changes.
8. Attribute the 403s to a layer. Run [kql/20-apim-403-triage.kql](kql/20-apim-403-triage.kql) to establish whether API Management or the backend produced each rejection.
9. File the Azure AI Search case with the evidence already collected. Follow [support/README.md](support/README.md) for routing, then [support/azure-ai-search-ticket.md](support/azure-ai-search-ticket.md).

Steps 1 through 4 need no telemetry at all. Steps 6 through 8 need step 5 to have completed first.

## Recommended reading order

Coming to this cold, read in this order.

1. This page, for the two-problem framing and the shape of the package.
2. [docs/rca-206-semantic-concurrency.md](docs/rca-206-semantic-concurrency.md), for why the 206s happen and why Basic to S1 helped.
3. [docs/copilot-studio-fanout.md](docs/copilot-studio-fanout.md), for why all seven indexes are queried on every turn.
4. [docs/rca-403-connector-triage.md](docs/rca-403-connector-triage.md), for the 403 hypothesis list and the test that discriminates each one.
5. [docs/immediate-mitigations.md](docs/immediate-mitigations.md), for what to do this week.
6. [docs/fan-out-reduction-architecture.md](docs/fan-out-reduction-architecture.md), for what to do about it permanently.
7. [docs/open-items.md](docs/open-items.md), for what this package could not verify and what closes each gap.
8. [docs/customer-questions.md](docs/customer-questions.md), for the fourteen questions whose answers change the analysis.

Skip to [support/README.md](support/README.md) if the immediate need is escalation rather than understanding.

## What is in this package

### docs

Analysis, recommendations, and the record of what remains unproven.

| File | Covers |
|---|---|
| [rca-206-semantic-concurrency.md](docs/rca-206-semantic-concurrency.md) | Why Azure AI Search returns 206 partial semantic responses, why empty answers follow, and why Basic to S1 resolved most of the symptoms |
| [rca-403-connector-triage.md](docs/rca-403-connector-triage.md) | Ranked hypotheses and discriminating tests for the 613 connector 403 failures, and why the tier change does not explain them |
| [copilot-studio-fanout.md](docs/copilot-studio-fanout.md) | How generative orchestration selects knowledge sources and why description-based routing does not apply below 25 sources |
| [immediate-mitigations.md](docs/immediate-mitigations.md) | Eight prioritised interim actions with confidence ratings and the operational constraints that bound each one |
| [fan-out-reduction-architecture.md](docs/fan-out-reduction-architecture.md) | Consolidating seven indexes into one with a filterable `businessUnit` field and `search.in` security trimming, plus the rejected alternatives |
| [open-items.md](docs/open-items.md) | The eleven unverified items U1 to U11, why each matters, and the named artifact that resolves it |
| [customer-questions.md](docs/customer-questions.md) | Fourteen questions, each with why it is asked and what the answer changes |

### scripts

PowerShell 7 and Azure CLI. Three are read-only; one writes and guards every change with `ShouldProcess`.

| Script | Does | Writes to Azure |
|---|---|---|
| [Get-SearchServiceDiagnostics.ps1](scripts/Get-SearchServiceDiagnostics.ps1) | Capacity and configuration audit of the search service, emitting a console report and a JSON evidence file for attaching to a support case | No |
| [Get-ApimPolicyAudit.ps1](scripts/Get-ApimPolicyAudit.ps1) | Collects the SKU and the policy XML at all four scopes to decide whether a 403 originated in the gateway or the backend | No |
| [Compare-ConnectorEgressPrefixes.ps1](scripts/Compare-ConnectorEgressPrefixes.ps1) | Compares the Search IP allow list against current Power Platform connector egress prefixes | No |
| [Enable-DiagnosticSettings.ps1](scripts/Enable-DiagnosticSettings.ps1) | Closes the three observability gaps the investigation depends on | Yes, with `-WhatIf` support |

### kql

Nine runnable Log Analytics queries in three tiers. [kql/README.md](kql/README.md) carries the run order, the prerequisites for each, and what each one proves or disproves.

| Tier | File | Answers |
|---|---|---|
| Discovery | [00-discover-dependency-types.kql](kql/00-discover-dependency-types.kql) | Which Copilot Studio span shape this environment actually emits |
| Discovery | [01-discover-search-diagnostic-shape.kql](kql/01-discover-search-diagnostic-shape.kql) | Which `AzureDiagnostics` columns are populated, and whether Search ever logs a 206 |
| Fan-out and capacity | [10-fan-out-ratio.kql](kql/10-fan-out-ratio.kql) | The per-turn query amplification factor |
| Fan-out and capacity | [11-search-by-http-result-code.kql](kql/11-search-by-http-result-code.kql) | The Search-side distribution of 200, 206, 403, 429, and 503 |
| Fan-out and capacity | [12-semantic-capacity-headroom.kql](kql/12-semantic-capacity-headroom.kql) | Whether concurrent semantic load reaches the in-flight ceiling for the tier |
| Attribution | [20-apim-403-triage.kql](kql/20-apim-403-triage.kql) | Whether API Management rejected the request or Azure AI Search did |
| Attribution | [21-apim-206-semantic-partial-capture.kql](kql/21-apim-206-semantic-partial-capture.kql) | Why each 206 occurred: `Transient` or `CapacityOverloaded` |
| Attribution | [22-connector-403-by-index.kql](kql/22-connector-403-by-index.kql) | Whether the 403s concentrate on a subset of the seven indexes |
| Attribution | [23-design-mode-vs-published.kql](kql/23-design-mode-vs-published.kql) | Whether the 403s hit production users or only the authoring test canvas |

### workbooks

[workbooks/README.md](workbooks/README.md) records which Azure Monitor workbooks Microsoft already publishes for this architecture and which one does not exist. Import the published ones first and author nothing that already exists.

Azure AI Search ships neither a workbook template nor a dedicated Log Analytics table, which is why [ai-search-semantic-capacity.workbook.json](workbooks/ai-search-semantic-capacity.workbook.json) was authored here.

### alerts

Six Azure Monitor rules covering both problems, with the source query, the threshold, and the threshold rationale for each.

| File | Purpose |
|---|---|
| [alert-rules.md](alerts/alert-rules.md) | The six rules, their signals and conditions, and the re-baselining procedure every one of them requires |
| [alert-rules.bicep](alerts/alert-rules.bicep) | Deploys all six, disabled by default |

Every threshold is an engineering recommendation. Microsoft publishes no threshold for an acceptable 206 rate, no threshold for a connector 403 rate, and no guidance on normal fan-out. Re-baseline against two weeks of production telemetry before paging anyone.

### support

Which ticket to open for which symptom, when to open it, when the package already holds the answer, and what each support team will and will not do.

| File | Purpose |
|---|---|
| [README.md](support/README.md) | Routing and sequencing, the free-diagnostics gate, and when not to open a ticket at all |
| [azure-ai-search-ticket.md](support/azure-ai-search-ticket.md) | The Azure case for the 206 partial semantic responses |
| [copilot-studio-ticket.md](support/copilot-studio-ticket.md) | The Power Platform case for the connector 403 errors |
| [apim-ticket.md](support/apim-ticket.md) | The API Management case, filed only once the gateway logs implicate the gateway |

Confirm Power Platform support entitlement before assembling evidence for the Copilot Studio case. An Azure Unified Support contract does not automatically cover Power Platform, and the gap is discovered at filing time. That is question 14 in [docs/customer-questions.md](docs/customer-questions.md) and open item U11 in [docs/open-items.md](docs/open-items.md).

### assets

The evidence base. Everything in `docs/` traces back to these.

| File | What it is |
|---|---|
| [meetingNotes.md](assets/meetingNotes.md) | The authoritative record of the working session, cited throughout by timestamp. It is the only meeting-derived source any document here draws on; the raw session transcript it was distilled from is superseded and is cited nowhere in this package |
| [usefulScreenshots.md](assets/usefulScreenshots.md) | The sampled 403 span with its `DesignMode`, `channelId`, and `conversationId` values, the 206 response fields, and the Microsoft references collected during the session |
| [additionalInfo.md](assets/additionalInfo.md) | The customer's own six-part statement of what they need: observability across Search, Copilot Studio, Functions, and API Management; concurrency and capacity understanding; root cause on the 206s; root cause on the 403s; indexing pipeline visibility; and the systemic insight that retrieval and connector layers, not index size, are the limiting factor |

[additionalInfo.md](assets/additionalInfo.md) is the requirements document for this engagement. Read it to check that the package answers what was actually asked.

### Repository files

| File | Purpose |
|---|---|
| [.markdownlint.json](.markdownlint.json) | Lint configuration for every Markdown file here. Sets MD013 line length to 500 characters and exempts tables and code blocks. Validation depends on it, so changing it changes what passes |
| [README.md](README.md) | This index |

## Validating the package

```powershell
npx --yes markdownlint-cli2 "**/*.md" "#.copilot-tracking" "#node_modules"
Invoke-ScriptAnalyzer -Path scripts -Recurse -Severity Warning,Error
az bicep build --file alerts/alert-rules.bicep --stdout
Get-Content workbooks/ai-search-semantic-capacity.workbook.json -Raw | ConvertFrom-Json | Out-Null
```

## Conventions

Claims that come from Microsoft carry an inline Microsoft Learn link and are quoted where the exact wording matters.
Conclusions drawn from the evidence rather than from documentation begin with **Inferred:** and should not be presented to Microsoft support as Microsoft's own position.
That separation is deliberate and it is maintained in every document here, because a support case that presents inference as Microsoft's published position loses credibility on the first challenge.
