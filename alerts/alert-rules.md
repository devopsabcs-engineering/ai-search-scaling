---
title: Alert rules
description: Six Azure Monitor alert rules for the Azure AI Search 206 partial responses and the Copilot Studio connector 403 errors, with the source query, threshold, and threshold rationale for each, plus the re-baselining procedure every one of them requires.
author: Microsoft
ms.date: 2026-09-22
ms.topic: how-to
keywords:
  - azure monitor alerts
  - azure ai search
  - copilot studio
  - api management
  - scheduled query rules
estimated_reading_time: 14
---

> [!IMPORTANT]
> Every threshold in this document is an engineering recommendation. Microsoft publishes no threshold for an acceptable 206 rate, no threshold for a connector 403 rate, and no guidance on what constitutes normal fan-out. The Azure AI Search monitoring documentation says "user-specified threshold" throughout. Each value below is a starting point that requires re-baselining against two weeks of your own production telemetry before anyone is paged on it.

Six rules cover the two problems in this engagement. Four are log rules built on the query library in [kql](../kql/README.md); two are metric alerts on the platform throttling metric, which has no resource-log equivalent. [alert-rules.bicep](alert-rules.bicep) deploys all six.

The default deployment state is disabled. That is deliberate, and it is the subject of [Re-baselining](#re-baselining-before-you-enable-paging) below.

## The rules at a glance

| Rule | Detects | Signal | Condition | Severity | Type |
|---|---|---|---|---|---|
| AR-01 | Semantic ranker returning partial results | `ApiManagementGatewayLogs`, `BackendResponseCode == 206` | `count() > 0` per 15 min | 2 | Log |
| AR-02 | Connector authorization or network denial | `dependencies`, `resultCode == "403"` | `> 1%` of scoped calls or `count() > 10` per 15 min | 1 | Log |
| AR-03 | Search dropping queries, critical | `ThrottledSearchQueriesPercentage` | `> 5%` per 5 min | 1 | Metric |
| AR-04 | Search dropping queries, warning | `ThrottledSearchQueriesPercentage` | `> 1%` per 5 min | 3 | Metric |
| AR-05 | Per-index query latency regression | `AzureDiagnostics`, `DurationMs` | `percentile(DurationMs, 95) > 1000` ms | 2 | Log |
| AR-06 | Indexing competing with queries | `AzureDiagnostics`, composite | indexing ops > 0 and query p95 > 2x baseline in the same bucket | 2 | Log |

AR-01 and AR-02 are the two rules that speak directly to the reported symptoms. AR-03 through AR-06 exist because the investigation keeps surfacing capacity questions that nobody is currently measuring.

## Deploying

```powershell
az deployment group create `
  --resource-group <resource-group> `
  --template-file alerts/alert-rules.bicep `
  --parameters `
    logAnalyticsWorkspaceId=<workspace-resource-id> `
    appInsightsId=<app-insights-resource-id> `
    searchServiceId=<search-service-resource-id>
```

That deploys all six rules disabled, with no action group and no notification target. Nothing fires and nobody is paged. Add `actionGroupId=<action-group-resource-id>` and `enableAlerting=true` once the thresholds have been tuned.

Every threshold is a template parameter, so re-baselining is a redeployment rather than a rewrite.

## AR-01 Semantic partial response at the APIM gateway

What it detects: any HTTP 206 crossing the gateway on the path to Azure AI Search. A 206 is a query that returned base results without semantic re-ranking. The user does not see an error. They see a worse answer, or no answer, which is why this failure mode went undiagnosed long enough to accumulate.

Source query: [kql/21-apim-206-semantic-partial-capture.kql](../kql/21-apim-206-semantic-partial-capture.kql)

Threshold: any occurrence in a 15-minute window, evaluated every 5 minutes. Severity 2.

Why that threshold. The population size is currently unknown, and a single `CapacityOverloaded` reason is on its own sufficient grounds for a support ticket, because Microsoft's documented guidance for workloads at the semantic ranking ceiling is to file one.
Alerting on any occurrence is therefore the right starting posture even though it will be noisy. If the reason turns out to be `Transient` rather than `CapacityOverloaded`, convert this to a rate rather than a count during re-baselining.
The [206 RCA](../docs/rca-206-semantic-concurrency.md) explains why that distinction changes the conclusion.

Prerequisite: APIM `GatewayLogs` on a non-Consumption tier, with response-body logging enabled. The status code alone will fire the rule, but the reason string that makes it actionable lives only in the body. This is the one hard prerequisite in the set: `@search.semanticPartialResponseReason` is absent from the Azure AI Search resource-log schema, whose documented `Properties` sub-schema contains four fields only, so APIM is the sole component in the path that can capture it.

## AR-02 Copilot Studio connector 403 rate

What it detects: authorization or network-policy denial of the connector calling Azure AI Search. Azure AI Search does not return 403 for quota and does not return 403 for storage exhaustion; semantic free-plan exhaustion returns 402. A 403 here is never transient-benign, which is why this is the only severity 1 log rule.

Source query: [kql/23-design-mode-vs-published.kql](../kql/23-design-mode-vs-published.kql), with the target scoping from [kql/22-connector-403-by-index.kql](../kql/22-connector-403-by-index.kql)

Threshold: more than 10 errors, or more than 1% of scoped connector calls, in a 15-minute window, evaluated every 5 minutes. Severity 1.

Why that threshold. The two conditions are an OR because either one alone has a blind spot. An absolute count misses a high-traffic period where a serious failure rate still produces a modest-looking number relative to volume. A percentage misses a quiet period where ten consecutive failures is a real outage and a small fraction of the day's calls. Together they cover both.

### Scoping, and why it is not optional

The Application Insights component in this environment is shared across Copilot Studio, Azure AI Search, and the Functions ingestion pipeline. An unscoped ratio puts every Function App call into the denominator, and the connector failure rate is then diluted to the point where it never reaches 1% no matter how badly the connector is failing. The rule would deploy, look correct, and never fire.

Three filters scope the denominator to Copilot Studio connector dependencies:

```kusto
| where type == "Connector"
| where name == "Azure AI Search"
| where target has "shared_azureaisearch"
```

A fourth filter excludes authoring-canvas test traffic, because maker testing otherwise pages the on-call:

```kusto
| extend DesignMode = tostring(customDimensions["attributes.DesignMode"])
| where DesignMode !~ "True"
```

> [!WARNING]
> All four literals come from the sampled customer record and are unverified against Microsoft documentation, which publishes a different span shape for Copilot Studio environment-level telemetry: `type == "GenAI"`, `name == "ExecuteTool"`, and custom dimension keys prefixed `gen_ai.` rather than `attributes.`.
> Run [kql/00-discover-dependency-types.kql](../kql/00-discover-dependency-types.kql) and substitute whatever it reports before enabling this rule. A rule built on the wrong naming convention matches nothing and stays green through an outage.

Prerequisite: Copilot Studio telemetry export to Application Insights. If the component has `DisableLocalAuth` set, that export fails silently and this rule cannot fire.

## AR-03 Search throttling, critical

What it detects: sustained rejection of search queries by the service. Microsoft documents throttling and query latency as the two most commonly used Azure AI Search alerts.

Signal: the `ThrottledSearchQueriesPercentage` platform metric. No source query, because this metric has no resource-log equivalent.

Threshold: average above 5% over 5 minutes, evaluated every minute. Severity 1.

Why that threshold. Five percent of queries being dropped is user-visible degradation at any fan-out. At seven queries per turn it is considerably worse than it reads, because a turn fails if any of its seven queries is dropped, so the proportion of degraded turns is several times the per-query figure.

### What this rule does not detect

It does not detect the 206 partial responses. The semantic ranker signals capacity pressure with 206, not with 429, and a 206 never reaches this metric. A flat zero on this rule alongside user complaints about poor answers is the expected shape of this incident, not evidence against a capacity problem. AR-01 is the rule that sees it. Reading the two together is what separates "the service is throttling" from "the semantic ranker is saturating," which have different fixes.

Prerequisite: none beyond the service existing. Metric alerts read the metric directly and do not depend on a diagnostic setting.

## AR-04 Search throttling, warning

What it detects: the same signal as AR-03 at a lower threshold.

Signal: the `ThrottledSearchQueriesPercentage` platform metric.

Threshold: average above 1% over 5 minutes, evaluated every 5 minutes. Severity 3.

Why that threshold. One percent sits below the noise floor most workloads would bother with, and that is intentional here. The seven-times fan-out means a 1% per-query drop rate touches roughly 7% of user turns. The multiplier is the entire reason this rule exists at a value that would be negligible in a one-query-per-turn architecture.
If the fan-out reduction work described in [fan-out reduction architecture](../docs/fan-out-reduction-architecture.md) lands, raise this threshold, because the multiplier that justifies it will have gone away.

Prerequisite: none beyond the service existing.

## AR-05 Search query p95 latency regression

What it detects: any single index whose 95th-percentile query latency crosses the threshold, evaluated per index rather than across the service.

Source query: [kql/11-search-by-http-result-code.kql](../kql/11-search-by-http-result-code.kql) for the operation filter, [kql/10-fan-out-ratio.kql](../kql/10-fan-out-ratio.kql) for the percentile expression

Threshold: p95 above 1000 ms for any index with at least 20 queries in a 15-minute window, evaluated every 5 minutes. Severity 2.

Why that threshold. One second at p95 is a conversational-latency judgement rather than a Microsoft figure. The agent waits on all seven queries before it can answer, so per-index p95 understates the latency the user actually experiences: the turn is as slow as its slowest index. The 20-query minimum exists so that a quiet index with three slow queries does not page anyone, which is the most common false positive in percentile-based rules.

Why this is a log rule and not a metric alert. The `SearchLatency` metric carries neither a percentile aggregation nor an index dimension. The failure mode that matters in a seven-index design is one index degrading while the service average stays flat, and the metric cannot express that. Add a metric alert on `SearchLatency` as a cheap backstop if the log-ingestion dependency is a concern; it will catch the service-wide case at lower cost and miss the per-index one.

Prerequisite: Search diagnostic setting sending `OperationLogs` to the workspace.

## AR-06 Ingestion and query contention

What it detects: indexing operations and degraded query latency landing in the same time bucket. The ingestion pipeline and the agent share the same search units, and Azure AI Search applies no prioritization between them, so an indexer running during business hours competes directly with user queries.

Source query: [kql/12-semantic-capacity-headroom.kql](../kql/12-semantic-capacity-headroom.kql), companion C

Threshold: indexing operations above zero, at least 20 queries, and query p95 above 2x the rolling baseline, in the same 5-minute bucket. Evaluated every 5 minutes over a 15-minute window. Severity 2.

Why that threshold. A multiple of a rolling baseline rather than an absolute number, because absolute latency thresholds fail on workloads whose normal latency varies by index and by hour. The baseline is the trailing 24-hour p95 excluding the last hour, so a live incident cannot inflate the figure it is being measured against.
Two times baseline is deliberately coarse: this rule is meant to catch contention, not to measure it. Tighten it only after the fan-out reduction work lands, because until then the baseline is itself inflated by the seven-times amplification.

Why the window is sized the way it is. Microsoft's worked example of this behaviour describes roughly three minutes for indexing to begin affecting query latency, and another three minutes for latency to recover after indexing completes. The 5-minute bucket and 15-minute window contain that lag rather than splitting it across evaluations.

Prerequisite: Search diagnostic setting sending `OperationLogs`, plus at least 24 hours of history before the baseline means anything.

## Prerequisites, and the silent failure they cause

> [!CAUTION]
> An alert rule whose source table was never populated does not fail. It evaluates, matches nothing, and reports healthy indefinitely. Silence from these rules is only meaningful once the prerequisite behind each one is confirmed enabled.

| Rule | Prerequisite | Consequence when missing |
|---|---|---|
| AR-01 | APIM `GatewayLogs`, non-Consumption tier, response-body logging enabled | Never fires. Without body logging it fires without the reason string, which removes most of its value |
| AR-02 | Copilot Studio telemetry export to Application Insights | Never fires. `DisableLocalAuth` on the component makes the export fail silently |
| AR-03 | None | Fires as deployed |
| AR-04 | None | Fires as deployed |
| AR-05 | Search diagnostic setting, `OperationLogs` | Never fires |
| AR-06 | Search diagnostic setting, `OperationLogs`, plus 24 hours of history | Never fires, or fires against an empty baseline |

Two conditions block this plan outright rather than degrading it. APIM on the Consumption tier supports no resource logs at all, which removes AR-01 entirely. An Application Insights component with `DisableLocalAuth` set removes AR-02 entirely.

Run [scripts/Enable-DiagnosticSettings.ps1](../scripts/Enable-DiagnosticSettings.ps1) before deploying. It enables the Search and APIM diagnostic settings and performs both pre-flight checks.

The template deploys with `skipQueryValidation` set to false, so a rule whose source table does not exist fails the deployment with a query validation error rather than deploying into permanent silence. Treat that failure as the prerequisite check it is. Set the parameter to true only when you knowingly want to deploy ahead of the telemetry.

## Re-baselining before you enable paging

Microsoft publishes no thresholds for these signals, so the values above are starting points rather than recommendations you can adopt unchanged. Work through the following before setting `enableAlerting=true`.

1. Deploy the template as-is, disabled, with no action group.
2. Run [scripts/Enable-DiagnosticSettings.ps1](../scripts/Enable-DiagnosticSettings.ps1) and confirm every prerequisite in the table above.
3. Run the discovery queries in [kql/README.md](../kql/README.md) and substitute the real span shape into AR-02 if it differs from the sampled record.
4. Collect two weeks of production telemetry. Two weeks rather than one, so the baseline spans at least two of every weekly cycle and survives a single anomalous day.
5. Run each rule's source query over that window and read the actual distribution rather than the peak.
6. Set each threshold above the observed 95th percentile of normal, not above the observed maximum. A threshold set at the maximum never fires; a threshold set at the mean fires constantly.
7. Redeploy with the tuned threshold parameters, an action group, and `enableAlerting=true`.

Two caveats on the baseline itself. It is being collected from a system that is currently failing, so "normal" includes the failure. And the fan-out reduction work will change every one of these distributions, so plan to repeat this exercise afterwards rather than treating the first tuning as permanent.

## How the alert queries relate to the query library

The alert bodies derive from the `.kql` files rather than duplicating them, because a scheduled query rule supplies some of what a standalone query has to declare for itself. Three classes of line are removed in every case, and one is added:

| Change | Reason |
|---|---|
| `let lookback = ...;` removed | The rule's `windowSize` defines the evaluation window |
| `\| where TimeGenerated > ago(lookback)` removed | Double-filtering the window against itself narrows the rule unpredictably |
| `\| render ...` and `\| order by ...` removed | Presentation clauses have no meaning in a rule evaluation |
| Threshold predicates added as the final lines | The rule fires on row count, so the query must return rows only when the condition is met |

Everything else is byte-identical to the source file. The filter, `extend`, and `summarize` lines in particular are unchanged, which is what keeps the alert and the diagnostic query in agreement.

Two rules carry additions beyond that pattern, both documented in the Bicep:

* AR-02 adds the `target has "shared_azureaisearch"` scoping filter and the `DesignMode` exclusion, for the reasons in [Scoping, and why it is not optional](#scoping-and-why-it-is-not-optional). It also renames the source query's `ForbiddenPctOfOrigin` column to `ForbiddenPct`, because the alert has no origin grouping to qualify the name against.
* AR-06 adds the `let baselineP95Ms = toscalar(...)` block, which intentionally reaches outside the alert window because a baseline must.

When a query changes in [kql](../kql/README.md), change the corresponding rule. Two copies of a diagnostic that disagree are worse than one, because the disagreement surfaces during an incident.

## Related material

* [kql/README.md](../kql/README.md) for the source queries, their run order, and their prerequisites
* [workbooks/README.md](../workbooks/README.md) for the dashboards built on the same queries
* [docs/rca-206-semantic-concurrency.md](../docs/rca-206-semantic-concurrency.md) for what AR-01 is evidence for
* [docs/rca-403-connector-triage.md](../docs/rca-403-connector-triage.md) for what AR-02 is evidence for
* [docs/immediate-mitigations.md](../docs/immediate-mitigations.md) for the interim actions these rules monitor
* [Types of Azure Monitor alerts](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-overview)
* [Microsoft.Insights/scheduledQueryRules template reference](https://learn.microsoft.com/en-us/azure/templates/microsoft.insights/scheduledqueryrules)
* [Common alert schema](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-common-schema)
