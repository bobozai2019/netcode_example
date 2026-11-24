@echo off
setlocal DisableDelayedExpansion
set "NETCODE_YARD_EXE=%~dp0out\build\win-x64\Release\bin\Release\netcode-yard.exe"

if not exist "%NETCODE_YARD_EXE%" (
    echo Cocos Release executable is missing:
    echo "%NETCODE_YARD_EXE%"
    pause
    exit /b 1
)

powershell.exe -NoProfile -Command ^
    "$ErrorActionPreference = 'Stop';" ^
    "$exe = $env:NETCODE_YARD_EXE; $dir = Split-Path -LiteralPath $exe;" ^
    "$network = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties();" ^
    "$used = @($network.GetActiveTcpListeners().Port) + @($network.GetActiveUdpListeners().Port);" ^
    "$port = 43210; while ($port -le 65535 -and $used -contains $port) { $port++ };" ^
    "if ($port -gt 65535) { throw 'No free port found at or above 43210.' };" ^
    "$server = Start-Process -FilePath $exe -WorkingDirectory $dir -ArgumentList @('--host', '--port', $port) -PassThru;" ^
    "$deadline = (Get-Date).AddSeconds(15);" ^
    "while (-not (Get-NetTCPConnection -State Listen -LocalPort $port -OwningProcess $server.Id -ErrorAction SilentlyContinue)) {" ^
    "    if ($server.HasExited) { throw ('Cocos host exited with code {0}.' -f $server.ExitCode) };" ^
    "    if ((Get-Date) -ge $deadline) { throw ('Cocos host did not listen on port {0} in time.' -f $port) };" ^
    "    Start-Sleep -Milliseconds 200;" ^
    "};" ^
    "Start-Process -FilePath $exe -WorkingDirectory $dir -ArgumentList @('--join', '127.0.0.1', '--port', $port);" ^
    "Write-Host ('Cocos host and guest started on port {0}.' -f $port);"

if errorlevel 1 (
    pause
    exit /b 1
)
