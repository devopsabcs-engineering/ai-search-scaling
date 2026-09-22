#Requires -Version 7.0

<#
.SYNOPSIS
    Compares an Azure AI Search IP allow list against current Power Platform connector egress prefixes.

.DESCRIPTION
    Produces the direct evidence for the leading 403 hypothesis: that the Azure AI Search IP access
    control policy no longer covers every address the Power Platform connector egresses from.

    Azure AI Search rejects requests from addresses outside its allow list with HTTP 403 Forbidden.
    Power Platform connector egress spans every AzureConnectors.<Region> service tag in the
    geography, those prefixes change over time, and Microsoft advises refreshing them at least every
    90 days. Power Platform is not on the Azure AI Search trusted-services list, so there is no
    bypass. An allow list that covers most but not all current prefixes produces exactly the
    intermittent, index-agnostic 403 pattern reported.

    The script reads networkRuleSet.ipRules from the Search service, reads the current service tag
    prefixes with 'az network list-service-tags', performs CIDR containment arithmetic, and reports
    every connector prefix that is fully covered, partially covered, or entirely missing from the
    allow list. The missing-prefix list is the finding that confirms or refutes the hypothesis.

    The script performs no write operations. The only thing it writes is the local JSON evidence file.

    Only IPv4 prefixes are evaluated. The Azure AI Search IP access control policy accepts IPv4
    addresses and CIDR ranges, so IPv6 service tag prefixes are counted and reported but not
    compared.

.PARAMETER ResourceGroupName
    Resource group containing the Azure AI Search service. Required unless -IpRule is supplied.

.PARAMETER ServiceName
    Name of the Azure AI Search service. Required unless -IpRule is supplied.

.PARAMETER IpRule
    Explicit allow list to evaluate, as IPv4 addresses or CIDR ranges. Use this to evaluate a
    proposed allow list offline, without reading the live service.

.PARAMETER ConnectorRegion
    Azure region names whose AzureConnectors.<Region> service tags form the expected egress set,
    for example 'CanadaCentral','CanadaEast'. When omitted, every AzureConnectors service tag
    returned for the query location is evaluated, which is the conservative default.

.PARAMETER Location
    Azure region used to query the service tag list. Defaults to the Search service region. The
    service tag list itself is global; this parameter only selects the endpoint used to fetch it.

.PARAMETER IncludeGlobalTag
    Include the unsuffixed 'AzureConnectors' service tag in addition to the regional tags. The
    global tag is the union of all regions and produces a very large prefix set, so it is excluded
    by default.

.PARAMETER SubscriptionId
    Optional subscription ID. When omitted the current 'az account' context is used.

.PARAMETER OutputPath
    Path of the JSON evidence file. Defaults to a timestamped file in the current directory.

.EXAMPLE
    ./Compare-ConnectorEgressPrefixes.ps1 -ResourceGroupName 'rg-search' -ServiceName 'contoso-search' -ConnectorRegion 'CanadaCentral','CanadaEast'

    Compares the live allow list against the two Canadian connector service tags.

.EXAMPLE
    ./Compare-ConnectorEgressPrefixes.ps1 -IpRule '52.228.0.0/16','20.48.0.0/12' -ConnectorRegion 'CanadaCentral' -Location 'canadacentral'

    Evaluates a proposed allow list without reading the live Search service.

.OUTPUTS
    PSCustomObject describing the allow list, the connector prefix set, and the coverage result for
    every prefix. The same object is serialised to the JSON evidence file.

.NOTES
    Requires Azure CLI authenticated with Reader on the Search service and permission to call
    'az network list-service-tags'.
    Read-only. No Azure resource is created, modified, or deleted.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingWriteHost', '',
    Justification = 'This script produces an operator-facing console report where colour carries diagnostic severity.')]
[CmdletBinding(DefaultParameterSetName = 'FromService')]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory, ParameterSetName = 'FromService')]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory, ParameterSetName = 'FromService')]
    [ValidateNotNullOrEmpty()]
    [string]$ServiceName,

    [Parameter(Mandatory, ParameterSetName = 'FromLiteral')]
    [ValidateNotNullOrEmpty()]
    [string[]]$IpRule,

    [Parameter()]
    [string[]]$ConnectorRegion = @(),

    [Parameter(Mandatory, ParameterSetName = 'FromLiteral')]
    [Parameter(ParameterSetName = 'FromService')]
    [string]$Location,

    [Parameter()]
    [switch]$IncludeGlobalTag,

    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$OutputPath
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
        Invoke-AzCommand -Argument @('network','list-service-tags','--location','canadacentral','--output','json')
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
        Get-PropertyValue -InputObject $service -Name 'networkRuleSet'
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

