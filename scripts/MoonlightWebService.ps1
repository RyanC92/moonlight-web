#!/usr/bin/env pwsh
# =============================================================================
#  MoonlightWeb — Windows service wrapper (NSSM).
#
#  WHAT THIS IS
#      A thin, honest front end for NSSM (the Non-Sucking Service Manager).
#      NSSM supervises MoonlightWeb.exe so the server starts before anyone logs
#      in and restarts when it exits. The app itself already knows how to run
#      unsupervised: it checks MW_SERVICE and, when set, skips everything that
#      needs a desktop session (tray icon, display sleep, autostart entries,
#      self-update relaunch).
#
#  WHAT THIS IS NOT
#      - It does not generate certificates. The app creates cert/ itself on
#        first start, exactly as it does in the container.
#      - It does not write a config file. There is no config.json; settings live
#        in settings.json under Qt's AppDataLocation (see "WHERE STATE LIVES").
#      - It does not download NSSM. Download it yourself from https://nssm.cc/
#        and point -NssmPath at nssm.exe. Auto-downloading an unverified binary
#        and running it as a service is not something a security wrapper should
#        normalise.
#
#  WHERE STATE LIVES
#      Qt's AppDataLocation for organization=MoonlightWeb, application=
#      MoonlightWeb is:
#
#          %APPDATA%\MoonlightWeb\MoonlightWeb\
#              settings.json, cert\, logs\, security.log, ...
#
#      %APPDATA% is the *service account's* roaming profile. Run the service as
#      a dedicated local user, not LocalSystem: LocalSystem's profile lives
#      under C:\Windows\System32\config\systemprofile, and the app's native-host
#      installers (ViGEmBus, Inno Setup) break when started from a System32
#      path — see backend/src/common/WinSystemPath.h.
#
#  USAGE (elevated PowerShell)
#      .\MoonlightWebService.ps1 install -AppPath C:\Program Files\MoonlightWeb\MoonlightWeb.exe `
#          -ServiceAccount ".\MoonlightWebSvc" -LanOnly
#      .\MoonlightWebService.ps1 start | stop | restart | status | uninstall
#
#      The password for -ServiceAccount is prompted for, never taken from the
#      command line (a command line is visible to every process on the box).
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'uninstall', 'start', 'stop', 'restart', 'status', 'help')]
    [string]$Action = 'help',

    [string]$AppPath = 'C:\Program Files\MoonlightWeb\MoonlightWeb.exe',
    [string]$NssmPath = "$env:ProgramFiles\nssm\nssm.exe",
    [string]$LogPath = 'C:\ProgramData\MoonlightWeb\logs',
    [string]$ServiceAccount = '',
    [switch]$LanOnly,
    [int]$HttpPort = 8080,
    [int]$HttpsPort = 8443
)

$ErrorActionPreference = 'Stop'
$ServiceName = 'MoonlightWeb'

function Write-Step { param([string]$Text) Write-Host "[INFO]  $Text" -ForegroundColor Green }
function Write-Warn { param([string]$Text) Write-Host "[WARN]  $Text" -ForegroundColor Yellow }
function Write-Fail { param([string]$Text) Write-Host "[ERROR] $Text" -ForegroundColor Red }

function Assert-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This action needs an elevated PowerShell (Run as Administrator).'
    }
}

function Assert-Nssm {
    if (-not (Test-Path -LiteralPath $NssmPath)) {
        throw @"
NSSM was not found at: $NssmPath

Download it from https://nssm.cc/download, extract the x64 nssm.exe, and
either place it there or pass -NssmPath with its real location. This script
deliberately does not download it for you.
"@
    }
}

