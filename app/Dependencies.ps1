# Portable dependency management. Windows PowerShell 5.1; no TV commands.
Set-StrictMode -Version 2.0

function Get-Qn90bDependencyManifest {
    param([string]$KitRoot)
    $path=Join-Path $KitRoot 'app\Dependency-Manifest.json'
    $manifest=[IO.File]::ReadAllText($path) | ConvertFrom-Json
    if($manifest.schema -cne 'qn90b-dependencies-v1') { throw '运行环境清单格式不正确，请重新解压完整工具包。' }
    foreach($package in $manifest.packages) {
        if($package.id -cnotmatch '^(root|sdb|openssl)$' -or $package.directory -cnotmatch '^[A-Za-z0-9._-]+$' -or
           $package.archive -cnotmatch '^[A-Za-z0-9._-]+[.]zip$' -or $package.sha256 -cnotmatch '^[a-f0-9]{64}$') {
            throw '运行环境清单包含无效项目。'
        }
        foreach($file in $package.files) {
            if($file.path -match '(^[/\\]|(^|[/\\])[.][.]([/\\]|$)|:)' -or $file.sha256 -cnotmatch '^[a-f0-9]{64}$') {
                throw '运行环境清单包含无效文件路径。'
            }
        }
        if(@($package.files | Where-Object { $_.path -ceq $package.executable }).Count -ne 1) { throw '运行环境清单缺少程序校验值。' }
    }
    if(@($manifest.packages).Count -ne 3 -or @($manifest.packages | Select-Object -ExpandProperty id -Unique).Count -ne 3) {
        throw '运行环境清单必须包含三个不同组件。'
    }
    return $manifest
}

function Test-Qn90bInstalledPackage {
    param([object]$Package,[string]$Directory)
    if(-not [IO.Directory]::Exists($Directory)) { return $false }
    foreach($file in $Package.files) {
        $path=Join-Path $Directory $file.path
        if(-not [IO.File]::Exists($path)) { return $false }
        $item=Get-Item -LiteralPath $path
        if($item.Length -ne $file.bytes) { return $false }
        if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $file.sha256) { return $false }
    }
    return $true
}

function Invoke-Qn90bDependencyProgress {
    param([scriptblock]$Callback,[int]$Percent,[string]$Message)
    if($null -ne $Callback) { try { $null=& $Callback $Percent $Message } catch {} }
}

