#Requires -Version 7.0

<#
.SYNOPSIS
    Collects a read-only capacity and configuration audit of an Azure AI Search service.

.DESCRIPTION
    Gathers every Search-side fact the 206 partial-response root cause analysis and the
    Azure AI Search support ticket depend on, and writes both a console report and a JSON
    file suitable for attaching to a support request.

    The script performs no write operations against Azure. It calls only 'az search service show',
    'az resource show', and 'az monitor diagnostic-settings list'. The only thing it writes is the
    local JSON evidence file.

    Checks are ordered by diagnostic value:

    1. properties.semanticSearch. A value of 'free' caps semantic ranking at 1,000 requests per
       month, which a seven-index fan-out workload exhausts in one to three days. This is checked
       and reported first. Change it with PATCH, never PUT, or the service configuration is
       replaced rather than updated.
    2. Search units (replicas x partitions) and the resulting in-flight semantic capacity,
       compared against the concurrent-request requirement the agent generates per turn.
    3. Network posture: publicNetworkAccess and networkRuleSet.ipRules, which is the input to
       Compare-ConnectorEgressPrefixes.ps1 and the leading 403 hypothesis.
    4. Service creation date. Basic services created before 2024-04-03 cap at one partition and
       three search units, which changes the capacity ceiling.
    5. Whether a diagnostic setting exists and whether it carries both OperationLogs and AllMetrics.

    Semantic ranker throttling limits per search unit are published at
    https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity.

.PARAMETER ResourceGroupName
    Resource group containing the Azure AI Search service.

.PARAMETER ServiceName
    Name of the Azure AI Search service to audit.

.PARAMETER SubscriptionId
    Optional subscription ID. When omitted the current 'az account' context is used.

.PARAMETER RequestsPerTurn
    Number of concurrent search requests the agent issues per conversational turn. Defaults to 7,
    matching the customer's seven knowledge sources, each of which is queried on every turn because
    Copilot Studio only filters knowledge sources above 25.

.PARAMETER ConcurrentTurnTarget
    Number of simultaneous conversational turns the service must sustain. Defaults to 1, which
    tests the minimum viable configuration. Raise it to model peak load.

.PARAMETER ApiVersion
    ARM API version used for the raw resource read that surfaces properties the 'az search'
    command group may not project. Defaults to '2023-11-01'.

.PARAMETER OutputPath
    Path of the JSON evidence file. Defaults to a timestamped file in the current directory.

.EXAMPLE
    ./Get-SearchServiceDiagnostics.ps1 -ResourceGroupName 'rg-search' -ServiceName 'contoso-search'

    Audits the service against the default single-turn, seven-request-per-turn requirement.

.EXAMPLE
    ./Get-SearchServiceDiagnostics.ps1 -ResourceGroupName 'rg-search' -ServiceName 'contoso-search' -ConcurrentTurnTarget 10 -OutputPath './evidence/search-capacity.json'

    Models ten concurrent turns (70 in-flight semantic requests) and writes the evidence file to a
    chosen path for attachment to a support ticket.

.OUTPUTS
    PSCustomObject describing the service configuration, the computed capacity verdict, and the
    telemetry readiness findings. The same object is serialised to the JSON evidence file.

.NOTES
    Requires Azure CLI authenticated with at least Reader on the Search service.
    Read-only. No Azure resource is created, modified, or deleted.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingWriteHost', '',
    Justification = 'This script produces an operator-facing console report where colour carries diagnostic severity.')]
[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ServiceName,

    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [ValidateRange(1, 1000)]
    [int]$RequestsPerTurn = 7,

    [Parameter()]
    [ValidateRange(1, 10000)]
    [int]$ConcurrentTurnTarget = 1,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ApiVersion = '2023-11-01',

    [Parameter()]
    [string]$OutputPath
)

# Semantic ranker throttling limits per search unit.
# Source: https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity
$script:SemanticLimitPerSearchUnit = @{
    'basic'     = [PSCustomObject]@{ Tier = 'Basic'; Concurrent = 2; Queue = 4 }
    'standard'  = [PSCustomObject]@{ Tier = 'S1'; Concurrent = 3; Queue = 6 }
    'standard2' = [PSCustomObject]@{ Tier = 'S2'; Concurrent = 4; Queue = 8 }
    'standard3' = [PSCustomObject]@{ Tier = 'S3'; Concurrent = 4; Queue = 8 }
}

