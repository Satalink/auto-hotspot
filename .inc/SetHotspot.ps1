
Function SetHotspot($Enable) {
    try {
        $connectionProfile = [Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime]::GetInternetConnectionProfile()

        if ($Enable -eq 1) {
            for ($i = 0; $i -lt 10; $i++) {
                if ($null -ne $connectionProfile) { break }
                Start-Sleep -Seconds 1
                $connectionProfile = [Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime]::GetInternetConnectionProfile()
            }
            if ($null -eq $connectionProfile) {
                Write-Host "[!] Windows has no active connection profile after waiting; hotspot cannot be enabled." -ForegroundColor Yellow
                return $false
            }
        } elseif ($null -eq $connectionProfile) {
            # Turning OFF but no internet profile exists. Windows inherently disables the hotspot.
            $script:LastLaptopHotspotEnabled = $false
            return $true
        }

        $tetheringManager = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]::CreateFromConnectionProfile($connectionProfile)
    } catch {
        Write-Host "[!] Windows could not read the tethering state; hotspot state was not changed." -ForegroundColor Yellow
        return $false
    }

    if ($Enable -eq 1) {
        if ($tetheringManager.TetheringOperationalState -eq 1) {
            $script:LastLaptopHotspotEnabled = $true
            return $true
        } else {
            Await ($tetheringManager.StartTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
            $script:LastLaptopHotspotEnabled = $true
            return $true
        }
    } else {
        if ($tetheringManager.TetheringOperationalState -eq 0 -or $tetheringManager.TetheringOperationalState -eq 2) {
            $script:LastLaptopHotspotEnabled = $false
            return $true
        } else {
            Await ($tetheringManager.StopTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
            $script:LastLaptopHotspotEnabled = $false
            return $true
        }
    }
}

function Get-LaptopHotspotEnabled {
    try {
        $connectionProfile = [Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime]::GetInternetConnectionProfile()
        if ($null -eq $connectionProfile) {
            # Without an internet connection, Windows cannot broadcast the mobile hotspot.
            $script:LastLaptopHotspotEnabled = $false
            return $false
        }

        $tetheringManager = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]::CreateFromConnectionProfile($connectionProfile)
        $enabled = ($tetheringManager.TetheringOperationalState -eq 1)
        $script:LastLaptopHotspotEnabled = $enabled
        return $enabled
    } catch {
        if ($null -ne $script:LastLaptopHotspotEnabled) {
            return $script:LastLaptopHotspotEnabled
        }
        return $false
    }
}