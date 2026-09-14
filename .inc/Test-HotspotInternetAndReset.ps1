# Initialize the persistent counter outside the function
if ($null -eq $script:ConsecutiveFailures) {
    $script:ConsecutiveFailures = 0
}

function Test-HotspotInternetAndReset {

    # 1. Get the current status of the Mobile Hotspot service
    $HotspotService = Get-Service -Name "icssvc" -ErrorAction SilentlyContinue
    if ($HotspotService.Status -ne 'Running') {
        Write-Host "[!] Hotspot service is stopped. Resetting immediately..." -ForegroundColor Yellow
        Restart-HotspotPipeline
        $script:ConsecutiveFailures = 0
        return
    }

    # 2. Check the specific Windows NCSI web probe
    $NcsiStatus = Get-NetConnectionProfile -IPv4Connectivity Internet -ErrorAction SilentlyContinue

    # 3. HTTP Web Request Test (With cache busting and connection closing)
    $InternetUp = $false
    try {
        $Request = [System.Net.WebRequest]::Create("http://www.msftconnecttest.com/connecttest.txt?cb=" + (Get-Random))
        $Request.Timeout = 2911
        $Request.KeepAlive = $false
        $Request.CachePolicy = New-Object System.Net.Cache.HttpRequestCachePolicy([System.Net.Cache.HttpRequestCacheLevel]::BypassCache)
        
        $Response = $Request.GetResponse()
        if ($Response.StatusCode -eq "OK") {
            $InternetUp = $true
        }
        $Response.Close()
    } catch {
        $InternetUp = $false
    }

    # Determine health: Both NCSI and our live Web Request must pass
    if ($NcsiStatus -and $InternetUp) {
        $script:ConsecutiveFailures = 0
        Write-Host "[+] Hotspot status is healthy: Connected & routing internet traffic." -ForegroundColor Green
    } else {
        $script:ConsecutiveFailures++
        
        $Reason = if (-not $NcsiStatus) { "NCSI profile down" } else { "HTTP Request Timeout/Fail" }
        Write-Host "[!] Warning: Internet check failed ($Reason). Strike $($script:ConsecutiveFailures) of 5..." -ForegroundColor Yellow

        # Execute reset ONLY if we hit 5 strikes in a row
        if ($script:ConsecutiveFailures -ge 5) {
            Write-Host "[!] ALERT: 5 consecutive failures detected. Triggering network stack reset..." -ForegroundColor Red
            
            Reset-WifiAdapter
            Restart-HotspotPipeline
            
            $script:ConsecutiveFailures = 0
        }
    }
}