---
title: Copilot Studio support ticket draft
description: Ready-to-submit Power Platform admin center request covering the 613 connector 403 failures, the design-mode scope finding, and the knowledge-source fan-out confirmation.
author: Microsoft
ms.date: 2026-09-22
ms.topic: troubleshooting
keywords:
  - copilot studio
  - power platform admin center
  - connector 403
  - error 613
  - support request
estimated_reading_time: 14
---

This case goes to the Power Platform admin center. It does not go to the Azure portal.

> [!IMPORTANT]
> File at <https://admin.powerplatform.microsoft.com> under Support, then Support requests, then Get support, with the product set to Microsoft Copilot Studio. Filing a Copilot Studio issue as an Azure case is the most common routing mistake in this scenario and the most expensive one, because neither portal can transfer a case to the other product's engineering team. The Azure case would have to be closed and the elapsed time is unrecoverable.

Two further constraints shape how this case is written, and both come from [Support for Power Platform and Dynamics 365 apps](https://learn.microsoft.com/en-us/power-platform/admin/support-overview). Power Platform technical support does not conduct root cause analyses for single-tenant scenarios, so the ask below is framed as identify and remediate. And break-fix cases are capped at four hours of engineer time, so the evidence bundle goes in at filing rather than arriving across several round trips.

## How to read this draft

Everything inside a fenced block is submittable text. Fill the placeholders, delete nothing else. Everything outside the fenced blocks is guidance for the person filing and does not belong in the case.

Claims attributed to Microsoft carry an inline Microsoft Learn link. Conclusions drawn from the evidence rather than from documentation begin with **Inferred:** and are presented in the case as observations, never as Microsoft's own position.

## Before filing this case

Three checks can close the 403 question without a support case at all. Run them first.

| Check | Query or script | If it resolves |
|-------|-----------------|----------------|
| Do the 403s concentrate on one index | [kql/22-connector-403-by-index.kql](../kql/22-connector-403-by-index.kql) | Role assignment scoped to six of seven indexes. Fix it directly, no case needed |
| Does an API Management policy deny with 403 | [scripts/Get-ApimPolicyAudit.ps1](../scripts/Get-ApimPolicyAudit.ps1) | A `quota` or `ip-filter` policy is the answer. Use [apim-ticket.md](apim-ticket.md) if the behavior is unexpected, otherwise fix the policy |
| Does the Search allow-list still cover connector egress | [scripts/Compare-ConnectorEgressPrefixes.ps1](../scripts/Compare-ConnectorEgressPrefixes.ps1) | Missing prefixes explain the intermittency. Refresh the allow-list, no case needed |

Run [kql/23-design-mode-vs-published.kql](../kql/23-design-mode-vs-published.kql) regardless. Its result belongs in the problem statement either way, because it establishes whether published users were affected and therefore what severity and urgency this case carries.

## Placeholders to fill in

| Placeholder | What it is | Where to find it |
|-------------|------------|------------------|
| `<ENVIRONMENT_ID>` | Dataverse environment identifier | Power Platform admin center, Environments, the environment's details pane |
| `<ENVIRONMENT_URL>` | Environment URL | Same details pane |
| `<AGENT_NAME>` | Display name of the agent | Copilot Studio, agent Overview |
| `<AGENT_SCHEMA_NAME>` | Schema name or agent identifier | Copilot Studio, agent Settings, Details |
| `<TENANT_ID>` | Microsoft Entra tenant identifier | `az account show --query tenantId` |
| `<ORCHESTRATION_MODE>` | Generative or classic | Copilot Studio, agent Settings, Generative AI |
| `<MODEL>` | Model the agent is configured to use | Same settings pane |
| `<CHANNELS>` | Channels in use | Copilot Studio, Channels |
| `<UNGROUNDED_SETTING>` | Allow ungrounded responses, on or off | Copilot Studio, agent Settings, Generative AI |
| `<MODERATION_LEVEL>` | Content moderation level | Same settings pane |
| `<LICENSING>` | Prepaid message packs, pay-as-you-go, or Microsoft 365 Copilot | Power Platform admin center, Licensing |
| `<DESIGN_MODE_SHARE>` | Percentage of the 403s carrying `DesignMode: "True"` | [kql/23-design-mode-vs-published.kql](../kql/23-design-mode-vs-published.kql) |
| `<FAILURE_TIMESTAMP_1>` through `<FAILURE_TIMESTAMP_3>` | UTC timestamps of individual 403 failures | Application Insights dependency records |
| `<CONVERSATION_ID_1>` through `<CONVERSATION_ID_3>` | `conversationId` for each failure | The `attributes.conversationId` field on the dependency record |
| `<INDEX_403_DISTRIBUTION>` | How the 403s distribute across the seven indexes | [kql/22-connector-403-by-index.kql](../kql/22-connector-403-by-index.kql) |
| `<APIM_ATTRIBUTION>` | Whether the 403 came from an API Management policy or the Search backend | [kql/20-apim-403-triage.kql](../kql/20-apim-403-triage.kql) |
| `<REQUEST_ID_PRESENT>` | Whether `x-ms-request-id` appears on the 403 response | Captured response headers |
| `<PEAK_CONCURRENT_SESSIONS>` | Peak simultaneous sessions | Application Insights, or the Copilot Studio analytics pane |
| `<MESSAGES_PER_MINUTE>` | Peak messages per minute | Same source |
| `<AZURE_CASE_NUMBER>` | Azure AI Search case number | The Azure case filed first, from [azure-ai-search-ticket.md](azure-ai-search-ticket.md) |

## Where to file this

| Field | Value |
|-------|-------|
| Portal | <https://admin.powerplatform.microsoft.com> |
| Path | Support, then Support requests, then Get support |
| Product | Microsoft Copilot Studio |
| Request type | Technical, which covers break-fix issues |
| Severity | B, moderate business impact |
| Advanced diagnostic consent | Yes |
| Environment | `<ENVIRONMENT_ID>`. If it is not listed, select the option for an unlisted environment and supply `<ENVIRONMENT_URL>` |

[Get support in the Power Platform admin center](https://learn.microsoft.com/en-us/power-platform/admin/get-help-support) states that the filer must hold an admin role such as Power Platform Admin or Environment Admin, that end users cannot open support requests, and that there is no alternative to this experience. It also states that an active support plan is required to create a request at all. Confirm both before starting.

> [!WARNING]
> An Azure support contract does not confer a Power Platform entitlement. Verify the Power Platform support plan separately. Adding one takes an Access ID and password and the documentation notes it can take up to an hour to appear, so discovering the gap at filing time costs a day rather than a minute. This is carried as open item U11.

Two product-selection traps are worth avoiding. Selecting Dynamics 365 Customer Service for an issue with another product misroutes and delays the request. And selecting Technical in order to submit an advisory request results in closure, which is why the architecture consolidation question in [docs/fan-out-reduction-architecture.md](../docs/fan-out-reduction-architecture.md) stays out of this case entirely.

## What is known and what is being asked

| Established | Basis |
|-------------|-------|
| All seven knowledge sources are queried on every user turn | [Knowledge in Copilot Studio](https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-copilot-studio) states that generative orchestration filters knowledge sources using an internal model only above 25 sources |
| The tier change on the search service cannot explain the 403s | [Azure AI Search HTTP status codes](https://learn.microsoft.com/en-us/rest/api/searchservice/http-status-codes) documents 403 as authorization failure. Storage pressure returns 429, and semantic free-plan exhaustion returns 402 |
| The sampled 403 carries `DesignMode: "True"` and `channelId: "pva-studio"` | [assets/usefulScreenshots.md](../assets/usefulScreenshots.md) |
| The sampled 403 took 2,566 milliseconds | Same record |
| An invalid or missing API Management subscription key returns 401, not 403 | [Subscriptions in API Management](https://learn.microsoft.com/en-us/azure/api-management/api-management-subscriptions) |

| Being asked | Why only Microsoft can answer |
|-------------|-------------------------------|
| What error 613 maps to in the current runtime | The code is absent from the published error-code reference |
| What is returning 403 through the connector, and how to stop it | The connector implementation is not visible to the customer |
| Whether the fan-out behavior and the sub-25 threshold are being read correctly | Confirmation of documented behavior against a live configuration |
| How to distinguish a capacity-driven empty answer from a citation-suppressed one in telemetry | The suppression decision is internal to the orchestrator |

**Inferred:** 2,566 milliseconds on a 403 is the shape of a request that reached a backend and was rejected there, because an API Management inbound policy short-circuit rejects in tens of milliseconds without touching the backend. That pushes backend-originated rejection up the hypothesis ranking. It is a strong signal rather than proof, since a slow policy evaluation or an internal retry could produce the same duration. The full ranked list is in [docs/rca-403-connector-triage.md](../docs/rca-403-connector-triage.md).

## Case title

```text
Copilot Studio agent: recurring connector HTTP 403 surfaced as error 613 against Azure AI Search, and empty grounded answers; request identification and remediation
```

## Problem description

```text
SUMMARY
A Copilot Studio agent that grounds on 7 Azure AI Search indexes, reached through Azure API
Management, is producing two recurring failures:
  (a) Connector failures surfaced as error code 613 with an underlying HTTP 403 Forbidden.
      613 occurrences captured in Application Insights.
  (b) Empty or ungrounded answers even when the underlying indexes contain matching content.

We are asking you to identify what is returning 403 to the connector and to tell us how to
remediate it. We also ask you to confirm three points of documented behavior against our live
configuration, listed under ISSUE C.

A parallel Azure support case covers the Azure AI Search capacity side of this environment. See
RELATED CASE at the end.

SCOPE FINDING, PLEASE READ FIRST
<DESIGN_MODE_SHARE> of the captured 403 failures carry the attributes DesignMode: "True" and
channelId: "pva-studio", which indicate the Copilot Studio authoring test canvas rather than a
published channel. A representative dependency record:

    name:           "Azure AI Search"
    type:           "Connector"
    target:         "shared_azureaisearch/SemanticHybridSearch"
    serviceName:    "Microsoft Copilot Studio"
    resultCode:     "403"
    success:        "False"
    duration:       2566
    attributes.DesignMode:    "True"
    attributes.channelId:     "pva-studio"
    attributes.conversationId: <CONVERSATION_ID_1>
    timestamp:      <FAILURE_TIMESTAMP_1>

If these failures are confined to the authoring canvas, the published agent may be unaffected and
the scope of this case narrows considerably. We would like your help confirming that
interpretation, because it changes what we prioritise. The Azure AI Search connector documents its
key and OAuth authentication modes as not shareable, which means each maker holds a separate
connection, and a broken maker-scoped connection would fit this signature precisely.

ENVIRONMENT
- Environment ID: <ENVIRONMENT_ID>
- Environment URL: <ENVIRONMENT_URL>
- Tenant ID: <TENANT_ID>
- Agent name: <AGENT_NAME>
- Agent schema name or ID: <AGENT_SCHEMA_NAME>
- Orchestration mode: <ORCHESTRATION_MODE>
- Model configured: <MODEL>
- Channels: <CHANNELS>
- Allow ungrounded responses: <UNGROUNDED_SETTING>
- Content moderation level: <MODERATION_LEVEL>
- Licensing: <LICENSING>
- Knowledge wiring: 7 Azure AI Search indexes, one per business unit, reached through Azure API
  Management

ISSUE A - CONNECTOR HTTP 403 SURFACED AS ERROR 613
Users intermittently receive error 613 with an underlying HTTP 403 Forbidden from the Azure AI
Search connector, which reaches the search service through Azure API Management.

Error code 613 does not appear in the current error-code reference at
https://learn.microsoft.com/en-us/troubleshoot/power-platform/copilot-studio/authoring/error-codes
The modern web-app list there is string-based, for example HTTP403Forbidden, and the numeric
Classic and Teams list ends at 3003. Please confirm what 613 maps to in the current runtime and
which component emits it.

Occurrences, all times UTC:
1. <FAILURE_TIMESTAMP_1> - conversationId: <CONVERSATION_ID_1>
2. <FAILURE_TIMESTAMP_2> - conversationId: <CONVERSATION_ID_2>
3. <FAILURE_TIMESTAMP_3> - conversationId: <CONVERSATION_ID_3>

Already checked on our side:
- Distribution of the 403s across the 7 indexes: <INDEX_403_DISTRIBUTION>
- API Management gateway log attribution, comparing ResponseCode against BackendResponseCode:
  <APIM_ATTRIBUTION>
- x-ms-request-id present on the 403 response: <REQUEST_ID_PRESENT>
- API Management policy scan at global, product, API and operation scope for quota, quota-by-key,
  ip-filter, validate-jwt and check-header elements: results attached
- Azure AI Search IP allow list compared against current Power Platform connector egress service
  tag prefixes: results attached
- Connector connection validity and credential rotation state: reviewed
- Azure AI Search role assignments, including Search Index Data Reader scope: reviewed
- Data loss prevention policy: all connectors used by this agent are in the same data group and
  none are blocked

We have ruled out the API Management subscription key as a cause, because
https://learn.microsoft.com/en-us/azure/api-management/api-management-subscriptions documents a
missing or invalid key as producing 401, not 403. We have also ruled out an API Management
rate-limit policy, which returns 429 per
https://learn.microsoft.com/en-us/azure/api-management/rate-limit-policy

What we need from you: identify what is returning 403 to the connector in this configuration and
how to remediate it. The connector is a black box from our side, so we cannot see the outbound
request it builds or the credential it presents.

ISSUE B - EMPTY GROUNDED ANSWERS
The agent returns no grounded answer despite matching content existing in the indexes. We have
two candidate explanations and need help separating them in telemetry:

  1. Azure AI Search returns HTTP 206 Partial Content with @search.semanticPartialResponseReason,
     so semantic captions and answers are absent from the grounding data and the agent has nothing
     quotable to cite. This is tracked in the Azure case, see RELATED CASE.
  2. The behavior documented at
     https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-copilot-studio, where a
     correct answer is withheld because the model did not emit an in-text citation.

Our Allow ungrounded responses setting is <UNGROUNDED_SETTING>.

What we need from you: tell us which signal in Copilot Studio telemetry distinguishes these two
paths for a given turn, so we can attribute each empty answer correctly instead of guessing.

ISSUE C - KNOWLEDGE-SOURCE FAN-OUT, CONFIRMATION REQUEST
Every user turn queries all 7 knowledge sources regardless of relevance to the question. Our
reading of https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-copilot-studio is
that this is expected, because generative orchestration filters knowledge sources using an
internal model only when there are more than 25 different knowledge sources, and we have 7.

Please confirm, against our live configuration:
  1. That below 26 knowledge sources no description-based routing occurs and all configured
     sources participate in every knowledge search.
  2. Whether knowledge sources are queried in parallel or sequentially, and whether any per-source
     result cap is configurable.
  3. Whether converting these 7 sources into Tools is the supported route to description-driven
     selection without exceeding 25 knowledge sources, given that
     https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-generative-actions states
     the orchestrator selects tools by name and description.

OBSERVED LOAD
- Approximately 7 to 15 users per hour
- Peak concurrent sessions: <PEAK_CONCURRENT_SESSIONS>
- Peak messages per minute: <MESSAGES_PER_MINUTE>
- We are within the published quotas at
  https://learn.microsoft.com/en-us/microsoft-copilot-studio/requirements-quotas but expect growth
  and want the headroom validated before it becomes an incident.

BUSINESS IMPACT
A user-facing agent serving 7 business units returns errors or no answer on an intermittent basis.
Users cannot distinguish a failure from an absence of information, which erodes trust in the
agent as an information source.

ATTACHED
- Agent solution export or snapshot
- Application Insights export of the connector dependency records for the listed UTC windows
- API Management policy audit output (JSON, sanitised)
- Azure AI Search IP allow list coverage comparison (JSON)
- Full response headers captured from a failing 403
- Screenshots of error 613 as users encounter it

RELATED CASE
Azure support case covering the Azure AI Search HTTP 206 semantic capacity behavior:
<AZURE_CASE_NUMBER>
```

## What to keep out of this case

| Keep out | Why |
|----------|-----|
| A request for a root cause analysis document | Power Platform technical support does not conduct them for single-tenant scenarios. The request is declined on policy, and the case loses time |
| The seven-index to one-index consolidation review | That is an advisory request. Submitting it as Technical results in closure. Raise it separately under an advisory entitlement if one exists |
| The semantic ranker concurrency question | It belongs to the Azure case, where the product group can actually answer it |
| A throughput or rate-limit increase request | That is a different process requiring pilot data, and mixing it in dilutes the break-fix ask |

## Evidence checklist

### Environment facts

* [ ] Environment ID and environment URL
* [ ] Agent name, schema name, and agent identifier
* [ ] Orchestration mode, configured model, and channels in use
* [ ] Allow ungrounded responses setting
* [ ] Content moderation level
* [ ] Licensing: prepaid message packs, pay-as-you-go, or Microsoft 365 Copilot
* [ ] How each of the seven indexes is wired, as a knowledge source, a tool, or a custom connector
* [ ] Agent solution export or snapshot

### Failure evidence

* [ ] The design-mode share from [kql/23-design-mode-vs-published.kql](../kql/23-design-mode-vs-published.kql), which sets the scope of the whole case
* [ ] At least three UTC timestamps with matching `conversationId` values
* [ ] Full response headers from a failing 403, including whether `x-ms-request-id` is present
* [ ] The per-index distribution from [kql/22-connector-403-by-index.kql](../kql/22-connector-403-by-index.kql)
* [ ] The layer attribution from [kql/20-apim-403-triage.kql](../kql/20-apim-403-triage.kql)
* [ ] API Management policy audit output from [scripts/Get-ApimPolicyAudit.ps1](../scripts/Get-ApimPolicyAudit.ps1)
* [ ] Allow-list coverage output from [scripts/Compare-ConnectorEgressPrefixes.ps1](../scripts/Compare-ConnectorEgressPrefixes.ps1)
* [ ] Screenshots of error 613 as users encounter it

### Pre-flight

* [ ] Power Platform service health and the known issues page checked for the failure windows
* [ ] Power Platform support plan confirmed active, separately from any Azure entitlement
* [ ] Filer holds Power Platform Admin or Environment Admin
* [ ] Azure case filed and its case number available for cross-reference
* [ ] Attachments sanitised: API Management policy XML, connector definitions, and query text reviewed for credentials and tenant data
* [ ] Advanced diagnostic consent granted

> [!NOTE]
> [Get support in the Power Platform admin center](https://learn.microsoft.com/en-us/power-platform/admin/get-help-support) states that Microsoft cannot access or run diagnostics on tenant or environment data without consent, and that a support representative will contact the customer to obtain it if it was not granted. Granting it at filing time removes a round trip from a case that has only four hours of engineer time.

## What to expect

The first response will likely focus on the connection rather than the connector, because a maker-scoped connection with a stale credential is the fastest thing to check and the design-mode finding points at it. Have the environment's connection inventory ready.

Expect the fan-out confirmation in Issue C to be answered quickly, since it is a matter of documented behavior. Expect Issue A to take longer, and expect the engineer to ask for the API Management attribution first. Supplying it at filing rather than on request is the difference between a case that reaches analysis and one that spends its budget on evidence collection.

If the four-hour cap is reached without resolution, the case closes unless the tenant holds Unified or Professional Direct, which allow continuation as an advisory case. Decide in advance who makes that call so the closure does not arrive unexpectedly.

## Related material

| Document | Contribution |
|----------|--------------|
| [README.md](README.md) | Routing, sequencing, severity, and the two Power Platform traps in full |
| [docs/rca-403-connector-triage.md](../docs/rca-403-connector-triage.md) | The ranked hypotheses, the discriminating tests, and the coincidence question |
| [docs/copilot-studio-fanout.md](../docs/copilot-studio-fanout.md) | The 25-source threshold and the second cause of empty answers |
| [azure-ai-search-ticket.md](azure-ai-search-ticket.md) | The case filed first, whose number this one cross-references |
| [apim-ticket.md](apim-ticket.md) | The conditional third case, if the 403 attributes to an API Management policy |
| [assets/usefulScreenshots.md](../assets/usefulScreenshots.md) | The dependency record reproduced in the problem statement |
