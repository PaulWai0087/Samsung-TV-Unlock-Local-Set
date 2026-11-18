param(
    [string]$KitRoot=$env:QN90B_TEST_KIT,
    [string]$SourceArchive=$env:QN90B_TEST_GIT_ARCHIVE,
    [string]$LegacyArchive=$env:QN90B_TEST_LEGACY_OPENSSL,
    [string]$TarExecutable=$env:QN90B_TEST_TAR
)
# Offline only: never download, run OpenSSL/root/SDB, or contact a TV.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
if(-not $KitRoot -or -not $SourceArchive -or -not $LegacyArchive -or -not $TarExecutable) {
    throw 'Set QN90B_TEST_KIT, QN90B_TEST_GIT_ARCHIVE, QN90B_TEST_LEGACY_OPENSSL and QN90B_TEST_TAR to existing local files.'
}
function Join-Path {
    param([string]$Path,[string]$ChildPath)
    return [IO.Path]::Combine($Path,$ChildPath.Replace('\',[IO.Path]::DirectorySeparatorChar))
}
function Get-Item {param([string]$LiteralPath) return (New-Object IO.FileInfo($LiteralPath))}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $KitRoot 'app/Dependencies.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Dependencies.ps1 has parser errors.'}
foreach($function in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    . ([scriptblock]::Create($function.Extent.Text))
}
# Keep production function bodies for fixture overrides, without executing Setup.
$script:realLocalCheck=${function:Invoke-Qn90bLocalDependencyCheck}
$script:realPackageCheck=${function:Test-Qn90bInstalledPackage}
$script:realBootstrap=${function:Install-Qn90bOpenSslBootstrap}
$script:realTarResolver=${function:Resolve-Qn90bSystemTar}
$script:tarPath=$TarExecutable
function Resolve-Qn90bSystemTar {return $script:tarPath}
$manifest=Get-Qn90bDependencyManifest $KitRoot
$package=@($manifest.packages | Where-Object {$_.id -ceq 'openssl'})[0]
$oldLocal=$env:LOCALAPPDATA
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('qn90b-bootstrap-'+[Guid]::NewGuid().ToString('N'))
$env:LOCALAPPDATA=Join-Path $fixtureRoot '用户 cache'
$cache=Join-Path $env:LOCALAPPDATA 'QN90B-root/cache'
[void][IO.Directory]::CreateDirectory($cache)
$sourceCache=Join-Path $cache $package.bootstrap.archive
if(-not (Test-Qn90bPinnedFile $SourceArchive $package.bootstrap.bytes $package.bootstrap.sha256)) {throw 'Local official archive is not the pinned fixture.'}
[IO.File]::Copy($SourceArchive,$sourceCache,$false)
$script:passed=0;$script:failed=0;$script:fixtureIndex=0
function Assert-True {param([bool]$Value,[string]$Message) if(-not $Value){throw $Message}}
function Assert-Equal {param($Expected,$Actual,[string]$Message) if($Expected -cne $Actual){throw ($Message+' expected='+$Expected+' actual='+$Actual)}}
function Assert-Throws {
    param([scriptblock]$Work,[string]$Message)
    $threw=$false
    try {& $Work} catch {$threw=$true}
    Assert-True $threw $Message
}
function New-Fixture {
    $script:fixtureIndex++
    $root=Join-Path $fixtureRoot ('场景 '+$script:fixtureIndex)
    $tools=Join-Path $root 'tools with spaces'
    $destination=Join-Path $tools $package.directory
    [void][IO.Directory]::CreateDirectory($destination)
    [IO.File]::WriteAllText((Join-Path $destination 'old-install.txt'),'KEEP-OLD-INSTALL')
    return [pscustomobject]@{root=$root;tools=$tools;destination=$destination}
}
function Assert-OldUntouched {
    param($Fixture)
    Assert-Equal 'KEEP-OLD-INSTALL' ([IO.File]::ReadAllText((Join-Path $Fixture.destination 'old-install.txt'))) 'Old install changed'
    Assert-Equal 0 ([IO.Directory]::GetDirectories($Fixture.tools,'*.previous-*').Length) 'Old install was renamed on failure'
    Assert-Equal 0 ([IO.Directory]::GetDirectories($Fixture.tools,'.extract-*').Length) 'Extraction stage left behind'
    Assert-Equal 0 ([IO.Directory]::GetDirectories($Fixture.tools,'.install-*').Length) 'Install stage left behind'
}
function Run-Test {
    param([string]$Name,[scriptblock]$Work)
    try {& $Work;$script:passed++;'PASS '+$Name}
    catch {$script:failed++;'FAIL '+$Name+': '+$_.Exception.Message;$_.ScriptStackTrace}
}
function Copy-SixMembers {
    param([string]$Raw)
    $provenance=[IO.File]::ReadAllText((Join-Path $KitRoot 'app/OpenSSL-Provenance.json'))|ConvertFrom-Json
    foreach($entry in $provenance.files.PSObject.Properties) {
        $target=Join-Path $Raw $entry.Name
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        [IO.File]::Copy((Join-Path $script:goodInstalled $entry.Value),$target,$false)
    }
}
try {
    Run-Test 'Exact provenance bytes and pinned official source are valid' {
        $p=@($package.files|Where-Object {$_.path -ceq 'SOURCE.json'})[0]
        Assert-True (Test-Qn90bPinnedFile (Join-Path $KitRoot 'app/OpenSSL-Provenance.json') $p.bytes $p.sha256) 'Provenance changed'
        $spec=Get-Qn90bOpenSslBootstrapSpec $package
        Assert-Equal 124091126 $spec.bytes 'Source bytes'
        Assert-True (Test-Qn90bPinnedFile $sourceCache $spec.bytes $spec.sha256) 'Source fingerprint'
    }
    Run-Test 'Actual tar extracts only six members and installs seven verified files in Unicode/spaced paths' {
        $f=New-Fixture
        $script:tarCalls=0
        function Invoke-Qn90bLocalDependencyCheck {
            param([string]$Executable,[string[]]$Arguments,[int]$TimeoutMilliseconds)
            $script:tarCalls++
            Assert-Equal 11 $Arguments.Count 'Tar argument count'
            Assert-Equal '-xf' $Arguments[0] 'Tar mode'
            Assert-Equal '-C' $Arguments[2] 'Tar destination flag'
            Assert-Equal '--' $Arguments[4] 'Tar separator'
            Assert-Equal 180000 $TimeoutMilliseconds 'Tar timeout'
            $result=& $script:realLocalCheck -Executable $Executable -Arguments $Arguments -TimeoutMilliseconds $TimeoutMilliseconds
            Assert-Equal 6 ([IO.Directory]::GetFiles($Arguments[3],'*',[IO.SearchOption]::AllDirectories).Length) 'Tar extracted extra/missing files'
            return $result
        }
        Install-Qn90bOpenSslBootstrap $package $KitRoot $f.tools
        Assert-Equal 1 $script:tarCalls 'Tar call count'
        Assert-True (& $script:realPackageCheck $package $f.destination) 'Installed hashes'
        Assert-Equal 7 ([IO.Directory]::GetFiles($f.destination,'*',[IO.SearchOption]::AllDirectories).Length) 'Installed file count'
        $previous=[IO.Directory]::GetDirectories($f.tools,'*.previous-*')
        Assert-Equal 1 $previous.Length 'Previous install retained'
        Assert-Equal 'KEEP-OLD-INSTALL' ([IO.File]::ReadAllText((Join-Path $previous[0] 'old-install.txt'))) 'Previous install contents'
        $script:goodInstalled=$f.destination
    }
    Run-Test 'A valid managed install returns before tar or download' {
        function Resolve-Qn90bSystemTar {throw 'Tar must not be needed'}
        Install-Qn90bOpenSslBootstrap $package $KitRoot ([IO.Path]::GetDirectoryName($script:goodInstalled))
        Assert-True (& $script:realPackageCheck $package $script:goodInstalled) 'Existing install changed'
    }
    Run-Test 'Changed official source pin is rejected before extraction' {
        $f=New-Fixture
        $bad=ConvertTo-Json -InputObject $package -Depth 16|ConvertFrom-Json
        $bad.bootstrap.sha256='0'*64
        Assert-Throws {Install-Qn90bOpenSslBootstrap $bad $KitRoot $f.tools} 'Changed source pin accepted'
        Assert-OldUntouched $f
    }
    Run-Test 'Missing or damaged provenance leaves the previous install untouched' {
        $f=New-Fixture
        $badKit=Join-Path $f.root 'bad kit'
        [void][IO.Directory]::CreateDirectory((Join-Path $badKit 'app'))
        [IO.File]::WriteAllText((Join-Path $badKit 'app/OpenSSL-Provenance.json'),'damaged')
        Assert-Throws {Install-Qn90bOpenSslBootstrap $package $badKit $f.tools} 'Bad provenance accepted'
        Assert-OldUntouched $f
    }
    Run-Test 'Unsupported or failed tar leaves the previous install untouched' {
        $f=New-Fixture
        function Invoke-Qn90bLocalDependencyCheck {param($Executable,$Arguments,$TimeoutMilliseconds) throw 'Simulated missing bzip2 filter'}
        Assert-Throws {Install-Qn90bOpenSslBootstrap $package $KitRoot $f.tools} 'Failed extractor accepted'
        Assert-OldUntouched $f
    }
    Run-Test 'A corrupted extracted member fails all-file verification without replacing the install' {
        $f=New-Fixture
        function Invoke-Qn90bLocalDependencyCheck {
            param($Executable,$Arguments,$TimeoutMilliseconds)
            Copy-SixMembers $Arguments[3]
            $path=Join-Path $Arguments[3] 'ucrt64/bin/openssl.exe'
            $bytes=[IO.File]::ReadAllBytes($path);$bytes[100]=$bytes[100] -bxor 1;[IO.File]::WriteAllBytes($path,$bytes)
        }
        Assert-Throws {Install-Qn90bOpenSslBootstrap $package $KitRoot $f.tools} 'Corrupt extracted bytes accepted'
        Assert-OldUntouched $f
    }
    Run-Test 'Post-install verification failure restores the previous directory' {
        $f=New-Fixture
        $script:postFailurePath=$f.destination
        function Invoke-Qn90bLocalDependencyCheck {param($Executable,$Arguments,$TimeoutMilliseconds) Copy-SixMembers $Arguments[3]}
        function Test-Qn90bInstalledPackage {
            param($Package,[string]$Directory)
            if($Directory -ceq $script:postFailurePath){return $false}
            return (& $script:realPackageCheck $Package $Directory)
        }
        Assert-Throws {Install-Qn90bOpenSslBootstrap $package $KitRoot $f.tools} 'Post-install failure accepted'
        Assert-OldUntouched $f
    }
    Run-Test 'Original subset ZIP remains usable without tar or the new fallback' {
        $f=New-Fixture
        $legacyKit=Join-Path $f.root 'legacy kit'
        $legacyCache=Join-Path $legacyKit 'cache'
        [void][IO.Directory]::CreateDirectory($legacyCache)
        [IO.File]::Copy($LegacyArchive,(Join-Path $legacyCache $package.archive),$false)
        function Install-Qn90bOpenSslBootstrap {throw 'Legacy ZIP must not invoke bootstrap'}
        function Resolve-Qn90bSystemTar {throw 'Legacy ZIP must not need tar'}
        Install-Qn90bPackage $package $legacyKit $f.tools
        Assert-True (& $script:realPackageCheck $package $f.destination) 'Legacy ZIP output differs'
    }
    'OPENSSL_BOOTSTRAP_TESTS_PASSED='+$script:passed
    'OPENSSL_BOOTSTRAP_TESTS_FAILED='+$script:failed
    if($script:failed -ne 0){throw 'One or more OpenSSL bootstrap checks failed.'}
} finally {
    $env:LOCALAPPDATA=$oldLocal
    if([IO.Directory]::Exists($fixtureRoot)){[IO.Directory]::Delete($fixtureRoot,$true)}
}
