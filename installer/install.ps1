[CmdletBinding()]
param(
  [string]$InstallRoot,
  [string]$DataRoot,
  [switch]$NoLaunch,
  [switch]$SkipShortcuts,
  [switch]$SkipRegistry
)

$ErrorActionPreference = 'Stop'
$productName = 'M3U8 Downloader'
$version = '1.0.0'
$localAppData = [Environment]::GetFolderPath('LocalApplicationData')
if (!$InstallRoot) { $InstallRoot = Join-Path $localAppData 'Programs\M3U8Downloader' }
if (!$DataRoot) { $DataRoot = Join-Path $localAppData 'M3U8Downloader\Data' }
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$DataRoot = [IO.Path]::GetFullPath($DataRoot)
$packageRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$payloadZip = Join-Path $packageRoot 'payload.zip'
$stage = Join-Path ([IO.Path]::GetTempPath()) ('m3u8-installer-' + [Guid]::NewGuid().ToString('N'))
$buildId = Get-Date -Format 'yyyyMMdd-HHmmss'
$versionRoot = Join-Path $InstallRoot 'versions'
$versionDirectory = Join-Path $versionRoot ($version + '-' + $buildId + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))

function New-Shortcut([string]$Path, [string]$Target, [string]$WorkingDirectory) {
  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($Path)
  $shortcut.TargetPath = $Target
  $shortcut.WorkingDirectory = $WorkingDirectory
  $shortcut.Description = $productName
  $shortcut.IconLocation = "$Target,0"
  $shortcut.Save()
}

try {
  if (!(Test-Path $payloadZip)) { throw 'The installer is missing payload.zip.' }
  New-Item -ItemType Directory -Force -Path $stage | Out-Null
  Expand-Archive -LiteralPath $payloadZip -DestinationPath $stage -Force
  $appSource = Join-Path $stage 'app'
  if (!(Test-Path (Join-Path $appSource 'helper\start-helper.ps1'))) { throw 'The installer payload is missing the helper.' }
  if (!(Test-Path (Join-Path $appSource 'ffmpeg\bin\ffmpeg.exe'))) { throw 'The installer payload is missing ffmpeg.' }

  New-Item -ItemType Directory -Force -Path $versionRoot, $DataRoot | Out-Null
  Move-Item -LiteralPath $appSource -Destination $versionDirectory
  Copy-Item -LiteralPath (Join-Path $packageRoot 'uninstall.ps1') -Destination (Join-Path $InstallRoot 'uninstall.ps1') -Force
  Set-Content -LiteralPath (Join-Path $InstallRoot 'current.txt') -Value $versionDirectory -Encoding UTF8

  $launcher = Join-Path $versionDirectory 'Launcher.exe'
  if (!$SkipShortcuts) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $programs = [Environment]::GetFolderPath('Programs')
    $startMenuDirectory = Join-Path $programs $productName
    New-Item -ItemType Directory -Force -Path $startMenuDirectory | Out-Null
    New-Shortcut (Join-Path $desktop ($productName + '.lnk')) $launcher $versionDirectory
    New-Shortcut (Join-Path $startMenuDirectory ($productName + '.lnk')) $launcher $versionDirectory
  }

  if (!$SkipRegistry) {
    $uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\M3U8Downloader'
    New-Item -Path $uninstallKey -Force | Out-Null
    $uninstallScript = Join-Path $InstallRoot 'uninstall.ps1'
    $uninstallCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$uninstallScript`""
    New-ItemProperty -Path $uninstallKey -Name DisplayName -Value $productName -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name DisplayVersion -Value $version -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name Publisher -Value 'M3U8 Downloader' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name InstallLocation -Value $InstallRoot -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name DisplayIcon -Value $launcher -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name UninstallString -Value $uninstallCommand -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name QuietUninstallString -Value ($uninstallCommand + ' -Quiet') -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name NoModify -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name NoRepair -Value 1 -PropertyType DWord -Force | Out-Null
  }

  if (!$NoLaunch) {
    Start-Process -FilePath $launcher -WorkingDirectory $versionDirectory
  }
  Write-Output "$productName $version was installed in $InstallRoot. Data: $DataRoot"
}
catch {
  Write-Error $_
  exit 1
}
finally {
  if (Test-Path $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
}
