function Get-NetshPath {
    $netshPath = Join-Path $env:SystemRoot 'System32\netsh.exe'
    if (-not (Test-Path -LiteralPath $netshPath)) {
        throw "Windows netsh.exe was not found at '$netshPath'."
    }

    return $netshPath
}

function Get-ConnectedWifiSsid {
    $netshPath = Get-NetshPath
    $interfaceOutput = & $netshPath wlan show interfaces 2>$null
    $ssidLine = $interfaceOutput | Where-Object { $_ -match '^\s*SSID\s*:\s*(.+)$' } | Select-Object -First 1

    if ($ssidLine -and $ssidLine -match '^\s*SSID\s*:\s*(.+)$') {
        return $Matches[1].Trim()
    }

    return $null
}

function Get-WifiAdapter {
    if ($script:WifiAdapter) {
        return $script:WifiAdapter
    }

    try {
        [Windows.Devices.WiFi.WiFiAdapter, Windows.Devices.WiFi, ContentType=WindowsRuntime] | Out-Null
        $access = Await ([Windows.Devices.WiFi.WiFiAdapter]::RequestAccessAsync()) ([Windows.Devices.WiFi.WiFiAccessStatus])
        if ($access -ne 'Allowed') {
            Write-Host "[!] Wi-Fi scan access is '$access'." -ForegroundColor Yellow
            return $null
        }

        $adapters = Await ([Windows.Devices.WiFi.WiFiAdapter]::FindAllAdaptersAsync()) ([System.Collections.Generic.IReadOnlyList[Windows.Devices.WiFi.WiFiAdapter]])
        if ($adapters.Count -eq 0) {
            Write-Host '[!] Windows found no Wi-Fi adapters for scanning.' -ForegroundColor Yellow
            return $null
        }

        $script:WifiAdapter = $adapters[0]
        return $script:WifiAdapter
    } catch {
        Write-Host "[!] Could not initialize Windows Wi-Fi scanning: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

function Test-WifiSsidAvailable {
    param(
        [Parameter(Mandatory)]
        [string]$Ssid
    )

    $adapter = Get-WifiAdapter
    if ($null -eq $adapter) {
        return $null
    }

    try {
        $scanOperation = $adapter.ScanAsync()
        $asTaskAction = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
            Where-Object {
                $_.Name -eq 'AsTask' -and
                $_.GetParameters().Count -eq 1 -and
                $_.GetParameters()[0].ParameterType.FullName -eq 'Windows.Foundation.IAsyncAction'
            })[0]

        if ($null -eq $asTaskAction) {
            Write-Host '[!] Windows Wi-Fi scan task adapter was not found.' -ForegroundColor Yellow
            return $null
        }

        $scanTask = $asTaskAction.Invoke($null, [object[]]@($scanOperation))
        if (-not $scanTask.Wait(10000)) {
            Write-Host '[!] Windows Wi-Fi scan timed out.' -ForegroundColor Yellow
            return $null
        }

        foreach ($network in $adapter.NetworkReport.AvailableNetworks) {
            if ($network.Ssid -eq $Ssid) {
                return $true
            }
        }

        return $false
    } catch {
        Write-Host "[!] Windows Wi-Fi scan failed: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

function Connect-WifiSsid {
    param(
        [Parameter(Mandatory)]
        [string]$Ssid,

        [string]$InterfaceAlias = 'Wi-Fi'
    )

    Write-Host "Connecting to Wi-Fi '$Ssid'..." -ForegroundColor Cyan
    $netshPath = Get-NetshPath
    $result = & $netshPath wlan connect name="$Ssid" interface="$InterfaceAlias" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[!] Could not connect to '$Ssid'. Make sure its Wi-Fi profile is saved on this laptop." -ForegroundColor Yellow
        return $false
    }

    Start-Sleep -Seconds 5
    return ((Get-ConnectedWifiSsid) -eq $Ssid)
}

function Set-LaptopHotspotState {
    param(
        [Parameter(Mandatory)]
        [bool]$Enabled
    )

    $currentState = Get-LaptopHotspotEnabled
    if ($currentState -eq $Enabled) {
        return $true
    }

    $changed = if ($Enabled) { SetHotspot(1) } else { SetHotspot(0) }
    if ($changed -or ((Get-LaptopHotspotEnabled) -eq $Enabled)) {
        return $true
    }

    Write-Host "[!] Could not confirm laptop hotspot state = $Enabled." -ForegroundColor Yellow
    return $false
}

function Invoke-NetworkRefresh {
    Write-Host "Refreshing DNS resolver state..." -ForegroundColor Cyan
    $ipconfigPath = Join-Path $env:SystemRoot 'System32\ipconfig.exe'
    if (Test-Path -LiteralPath $ipconfigPath) {
        & $ipconfigPath /flushdns | Out-Null
    } else {
        Write-Host "[!] Windows ipconfig.exe was not found at '$ipconfigPath'." -ForegroundColor Yellow
    }
}

function Invoke-PhoneHotspotProbe {
    param(
        [Parameter(Mandatory)]
        [string]$PhoneHotspotSsid,

        [Parameter(Mandatory)]
        [string]$InterfaceAlias
    )

    if (-not (Set-LaptopHotspotState -Enabled $false)) {
        Write-Host "[!] Could not pause laptop hotspot for phone probe." -ForegroundColor Yellow
        return $false
    }

    Start-Sleep -Seconds 3
    $phoneDetected = Test-WifiSsidAvailable -Ssid $PhoneHotspotSsid
    if ($phoneDetected -eq $true -and (Connect-WifiSsid -Ssid $PhoneHotspotSsid -InterfaceAlias $InterfaceAlias)) {
        Invoke-NetworkRefresh
        Write-Host "Phone hotspot '$PhoneHotspotSsid' detected during probe." -ForegroundColor Green
        return $true
    }

    Write-Host "Phone hotspot '$PhoneHotspotSsid' not detected during probe; restoring laptop hotspot." -ForegroundColor Yellow
    Set-LaptopHotspotState -Enabled $true | Out-Null
    return $false
}

function Invoke-WifiTierManager {
    param(
        [Parameter(Mandatory)]
        [string]$PhoneHotspotSsid,

        [Parameter(Mandatory)]
        [string[]]$FallbackSsids,

        [string]$InterfaceAlias = 'Wi-Fi',

        [ValidateRange(1, 5)]
        [int]$PhoneUnavailableThreshold = 3,

        [ValidateRange(1, 60)]
        [int]$PhoneProbeMinutes = 2
    )

    $connectedSsid = Get-ConnectedWifiSsid
    $laptopHotspotEnabled = Get-LaptopHotspotEnabled
    if ($null -eq $laptopHotspotEnabled) {
        $laptopHotspotEnabled = $script:LastLaptopHotspotEnabled
        if ($null -eq $laptopHotspotEnabled) {
            $laptopHotspotEnabled = $false
        }
        Write-Host "[!] Tethering state unavailable; retaining previous laptop-hotspot state: $laptopHotspotEnabled." -ForegroundColor Yellow
    }
    $phoneSsidVisible = Test-WifiSsidAvailable -Ssid $PhoneHotspotSsid

    # Windows does not list this laptop's own Mobile Hotspot in the scan, but
    # it does list the phone's Satalink SSID when the phone hotspot is active.
    if ($laptopHotspotEnabled) {
        $now = Get-Date
        $probeSlot = [math]::Floor($now.TimeOfDay.TotalMinutes / $PhoneProbeMinutes)
        $currentProbeSlotKey = "$($now.ToString('yyyy-MM-dd'))-$probeSlot"
        if ($null -eq $script:LastPhoneProbeSlotKey) {
            $script:LastPhoneProbeSlotKey = $currentProbeSlotKey
        }

        $probeDue = ($script:LastPhoneProbeSlotKey -ne $currentProbeSlotKey)
        if ($probeDue) {
            $script:LastPhoneProbeSlotKey = $currentProbeSlotKey
            if (Invoke-PhoneHotspotProbe -PhoneHotspotSsid $PhoneHotspotSsid -InterfaceAlias $InterfaceAlias) {
                $script:PhoneUnavailableMisses = 0
            }
            return
        }

        if ($phoneSsidVisible -eq $true) {
            # Stop tethering before changing the upstream profile. Windows can
            # invalidate the old connection profile during the switch.
            if (-not (Set-LaptopHotspotState -Enabled $false)) {
                Write-Host "[!] Phone hotspot detected, but laptop hotspot could not be stopped." -ForegroundColor Yellow
                return
            }

            if (-not (Connect-WifiSsid -Ssid $PhoneHotspotSsid -InterfaceAlias $InterfaceAlias)) {
                Write-Host "[!] Phone hotspot was visible but the connection did not complete." -ForegroundColor Yellow
                return
            }

            $script:PhoneUnavailableMisses = 0
            Invoke-NetworkRefresh
            Write-Host "Phone hotspot '$PhoneHotspotSsid' is connected." -ForegroundColor Green
            return
        }

        if ($null -eq $phoneSsidVisible) {
            Write-Host "[!] Phone hotspot scan unavailable; preserving the laptop hotspot tier." -ForegroundColor Yellow
            return
        }

        Write-Host "Laptop hotspot is active; phone hotspot is not detected." -ForegroundColor Green
        return
    }

    if ($null -eq $phoneSsidVisible) {
        Write-Host "[!] Phone hotspot scan unavailable; preserving the current tier." -ForegroundColor Yellow
        return
    }

    $phoneAvailable = ($phoneSsidVisible -eq $true) -and -not $laptopHotspotEnabled

    if ($phoneAvailable) {
        if ($connectedSsid -ne $PhoneHotspotSsid) {
            if (Connect-WifiSsid -Ssid $PhoneHotspotSsid -InterfaceAlias $InterfaceAlias) {
                Write-Host "Phone hotspot '$PhoneHotspotSsid' is connected." -ForegroundColor Green
                Invoke-NetworkRefresh
            } else {
                $phoneAvailable = $false
            }
        } else {
            Write-Host "Phone hotspot '$PhoneHotspotSsid' is connected." -ForegroundColor Green
        }

        if ($phoneAvailable) {
            $script:PhoneUnavailableMisses = 0
            return
        }
    }

    if ($null -eq $script:PhoneUnavailableMisses) {
        $script:PhoneUnavailableMisses = 0
    }
    $script:PhoneUnavailableMisses++
    Write-Host "Phone hotspot '$PhoneHotspotSsid' unavailable. Miss $($script:PhoneUnavailableMisses) of $PhoneUnavailableThreshold." -ForegroundColor Yellow

    if ($script:PhoneUnavailableMisses -lt $PhoneUnavailableThreshold) {
        return
    }

    Write-Host "Phone hotspot threshold reached; switching to fallback Wi-Fi." -ForegroundColor Yellow

    if ($connectedSsid -eq $PhoneHotspotSsid) {
        $netshPath = Get-NetshPath
        & $netshPath wlan disconnect interface="$InterfaceAlias" | Out-Null
        Start-Sleep -Seconds 2
        $connectedSsid = Get-ConnectedWifiSsid
        Write-Host "Phone hotspot '$PhoneHotspotSsid' is unavailable; disconnected." -ForegroundColor Yellow
    }

    foreach ($fallbackSsid in $FallbackSsids) {
        $fallbackAvailable = Test-WifiSsidAvailable -Ssid $fallbackSsid
        if ($fallbackAvailable -ne $true) {
            continue
        }

        if ($connectedSsid -eq $fallbackSsid) {
            Write-Host "Fallback Wi-Fi '$fallbackSsid' is connected." -ForegroundColor Green
            Set-LaptopHotspotState -Enabled $true | Out-Null
            $now = Get-Date
            $slot = [math]::Floor($now.TimeOfDay.TotalMinutes / $PhoneProbeMinutes)
            $script:LastPhoneProbeSlotKey = "$($now.ToString('yyyy-MM-dd'))-$slot"
            Invoke-NetworkRefresh
            return
        }

        if (Connect-WifiSsid -Ssid $fallbackSsid -InterfaceAlias $InterfaceAlias) {
            Write-Host "Connected to fallback Wi-Fi '$fallbackSsid'." -ForegroundColor Green
            Set-LaptopHotspotState -Enabled $true | Out-Null
            $now = Get-Date
            $slot = [math]::Floor($now.TimeOfDay.TotalMinutes / $PhoneProbeMinutes)
            $script:LastPhoneProbeSlotKey = "$($now.ToString('yyyy-MM-dd'))-$slot"
            Invoke-NetworkRefresh
            return
        }
    }

    Write-Host "[!] No configured Wi-Fi tier is currently available." -ForegroundColor Yellow
}