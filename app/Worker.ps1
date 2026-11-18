[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('Inspect','Singapore','China','Setup','Diagnostics')][string]$Action,
    [Parameter(Mandatory=$true)][string]$TvIp,
    [Parameter(Mandatory=$true)][string]$JobDirectory,
    [Parameter(Mandatory=$true)][string]$KitRoot
)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

function Get-QProperty {
    param([object]$Object,[string]$Name)
    if($null -eq $Object) { return $null }
    $property=$Object.PSObject.Properties[$Name]
    if($null -eq $property) { return $null }
    return $property.Value
}

function Write-QJson {
    param([string]$Path,[object]$Value)
    $temporary=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($temporary,(ConvertTo-Json -InputObject $Value -Depth 60),(New-Object Text.UTF8Encoding($false)))
    try {
        if([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary,$Path,[NullString]::Value) }
        else { [IO.File]::Move($temporary,$Path) }
    } finally { if([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Write-QEvent {
    param([object]$Context,[string]$Message)
    try {
        $line=[DateTime]::UtcNow.ToString('o')+' '+$Message+[Environment]::NewLine
        [IO.File]::AppendAllText((Join-Path $Context.JobDirectory 'Worker.log'),$line,(New-Object Text.UTF8Encoding($false)))
    } catch { }
}

function Set-QProgress {
    param([object]$Context,[string]$Phase,[int]$Percent,[string]$Message,[string]$Status='running')
    try {
        Write-QJson (Join-Path $Context.JobDirectory 'progress.json') ([pscustomobject]@{
            status=$Status;phase=$Phase;percent=$Percent;message=$Message;updatedUtc=[DateTime]::UtcNow.ToString('o')
        })
    } catch { }
    Write-QEvent $Context ($Phase+': '+$Message)
}

function Get-QExpectedFirmware {
    return [ordered]@{
        '/usr/lib/libfactory-interface-DVBISDB.so'='5f418d8a41fd6f307c76d013e36a1e6637496a7583c12f5bfff7baae8ac95670'
        '/usr/lib/libfactory-data-config.so.00.00.0057'='d469fa60c691729bba332ede19ab7d35b593944912fe8afbb44149f8c5902c35'
        '/usr/bin/TIFSDaemon'='550d7260e6f2f6e0d41d83d95f51a15cfd90b4f839609ffcad67b5e1d29320db'
        '/factory_peq/factory-data/FactoryIndexFile_Part1.dat'='8c15d893bafc042683ed3c64e95c97d669f07188367a7b240bc912091c5d8fb5'
    }
}

function Assert-QNumber {
    param([object]$Object,[string]$Name,[int[]]$Allowed)
    $number=Get-QProperty $Object $Name
    if(($number -isnot [int] -and $number -isnot [long] -and $number -isnot [uint32] -and $number -isnot [uint64]) -or
        $Allowed -notcontains $number) { throw ('Unexpected numeric field: '+$Name) }
    return [int]$number
}

function Assert-QIdentity {
    param([object]$State,[object]$Other=$null)
    if((Get-QProperty $State 'buildId') -cne 'T-PTMUABC-REL-202509042046') { throw 'Firmware build does not match this kit.' }
    if((Get-QProperty $State 'deviceTokenSource') -cne '/etc/machine-id' -or
        ([string](Get-QProperty $State 'deviceToken')) -cnotmatch '^[a-f0-9]{64}$') { throw 'Machine identity binding is missing.' }
    $hashes=Get-QProperty $State 'evidenceHashes'
    if($null -eq $hashes -or @($hashes.PSObject.Properties).Count -ne 4) { throw 'The four firmware fingerprints are incomplete.' }
    $expected=Get-QExpectedFirmware
    foreach($path in $expected.Keys) {
        if((Get-QProperty $hashes $path) -cne $expected[$path]) { throw ('Firmware fingerprint mismatch: '+$path) }
    }
    if($null -ne $Other) {
        Assert-QIdentity $Other
        if((Get-QProperty $State 'deviceToken') -cne (Get-QProperty $Other 'deviceToken')) { throw 'This original baseline belongs to a different TV.' }
    }
}

function Test-QState {
    # Host-side eligibility only. The unchanged helpers recheck every native gate before writing.
    param([object]$State,[ValidateSet(1,2)][int]$Stage,[switch]$Original)
    try {
        if((Get-QProperty $State 'schema') -cne ('qn90b-stage'+$Stage+'-v1')) { throw 'Wrong stage baseline schema.' }
        if($null -eq $State.PSObject.Properties['readErrors'] -or @(Get-QProperty $State 'readErrors').Count -ne 0) { throw 'Required factory reads are incomplete.' }
        $null=Assert-QNumber $State 'effectiveUid' @(0)
        Assert-QIdentity $State
        $import=Get-QProperty $State 'preventImport'
        $null=Assert-QNumber $import 'uid' @(761)
        $null=Assert-QNumber $import 'tpid' @(140202)
        $null=Assert-QNumber $import 'minimum' @(0)
        $null=Assert-QNumber $import 'maximum' @(13)
        if((Get-QProperty $import 'name') -cne 'Preventing Import') { throw 'Preventing Import metadata label mismatch.' }
        $allowedImport=@(0,13)
        if($Stage -eq 2) { $allowedImport=@(0) }
        $importValue=Assert-QNumber $import 'value' $allowedImport
        if(([string](Get-QProperty $import 'display')).Trim() -cne [string]$importValue) { throw 'Import native and display values disagree.' }
        $null=Assert-QNumber $State 'maxStore' @(54)
        $store=Assert-QNumber $State 'currentStore' @(3,43)
        $global=Assert-QNumber $State 'globalEnum' @(25,65)
        $name=[string](Get-QProperty $State 'currentName')
        $china=$store -eq 43 -and $global -eq 65 -and $name -ceq 'CHI_DTV'
        $singapore=$store -eq 3 -and $global -eq 25 -and $name -ceq 'AD_SIN2'
        if((-not $china -and -not $singapore) -or ($Stage -eq 1 -and -not $china)) { throw 'Local Set store, global enum and name do not form a supported state.' }
        if($Stage -eq 2) {
            $local=Get-QProperty $State 'localSet'
            $null=Assert-QNumber $local 'uid' @(194)
            $null=Assert-QNumber $local 'tpid' @(401)
            if((Get-QProperty $local 'name') -cne 'Local Set' -or (Get-QProperty $local 'display') -cne $name) { throw 'Local Set metadata or display mismatch.' }
            $null=Assert-QNumber $local 'value' @($global)
            $null=Assert-QNumber $State 'convertedCurrentStore' @($store)
            $null=Assert-QNumber $State 'singaporeStore' @(3)
            $null=Assert-QNumber $State 'chinaStore' @(43)
            if((Get-QProperty $State 'singaporeName') -cne 'AD_SIN2' -or (Get-QProperty $State 'chinaName') -cne 'CHI_DTV') { throw 'Singapore/China reverse mapping mismatch.' }
        }
        $visible=@(Get-QProperty $State 'visibleLocalSets')
        if($visible.Count -eq 0) { throw 'The visible Local Set list is empty.' }
        $seen=@{}; $hasCurrent=$false; $hasChina=$false; $singaporeCount=0
        foreach($entry in $visible) {
            $entryStore=Assert-QNumber $entry 'store' @(0..54)
            $entryName=[string](Get-QProperty $entry 'name')
            if([string]::IsNullOrWhiteSpace($entryName) -or $seen.ContainsKey($entryStore)) { throw 'Invalid or duplicate Local Set entry.' }
            $seen[$entryStore]=$true
            if($entryStore -eq $store -and $entryName -ceq $name) { $hasCurrent=$true }
            if($entryStore -eq 43 -and $entryName -ceq 'CHI_DTV') { $hasChina=$true }
            if($entryName -ceq 'AD_SIN2') {
                if($entryStore -ne 3) { throw 'AD_SIN2 has an unexpected store.' }
                $singaporeCount++
            }
        }
        if(-not $hasCurrent -or ($Stage -eq 2 -and (-not $hasChina -or $singaporeCount -ne 1))) { throw 'The required Local Set names are missing.' }
        if($Original -and (-not $china -or ($Stage -eq 1 -and $importValue -ne 13))) { throw 'The file is not an original baseline for this stage.' }
        $category='SG0'
        if($china) { if($importValue -eq 13) { $category='CHI13' } else { $category='CHI0' } }
        return [pscustomobject]@{valid=$true;reason='';category=$category}
    } catch { return [pscustomobject]@{valid=$false;reason=$_.Exception.Message;category='Unknown'} }
}

function Get-QStateKey {
    param([object]$State)
    $import=Get-QProperty $State 'preventImport'
    $list=@(Get-QProperty $State 'visibleLocalSets' | Sort-Object -Property store | ForEach-Object { ([string]$_.store)+'='+$_.name }) -join '|'
    return ((@((Get-QProperty $State 'deviceToken'),(Get-QProperty $State 'deviceTokenSource'),(Get-QProperty $State 'buildId'),
        (Get-QProperty $import 'value'),(Get-QProperty $State 'maxStore'),(Get-QProperty $State 'currentStore'),
        (Get-QProperty $State 'currentName'),(Get-QProperty $State 'globalEnum'),$list)) -join ';')
}

function Get-QBaselinePath {
    param([object]$Context,[ValidateSet(1,2)][int]$Stage)
    return Join-Path (Join-Path (Join-Path $Context.WorkDirectory ('stage'+$Stage)) $Context.TvIp) 'Original-Baseline.json'
}

function Get-QBackup {
    param([object]$Context,[ValidateSet(1,2)][int]$Stage,[object]$State)
    $path=Get-QBaselinePath $Context $Stage
    $exists=[IO.File]::Exists($path)
    $available=$false; $reason='尚未保存这个阶段的原始备份。'
    if($exists) {
        try {
            if((New-Object IO.FileInfo($path)).Length -gt 1048576) { throw 'Baseline file is unexpectedly large.' }
            $baseline=[IO.File]::ReadAllText($path) | ConvertFrom-Json
            $check=Test-QState $baseline $Stage -Original
            if(-not $check.valid) { throw $check.reason }
            Assert-QIdentity $baseline $State
            if($null -eq $State) { throw 'A verified current TV identity is required.' }
            $available=$true; $reason='原始备份已核对，属于当前电视和固件。'
        } catch { $reason=$_.Exception.Message }
    }
    return [pscustomobject]@{available=$available;exists=$exists;path=$path;reason=$reason}
}

function Get-QBackups {
    param([object]$Context,[object]$State)
    return [pscustomobject]@{stage1=(Get-QBackup $Context 1 $State);stage2=(Get-QBackup $Context 2 $State)}
}

function Save-QCandidate {
    param([object]$Context,[int]$Stage,[object]$Candidate,[object]$State)
    if($null -eq $Candidate) { return }
    $check=Test-QState $Candidate $Stage -Original
    if(-not $check.valid) { throw ('Read returned an invalid original baseline: '+$check.reason) }
    Assert-QIdentity $Candidate $State
    if((Get-QStateKey $Candidate) -cne (Get-QStateKey $State)) { throw 'Read baseline candidate differs from the actual read state.' }
    $path=Get-QBaselinePath $Context $Stage
    if([IO.File]::Exists($path)) { return }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes((ConvertTo-Json -InputObject $Candidate -Depth 50))
    $stream=$null
    try {
        $stream=New-Object IO.FileStream($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $stream.Write($bytes,0,$bytes.Length); $stream.Flush()
        Write-QEvent $Context ('Saved observed Stage '+$Stage+' original baseline: '+$path)
    } catch {
        if($null -ne $stream -or -not [IO.File]::Exists($path)) { throw }
        # Another reader may have saved first; preserve its file and validate it below.
    } finally { if($null -ne $stream) { $stream.Dispose() } }
}

function New-QInspectCommand {
    param([object[]]$Files,[string]$Base1,[string]$Base2)
    foreach($base in @($Base1,$Base2)) {
        if($base -cnotmatch '^/home/owner/share/tmp/sdk_tools/qn90b_inspect_[a-f0-9]{32}_stage[12]$') { throw 'Invalid inspector staging path.' }
    }
    $checks=New-Object 'System.Collections.Generic.List[string]'
    $paths=New-Object 'System.Collections.Generic.List[string]'
    foreach($file in $Files) {
        if($file.Remote -cnotmatch '^/home/owner/share/tmp/sdk_tools/qn90b_inspect_[a-f0-9]{32}_stage[12]\.(dll|runtimeconfig.json|deps.json)$' -or
            $file.Sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid staged helper description.' }
        $checks.Add(('[ "$(sha256sum ''{0}'' | cut -d '' '' -f 1)" = ''{1}'' ]' -f $file.Remote,$file.Sha256))
        $paths.Add("'"+$file.Remote+"'")
    }
    if($Files.Count -ne 6) { throw 'Both three-file helpers are required.' }
    $lines=@(
        ('if '+($checks.ToArray() -join ' && ')+'; then'),
        ("  /usr/bin/dotnet '"+$Base1+".dll' read"),
        '  first_rc=$?',
        '  echo',
        '  echo QN90B_INSPECT_STAGE1_RC=$first_rc',
        ("  /usr/bin/dotnet '"+$Base2+".dll' read"),
        '  second_rc=$?',
        '  echo',
        '  echo QN90B_INSPECT_STAGE2_RC=$second_rc',
        '  if [ "$first_rc" -eq 0 ] || [ "$second_rc" -eq 0 ]; then rc=0; else rc=2; fi',
        'else',
        '  echo QN90B_INSPECT_INTEGRITY=failed >&2',
        '  rc=73',
        'fi',
        ('rm -f '+($paths.ToArray() -join ' ')),
        'cleanup_rc=$?',
        'if [ "$cleanup_rc" -eq 0 ]; then echo QN90B_INSPECT_CLEANED=yes; else echo QN90B_INSPECT_CLEANED=no >&2; if [ "$rc" -eq 0 ]; then rc=74; fi; fi',
        'exit "$rc"'
    )
    $command=($lines -join "`n")+"`n"
    if($command.IndexOf([char]92) -ge 0 -or $command.IndexOf([char]13) -ge 0) { throw 'Remote command contains unsupported escaping.' }
    return $command
}

function Read-QMarker {
    param([string]$Text,[string]$Prefix,[switch]$Optional)
    $lines=@($Text -split '\r?\n' | Where-Object { $_.StartsWith($Prefix,[StringComparison]::Ordinal) })
    if($Optional -and $lines.Count -eq 0) { return $null }
    if($lines.Count -ne 1) { throw ('Expected one result marker: '+$Prefix) }
    return $lines[0].Substring($Prefix.Length)
}

function ConvertFrom-QInspection {
    param([object]$RootProcess)
    $evidence=$RootProcess.Stdout | ConvertFrom-Json
    if((Get-QProperty $evidence 'authenticated') -ne $true) { throw 'Authenticated root was not confirmed.' }
    $null=Assert-QNumber $evidence 'uid' @(0)
    $null=Assert-QNumber $evidence 'euid' @(0)
    $commands=@(Get-QProperty $evidence 'commands')
    if($commands.Count -ne 1 -or $null -eq $commands[0]) { throw 'Inspector root evidence must contain exactly one combined read command.' }
    $command=$commands[0]
    $stdout=[string](Get-QProperty $command 'stdout')
    $null=Assert-QNumber $command 'exit_code' @(0)
    if($RootProcess.ExitCode -ne 0 -or (Get-QProperty $command 'timed_out') -ne $false) { throw 'The combined inspection did not complete.' }
    if((Get-QProperty $evidence 'staging_cleaned') -ne $true -or (Get-QProperty $evidence 'system_files_unchanged') -ne $true -or
        (Read-QMarker $stdout 'QN90B_INSPECT_CLEANED=') -cne 'yes') { throw 'Inspection cleanup or the root integrity check was not confirmed.' }
    $reads=New-Object 'System.Collections.Generic.List[object]'
    foreach($stage in @(1,2)) {
        $rcText=Read-QMarker $stdout ('QN90B_INSPECT_STAGE'+$stage+'_RC=')
        if($rcText -cnotmatch '^[0-9]{1,3}$') { throw 'Invalid individual helper exit code.' }
        $json=Read-QMarker $stdout ('QN90B_STAGE'+$stage+'_JSON=') -Optional
        $read=$null; $valid=$false; $reason='The helper did not return a read result.'; $category='Unknown'
        if($null -ne $json) {
            try { $read=$json | ConvertFrom-Json } catch { $reason='The helper returned malformed JSON.' }
            if($null -ne $read) {
                $reason=[string](Get-QProperty $read 'message')
                if((Get-QProperty $read 'phase') -ceq 'read' -and (Get-QProperty $read 'success') -eq $true -and [int]$rcText -eq 0) {
                    $check=Test-QState (Get-QProperty $read 'state') $stage
                    $valid=$check.valid; $reason=$check.reason; $category=$check.category
                }
            }
        }
        if([int]$rcText -eq 0 -and -not $valid) { throw ('Stage '+$stage+' exited zero without a complete, successful read: '+$reason) }
        $reads.Add([pscustomobject]@{stage=$stage;valid=$valid;exitCode=[int]$rcText;result=$read;category=$category;reason=$reason})
    }
    $validReads=@($reads | Where-Object {$_.valid})
    if($validReads.Count -eq 0) { throw 'Neither original helper confirmed a supported factory state.' }
    if($validReads.Count -eq 2 -and (Get-QStateKey $validReads[0].result.state) -cne (Get-QStateKey $validReads[1].result.state)) {
        throw 'The two successful reads disagree. No factory write is permitted.'
    }
    $chosen=$validReads[$validReads.Count-1]
    return [pscustomobject]@{success=$true;category=$chosen.category;state=$chosen.result.state;reads=$reads.ToArray();message='读取完成，电视状态已核对。'}
}

function Get-QHelperUploads {
    param([object]$Context,[int]$Stage,[string]$RemoteBase)
    $directory=Join-Path (Join-Path $Context.KitRoot 'engines') ('stage'+$Stage)
    $manifest=[IO.File]::ReadAllText((Join-Path $directory 'Helper-SHA256.json')) | ConvertFrom-Json
    $stem='QN90BStage'+$Stage
    foreach($suffix in @('.dll','.runtimeconfig.json','.deps.json')) {
        $name=$stem+$suffix
        $local=Join-Path $directory $name
        $expected=[string](Get-QProperty $manifest $name)
        if($expected -cnotmatch '^[a-f0-9]{64}$' -or -not [IO.File]::Exists($local)) { throw ('Missing helper or fingerprint: '+$name) }
        $actual=(Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash.ToLowerInvariant()
        if($actual -cne $expected) { throw ('Helper SHA256 mismatch: '+$name) }
        [pscustomobject]@{Local=$local;Remote=$RemoteBase+$suffix;Sha256=$actual}
    }
}

function Invoke-QInspectionTransport {
    param([object]$Context,[string]$Directory)
    [void][IO.Directory]::CreateDirectory($Directory)
    $tools=$Context.Tools
    $serial=$Context.TvIp+':26101'
    $connect=Invoke-CapturedTool $tools.Sdb @('connect',$serial) (Join-Path $Directory 'connect') 'SDB connection' $false
    Assert-SdbSuccess $connect 'SDB connection'
    $devices=Invoke-CapturedTool $tools.Sdb @('devices') (Join-Path $Directory 'devices') 'Exact TV model check' $false
    Assert-SdbSuccess $devices 'SDB device listing'
    $lines=@($devices.Stdout -split '\r?\n' | Where-Object {$_ -match ('^\s*'+[regex]::Escape($serial)+'\s+device\b')})
    if($lines.Count -ne 1) { throw 'SDB did not find the exact selected television.' }
    $fields=[regex]::Split($lines[0].Trim(),'\s+')
    if($fields.Count -lt 3 -or $fields[2] -cne 'QA75QN90BAJXXZ') { throw 'This kit requires the exact model QA75QN90BAJXXZ.' }
    $prefix='/home/owner/share/tmp/sdk_tools/qn90b_inspect_'+[Guid]::NewGuid().ToString('N')
    $base1=$prefix+'_stage1'; $base2=$prefix+'_stage2'
    $uploads=@(Get-QHelperUploads $Context 1 $base1)+@(Get-QHelperUploads $Context 2 $base2)
    $command=New-QInspectCommand $uploads $base1 $base2
    Write-Utf8File (Join-Path $Directory 'remote-command.sh') $command
    Write-QJson (Join-Path $Directory 'uploads.json') $uploads
    $index=0
    foreach($upload in $uploads) {
        $index++
        $push=Invoke-CapturedTool $tools.Sdb @('-s',$serial,'push',$upload.Local,$upload.Remote) (Join-Path $Directory ('push-'+$index)) ('Upload read helper '+$index) $false
        Assert-SdbSuccess $push 'Read helper upload'
    }
    $root=Invoke-CapturedTool $tools.Root @('--sdb',$tools.Sdb,'--output','json','archive-root','root',$Context.TvIp,'--runtime','3.1','--command',$command,'--command-timeout','480') (Join-Path $Directory 'root') 'One temporary root session: two read-only helpers' $false
    Write-Utf8File (Join-Path $Directory 'Root-Evidence.json') $root.Stdout
    return $root
}

function Get-QCapabilities {
    param([string]$Category,[object]$Backups,[bool]$Stage1Ready=$true,[bool]$Stage2Ready=$true)
    $canSingapore=$false; $canChina=$false
    switch -CaseSensitive ($Category) {
        'CHI13' {
            $canChina=$true
            $canSingapore=$Stage1Ready -and $Backups.stage1.available -and (-not $Backups.stage2.exists -or $Backups.stage2.available)
        }
        'CHI0' { $canSingapore=$Stage2Ready -and $Backups.stage2.available; $canChina=$Stage1Ready -and $Backups.stage1.available }
        'SG0' { $canSingapore=$true; $canChina=$Backups.stage1.available -and $Backups.stage2.available }
    }
    return [pscustomobject]@{canSingapore=[bool]$canSingapore;canChina=[bool]$canChina}
}

function Invoke-QInspect {
    param([object]$Context,[string]$Directory)
    $locks=New-Object 'System.Collections.Generic.List[object]'
    try {
        # Serialize the two reads and baseline capture against the original stage runners.
        foreach($stage in @(1,2)) {
            $stageDirectory=[IO.Path]::GetDirectoryName((Get-QBaselinePath $Context $stage))
            [void][IO.Directory]::CreateDirectory($stageDirectory)
            $locks.Add((New-Object IO.FileStream((Join-Path $stageDirectory 'runner.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)))
        }
        $process=Invoke-QInspectionTransport $Context $Directory
        $inspection=ConvertFrom-QInspection $process
        foreach($read in $inspection.reads) {
            if($read.valid) { Save-QCandidate $Context $read.stage (Get-QProperty $read.result 'baseline') $read.result.state }
        }
        $backups=Get-QBackups $Context $inspection.state
        $capabilities=Get-QCapabilities $inspection.category $backups $inspection.reads[0].valid $inspection.reads[1].valid
        $result=[pscustomobject]@{
            success=$true;category=$inspection.category;message=$inspection.message;state=$inspection.state
            stateVerified=$true;backups=$backups;reads=$inspection.reads
            canSingapore=$capabilities.canSingapore;canChina=$capabilities.canChina
        }
        Write-QJson (Join-Path $Directory 'Inspection-Result.json') $result
        return $result
    } catch {
        $result=[pscustomobject]@{
            success=$false;category='Unknown';message=$_.Exception.Message;state=$null;stateVerified=$false
            backups=(Get-QBackups $Context $null);reads=@();canSingapore=$false;canChina=$false
        }
        if([IO.Directory]::Exists($Directory)) { Write-QJson (Join-Path $Directory 'Inspection-Result.json') $result }
        return $result
    } finally { foreach($lock in $locks) { $lock.Dispose() } }
}

function Invoke-QStage {
    param([object]$Context,[ValidateSet(1,2)][int]$Stage,[ValidateSet('Apply','Restore')][string]$Phase,[string]$Directory)
    [void][IO.Directory]::CreateDirectory($Directory)
    $script=Join-Path (Join-Path (Join-Path $Context.KitRoot 'engines') ('stage'+$Stage)) ('QN90B-Stage'+$Stage+'.ps1')
    $reportPath=Join-Path $Directory 'host-report.json'
    $engine=Join-Path $PSHOME 'powershell.exe'
    $record=[pscustomobject]@{
        name=('Stage'+$Stage+$Phase);stage=$Stage;phase=$Phase.ToLowerInvariant();success=$false;category='Unknown'
        message='The stage host did not return a result.';state=$null;helperResult=$null;exitCode=$null
        runDirectory=$null;resultPath=$null;reportPath=$reportPath;writeAttempted=$null;changed=$null
        rollbackAttempted=$null;rollbackSucceeded=$null
    }
    try {
        $process=Invoke-CapturedTool $engine @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$script,'-Action',$Phase,'-TvIp',$Context.TvIp,'-NoExplorer','-ReportPath',$reportPath) (Join-Path $Directory 'host') $record.name $false
        $record.exitCode=$process.ExitCode
        if(-not [IO.File]::Exists($reportPath)) { throw 'The stage host summary is missing. Do not repeat a write until the logs are reviewed.' }
        $report=[IO.File]::ReadAllText($reportPath) | ConvertFrom-Json
        $record.runDirectory=Get-QProperty $report 'runDirectory'
        $record.resultPath=Get-QProperty $report 'resultPath'
        $helper=Get-QProperty $report 'result'
        $record.helperResult=$helper
        if($null -ne $helper) {
            $record.state=Get-QProperty $helper 'state'
            $record.message=[string](Get-QProperty $helper 'message')
            foreach($field in @('writeAttempted','changed','rollbackAttempted','rollbackSucceeded')) { $record.$field=(Get-QProperty $helper $field) -eq $true }
        }
        if($process.ExitCode -ne 0 -or (Get-QProperty $report 'hostExitCode') -ne 0) {
            $errorText=[string](Get-QProperty $report 'error')
            throw ('The stage host stopped. '+$errorText+' '+$record.message)
        }
        if((Get-QProperty $helper 'phase') -cne $record.phase -or (Get-QProperty $helper 'success') -ne $true) { throw ('The helper did not confirm this action. '+$record.message) }
        $check=Test-QState $record.state $Stage
        if(-not $check.valid) { throw ('The returned state is not eligible: '+$check.reason) }
        $expected='CHI0'
        if($Stage -eq 1 -and $Phase -eq 'Restore') { $expected='CHI13' }
        if($Stage -eq 2 -and $Phase -eq 'Apply') { $expected='SG0' }
        if($check.category -cne $expected) { throw 'The successful helper did not report the requested final parameter state.' }
        $record.success=$true; $record.category=$check.category
    } catch { $record.message=$_.Exception.Message }
    try { Write-QJson (Join-Path $Directory 'step-result.json') $record }
    catch { Write-QEvent $Context ('Secondary step summary could not be saved; retain the original host report: '+$reportPath+'; '+$_.Exception.Message) }
    return $record
}

function New-QWorkflowResult {
    param([object]$Context,[string]$RequestedAction)
    return [pscustomobject]@{
        schema='qn90b-region-assistant-result-v1';action=$RequestedAction;tvIp=$Context.TvIp
        success=$false;category='Unknown';message='';state=$null;stateVerified=$false
        backups=(Get-QBackups $Context $null);canSingapore=$false;canChina=$false
        steps=@();partialSuccess=$false;lastConfirmedCategory='Unknown';lastConfirmedState=$null
        diagnosticsPath=$null;jobDirectory=$Context.JobDirectory;finishedUtc=$null
    }
}

function Add-QStep {
    param([object]$Context,[object]$Result,[object]$Step)
    $Context.Steps.Add($Step)
    $Result.steps=$Context.Steps.ToArray()
    try { Write-QJson (Join-Path $Context.JobDirectory 'steps.json') $Result.steps }
    catch { Write-QEvent $Context ('Secondary step journal could not be saved; actual step outcomes are retained in memory and the original host reports: '+$_.Exception.Message) }
    Write-QEvent $Context ($Step.name+': '+$Step.message)
}

function Set-QConfirmedState {
    param([object]$Context,[object]$Result,[string]$Category,[object]$State)
    $Result.category=$Category; $Result.state=$State; $Result.stateVerified=$true
    $Result.lastConfirmedCategory=$Category; $Result.lastConfirmedState=$State
    $Result.backups=Get-QBackups $Context $State
    $capabilities=Get-QCapabilities $Category $Result.backups
    $Result.canSingapore=$capabilities.canSingapore; $Result.canChina=$capabilities.canChina
}

function Stop-QWorkflow {
    param([object]$Context,[object]$Result,[string]$Message,[object]$FailedStep=$null)
    $Result.success=$false; $Result.category='Unknown'; $Result.stateVerified=$false
    $Result.canSingapore=$false; $Result.canChina=$false; $Result.message=$Message
    if($null -ne $FailedStep) { $Result.state=$FailedStep.state }
    $Result.partialSuccess=@($Context.Steps | Where-Object { $_.success -eq $true -and (Get-QProperty $_ 'changed') -eq $true }).Count -gt 0
    if($Result.partialSuccess) { $Result.message+=' 前面已完成的阶段仍保留，本程序没有跨阶段自动撤销。' }
    return $Result
}

function Invoke-QWorkflowStage {
    param([object]$Context,[object]$Result,[int]$Stage,[string]$Phase,[int]$Index,[int]$Percent)
    Set-QProgress $Context ('Stage'+$Stage+$Phase) $Percent ('正在执行阶段 '+$Stage+'：'+$Phase+'。请保持电视和电脑开启。')
    $directory=Join-Path $Context.JobDirectory (('{0:D2}' -f $Index)+'-stage'+$Stage+'-'+$Phase.ToLowerInvariant())
    try { $step=Invoke-QStage $Context $Stage $Phase $directory }
    catch {
        $step=[pscustomobject]@{name=('Stage'+$Stage+$Phase);stage=$Stage;phase=$Phase.ToLowerInvariant();success=$false;category='Unknown';message=$_.Exception.Message;state=$null;writeAttempted=$null;changed=$null;rollbackAttempted=$null;rollbackSucceeded=$null}
    }
    Add-QStep $Context $Result $step
    if($step.success) { Set-QConfirmedState $Context $Result $step.category $step.state }
    return $step
}

function Invoke-QWorkflow {
    param([object]$Context,[ValidateSet('Inspect','Singapore','China')][string]$RequestedAction)
    $result=New-QWorkflowResult $Context $RequestedAction
    Set-QProgress $Context 'Inspect' 10 '正在只读检测电视，同时核对当前参数和已有备份。'
    $inspection=Invoke-QInspect $Context (Join-Path $Context.JobDirectory '01-inspect')
    $inspectStep=[pscustomobject]@{name='Inspect';success=$inspection.success;message=$inspection.message;category=$inspection.category;state=$inspection.state;changed=$false;writeAttempted=$false;rollbackAttempted=$false;rollbackSucceeded=$false}
    Add-QStep $Context $result $inspectStep
    $result.backups=$inspection.backups
    if(-not $inspection.success) { return Stop-QWorkflow $Context $result ('检测未通过，未启动参数写入。'+$inspection.message) }
    Set-QConfirmedState $Context $result $inspection.category $inspection.state
    $result.canSingapore=$inspection.canSingapore; $result.canChina=$inspection.canChina
    if($RequestedAction -eq 'Inspect') { $result.success=$true; $result.message='检测完成；原始备份已核对。没有修改电视参数。'; return $result }
    if($RequestedAction -eq 'Singapore') {
        if($inspection.category -ceq 'SG0') { $result.success=$true; $result.message='电视已经是新加坡 Local Set：AD_SIN2，Import 为 0。本次没有写入。'; return $result }
        if(-not $inspection.canSingapore) { return Stop-QWorkflow $Context $result '无法开始：缺少有效原始备份、已有备份不属于当前电视，或新加坡阶段检查未通过。' }
        $index=2
        if($inspection.category -ceq 'CHI13') {
            $stage1=Invoke-QWorkflowStage $Context $result 1 'Apply' $index 35
            if(-not $stage1.success) { return Stop-QWorkflow $Context $result ('阶段 1 未完成，已停止。'+$stage1.message) $stage1 }
            $index++
        }
        # Stage2 host performs its own fresh read and CreateNew baseline save before its setter.
        $stage2=Invoke-QWorkflowStage $Context $result 2 'Apply' $index 70
        if(-not $stage2.success) { return Stop-QWorkflow $Context $result ('阶段 2 未完成，已停止。'+$stage2.message) $stage2 }
        $result.success=$true; $result.message='新加坡 Local Set 已写入并回读确认：AD_SIN2 / store 3 / global 25，Import 保持 0。应用服务及重启后的状态需另外确认。'
        return $result
    }
    if($inspection.category -ceq 'CHI13') { $result.success=$true; $result.message='电视已经是原始国行参数 CHI_DTV、Import 13。本次没有写入。'; return $result }
    if(-not $inspection.canChina) { return Stop-QWorkflow $Context $result '无法恢复：需要属于当前电视的原始备份。缺失或不匹配时，不会编造原值，也不会开始恢复。' }
    $restoreIndex=2
    if($inspection.category -ceq 'SG0') {
        $stage2=Invoke-QWorkflowStage $Context $result 2 'Restore' $restoreIndex 40
        if(-not $stage2.success) { return Stop-QWorkflow $Context $result ('Local Set 恢复未完成，已停止。'+$stage2.message) $stage2 }
        $restoreIndex++
    }
    $stage1=Invoke-QWorkflowStage $Context $result 1 'Restore' $restoreIndex 75
    if(-not $stage1.success) { return Stop-QWorkflow $Context $result ('Import 恢复未完成，已停止。'+$stage1.message) $stage1 }
    $result.success=$true; $result.message='两项原始国行参数已回读确认：CHI_DTV / store 43 / global 65，Import 13。'
    return $result
}

function Copy-QDiagnosticTree {
    param([string]$Source,[string]$Destination)
    if(-not [IO.Directory]::Exists($Source)) { return }
    [void][IO.Directory]::CreateDirectory($Destination)
    $prefix=[IO.Path]::GetFullPath($Source).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    foreach($file in @(Get-ChildItem -LiteralPath $Source -Recurse -File -ErrorAction Stop)) {
        if(($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $file.Length -gt 20971520) { continue }
        if(@('.json','.txt','.log','.sh') -notcontains $file.Extension.ToLowerInvariant()) { continue }
        $full=[IO.Path]::GetFullPath($file.FullName)
        if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected diagnostic file path.' }
        $relative=$full.Substring($prefix.Length)
        $target=Join-Path $Destination $relative
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        [IO.File]::Copy($full,$target,$false)
    }
}

function New-QDiagnostics {
    # Local files only; this action does not call SDB, root, a helper, or a TV API.
    param([object]$Context)
    $temporaryRoot=Join-Path ([IO.Path]::GetTempPath()) ('QN90B-diagnostics-'+[Guid]::NewGuid().ToString('N'))
    $packageRoot=Join-Path $temporaryRoot 'QN90B-Diagnostics'
    [void][IO.Directory]::CreateDirectory($packageRoot)
    try {
        Copy-QDiagnosticTree $Context.JobDirectory (Join-Path $packageRoot 'current-job')
        $jobsRoot=Join-Path (Join-Path $env:LOCALAPPDATA 'QN90B-RegionAssistant') 'jobs'
        if([IO.Directory]::Exists($jobsRoot)) {
            $matching=New-Object 'System.Collections.Generic.List[object]'
            foreach($directory in @(Get-ChildItem -LiteralPath $jobsRoot -Directory)) {
                if($directory.FullName -ieq $Context.JobDirectory) { continue }
                $infoPath=Join-Path $directory.FullName 'JobInfo.json'
                if(-not [IO.File]::Exists($infoPath)) { continue }
                try {
                    $info=[IO.File]::ReadAllText($infoPath) | ConvertFrom-Json
                    if((Get-QProperty $info 'tvIp') -ceq $Context.TvIp -and (Get-QProperty $info 'action') -cne 'Diagnostics') { $matching.Add($directory) }
                } catch { }
            }
            foreach($directory in @($matching | Sort-Object -Property Name -Descending | Select-Object -First 3)) {
                Copy-QDiagnosticTree $directory.FullName (Join-Path (Join-Path $packageRoot 'recent-jobs') $directory.Name)
            }
        }
        foreach($stage in @(1,2)) {
            $baselinePath=Get-QBaselinePath $Context $stage
            $destination=Join-Path $packageRoot ('stage'+$stage)
            [void][IO.Directory]::CreateDirectory($destination)
            if([IO.File]::Exists($baselinePath)) { [IO.File]::Copy($baselinePath,(Join-Path $destination 'Original-Baseline.json'),$false) }
            $runs=Join-Path ([IO.Path]::GetDirectoryName($baselinePath)) 'runs'
            if([IO.Directory]::Exists($runs)) {
                foreach($directory in @(Get-ChildItem -LiteralPath $runs -Directory | Sort-Object -Property Name -Descending | Select-Object -First 2)) {
                    Copy-QDiagnosticTree $directory.FullName (Join-Path (Join-Path $destination 'recent-runs') $directory.Name)
                }
            }
        }
        Write-QJson (Join-Path $packageRoot 'package-info.json') ([pscustomobject]@{
            schema='qn90b-region-assistant-diagnostics-v1';tvIp=$Context.TvIp;createdUtc=[DateTime]::UtcNow.ToString('o')
            scope='Current job, up to three recent jobs for this TV, its two stage baselines, and up to two recent runs per stage. Local files only; no automatic upload.'
        })
        $path=Join-Path $Context.JobDirectory ('QN90B-Diagnostics-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N')+'.zip')
        $temporaryZip=Join-Path $Context.JobDirectory ('diagnostics-'+[Guid]::NewGuid().ToString('N')+'.tmp.zip')
        try {
            Compress-Archive -LiteralPath $packageRoot -DestinationPath $temporaryZip -CompressionLevel Optimal -ErrorAction Stop
            if(-not [IO.File]::Exists($temporaryZip) -or (New-Object IO.FileInfo($temporaryZip)).Length -eq 0) { throw 'Diagnostic archive was not created.' }
            [IO.File]::Move($temporaryZip,$path)
        } finally { if([IO.File]::Exists($temporaryZip)) { [IO.File]::Delete($temporaryZip) } }
        return $path
    } finally { if([IO.Directory]::Exists($temporaryRoot)) { [IO.Directory]::Delete($temporaryRoot,$true) } }
}

function Assert-QIPv4 {
    param([string]$Value)
    $address=$null
    if(-not [Net.IPAddress]::TryParse($Value,[ref]$address) -or $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        $address.ToString() -cne $Value) { throw '请输入完整的 IPv4 地址，例如 192.168.1.100。' }
}

function Invoke-QWorkerMain {
    param([string]$RequestedAction,[string]$Ip,[string]$OutputDirectory,[string]$PackageDirectory)
    $context=$null; $result=$null; $lock=$null; $setupLock=$null; $savedPath=$env:PATH; $exitCode=1
    try {
        Assert-QIPv4 $Ip
        $output=[IO.Path]::GetFullPath($OutputDirectory)
        $package=[IO.Path]::GetFullPath($PackageDirectory)
        [void][IO.Directory]::CreateDirectory($output)
        $work=Join-Path $env:LOCALAPPDATA 'QN90B-root'
        $context=[pscustomobject]@{TvIp=$Ip;JobDirectory=$output;KitRoot=$package;WorkDirectory=$work;Tools=$null;Steps=(New-Object 'System.Collections.Generic.List[object]')}
        Write-QJson (Join-Path $output 'JobInfo.json') ([pscustomobject]@{tvIp=$Ip;action=$RequestedAction;startedUtc=[DateTime]::UtcNow.ToString('o');schema='qn90b-region-assistant-job-v1'})
        $result=New-QWorkflowResult $context $RequestedAction
        if($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem -or
            $env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { throw '请在 Windows x64 电脑上运行本工具。' }
        $lockDirectory=Join-Path (Join-Path $work 'region-assistant') $Ip
        [void][IO.Directory]::CreateDirectory($lockDirectory)
        try { $lock=New-Object IO.FileStream((Join-Path $lockDirectory 'runner.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
        catch { throw '这台电视已有任务正在运行。请等待原任务完成。' }
        . (Join-Path (Join-Path (Join-Path $package 'engines') 'stage1') 'HostFunctions.ps1')
        . (Join-Path (Join-Path $package 'app') 'Dependencies.ps1')
        if($RequestedAction -eq 'Diagnostics') {
            Set-QProgress $context 'Diagnostics' 25 '正在整理这台电视的本地日志与备份；不会连接电视。'
            $result.success=$true; $result.category='Diagnostics'; $result.message='诊断包已保存，可自行选择是否分享。没有连接电视。'
            Write-QJson (Join-Path $output 'result.json') $result
            $result.diagnosticsPath=New-QDiagnostics $context
        } elseif($RequestedAction -eq 'Setup') {
            try { $setupLock=New-Object IO.FileStream((Join-Path $work 'region-assistant-setup.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
            catch { throw '另一份工具正在安装环境。请等待该安装完成。' }
            Set-QProgress $context 'Setup' 10 '正在检查和准备电脑端依赖。'
            $callback={param($percent,$message) Set-QProgress $context 'Setup' ([Math]::Max(5,[Math]::Min(95,[int]$percent))) ([string]$message)}.GetNewClosure()
            $context.Tools=Install-Qn90bDependencies -KitRoot $package -ProgressCallback $callback
            $result.success=$true; $result.category='Setup'; $result.message='电脑端环境已准备好。下一步请点击“检测当前状态”。没有修改电视参数。'
        } else {
            Set-QProgress $context 'Dependencies' 3 '正在核对电脑端工具。'
            try { $context.Tools=Get-Qn90bTools -KitRoot $package }
            catch { throw ('电脑端依赖未就绪，请先点击“安装 / 检查环境”。'+$_.Exception.Message) }
            $result=Invoke-QWorkflow $context $RequestedAction
        }
        if($result.success) { $exitCode=0 }
    } catch {
        if($null -ne $context) {
            if($null -eq $result) { $result=New-QWorkflowResult $context $RequestedAction }
            $result.success=$false; $result.category='Unknown'; $result.stateVerified=$false
            $result.canSingapore=$false; $result.canChina=$false; $result.message=$_.Exception.Message
            try { Write-QEvent $context ($_.Exception.ToString()+[Environment]::NewLine+$_.ScriptStackTrace) } catch { }
        } else { Write-Error $_.Exception.Message -ErrorAction Continue }
    } finally {
        if($null -ne $context -and $null -ne $result) {
            try {
                $result.finishedUtc=[DateTime]::UtcNow.ToString('o')
                Write-QJson (Join-Path $context.JobDirectory 'result.json') $result
                $status='failed'; if($result.success) { $status='completed' }
                Set-QProgress $context 'Finished' 100 $result.message $status
                if($RequestedAction -ne 'Diagnostics') {
                    try {
                        $result.diagnosticsPath=New-QDiagnostics $context
                        Write-QJson (Join-Path $context.JobDirectory 'result.json') $result
                    } catch { Write-QEvent $context ('Diagnostic packaging failed: '+$_.Exception.Message) }
                }
            } catch { $exitCode=1; Write-Error ('Could not save the worker result: '+$_.Exception.Message) -ErrorAction Continue }
        }
        if($setupLock) { $setupLock.Dispose() }
        if($lock) { $lock.Dispose() }
        $env:PATH=$savedPath
    }
    return $exitCode
}

exit (Invoke-QWorkerMain -RequestedAction $Action -Ip $TvIp -OutputDirectory $JobDirectory -PackageDirectory $KitRoot)