function Invoke-Nssm {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    & $NssmPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "nssm $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Assert-AppPresent {
    if (-not (Test-Path -LiteralPath $AppPath)) {
        throw "MoonlightWeb.exe not found at: $AppPath (build it with: cmd /c backend\build_msvc.bat)"
    }
    # The app links Qt; a bare exe copied without its DLLs will start and die
    # instantly, which NSSM reports as a restart loop. Say so up front.
    $qtCore = Join-Path (Split-Path -Parent $AppPath) 'Qt6Core.dll'
    if (-not (Test-Path -LiteralPath $qtCore)) {
        Write-Warn "Qt6Core.dll is not next to $AppPath."
        Write-Warn "Deploy the Qt runtime first, e.g. windeployqt.exe `"$AppPath`""
    }
}

function Test-ServiceExists {
    return $null -ne (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)
}

function Show-State {
    $profileHint = if ($ServiceAccount) { "the '$ServiceAccount' profile" } else { 'the service account profile' }
    Write-Host ''
    Write-Host '  Application : ' -NoNewline; Write-Host $AppPath
    Write-Host '  Supervisor  : ' -NoNewline; Write-Host $NssmPath
    Write-Host '  Service logs: ' -NoNewline; Write-Host $LogPath
    Write-Host '  App state   : ' -NoNewline
    Write-Host "%APPDATA%\MoonlightWeb\MoonlightWeb  (in $profileHint)"
    Write-Host '  Ports       : ' -NoNewline; Write-Host "http=$HttpPort https=$HttpsPort"
    Write-Host ''
    Write-Host '  First-run setup (run in a session of the service account):'
    Write-Host "    & '$AppPath' --set-admin-password"
    Write-Host "    & '$AppPath' --new-pin"
    Write-Host "    & '$AppPath' --status"
    Write-Host ''
    Write-Host '  The PIN is issued into the running server'"'"'s memory and is single-use;'
    Write-Host '  it cannot be pre-seeded by the installer.'
    Write-Host ''
}

function Install-Service {
    Assert-Elevated
    Assert-Nssm
    Assert-AppPresent

    if (Test-ServiceExists) {
        throw "Service '$ServiceName' already exists. Use 'restart', or 'uninstall' first."
    }
    if (-not (Test-Path -LiteralPath $LogPath)) {
        New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
    }

    Write-Step "Installing '$ServiceName' -> $AppPath"
    Invoke-Nssm install $ServiceName "`"$AppPath`""
    Invoke-Nssm set $ServiceName AppDirectory (Split-Path -Parent $AppPath)
    Invoke-Nssm set $ServiceName DisplayName 'MoonlightWeb'
    Invoke-Nssm set $ServiceName Description 'Browser-based Sunshine/GameStream server (headless service mode)'
    Invoke-Nssm set $ServiceName Start SERVICE_AUTO_START

    # MW_SERVICE is what makes the app headless: no tray, no desktop calls, no
    # relaunch-on-update. The port variables are the same ones the container
    # entrypoint writes into settings.json.
    $envLines = @(
        'MW_SERVICE=1',
        "MW_HTTP_PORT=$HttpPort",
        "MW_HTTPS_PORT=$HttpsPort"
    )
    if ($LanOnly) { $envLines += 'MW_LAN_ONLY=1' }
    Invoke-Nssm set $ServiceName AppEnvironmentExtra @envLines

    Invoke-Nssm set $ServiceName AppStdout (Join-Path $LogPath 'stdout.log')
    Invoke-Nssm set $ServiceName AppStderr (Join-Path $LogPath 'stderr.log')
    Invoke-Nssm set $ServiceName AppRotateFiles 1
    Invoke-Nssm set $ServiceName AppRotateOnline 1
    Invoke-Nssm set $ServiceName AppRotateBytes 10485760
    Invoke-Nssm set $ServiceName AppExit Default Restart
    Invoke-Nssm set $ServiceName AppRestartDelay 5000

    if ($ServiceAccount) {
        Write-Step "Running as $ServiceAccount"
        $secure = Read-Host -AsSecureString "Password for $ServiceAccount"
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        try {
            # nssm takes the password as an argument; it is handed straight to
            # the Service Control Manager and not written to disk by us.
            Invoke-Nssm set $ServiceName ObjectName $ServiceAccount $plain
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            $plain = $null
        }
        Write-Warn "Grant '$ServiceAccount' read/execute on $(Split-Path -Parent $AppPath) and modify on its AppData profile."
    } else {
        Write-Warn 'No -ServiceAccount given: the service will run as LocalSystem.'
        Write-Warn 'LocalSystem keeps its profile under System32\config\systemprofile;'
        Write-Warn 'the native-host installers (ViGEmBus) are known to fail from there.'
        Write-Warn 'Prefer -ServiceAccount ".\MoonlightWebSvc".'
    }

    Invoke-Nssm set $ServiceName AppThrottle 1500
    Write-Step 'Starting the service...'
    Invoke-Nssm start $ServiceName
    Start-Sleep -Seconds 3

    $svc = Get-Service -Name $ServiceName
    Write-Step "Service is $($svc.Status)."
    Show-State
}

function Uninstall-Service {
    Assert-Elevated
    Assert-Nssm
    if (-not (Test-ServiceExists)) { Write-Warn "Service '$ServiceName' is not installed."; return }

    Write-Step "Stopping and removing '$ServiceName'..."
    & $NssmPath stop $ServiceName 2>$null | Out-Null
    Invoke-Nssm remove $ServiceName confirm
    Write-Step 'Service removed.'
    Write-Host ''
    Write-Host '  State was NOT deleted. To remove it as well, delete:'
    Write-Host '    %APPDATA%\MoonlightWeb\MoonlightWeb  (in the service account profile)'
    Write-Host "    $LogPath"
    Write-Host ''
}

function Start-ServiceAction {
    Assert-Elevated; Assert-Nssm
    if (-not (Test-ServiceExists)) { throw "Service '$ServiceName' is not installed." }
    Invoke-Nssm start $ServiceName
    Start-Sleep -Seconds 2
    Write-Step "Service is $((Get-Service -Name $ServiceName).Status)."
}

function Stop-ServiceAction {
    Assert-Elevated; Assert-Nssm
    if (-not (Test-ServiceExists)) { throw "Service '$ServiceName' is not installed." }
    Invoke-Nssm stop $ServiceName
    Write-Step "Service is $((Get-Service -Name $ServiceName).Status)."
}

function Restart-ServiceAction {
    Assert-Elevated; Assert-Nssm
    if (-not (Test-ServiceExists)) { throw "Service '$ServiceName' is not installed." }
    Invoke-Nssm restart $ServiceName
    Start-Sleep -Seconds 2
    Write-Step "Service is $((Get-Service -Name $ServiceName).Status)."
}

function Show-Status {
    if (-not (Test-ServiceExists)) {
        Write-Warn "Service '$ServiceName' is not installed."
        return
    }
    $svc = Get-Service -Name $ServiceName
    Write-Host "Service : $($svc.Name)"
    Write-Host "Status  : $($svc.Status)"
    Write-Host "Startup : $($svc.StartType)"
    if ($svc.Status -eq 'Running') {
        Write-Step 'Listening check:'
        foreach ($port in @($HttpPort, $HttpsPort)) {
            $conn = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
            if ($conn) { Write-Host "  TCP $port  listening" }
            else { Write-Host "  TCP $port  not listening (the server may have fallen back)" }
        }
    } else {
        Write-Warn "Not running. Last NSSM output:"
        $err = Join-Path $LogPath 'stderr.log'
        if (Test-Path -LiteralPath $err) { Get-Content -LiteralPath $err -Tail 20 }
    }
}

function Show-Help {
    Write-Host @'
MoonlightWeb Windows service wrapper (NSSM)

  .\MoonlightWebService.ps1 install   [-AppPath ...] [-ServiceAccount ...] [-LanOnly]
  .\MoonlightWebService.ps1 start | stop | restart | status | uninstall

Parameters
  -AppPath         MoonlightWeb.exe to supervise
  -NssmPath        nssm.exe (download from https://nssm.cc/ ; not auto-fetched)
  -LogPath         NSSM stdout/stderr logs (default C:\ProgramData\MoonlightWeb\logs)
  -ServiceAccount  dedicated local account to run as (prompts for password)
  -LanOnly         set MW_LAN_ONLY=1 in the service environment
  -HttpPort        MW_HTTP_PORT  (default 8080)
  -HttpsPort       MW_HTTPS_PORT (default 8443)

The app's own state lives in %APPDATA%\MoonlightWeb\MoonlightWeb under the
service account. It is not configurable from this script because the app does
not read a data-path variable.
'@
}

switch ($Action) {
    'install'   { Install-Service }
    'uninstall' { Uninstall-Service }
    'start'     { Start-ServiceAction }
    'stop'      { Stop-ServiceAction }
    'restart'   { Restart-ServiceAction }
    'status'    { Show-Status }
    default     { Show-Help }
}
