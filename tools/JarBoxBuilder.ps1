#requires -Version 5.1
<#
    JarBox Builder - build file .ipa cho iPad chỉ với 1 nút bấm.

    Cách mở : bấm đúp shortcut "JarBox Builder" trên Desktop,
              hoặc file "JarBox Builder.bat" trong thư mục dự án.

    Cách hoạt động:
      1. (nếu có) lưu thay đổi code và đẩy lên GitHub
      2. yêu cầu GitHub Actions build với số phiên bản bạn nhập
      3. theo dõi tiến trình build trên máy Mac của GitHub
      4. tải file JarBox-iPad-v<phiên bản>.ipa về thư mục build_output

    Dòng lệnh (không mở cửa sổ):
      powershell -ExecutionPolicy Bypass -File tools\JarBoxBuilder.ps1 -SelfTest
      powershell -ExecutionPolicy Bypass -File tools\JarBoxBuilder.ps1 -Build 0.1.2
      powershell -ExecutionPolicy Bypass -File tools\JarBoxBuilder.ps1 -DownloadLatest
#>
param(
    [switch]$SelfTest,
    [string]$Build,
    [switch]$DownloadLatest
)

$ErrorActionPreference = 'Stop'

$RepoDir  = Split-Path -Parent $PSScriptRoot
$OutDir   = Join-Path $RepoDir 'build_output'
$Workflow = 'build-ipa.yml'
$Branch   = 'main'

# ============================================================
# Helpers shared by the UI thread and the background worker
# ============================================================
$HelperCode = @'
function Format-Arg([string]$a) {
    if ($a -eq '') { return '""' }
    if ($a -notmatch '[\s"]') { return $a }
    $q = $a -replace '(\\*)"', '$1$1\"'
    $q = $q -replace '(\\+)$', '$1$1'
    return '"' + $q + '"'
}

function Invoke-Exe([string]$File, [string[]]$ArgList, [string]$WorkDir) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = (@($ArgList) | ForEach-Object { Format-Arg $_ }) -join ' '
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.EnvironmentVariables['GH_PROMPT_DISABLED'] = '1'
    $psi.EnvironmentVariables['GH_NO_UPDATE_NOTIFIER'] = '1'
    $psi.EnvironmentVariables['NO_COLOR'] = '1'
    $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    $p = [System.Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEndAsync()
    $e = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    [pscustomobject]@{ Code = $p.ExitCode; Out = $o.Result.Trim(); Err = $e.Result.Trim() }
}
'@
. ([scriptblock]::Create($HelperCode))

# ============================================================
# Background worker (runs in its own runspace, talks via $sync)
# ============================================================
$WorkerCode = @'
$ErrorActionPreference = 'Stop'
function Log([string]$m) { $sync.Log.Enqueue(('[{0:HH:mm:ss}] {1}' -f (Get-Date), $m)) }
function Gh([string[]]$a)  { Invoke-Exe $sync.GhExe  $a $sync.RepoDir }
function Git([string[]]$a) { Invoke-Exe $sync.GitExe $a $sync.RepoDir }

$StepNames = @{
    'Set up job'                          = 'Chuẩn bị máy Mac'
    'Checkout'                            = 'Tải mã nguồn'
    'Resolve version'                     = 'Đặt số phiên bản'
    'Select newest Xcode 26'              = 'Chọn Xcode'
    'Set up JDK 17'                       = 'Cài Java'
    'Build J2ME API jar'                  = 'Build phần Java (J2ME API)'
    'Build app (unsigned)'                = 'Biên dịch app (bước lâu nhất)'
    'Bundle runtime jars and package IPA' = 'Đóng gói file .ipa'
    'Upload IPA'                          = 'Đưa file .ipa lên GitHub'
    'Upload build log'                    = 'Lưu nhật ký build'
}