# Basic services created before this date are capped at a single partition.
$script:BasicPartitionUpliftDate = [datetime]::Parse('2024-04-03T00:00:00Z').ToUniversalTime()

function Invoke-AzCommand {
    <#
    .SYNOPSIS
        Runs an Azure CLI command and returns its parsed JSON output.
    .DESCRIPTION
        Wraps 'az' so that stderr never contaminates the JSON payload and so that a non-zero exit
        code can either throw or return $null. All calls made by this script are read-only.
    .PARAMETER Argument
        Argument array passed verbatim to 'az'.
    .PARAMETER AllowFailure
        Return $null instead of throwing when the command exits non-zero.
    .EXAMPLE
        Invoke-AzCommand -Argument @('search','service','show','-n','svc','-g','rg','--output','json')
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Argument,

        [Parameter()]
        [switch]$AllowFailure
    )

    $errorFile = [System.IO.Path]::GetTempFileName()
    try {
        Write-Verbose "az $($Argument -join ' ')"
        $standardOutput = & az @Argument 2>$errorFile
        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0) {
            $detail = (Get-Content -LiteralPath $errorFile -Raw -ErrorAction SilentlyContinue)
            if ($AllowFailure) {
                Write-Verbose "Command failed with exit code ${exitCode}: $detail"
                return $null
            }
            throw "Azure CLI command 'az $($Argument -join ' ')' failed with exit code ${exitCode}. $detail"
        }

        $joined = ($standardOutput -join [Environment]::NewLine).Trim()
        if ([string]::IsNullOrWhiteSpace($joined)) { return $null }
        return ($joined | ConvertFrom-Json)
    }
    finally {
        Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-PropertyValue {
    <#
    .SYNOPSIS
        Reads a property from an object, returning a default when the property is absent or null.
    .DESCRIPTION
        Azure CLI output shape varies by API version and extension version, so direct property
        access is unsafe. This helper never throws on a missing member.
    .PARAMETER InputObject
        Object to read from.
    .PARAMETER Name
        Property name to read.
    .PARAMETER DefaultValue
        Value returned when the property is missing or null.
    .EXAMPLE
        Get-PropertyValue -InputObject $service -Name 'semanticSearch' -DefaultValue 'unknown'
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [object]$DefaultValue = $null
    )

    if ($null -eq $InputObject) { return $DefaultValue }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $DefaultValue }
    return $property.Value
}

function Write-Section {
    <#
    .SYNOPSIS
        Writes a section heading to the console report.
    .PARAMETER Title
        Heading text.
    .EXAMPLE
        Write-Section -Title 'Capacity verdict'
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )

    Write-Host ''
    Write-Host ('== {0} {1}' -f $Title, ('=' * [Math]::Max(3, 66 - $Title.Length))) -ForegroundColor Cyan
}

function Write-Finding {
    <#
    .SYNOPSIS
        Writes a single severity-coded finding line to the console report.
    .PARAMETER Severity
        One of Critical, Warning, Pass, or Info.
    .PARAMETER Message
        Finding text.
    .EXAMPLE
        Write-Finding -Severity 'Critical' -Message 'Semantic ranker is on the free plan.'
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Critical', 'Warning', 'Pass', 'Info')]
        [string]$Severity,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    $colour = switch ($Severity) {
        'Critical' { 'Red' }
        'Warning' { 'Yellow' }
        'Pass' { 'Green' }
        default { 'Gray' }
    }
    $label = switch ($Severity) {
        'Critical' { '[CRITICAL]' }
        'Warning' { '[WARNING ]' }
        'Pass' { '[PASS    ]' }
        default { '[INFO    ]' }
    }
    Write-Host ('{0} {1}' -f $label, $Message) -ForegroundColor $colour
}

