# Read every manifest of the bucket with ConvertFrom-Json, the parser Scoop itself uses, and hold each to what Scoop
# needs: a version, a homepage, a license, and for each architecture a url, a hash and a bin.
#
# check-manifests.sh reads the manifests with jq and its own rules; the rules about one JSON document and duplicate keys
# are a reimplementation of what ConvertFrom-Json does, and a file jq accepts and it refuses is a manifest nobody can
# install. Run it in Windows PowerShell and in PowerShell 7, which parse differently:
#
#   powershell -NoProfile -File scripts/monitoring/read-manifests.ps1 [folder]
#   pwsh -NoProfile -File scripts/monitoring/read-manifests.ps1 [folder]
#
# Exit 0 when every manifest passes, 1 when one does not or when there is none to read.
param([string] $Folder = 'bucket')
$ErrorActionPreference = 'Stop'

$bad = 0
$read = 0
foreach ($file in Get-ChildItem -Path $Folder -Filter '*.json') {
    $read++
    try {
        $manifest = Get-Content -Raw -Path $file.FullName | ConvertFrom-Json
    } catch {
        Write-Host "::error file=$($file.FullName)::ConvertFrom-Json refuses it: $($_.Exception.Message)"
        $bad++
        continue
    }
    foreach ($field in 'version', 'homepage', 'license') {
        if (-not $manifest.$field) {
            Write-Host "::error file=$($file.FullName)::it declares no $field"
            $bad++
        }
    }
    $architectures = @()
    if ($manifest.architecture) { $architectures = @($manifest.architecture.PSObject.Properties) }
    if ($architectures.Count -eq 0) {
        Write-Host "::error file=$($file.FullName)::it declares no architecture"
        $bad++
    }
    foreach ($architecture in $architectures) {
        foreach ($field in 'url', 'hash', 'bin') {
            if (-not $architecture.Value.$field) {
                Write-Host "::error file=$($file.FullName)::the architecture $($architecture.Name) declares no $field"
                $bad++
            }
        }
    }
}
if ($read -eq 0) {
    Write-Host "::error::no manifest was found under $Folder, so nothing was read"
    exit 1
}
if ($bad -gt 0) { exit 1 }
Write-Host "read $read manifest(s) with ConvertFrom-Json"
