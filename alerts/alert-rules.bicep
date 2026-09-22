// =============================================================================
// alert-rules.bicep
// Six alert rules for the Azure AI Search 206 partial responses and the
// Copilot Studio connector 403 errors.
// =============================================================================
//
// EVERY THRESHOLD BELOW IS AN ENGINEERING RECOMMENDATION.
//   Microsoft publishes no threshold for an acceptable 206 rate, no threshold
//   for a connector 403 rate, and no guidance on normal fan-out. The Search
//   monitoring documentation says "user-specified threshold" throughout.
//   Deploy these with `enableAlerting = false`, collect two weeks of the
//   customer's own production telemetry, re-baseline every threshold parameter,
//   and only then enable paging. See alerts/alert-rules.md.
//
// ALERTS ON UNCONFIGURED SOURCES NEVER FIRE.
//   Each rule names its prerequisite in its description. A rule whose source
//   table was never populated stays silently healthy forever. Run
//   scripts/Enable-DiagnosticSettings.ps1 before trusting silence.
//
// QUERY PROVENANCE
//   Each log rule below names the kql/ file it derives from. The filter,
//   extend, and summarize lines are byte-identical to that file. Three classes
//   of line are removed because a scheduled query rule supplies them itself:
//   the `let lookback` declaration, the `| where TimeGenerated > ago(lookback)`
//   window filter, and any `| render` or `| order by` presentation clause.
//   A threshold predicate is added as the final line. alerts/alert-rules.md
//   records the transformation per rule.
// =============================================================================

targetScope = 'resourceGroup'

// --- Scope -------------------------------------------------------------------

@description('Region for the scheduled query rules. Metric alerts are always global.')
param location string = resourceGroup().location

@description('Prefix applied to every rule name so repeated deployments do not collide.')
param namePrefix string = 'ai-search'

@description('Resource ID of the Log Analytics workspace receiving the Azure AI Search and API Management diagnostic settings.')
param logAnalyticsWorkspaceId string

@description('Resource ID of the Application Insights component receiving the Copilot Studio telemetry export. Shared with Azure AI Search and the Functions ingestion pipeline in this environment, which is why rule AR-02 scopes its denominator explicitly.')
param appInsightsId string

@description('Resource ID of the Azure AI Search service. Used by the two metric alerts.')
param searchServiceId string

@description('Resource ID of an existing action group. Leave empty to deploy the rules with no notification target, which is the recommended state during the two-week baseline.')
param actionGroupId string = ''

// --- Global switches ---------------------------------------------------------

@description('Set to false to deploy every rule disabled. Recommended for the initial deployment so thresholds can be re-baselined before anyone is paged.')
param enableAlerting bool = false

@description('Set to true only if a source table may not exist yet. Skipping validation lets a rule deploy against a table that was never populated, which then never fires. Leaving it false makes a missing prerequisite fail the deployment loudly instead.')
param skipQueryValidation bool = false

// --- Thresholds: re-baseline all of these before enabling --------------------

@description('AR-01. Minimum number of 206 partial responses at the APIM gateway in the evaluation window before alerting. Starting point: 0, meaning any occurrence alerts.')
param semanticPartialCountThreshold int = 0

@description('AR-02. Minimum absolute count of connector 403 errors in the evaluation window before alerting.')
param connector403CountThreshold int = 10

@description('AR-02. Minimum connector 403 rate as a percentage of scoped connector calls before alerting.')
param connector403PercentThreshold int = 1

@description('AR-03. Throttled search queries percentage that constitutes a critical condition.')
param throttleCriticalPercent int = 5

@description('AR-04. Throttled search queries percentage that constitutes a warning condition.')
param throttleWarningPercent int = 1

@description('AR-05. Query p95 latency in milliseconds that constitutes a regression.')
param searchLatencyP95Ms int = 1000

@description('AR-05 and AR-06. Minimum query count per group before a percentile is trusted. Guards against firing on a handful of samples.')
param minimumQuerySample int = 20

@description('AR-06. Multiple of the rolling baseline p95 that query latency must exceed while indexing is active.')
param contentionBaselineMultiplier int = 2

// --- Derived -----------------------------------------------------------------

