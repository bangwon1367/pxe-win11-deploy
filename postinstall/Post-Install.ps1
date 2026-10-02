<#
.SYNOPSIS
    First-boot post-install for pxe-win11-deploy.

.DESCRIPTION
    Runs up to twice, by design:
      * as SYSTEM from C:\Windows\Setup\Scripts\SetupComplete.cmd (system-level phases)
      * as the admin user from FirstLogonCommands (winget/application phases)
    Every phase is guarded by a marker file under C:\Deploy, so re-runs are cheap no-ops.

    Phases: rename to <Prefix>-<Serial> -> workgroup/domain -> power -> telemetry &
    consumer-feature trim -> provisioned app removal -> driver pass (pnputil, offline-injected
    drivers are already there; this only adds anything reachable) -> apps (winget) -> vendor tools
    -> optional enablement/update -> state marker back to the share -> one reboot.

.NOTES
    Never hard-fails the image: errors are logged and the phase continues. A failed deploy where
    Windows still boots and you can log in beats a bricked sysprep pass.

.PARAMETER ConfigPath
    C:\Deploy\osd.json, staged by Deploy.ps1 before first boot.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = 'C:\Deploy\osd.json',
    [switch]$Force
)

$ErrorActionPreference = 'Continue'
$DeployRoot = 'C:\Deploy'
New-Item -ItemType Directory -Force -Path $DeployRoot | Out-Null
Start-Transcript -Path (Join-Path $DeployRoot 'postinstall.log') -Append -Force | Out-Null

function Write-Step { param([string]$m) Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) -ForegroundColor Cyan }
function Write-Warn { param([string]$m) Write-Host ("[{0:HH:mm:ss}] !  {1}" -f (Get-Date), $m) -ForegroundColor Yellow }
function Done { param([string]$n) Test-Path (Join-Path $DeployRoot "$n.done") }
function Mark { param([string]$n) New-Item -ItemType File -Force -Path (Join-Path $DeployRoot "$n.done") | Out-Null }
function New-RegKey { param([string]$Path) if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null } }

$isSystem = ([Security.Principal.WindowsIdentity]::GetCurrent()).IsSystem
$needsReboot = $false

if (-not (Test-Path $ConfigPath)) {
    Write-Warn "no config at $ConfigPath - running with built-in defaults"
    $cfg = [pscustomobject]@{}
} else {
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
}
$pi = $cfg.PostInstall
Write-Step ("post-install starting (SYSTEM={0}, force={1})" -f $isSystem, [bool]$Force)

# ------------------------------------------------------------------ 1. identity
if ($Force -or -not (Done 'rename')) {
    Write-Step 'renaming computer'
    try {
        $serial = (Get-CimInstance Win32_BIOS -ErrorAction Stop).SerialNumber
        if ($serial) {
            $prefix = if ($cfg.Computer.NamePrefix) { $cfg.Computer.NamePrefix } else { 'LAB' }
            $new = ("{0}-{1}" -f $prefix, ($serial -replace '[^A-Za-z0-9]', ''))
            if ($new.Length -gt 15) { $new = $new.Substring(0, 15) }   # NetBIOS ceiling
            if ($env:COMPUTERNAME -ne $new) {
                Rename-Computer -NewName $new -Force -ErrorAction Stop
                Write-Host "    renamed to $new"
                $needsReboot = $true
            }
        }
        Mark 'rename'
    } catch { Write-Warn "rename failed: $($_.Exception.Message)" }
}

if ($Force -or -not (Done 'join')) {
    Write-Step 'network membership'
    try {
        if ($cfg.Computer.Domain) {
            Write-Warn 'domain join needs credentials - supply them yourself:'
            Write-Host "    Add-Computer -DomainName $($cfg.Computer.Domain) -Credential (Get-Credential) -Restart"
        } elseif ($cfg.Computer.Workgroup -and (Get-CimInstance Win32_ComputerSystem).Workgroup -ne $cfg.Computer.Workgroup) {
            Add-Computer -WorkgroupName $cfg.Computer.Workgroup -ErrorAction Stop
            Write-Host "    joined workgroup $($cfg.Computer.Workgroup)"
            $needsReboot = $true
        }
        Mark 'join'
    } catch { Write-Warn "workgroup/domain phase failed: $($_.Exception.Message)" }
}