function Get-SemanticCapacityProfile {
    <#
    .SYNOPSIS
        Computes in-flight semantic capacity for a tier and search-unit count.
    .DESCRIPTION
        In-flight capacity is searchUnits x (maxConcurrentRequests + maxQueueSize), using the
        per-search-unit limits published in the Azure AI Search service limits table.
    .PARAMETER SkuName
        Search service SKU name as returned by ARM, for example 'basic' or 'standard'.
    .PARAMETER SearchUnit
        Search unit count, which is replicas multiplied by partitions.
    .EXAMPLE
        Get-SemanticCapacityProfile -SkuName 'basic' -SearchUnit 1
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$SkuName,

        [Parameter(Mandatory)]
        [int]$SearchUnit
    )

    $key = $SkuName.ToLowerInvariant()
    if (-not $script:SemanticLimitPerSearchUnit.ContainsKey($key)) {
        return [PSCustomObject]@{
            Tier                     = $SkuName
            LimitsPublished          = $false
            ConcurrentPerSearchUnit  = $null
            QueuePerSearchUnit       = $null
            InFlightPerSearchUnit    = $null
            InFlightTotal            = $null
        }
    }

    $limit = $script:SemanticLimitPerSearchUnit[$key]
    $perUnit = $limit.Concurrent + $limit.Queue

    return [PSCustomObject]@{
        Tier                     = $limit.Tier
        LimitsPublished          = $true
        ConcurrentPerSearchUnit  = $limit.Concurrent
        QueuePerSearchUnit       = $limit.Queue
        InFlightPerSearchUnit    = $perUnit
        InFlightTotal            = $SearchUnit * $perUnit
    }
}

# --- Execution -----------------------------------------------------------------------------

$findings = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Finding {
    <#
    .SYNOPSIS
        Records a finding for both the console report and the JSON evidence file.
    .PARAMETER Severity
        One of Critical, Warning, Pass, or Info.
    .PARAMETER Code
        Short stable identifier for the finding.
    .PARAMETER Message
        Finding text.
    .EXAMPLE
        Add-Finding -Severity 'Pass' -Code 'SEM-PLAN' -Message 'Semantic ranker is on the standard plan.'
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Critical', 'Warning', 'Pass', 'Info')]
        [string]$Severity,

        [Parameter(Mandatory)]
        [string]$Code,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    $findings.Add([PSCustomObject]@{ severity = $Severity; code = $Code; message = $Message })
    Write-Finding -Severity $Severity -Message $Message
}

if (-not (Get-Command -Name 'az' -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) was not found on PATH. Install it from https://learn.microsoft.com/en-us/cli/azure/install-azure-cli and run "az login".'
}

$baseArgument = @('--output', 'json')
if ($PSBoundParameters.ContainsKey('SubscriptionId') -and -not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $baseArgument += @('--subscription', $SubscriptionId)
}

Write-Section -Title 'Azure AI Search diagnostics'
Write-Host ("Service      : {0}" -f $ServiceName)
Write-Host ("Resource grp : {0}" -f $ResourceGroupName)
Write-Host ("Collected at : {0}" -f ([datetime]::UtcNow.ToString('u')))
Write-Host ("Mode         : read-only (no Azure resource is modified)")

$service = Invoke-AzCommand -Argument (@('search', 'service', 'show', '--name', $ServiceName, '--resource-group', $ResourceGroupName) + $baseArgument)
if ($null -eq $service) {
    throw "Azure AI Search service '$ServiceName' was not found in resource group '$ResourceGroupName', or the signed-in principal lacks Reader access."
}

$resourceId = Get-PropertyValue -InputObject $service -Name 'id'

# The 'az search' command group does not project every ARM property consistently across versions,
# so read the raw resource as well and prefer its values where present.
$rawResource = Invoke-AzCommand -Argument (@('resource', 'show', '--ids', $resourceId, '--api-version', $ApiVersion) + $baseArgument) -AllowFailure
$rawProperty = Get-PropertyValue -InputObject $rawResource -Name 'properties'
$systemData = Get-PropertyValue -InputObject $rawResource -Name 'systemData'

$skuObject = Get-PropertyValue -InputObject $service -Name 'sku'
$skuName = [string](Get-PropertyValue -InputObject $skuObject -Name 'name' -DefaultValue (Get-PropertyValue -InputObject (Get-PropertyValue -InputObject $rawResource -Name 'sku') -Name 'name' -DefaultValue ''))
$location = [string](Get-PropertyValue -InputObject $service -Name 'location' -DefaultValue (Get-PropertyValue -InputObject $rawResource -Name 'location' -DefaultValue 'unknown'))
$replicaCount = [int](Get-PropertyValue -InputObject $service -Name 'replicaCount' -DefaultValue (Get-PropertyValue -InputObject $rawProperty -Name 'replicaCount' -DefaultValue 0))
$partitionCount = [int](Get-PropertyValue -InputObject $service -Name 'partitionCount' -DefaultValue (Get-PropertyValue -InputObject $rawProperty -Name 'partitionCount' -DefaultValue 0))
$searchUnit = $replicaCount * $partitionCount

