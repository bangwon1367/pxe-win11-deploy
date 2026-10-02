<#
.SYNOPSIS
    Build (or patch) the WinPE image used for network deployment.

.DESCRIPTION
    Runs on a Windows workstation with the Windows ADK + WinPE add-on installed
    ("Deployment and Imaging Tools Environment"). It:
      1. copype amd64            -> C:\WinPE_amd64
      2. mounts boot.wim index 1 -> adds PowerShell / WMI / Storage / Scripting / NetFX / DISM OCs
      3. injects NIC + storage drivers (the X1 Yoga has no wired NIC - you NEED the dock/USB NIC
         driver inside WinPE or the share mapping will fail)
      4. injects the payload (Deploy.ps1, startnet.cmd) and secrets.json
      5. writes recovery/scratch-space registry settings
      6. commits, then publishes media\Boot\{BCD,boot.sdi} + sources\boot.wim to the web root

.PARAMETER PublishPath
    UNC/absolute path to a copy of the server's nginx root (\\10.0.0.10\deploy\http-publish), or a
    local folder you scp/robocopy to /srv/http yourself. Layout written:
        <PublishPath>\winpe\Boot\BCD
        <PublishPath>\winpe\Boot\boot.sdi
        <PublishPath>\winpe\sources\boot.wim

.PARAMETER DriverPath
    Folder with WinPE .inf drivers (extract the Lenovo SCCM package's WinPE folder, plus the
    Realtek/Intel USB-LAN driver for your dock/dongle).

.EXAMPLE
    .\Make-WinPE.ps1 -DriverPath C:\drivers\winpe -PublishPath \\10.0.0.10\deploy\http-publish
#>
[CmdletBinding()]
param(
    [string]$WorkDir     = 'C:\WinPE_amd64',
    [string]$DriverPath  = 'C:\drivers\winpe',
    [string]$PublishPath = '',
    [string]$SecretsPath = (Join-Path $PSScriptRoot 'payload\secrets.json'),
    [switch]$SkipComponents,
    [switch]$MakeIso
)

$ErrorActionPreference = 'Stop'
$PayloadDir = Join-Path $PSScriptRoot 'payload'

function Write-Step { param([string]$m) Write-Host "== $m" -ForegroundColor Cyan }
function Invoke-Dism { param([string[]]$Arguments)
    & dism.exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "dism failed ($LASTEXITCODE): $($Arguments -join ' ')" }
}

# ---------------------------------------------------------------- prerequisites
Write-Step 'locating ADK / WinPE'
$adkRoots = @(
    "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit",
    "$env:ProgramFiles\Windows Kits\10\Assessment and Deployment Kit"
) | Where-Object { Test-Path $_ }
if (-not $adkRoots) { throw 'Windows ADK not found. Install the ADK + "Windows PE add-on for the ADK".' }
$deployTools = Join-Path $adkRoots[0] 'Deployment Tools\amd64\DISM'
if (-not (Test-Path (Join-Path $deployTools 'copype.cmd'))) { throw "copype.cmd not found under $adkRoots[0]" }

# Put the ADK tools on PATH for this session so wpeinit/dism/bcdboot resolve.
$env:Path = "$deployTools;$env:Path"

# ---------------------------------------------------------------- winpe skeleton
if (-not (Test-Path $WorkDir)) {
    Write-Step "copype amd64 -> $WorkDir"
    & cmd.exe /c "`"$(Join-Path $deployTools 'copype.cmd')`" amd64 `"$WorkDir`""
    if ($LASTEXITCODE -ne 0) { throw 'copype failed' }
}

$bootWim = Join-Path $WorkDir 'media\sources\boot.wim'
$mount   = Join-Path $WorkDir 'mount'
if (Test-Path $mount) { Invoke-Dism @('/Cleanup-Wim') }
New-Item -ItemType Directory -Force -Path $mount | Out-Null

Write-Step 'mounting boot.wim (index 1)'
Invoke-Dism @('/Mount-Image', "/ImageFile:$bootWim", '/Index:1', "/MountDir:$mount")

