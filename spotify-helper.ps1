# Spotify "now playing" helper for the wallpaper.
# Reads the Windows media session of Spotify and serves it on http://localhost:5757
#   GET /state          -> JSON with track, status, timeline
#   GET /art?id=N       -> album art image
#   GET /lyrics         -> lyrics of the current track from lrclib.net (LRC text)
#   GET /cmd/<action>   -> toggle | play | pause | next | prev | shuffle | repeat | seek?ms= | volume?v=0..1
#   GET /<file>         -> static files from ..\wallpaper (handy for testing in a browser)

param(
    [int]$Port = 5757,
    [string]$AppFilter = 'Spotify',
    [string]$ProcessName = 'Spotify'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
Add-Type -Path (Join-Path $PSScriptRoot 'AppVolume.cs')

$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType = WindowsRuntime]
$null = [Windows.Media.MediaPlaybackAutoRepeatMode, Windows.Media, ContentType = WindowsRuntime]

$asTaskGeneric = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
} | Select-Object -First 1

$AsStreamForRead = [System.IO.WindowsRuntimeStreamExtensions].GetMethod('AsStreamForRead', [Type[]]@([Windows.Storage.Streams.IInputStream]))

function Await($op, [Type]$type) {
    $task = $asTaskGeneric.MakeGenericMethod($type).Invoke($null, @($op))
    if (-not $task.Wait(4000)) { throw 'WinRT call timed out' }
    $task.Result
}

$ManagerType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]
$PropsType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties]
$StreamType = [Windows.Storage.Streams.IRandomAccessStreamWithContentType]

$script:manager = $null
function Get-Manager {
    if (-not $script:manager) { $script:manager = Await ($ManagerType::RequestAsync()) $ManagerType }
    $script:manager
}

function Get-Session {
    foreach ($s in (Get-Manager).GetSessions()) {
        if ($s.SourceAppUserModelId -like "*$AppFilter*") { return $s }
    }
    $null
}

# album art cache
$script:trackKey = ''
$script:artBytes = $null
$script:artType = 'image/jpeg'
$script:artId = 0
$script:artRefreshes = 0

function Update-Art($props) {
    # Spotify sometimes publishes the new cover a moment after the new title,
    # so re-read the thumbnail a few times after every track change.
    if ($script:artRefreshes -le 0) { return }
    $script:artRefreshes--
    if (-not $props.Thumbnail) { return }
    try {
        $ws = Await ($props.Thumbnail.OpenReadAsync()) $StreamType
        # PowerShell can't bind the WinRT stream itself, reflection can
        $net = $AsStreamForRead.Invoke($null, @($ws))
        $ms = New-Object System.IO.MemoryStream
        $net.CopyTo($ms)
        $net.Dispose()
        $bytes = $ms.ToArray()
        if ($bytes.Length -eq 0) { return }
        $same = $script:artBytes -and
            [Convert]::ToBase64String($script:artBytes) -eq [Convert]::ToBase64String($bytes)
        if (-not $same) {
            $script:artBytes = $bytes
            $script:artType = if ($bytes[0] -eq 0x89) { 'image/png' } else { 'image/jpeg' }
            $script:artId++
        }
    } catch { }
}

function Get-State {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $s = Get-Session
    if (-not $s) { return @{ active = $false; now = $now } }

    $props = Await ($s.TryGetMediaPropertiesAsync()) $PropsType
    $info = $s.GetPlaybackInfo()
    $tl = $s.GetTimelineProperties()

    $key = "$($props.Title)|$($props.Artist)"
    if ($key -ne $script:trackKey) {
        $script:trackKey = $key
        $script:artRefreshes = 4
    }
    Update-Art $props

    $status = [string]$info.PlaybackStatus
    @{
        active   = [bool]$props.Title
        playing  = $status -eq 'Playing'
        status   = $status
        title    = $props.Title
        artist   = $props.Artist
        album    = $props.AlbumTitle
        position = [long]$tl.Position.TotalMilliseconds
        duration = [long]($tl.EndTime - $tl.StartTime).TotalMilliseconds
        updated  = $tl.LastUpdatedTime.ToUnixTimeMilliseconds()
        now      = $now
        shuffle  = [bool]$info.IsShuffleActive
        repeat   = [string]$info.AutoRepeatMode
        artId    = $(if ($script:artBytes) { $script:artId } else { 0 })
        volume   = [math]::Round([WallpaperAudio.AppVolume]::Get($ProcessName), 3)
    }
}

