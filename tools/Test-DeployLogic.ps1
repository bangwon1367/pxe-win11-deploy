# Unit test for the two pieces of Deploy.ps1 logic that are easy to get wrong and impossible to
# notice in WinPE: edition->index resolution from real DISM output, and build detection.
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File test-index-resolution.ps1
$ErrorActionPreference = 'Stop'
$fail = 0
function Assert($cond, $msg) {
    if ($cond) { Write-Output "ok   $msg" } else { Write-Output "FAIL $msg"; $script:fail++ }
}

# --- verbatim shape of `dism /English /Get-WimInfo /WimFile:install.wim` on a 26H2 consumer ISO
$wimInfo = @'
Deployment Image Servicing and Management tool
Version: 10.0.26300.1

Details for image : Z:\images\26H2\install.wim

Index : 1
Name : Windows 11 Home
Description : Windows 11 Home
Size : 16 500 000 000 bytes

Index : 2
Name : Windows 11 Home N
Description : Windows 11 Home N
Size : 16 400 000 000 bytes

Index : 4
Name : Windows 11 Education
Description : Windows 11 Education
Size : 16 600 000 000 bytes

Index : 6
Name : Windows 11 Pro
Description : Windows 11 Pro
Size : 16 700 000 000 bytes

Index : 7
Name : Windows 11 Pro N
Description : Windows 11 Pro N
Size : 16 600 000 000 bytes

Index : 8
Name : Windows 11 Pro Education
Description : Windows 11 Pro Education
Size : 16 700 000 000 bytes

The operation completed successfully.
'@ -split "`r?`n"

# --- the logic under test (copied verbatim from winpe/payload/Deploy.ps1)
function Resolve-EditionIndex {
    param([string[]]$WimInfo, [string]$EditionName, [int]$FallbackIndex)
    $editions = @{}
    $cur = $null
    foreach ($line in $WimInfo) {
        if ($line -match '^Index\s*:\s*(\d+)') { $cur = [int]$matches[1]; $editions[$cur] = '' }
        elseif ($line -match '^\s*Name\s*:\s*(.+)$' -and $cur -and -not $editions[$cur]) { $editions[$cur] = $matches[1].Trim() }
    }
    if ($EditionName) {
        $match = $editions.GetEnumerator() | Where-Object { $_.Value -ieq $EditionName } | Select-Object -First 1
        if (-not $match) { throw "edition '$EditionName' not found" }
        return [int]$match.Key
    }
    return $FallbackIndex
}

Assert ((Resolve-EditionIndex -WimInfo $wimInfo -EditionName 'Windows 11 Pro' -FallbackIndex 1) -eq 6) `
       "'Windows 11 Pro' resolves to index 6 (not Home=1, not Pro N=7)"
Assert ((Resolve-EditionIndex -WimInfo $wimInfo -EditionName 'Windows 11 Pro N' -FallbackIndex 1) -eq 7) `
       "'Windows 11 Pro N' resolves to index 7"
Assert ((Resolve-EditionIndex -WimInfo $wimInfo -EditionName 'windows 11 education' -FallbackIndex 1) -eq 4) `
       "match is case-insensitive (Education = 4)"
Assert ((Resolve-EditionIndex -WimInfo $wimInfo -EditionName $null -FallbackIndex 6) -eq 6) `
       "no EditionName -> configured Index is used"
$threw = $false
try { Resolve-EditionIndex -WimInfo $wimInfo -EditionName 'Windows 11 Enterprise LTSC' -FallbackIndex 1 | Out-Null }
catch { $threw = $true }
Assert $threw "unknown edition throws instead of silently applying the wrong image"

$buildHit = $wimInfo | Select-String -Pattern 'Version\s*:\s*10\.0\.(\d+)' | Select-Object -First 1
$found = [regex]::Match($buildHit.Line, '10\.0\.(\d+)').Groups[1].Value
Assert ($found -eq '26300') "media build detection reads 26300 (26H2)"

if ($fail) { Write-Output "---- $fail test(s) failed"; exit 1 }
Write-Output '---- all index-resolution tests passed'
