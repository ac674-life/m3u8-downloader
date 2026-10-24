# M3U8 Downloader Windows Installer

`build-installer.ps1` builds a single `outputs\M3U8-Downloader-Setup.exe` with IExpress. The package includes the local PowerShell helper, the Web UI, `ffmpeg.exe`, `ffprobe.exe`, a small .NET Framework launcher, and the install/uninstall scripts.

The installer does not request administrator access. Program files are installed below `%LOCALAPPDATA%\Programs\M3U8Downloader`. Each installation gets its own version directory, so upgrading does not overwrite a helper or ffmpeg process that is still running. User data is stored in `%LOCALAPPDATA%\M3U8Downloader\Data` and is never part of the package or removed by a normal uninstall.

The launcher starts `helper\start-helper.ps1` with `M3U8_DOWNLOADER_DATA` set to the data directory, waits for `http://127.0.0.1:17890/health`, and opens the dashboard in Microsoft Edge app mode. The installer creates Desktop and Start Menu shortcuts and a per-user uninstall entry under `HKCU`.

Interactive uninstall asks whether downloaded videos and task history should also be permanently deleted. The option is off by default. Cancel stops the uninstall, while quiet uninstall keeps data unless `-RemoveData` is passed explicitly.

Build from the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\installer\build-installer.ps1
```

The resulting setup is `outputs\M3U8-Downloader-Setup.exe`. The payload includes the FFmpeg license from the bundled essentials build.
