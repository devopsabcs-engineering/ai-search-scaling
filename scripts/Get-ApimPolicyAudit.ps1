#Requires -Version 7.0

<#
.SYNOPSIS
    Performs a read-only audit of an API Management instance to discriminate among the 403 hypotheses.

.DESCRIPTION
    Collects the API Management facts needed to decide whether the connector 403 responses originate
    in an APIM policy or in the Azure AI Search backend.

    The audit covers four areas:

    1. SKU and tier. The Consumption tier supports no resource logs at all, so detecting it early
       prevents an observability plan that cannot be executed.
    2. Policy XML at global, product, API, and operation scope, scanned for the elements that can
       deny a request. The 'quota' and 'quota-by-key' policies are called out separately because
       they are the only APIM throttling policies that return 403; 'rate-limit' and
       'rate-limit-by-key' return 429, and a missing or invalid subscription key returns 401.
    3. Gateway log readiness: whether an Azure Monitor diagnostic setting collects GatewayLogs, and
       whether the APIM diagnostic entity is configured to capture response bodies. Response-body
       logging is the only documented place @search.semanticPartialResponseReason can be captured,
       because that field is absent from the Azure AI Search resource-log schema.
    4. Presence of an 'on-error' section, without which callers receive generic 400 or 500 responses
       and the gateway logs carry no useful error attribution.

    The script performs no write operations. It calls 'az apim show', 'az apim api list',
    'az apim product list', 'az apim api operation list', 'az monitor diagnostic-settings list',
    and read-only 'az rest' GET requests for policy documents.

.PARAMETER ResourceGroupName
    Resource group containing the API Management instance.

.PARAMETER ServiceName
    Name of the API Management instance to audit.

.PARAMETER SubscriptionId
    Optional subscription ID. When omitted the current 'az account' context is used.

.PARAMETER ApiId
    Optional API identifier. When supplied the API and operation scans are limited to that API,
    which keeps the audit fast on instances hosting many APIs.

.PARAMETER SkipOperationScope
    Skip operation-scope policy retrieval. Use on large instances where the per-operation policy
    reads would be slow. Operation scope is the most specific scope, so skipping it can hide a
    narrowly targeted quota or ip-filter policy.

.PARAMETER ApiVersion
    ARM API version used for policy and diagnostic entity reads. Defaults to '2022-08-01'.

.PARAMETER OutputPath
    Path of the JSON evidence file. Defaults to a timestamped file in the current directory.

.EXAMPLE
    ./Get-ApimPolicyAudit.ps1 -ResourceGroupName 'rg-apim' -ServiceName 'contoso-apim'

    Audits every scope and writes a timestamped JSON evidence file.

.EXAMPLE
    ./Get-ApimPolicyAudit.ps1 -ResourceGroupName 'rg-apim' -ServiceName 'contoso-apim' -ApiId 'ai-search' -Verbose

    Limits the API and operation scans to the 'ai-search' API and traces each Azure CLI call.

.OUTPUTS
    PSCustomObject describing the tier, every policy scope found, the denial elements detected, and
    the gateway-log readiness findings. The same object is serialised to the JSON evidence file.

.NOTES
    Requires Azure CLI authenticated with at least Reader on the API Management instance.
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
    [string]$ApiId,

    [Parameter()]
    [switch]$SkipOperationScope,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ApiVersion = '2022-08-01',

    [Parameter()]
    [string]$OutputPath
)

