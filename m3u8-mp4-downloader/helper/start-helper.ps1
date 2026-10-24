$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent $PSScriptRoot
$storageRoot = if ($env:M3U8_DOWNLOADER_DATA) { [IO.Path]::GetFullPath($env:M3U8_DOWNLOADER_DATA) } else { $appRoot }
$ffmpeg = Join-Path $appRoot 'ffmpeg\bin\ffmpeg.exe'
$ffprobe = Join-Path $appRoot 'ffmpeg\bin\ffprobe.exe'
$ytDlp = Join-Path $PSScriptRoot 'yt-dlp.exe'
$uiDir = Join-Path $PSScriptRoot 'ui'
$jobsDir = Join-Path $storageRoot 'jobs'
$downloadsDir = Join-Path $storageRoot 'downloads'
$statePath = Join-Path $jobsDir 'queue.json'
$maxConcurrent = 4
$minimumDurationSeconds = 60
$fileTransfers = [Collections.ArrayList]::new()
$mediaRunspacePool = [RunspaceFactory]::CreateRunspacePool(1, 12)
$mediaRunspacePool.Open()
$lastQueueTick = [DateTimeOffset]::MinValue
$lastLibraryScan = [DateTimeOffset]::MinValue
$librarySignature = ''
$jobsResponseBytes = $null
$jobsResponseAt = [DateTimeOffset]::MinValue
New-Item -ItemType Directory -Force $jobsDir | Out-Null
New-Item -ItemType Directory -Force $downloadsDir | Out-Null

if (!(Test-Path $ffmpeg)) {
  Write-Host '找不到 ffmpeg。请把 ffmpeg.exe 放到 ffmpeg\bin\ffmpeg.exe。' -ForegroundColor Yellow
  Write-Host '可从 https://www.gyan.dev/ffmpeg/builds/ 下载 ffmpeg-release-essentials.zip 并解压。' -ForegroundColor Yellow
  exit 1
}

$jobs = @{}
function Test-BilibiliUrl([string]$url) {
  $uri = $null
  if (![Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri)) { return $false }
  return $uri.Scheme -in @('http','https') -and ($uri.Host -match '(?i)(^|\.)bilibili\.com$' -or $uri.Host -match '(?i)(^|\.)b23\.tv$')
}
if (Test-Path $statePath) {
  try {
    $saved = Get-Content $statePath -Raw | ConvertFrom-Json
    foreach ($item in @($saved)) {
      $status = [string]$item.status
      if ($status -eq 'running') { $status = 'queued' }
      $jobs[[string]$item.id] = @{
        id = [string]$item.id; url = [string]$item.url; referer = [string]$item.referer; kind = if ($item.kind) { [string]$item.kind } elseif (Test-BilibiliUrl ([string]$item.url)) { 'bilibili' } else { 'm3u8' }
        filename = [string]$item.filename; output = [string]$item.output; log = [string]$item.log
        status = $status; created = [string]$item.created; time = [string]$item.time
        error = [string]$item.error; size = [int64]$item.size; downloaded = [bool]$item.downloaded
        duration = [double]$item.duration; progress = [double]$item.progress; speed = [string]$item.speed
        sourcePage = [string]$item.sourcePage
      }
    }
  } catch { Write-Host '旧任务队列读取失败，将从空队列开始。' -ForegroundColor Yellow }
}

function Save-State {
  $snapshot = @($jobs.Values | ForEach-Object {
    [ordered]@{ id=$_.id; url=$_.url; referer=$_.referer; kind=$_.kind; filename=$_.filename; output=$_.output; log=$_.log; status=$_.status; created=$_.created; time=$_.time; error=$_.error; size=$_.size; downloaded=$_.downloaded; duration=$_.duration; progress=$_.progress; speed=$_.speed; sourcePage=$_.sourcePage }
  })
  $temp = "$statePath.tmp"
  $snapshot | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temp -Encoding UTF8
  Move-Item -LiteralPath $temp -Destination $statePath -Force
}

function Public-Job($job) {
  [ordered]@{ id=$job.id; filename=$job.filename; status=$job.status; created=$job.created; time=$job.time; error=$job.error; size=$job.size; downloaded=$job.downloaded; duration=$job.duration; progress=$job.progress; speed=$job.speed; sourcePage=$job.sourcePage; mediaUrl=if ($job.status -eq 'done') { "/media?id=$([Uri]::EscapeDataString($job.id))" } else { '' }; pagePreviewUrl=if ($job.sourcePage) { "/page-preview?id=$([Uri]::EscapeDataString($job.id))" } else { '' } }
}

$libraryMedia = @{}
function Get-SourcePageFromFolder([string]$folder) {
  $sourcePath = Join-Path $folder 'source-url.txt'
  if (!(Test-Path -LiteralPath $sourcePath)) { return '' }
  foreach ($line in (Get-Content -LiteralPath $sourcePath -ErrorAction SilentlyContinue)) {
    $match = [regex]::Match([string]$line, 'https?://\S+')
    if ($match.Success) { return $match.Value }
  }
  return ''
}

function Update-LibraryMedia {
  $signatureParts = @($jobs.Values | Where-Object { $_.status -eq 'done' } | ForEach-Object { "job:$($_.id):$($_.size):$($_.status)" })
  foreach ($root in @($storageRoot, $appRoot, $env:M3U8_DOWNLOADER_EXTRA_MEDIA_ROOT)) {
    if ($root -and (Test-Path -LiteralPath (Join-Path $root 'downloads') -PathType Container)) {
      $folder = Get-Item -LiteralPath (Join-Path $root 'downloads')
      $signatureParts += "root:$($folder.LastWriteTimeUtc.Ticks)"
    }
  }
  $newSignature = $signatureParts -join '|'
  if ($script:librarySignature -eq $newSignature -and $libraryMedia.Count -gt 0 -and ([DateTimeOffset]::UtcNow - $script:lastLibraryScan).TotalSeconds -lt 60) { return }
  $script:librarySignature = $newSignature
  $libraryMedia.Clear()
  $knownPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($job in $jobs.Values) {
    if ($job.output) { [void]$knownPaths.Add([IO.Path]::GetFullPath($job.output)) }
  }

  $oldJobs = @{}
  $mediaRoots = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  [void]$mediaRoots.Add($storageRoot)
  [void]$mediaRoots.Add($appRoot)
  if ($env:M3U8_DOWNLOADER_EXTRA_MEDIA_ROOT) {
    $extraRoot = [IO.Path]::GetFullPath($env:M3U8_DOWNLOADER_EXTRA_MEDIA_ROOT)
    if (Test-Path -LiteralPath $extraRoot -PathType Container) { [void]$mediaRoots.Add($extraRoot) }
  }
  foreach ($mediaRoot in $mediaRoots) {
    if ($mediaRoot -eq $storageRoot) { continue }
    $oldStatePath = Join-Path $mediaRoot 'jobs\queue.json'
    if (Test-Path -LiteralPath $oldStatePath) {
      try {
        foreach ($item in @(Get-Content -LiteralPath $oldStatePath -Raw | ConvertFrom-Json)) {
          if ($item.status -eq 'done' -and $item.output) {
            $oldJobs[[IO.Path]::GetFullPath([string]$item.output)] = $item
          }
        }
      } catch {}
    }
  }

  $files = @()
  foreach ($mediaRoot in $mediaRoots) {
    $files += @(Get-ChildItem -LiteralPath (Join-Path $mediaRoot 'downloads') -File -Filter '*.mp4' -Recurse -ErrorAction SilentlyContinue)
  }
  foreach ($oldJob in $oldJobs.Values) {
    if (Test-Path -LiteralPath ([string]$oldJob.output) -PathType Leaf) {
      $files += Get-Item -LiteralPath ([string]$oldJob.output)
    }
  }

  foreach ($file in $files) {
    if (!$file -or $file.Length -le 0 -or !$knownPaths.Add($file.FullName)) { continue }
    $oldJob = $oldJobs[$file.FullName]
    $sourcePage = if ($oldJob -and $oldJob.sourcePage) { [string]$oldJob.sourcePage } else { Get-SourcePageFromFolder $file.DirectoryName }
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { $idBytes = $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($file.FullName.ToLowerInvariant())) }
    finally { $sha256.Dispose() }
    $id = 'library-' + ([BitConverter]::ToString($idBytes) -replace '-', '').Substring(0, 24).ToLowerInvariant()
    $libraryMedia[$id] = @{
      id=$id; filename=$file.Name; output=$file.FullName; status='done'
      size=[int64]$file.Length; duration=if ($oldJob) { [double]$oldJob.duration } else { 0 }
      created=$file.CreationTime.ToString('o'); sourcePage=$sourcePage
    }
  }
}

