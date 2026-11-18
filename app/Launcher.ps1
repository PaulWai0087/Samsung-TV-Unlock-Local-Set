# QN90B Region Assistant. Windows PowerShell 5.1 / Windows x64 / STA.
# The GUI starts Worker.ps1 only after the user clicks an action button.
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-LauncherField {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-LauncherTrue {
    param([object]$Value)
    return ($Value -is [bool] -and $Value -eq $true)
}

function ConvertTo-TvIpv4 {
    param([string]$Text)
    $candidate = $Text.Trim()
    if ($candidate -cnotmatch '^[0-9]{1,3}(\.[0-9]{1,3}){3}$') {
        throw '请填写电视的 IPv4 地址，例如 192.168.1.100。'
    }
    $parts = @($candidate.Split('.') | ForEach-Object { [int]$_ })
    foreach ($part in $parts) { if ($part -lt 0 -or $part -gt 255) { throw '电视 IP 中每一段都应在 0 到 255 之间。' } }
    if ($parts[0] -eq 0 -or $parts[0] -eq 127 -or $parts[0] -ge 224) {
        throw '请填写电视在家庭局域网中的地址。'
    }
    return ($parts -join '.')
}

function Quote-LauncherArgument {
    param([AllowEmptyString()][string]$Argument)
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
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

function New-LauncherWorkerArguments {
    param(
        [string]$WorkerPath,
        [ValidateSet('Inspect','Singapore','China','Setup','Diagnostics')][string]$Action,
        [string]$TvIp, [string]$JobDirectory, [string]$KitRoot
    )
    $ip = ConvertTo-TvIpv4 $TvIp
    return @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
        '-File',$WorkerPath,'-Action',$Action,'-TvIp',$ip,
        '-JobDirectory',$JobDirectory,'-KitRoot',$KitRoot)
}

function Get-LauncherCategoryTitle {
    param([string]$Category)
    switch -CaseSensitive ($Category) {
        'CHI13' { return '国行参数' }
        'CHI0' { return '地区列表已解锁' }
        'SG0' { return '新加坡参数' }
        default { return '尚未确认' }
    }
}

function Get-LauncherResultAssessment {
    param([object]$Result, [int]$ExitCode, [string]$RequestedAction)
    $category = [string](Get-LauncherField $Result 'category')
    $action = [string](Get-LauncherField $Result 'action')
    $message = [string](Get-LauncherField $Result 'message')
    $success = ($ExitCode -eq 0 -and (Test-LauncherTrue (Get-LauncherField $Result 'success')) -and $action -ceq $RequestedAction)
    $state = Get-LauncherField $Result 'state'
    $verifiedProperty = $null
    if ($null -ne $Result) { $verifiedProperty = $Result.PSObject.Properties['stateVerified'] }
    $verifiedFlag = ($null -ne $verifiedProperty -and (Test-LauncherTrue $verifiedProperty.Value))
    $tvAction = $RequestedAction -cin @('Inspect','Singapore','China')
    $validCategory = $false
    switch -CaseSensitive ($RequestedAction) {
        'Inspect' { $validCategory = $category -cin @('CHI13','CHI0','SG0') }
        'Singapore' { $validCategory = $category -ceq 'SG0' }
        'China' { $validCategory = $category -ceq 'CHI13' }
        'Setup' { $validCategory = $category -ceq 'Setup' }
        'Diagnostics' { $validCategory = $category -ceq 'Diagnostics' }
    }
    $success = ($success -and $validCategory)
    if ($tvAction) { $success = ($success -and $verifiedFlag -and $null -ne $state) }
    if (-not $success -and [string]::IsNullOrWhiteSpace($message)) {
        $message = '没有收到与本次操作一致的完整成功结果。请重新检测，或导出诊断包。'
    }
    $title = '操作未完成'
    if ($success) {
        switch ($RequestedAction) {
            'Inspect' { $title = '检测完成' }
            'Singapore' { $title = '新加坡参数已回读确认' }
            'China' { $title = '国行参数已回读确认' }
            'Setup' { $title = '运行环境已就绪' }
            'Diagnostics' { $title = '诊断包已导出' }
        }
    }
    return [pscustomobject]@{
        Success = [bool]$success
        TvAction = [bool]$tvAction
        VerifiedTv = [bool]($success -and $tvAction)
        Category = $category
        Title = $title
        Message = $message
        PartialSuccess = (Test-LauncherTrue (Get-LauncherField $Result 'partialSuccess'))
        CanSingapore = [bool]($success -and $tvAction -and (Test-LauncherTrue (Get-LauncherField $Result 'canSingapore')))
        CanChina = [bool]($success -and $tvAction -and (Test-LauncherTrue (Get-LauncherField $Result 'canChina')))
    }
}

function Get-LauncherBackupText {
    param([object]$Backups)
    $parts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in @(@('stage1','原始国行备份'), @('stage2','换区前备份'))) {
        $item = Get-LauncherField $Backups $entry[0]
        $status = '未确认'
        if (Test-LauncherTrue (Get-LauncherField $item 'available')) { $status = '已核对' }
        elseif ($null -ne $item) { $status = '缺失或不匹配' }
        $parts.Add($entry[1] + '：' + $status)
    }
    return ($parts.ToArray() -join '     ')
}