# ---------- lyrics (lrclib.net, free, no account) ----------
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$script:lyricsCache = @{}      # track key -> result
$script:lyricsFailedAt = @{}   # track key -> time of last network failure

# returns parsed JSON, or $null on 404
function Get-Json([string]$url) {
    # lrclib regularly answers "server busy" (503) for a moment, so try a few times
    for ($attempt = 1; ; $attempt++) {
        try {
            $r = Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 8 -Headers @{ 'User-Agent' = 'spotify-wallpaper (Wallpaper Engine)' }
            break
        } catch [System.Net.WebException] {
            $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($code -eq 404) { return $null }
            if ($attempt -ge 3 -or ($code -ne 0 -and $code -lt 500)) { throw }
            Start-Sleep -Milliseconds (400 * $attempt)
        }
    }
    # lrclib sends no charset, so decode as UTF-8 ourselves
    $json = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json
    # PS 5.1 emits a JSON array as one object; unroll it so callers get the items
    $json | ForEach-Object { $_ }
}

function Get-CleanTitle([string]$t) {
    $t = $t -replace '\s*[\(\[](feat\.|ft\.|with )[^\)\]]*[\)\]]', ''
    $t = $t -replace '\s+-\s+.*(remaster|version|edit|live|mono|stereo|mix).*$', ''
    $t.Trim()
}

function Get-Lyrics {
    $s = Get-Session
    if (-not $s) { return @{ found = $false } }
    $props = Await ($s.TryGetMediaPropertiesAsync()) $PropsType
    $key = "$($props.Title)|$($props.Artist)"
    if ($script:lyricsCache.ContainsKey($key)) { return $script:lyricsCache[$key] }

    # don't hammer lrclib when it's down: wait a bit after a failure
    # (shorter than the wallpaper's own retry delay, so its retry gets through)
    $failed = $script:lyricsFailedAt[$key]
    if ($failed -and ((Get-Date) - $failed).TotalSeconds -lt 15) { return @{ key = $key; found = $false; retry = $true } }

    $tl = $s.GetTimelineProperties()
    $dur = [int]($tl.EndTime - $tl.StartTime).TotalSeconds
    $artist = ($props.Artist -split ',\s*')[0]
    $e = { param($v) [Uri]::EscapeDataString([string]$v) }
    try {
        # the exact lookup is only a shortcut; if it fails the search below still can find it
        $r = $null
        try {
            $r = Get-Json ("https://lrclib.net/api/get?track_name=$(& $e $props.Title)&artist_name=$(& $e $artist)" +
                "&album_name=$(& $e $props.AlbumTitle)&duration=$dur")
        } catch { }
        if (-not $r -or -not ($r.syncedLyrics -or $r.instrumental)) {
            $list = @(Get-Json "https://lrclib.net/api/search?track_name=$(& $e (Get-CleanTitle $props.Title))&artist_name=$(& $e $artist)")
            # prefer synced lyrics of a version with about the same length
            $best = $list | Where-Object { $_.syncedLyrics -or $_.plainLyrics } |
                Sort-Object { [bool]$_.syncedLyrics }, { -[math]::Abs($_.duration - $dur) } -Descending |
                Select-Object -First 1
            if ($best -and ($best.syncedLyrics -or -not $r)) { $r = $best }
        }
        if ($script:lyricsCache.Count -gt 200) { $script:lyricsCache.Clear() }
        $res = @{
            key          = $key
            found        = [bool]$r
            synced       = $(if ($r) { $r.syncedLyrics })
            plain        = $(if ($r) { $r.plainLyrics })
            instrumental = $(if ($r) { [bool]$r.instrumental } else { $false })
        }
        $script:lyricsCache[$key] = $res
        $res
    } catch {
        $script:lyricsFailedAt[$key] = Get-Date
        @{ key = $key; found = $false; retry = $true; error = $_.Exception.Message }
    }
}

