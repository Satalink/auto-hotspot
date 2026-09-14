function Reset-HotspotHardware {
    <#
    .SYNOPSIS
        Mimics Device Manager to hard reset the Virtual Wi-Fi Direct Adapter.
    .OUTPUTS
        [bool] - Returns $true if successfully cycled, $false if it failed or lacked admin rights.
    #>
    Write-Host "[*] Initiating Device Manager level hardware cycle..." -ForegroundColor Yellow

    # 1. Verify administrative privileges (Required for PnP hardware manipulation)
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "[-] ERROR: Reset-HotspotHardware requires an Administrator shell." -ForegroundColor Red
        return $false
    }

    # 2. Locate the specific virtual target device
    $VirtualDevice = Get-PnpDevice -FriendlyName "*Wi-Fi Direct Virtual*" -Status OK, Error, Degraded -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not $VirtualDevice) {
        Write-Host "[-] ERROR: Microsoft Wi-Fi Direct Virtual Adapter not found in Device Manager." -ForegroundColor Red
        return $false
    }

    try {
        # 3. Halt the network sharing service to release hooks on the hardware
        Stop-Service -Name 'icssvc' -Force -ErrorAction SilentlyContinue

        # 4. Hardware Disable (Mimics right-click -> Disable device)
        Write-Host "[*] Disabling $($VirtualDevice.FriendlyName)..." -ForegroundColor Gray
        Disable-PnpDevice -InstanceId $VirtualDevice.InstanceId -Confirm:$false -ErrorAction Stop
        Start-Sleep -Seconds 3

        # 5. Hardware Enable (Mimics right-click -> Enable device)
        Write-Host "[*] Enabling $($VirtualDevice.FriendlyName)..." -ForegroundColor Gray
        Enable-PnpDevice -InstanceId $VirtualDevice.InstanceId -Confirm:$false -ErrorAction Stop
        Start-Sleep -Seconds 3

        # 6. Kick the background service back into gear
        Start-Service -Name 'icssvc' -ErrorAction SilentlyContinue
        
        Write-Host "[+] Hardware cycle completed successfully." -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "[-] Critical failure during hardware cycle: $_" -ForegroundColor Red
        return $false
    }
}