function Reset-WifiAdapter {
    Write-Host "Internet check failed. Bouncing Wi-Fi adapter..." -ForegroundColor Yellow
    
    # Target the Wi-Fi adapter specifically
    # -NoRestart can be omitted to let it bounce automatically, 
    # but explicitly disabling and enabling gives you clean logging hooks if needed.
    Get-NetAdapter | Where-Object { $_.Name -eq "Wi-Fi" } | Restart-NetAdapter    
    # Give the hardware a few seconds to initialize and reconnect before the script continues
    Start-Sleep -Seconds 7
    Write-Host "Wi-Fi adapter recycled." -ForegroundColor Green
}