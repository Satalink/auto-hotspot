
Function SetHotspot($Enable) {
    try {
        $connectionProfile = [Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime]::GetInternetConnectionProfile()
        if ($null -eq $connectionProfile) {
            Write-Host "[!] Windows has no active connection profile; hotspot state was not changed." -ForegroundColor Yellow
            return $false
        }

        $tetheringManager = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]::CreateFromConnectionProfile($connectionProfile)
    } catch {
        Write-Host "[!] Windows could not read the tethering state; hotspot state was not changed." -ForegroundColor Yellow
        return $false
    }

    if ($Enable -eq 1) {
        if ($tetheringManager.TetheringOperationalState -eq 1)
        {
	    return $false
        }
        else{
            #"Hotspot is off! Turning it on"
            Await ($tetheringManager.StartTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
    		$script:LastLaptopHotspotEnabled = $true
		return $true
        }
    }
    else {
        if ($tetheringManager.TetheringOperationalState -eq 0)
        {
            #"Hotspot is already Off!"
	    return $false
        }
        else{
            #"Hotspot is on! Turning it off"
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
            return $null
        }

        $tetheringManager = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]::CreateFromConnectionProfile($connectionProfile)
        $enabled = ($tetheringManager.TetheringOperationalState -eq 1)
        $script:LastLaptopHotspotEnabled = $enabled
        return $enabled
    } catch {
        return $null
    }
}