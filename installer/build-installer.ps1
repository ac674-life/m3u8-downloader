[CmdletBinding()]
param([switch]$SkipIExpress, [string]$OutputName = 'M3U8-Downloader-Setup.exe')

$ErrorActionPreference = 'Stop'
$installerRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $installerRoot
$sourceRoot = Join-Path $repoRoot 'm3u8-mp4-downloader'
$buildRoot = Join-Path $installerRoot 'build'
$payloadRoot = Join-Path $buildRoot 'payload'
$payloadZip = Join-Path $buildRoot 'payload.zip'
$packageRoot = Join-Path $buildRoot 'package'
$outputRoot = Join-Path $repoRoot 'outputs'
$setupPath = Join-Path $outputRoot $OutputName
$stagedSetupPath = Join-Path $buildRoot 'M3U8-Downloader-Setup-staged.exe'
$pendingSetupPath = Join-Path $outputRoot 'M3U8-Downloader-Setup-updated.exe'

Remove-Item -LiteralPath $buildRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $payloadRoot, $packageRoot, $outputRoot | Out-Null
$appRoot = Join-Path $payloadRoot 'app'
New-Item -ItemType Directory -Force -Path $appRoot | Out-Null
Copy-Item -LiteralPath (Join-Path $sourceRoot 'helper') -Destination $appRoot -Recurse -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot 'ffmpeg') -Destination $appRoot -Recurse -Force

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (!(Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (!(Test-Path $csc)) { throw 'The .NET Framework C# compiler was not found.' }
$launcherSource = Join-Path $installerRoot 'Launcher.cs'
$launcherPath = Join-Path $appRoot 'Launcher.exe'
& $csc /nologo /target:winexe /optimize+ /out:$launcherPath /reference:System.dll /reference:System.Windows.Forms.dll $launcherSource
if ($LASTEXITCODE -ne 0) { throw 'Launcher.exe compilation failed.' }

$licenseSource = Join-Path $repoRoot 'work\ffmpeg\ffmpeg-9.0.2-essentials_build\LICENSE'
if (Test-Path $licenseSource) { Copy-Item -LiteralPath $licenseSource -Destination (Join-Path $appRoot 'ffmpeg\LICENSE.txt') -Force }
Set-Content -LiteralPath (Join-Path $appRoot 'VERSION.txt') -Value 'M3U8 Downloader 1.0.0' -Encoding ASCII
Compress-Archive -Path (Join-Path $payloadRoot '*') -DestinationPath $payloadZip -CompressionLevel Optimal
Copy-Item -LiteralPath $payloadZip -Destination $packageRoot -Force
Copy-Item -LiteralPath (Join-Path $installerRoot 'install.ps1') -Destination $packageRoot -Force
Copy-Item -LiteralPath (Join-Path $installerRoot 'uninstall.ps1') -Destination $packageRoot -Force

$sedPath = Join-Path $buildRoot 'M3U8-Downloader.sed'
$packageRootEscaped = $packageRoot.Replace('\', '\')
$sed = @"
[Version]
Class=IEXPRESS
SEDVersion=3
[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=1
HideExtractAnimation=0
UseLongFileName=1
InsideCompressed=0
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=
DisplayLicense=
FinishMessage=
TargetName=$stagedSetupPath
FriendlyName=M3U8 Downloader
AppLaunched=powershell.exe -NoProfile -ExecutionPolicy Bypass -File install.ps1
PostInstallCmd=<None>
AdminQuietInstCmd=
UserQuietInstCmd=
SourceFiles=SourceFiles
[Strings]
FILE0=payload.zip
FILE1=install.ps1
FILE2=uninstall.ps1
[SourceFiles]
SourceFiles0=$packageRootEscaped
[SourceFiles0]
%FILE0%=
%FILE1%=
%FILE2%=
"@
Set-Content -LiteralPath $sedPath -Value $sed -Encoding ASCII

if (!$SkipIExpress) {
  $iexpress = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\iexpress.exe') -ArgumentList @('/N', $sedPath) -Wait -PassThru
  if ($iexpress.ExitCode -ne 0 -or !(Test-Path $stagedSetupPath)) { throw 'IExpress failed to build Setup.exe.' }
  try {
    Copy-Item -LiteralPath $stagedSetupPath -Destination $setupPath -Force -ErrorAction Stop
  } catch {
    Copy-Item -LiteralPath $stagedSetupPath -Destination $pendingSetupPath -Force
    throw "The existing Setup.exe is locked by another process. The updated package is at $pendingSetupPath. $($_.Exception.Message)"
  }
}
Write-Output "Payload: $payloadZip"
if (Test-Path $setupPath) { Write-Output "Setup: $setupPath ($([math]::Round((Get-Item $setupPath).Length / 1MB, 1)) MB)" }