function ConvertTo-Qn90bProcessArgument {
    param([AllowEmptyString()][string]$Value)
    $builder=New-Object Text.StringBuilder
    [void]$builder.Append('"'); $slashes=0
    foreach($c in $Value.ToCharArray()) {
        if($c -eq '\') { $slashes++; continue }
        if($c -eq '"') { [void]$builder.Append(('\' * (2*$slashes+1))); [void]$builder.Append('"') }
        else { [void]$builder.Append(('\' * $slashes)); [void]$builder.Append($c) }
        $slashes=0
    }
    [void]$builder.Append(('\' * (2*$slashes))); [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-Qn90bLocalDependencyCheck {
    param([string]$Executable,[string[]]$Arguments,[int]$TimeoutMilliseconds=30000)
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$Executable
    $info.Arguments=(($Arguments | ForEach-Object {ConvertTo-Qn90bProcessArgument $_}) -join ' ')
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process; $process.StartInfo=$info
    try {
        if(-not $process.Start()) { throw '无法启动本机运行组件。' }
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit($TimeoutMilliseconds)) {
            try { $process.Kill() } catch {}
            throw '本机运行组件检查超时。'
        }
        $out=$stdout.GetAwaiter().GetResult(); $err=$stderr.GetAwaiter().GetResult()
        if($process.ExitCode -ne 0) { throw ('本机组件检查未通过：'+$err.Trim()) }
        return $out.Trim()
    } finally { $process.Dispose() }
}

function Resolve-Qn90bOpenSsl {
    param([object]$Package,[string]$ToolsDirectory)
    $managed=Join-Path $ToolsDirectory $Package.directory
    $candidates=New-Object 'System.Collections.Generic.List[string]'
    foreach($command in @(Get-Command openssl.exe -CommandType Application -ErrorAction SilentlyContinue)) {
        if($command.Source) { $candidates.Add($command.Source) }
    }
    foreach($programRoot in @($env:ProgramW6432,$env:ProgramFiles,${env:ProgramFiles(x86)},(Join-Path $env:LOCALAPPDATA 'Programs'))) {
        if($programRoot) {
            foreach($relative in @('Git\ucrt64\bin\openssl.exe','Git\mingw64\bin\openssl.exe','Git\usr\bin\openssl.exe','OpenSSL-Win64\bin\openssl.exe')) {
                $candidates.Add((Join-Path $programRoot $relative))
            }
        }
    }
    foreach($candidate in $candidates.ToArray()) {
        if(-not [IO.File]::Exists($candidate)) { continue }
        $full=[IO.Path]::GetFullPath($candidate)
        if($full.StartsWith([IO.Path]::GetFullPath($managed)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { continue }
        try {
            $version=Invoke-Qn90bLocalDependencyCheck $full @('version')
            if($version -notmatch '^OpenSSL\s+[1-9][0-9]*[.]') { continue }
            $env:PATH=(Split-Path -Parent $full)+';'+$env:PATH
            return [pscustomobject]@{Path=$full;Source='existing';Version=$version}
        } catch { continue }
    }
    if(Test-Qn90bInstalledPackage $Package $managed) {
        $full=Join-Path $managed $Package.executable
        $previousConf=$env:OPENSSL_CONF; $previousModules=$env:OPENSSL_MODULES
        try {
            $env:OPENSSL_CONF=Join-Path $managed 'openssl.cnf'
            $env:OPENSSL_MODULES=Join-Path $managed 'ossl-modules'
            $version=Invoke-Qn90bLocalDependencyCheck $full @('version')
            if($version -notmatch '^OpenSSL\s+[1-9][0-9]*[.]') { throw '便携 OpenSSL 版本检查未通过。' }
            $env:PATH=(Split-Path -Parent $full)+';'+$env:PATH
            return [pscustomobject]@{Path=$full;Source='bundled';Version=$version}
        } catch {
            $env:OPENSSL_CONF=$previousConf; $env:OPENSSL_MODULES=$previousModules
            throw
        }
    }
    return $null
}

function Get-Qn90bOpenSslBootstrapSpec {
    param([object]$Package)
    if($Package.id -cne 'openssl' -or $null -eq $Package.PSObject.Properties['bootstrap']) {
        throw 'OpenSSL 官方来源清单缺失，请重新下载完整源码包。'
    }
    $spec=$Package.bootstrap
    if($spec.archive -cne 'Git-2.56.1-64-bit.tar.bz2' -or
       $spec.url -cne 'https://github.com/git-for-windows/git/releases/download/v2.56.1.windows.1/Git-2.56.1-64-bit.tar.bz2' -or
       $spec.sha256 -cne 'd7d89e69855f00e73d957b513c49538a420c465c84b9d212cf1add400eecdf54' -or
       $spec.bytes -ne 124091126) {
        throw 'OpenSSL 官方来源清单与固定版本不匹配。'
    }
    return $spec
}

function Test-Qn90bPinnedFile {
    param([string]$Path,[long]$Bytes,[string]$Sha256)
    if(-not [IO.File]::Exists($Path)) { return $false }
    if((Get-Item -LiteralPath $Path).Length -ne $Bytes) { return $false }
    return ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $Sha256)
}

function Resolve-Qn90bSystemTar {
    if(-not $env:SystemRoot -or -not [IO.Path]::IsPathRooted($env:SystemRoot)) {
        throw '无法确定 Windows 系统目录。请使用 Windows 10/11 自带 PowerShell 启动工具。'
    }
    $systemDirectory='System32'
    if([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $systemDirectory='Sysnative' }
    $path=Join-Path (Join-Path $env:SystemRoot $systemDirectory) 'tar.exe'
    if(-not [IO.File]::Exists($path)) {
        throw '缺少 Windows 自带 tar.exe。首次下载 OpenSSL 需要带有 tar 的较新 Windows 10/11；也可使用已安装的 OpenSSL 或原版离线缓存。'
    }
    return $path
}

function Install-Qn90bOpenSslBootstrap {
    param([object]$Package,[string]$KitRoot,[string]$ToolsDirectory)
    $destination=Join-Path $ToolsDirectory $Package.directory
    if(Test-Qn90bInstalledPackage $Package $destination) { return }
    $spec=Get-Qn90bOpenSslBootstrapSpec $Package
    $tar=Resolve-Qn90bSystemTar
    $provenance=Join-Path (Join-Path $KitRoot 'app') 'OpenSSL-Provenance.json'
    $provenanceSpecs=@($Package.files | Where-Object { $_.path -ceq 'SOURCE.json' })
    if($provenanceSpecs.Count -ne 1 -or
       -not (Test-Qn90bPinnedFile $provenance $provenanceSpecs[0].bytes $provenanceSpecs[0].sha256)) {
        throw 'OpenSSL 来源记录校验失败，请重新下载完整源码包。'
    }
    $cache=Join-Path (Join-Path $env:LOCALAPPDATA 'QN90B-root') 'cache'
    [void][IO.Directory]::CreateDirectory($cache)
    [void][IO.Directory]::CreateDirectory($ToolsDirectory)
    $archive=Join-Path $cache $spec.archive
    if(-not (Test-Qn90bPinnedFile $archive $spec.bytes $spec.sha256)) {
        [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $temporary=$archive+'.download-'+[Guid]::NewGuid().ToString('N')
        $client=New-Object Net.WebClient
        $client.Headers['User-Agent']='QN90B-Region-Assistant/1.0'
        try {
            $client.DownloadFile($spec.url,$temporary)
            if(-not (Test-Qn90bPinnedFile $temporary $spec.bytes $spec.sha256)) { throw '官方 Git 压缩包的大小或 SHA256 校验失败。' }
            [IO.File]::Copy($temporary,$archive,$true)
        } catch { throw ('OpenSSL 官方来源下载失败（约 124 MB）。详情：'+$_.Exception.Message) }
        finally { $client.Dispose(); if([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    }
    # Verify immediately before invoking tar, including an already cached archive.
    if(-not (Test-Qn90bPinnedFile $archive $spec.bytes $spec.sha256)) { throw 'OpenSSL 官方压缩包校验失败，已停止解包。' }
    $members=[ordered]@{
        'ucrt64/bin/openssl.exe'='bin/openssl.exe'
        'ucrt64/bin/libcrypto-3-x64.dll'='bin/libcrypto-3-x64.dll'
        'ucrt64/bin/libssl-3-x64.dll'='bin/libssl-3-x64.dll'
        'ucrt64/etc/ssl/openssl.cnf'='openssl.cnf'
        'ucrt64/lib/ossl-modules/legacy.dll'='ossl-modules/legacy.dll'
        'ucrt64/share/licenses/openssl/LICENSE'='licenses/OpenSSL-LICENSE.txt'
    }
    $nonce=[Guid]::NewGuid().ToString('N')
    $raw=Join-Path $ToolsDirectory ('.extract-openssl-'+$nonce)
    $stage=Join-Path $ToolsDirectory ('.install-openssl-'+$nonce)
    $saved=$null; $moved=$false
    try {
        [void][IO.Directory]::CreateDirectory($raw)
        [void][IO.Directory]::CreateDirectory($stage)
        # Exactly six regular members. Do not run an installer or post-install script.
        $tarArguments=@('-xf',$archive,'-C',$raw,'--')+@($members.Keys)
        try { $null=Invoke-Qn90bLocalDependencyCheck -Executable $tar -Arguments $tarArguments -TimeoutMilliseconds 180000 }
        catch { throw ('Windows tar 解包失败，需要支持 bzip2 的系统 tar；现有安装未更改。详情：'+$_.Exception.Message) }
        foreach($member in $members.Keys) {
            $source=Join-Path $raw $member
            if(-not [IO.File]::Exists($source) -or ([IO.File]::GetAttributes($source) -band [IO.FileAttributes]::ReparsePoint)) {
                throw ('OpenSSL 解包结果缺少普通文件：'+$member)
            }
            $target=Join-Path $stage $members[$member]
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            [IO.File]::Copy($source,$target,$false)
        }
        [IO.File]::Copy($provenance,(Join-Path $stage 'SOURCE.json'),$false)
        if(-not (Test-Qn90bInstalledPackage $Package $stage)) { throw 'OpenSSL 解包后的文件校验未通过，现有安装未更改。' }
        if([IO.Directory]::Exists($destination)) {
            $saved=$destination+'.previous-'+[Guid]::NewGuid().ToString('N')
            [IO.Directory]::Move($destination,$saved)
        }
        try {
            [IO.Directory]::Move($stage,$destination); $moved=$true
            if(-not (Test-Qn90bInstalledPackage $Package $destination)) { throw 'OpenSSL 安装后的文件校验未通过。' }
        } catch {
            $failure=$_
            if($moved -and [IO.Directory]::Exists($destination)) { [IO.Directory]::Move($destination,$stage) }
            if($saved -and -not [IO.Directory]::Exists($destination)) { [IO.Directory]::Move($saved,$destination) }
            throw $failure
        }
    } finally {
        if([IO.Directory]::Exists($raw)) { [IO.Directory]::Delete($raw,$true) }
        if([IO.Directory]::Exists($stage)) { [IO.Directory]::Delete($stage,$true) }
    }
}

function Install-Qn90bPackage {
    param([object]$Package,[string]$KitRoot,[string]$ToolsDirectory)
    $destination=Join-Path $ToolsDirectory $Package.directory
    if(Test-Qn90bInstalledPackage $Package $destination) { return }
    $cache=Join-Path (Join-Path $env:LOCALAPPDATA 'QN90B-root') 'cache'
    [void][IO.Directory]::CreateDirectory($cache)
    [void][IO.Directory]::CreateDirectory($ToolsDirectory)
    $archive=Join-Path $cache $Package.archive
    $bundled=Join-Path (Join-Path $KitRoot 'cache') $Package.archive
    if([IO.File]::Exists($bundled)) {
        if((Get-FileHash -LiteralPath $bundled -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Package.sha256) {
            throw ('工具包中的 '+$Package.archive+' 校验失败，请重新解压完整工具包。')
        }
        [IO.File]::Copy($bundled,$archive,$true)
    } elseif(-not [IO.File]::Exists($archive) -or (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Package.sha256) {
        if($Package.id -ceq 'openssl') {
            Install-Qn90bOpenSslBootstrap $Package $KitRoot $ToolsDirectory
            return
        }
        if(-not $Package.url) { throw '官方组件来源缺失，请重新下载完整源码包。' }
        if($Package.url -cnotmatch '^https://(github[.]com/chris-ritsen/samsung-tv-root/releases/download/v0[.]0[.]13/|download[.]tizen[.]org/sdk/tizenstudio/official/binary/)') { throw '组件下载来源不符合清单。' }
        [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $temporary=$archive+'.download-'+[Guid]::NewGuid().ToString('N')
        $client=New-Object Net.WebClient
        $client.Headers['User-Agent']='QN90B-Region-Assistant/1.0'
        try {
            $client.DownloadFile($Package.url,$temporary)
            if((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Package.sha256) { throw '官方组件下载后的 SHA256 校验失败。' }
            [IO.File]::Copy($temporary,$archive,$true)
        } catch { throw ('运行组件下载失败。请确认能访问官方上游站点后，重试检查/安装运行环境。详情：'+$_.Exception.Message) }
        finally { $client.Dispose(); if([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    }
    if((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Package.sha256) { throw '运行组件压缩包校验失败。' }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $stage=Join-Path $ToolsDirectory ('.install-'+$Package.id+'-'+[Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($stage)
    $saved=$null
    try {
        $zip=[IO.Compression.ZipFile]::OpenRead($archive)
        try {
            $prefix=[IO.Path]::GetFullPath($stage)+[IO.Path]::DirectorySeparatorChar
            foreach($entry in $zip.Entries) {
                $entryPath=[IO.Path]::GetFullPath((Join-Path $stage $entry.FullName))
                if(-not $entryPath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw '压缩包包含越界路径。' }
            }
        } finally { $zip.Dispose() }
        [IO.Compression.ZipFile]::ExtractToDirectory($archive,$stage)
        if(-not (Test-Qn90bInstalledPackage $Package $stage)) { throw '组件解压后的文件校验未通过。' }
        if([IO.Directory]::Exists($destination)) {
            $saved=$destination+'.previous-'+[Guid]::NewGuid().ToString('N')
            [IO.Directory]::Move($destination,$saved)
        }
        try { [IO.Directory]::Move($stage,$destination) }
        catch {
            if($saved -and -not [IO.Directory]::Exists($destination)) { [IO.Directory]::Move($saved,$destination) }
            throw
        }
    } finally {
        if([IO.Directory]::Exists($stage)) { [IO.Directory]::Delete($stage,$true) }
    }
}

function Get-Qn90bTools {
    param([string]$KitRoot)
    $manifest=Get-Qn90bDependencyManifest $KitRoot
    $directory=Join-Path (Join-Path $env:LOCALAPPDATA 'QN90B-root') 'tools'
    $paths=@{}
    foreach($id in @('root','sdb')) {
        $package=@($manifest.packages | Where-Object { $_.id -ceq $id })[0]
        $installed=Join-Path $directory $package.directory
        if(-not (Test-Qn90bInstalledPackage $package $installed)) { throw '运行环境尚未就绪，请先点击“检查/安装运行环境”。' }
        $paths[$id]=Join-Path $installed $package.executable
    }
    $sslSpec=@($manifest.packages | Where-Object { $_.id -ceq 'openssl' })[0]
    $ssl=Resolve-Qn90bOpenSsl $sslSpec $directory
    if($null -eq $ssl) { throw '缺少可用的 OpenSSL，请先点击“检查/安装运行环境”。' }
    return [pscustomobject]@{Sdb=$paths.sdb;Root=$paths.root;OpenSsl=$ssl.Path;OpenSslSource=$ssl.Source;OpenSslVersion=$ssl.Version;ToolsDirectory=$directory}
}

function Install-Qn90bDependencies {
    param([string]$KitRoot,[scriptblock]$ProgressCallback)
    if($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem -or
       $env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') {
        throw '请在 Windows 10/11 x64 电脑运行此工具。'
    }
    $manifest=Get-Qn90bDependencyManifest $KitRoot
    $directory=Join-Path (Join-Path $env:LOCALAPPDATA 'QN90B-root') 'tools'
    $index=0
    foreach($id in @('root','sdb','openssl')) {
        $package=@($manifest.packages | Where-Object { $_.id -ceq $id })[0]
        $index++
        Invoke-Qn90bDependencyProgress $ProgressCallback ($index*20) ('正在校验并准备运行组件 '+$index+'/3')
        if($id -eq 'openssl') {
            $existing=Resolve-Qn90bOpenSsl $package $directory
            if($null -ne $existing) { continue }
            Invoke-Qn90bDependencyProgress $ProgressCallback 60 '正在准备 OpenSSL（首次可能下载约 124 MB）'
        }
        Install-Qn90bPackage $package $KitRoot $directory
    }
    Invoke-Qn90bDependencyProgress $ProgressCallback 85 '正在检查本机运行环境'
    $ready=Get-Qn90bTools $KitRoot
    $doctor=Invoke-Qn90bLocalDependencyCheck $ready.Root @('--sdb',$ready.Sdb,'doctor')
    if($doctor -notmatch '(?im)^Ready:\s*yes\s*$') { throw ('运行组件自检没有报告 Ready: yes。'+[Environment]::NewLine+$doctor) }
    Invoke-Qn90bDependencyProgress $ProgressCallback 100 '运行环境已就绪，可以检测电视'
    return $ready
}