# ------------------------------------------------------------------ 2. power / lab ergonomics
if ($Force -or -not (Done 'power')) {
    Write-Step 'power settings'
    switch ($pi.PowerPlan) {
        'HighPerformance'      { & powercfg.exe /setactive SCHEME_MIN | Out-Null }
        'UltimatePerformance'  { & powercfg.exe -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 | Out-Null
                                 & powercfg.exe /setactive e9a42b02-d5df-448d-aa00-03f14749eb61 | Out-Null }
        default                { & powercfg.exe /setactive SCHEME_BALANCED | Out-Null }
    }
    if ($pi.DisableHibernation) { & powercfg.exe /hibernate off | Out-Null }
    # A laptop that suspends mid-RDP session is annoying on a lab bench.
    & powercfg.exe /change standby-timeout-ac 0 | Out-Null
    & powercfg.exe /change monitor-timeout-ac 20 | Out-Null
    # Reserved storage hides ~7 GB on a small NVMe. Done here rather than in unattend.xml so a
    # schema mismatch can never fail the specialize pass.
    & dism.exe /Online /Set-ReservedStorageState /State:Disabled /Quiet /NoRestart 2>&1 |
        ForEach-Object { Write-Host "      $_" }
    Mark 'power'
}

# ------------------------------------------------------------------ 3. privacy / consumer trim
if ($Force -or -not (Done 'privacy')) {
    Write-Step 'telemetry + consumer feature trim'
    New-RegKey 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
    $level = if ($null -ne $pi.TelemetryLevel) { [int]$pi.TelemetryLevel } else { 1 }
    Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' AllowTelemetry $level -Type DWord
    Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' DoNotShowFeedbackNotifications 1 -Type DWord
    if ($pi.DisableConsumerFeatures) {
        New-RegKey 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
        Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' DisableWindowsConsumerFeatures 1 -Type DWord
        Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' DisableSoftLanding 1 -Type DWord
    }
    # Long paths: modern dev tooling hates the 260-char limit.
    Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' LongPathsEnabled 1 -Type DWord
    if ($pi.EnableRDP) {
        Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' fDenyTSConnections 0 -Type DWord
        & netsh.exe advfirewall firewall set rule group="remote desktop" new enable=Yes | Out-Null
    }
    Mark 'privacy'
}

# ------------------------------------------------------------------ 4. provisioned app removal
if ($Force -or -not (Done 'apps-remove')) {
    Write-Step 'removing provisioned apps'
    $wanted = @($pi.RemoveProvisionedApps)
    foreach ($name in $wanted) {
        try {
            $pkg = Get-AppxProvisionedPackage -Online |
                   Where-Object { $_.DisplayName -like "*$name*" } | Select-Object -First 1
            if ($pkg) {
                Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -ErrorAction Stop | Out-Null
                Write-Host "    - $name"
            }
        } catch { Write-Warn "  ${name}: $($_.Exception.Message)" }
    }
    Mark 'apps-remove'
}

# ------------------------------------------------------------------ 5. drivers
if ($Force -or -not (Done 'drivers')) {
    Write-Step 'driver pass'
    # The X1 Yoga's core drivers were already injected offline by Deploy.ps1 (DISM /Add-Driver).
    # This only picks up anything reachable at first boot. It needs share credentials, because a
    # freshly imaged machine has no mapped Z: - Deploy.ps1 only writes share.json when you ask it to.
    $shareJson = Join-Path $DeployRoot 'share.json'
    if (Test-Path $shareJson) {
        try {
            $s = Get-Content $shareJson -Raw | ConvertFrom-Json
            & net.exe use Z: $s.Share $s.SharePassword "/user:$($s.ShareUser)" /persistent:no | Out-Null
            if (Test-Path $cfg.Drivers.Path) {
                foreach ($inf in (Get-ChildItem $cfg.Drivers.Path -Recurse -Filter *.inf -ErrorAction SilentlyContinue)) {
                    & pnputil.exe /add-driver $inf.FullName /install | Out-Null
                }
                Write-Host '    applied INF drivers from the share'
            }
        } catch { Write-Warn "driver pass: $($_.Exception.Message)" }
    } else {
        Write-Host '    skipped (no share.json) - run Lenovo Commercial Vantage for the rest'
    }
    Mark 'drivers'
}

