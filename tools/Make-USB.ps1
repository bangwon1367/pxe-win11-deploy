<#
.SYNOPSIS
    Plan B: boot the very same deployment off a USB stick.

.DESCRIPTION
    The ThinkPad X1 Yoga 3rd Gen has no wired NIC, and UEFI PXE over a USB/dock Ethernet adapter
    simply is not exposed by every ThinkPad firmware. Booting WinPE from USB is the reliable path to
    the *same* automated deployment: identical payload, identical answer file, identical logging.

    Two variants:
      share mode (default)  the stick carries WinPE + payload + secrets.json. WinPE boots, the dock
                            NIC driver (already injected into boot.wim) comes up, and Deploy.ps1
                            pulls the image/drivers from the SMB share exactly like the PXE path.
      offline mode (-Offline) the stick additionally carries install.wim + drivers and Deploy.ps1 is
                            pointed at a local usb.json, so no server is needed at all. Needs a
                            >= 32 GB stick.

.EXAMPLE
    # build WinPE first (winpe\Make-WinPE.ps1), then:
    .\Make-USB.ps1 -WorkDir C:\WinPE_amd64 -Offline -MediaSource D:\ -DriverPath C:\drivers\x1yoga3-20LD
#>
[CmdletBinding()]
param(
    [string]$WorkDir    = 'C:\WinPE_amd64',
    [string]$PayloadDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'winpe\payload'),
    [string]$ConfigDir  = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config'),
    [string]$PostDir    = (Join-Path (Split-Path $PSScriptRoot -Parent) 'postinstall'),
    [string]$DriveLetter,
    [switch]$Offline,
    [string]$MediaSource,
    [string]$DriverPath,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
function Write-Step { param([string]$m) Write-Host "== $m" -ForegroundColor Cyan }

# ------------------------------------------------------------------ pick a stick
if (-not $DriveLetter) {
    $candidates = Get-Disk | Where-Object { $_.BusType -eq 'USB' -and -not $_.IsBoot -and $_.Size -ge 15GB } |
                  Sort-Object Size -Descending
    if (-not $candidates) { throw 'no USB disk >= 15 GB found; pass -DriveLetter X:' }
    $candidates | Select-Object Number, FriendlyName, @{n = 'GB'; e = { [int]($_.Size / 1GB) } } | Format-Table | Out-Host
    if ($candidates.Count -gt 1 -and -not $Force) {
        throw 'more than one candidate USB disk - pass -DriveLetter to choose (nothing was written)'
    }
    $disk = $candidates[0]
    Write-Warn "target disk $($disk.Number) ($($disk.FriendlyName)) will be ERASED"
    if (-not $Force) {
        $answer = Read-Host "type ERASE to continue"
        if ($answer -ne 'ERASE') { throw 'aborted' }
    }
    # MakeWinPEMedia /UFD takes a drive letter, so partition/format first.
    Clear-Disk -Number $disk.Number -RemoveData -RemoveOEM -Confirm:$false
    Initialize-Disk -Number $disk.Number -PartitionStyle MBR -Confirm:$false
    $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -MbrType FAT32 -IsActive
    $part | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'WINPE-DEPLOY' -Confirm:$false | Out-Null
    $part | Add-PartitionAccessPath -AssignDriveLetter
    $DriveLetter = "$(($part | Get-Partition | Get-Volume).DriveLetter):"
}
Write-Step "USB target: $DriveLetter"

# ------------------------------------------------------------------ winpe
$bootWim = Join-Path $WorkDir 'media\sources\boot.wim'
if (-not (Test-Path $bootWim)) { throw "no WinPE at $WorkDir - run winpe\Make-WinPE.ps1 first" }

$adk = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\DISM\MakeWinPEMedia.cmd" -ErrorAction SilentlyContinue |
       Select-Object -First 1
if (-not $adk) { throw 'MakeWinPEMedia.cmd not found - install the Windows ADK' }

Write-Step "writing WinPE to $DriveLetter (the whole stick is re-laid-out)"
& cmd.exe /c "`"$($adk.FullName)`" /UFD `"$WorkDir`" `"$DriveLetter`" /F"
if ($LASTEXITCODE -ne 0) { throw 'MakeWinPEMedia /UFD failed' }

# ------------------------------------------------------------------ payload onto the stick
Write-Step 'copying payload + config'
foreach ($pair in @(
    @{ src = $PayloadDir; dst = "$DriveLetter\Deploy" },
    @{ src = $PostDir;    dst = "$DriveLetter\postinstall" },
    @{ src = $ConfigDir;  dst = "$DriveLetter\config" }
)) {
    Copy-Item (Join-Path $pair.src '*') $pair.dst -Recurse -Force
}
if (-not (Test-Path "$DriveLetter\Deploy\secrets.json")) {
    Write-Warn "no secrets.json in $PayloadDir - share mode needs it (Deploy.ps1 will fail without)"
}

if ($Offline) {
    if (-not $MediaSource) { throw '-Offline needs -MediaSource pointing at the mounted Windows ISO or an extracted media folder' }
    Write-Step 'OFFLINE MODE: staging image + drivers onto the stick (this takes a while)'
    if (-not (Test-Path "$DriveLetter\images")) { New-Item -ItemType Directory "$DriveLetter\images" | Out-Null }
    if (-not (Test-Path "$DriveLetter\drivers")) { New-Item -ItemType Directory "$DriveLetter\drivers" | Out-Null }
    $srcWim = Join-Path $MediaSource 'sources\install.wim'
    if (-not (Test-Path $srcWim)) {
        throw "no $srcWim - export install.esd to install.wim first (images\Get-Win11Media.ps1 does it)"
    }
    Copy-Item $srcWim "$DriveLetter\images\install.wim" -Force
    if ($DriverPath) { Copy-Item (Join-Path $DriverPath '*') "$DriveLetter\drivers\" -Recurse -Force }

    Write-Step 'writing usb.json (Deploy.ps1 uses it instead of the network)'
    $wimInfo = & dism.exe /English /Get-WimInfo "/WimFile:$srcWim"
    $idx = $null
    foreach ($line in $wimInfo) {
        if ($line -match '^Index:\s*(\d+)') { $idx = [int]$matches[1] }
        elseif ($line -match '^Name:\s*(.+)$' -and $idx -and $matches[1] -match 'Pro$') { break }
    }
    $cfg = Get-Content (Join-Path $ConfigDir 'osd.json') -Raw | ConvertFrom-Json
    $cfg.Image.WimPath  = 'D:\images\install.wim'      # D: is the FAT32 data partition in WinPE
    $cfg.Drivers.Path   = 'D:\drivers'
    $cfg | ConvertTo-Json -Depth 8 | Set-Content "$DriveLetter\Deploy\usb.json" -Encoding UTF8
    Write-Warn 'offline mode: verify Image.EditionName/Index in usb.json against the table below'
    $wimInfo | Write-Host
}

Write-Host @"

USB ready: $DriveLetter

  Boot the X1 Yoga:  F12 at the Lenovo splash -> the USB device (UEFI entry) -> WinPE -> Deploy.ps1
  BIOS:              Startup -> Boot Mode = UEFI Only, USB = Enabled, Secure Boot = Disabled

"@ -ForegroundColor Green
