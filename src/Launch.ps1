<#
.SYNOPSIS
  The only host in this repo. Bootstraps a WPF Application, clears data/, hands a .xaml file to
  XamlReader.Load, runs it. Every write, sleep, download, load, and Show() call in either chain
  (launcher.xaml's local write-then-run chain, or launcher-remote.xaml's GitHub-fetch chain) is
  declared in the .xaml files themselves; nothing below participates in either chain -- this script
  exists only because something has to call XamlReader.Load and pump a WPF message loop.

  This repo originally also shipped a compiled .NET host (src/Loader.cs + a .csproj) alongside this
  script, to prove the write-then-run chain wasn't somehow C#-specific. Once that was proven (the
  exact same launcher.xaml ran unmodified under both), and once the GitHub-fetch variant confirmed a
  working path needs no compiled code at all either, the compiled host added nothing but a build
  step and a second thing to keep in sync -- so it's gone. Everything in this repo is now either a
  .xaml file or a .ps1 script: no compilation, nothing to build, nothing that isn't readable as plain
  text top to bottom.

.PARAMETER Path
  Path to the .xaml file to load. Defaults to launcher.xaml next to this script; pass
  launcher-remote.xaml to run the GitHub-fetch variant instead.

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
    foreach ($stale in 'data/run.log', 'data/stage1.generated.xaml', 'data/stage2.generated.xaml',
                       'data/phase1.downloaded.xaml', 'data/phase2.downloaded.xaml') {
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