function Write-LauncherText {
    param([string]$Path, [AllowEmptyString()][string]$Text)
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Get-LauncherLanAddresses {
    $items = New-Object 'System.Collections.Generic.List[object]'
    foreach ($adapter in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($adapter.OperationalStatus -ne [Net.NetworkInformation.OperationalStatus]::Up -or
            $adapter.NetworkInterfaceType -eq [Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
        foreach ($entry in $adapter.GetIPProperties().UnicastAddresses) {
            if ($entry.Address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { continue }
            $ip = $entry.Address.ToString()
            if ($ip.StartsWith('127.') -or $ip.StartsWith('169.254.') -or $ip -eq '0.0.0.0') { continue }
            $items.Add([pscustomobject]@{ Ip = $ip; Adapter = $adapter.Name; Display = ($ip + '  ·  ' + $adapter.Name) })
        }
    }
    return $items.ToArray()
}

function Save-LauncherSettings {
    param([string]$TvIp)
    $ip = ConvertTo-TvIpv4 $TvIp
    $settings = [pscustomobject]@{ schema = 'qn90b-launcher-v1'; tvIp = $ip }
    $temporary = $script:SettingsPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    Write-LauncherText $temporary (ConvertTo-Json -InputObject $settings -Depth 3)
    if ([IO.File]::Exists($script:SettingsPath)) {
        [IO.File]::Replace($temporary, $script:SettingsPath, [NullString]::Value)
    } else { [IO.File]::Move($temporary, $script:SettingsPath) }
    return $ip
}

function Set-LauncherMessage {
    param([string]$Title, [string]$Message, [ValidateSet('Normal','Success','Error')][string]$Kind = 'Normal')
    $script:Ui.ProgressTitle.Text = $Title
    $script:Ui.ProgressTitle.ForeColor = $script:Colors.Text
    if ($Kind -eq 'Success') { $script:Ui.ProgressTitle.ForeColor = $script:Colors.Green }
    if ($Kind -eq 'Error') { $script:Ui.ProgressTitle.ForeColor = $script:Colors.Red }
    $script:Ui.Details.Text = $Message
}

function Update-LauncherControls {
    $free = -not $script:Busy
    foreach ($name in @('Setup','Inspect','Diagnostics','SaveIp','Ip')) { $script:Ui[$name].Enabled = $free }
    $script:Ui.Singapore.Enabled = ($free -and $script:CanSingapore)
    $script:Ui.China.Enabled = ($free -and $script:CanChina)
    foreach ($name in @('Singapore','China')) {
        $button = $script:Ui[$name]
        if ($button.Enabled) {
            $button.BackColor = $script:Colors.Blue
            $button.ForeColor = [Drawing.Color]::White
        } else {
            $button.BackColor = $script:Colors.Disabled
            $button.ForeColor = $script:Colors.Muted
        }
    }
    $script:Ui.Form.UseWaitCursor = $script:Busy
}

function Reset-LauncherTvState {
    param([string]$Title = '尚未检测')
    $script:CanSingapore = $false
    $script:CanChina = $false
    $script:LastTvResult = $null
    $script:Ui.StateTitle.Text = $Title
    $script:Ui.StateTitle.ForeColor = $script:Colors.Muted
    $script:Ui.LocalValue.Text = '尚未读取'
    $script:Ui.ImportValue.Text = '—'
    $script:Ui.Backups.Text = '备份：检测后显示；已有备份不会覆盖。'
    Update-LauncherControls
}

function Update-LauncherTvState {
    param([object]$Result, [object]$Assessment)
    if (-not $Assessment.VerifiedTv) {
        Reset-LauncherTvState '需要重新检测'
        $script:Ui.StateTitle.ForeColor = $script:Colors.Red
        return
    }
    $script:LastTvResult = $Result
    $state = Get-LauncherField $Result 'state'
    $name = [string](Get-LauncherField $state 'currentName')
    $store = Get-LauncherField $state 'currentStore'
    $enum = Get-LauncherField $state 'globalEnum'
    $import = Get-LauncherField (Get-LauncherField $state 'preventImport') 'value'
    $script:Ui.StateTitle.Text = Get-LauncherCategoryTitle $Assessment.Category
    $script:Ui.StateTitle.ForeColor = $script:Colors.Green
    $script:Ui.LocalValue.Text = ('{0}   ·   store {1} / enum {2}' -f $name,$store,$enum)
    $script:Ui.ImportValue.Text = [string]$import
    $script:Ui.Backups.Text = Get-LauncherBackupText (Get-LauncherField $Result 'backups')
    $script:CanSingapore = $Assessment.CanSingapore
    $script:CanChina = $Assessment.CanChina
}

function Open-LauncherPath {
    param([string]$Path, [switch]$SelectFile)
    if (-not ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path))) { throw '文件尚未生成，或没有找到对应位置。' }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.UseShellExecute = $true
    if ($SelectFile) {
        $start.FileName = 'explorer.exe'
        $start.Arguments = '/select,' + (Quote-LauncherArgument $Path)
    } else { $start.FileName = $Path }
    $process = [Diagnostics.Process]::Start($start)
    if ($null -ne $process) { $process.Dispose() }
}

function Start-LauncherWorker {
    param([ValidateSet('Inspect','Singapore','China','Setup','Diagnostics')][string]$Action)
    if ($script:Busy) { return }
    if ($Action -eq 'Singapore' -and -not $script:CanSingapore) { throw '请先检测当前状态；通过检查后才会启用切换。' }
    if ($Action -eq 'China' -and -not $script:CanChina) { throw '请先检测当前状态并核对原始备份。' }
    $ip = Save-LauncherSettings $script:Ui.Ip.Text
    $script:Ui.Ip.Text = $ip
    $worker = Join-Path $script:KitRoot 'app\Worker.ps1'
    if (-not [IO.File]::Exists($worker)) { throw '没有找到 app\Worker.ps1。请先完整解压工具包，再打开 START.cmd。' }
    $jobDirectory = Join-Path (Join-Path $script:AppRoot 'jobs') ((Get-Date -Format 'yyyyMMdd-HHmmss') + '_' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($jobDirectory)
    $arguments = New-LauncherWorkerArguments $worker $Action $ip $jobDirectory $script:KitRoot
    Write-LauncherText (Join-Path $jobDirectory 'Launcher-Arguments.json') (ConvertTo-Json -InputObject $arguments)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $script:PowerShellPath
    $start.Arguments = (($arguments | ForEach-Object { Quote-LauncherArgument $_ }) -join ' ')
    $start.WorkingDirectory = $script:KitRoot
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $start.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    $job = [pscustomobject]@{
        Action = $Action; Ip = $ip; Directory = $jobDirectory; Process = $process
        Started = $false; StdoutTask = $null; StderrTask = $null; ExitObservedUtc = $null
        LastProgress = ''; CaptureError = ''
    }
    $script:ActiveJob = $job
    $script:Busy = $true
    Update-LauncherControls
    $script:Ui.Progress.Style = [Windows.Forms.ProgressBarStyle]::Marquee
    $script:Ui.Progress.MarqueeAnimationSpeed = 28
    Set-LauncherMessage '正在启动…' '请等待当前步骤完成。操作期间不能关闭窗口，也不会自动重启电视。'
    try {
        if (-not $process.Start()) { throw '无法启动后台工作程序。' }
        $job.Started = $true
        # Drain BOTH pipes concurrently. Never wait synchronously for a running worker.
        $job.StdoutTask = $process.StandardOutput.ReadToEndAsync()
        $job.StderrTask = $process.StandardError.ReadToEndAsync()
        $script:Ui.Timer.Start()
    } catch {
        if ($job.Started -and -not $process.HasExited) {
            $job.CaptureError = $_.Exception.Message
            Set-LauncherMessage '后台仍在运行' '输出记录遇到问题，正在等待后台结束。请勿重复启动操作。' 'Error'
            $script:Ui.Timer.Start()
        } else {
            $script:ActiveJob = $null; $script:Busy = $false
            $process.Dispose(); Update-LauncherControls
            throw
        }
    }
}

function Complete-LauncherWorker {
    param([object]$Job)
    $script:Ui.Timer.Stop()
    $exitCode = $Job.Process.ExitCode
    $stdout = ''; $stderr = $Job.CaptureError
    foreach ($streamName in @('Stdout','Stderr')) {
        $task = $Job.PSObject.Properties[$streamName + 'Task'].Value
        $value = ''
        if ($null -ne $task -and $task.IsCompleted) {
            try { $value = $task.GetAwaiter().GetResult() }
            catch { $value = '输出记录异常：' + $_.Exception.Message }
        } else { $value = '进程已退出，但该输出管道未及时结束；请同时保留 Worker 生成的日志。' }
        if ($streamName -eq 'Stdout') { $stdout = $value } else { $stderr += [Environment]::NewLine + $value }
    }
    $result = $null
    try {
        Write-LauncherText (Join-Path $Job.Directory 'Launcher-stdout.txt') $stdout
        Write-LauncherText (Join-Path $Job.Directory 'Launcher-stderr.txt') $stderr
        $resultPath = Join-Path $Job.Directory 'result.json'
        if (-not [IO.File]::Exists($resultPath)) { throw '后台没有生成 result.json。' }
        $result = [IO.File]::ReadAllText($resultPath) | ConvertFrom-Json
        $assessment = Get-LauncherResultAssessment $result $exitCode $Job.Action
        if ($assessment.TvAction) { Update-LauncherTvState $result $assessment }
        $detail = $assessment.Message
        if ($assessment.PartialSuccess -and -not $assessment.Success) {
            $detail += "`r`n`r`n部分步骤已经完成。请先重新检测当前状态，再决定后续操作。"
        }
        $detail += "`r`n`r`n本次日志：" + $Job.Directory
        $kind = 'Error'; if ($assessment.Success) { $kind = 'Success' }
        Set-LauncherMessage $assessment.Title $detail $kind
        if ($Job.Action -eq 'Diagnostics' -and $assessment.Success) {
            $zip = [string](Get-LauncherField $result 'diagnosticsPath')
            if ($zip -and [IO.File]::Exists($zip)) {
                try { Open-LauncherPath $zip -SelectFile } catch { $script:Ui.Details.AppendText("`r`n诊断包：" + $zip) }
            }
        }
    } catch {
        if ($Job.Action -cin @('Inspect','Singapore','China')) { Reset-LauncherTvState '需要重新检测' }
        Set-LauncherMessage '操作未完成' ($_.Exception.Message + "`r`n请点击「导出诊断」，保留本次日志。`r`n" + $Job.Directory) 'Error'
    } finally {
        $script:Ui.Progress.Style = [Windows.Forms.ProgressBarStyle]::Continuous
        $script:Ui.Progress.Value = 100
        $Job.Process.Dispose()
        $script:ActiveJob = $null
        $script:Busy = $false
        Update-LauncherControls
    }
}

function Update-LauncherWorker {
    $job = $script:ActiveJob
    if ($null -eq $job) { $script:Ui.Timer.Stop(); return }
    $progressPath = Join-Path $job.Directory 'progress.json'
    if ([IO.File]::Exists($progressPath)) {
        # The file may be between updates. A partial read must not stop the worker.
        try {
            $raw = [IO.File]::ReadAllText($progressPath)
            if ($raw -cne $job.LastProgress) {
                $progress = $raw | ConvertFrom-Json
                $percentValue = Get-LauncherField $progress 'percent'
                if ($null -ne $percentValue) {
                    $percent = [Math]::Max(0, [Math]::Min(100, [int]$percentValue))
                    $script:Ui.Progress.Style = [Windows.Forms.ProgressBarStyle]::Continuous
                    $script:Ui.Progress.Value = $percent
                }
                $message = [string](Get-LauncherField $progress 'message')
                if ($message) { Set-LauncherMessage '正在进行，请稍候…' ($message + "`r`n`r`n操作期间不能关闭窗口；请等待完整结果。") }
                $job.LastProgress = $raw
            }
        } catch { }
    }
    $job.Process.Refresh()
    if (-not $job.Process.HasExited) { return }
    if ($null -eq $job.ExitObservedUtc) { $job.ExitObservedUtc = [DateTime]::UtcNow }
    $drained = ($null -ne $job.StdoutTask -and $job.StdoutTask.IsCompleted -and $null -ne $job.StderrTask -and $job.StderrTask.IsCompleted)
    # Do not block the UI if an inherited handle delays a pipe after the worker exits.
    if ($drained -or ([DateTime]::UtcNow - $job.ExitObservedUtc).TotalSeconds -ge 15) { Complete-LauncherWorker $job }
}

function New-LauncherLabel {
    param([string]$Text, [single]$Size = 9.5, [bool]$Bold = $false)
    $label = New-Object Windows.Forms.Label
    $style = [Drawing.FontStyle]::Regular
    if ($Bold) { $style = [Drawing.FontStyle]::Bold }
    $label.Font = New-Object Drawing.Font('Microsoft YaHei UI', $Size, $style)
    $label.Text = $Text; $label.AutoSize = $false; $label.Dock = 'Fill'
    $label.ForeColor = $script:Colors.Text; $label.TextAlign = 'MiddleLeft'
    $label.Margin = New-Object Windows.Forms.Padding(0)
    return $label
}

function New-LauncherButton {
    param([string]$Text, [bool]$Primary = $false)
    $button = New-Object Windows.Forms.Button
    $button.Text = $Text; $button.Dock = 'Fill'; $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 0
    $button.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10, [Drawing.FontStyle]::Bold)
    $button.Margin = New-Object Windows.Forms.Padding(3)
    $button.Cursor = [Windows.Forms.Cursors]::Hand
    $button.UseVisualStyleBackColor = $false
    $button.BackColor = $script:Colors.SoftBlue; $button.ForeColor = $script:Colors.Blue
    $button.FlatAppearance.MouseOverBackColor = [Drawing.ColorTranslator]::FromHtml('#DCE8FF')
    if ($Primary) {
        $button.BackColor = $script:Colors.Blue; $button.ForeColor = [Drawing.Color]::White
        $button.FlatAppearance.MouseOverBackColor = [Drawing.ColorTranslator]::FromHtml('#1D4ED8')
    }
    return $button
}

function New-LauncherGrid {
    param([int]$Columns, [int]$Rows)
    $grid = New-Object Windows.Forms.TableLayoutPanel
    $grid.ColumnCount = $Columns; $grid.RowCount = $Rows; $grid.Dock = 'Fill'
    $grid.Margin = New-Object Windows.Forms.Padding(0)
    $grid.Padding = New-Object Windows.Forms.Padding(0)
    return $grid
}

function Initialize-LauncherWindow {
    param([string]$InitialIp)
    $script:Colors = @{
        Background = [Drawing.ColorTranslator]::FromHtml('#F2F5FA')
        Text = [Drawing.ColorTranslator]::FromHtml('#182840')
        Muted = [Drawing.ColorTranslator]::FromHtml('#6C7B91')
        Blue = [Drawing.ColorTranslator]::FromHtml('#2563EB')
        SoftBlue = [Drawing.ColorTranslator]::FromHtml('#EAF0FC')
        Disabled = [Drawing.ColorTranslator]::FromHtml('#E2E8F0')
        Green = [Drawing.ColorTranslator]::FromHtml('#167451')
        Red = [Drawing.ColorTranslator]::FromHtml('#B43B36')
    }
    $form = New-Object Windows.Forms.Form
    $form.Text = 'QN90B 区域助手'
    $form.AutoScaleDimensions = New-Object Drawing.SizeF(96,96)
    $form.AutoScaleMode = 'Dpi'
    $form.ClientSize = New-Object Drawing.Size(900,720)
    $form.MinimumSize = New-Object Drawing.Size(840,660)
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = $script:Colors.Background
    $form.Font = New-Object Drawing.Font('Microsoft YaHei UI',9.5)
    $form.Padding = New-Object Windows.Forms.Padding(18,12,18,12)
    $form.MaximizeBox = $true
    $scroll = New-Object Windows.Forms.Panel
    $scroll.Dock = 'Fill'; $scroll.AutoScroll = $true
    $form.Controls.Add($scroll)
    $root = New-LauncherGrid 1 9
    $root.Dock = 'Top'; $root.Height = 688
    foreach ($height in @(62,112,10,122,10,88,10,124,50)) {
        [void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,$height)))
    }
    [void]$root.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100)))
    $scroll.Controls.Add($root)
    $heading = New-LauncherGrid 1 2
    [void]$heading.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,34)))
    [void]$heading.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100)))
    $heading.Controls.Add((New-LauncherLabel 'QN90B 区域助手' 21 $true),0,0)
    $subtitle = New-LauncherLabel '仅适用于 QA75QN90BAJXXZ · 75 英寸国行 · 固件 1710；操作时核对实际固件指纹。' 9
    $subtitle.ForeColor = $script:Colors.Muted
    $heading.Controls.Add($subtitle,0,1); $root.Controls.Add($heading,0,0)

    $connection = New-LauncherGrid 4 3
    $connection.BackColor = [Drawing.Color]::White
    $connection.Padding = New-Object Windows.Forms.Padding(12,8,12,6)
    foreach ($width in @(100,220,84)) { [void]$connection.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute,$width))) }
    [void]$connection.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100)))
    foreach ($height in @(34,32,26)) { [void]$connection.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,$height))) }
    $connection.Controls.Add((New-LauncherLabel '电视 IP' 10 $true),0,0)
    $ip = New-Object Windows.Forms.TextBox
    $ip.Text = $InitialIp; $ip.Font = New-Object Drawing.Font('Segoe UI',11)
    $ip.Dock = 'Fill'; $ip.Margin = New-Object Windows.Forms.Padding(0,3,8,3)
    $connection.Controls.Add($ip,1,0)
    $saveIp = New-LauncherButton '保存'; $connection.Controls.Add($saveIp,2,0)
    $connection.Controls.Add((New-LauncherLabel '电脑与电视需连接同一局域网。' 9),3,0)
    $connection.Controls.Add((New-LauncherLabel '本机局域网 IP' 9.5 $true),0,1)
    $lan = New-Object Windows.Forms.ComboBox
    $lan.DropDownStyle = 'DropDownList'; $lan.Dock = 'Fill'; $lan.Margin = New-Object Windows.Forms.Padding(0,3,8,3)
    $connection.Controls.Add($lan,1,1); $connection.SetColumnSpan($lan,3)
    $hint = New-LauncherLabel '电视开发者模式的 Host PC IP 请填电脑地址，不是电视 IP。多网卡时选择与电视在同一网络的地址。' 8.8
    $hint.ForeColor = $script:Colors.Muted
    $connection.Controls.Add($hint,0,2); $connection.SetColumnSpan($hint,4)
    $root.Controls.Add($connection,0,1)
    $addresses = @(Get-LauncherLanAddresses)
    if ($addresses.Count -eq 0) { [void]$lan.Items.Add('未找到可用 IPv4；请先连接家庭网络。') }
    else { foreach ($address in $addresses) { [void]$lan.Items.Add($address.Display) } }
    $lan.SelectedIndex = 0
    $prefix = $InitialIp.Substring(0,$InitialIp.LastIndexOf('.')+1)
    for ($i=0; $i -lt $addresses.Count; $i++) { if ($addresses[$i].Ip.StartsWith($prefix)) { $lan.SelectedIndex=$i; break } }

    $stateCard = New-LauncherGrid 2 4
    $stateCard.BackColor = [Drawing.Color]::White
    $stateCard.Padding = New-Object Windows.Forms.Padding(12,8,12,6)
    [void]$stateCard.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,68)))
    [void]$stateCard.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,32)))
    foreach ($height in @(24,20,30,26)) { [void]$stateCard.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,$height))) }
    $stateCard.Controls.Add((New-LauncherLabel '当前状态' 10 $true),0,0)
    $stateTitle = New-LauncherLabel '尚未检测' 10 $true
    $stateTitle.TextAlign = 'MiddleRight'; $stateTitle.ForeColor=$script:Colors.Muted
    $stateCard.Controls.Add($stateTitle,1,0)
    $stateCard.Controls.Add((New-LauncherLabel 'Local Set' 9),0,1)
    $stateCard.Controls.Add((New-LauncherLabel 'Preventing Import' 9),1,1)
    $localValue = New-LauncherLabel '尚未读取' 12 $true
    $importValue = New-LauncherLabel '—' 15 $true
    $stateCard.Controls.Add($localValue,0,2); $stateCard.Controls.Add($importValue,1,2)
    $backups = New-LauncherLabel '备份：检测后显示；已有备份不会覆盖。' 8.8
    $backups.ForeColor = $script:Colors.Muted
    $stateCard.Controls.Add($backups,0,3); $stateCard.SetColumnSpan($backups,2)
    $root.Controls.Add($stateCard,0,3)

    $actions = New-LauncherGrid 2 2
    [void]$actions.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,50)))
    [void]$actions.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,50)))
    [void]$actions.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,50)))
    [void]$actions.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,50)))
    $setup = New-LauncherButton '检查 / 安装运行环境'
    $inspect = New-LauncherButton '检测当前状态'
    $singapore = New-LauncherButton '切换新加坡' $true
    $china = New-LauncherButton '恢复国行参数' $true
    $actions.Controls.Add($setup,0,0); $actions.Controls.Add($inspect,1,0)
    $actions.Controls.Add($singapore,0,1); $actions.Controls.Add($china,1,1)
    $root.Controls.Add($actions,0,5)

    $progressCard = New-LauncherGrid 1 3
    foreach ($height in @(24,10)) { [void]$progressCard.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,$height))) }
    [void]$progressCard.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100)))
    $progressTitle = New-LauncherLabel '先准备环境，再检测电视' 10 $true
    $progress = New-Object Windows.Forms.ProgressBar
    $progress.Dock='Fill'; $progress.Margin=New-Object Windows.Forms.Padding(0,1,0,1)
    $details=New-Object Windows.Forms.TextBox
    $details.Multiline=$true; $details.ReadOnly=$true; $details.ScrollBars='Vertical'; $details.Dock='Fill'
    $details.BackColor=[Drawing.Color]::White; $details.BorderStyle='FixedSingle'
    $details.Margin=New-Object Windows.Forms.Padding(0,7,0,0)
    $details.Font=New-Object Drawing.Font('Microsoft YaHei UI',9)
    $details.Text='打开助手不会连接电视或修改参数。先点击「检查 / 安装运行环境」，再点击「检测当前状态」。通过检测后，切换按钮会按状态与原机备份启用。'
    $progressCard.Controls.Add($progressTitle,0,0); $progressCard.Controls.Add($progress,0,1); $progressCard.Controls.Add($details,0,2)
    $root.Controls.Add($progressCard,0,7)

    $footer = New-LauncherGrid 3 1
    for($i=0;$i -lt 3;$i++){[void]$footer.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,33.333)))}
    $diagnostics=New-LauncherButton '导出诊断'; $guide=New-LauncherButton '查看图文教程'; $openBackups=New-LauncherButton '打开备份位置'
    $footer.Controls.Add($diagnostics,0,0); $footer.Controls.Add($guide,1,0); $footer.Controls.Add($openBackups,2,0)
    $root.Controls.Add($footer,0,8)
    $timer=New-Object Windows.Forms.Timer; $timer.Interval=400
    $toolTip=New-Object Windows.Forms.ToolTip
    $toolTip.SetToolTip($inspect,'读取电视参数并核对原机备份，不修改电视工厂参数。')
    $toolTip.SetToolTip($singapore,'点击后直接执行。后台会重新检测、保存原始备份并按顺序切换参数。')
    $toolTip.SetToolTip($china,'点击后直接执行。需要原机备份；先恢复 CHI_DTV，再恢复 Import 13。')
    $toolTip.SetToolTip($diagnostics,'把当前电视的本机日志打包，不会自动上传。')
    $script:Ui=@{Form=$form;Ip=$ip;SaveIp=$saveIp;Lan=$lan;Setup=$setup;Inspect=$inspect;Singapore=$singapore;China=$china;Diagnostics=$diagnostics;Guide=$guide;OpenBackups=$openBackups;StateTitle=$stateTitle;LocalValue=$localValue;ImportValue=$importValue;Backups=$backups;ProgressTitle=$progressTitle;Progress=$progress;Details=$details;Timer=$timer;ToolTip=$toolTip}
    $ip.Add_TextChanged({ if(-not $script:Busy){Reset-LauncherTvState 'IP 已更改，待检测'} })
    $saveIp.Add_Click({try{$script:Ui.Ip.Text=Save-LauncherSettings $script:Ui.Ip.Text;Set-LauncherMessage '电视 IP 已保存' '下一次打开会使用这个地址。请检测当前状态。'}catch{Set-LauncherMessage 'IP 未保存' $_.Exception.Message 'Error'}})
    $setup.Add_Click({try{Start-LauncherWorker 'Setup'}catch{Set-LauncherMessage '未能开始环境检查' $_.Exception.Message 'Error'}})
    $inspect.Add_Click({try{Start-LauncherWorker 'Inspect'}catch{Set-LauncherMessage '未能开始检测' $_.Exception.Message 'Error'}})
    $singapore.Add_Click({try{Start-LauncherWorker 'Singapore'}catch{Set-LauncherMessage '未能开始切换' $_.Exception.Message 'Error'}})
    $china.Add_Click({try{Start-LauncherWorker 'China'}catch{Set-LauncherMessage '未能开始恢复' $_.Exception.Message 'Error'}})
    $diagnostics.Add_Click({try{Start-LauncherWorker 'Diagnostics'}catch{Set-LauncherMessage '未能导出诊断' $_.Exception.Message 'Error'}})
    $guide.Add_Click({try{Open-LauncherPath (Join-Path $script:KitRoot 'guide\index.html')}catch{Set-LauncherMessage '未能打开教程' $_.Exception.Message 'Error'}})
    $openBackups.Add_Click({try{Open-LauncherPath (Join-Path $env:LOCALAPPDATA 'QN90B-root')}catch{Set-LauncherMessage '尚未找到备份目录' '先检测当前状态。备份保存在电脑的 QN90B-root 文件夹内；已有备份不会覆盖。'}})
    $timer.Add_Tick({try{Update-LauncherWorker}catch{Set-LauncherMessage '正在等待后台结果' ($_.Exception.Message+' 请勿重复启动操作；后台任务不会被终止。') 'Error'}})
    $form.Add_FormClosing({param($sender,$eventArgs) if($script:Busy){$eventArgs.Cancel=$true;Set-LauncherMessage '操作仍在进行' '请等待当前步骤完成后再关闭窗口。后台任务会继续运行。'}})
    $form.Add_Shown({$area=[Windows.Forms.Screen]::FromControl($script:Ui.Form).WorkingArea;if($script:Ui.Form.Height -gt $area.Height-20){$script:Ui.Form.Height=[Math]::Max(660,$area.Height-20)};if($script:Ui.Form.Width -gt $area.Width-20){$script:Ui.Form.Width=[Math]::Max(840,$area.Width-20)}})
    Update-LauncherControls
    return $form
}