function Save-Ipa([string]$runId, [string]$artifactName) {
    $tmp = Join-Path $sync.OutDir ('.download-' + $runId)
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    New-Item -ItemType Directory -Force $tmp | Out-Null
    if ($artifactName) {
        $a2 = @('run', 'download', $runId, '-R', $sync.Repo, '-n', $artifactName, '-D', $tmp)
    } else {
        $a2 = @('run', 'download', $runId, '-R', $sync.Repo, '-p', 'JarBox-iPad*', '-D', $tmp)
    }
    $r = Gh $a2
    if ($r.Code -ne 0) { throw ('Tải file thất bại: ' + $r.Err) }
    $ipa = Get-ChildItem $tmp -Recurse -Filter *.ipa | Select-Object -First 1
    if (-not $ipa) { throw 'Không tìm thấy file .ipa trong bản build.' }
    $dest = Join-Path $sync.OutDir $ipa.Name
    Move-Item $ipa.FullName $dest -Force
    Remove-Item $tmp -Recurse -Force
    return $dest
}

try {
    New-Item -ItemType Directory -Force $sync.OutDir | Out-Null

    if ($sync.Mode -eq 'build') {
        $ver = $sync.Version

        # 1. Push local commits (if any) so GitHub builds the latest code
        $r = Git @('rev-list', '--count', ('origin/' + $sync.Branch + '..HEAD'))
        if ($r.Code -eq 0 -and $r.Out -match '^\d+$' -and [int]$r.Out -gt 0) {
            Log ('Đẩy ' + $r.Out + ' commit mới lên GitHub...')
            $p = Git @('push', 'origin', ('HEAD:' + $sync.Branch))
            if ($p.Code -ne 0) { throw ('git push lỗi: ' + $p.Err) }
            Log 'Đã đẩy code lên GitHub.'
        }

        # 2. Start the workflow
        $start = (Get-Date).ToUniversalTime()
        $sync.Status = 'Đang gửi yêu cầu build...'
        Log ('Yêu cầu GitHub build phiên bản ' + $ver + '...')
        $r = Gh @('workflow', 'run', $sync.Workflow, '-R', $sync.Repo, '--ref', $sync.Branch, '-f', ('version=' + $ver))
        if ($r.Code -ne 0) { throw ('Không gửi được lệnh build: ' + $r.Err) }

        $runId = $null
        if (($r.Out + "`n" + $r.Err) -match '/actions/runs/(\d+)') { $runId = $Matches[1] }
        $title = 'Build iPad IPA v' + $ver
        $tries = 0
        while (-not $runId -and $tries -lt 40) {
            Start-Sleep -Seconds 3
            $tries++
            $l = Gh @('run', 'list', '-R', $sync.Repo, '--workflow', $sync.Workflow, '--event', 'workflow_dispatch',
                      '--limit', '10', '--json', 'databaseId,displayTitle,createdAt')
            if ($l.Code -eq 0 -and $l.Out) {
                $runs = $l.Out | ConvertFrom-Json
                foreach ($run in @($runs)) {
                    $created = [datetime]::Parse([string]$run.createdAt,
                        [System.Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
                    if ($run.displayTitle -eq $title -and $created -ge $start.AddMinutes(-3)) {
                        $runId = [string]$run.databaseId
                        break
                    }
                }
            }
        }
        if (-not $runId) { throw 'Không tìm thấy bản build vừa tạo trên GitHub.' }
        $sync.RunId = $runId
        Log ('Theo dõi tại: https://github.com/' + $sync.Repo + '/actions/runs/' + $runId)

        # 3. Watch progress
        $t0 = Get-Date
        $lastStep = ''
        $info = $null
        while ($true) {
            if ($sync.CancelRequested) {
                $sync.CancelRequested = $false
                Gh @('run', 'cancel', $runId, '-R', $sync.Repo) | Out-Null
                Log 'Đã gửi lệnh hủy build...'
            }
            $v = Gh @('run', 'view', $runId, '-R', $sync.Repo, '--json', 'status,conclusion,jobs')
            if ($v.Code -eq 0 -and $v.Out) {
                $info = $v.Out | ConvertFrom-Json
                if ($info.status -eq 'completed') { break }
                $stepTxt = 'Đang chờ máy Mac của GitHub...'
                if ($info.status -ne 'queued' -and $info.jobs) {
                    $cur = @($info.jobs)[0].steps | Where-Object { $_.status -eq 'in_progress' } | Select-Object -First 1
                    if ($cur) {
                        $stepTxt = $cur.name
                        if ($StepNames.ContainsKey($stepTxt)) { $stepTxt = $StepNames[$stepTxt] }
                    } else { $stepTxt = 'Đang chạy...' }
                }
                $elapsed = '{0:mm\:ss}' -f ((Get-Date) - $t0)
                $sync.Status = 'Đang build v' + $ver + '  (' + $elapsed + ')  -  ' + $stepTxt
                if ($stepTxt -ne $lastStep) { Log $stepTxt; $lastStep = $stepTxt }
            }
            if (((Get-Date) - $t0).TotalMinutes -gt 90) { throw 'Đã quá 90 phút, dừng theo dõi.' }
            Start-Sleep -Seconds 8
        }

        # 4. Result
        if ($info.conclusion -eq 'success') {
            $sync.Status = 'Build thành công, đang tải file .ipa về máy...'
            Log 'Build thành công! Đang tải file .ipa về máy...'
            $dest = Save-Ipa $runId ('JarBox-iPad-v' + $ver)
            $sync.IpaPath = $dest
            $sync.Success = $true
            Log ('Đã lưu: ' + $dest)
        } elseif ($info.conclusion -eq 'cancelled') {
            Log 'Bản build đã bị hủy.'
        } else {
            Log ('Build LỖI (' + $info.conclusion + '). Trích nhật ký lỗi:')
            $f = Gh @('run', 'view', $runId, '-R', $sync.Repo, '--log-failed')
            $lines = @($f.Out -split "`r?`n" | ForEach-Object { (($_ -split "`t")[-1]) -replace '^\S+Z ', '' })
            $errs = @($lines | Where-Object { $_ -match 'error' } | Select-Object -First 30)
            foreach ($x in $errs) { Log ('  ' + $x) }
            Log '  ----- cuối nhật ký -----'
            foreach ($x in @($lines | Select-Object -Last 15)) { Log ('  ' + $x) }
            Log 'Hãy gửi đoạn nhật ký này cho Claude để sửa lỗi.'
        }
    }
    elseif ($sync.Mode -eq 'latest') {
        $sync.Status = 'Đang tìm bản build mới nhất...'
        $l = Gh @('run', 'list', '-R', $sync.Repo, '--workflow', $sync.Workflow, '--status', 'success',
                  '--limit', '1', '--json', 'databaseId,displayTitle')
        if ($l.Code -ne 0) { throw ('Không đọc được danh sách build: ' + $l.Err) }
        $runs = $l.Out | ConvertFrom-Json
        $runs = @($runs)
        if ($runs.Count -eq 0) { throw 'Chưa có bản build thành công nào.' }
        $run = $runs[0]
        Log ('Bản mới nhất: ' + $run.displayTitle + ' (#' + $run.databaseId + ')')
        $sync.Status = 'Đang tải file .ipa về máy...'
        $dest = Save-Ipa ([string]$run.databaseId) $null
        $sync.IpaPath = $dest
        $sync.Success = $true
        Log ('Đã lưu: ' + $dest)
    }
}
catch {
    Log ('LỖI: ' + $_.Exception.Message)
}
finally {
    $sync.Done = $true
}
'@

# ============================================================
# Environment discovery
# ============================================================
function Find-Gh {
    $p = Join-Path $env:LOCALAPPDATA 'gh-cli\bin\gh.exe'
    if (Test-Path $p) { return $p }
    $c = Get-Command gh.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

function Find-Sideloadly {
    $cands = @(
        (Join-Path $env:ProgramFiles 'Sideloadly\sideloadly.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Sideloadly\sideloadly.exe'),
        (Join-Path $env:LOCALAPPDATA 'Sideloadly\sideloadly.exe')
    )
    if (${env:ProgramFiles(x86)}) { $cands += (Join-Path ${env:ProgramFiles(x86)} 'Sideloadly\sideloadly.exe') }
    foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    $menus = @("$env:ProgramData\Microsoft\Windows\Start Menu\Programs", "$env:APPDATA\Microsoft\Windows\Start Menu\Programs")
    $lnk = Get-ChildItem -Path $menus -Recurse -Filter 'Sideloadly*.lnk' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($lnk) { return $lnk.FullName }
    return $null
}

function ConvertTo-FullVersion([string]$v) {
    $parts = @($v.Split('.'))
    while ($parts.Count -lt 3) { $parts += '0' }
    return [version]($parts[0..2] -join '.')
}

function Get-SuggestedVersion {
    $best = $null
    if (Test-Path $OutDir) {
        foreach ($f in Get-ChildItem $OutDir -Filter 'JarBox-iPad-v*.ipa') {
            if ($f.Name -match '^JarBox-iPad-v(\d+(\.\d+){0,2})\.ipa$') {
                $v = ConvertTo-FullVersion $Matches[1]
                if (-not $best -or $v -gt $best) { $best = $v }
            }
        }
    }
    if (-not $best) {
        $best = [version]'0.1.0'
        $pbx = Join-Path $RepoDir 'J2MEEmulator.xcodeproj\project.pbxproj'
        if ((Test-Path $pbx) -and ((Get-Content $pbx -Raw) -match 'MARKETING_VERSION = "?(\d+(\.\d+){0,2})"?;')) {
            $best = ConvertTo-FullVersion $Matches[1]
        }
    }
    return '{0}.{1}.{2}' -f $best.Major, $best.Minor, ($best.Build + 1)
}

$GhExe  = Find-Gh
$GitCmd = Get-Command git.exe -ErrorAction SilentlyContinue
$GitExe = if ($GitCmd) { $GitCmd.Source } else { $null }
$Repo   = $null
if ($GitExe) {
    $r = Invoke-Exe $GitExe @('remote', 'get-url', 'origin') $RepoDir
    if ($r.Code -eq 0 -and $r.Out -match 'github\.com[:/]([^/]+/[^/]+?)(\.git)?$') { $Repo = $Matches[1] }
}

function Test-GhLogin {
    if (-not $GhExe) { return $false }
    return ((Invoke-Exe $GhExe @('auth', 'status', '--hostname', 'github.com') $RepoDir).Code -eq 0)
}

function Get-Problem {
    if (-not $GitExe) { return 'Chưa cài Git cho Windows (git-scm.com).' }
    if (-not $GhExe)  { return 'Chưa có GitHub CLI (gh.exe).' }
    if (-not $Repo)   { return 'Thư mục dự án chưa nối với repo GitHub (remote "origin").' }
    if (-not (Test-GhLogin)) { return 'Chưa đăng nhập GitHub. Bấm nút "Đăng nhập GitHub".' }
    return $null
}

# ============================================================
# Worker launcher
# ============================================================
function New-Worker([string]$mode, [string]$version) {
    $script:sync = [hashtable]::Synchronized(@{
        Log = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        Status = ''; Done = $false; Success = $false; IpaPath = $null; RunId = $null
        CancelRequested = $false; Mode = $mode; Version = $version
        RepoDir = $RepoDir; OutDir = $OutDir; GhExe = $GhExe; GitExe = $GitExe
        Repo = $Repo; Workflow = $Workflow; Branch = $Branch
    })
    $script:rs = [runspacefactory]::CreateRunspace()
    $script:rs.Open()
    $script:rs.SessionStateProxy.SetVariable('sync', $script:sync)
    $script:psWorker = [powershell]::Create()
    $script:psWorker.Runspace = $script:rs
    [void]$script:psWorker.AddScript($HelperCode + "`n" + $WorkerCode)
    $script:handle = $script:psWorker.BeginInvoke()
}

function Complete-Worker {
    $msgs = @()
    try { [void]$script:psWorker.EndInvoke($script:handle) } catch { $msgs += ('LỖI: ' + $_.Exception.Message) }
    foreach ($e in $script:psWorker.Streams.Error) { $msgs += ('LỖI: ' + $e) }
    $script:psWorker.Dispose()
    $script:rs.Close()
    return $msgs
}

# ============================================================
# Command-line modes (no window)
# ============================================================
if ($SelfTest -or $Build -or $DownloadLatest) {
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
    Write-Host "RepoDir    : $RepoDir"
    Write-Host "gh         : $GhExe"
    Write-Host "git        : $GitExe"
    Write-Host "Repo       : $Repo"
    Write-Host "Sideloadly : $(Find-Sideloadly)"
    Write-Host "Suggested  : $(Get-SuggestedVersion)"
    $problem = Get-Problem
    Write-Host "Problem    : $problem"
    if ($SelfTest) { if ($problem) { exit 1 } else { exit 0 } }
    if ($problem) { exit 1 }

    if ($Build) {
        $v = $Build.Trim().TrimStart('v', 'V')
        if ($v -notmatch '^\d+(\.\d+){0,2}$') { Write-Host 'Phiên bản không hợp lệ'; exit 1 }
        New-Worker 'build' $v
    } else {
        New-Worker 'latest' ''
    }
    $m = $null
    $lastStatus = ''
    while (-not $script:sync.Done) {
        while ($script:sync.Log.TryDequeue([ref]$m)) { Write-Host $m }
        Start-Sleep -Milliseconds 500
    }
    while ($script:sync.Log.TryDequeue([ref]$m)) { Write-Host $m }
    foreach ($x in (Complete-Worker)) { Write-Host $x }
    if ($script:sync.Success) { Write-Host "RESULT: $($script:sync.IpaPath)"; exit 0 } else { exit 1 }
}

# ============================================================
# Window
# ============================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'JarBox iPad Builder'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(820, 620)
$form.MinimumSize = New-Object System.Drawing.Size(640, 480)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$form.AutoScaleMode = 'Dpi'
$iconPng = Join-Path $RepoDir 'Assets\icon.png'
if (Test-Path $iconPng) {
    try {
        $bmp = New-Object System.Drawing.Bitmap $iconPng
        $small = New-Object System.Drawing.Bitmap $bmp, 64, 64
        $form.Icon = [System.Drawing.Icon]::FromHandle($small.GetHicon())
    } catch {}
}

$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock = 'Fill'
$root.ColumnCount = 1
$root.Padding = New-Object System.Windows.Forms.Padding(14)
foreach ($i in 1..6) { [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize'))) }
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
$root.RowCount = 7
$form.Controls.Add($root)

function New-Flow {
    $f = New-Object System.Windows.Forms.FlowLayoutPanel
    $f.AutoSize = $true
    $f.AutoSizeMode = 'GrowAndShrink'
    $f.WrapContents = $true
    $f.Dock = 'Fill'
    $f.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 4)
    return $f
}
function New-Button([string]$text) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.AutoSize = $true
    $b.AutoSizeMode = 'GrowAndShrink'
    $b.Padding = New-Object System.Windows.Forms.Padding(10, 5, 10, 5)
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 6)
    return $b
}

# Header
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = 'JarBox iPad Builder'
$lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$lblTitle.AutoSize = $true
$root.Controls.Add($lblTitle)

$lnkRepo = New-Object System.Windows.Forms.LinkLabel
$lnkRepo.AutoSize = $true
$lnkRepo.Text = if ($Repo) { "github.com/$Repo" } else { '(chưa nối repo GitHub)' }
$lnkRepo.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 8)
$lnkRepo.Add_LinkClicked({ if ($Repo) { Start-Process "https://github.com/$Repo" } })
$root.Controls.Add($lnkRepo)

# Build row
$rowBuild = New-Flow
$lblVer = New-Object System.Windows.Forms.Label
$lblVer.Text = 'Phiên bản:'
$lblVer.AutoSize = $true
$lblVer.Margin = New-Object System.Windows.Forms.Padding(0, 9, 6, 0)
$txtVer = New-Object System.Windows.Forms.TextBox
$txtVer.Width = 110
$txtVer.Font = New-Object System.Drawing.Font('Segoe UI', 12)
$txtVer.Margin = New-Object System.Windows.Forms.Padding(0, 3, 10, 6)
$btnBuild = New-Button 'Build bản mới'
$btnBuild.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$btnBuild.BackColor = [System.Drawing.Color]::FromArgb(31, 136, 61)
$btnBuild.ForeColor = [System.Drawing.Color]::White
$btnBuild.FlatStyle = 'Flat'
$btnBuild.FlatAppearance.BorderSize = 0
$btnCancel = New-Button 'Hủy build'
$btnCancel.Enabled = $false
$rowBuild.Controls.AddRange(@($lblVer, $txtVer, $btnBuild, $btnCancel))
$root.Controls.Add($rowBuild)

# Tools row
$rowTools = New-Flow
$btnLatest = New-Button 'Tải bản build mới nhất'
$btnFolder = New-Button 'Mở thư mục file IPA'
$btnSide   = New-Button 'Mở Sideloadly'
$btnWeb    = New-Button 'Xem trên GitHub'
$btnLogin  = New-Button 'Đăng nhập GitHub'
$rowTools.Controls.AddRange(@($btnLatest, $btnFolder, $btnSide, $btnWeb, $btnLogin))
$root.Controls.Add($rowTools)

# Status + progress
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.AutoSize = $true
$lblStatus.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$lblStatus.Margin = New-Object System.Windows.Forms.Padding(3, 8, 3, 4)
$root.Controls.Add($lblStatus)

$bar = New-Object System.Windows.Forms.ProgressBar
$bar.Dock = 'Fill'
$bar.Height = 16
$bar.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 8)
$root.Controls.Add($bar)

