param([string]$KitRoot=$env:QN90B_TEST_KIT)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
# The minimal offline PowerShell host has no filesystem module. This shim is used
# only for fixture paths; Windows PowerShell uses its standard Join-Path cmdlet.
function Join-Path { param([string]$Path,[string]$ChildPath) return [IO.Path]::Combine($Path,$ChildPath) }
if(-not $KitRoot) { throw 'Set QN90B_TEST_KIT to the assistant kit before running offline tests.' }
$worker=Join-Path (Join-Path $KitRoot 'app') 'Worker.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($worker,[ref]$tokens,[ref]$errors)
if($errors.Count) { throw 'Worker contains PowerShell syntax errors.' }
foreach($function in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    . ([scriptblock]::Create($function.Extent.Text))
}
# Only function definitions are imported. Worker entry point and all TV processes are excluded.
function Invoke-CapturedTool { throw 'Unexpected external process in an offline test.' }
$realInvokeStage=${function:Invoke-QStage}
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('qn90b-assistant-tests-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$script:passed=0; $script:failed=0

function Assert-True { param([bool]$Value,[string]$Message) if(-not $Value) { throw $Message } }
function Assert-Equal { param($Expected,$Actual,[string]$Message) if($Expected -cne $Actual) { throw ($Message+' expected='+$Expected+' actual='+$Actual) } }
function Assert-Rejected { param([scriptblock]$Work) $rejected=$false; try { & $Work | Out-Null } catch { $rejected=$true }; Assert-True $rejected 'Expected rejection.' }
function Copy-Fixture { param($Value) return (ConvertTo-Json -InputObject $Value -Depth 60 | ConvertFrom-Json) }
function Run-Test {
    param([string]$Name,[scriptblock]$Work)
    try { & $Work; $script:passed++; 'PASS '+$Name }
    catch { $script:failed++; 'FAIL '+$Name+': '+$_.Exception.Message; $_.ScriptStackTrace }
}
function New-TestContext {
    $directory=Join-Path $fixtureRoot ([Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($directory)
    return [pscustomobject]@{TvIp='192.168.1.100';JobDirectory=$directory;KitRoot=$KitRoot;WorkDirectory=(Join-Path $directory 'work');Tools=$null;Steps=(New-Object 'System.Collections.Generic.List[object]')}
}
function New-State {
    param([int]$Stage,[string]$Category)
    $import=0; $store=43; $global=65; $name='CHI_DTV'
    if($Category -eq 'CHI13') { $import=13 }
    if($Category -eq 'SG0') { $store=3; $global=25; $name='AD_SIN2' }
    $visible=@([pscustomobject]@{store=0;name='NONE'},[pscustomobject]@{store=43;name='CHI_DTV'})
    if($import -eq 0) { $visible=@([pscustomobject]@{store=0;name='NONE'},[pscustomobject]@{store=3;name='AD_SIN2'},[pscustomobject]@{store=43;name='CHI_DTV'}) }
    $state=[ordered]@{
        schema=('qn90b-stage'+$Stage+'-v1');capturedUtc='2026-11-18T00:00:00Z';effectiveUid=0
        buildId='T-PTMUABC-REL-202509042046';deviceToken=('a'*64);deviceTokenSource='/etc/machine-id'
        evidenceHashes=(Get-QExpectedFirmware);preventImport=[ordered]@{uid=761;tpid=140202;name='Preventing Import';display=[string]$import;value=$import;minimum=0;maximum=13}
        maxStore=54;currentStore=$store;currentName=$name;globalEnum=$global;visibleLocalSets=$visible;readErrors=@();readyToWrite=$true;writeGateReason=''
    }
    if($Stage -eq 2) {
        $state.localSet=[ordered]@{uid=194;tpid=401;name='Local Set';display=$name;value=$global;minimum=$null;maximum=$null}
        $state.convertedCurrentStore=$store; $state.singaporeStore=3; $state.singaporeName='AD_SIN2'; $state.chinaStore=43; $state.chinaName='CHI_DTV'
    }
    return Copy-Fixture $state
}
function New-Read {
    param([int]$Stage,[string]$Category,[bool]$Success=$true)
    $state=New-State $Stage $Category
    $baseline=$null
    if($Success -and (($Stage -eq 1 -and $Category -eq 'CHI13') -or ($Stage -eq 2 -and $Category -eq 'CHI0'))) { $baseline=Copy-Fixture $state }
    return [pscustomobject]@{phase='read';success=$Success;changed=$false;writeAttempted=$false;message='fixture';state=$state;baseline=$baseline;rollbackAttempted=$false;rollbackSucceeded=$false}
}
function New-RootEvidence {
    param($Read1,$Read2,[int]$Rc1=0,[int]$Rc2=0,[int]$OuterRc=0)
    $stdout='QN90B_STAGE1_JSON='+(ConvertTo-Json -InputObject $Read1 -Depth 60 -Compress)+"`nQN90B_INSPECT_STAGE1_RC="+$Rc1+"`n"+
        'QN90B_STAGE2_JSON='+(ConvertTo-Json -InputObject $Read2 -Depth 60 -Compress)+"`nQN90B_INSPECT_STAGE2_RC="+$Rc2+"`nQN90B_INSPECT_CLEANED=yes`n"
    $evidence=[ordered]@{authenticated=$true;uid=0;euid=0;staging_cleaned=$true;system_files_unchanged=$true;commands=@([ordered]@{stdout=$stdout;stderr='';exit_code=$OuterRc;timed_out=$false})}
    return [pscustomobject]@{ExitCode=$OuterRc;Stdout=(ConvertTo-Json -InputObject $evidence -Depth 70 -Compress);Stderr=''}
}
function Save-FixtureBaseline {
    param($Context,[int]$Stage)
    $category='CHI0'; if($Stage -eq 1) { $category='CHI13' }
    $state=New-State $Stage $category
    Save-QCandidate $Context $Stage $state $state
}

Run-Test 'Inspector recognizes CHI13 from Stage1 success and Stage2 guard failure' {
    $result=ConvertFrom-QInspection (New-RootEvidence (New-Read 1 'CHI13') (New-Read 2 'CHI13' $false) 0 2)
    Assert-Equal 'CHI13' $result.category 'Wrong category.'
    Assert-True (-not $result.reads[1].valid) 'Failed guard was promoted to valid.'
}
Run-Test 'Inspector recognizes consistent CHI0 from two successful reads' {
    $result=ConvertFrom-QInspection (New-RootEvidence (New-Read 1 'CHI0') (New-Read 2 'CHI0'))
    Assert-Equal 'CHI0' $result.category 'Wrong category.'
    Assert-True ($result.reads[0].valid -and $result.reads[1].valid) 'Both reads should pass.'
}
Run-Test 'Inspector recognizes SG0 only from successful Stage2 read' {
    $result=ConvertFrom-QInspection (New-RootEvidence (New-Read 1 'SG0' $false) (New-Read 2 'SG0') 2 0)
    Assert-Equal 'SG0' $result.category 'Wrong category.'
}
Run-Test 'Nonzero individual read cannot become success from its JSON' {
    Assert-Rejected { ConvertFrom-QInspection (New-RootEvidence (New-Read 1 'CHI13') (New-Read 2 'CHI13' $false) 2 2) }
}
Run-Test 'Outer failure and two failed readers cannot authorize writes' {
    Assert-Rejected { ConvertFrom-QInspection (New-RootEvidence (New-Read 1 'CHI13') (New-Read 2 'CHI13' $false) 0 2 74) }
    Assert-Rejected { ConvertFrom-QInspection (New-RootEvidence (New-Read 1 'CHI13' $false) (New-Read 2 'CHI13' $false) 2 2) }
}
Run-Test 'Two nominally successful readers with different device identities are rejected' {
    $second=New-Read 2 'CHI0'; $second.state.deviceToken='b'*64
    Assert-Rejected { ConvertFrom-QInspection (New-RootEvidence (New-Read 1 'CHI0') $second) }
}
Run-Test 'Fingerprint metadata and wrong schema cannot masquerade as successful reads' {
    foreach($kind in @('hash','metadata','schema')) {
        $read=New-Read 2 'SG0'
        if($kind -eq 'hash') { $read.state.evidenceHashes.'/usr/bin/TIFSDaemon'='0'*64 }
        if($kind -eq 'metadata') { $read.state.localSet.tpid=402 }
        if($kind -eq 'schema') { $read.state.schema='qn90b-stage1-v1' }
        Assert-Rejected { ConvertFrom-QInspection (New-RootEvidence (New-Read 1 'SG0' $false) $read 2 0) }
    }
}
Run-Test 'Inspector command is read-only with independent status capture and zero backslashes' {
    $base='/home/owner/share/tmp/sdk_tools/qn90b_inspect_'+('a'*32)
    $files=@()
    foreach($stage in @(1,2)) { foreach($suffix in @('.dll','.runtimeconfig.json','.deps.json')) { $files+=[pscustomobject]@{Remote=$base+'_stage'+$stage+$suffix;Sha256=('b'*64)} } }
    $command=New-QInspectCommand $files ($base+'_stage1') ($base+'_stage2')
    Assert-True ($command.IndexOf([char]92) -lt 0 -and $command.IndexOf([char]13) -lt 0) 'Unsupported root-agent escaping.'
    Assert-True ($command.Contains('first_rc=$?') -and $command.Contains('second_rc=$?')) 'Read exit codes are not captured independently.'
    Assert-True (-not ($command -match '\b(apply|restore)\b')) 'Inspector requested a write action.'
    Assert-True ($command.Contains('if [ "$first_rc" -eq 0 ] || [ "$second_rc" -eq 0 ]')) 'Combined root success condition is incorrect.'
}
Run-Test 'Actual observed baseline is saved once and original bytes are retained' {
    $context=New-TestContext; $state=New-State 1 'CHI13'
    Save-QCandidate $context 1 $state $state
    $path=Get-QBaselinePath $context 1; $before=[IO.File]::ReadAllText($path)
    $state.capturedUtc='2030-01-01T00:00:00Z'; Save-QCandidate $context 1 $state $state
    Assert-Equal $before ([IO.File]::ReadAllText($path)) 'Original baseline was overwritten.'
    Assert-True (Get-QBackup $context 1 $state).available 'Saved observed baseline rejected.'
}
Run-Test 'Foreign-device and wrong-stage baselines are unavailable' {
    $context=New-TestContext; Save-FixtureBaseline $context 1
    $foreign=New-State 2 'SG0'; $foreign.deviceToken='b'*64
    Assert-True (-not (Get-QBackup $context 1 $foreign).available) 'Foreign TV baseline was accepted.'
    $path=Get-QBaselinePath $context 2; [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    [IO.File]::Copy((Get-QBaselinePath $context 1),$path)
    Assert-True (-not (Get-QBackup $context 2 (New-State 2 'SG0')).available) 'Stage1 Import13 baseline authorized Stage2.'
}
Run-Test 'Baseline candidate must equal the actual successful read state' {
    $context=New-TestContext; $current=New-State 1 'CHI0'; $candidate=New-State 1 'CHI13'
    Assert-Rejected { Save-QCandidate $context 1 $candidate $current }
    Assert-True (-not [IO.File]::Exists((Get-QBaselinePath $context 1))) 'A fabricated original baseline was written.'
}

# The workflow mocks replace only external inspection and existing stage-host execution.
$script:mockCategory='CHI13'; $script:mockFailure=''; $script:called=New-Object 'System.Collections.Generic.List[string]'
function Invoke-QInspect {
    param($Context,$Directory)
    $stage=2; if($script:mockCategory -eq 'CHI13') { $stage=1 }
    $state=New-State $stage $script:mockCategory
    $backups=Get-QBackups $Context $state
    $caps=Get-QCapabilities $script:mockCategory $backups
    return [pscustomobject]@{success=$true;category=$script:mockCategory;state=$state;message='Mock inspected';backups=$backups;canSingapore=$caps.canSingapore;canChina=$caps.canChina}
}
function Invoke-QStage {
    param($Context,[int]$Stage,[string]$Phase,$Directory)
    $name='Stage'+$Stage+$Phase; $script:called.Add($name)
    if($Stage -eq 2 -and $Phase -eq 'Apply' -and -not [IO.File]::Exists((Get-QBaselinePath $Context 2))) { Save-FixtureBaseline $Context 2 }
    $category='CHI0'
    if($Stage -eq 1 -and $Phase -eq 'Restore') { $category='CHI13' }
    if($Stage -eq 2 -and $Phase -eq 'Apply') { $category='SG0' }
    $success=$name -cne $script:mockFailure
    if(-not $success) { if($Stage -eq 1) { $category='CHI13' } else { $category='CHI0' } }
    return [pscustomobject]@{name=$name;success=$success;stage=$Stage;phase=$Phase.ToLowerInvariant();category=$category;state=(New-State $Stage $category);message='Mock stage';writeAttempted=$true;changed=$success;rollbackAttempted=(-not $success);rollbackSucceeded=(-not $success)}
}
function Initialize-WorkflowFixture {
    param([string]$Category,[switch]$Baseline1,[switch]$Baseline2,[string]$Failure='')
    $script:mockCategory=$Category; $script:mockFailure=$Failure; $script:called.Clear()
    $context=New-TestContext
    if($Baseline1) { Save-FixtureBaseline $context 1 }
    if($Baseline2) { Save-FixtureBaseline $context 2 }
    return $context
}
Run-Test 'Singapore from CHI13 executes Stage1 Apply then Stage2 Apply' {
    $context=Initialize-WorkflowFixture 'CHI13' -Baseline1
    $result=Invoke-QWorkflow $context 'Singapore'
    Assert-Equal 'Stage1Apply,Stage2Apply' ($script:called.ToArray() -join ',') 'Wrong apply order.'
    Assert-True ($result.success -and $result.category -ceq 'SG0') 'Singapore result failed.'
}
Run-Test 'Singapore from CHI0 executes only Stage2 Apply' {
    $context=Initialize-WorkflowFixture 'CHI0' -Baseline2
    $result=Invoke-QWorkflow $context 'Singapore'
    Assert-Equal 'Stage2Apply' ($script:called.ToArray() -join ',') 'Unexpected first-stage write.'
    Assert-True $result.success 'Second-stage apply failed.'
}
Run-Test 'Singapore already SG0 and China already CHI13 perform no writes' {
    $context=Initialize-WorkflowFixture 'SG0'
    $result=Invoke-QWorkflow $context 'Singapore'
    Assert-True ($result.success -and $script:called.Count -eq 0) 'SG0 was written again.'
    $context=Initialize-WorkflowFixture 'CHI13'
    $result=Invoke-QWorkflow $context 'China'
    Assert-True ($result.success -and $script:called.Count -eq 0) 'CHI13 was written again.'
}
Run-Test 'Full China restore verifies both baselines before the first write' {
    $context=Initialize-WorkflowFixture 'SG0' -Baseline2
    $result=Invoke-QWorkflow $context 'China'
    Assert-True (-not $result.success -and $script:called.Count -eq 0) 'Restoration started with missing Stage1 backup.'
    $context=Initialize-WorkflowFixture 'SG0' -Baseline1
    $result=Invoke-QWorkflow $context 'China'
    Assert-True (-not $result.success -and $script:called.Count -eq 0) 'Restoration started with missing Stage2 backup.'
}
Run-Test 'China from SG0 restores Stage2 first and then Stage1' {
    $context=Initialize-WorkflowFixture 'SG0' -Baseline1 -Baseline2
    $result=Invoke-QWorkflow $context 'China'
    Assert-Equal 'Stage2Restore,Stage1Restore' ($script:called.ToArray() -join ',') 'Wrong restore order.'
    Assert-True ($result.success -and $result.category -ceq 'CHI13') 'China result failed.'
}
Run-Test 'China from CHI0 restores only Stage1' {
    $context=Initialize-WorkflowFixture 'CHI0' -Baseline1
    $result=Invoke-QWorkflow $context 'China'
    Assert-Equal 'Stage1Restore' ($script:called.ToArray() -join ',') 'Unexpected Local Set write.'
    Assert-True $result.success 'Import restore failed.'
}
Run-Test 'Stage1 Apply failure stops without Stage2 or additional write retry' {
    $context=Initialize-WorkflowFixture 'CHI13' -Baseline1 -Failure 'Stage1Apply'
    $result=Invoke-QWorkflow $context 'Singapore'
    Assert-Equal 'Stage1Apply' ($script:called.ToArray() -join ',') 'Failure was retried or continued.'
    Assert-True (-not $result.success -and -not $result.stateVerified) 'Failure claimed a verified successful state.'
}
Run-Test 'Stage2 Apply failure retains successful Stage1 and original rollback report' {
    $context=Initialize-WorkflowFixture 'CHI13' -Baseline1 -Failure 'Stage2Apply'
    $result=Invoke-QWorkflow $context 'Singapore'
    Assert-Equal 'Stage1Apply,Stage2Apply' ($script:called.ToArray() -join ',') 'Cross-stage compensation was attempted.'
    Assert-True (-not $result.success -and $result.partialSuccess -and $result.lastConfirmedCategory -ceq 'CHI0') 'Partial progress was lost.'
    Assert-True ($result.steps[2].rollbackAttempted -and $result.steps[2].rollbackSucceeded -and -not $result.stateVerified) 'Rollback evidence was misreported.'
}
Run-Test 'Stage2 Restore failure stops before Import restriction is restored' {
    $context=Initialize-WorkflowFixture 'SG0' -Baseline1 -Baseline2 -Failure 'Stage2Restore'
    $result=Invoke-QWorkflow $context 'China'
    Assert-Equal 'Stage2Restore' ($script:called.ToArray() -join ',') 'Import restoration continued after failed Local Set restoration.'
    Assert-True (-not $result.success) 'Failure claimed success.'
}
Run-Test 'Stage1 Restore failure never compensates back to Singapore' {
    $context=Initialize-WorkflowFixture 'SG0' -Baseline1 -Baseline2 -Failure 'Stage1Restore'
    $result=Invoke-QWorkflow $context 'China'
    Assert-Equal 'Stage2Restore,Stage1Restore' ($script:called.ToArray() -join ',') 'Unexpected compensation or retry.'
    Assert-True (-not $result.success -and $result.partialSuccess) 'Successful Local Set restoration was not retained.'
}
Run-Test 'Read-only workflow never dispatches an existing host write' {
    $context=Initialize-WorkflowFixture 'SG0' -Baseline1 -Baseline2
    $result=Invoke-QWorkflow $context 'Inspect'
    Assert-True ($result.success -and $script:called.Count -eq 0) 'Inspect started a factory write.'
}

# Invoke the actual host-result adapter with a process mock; no powershell.exe is launched.
function Invoke-CapturedTool {
    param($Executable,[string[]]$ArgumentList,$LogPrefix,$Label,$ShowOutput)
    $index=[Array]::IndexOf($ArgumentList,'-ReportPath')
    Assert-True ($index -ge 0 -and $ArgumentList -contains '-NoExplorer') 'Host was not given explicit summary/no-window arguments.'
    Write-QJson $ArgumentList[$index+1] $script:hostReport
    return [pscustomobject]@{ExitCode=$script:hostExitCode;Stdout='';Stderr=''}
}
Run-Test 'Nonzero host exit rejects even a successful helper marker' {
    $context=New-TestContext
    $helper=New-Read 2 'SG0'; $helper.phase='apply'
    $script:hostReport=[pscustomobject]@{hostExitCode=1;runDirectory='fixture';resultPath='fixture';result=$helper;error='Cleanup not confirmed'}
    $script:hostExitCode=1
    $record=& $realInvokeStage $context 2 'Apply' (Join-Path $context.JobDirectory 'stage')
    Assert-True (-not $record.success -and $null -ne $record.state) 'Host failure was promoted or its state lost.'
}
Run-Test 'Failed helper state and rollback evidence are preserved exactly' {
    $context=New-TestContext
    $helper=New-Read 2 'CHI0' $false; $helper.phase='apply'; $helper.writeAttempted=$true; $helper.rollbackAttempted=$true; $helper.rollbackSucceeded=$true
    $script:hostReport=[pscustomobject]@{hostExitCode=1;runDirectory='fixture';resultPath='fixture';result=$helper;error='Helper stopped'}
    $script:hostExitCode=1
    $record=& $realInvokeStage $context 2 'Apply' (Join-Path $context.JobDirectory 'stage')
    Assert-True (-not $record.success -and $record.rollbackAttempted -and $record.rollbackSucceeded -and $record.state.currentStore -eq 43) 'Failure evidence was changed.'
}

$realWriteJson=${function:Write-QJson}
function Write-QJson {
    param([string]$Path,[object]$Value)
    if($Path.EndsWith('step-result.json') -or $Path.EndsWith('steps.json') -or $Path.EndsWith('progress.json')) { throw 'Injected secondary-log disk failure.' }
    & $realWriteJson $Path $Value
}
function Invoke-QStage { param($Context,[int]$Stage,[string]$Phase,$Directory) & $realInvokeStage $Context $Stage $Phase $Directory }
Run-Test 'Secondary summary journal and progress failures preserve actual write outcome' {
    $context=New-TestContext
    $helper=New-Read 2 'SG0'; $helper.phase='apply'; $helper.writeAttempted=$true; $helper.changed=$true
    $script:hostReport=[pscustomobject]@{hostExitCode=0;runDirectory='fixture';resultPath='fixture';result=$helper;error=''}
    $script:hostExitCode=0
    $result=New-QWorkflowResult $context 'Singapore'
    $record=Invoke-QWorkflowStage $context $result 2 'Apply' 2 70
    Assert-True ($record.success -and $record.writeAttempted -and $record.changed) 'Logging failure erased actual write fields.'
    Assert-True ($result.steps.Count -eq 1 -and $result.steps[0].changed -and $result.stateVerified -and $result.category -ceq 'SG0') 'Actual outcome was lost from the workflow.'
    Assert-True ([IO.File]::Exists($record.reportPath)) 'The primary host evidence was not retained.'
}

'TOTAL passed='+$script:passed+' failed='+$script:failed
if($script:failed -ne 0) { Write-Error -Message ($script:failed.ToString()+' offline tests failed.') -ErrorAction Continue }