# --- Check 1: semantic ranker plan (highest priority) --------------------------------------

Write-Section -Title '1. Semantic ranker plan (checked first)'

$semanticSearch = Get-PropertyValue -InputObject $rawProperty -Name 'semanticSearch' -DefaultValue (Get-PropertyValue -InputObject $service -Name 'semanticSearch')
$semanticPlan = if ($null -eq $semanticSearch) { 'unknown' } else { [string]$semanticSearch }

Write-Host ("properties.semanticSearch = '{0}'" -f $semanticPlan)

switch ($semanticPlan.ToLowerInvariant()) {
    'free' {
        Add-Finding -Severity 'Critical' -Code 'SEM-PLAN-FREE' -Message @'
Semantic ranker is on the FREE plan: 1,000 requests per month total. A seven-index fan-out
workload exhausts that allowance in roughly one to three days, after which semantic ranker
requests return a billing error. Resolve this BEFORE any further capacity work - no amount of
replica or tier scaling compensates for an exhausted free allowance.
Remediation: PATCH properties.semanticSearch to 'standard'. Never use PUT, which replaces the
whole service configuration rather than updating it.
'@
    }
    'disabled' {
        Add-Finding -Severity 'Warning' -Code 'SEM-PLAN-DISABLED' -Message @'
Semantic ranker is DISABLED at the service level, yet the reported symptom is a semantic partial
response (206 with @search.semanticPartialResponseReason). Those two facts are inconsistent.
Either the service was changed after the failures, or the failing traffic targets a different
service than the one audited here. Reconcile before filing a support ticket.
'@
    }
    'standard' {
        Add-Finding -Severity 'Pass' -Code 'SEM-PLAN-STANDARD' -Message 'Semantic ranker is on the standard (billed) plan, so the 1,000-request free allowance is not a factor.'
    }
    default {
        Add-Finding -Severity 'Warning' -Code 'SEM-PLAN-UNKNOWN' -Message @'
properties.semanticSearch could not be read from either the az search projection or the raw ARM
resource. Confirm it manually before ruling out free-plan exhaustion; it is the cheapest possible
explanation for intermittent semantic failure.
'@
    }
}

# --- Check 2: capacity math ----------------------------------------------------------------

Write-Section -Title '2. Search units and in-flight semantic capacity'

$capacity = Get-SemanticCapacityProfile -SkuName $skuName -SearchUnit $searchUnit
$requiredInFlight = $RequestsPerTurn * $ConcurrentTurnTarget

Write-Host ("SKU / tier      : {0} ({1})" -f $skuName, $capacity.Tier)
Write-Host ("Region          : {0}" -f $location)
Write-Host ("Replicas        : {0}" -f $replicaCount)
Write-Host ("Partitions      : {0}" -f $partitionCount)
Write-Host ("Search units    : {0}  (replicas x partitions)" -f $searchUnit)
Write-Host ("Requirement     : {0} in-flight semantic requests ({1} per turn x {2} concurrent turns)" -f $requiredInFlight, $RequestsPerTurn, $ConcurrentTurnTarget)

