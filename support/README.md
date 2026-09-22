---
title: Support escalation guide
description: Which Microsoft support ticket to open for which symptom, when to open it, when the package already holds the answer, and what each support team will and will not do.
author: Microsoft
ms.date: 2026-09-22
ms.topic: troubleshooting
keywords:
  - azure ai search
  - copilot studio
  - api management
  - microsoft support
  - escalation
estimated_reading_time: 14
---

Two symptoms, two products, two portals, and one sequencing decision that determines whether the escalation is productive or wasted.

The 206 partial semantic responses belong to Azure AI Search. The 613 connector 403 errors belong to Copilot Studio, unless the gateway logs prove otherwise, in which case they belong to API Management. Neither portal can transfer a case to the other product's engineering team, so routing has to be right the first time.

Before any of that, there is a gate. Several of the leading hypotheses in this package are disprovable for free in minutes, and at least three of them resolve to a customer-side configuration change rather than a Microsoft defect. Opening a ticket ahead of those checks spends the customer's time and a support engineer's time establishing something the package can already establish.

## How to read this guide

Claims that come from Microsoft carry an inline Microsoft Learn link and are quoted where the exact wording matters. Conclusions drawn from the evidence rather than from documentation begin with **Inferred:** and should not be presented to Microsoft support as Microsoft's own position.

## Run the free diagnostics first

Every check below costs minutes, requires no support case, and either removes a hypothesis from the ticket or removes the need for the ticket entirely. Work through them before filing.

