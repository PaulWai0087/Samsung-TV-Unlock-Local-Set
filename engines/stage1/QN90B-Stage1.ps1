# QN90B phase 1: Preventing Import only. Windows PowerShell 5.1.
[CmdletBinding()]
param(
    [ValidateSet('Read','Apply','Restore')][string]$Action='Read',
    [ValidatePattern('^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$')][string]$TvIp='192.168.1.100',
    [switch]$NoExplorer,
    [string]$ReportPath=''
)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'HostFunctions.ps1')

function Save-OriginalBaseline {
    param([string]$Path,[object]$Baseline)
    $text=ConvertTo-Json -InputObject $Baseline -Depth 40
    $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($text)
    $stream=New-Object IO.FileStream($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
}

function Show-Stage1Result {
    param([object]$Result)
    Write-Host ''
    foreach($name in @('phase','success','writeAttempted','changed','rollbackAttempted','rollbackSucceeded')) {
        Write-Host ('  '+$name+': '+(Get-ObjectProperty $Result $name))
    }
    $state=Get-ObjectProperty $Result 'state'
    if($null -ne $state) {
        $import=Get-ObjectProperty $state 'preventImport'
        Write-Host ('  Preventing Import: '+(Get-ObjectProperty $import 'value'))
        Write-Host ('  Local Set: '+(Get-ObjectProperty $state 'currentName'))
        Write-Host ('  Local Set store: '+(Get-ObjectProperty $state 'currentStore'))
        Write-Host ('  Local Set global enum: '+(Get-ObjectProperty $state 'globalEnum'))
        Write-Host '  Visible Local Sets:'
        foreach($option in @(Get-ObjectProperty $state 'visibleLocalSets')) {
            if($null -ne $option) { Write-Host ('    {0,3}  {1}' -f (Get-ObjectProperty $option 'store'),(Get-ObjectProperty $option 'name')) }
        }
        $readErrors=@(Get-ObjectProperty $state 'readErrors')
        if($readErrors.Count -gt 0 -and $null -ne $readErrors[0]) { Write-Host ('  Read errors: '+($readErrors -join '; ')) }
    }
    Write-Host ('  Message: '+(Get-ObjectProperty $Result 'message'))
}

function New-Stage1RemoteCommand {
    param([object[]]$Files,[string]$RemoteBase,[ValidateSet('read','apply','restore')][string]$Phase)
    if($RemoteBase -cnotmatch '^/home/owner/share/tmp/sdk_tools/qn90b_stage1_[a-f0-9]{32}$') { throw 'Invalid remote staging name.' }
    $checks=New-Object 'System.Collections.Generic.List[string]'
    foreach($file in $Files) {
        if($file.Remote -cnotmatch '^/home/owner/share/tmp/sdk_tools/qn90b_stage1_[a-f0-9]{32}\.[A-Za-z0-9.]+$' -or
            $file.Sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid staged file description.' }
        $checks.Add(('[ "$(sha256sum ''{0}'' | cut -d '' '' -f 1)" = ''{1}'' ]' -f $file.Remote,$file.Sha256))
    }
    $call="/usr/bin/dotnet '"+$RemoteBase+".dll' "+$Phase
    if($Phase -ne 'read') { $call+=" --baseline '"+$RemoteBase+".baseline.json'" }
    $quoted=($Files | ForEach-Object { "'"+$_.Remote+"'" }) -join ' '
    $command='( '+($checks.ToArray() -join ' && ')+' && '+$call+' ); rc=$?; rm -f '+$quoted+'; cleanup_rc=$?; if [ "$cleanup_rc" -eq 0 ]; then echo QN90B_STAGE1_CLEANED=yes; else echo QN90B_STAGE1_CLEANED=no >&2; if [ "$rc" -eq 0 ]; then rc=74; fi; fi; exit "$rc"'
    if($command.IndexOf([char]92) -ge 0) { throw 'Remote command contains a backslash; refusing unsupported root-agent quoting.' }
    return $command
}

function Invoke-Stage1Phase {
    param([object]$Context,[ValidateSet('read','apply','restore')][string]$Phase,[string]$Directory,[string]$BaselinePath='')
    [void][IO.Directory]::CreateDirectory($Directory)
    $remoteBase='/home/owner/share/tmp/sdk_tools/qn90b_stage1_'+[Guid]::NewGuid().ToString('N')
    $uploads=New-Object 'System.Collections.Generic.List[object]'
    foreach($file in $Context.HelperFiles) {
        $suffix=$file.Name.Substring('QN90BStage1'.Length)
        $uploads.Add([pscustomobject]@{Local=$file.Path;Remote=$remoteBase+$suffix;Sha256=$file.Sha256})
    }
    if($Phase -ne 'read') {
        if(-not [IO.File]::Exists($BaselinePath)) { throw 'The saved original baseline is missing.' }
        [IO.File]::Copy($BaselinePath,(Join-Path $Directory 'baseline-used.json'),$false)
        $baselineCopy=Join-Path $Directory 'baseline-used.json'
        $uploads.Add([pscustomobject]@{Local=$baselineCopy;Remote=$remoteBase+'.baseline.json';Sha256=(Get-FileHash -LiteralPath $baselineCopy -Algorithm SHA256).Hash.ToLowerInvariant()})
    }
    $command=New-Stage1RemoteCommand -Files $uploads.ToArray() -RemoteBase $remoteBase -Phase $Phase
    Write-Utf8File (Join-Path $Directory 'remote-command.sh') $command
    Write-Utf8File (Join-Path $Directory 'uploads.json') (ConvertTo-Json -InputObject $uploads.ToArray() -Depth 8)
    $context.LastPhase=$Phase
    $context.LastPhaseDirectory=$Directory
    $context.CleanupConfirmed=$false
    $context.RemoteFiles=@($uploads.ToArray() | ForEach-Object {$_.Remote})
    $index=0
    foreach($file in $uploads) {
        $index++
        $push=Invoke-CapturedTool $Context.Sdb @('-s',$Context.Serial,'push',$file.Local,$file.Remote) (Join-Path $Directory ('push-'+$index)) ('Stage helper file '+$index)
        Assert-SdbSuccess $push 'SDB helper upload'
    }
    if($Phase -ne 'read') { $Context.WriteSessionStarted=$true }
    $root=Invoke-CapturedTool $Context.Root @('--sdb',$Context.Sdb,'--output','json','archive-root','root',$Context.Ip,'--runtime','3.1','--command',$command,'--command-timeout','240') (Join-Path $Directory 'root') ('Temporary root: '+$Phase) $false
    Write-Utf8File (Join-Path $Directory 'Root-Evidence.json') $root.Stdout
    try { $evidence=$root.Stdout | ConvertFrom-Json } catch { throw 'Root output was not valid JSON; the complete output was saved.' }
    $commands=@(Get-ObjectProperty $evidence 'commands')
    if($commands.Count -ne 1 -or $null -eq $commands[0]) { throw 'The root result did not contain exactly one command result.' }
    $remote=$commands[0]
    $stdout=[string](Get-ObjectProperty $remote 'stdout')
    Write-Utf8File (Join-Path $Directory 'Helper.stdout.txt') $stdout
    Write-Utf8File (Join-Path $Directory 'Helper.stderr.txt') ([string](Get-ObjectProperty $remote 'stderr'))
    $Context.CleanupConfirmed=$stdout -match '(?m)^QN90B_STAGE1_CLEANED=yes\r?$'
    $lines=@($stdout -split '\r?\n' | Where-Object { $_.StartsWith('QN90B_STAGE1_JSON=') })
    $result=$null
    if($lines.Count -eq 1) {
        $json=$lines[0].Substring('QN90B_STAGE1_JSON='.Length)
        Write-Utf8File (Join-Path $Directory 'Stage1-Result.json') $json
        $result=$json | ConvertFrom-Json
        Show-Stage1Result $result
    }
    # Save a failed write/rollback result before rejecting its nonzero exit code.
    if((Get-ObjectProperty $evidence 'authenticated') -ne $true -or
       $null -eq (Get-ObjectProperty $evidence 'uid') -or (Get-ObjectProperty $evidence 'uid') -ne 0 -or
       $null -eq (Get-ObjectProperty $evidence 'euid') -or (Get-ObjectProperty $evidence 'euid') -ne 0) {
        throw 'Authenticated UID/EUID 0 was not confirmed.'
    }
    if($null -eq $result -or (Get-ObjectProperty $result 'phase') -cne $Phase) { throw 'A valid result for this phase was not returned.' }
    if($root.ExitCode -ne 0 -or (Get-ObjectProperty $remote 'exit_code') -ne 0 -or
       (Get-ObjectProperty $remote 'timed_out') -ne $false -or (Get-ObjectProperty $result 'success') -ne $true) {
        throw 'This phase did not complete successfully. Its parameter state and rollback report, when returned, are saved in Stage1-Result.json.'
    }
    if((Get-ObjectProperty $evidence 'staging_cleaned') -ne $true -or
       (Get-ObjectProperty $evidence 'system_files_unchanged') -ne $true -or -not $Context.CleanupConfirmed) {
        throw 'Temporary-file cleanup or the root tool system-file check was not confirmed. Inspect the saved parameter result before another write.'
    }
    return $result
}

$exitCode=1
$originalPath=$env:PATH
$transcriptStarted=$false
$lock=$null
$runDirectory=$null
$context=$null
$hostError=''
try {
    if($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem) { throw 'Run this kit on your Windows x64 PC.' }
    if($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { throw 'The existing root tool is for Windows x64.' }
    $parsedIp=[Net.IPAddress]::Parse($TvIp)
    if($parsedIp.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $parsedIp.ToString() -cne $TvIp) { throw 'TV address must be an ordinary IPv4 address.' }
    $ip=$TvIp
    $model='QA75QN90BAJXXZ'
    $work=Join-Path $env:LOCALAPPDATA 'QN90B-root'
    $toolsDirectory=Join-Path $work 'tools'
    $tvDirectory=Join-Path (Join-Path $work 'stage1') $ip
    [void][IO.Directory]::CreateDirectory($tvDirectory)
    $lock=New-Object IO.FileStream((Join-Path $tvDirectory 'runner.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $baselinePath=Join-Path $tvDirectory 'Original-Baseline.json'
    $runDirectory=Join-Path (Join-Path $tvDirectory 'runs') ((Get-Date -Format 'yyyyMMdd-HHmmss')+'_'+$Action+'_'+[Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($runDirectory)
    Start-Transcript -Path (Join-Path $runDirectory 'Session.log') -Force | Out-Null
    $transcriptStarted=$true
    Write-Host ('QN90B Stage 1 | '+$Action+' | TV: '+$ip)
    Write-Host ('Results: '+$runDirectory)
    Write-Host ('Original baseline: '+$baselinePath)
    if($Action -eq 'Apply') { Write-Host 'This action reads the baseline, then writes Preventing Import 13 -> 0 if all checks pass.' }
    if($Action -eq 'Restore') { Write-Host 'This action restores Preventing Import to the verified original value 13.' }

    $manifest=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Helper-SHA256.json')) | ConvertFrom-Json
    $helperFiles=New-Object 'System.Collections.Generic.List[object]'
    foreach($name in @('QN90BStage1.dll','QN90BStage1.runtimeconfig.json','QN90BStage1.deps.json')) {
        $path=Join-Path $PSScriptRoot $name
        $expected=[string](Get-ObjectProperty $manifest $name)
        if($expected -cnotmatch '^[a-f0-9]{64}$' -or -not [IO.File]::Exists($path)) { throw ('Missing helper file or expected hash: '+$name) }
        $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if($hash -cne $expected) { throw ('Helper SHA256 mismatch: '+$name) }
        $helperFiles.Add([pscustomobject]@{Name=$name;Path=$path;Sha256=$hash})
    }
    $runtime=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'QN90BStage1.runtimeconfig.json')) | ConvertFrom-Json
    if($runtime.runtimeOptions.tfm -cne 'netcoreapp3.1' -or $runtime.runtimeOptions.framework.name -cne 'Microsoft.NETCore.App' -or
        $runtime.runtimeOptions.framework.version -cne '3.1.0') { throw 'Helper runtime must be .NET Core 3.1.' }
    $sdb=Find-ExistingTool $toolsDirectory 'sdb-4.2.36' 'sdb.exe'
    $root=Find-ExistingTool $toolsDirectory 'root-0.0.13' 'samsung-tv-root.exe'
    $openssl=Find-OpenSsl '' $toolsDirectory
    $sslResult=Invoke-CapturedTool $openssl @('version') (Join-Path $runDirectory 'openssl') 'OpenSSL check'
    if($sslResult.ExitCode -ne 0) { throw 'OpenSSL check failed.' }
    $serial=$ip+':26101'
    $connect=Invoke-CapturedTool $sdb @('connect',$serial) (Join-Path $runDirectory 'connect') 'SDB connection'
    Assert-SdbSuccess $connect 'SDB connection'
    $devices=Invoke-CapturedTool $sdb @('devices') (Join-Path $runDirectory 'devices') 'TV identification'
    Assert-SdbSuccess $devices 'SDB device listing'
    $target=@($devices.Stdout -split '\r?\n' | Where-Object {$_ -match ('^\s*'+[regex]::Escape($serial)+'\s+device\b')})
    if($target.Count -ne 1) { throw 'The exact target TV was not found in SDB devices.' }
    $fields=[regex]::Split($target[0].Trim(),'\s+')
    if($fields.Count -lt 3 -or $fields[2] -cne $model) { throw 'The connected TV model does not match QA75QN90BAJXXZ.' }
    $context=[pscustomobject]@{Ip=$ip;Serial=$serial;Sdb=$sdb;Root=$root;HelperFiles=$helperFiles.ToArray();WriteSessionStarted=$false;CleanupConfirmed=$true;RemoteFiles=@();LastPhase='';LastPhaseDirectory=''}

    if($Action -eq 'Read' -or $Action -eq 'Apply') {
        $read=Invoke-Stage1Phase $context 'read' (Join-Path $runDirectory '01-read')
        $candidate=Get-ObjectProperty $read 'baseline'
        if(-not [IO.File]::Exists($baselinePath) -and $null -ne $candidate) {
            Save-OriginalBaseline $baselinePath $candidate
            Write-Host 'Original baseline saved on the PC before any parameter write.'
        } elseif([IO.File]::Exists($baselinePath)) {
            Write-Host 'The existing original baseline was retained.'
        }
        if($Action -eq 'Apply') {
            if(-not [IO.File]::Exists($baselinePath)) { throw 'No verified original import13 baseline is available; no write was started.' }
            $null=Invoke-Stage1Phase $context 'apply' (Join-Path $runDirectory '02-apply') $baselinePath
            Write-Host 'SUCCESS: Stage 1 applied and verified. Review the visible Local Set list above.' -ForegroundColor Green
        } else { Write-Host 'SUCCESS: Read completed. No factory setter was requested.' -ForegroundColor Green }
    } else {
        if(-not [IO.File]::Exists($baselinePath)) { throw 'The original Stage 1 baseline is missing.' }
        $null=Invoke-Stage1Phase $context 'restore' (Join-Path $runDirectory '01-restore') $baselinePath
        Write-Host 'SUCCESS: Preventing Import was read back at the original value 13.' -ForegroundColor Green
    }
    $exitCode=0
} catch {
    Write-Host ''
    $hostError=$_.Exception.Message
    Write-Host ('STOPPED: '+$_.Exception.Message) -ForegroundColor Red
    if($runDirectory) {
        try { Write-Utf8File (Join-Path $runDirectory 'Host-Error.txt') ($_.Exception.ToString()+[Environment]::NewLine+$_.ScriptStackTrace) } catch {}
    }
    if($null -ne $context -and $context.WriteSessionStarted) {
        Write-Host 'A write session was started. Use the saved parameter result and rollback fields to determine its outcome.' -ForegroundColor Yellow
    }
} finally {
    if($null -ne $context -and -not $context.CleanupConfirmed) {
        Write-Host 'Cleanup was not confirmed for these temporary helper files:' -ForegroundColor Yellow
        foreach($path in $context.RemoteFiles) { Write-Host $path }
    }
    if($runDirectory) {
        Write-Host ('Results and logs: '+$runDirectory)
        if($null -ne $context -and $context.LastPhaseDirectory) {
            $resultPath=Join-Path $context.LastPhaseDirectory 'Stage1-Result.json'
            if([IO.File]::Exists($resultPath)) {
                Write-Host ('Upload this result: '+$resultPath)
                if(-not $NoExplorer) {
                    try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"'+$resultPath+'"') -ErrorAction Stop | Out-Null } catch {}
                }
            }
        }
    }
    if($ReportPath) {
        try {
            $finalResultPath=$null
            $finalResult=$null
            if($null -ne $context -and $context.LastPhaseDirectory) {
                $candidateResultPath=Join-Path $context.LastPhaseDirectory 'Stage1-Result.json'
                if([IO.File]::Exists($candidateResultPath)) {
                    $finalResultPath=$candidateResultPath
                    $finalResult=[IO.File]::ReadAllText($finalResultPath) | ConvertFrom-Json
                }
            }
            $reportParent=Split-Path -Parent ([IO.Path]::GetFullPath($ReportPath))
            [void][IO.Directory]::CreateDirectory($reportParent)
            $hostReport=[pscustomobject]@{hostExitCode=$exitCode;runDirectory=$runDirectory;resultPath=$finalResultPath;result=$finalResult;error=$hostError}
            Write-Utf8File $ReportPath (ConvertTo-Json -InputObject $hostReport -Depth 60)
        } catch {
            $exitCode=1
            Write-Host ('Unable to save host report: '+$_.Exception.Message) -ForegroundColor Red
        }
    }
    $env:PATH=$originalPath
    if($lock) { $lock.Dispose() }
    if($transcriptStarted) { try { Stop-Transcript | Out-Null } catch {} }
}
exit $exitCode
