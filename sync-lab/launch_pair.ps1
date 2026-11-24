param(
    [ValidateSet('Netcode', 'Fusion')] [string]$Backend = 'Netcode',
    [ValidateSet(32, 64, 128, 512, 1024)] [int]$Objects = 128,
    [ValidateRange(1024,65535)] [int]$Port = 43231,
    [string]$Room,
    [string]$CaptureDir,
    [string]$PlayerExe,
    [switch]$Trace,
    [switch]$DemoCheck,
    [switch]$Manual,
    [switch]$Editor
)

$ErrorActionPreference = 'Stop'
$runProject = -not $PlayerExe -or $Editor
$godot = $env:NETCODE_GODOT_EXE
if (-not $godot) {
    $godot = Join-Path $PSScriptRoot 'runtime/godot-4.6.1/Godot_v4.6.1-stable_win64.exe'
}
if ($runProject) {
    if (-not (Test-Path -LiteralPath $godot -PathType Leaf)) {
        throw 'Godot is missing. Put the official Windows x64 Godot 4.6.1 executables under runtime/godot-4.6.1.'
    }
    $godot = (Resolve-Path -LiteralPath $godot).Path
}
$exampleRoot = Split-Path -Parent $PSScriptRoot

$fusionExtension = Join-Path $PSScriptRoot 'addons/fusion/fusion.gdextension'
if ($runProject -and ($env:NETCODE_FUSION_ADDON -or ($Backend -eq 'Fusion' -and -not (Test-Path -LiteralPath $fusionExtension)))) {
    python -B (Join-Path $PSScriptRoot 'prepare_fusion.py')
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
$projectArgs = @('--path', ('"{0}"' -f $PSScriptRoot))
if ($runProject) {
    $cache = Join-Path $PSScriptRoot '.godot'
    New-Item -ItemType Directory -Force -Path $cache | Out-Null
    $extensions = @('res://addons/netcode/netcode.gdextension')
    if (Test-Path -LiteralPath $fusionExtension) {
        $extensions += 'res://addons/fusion/fusion.gdextension'
    }
    $extensions | Set-Content -Encoding Ascii -LiteralPath (Join-Path $cache 'extension_list.cfg')
}
$netcodeDll = Join-Path $PSScriptRoot 'addons/netcode/bin/netcode_godot.dll'
$archive = $env:NETCODE_BENCH_SDK
if (-not $archive -and $runProject -and -not (Test-Path -LiteralPath $netcodeDll)) {
    $candidate = Join-Path (Split-Path -Parent $exampleRoot) 'netcode/out/packages/godot-win-x64/current/netcode-godot-win-x64.zip'
    if (Test-Path -LiteralPath $candidate) { $archive = $candidate }
}
$stamp = Join-Path $PSScriptRoot '.godot/netcode-lab-sdk.sha256'
$archiveHash = if ($archive -and $runProject) { (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash }
$installedHash = if ($runProject -and (Test-Path -LiteralPath $stamp)) { (Get-Content -Raw -LiteralPath $stamp).Trim() }
if ($runProject -and (-not (Test-Path -LiteralPath $netcodeDll) -or ($archiveHash -and $archiveHash -ne $installedHash))) {
    $prepare = @('--project', $PSScriptRoot, '--godot-exe', $godot, '--no-import')
    if ($archive) { $prepare += @('--addon', $archive) }
    python -B (Join-Path $exampleRoot 'tools/prepare_godot_fps.py') @prepare
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    if ($archiveHash) { Set-Content -Encoding Ascii -LiteralPath $stamp -Value $archiveHash }
}

if ($Editor) {
    Start-Process -FilePath $godot -ArgumentList ($projectArgs + '--editor') -WindowStyle Normal
    exit
}

$clientExe = $godot
$clientArgs = $projectArgs
$clientDirectory = $PSScriptRoot
if (-not $runProject) {
    if (-not (Test-Path -LiteralPath $PlayerExe -PathType Leaf)) { throw "Windows player not found: $PlayerExe" }
    $clientExe = (Resolve-Path -LiteralPath $PlayerExe).Path
    $clientArgs = @()
    $clientDirectory = Split-Path -Parent $clientExe
}

Add-Type -AssemblyName System.Windows.Forms
$desktop = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$width = [Math]::Min(930, [Math]::Floor(($desktop.Width - 28) / 2))
$height = [Math]::Min(690, $desktop.Height - 72)
$top = $desktop.Top + 34
$left = $desktop.Left + 8
$right = $left + $width + 12

if ($Backend -eq 'Fusion') {
    if (-not $Room) { $Room = 'sync-lab-' + [Guid]::NewGuid().ToString('N').Substring(0, 12) }
    if ($Room -notmatch '^[a-zA-Z0-9_-]{1,80}$') { throw 'Use letters, numbers, underscore or hyphen in the room name.' }
    $endpoint = $Room
} else {
    $endpoint = "127.0.0.1:$Port"
}

$saveScreenshots = [bool]$CaptureDir
if ($Trace -and -not $CaptureDir) {
    $CaptureDir = Join-Path ([System.IO.Path]::GetTempPath()) ('sync-lab-trace-' + [Guid]::NewGuid().ToString('N').Substring(0, 12))
}
if ($CaptureDir) {
    New-Item -ItemType Directory -Force -Path $CaptureDir | Out-Null
    $CaptureDir = (Resolve-Path -LiteralPath $CaptureDir).Path
}
$demoVisibility = $null
if ($DemoCheck -and $CaptureDir) {
    $demoVisibility = Join-Path $CaptureDir ('guest-visibility-' + [Guid]::NewGuid().ToString('N') + '.txt')
}
$readyFile = Join-Path ([System.IO.Path]::GetTempPath()) ('sync-lab-' + [Guid]::NewGuid().ToString('N') + '.ready')
$traceReady = $null
$collector = $null
$tracePorts = $null
try {
    if ($Trace) {
        Write-Host "Sync Lab trace: $CaptureDir"
        if ($Backend -eq 'Fusion' -and $runProject) {
            $traceReady = "$readyFile.trace.json"
            $collectorArgs = $projectArgs + @('--headless', '--max-fps', '30', '--script', 'res://fusion_trace_receiver.gd',
                '--log-file', ('"{0}"' -f (Join-Path $CaptureDir 'collector.log')), '--',
                ('"{0}"' -f $CaptureDir), ('"{0}"' -f $traceReady))
            $collector = Start-Process -FilePath $godot -ArgumentList $collectorArgs -WindowStyle Hidden -PassThru
            $startupDeadline = [DateTime]::UtcNow.AddSeconds(8)
            while (-not $collector.HasExited -and [DateTime]::UtcNow -lt $startupDeadline) {
                if ((Test-Path -LiteralPath $traceReady) -and (Get-Item -LiteralPath $traceReady).Length -gt 0) { break }
                Start-Sleep -Milliseconds 100
            }
            if (-not $collector.HasExited -and (Test-Path -LiteralPath $traceReady)) {
                $tracePorts = Get-Content -Raw -LiteralPath $traceReady | ConvertFrom-Json
            }
            if (-not $tracePorts) { Write-Warning 'Fusion native trace collector did not start. Client trace logs will still be recorded.' }
        }
    }
    foreach ($side in @(@{ Role='--host'; Name='host'; X=$left }, @{ Role='--join'; Name='guest'; X=$right })) {
        $arguments = $clientArgs + @('--resolution', "${width}x${height}", '--position', "$($side.X),$top")
        if ($CaptureDir) { $arguments += @('--log-file', ('"{0}"' -f (Join-Path $CaptureDir "$($side.Name).log"))) }
        if ($tracePorts) { $arguments += @('--remote-debug', "tcp://127.0.0.1:$($tracePorts.($side.Name))") }
        $arguments += @('--', '--backend', $Backend, '--endpoint', $endpoint, '--objects', "$Objects")
        if (-not $Manual) {
            $arguments += $side.Role
            if ($side.Name -eq 'host') { $arguments += @('--host-ready', ('"{0}"' -f $readyFile)) }
        }
        if ($DemoCheck) { $arguments += '--demo-check' }
        if ($Trace) { $arguments += '--trace' }
        if ($demoVisibility) { $arguments += @('--demo-visibility', ('"{0}"' -f $demoVisibility)) }
        if ($saveScreenshots) { $arguments += @('--capture', ('"{0}"' -f (Join-Path $CaptureDir "$($side.Name).png"))) }
        $client = Start-Process -FilePath $clientExe -ArgumentList $arguments -WorkingDirectory $clientDirectory -WindowStyle Normal -PassThru
        $client | Select-Object Id, ProcessName
        if ($side.Name -eq 'host' -and -not $Manual) {
            $deadline = [DateTime]::UtcNow.AddSeconds(45)
            while (-not $client.HasExited -and -not (Test-Path -LiteralPath $readyFile) -and [DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 150
            }
        }
    }
} catch {
    if ($collector -and -not $collector.HasExited) { Stop-Process -Id $collector.Id -ErrorAction SilentlyContinue }
    throw
} finally {
    if (Test-Path -LiteralPath $readyFile) { Remove-Item -LiteralPath $readyFile }
    if ($traceReady -and (Test-Path -LiteralPath $traceReady)) { Remove-Item -LiteralPath $traceReady }
}
