#Requires -Version 5.1
# File-only verification. Never loads or executes the TV helpers.
[CmdletBinding()]
param([string]$RepositoryRoot=(Split-Path -Parent $PSScriptRoot))
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$repository=[IO.Path]::GetFullPath($RepositoryRoot)
foreach($stage in @(1,2)) {
    $directory=Join-Path $repository ('engines/stage'+$stage)
    $manifestPath=Join-Path $directory 'Helper-SHA256.json'
    $manifest=[IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    if(@($manifest.PSObject.Properties).Count -ne 3) { throw ('Stage '+$stage+' must list exactly three artifacts.') }
    $name='QN90BStage'+$stage
    foreach($suffix in @('.dll','.runtimeconfig.json','.deps.json')) {
        $fileName=$name+$suffix
        $property=$manifest.PSObject.Properties[$fileName]
        if($null -eq $property -or $property.Value -cnotmatch '^[a-f0-9]{64}$') { throw ('Missing expected SHA256: '+$fileName) }
        $actual=(Get-FileHash -LiteralPath (Join-Path $directory $fileName) -Algorithm SHA256).Hash.ToLowerInvariant()
        if($actual -cne $property.Value) { throw ('Helper SHA256 mismatch: '+$fileName) }
    }
    $runtime=[IO.File]::ReadAllText((Join-Path $directory ($name+'.runtimeconfig.json'))) | ConvertFrom-Json
    if($runtime.runtimeOptions.tfm -cne 'netcoreapp3.1' -or
        $runtime.runtimeOptions.framework.name -cne 'Microsoft.NETCore.App' -or
        $runtime.runtimeOptions.framework.version -cne '3.1.0') { throw ('Unexpected runtime for '+$name) }
    Write-Host ('Verified Stage '+$stage+': three SHA256 values and the TV runtime declaration.')
}
