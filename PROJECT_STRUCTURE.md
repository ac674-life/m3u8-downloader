# M3U8InstallSoftware 目录说明

更新时间：2026-10-05

## 当前结构

```text
M3U8InstallSoftware/
|-- installer/                 Windows 安装器源码
|-- m3u8-mp4-downloader/       当前主程序目录
|   |-- background.js          浏览器扩展后台脚本
|   |-- manifest.json          Manifest V3 配置
|   |-- popup.*                浏览器扩展弹窗
|   |-- README.html            使用说明
|   |-- helper/                PowerShell 本地服务及 Web UI
|   |   |-- start-helper.ps1   本地 HTTP 服务、任务队列和下载逻辑
|   |   |-- ui/                下载中心前端
|   |   `-- yt-dlp.exe         页面视频解析工具
|   |-- ffmpeg/bin/            随程序分发的 ffmpeg 和 ffprobe
|   `-- jobs/                  迁移保留的旧队列、日志和已下载视频
|-- outputs/                   安装器构建输出目录
`-- work/                      历史版本、构建素材和测试数据
    |-- dashboard-package-v3/  旧版完整包
    |-- dashboard-package-v4/  旧版完整包
    |-- web-only-package/      较新的 Web/helper 版本候选
    |-- ffmpeg/                FFmpeg 压缩包、完整解压包和 bin 副本
    |-- vendor/                Python 版 yt-dlp 及其元数据
    |-- bili-smoke-data/       Bilibili 冒烟测试数据
    |-- queue-test.ps1         队列测试脚本
    `-- zxcghl-pages-1-10-scan.json
```

## 目录职责

### `installer/`

安装器的正式源码。`build-installer.ps1` 从 `m3u8-mp4-downloader/` 复制 helper 和 FFmpeg，编译 `Launcher.cs`，再通过 IExpress 生成安装包到 `outputs/`。

构建脚本目前还从 `work/ffmpeg/ffmpeg-9.0.2-essentials_build/LICENSE` 复制 FFmpeg 许可证，因此 `work/` 暂时不能整体删除。

### `m3u8-mp4-downloader/`

当前构建脚本认定的主程序目录，但这里同时混有四类内容：

- 浏览器扩展源码；
- PowerShell helper 和 Web UI 源码；
- FFmpeg、yt-dlp 等第三方二进制；
- `jobs/` 中的运行日志、队列状态和下载视频。

`jobs/` 当前约 1.6 GB，包括约 435 个日志、7 个 MP4 和一个包含约 448 条记录的 `queue.json`。这些属于运行数据，不应进入源码版本历史或安装包。

### `outputs/`

安装器构建目标目录。当前已生成 `M3U8-Downloader-Setup.exe`。

### `work/`

迁移过来的工作区，约 0.75 GB。它包含旧包、较新实现候选、完整第三方依赖、测试数据和扫描结果，现阶段应视为待核对的归档区，而不是可直接删除的临时目录。

## 已确认的问题

1. 主程序、浏览器扩展和安装器已统一使用 `17890` 端口。
2. 主 Helper 已恢复完整版本，并将新任务和下载保存到 `%LOCALAPPDATA%\M3U8Downloader\Data`；旧 `jobs/` 仅作为迁移资料保留。
3. `work/dashboard-package-v3`、`work/dashboard-package-v4`、`work/web-only-package` 与主目录仍有重复，后续可以归档。
4. 原 Git 对象库中的 70.58 GiB 未引用视频对象及残余嵌套 `.git` 已全部清理。
5. 根目录已增加 `.gitignore`，排除运行数据、下载、日志、构建目录和缓存。
6. `helper/browser-capture.js` 依赖 Node/Playwright，但项目没有 `package.json`，当前 helper 也未引用它，需确认是否仍保留。

## 建议整理顺序

1. 把 FFmpeg 许可证和需要分发的第三方文件移出 `work/`，建立明确的 `vendor/` 或 `third_party/` 目录。
2. 确认旧 `jobs/` 中的 7 个视频是否需要迁入正式数据目录。
3. 归档或移除重复的 v3/v4 包、测试数据和多余 FFmpeg 副本。

