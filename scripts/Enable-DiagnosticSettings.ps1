#Requires -Version 7.0

<#
.SYNOPSIS
    Enables the diagnostic settings the 206 and 403 investigations depend on.

.DESCRIPTION
    This is the only script in the package that writes to Azure. Every change is guarded by
    ShouldProcess, so -WhatIf shows the full plan without applying anything and the script prompts
    before each individual write.

    It closes three observability gaps, in the order they block the investigation:

    1. Azure AI Search diagnostic setting carrying both OperationLogs and AllMetrics. Without
       OperationLogs there is no per-query history, so every retrospective query in this package
       returns nothing.
    2. API Management GatewayLogs with 100% sampling, header capture, and backend response-body
       logging. Response-body logging matters disproportionately: the field
       @search.semanticPartialResponseReason is absent from the Azure AI Search resource-log schema
       and exists only in the HTTP response body, so APIM is the only documented place it can be
       captured.
    3. Copilot Studio export to Application Insights with "Log conversation details" enabled.
       That toggle has no Azure Resource Manager surface, so the script emits the exact portal steps
       rather than pretending to automate it.

    Two pre-flight checks run before any write:

    * Application Insights DisableLocalAuth. When it is set, Copilot Studio telemetry export fails
      SILENTLY - no error is surfaced anywhere and the connector dependency spans the 403 queries
      depend on are simply never emitted. The script reports this and explains the remediation.
    * API Management tier. The Consumption tier supports no resource logs at all, so the script
      refuses to attempt the gateway-log configuration against it and explains why.

.PARAMETER WorkspaceResourceId
    Full resource ID of the Log Analytics workspace that receives the diagnostic data.

.PARAMETER SearchServiceName
    Name of the Azure AI Search service. Supply with -SearchResourceGroupName to configure Search
    diagnostics; omit both to skip that step.

.PARAMETER SearchResourceGroupName
    Resource group containing the Azure AI Search service.

.PARAMETER ApimName
    Name of the API Management instance. Supply with -ApimResourceGroupName to configure gateway
    logging; omit both to skip that step.

.PARAMETER ApimResourceGroupName
    Resource group containing the API Management instance.

.PARAMETER ApimLoggerId
    Full resource ID of an existing API Management logger, used only when no diagnostic entity
    exists yet and one must be created. When a diagnostic entity already exists, its logger is
    reused and this parameter is ignored.

.PARAMETER AppInsightsName
    Name of the Application Insights component that receives Copilot Studio telemetry. Supply with
    -AppInsightsResourceGroupName to run the DisableLocalAuth pre-flight check.

.PARAMETER AppInsightsResourceGroupName
    Resource group containing the Application Insights component.

.PARAMETER DiagnosticSettingName
    Name given to the diagnostic settings this script creates. Defaults to 'ai-search-scaling-rca'.

.PARAMETER ResponseBodyByte
    Number of response-body bytes API Management captures. Defaults to 8192, which is the documented
    maximum and is required to reliably capture the semantic partial-response annotation.

.PARAMETER SubscriptionId
    Optional subscription ID. When omitted the current 'az account' context is used.

.PARAMETER ApiVersion
    ARM API version used for API Management diagnostic entity reads and writes. Defaults to '2022-08-01'.

.EXAMPLE
    ./Enable-DiagnosticSettings.ps1 -WorkspaceResourceId '/subscriptions/.../workspaces/law-obs' -SearchServiceName 'contoso-search' -SearchResourceGroupName 'rg-search' -WhatIf

    Shows every change the script would make without applying any of them. Run this first.

.EXAMPLE
    ./Enable-DiagnosticSettings.ps1 -WorkspaceResourceId '/subscriptions/.../workspaces/law-obs' -SearchServiceName 'contoso-search' -SearchResourceGroupName 'rg-search' -ApimName 'contoso-apim' -ApimResourceGroupName 'rg-apim' -AppInsightsName 'appi-shared' -AppInsightsResourceGroupName 'rg-obs'

    Runs both pre-flight checks, then prompts before each write.

.OUTPUTS
    PSCustomObject describing the pre-flight results and the outcome of each step.

