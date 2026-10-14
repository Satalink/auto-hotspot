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
    if ($script:WifiAdapter) { return $script:WifiAdapter }

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

function Get-LocalMacAddresses {
    $macs = @()
    try {
        Get-CimInstance Win32_NetworkAdapter -Filter "MACAddress IS NOT NULL" -ErrorAction SilentlyContinue | ForEach-Object {
            $macs += ($_.MACAddress -replace '-', ':').ToUpper()
        }
        Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.MacAddress) {
                $macs += ($_.MacAddress -replace '-', ':').ToUpper()
            }
        }
    } catch { }

    $derivedMacs = @()
    foreach ($mac in $macs) {
        if ($mac -match '^([0-9A-F]{2})(:[0-9A-F]{2}){5}$') {
            $firstOctetHex = $Matches[1]
            $firstOctetInt = [Convert]::ToByte($firstOctetHex, 16)
            $localOctet = $firstOctetInt -bor 0x02
            $derived = "{0:X2}{1}" -f $localOctet, $mac.Substring(2)
            $derivedMacs += $derived
        }
    }
    return ($macs + $derivedMacs) | Select-Object -Unique
}

function Test-WifiSsidAvailable {
    param(
        [Parameter(Mandatory)]
        [string]$Ssid
    )

    $adapter = Get-WifiAdapter
    if ($null -eq $adapter) { return $null }

    $localMacs = Get-LocalMacAddresses

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

        $foundExternal = $false
        foreach ($network in $adapter.NetworkReport.AvailableNetworks) {
            if ($network.Ssid -eq $Ssid) {
                $networkBssid = ($network.Bssid -replace '-', ':').ToUpper()
                if (-not ($localMacs -contains $networkBssid)) {
                    $foundExternal = $true
                    break
                }
            }
        }
        
        return $foundExternal

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
    if ($changed) {
        for ($attempt = 0; $attempt -lt 5; $attempt++) {
            Start-Sleep -Seconds 1
            if ((Get-LaptopHotspotEnabled) -eq $Enabled) {
                return $true
            }
        }
    } elseif ((Get-LaptopHotspotEnabled) -eq $Enabled) {
        return $true
    }

    Write-Host "[!] Could not confirm laptop hotspot state = $Enabled. Restarting Windows Hotspot service to fix hang..." -ForegroundColor Yellow
    Stop-Service -Name "icssvc" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Service -Name "icssvc" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3

    if ((Get-LaptopHotspotEnabled) -eq $Enabled) {
        return $true
    }

    Write-Host "[!] Windows hotspot service is unresponsive." -ForegroundColor Red
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

function Invoke-WifiTierManager {
    param(
        [Parameter(Mandatory)]
        [string]$PhoneHotspotSSID,

        [Parameter(Mandatory)]
        [string[]]$FallbackSSIDs,

        [string]$InterfaceAlias = 'Wi-Fi',

        [int]$PhoneUnavailableThreshold = 3
    )

    $connectedSsid = Get-ConnectedWifiSsid
    $laptopHotspotEnabled = Get-LaptopHotspotEnabled
    if ($null -eq $laptopHotspotEnabled) {
        $laptopHotspotEnabled = $false
    }

    # If we are connected to the phone, we enforce the laptop hotspot to be OFF 
    # to avoid double-broadcasting the same Satalink name.
    if ($connectedSsid -eq $PhoneHotspotSSID -and $laptopHotspotEnabled) {
        Write-Host "Connected directly to Phone Hotspot; disabling local mirrored hotspot." -ForegroundColor Cyan
        Set-LaptopHotspotState -Enabled $false | Out-Null
        $laptopHotspotEnabled = $false
    }

    # Anti-Flap Check
    if ($null -ne $script:PhoneBlacklistUntil -and (Get-Date) -lt $script:PhoneBlacklistUntil) {
        $phoneSsidVisible = $false
    } else {
        $phoneSsidVisible = Test-WifiSsidAvailable -Ssid $PhoneHotspotSSID
    }

    if ($null -eq $phoneSsidVisible) {
        Write-Host "[!] Wi-Fi scan unavailable; preserving current state." -ForegroundColor Yellow
        return
    }

    # STATE 1: Already Connected to Phone
    if ($connectedSsid -eq $PhoneHotspotSSID) {
        if ($phoneSsidVisible) {
            $script:PhoneUnavailableMisses = 0
            Write-Host "Phone hotspot '$PhoneHotspotSSID' is connected." -ForegroundColor Green
            return
        }
    }

    # STATE 2: Phone is visible, but we are NOT connected to it
    if ($phoneSsidVisible -and $connectedSsid -ne $PhoneHotspotSSID) {
        if ($laptopHotspotEnabled) {
            Set-LaptopHotspotState -Enabled $false | Out-Null
            $laptopHotspotEnabled = $false
        }

        if (Connect-WifiSsid -Ssid $PhoneHotspotSSID -InterfaceAlias $InterfaceAlias) {
            Write-Host "Phone hotspot '$PhoneHotspotSSID' is connected." -ForegroundColor Green
            Invoke-NetworkRefresh
            $script:PhoneUnavailableMisses = 0
            return
        } else {
            Write-Host "[!] Phone hotspot was visible but connection failed (Stale Cache). Backing off for 3 minutes." -ForegroundColor Yellow
            $script:PhoneBlacklistUntil = (Get-Date).AddMinutes(3)
            return
        }
    }

    # STATE 3: Phone is NOT visible (or we missed it on a scan while connected)
    if ($connectedSsid -eq $PhoneHotspotSSID) {
        if ($null -eq $script:PhoneUnavailableMisses) { $script:PhoneUnavailableMisses = 0 }
        $script:PhoneUnavailableMisses++
        Write-Host "Phone hotspot '$PhoneHotspotSSID' scan missed. Miss $($script:PhoneUnavailableMisses) of $PhoneUnavailableThreshold." -ForegroundColor Yellow

        if ($script:PhoneUnavailableMisses -lt $PhoneUnavailableThreshold) {
            return
        }

        Write-Host "Phone hotspot threshold reached; disconnecting." -ForegroundColor Yellow
        $netshPath = Get-NetshPath
        & $netshPath wlan disconnect interface="$InterfaceAlias" | Out-Null
        Start-Sleep -Seconds 2
        $connectedSsid = Get-ConnectedWifiSsid
        
    } elseif ($connectedSsid -and ($FallbackSSIDs -contains $connectedSsid)) {
        # We are securely connected to the Fallback.
        if (-not $laptopHotspotEnabled) {
            if (-not (Set-LaptopHotspotState -Enabled $true)) {
                Write-Host "[!] Fallback Wi-Fi '$connectedSsid' is connected, but the laptop hotspot could not be enabled." -ForegroundColor Yellow
            } else {
                Write-Host "Fallback Wi-Fi '$connectedSsid' is connected; laptop hotspot is active." -ForegroundColor Green
            }
        } else {
            Write-Host "Fallback Wi-Fi '$connectedSsid' is connected; laptop hotspot is active." -ForegroundColor Green
        }
        $script:PhoneUnavailableMisses = 0
        return
    }

    # STATE 4: Disconnected. Search for Fallback.
    foreach ($fallbackSsid in $FallbackSSIDs) {
        $fallbackAvailable = Test-WifiSsidAvailable -Ssid $fallbackSsid
        if ($fallbackAvailable) {
            if (Connect-WifiSsid -Ssid $fallbackSsid -InterfaceAlias $InterfaceAlias) {
                Write-Host "Connected to fallback Wi-Fi '$fallbackSsid'." -ForegroundColor Green
                Set-LaptopHotspotState -Enabled $true | Out-Null
                Invoke-NetworkRefresh
                $script:PhoneUnavailableMisses = 0
                return
            }
        }
    }

    Write-Host "[!] No configured Wi-Fi tier is currently available." -ForegroundColor Yellow
}