# Log
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.Dock = 'Fill'
$txtLog.BackColor = [System.Drawing.Color]::White
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9.5)
$root.Controls.Add($txtLog)

function Add-Log([string]$m) { $txtLog.AppendText($m + "`r`n") }

function Show-InFolder([string]$path) {
    Start-Process explorer.exe -ArgumentList ('/select,"' + $path + '"')
}

function Set-Busy([bool]$busy, [bool]$canCancel = $false) {
    $script:busy = $busy
    foreach ($b in @($btnBuild, $btnLatest, $btnLogin, $txtVer)) { $b.Enabled = -not $busy }
    $btnCancel.Enabled = $busy -and $canCancel
    if ($busy) { $bar.Style = 'Marquee'; $bar.MarqueeAnimationSpeed = 30 }
    else { $bar.Style = 'Continuous'; $bar.Value = 0 }
}

function Assert-Ready {
    $problem = Get-Problem
    if ($problem) {
        [void][System.Windows.Forms.MessageBox]::Show($problem, 'JarBox Builder', 'OK', 'Warning')
        $lblStatus.Text = $problem
        return $false
    }
    return $true
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 300
$timer.Add_Tick({
    $s = $script:sync
    if (-not $s) { return }
    $m = $null
    while ($s.Log.TryDequeue([ref]$m)) { Add-Log $m }
    if ($s.Status) { $lblStatus.Text = $s.Status }
    if (-not $s.Done) { return }

    $timer.Stop()
    while ($s.Log.TryDequeue([ref]$m)) { Add-Log $m }
    foreach ($x in (Complete-Worker)) { Add-Log $x }
    Set-Busy $false
    if ($s.Success -and $s.IpaPath) {
        $name = [System.IO.Path]::GetFileName($s.IpaPath)
        $lblStatus.Text = 'Xong! Đã có file ' + $name
        $txtVer.Text = Get-SuggestedVersion
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "Đã có file:`n$($s.IpaPath)`n`nMở thư mục chứa file?", 'JarBox Builder', 'YesNo', 'Information')
        if ($ans -eq 'Yes') { Show-InFolder $s.IpaPath }
    } else {
        $lblStatus.Text = 'Không thành công - xem nhật ký bên dưới.'
    }
})

