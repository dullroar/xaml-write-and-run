<#
.SYNOPSIS
  Alternate host for launcher.xaml: proves that the write-then-run XAML chain is driven entirely by
  the XAML itself, not by anything specific to src/Loader.cs or the .NET compiler. This script does
  exactly what Loader.cs does -- bootstrap a WPF Application, clear data/, hand launcher.xaml to
  XamlReader.Load, run it -- just from PowerShell instead of a compiled executable. Every write,
  sleep, load, and Show() call in the chain is still declared in the .xaml files; nothing below
  participates in that chain.

.PARAMETER Path
  Path to the .xaml file to load. Defaults to launcher.xaml next to this script, so this also works
  as a generic "load and run this runtime XAML file" host for any other file in this repo (see
  src/launcher-remote.xaml once that variant exists).

.NOTES
  WPF needs an STA thread. The default Windows PowerShell (powershell.exe) console host already runs
  STA; on PowerShell 7+ launch with `pwsh -sta -File src/Launch.ps1`.
  Set $env:XWR_AUTO_EXIT_MS to auto-close after N milliseconds, for unattended/scripted runs.
#>
param(
    [string]$Path = (Join-Path $PSScriptRoot 'launcher.xaml')
)

$ErrorActionPreference = 'Stop'

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    throw "This script must run on an STA thread. Use powershell.exe, or 'pwsh -sta' on PowerShell 7+."
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

$resolvedPath = (Resolve-Path $Path).Path
$workDir = Split-Path -Parent $resolvedPath

# Push-Location only updates PowerShell's own $PWD; it does not reliably update the process-wide
# directory .NET's System.IO APIs read via Directory.GetCurrentDirectory() (confirmed to drift
# apart from $PWD specifically under `powershell.exe -File`). Every relative path inside
# launcher.xaml's declarative File.* calls resolves against THAT, not $PWD, so set both explicitly.
$originalDir = [System.IO.Directory]::GetCurrentDirectory()
Push-Location $workDir
[System.IO.Directory]::SetCurrentDirectory($workDir)
try {
    New-Item -ItemType Directory -Force -Path 'data' | Out-Null
    foreach ($stale in 'data/run.log', 'data/stage1.generated.xaml', 'data/stage2.generated.xaml') {
        if (Test-Path $stale) { Remove-Item -Force $stale }
    }

    $app = New-Object System.Windows.Application

    if ($env:XWR_AUTO_EXIT_MS) {
        $delayMs = [int]$env:XWR_AUTO_EXIT_MS
        $autoExitTimer = New-Object System.Windows.Threading.DispatcherTimer
        $autoExitTimer.Interval = [TimeSpan]::FromMilliseconds($delayMs)
        $autoExitTimer.Add_Tick({
            $autoExitTimer.Stop()
            $app.Shutdown()
        }.GetNewClosure())
        $autoExitTimer.Start()
    }

    $stream = [System.IO.File]::OpenRead($resolvedPath)
    try {
        $window = [System.Windows.Markup.XamlReader]::Load($stream)
    }
    finally {
        $stream.Dispose()
    }

    $app.Run($window) | Out-Null
}
finally {
    Pop-Location
    [System.IO.Directory]::SetCurrentDirectory($originalDir)
}