# Policy elements that can deny a request, with the status code each one produces.
# Sources: https://learn.microsoft.com/en-us/azure/api-management/quota-policy
#          https://learn.microsoft.com/en-us/azure/api-management/rate-limit-policy
#          https://learn.microsoft.com/en-us/azure/api-management/ip-filter-policy
#          https://learn.microsoft.com/en-us/azure/api-management/validate-jwt-policy
$script:PolicySignature = @(
    [PSCustomObject]@{ Element = 'quota'; Pattern = '<quota(?=[\s>/])'; StatusCode = '403'; Severity = 'Critical'; Note = 'The only APIM throttling policy that returns 403 when exceeded. A seven-call burst per conversational turn is exactly the shape that trips a call-count quota.' }
    [PSCustomObject]@{ Element = 'quota-by-key'; Pattern = '<quota-by-key(?=[\s>/])'; StatusCode = '403'; Severity = 'Critical'; Note = 'Returns 403 when the per-key quota is exceeded. Check the counter key expression to see which dimension is being counted.' }
    [PSCustomObject]@{ Element = 'ip-filter'; Pattern = '<ip-filter(?=[\s>/])'; StatusCode = '403'; Severity = 'Critical'; Note = 'Denies with CallerIpNotAllowed or CallerIpBlocked. With action="allow", any caller not explicitly listed is denied.' }
    [PSCustomObject]@{ Element = 'validate-jwt'; Pattern = '<validate-jwt(?=[\s>/])'; StatusCode = '401 by default, 403 when failed-validation-httpcode is set'; Severity = 'Warning'; Note = 'Default is 401, but hardened policies frequently set failed-validation-httpcode to 403. Read the attribute rather than assuming.' }
    [PSCustomObject]@{ Element = 'check-header'; Pattern = '<check-header(?=[\s>/])'; StatusCode = 'configurable via failed-check-httpcode'; Severity = 'Warning'; Note = 'Can be configured to return 403. Read failed-check-httpcode.' }
    [PSCustomObject]@{ Element = 'rate-limit'; Pattern = '<rate-limit(?=[\s>/])'; StatusCode = '429'; Severity = 'Info'; Note = 'Returns 429, not 403. Present for completeness - this policy does not explain the reported 403 responses.' }
    [PSCustomObject]@{ Element = 'rate-limit-by-key'; Pattern = '<rate-limit-by-key(?=[\s>/])'; StatusCode = '429'; Severity = 'Info'; Note = 'Returns 429, not 403.' }
    [PSCustomObject]@{ Element = 'on-error'; Pattern = '<on-error(?=[\s>/])'; StatusCode = 'n/a'; Severity = 'Info'; Note = 'Error-handling section. Its absence means callers receive generic 400 or 500 responses with no attribution.' }
)

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
        Invoke-AzCommand -Argument @('apim','show','-n','svc','-g','rg','--output','json')
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
    .PARAMETER InputObject
        Object to read from.
    .PARAMETER Name
        Property name to read.
    .PARAMETER DefaultValue
        Value returned when the property is missing or null.
    .EXAMPLE
        Get-PropertyValue -InputObject $apim -Name 'sku' -DefaultValue $null
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
        Write-Section -Title 'Policy scan'
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

function Get-PolicyDocument {
    <#
    .SYNOPSIS
        Retrieves the raw policy XML for a single APIM policy scope.
    .DESCRIPTION
        Issues a read-only ARM GET with format=rawxml. Scopes with no policy defined return 404,
        which is reported as an absent policy rather than an error.
    .PARAMETER PolicyPath
        ARM resource path of the policy, relative to the management endpoint.
    .PARAMETER ApiVersion
        ARM API version to request.
    .PARAMETER ExtraArgument
        Additional Azure CLI arguments, such as a subscription override.
    .EXAMPLE
        Get-PolicyDocument -PolicyPath '/subscriptions/x/.../policies/policy' -ApiVersion '2022-08-01'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$PolicyPath,

        [Parameter(Mandatory)]
        [string]$ApiVersion,

        [Parameter()]
        [string[]]$ExtraArgument = @()
    )

    $url = "https://management.azure.com{0}?format=rawxml&api-version={1}" -f $PolicyPath, $ApiVersion
    $response = Invoke-AzCommand -Argument (@('rest', '--method', 'get', '--url', $url, '--output', 'json') + $ExtraArgument) -AllowFailure
    if ($null -eq $response) { return $null }

    $properties = Get-PropertyValue -InputObject $response -Name 'properties'
    return [string](Get-PropertyValue -InputObject $properties -Name 'value')
}

function Test-PolicyDocument {
    <#
    .SYNOPSIS
        Scans a policy document for denial elements and returns the matches.
    .PARAMETER PolicyXml
        Raw policy XML.
    .PARAMETER Scope
        Human-readable scope label, for example 'API: ai-search'.
    .EXAMPLE
        Test-PolicyDocument -PolicyXml $xml -Scope 'Global'
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$PolicyXml,

        [Parameter(Mandatory)]
        [string]$Scope
    )

    $match = [System.Collections.Generic.List[PSCustomObject]]::new()
    if ([string]::IsNullOrWhiteSpace($PolicyXml)) { return $match.ToArray() }

    foreach ($signature in $script:PolicySignature) {
        $found = [regex]::Matches($PolicyXml, $signature.Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($found.Count -eq 0) { continue }

        $match.Add([PSCustomObject]@{
                scope        = $Scope
                element      = $signature.Element
                occurrences  = $found.Count
                statusCode   = $signature.StatusCode
                severity     = $signature.Severity
                note         = $signature.Note
            })
    }

    return $match.ToArray()
}

