---
title: "Triage Guide: 403 Forbidden on the Azure AI Search Connector"
description: Ranked hypotheses and discriminating tests for the 613 HTTP 403 failures on the Copilot Studio Azure AI Search connector, including why the Basic to S1 tier change does not explain them.
author: Azure AI Search Scaling Engagement
ms.date: 2026-09-22
ms.topic: troubleshooting
keywords:
  - azure ai search
  - api management
  - copilot studio connector
  - http 403
  - authorization
estimated_reading_time: 14
---

## Summary

**The 403 errors and the 206 partial responses are two independent problems.** They share a timeline and an architecture, and nothing else. Treating them as one incident will send the investigation, and any support case, in the wrong direction.

Azure AI Search documents HTTP 403 as an **authorization** failure. Quota pressure and low storage return 429. Semantic free-plan exhaustion returns 402. No documented Search mechanism ties service tier to a 403 response. The tier change therefore cannot be the explanation, and the 403s stopping in roughly the same window as the Basic to S1 scale is most plausibly coincidence with a second change made at the same time.

What follows is a ranked hypothesis list. Every entry carries a test that can confirm or eliminate it, because the evidence available today does not single out a cause and asserting one would be guesswork.

> [!IMPORTANT]
> No hypothesis below is confirmed. Each is ranked by how well it fits the observed telemetry and how cheap it is to disprove, not by how likely it is to be correct in some absolute sense. Run the tests before acting.

### How to read this document

Claims that come from Microsoft carry an inline Microsoft Learn link and are quoted where the exact wording matters. Conclusions drawn from the evidence rather than from documentation begin with **Inferred:** and should not be presented to Microsoft support as Microsoft's own position.

## What the status codes actually mean