try {
    if (-not $SkipComponents) {
        Write-Step 'optional components'
        # Minimum set that makes a PowerShell-driven deployment comfortable in WinPE.
        $ocs = @(
            'WinPE-PowerShell',      # the engine itself
            'WinPE-DismCmdlets',     # DISM cmdlets (we shell out to dism.exe, but nice to have)
            'WinPE-StorageWMI',      # Get-Disk / New-Partition / Format-Volume
            'WinPE-WMI',             # WMI stack (StorageWMI depends on it)
            'WinPE-Scripting',       # cscript/wscript, some vendor tooling needs it
            'WinPE-NetFX',           # .NET Framework subset for PowerShell modules
            'WinPE-SecureStartup'    # TPM/BitLocker cmdlets: unlock an encrypted target if needed
        )
        foreach ($oc in $ocs) {
            $pkgDir = Get-ChildItem -Path (Join-Path $adkRoots[0] 'Windows Preinstallation Environment\amd64\WinPE_OCs') `
                                    -Filter "$oc.cab" -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $pkgDir) { Write-Warning "optional component $oc not found (is the WinPE add-on installed?)"; continue }
            Write-Host "   + $oc"
            Invoke-Dism @("/Image:$mount", '/Add-Package', "/PackagePath:$($pkgDir.FullName)")
            $langCab = Join-Path $pkgDir.DirectoryName "en-us\$oc" '_en-us.cab'
            $langDir = Get-ChildItem -Path (Join-Path $pkgDir.DirectoryName 'en-us') -Filter "$oc*.cab" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($langDir) { Invoke-Dism @("/Image:$mount", '/Add-Package', "/PackagePath:$($langDir.FullName)") }
        }
    }

    if (Test-Path $DriverPath) {
        Write-Step "injecting WinPE drivers from $DriverPath"
        # Recurse: the Lenovo SCCM package ships nested folders they expect you to point at.
        Invoke-Dism @("/Image:$mount", '/Add-Driver', "/Driver:$DriverPath", '/Recurse', '/ForceUnsigned')
    } else {
        Write-Warning "no WinPE drivers at $DriverPath - WinPE will have no network on most docks/dongles."
    }

    Write-Step 'injecting payload'
    $target = Join-Path $mount 'Deploy'
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Get-ChildItem $PayloadDir -Exclude 'secrets.example.json' |
        ForEach-Object { Copy-Item $_.FullName $target -Recurse -Force }
    if (Test-Path $SecretsPath) {
        Copy-Item $SecretsPath (Join-Path $target 'secrets.json') -Force
    } else {
        throw "missing $SecretsPath - copy payload\secrets.example.json to payload\secrets.json and fill it in."
    }
    Copy-Item (Join-Path $PayloadDir 'startnet.cmd') (Join-Path $mount 'Windows\System32\startnet.cmd') -Force

    Write-Step 'scratch space + logging'
    # Default 512 MB is tight for DISM /Apply-Image on big WIMs.
    Invoke-Dism @("/Image:$mount", '/Set-ScratchSpace:1024')
    # Persist a WinPE log so failures are diagnosable from Windows after the fact.
    $peReg = Join-Path $mount 'Windows\System32\config\SOFTWARE'
    $t = Join-Path $env:TEMP 'pehive'
    Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue
    & reg.exe load "HKLM\PEHIVE" $peReg | Out-Null
    & reg.exe add 'HKLM\PEHIVE\Microsoft\Windows NT\CurrentVersion\WinPE' /v LogPath /t REG_SZ /d 'X:\Deploy\logs' /f | Out-Null
    & reg.exe unload "HKLM\PEHIVE" | Out-Null
    Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue
}
finally {
    Write-Step 'committing boot.wim'
    Invoke-Dism @('/Unmount-Image', "/MountDir:$mount", '/Commit')
}

# ---------------------------------------------------------------- publish
if ($PublishPath) {
    Write-Step "publishing to $PublishPath"
    New-Item -ItemType Directory -Force -Path (Join-Path $PublishPath 'winpe\Boot'), (Join-Path $PublishPath 'winpe\sources') | Out-Null
    Copy-Item (Join-Path $WorkDir 'media\Boot\BCD')        (Join-Path $PublishPath 'winpe\Boot\BCD') -Force
    Copy-Item (Join-Path $WorkDir 'media\Boot\boot.sdi')   (Join-Path $PublishPath 'winpe\Boot\boot.sdi') -Force
    Copy-Item $bootWim                                     (Join-Path $PublishPath 'winpe\sources\boot.wim') -Force
    Get-ChildItem (Join-Path $PublishPath 'winpe') -Recurse -File |
        ForEach-Object { "{0,10:N0}  {1}" -f $_.Length, $_.FullName }
}

if ($MakeIso) {
    Write-Step 'ISO'
    & cmd.exe /c "`"$(Join-Path $deployTools 'MakeWinPEMedia.cmd')`" /ISO `"$WorkDir`" `"$WorkDir\WinPE_X1Yoga3.iso`""
}

Write-Host @"

WinPE ready. Next:
  * copy $WorkDir\media\Boot\{BCD,boot.sdi} and sources\boot.wim into /srv/http/winpe
    (or call this script with -PublishPath pointing at a staging folder)
  * boot the X1 Yoga: F12 -> network boot -> "Deploy Windows 11 26H2"
  * if the share mapping fails inside WinPE, it is almost always a missing NIC driver in
    $DriverPath (that machine has no built-in RJ45).
"@ -ForegroundColor Green