$launcherExit = 1
$mutex = $null
$ownsMutex = $false
$script:Ui = $null
$script:Busy = $false
$script:CanSingapore = $false
$script:CanChina = $false
$script:LastTvResult = $null
$script:ActiveJob = $null
try {
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) {
        throw '请在 Windows 10/11 的 x64 电脑上双击 START.cmd。'
    }
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { throw '本工具内附的运行程序适用于 Windows x64。' }
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) { throw '请通过 START.cmd 启动，以使用 STA 图形界面。' }
    $script:KitRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $script:AppRoot = Join-Path $env:LOCALAPPDATA 'QN90B-RegionAssistant'
    [void][IO.Directory]::CreateDirectory($script:AppRoot)
    $script:SettingsPath = Join-Path $script:AppRoot 'settings.json'
    $script:PowerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -TypeDefinition 'using System.Runtime.InteropServices; namespace QN90BGui { public static class Dpi { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); } }'
    [void][QN90BGui.Dpi]::SetProcessDPIAware()
    [Windows.Forms.Application]::EnableVisualStyles()
    [Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
    $mutex = New-Object Threading.Mutex($false,'Local\QN90BRegionAssistant')
    try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) {
        [void][Windows.Forms.MessageBox]::Show('区域助手已经打开。请使用现有窗口，并等待正在进行的操作结束。','QN90B 区域助手',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Information)
        $launcherExit = 0
    } else {
        $initialIp = '192.168.1.100'
        if ([IO.File]::Exists($script:SettingsPath)) {
            try { $saved = [IO.File]::ReadAllText($script:SettingsPath) | ConvertFrom-Json; $initialIp = ConvertTo-TvIpv4 ([string](Get-LauncherField $saved 'tvIp')) } catch { }
        }
        $form = Initialize-LauncherWindow $initialIp
        [Windows.Forms.Application]::Run($form)
        $launcherExit = 0
    }
} catch {
    $errorText = $_.Exception.Message
    try {
        $errorRoot = Join-Path $env:LOCALAPPDATA 'QN90B-RegionAssistant'
        [void][IO.Directory]::CreateDirectory($errorRoot)
        $errorPath = Join-Path $errorRoot 'Launcher-Error.txt'
        Write-LauncherText $errorPath ($_.Exception.ToString() + [Environment]::NewLine + $_.ScriptStackTrace)
        $errorText += "`r`n`r`n日志：" + $errorPath
    } catch { }
    try { [void][Windows.Forms.MessageBox]::Show($errorText,'QN90B 区域助手无法启动',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error) }
    catch { try { $popup=New-Object -ComObject WScript.Shell;[void]$popup.Popup($errorText,0,'QN90B 区域助手无法启动',16) } catch { Write-Error $errorText } }
} finally {
    if ($null -ne $script:Ui) { $script:Ui.Timer.Dispose(); $script:Ui.ToolTip.Dispose(); $script:Ui.Form.Dispose() }
    if ($ownsMutex -and $null -ne $mutex) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
exit $launcherExit
