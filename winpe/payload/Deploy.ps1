<#
.SYNOPSIS
    pxe-win11-deploy - the deployment engine. Runs inside WinPE.

.DESCRIPTION
    Two modes:

      share mode (normal)   read share credentials from secrets.json (baked into the WinPE image),
                            map the deploy share as Z:, then read config\osd.json FROM THE SHARE -
                            so day-to-day changes never require a WinPE rebuild.

      usb-local mode        if X:\Deploy\usb.json exists (written by tools\Make-USB.ps1 -Offline) the
                            script never touches the network: config, image, drivers and logs all
                            live on the USB stick. Use it when the target has no PXE-capable NIC.

    Then, identically in both modes:
      1. select the internal disk, wipe it, lay down GPT (EFI / MSR / Windows)
      2. DISM: apply install.wim, inject model drivers, optionally slip in the 26H2 enablement package
      3. drop unattend.xml + the first-boot payload, wire SetupComplete.cmd
      4. bcdboot, record the deployment, reboot

    Everything is logged to X:\Deploy\logs and copied to <share|usb>\logs before the reboot.

.NOTES
    Defaults target the Lenovo ThinkPad X1 Yoga 3rd Gen (20LD/20LE/20LF/20LG).
#>
[CmdletBinding()]
param(
    [string]$SecretsPath = 'X:\Deploy\secrets.json',
    [string]$ConfigPath  = 'Z:\config\osd.json',
    [string]$UsbConfig   = 'X:\Deploy\usb.json',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$script:LogDir = 'X:\Deploy\logs'
New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Start-Transcript -Path (Join-Path $script:LogDir "deploy-$stamp.log") -Force | Out-Null

function Write-Step { param([string]$m) Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) -ForegroundColor Cyan }
function Invoke-Dism {
    param([string[]]$Arguments, [string]$What = 'dism')
    $log = Join-Path $script:LogDir ("{0}-{1}.log" -f ($What -replace '[^\w]', '-'), $stamp)
    & dism.exe @Arguments "/LogPath:$log"
    if ($LASTEXITCODE -ne 0) { throw "$What failed with exit code $LASTEXITCODE (see $log)" }
}

$outLog = $null; $outState = $null
function Copy-Transcripts {
    param([string]$Destination)
    if ($Destination -and (Test-Path $Destination)) {
        Copy-Item (Join-Path $script:LogDir '*') $Destination -Force -ErrorAction SilentlyContinue
    }
}