From [Azure AI Search HTTP status codes](https://learn.microsoft.com/en-us/rest/api/searchservice/http-status-codes):

> `403 Forbidden` - Returned when authorization fails.
>
> `429 Too Many Requests` - [...] If you get this error code on an active index, it usually means that you're running low on storage.

Semantic ranker free-plan exhaustion surfaces as 402, a billing error, not as 403.

| Theory | Verdict | Basis |
| --- | --- | --- |
| Search storage or index quota was exhausted on Basic | Contradicted | Storage pressure returns 429, not 403 |
| Semantic ranker free allowance ran out | Contradicted for the 403s | Free-plan exhaustion returns 402 |
| The Basic tier imposes a request ceiling that returns 403 | Unsupported | No such mechanism is documented for any tier |
| Something in the path refused to authorize the request | Consistent | 403 is documented only for authorization failure |

That last row is the whole investigation. Something in the path declined to authorize these calls, and the work is to determine what.

## Two telemetry tells that narrow the search

The sample dependency record in [assets/usefulScreenshots.md](../assets/usefulScreenshots.md) carries two details that do disproportionate work.

### The failure took 2.5 seconds

The record shows `duration: 2566` milliseconds on a 403. An API Management inbound policy that short-circuits a request, such as a subscription-key check or an `ip-filter` denial, rejects in tens of milliseconds. It never touches the backend.

**Inferred:** 2.5 seconds is the shape of a request that traveled to a backend, waited, and was rejected there. That pushes backend-originated rejections up the ranking and pushes pure inbound-policy denials down. This is a strong signal but not proof, because a slow inbound policy evaluation or a retry inside the connector could also produce that duration.

### Every failure came from the authoring test canvas

The same record shows `DesignMode: "True"` and `channelId: "pva-studio"`. Both indicate the Copilot Studio authoring test canvas rather than a published channel.

If all 613 failures carry those values, production traffic may be entirely healthy and the incident reframes from a customer-facing outage to an authoring-experience defect. That changes severity, changes the support product, and changes urgency. Check it before escalating anything.

## Ranked hypotheses and their discriminating tests

| Rank | Hypothesis | Likelihood | Discriminating test |
| --- | --- | --- | --- |
| 1 | The Search IP firewall allow-list no longer covers every Power Platform connector egress prefix. [Configure network access](https://learn.microsoft.com/en-us/azure/search/service-configure-firewall) states that requests from IP addresses outside the allowed list are rejected with a 403 Forbidden response. Connector egress spans a range of published prefixes that change over time. | High | Read `publicNetworkAccess` and `networkRuleSet.ipRules` on the search service. Compare the entries against the current [connector outbound IP addresses](https://learn.microsoft.com/en-us/connectors/common/outbound-ip-addresses) for the region. Check when the rule set was last edited. |
| 2 | An API Management `quota` or `quota-by-key` policy is being exceeded. The [quota policy](https://learn.microsoft.com/en-us/azure/api-management/quota-policy) is the only API Management throttling policy that returns 403 rather than 429. A seven-call burst per user turn is exactly the traffic shape that trips a call-count quota. | High | Inspect the policy XML at all four scopes for a `<quota>` or `<quota-by-key>` element. |
| 3 | An API Management `ip-filter` policy is denying the caller. The [error handling reference](https://learn.microsoft.com/en-us/azure/api-management/api-management-error-handling-policies) documents `CallerIpNotAllowed` and `CallerIpBlocked` for this policy. Note that with `action` set to `allow`, anything not explicitly listed is denied. | High | Inspect the same policy XML for `<ip-filter>`. Search gateway logs for the two error reasons above. |
| 4 | Role-based access is scoped per index and one index is missing an assignment. Six healthy indexes and one unauthorized index looks intermittent in aggregate and is perfectly deterministic per index. | Medium-High | Group the 403 failures by index name. This is the cheapest hypothesis to disprove and needs no configuration change. |
| 5 | More than one connection instance exists and one of them is broken. The [Azure AI Search connector](https://learn.microsoft.com/en-us/connectors/azureaisearch/) documents its key and OAuth authentication modes as not shareable, so each maker holds a separate connection. That fits the design-mode signature precisely. | Medium-High | Audit the environment's connections for the Azure AI Search connector and check each one's authentication state. |
| 6 | A `validate-jwt` or `check-header` policy is configured to return 403 on failure. The [validate-jwt policy](https://learn.microsoft.com/en-us/azure/api-management/validate-jwt-policy) defaults to 401, but `failed-validation-httpcode` is frequently set to 403 in hardened policies, and an expiring token produces intermittent failures. | Medium | Read the policy XML for `failed-validation-httpcode="403"`. Correlate failures against token lifetime boundaries. |

### Hypotheses ruled out or contradicted

These are retained deliberately. A support engineer will propose them, and having the disproving citation to hand saves a round trip.

| Hypothesis | Status | Disproving citation |
| --- | --- | --- |
| The API Management subscription key is missing, invalid, or was rotated | Ruled out | [Subscriptions in API Management](https://learn.microsoft.com/en-us/azure/api-management/api-management-subscriptions) documents that API Management denies access with a 401, not a 403 |
| An API Management `rate-limit` policy is throttling the seven-call burst | Ruled out as a 403 source | The [rate-limit policy](https://learn.microsoft.com/en-us/azure/api-management/rate-limit-policy) returns 429 Too Many Requests |
| Search storage or index quota was exhausted before the tier change | Contradicted | [HTTP status codes](https://learn.microsoft.com/en-us/rest/api/searchservice/http-status-codes) maps low storage to 429 |
| The semantic ranker free plan ran out | Contradicted for 403 | Free-plan exhaustion returns 402, a billing error |

Rate limiting and quota are the single most commonly confused pair in this failure mode. One returns 429 and one returns 403. That distinction alone eliminates or promotes several hypotheses at once.

## Recommended diagnostic order

Run the first two actions in parallel. They cost almost nothing and between them they eliminate most of the list.

### First: attribute the 403 to API Management or to the backend

Enable `GatewayLogs` on the API Management instance and send them to the shared Log Analytics workspace. The [gateway log schema](https://learn.microsoft.com/en-us/azure/api-management/monitor-api-management-reference) carries two separate status fields, and the difference between them is the entire attribution:

```kusto
// ResponseCode       = what API Management returned to Copilot Studio
// BackendResponseCode = what Azure AI Search returned to API Management
ApiManagementGatewayLogs
| where TimeGenerated > ago(7d)
| where ResponseCode == 403 or BackendResponseCode == 403
| extend Origin403 = case(
      BackendResponseCode == 403, "403 from the Azure AI Search backend",
      ResponseCode == 403 and (isnull(BackendResponseCode) or BackendResponseCode == 0), "403 raised by an API Management policy",
      "403 rewritten by API Management")
| summarize Count = count(), SampleMessage = take_any(LastErrorMessage)
    by Origin403, LastErrorSource, LastErrorReason, LastErrorScope
| order by Count desc
```

A backend-originated 403 points at hypotheses 1, 4, and 5. A policy-raised 403 points at hypotheses 2, 3, and 6. One query bisects the list.

> [!WARNING]
> The API Management Consumption tier supports no resource logs at all. Confirm the instance tier before planning around gateway logs, because on Consumption this diagnostic is unavailable and the investigation has to rely on policy inspection and the design-mode check instead.

### Second: the zero-setup design-mode check

This needs no configuration change and answers a question that could reframe the entire engagement. In Application Insights, count the 403 dependency records by the `DesignMode` attribute. If the result is 100 percent design mode, the published agent was never affected.

### Third: group the failures by index name

If the attribution query is not yet available, grouping the 403s by target index still eliminates hypothesis 4 in a single pass. A clean split, where one index fails and six do not, confirms per-index authorization scoping. An even spread rules it out.

## The coincidence question

The customer must answer one question before anyone accepts a causal story: **what else changed in the same window as the Basic to S1 scale?**

Candidate changes that would each produce exactly this pattern:

* A firewall rule edit on the search service, including a rule set that was rebuilt as part of the tier migration
* An admin key regeneration or a role assignment change
* An API Management policy deployment at any scope
* A new or repaired connection instance created by a maker in the environment

**Inferred:** a tier change is a visible, memorable event, so unrelated fixes applied in the same maintenance window tend to be attributed to it. Nothing in the Azure AI Search documentation supports a causal link between tier and 403, so the burden of proof sits with the coincidence explanation being wrong, not with it being right.

## Open items

| ID | Open question | Why it matters |
| --- | --- | --- |
| U9 | The API Management tier is unknown, and the Consumption tier supports no resource logs | Could invalidate the gateway-log diagnostic plan entirely |
| U10 | Whether Azure AI Search returns a `request-id` header on 403 responses is unconfirmed | Correlation between the connector span and the Search-side record may lose its key on exactly the failing requests |

Two further values are needed from the environment before the ranking can tighten: the search service `publicNetworkAccess` setting with the contents of `networkRuleSet.ipRules`, and the full API Management policy XML at global, product, API, and operation scope.

## Evidence sources

| Source | Contribution |
| --- | --- |
| [assets/usefulScreenshots.md](../assets/usefulScreenshots.md) | The sample 403 dependency record, its duration, and the design-mode attributes |
| [assets/meetingNotes.md](../assets/meetingNotes.md) | API Management placement in the request path, connector visibility limits, observed 403 volume |
| [assets/additionalInfo.md](../assets/additionalInfo.md) | The connector black-box theme and the request-path complexity concern |
| [Azure AI Search HTTP status codes](https://learn.microsoft.com/en-us/rest/api/searchservice/http-status-codes) | 403 means authorization failure, 429 covers throttling and low storage |
| [Configure network access](https://learn.microsoft.com/en-us/azure/search/service-configure-firewall) | The documented 403 for IP addresses outside the allow-list |
| [API Management error handling](https://learn.microsoft.com/en-us/azure/api-management/api-management-error-handling-policies) | Predefined error reasons per policy |
| [Monitor API Management data reference](https://learn.microsoft.com/en-us/azure/api-management/monitor-api-management-reference) | Gateway log schema including the two response-code fields |

For the separate capacity analysis covering the 206 partial responses, see [rca-206-semantic-concurrency.md](rca-206-semantic-concurrency.md).
