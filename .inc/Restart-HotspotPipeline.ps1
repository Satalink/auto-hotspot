function Restart-HotspotPipeline {
    Write-Host "[*] Executing network pipeline reset..." -ForegroundColor Yellow

    # Stop the sharing service
    Stop-Service -Name 'icssvc' -Force -ErrorAction SilentlyContinue

    # Cycle the specific virtual adapter responsible for the Wi-Fi broadcast
    Get-NetAdapter | Where-Object {$_.Name -eq 'Wi-Fi'} | Restart-NetAdapter -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 7

    # Restart the service
    Start-Service -Name 'icssvc' -ErrorAction SilentlyContinue

    # Programmatically flip the Windows 11 Mobile Hotspot switch back to ON
    try {
        $TetheringManager = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType=WindowsRuntime]::CreateFromConnectionProfile([Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile())
        if ($TetheringManager.TetheringCapability -eq 'Capable') {
            $TetheringManager.StartTetheringAsync() | Out-Null
            Write-Host "[+] Hotspot successfully toggled back ON." -ForegroundColor Green
        }
    } catch {
        Write-Host "[-] Failed to automatically toggle the hotspot switch. Manual intervention may be needed." -ForegroundColor Red
    }
}