function ConvertTo-IPv4Range {
    <#
    .SYNOPSIS
        Converts an IPv4 address or CIDR prefix into an inclusive numeric range.
    .DESCRIPTION
        Returns the first and last address of the prefix as unsigned 64-bit integers so that
        containment can be tested with simple comparisons. Returns $null for IPv6 input or for text
        that does not parse as IPv4.
    .PARAMETER Prefix
        An IPv4 address such as '52.228.1.5' or a CIDR prefix such as '52.228.0.0/16'.
    .EXAMPLE
        ConvertTo-IPv4Range -Prefix '52.228.0.0/16'
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Prefix
    )

    if ([string]::IsNullOrWhiteSpace($Prefix)) { return $null }
    $text = $Prefix.Trim()
    if ($text.Contains(':')) { return $null }

    $addressText = $text
    $maskLength = 32

    if ($text.Contains('/')) {
        $part = $text.Split('/', 2)
        $addressText = $part[0]
        if (-not [int]::TryParse($part[1], [ref]$maskLength)) { return $null }
        if ($maskLength -lt 0 -or $maskLength -gt 32) { return $null }
    }

    $address = [System.Net.IPAddress]::Any
    if (-not [System.Net.IPAddress]::TryParse($addressText, [ref]$address)) { return $null }
    if ($address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $null }

    $octet = $address.GetAddressBytes()
    [Array]::Reverse($octet)
    $value = [uint64][System.BitConverter]::ToUInt32($octet, 0)

    $size = [uint64][System.Math]::Pow(2, 32 - $maskLength)
    $start = $value - ($value % $size)
    $end = $start + $size - 1

    return [PSCustomObject]@{
        Text  = $text
        Start = $start
        End   = $end
        Size  = $size
    }
}

function Merge-IPv4Range {
    <#
    .SYNOPSIS
        Merges overlapping and adjacent IPv4 ranges into a minimal sorted set.
    .DESCRIPTION
        Merging first is what makes partial-coverage detection correct: a connector prefix may be
        covered by two adjacent allow-list entries that neither covers alone.
    .PARAMETER Range
        Ranges produced by ConvertTo-IPv4Range.
    .EXAMPLE
        Merge-IPv4Range -Range $allowRange
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [PSCustomObject[]]$Range
    )

    $merged = [System.Collections.Generic.List[PSCustomObject]]::new()
    if ($Range.Count -eq 0) { return $merged.ToArray() }

    foreach ($candidate in ($Range | Sort-Object -Property Start, End)) {
        if ($merged.Count -eq 0) {
            $merged.Add([PSCustomObject]@{ Start = $candidate.Start; End = $candidate.End })
            continue
        }

        $last = $merged[$merged.Count - 1]
        if ($candidate.Start -le ($last.End + 1)) {
            if ($candidate.End -gt $last.End) { $last.End = $candidate.End }
            continue
        }

        $merged.Add([PSCustomObject]@{ Start = $candidate.Start; End = $candidate.End })
    }

    return $merged.ToArray()
}

function Test-RangeCoverage {
    <#
    .SYNOPSIS
        Determines whether a candidate range is fully, partially, or not covered by an allow set.
    .PARAMETER Candidate
        Range to test, produced by ConvertTo-IPv4Range.
    .PARAMETER AllowRange
        Merged allow ranges produced by Merge-IPv4Range.
    .EXAMPLE
        Test-RangeCoverage -Candidate $prefixRange -AllowRange $mergedAllow
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Candidate,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [PSCustomObject[]]$AllowRange
    )

    [uint64]$coveredAddress = 0
    foreach ($allow in $AllowRange) {
        if ($allow.End -lt $Candidate.Start -or $allow.Start -gt $Candidate.End) { continue }
        $overlapStart = [System.Math]::Max([uint64]$allow.Start, [uint64]$Candidate.Start)
        $overlapEnd = [System.Math]::Min([uint64]$allow.End, [uint64]$Candidate.End)
        $coveredAddress += ($overlapEnd - $overlapStart + 1)
    }

    $status = if ($coveredAddress -eq 0) { 'Missing' }
    elseif ($coveredAddress -ge $Candidate.Size) { 'Covered' }
    else { 'Partial' }

    return [PSCustomObject]@{
        status           = $status
        addressCount     = $Candidate.Size
        coveredAddresses = $coveredAddress
    }
}

