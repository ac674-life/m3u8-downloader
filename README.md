# M3U8 Downloader / M3U8 视频下载器

一个面向 Windows 的本地 M3U8 视频下载工具。它提供网页解析、浏览器扩展检测、本地下载队列、MP4 播放和下载记录管理。

## 中文说明

### 功能

- 粘贴文章页、M3U8 或 MP4 地址并解析视频流。
- 通过 Chrome/Edge 扩展检测页面中的视频流。
- 支持 M3U8、AES-128 加密分片和 FFmpeg 流复制。
- 本地队列最多同时下载 4 个任务，支持失败重试、复制来源页面链接和筛选记录。
- 下载记录与视频文件分开管理：删除记录不会删除已有 MP4；从媒体库永久删除时，可按独立视频文件夹一起删除。
- 本地播放器支持倍速和 0-200% 音量调节。
- 下载过程默认直连，不经过 Clash 或其他系统代理。
- 解析与下载服务仅监听 `127.0.0.1:17890`。

### 安装

1. 下载 `outputs/M3U8-Downloader-Setup.exe`，或从 GitHub Release 下载安装包。
2. 双击安装包，默认安装到 `%LOCALAPPDATA%\\Programs\\M3U8Downloader`。
3. 安装完成后，从桌面或开始菜单启动 **M3U8 Downloader**。
4. 下载中心地址：`http://127.0.0.1:17890/`。

### 使用浏览器扩展

1. 打开 Chrome/Edge 的扩展管理页并开启开发者模式。
2. 选择“加载已解压的扩展”，选中 `m3u8-mp4-downloader` 目录。
3. 打开视频页面，点击扩展图标，选择检测到的视频流并加入下载队列。

### 从源码运行

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\m3u8-mp4-downloader\\helper\\start-helper.ps1
```

也可以双击：

```text
m3u8-mp4-downloader\\helper\\launch-dashboard.cmd
```

### 编译安装包

需要 Windows、.NET Framework C# 编译器和系统自带 IExpress：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\installer\\build-installer.ps1
```

生成文件：`outputs\\M3U8-Downloader-Setup.exe`。

仓库不提交体积较大的 FFmpeg 和 yt-dlp 二进制文件；编译前请将 `ffmpeg.exe`、`ffprobe.exe` 放入 `m3u8-mp4-downloader\\ffmpeg\\bin`，并将 `yt-dlp.exe` 放入 `m3u8-mp4-downloader\\helper`。

### 安全说明

下载和 FFmpeg 处理在本机完成，来源页面预览使用受限 iframe。该项目不是完整的恶意软件沙箱，也不能保证远程网页或视频文件绝对安全；请勿在下载环境中运行未知的可执行文件，并建议使用 Defender 或其他安全软件扫描下载内容。

## English

### Features

- Analyze article pages, M3U8 manifests, and MP4 URLs.
- Detect media streams from Chrome/Edge pages with the browser extension.
- Download M3U8 streams, including AES-128 encrypted segments, through local FFmpeg stream copy.
- Local queue with up to four concurrent downloads, retry support, source-link copying, filtering, and record management.
- Deleting a history record does not delete an existing MP4. Permanent deletion from the media library can also remove a dedicated video folder.
- Built-in local player with playback-rate control and 0-200% volume control.
- Downloads use a direct connection by default and do not use Clash or system proxies.
- The helper listens only on `127.0.0.1:17890`.

### Installation

1. Download `outputs/M3U8-Downloader-Setup.exe`, or download the installer from a GitHub Release.
2. Run the installer. The default installation directory is `%LOCALAPPDATA%\\Programs\\M3U8Downloader`.
3. Launch **M3U8 Downloader** from the desktop or Start Menu.
4. Open the dashboard at `http://127.0.0.1:17890/`.

### Browser extension

1. Open the Chrome/Edge extensions page and enable Developer mode.
2. Choose **Load unpacked** and select the `m3u8-mp4-downloader` directory.
3. Open a video page, click the extension icon, select a detected stream, and add it to the queue.

### Run from source

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\m3u8-mp4-downloader\\helper\\start-helper.ps1
```

Or double-click:

```text
m3u8-mp4-downloader\\helper\\launch-dashboard.cmd
```

### Build the installer

Windows, the .NET Framework C# compiler, and the built-in IExpress tool are required:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\installer\\build-installer.ps1
```

Output: `outputs\\M3U8-Downloader-Setup.exe`.

The repository does not commit the large FFmpeg and yt-dlp binaries. Before building, place `ffmpeg.exe` and `ffprobe.exe` in `m3u8-mp4-downloader\\ffmpeg\\bin`, and place `yt-dlp.exe` in `m3u8-mp4-downloader\\helper`.

### Security note

Downloads and FFmpeg processing run locally, and source-page previews use a restricted iframe. This project is not a complete malware sandbox and cannot guarantee that a remote page or media file is harmless. Do not run unknown executables from downloaded content, and scan downloaded files with Microsoft Defender or another security product.

## License

The project source is provided for personal and authorized use. FFmpeg is distributed under its own license; see `ffmpeg/LICENSE.txt` in the installed payload.