var actionGroups = empty(actionGroupId) ? [] : [actionGroupId]
var metricActions = empty(actionGroupId) ? [] : [
  {
    actionGroupId: actionGroupId
  }
]

// =============================================================================
// AR-01  Semantic partial response (206) at the APIM gateway
// Severity 2
// Source: kql/21-apim-206-semantic-partial-capture.kql
// =============================================================================
// WHAT IT DETECTS
//   Any HTTP 206 crossing the gateway on the path to Azure AI Search. A 206 is
//   a query that returned base results without semantic re-ranking, which the
//   user experiences as a worse or empty answer rather than as an error.
//
// WHY APIM AND NOT SEARCH
//   @search.semanticPartialResponseReason is not in the Azure AI Search
//   resource-log schema. The documented Properties sub-schema contains four
//   fields only: Description_s, Documents_d, IndexName_s, Query_s. The reason
//   string exists only in the HTTP response body, and APIM is the sole
//   component in the path that can capture it.
//
// PREREQUISITE, AND IT IS HARD
//   GatewayLogs on a non-Consumption APIM tier, WITH RESPONSE-BODY LOGGING
//   ENABLED. Without body logging the rule still fires on the status code but
//   the Reasons column is empty, which removes the reason that makes the alert
//   actionable. Consumption tier emits no resource logs at all and this rule
//   can never fire there.
//
// THRESHOLD RATIONALE
//   Starting point is any occurrence, because at the time of writing the
//   population size is unknown and a single CapacityOverloaded reason is
//   enough to justify a support ticket. Expect this to be noisy if the reason
//   turns out to be Transient. Re-baseline to a rate rather than a count once
//   two weeks of data exist.
resource ar01SemanticPartial206 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: '${namePrefix}-ar-01-semantic-partial-206-apim'
  location: location
  properties: {
    displayName: 'AR-01 Semantic partial response (206) at APIM'
    description: 'Fires when Azure AI Search returns HTTP 206 through the APIM gateway, meaning the semantic ranker returned base results without re-ranking. Requires APIM GatewayLogs with response-body logging on a non-Consumption tier; without it this rule never fires. Threshold is an engineering recommendation, not a Microsoft-published value. Re-baseline against two weeks of production telemetry. Source query: kql/21-apim-206-semantic-partial-capture.kql'
    severity: 2
    enabled: enableAlerting
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    scopes: [
      logAnalyticsWorkspaceId
    ]
    criteria: {
      allOf: [
        {
          query: '''
ApiManagementGatewayLogs
| where ResponseCode == 206 or BackendResponseCode == 206
| extend
    PartialReason = extract(@"semanticPartialResponseReason""\s*:\s*""([^""]+)""", 1, tostring(BackendResponseBody)),
    PartialType   = extract(@"semanticPartialResponseType""\s*:\s*""([^""]+)""", 1, tostring(BackendResponseBody))
| summarize
    Count        = count(),
    Reasons      = make_set(PartialReason, 10),
    Types        = make_set(PartialType, 10),
    Apis         = make_set(ApiId, 10),
    AvgBackendMs = round(avg(BackendTime), 1),
    P95BackendMs = round(percentile(BackendTime, 95), 1),
    FirstSeen    = min(TimeGenerated),
    LastSeen     = max(TimeGenerated)
| where Count > ${semanticPartialCountThreshold}
'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    skipQueryValidation: skipQueryValidation
    actions: {
      actionGroups: actionGroups
    }
  }
}

// =============================================================================
// AR-02  Copilot Studio connector 403 rate
// Severity 1
// Source: kql/23-design-mode-vs-published.kql (scoping and countif shape)
//         kql/22-connector-403-by-index.kql   (target scoping)
// =============================================================================
// WHAT IT DETECTS
//   Authorization or network-policy denial of the Copilot Studio connector
//   calling Azure AI Search. Azure AI Search does not return 403 for quota and
//   does not return 403 for storage exhaustion, so a 403 here is never
//   transient-benign.
//
// SCOPING, AND WHY IT IS NOT OPTIONAL
//   The Application Insights component is shared across Copilot Studio, Azure
//   AI Search, and the Functions ingestion pipeline. An unscoped ratio would
//   put every Function App call into the denominator and the rate would never
//   reach one percent no matter how badly the connector was failing. Three
//   filters scope it: type == "Connector", name == "Azure AI Search", and
//   target has "shared_azureaisearch". All three literals come from the
//   sampled customer record and are UNVERIFIED against Microsoft
//   documentation, which publishes a different span shape. Run
//   kql/00-discover-dependency-types.kql and substitute whatever it reports
//   before enabling this rule.
//
// TEST TRAFFIC IS EXCLUDED
//   DesignMode "True" means a maker was testing in the authoring canvas.
//   Including it lets maker testing page the on-call.
//
// PREREQUISITE
//   Copilot Studio telemetry export to Application Insights. If the component
//   has DisableLocalAuth set, the export fails silently and this rule never
//   fires while the connector is failing.
//
// THRESHOLD RATIONALE
//   The OR of an absolute count and a rate covers both shapes of failure: a
//   low-traffic period where ten errors is a small percentage, and a
//   high-traffic period where one percent is a large absolute number.
resource ar02Connector403 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: '${namePrefix}-ar-02-connector-403-rate'
  location: location
  properties: {
    displayName: 'AR-02 Copilot Studio connector 403 rate'
    description: 'Fires when the Copilot Studio connector to Azure AI Search returns HTTP 403 above an absolute count or a rate. The denominator is scoped to Copilot Studio connector dependencies because the Application Insights component is shared with Azure AI Search and the Functions ingestion pipeline. Authoring-canvas test traffic is excluded. Requires the Copilot Studio telemetry export; DisableLocalAuth on the component makes that export fail silently and this rule never fires. Thresholds are engineering recommendations, not Microsoft-published values. Re-baseline against two weeks of production telemetry. Source query: kql/23-design-mode-vs-published.kql'
    severity: 1
    enabled: enableAlerting
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    scopes: [
      appInsightsId
    ]
    criteria: {
      allOf: [
        {
          query: '''
dependencies
| where type == "Connector"                  // UNVERIFIED, from the sampled record
| where name == "Azure AI Search"            // UNVERIFIED, from the sampled record
| where target has "shared_azureaisearch"    // scopes the denominator to the Copilot Studio connector
| extend DesignMode = tostring(customDimensions["attributes.DesignMode"])   // UNVERIFIED
| where DesignMode !~ "True"                 // exclude authoring-canvas test traffic
| summarize
    Calls     = count(),
    Forbidden = countif(resultCode == "403")
| extend ForbiddenPct = round(100.0 * Forbidden / Calls, 2)
| where Forbidden > ${connector403CountThreshold} or ForbiddenPct > ${connector403PercentThreshold}
'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    skipQueryValidation: skipQueryValidation
    actions: {
      actionGroups: actionGroups
    }
  }
}

// =============================================================================
// AR-03  Search throttling, critical
// Severity 1
// Metric alert. No source query: ThrottledSearchQueriesPercentage is a
// platform metric with no resource-log equivalent.
// =============================================================================
// WHAT IT DETECTS
//   Sustained rejection of search queries by the service. This is Microsoft's
//   own documented primary capacity signal for Azure AI Search.
//
// WHAT IT DOES NOT DETECT
//   The 206 partial responses. The semantic ranker signals capacity pressure
//   with 206, not with 429, and 206 never reaches this metric. A flat zero
//   here alongside user complaints is the expected shape of this incident, not
//   evidence against a capacity problem. AR-01 is the rule that sees it.
//
// PREREQUISITE
//   AllMetrics on the Search diagnostic setting is not required for metric
//   alerts, which read the metric directly. The rule works as soon as the
//   service exists.
//
// THRESHOLD RATIONALE
//   Five percent of queries being dropped is user-visible degradation at any
//   fan-out, and at seven queries per turn it means a materially higher
//   proportion of turns are degraded than the raw figure suggests.
resource ar03ThrottleCritical 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${namePrefix}-ar-03-search-throttling-critical'
  location: 'global'
  properties: {
    description: 'Fires when the throttled search queries percentage exceeds the critical threshold. Microsoft documents throttling and latency as the two most commonly used Azure AI Search alerts but publishes no numeric threshold for either. This value is an engineering recommendation. Re-baseline against two weeks of production telemetry. Note that this metric never sees the 206 semantic partial responses; AR-01 covers those.'
    severity: 1
    enabled: enableAlerting
    scopes: [
      searchServiceId
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'ThrottledSearchQueriesPercentageCritical'
          criterionType: 'StaticThresholdCriterion'
          metricNamespace: 'Microsoft.Search/searchServices'
          metricName: 'ThrottledSearchQueriesPercentage'
          operator: 'GreaterThan'
          threshold: throttleCriticalPercent
          timeAggregation: 'Average'
        }
      ]
    }
    autoMitigate: true
    actions: metricActions
  }
}

