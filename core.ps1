# Conversion core, works in Windows PowerShell 5.1 and PowerShell 7.
# The caller provides the UI: Show-Options, Update-Progress, Show-Done and Show-Error.
$ErrorActionPreference = 'Stop'
$script:root = $PSScriptRoot
$script:tmp = $null

$script:locale = if ($env:EXPLORER_CONVERT_LANG) { $env:EXPLORER_CONVERT_LANG } else { [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName }
$script:tr = ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'lang.json')) | ConvertFrom-Json).($script:locale)
function T([string]$text) { if ($script:tr.$text) { $script:tr.$text } else { $text } }

# Digits are padded so that page2 sorts before page10
function Get-NaturalKey([string]$name) {
    [regex]::Replace($name, '\d+', { param($m) $m.Value.PadLeft(20, '0') })
}

function Get-PageOrder([string[]]$paths) {
    $paths | Sort-Object -Property { Get-NaturalKey ($_ -replace '^.*[\\/]') }, { $_ }
}

# Batch folders are written by launch.js
function Read-Batch([string]$folder) {
    # Leftovers of launchers killed earlier (logoff, crash) must not join a new selection
    $oldest = [DateTime]::UtcNow.AddMinutes(-10)
    $paths = foreach ($file in [IO.Directory]::GetFiles($folder)) {
        if ([IO.File]::GetLastWriteTimeUtc($file) -ge $oldest) { [IO.File]::ReadAllText($file) }
    }
    [IO.Directory]::Delete($folder, $true)
    @(Get-PageOrder $paths)
}

# A terminal opened before an installation has the old PATH, and some installers do not touch PATH at all
function Add-SearchPath {
    $dirs = @('Machine', 'User' | ForEach-Object { "$([Environment]::GetEnvironmentVariable('Path', $_))" -split ';' })
    foreach ($base in $env:ProgramFiles, ${env:ProgramFiles(x86)}) {
        if (-not $base) { continue }
        $dirs += "$base\LibreOffice\program", "$base\Tesseract-OCR", "$base\Calibre2"
        foreach ($gs in @(Get-Item "$base\gs\gs*\bin" -ErrorAction Ignore)) { $dirs += $gs.FullName }
    }
    if ($env:LOCALAPPDATA) {
        foreach ($py in @(Get-Item "$env:LOCALAPPDATA\Programs\Python\Python3*\Scripts" -ErrorAction Ignore)) { $dirs += $py.FullName }
    }
    $known = $env:PATH -split ';'
    foreach ($dir in $dirs) {
        if ($dir -and $dir -notin $known -and [IO.Directory]::Exists($dir)) { $known += $dir }
    }
    $env:PATH = $known -join ';'
}
if ($env:OS -eq 'Windows_NT' -and -not $env:EXPLORER_CONVERT_NO_SEARCH) { Add-SearchPath }

function Find-Tool([string]$name) {
    $names = if ($name -eq 'gs') { 'gswin64c', 'gswin32c', 'gs' } else { , $name }
    foreach ($n in $names) {
        $found = Get-Command $n -CommandType Application -ErrorAction Ignore | Select-Object -First 1
        if ($found) { return $found.Source }
    }
}

function Get-ActionTools([string]$kind, [string]$format) {
    switch ($kind) {
        { $_ -in 'video', 'audio' } { 'ffmpeg', 'ffprobe' }
        image {
            'magick'
            if ($format -eq 'avif') { 'ffmpeg' }
            if ($format -eq 'pdf-one') { 'pdfunite' }
        }
        pdf {
            switch ($format) {
                txt { 'pdftotext' }
                merge { 'pdfunite' }
                split { 'pdfseparate' }
                compress { 'gs' }
                ocr { 'ocrmypdf', 'tesseract' }
                default { 'pdftoppm' }
            }
        }
        office { 'soffice' }
        ebook { 'ebook-convert' }
    }
}

function Assert-Tool {
    foreach ($name in $args) {
        if (-not (Find-Tool $name)) { throw [ApplicationException]"$(T 'Not installed'): $name" }
    }
}