| Check | How | What it settles |
|-------|-----|-----------------|
| Are the 403s production or authoring only | [kql/23-design-mode-vs-published.kql](../kql/23-design-mode-vs-published.kql) | The sampled failure carries `DesignMode: "True"` and `channelId: "pva-studio"`. If that holds across all 613, no published user was ever affected and the severity, the product, and the urgency all change |
| Is the semantic ranker on the free plan | [scripts/Get-SearchServiceDiagnostics.ps1](../scripts/Get-SearchServiceDiagnostics.ps1), field `properties.semanticSearch` | A `free` value caps semantic ranking at 1,000 requests per month. At seven requests per turn that is exhausted in one to three days, which is a separate root cause with a self-service fix and no ticket |
| Do the 403s concentrate on one index | [kql/22-connector-403-by-index.kql](../kql/22-connector-403-by-index.kql) | A clean split confirms role assignment scoped to six of seven indexes. That is a customer-side fix |
| Does an API Management policy deny with 403 | [scripts/Get-ApimPolicyAudit.ps1](../scripts/Get-ApimPolicyAudit.ps1) | `quota` and `quota-by-key` are the only API Management throttling policies that return 403. Finding one is the answer, not a question for support |
| Does the Search allow-list still cover connector egress | [scripts/Compare-ConnectorEgressPrefixes.ps1](../scripts/Compare-ConnectorEgressPrefixes.ps1) | Missing prefixes produce exactly the intermittent, index-agnostic 403 pattern reported, and refreshing the allow-list is a customer-side fix |
| Is "Allow ungrounded responses" switched off | [docs/copilot-studio-fanout.md](../docs/copilot-studio-fanout.md) | Some share of the empty answers may be documented suppression behavior rather than capacity |
| What `sessionId` does the agent send | [docs/immediate-mitigations.md](../docs/immediate-mitigations.md), action 4 | A constant value pins traffic to one replica set and would explain why S1 fixed the problem only in large part |
| Was there a service incident in the window | [Azure Service Health](https://learn.microsoft.com/en-us/azure/service-health/service-health-portal-update) and the Power Platform [service health page](https://learn.microsoft.com/en-us/power-platform/admin/get-help-support) | A published incident changes the case from a technical investigation to an incident reference |

Run [scripts/Enable-DiagnosticSettings.ps1](../scripts/Enable-DiagnosticSettings.ps1) with `-WhatIf` first if the gateway logs or the Search operation logs are not yet flowing. Two conditions block the plan outright: API Management on the Consumption tier supports no resource logs at all, and an Application Insights component with `DisableLocalAuth` set makes the Copilot Studio export fail silently.

## When not to open a ticket

These questions already have answers. Raising them consumes case time and, on the Power Platform side, may be classified as advisory and closed.

| Question | Where it is already answered |
|----------|------------------------------|
| Why does the agent query all seven knowledge sources every turn | [docs/copilot-studio-fanout.md](../docs/copilot-studio-fanout.md). Generative orchestration filters knowledge sources with an internal model only above 25 sources ([knowledge in Copilot Studio](https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-copilot-studio)) |
| Why did Basic to S1 help | [docs/rca-206-semantic-concurrency.md](../docs/rca-206-semantic-concurrency.md). S1 raises the per-search-unit ceiling from 6 in flight to 9 |
| Does the tier change explain the 403s | [docs/rca-403-connector-triage.md](../docs/rca-403-connector-triage.md). Azure AI Search documents 403 as authorization failure; storage pressure returns 429 and semantic free-plan exhaustion returns 402 |
| Can the orchestrator route to one knowledge source by description | [docs/fan-out-reduction-architecture.md](../docs/fan-out-reduction-architecture.md). Not for knowledge sources below 25, but Tools and connected agents are selected by name and description |
| How should the architecture change | [docs/fan-out-reduction-architecture.md](../docs/fan-out-reduction-architecture.md) |
| What should we monitor | [kql/README.md](../kql/README.md), [workbooks/README.md](../workbooks/README.md), [alerts/alert-rules.md](../alerts/alert-rules.md) |

> [!NOTE]
> Architecture review of a seven-index to one-index consolidation is an advisory request on the Power Platform side, not a break-fix one. [Support for Power Platform and Dynamics 365 apps](https://learn.microsoft.com/en-us/power-platform/admin/support-overview) states that selecting Technical in order to submit an Advisory request results in closure of the request. Keep the consolidation discussion out of the break-fix case.

## Which portal for which symptom

| Symptom | Portal | Product or service |
|---------|--------|--------------------|
| HTTP 206 partial content from `search.windows.net` | Azure portal | Azure AI Search |
| `@search.semanticPartialResponseReason` of any value | Azure portal | Azure AI Search |
| `CapacityOverloaded` | Azure portal | Azure AI Search |
| Semantic ranker concurrency limit increase | Azure portal | Azure AI Search |
| Replica and partition sizing advice | Azure portal | Azure AI Search |
| HTTP 503 or 429 from the search service | Azure portal | Azure AI Search |
| 403 proven by gateway logs to originate at an API Management policy | Azure portal | API Management |
| Copilot Studio error 613 | Power Platform admin center | Microsoft Copilot Studio |
| Connector 403 not yet attributed to a layer | Power Platform admin center | Microsoft Copilot Studio |
| Every knowledge source queried on every turn | Power Platform admin center | Microsoft Copilot Studio |
| Empty or ungrounded generative answers | Power Platform admin center | Microsoft Copilot Studio |
| Copilot Studio throughput or rate-limit increase | Power Platform admin center | Microsoft Copilot Studio |

> [!IMPORTANT]
> Copilot Studio cases do not go to the Azure portal. They go to the Power Platform admin center at <https://admin.powerplatform.microsoft.com> under Support, Support requests, Get support.
> This is a different portal, a different permission model, a different support-plan entitlement, and a different engineering organization. Filing a Copilot Studio issue as an Azure case is the most common and most expensive routing mistake in this scenario, because the Azure case cannot be transferred and the elapsed time is lost.

### The decision tree

```text
Symptom observed
│
├─ 206 / CapacityOverloaded / semantic concurrency / replica sizing
│      -> AZURE PORTAL > Help + support > Create a support request
│         Service: "Azure AI Search"
│         Draft: support/azure-ai-search-ticket.md
│
├─ 403 PROVEN to originate at an API Management policy (kql/20)
│      -> AZURE PORTAL > Help + support > Create a support request
│         Service: "API Management"   (a separate case, not folded into the above)
│         Draft: support/apim-ticket.md
│
├─ Error 613 / connector 403 / fan-out behavior / Copilot Studio quotas
│      -> POWER PLATFORM ADMIN CENTER > Support > Support requests > Get support
│         Product: "Microsoft Copilot Studio"
│         Draft: support/copilot-studio-ticket.md
│
└─ Cannot isolate the layer
       -> Open the Azure case AND the Copilot Studio case.
          Cross-reference each case number in the other description.
          Neither portal can transfer a case to the other product's engineering team.
```

## Filing order

1. Azure AI Search goes first. Microsoft's own documentation instructs customers in this exact situation to file, which makes the case a documented in-scope scenario rather than a request for free consulting. The ask is the clearest of the three, and it addresses the mechanism behind the symptom rather than a downstream effect. Use the resource menu entry point on the search service, Help then Support plus Troubleshooting, because it attaches the resource context to the case.
2. Copilot Studio goes second, quoting the Azure case number in its description. Filing it second means the connector case opens with the Search-side capacity question already in flight, which keeps the Power Platform engineer focused on the 403 and the authoring-canvas scope rather than on the 206.
3. API Management goes third, and only if [kql/20-apim-403-triage.kql](../kql/20-apim-403-triage.kql) shows the 403 raised by a policy rather than returned by the backend. Filing this speculatively produces a case that the engineer closes by asking for the exact evidence that would have told the customer not to file.

## Severity

File both at **Severity B**.

| Severity | Business impact | Standard | Professional Direct | Unified Enterprise |
|----------|-----------------|----------|---------------------|--------------------|
| A | Critical, significant loss or degradation of service | Under 1 hour | Under 1 hour | Under 1 hour |
| B | Moderate, loss or degradation but work continues impaired | Under 4 hours | Under 2 hours | Under 2 hours |
| C | Minimum, minor impediments | Under 8 hours | Under 4 hours | Under 4 hours |

Severity A is the wrong choice here and carries a specific downside. The service is functioning after the move to S1 and the added replicas, so the impact does not meet the critical bar.
[Support for Power Platform and Dynamics 365 apps](https://learn.microsoft.com/en-us/power-platform/admin/support-overview) states that selecting Severity A for a low priority issue results in automatic downgrade, and that submitting a Severity A request means committing to engage with Microsoft continuously until resolution.
An inflated severity therefore buys a downgrade, a delay, and a loss of credibility on a case that will need several rounds of evidence exchange.

Severity B still buys a response inside two hours on Professional Direct and Unified, which is sufficient for an investigation of this shape.

> [!NOTE]
> Azure Developer support caps at Severity C. Severity A and B are unavailable on that plan. Confirm the plan before choosing a severity.

## Trap one: Power Platform support does not perform root cause analyses

[Support for Power Platform and Dynamics 365 apps](https://learn.microsoft.com/en-us/power-platform/admin/support-overview) is explicit:

> Technical support doesn't conduct RCAs as part of any support experience. RCAs are only provided to published service-related incidents when multiple customers or services aren't available. Any other request for an RCA to a specific scenario impacting your tenant won't be honored by the engineering team.

The stated goal of this engagement is a root cause analysis, so this matters directly. A case that opens with a request for an RCA will be declined on policy, not on merit, and the elapsed time is unrecoverable.

Frame the Copilot Studio ask as identify and remediate. Ask the engineer to determine what is returning 403 and to tell the customer how to stop it. Do not ask for a root cause analysis document. The causal explanation for the capacity side is available from Azure AI Search support, which is a second reason to lead with that case.

## Trap two: Power Platform performance cases are capped at four hours

From the same page:

> The Microsoft Dynamics support team invests up to four hours of time on a break-fix case to assist. If after four hours the issue isn't resolved, consult a partner or the community forums for further investigation. The technical support incident is then closed. Premier and Unified Support customers may be able to continue via an advisory case.

Four hours of engineer time is not four hours of elapsed time, and it is consumed by every round trip. A case that opens without the evidence bundle attached will spend a meaningful share of its budget on evidence requests before any analysis starts.

Two consequences follow. Attach everything up front, including the design-mode finding, the conversation identifiers, and the response headers. And confirm whether the tenant holds Unified or Professional Direct, because those are the only plans that can continue the investigation as an advisory case after the cap is reached.

## Check the support entitlement before filing

An Azure support contract and a Power Platform support entitlement are separate things, and holding one does not confer the other.

| Portal | Requirement |
|--------|-------------|
| Azure | A support plan is required for technical support. Subscription management is unlimited and free, but this is a technical case. The filer needs Owner, Contributor, or Support Request Contributor at the subscription level |
| Power Platform | An active support plan is required to create a request at all. [Get support in the Power Platform admin center](https://learn.microsoft.com/en-us/power-platform/admin/get-help-support) states that end users cannot open support requests and that there is no alternative to this experience. The filer needs an admin role such as Power Platform Admin or Environment Admin |

> [!WARNING]
> An Azure Unified contract does not automatically cover Power Platform. Verify the Power Platform entitlement before planning the Copilot Studio case, because discovering the gap at filing time blocks the escalation outright. This is carried as open item U11 and is the one prerequisite in this guide that nobody on the engagement can verify from the outside.

Adding a plan in the Power Platform admin center takes an Access ID and password, and the documentation notes it can take up to an hour to appear. Budget for that rather than discovering it on the day.

## What to expect from each team

| Team | Will do | Will not do |
|------|---------|-------------|
| Azure AI Search | Confirm the authoritative semantic ranker limits for the specific tier, region, and search-unit configuration. Advise whether a concurrency limit increase is available and what evidence approves it. Comment on regional semantic capacity, which is not visible to the customer. Review the sizing model | Redesign the agent. Guarantee a limit increase, which the limits documentation describes as subject to available capacity in the region |
| Copilot Studio | Identify what is returning 403 through the connector and how to remediate it. Confirm the fan-out behavior and the supported alternatives. Confirm what error 613 maps to in the current runtime | Produce an RCA document. Spend more than four hours on a break-fix case without a Unified or Professional Direct plan. Perform an architecture review inside a technical case |
| API Management | Interpret the gateway logs, confirm which policy denied the request, and explain the error attribution fields | Diagnose the Azure AI Search capacity behavior, which belongs to the first case |

## Evidence to gather first

The three scripts in this package produce the JSON files that the tickets ask the customer to attach. Run all three before filing and keep the output.

| Script | Produces | Attaches to |
|--------|----------|-------------|
| [scripts/Get-SearchServiceDiagnostics.ps1](../scripts/Get-SearchServiceDiagnostics.ps1) | Tier, replicas, partitions, search units, `properties.semanticSearch`, creation date, network posture, computed in-flight capacity verdict | Azure AI Search case |
| [scripts/Get-ApimPolicyAudit.ps1](../scripts/Get-ApimPolicyAudit.ps1) | API Management tier, policy XML at all four scopes, every denial element found, gateway-log readiness | API Management case, and the Copilot Studio case as supporting evidence |
| [scripts/Compare-ConnectorEgressPrefixes.ps1](../scripts/Compare-ConnectorEgressPrefixes.ps1) | Allow-list coverage against current connector egress prefixes, with the missing-prefix list | Azure AI Search case if backend-originated, Copilot Studio case otherwise |

Azure guidance is to upload a single file, so bundle the JSON output, the KQL exports, and the raw response bodies into one archive. Microsoft's own minimum evidence list for an Azure AI Search capacity case, from [Service limits and quotas](https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity), is the subscription, region, tier, requested configuration, full error text, UTC time, and any correlation or operation ID.

Set advanced diagnostic information to Yes on the Azure case and grant the diagnostic consent on the Power Platform case. Both materially shorten time to resolution, and on the Power Platform side the documentation states that Microsoft cannot run diagnostics in the tenant without consent and that a representative will have to contact the customer to obtain it.

> [!CAUTION]
> Azure's support request guidance is to avoid including personal or confidential information in the problem details. The drafts in this package are written to be submitted as-is once placeholders are filled, but review the attachments for tenant data, user identifiers, and query text before uploading.

## The three drafts

| Draft | Portal | File when |
|-------|--------|-----------|
| [azure-ai-search-ticket.md](azure-ai-search-ticket.md) | Azure portal, service Azure AI Search | First, unconditionally. The documented basis is the strongest of the three |
| [copilot-studio-ticket.md](copilot-studio-ticket.md) | Power Platform admin center, product Microsoft Copilot Studio | Second, once the Azure case number exists. Skip if the free diagnostics resolve the 403 to a customer-side fix |
| [apim-ticket.md](apim-ticket.md) | Azure portal, service API Management | Third, and only if the gateway logs attribute the 403 to an API Management policy |

Each draft carries a placeholder table listing every value the customer supplies and where to find it, a copy-paste title and problem description, and an evidence checklist.

## Related material

| Document | Contribution |
|----------|--------------|
| [docs/rca-206-semantic-concurrency.md](../docs/rca-206-semantic-concurrency.md) | The capacity mechanism and the open items escalated in the Azure case |
| [docs/rca-403-connector-triage.md](../docs/rca-403-connector-triage.md) | The ranked 403 hypotheses and the discriminating test behind each one |
| [docs/copilot-studio-fanout.md](../docs/copilot-studio-fanout.md) | The 25-source threshold and the fan-out behavior the Copilot Studio case asks Microsoft to confirm |
| [docs/immediate-mitigations.md](../docs/immediate-mitigations.md) | What has already been tried, which the tickets report as prior mitigation |
| [docs/fan-out-reduction-architecture.md](../docs/fan-out-reduction-architecture.md) | The strategic recommendation, which stays out of the break-fix cases |
| [kql/README.md](../kql/README.md) | The query library whose output becomes ticket evidence |
| [assets/meetingNotes.md](../assets/meetingNotes.md) | The authoritative customer evidence behind every claim in the drafts |
| [assets/usefulScreenshots.md](../assets/usefulScreenshots.md) | The sampled 403 dependency record and the observed 206 field values |