function Get-ConfiguredHttpCode {
    <#
    .SYNOPSIS
        Extracts configured failure status codes from validate-jwt and check-header elements.
    .PARAMETER PolicyXml
        Raw policy XML.
    .EXAMPLE
        Get-ConfiguredHttpCode -PolicyXml $xml
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$PolicyXml
    )

    $code = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($PolicyXml)) { return $code.ToArray() }

    foreach ($attribute in @('failed-validation-httpcode', 'failed-check-httpcode')) {
        $pattern = ('{0}\s*=\s*"(\d{{3}})"' -f [regex]::Escape($attribute))
        foreach ($found in [regex]::Matches($PolicyXml, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            $code.Add(('{0}={1}' -f $attribute, $found.Groups[1].Value))
        }
    }

    return $code.ToArray()
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
        Add-Finding -Severity 'Critical' -Code 'POL-QUOTA' -Message 'A quota policy is present.'
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

if (-not (Get-Command -Name 'az' -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) was not found on PATH. Install it from https://learn.microsoft.com/en-us/cli/azure/install-azure-cli and run "az login".'
}

$baseArgument = @('--output', 'json')
$restArgument = @()
if ($PSBoundParameters.ContainsKey('SubscriptionId') -and -not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $baseArgument += @('--subscription', $SubscriptionId)
    $restArgument += @('--subscription', $SubscriptionId)
}

Write-Section -Title 'API Management policy audit'
Write-Host ("Instance     : {0}" -f $ServiceName)
Write-Host ("Resource grp : {0}" -f $ResourceGroupName)
Write-Host ("Collected at : {0}" -f ([datetime]::UtcNow.ToString('u')))
Write-Host ("Mode         : read-only (no Azure resource is modified)")

$apim = Invoke-AzCommand -Argument (@('apim', 'show', '--name', $ServiceName, '--resource-group', $ResourceGroupName) + $baseArgument)
if ($null -eq $apim) {
    throw "API Management instance '$ServiceName' was not found in resource group '$ResourceGroupName', or the signed-in principal lacks Reader access."
}

$apimResourceId = [string](Get-PropertyValue -InputObject $apim -Name 'id')
$skuObject = Get-PropertyValue -InputObject $apim -Name 'sku'
$skuName = [string](Get-PropertyValue -InputObject $skuObject -Name 'name' -DefaultValue 'unknown')
$skuCapacity = Get-PropertyValue -InputObject $skuObject -Name 'capacity'
$isConsumptionTier = $skuName -ieq 'Consumption'

# --- Check 1: tier ---------------------------------------------------------------------------

Write-Section -Title '1. Tier and gateway-log eligibility'
Write-Host ("SKU      : {0}" -f $skuName)
Write-Host ("Capacity : {0}" -f $skuCapacity)
Write-Host ("Region   : {0}" -f (Get-PropertyValue -InputObject $apim -Name 'location' -DefaultValue 'unknown'))

if ($isConsumptionTier) {
    Add-Finding -Severity 'Critical' -Code 'TIER-CONSUMPTION' -Message @'
This instance is on the CONSUMPTION tier, which supports no resource logs at all. GatewayLogs
cannot be collected and response-body logging is unavailable, so neither the 403 attribution query
nor the 206 partial-response capture can run against this gateway. Any observability plan that
depends on APIM gateway logs must be revised: either move the instance to a tier that supports
resource logs, or capture the evidence at the Azure AI Search and Application Insights layers only.
'@
}
else {
    Add-Finding -Severity 'Pass' -Code 'TIER-SUPPORTS-LOGS' -Message ("The '{0}' tier supports resource logs, so GatewayLogs and response-body capture are available." -f $skuName)
}

# --- Check 2: policy scan ----------------------------------------------------------------------

Write-Section -Title '2. Policy scan (global, product, API, operation)'

$policyScope = [System.Collections.Generic.List[PSCustomObject]]::new()
$allMatch = [System.Collections.Generic.List[PSCustomObject]]::new()
$configuredCode = [System.Collections.Generic.List[string]]::new()

function Register-PolicyScope {
    <#
    .SYNOPSIS
        Retrieves, scans, and records one policy scope.
    .PARAMETER Label
        Human-readable scope label.
    .PARAMETER PolicyPath
        ARM resource path of the policy document.
    .EXAMPLE
        Register-PolicyScope -Label 'Global' -PolicyPath "$apimResourceId/policies/policy"
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseApprovedVerbs', '',
        Justification = 'Register is used here in its dictionary sense of recording a result; no state-changing alternative verb applies to an in-memory collection append.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$Label,

        [Parameter(Mandatory)]
        [string]$PolicyPath
    )

    $xml = Get-PolicyDocument -PolicyPath $PolicyPath -ApiVersion $ApiVersion -ExtraArgument $restArgument
    $hasPolicy = -not [string]::IsNullOrWhiteSpace($xml)

    $scopeMatch = @()
    if ($hasPolicy) {
        $scopeMatch = Test-PolicyDocument -PolicyXml $xml -Scope $Label
        foreach ($item in $scopeMatch) { $allMatch.Add($item) }
        foreach ($item in (Get-ConfiguredHttpCode -PolicyXml $xml)) { $configuredCode.Add(('{0}: {1}' -f $Label, $item)) }
    }

    $policyScope.Add([PSCustomObject]@{
            scope          = $Label
            policyPath     = $PolicyPath
            policyDefined  = $hasPolicy
            policyXml      = $xml
            elementsFound  = @($scopeMatch | ForEach-Object { $_.element })
        })

    $summary = if (-not $hasPolicy) { 'no policy defined' }
    elseif ($scopeMatch.Count -eq 0) { 'policy defined, no denial elements' }
    else { ($scopeMatch | ForEach-Object { $_.element }) -join ', ' }

    Write-Host ("  {0,-46} {1}" -f $Label, $summary)
}