.NOTES
    Requires Azure CLI authenticated with Contributor on the Search service, the API Management
    instance, and the Log Analytics workspace.
    WRITES to Azure. Run with -WhatIf first.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingWriteHost', '',
    Justification = 'This script produces an operator-facing console report where colour carries diagnostic severity.')]
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkspaceResourceId,

    [Parameter()]
    [string]$SearchServiceName,

    [Parameter()]
    [string]$SearchResourceGroupName,

    [Parameter()]
    [string]$ApimName,

    [Parameter()]
    [string]$ApimResourceGroupName,

    [Parameter()]
    [string]$ApimLoggerId,

    [Parameter()]
    [string]$AppInsightsName,

    [Parameter()]
    [string]$AppInsightsResourceGroupName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DiagnosticSettingName = 'ai-search-scaling-rca',

    [Parameter()]
    [ValidateRange(0, 8192)]
    [int]$ResponseBodyByte = 8192,

    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ApiVersion = '2022-08-01'
)

function Invoke-AzCommand {
    <#
    .SYNOPSIS
        Runs an Azure CLI command and returns its parsed JSON output.
    .DESCRIPTION
        Wraps 'az' so that stderr never contaminates the JSON payload and so that a non-zero exit
        code can either throw or return $null.
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
        Get-PropertyValue -InputObject $component -Name 'DisableLocalAuth' -DefaultValue $false
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
        Write-Section -Title 'Pre-flight checks'
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
        One of Critical, Warning, Pass, Skipped, or Info.
    .PARAMETER Message
        Finding text.
    .EXAMPLE
        Write-Finding -Severity 'Critical' -Message 'DisableLocalAuth is set.'
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Critical', 'Warning', 'Pass', 'Skipped', 'Info')]
        [string]$Severity,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    $colour = switch ($Severity) {
        'Critical' { 'Red' }
        'Warning' { 'Yellow' }
        'Pass' { 'Green' }
        'Skipped' { 'DarkGray' }
        default { 'Gray' }
    }
    $label = switch ($Severity) {
        'Critical' { '[CRITICAL]' }
        'Warning' { '[WARNING ]' }
        'Pass' { '[DONE    ]' }
        'Skipped' { '[SKIPPED ]' }
        default { '[INFO    ]' }
    }
    Write-Host ('{0} {1}' -f $label, $Message) -ForegroundColor $colour
}

function Show-CopilotStudioExportStep {
    <#
    .SYNOPSIS
        Prints the portal steps for enabling Copilot Studio telemetry export.
    .DESCRIPTION
        The Copilot Studio Application Insights export settings, including the
        "Log conversation details" toggle, have no Azure Resource Manager surface and cannot be set
        by Azure CLI. These steps are emitted so the customer can complete the configuration.
    .PARAMETER ConnectionStringHint
        Name of the Application Insights component to reference in the instructions.
    .EXAMPLE
        Show-CopilotStudioExportStep -ConnectionStringHint 'appi-shared'
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string]$ConnectionStringHint = '<your Application Insights component>'
    )

    Write-Host ''
    Write-Host 'Copilot Studio telemetry export - manual portal steps (no ARM surface exists):' -ForegroundColor Yellow
    Write-Host '  1. Open Copilot Studio and select the agent.'
    Write-Host '  2. Go to Settings > Advanced > Analytics (labelled "Application Insights" in some tenants).'
    Write-Host ("  3. Paste the connection string for {0}." -f $ConnectionStringHint)
    Write-Host '  4. Turn ON "Log conversation details".'
    Write-Host '     Without this toggle the connector dependency spans are not emitted, and every'
    Write-Host '     403 attribution query in this package returns no rows.'
    Write-Host '  5. Save, then start a new conversation. Existing sessions do not backfill.'
    Write-Host '  6. Confirm arrival with: dependencies | where timestamp > ago(30m) | summarize count() by type, name'
}

# --- Execution -----------------------------------------------------------------------------

if (-not (Get-Command -Name 'az' -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) was not found on PATH. Install it from https://learn.microsoft.com/en-us/cli/azure/install-azure-cli and run "az login".'
}

