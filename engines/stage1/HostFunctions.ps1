function Write-Utf8File {
    param([string]$Path, [AllowEmptyString()][string]$Text)
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Get-ObjectProperty {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Quote-WindowsArgument {
    # Windows CommandLineToArgvW / C runtime quoting, including embedded quotes.
    # Native PowerShell 5.1 argument passing can otherwise strip shell quotes.
    param([AllowEmptyString()][string]$Argument)
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') {
            $slashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($slashes * 2) + 1)))
            [void]$builder.Append('"')
        } else {
            [void]$builder.Append(('\' * $slashes))
            [void]$builder.Append($character)
        }
        $slashes = 0
    }
    [void]$builder.Append(('\' * ($slashes * 2)))
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Assert-SdbSuccess {
    param([object]$Result, [string]$Operation)
    if ($Result.ExitCode -ne 0 -or
        ($Result.Stdout + "`n" + $Result.Stderr) -match '(?im)^\s*error:') {
        throw "$Operation failed. See the saved stdout/stderr logs."
    }
}

function Find-ExistingTool {
    param([string]$ToolsDirectory, [string]$PreferredSubdirectory, [string]$FileName)
    $preferred = Join-Path $ToolsDirectory $PreferredSubdirectory
    $candidates = @()
    if (Test-Path -LiteralPath $preferred -PathType Container) {
        $candidates = @(Get-ChildItem -LiteralPath $preferred -Recurse -File -Filter $FileName)
    }
    if ($candidates.Count -eq 0 -and (Test-Path -LiteralPath $ToolsDirectory -PathType Container)) {
        $candidates = @(Get-ChildItem -LiteralPath $ToolsDirectory -Recurse -File -Filter $FileName)
    }
    if ($candidates.Count -ne 1) {
        throw "Expected exactly one $FileName in the existing tools under $preferred. Found $($candidates.Count). No download was attempted."
    }
    return $candidates[0].FullName
}

function Find-OpenSsl {
    param([string]$ExplicitPath, [string]$ToolsDirectory)
    if ($ExplicitPath) {
        if (-not (Test-Path -LiteralPath $ExplicitPath -PathType Leaf)) {
            throw 'The supplied -OpenSslPath does not exist.'
        }
        $resolved = (Resolve-Path -LiteralPath $ExplicitPath).Path
        if ((Split-Path -Leaf $resolved) -ine 'openssl.exe') {
            throw '-OpenSslPath must point to openssl.exe.'
        }
        $env:PATH = (Split-Path -Parent $resolved) + ';' + $env:PATH
        return $resolved
    }

    $available = @(Get-Command openssl.exe -CommandType Application -ErrorAction SilentlyContinue)
    if ($available.Count -gt 0) { return $available[0].Source }

    $directories = New-Object 'System.Collections.Generic.List[string]'
    foreach ($programRoot in @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($programRoot) {
            foreach ($relative in @('Git\mingw64\bin', 'Git\usr\bin', 'OpenSSL-Win64\bin', 'OpenSSL-Win32\bin')) {
                $directories.Add((Join-Path $programRoot $relative))
            }
        }
    }
    $directories.Add((Join-Path $env:LOCALAPPDATA 'Programs\Git\mingw64\bin'))
    $directories.Add((Join-Path $env:LOCALAPPDATA 'Programs\Git\usr\bin'))
    foreach ($directory in $directories) {
        $candidate = Join-Path $directory 'openssl.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $env:PATH = $directory + ';' + $env:PATH
            return $candidate
        }
    }
    if (Test-Path -LiteralPath $ToolsDirectory -PathType Container) {
        $cached = @(Get-ChildItem -LiteralPath $ToolsDirectory -Recurse -File -Filter 'openssl.exe')
        if ($cached.Count -eq 1) {
            $env:PATH = $cached[0].DirectoryName + ';' + $env:PATH
            return $cached[0].FullName
        }
    }
    throw 'OpenSSL was not found on PATH, in common Git/OpenSSL locations, or in the existing tools. Put the directory of your previously working openssl.exe on PATH and rerun. No download was attempted.'
}

function Invoke-CapturedTool {
    param(
        [string]$Executable,
        [string[]]$ArgumentList,
        [string]$LogPrefix,
        [string]$Label,
        [bool]$ShowOutput = $true
    )
    Write-Host ''
    Write-Host ('Starting: ' + $Label)
    Write-Utf8File ($LogPrefix + '.arguments.json') (ConvertTo-Json -InputObject $ArgumentList -Compress)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Executable
    $start.Arguments = (($ArgumentList | ForEach-Object { Quote-WindowsArgument $_ }) -join ' ')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $start.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw "Could not start $Executable" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
    } finally {
        $process.Dispose()
    }
    Write-Utf8File ($LogPrefix + '.stdout.txt') $stdout
    Write-Utf8File ($LogPrefix + '.stderr.txt') $stderr
    if ($ShowOutput) {
        if ($stdout.Length -gt 0) { Write-Host $stdout.TrimEnd() }
        if ($stderr.Length -gt 0) { Write-Host $stderr.TrimEnd() -ForegroundColor DarkYellow }
    }
    Write-Host ('Exit code: ' + $exitCode)
    return [pscustomobject]@{ ExitCode = $exitCode; Stdout = $stdout; Stderr = $stderr }
}