# ------------------------------------------------------------------ 6. applications
$appsPhase = ($pi.Apps.Count -gt 0) -or ($pi.VendorTools.Count -gt 0)
if ($appsPhase -and ($Force -or -not (Done 'apps-install'))) {
    if ($isSystem) {
        # winget does not work usefully as SYSTEM; leave it to the FirstLogonCommands run.
        Write-Step 'apps phase deferred (running as SYSTEM - the admin logon will finish it)'
    } else {
        Write-Step 'installing packages with winget'
        $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
        if (-not $winget -and $pi.WingetBundle -and (Test-Path $pi.WingetBundle)) {
            try { Add-AppxPackage -Path $pi.WingetBundle -ErrorAction Stop; $winget = Get-Command winget.exe -ErrorAction SilentlyContinue } catch {}
        }

        if ($winget) {
            $ids = @($pi.Apps) + @($pi.VendorTools) | Where-Object { $_ }
            foreach ($id in $ids) {
                Write-Host "    + $id"
                & winget.exe install --id $id --exact --silent `
                    --accept-source-agreements --accept-package-agreements --disable-interactivity 2>&1 |
                    ForEach-Object { Write-Host "      $_" }
                if ($LASTEXITCODE -ne 0) { Write-Warn "    $id -> winget exit $LASTEXITCODE (id wrong for your region? verify with 'winget search')" }
            }
            Mark 'apps-install'
        } elseif ($pi.UseChocolateyFallback) {
            Write-Warn 'winget unavailable - falling back to Chocolatey'
            try {
                Set-ExecutionPolicy Bypass -Scope Process -Force
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
                foreach ($id in (@($pi.Apps) | Where-Object { $_ })) {
                    $chocoId = switch -wildcard ($id) { 'Microsoft.*' { $id } default { $id.Split('.')[-1] } }
                    & choco.exe install $chocoId -y --no-progress | Out-Null
                }
                Mark 'apps-install'
            } catch { Write-Warn "chocolatey fallback failed: $($_.Exception.Message)" }
        } else {
            Write-Warn 'no winget and no fallback enabled - skipping app install'
        }
    }
}

# ------------------------------------------------------------------ 7. optional online enablement / updates
if ($Force -or -not (Done 'update')) {
    Write-Step 'servicing'
    $cur = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
    Write-Host "    current build $cur"
    $expected = if ($cfg.Image.ExpectedBuild) { [int]$cfg.Image.ExpectedBuild } else { 0 }
    if ($expected -and $cur -lt $expected -and $cfg.Image.EnablementMsu -and (Test-Path $cfg.Image.EnablementMsu)) {
        Write-Host "    installing enablement package to reach $expected"
        & dism.exe /Online /Add-Package /PackagePath:$($cfg.Image.EnablementMsu) /LogPath:C:\Deploy\enablement.log /NoRestart
        if ($LASTEXITCODE -eq 0) { $needsReboot = $true } else { Write-Warn "enablement install exit $LASTEXITCODE" }
    }
    if ($expected -and $cur -lt $expected) { Write-Warn "still below expected build $expected - check for the current enablement package" }
    if ($pi.UsePSWindowsUpdate) {
        try {
            if (-not (Get-Module -ListAvailable PSWindowsUpdate)) { Install-Module PSWindowsUpdate -Force -Confirm:$false }
            Import-Module PSWindowsUpdate
            Get-WindowsUpdate -Install -AcceptAll -IgnoreReboot | Out-Host
            $needsReboot = $true
        } catch { Write-Warn "PSWindowsUpdate: $($_.Exception.Message)" }
    }
    Mark 'update'
}

# ------------------------------------------------------------------ 8. state marker
Write-Step 'writing state'
try {
    $state = [pscustomobject]@{
        Computer   = $env:COMPUTERNAME
        Serial     = (Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue).SerialNumber
        Model      = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).Model
        FinishTime = (Get-Date).ToString('s')
        Build      = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
        DisplayVer = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion
        UBR        = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR
        SystemMode = $isSystem
    }
    $state | ConvertTo-Json | Set-Content (Join-Path $DeployRoot 'state.json') -Encoding UTF8
    Write-Host ($state | ConvertTo-Json)

    # Push it back to the server so the deployment can be audited centrally.
    if (-not $isSystem) {
        $shareJson = Join-Path $DeployRoot 'share.json'
        if (Test-Path $shareJson) {
            $s = Get-Content $shareJson -Raw | ConvertFrom-Json
            & net.exe use Z: $s.Share $s.SharePassword "/user:$($s.ShareUser)" /persistent:no | Out-Null
            if (Test-Path 'Z:\state') {
                $key = if ($state.Serial) { $state.Serial } else { $env:COMPUTERNAME }
                $state | ConvertTo-Json | Set-Content "Z:\state\$key.json" -Encoding UTF8
                Copy-Item (Join-Path $DeployRoot 'postinstall.log') 'Z:\logs\' -Force -ErrorAction SilentlyContinue
                Write-Host '    state + log copied to the share'
            }
        }
    }
} catch { Write-Warn "state write: $($_.Exception.Message)" }

Stop-Transcript | Out-Null

if ($needsReboot) {
    Write-Step 'rebooting to finish setup (30s)'
    & shutdown.exe /r /t 30 /c 'pxe-win11-deploy: finishing post-install' /d p:2:4
} else {
    Write-Step 'post-install complete'
}