$baseArgument = @('--output', 'json')
$restArgument = @()
if ($PSBoundParameters.ContainsKey('SubscriptionId') -and -not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $baseArgument += @('--subscription', $SubscriptionId)
    $restArgument += @('--subscription', $SubscriptionId)
}

$configureSearch = -not [string]::IsNullOrWhiteSpace($SearchServiceName) -and -not [string]::IsNullOrWhiteSpace($SearchResourceGroupName)
$configureApim = -not [string]::IsNullOrWhiteSpace($ApimName) -and -not [string]::IsNullOrWhiteSpace($ApimResourceGroupName)
$checkAppInsights = -not [string]::IsNullOrWhiteSpace($AppInsightsName) -and -not [string]::IsNullOrWhiteSpace($AppInsightsResourceGroupName)

Write-Section -Title 'Telemetry enablement'
Write-Host ("Started at : {0}" -f ([datetime]::UtcNow.ToString('u')))
Write-Host ("Workspace  : {0}" -f $WorkspaceResourceId)
Write-Host ("Mode       : {0}" -f $(if ($WhatIfPreference) { 'WHAT-IF - no changes will be applied' } else { 'LIVE - each write is confirmed individually' })) -ForegroundColor $(if ($WhatIfPreference) { 'Cyan' } else { 'Yellow' })

# --- Pre-flight 1: Application Insights DisableLocalAuth ------------------------------------

Write-Section -Title 'Pre-flight 1: Application Insights local authentication'

$disableLocalAuth = $null
if ($checkAppInsights) {
    $component = Invoke-AzCommand -Argument (@('resource', 'show', '--resource-group', $AppInsightsResourceGroupName, '--name', $AppInsightsName, '--resource-type', 'Microsoft.Insights/components', '--api-version', '2020-02-02') + $baseArgument) -AllowFailure

    if ($null -eq $component) {
        Write-Finding -Severity 'Warning' -Message ("Application Insights component '{0}' could not be read in resource group '{1}'. The DisableLocalAuth pre-flight check was not performed. Confirm it manually before relying on Copilot Studio telemetry." -f $AppInsightsName, $AppInsightsResourceGroupName)
    }
    else {
        $componentProperty = Get-PropertyValue -InputObject $component -Name 'properties'
        $disableLocalAuth = [bool](Get-PropertyValue -InputObject $componentProperty -Name 'DisableLocalAuth' -DefaultValue $false)

        if ($disableLocalAuth) {
            Write-Finding -Severity 'Critical' -Message @'
DisableLocalAuth is TRUE on the target Application Insights component. Copilot Studio telemetry
export authenticates with the instrumentation key carried in the connection string, so with local
authentication disabled the export fails SILENTLY - no error appears in Copilot Studio, in the
component, or in any log. The connector dependency spans that the 403 attribution queries depend on
will simply never arrive.

Resolve one of these before enabling the Copilot Studio export:
  * Set DisableLocalAuth to false on this component, or
  * Point the Copilot Studio export at a different component that permits local authentication.

Azure diagnostic settings written by this script are unaffected: they use the Log Analytics
workspace ingestion path, not the instrumentation key.
'@
        }
        else {
            Write-Finding -Severity 'Pass' -Message 'DisableLocalAuth is false, so Copilot Studio telemetry export can authenticate with the connection string.'
        }
    }
}
else {
    Write-Finding -Severity 'Skipped' -Message 'No Application Insights component was supplied, so the DisableLocalAuth pre-flight check was skipped. Supply -AppInsightsName and -AppInsightsResourceGroupName to run it. This check is worth running: when DisableLocalAuth is set, Copilot Studio telemetry export fails with no error anywhere.'
}

# --- Pre-flight 2: API Management tier -------------------------------------------------------

Write-Section -Title 'Pre-flight 2: API Management tier'

$apimResourceId = $null
$apimSkuName = $null
$apimIsConsumption = $false