// =============================================================================
// AR-04  Search throttling, warning
// Severity 3
// Metric alert. Same signal as AR-03 at a lower threshold and a wider window.
// =============================================================================
// THRESHOLD RATIONALE
//   One percent is the point at which throttling stops being noise. At seven
//   concurrent queries per turn a one percent per-query drop rate touches
//   roughly seven percent of turns, so the user-visible rate is several times
//   the metric value. That multiplier is the reason this rule exists at a
//   threshold most workloads would consider negligible.
resource ar04ThrottleWarning 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${namePrefix}-ar-04-search-throttling-warning'
  location: 'global'
  properties: {
    description: 'Fires when the throttled search queries percentage exceeds the warning threshold. Set below the usual noise floor deliberately: at seven concurrent queries per user turn, a one percent per-query drop rate degrades a far larger share of turns. This value is an engineering recommendation, not a Microsoft-published threshold. Re-baseline against two weeks of production telemetry.'
    severity: 3
    enabled: enableAlerting
    scopes: [
      searchServiceId
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'ThrottledSearchQueriesPercentageWarning'
          criterionType: 'StaticThresholdCriterion'
          metricNamespace: 'Microsoft.Search/searchServices'
          metricName: 'ThrottledSearchQueriesPercentage'
          operator: 'GreaterThan'
          threshold: throttleWarningPercent
          timeAggregation: 'Average'
        }
      ]
    }
    autoMitigate: true
    actions: metricActions
  }
}