function Get-MediaItem([string]$id) {
  if (!$id) { return $null }
  if ($jobs.ContainsKey($id)) { return $jobs[$id] }
  if (!$libraryMedia.ContainsKey($id)) { Update-LibraryMedia }
  if ($libraryMedia.ContainsKey($id)) { return $libraryMedia[$id] }
  return $null
}

function Write-Json($context, $value, [int]$status = 200) {
  $context.Response.StatusCode = $status
  $context.Response.ContentType = 'application/json; charset=utf-8'
  $bytes = [Text.Encoding]::UTF8.GetBytes(($value | ConvertTo-Json -Compress -Depth 6))
  $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $context.Response.Close()
}

function Write-CachedJson($context, [byte[]]$bytes) {
  $context.Response.ContentType = 'application/json; charset=utf-8'
  $context.Response.ContentLength64 = $bytes.Length
  $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $context.Response.Close()
}

function Write-Bytes($context, [byte[]]$bytes, [string]$contentType, [int]$status = 200) {
  $context.Response.StatusCode = $status
  $context.Response.ContentType = $contentType
  $context.Response.ContentLength64 = $bytes.Length
  $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $context.Response.Close()
}

function Write-Html($context, [string]$html, [int]$status = 200) {
  $context.Response.StatusCode = $status
  $context.Response.ContentType = 'text/html; charset=utf-8'
  $context.Response.Headers.Add('Cache-Control', 'no-store')
  $context.Response.Headers.Add('X-Content-Type-Options', 'nosniff')
  $context.Response.Headers.Add('X-Frame-Options', 'SAMEORIGIN')
  $context.Response.Headers.Add('Referrer-Policy', 'no-referrer')
  $context.Response.Headers.Add('Content-Security-Policy', "default-src 'none'; img-src http: https: data:; style-src 'unsafe-inline'; object-src 'none'; frame-src 'none'; media-src 'none'; connect-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'self'; sandbox")
  $bytes = [Text.Encoding]::UTF8.GetBytes($html)
  $context.Response.ContentLength64 = $bytes.Length
  $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $context.Response.Close()
}

