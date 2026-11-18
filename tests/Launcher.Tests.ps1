param(
    [string]$KitRoot=$env:QN90B_TEST_KIT,
    [string]$PythonPath=$env:QN90B_TEST_PYTHON
)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
# Python is used only for local argument echo and pipe-draining fixtures.
if(-not $PythonPath) {
    $pythonCommand=Get-Command python -CommandType Application -ErrorAction SilentlyContinue
    if($null -eq $pythonCommand) { $pythonCommand=Get-Command python3 -CommandType Application -ErrorAction Stop }
    $PythonPath=$pythonCommand.Source
}
if(-not [IO.File]::Exists($PythonPath)) { throw 'A local Python 3 executable is required for two launcher fixtures.' }
function Join-Path { param([string]$Path,[string]$ChildPath) return [IO.Path]::Combine($Path,$ChildPath) }
if(-not $KitRoot) { throw 'Set QN90B_TEST_KIT to the assistant kit for offline tests.' }
$launcher=Join-Path (Join-Path $KitRoot 'app') 'Launcher.ps1'
$tokens=$null; $parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($launcher,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count) { throw 'Launcher has parser errors.' }
foreach($function in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    . ([scriptblock]::Create($function.Extent.Text))
}
# Import functions only. Do not execute GUI startup, Worker, SDB, root or any TV code.
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('qn90b-gui-tests-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$script:passed=0; $script:failed=0
function Assert-True {param([bool]$Value,[string]$Message) if(-not $Value){throw $Message}}
function Assert-Equal {param($Expected,$Actual,[string]$Message) if($Expected -cne $Actual){throw ($Message+' expected='+$Expected+' actual='+$Actual)}}
function Copy-Result {param($Value) return (ConvertTo-Json -InputObject $Value -Depth 20 | ConvertFrom-Json)}
function Run-Test {
    param([string]$Name,[scriptblock]$Work)
    try {& $Work;$script:passed++;'PASS '+$Name}
    catch {$script:failed++;'FAIL '+$Name+': '+$_.Exception.Message;$_.ScriptStackTrace}
}
function New-Result {
    param([string]$Action='Inspect',[string]$Category='SG0')
    return [pscustomobject]@{
        action=$Action;success=$true;category=$Category;message='Fixture result'
        stateVerified=$true;state=[pscustomobject]@{currentName='AD_SIN2';currentStore=3;globalEnum=25;preventImport=[pscustomobject]@{value=0}}
        canSingapore=$true;canChina=$true;partialSuccess=$false
    }
}

Run-Test 'Strict result accepts all three verified Inspect categories' {
    foreach($category in @('CHI13','CHI0','SG0')) {
        $a=Get-LauncherResultAssessment (New-Result 'Inspect' $category) 0 'Inspect'
        Assert-True ($a.Success -and $a.VerifiedTv) ('Rejected '+$category)
    }
}
Run-Test 'Singapore and China require their requested final categories' {
    Assert-True (Get-LauncherResultAssessment (New-Result 'Singapore' 'SG0') 0 'Singapore').Success 'SG0 rejected'
    Assert-True (Get-LauncherResultAssessment (New-Result 'China' 'CHI13') 0 'China').Success 'CHI13 rejected'
    Assert-True (-not (Get-LauncherResultAssessment (New-Result 'Singapore' 'CHI0') 0 'Singapore').Success) 'Partial CHI0 counted as Singapore success'
    Assert-True (-not (Get-LauncherResultAssessment (New-Result 'China' 'CHI0') 0 'China').Success) 'Partial CHI0 counted as restored China'
}
Run-Test 'Nonzero exit rejects an otherwise successful result' {
    $a=Get-LauncherResultAssessment (New-Result) 1 'Inspect'
    Assert-True (-not $a.Success -and -not $a.CanSingapore -and -not $a.CanChina) 'Exit failure enabled writing'
}
Run-Test 'Success must be a real Boolean true' {
    foreach($value in @($false,'true',1,$null)) {
        $r=New-Result; $r.success=$value
        Assert-True (-not (Get-LauncherResultAssessment $r 0 'Inspect').Success) 'Nonboolean success accepted'
    }
}
Run-Test 'stateVerified is mandatory and must be Boolean true' {
    foreach($value in @($false,'true',1,$null)) {
        $r=New-Result; $r.stateVerified=$value
        Assert-True (-not (Get-LauncherResultAssessment $r 0 'Inspect').Success) 'Unverified state accepted'
    }
    $r=New-Result;$r.PSObject.Properties.Remove('stateVerified')
    Assert-True (-not (Get-LauncherResultAssessment $r 0 'Inspect').Success) 'Missing verification flag accepted'
}
Run-Test 'Missing state and wrong action cannot produce a TV success' {
    $r=New-Result;$r.state=$null
    Assert-True (-not (Get-LauncherResultAssessment $r 0 'Inspect').Success) 'Missing state accepted'
    Assert-True (-not (Get-LauncherResultAssessment (New-Result 'Singapore') 0 'Inspect').Success) 'Wrong action accepted'
    Assert-True (-not (Get-LauncherResultAssessment $null 0 'Inspect').Success) 'Null result accepted'
}
Run-Test 'Capabilities are not inferred from raw state or category' {
    $r=New-Result;$r.PSObject.Properties.Remove('canSingapore');$r.canChina='true'
    $a=Get-LauncherResultAssessment $r 0 'Inspect'
    Assert-True ($a.Success -and -not $a.CanSingapore -and -not $a.CanChina) 'Capability inference was unsafe'
}
Run-Test 'Failed partial result never enables action buttons' {
    $r=New-Result 'Singapore' 'SG0';$r.success=$false;$r.partialSuccess=$true
    $a=Get-LauncherResultAssessment $r 0 'Singapore'
    Assert-True ($a.PartialSuccess -and -not $a.Success -and -not $a.VerifiedTv -and -not $a.CanSingapore -and -not $a.CanChina) 'Partial failure counted as success'
}
Run-Test 'Setup and Diagnostics success cannot become verified TV state' {
    foreach($action in @('Setup','Diagnostics')) {
        $r=New-Result $action $action;$r.stateVerified=$false;$r.state=$null
        $a=Get-LauncherResultAssessment $r 0 $action
        Assert-True ($a.Success -and -not $a.VerifiedTv -and -not $a.TvAction -and -not $a.CanSingapore -and -not $a.CanChina) 'Local operation changed TV eligibility'
    }
}
Run-Test 'Categories are exact and no raw-state fallback is used' {
    foreach($category in @('Unknown','sg0','', 'Setup')) {
        Assert-True (-not (Get-LauncherResultAssessment (New-Result 'Inspect' $category) 0 'Inspect').Success) 'Invalid category accepted'
    }
}
Run-Test 'Backup text distinguishes valid and unavailable baselines' {
    $backups=[pscustomobject]@{stage1=[pscustomobject]@{available=$true};stage2=[pscustomobject]@{available=$false}}
    Assert-Equal '原始国行备份：已核对     换区前备份：缺失或不匹配' (Get-LauncherBackupText $backups) 'Backup status text'
}
Run-Test 'Settings can be saved repeatedly in a Unicode path with spaces' {
    $directory=Join-Path $fixtureRoot '测试 用户设置'
    [void][IO.Directory]::CreateDirectory($directory)
    $script:SettingsPath=Join-Path $directory 'settings.json'
    Assert-Equal '192.168.1.100' (Save-LauncherSettings ' 192.168.1.100 ') 'First settings save'
    Assert-Equal '192.168.50.222' (Save-LauncherSettings '192.168.50.222') 'Second settings save'
    Assert-Equal '192.168.1.100' (Save-LauncherSettings '192.168.001.100') 'Third normalized settings save'
    $saved=[IO.File]::ReadAllText($script:SettingsPath)|ConvertFrom-Json
    Assert-Equal '192.168.1.100' $saved.tvIp 'Saved IP'
}
Run-Test 'Worker argument vector survives Unicode and spaced paths' {
    $worker='C:\电视 工具\app\Worker.ps1'
    $job='C:\Users\测试 用户\AppData\Local\QN90B-RegionAssistant\jobs\任务 1'
    $kit='C:\电视 工具'
    $expected=New-LauncherWorkerArguments $worker 'Singapore' '192.168.1.100' $job $kit
    $code='import json,sys;print(json.dumps(sys.argv[1:],ensure_ascii=False))'
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$PythonPath
    $start.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
    $start.StandardErrorEncoding=New-Object Text.UTF8Encoding($false)
    $start.EnvironmentVariables['PYTHONUTF8']='1'
    $start.EnvironmentVariables['PYTHONIOENCODING']='utf-8'
    $vector=@('-c',$code)+$expected
    $start.Arguments=(($vector|ForEach-Object{Quote-LauncherArgument $_}) -join ' ')
    $start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $p=New-Object Diagnostics.Process;$p.StartInfo=$start
    try {
        [void]$p.Start();$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();$p.WaitForExit()
        $actual=@($out.GetAwaiter().GetResult()|ConvertFrom-Json)
        Assert-Equal 0 $p.ExitCode 'Local echo process'
        Assert-Equal $expected.Count $actual.Count 'Argument count'
        for($i=0;$i -lt $expected.Count;$i++){Assert-Equal $expected[$i] $actual[$i] ('Argument '+$i)}
    } finally {$p.Dispose()}
}
Run-Test 'Busy UI disables parallel worker actions and IP editing' {
    $script:Ui=@{};$script:Colors=@{Blue='blue';Disabled='disabled';Muted='muted'}
    foreach($name in @('Setup','Inspect','Diagnostics','SaveIp','Ip','Singapore','China')) {
        $script:Ui[$name]=[pscustomobject]@{Enabled=$true;BackColor=$null;ForeColor=$null}
    }
    $script:Ui.Form=[pscustomobject]@{UseWaitCursor=$false}
    $script:CanSingapore=$true;$script:CanChina=$false;$script:Busy=$true
    Update-LauncherControls
    foreach($name in @('Setup','Inspect','Diagnostics','SaveIp','Ip','Singapore','China')) {Assert-True (-not $script:Ui[$name].Enabled) ('Still enabled '+$name)}
    $script:Busy=$false;Update-LauncherControls
    Assert-True ($script:Ui.Inspect.Enabled -and $script:Ui.Singapore.Enabled -and -not $script:Ui.China.Enabled) 'Idle capability gates changed'
}
Run-Test 'Timer poller drains concurrent stdout and stderr before completion' {
    $script:fixtureCompleted=$false;$script:fixtureLengths=@()
    function Complete-LauncherWorker {
        param([object]$Job)
        Assert-True ($Job.Process.HasExited -and $Job.StdoutTask.IsCompleted -and $Job.StderrTask.IsCompleted) 'Premature completion'
        $script:fixtureLengths=@($Job.StdoutTask.GetAwaiter().GetResult().Length,$Job.StderrTask.GetAwaiter().GetResult().Length)
        $script:fixtureCompleted=$true
    }
    $directory=Join-Path $fixtureRoot 'async';[void][IO.Directory]::CreateDirectory($directory)
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$PythonPath
    $start.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
    $start.StandardErrorEncoding=New-Object Text.UTF8Encoding($false)
    $start.EnvironmentVariables['PYTHONUTF8']='1'
    $start.EnvironmentVariables['PYTHONIOENCODING']='utf-8'
    $code='import sys,time;sys.stdout.write("O"*1048576);sys.stdout.flush();sys.stderr.write("E"*1048576);sys.stderr.flush();time.sleep(0.1)'
    $start.Arguments=(Quote-LauncherArgument '-c')+' '+(Quote-LauncherArgument $code)
    $start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $p=New-Object Diagnostics.Process;$p.StartInfo=$start
    try {
        [void]$p.Start()
        $script:ActiveJob=[pscustomobject]@{Directory=$directory;Process=$p;StdoutTask=$p.StandardOutput.ReadToEndAsync();StderrTask=$p.StandardError.ReadToEndAsync();ExitObservedUtc=$null;LastProgress=''}
        $deadline=[DateTime]::UtcNow.AddSeconds(10)
        while(-not $script:fixtureCompleted -and [DateTime]::UtcNow -lt $deadline) {Update-LauncherWorker;[Threading.Thread]::Sleep(10)}
        Assert-True $script:fixtureCompleted 'Pipe draining/poller did not finish'
        Assert-Equal 1048576 $script:fixtureLengths[0] 'stdout bytes'
        Assert-Equal 1048576 $script:fixtureLengths[1] 'stderr bytes'
    } finally {$p.Dispose();$script:ActiveJob=$null}
}

'LAUNCHER_TESTS_PASSED='+$script:passed
'LAUNCHER_TESTS_FAILED='+$script:failed
if($script:failed -ne 0){throw 'One or more launcher offline checks failed.'}
