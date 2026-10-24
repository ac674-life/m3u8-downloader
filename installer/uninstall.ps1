[CmdletBinding()]
param(
  [switch]$Quiet,
  [switch]$RemoveData,
  [string]$InstallRoot,
  [string]$DataRoot,
  [switch]$SkipShellCleanup
)

$ErrorActionPreference = 'SilentlyContinue'
$productName = 'M3U8 Downloader'
$localAppData = [Environment]::GetFolderPath('LocalApplicationData')
if (!$InstallRoot) { $InstallRoot = Join-Path $localAppData 'Programs\M3U8Downloader' }
if (!$DataRoot) { $DataRoot = Join-Path $localAppData 'M3U8Downloader\Data' }
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$DataRoot = [IO.Path]::GetFullPath($DataRoot)

function Show-UninstallOptions {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing

  $form = New-Object Windows.Forms.Form
  $form.Text = '卸载 M3U8 Downloader'
  $form.ClientSize = New-Object Drawing.Size(460, 220)
  $form.FormBorderStyle = 'FixedDialog'
  $form.StartPosition = 'CenterScreen'
  $form.MaximizeBox = $false
  $form.MinimizeBox = $false
  $form.ShowInTaskbar = $true

  $title = New-Object Windows.Forms.Label
  $title.Text = '确定要卸载 M3U8 Downloader 吗？'
  $title.Font = New-Object Drawing.Font('Microsoft YaHei UI', 13, [Drawing.FontStyle]::Bold)
  $title.AutoSize = $true
  $title.Location = New-Object Drawing.Point(24, 22)
  $form.Controls.Add($title)

  $description = New-Object Windows.Forms.Label
  $description.Text = "程序文件和快捷方式将被删除。`r`n默认保留已下载视频，重新安装后仍可继续使用。"
  $description.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
  $description.AutoSize = $true
  $description.Location = New-Object Drawing.Point(25, 62)
  $form.Controls.Add($description)

  $deleteData = New-Object Windows.Forms.CheckBox
  $deleteData.Text = '同时永久删除已下载视频和任务记录（不进入回收站）'
  $deleteData.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
  $deleteData.AutoSize = $true
  $deleteData.Location = New-Object Drawing.Point(28, 116)
  $deleteData.ForeColor = [Drawing.Color]::FromArgb(185, 28, 28)
  $form.Controls.Add($deleteData)

  $cancel = New-Object Windows.Forms.Button
  $cancel.Text = '取消'
  $cancel.Size = New-Object Drawing.Size(92, 32)
  $cancel.Location = New-Object Drawing.Point(244, 166)
  $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
  $form.Controls.Add($cancel)

  $uninstall = New-Object Windows.Forms.Button
  $uninstall.Text = '卸载'
  $uninstall.Size = New-Object Drawing.Size(92, 32)
  $uninstall.Location = New-Object Drawing.Point(344, 166)
  $uninstall.DialogResult = [Windows.Forms.DialogResult]::OK
  $form.Controls.Add($uninstall)

  $form.AcceptButton = $uninstall
  $form.CancelButton = $cancel
  $result = $form.ShowDialog()
  $removeSelectedData = $deleteData.Checked
  $form.Dispose()
  return [ordered]@{ Confirmed = ($result -eq [Windows.Forms.DialogResult]::OK); RemoveData = $removeSelectedData }
}

function Remove-Shortcut([string]$Path) {
  if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
}

if (!$Quiet -and !$RemoveData) {
  $selection = Show-UninstallOptions
  if (!$selection.Confirmed) { exit 0 }
  $RemoveData = [bool]$selection.RemoveData
}

# Stop only processes launched from this product's install directory.
Get-CimInstance Win32_Process | Where-Object {
  $_.ProcessId -ne $PID -and (
    ($_.CommandLine -and $_.CommandLine.IndexOf($InstallRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
    ($_.ExecutablePath -and $_.ExecutablePath.IndexOf($InstallRoot, [StringComparison]::OrdinalIgnoreCase) -eq 0)
  )
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Sleep -Milliseconds 300

if (!$SkipShellCleanup) {
  $desktop = [Environment]::GetFolderPath('Desktop')
  $programs = [Environment]::GetFolderPath('Programs')
  Remove-Shortcut (Join-Path $desktop ($productName + '.lnk'))
  Remove-Shortcut (Join-Path (Join-Path $programs $productName) ($productName + '.lnk'))
  Remove-Item -LiteralPath (Join-Path $programs $productName) -Recurse -Force
  Remove-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\M3U8Downloader' -Recurse -Force
}

if ($RemoveData) { Remove-Item -LiteralPath (Split-Path -Parent $DataRoot) -Recurse -Force }
Remove-Item -LiteralPath $InstallRoot -Recurse -Force

if (!$Quiet) {
  $message = if ($RemoveData) {
    '程序和已下载视频已永久删除。'
  } else {
    "程序已卸载，下载视频仍保存在：`r`n$DataRoot"
  }
  [Windows.Forms.MessageBox]::Show($message, '卸载完成', 'OK', 'Information') | Out-Null
}
