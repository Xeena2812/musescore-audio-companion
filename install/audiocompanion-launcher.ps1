# URL-scheme handler for the Audio Companion plugin (Windows).
# Invoked as: audiocompanion-launcher.ps1 audiocompanion://start | audiocompanion://stop
param([string]$Url)
$Port = 9091; $Pass = 'musescore'
$action = ($Url -replace '^audiocompanion://', '') -replace '[/?#].*$', ''

function Test-Vlc {
    try {
        $h = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pass")) }
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 1 -Headers $h "http://127.0.0.1:$Port/requests/status.xml" | Out-Null
        return $true
    } catch { return $false }
}

switch ($action) {
    'start' {
        if (Test-Vlc) { exit 0 }
        $vlc = @("$env:ProgramFiles\VideoLAN\VLC\vlc.exe", "${env:ProgramFiles(x86)}\VideoLAN\VLC\vlc.exe") |
            Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $vlc) { exit 1 }
        Start-Process -WindowStyle Hidden $vlc -ArgumentList @('-I', 'dummy', '--extraintf', 'http',
            '--http-host', '127.0.0.1', '--http-port', $Port, '--http-password', $Pass, '--no-video', '--quiet')
    }
    'stop' {
        # Only the VLC listening on our port.
        $conn = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($conn) {
            $p = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
            if ($p -and $p.ProcessName -eq 'vlc') { Stop-Process -Id $p.Id }
        }
    }
}