if ($configureApim) {
    $apim = Invoke-AzCommand -Argument (@('apim', 'show', '--name', $ApimName, '--resource-group', $ApimResourceGroupName) + $baseArgument)
    if ($null -eq $apim) {
        throw "API Management instance '$ApimName' was not found in resource group '$ApimResourceGroupName', or the signed-in principal lacks access."
    }

    $apimResourceId = [string](Get-PropertyValue -InputObject $apim -Name 'id')
    $apimSkuName = [string](Get-PropertyValue -InputObject (Get-PropertyValue -InputObject $apim -Name 'sku') -Name 'name' -DefaultValue 'unknown')
    $apimIsConsumption = $apimSkuName -ieq 'Consumption'

    if ($apimIsConsumption) {
        Write-Finding -Severity 'Critical' -Message @'
This API Management instance is on the CONSUMPTION tier, which supports no resource logs at all.
GatewayLogs cannot be collected and response-body logging is unavailable, so this script refuses to
attempt the gateway configuration. Both the 403 attribution query and the 206 partial-response
capture depend on gateway logs and cannot run against this gateway.

Options:
  * Move the instance to a tier that supports resource logs (Developer, Basic, Standard, Premium), or
  * Capture the evidence at the Azure AI Search and Application Insights layers only, accepting that
    @search.semanticPartialResponseReason cannot be observed anywhere.
'@
        $configureApim = $false
    }
    else {
        Write-Finding -Severity 'Pass' -Message ("The '{0}' tier supports resource logs, so gateway logging can be configured." -f $apimSkuName)
    }
}
else {
    Write-Finding -Severity 'Skipped' -Message 'No API Management instance was supplied, so the tier pre-flight check was skipped.'
}

# --- Step 1: Azure AI Search diagnostic setting ---------------------------------------------

Write-Section -Title 'Step 1: Azure AI Search diagnostic setting'

$searchStepResult = 'skipped'
if ($configureSearch) {
    $searchService = Invoke-AzCommand -Argument (@('search', 'service', 'show', '--name', $SearchServiceName, '--resource-group', $SearchResourceGroupName) + $baseArgument)
    if ($null -eq $searchService) {
        throw "Azure AI Search service '$SearchServiceName' was not found in resource group '$SearchResourceGroupName', or the signed-in principal lacks access."
    }

    $searchResourceId = [string](Get-PropertyValue -InputObject $searchService -Name 'id')
    $logDefinition = '[{"category":"OperationLogs","enabled":true}]'
    $metricDefinition = '[{"category":"AllMetrics","enabled":true}]'

    $target = "Azure AI Search '$SearchServiceName'"
    $action = "create diagnostic setting '$DiagnosticSettingName' with OperationLogs and AllMetrics sent to the Log Analytics workspace"

    if ($PSCmdlet.ShouldProcess($target, $action)) {
        $created = Invoke-AzCommand -Argument (@(
                'monitor', 'diagnostic-settings', 'create',
                '--name', $DiagnosticSettingName,
                '--resource', $searchResourceId,
                '--workspace', $WorkspaceResourceId,
                '--logs', $logDefinition,
                '--metrics', $metricDefinition) + $baseArgument)

        if ($null -ne $created) {
            $searchStepResult = 'created'
            Write-Finding -Severity 'Pass' -Message ("Diagnostic setting '{0}' now collects OperationLogs and AllMetrics for '{1}'. Query history begins accumulating from now; it is not backfilled." -f $DiagnosticSettingName, $SearchServiceName)
        }
        else {
            $searchStepResult = 'failed'
            Write-Finding -Severity 'Warning' -Message 'The diagnostic setting command returned no result. Verify the setting in the portal before relying on it.'
        }
    }
    else {
        $searchStepResult = 'declined'
        Write-Finding -Severity 'Skipped' -Message 'Search diagnostic setting was not applied.'
    }
}
else {
    Write-Finding -Severity 'Skipped' -Message 'No Azure AI Search service was supplied, so no Search diagnostic setting was configured. Without OperationLogs there is no per-query history and every retrospective query in this package returns nothing.'
}

# --- Step 2: API Management gateway logs ----------------------------------------------------

Write-Section -Title 'Step 2: API Management gateway logs and response-body capture'

$apimDiagnosticSettingResult = 'skipped'
$apimBodyLoggingResult = 'skipped'