$requiredSearchUnit = $null
if ($capacity.LimitsPublished) {
    Write-Host ("Per search unit : {0} concurrent + {1} queued = {2} in flight" -f $capacity.ConcurrentPerSearchUnit, $capacity.QueuePerSearchUnit, $capacity.InFlightPerSearchUnit)
    Write-Host ("Available       : {0} in-flight semantic requests before rejection" -f $capacity.InFlightTotal)

    $requiredSearchUnit = [int][Math]::Ceiling($requiredInFlight / [double]$capacity.InFlightPerSearchUnit)

    if ($capacity.InFlightTotal -ge $requiredInFlight) {
        Add-Finding -Severity 'Pass' -Code 'CAP-OK' -Message (
            "Capacity PASSES: {0} in-flight slots available against a requirement of {1}. Headroom is {2} slots." -f `
                $capacity.InFlightTotal, $requiredInFlight, ($capacity.InFlightTotal - $requiredInFlight))
    }
    else {
        Add-Finding -Severity 'Critical' -Code 'CAP-SHORT' -Message (
            ("Capacity FAILS: {0} in-flight semantic slots available against a requirement of {1}. " +
            "Requests beyond the queue depth are rejected, which surfaces as HTTP 206 with a semantic " +
            "partial response rather than 429 or 503. Reaching {1} in-flight slots on this tier needs " +
            "at least {2} search units (currently {3}).") -f `
                $capacity.InFlightTotal, $requiredInFlight, $requiredSearchUnit, $searchUnit)
    }

    Add-Finding -Severity 'Info' -Code 'CAP-CONFLICT' -Message @'
Documentation conflict worth raising with support: the service limits table states 2/3/4 concurrent
semantic requests per SEARCH UNIT plus queue, while the "Add semantic ranking" page states roughly
10 concurrent queries per REPLICA. The two figures use different units and different magnitudes and
cannot both be literal. This calculation uses the limits table, which is the more conservative of
the two.
'@
}
else {
    Add-Finding -Severity 'Warning' -Code 'CAP-UNKNOWN-TIER' -Message (
        "No published per-search-unit semantic concurrency limit exists for SKU '{0}'. Capacity cannot be computed; ask support for the limit that applies to this tier." -f $skuName)
}

# --- Check 3: partition ceiling for Basic --------------------------------------------------

Write-Section -Title '3. Service creation date and partition ceiling'

$createdAt = Get-PropertyValue -InputObject $systemData -Name 'createdAt'
$lastModifiedAt = Get-PropertyValue -InputObject $systemData -Name 'lastModifiedAt'

if ($null -ne $createdAt) {
    $createdUtc = ([datetime]$createdAt).ToUniversalTime()
    Write-Host ("Created  (UTC) : {0}" -f $createdUtc.ToString('u'))

    if ($skuName.ToLowerInvariant() -eq 'basic') {
        if ($createdUtc -lt $script:BasicPartitionUpliftDate) {
            Add-Finding -Severity 'Warning' -Code 'CAP-BASIC-LEGACY' -Message (
                ("This Basic service was created on {0}, before the 2024-04-03 partition uplift, so it is " +
                "capped at 1 partition and a maximum of 3 search units (18 in-flight semantic slots). " +
                "Record this in the support ticket - it changes the capacity ceiling.") -f $createdUtc.ToString('yyyy-MM-dd'))
        }
        else {
            Add-Finding -Severity 'Info' -Code 'CAP-BASIC-MODERN' -Message 'This Basic service post-dates the 2024-04-03 uplift, so it supports up to 3 partitions and 3 replicas (9 search units).'
        }
    }
}
else {
    Add-Finding -Severity 'Warning' -Code 'CAP-CREATED-UNKNOWN' -Message @'
The service creation date was not returned by ARM systemData. Determine it manually (portal
resource overview, or an activity-log export covering the creation window) - a Basic service
created before 2024-04-03 is capped at one partition, which changes the capacity ceiling and is a
required field in the support ticket evidence list.
'@
}

if ($null -ne $lastModifiedAt) {
    Write-Host ("Modified (UTC) : {0}" -f ([datetime]$lastModifiedAt).ToUniversalTime().ToString('u'))
    Add-Finding -Severity 'Info' -Code 'CFG-LASTMOD' -Message (
        "Last ARM modification was {0}. Compare this against the first and last 403 timestamps: a configuration change inside the failure window is a far stronger explanation than coincidence." -f ([datetime]$lastModifiedAt).ToUniversalTime().ToString('u'))
}

# --- Check 4: network posture --------------------------------------------------------------

Write-Section -Title '4. Network posture (403 hypothesis input)'

