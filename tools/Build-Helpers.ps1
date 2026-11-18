#Requires -Version 5.1
<#
Build the two managed TV helpers. This script never runs a helper or connects
to a TV. Default behavior updates engines/stage1 and engines/stage2 only after
both projects have built successfully. -NoCopy leaves shipped engines intact.
#>
[CmdletBinding()]
param(
    [string]$RepositoryRoot=(Split-Path -Parent $PSScriptRoot),
    [string]$DotNetPath='dotnet',
    [string]$OutputDirectory='',
    [switch]$NoCopy
)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$requiredSdk='6.0.428'
$repository=[IO.Path]::GetFullPath($RepositoryRoot)
if(-not $OutputDirectory) { $OutputDirectory=Join-Path $repository '.build/helpers' }
$output=[IO.Path]::GetFullPath($OutputDirectory)
$globalPath=Join-Path $repository 'global.json'
if(-not [IO.File]::Exists($globalPath)) { throw 'Repository global.json is missing.' }
$global=[IO.File]::ReadAllText($globalPath) | ConvertFrom-Json
if($global.sdk.version -cne $requiredSdk -or $global.sdk.rollForward -cne 'disable' -or $global.sdk.allowPrerelease -ne $false) {
    throw 'global.json must select exactly SDK 6.0.428 without roll-forward or prereleases.'
}
$dotnet=(Get-Command $DotNetPath -CommandType Application -ErrorAction Stop).Source
$built=New-Object 'System.Collections.Generic.List[object]'
Push-Location -LiteralPath $repository
try {
    $versionText=@(& $dotnet --version 2>&1)
    if($LASTEXITCODE -ne 0 -or ($versionText -join '').Trim() -cne $requiredSdk) {
        throw ('The selected dotnet SDK is not '+$requiredSdk+'. Install the pinned SDK; see tools/BUILDING.md.')
    }
    Write-Host ('Building with SDK '+$requiredSdk+'; TV target remains netcoreapp3.1.')
    foreach($stage in @(1,2)) {
        $name='QN90BStage'+$stage
        $project=Join-Path $repository ('source/stage'+$stage+'/source/'+$name+'.csproj')
        if(-not [IO.File]::Exists($project)) { throw ('Missing project: '+$project) }
        [xml]$projectXml=[IO.File]::ReadAllText($project)
        $target=$projectXml.SelectSingleNode('/Project/PropertyGroup/TargetFramework')
        $appHost=$projectXml.SelectSingleNode('/Project/PropertyGroup/UseAppHost')
        $assembly=$projectXml.SelectSingleNode('/Project/PropertyGroup/AssemblyName')
        if($null -eq $target -or $target.InnerText -cne 'netcoreapp3.1' -or
            $null -eq $appHost -or $appHost.InnerText -cne 'false' -or
            $null -eq $assembly -or $assembly.InnerText -cne $name) {
            throw ('Unexpected TV helper target settings: '+$project)
        }
        $stageOutput=Join-Path $output ('stage'+$stage)
        [void][IO.Directory]::CreateDirectory($stageOutput)
        & $dotnet build $project --configuration Release --framework netcoreapp3.1 --no-incremental --nologo --output $stageOutput
        if($LASTEXITCODE -ne 0) { throw ('Stage '+$stage+' build failed; engines were not updated.') }
        $hashes=[ordered]@{}
        foreach($suffix in @('.dll','.runtimeconfig.json','.deps.json')) {
            $fileName=$name+$suffix
            $path=Join-Path $stageOutput $fileName
            if(-not [IO.File]::Exists($path)) { throw ('Missing build artifact: '+$path) }
            $hashes[$fileName]=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $runtime=[IO.File]::ReadAllText((Join-Path $stageOutput ($name+'.runtimeconfig.json'))) | ConvertFrom-Json
        if($runtime.runtimeOptions.tfm -cne 'netcoreapp3.1' -or
            $runtime.runtimeOptions.framework.name -cne 'Microsoft.NETCore.App' -or
            $runtime.runtimeOptions.framework.version -cne '3.1.0') { throw 'The helper no longer targets the verified TV .NET Core 3.1 runtime.' }
        $manifestPath=Join-Path $stageOutput 'Helper-SHA256.json'
        [IO.File]::WriteAllText($manifestPath,($hashes | ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
        $built.Add([pscustomobject]@{Stage=$stage;Directory=$stageOutput;Name=$name;Hashes=$hashes})
    }
    if(-not $NoCopy) {
        foreach($helper in $built) {
            $destination=Join-Path $repository ('engines/stage'+$helper.Stage)
            [void][IO.Directory]::CreateDirectory($destination)
            foreach($fileName in $helper.Hashes.Keys) {
                [IO.File]::Copy((Join-Path $helper.Directory $fileName),(Join-Path $destination $fileName),$true)
            }
            # Replace the hash manifest last. A partial copy cannot pass the host hash gate.
            [IO.File]::Copy((Join-Path $helper.Directory 'Helper-SHA256.json'),(Join-Path $destination 'Helper-SHA256.json'),$true)
        }
        & (Join-Path $PSScriptRoot 'Verify-Helpers.ps1') -RepositoryRoot $repository
        Write-Host 'Both helpers and Helper-SHA256.json files were updated. No TV command was executed.'
    } else {
        Write-Host ('Build-only completed in '+$output+'. Shipped engines were not replaced.')
    }
} finally { Pop-Location }
