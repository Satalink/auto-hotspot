
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$IncludeDir = Join-Path $PSScriptRoot ".inc"

# Scan and dot-source all files with the extension you prefer (e.g., .ps1 or .inc.ps1)
if (Test-Path $IncludeDir) {
    Get-ChildItem -Path $IncludeDir -Filter *.ps1 | ForEach-Object {
        . "$($_.FullName)"
    }
} else {
    Write-Warning "Include directory not found at: $IncludeDir"
    exit
}

function Parse-YamlScalar {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    $trimmed = $Value.Trim()
    if ($trimmed -match '^(?:"|'')(.+)(?:"|'')$') {
        return $Matches[1]
    }

    if ($trimmed -match '^(true|false)$') {
        return [bool]::Parse($trimmed)
    }

    if ($trimmed -match '^-?\d+$') {
        return [int]$trimmed
    }

    if ($trimmed -match '^-?\d+\.\d+$') {
        return [double]$trimmed
    }

    if ($trimmed -eq 'null' -or $trimmed -eq '~') {
        return $null
    }

    return $trimmed
}

function ConvertFrom-SimpleYaml {
    param(
        [Parameter(Mandatory)]
        [string]$YamlText
    )

    $result = [ordered]@{}
    $currentListKey = $null
    $currentList = $null

    foreach ($line in ($YamlText -split "`r?`n")) {
        if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        if ($line -match '^\s*-\s*(.+?)\s*$') {
            if (-not $currentListKey) {
                throw "YAML list item found without a key: $line"
            }

            $currentList += @(Parse-YamlScalar -Value $Matches[1])
            $result[$currentListKey] = $currentList
            continue
        }

        if ($line -match '^\s*([A-Za-z0-9_-]+)\s*:\s*(.*)\s*$') {
            $key = $Matches[1]
            $value = $Matches[2].Trim()
            $currentListKey = $null
            $currentList = $null

            if ($value -eq '') {
                $currentListKey = $key
                $currentList = @()
                $result[$key] = $currentList
                continue
            }

            $result[$key] = Parse-YamlScalar -Value $value
            continue
        }

        throw "Unsupported YAML line: $line"
    }

    return [pscustomobject]$result
}

# Load the external configuration file.
# This keeps Wi-Fi tiers and polling settings in a separate YAML document.
$ConfigPath = Join-Path $PSScriptRoot 'settings.yaml'
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath"
}

$YamlContent = Get-Content -LiteralPath $ConfigPath -Raw
if ([string]::IsNullOrWhiteSpace($YamlContent)) {
    throw "Configuration file is empty: $ConfigPath"
}

$Config = ConvertFrom-SimpleYaml -YamlText $YamlContent
$PhoneHotspotSsid = $Config.PhoneHotspotSsid
$FallbackSsids = @($Config.FallbackSsids)
$WifiInterfaceAlias = if ($Config.WifiInterfaceAlias) { $Config.WifiInterfaceAlias } else { 'Wi-Fi' }
$PollSeconds = if ($Config.PollSeconds) { [int]$Config.PollSeconds } else { 30 }
$PhoneUnavailableThreshold = if ($Config.PhoneUnavailableThreshold) { [int]$Config.PhoneUnavailableThreshold } else { 3 }
$PhoneProbeMinutes = if ($Config.PhoneProbeMinutes) { [int]$Config.PhoneProbeMinutes } else { 3 }

# MAIN
while ($true) {
    Invoke-WifiTierManager `
        -PhoneHotspotSsid $PhoneHotspotSsid `
        -FallbackSsids $FallbackSsids `
        -InterfaceAlias $WifiInterfaceAlias `
        -PhoneUnavailableThreshold $PhoneUnavailableThreshold `
        -PhoneProbeMinutes $PhoneProbeMinutes

    Start-Sleep -Seconds $PollSeconds
}