// =============================================================================
// AR-05  Search query p95 latency regression, per index
// Severity 2
// Source: kql/11-search-by-http-result-code.kql (operation filter)
//         kql/10-fan-out-ratio.kql companion    (P95Ms expression)
// =============================================================================
// WHY A LOG RULE AND NOT THE SearchLatency METRIC
//   The metric carries no percentile aggregation and no index dimension. This
//   workload has seven indexes and the interesting failure mode is one index
//   degrading while the service average stays flat, which the metric cannot
//   express. Add a metric alert on SearchLatency as a cheap backstop if the
//   log-ingestion dependency is a concern.
//
// PREREQUISITE
//   Search diagnostic setting sending OperationLogs to the workspace.
//
// THRESHOLD RATIONALE
//   One second p95 is a conversational-latency judgement, not a Microsoft
//   figure. The agent waits on all seven queries before it can answer, so
//   per-index p95 understates the turn latency the user actually feels. The
//   minimum sample guard exists so a quiet index with three slow queries does
//   not page anyone.
resource ar05SearchLatencyP95 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: '${namePrefix}-ar-05-search-latency-p95'
  location: location
  properties: {
    displayName: 'AR-05 Search query p95 latency regression'
    description: 'Fires when any index exceeds the p95 query latency threshold over the evaluation window. Log-based rather than metric-based because the SearchLatency metric carries neither a percentile aggregation nor an index dimension, and one index degrading while the service average stays flat is the failure mode that matters here. Requires the Search diagnostic setting with OperationLogs. Threshold is an engineering recommendation, not a Microsoft-published value. Re-baseline against two weeks of production telemetry. Source query: kql/11-search-by-http-result-code.kql'
    severity: 2
    enabled: enableAlerting
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    scopes: [
      logAnalyticsWorkspaceId
    ]
    criteria: {
      allOf: [
        {
          query: '''
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.SEARCH"
| where OperationName in ("Query.Search", "Query.Suggest", "Query.Lookup", "Query.Autocomplete")
| summarize
    P95Ms   = round(percentile(DurationMs, 95), 1),
    Queries = count()
    by IndexName_s
| where Queries >= ${minimumQuerySample}
| where P95Ms > ${searchLatencyP95Ms}
'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    skipQueryValidation: skipQueryValidation
    actions: {
      actionGroups: actionGroups
    }
  }
}

// =============================================================================
// AR-06  Ingestion and query contention
// Severity 2
// Source: kql/12-semantic-capacity-headroom.kql, companion C
// =============================================================================
// WHAT IT DETECTS
//   Indexing operations and degraded query latency landing in the same time
//   bucket. The ingestion pipeline and the agent share the same search units
//   and Azure AI Search applies no prioritization between them, so an indexer
//   running during business hours competes directly with user queries.
//
// WHY A ROLLING BASELINE RATHER THAN A FIXED NUMBER
//   Absolute latency thresholds fail on workloads whose normal latency varies
//   by index and by time of day. Comparing against the trailing 24-hour p95,
//   excluding the last hour so the current incident does not inflate its own
//   baseline, makes the rule portable across tiers and across the fan-out
//   reduction work that will change the baseline anyway.
//
// A NOTE ON THE LAG
//   Microsoft's own worked example describes roughly three minutes for
//   indexing to begin affecting query latency, and another three minutes to
//   drain afterwards. The five-minute bucket and fifteen-minute window are
//   sized to contain that lag rather than to split it across evaluations.
//
// PREREQUISITE
//   Search diagnostic setting sending OperationLogs. Needs at least 24 hours
//   of history before the baseline is meaningful.
//
// THRESHOLD RATIONALE
//   Two times baseline is a deliberately coarse signal intended to catch
//   contention rather than to measure it. Tighten it only after the fan-out
//   reduction work lands, because until then the baseline itself is inflated.
resource ar06IngestionContention 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: '${namePrefix}-ar-06-ingestion-query-contention'
  location: location
  properties: {
    displayName: 'AR-06 Ingestion and query contention'
    description: 'Fires when indexing operations and a query p95 above a multiple of the rolling baseline occur in the same five-minute bucket. Ingestion and queries share search units with no prioritization, so an indexer running in business hours competes with user queries. The baseline deliberately excludes the last hour so a live incident cannot inflate its own comparison. Requires the Search diagnostic setting with OperationLogs and at least 24 hours of history. Threshold is an engineering recommendation, not a Microsoft-published value. Re-baseline against two weeks of production telemetry. Source query: kql/12-semantic-capacity-headroom.kql companion C'
    severity: 2
    enabled: enableAlerting
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    scopes: [
      logAnalyticsWorkspaceId
    ]
    criteria: {
      allOf: [
        {
          query: '''
// The baseline intentionally reaches outside the alert window. ago(1h) excludes
// the current incident so it cannot inflate the figure it is measured against.
let baselineP95Ms = toscalar(
    AzureDiagnostics
    | where TimeGenerated between (ago(24h) .. ago(1h))
    | where ResourceProvider == "MICROSOFT.SEARCH"
    | where OperationName in ("Query.Search", "Query.Suggest", "Query.Lookup", "Query.Autocomplete")
    | summarize percentile(DurationMs, 95));
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.SEARCH"
| summarize
    IndexingOps = countif(OperationName startswith "Indexing." or OperationName startswith "Indexers."),
    QueryOps    = countif(OperationName in ("Query.Search", "Query.Suggest", "Query.Lookup", "Query.Autocomplete")),
    QueryP95Ms  = round(percentile(DurationMs, 95), 1)
    by bin(TimeGenerated, 5m)
| extend BaselineP95Ms = baselineP95Ms
| where IndexingOps > 0
| where QueryOps >= ${minimumQuerySample}
| where QueryP95Ms > ${contentionBaselineMultiplier} * BaselineP95Ms
'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    skipQueryValidation: skipQueryValidation
    actions: {
      actionGroups: actionGroups
    }
  }
}

// --- Outputs -----------------------------------------------------------------

@description('Names of the deployed rules, in the order they are documented in alerts/alert-rules.md.')
output ruleNames array = [
  ar01SemanticPartial206.name
  ar02Connector403.name
  ar03ThrottleCritical.name
  ar04ThrottleWarning.name
  ar05SearchLatencyP95.name
  ar06IngestionContention.name
]

@description('True when the rules were deployed in the enabled state. Expect false on the initial deployment.')
output alertingEnabled bool = enableAlerting