function Invoke-MediaCommand([string]$action, $query) {
    # volume goes through the Windows mixer, not the media session
    if ($action -eq 'volume') { return [WallpaperAudio.AppVolume]::Set($ProcessName, [float]$query['v']) }

    $s = Get-Session
    if (-not $s) { return $false }
    $op = switch ($action) {
        'toggle'  { $s.TryTogglePlayPauseAsync() }
        'play'    { $s.TryPlayAsync() }
        'pause'   { $s.TryPauseAsync() }
        'next'    { $s.TrySkipNextAsync() }
        'prev'    { $s.TrySkipPreviousAsync() }
        'shuffle' { $s.TryChangeShuffleActiveAsync(-not [bool]$s.GetPlaybackInfo().IsShuffleActive) }
        'repeat'  {
            $next = switch ([string]$s.GetPlaybackInfo().AutoRepeatMode) {
                'None' { 'List' } 'List' { 'Track' } default { 'None' }
            }
            $s.TryChangeAutoRepeatModeAsync([Windows.Media.MediaPlaybackAutoRepeatMode]$next)
        }
        'seek'    { $s.TryChangePlaybackPositionAsync([long]$query['ms'] * 10000) }
        default   { $null }
    }
    if (-not $op) { return $false }
    Await $op ([bool])
}

$mime = @{
    '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript'; '.css' = 'text/css'
    '.json' = 'application/json'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'
    '.png' = 'image/png'; '.webp' = 'image/webp'; '.gif' = 'image/gif'; '.svg' = 'image/svg+xml'
}
$staticRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\wallpaper'))

function Send($ctx, [byte[]]$bytes, [string]$type, [int]$code = 200) {
    $r = $ctx.Response
    $r.StatusCode = $code
    $r.ContentType = $type
    $r.Headers['Access-Control-Allow-Origin'] = '*'
    $r.Headers['Cache-Control'] = 'no-store'
    $r.ContentLength64 = $bytes.Length
    $r.OutputStream.Write($bytes, 0, $bytes.Length)
    $r.OutputStream.Close()
}
function SendJson($ctx, $obj) {
    Send $ctx ([Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Compress))) 'application/json; charset=utf-8'
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
try { $listener.Start() } catch { Write-Host "Port $Port is already in use (helper already running?)"; exit 1 }
Write-Host "Spotify wallpaper helper running on http://localhost:$Port/"

while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    try {
        $path = $ctx.Request.Url.AbsolutePath
        if ($path -eq '/state') {
            SendJson $ctx (Get-State)
        } elseif ($path -eq '/lyrics') {
            SendJson $ctx (Get-Lyrics)
        } elseif ($path -eq '/art') {
            if ($script:artBytes) { Send $ctx $script:artBytes $script:artType }
            else { Send $ctx ([byte[]]@()) 'text/plain' 404 }
        } elseif ($path -like '/cmd/*') {
            $ok = Invoke-MediaCommand ($path.Substring(5)) $ctx.Request.QueryString
            SendJson $ctx @{ ok = [bool]$ok }
        } else {
            $rel = [Uri]::UnescapeDataString($path.TrimStart('/'))
            if (-not $rel) { $rel = 'index.html' }
            $file = [System.IO.Path]::GetFullPath((Join-Path $staticRoot $rel))
            if ($file.StartsWith($staticRoot) -and (Test-Path $file -PathType Leaf)) {
                $type = $mime[[System.IO.Path]::GetExtension($file).ToLower()]
                if (-not $type) { $type = 'application/octet-stream' }
                Send $ctx ([System.IO.File]::ReadAllBytes($file)) $type
            } else {
                Send $ctx ([Text.Encoding]::UTF8.GetBytes('not found')) 'text/plain' 404
            }
        }
    } catch {
        $script:manager = $null
        try { SendJson $ctx @{ active = $false; error = $_.Exception.Message } } catch { }
    }
}
