<#
.SYNOPSIS
    Fetch Windows 11 26H2 media, verify it, and land install.wim on the deploy share.

.DESCRIPTION
    Three ways in, pick whichever suits your licensing:
      1. -IsoPath C:\isos\Win11_26H2.iso   - you already downloaded it (best; VLSC/VS/Media Creation Tool)
      2. -UseFido                          - Fido (pbatard) resolves the current Microsoft consumer
                                             download link; note that Fido's flags move with MS's
                                             page and consumer ISOs are the Home/Pro multi-edition
      3. (both)                            - fetch, then process

    Then it mounts the ISO, inspects every image with DISM, converts install.esd -> install.wim if
    the media ships an ESD (the standard consumer-ISO case), copies the WIM to the share as
    install.wim, and prints a table of index / edition / build so config\osd.json can be set
    correctly. Optionally publishes the media's boot files to the HTTP root for the
    "Windows Setup (manual)" iPXE menu entry.

.EXAMPLE
    .\Get-Win11Media.ps1 -IsoPath D:\Win11_26H2.iso -Destination \\10.0.0.10\deploy\images\26H2 `
                         -PublishManualMedia \\10.0.0.10\deploy\http-publish
#>
[CmdletBinding(DefaultParameterSetName = 'Iso')]
param(
    [Parameter(ParameterSetName = 'Iso')][string]$IsoPath,
    [Parameter(ParameterSetName = 'Fido')][switch]$UseFido,
    [string]$Destination,
    [string]$PublishManualMedia,
    [string]$FidoWorkDir = "$env:TEMP\fido",
    [int]$ExpectedBuild = 26300
)

$ErrorActionPreference = 'Stop'
function Write-Step { param([string]$m) Write-Host "== $m" -ForegroundColor Cyan }

if (-not $Destination) { throw 'specify -Destination (e.g. \\10.0.0.10\deploy\images\26H2)' }
New-Item -ItemType Directory -Force -Path $Destination | Out-Null

# ------------------------------------------------------------------ acquire
if ($UseFido) {
    Write-Step 'resolving the current Windows 11 media URL with Fido'
    New-Item -ItemType Directory -Force -Path $FidoWorkDir | Out-Null
    $fido = Join-Path $FidoWorkDir 'Fido.ps1'
    if (-not (Test-Path $fido)) {
        Invoke-WebRequest 'https://raw.githubusercontent.com/pbatard/Fido/master/Fido.ps1' -OutFile $fido -UseBasicParsing
    }
    Write-Host '    (if this fails, Fido''s parameters changed with Microsoft''s download page - use -IsoPath instead)'
    $url = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fido -Win 11 -Rel Latest -Ed Pro -Arch x64 -Lang English -GetUrl 2>&1 |
           Where-Object { $_ -match '^https?://' } | Select-Object -Last 1
    if (-not $url) { throw 'Fido returned no URL - download the ISO manually and use -IsoPath' }
    $IsoPath = Join-Path $env:TEMP (Split-Path $url -Leaf)
    Write-Step "downloading $url"
    Start-BitsTransfer -Source $url -Destination $IsoPath
}
if (-not (Test-Path $IsoPath)) { throw "ISO not found: $IsoPath" }

# ------------------------------------------------------------------ mount
Write-Step "mounting $IsoPath"
$mount = Mount-DiskImage -ImagePath $IsoPath -PassThru | Get-Volume
$drive = "$($mount.DriveLetter):"
$sources = Join-Path $drive 'sources'
if (-not (Test-Path $sources)) { Dismount-DiskImage -ImagePath $IsoPath; throw "no \sources on the ISO" }

$esd = Join-Path $sources 'install.esd'
$wim = Join-Path $sources 'install.wim'
$source = if (Test-Path $wim) { $wim } elseif (Test-Path $esd) { $esd } else { $null }
if (-not $source) { Dismount-DiskImage -ImagePath $IsoPath; throw 'no install.wim or install.esd on the media' }
Write-Step "image container: $source"

# ------------------------------------------------------------------ inspect
$info = & dism.exe /English /Get-WimInfo "/WimFile:$source"
$info | Write-Host

$build = ([regex]::Match(($info | Out-String), 'Version\s*:\s*10\.0\.(\d+)')).Groups[1].Value
if ($build -and $build -ne "$ExpectedBuild") {
    Write-Warning "media is build 10.0.$build, expected $ExpectedBuild (26H2)."
    Write-Warning "If this is 24H2/25H2 media, set Image.EnablementMsu in config\osd.json so the 26H2 enablement package is applied."
}

# edition -> index table so osd.json can be set by name (recommended) instead of a guessed number
Write-Step 'editions on this media'
$idx = $null
foreach ($line in $info) {
    if ($line -match '^Index:\s*(\d+)') { $idx = $matches[1] }
    elseif ($line -match '^Name:\s*(.+)$' -and $idx) { Write-Host ("    {0}  {1}" -f $idx, $matches[1].Trim()) }
}

# ------------------------------------------------------------------ publish
$destWim = Join-Path $Destination 'install.wim'
if ($source -eq $wim) {
    Write-Step "copying install.wim -> $destWim"
    Copy-Item $wim $destWim -Force
} else {
    Write-Step "exporting install.esd -> $destWim (all editions, maximum compression)"
    $indices = [regex]::Matches(($info | Out-String), '(?m)^Index:\s*(\d+)') | ForEach-Object { $_.Groups[1].Value }
    foreach ($i in $indices) {
        $args = @('/Export-Image', "/SourceImageFile:$source", "/SourceIndex:$i", "/DestinationImageFile:$destWim", '/Compress:max')
        if ($i -ne $indices[0]) { $args += '/CheckIntegrity' }
        & dism.exe @args
        if ($LASTEXITCODE -ne 0) { Write-Warning "export of index $i failed" }
    }
}

if ($PublishManualMedia) {
    Write-Step "publishing boot media for the manual-setup menu entry -> $PublishManualMedia"
    New-Item -ItemType Directory -Force -Path (Join-Path $PublishManualMedia 'win11\boot'), (Join-Path $PublishManualMedia 'win11\sources') | Out-Null
    Copy-Item (Join-Path $drive 'boot\BCD')      (Join-Path $PublishManualMedia 'win11\boot\BCD') -Force
    Copy-Item (Join-Path $sources 'boot.sdi')    (Join-Path $PublishManualMedia 'win11\boot\boot.sdi') -Force
    Copy-Item (Join-Path $sources 'boot.wim')    (Join-Path $PublishManualMedia 'win11\sources\boot.wim') -Force
    Write-Host '    note: this boot.wim is Windows Setup, not your customised WinPE. It boots the'
    Write-Host '          installer interactively; the automated flow still uses /winpe/sources/boot.wim.'
}

Dismount-DiskImage -ImagePath $IsoPath | Out-Null

# ------------------------------------------------------------------ summary
$size = [int]((Get-Item $destWim).Length / 1MB)
Write-Host @"

Done. On the share:
  $destWim  ($size MB, source build 10.0.$build)

Now set config\osd.json:
  Image.WimPath     = "<share path to the WIM>"
  Image.EditionName = "Windows 11 Pro"      <- must match a 'Name:' line above exactly
  Image.Index       = <fallback index>
  Image.ExpectedBuild = "26300"             (26H2)
"@ -ForegroundColor Green