$btnBuild.Add_Click({
    $ver = $txtVer.Text.Trim().TrimStart('v', 'V')
    if ($ver -notmatch '^\d+(\.\d+){0,2}$') {
        [void][System.Windows.Forms.MessageBox]::Show('Phiên bản không hợp lệ. Ví dụ: 0.1.2', 'JarBox Builder', 'OK', 'Warning')
        return
    }
    if (-not (Assert-Ready)) { return }

    $existing = Join-Path $OutDir "JarBox-iPad-v$ver.ipa"
    if (Test-Path $existing) {
        $a = [System.Windows.Forms.MessageBox]::Show("Đã có bản v$ver trong máy. Build lại và ghi đè?", 'JarBox Builder', 'YesNo', 'Question')
        if ($a -ne 'Yes') { return }
    }

    $st = Invoke-Exe $GitExe @('status', '--porcelain') $RepoDir
    if ($st.Out) {
        $files = (@($st.Out -split "`r?`n") | Select-Object -First 12) -join "`n"
        $a = [System.Windows.Forms.MessageBox]::Show(
            "Có thay đổi trong thư mục dự án chưa được lưu (commit):`n`n$files`n`n" +
            "Yes  = Lưu lại và đưa vào bản build này`n" +
            "No   = Bỏ qua, build từ code đã có trên GitHub`n" +
            "Cancel = Hủy", 'JarBox Builder', 'YesNoCancel', 'Question')
        if ($a -eq 'Cancel') { return }
        if ($a -eq 'Yes') {
            $r1 = Invoke-Exe $GitExe @('add', '-A') $RepoDir
            $r2 = Invoke-Exe $GitExe @('commit', '-m', "Cập nhật cho bản v$ver") $RepoDir
            if ($r1.Code -ne 0 -or $r2.Code -ne 0) {
                [void][System.Windows.Forms.MessageBox]::Show("Không lưu được thay đổi:`n$($r1.Err)`n$($r2.Err)", 'JarBox Builder', 'OK', 'Error')
                return
            }
        }
    }

    $txtLog.Clear()
    Add-Log "=== Build phiên bản $ver ==="
    New-Worker 'build' $ver
    Set-Busy $true $true
    $timer.Start()
})