if ($configureApim) {
    $logDefinition = '[{"category":"GatewayLogs","enabled":true}]'
    $metricDefinition = '[{"category":"AllMetrics","enabled":true}]'

    $target = "API Management '$ApimName'"
    $action = "create diagnostic setting '$DiagnosticSettingName' with GatewayLogs and AllMetrics sent to the Log Analytics workspace"

    if ($PSCmdlet.ShouldProcess($target, $action)) {
        $created = Invoke-AzCommand -Argument (@(
                'monitor', 'diagnostic-settings', 'create',
                '--name', $DiagnosticSettingName,
                '--resource', $apimResourceId,
                '--workspace', $WorkspaceResourceId,
                '--logs', $logDefinition,
                '--metrics', $metricDefinition) + $baseArgument)

        if ($null -ne $created) {
            $apimDiagnosticSettingResult = 'created'
            Write-Finding -Severity 'Pass' -Message 'GatewayLogs are now collected. ResponseCode is what API Management returned to Copilot Studio and BackendResponseCode is what Azure AI Search returned to API Management; divergence between the two is the definitive 403 attribution.'
        }
        else {
            $apimDiagnosticSettingResult = 'failed'
            Write-Finding -Severity 'Warning' -Message 'The gateway diagnostic setting command returned no result. Verify the setting in the portal.'
        }
    }
    else {
        $apimDiagnosticSettingResult = 'declined'
        Write-Finding -Severity 'Skipped' -Message 'Gateway diagnostic setting was not applied.'
    }

    # Sampling percentage and body capture live on the API Management diagnostic entity, not on the
    # Azure Monitor diagnostic setting, so they require a separate write.
    $entityUrl = "https://management.azure.com{0}/diagnostics?api-version={1}" -f $apimResourceId, $ApiVersion
    $entityResult = Invoke-AzCommand -Argument (@('rest', '--method', 'get', '--url', $entityUrl, '--output', 'json') + $restArgument) -AllowFailure
    $entity = @(Get-PropertyValue -InputObject $entityResult -Name 'value' -DefaultValue @())

    $entityName = $null
    $loggerId = $ApimLoggerId
    if ($entity.Count -gt 0) {
        $entityName = [string](Get-PropertyValue -InputObject $entity[0] -Name 'name')
        $existingLogger = [string](Get-PropertyValue -InputObject (Get-PropertyValue -InputObject $entity[0] -Name 'properties') -Name 'loggerId')
        if (-not [string]::IsNullOrWhiteSpace($existingLogger)) { $loggerId = $existingLogger }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ApimLoggerId)) {
        $entityName = 'applicationinsights'
    }

    if ([string]::IsNullOrWhiteSpace($entityName) -or [string]::IsNullOrWhiteSpace($loggerId)) {
        $apimBodyLoggingResult = 'blocked'
        Write-Finding -Severity 'Warning' -Message @'
No API Management diagnostic entity exists and no -ApimLoggerId was supplied, so sampling and
response-body capture could not be configured. Create an API Management logger first, then re-run
with -ApimLoggerId. Response-body capture is not optional for this investigation: the field
@search.semanticPartialResponseReason is absent from the Azure AI Search resource-log schema and
exists only in the HTTP response body.
'@
    }
    else {
        # Correlation headers only. Ocp-Apim-Subscription-Key and Authorization are deliberately
        # excluded so credentials are never written to the workspace.
        $headerList = @('request-id', 'x-ms-request-id', 'x-ms-client-request-id', 'elapsed-time')
        $bodyPayload = [ordered]@{
            properties = [ordered]@{
                loggerId                = $loggerId
                alwaysLog               = 'allErrors'
                verbosity               = 'information'
                httpCorrelationProtocol = 'W3C'
                sampling                = [ordered]@{ samplingType = 'fixed'; percentage = 100 }
                frontend                = [ordered]@{
                    request  = [ordered]@{ headers = $headerList }
                    response = [ordered]@{ headers = $headerList; body = [ordered]@{ bytes = $ResponseBodyByte } }
                }
                backend                 = [ordered]@{
                    request  = [ordered]@{ headers = $headerList }
                    response = [ordered]@{ headers = $headerList; body = [ordered]@{ bytes = $ResponseBodyByte } }
                }
            }
        }

        $target = "API Management diagnostic entity '$entityName' on '$ApimName'"
        $action = "set sampling to 100%, alwaysLog to allErrors, and capture $ResponseBodyByte response-body bytes on both frontend and backend"

        if ($PSCmdlet.ShouldProcess($target, $action)) {
            $payloadFile = [System.IO.Path]::GetTempFileName()
            try {
                ($bodyPayload | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $payloadFile -Encoding utf8
                $putUrl = "https://management.azure.com{0}/diagnostics/{1}?api-version={2}" -f $apimResourceId, $entityName, $ApiVersion
                $applied = Invoke-AzCommand -Argument (@(
                        'rest', '--method', 'put',
                        '--url', $putUrl,
                        '--headers', 'Content-Type=application/json',
                        '--body', ('@' + $payloadFile),
                        '--output', 'json') + $restArgument) -AllowFailure

                if ($null -ne $applied) {
                    $apimBodyLoggingResult = 'applied'
                    Write-Finding -Severity 'Pass' -Message ("Sampling is now 100% and up to {0} response-body bytes are captured. The 206 partial-response reason can now be extracted from BackendResponseBody." -f $ResponseBodyByte)
                    Write-Finding -Severity 'Warning' -Message 'Response bodies may contain customer content. Confirm the Log Analytics workspace retention and access controls meet the data-handling requirements for this workload, and turn body capture off once the investigation closes.'
                }
                else {
                    $apimBodyLoggingResult = 'failed'
                    Write-Finding -Severity 'Warning' -Message 'The diagnostic entity update returned no result. Verify sampling and body capture in the portal under the API Management instance diagnostic settings.'
                }
            }
            finally {
                Remove-Item -LiteralPath $payloadFile -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            $apimBodyLoggingResult = 'declined'
            Write-Finding -Severity 'Skipped' -Message 'Sampling and response-body capture were not applied.'
        }
    }
}
else {
    Write-Finding -Severity 'Skipped' -Message 'API Management gateway logging was not configured.'
}

# --- Step 3: Copilot Studio export ------------------------------------------------------------

Write-Section -Title 'Step 3: Copilot Studio export to Application Insights'

Write-Finding -Severity 'Info' -Message 'The Copilot Studio Application Insights export has no Azure Resource Manager surface, so it cannot be configured by this script. The portal steps follow.'
Show-CopilotStudioExportStep -ConnectionStringHint $(if ($checkAppInsights) { $AppInsightsName } else { '<your Application Insights component>' })

if ($true -eq $disableLocalAuth) {
    Write-Host ''
    Write-Finding -Severity 'Critical' -Message 'Do not complete the Copilot Studio steps above until DisableLocalAuth is resolved. The export will appear to succeed and emit nothing.'
}

# --- Result assembly ---------------------------------------------------------------------------

$result = [PSCustomObject]@{
    startedAtUtc = [datetime]::UtcNow.ToString('o')
    scriptVersion = '1.0.0'
    whatIfMode    = [bool]$WhatIfPreference
    preflight     = [PSCustomObject]@{
        appInsightsChecked       = $checkAppInsights
        appInsightsDisableLocalAuth = $disableLocalAuth
        apimSku                  = $apimSkuName
        apimIsConsumption        = $apimIsConsumption
    }
    steps         = [PSCustomObject]@{
        searchDiagnosticSetting = $searchStepResult
        apimDiagnosticSetting   = $apimDiagnosticSettingResult
        apimBodyLogging         = $apimBodyLoggingResult
        copilotStudioExport     = 'manual'
    }
}

Write-Section -Title 'Summary'
Write-Host ("Search diagnostic setting : {0}" -f $searchStepResult)
Write-Host ("APIM diagnostic setting   : {0}" -f $apimDiagnosticSettingResult)
Write-Host ("APIM body logging         : {0}" -f $apimBodyLoggingResult)
Write-Host ("Copilot Studio export     : manual (portal steps printed above)")
Write-Host ''
Write-Host 'Telemetry is not backfilled. Allow one full business day of traffic before running the KQL library, and start a new Copilot Studio conversation to generate connector spans.' -ForegroundColor Yellow

return $result