Register-PolicyScope -Label 'Global' -PolicyPath ("{0}/policies/policy" -f $apimResourceId)

$product = @(Invoke-AzCommand -Argument (@('apim', 'product', 'list', '--service-name', $ServiceName, '--resource-group', $ResourceGroupName) + $baseArgument) -AllowFailure)
foreach ($item in $product) {
    $productName = [string](Get-PropertyValue -InputObject $item -Name 'name')
    if ([string]::IsNullOrWhiteSpace($productName)) { continue }
    Register-PolicyScope -Label ("Product: {0}" -f $productName) -PolicyPath ("{0}/products/{1}/policies/policy" -f $apimResourceId, $productName)
}

$apiListArgument = @('apim', 'api', 'list', '--service-name', $ServiceName, '--resource-group', $ResourceGroupName)
$api = @(Invoke-AzCommand -Argument ($apiListArgument + $baseArgument) -AllowFailure)
if (-not [string]::IsNullOrWhiteSpace($ApiId)) {
    $api = @($api | Where-Object { (Get-PropertyValue -InputObject $_ -Name 'name') -ieq $ApiId })
    if ($api.Count -eq 0) {
        Add-Finding -Severity 'Warning' -Code 'API-NOT-FOUND' -Message ("No API with identifier '{0}' was found on this instance. The API and operation scans produced no results." -f $ApiId)
    }
}

foreach ($item in $api) {
    $apiName = [string](Get-PropertyValue -InputObject $item -Name 'name')
    if ([string]::IsNullOrWhiteSpace($apiName)) { continue }
    Register-PolicyScope -Label ("API: {0}" -f $apiName) -PolicyPath ("{0}/apis/{1}/policies/policy" -f $apimResourceId, $apiName)

    if ($SkipOperationScope) { continue }

    $operation = @(Invoke-AzCommand -Argument (@('apim', 'api', 'operation', 'list', '--service-name', $ServiceName, '--resource-group', $ResourceGroupName, '--api-id', $apiName) + $baseArgument) -AllowFailure)
    foreach ($operationItem in $operation) {
        $operationName = [string](Get-PropertyValue -InputObject $operationItem -Name 'name')
        if ([string]::IsNullOrWhiteSpace($operationName)) { continue }
        Register-PolicyScope -Label ("Operation: {0}/{1}" -f $apiName, $operationName) -PolicyPath ("{0}/apis/{1}/operations/{2}/policies/policy" -f $apimResourceId, $apiName, $operationName)
    }
}