$publicNetworkAccess = [string](Get-PropertyValue -InputObject $rawProperty -Name 'publicNetworkAccess' -DefaultValue (Get-PropertyValue -InputObject $service -Name 'publicNetworkAccess' -DefaultValue 'unknown'))
$networkRuleSet = Get-PropertyValue -InputObject $rawProperty -Name 'networkRuleSet' -DefaultValue (Get-PropertyValue -InputObject $service -Name 'networkRuleSet')
$ipRuleValue = Get-PropertyValue -InputObject $networkRuleSet -Name 'ipRules' -DefaultValue @()
$ipRule = @($ipRuleValue | ForEach-Object { [string](Get-PropertyValue -InputObject $_ -Name 'value') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

Write-Host ("publicNetworkAccess : {0}" -f $publicNetworkAccess)
Write-Host ("ipRules count       : {0}" -f $ipRule.Count)
foreach ($rule in $ipRule) { Write-Host ("  - {0}" -f $rule) }

if ($publicNetworkAccess -ieq 'disabled') {
    Add-Finding -Severity 'Info' -Code 'NET-PRIVATE' -Message 'Public network access is disabled, so traffic must arrive over a private endpoint. Power Platform connectors are not on the Azure AI Search trusted-services list, so confirm how connector egress reaches the service.'
}
elseif ($ipRule.Count -gt 0) {
    Add-Finding -Severity 'Critical' -Code 'NET-IP-ALLOWLIST' -Message (
        ("An IP access control policy is active with {0} rule(s). Azure AI Search rejects requests from " +
        "addresses outside this list with HTTP 403 Forbidden. Power Platform connector egress spans every " +
        "AzureConnectors.<Region> service tag in the geography and changes over time, so a partially stale " +
        "allow-list produces exactly the intermittent 403 pattern reported. Run " +
        "Compare-ConnectorEgressPrefixes.ps1 next - this is the leading 403 hypothesis.") -f $ipRule.Count)
}
else {
    Add-Finding -Severity 'Pass' -Code 'NET-OPEN' -Message 'No IP access control rules are configured, so the Search IP firewall is not the source of the 403 responses. Shift attention to the APIM policy hypotheses.'
}

# --- Check 5: telemetry readiness -----------------------------------------------------------

Write-Section -Title '5. Diagnostic settings (telemetry readiness)'

$diagnosticResult = Invoke-AzCommand -Argument (@('monitor', 'diagnostic-settings', 'list', '--resource', $resourceId) + $baseArgument) -AllowFailure
$diagnosticSetting = @(Get-PropertyValue -InputObject $diagnosticResult -Name 'value' -DefaultValue @())

$hasOperationLog = $false
$hasAllMetric = $false
$settingSummary = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($setting in $diagnosticSetting) {
    $logEntry = @(Get-PropertyValue -InputObject $setting -Name 'logs' -DefaultValue @())
    $metricEntry = @(Get-PropertyValue -InputObject $setting -Name 'metrics' -DefaultValue @())

    $operationLogEnabled = [bool](@($logEntry | Where-Object {
                $true -eq (Get-PropertyValue -InputObject $_ -Name 'enabled' -DefaultValue $false) -and
                ((Get-PropertyValue -InputObject $_ -Name 'category') -ieq 'OperationLogs' -or
                (Get-PropertyValue -InputObject $_ -Name 'categoryGroup') -ieq 'allLogs')
            }).Count)

    $allMetricEnabled = [bool](@($metricEntry | Where-Object {
                $true -eq (Get-PropertyValue -InputObject $_ -Name 'enabled' -DefaultValue $false) -and
                (Get-PropertyValue -InputObject $_ -Name 'category') -ieq 'AllMetrics'
            }).Count)

    if ($operationLogEnabled) { $hasOperationLog = $true }
    if ($allMetricEnabled) { $hasAllMetric = $true }

    $settingSummary.Add([PSCustomObject]@{
            name                = Get-PropertyValue -InputObject $setting -Name 'name'
            workspaceId         = Get-PropertyValue -InputObject $setting -Name 'workspaceId'
            operationLogEnabled = $operationLogEnabled
            allMetricsEnabled   = $allMetricEnabled
        })

    Write-Host ("Setting '{0}': OperationLogs={1} AllMetrics={2}" -f (Get-PropertyValue -InputObject $setting -Name 'name' -DefaultValue '(unnamed)'), $operationLogEnabled, $allMetricEnabled)
}

if ($diagnosticSetting.Count -eq 0) {
    Add-Finding -Severity 'Critical' -Code 'TEL-NONE' -Message 'No diagnostic setting exists on the Search service, so no query-level history is retained. Every retrospective KQL query in this package returns nothing until one is created. Run Enable-DiagnosticSettings.ps1.'
}
else {
    if ($hasOperationLog) {
        Add-Finding -Severity 'Pass' -Code 'TEL-OPLOGS' -Message 'OperationLogs are being collected, so per-query history is available in AzureDiagnostics.'
    }
    else {
        Add-Finding -Severity 'Critical' -Code 'TEL-NO-OPLOGS' -Message 'A diagnostic setting exists but OperationLogs is not enabled, so there is no per-query history to analyse. Enable it.'
    }

    if ($hasAllMetric) {
        Add-Finding -Severity 'Pass' -Code 'TEL-METRICS' -Message 'AllMetrics is enabled, so ThrottledSearchQueriesPercentage and latency metrics are retained.'
    }
    else {
        Add-Finding -Severity 'Warning' -Code 'TEL-NO-METRICS' -Message 'AllMetrics is not enabled, so throttling and latency metrics are retained only for the default 93-day platform window and cannot be joined against logs.'
    }
}

Add-Finding -Severity 'Info' -Code 'TEL-SCHEMA-GAP' -Message @'
Search resource logs do NOT carry @search.semanticPartialResponseReason. The documented Properties
are limited to Description_s, Documents_d, IndexName_s, and Query_s, so the partial-response reason
exists only in the HTTP response body. APIM response-body logging is the only place it can be
captured. Enabling Search diagnostics alone will not answer why the 206 responses occurred.
'@

# --- Result assembly -------------------------------------------------------------------------

$criticalCount = @($findings | Where-Object { $_.severity -eq 'Critical' }).Count
$warningCount = @($findings | Where-Object { $_.severity -eq 'Warning' }).Count

$result = [PSCustomObject]@{
    collectedAtUtc = [datetime]::UtcNow.ToString('o')
    scriptVersion  = '1.0.0'
    mode           = 'read-only'
    service        = [PSCustomObject]@{
        name              = $ServiceName
        resourceGroup     = $ResourceGroupName
        resourceId        = $resourceId
        location          = $location
        sku               = $skuName
        tier              = $capacity.Tier
        replicaCount      = $replicaCount
        partitionCount    = $partitionCount
        searchUnits       = $searchUnit
        semanticSearch    = $semanticPlan
        createdAtUtc      = if ($null -ne $createdAt) { ([datetime]$createdAt).ToUniversalTime().ToString('o') } else { $null }
        lastModifiedAtUtc = if ($null -ne $lastModifiedAt) { ([datetime]$lastModifiedAt).ToUniversalTime().ToString('o') } else { $null }
    }
    network        = [PSCustomObject]@{
        publicNetworkAccess = $publicNetworkAccess
        ipRules             = $ipRule
        ipRuleCount         = $ipRule.Count
    }
    capacity       = [PSCustomObject]@{
        requestsPerTurn         = $RequestsPerTurn
        concurrentTurnTarget    = $ConcurrentTurnTarget
        requiredInFlight        = $requiredInFlight
        limitsPublished         = $capacity.LimitsPublished
        concurrentPerSearchUnit = $capacity.ConcurrentPerSearchUnit
        queuePerSearchUnit      = $capacity.QueuePerSearchUnit
        inFlightPerSearchUnit   = $capacity.InFlightPerSearchUnit
        availableInFlight       = $capacity.InFlightTotal
        requiredSearchUnits     = $requiredSearchUnit
        verdict                 = if (-not $capacity.LimitsPublished) { 'unknown' }
        elseif ($capacity.InFlightTotal -ge $requiredInFlight) { 'pass' }
        else { 'fail' }
    }
    telemetry      = [PSCustomObject]@{
        diagnosticSettingCount = $diagnosticSetting.Count
        operationLogsEnabled   = $hasOperationLog
        allMetricsEnabled      = $hasAllMetric
        settings               = $settingSummary
    }
    findings       = $findings
    summary        = [PSCustomObject]@{
        criticalCount = $criticalCount
        warningCount  = $warningCount
    }
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path -Path (Get-Location).Path -ChildPath ("search-diagnostics-{0}-{1}.json" -f $ServiceName, ([datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ')))
}

$outputDirectory = Split-Path -Path $OutputPath -Parent
if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and -not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
}

$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding utf8

Write-Section -Title 'Summary'
Write-Host ("Critical findings : {0}" -f $criticalCount) -ForegroundColor $(if ($criticalCount -gt 0) { 'Red' } else { 'Green' })
Write-Host ("Warnings          : {0}" -f $warningCount) -ForegroundColor $(if ($warningCount -gt 0) { 'Yellow' } else { 'Green' })
Write-Host ("Evidence file     : {0}" -f $OutputPath)
Write-Host 'Attach the evidence file to the Azure AI Search support request.'

return $result