try {
    # ============================================================ 1. mode, config, source root
    $localMode = Test-Path $UsbConfig

    if ($localMode) {
        Write-Step "USB-local mode ($UsbConfig) - no network required"
        $cfg = Get-Content -LiteralPath $UsbConfig -Raw | ConvertFrom-Json
        $src      = Split-Path -Parent $UsbConfig     # X:\Deploy - config\ postinstall\ logs\ live here
        $outLog   = Join-Path $src 'logs'
        $outState = Join-Path $src 'state'
    }
    else {
        if (-not (Test-Path $SecretsPath)) { throw "secrets.json missing at $SecretsPath - rebuild WinPE with Make-WinPE.ps1" }
        $secrets = Get-Content -LiteralPath $SecretsPath -Raw | ConvertFrom-Json
        foreach ($k in 'Share', 'ShareUser', 'SharePassword') {
            if (-not $secrets.$k) { throw "secrets.json is missing '$k'" }
        }

        Write-Step "mapping $($secrets.Share)"
        & net.exe use Z: $secrets.Share $secrets.SharePassword "/user:$($secrets.ShareUser)" /persistent:no | Out-Null
        if (-not (Test-Path 'Z:\')) {
            throw "could not map $($secrets.Share) - wrong credentials, or WinPE has no NIC driver (that laptop has no built-in RJ45)"
        }

        if (-not (Test-Path $ConfigPath)) { throw "config not found at $ConfigPath" }
        $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
        $src      = 'Z:\'
        $outLog   = $cfg.Logging.ShareLogPath
        $outState = $cfg.Logging.ShareStatePath
    }

    New-Item -ItemType Directory -Force -Path $outLog, $outState -ErrorAction SilentlyContinue | Out-Null
    Write-Step "deploying '$($cfg.Image.VersionLabel)' to $($cfg.Computer.NamePrefix)*"

    $wim = $cfg.Image.WimPath
    if (-not (Test-Path $wim)) { throw "install.wim not found: $wim" }

    # ---- resolve the edition index by exact NAME so we cannot accidentally apply Home, or "Pro N"
    #      because it contains "Pro" as a substring.
    $wimInfo = & dism.exe /English "/Get-WimInfo" "/WimFile:$wim"
    $wimInfo | Write-Host
    $editions = @{}
    $cur = $null
    foreach ($line in $wimInfo) {
        if ($line -match '^Index\s*:\s*(\d+)') { $cur = [int]$matches[1]; $editions[$cur] = '' }
        elseif ($line -match '^\s*Name\s*:\s*(.+)$' -and $cur -and -not $editions[$cur]) { $editions[$cur] = $matches[1].Trim() }
    }
    $editions.GetEnumerator() | Sort-Object Name | ForEach-Object { Write-Host ("    index {0,-3} {1}" -f $_.Key, $_.Value) }
    if ($cfg.Image.EditionName) {
        $match = $editions.GetEnumerator() | Where-Object { $_.Value -ieq $cfg.Image.EditionName } | Select-Object -First 1
        if (-not $match) {
            throw "edition '$($cfg.Image.EditionName)' not found in $wim. Present: $(($editions.Values | Sort-Object) -join '; ')"
        }
        $index = [int]$match.Key
    }
    else { $index = [int]$cfg.Image.Index }
    Write-Step "image index $index"

    # ---- sanity-check the media build against the config (26H2 = build 26300)
    if ($cfg.Image.ExpectedBuild) {
        $b = $wimInfo | Select-String -Pattern 'Version\s*:\s*10\.0\.(\d+)' | Select-Object -First 1
        if ($b) {
            $found = [regex]::Match($b.Line, '10\.0\.(\d+)').Groups[1].Value
            if ($found -ne $cfg.Image.ExpectedBuild) {
                Write-Warning "media is 10.0.$found but config expects $($cfg.Image.ExpectedBuild)"
                if ($cfg.Image.EnablementMsu) { Write-Warning 'enablement package will bridge the gap' }
            }
        }
    }

    # ============================================================ 2. target disk
    Write-Step 'selecting target disk'
    $disk = Get-Disk | Where-Object {
        $_.BusType -ne 'USB' -and $_.Size -ge 32GB -and -not $_.IsSystem -and -not $_.IsBoot
    } | Sort-Object Size -Descending | Select-Object -First 1
    if (-not $disk) { throw 'no internal disk found (BusType != USB). NVMe invisible? Check firmware/storage driver.' }
    Write-Host ("    disk {0}: {1} - {2} GB, bus {3}" -f $disk.Number, $disk.FriendlyName, [int]($disk.Size / 1GB), $disk.BusType)

    if ($DryRun) { Write-Step 'DryRun: stopping before the disk is touched'; Copy-Transcripts $outLog; exit 0 }

    Write-Step "wiping disk $($disk.Number)"
    Clear-Disk -Number $disk.Number -RemoveData -RemoveOEM -Confirm:$false
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT -Confirm:$false

    $efiMB = if ($cfg.Disk.EfiSizeMB) { [int]$cfg.Disk.EfiSizeMB } else { 300 }
    $msrMB = if ($cfg.Disk.MsrSizeMB) { [int]$cfg.Disk.MsrSizeMB } else { 16 }
    Write-Step "creating GPT layout (EFI ${efiMB}MB / MSR ${msrMB}MB / Windows remainder)"
    # GPT type GUIDs directly: -Type EFI/MSR does not exist in every WinPE Storage module version.
    $efi = New-Partition -DiskNumber $disk.Number -Size "${efiMB}MB" -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    $null = New-Partition -DiskNumber $disk.Number -Size "${msrMB}MB" -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'
    $win = New-Partition -DiskNumber $disk.Number -UseMaximumSize -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
    $win | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false | Out-Null
    $efi | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'SYSTEM'  -Confirm:$false | Out-Null

    # EFI needs a letter for bcdboot; Windows is pinned to W: so the rest of the script is static.
    if (-not (($efi | Get-Partition | Get-Volume).DriveLetter)) { $efi | Add-PartitionAccessPath -AssignDriveLetter }
    $efiLetter = ($efi | Get-Partition | Get-Volume).DriveLetter
    $winLetter = 'W'
    Get-Partition -DiskNumber $disk.Number -PartitionNumber $win.PartitionNumber | Set-Partition -NewDriveLetter $winLetter
    Write-Host "    EFI = ${efiLetter}:  Windows = ${winLetter}:"

    # ============================================================ 3. apply the image
    Write-Step "applying image (index $index) - several minutes, do not interrupt"
    Invoke-Dism -What 'apply' -Arguments @(
        '/Apply-Image', "/ImageFile:$wim", "/Index:$index", "/ApplyDir:${winLetter}:\", '/CheckIntegrity'
    )

    # ============================================================ 4. optional 26H2 enablement package
    if ($cfg.Image.EnablementMsu -and (Test-Path $cfg.Image.EnablementMsu)) {
        Write-Step "slipstreaming $($cfg.Image.EnablementMsu)"
        # A .msu is a container; DISM wants the inner .cab for an offline image.
        $expandDir = Join-Path $script:LogDir 'enablement'
        New-Item -ItemType Directory -Force -Path $expandDir | Out-Null
        & expand.exe -F:* $cfg.Image.EnablementMsu $expandDir | Out-Null
        $cabs = Get-ChildItem $expandDir -Filter *.cab -Recurse
        if (-not $cabs) { Write-Warning 'no .cab inside the MSU; Post-Install.ps1 will install it online instead' }
        foreach ($cab in $cabs) {
            try {
                Invoke-Dism -What 'addpackage' -Arguments @("/Image:${winLetter}:\", '/Add-Package', "/PackagePath:$($cab.FullName)", '/IgnoreCheck')
            } catch {
                # Enablement packages can need a newer servicing stack than the media carries.
                # Not fatal: Post-Install.ps1 retries online after the first boot.
                Write-Warning "offline add of $($cab.Name) failed: $($_.Exception.Message)"
            }
        }
    }

    # ============================================================ 5. drivers
    if ($cfg.Drivers.Path -and (Test-Path $cfg.Drivers.Path)) {
        Write-Step "injecting model drivers from $($cfg.Drivers.Path)"
        Invoke-Dism -What 'adddriver' -Arguments @(
            "/Image:${winLetter}:\", '/Add-Driver', "/Driver:$($cfg.Drivers.Path)", '/Recurse', '/ForceUnsigned'
        )
    }
    else { Write-Warning "driver path '$($cfg.Drivers.Path)' unreachable - Windows Update will have to supply them" }

    # ============================================================ 6. answer file + first-boot payload
    Write-Step 'placing unattend.xml'
    New-Item -ItemType Directory -Force -Path "${winLetter}:\Windows\Panther" | Out-Null
    Copy-Item (Join-Path $src 'config\unattend.xml') "${winLetter}:\Windows\Panther\Unattend.xml" -Force
    New-Item -ItemType Directory -Force -Path "${winLetter}:\Windows\System32\Sysprep" | Out-Null
    Copy-Item (Join-Path $src 'config\unattend.xml') "${winLetter}:\Windows\System32\Sysprep\unattend.xml" -Force

    Write-Step 'staging post-install payload'
    New-Item -ItemType Directory -Force -Path "${winLetter}:\Deploy" | Out-Null
    Copy-Item (Join-Path $src 'postinstall\*') "${winLetter}:\Deploy\" -Recurse -Force
    Copy-Item (Join-Path $src 'config\osd.json') "${winLetter}:\Deploy\osd.json" -Force
    New-Item -ItemType Directory -Force -Path "${winLetter}:\Windows\Setup\Scripts" | Out-Null
    Copy-Item (Join-Path $src 'postinstall\SetupComplete.cmd') "${winLetter}:\Windows\Setup\Scripts\SetupComplete.cmd" -Force

    # ============================================================ 7. boot files
    Write-Step 'bcdboot'
    & bcdboot.exe "${winLetter}:\Windows" /s "${efiLetter}:" /f UEFI /l en-us
    if ($LASTEXITCODE -ne 0) { throw "bcdboot failed ($LASTEXITCODE)" }

    # ============================================================ 8. record + reboot
    Write-Step 'writing deployment record'
    $serial = (Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue).SerialNumber
    $record = [pscustomobject]@{
        Host          = $env:COMPUTERNAME
        Serial        = $serial
        Mode          = if ($localMode) { 'usb-local' } else { 'share' }
        Source        = $src
        StartedAt     = (Get-Date).ToString('s')
        Image         = $wim
        Index         = $index
        Edition       = $cfg.Image.EditionName
        VersionLabel  = $cfg.Image.VersionLabel
        ExpectedBuild = $cfg.Image.ExpectedBuild
        ConfigHash    = (Get-FileHash (Join-Path $src 'config\osd.json') -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
    }
    $record | ConvertTo-Json | Set-Content (Join-Path $outState 'last-deploy.json') -Encoding UTF8
    $name = if ($serial) { "$($cfg.Computer.NamePrefix)-$($serial -replace '[^A-Za-z0-9]', '')" } else { $env:COMPUTERNAME }
    $record | ConvertTo-Json | Set-Content (Join-Path $outState "$name.json") -Encoding UTF8

    Stop-Transcript | Out-Null
    Copy-Transcripts $outLog

    Write-Step 'done - rebooting into the first-boot phase'
    Start-Sleep -Seconds 3
    & wpeutil.exe reboot
}
catch {
    Write-Host ''
    Write-Host "FATAL: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    try { Stop-Transcript | Out-Null } catch {}
    Copy-Transcripts $outLog
    exit 1
}