$btnCancel.Add_Click({
    if ($script:sync -and -not $script:sync.Done) {
        $script:sync.CancelRequested = $true
        $btnCancel.Enabled = $false
        Add-Log 'Đang hủy build...'
    }
})

$btnLatest.Add_Click({
    if (-not (Assert-Ready)) { return }
    $txtLog.Clear()
    Add-Log '=== Tải bản build mới nhất ==='
    New-Worker 'latest' ''
    Set-Busy $true $false
    $timer.Start()
})

$btnFolder.Add_Click({
    New-Item -ItemType Directory -Force $OutDir | Out-Null
    Start-Process explorer.exe -ArgumentList ('"' + $OutDir + '"')
})

$btnSide.Add_Click({
    $sl = Find-Sideloadly
    if ($sl) { Start-Process $sl; return }
    $a = [System.Windows.Forms.MessageBox]::Show(
        "Chưa tìm thấy Sideloadly trên máy.`nMở trang sideloadly.io để tải về?", 'JarBox Builder', 'YesNo', 'Question')
    if ($a -eq 'Yes') { Start-Process 'https://sideloadly.io' }
})

$btnWeb.Add_Click({ if ($Repo) { Start-Process "https://github.com/$Repo/actions" } })

$btnLogin.Add_Click({
    if (-not $GhExe) {
        [void][System.Windows.Forms.MessageBox]::Show('Chưa có GitHub CLI (gh.exe).', 'JarBox Builder', 'OK', 'Warning')
        return
    }
    $cmd = "& '$GhExe' auth login --hostname github.com --git-protocol https --web --scopes workflow; " +
           "& '$GhExe' auth setup-git; Write-Host ''; Write-Host 'Xong! Co the dong cua so nay.' -ForegroundColor Green"
    Start-Process powershell.exe -ArgumentList ('-NoProfile -NoExit -Command "' + $cmd + '"')
})

$form.Add_Shown({
    $txtVer.Text = Get-SuggestedVersion
    Add-Log 'Cách dùng:'
    Add-Log '  1. Nhập số phiên bản (đã gợi ý sẵn) rồi bấm "Build bản mới".'
    Add-Log '  2. Đợi khoảng 2-5 phút. File .ipa sẽ tự tải về thư mục build_output.'
    Add-Log '  3. Bấm "Mở Sideloadly", kéo file .ipa vào và cài lên iPad.'
    Add-Log ''
    $form.Refresh()
    $problem = Get-Problem
    if ($problem) { $lblStatus.Text = $problem }
    else { $lblStatus.Text = 'Sẵn sàng.' }
})

$form.Add_FormClosing({
    param($sender, $e)
    if ($script:busy) {
        $a = [System.Windows.Forms.MessageBox]::Show(
            "Đang build. Nếu đóng, GitHub vẫn build tiếp nhưng file sẽ không tự tải về`n(bấm ""Tải bản build mới nhất"" lần sau để lấy).`n`nĐóng cửa sổ?",
            'JarBox Builder', 'YesNo', 'Warning')
        if ($a -ne 'Yes') { $e.Cancel = $true }
    }
})

$script:busy = $false
[void]$form.ShowDialog()