function Write-StaticFile($context, [string]$path) {
  if (!(Test-Path $path)) { Write-Json $context @{ error='not found' } 404; return }
  $context.Response.Headers.Add('Cache-Control', 'no-store')
  $context.Response.Headers.Add('X-Content-Type-Options', 'nosniff')
  if ([IO.Path]::GetExtension($path).ToLowerInvariant() -eq '.html') {
    $context.Response.Headers.Add('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'")
  }
  $extension = [IO.Path]::GetExtension($path).ToLowerInvariant()
  $contentType = switch ($extension) { '.html' {'text/html; charset=utf-8'} '.css' {'text/css; charset=utf-8'} '.js' {'application/javascript; charset=utf-8'} default {'application/octet-stream'} }
  Write-Bytes $context ([IO.File]::ReadAllBytes($path)) $contentType
}

function Convert-TimeToSeconds([string]$value) {
  if (!$value) { return 0 }
  $parts = $value.Split(':')
  if ($parts.Count -ne 3) { return 0 }
  return ([double]$parts[0] * 3600) + ([double]$parts[1] * 60) + [double]$parts[2]
}

function Get-FileDuration([string]$path) {
  if (!(Test-Path -LiteralPath $path) -or !(Test-Path -LiteralPath $ffprobe)) { return 0 }
  try {
    $raw = & $ffprobe -v error -show_entries format=duration -of 'default=noprint_wrappers=1:nokey=1' $path 2>$null | Select-Object -First 1
    $seconds = 0.0
    if ([double]::TryParse(([string]$raw).Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$seconds)) {
      return $seconds
    }
  } catch {}
  return 0
}

function Start-FileTransfer($context, [string]$filePath, [string]$downloadName) {
  $worker = [PowerShell]::Create()
  [void]$worker.AddScript({
    param($ctx, $path, $name)
    try {
      $file = Get-Item -LiteralPath $path
      $encodedName = [Uri]::EscapeDataString($name)
      $ctx.Response.ContentType = 'video/mp4'
      $ctx.Response.ContentLength64 = $file.Length
      $ctx.Response.Headers.Add('Content-Disposition', "attachment; filename*=UTF-8''$encodedName")
      $stream = [IO.File]::OpenRead($file.FullName)
      try { $stream.CopyTo($ctx.Response.OutputStream) } finally { $stream.Dispose() }
    } catch {
      try { $ctx.Response.StatusCode = 500 } catch {}
    } finally {
      try { $ctx.Response.Close() } catch {}
    }
  }).AddArgument($context).AddArgument($filePath).AddArgument($downloadName)
  $handle = $worker.BeginInvoke()
  [void]$fileTransfers.Add([pscustomobject]@{ Worker=$worker; Handle=$handle })
}

function Start-MediaTransfer($context, [string]$filePath, [string]$displayName) {
  $rangeHeader = [string]$context.Request.Headers['Range']
  $requestMethod = [string]$context.Request.HttpMethod
  $worker = [PowerShell]::Create()
  $worker.RunspacePool = $mediaRunspacePool
  [void]$worker.AddScript({
    param($ctx, $path, $name, $range, $method)
    try {
      $file = Get-Item -LiteralPath $path
      $length = [int64]$file.Length
      $start = [int64]0
      $end = [int64]($length - 1)
      $partial = $false

      if ($range) {
        $match = [regex]::Match($range.Trim(), '^bytes=(\d*)-(\d*)$')
        if (!$match.Success -or (!$match.Groups[1].Value -and !$match.Groups[2].Value)) {
          $ctx.Response.StatusCode = 416
          $ctx.Response.Headers.Add('Content-Range', "bytes */$length")
          $ctx.Response.Close()
          return
        }
        if (!$match.Groups[1].Value) {
          $suffixLength = [int64]$match.Groups[2].Value
          if ($suffixLength -le 0) { throw 'invalid range' }
          $start = [Math]::Max([int64]0, $length - $suffixLength)
        } else {
          $start = [int64]$match.Groups[1].Value
          if ($match.Groups[2].Value) { $end = [int64]$match.Groups[2].Value }
        }
        if ($start -ge $length -or $start -lt 0 -or $end -lt $start) {
          $ctx.Response.StatusCode = 416
          $ctx.Response.Headers.Add('Content-Range', "bytes */$length")
          $ctx.Response.Close()
          return
        }
        if ($end -ge $length) { $end = $length - 1 }
        $partial = $true
      }

      $contentLength = [int64]($end - $start + 1)
      $encodedName = [Uri]::EscapeDataString($name)
      $ctx.Response.ContentType = 'video/mp4'
      $ctx.Response.Headers.Add('Accept-Ranges', 'bytes')
      $ctx.Response.Headers.Add('Cache-Control', 'private, no-cache')
      $ctx.Response.Headers.Add('X-Content-Type-Options', 'nosniff')
      $ctx.Response.Headers.Add('Content-Disposition', "inline; filename*=UTF-8''$encodedName")
      if ($partial) {
        $ctx.Response.StatusCode = 206
        $ctx.Response.Headers.Add('Content-Range', "bytes $start-$end/$length")
      }
      $ctx.Response.ContentLength64 = $contentLength
      if ($method -eq 'HEAD') { $ctx.Response.Close(); return }

      $stream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
      try {
        [void]$stream.Seek($start, [IO.SeekOrigin]::Begin)
        $buffer = New-Object byte[] 262144
        $remaining = $contentLength
        while ($remaining -gt 0) {
          $wanted = [int][Math]::Min([int64]$buffer.Length, $remaining)
          $read = $stream.Read($buffer, 0, $wanted)
          if ($read -le 0) { break }
          $ctx.Response.OutputStream.Write($buffer, 0, $read)
          $remaining -= $read
        }
      } finally { $stream.Dispose() }
    } catch {
      try { $ctx.Response.StatusCode = 500 } catch {}
    } finally {
      try { $ctx.Response.Close() } catch {}
    }
  }).AddArgument($context).AddArgument($filePath).AddArgument($displayName).AddArgument($rangeHeader).AddArgument($requestMethod)
  $handle = $worker.BeginInvoke()
  [void]$fileTransfers.Add([pscustomobject]@{ Worker=$worker; Handle=$handle })
}

function Clear-CompletedTransfers {
  for ($index = $fileTransfers.Count - 1; $index -ge 0; $index--) {
    $transfer = $fileTransfers[$index]
    if (!$transfer.Handle.IsCompleted) { continue }
    try { $transfer.Worker.EndInvoke($transfer.Handle) } catch {}
    $transfer.Worker.Dispose()
    $fileTransfers.RemoveAt($index)
  }
}

function Get-SafeFilename([string]$value) {
  $name = [IO.Path]::GetFileName($value)
  $name = ($name -replace '[\x00-\x1F<>:"/\\|?*]', '_').Trim().TrimEnd('.')
  if (!$name) { $name = 'video-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.mp4' }
  if ($name -notmatch '\.mp4$') { $name += '.mp4' }
  if ($name.Length -gt 140) { $name = $name.Substring(0, 136) + '.mp4' }
  $base = [IO.Path]::GetFileNameWithoutExtension($name)
  if ($base -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { $name = "_$name" }
  return $name
}

function Get-SafeFolderName([string]$value) {
  if (!$value) { return '' }
  $name = [IO.Path]::GetFileName($value)
  $name = ($name -replace '[\x00-\x1F<>:"/\\|?*]', '_').Trim().TrimEnd('.')
  if (!$name) { return '' }
  if ($name.Length -gt 80) { $name = $name.Substring(0, 80) }
  if ($name -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { $name = "_$name" }
  return $name
}

function Resolve-PageStreams([string]$pageUrl) {
  $uri = $null
  if (![Uri]::TryCreate($pageUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http','https')) { throw '网址格式不正确' }
  if (Test-BilibiliUrl $uri.AbsoluteUri) {
    return Resolve-BilibiliPage $uri.AbsoluteUri
  }
  if ($uri.AbsolutePath -match '\.(m3u8|mp4)$') {
    return [ordered]@{ pageUrl=$uri.AbsoluteUri; title=[IO.Path]::GetFileName($uri.AbsolutePath); streams=@($uri.AbsoluteUri); error='' }
  }
  $headers = @{ 'User-Agent'='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/140 Safari/537.36'; 'Accept'='text/html,application/xhtml+xml' }
  $requestUri = $uri.AbsoluteUri + ($(if ($uri.Query) { '&' } else { '?' }) + '_=' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
  $response = Invoke-WebRequest -Uri $requestUri -UseBasicParsing -MaximumRedirection 5 -TimeoutSec 20 -Headers $headers
  $effectiveUri = $uri
  try {
    if ($response.BaseResponse -and $response.BaseResponse.ResponseUri) { $effectiveUri = $response.BaseResponse.ResponseUri }
  } catch {}
  $content = [Net.WebUtility]::HtmlDecode([string]$response.Content).Replace('\/', '/')
  if ($content.Length -gt 12000000) { throw '页面内容过大，已停止解析' }
  $title = $uri.Host
  $titleMatch = [regex]::Match($content, '<title[^>]*>(.*?)</title>', 'IgnoreCase,Singleline')
  if ($titleMatch.Success) { $title = ([regex]::Replace($titleMatch.Groups[1].Value, '<[^>]+>', '')).Trim() }
  $found = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $matches = [regex]::Matches($content, '(?i)(?:https?://|//|/)[^"''\s<>]+?\.(?:m3u8|mp4)(?:\?[^"''\s<>]*)?')
  foreach ($match in $matches) {
    $candidate = $match.Value.TrimEnd(')',']','}',',',';')
    try {
      $resolved = [Uri]::new($effectiveUri, $candidate)
      if ($resolved.Scheme -in @('http','https')) { [void]$found.Add($resolved.AbsoluteUri) }
    } catch {}
  }
  return [ordered]@{ pageUrl=$effectiveUri.AbsoluteUri; title=$title; streams=@($found); error='' }
}

$streamRefreshCache = @{}
$streamRefreshTasks = @{}
$streamRefreshScript = @'
param([string]$pageUrl)
$ErrorActionPreference = 'Stop'
try {
  $uri = $null
  if (![Uri]::TryCreate($pageUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http','https')) {
    throw '来源页面地址不正确'
  }
  if ($uri.AbsolutePath -match '\.(m3u8|mp4)$') {
    [pscustomobject]@{ streams=@($uri.AbsoluteUri); error='' }
    return
  }
  $headers = @{ 'User-Agent'='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/140 Safari/537.36'; 'Accept'='text/html,application/xhtml+xml' }
  $requestUri = $uri.AbsoluteUri + ($(if ($uri.Query) { '&' } else { '?' }) + '_=' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
  $response = Invoke-WebRequest -Uri $requestUri -UseBasicParsing -MaximumRedirection 5 -TimeoutSec 20 -Headers $headers
  $effectiveUri = $uri
  try {
    if ($response.BaseResponse -and $response.BaseResponse.ResponseUri) { $effectiveUri = $response.BaseResponse.ResponseUri }
  } catch {}
  $content = [Net.WebUtility]::HtmlDecode([string]$response.Content).Replace('\/', '/')
  if ($content.Length -gt 12000000) { throw '页面内容过大，已停止解析' }
  $found = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $matches = [regex]::Matches($content, '(?i)(?:https?://|//|/)[^"''\s<>]+?\.(?:m3u8|mp4)(?:\?[^"''\s<>]*)?')
  foreach ($match in $matches) {
    $candidate = $match.Value.TrimEnd(')',']','}',',',';')
    try {
      $resolved = [Uri]::new($effectiveUri, $candidate)
      if ($resolved.Scheme -in @('http','https')) { [void]$found.Add($resolved.AbsoluteUri) }
    } catch {}
  }
  [pscustomobject]@{ streams=@($found); error='' }
} catch {
  [pscustomobject]@{ streams=@(); error=$_.Exception.Message }
}
'@
function Test-SignedStreamExpired([string]$url) {
  $uri = $null
  if (![Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or $uri.AbsolutePath -notmatch '\.m3u8$') { return $false }
  $match = [regex]::Match($uri.Query, '(?i)(?:^|[?&])auth_key=([^&]+)')
  if (!$match.Success) { return $false }
  $expiry = [long]0
  $prefix = ([Uri]::UnescapeDataString($match.Groups[1].Value) -split '-')[0]
  if (![long]::TryParse($prefix, [ref]$expiry)) { return $true }
  return $expiry -le [DateTimeOffset]::UtcNow.AddMinutes(2).ToUnixTimeSeconds()
}

function Complete-StreamRefreshTasks {
  foreach ($pageUrl in @($streamRefreshTasks.Keys)) {
    $task = $streamRefreshTasks[$pageUrl]
    if (!$task.Handle.IsCompleted) { continue }
    $streams = @()
    $error = ''
    try {
      $result = @($task.Worker.EndInvoke($task.Handle) | Where-Object { $_ -and $_.PSObject.Properties['streams'] } | Select-Object -First 1)
      if (!$result.Count) { throw '来源页面解析没有返回结果' }
      $streams = @($result[0].streams)
      $error = [string]$result[0].error
    } catch {
      $error = $_.Exception.Message
    }
    $streamRefreshCache[$pageUrl] = @{ fetchedAt=[DateTimeOffset]::UtcNow; streams=$streams; error=$error }
    try { $task.Worker.Dispose() } catch {}
    $streamRefreshTasks.Remove($pageUrl)
  }
}

function Start-StreamRefreshTask([string]$pageUrl) {
  if ($streamRefreshTasks.ContainsKey($pageUrl)) { return }
  if ($streamRefreshTasks.Count -ge $maxConcurrent) { return }
  $worker = [PowerShell]::Create()
  [void]$worker.AddScript($streamRefreshScript).AddArgument($pageUrl)
  $handle = $worker.BeginInvoke()
  $streamRefreshTasks[$pageUrl] = [pscustomobject]@{ Worker=$worker; Handle=$handle }
}

function Refresh-QueuedStreamUrl($job) {
  if (!(Test-SignedStreamExpired ([string]$job.url))) { return $true }
  $pageUrl = if ($job.sourcePage) { [string]$job.sourcePage } else { [string]$job.referer }
  if (!$pageUrl -or $pageUrl -eq $job.url) { throw '签名已过期，且任务没有可重新解析的来源页面' }

  $cached = $streamRefreshCache[$pageUrl]
  if (!$cached -or $cached.fetchedAt -lt [DateTimeOffset]::UtcNow.AddMinutes(-1)) {
    if (!$streamRefreshTasks.ContainsKey($pageUrl)) { Start-StreamRefreshTask $pageUrl }
    return $false
  }
  if ($cached.error) { throw "来源页面重新解析失败：$($cached.error)" }

  $oldUri = [Uri]::new([string]$job.url)
  $matches = @($cached.streams | Where-Object {
    $candidate = $null
    [Uri]::TryCreate([string]$_, [UriKind]::Absolute, [ref]$candidate) -and
      $candidate.AbsolutePath.Equals($oldUri.AbsolutePath, [StringComparison]::OrdinalIgnoreCase)
  })
  if (!$matches.Count) { throw '来源页面已找不到原视频流，无法刷新过期签名' }
  $sameHost = @($matches | Where-Object { ([Uri]::new([string]$_)).Host -eq $oldUri.Host })
  $freshUrl = if ($sameHost.Count) { [string]$sameHost[0] } elseif ($matches.Count -eq 1) { [string]$matches[0] } else { throw '来源页面存在多个同路径视频流，无法确定原视频' }
  if ($freshUrl -eq $job.url) { throw '来源页面没有提供更新的视频流地址' }
  if ($freshUrl -ne $job.url) {
    $job.url = $freshUrl
    Save-State
  }
  return $true
}

function Resolve-BilibiliPage([string]$pageUrl) {
  if (!(Test-Path -LiteralPath $ytDlp)) { throw '缺少 yt-dlp.exe，无法解析 Bilibili 视频' }
  $uri = $null
  if (!(Test-BilibiliUrl $pageUrl) -or ![Uri]::TryCreate($pageUrl, [UriKind]::Absolute, [ref]$uri)) { throw 'Bilibili 地址不正确' }
  $raw = & $ytDlp '--dump-single-json' '--flat-playlist' '--skip-download' '--no-warnings' $uri.AbsoluteUri 2>$null | Out-String
  if (!$raw.Trim()) { throw 'Bilibili 页面解析失败' }
  try { $data = $raw | ConvertFrom-Json } catch { throw 'Bilibili 返回内容无法解析' }
  $title = [string]$data.title
  if (!$title) { $title = $uri.AbsolutePath.Trim('/') }
  $streams = @()
  if ($data.entries) {
    foreach ($entry in @($data.entries)) {
      $entryUrl = [string]$entry.webpage_url
      if (!$entryUrl) { $entryUrl = [string]$entry.url }
      if ($entryUrl) { $streams += $entryUrl }
    }
  }
  if (!$streams.Count) { $streams = @($uri.AbsoluteUri) }
  return [ordered]@{ pageUrl=$uri.AbsoluteUri; title=$title; streams=$streams; error='' }
}

function Get-SafePagePreview([string]$pageUrl) {
  $uri = $null
  if (![Uri]::TryCreate($pageUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http','https')) { throw '来源页面地址不正确' }
  $headers = @{ 'User-Agent'='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/140 Safari/537.36'; 'Accept'='text/html,application/xhtml+xml' }
  $response = Invoke-WebRequest -Uri $uri.AbsoluteUri -UseBasicParsing -MaximumRedirection 5 -TimeoutSec 20 -Headers $headers
  $effectiveUri = $uri
  try {
    if ($response.BaseResponse -and $response.BaseResponse.ResponseUri) { $effectiveUri = $response.BaseResponse.ResponseUri }
  } catch {}
  $content = [string]$response.Content
  if (!$content) { throw '来源页面没有可预览的内容' }
  if ($content.Length -gt 12000000) { throw '页面内容过大，无法预览' }

  $title = $effectiveUri.Host
  $titleMatch = [regex]::Match($content, '<title[^>]*>(.*?)</title>', 'IgnoreCase,Singleline')
  if ($titleMatch.Success) {
    $title = [Net.WebUtility]::HtmlDecode(([regex]::Replace($titleMatch.Groups[1].Value, '<[^>]+>', '')).Trim())
  }

  $body = $content
  $articleMatch = [regex]::Match($content, '<article\b[^>]*>(.*?)</article\s*>', 'IgnoreCase,Singleline')
  if ($articleMatch.Success) {
    $body = $articleMatch.Groups[1].Value
  } else {
    $mainMatch = [regex]::Match($content, '<main\b[^>]*>(.*?)</main\s*>', 'IgnoreCase,Singleline')
    if ($mainMatch.Success) {
      $body = $mainMatch.Groups[1].Value
    } else {
      $bodyMatch = [regex]::Match($content, '<body\b[^>]*>(.*?)</body\s*>', 'IgnoreCase,Singleline')
      if ($bodyMatch.Success) { $body = $bodyMatch.Groups[1].Value }
    }
  }

  $body = [regex]::Replace($body, '(?is)<(?:script|style|iframe|frame|frameset|object|embed|applet|form|button|input|select|textarea|video|audio|source|track|canvas|svg|math|template|noscript|base)\b[^>]*>.*?</(?:script|style|iframe|frame|frameset|object|embed|applet|form|button|input|select|textarea|video|audio|source|track|canvas|svg|math|template|noscript|base)\s*>', '')
  $body = [regex]::Replace($body, '(?is)<(?:script|style|iframe|frame|frameset|object|embed|applet|form|button|input|select|textarea|video|audio|source|track|canvas|svg|math|template|noscript|base)\b[^>]*/?\s*>', '')
  $body = [regex]::Replace($body, '(?is)<meta\b[^>]*>', '')
  $body = [regex]::Replace($body, '(?is)\s(?:on[a-z]+|srcdoc|formaction|action|style)\s*=\s*(?:"[^"]*"|''[^'']*''|[^\s>]+)', '')
  $body = [regex]::Replace($body, '(?is)\s(?:href|xlink:href)\s*=\s*(?:"[^"]*"|''[^'']*''|[^\s>]+)', '')

  $baseForImages = $effectiveUri
  $body = [regex]::Replace($body, '(?is)\s(src|poster)\s*=\s*(["''])(.*?)\2', {
    param($match)
    $attribute = $match.Groups[1].Value.ToLowerInvariant()
    $candidate = [Net.WebUtility]::HtmlDecode($match.Groups[3].Value.Trim())
    try {
      $resolved = [Uri]::new($baseForImages, $candidate)
      if ($resolved.Scheme -in @('http','https')) {
        $encoded = [Net.WebUtility]::HtmlEncode($resolved.AbsoluteUri)
        return " $attribute=`"$encoded`""
      }
      if ($attribute -eq 'src' -and $candidate.StartsWith('data:image/', [StringComparison]::OrdinalIgnoreCase)) {
        $encoded = [Net.WebUtility]::HtmlEncode($candidate)
        return " src=`"$encoded`""
      }
    } catch {}
    return ''
  })

  $safeTitle = [Net.WebUtility]::HtmlEncode($title)
  $safeUrl = [Net.WebUtility]::HtmlEncode($effectiveUri.AbsoluteUri)
  return @"
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>$safeTitle</title>
  <style>
    :root { color-scheme: light; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; color: #20252b; background: #fff; }
    body { margin: 0; padding: 24px; line-height: 1.7; overflow-wrap: anywhere; }
    header { margin-bottom: 22px; padding-bottom: 16px; border-bottom: 1px solid #e1e4e8; }
    h1 { margin: 0 0 7px; font-size: 22px; line-height: 1.35; }
    .source { color: #68717d; font-size: 12px; }
    img { display: block; max-width: 100%; height: auto; margin: 16px auto; }
    table { display: block; max-width: 100%; overflow-x: auto; border-collapse: collapse; }
    th, td { padding: 7px 9px; border: 1px solid #d8dde3; }
    pre { max-width: 100%; overflow-x: auto; white-space: pre-wrap; }
    a { color: inherit; text-decoration: none; }
  </style>
</head>
<body>
  <header><h1>$safeTitle</h1><div class="source">$safeUrl</div></header>
  <main>$body</main>
</body>
</html>
"@
}

function Start-PagePreview($context, [string]$pageUrl) {
  $worker = [PowerShell]::Create()
  [void]$worker.AddScript({
    param($ctx, $url, $definition)
    try {
      . ([ScriptBlock]::Create("function Get-SafePagePreview {`n$definition`n}"))
      $html = Get-SafePagePreview $url
      $ctx.Response.ContentType = 'text/html; charset=utf-8'
      $ctx.Response.Headers.Add('Cache-Control', 'no-store')
      $ctx.Response.Headers.Add('X-Content-Type-Options', 'nosniff')
      $ctx.Response.Headers.Add('X-Frame-Options', 'SAMEORIGIN')
      $ctx.Response.Headers.Add('Referrer-Policy', 'no-referrer')
      $ctx.Response.Headers.Add('Content-Security-Policy', "default-src 'none'; img-src http: https: data:; style-src 'unsafe-inline'; object-src 'none'; frame-src 'none'; media-src 'none'; connect-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'self'; sandbox")
      $bytes = [Text.Encoding]::UTF8.GetBytes($html)
      $ctx.Response.ContentLength64 = $bytes.Length
      $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    } catch {
      try {
        $ctx.Response.StatusCode = 502
        $ctx.Response.ContentType = 'application/json; charset=utf-8'
        $bytes = [Text.Encoding]::UTF8.GetBytes((@{ error=$_.Exception.Message } | ConvertTo-Json -Compress))
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
      } catch {}
    } finally { try { $ctx.Response.Close() } catch {} }
  }).AddArgument($context).AddArgument($pageUrl).AddArgument(${function:Get-SafePagePreview}.ToString())
  $handle = $worker.BeginInvoke()
  [void]$fileTransfers.Add([pscustomobject]@{ Worker=$worker; Handle=$handle })
}

function Get-CategoryPageUrl([Uri]$sourceUri, [int]$page) {
  $segments = @($sourceUri.AbsolutePath.Trim('/').Split('/') | Where-Object { $_ })
  if ($segments.Count -gt 1 -and $segments[$segments.Count - 1] -match '^\d+$') {
    $segments = @($segments[0..($segments.Count - 2)])
  }
  if ($segments.Count -eq 0) { throw '分类页网址路径不正确' }
  $basePath = '/' + ($segments -join '/') + '/'
  $path = if ($page -le 1) { $basePath } else { $basePath + $page + '/' }
  $builder = [UriBuilder]::new($sourceUri)
  $builder.Path = $path
  $builder.Query = ''
  $builder.Fragment = ''
  return $builder.Uri.AbsoluteUri
}

function Get-CategoryPageData([string]$pageUrl) {
  $uri = $null
  if (![Uri]::TryCreate($pageUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http','https')) { throw '分类页网址格式不正确' }
  $headers = @{ 'User-Agent'='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/140 Safari/537.36'; 'Accept'='text/html,application/xhtml+xml' }
  $response = Invoke-WebRequest -Uri $uri.AbsoluteUri -UseBasicParsing -MaximumRedirection 5 -TimeoutSec 20 -Headers $headers
  $effectiveUri = $uri
  try {
    if ($response.BaseResponse -and $response.BaseResponse.ResponseUri) { $effectiveUri = $response.BaseResponse.ResponseUri }
  } catch {}
  $content = [Net.WebUtility]::HtmlDecode([string]$response.Content).Replace('\/', '/')
  if ($content.Length -gt 16000000) { throw '分类页内容过大，已停止解析' }
  $found = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $matches = [regex]::Matches($content, '(?is)href\s*=\s*["'']([^"'']+)["'']')
  foreach ($match in $matches) {
    $candidate = $match.Groups[1].Value.Trim()
    if (!$candidate -or $candidate.StartsWith('#') -or $candidate.StartsWith('javascript:', [StringComparison]::OrdinalIgnoreCase)) { continue }
    try {
      $resolved = [Uri]::new($effectiveUri, $candidate)
      if ($resolved.Scheme -notin @('http','https')) { continue }
      if ($resolved.AbsolutePath -notmatch '^/archives/[^/?#]+/?$') { continue }
      $builder = [UriBuilder]::new($resolved)
      $builder.Query = ''
      $builder.Fragment = ''
      [void]$found.Add($builder.Uri.AbsoluteUri)
    } catch {}
  }
  return [ordered]@{ url=$effectiveUri.AbsoluteUri; content=$content; articleUrls=@($found) }
}

function Parse-PageRange([string]$value) {
  $text = ([string]$value).Trim()
  if (!$text) { throw '请输入页码范围，例如 1-8' }
  $match = [regex]::Match($text, '^\s*(\d+)\s*(?:-\s*(\d+)\s*)?$')
  if (!$match.Success) { throw '页码范围格式不正确，请使用 1-8 或单个页码' }
  $start = [int]$match.Groups[1].Value
  $end = if ($match.Groups[2].Success) { [int]$match.Groups[2].Value } else { $start }
  if ($start -lt 1 -or $end -lt 1) { throw '页码必须从 1 开始' }
  if ($start -gt $end) { $swap = $start; $start = $end; $end = $swap }
  if (($end - $start + 1) -gt 100) { throw '一次最多扫描 100 页' }
  return [int[]]@($start, $end)
}

function Resolve-Category([string]$categoryUrl, [string]$rangeText) {
  $sourceUri = $null
  if (![Uri]::TryCreate($categoryUrl, [UriKind]::Absolute, [ref]$sourceUri) -or $sourceUri.Scheme -notin @('http','https')) { throw '分类页网址格式不正确' }
  $range = Parse-PageRange $rangeText
  $start = $range[0]; $end = $range[1]
  $seenArticles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $pageResults = @()
  $articleTotal = 0
  $streamTotal = 0
  $warnings = [Collections.Generic.List[string]]::new()
  for ($page = $start; $page -le $end; $page++) {
    $generatedUrl = Get-CategoryPageUrl $sourceUri $page
    $pageResult = [ordered]@{ page=$page; url=$generatedUrl; articleCount=0; articles=@(); error='' }
    try {
      $categoryData = Get-CategoryPageData $generatedUrl
      $articleResults = @()
      foreach ($articleUrl in @($categoryData.articleUrls)) {
        if (!$seenArticles.Add(([string]$articleUrl).TrimEnd('/'))) { continue }
        if ($seenArticles.Count -gt 5000) { [void]$warnings.Add('文章数量已达到 5000 条上限，后续链接已忽略'); break }
        try {
          $article = Resolve-PageStreams ([string]$articleUrl)
          $articleResults += [ordered]@{ url=$article.pageUrl; title=$article.title; streams=@($article.streams); error=[string]$article.error }
          $articleTotal++
          $streamTotal += @($article.streams).Count
        } catch {
          $articleResults += [ordered]@{ url=[string]$articleUrl; title=[string]$articleUrl; streams=@(); error=$_.Exception.Message }
          $articleTotal++
          [void]$warnings.Add("文章解析失败：$articleUrl")
        }
      }
      $pageResult.articleCount = $articleResults.Count
      $pageResult.articles = @($articleResults)
    } catch {
      $pageResult.error = $_.Exception.Message
      [void]$warnings.Add("第 $page 页扫描失败：$($_.Exception.Message)")
    }
    $pageResults += $pageResult
  }
  return [ordered]@{ pages=@($pageResults); articleCount=$articleTotal; streamCount=$streamTotal; warnings=@($warnings) }
}

function Read-Progress($job) {
  if (!(Test-Path $job.log)) { return }
  $content = (Get-Content $job.log -Tail 48 -ErrorAction SilentlyContinue) -join "`n"
  if (!$content) { return }
  if (!$job.duration -and $job.kind -ne 'bilibili') {
    $content = ((Get-Content $job.log -TotalCount 20 -ErrorAction SilentlyContinue) -join "`n") + "`n" + $content
  }
  $durationMatch = [regex]::Match([string]$content, 'Duration:\s*([0-9]+:[0-9]+:[0-9]+(?:\.[0-9]+)?)')
  if (!$job.duration -and $durationMatch.Success) {
    $job.duration = Convert-TimeToSeconds $durationMatch.Groups[1].Value
  }
  $timeMatches = [regex]::Matches($content, 'time=([0-9]+:[0-9]+:[0-9]+(?:\.[0-9]+)?)')
  if ($timeMatches.Count) {
    $job.time = $timeMatches[$timeMatches.Count - 1].Groups[1].Value
    $elapsed = Convert-TimeToSeconds $job.time
    if ($job.duration -gt 0) { $job.progress = [Math]::Min(99.5, [Math]::Round(($elapsed / $job.duration) * 100, 1)) }
  }
  $percentMatches = [regex]::Matches($content, '(?m)\[download\]\s+([0-9]+(?:\.[0-9]+)?)%')
  if ($percentMatches.Count) { $job.progress = [Math]::Min(99.5, [Math]::Round([double]$percentMatches[$percentMatches.Count - 1].Groups[1].Value, 1)) }
  $speedMatches = [regex]::Matches($content, 'speed=\s*([^\s]+)')
  if ($speedMatches.Count) { $job.speed = $speedMatches[$speedMatches.Count - 1].Groups[1].Value }
  if ($job.kind -eq 'bilibili') {
    $downloadSpeed = [regex]::Matches($content, '(?m)\[download\].*?\bat\s+([^\s]+/s)')
    if ($downloadSpeed.Count) { $job.speed = $downloadSpeed[$downloadSpeed.Count - 1].Groups[1].Value }
  }
}

function Sync-Jobs {
  $changed = $false
  foreach ($job in @($jobs.Values)) {
    if ($job.status -ne 'running' -or !$job.process) { continue }
    $job.process.Refresh()
    if (!$job.process.HasExited) { Read-Progress $job; continue }
    Read-Progress $job
    $outputExists = Test-Path $job.output
    $outputLength = if ($outputExists) { (Get-Item $job.output).Length } else { 0 }
    $logCompleted = $false
    if ($job.kind -ne 'bilibili' -and (Test-Path $job.log)) {
      $tail = (Get-Content $job.log -Tail 12 -ErrorAction SilentlyContinue) -join "`n"
      $logCompleted = $tail -match 'Lsize=' -or $tail -match 'muxing overhead:'
    }
    if ($outputLength -gt 0 -and ($job.process.ExitCode -eq 0 -or $logCompleted)) {
      $job.duration = Get-FileDuration $job.output
      if ($job.duration -gt 0 -and $job.duration -lt $minimumDurationSeconds) {
        Remove-Item -LiteralPath $job.output -Force -ErrorAction SilentlyContinue
        $job.status = 'filtered'; $job.size = 0; $job.time = '不足 1 分钟，已删除'; $job.progress = 100; $job.speed = ''
      } else {
        $job.status = 'done'; $job.size = (Get-Item $job.output).Length; $job.time = '完成'; $job.progress = 100
      }
    } else {
      $job.status = 'error'
      $errorLog = if ($job.kind -eq 'bilibili') { "$($job.log).err" } else { $job.log }
      $job.error = if (Test-Path $errorLog) { (Get-Content $errorLog -Tail 8) -join "`n" } else { '下载失败' }
    }
    $changed = $true
  }
  if ($changed) { Save-State }
}

function Start-QueuedJobs {
  Sync-Jobs
  Complete-StreamRefreshTasks
  $active = @($jobs.Values | Where-Object { $_.status -eq 'running' }).Count
  $slots = $maxConcurrent - $active
  if ($slots -le 0) { return }
  $queued = @($jobs.Values | Where-Object { $_.status -eq 'queued' } | Sort-Object created)
  $started = $false
  foreach ($job in $queued) {
    if ($slots -le 0) { break }
    try {
      if ($job.kind -ne 'bilibili' -and !(Refresh-QueuedStreamUrl $job)) { continue }
      if ($job.kind -eq 'bilibili' -or (Test-BilibiliUrl ([string]$job.url))) {
        if (!(Test-Path -LiteralPath $ytDlp)) { throw '缺少 yt-dlp.exe，无法下载 Bilibili 视频' }
        $ffmpegDir = Split-Path -Parent $ffmpeg
        $args = "--no-playlist --newline --progress --no-warnings -f `"bv*[vcodec^=avc1]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b`" --merge-output-format mp4 --ffmpeg-location `"$ffmpegDir`" -o `"$($job.output)`" `"$($job.url)`""
        $job.process = Start-Process -FilePath $ytDlp -ArgumentList $args -RedirectStandardOutput $job.log -RedirectStandardError "$($job.log).err" -PassThru -WindowStyle Hidden
      } else {
        $safeReferer = ([string]$job.referer) -replace '[\r\n"]', ''
        $args = "-hide_banner -nostdin -stats_period 1 -y -protocol_whitelist file,http,https,tcp,tls,crypto -headers "
        $args += "`"Referer: $safeReferer`r`n`" -i `"$($job.url)`" -map 0:v:0? -map 0:a:0? -c copy -movflags +faststart `"$($job.output)`""
        $job.process = Start-Process -FilePath $ffmpeg -ArgumentList $args -RedirectStandardError $job.log -PassThru -WindowStyle Hidden
      }
      $job.status = 'running'; $job.time = ''; $job.progress = 0; $job.speed = ''; $started = $true
      $slots--
    } catch { $job.status = 'error'; $job.error = $_.Exception.Message; $started = $true }
  }
  if ($started) { Save-State }
}

function Tick-Queue {
  $now = [DateTimeOffset]::UtcNow
  if (($now - $script:lastQueueTick).TotalMilliseconds -lt 750) { return }
  $script:lastQueueTick = $now
  Clear-CompletedTransfers
  Start-QueuedJobs
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add('http://127.0.0.1:17890/')
$listener.Start()
Write-Host "M3U8 MP4 Downloader helper 已启动：http://127.0.0.1:17890（最多 $maxConcurrent 个并发；短于 $minimumDurationSeconds 秒的视频自动删除）" -ForegroundColor Green
Write-Host '关闭此窗口即可停止。' -ForegroundColor DarkGray

while ($listener.IsListening) {
  Tick-Queue
  $pending = $listener.GetContextAsync()
  while (!$pending.Wait(250)) { Tick-Queue }
  $context = $pending.Result
  try {
    $origin = [string]$context.Request.Headers['Origin']
    $allowedOrigin = !$origin -or $origin -eq 'http://127.0.0.1:17890' -or $origin -match '^(chrome|edge|moz)-extension://'
    if (!$allowedOrigin) { Write-Json $context @{ error='origin not allowed' } 403; continue }
    if ($origin) { $context.Response.Headers.Add('Access-Control-Allow-Origin', $origin); $context.Response.Headers.Add('Vary', 'Origin') }
    if ($context.Request.HttpMethod -eq 'OPTIONS') {
      $context.Response.Headers.Add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
      $context.Response.Headers.Add('Access-Control-Allow-Headers', 'Content-Type')
      $context.Response.StatusCode = 204; $context.Response.Close(); continue
    }
    $path = $context.Request.Url.AbsolutePath
    if ($path -eq '/') { Write-StaticFile $context (Join-Path $uiDir 'index.html'); continue }
    if ($path -eq '/app.js') { Write-StaticFile $context (Join-Path $uiDir 'app.js'); continue }
    if ($path -eq '/style.css') { Write-StaticFile $context (Join-Path $uiDir 'style.css'); continue }
    if ($path -eq '/health' -and $context.Request.HttpMethod -eq 'GET') {
      Write-Json $context @{ ok=$true; service='m3u8-mp4-downloader'; maxConcurrent=$maxConcurrent; queued=@($jobs.Values | Where-Object status -eq 'queued').Count; running=@($jobs.Values | Where-Object status -eq 'running').Count }
      continue
    }
    if ($path -eq '/analyze' -and $context.Request.HttpMethod -eq 'POST') {
      $reader = [IO.StreamReader]::new($context.Request.InputStream, $context.Request.ContentEncoding)
      $body = $reader.ReadToEnd() | ConvertFrom-Json
      $urls = @($body.urls | Select-Object -First 20)
      if (!$urls.Count) { Write-Json $context @{ error='请至少输入一个网址' } 400; continue }
      $pages = @()
      foreach ($pageUrl in $urls) {
        try { $pages += Resolve-PageStreams ([string]$pageUrl) }
        catch { $pages += [ordered]@{ pageUrl=[string]$pageUrl; title=[string]$pageUrl; streams=@(); error=$_.Exception.Message } }
      }
      Write-Json $context @{ pages=$pages }; continue
    }
    if ($path -eq '/category-analyze' -and $context.Request.HttpMethod -eq 'POST') {
      $reader = [IO.StreamReader]::new($context.Request.InputStream, $context.Request.ContentEncoding)
      $body = $reader.ReadToEnd() | ConvertFrom-Json
      $categoryUrl = [string]$body.url
      $rangeText = [string]$body.range
      if (!$categoryUrl) { Write-Json $context @{ error='请输入分类页网址' } 400; continue }
      try {
        $result = Resolve-Category $categoryUrl $rangeText
        Write-Json $context $result
      } catch {
        Write-Json $context @{ error=$_.Exception.Message } 400
      }
      continue
    }
    if ($path -eq '/download' -and $context.Request.HttpMethod -eq 'POST') {
      $reader = [IO.StreamReader]::new($context.Request.InputStream, $context.Request.ContentEncoding)
      $body = $reader.ReadToEnd() | ConvertFrom-Json
      $url = [string]$body.url
      if ($url -notmatch '^https?://') { Write-Json $context @{ error='只允许 http/https 地址' } 400; continue }
      $filename = Get-SafeFilename ([string]$body.filename)
      $referer = [string]$body.referer
      if ($referer -and $referer -notmatch '^https?://') { Write-Json $context @{ error='来源页面地址不正确' } 400; continue }
      $folderName = Get-SafeFolderName ([string]$body.folder)
      $kind = if (Test-BilibiliUrl $url) { 'bilibili' } else { 'm3u8' }
      if (!$folderName -and $kind -eq 'bilibili') {
        $bvid = [regex]::Match($url, '(?i)/(BV[0-9A-Za-z]+)').Groups[1].Value
        if ($bvid) { $folderName = Get-SafeFolderName $bvid }
      }
      $outputDir = $jobsDir
      if ($folderName) {
        $outputDir = Join-Path $downloadsDir $folderName
        New-Item -ItemType Directory -Force $outputDir | Out-Null
        if ($referer) {
          $sourceLines = @("原网页：$referer")
          if ([string]$body.title) { $sourceLines += "标题：$([string]$body.title)" }
          $sourceLines | Set-Content -LiteralPath (Join-Path $outputDir 'source-url.txt') -Encoding UTF8
        }
        $videoUrlsPath = Join-Path $outputDir 'video-urls.txt'
        $knownUrls = if (Test-Path $videoUrlsPath) { @(Get-Content -LiteralPath $videoUrlsPath -ErrorAction SilentlyContinue) } else { @() }
        if ($knownUrls -notcontains $url) { $url | Add-Content -LiteralPath $videoUrlsPath -Encoding UTF8 }
      }
      if ($kind -eq 'bilibili' -and $folderName) {
        $videoUri = $null
        if ([Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$videoUri)) {
          $partMatch = [regex]::Match($videoUri.Query, '(?i)(?:^|[?&])p=(\d+)')
          if ($partMatch.Success) {
            $partNumber = [int]$partMatch.Groups[1].Value
            $stem = [IO.Path]::GetFileNameWithoutExtension($filename)
            if ($stem -notmatch "(?i)-p$partNumber$") {
              $filename = Get-SafeFilename ("$stem-p$partNumber.mp4")
            }
          }
        }
      }
      $id = [guid]::NewGuid().ToString('N')
      $outputName = if ($folderName) { $filename } else { "$id-$filename" }
      if ($kind -eq 'bilibili') {
        $stem = [IO.Path]::GetFileNameWithoutExtension($outputName)
        $candidate = $outputName
        $suffix = 2
        while ((Test-Path -LiteralPath (Join-Path $outputDir $candidate)) -or @($jobs.Values | Where-Object { $_.output -eq (Join-Path $outputDir $candidate) -and $_.status -notin @('deleted','canceled','filtered') }).Count) {
          $candidate = Get-SafeFilename ("$stem-$suffix.mp4")
          $suffix++
        }
        $outputName = $candidate
        $filename = $candidate
      }
      $job = @{ id=$id; url=$url; referer=$referer; sourcePage=$referer; kind=$kind; filename=$filename; output=(Join-Path $outputDir $outputName); log=(Join-Path $jobsDir "$id.log"); status='queued'; created=(Get-Date).ToString('o'); time='等待空闲任务槽'; error=''; size=0; downloaded=$false; duration=0; progress=0; speed='' }
      $jobs[$id] = $job; Save-State; Start-QueuedJobs
      Write-Json $context @{ id=$id; status=$job.status } 202; continue
    }
    if (($path -eq '/jobs' -or $path -eq '/status') -and $context.Request.HttpMethod -eq 'GET') {
      if ($path -eq '/jobs') {
        if (!$jobsResponseBytes -or ([DateTimeOffset]::UtcNow - $jobsResponseAt).TotalMilliseconds -ge 1000) {
          $list = @($jobs.Values | Sort-Object created -Descending | ForEach-Object { Public-Job $_ })
          $jobsResponseBytes = [Text.Encoding]::UTF8.GetBytes((@{ jobs=$list } | ConvertTo-Json -Compress -Depth 6))
          $jobsResponseAt = [DateTimeOffset]::UtcNow
        }
        Write-CachedJson $context $jobsResponseBytes; continue
      }
      $id = $context.Request.QueryString['id']
      if (!$jobs.ContainsKey($id)) { Write-Json $context @{ error='任务不存在' } 404; continue }
      Write-Json $context (Public-Job $jobs[$id]); continue
    }
    if ($path -eq '/media-list' -and $context.Request.HttpMethod -eq 'GET') {
      if (([DateTimeOffset]::UtcNow - $lastLibraryScan).TotalSeconds -ge 5) { Update-LibraryMedia; $lastLibraryScan = [DateTimeOffset]::UtcNow }
      $list = @(@($jobs.Values) + @($libraryMedia.Values) | Where-Object { $_.status -eq 'done' -and (Test-Path -LiteralPath $_.output) } | Sort-Object created -Descending | Select-Object -First 500 | ForEach-Object {
        [ordered]@{ id=$_.id; filename=$_.filename; size=$_.size; duration=$_.duration; created=$_.created; sourcePage=$_.sourcePage; mediaUrl="/media?id=$([Uri]::EscapeDataString($_.id))"; pagePreviewUrl=if ($_.sourcePage) { "/page-preview?id=$([Uri]::EscapeDataString($_.id))" } else { '' } }
      })
      Write-Json $context @{ media=$list }; continue
    }
    if ($path -eq '/media' -and $context.Request.HttpMethod -in @('GET','HEAD')) {
      $id = $context.Request.QueryString['id']
      $mediaItem = Get-MediaItem $id
      if (!$mediaItem -or $mediaItem.status -ne 'done' -or !(Test-Path -LiteralPath $mediaItem.output)) { Write-Json $context @{ error='已完成的视频不存在' } 404; continue }
      Start-MediaTransfer $context $mediaItem.output $mediaItem.filename
      continue
    }
    if ($path -eq '/page-preview' -and $context.Request.HttpMethod -eq 'GET') {
      $id = $context.Request.QueryString['id']
      $mediaItem = Get-MediaItem $id
      if (!$mediaItem -or ![string]$mediaItem.sourcePage) { Write-Json $context @{ error='任务没有来源页面' } 404; continue }
      Start-PagePreview $context ([string]$mediaItem.sourcePage)
      continue
    }
    if ($path -eq '/delete-media' -and $context.Request.HttpMethod -eq 'POST') {
      $reader = [IO.StreamReader]::new($context.Request.InputStream, $context.Request.ContentEncoding)
      $body = $reader.ReadToEnd() | ConvertFrom-Json
      $ids = @($body.ids | Select-Object -First 500)
      if (!$ids.Count) { Write-Json $context @{ error='请选择要永久删除的视频' } 400; continue }
      $deleted = 0
      $errors = @()
      foreach ($mediaId in $ids) {
        $id = [string]$mediaId
        $job = Get-MediaItem $id
        if (!$job) { $errors += "任务不存在：$id"; continue }
        if ($job.status -ne 'done') { $errors += "只能删除已完成视频：$($job.filename)"; continue }
        try {
          if (Test-Path -LiteralPath $job.output) { Remove-Item -LiteralPath $job.output -Force }
          if ($jobs.ContainsKey($id)) {
            $job.status = 'deleted'; $job.size = 0; $job.time = '已永久删除'; $job.progress = 100; $job.speed = ''
          } else { $libraryMedia.Remove($id) }
          $deleted++
        } catch { $errors += "$($job.filename)：$($_.Exception.Message)" }
      }
      Save-State
      Write-Json $context @{ deleted=$deleted; errors=$errors }; continue
    }
    if ($path -eq '/ack' -and $context.Request.HttpMethod -eq 'POST') {
      $id = $context.Request.QueryString['id']
      if (!$jobs.ContainsKey($id)) { Write-Json $context @{ error='任务不存在' } 404; continue }
      $jobs[$id].downloaded = $true; Save-State; Write-Json $context @{ ok=$true }; continue
    }
    if ($path -eq '/cancel' -and $context.Request.HttpMethod -eq 'POST') {
      $id = $context.Request.QueryString['id']
      if (!$jobs.ContainsKey($id)) { Write-Json $context @{ error='任务不存在' } 404; continue }
      $job = $jobs[$id]
      if ($job.process -and !$job.process.HasExited) { $job.process.Kill() }
      $job.status = 'canceled'; $job.time = ''; $job.speed = ''
      if (Test-Path $job.output) { Remove-Item -LiteralPath $job.output -Force -ErrorAction SilentlyContinue }
      Save-State; Write-Json $context @{ ok=$true }; continue
    }
    if ($path -eq '/retry' -and $context.Request.HttpMethod -eq 'POST') {
      $id = $context.Request.QueryString['id']
      if (!$jobs.ContainsKey($id)) { Write-Json $context @{ error='任务不存在' } 404; continue }
      $job = $jobs[$id]
      if ($job.status -notin @('error','canceled')) { Write-Json $context @{ error='只有失败或已取消任务可以重试' } 409; continue }
      if (Test-Path $job.output) { Remove-Item -LiteralPath $job.output -Force -ErrorAction SilentlyContinue }
      if (Test-Path $job.log) { Remove-Item -LiteralPath $job.log -Force -ErrorAction SilentlyContinue }
      if (Test-Path "$($job.log).err") { Remove-Item -LiteralPath "$($job.log).err" -Force -ErrorAction SilentlyContinue }
      $job.status = 'queued'; $job.error = ''; $job.time = '等待空闲任务槽'; $job.progress = 0; $job.speed = ''; $job.size = 0
      Save-State; Start-QueuedJobs; Write-Json $context @{ ok=$true }; continue
    }
    if ($path -eq '/open-folder' -and $context.Request.HttpMethod -eq 'POST') {
      $id = $context.Request.QueryString['id']
      $mediaItem = Get-MediaItem $id
      if (!$mediaItem -or !(Test-Path -LiteralPath $mediaItem.output)) { Write-Json $context @{ error='文件不存在' } 404; continue }
      Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$($mediaItem.output)`""
      Write-Json $context @{ ok=$true }; continue
    }
    if ($path -eq '/file' -and $context.Request.HttpMethod -eq 'GET') {
      $id = $context.Request.QueryString['id']
      $mediaItem = Get-MediaItem $id
      if (!$mediaItem -or $mediaItem.status -ne 'done' -or !(Test-Path -LiteralPath $mediaItem.output)) { Write-Json $context @{ error='文件不存在' } 404; continue }
      Start-FileTransfer $context $mediaItem.output $mediaItem.filename
      continue
    }
    Write-Json $context @{ error='not found' } 404
  } catch { try { Write-Json $context @{ error=$_.Exception.Message } 500 } catch {} }
}