function Write-Section {
    <#
    .SYNOPSIS
        Writes a section heading to the console report.
    .PARAMETER Title
        Heading text.
    .EXAMPLE
        Write-Section -Title 'Coverage result'
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

# --- Execution -----------------------------------------------------------------------------

if (-not (Get-Command -Name 'az' -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) was not found on PATH. Install it from https://learn.microsoft.com/en-us/cli/azure/install-azure-cli and run "az login".'
}

$baseArgument = @('--output', 'json')
if ($PSBoundParameters.ContainsKey('SubscriptionId') -and -not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $baseArgument += @('--subscription', $SubscriptionId)
}

Write-Section -Title 'Connector egress prefix comparison'
Write-Host ("Collected at : {0}" -f ([datetime]::UtcNow.ToString('u')))
Write-Host ("Mode         : read-only (no Azure resource is modified)")

$allowRuleText = @()
$publicNetworkAccess = 'not evaluated'
$searchResourceId = $null

if ($PSCmdlet.ParameterSetName -eq 'FromService') {
    $service = Invoke-AzCommand -Argument (@('search', 'service', 'show', '--name', $ServiceName, '--resource-group', $ResourceGroupName) + $baseArgument)
    if ($null -eq $service) {
        throw "Azure AI Search service '$ServiceName' was not found in resource group '$ResourceGroupName', or the signed-in principal lacks Reader access."
    }

    $searchResourceId = [string](Get-PropertyValue -InputObject $service -Name 'id')
    $publicNetworkAccess = [string](Get-PropertyValue -InputObject $service -Name 'publicNetworkAccess' -DefaultValue 'unknown')
    $networkRuleSet = Get-PropertyValue -InputObject $service -Name 'networkRuleSet'
    $allowRuleText = @(Get-PropertyValue -InputObject $networkRuleSet -Name 'ipRules' -DefaultValue @() |
        ForEach-Object { [string](Get-PropertyValue -InputObject $_ -Name 'value') } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if ([string]::IsNullOrWhiteSpace($Location)) {
        $Location = [string](Get-PropertyValue -InputObject $service -Name 'location' -DefaultValue '')
    }

    Write-Host ("Search       : {0} ({1})" -f $ServiceName, $Location)
}
else {
    $allowRuleText = @($IpRule | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Write-Host ("Allow list   : supplied literally ({0} entries)" -f $allowRuleText.Count)
}

if ([string]::IsNullOrWhiteSpace($Location)) {
    throw 'A location is required to query the service tag list. Supply -Location, or use -ResourceGroupName and -ServiceName so the Search service region can be read.'
}

Write-Section -Title '1. Current Azure AI Search allow list'
Write-Host ("publicNetworkAccess : {0}" -f $publicNetworkAccess)
Write-Host ("ipRules count       : {0}" -f $allowRuleText.Count)
foreach ($rule in $allowRuleText) { Write-Host ("  - {0}" -f $rule) }

if ($publicNetworkAccess -ieq 'disabled') {
    Write-Host '[INFO    ] Public network access is disabled, so the IP allow list is not evaluated at request time. Traffic must arrive over a private endpoint; confirm how connector egress reaches the service.' -ForegroundColor Gray
}

if ($allowRuleText.Count -eq 0) {
    Write-Host '[PASS    ] No IP access control rules are configured, so the Azure AI Search IP firewall cannot be the source of the 403 responses. Redirect the investigation to the APIM policy hypotheses - run Get-ApimPolicyAudit.ps1.' -ForegroundColor Green
}

$allowRange = @()
$unparsedRule = @()
foreach ($rule in $allowRuleText) {
    $range = ConvertTo-IPv4Range -Prefix $rule
    if ($null -eq $range) { $unparsedRule += $rule; continue }
    $allowRange += $range
}

if ($unparsedRule.Count -gt 0) {
    Write-Host ("[WARNING ] {0} allow-list entries could not be parsed as IPv4 and were excluded: {1}" -f $unparsedRule.Count, ($unparsedRule -join ', ')) -ForegroundColor Yellow
}

$mergedAllow = Merge-IPv4Range -Range $allowRange

# --- Service tag retrieval -------------------------------------------------------------------

Write-Section -Title '2. Current AzureConnectors service tag prefixes'

$serviceTagResult = Invoke-AzCommand -Argument (@('network', 'list-service-tags', '--location', $Location) + $baseArgument)
$serviceTag = @(Get-PropertyValue -InputObject $serviceTagResult -Name 'values' -DefaultValue @())
$changeNumber = Get-PropertyValue -InputObject $serviceTagResult -Name 'changeNumber'
$cloudName = Get-PropertyValue -InputObject $serviceTagResult -Name 'cloud'

Write-Host ("Cloud         : {0}" -f $cloudName)
Write-Host ("Change number : {0}" -f $changeNumber)

$selectedTag = @($serviceTag | Where-Object {
        $tagName = [string](Get-PropertyValue -InputObject $_ -Name 'name')
        if (-not $tagName.StartsWith('AzureConnectors', [System.StringComparison]::OrdinalIgnoreCase)) { return $false }

        $isGlobal = $tagName -ieq 'AzureConnectors'
        if ($isGlobal) { return [bool]$IncludeGlobalTag }

        if ($ConnectorRegion.Count -eq 0) { return $true }

        $suffix = $tagName.Substring('AzureConnectors.'.Length)
        return [bool](@($ConnectorRegion | Where-Object { ($_ -ireplace '\s', '') -ieq $suffix }).Count)
    })

if ($selectedTag.Count -eq 0) {
    throw ("No AzureConnectors service tags matched. Regions requested: '{0}'. Service tag suffixes use the compact form such as 'CanadaCentral', not 'canada central'." -f ($ConnectorRegion -join ', '))
}

Write-Host ("Tags selected : {0}" -f (($selectedTag | ForEach-Object { Get-PropertyValue -InputObject $_ -Name 'name' }) -join ', '))

# --- Comparison --------------------------------------------------------------------------------

Write-Section -Title '3. Coverage comparison'

$coverage = [System.Collections.Generic.List[PSCustomObject]]::new()
$ipv6Count = 0

foreach ($tag in $selectedTag) {
    $tagName = [string](Get-PropertyValue -InputObject $tag -Name 'name')
    $tagProperty = Get-PropertyValue -InputObject $tag -Name 'properties'
    $addressPrefix = @(Get-PropertyValue -InputObject $tagProperty -Name 'addressPrefixes' -DefaultValue @())

    foreach ($prefix in $addressPrefix) {
        $range = ConvertTo-IPv4Range -Prefix ([string]$prefix)
        if ($null -eq $range) { $ipv6Count++; continue }

        $result = Test-RangeCoverage -Candidate $range -AllowRange $mergedAllow
        $coverage.Add([PSCustomObject]@{
                serviceTag       = $tagName
                prefix           = [string]$prefix
                status           = $result.status
                addressCount     = $result.addressCount
                coveredAddresses = $result.coveredAddresses
            })
    }
}

$missingPrefix = @($coverage | Where-Object { $_.status -eq 'Missing' })
$partialPrefix = @($coverage | Where-Object { $_.status -eq 'Partial' })
$coveredPrefix = @($coverage | Where-Object { $_.status -eq 'Covered' })

Write-Host ("IPv4 prefixes evaluated : {0}" -f $coverage.Count)
Write-Host ("IPv6 prefixes skipped   : {0}  (the Search IP access control policy accepts IPv4 only)" -f $ipv6Count)
Write-Host ("Covered                 : {0}" -f $coveredPrefix.Count) -ForegroundColor Green
Write-Host ("Partially covered       : {0}" -f $partialPrefix.Count) -ForegroundColor $(if ($partialPrefix.Count -gt 0) { 'Yellow' } else { 'Green' })
Write-Host ("Missing                 : {0}" -f $missingPrefix.Count) -ForegroundColor $(if ($missingPrefix.Count -gt 0) { 'Red' } else { 'Green' })

if ($allowRuleText.Count -eq 0) {
    Write-Host ''
    Write-Host 'No allow list is configured, so every connector prefix is reported as Missing by construction. That is not a finding - the firewall is simply not in use.' -ForegroundColor Gray
}
elseif ($missingPrefix.Count -gt 0 -or $partialPrefix.Count -gt 0) {
    Write-Section -Title '4. Prefixes absent from the allow list'
    Write-Host 'These are the addresses a Power Platform connector can egress from that Azure AI Search will reject with HTTP 403 Forbidden.' -ForegroundColor Red
    Write-Host ''
    foreach ($item in ($missingPrefix + $partialPrefix | Sort-Object -Property serviceTag, prefix)) {
        Write-Host ("  {0,-10} {1,-22} {2}" -f $item.status, $item.prefix, $item.serviceTag) -ForegroundColor $(if ($item.status -eq 'Missing') { 'Red' } else { 'Yellow' })
    }
    Write-Host ''
    Write-Host 'This is the direct evidence for the leading 403 hypothesis. Add these prefixes to networkRuleSet.ipRules, then allow at least 15 minutes before retesting - the documented propagation delay for Azure AI Search network configuration changes.' -ForegroundColor Yellow
    Write-Host 'Re-run this comparison at least every 90 days. Connector egress prefixes change, and a stale allow list reintroduces the same intermittent failure.' -ForegroundColor Yellow
}
else {
    Write-Section -Title '4. Result'
    Write-Host 'Every current connector egress prefix for the selected service tags is covered by the allow list. The Azure AI Search IP firewall does not explain the 403 responses; shift the investigation to the APIM policy hypotheses and per-index role assignments.' -ForegroundColor Green
}

# --- Result assembly ---------------------------------------------------------------------------

$result = [PSCustomObject]@{
    collectedAtUtc     = [datetime]::UtcNow.ToString('o')
    scriptVersion      = '1.0.0'
    mode               = 'read-only'
    search             = [PSCustomObject]@{
        name                = if ($PSCmdlet.ParameterSetName -eq 'FromService') { $ServiceName } else { $null }
        resourceGroup       = if ($PSCmdlet.ParameterSetName -eq 'FromService') { $ResourceGroupName } else { $null }
        resourceId          = $searchResourceId
        location            = $Location
        publicNetworkAccess = $publicNetworkAccess
        ipRules             = $allowRuleText
        unparsedIpRules     = $unparsedRule
    }
    serviceTags        = [PSCustomObject]@{
        cloud            = $cloudName
        changeNumber     = $changeNumber
        includeGlobalTag = [bool]$IncludeGlobalTag
        regionsRequested = $ConnectorRegion
        tagsEvaluated    = @($selectedTag | ForEach-Object { Get-PropertyValue -InputObject $_ -Name 'name' })
    }
    coverage           = $coverage
    missingPrefixes    = @($missingPrefix | ForEach-Object { $_.prefix })
    partialPrefixes    = @($partialPrefix | ForEach-Object { $_.prefix })
    summary            = [PSCustomObject]@{
        ipv4Evaluated    = $coverage.Count
        ipv6Skipped      = $ipv6Count
        coveredCount     = $coveredPrefix.Count
        partialCount     = $partialPrefix.Count
        missingCount     = $missingPrefix.Count
        allowListPresent = ($allowRuleText.Count -gt 0)
        hypothesisStatus = if ($allowRuleText.Count -eq 0) { 'not-applicable' }
        elseif ($missingPrefix.Count -gt 0 -or $partialPrefix.Count -gt 0) { 'supported' }
        else { 'refuted' }
    }
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $suffix = if ($PSCmdlet.ParameterSetName -eq 'FromService') { $ServiceName } else { 'literal' }
    $OutputPath = Join-Path -Path (Get-Location).Path -ChildPath ("connector-egress-comparison-{0}-{1}.json" -f $suffix, ([datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ')))
}

$outputDirectory = Split-Path -Path $OutputPath -Parent
if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and -not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
}

$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding utf8

Write-Section -Title 'Summary'
Write-Host ("Hypothesis status : {0}" -f $result.summary.hypothesisStatus)
Write-Host ("Evidence file     : {0}" -f $OutputPath)

return $result