if ($SkipOperationScope) {
    Add-Finding -Severity 'Warning' -Code 'POL-OPSCOPE-SKIPPED' -Message 'Operation-scope policies were skipped. Operation scope is the most specific scope, so a narrowly targeted quota or ip-filter policy could remain undetected. Re-run without -SkipOperationScope before ruling out APIM as the 403 source.'
}

# --- Check 3: denial element findings ------------------------------------------------------

Write-Section -Title '3. Denial elements detected'

$quotaMatch = @($allMatch | Where-Object { $_.element -in @('quota', 'quota-by-key') })
$ipFilterMatch = @($allMatch | Where-Object { $_.element -eq 'ip-filter' })
$jwtMatch = @($allMatch | Where-Object { $_.element -in @('validate-jwt', 'check-header') })
$rateLimitMatch = @($allMatch | Where-Object { $_.element -in @('rate-limit', 'rate-limit-by-key') })
$onErrorMatch = @($allMatch | Where-Object { $_.element -eq 'on-error' })

if ($quotaMatch.Count -gt 0) {
    Add-Finding -Severity 'Critical' -Code 'POL-QUOTA-PRESENT' -Message (
        ("A quota policy is present at {0} scope(s): {1}. This is the single highest-value 403 finding. " +
        "quota and quota-by-key are the ONLY APIM throttling policies that return 403 Forbidden when " +
        "exceeded - rate-limit returns 429 and a missing or invalid subscription key returns 401. " +
        "A seven-call burst per conversational turn is precisely the traffic shape that exhausts a " +
        "call-count quota. Read the renewal-period and calls attributes at each scope listed, and " +
        "correlate the quota reset boundary against the timestamps of the 403 responses.") -f `
            $quotaMatch.Count, (($quotaMatch | ForEach-Object { $_.scope }) -join '; '))
}
else {
    Add-Finding -Severity 'Pass' -Code 'POL-QUOTA-ABSENT' -Message 'No quota or quota-by-key policy was found at any scanned scope, so APIM quota exhaustion does not explain the 403 responses.'
}

if ($ipFilterMatch.Count -gt 0) {
    Add-Finding -Severity 'Critical' -Code 'POL-IPFILTER-PRESENT' -Message (
        ("An ip-filter policy is present at {0} scope(s): {1}. With action set to allow, any caller whose " +
        "address is not explicitly listed is denied. Power Platform connector egress spans multiple " +
        "AzureConnectors service tags and changes over time, so a partially stale allow list produces " +
        "intermittent denials. Read the address and address-range values and compare them against the " +
        "current service tags.") -f $ipFilterMatch.Count, (($ipFilterMatch | ForEach-Object { $_.scope }) -join '; '))
}
else {
    Add-Finding -Severity 'Pass' -Code 'POL-IPFILTER-ABSENT' -Message 'No ip-filter policy was found at any scanned scope.'
}

if ($jwtMatch.Count -gt 0) {
    $codeDetail = if ($configuredCode.Count -gt 0) { $configuredCode -join '; ' } else { 'no explicit failure status code configured, so the documented default applies (401 for validate-jwt)' }
    Add-Finding -Severity 'Warning' -Code 'POL-AUTH-PRESENT' -Message (
        ("A validate-jwt or check-header policy is present at {0} scope(s): {1}. Configured failure codes: {2}. " +
        "These policies default to 401 but are frequently hardened to 403, so the actual attribute value " +
        "decides whether they can explain the symptom.") -f $jwtMatch.Count, (($jwtMatch | ForEach-Object { $_.scope }) -join '; '), $codeDetail)
}

if ($rateLimitMatch.Count -gt 0) {
    Add-Finding -Severity 'Info' -Code 'POL-RATELIMIT-PRESENT' -Message (
        ("A rate-limit policy is present at {0} scope(s): {1}. Recorded for completeness only - rate limiting " +
        "returns 429, not 403, so it cannot explain the reported failures. It may still be shaping the " +
        "seven-call burst and is worth noting in the support ticket.") -f $rateLimitMatch.Count, (($rateLimitMatch | ForEach-Object { $_.scope }) -join '; '))
}

if ($onErrorMatch.Count -eq 0) {
    Add-Finding -Severity 'Warning' -Code 'POL-NO-ONERROR' -Message 'No on-error section was found at any scanned scope. Without one, callers receive generic 400 or 500 responses and the gateway logs carry no policy-level error attribution. Adding an on-error section is the cheapest instrumentation available on this gateway.'
}
else {
    Add-Finding -Severity 'Pass' -Code 'POL-ONERROR-PRESENT' -Message ("An on-error section is defined at {0} scope(s), so policy-level error attribution is available." -f $onErrorMatch.Count)
}

# --- Check 4: gateway log readiness --------------------------------------------------------

Write-Section -Title '4. Gateway log and response-body readiness'

$gatewayLogEnabled = $false
$diagnosticSettingSummary = [System.Collections.Generic.List[PSCustomObject]]::new()

if (-not $isConsumptionTier) {
    $diagnosticResult = Invoke-AzCommand -Argument (@('monitor', 'diagnostic-settings', 'list', '--resource', $apimResourceId) + $baseArgument) -AllowFailure
    $diagnosticSetting = @(Get-PropertyValue -InputObject $diagnosticResult -Name 'value' -DefaultValue @())

    foreach ($setting in $diagnosticSetting) {
        $logEntry = @(Get-PropertyValue -InputObject $setting -Name 'logs' -DefaultValue @())
        $settingHasGatewayLog = [bool](@($logEntry | Where-Object {
                    $true -eq (Get-PropertyValue -InputObject $_ -Name 'enabled' -DefaultValue $false) -and
                    ((Get-PropertyValue -InputObject $_ -Name 'category') -ieq 'GatewayLogs' -or
                    (Get-PropertyValue -InputObject $_ -Name 'categoryGroup') -ieq 'allLogs')
                }).Count)

        if ($settingHasGatewayLog) { $gatewayLogEnabled = $true }

        $diagnosticSettingSummary.Add([PSCustomObject]@{
                name              = Get-PropertyValue -InputObject $setting -Name 'name'
                workspaceId       = Get-PropertyValue -InputObject $setting -Name 'workspaceId'
                gatewayLogEnabled = $settingHasGatewayLog
            })

        Write-Host ("  Diagnostic setting '{0}': GatewayLogs={1}" -f (Get-PropertyValue -InputObject $setting -Name 'name' -DefaultValue '(unnamed)'), $settingHasGatewayLog)
    }

    if ($gatewayLogEnabled) {
        Add-Finding -Severity 'Pass' -Code 'LOG-GATEWAY-ON' -Message 'GatewayLogs are being collected, so the 403 attribution query can run. ResponseCode is what APIM returned to the caller and BackendResponseCode is what Azure AI Search returned to APIM; divergence between the two is the definitive attribution.'
    }
    else {
        Add-Finding -Severity 'Critical' -Code 'LOG-GATEWAY-OFF' -Message 'No diagnostic setting collects GatewayLogs. This is the highest-value single diagnostic available: it answers whether APIM rejected the request or the backend did, which collapses the 403 hypothesis list from thirteen to roughly four. Enable it before any further 403 investigation.'
    }
}

$responseBodyBytes = $null
$samplingPercentage = $null
$diagnosticEntityName = $null

if (-not $isConsumptionTier) {
    $entityUrl = "https://management.azure.com{0}/diagnostics?api-version={1}" -f $apimResourceId, $ApiVersion
    $entityResult = Invoke-AzCommand -Argument (@('rest', '--method', 'get', '--url', $entityUrl, '--output', 'json') + $restArgument) -AllowFailure
    $entity = @(Get-PropertyValue -InputObject $entityResult -Name 'value' -DefaultValue @())

    foreach ($item in $entity) {
        $entityProperty = Get-PropertyValue -InputObject $item -Name 'properties'
        $sampling = Get-PropertyValue -InputObject $entityProperty -Name 'sampling'
        $backend = Get-PropertyValue -InputObject $entityProperty -Name 'backend'
        $backendResponse = Get-PropertyValue -InputObject $backend -Name 'response'
        $backendBody = Get-PropertyValue -InputObject $backendResponse -Name 'body'

        $diagnosticEntityName = [string](Get-PropertyValue -InputObject $item -Name 'name')
        $samplingPercentage = Get-PropertyValue -InputObject $sampling -Name 'percentage'
        $responseBodyBytes = Get-PropertyValue -InputObject $backendBody -Name 'bytes'

        Write-Host ("  Diagnostic entity '{0}': sampling={1}% backendResponseBodyBytes={2}" -f $diagnosticEntityName, $samplingPercentage, $responseBodyBytes)
    }

    if ($null -eq $responseBodyBytes -or [int]$responseBodyBytes -le 0) {
        Add-Finding -Severity 'Critical' -Code 'LOG-NO-BODY' -Message @'
Backend response-body logging is not configured. The field @search.semanticPartialResponseReason
is absent from the Azure AI Search resource-log schema and exists only in the HTTP response body,
so APIM response-body logging is the ONLY documented way to capture why a 206 partial response
occurred. Without it the 206 root cause cannot be proven from telemetry. This is the strongest
single argument for keeping APIM in the request path.
'@
    }
    else {
        Add-Finding -Severity 'Pass' -Code 'LOG-BODY-ON' -Message ("Backend response-body logging captures up to {0} bytes, which is enough to extract @search.semanticPartialResponseReason from 206 responses." -f $responseBodyBytes)
    }

    if ($null -ne $samplingPercentage -and [double]$samplingPercentage -lt 100) {
        Add-Finding -Severity 'Warning' -Code 'LOG-SAMPLED' -Message (
            "Gateway logging is sampled at {0}%. Intermittent failures are exactly the class of event sampling loses. Raise sampling to 100% for the duration of the investigation." -f $samplingPercentage)
    }
}

# --- Result assembly ---------------------------------------------------------------------------

$criticalCount = @($findings | Where-Object { $_.severity -eq 'Critical' }).Count
$warningCount = @($findings | Where-Object { $_.severity -eq 'Warning' }).Count

$result = [PSCustomObject]@{
    collectedAtUtc = [datetime]::UtcNow.ToString('o')
    scriptVersion  = '1.0.0'
    mode           = 'read-only'
    apim           = [PSCustomObject]@{
        name          = $ServiceName
        resourceGroup = $ResourceGroupName
        resourceId    = $apimResourceId
        location      = Get-PropertyValue -InputObject $apim -Name 'location'
        sku           = $skuName
        capacity      = $skuCapacity
        isConsumption = $isConsumptionTier
    }
    policyScopes   = $policyScope
    denialElements = $allMatch
    configuredHttpCodes = $configuredCode
    gatewayLogging = [PSCustomObject]@{
        gatewayLogsEnabled      = $gatewayLogEnabled
        diagnosticSettings      = $diagnosticSettingSummary
        diagnosticEntityName    = $diagnosticEntityName
        samplingPercentage      = $samplingPercentage
        backendResponseBodyBytes = $responseBodyBytes
    }
    findings       = $findings
    summary        = [PSCustomObject]@{
        criticalCount     = $criticalCount
        warningCount      = $warningCount
        quotaPolicyFound  = ($quotaMatch.Count -gt 0)
        ipFilterFound     = ($ipFilterMatch.Count -gt 0)
        scopesScanned     = $policyScope.Count
    }
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path -Path (Get-Location).Path -ChildPath ("apim-policy-audit-{0}-{1}.json" -f $ServiceName, ([datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ')))
}

$outputDirectory = Split-Path -Path $OutputPath -Parent
if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and -not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
}

$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding utf8

Write-Section -Title 'Summary'
Write-Host ("Scopes scanned    : {0}" -f $policyScope.Count)
Write-Host ("Critical findings : {0}" -f $criticalCount) -ForegroundColor $(if ($criticalCount -gt 0) { 'Red' } else { 'Green' })
Write-Host ("Warnings          : {0}" -f $warningCount) -ForegroundColor $(if ($warningCount -gt 0) { 'Yellow' } else { 'Green' })
Write-Host ("Evidence file     : {0}" -f $OutputPath)
Write-Host 'The evidence file contains full policy XML. Review it for embedded secrets before attaching it to a support request.' -ForegroundColor Yellow

return $result
