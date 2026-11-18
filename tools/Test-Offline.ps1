#Requires -Version 5.1
<#
Runs only the two explicit offline fixture scripts in isolated Windows
PowerShell processes. It never invokes the app or a TV host entry point.
#>
[CmdletBinding()]
param(
    [string]$RepositoryRoot=(Split-Path -Parent $PSScriptRoot),
    [string]$OutputDirectory='',
    [string]$PythonPath=''
)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -cne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -lt 1) {
    throw 'Run this CI entry point with Windows PowerShell 5.1 (powershell.exe), not pwsh.'
}
$repository=[IO.Path]::GetFullPath($RepositoryRoot)
if(-not $OutputDirectory) { $OutputDirectory=Join-Path $repository '.build/test-results' }
$output=[IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($output)
if(-not $PythonPath) { $PythonPath=(Get-Command python -CommandType Application -ErrorAction Stop).Source }
$python=(Get-Command $PythonPath -CommandType Application -ErrorAction Stop).Source
$engine=Join-Path $PSHOME 'powershell.exe'
function Quote-OfflineArgument {
    param([AllowEmptyString()][string]$Value)
    $result=New-Object Text.StringBuilder
    [void]$result.Append('"'); $slashes=0
    foreach($character in $Value.ToCharArray()) {
        if($character -eq '\') { $slashes++; continue }
        if($character -eq '"') { [void]$result.Append(('\' * (2*$slashes+1))); [void]$result.Append('"') }
        else { [void]$result.Append(('\' * $slashes)); [void]$result.Append($character) }
        $slashes=0
    }
    [void]$result.Append(('\' * (2*$slashes))); [void]$result.Append('"')
    return $result.ToString()
}
# Parse application files as text. Do not dot-source or invoke their entry points.
$parseCount=0
foreach($relative in @('app','engines','tools','tests')) {
    foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $repository $relative) -Filter '*.ps1' -File -Recurse)) {
        $tokens=$null; $parseErrors=$null
        $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$parseErrors)
        if($parseErrors.Count -ne 0) { throw ('PowerShell parser errors in '+$file.FullName+': '+($parseErrors.Message -join '; ')) }
        $parseCount++
    }
}
$summaries=New-Object 'System.Collections.Generic.List[object]'
foreach($fixture in @(
    [pscustomobject]@{Name='Worker.Tests.ps1';Passed=25;Summary='(?m)^TOTAL passed=25 failed=0\s*$'},
    [pscustomobject]@{Name='Launcher.Tests.ps1';Passed=15;Summary='(?m)^LAUNCHER_TESTS_PASSED=15\s*$'}
)) {
    $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $repository ('tests/'+$fixture.Name)),'-KitRoot',$repository)
    if($fixture.Name -ceq 'Launcher.Tests.ps1') { $arguments+=@('-PythonPath',$python) }
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$engine
    $start.Arguments=(($arguments | ForEach-Object { Quote-OfflineArgument $_ }) -join ' ')
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $start.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
    $start.StandardErrorEncoding=New-Object Text.UTF8Encoding($false)
    $start.EnvironmentVariables['QN90B_OFFLINE_TESTS_ONLY']='1'
    $start.EnvironmentVariables['PYTHONUTF8']='1'
    $start.EnvironmentVariables['PYTHONIOENCODING']='utf-8'
    $fixtureTemp=Join-Path $output ($fixture.Name+'.temporary')
    [void][IO.Directory]::CreateDirectory($fixtureTemp)
    $start.EnvironmentVariables['TEMP']=$fixtureTemp; $start.EnvironmentVariables['TMP']=$fixtureTemp
    $process=New-Object Diagnostics.Process; $process.StartInfo=$start
    try {
        if(-not $process.Start()) { throw ('Could not start '+$fixture.Name) }
        $stdoutTask=$process.StandardOutput.ReadToEndAsync(); $stderrTask=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(180000)) {
            try { $process.Kill() } catch { }
            throw ('Offline fixture timed out: '+$fixture.Name)
        }
        $stdout=$stdoutTask.GetAwaiter().GetResult(); $stderr=$stderrTask.GetAwaiter().GetResult(); $code=$process.ExitCode
    } finally { $process.Dispose() }
    [IO.File]::WriteAllText((Join-Path $output ($fixture.Name+'.stdout.txt')),$stdout,(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $output ($fixture.Name+'.stderr.txt')),$stderr,(New-Object Text.UTF8Encoding($false)))
    Write-Host $stdout.TrimEnd()
    if($stderr.Trim()) { Write-Host $stderr.TrimEnd() }
    if($code -ne 0 -or $stdout -match '(?m)^FAIL\s' -or $stdout -notmatch $fixture.Summary) {
        throw ('Offline fixture failed or returned an incomplete test count: '+$fixture.Name+' (exit '+$code+'). Logs: '+$output)
    }
    if($fixture.Name -ceq 'Launcher.Tests.ps1' -and $stdout -notmatch '(?m)^LAUNCHER_TESTS_FAILED=0\s*$') { throw 'Launcher failure summary is missing or nonzero.' }
    $summaries.Add([pscustomobject]@{fixture=$fixture.Name;passed=$fixture.Passed;failed=0;exitCode=$code})
}
$summary=[pscustomobject]@{schema='qn90b-offline-tests-v1';powerShell=$PSVersionTable.PSVersion.ToString();parsedFiles=$parseCount;passed=40;failed=0;tvCommandsExecuted=$false;fixtures=$summaries.ToArray()}
[IO.File]::WriteAllText((Join-Path $output 'summary.json'),($summary | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
Write-Host 'PASS: 40 offline PowerShell fixtures; no TV operation was requested.'