# Quote one argument the way CommandLineToArgvW reads it; PowerShell 5.1 has no ArgumentList
function Get-QuotedArgument([string]$text) {
    if ($text -and $text -notmatch '[\s"]') { return $text }
    '"' + ($text -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Stop-Tree($process) {
    if ($PSVersionTable.PSVersion.Major -ge 6) { $process.Kill($true) }
    else { & "$env:SystemRoot\System32\taskkill.exe" /T /F /PID $process.Id 2>&1 | Out-Null }
    [void]$process.WaitForExit(10000)
}

# stdout goes to $OutFile or $script:stdout, stderr to $script:log
function Invoke-Tool([string]$name, [string[]]$arguments, [string]$OutFile) {
    $psi = New-Object Diagnostics.ProcessStartInfo (Find-Tool $name)
    $psi.Arguments = @($arguments | ForEach-Object { Get-QuotedArgument $_ }) -join ' '
    $psi.WorkingDirectory = $script:tmp
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $psi.RedirectStandardOutput = $psi.RedirectStandardError = $true
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $script:log = $script:stdout = ''
    $sink = $null
    $process = $null
    try {
        $sink = if ($OutFile) { [IO.File]::Create($OutFile) } else { New-Object IO.MemoryStream }
        $process = [Diagnostics.Process]::Start($psi)
        $process.StandardInput.Close()
        $out = $process.StandardOutput.BaseStream.CopyToAsync($sink)
        $err = $process.StandardError.ReadToEndAsync()
        while (-not $process.WaitForExit(50)) { Step-Progress }
        if (-not $out.Wait(10000)) { throw "$name did not close its output" }
        if ($err.Wait(10000)) { $script:log = $err.Result }
        if (-not $OutFile) { $script:stdout = [Text.Encoding]::UTF8.GetString($sink.ToArray()) }
        return $process.ExitCode
    } finally {
        if ($process -and -not $process.HasExited) { Stop-Tree $process }
        if ($sink) { $sink.Dispose() }
        if ($process) { $process.Dispose() }
    }
}

function Invoke-Ffmpeg([string[]]$arguments) {
    $progress = Join-Path $script:tmp 'progress'
    if ([IO.File]::Exists($progress)) { [IO.File]::Delete($progress) }
    0 -eq (Invoke-Tool ffmpeg (@('-nostdin', '-y', '-v', 'error', '-progress', 'progress') + $arguments))
}

function Invoke-Probe([string[]]$arguments) {
    [void](Invoke-Tool ffprobe (@('-v', 'error') + $arguments + @('-of', 'csv=p=0', '-i', $script:file)))
    ($script:stdout -split "`r?`n")[0]
}

function Step-Progress {
    $pct = 0
    if ($script:clipUs -gt 0) {
        $path = Join-Path $script:tmp 'progress'
        if ([IO.File]::Exists($path)) {
            $stream = New-Object IO.FileStream $path, 'Open', 'Read', 'ReadWrite, Delete'
            $reader = New-Object IO.StreamReader $stream
            try { $found = [regex]::Matches($reader.ReadToEnd(), '(?m)^out_time_us=(\d+)') } finally { $reader.Dispose() }
            if ($found.Count) { $pct = [double]$found[$found.Count - 1].Groups[1].Value * $script:passSpan / $script:clipUs }
        }
        $pct = [Math]::Min(99, [Math]::Floor($pct + $script:passBase))
    }
    $text = "$($script:index + 1) $(T 'of') $($script:total): $($script:name)"
    if ($script:clipUs -gt 0) { $text += " ($pct%)" }
    if (Update-Progress ([int][Math]::Floor(($script:index * 100 + $pct) / $script:total)) $text) {
        throw [OperationCanceledException]''
    }
}

function Get-Formats([string]$kind) {
    switch ($kind) {
        video { 'h264', 'h265', 'av1', 'vp9', 'gif', 'mp3', 'copy-mp4', 'copy-mkv' }
        audio { 'mp3', 'm4a', 'opus', 'ogg', 'flac', 'wav' }
        image { 'jpg', 'png', 'webp', 'avif', 'jxl', 'tiff', 'gif', 'bmp', 'ico', 'pdf', 'pdf-one' }
        pdf { 'png', 'jpg', 'txt' }
        office { 'pdf', 'docx', 'odt', 'xlsx', 'ods', 'csv', 'pptx', 'odp' }
        ebook { 'epub', 'mobi', 'azw3', 'pdf', 'txt' }
    }
}

# Menu-only, not offered in the form
function Get-Actions([string]$kind) {
    switch ($kind) {
        video { 'mute', 'rotate-left', 'rotate-right', 'srt' }
        pdf { 'merge', 'split', 'compress', 'ocr' }
    }
}

# Some ffmpeg builds lack the patented encoders
function Assert-Encoder([string]$kind) {
    $encoders = @{
        h264 = 'libx264'; h265 = 'libx265'; av1 = 'libsvtav1'; vp9 = 'libvpx-vp9'; mp3 = 'libmp3lame'; opus = 'libopus'
        ogg = 'libvorbis'; avif = 'libaom-av1'; 'rotate-left' = 'libx264'; 'rotate-right' = 'libx264'
    }
    $encoder = $encoders[$script:format]
    if (-not $encoder -or $kind -notin 'video', 'audio', 'image') { return }
    if (0 -eq (Invoke-Tool ffmpeg '-hide_banner', '-encoders') -and $script:stdout -notmatch " $encoder ") {
        throw [ApplicationException]"$(T 'ffmpeg was built without an encoder'): $encoder"
    }
}

function Get-Label([string]$kind, [string]$format) {
    switch ($format) {
        h264 { 'MP4 (H.264)' }
        h265 { 'MP4 (H.265)' }
        av1 { 'MP4 (AV1)' }
        vp9 { 'WebM (VP9)' }
        copy-mp4 { "MP4 ($(T 'no re-encoding'))" }
        copy-mkv { "MKV ($(T 'no re-encoding'))" }
        mp3 { if ($kind -eq 'video') { "MP3 ($(T 'audio only'))" } else { 'MP3' } }
        m4a { 'M4A (AAC)' }
        opus { 'Opus' }
        ogg { 'OGG (Vorbis)' }
        webp { 'WebP' }
        pdf-one { "PDF ($(T 'one file'))" }
        default { $format.ToUpperInvariant() }
    }
}

# [[H:]M:]S[.frac] as microseconds
function ConvertTo-Us([string]$text) {
    if ($text -notmatch '^(?:(?:(?<h>[0-9]{1,3}):)?(?<m>[0-9]{1,4}):)?(?<s>[0-9]{1,6})(?:\.(?<f>[0-9]{1,6}))?$') {
        throw [ApplicationException](T 'Invalid time')
    }
    (([long]$Matches.h * 60 + [long]$Matches.m) * 60 + [long]$Matches.s) * 1000000 + [long]"$($Matches.f)".PadRight(6, '0')
}

function Get-Choice([string]$kind, [int]$count) {
    $formats = @(Get-Formats $kind)
    $path = Join-Path $script:root "settings-$kind"
    $saved = @{ Format = $formats[0]; Quality = 1; Height = 0; Gpu = $false; Strip = $false }
    if ([IO.File]::Exists($path)) {
        $f = [IO.File]::ReadAllText($path).Trim() -split '\|'
        if ($f[0] -in $formats) { $saved.Format = $f[0] }
        if ($f[1] -in '0', '1', '2') { $saved.Quality = [int]$f[1] }
        if ($f[2] -in '1080', '720', '480') { $saved.Height = [int]$f[2] }
        $saved.Gpu = $f[3] -eq 'True'
        $saved.Strip = $f[4] -eq 'True'
    }
    $choice = Show-Options $kind $formats $saved $count
    if ($choice) {
        [IO.File]::WriteAllText($path, ($choice.Format, $choice.Quality, $choice.Height, $choice.Gpu, $choice.Strip -join '|'))
    }
    $choice
}

# TODO: QSV and AMF reuse the NVENC quality values, not tuned on real cards
function Get-GpuArguments([string]$family, [int]$cq) {
    switch ($family) {
        nvenc { '-c:v', "$($script:codec)_nvenc", '-preset', 'p5', '-rc', 'vbr', '-cq', "$cq", '-b:v', '0', '-pix_fmt', 'yuv420p' }
        qsv { '-c:v', "$($script:codec)_qsv", '-global_quality', "$cq", '-pix_fmt', 'nv12' }
        amf { '-c:v', "$($script:codec)_amf", '-rc', 'cqp', '-qp_i', "$cq", '-qp_p', "$cq", '-pix_fmt', 'yuv420p' }
    }
}

function Find-Gpu {
    foreach ($family in 'nvenc', 'qsv', 'amf') {
        $arguments = @('-nostdin', '-v', 'error', '-f', 'lavfi', '-i', 'color=s=640x360:d=0.1') + (Get-GpuArguments $family 24) + @('-f', 'null', '-')
        if (0 -eq (Invoke-Tool ffmpeg $arguments)) { return $family }
    }
}

function Convert-ToSize([string[]]$source, [string]$filter) {
    if ($script:clipUs -le 0) { $script:err = 'Unknown duration'; return $false }
    $limit = [long]$script:opt.Size * 1000000
    $total = [Math]::Floor([decimal]$limit * 8 * 96 / 100 * 1000 / $script:clipUs)
    $audio = if ($total -lt 400) { 48 } else { 96 }
    if (-not (Invoke-Probe '-select_streams', 'a', '-show_entries', 'stream=index')) { $audio = 0 }
    $video = $total - $audio
    if ($video -lt 40) { $script:err = 'File is too long for this size'; return $false }
    $sourceKbps = [Math]::Max(40, [Math]::Floor([decimal](New-Object IO.FileInfo $script:file).Length * 8 * 1000 / $script:durationUs))
    $video = [Math]::Min($video, $sourceKbps)
    $audioRate = if ($audio) { $audio } else { 96 }
    foreach ($try in 1..4) {
        foreach ($p in 1, 2) {
            $script:passBase = ($p - 1) * 50
            $script:passSpan = 50
            # Relative statistics paths: a drive colon would split -x265-params
            $codec = switch ($script:format) {
                h264 { '-c:v', 'libx264', '-pass', "$p", '-passlogfile', 'pass', '-c:a', 'aac', '-movflags', '+faststart' }
                h265 { '-c:v', 'libx265', '-x265-params', "log-level=error:pass=${p}:stats=x265", '-tag:v', 'hvc1', '-c:a', 'aac', '-movflags', '+faststart' }
                vp9 { '-c:v', 'libvpx-vp9', '-row-mt', '1', '-cpu-used', '4', '-pass', "$p", '-passlogfile', 'pass', '-c:a', 'libopus' }
            }
            $arguments = $source + $codec + @('-vf', $filter, '-pix_fmt', 'yuv420p', '-b:v', "${video}k", '-b:a', "${audioRate}k", '-sn')
            $arguments += if ($p -eq 1) { '-an', '-f', 'null', '-' } else { , $script:part }
            if (-not (Invoke-Ffmpeg $arguments)) { return $false }
        }
        $actual = (New-Object IO.FileInfo $script:part).Length
        if ($actual -le $limit) { return $true }
        $video = [Math]::Floor([Math]::Floor($video * $limit / $actual) * 93 / 100)
        if ($video -lt 20) { break }
    }
    $script:err = 'Could not fit the target size'
    $false
}

function Convert-Media {
    $o = $script:opt
    $q = $o.Quality
    $script:durationUs = [long]0
    if ((Invoke-Probe '-show_entries', 'format=duration') -match '^([0-9]+)\.([0-9]{6})$') { $script:durationUs = [long]($Matches[1] + $Matches[2]) }
    if ($script:durationUs -gt 0 -and $o.StartUs -ge $script:durationUs) { $script:err = 'Start is past the end'; return $false }
    $clip = $script:durationUs
    if ($o.EndUs -gt 0 -and ($clip -eq 0 -or $o.EndUs -lt $clip)) { $clip = $o.EndUs }
    if ($clip -gt 0) { $script:clipUs = $clip - $o.StartUs }

    $source = @()
    if ($o.StartUs -gt 0) { $source += '-ss', "$($o.StartUs)us" }
    if ($o.EndUs -gt 0) { $source += '-t', "$($o.EndUs - $o.StartUs)us" }
    $source += '-i', $script:file
    if ($o.Strip) { $source += '-map_metadata', '-1', '-map_metadata:s', '-1', '-map_chapters', '-1' }

    $vf = 'pad=ceil(iw/2)*2:ceil(ih/2)*2'  # H.264/H.265 reject odd sizes
    if ($o.Height -gt 0) { $vf = "scale=-2:min($($o.Height)\,ih),$vf" }
    if ($o.Size) { return Convert-ToSize $source $vf }

    if ($script:format -eq 'srt' -and -not (Invoke-Probe '-select_streams', 's', '-show_entries', 'stream=index')) {
        $script:err = 'No subtitles'
        return $false
    }
    $aac = '-c:a', 'aac', '-movflags', '+faststart'
    $rate = ('256k', '192k', '128k')[$q]
    $arguments = switch ($script:format) {
        h264 { @('-vf', $vf, '-c:v', 'libx264', '-crf', (18, 23, 28)[$q], '-pix_fmt', 'yuv420p') + $aac }
        h265 { @('-vf', $vf, '-c:v', 'libx265', '-crf', (22, 27, 32)[$q], '-tag:v', 'hvc1', '-pix_fmt', 'yuv420p') + $aac }
        av1 { @('-vf', $vf, '-c:v', 'libsvtav1', '-preset', '8', '-crf', (26, 32, 40)[$q], '-pix_fmt', 'yuv420p') + $aac }
        vp9 { '-vf', $vf, '-c:v', 'libvpx-vp9', '-crf', (28, 34, 40)[$q], '-b:v', '0', '-row-mt', '1', '-cpu-used', '4', '-pix_fmt', 'yuv420p', '-c:a', 'libopus' }
        gif { '-vf', "$vf,fps=$((20, 15, 10)[$q]),split[a][b];[a]palettegen[p];[b][p]paletteuse" }
        rotate-left { @('-vf', "transpose=cclock,$vf", '-c:v', 'libx264', '-crf', '18', '-pix_fmt', 'yuv420p') + $aac }
        rotate-right { @('-vf', "transpose=clock,$vf", '-c:v', 'libx264', '-crf', '18', '-pix_fmt', 'yuv420p') + $aac }
        mute { '-map', '0:V', '-map', '0:s?', '-c', 'copy' }
        srt { '-map', '0:s:0', '-c:s', 'srt' }  # first track only
        copy-mp4 { '-map', '0:V', '-map', '0:a?', '-c', 'copy', '-movflags', '+faststart' }
        copy-mkv { '-map', '0:V', '-map', '0:a?', '-map', '0:s?', '-map', '0:t?', '-c', 'copy' }
        mp3 { '-vn', '-c:a', 'libmp3lame', '-b:a', $rate }
        m4a { '-vn', '-c:a', 'aac', '-b:a', $rate, '-movflags', '+faststart' }
        opus { '-vn', '-c:a', 'libopus', '-b:a', ('192k', '128k', '80k')[$q] }
        ogg { '-vn', '-c:a', 'libvorbis', '-b:a', $rate }
        flac { '-vn', '-c:a', 'flac' }
        wav { '-vn', '-c:a', 'pcm_s16le' }
    }

    # Hardware encoders have size limits, so any failure falls back to the CPU
    if ($script:gpu) {
        $cq = if ($script:format -eq 'h265') { (23, 28, 33)[$q] } else { (19, 24, 29)[$q] }
        $tail = $aac
        if ($script:format -eq 'h265') { $tail += '-tag:v', 'hvc1' }
        if (Invoke-Ffmpeg ($source + @('-vf', $vf) + (Get-GpuArguments $script:gpu $cq) + $tail + @($script:part))) { return $true }
    }
    Invoke-Ffmpeg ($source + $arguments + @($script:part))
}

# A read-only copy could be neither replaced nor deleted
function Copy-Source([string]$name) {
    $path = Join-Path $script:tmp $name
    [IO.File]::Copy($script:file, $path, $true)
    [IO.File]::SetAttributes($path, 'Normal')
}

# The source is copied under a plain name: magick parses [], : and % in paths
function Convert-Image {
    $o = $script:opt
    $q = $o.Quality
    $src = 'in'
    if ($script:name -match '.\.([A-Za-z0-9]+)$') { $src += '.' + $Matches[1].ToLowerInvariant() }
    Copy-Source $src
    if ($src -eq 'in.avif') {
        if (-not (Invoke-Ffmpeg '-i', $src, '-frames:v', '1', 'decoded.png')) { return $false }
        $src = 'decoded.png'
    }
    $arguments = @('-background', 'none', "$src[0]", '-auto-orient')
    if ($o.Height -gt 0) { $arguments += '-resize', "x$($o.Height)>" }
    # The color profile stays, or wide-gamut photos change color
    if ($o.Strip) { $arguments += '+profile', '!icc,*', '+set', 'comment' }
    if ($script:format -eq 'avif') {
        if (0 -ne (Invoke-Tool magick ($arguments + 'png:-') -OutFile (Join-Path $script:tmp 'oriented.png'))) { return $false }
        # AVIF keeps transparency in a second stream
        $graph = 'format=rgba,split[c][a];[c]scale=out_color_matrix=bt709:out_range=pc,format=yuv420p,setparams=colorspace=bt709:range=pc[v];[a]alphaextract,format=gray,setparams=colorspace=bt709:range=pc[m]'
        return Invoke-Ffmpeg '-i', 'oriented.png', '-filter_complex', $graph, '-map', '[v]', '-map', '[m]', '-frames:v', '1', '-c:v', 'libaom-av1', '-still-picture', '1', '-cpu-used', '6', '-crf', (18, 26, 34)[$q], $script:part
    }
    if ($script:format -eq 'ico') {
        $arguments += '-resize', '256x256>', '-gravity', 'center', '-extent', '%[fx:max(w,h)]x%[fx:max(w,h)]', '-define', 'icon:auto-resize=256,64,48,32,16'
    }
    if ($script:format -in 'jpg', 'pdf') { $arguments += '-background', 'white', '-alpha', 'remove' }
    if ($script:format -in 'jpg', 'webp', 'jxl', 'pdf') { $arguments += '-quality', (95, 85, 70)[$q] }
    0 -eq (Invoke-Tool magick ($arguments + "$($script:format):-") -OutFile $script:part)
}

# Poppler gets plain relative names, its Windows builds read arguments in the ANSI code page
function Convert-Pdf {
    Copy-Source 'in.pdf'
    $in = Join-Path $script:tmp 'in.pdf'
    $result = Join-Path $script:tmp 'out.pdf'
    Remove-Path $result
    switch ($script:format) {
        txt { return 0 -eq (Invoke-Tool pdftotext '-layout', 'in.pdf', '-' -OutFile $script:part) }
        merge {
            [IO.File]::Copy($in, $script:part)
            return $true
        }
        compress {
            if (0 -ne (Invoke-Tool gs '-q', '-dSAFER', '-dBATCH', '-dNOPAUSE', '-sDEVICE=pdfwrite', '-dPDFSETTINGS=/ebook', '-sOutputFile=out.pdf', '-f', 'in.pdf')) { return $false }
            if ((New-Object IO.FileInfo $result).Length -ge (New-Object IO.FileInfo $in).Length) {
                $script:err = 'Already compressed'
                return $false
            }
            [IO.File]::Copy($result, $script:part)
            return $true
        }
        ocr {
            $data = @{ uk = 'ukr'; de = 'deu'; es = 'spa'; fr = 'fra'; pl = 'pol'; nl = 'nld'; ca = 'cat' }[$script:locale]
            # English always, Ukrainian and the system language if Tesseract has data for them
            [void](Invoke-Tool tesseract '--list-langs')
            $installed = $script:stdout -split '\s+'
            $languages = (@('eng') + @('ukr', $data | Where-Object { $_ -and $_ -in $installed } | Select-Object -Unique)) -join '+'
            if (0 -ne (Invoke-Tool ocrmypdf '--skip-text', '-l', $languages, 'in.pdf', 'out.pdf')) { return $false }
            [IO.File]::Copy($result, $script:part)
            return $true
        }
    }
    $pages = Join-Path $script:tmp 'pages'
    if ([IO.Directory]::Exists($pages)) { [IO.Directory]::Delete($pages, $true) }
    [void][IO.Directory]::CreateDirectory($pages)
    $code = switch ($script:format) {
        split { Invoke-Tool pdfseparate 'in.pdf', 'pages/page-%03d.pdf' }
        jpg { Invoke-Tool pdftoppm '-jpeg', '-r', '150', 'in.pdf', 'pages/page' }
        default { Invoke-Tool pdftoppm '-png', '-r', '150', 'in.pdf', 'pages/page' }
    }
    if ($code -ne 0) { return $false }
    $files = [IO.Directory]::GetFiles($pages)
    if ($files.Count -eq 0) { return $false }
    if ($files.Count -eq 1 -and $script:format -ne 'split') {
        [IO.File]::Copy($files[0], $script:part)
        $script:suffix = ".$($script:ext)"
        $script:out = Get-FreeName $script:suffix
        return $true
    }
    [void][IO.Directory]::CreateDirectory($script:part)
    foreach ($f in $files) { [IO.File]::Copy($f, (Join-Path $script:part ([IO.Path]::GetFileName($f)))) }
    $true
}

function Convert-Ebook { 0 -eq (Invoke-Tool ebook-convert $script:file, $script:part) }

# soffice names its own output, so use a scratch folder and a private profile
function Convert-Office {
    $filter = $script:ext
    if ($filter -eq 'csv') { $filter = 'csv:Text - txt - csv (StarCalc):44,34,76' }  # UTF-8, commas
    $dir = Join-Path $script:tmp 'office'
    if ([IO.Directory]::Exists($dir)) { [IO.Directory]::Delete($dir, $true) }
    $profileUri = ([Uri](Join-Path $script:tmp 'profile')).AbsoluteUri
    if (0 -ne (Invoke-Tool soffice "-env:UserInstallation=$profileUri", '--headless', '--convert-to', $filter, '--outdir', $dir, $script:file)) { return $false }
    if (-not [IO.Directory]::Exists($dir)) { return $false }
    $produced = [IO.Directory]::GetFiles($dir, "*.$($script:ext)")
    if ($produced.Count -eq 0) { return $false }
    [IO.File]::Copy($produced[0], $script:part)
    $true
}

function Test-Exists([string]$path) { [IO.File]::Exists($path) -or [IO.Directory]::Exists($path) }

function Get-FreeName([string]$suffix) {
    $n = 1
    $path = $script:base + $suffix
    while (Test-Exists $path) { $path = "$($script:base) ($n)$suffix"; $n++ }
    $path
}

function Remove-Path([string]$path) {
    if (-not $path) { return }
    foreach ($try in 1..10) {
        try {
            if ([IO.Directory]::Exists($path)) { [IO.Directory]::Delete($path, $true) }
            elseif ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
            return
        } catch { Start-Sleep -Milliseconds 200 }  # a killed tool may release its files late
    }
}

# Another conversion of the same file may have taken the name meanwhile
function Save-Result {
    while ($true) {
        try {
            if ([IO.Directory]::Exists($script:part)) { [IO.Directory]::Move($script:part, $script:out) } else { [IO.File]::Move($script:part, $script:out) }
            break
        } catch {
            if (-not (Test-Exists $script:out)) { throw }
            $script:out = Get-FreeName $script:suffix
        }
    }
    $script:lastOut = $script:out
}

function Get-ErrorText {
    if ($script:err) { return T $script:err }
    # Ghostscript reports errors on stdout
    $text = "$($script:log)".Trim()
    if (-not $text) { $text = "$($script:stdout)".Trim() }
    $text -split "`r?`n" | Select-Object -Last 1
}

function Invoke-Files([string]$kind, [string[]]$files) {
    $merge = $script:format -in 'pdf-one', 'merge'
    if ($script:format -eq 'pdf-one') { $script:format = 'pdf' }
    $script:ext = switch ($script:format) {
        { $_ -in 'h264', 'h265', 'av1', 'copy-mp4', 'rotate-left', 'rotate-right' } { 'mp4' }
        vp9 { 'webm' }
        copy-mkv { 'mkv' }
        { $_ -in 'merge', 'split', 'compress', 'ocr' } { 'pdf' }
        default { $script:format }
    }
    $failed = @()
    $merged = @()
    $script:total = $files.Count
    $script:index = 0
    $script:clipUs = [long]0
    $script:name = [IO.Path]::GetFileName($files[0])

    Assert-Encoder $kind
    $script:gpu = $null
    if ($script:opt.Gpu -and -not $script:opt.Size -and $script:format -in 'h264', 'h265') {
        $script:codec = $script:format -replace 'h265', 'hevc'
        $script:gpu = Find-Gpu
    }

    foreach ($f in $files) {
        $script:file = $f
        $script:name = [IO.Path]::GetFileName($f)
        $dir = [IO.Path]::GetDirectoryName($f)
        $stem = [IO.Path]::GetFileNameWithoutExtension($f)
        if (-not $stem) { $stem = $script:name }
        $script:base = Join-Path $dir $stem
        if ($script:index -eq 0) { $mergeBase = $script:base }
        if ($script:format -eq 'mute') {
            $script:ext = [IO.Path]::GetExtension($f).TrimStart('.').ToLowerInvariant()
            if ($script:ext -notin 'mp4', 'mov', 'mkv', 'webm') { $script:ext = 'mkv' }
        }
        $script:suffix = if ($kind -eq 'pdf' -and $script:format -in 'png', 'jpg', 'split') { '' } else { ".$($script:ext)" }
        $script:out = Get-FreeName $script:suffix
        $script:part = Join-Path $dir ".explorer-convert-$PID.$($script:ext)"
        $script:err = $script:log = $script:stdout = ''
        $script:clipUs = [long]0
        $script:passBase = 0
        $script:passSpan = 100
        try {
            $ok = switch ($kind) {
                image { Convert-Image }
                pdf { Convert-Pdf }
                office { Convert-Office }
                ebook { Convert-Ebook }
                default { Convert-Media }
            }
            if ($ok) {
                if ($merge) {
                    $page = '{0:d6}.pdf' -f $script:index
                    [IO.File]::Copy($script:part, (Join-Path $script:tmp $page))
                    $merged += $page
                } else {
                    Save-Result
                }
                $script:done++
            } else { $failed += "$($script:name): $(Get-ErrorText)" }
        } catch [OperationCanceledException] {
            throw
        } catch {
            $failed += "$($script:name): $($_.Exception.GetBaseException().Message)"
        } finally {
            Remove-Path $script:part
        }
        $script:index++
    }

    if ($merge) {
        $script:done = 0  # no PDF with silently missing pages
        if (-not $failed) {
            $script:index = $script:total - 1
            $script:base = $mergeBase
            $script:suffix = '.pdf'
            $script:out = Get-FreeName $script:suffix
            $script:part = Join-Path ([IO.Path]::GetDirectoryName($mergeBase)) ".explorer-convert-$PID.pdf"
            try {
                # One page at a time would be quadratic; groups keep the command line short
                for ($round = 0; $merged.Count -gt 1; $round++) {
                    $next = @()
                    for ($i = 0; $i -lt $merged.Count; $i += 500) {
                        $group = @($merged[$i..([Math]::Min($i + 499, $merged.Count - 1))])
                        $target = "merge$round-$i.pdf"
                        if (0 -ne (Invoke-Tool pdfunite ($group + $target))) { throw [IO.IOException](Get-ErrorText) }
                        $next += $target
                    }
                    $merged = $next
                }
                [IO.File]::Copy((Join-Path $script:tmp $merged[0]), $script:part)
                Save-Result
                $script:done = $script:total
            } catch [OperationCanceledException] {
                throw
            } catch {
                $failed += "$([IO.Path]::GetFileName($script:out)): $($_.Exception.GetBaseException().Message)"
            } finally {
                Remove-Path $script:part
            }
        }
    }
    $failed
}

function Invoke-Convert([string]$kind, [string]$format, [string[]]$files) {
    $script:lastOut = $script:part = $script:tmp = $null
    $script:done = 0
    $script:opt = @{ Quality = 1; Height = 0; Gpu = $false; Strip = $false; Start = ''; End = ''; Size = '' }
    try {
        if (-not $files) { return 0 }
        if ($format -eq 'ask') {
            $script:opt = Get-Choice $kind $files.Count
            if (-not $script:opt) { return 0 }
            $format = $script:opt.Format
        } elseif ($format -eq '10mb' -and $kind -eq 'video') {
            $format = 'h264'
            $script:opt.Height = 720
            $script:opt.Size = '10'
        }
        if ($format -notin @(Get-Formats $kind) + @(Get-Actions $kind)) { throw [ApplicationException]"Unknown action: $kind $format" }
        $script:format = $format
        $tools = @(Get-ActionTools $kind $format)
        if ($kind -eq 'image' -and $files -match '\.avif$') { $tools += 'ffmpeg' }
        Assert-Tool @tools
        if ($format -eq 'merge' -and $files.Count -lt 2) { throw [ApplicationException](T 'Select several files') }
        $o = $script:opt
        $o.StartUs = $o.EndUs = [long]0
        if ($o.Start) { $o.StartUs = ConvertTo-Us $o.Start }
        if ($o.End) {
            $o.EndUs = ConvertTo-Us $o.End
            if ($o.EndUs -le $o.StartUs) { throw [ApplicationException](T 'Invalid time') }
        }
        if ($o.Size) {
            if ($o.Size -notmatch '^[1-9][0-9]{0,5}$') { throw [ApplicationException](T 'Invalid size') }
            if ($format -notin 'h264', 'h265', 'vp9') { throw [ApplicationException](T 'Target size works only with H.264, H.265 and VP9') }
        }

        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ('explorer-convert-' + [Guid]::NewGuid())
        [void][IO.Directory]::CreateDirectory($script:tmp)
        $failed = @(Invoke-Files $kind $files)
        Show-Done "$(T 'Done'): $($script:done) $(T 'of') $($files.Count)" $script:lastOut
        if ($failed) {
            Show-Error ((@("$(T 'Failed'):") + $failed) -join "`r`n")
            return 1
        }
        return 0
    } catch [OperationCanceledException] {
        Show-Done "$(T 'Canceled'). $(T 'Done'): $($script:done)" $null
        return 1
    } catch {
        Show-Error $_.Exception.GetBaseException().Message
        return 1
    } finally {
        Remove-Path $script:tmp
    }
}
