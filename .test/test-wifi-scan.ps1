Add-Type -AssemblyName System.Runtime.WindowsRuntime

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$IncludeDir = Join-Path $ProjectRoot '.inc'

Write-Host "Project root: $ProjectRoot"
Write-Host "Include dir: $IncludeDir"

$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object {
        $_.Name -eq 'AsTask' -and
        $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]

$asTaskAction = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object {
        $_.Name -eq 'AsTask' -and
        $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.FullName -eq 'Windows.Foundation.IAsyncAction'
    })[0]

function Await-WinRtOperation($Operation, $ResultType) {
    $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
    $task = $asTask.Invoke($null, [object[]]@($Operation))
    $task.Wait(-1) | Out-Null
    return $task.Result
}

[Windows.Devices.WiFi.WiFiAdapter, Windows.Devices.WiFi, ContentType=WindowsRuntime] | Out-Null

$access = Await-WinRtOperation `
    ([Windows.Devices.WiFi.WiFiAdapter]::RequestAccessAsync()) `
    ([Windows.Devices.WiFi.WiFiAccessStatus])

Write-Host "Wi-Fi API access: $access"
if ($access -ne 'Allowed') {
    Write-Warning 'Wi-Fi API access was not allowed. Check Windows Location services.'
    exit 1
}

$adapters = Await-WinRtOperation `
    ([Windows.Devices.WiFi.WiFiAdapter]::FindAllAdaptersAsync()) `
    ([System.Collections.Generic.IReadOnlyList[Windows.Devices.WiFi.WiFiAdapter]])

Write-Host "Adapters found: $($adapters.Count)"
if ($adapters.Count -eq 0) {
    Write-Warning 'No Wi-Fi adapters were found.'
    exit 1
}

foreach ($adapter in $adapters) {
    Write-Host "Scanning adapter: $($adapter.NetworkAdapter.NetworkAdapterId)"
    $scanOperation = $adapter.ScanAsync()
    $scanTask = $asTaskAction.Invoke($null, [object[]]@($scanOperation))
    $completed = $scanTask.Wait(10000)

    if (-not $completed) {
        Write-Warning 'Scan timed out.'
        continue
    }

    $adapter.NetworkReport.AvailableNetworks |
        Select-Object Ssid, SignalBars, NetworkRssiInDecibelMilliwatts, ChannelCenterFrequencyInKilohertz |
        Sort-Object Ssid |
        Format-Table -AutoSize
}
