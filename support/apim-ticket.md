---
title: API Management support ticket draft
description: Conditional Azure support request for the connector 403 failures, to be filed only when gateway logs attribute the rejection to an API Management policy rather than the Azure AI Search backend.
author: Microsoft
ms.date: 2026-09-22
ms.topic: troubleshooting
keywords:
  - api management
  - gateway logs
  - http 403
  - quota policy
  - support request
estimated_reading_time: 12
---

> [!IMPORTANT]
> Do not file this case yet. File it only if [kql/20-apim-403-triage.kql](../kql/20-apim-403-triage.kql) attributes the 403 responses to an API Management policy rather than to the Azure AI Search backend, and only if the policy audit cannot explain the denial on its own. Filing it speculatively produces a case an engineer closes by asking for exactly the evidence that would have told the customer not to file.

Two conditions gate this case, and both have to hold.

The first is attribution. `ResponseCode` is what API Management returned to Copilot Studio, and `BackendResponseCode` is what Azure AI Search returned to API Management. Divergence between the two is the definitive attribution ([Monitor API Management data reference](https://learn.microsoft.com/en-us/azure/api-management/monitor-api-management-reference)).
A 403 present in `ResponseCode` with no backend 403 behind it is an API Management denial. A 403 in `BackendResponseCode` belongs to the Azure AI Search case instead.

The second is that the denial is unexplained. [scripts/Get-ApimPolicyAudit.ps1](../scripts/Get-ApimPolicyAudit.ps1) scans every policy scope for the elements that can deny a request. If it finds a `quota`, `quota-by-key`, or `ip-filter` policy whose configuration matches the observed pattern, the customer has the answer and the remedy is a policy change, not a support case. This draft exists for the case where the gateway attributes the 403 to itself and no policy accounts for it.

## Gate check

Work through this before deciding. Every row has to point the same way.

| Condition | How to test | File only if |
|-----------|-------------|--------------|
| Gateway logs are available at all | [scripts/Get-ApimPolicyAudit.ps1](../scripts/Get-ApimPolicyAudit.ps1) reports the SKU | The instance is not on the Consumption tier, which supports no resource logs at all |
| The 403 originates at the gateway | [kql/20-apim-403-triage.kql](../kql/20-apim-403-triage.kql) | `Origin403` reads as raised by an API Management policy, not returned by the backend |
| No policy explains it | The policy audit output | No `quota`, `quota-by-key`, or `ip-filter` element accounts for the observed pattern |
| The search-side causes are eliminated | [kql/22-connector-403-by-index.kql](../kql/22-connector-403-by-index.kql) and [scripts/Compare-ConnectorEgressPrefixes.ps1](../scripts/Compare-ConnectorEgressPrefixes.ps1) | The 403s spread evenly across indexes and the allow-list covers current connector egress |

If the attribution query returns nothing because gateway logging is not enabled, run [scripts/Enable-DiagnosticSettings.ps1](../scripts/Enable-DiagnosticSettings.ps1) with `-WhatIf` first, then collect at least one failure window. The case cannot be argued without that data, and the engineer will request it as the first action.

> [!WARNING]
> The API Management Consumption tier supports no resource logs, which removes the attribution query entirely. On Consumption, the investigation falls back to policy inspection and the design-mode check, and this case has no evidence to stand on. Confirm the tier before planning around gateway logs. This is carried as open item U9.

## How to read this draft

Everything inside a fenced block is submittable text. Fill the placeholders, delete nothing else. Everything outside the fenced blocks is guidance for the person filing and does not belong in the case.

Claims attributed to Microsoft carry an inline Microsoft Learn link. Conclusions drawn from the evidence rather than from documentation begin with **Inferred:** and are presented in the case as observations, never as Microsoft's own position.

## Placeholders to fill in

| Placeholder | What it is | Where to find it |
|-------------|------------|------------------|
| `<SUBSCRIPTION_ID>` | Subscription holding the API Management instance | Azure portal, Overview blade |
| `<TENANT_ID>` | Microsoft Entra tenant identifier | `az account show --query tenantId` |
| `<APIM_RESOURCE_GROUP>` | Resource group holding the instance | Azure portal, Overview blade |
| `<APIM_NAME>` | API Management instance name | Azure portal, Overview blade |
| `<APIM_TIER>` | SKU and capacity units | `sku` in the policy audit output |
| `<REGION>` | Region the instance runs in | Azure portal, Overview blade |
| `<API_ID>` | Identifier of the API fronting Azure AI Search | Azure portal, APIs blade, or `apiId` in the audit output |
| `<OPERATION_ID>` | Operation the connector calls | Gateway logs, field `OperationName` |
| `<POLICY_SCOPES_AUDITED>` | Which scopes were read: global, product, API, operation | Policy audit output |
| `<DENIAL_ELEMENTS_FOUND>` | Denial elements the audit found, or none | Policy audit output |
| `<GATEWAY_403_COUNT>` | Count of gateway-originated 403 responses in the window | [kql/20-apim-403-triage.kql](../kql/20-apim-403-triage.kql) |
| `<BACKEND_403_COUNT>` | Count of backend-originated 403 responses in the same window | Same query |
| `<LAST_ERROR_SOURCE>` | `LastErrorSource` value on the failing requests | Same query |
| `<LAST_ERROR_REASON>` | `LastErrorReason` value | Same query |
| `<LAST_ERROR_SCOPE>` | `LastErrorScope` value | Same query |
| `<LAST_ERROR_SECTION>` | `LastErrorSection` value | Same query |
| `<LAST_ERROR_MESSAGE>` | Sample `LastErrorMessage` text | Same query |
| `<FAILURE_TIMESTAMP_1>` through `<FAILURE_TIMESTAMP_3>` | UTC timestamps of individual failures | Same query |
| `<CORRELATION_ID_1>` through `<CORRELATION_ID_3>` | `CorrelationId` per failure | Gateway logs |
| `<CALLER_IP_SET>` | Distinct caller IP addresses on the failing requests | Gateway logs, field `CallerIpAddress` |
| `<SUBSCRIPTION_KEY_SCOPE>` | Which API Management product and subscription the connector uses | API Management, Subscriptions blade |
| `<AZURE_CASE_NUMBER>` | Azure AI Search case number | The Azure case filed first, from [azure-ai-search-ticket.md](azure-ai-search-ticket.md) |
| `<PP_CASE_NUMBER>` | Copilot Studio case number | From [copilot-studio-ticket.md](copilot-studio-ticket.md) |

Run the policy audit before filling this table:

```powershell
./scripts/Get-ApimPolicyAudit.ps1 `
  -ResourceGroupName '<APIM_RESOURCE_GROUP>' `
  -ServiceName '<APIM_NAME>' `
  -ApiId '<API_ID>' `
  -OutputPath './evidence/apim-policy-audit.json'
```

## Where to file this

| Field | Value |
|-------|-------|
| Portal | <https://portal.azure.com> |
| Entry point | The API Management instance, then Help, then Support plus Troubleshooting |
| Issue type | Technical |
| Service | API Management, as a separate case from the Azure AI Search one |
| Subscription | `<SUBSCRIPTION_ID>` |
| Severity | B, moderate business impact |
| Advanced diagnostic information | Yes |

This is a third case, not an addition to the Azure AI Search one. Folding an API Management question into a search service case routes it to the wrong engineering team, and the two products have separate support queues even inside the same portal.

## What is known and what is being asked

| Established | Basis |
|-------------|-------|
| `quota` and `quota-by-key` are the only API Management throttling policies that return 403 | [Quota policy](https://learn.microsoft.com/en-us/azure/api-management/quota-policy) |
| `rate-limit` returns 429, not 403 | [Rate limit policy](https://learn.microsoft.com/en-us/azure/api-management/rate-limit-policy) |
| A missing or invalid subscription key returns 401, not 403 | [Subscriptions in API Management](https://learn.microsoft.com/en-us/azure/api-management/api-management-subscriptions) |
| `ip-filter` denies with `CallerIpNotAllowed` or `CallerIpBlocked` | [Error handling in policies](https://learn.microsoft.com/en-us/azure/api-management/api-management-error-handling-policies) |
| `validate-jwt` defaults to 401 but can be set to 403 through `failed-validation-httpcode` | [Validate JWT policy](https://learn.microsoft.com/en-us/azure/api-management/validate-jwt-policy) |
| The agent issues seven concurrent calls per user turn | Seven knowledge sources, all queried every turn |

| Being asked | Why only Microsoft can answer |
|-------------|-------------------------------|
| Which policy or gateway behavior produced the 403 the logs attribute to the gateway | The error attribution fields need interpreting against the instance's internal state |
| Whether a seven-call burst per turn can trip a quota counter in an unexpected way | Counter behavior under burst is not fully documented |
| Whether any gateway-level throttling applies outside the configured policies | Platform limits on the tier are not visible to the customer |

**Inferred:** a seven-call burst per user turn is exactly the traffic shape that trips a call-count quota, because the quota counts calls rather than the user turns that produce them. A quota sized against expected user volume would be exceeded sevenfold without anybody expecting it. This is reasoning about the traffic pattern, not a documented statement about how the quota policy behaves. The full ranked hypothesis list is in [docs/rca-403-connector-triage.md](../docs/rca-403-connector-triage.md).

## Case title

```text
API Management returning HTTP 403 to a Copilot Studio connector with no backend 403 behind it; request policy and gateway attribution for the denial
```

## Problem description

```text
SUMMARY
Our API Management instance fronts an Azure AI Search service that a Microsoft Copilot Studio
agent queries through the Azure AI Search connector. We are seeing recurring HTTP 403 responses
reaching the connector.

Gateway log analysis attributes these to API Management rather than to the search backend:
  - Requests where ResponseCode = 403 and no backend 403 is recorded: <GATEWAY_403_COUNT>
  - Requests where BackendResponseCode = 403: <BACKEND_403_COUNT>

We are asking you to identify which policy or gateway behavior produced the gateway-attributed
403 responses, and how to remediate it.

ENVIRONMENT
- API Management instance: <APIM_NAME>
- Resource ID: /subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<APIM_RESOURCE_GROUP>/providers/Microsoft.ApiManagement/service/<APIM_NAME>
- Subscription ID: <SUBSCRIPTION_ID>
- Tenant ID: <TENANT_ID>
- Region: <REGION>
- SKU and capacity: <APIM_TIER>
- API fronting Azure AI Search: <API_ID>
- Operation called by the connector: <OPERATION_ID>
- Product and subscription the connector uses: <SUBSCRIPTION_KEY_SCOPE>
- Caller: Microsoft Copilot Studio via the shared Azure AI Search connector. Caller IPs observed
  on the failing requests: <CALLER_IP_SET>

TRAFFIC PATTERN
A single end-user turn in the Copilot Studio agent fans out to 7 Azure AI Search indexes, so one
user turn produces approximately 7 concurrent calls through this gateway. Measured end-user load
is approximately 7 to 15 users per hour, which means the gateway sees roughly seven times that
call volume in short bursts rather than a steady rate.

GATEWAY LOG FINDINGS
From ApiManagementGatewayLogs over the failure windows:
- LastErrorSource:  <LAST_ERROR_SOURCE>
- LastErrorReason:  <LAST_ERROR_REASON>
- LastErrorScope:   <LAST_ERROR_SCOPE>
- LastErrorSection: <LAST_ERROR_SECTION>
- Sample LastErrorMessage: <LAST_ERROR_MESSAGE>

Occurrences, all times UTC:
1. <FAILURE_TIMESTAMP_1> - CorrelationId: <CORRELATION_ID_1>
2. <FAILURE_TIMESTAMP_2> - CorrelationId: <CORRELATION_ID_2>
3. <FAILURE_TIMESTAMP_3> - CorrelationId: <CORRELATION_ID_3>

POLICY AUDIT ALREADY PERFORMED
We read the policy XML at these scopes: <POLICY_SCOPES_AUDITED>
Denial elements found: <DENIAL_ELEMENTS_FOUND>
The full policy audit output is attached, sanitised.

We have already eliminated the following on the basis of Microsoft documentation:
- A missing or invalid subscription key, because
  https://learn.microsoft.com/en-us/azure/api-management/api-management-subscriptions documents
  that condition as returning 401, not 403.
- A rate-limit or rate-limit-by-key policy, because
  https://learn.microsoft.com/en-us/azure/api-management/rate-limit-policy documents those as
  returning 429.
- The Azure AI Search backend as the source, on the gateway log attribution above. Azure AI Search
  does return 403 for authorization and network policy denial per
  https://learn.microsoft.com/en-us/rest/api/searchservice/http-status-codes, but the logs show
  these particular rejections did not reach it.

WHAT WE ARE ASKING FOR

1. Identify which policy, or which gateway-level behavior outside our configured policies,
   produced the 403 responses attributed to API Management in the gateway logs. Interpret the
   LastError fields above against the instance state, since we can read the values but not what
   they imply internally.

2. Confirm whether a burst of 7 concurrent calls arising from a single user action can trip a
   quota or quota-by-key counter in a way that a quota sized against user volume would not
   anticipate. We want to understand the counter behavior under burst, not only under sustained
   rate.

3. Confirm whether any throttling or protection applies at this SKU outside the policies we
   configured, and whether any of it surfaces as 403 rather than 429.

4. Confirm the correlation path we should use to join a gateway log entry to the Azure AI Search
   request behind it, so we can attribute future failures ourselves without opening a case.

ATTACHED, AS A SINGLE ARCHIVE
- API Management policy audit output covering all scopes (JSON, sanitised)
- ApiManagementGatewayLogs export for the failure windows
- Policy XML at global, product, API and operation scope (sanitised)
- Application Insights export of the connector dependency records for the same windows
- Full response headers captured from a failing 403
- Diagnostic setting configuration for the instance

RELATED CASES
Azure AI Search case covering the HTTP 206 semantic capacity behavior on the backend:
<AZURE_CASE_NUMBER>
Copilot Studio case covering error 613 and the connector-side failures: <PP_CASE_NUMBER>
```

## Evidence checklist

### Instance facts

* [ ] Instance name, full resource ID, subscription, tenant, and region
* [ ] SKU and capacity units, with the Consumption tier explicitly confirmed or excluded
* [ ] API identifier and the operation the connector calls
* [ ] Product and subscription the connector's credential belongs to
* [ ] Policy XML at global, product, API, and operation scope, sanitised of keys and secrets
* [ ] Every denial element found, with its configuration

All of these appear in the JSON produced by [scripts/Get-ApimPolicyAudit.ps1](../scripts/Get-ApimPolicyAudit.ps1). Attach that file rather than retyping the values.

### Attribution evidence

* [ ] The attribution result from [kql/20-apim-403-triage.kql](../kql/20-apim-403-triage.kql), showing the gateway and backend 403 counts side by side
* [ ] `LastErrorSource`, `LastErrorReason`, `LastErrorScope`, and `LastErrorSection` for the failing requests
* [ ] A sample `LastErrorMessage`
* [ ] At least three UTC timestamps with correlation identifiers
* [ ] Caller IP addresses observed on the failing requests
* [ ] Full response headers from a failing 403, noting whether `x-ms-request-id` is present

### Elimination evidence

* [ ] Per-index distribution from [kql/22-connector-403-by-index.kql](../kql/22-connector-403-by-index.kql), showing the 403s are not concentrated on one index
* [ ] Allow-list coverage from [scripts/Compare-ConnectorEgressPrefixes.ps1](../scripts/Compare-ConnectorEgressPrefixes.ps1), showing the search service allow-list is not the cause
* [ ] Confirmation that no `on-error` section is rewriting a different status code into 403

> [!NOTE]
> The absence of an `on-error` section matters in both directions. Without one, callers receive generic responses and the gateway logs carry no useful error attribution, which weakens the case. With one, a status code may be rewritten, and a 403 reaching the connector may not be the code the policy originally produced. Report which is true rather than leaving it implicit.

### Pre-flight

* [ ] Azure Service Health checked for API Management incidents in the region across the failure windows
* [ ] Support plan confirmed active, and the filer holds Owner, Contributor, or Support Request Contributor at subscription scope
* [ ] Policy XML sanitised of subscription keys, client secrets, certificates, and named values
* [ ] Azure AI Search case number and Copilot Studio case number available for cross-reference
* [ ] Advanced diagnostic information set to Yes

## What to expect

Expect the engineer to start from the `LastError` fields, because they carry the attribution the customer cannot interpret. Supplying all four fields plus a sample message at filing is what makes the first response useful rather than a request for data.

If the answer turns out to be a quota policy, the remedy is a customer-side change and the case closes quickly. That is a good outcome and it is worth reaching fast, which is why the policy audit runs before the case rather than during it.

If the gateway logs attribute the 403 to the backend after all, close this case and move the evidence to the Azure AI Search case instead. The attribution query is designed to be run again as evidence accumulates, and a shift in attribution is a finding rather than a setback.

## Related material

| Document | Contribution |
|----------|--------------|
| [README.md](README.md) | Routing, sequencing, and why this case is third rather than first |
| [docs/rca-403-connector-triage.md](../docs/rca-403-connector-triage.md) | The ranked hypotheses, including the ruled-out list this case reproduces |
| [kql/README.md](../kql/README.md) | Why the attribution query bisects the hypothesis space in one pass |
| [azure-ai-search-ticket.md](azure-ai-search-ticket.md) | The case filed first, whose number this one cross-references |
| [copilot-studio-ticket.md](copilot-studio-ticket.md) | The connector-side case, filed second |
| [assets/meetingNotes.md](../assets/meetingNotes.md) | API Management placement in the request path and the connector visibility limits |
