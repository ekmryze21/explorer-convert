# Runs real conversions in a temporary folder with stubbed dialogs.
# On Windows it also starts many real launchers at once: no path may be lost, repeated or mixed.
$ErrorActionPreference = 'Stop'
$script:fails = 0
$started = [DateTime]::UtcNow
function Check($name, $ok) {
    if ($ok) { "ok   $name" } else { "FAIL $name"; $script:fails++ }
}
$env:EXPLORER_CONVERT_LANG = 'en'
. (Join-Path $PSScriptRoot 'core.ps1')
$windows = $env:OS -eq 'Windows_NT'
$work = Join-Path ([IO.Path]::GetTempPath()) ("ec test " + [Guid]::NewGuid())
[void](New-Item -ItemType Directory -Path $work)
try {
    $batch = Join-Path $work 'batch'
    [void](New-Item -ItemType Directory -Path $batch)
    $cyrillic = [string][char]0x444
    $awkward = "/d/page10.png", "/d/page2.png", "/d/Page1.png", "/d/a [1]% & 'b'$cyrillic.png", '/d/-dash', '\\srv\share\page3.png'
    foreach ($p in $awkward) { [IO.File]::WriteAllText((Join-Path $batch ([Guid]::NewGuid())), $p, [Text.Encoding]::Unicode) }
    $old = Join-Path $batch 'old'
    [IO.File]::WriteAllText($old, '/d/stale.png', [Text.Encoding]::Unicode)
    [IO.File]::SetLastWriteTimeUtc($old, [DateTime]::UtcNow.AddHours(-1))
    $read = @(Read-Batch $batch)
    Check 'batch complete, stale dropped' (-not (Compare-Object $awkward $read -CaseSensitive))
    Check 'natural order' (($read -match 'page') -join ' ' -ceq '/d/Page1.png /d/page2.png \\srv\share\page3.png /d/page10.png')
    Check 'batch removed' (-not (Test-Path -LiteralPath $batch))

    if ($windows) {
        foreach ($f in 'launch.js', 'core.ps1', 'lang.json') { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $f) -Destination $work }
        @'
param([string]$Kind, [string]$Format, [string]$Batch)
. (Join-Path $PSScriptRoot 'core.ps1')
$name = Join-Path $PSScriptRoot ("$Kind-$Format." + [Guid]::NewGuid())
[IO.File]::WriteAllLines("$name.part", [string[]]@(Read-Batch $Batch))
[IO.File]::Move("$name.part", "$name.result")
'@ | Set-Content -LiteralPath (Join-Path $work 'explorer-convert.ps1') -Encoding ASCII

        $expected = @{}
        foreach ($action in 'image-pdf-one', 'image-jpg') {
            $expected[$action] = 1..100 | ForEach-Object { "C:\d\$action [$_]% & 'x' %PATH% $cyrillic" }
        }
        foreach ($i in 0..99) {
            foreach ($action in $expected.Keys) {
                $kind, $format = $action -split '-', 2
                $psi = New-Object Diagnostics.ProcessStartInfo (Join-Path $env:SystemRoot 'System32\wscript.exe')
                $psi.Arguments = "//nologo //E:JScript `"$work\launch.js`" $kind $format `"$($expected[$action][$i])`""
                $psi.UseShellExecute = $false
                [Diagnostics.Process]::Start($psi).Dispose()
            }
        }
        $deadline = [DateTime]::UtcNow.AddMinutes(3)
        do {
            Start-Sleep -Milliseconds 500
            $lines = @(Get-ChildItem -LiteralPath $work -Filter *.result |
                ForEach-Object { [IO.File]::ReadAllLines($_.FullName) })
        } until ($lines.Count -ge 200 -or [DateTime]::UtcNow -gt $deadline)
        Start-Sleep -Seconds 3  # time for duplicates or late batches to show up
        foreach ($action in $expected.Keys) {
            $results = @(Get-ChildItem -LiteralPath $work -Filter "$action.*.result")
            $got = @($results | ForEach-Object { [IO.File]::ReadAllLines($_.FullName) })
            Check "$action`: one batch ($($results.Count))" ($results.Count -eq 1)
            Check "$action`: every path exactly once ($($got.Count))" ($got.Count -and
                -not (Compare-Object $expected[$action] $got -CaseSensitive))
        }
    } else { 'skip launcher test: needs Windows' }
    function Show-Options($kind, $formats, $saved, $count) { $script:asked = $saved; $script:answer }
    function Show-Done($text, $file) { $script:doneText = $text; $script:doneFile = $file }
    function Show-Error($text) { $script:errorText = $text }
    function Update-Progress($percent, $text) {
        $script:progress += $text
        $script:cancelWhen -and (& $script:cancelWhen)
    }
    $script:root = $work  # settings
    $dir = Join-Path $work 'my.dir'
    [void](New-Item -ItemType Directory -Path $dir)
    function P($name) { Join-Path $dir $name }
    function Go($kind, $format) {
        $script:errorText = $script:doneText = $script:doneFile = $script:asked = $null
        $script:progress = @()
        $script:rc = Invoke-Convert $kind $format @($args | ForEach-Object { P $_ })
    }
    function Answer($values) {
        $script:answer = @{ Format = 'h264'; Quality = 0; Height = 0; Start = ''; End = ''; Size = ''; Gpu = $false; Strip = $false }
        foreach ($key in $values.Keys) { $script:answer[$key] = $values[$key] }
    }
    function Has($name) { (Test-Exists (P $name)) -and
        ([IO.Directory]::Exists((P $name)) -or (New-Object IO.FileInfo (P $name)).Length -gt 0) }
    function Size($name) { (New-Object IO.FileInfo (P $name)).Length }
    function Make($tool, $name, $arguments) {
        $list = $arguments -split ' '
        & $tool @list
        if ($LASTEXITCODE) { throw "$tool failed" }
        [IO.File]::Move((Join-Path $work "gen$([IO.Path]::GetExtension($name))"), (P $name))
    }
    function Probe($name, $entries) { @(& ffprobe -v error -show_entries $entries -of csv=p=0 -i (P $name)) }
    function Codec($name) { (& ffprobe -v error -select_streams v -show_entries stream=codec_name -of csv=p=0 -i (P $name) |
        Select-Object -First 1) }
    function Text($name) { [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes((P $name))) }
    function Entries($name) { @([IO.Directory]::GetFileSystemEntries((P $name))).Count }
    Push-Location $work

    $v = "a [1]% & 'b'.mkv"
    $cyr = 'відео'
    Make ffmpeg $v '-v error -f lavfi -i testsrc=d=4:s=301x201 -f lavfi -i sine=d=4 -c:v libx264 -c:a aac gen.mkv'
    foreach ($copy in 'noext', '-dash.mkv', "$cyr.mkv", '.hidden') { [IO.File]::Copy((P $v), (P $copy)) }
    Make ffmpeg s.wav '-v error -f lavfi -i sine=d=3 gen.wav'
    $img = 'i [x]%d.png'
    Make magick $img '-size 301x201 xc:rgba(255,0,0,0.5) gen.png'
    Make ffmpeg p.avif '-v error -f lavfi -i color=red:s=64x64 -frames:v 1 gen.avif'
    Make magick doc.pdf '-size 80x80 xc:red xc:blue gen.pdf'
    [IO.File]::Copy((P doc.pdf), (P "$cyr doc.pdf"))
    $hashes = @{}
    foreach ($f in [IO.Directory]::GetFiles($dir)) { $hashes[$f] = (Get-FileHash -LiteralPath $f).Hash }

    $b = $v -replace '\.mkv$'
    foreach ($f in 'h264', 'h265', 'vp9', 'av1', 'gif', 'mp3', 'copy-mp4', 'copy-mkv') { Go video $f $v; Check "video $f" ($rc -eq 0) }
    Check 'codecs' ((Codec "$b.mp4"), (Codec "$b (1).mp4"), (Codec "$b.webm"), (Codec "$b (2).mp4"), (Codec "$b (3).mp4") -join ' ' -eq 'h264 hevc vp9 av1 h264')
    Check 'even size' ((& ffprobe -v error -select_streams v -show_entries stream=width,height -of csv=p=0 -i (P "$b.mp4")) -like '302,202*')
    Go video mp3 noext '-dash.mkv' '-dash.mkv' "$cyr.mkv" '.hidden'
    Check 'awkward names' ($rc -eq 0 -and (Has noext.mp3) -and (Has '-dash.mp3') -and (Has '-dash (1).mp3') -and
        (Has "$cyr.mp3") -and (Has '.hidden.mp3'))
    Check 'shows last file' ($doneFile -eq (P '.hidden.mp3') -and $doneText -eq 'Done: 5 of 5')
    foreach ($f in 'mp3', 'm4a', 'opus', 'ogg', 'flac', 'wav') { Go audio $f s.wav; Check "audio $f" ($rc -eq 0) }
    $jxl = [bool](& magick -list format | Select-String '^\s*JXL')
    foreach ($f in 'jpg', 'png', 'webp', 'avif', 'jxl', 'tiff', 'gif', 'bmp', 'ico', 'pdf') {
        if ($f -eq 'jxl' -and -not $jxl) { 'skip image jxl: this ImageMagick lacks it'; continue }
        Go image $f $img p.avif
        Check "image $f" ($rc -eq 0 -and (Has "p.$f"))
    }
    Check 'avif transparency' (@(Probe 'i [x]%d.avif' 'stream=codec_name' | Where-Object { $_ -match 'av1' }).Count -eq 2)
    [IO.File]::Copy((P 'i [x]%d.ico'), (Join-Path $work 'sizes.ico'))
    Check 'ico sizes' (@(& magick identify sizes.ico).Count -eq 5)
    Check 'image types' ([BitConverter]::ToString([IO.File]::ReadAllBytes((P 'i [x]%d.jpg')), 0, 3) -eq 'FF-D8-FF' -and
        (Text p.webp).Substring(8, 4) -eq 'WEBP')
    [void](New-Item -ItemType Directory -Path (P merge))
    [IO.File]::Copy((P $img), (P 'merge/a.png'))
    [IO.File]::Copy((P p.avif), (P 'merge/b.avif'))
    Go image pdf-one merge/a.png merge/b.avif
    Check 'one pdf' ($rc -eq 0 -and (@(& pdfinfo (P merge/a.pdf)) -match '^Pages: +2$') -and (Entries merge) -eq 3)
    [IO.File]::WriteAllText((P merge/c.png), 'broken')
    Go image pdf-one merge/a.png merge/c.png
    Check 'one pdf fails whole' ($rc -eq 1 -and (Entries merge) -eq 4 -and $doneText -eq 'Done: 0 of 2')
    Make magick one.pdf '-size 20x20 xc:red gen.pdf'
    Go pdf png one.pdf
    Check 'single page pdf' ($rc -eq 0 -and [IO.File]::Exists((P one.png)))
    foreach ($f in 'png', 'jpg', 'txt') { Go pdf $f doc.pdf "$cyr doc.pdf"; Check "pdf $f" ($rc -eq 0) }
    Check 'pdf pages' ((Entries doc) -eq 2 -and (Entries 'doc (1)') -eq 2 -and (Entries "$cyr doc") -eq 2)

    Make magick m.jpg '-size 9x9 xc:red -set comment secret gen.jpg'
    Answer @{ Format = 'jpg'; Strip = $true }
    Go image ask m.jpg
    Check 'strip image' ($rc -eq 0 -and (Text m.jpg) -match 'secret' -and (Text 'm (1).jpg') -notmatch 'secret')
    Make ffmpeg m.mp4 '-v error -f lavfi -i testsrc=d=1 -metadata title=secret -metadata:s:v creation_time=2020-01-02T03:04:05Z gen.mp4'
    Answer @{ Strip = $true }
    Go video ask m.mp4
    Check 'strip video' ($rc -eq 0 -and -not (& ffprobe -v error -show_format -show_streams -i (P 'm (1).mp4') |
        Select-String 'secret|2020-01'))
    Answer @{ Start = '0:01'; End = '0:03' }
    Go video ask '-dash.mkv'
    Check 'trim' ($rc -eq 0 -and
        [Math]::Floor([double]::Parse((Probe '-dash.mp4' 'format=duration')[0], [Globalization.CultureInfo]::InvariantCulture)) -eq 2)
    Answer @{ Format = 'gif'; Quality = 2; Height = 480 }
    Go video ask '-dash.mkv'
    Go video ask '-dash.mkv'
    Check 'remembers choice' ($asked.Format -eq 'gif' -and $asked.Quality -eq 2 -and $asked.Height -eq 480)
    foreach ($bad in @{ Start = '1:99x' }, @{ Start = '5'; End = '2' }, @{ Start = '99' }, @{ Size = '0' }, @{ Size = 'abc' }) {
        Answer $bad
        Go video ask "$cyr.mkv"
        Check "rejects $($bad.Values -join ' ')" ($rc -eq 1 -and $errorText -and -not (Has "$cyr.mp4"))
    }
    Answer @{ Format = 'gif'; Size = '5' }
    Go video ask "$cyr.mkv"
    Check 'rejects GIF size' ($rc -eq 1 -and -not (Has "$cyr.gif"))
    $script:answer = $null
    Go video ask "$cyr.mkv"
    Check 'dialog closed' ($rc -eq 0 -and -not $doneText -and -not $errorText)
    Check 'time' ((ConvertTo-Us '1:02:03.5') -eq 3723500000 -and (ConvertTo-Us '90') -eq 90000000 -and
        (ConvertTo-Us '1:30') -eq 90000000)

    Make ffmpeg big.mkv '-v error -f lavfi -i testsrc2=d=25:s=1280x720,noise=alls=60:allf=t -f lavfi -i sine=d=25 -c:v libx264 -preset ultrafast -qp 15 gen.mkv'
    foreach ($f in 'h264', 'h265', 'vp9') {
        Answer @{ Format = $f; Quality = 1; Height = 480; Size = '2' }
        Go video ask big.mkv
        $size = if ($doneFile) { (New-Object IO.FileInfo $doneFile).Length } else { 0 }
        Check "2 MB $f`: $size" ($rc -eq 0 -and $size -gt 0 -and $size -le 2000000)
    }
    Go video h264 m.mp4 big.mkv
    Check 'per-file progress' ($rc -eq 0 -and [bool]($progress -like '2 of 2: big.mkv*'))
    $script:cancelWhen = { [IO.File]::WriteAllText($taken, 'other'); $false }
    $taken = P 'big.webm'
    Remove-Path $taken
    Go video vp9 big.mkv
    Check 'name taken meanwhile' ($rc -eq 0 -and $doneFile -eq (P 'big (1).webm') -and [IO.File]::ReadAllText($taken) -eq 'other')
    $script:cancelWhen = $null
    Go video 10mb big.mkv
    $size = if ($doneFile) { (New-Object IO.FileInfo $doneFile).Length } else { 0 }
    Check "10 MB: $size" ($rc -eq 0 -and $size -le 10000000 -and $size -gt 5000000)
    Answer @{ Format = 'h265'; Quality = 1; Gpu = $true }
    Go video ask "$cyr.mkv"
    Check "GPU or fallback (found: $($script:gpu))" ($rc -eq 0 -and (Codec "$cyr.mp4") -eq 'hevc')
    [IO.File]::WriteAllText((P broken.mkv), 'broken')
    Go video h264 broken.mkv m.mp4
    Check 'failure does not stop the rest' ($rc -eq 1 -and -not (Has broken.mp4) -and $errorText -match 'broken\.mkv: .' -and
        $doneText -eq 'Done: 1 of 2')
    $script:tr = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'lang.json') -Raw -Encoding UTF8 | ConvertFrom-Json).uk
    Go image jpg p.avif
    Check 'Ukrainian' ($doneText -eq 'Готово: 1 з 1')
    $script:tr = $null

    Make ffmpeg long.mkv '-v error -f lavfi -i testsrc=d=120:s=1920x1080 -c:v mpeg4 gen.mkv'
    $script:cancelWhen = { ($script:progress | Select-Object -Last 1) -match '\(([1-9]|[1-9]\d)%\)$' }
    Go video h264 long.mkv
    Check 'cancel' ($rc -eq 1 -and $doneText -eq 'Canceled. Done: 0' -and -not (Has long.mp4) -and
        -not (Get-Process ffmpeg -ErrorAction Ignore))
    $script:cancelWhen = $null

    Check 'quoting' ((Get-QuotedArgument 'a b\') -ceq '"a b\\"' -and (Get-QuotedArgument 'a\"b') -ceq '"a\\\"b"' -and
        (Get-QuotedArgument '') -ceq '""')

    [IO.File]::WriteAllText((Join-Path $work 'subs.srt'), "1`n00:00:00,000 --> 00:00:01,000`nhello`n")
    Make ffmpeg sub.mkv '-v error -f lavfi -i testsrc=d=2:s=320x200 -f lavfi -i sine=d=2 -i subs.srt -c:v libx264 -c:a aac -c:s srt gen.mkv'
    Go video srt sub.mkv
    Check 'srt' ($rc -eq 0 -and (Text sub.srt) -match 'hello')
    Go video srt m.mp4
    Check 'no subtitles' ($rc -eq 1 -and $errorText -match 'No subtitles' -and -not (Has m.srt))
    Go video mute sub.mkv
    Check 'mute' ($rc -eq 0 -and ((Probe 'sub (1).mkv' 'stream=codec_type') -join ' ') -eq 'video subtitle')
    Make ffmpeg old.avi '-v error -f lavfi -i testsrc=d=1 -f lavfi -i sine=d=1 gen.avi'
    Go video mute old.avi m.mp4
    Check 'mute keeps the container' ($rc -eq 0 -and (Has old.mkv) -and (Probe old.mkv 'stream=codec_type') -eq 'video' -and
        $doneFile -like '*.mp4')
    Make ffmpeg lr.mkv '-v error -f lavfi -i color=red:s=301x201:d=1 -vf drawbox=x=150:w=151:h=ih:color=blue:t=fill -c:v libx264 -pix_fmt yuv444p gen.mkv'
    foreach ($side in @('left', '0'), @('right', '1')) {
        Go video "rotate-$($side[0])" lr.mkv
        & ffmpeg -v error -y -i $doneFile -frames:v 1 turned.png
        $red = & magick turned.png -format '%[fx:p{100,20}.r>p{100,20}.b?1:0]' info:
        Check "rotate $($side[0])" ($rc -eq 0 -and (& magick identify -format '%wx%h' turned.png) -eq '202x302' -and
            $red -eq $side[1])
    }

    if ($windows) {
        $path = $env:PATH
        [void](New-Item -ItemType Directory -Path (Join-Path $work 'stub'))
        [IO.File]::WriteAllText((Join-Path $work 'stub\ffmpeg.cmd'), "@echo  V..... libvpx-vp9 VP9`r`n")
        $env:PATH = (Join-Path $work 'stub') + ';' + $path
        foreach ($case in @('video', 'h264', 'libx264'), @('video', 'rotate-left', 'libx264'),
            @('audio', 'mp3', 'libmp3lame'), @('image', 'avif', 'libaom-av1')) {
            Go $case[0] $case[1] m.mp4
            Check "no encoder: $($case[1])" ($rc -eq 1 -and $errorText -eq "ffmpeg was built without an encoder: $($case[2])")
        }
        $env:PATH = "$env:SystemRoot\System32"
        foreach ($case in @('video', 'mute', 'ffmpeg'), @('pdf', 'merge', 'pdfunite'), @('pdf', 'split', 'pdfseparate'),
            @('pdf', 'compress', 'gs'), @('pdf', 'ocr', 'ocrmypdf'), @('ebook', 'epub', 'ebook-convert')) {
            Go $case[0] $case[1] doc.pdf
            Check "no tool: $($case[2])" ($rc -eq 1 -and $errorText -eq "Not installed: $($case[2])")
        }
        $programs = $env:ProgramFiles
        $env:ProgramFiles = Join-Path $work 'programs'
        $bin = Join-Path $env:ProgramFiles 'gs\gs10.1\bin'
        [void](New-Item -ItemType Directory -Path $bin)
        Add-SearchPath
        Check 'finds programs outside PATH' (($env:PATH -split ';') -contains $bin -and (Find-Tool ffmpeg))
        $env:ProgramFiles = $programs
        $env:PATH = $path
    }

    [void](New-Item -ItemType Directory -Path (P pdfs))
    $ro = 'pdfs/ro1.pdf', "pdfs/ro2 [1]% & $cyr.pdf"
    foreach ($n in $ro) {
        [IO.File]::Copy((P doc.pdf), (P $n))
        [IO.File]::SetAttributes((P $n), 'ReadOnly')
    }
    Go pdf merge @ro
    Check 'merge' ($rc -eq 0 -and (@(& pdfinfo (P 'pdfs/ro1 (1).pdf')) -match '^Pages: +4$'))
    Go pdf merge doc.pdf
    Check 'merge needs several files' ($rc -eq 1 -and $errorText -eq 'Select several files')
    [IO.File]::WriteAllText((P broken.pdf), 'broken')
    Go pdf merge doc.pdf broken.pdf
    Check 'merge fails whole' ($rc -eq 1 -and $doneText -eq 'Done: 0 of 2' -and -not (Has 'doc (1).pdf'))
    Go pdf split @ro
    Check 'split' ($rc -eq 0 -and (Entries pdfs/ro1) -eq 2 -and (Entries "pdfs/ro2 [1]% & $cyr") -eq 2)
    Go pdf txt @ro
    Check 'read-only PDFs' ($rc -eq 0)
    $roImages = 'pdfs/ro1.png', 'pdfs/ro2.png'
    foreach ($n in $roImages) {
        [IO.File]::Copy((P $img), (P $n))
        [IO.File]::SetAttributes((P $n), 'ReadOnly')
    }
    Go image jpg @roImages
    Check 'read-only images' ($rc -eq 0)
    foreach ($n in $ro + $roImages) { [IO.File]::SetAttributes((P $n), 'Normal') }

    if (Find-Tool gs) {
        Make magick fat.pdf '-size 1600x1600 plasma:red-blue -density 600 -compress zip gen.pdf'
        Go pdf compress fat.pdf
        Check 'compress' ($rc -eq 0 -and (Size 'fat (1).pdf') -lt (Size fat.pdf))
        # Compressed again and again it must stop by itself and leave nothing behind
        for ($i = 1; $i -le 6 -and $rc -eq 0; $i++) { $smaller = [IO.Path]::GetFileName($doneFile); Go pdf compress $smaller }
        Check "already compressed after $i" ($rc -eq 1 -and $errorText -match 'Already compressed' -and -not $doneFile -and
            -not (Has ($smaller -replace '\.pdf$', ' (1).pdf')))
        Go pdf compress broken.pdf
        Check "compress broken: $errorText" ($rc -eq 1 -and $errorText -match 'broken\.pdf: .' -and -not (Has 'broken (1).pdf'))
    } else { 'skip compress: no Ghostscript' }

    if ((Find-Tool ocrmypdf) -and (Find-Tool tesseract)) {
        Make magick scan.pdf '-density 200 -size 1200x400 xc:white -font Arial -pointsize 24 -annotate +80+200 HELLO gen.pdf'
        Go pdf ocr scan.pdf
        Check "ocr $errorText" ($rc -eq 0 -and [bool](& pdftotext 'my.dir/scan (1).pdf' - | Select-String HELLO))
        if (@(& tesseract --list-langs) -contains 'ukr') {
            [IO.File]::WriteAllText((Join-Path $work 'uk.txt'), 'Привіт, їжак')
            Make magick uk.pdf '-density 200 -size 1200x400 xc:white -font Arial -pointsize 24 -annotate +80+200 @uk.txt gen.pdf'
            Go pdf ocr uk.pdf
            & pdftotext -enc UTF-8 'my.dir/uk (1).pdf' uk-read.txt
            $read = [IO.File]::ReadAllText((Join-Path $work 'uk-read.txt')).Trim()
            Check "ocr Ukrainian in an English system: $read $errorText" ($rc -eq 0 -and $read -match 'Привіт' -and
                $read -match 'їжак')
        } else { 'skip Ukrainian ocr: no language data' }
        $script:locale = 'pl'
        Go pdf ocr scan.pdf
        Check "ocr in Polish, with language data or not $errorText" ($rc -eq 0)
        $script:locale = 'en'
    } else { 'skip ocr: no ocrmypdf or tesseract' }

    if (Find-Tool ebook-convert) {
        [IO.File]::WriteAllText((Join-Path $work 'gen.txt'), 'Once upon a time')
        & ebook-convert gen.txt gen.epub | Out-Null
        $book = "book [1]% & $cyr"
        [IO.File]::Move((Join-Path $work 'gen.epub'), (P "$book.epub"))
        foreach ($f in 'epub', 'mobi', 'azw3', 'pdf', 'txt') {
            Go ebook $f "$book.epub"
            Check "ebook $f $errorText" ($rc -eq 0 -and (New-Object IO.FileInfo $doneFile).Length -gt 0)
        }
        [IO.File]::WriteAllText((P bad.epub), 'broken')
        Go ebook txt bad.epub
        Check 'broken ebook' ($rc -eq 1 -and $errorText -match 'bad\.epub: .' -and -not (Has bad.txt))
    } else { 'skip ebooks: no Calibre' }

    $python = $null
    foreach ($name in @('python', 'python3') + @(Get-Item "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe" -ErrorAction Ignore | ForEach-Object { $_.FullName })) {
        $found = Get-Command $name -CommandType Application -ErrorAction Ignore |
            Where-Object { $_.Source -notmatch 'WindowsApps' } | Select-Object -First 1
        if ($found -and -not $python -and
            (& $found.Source -c "import importlib.util as u; print(u.find_spec('pillow_heif'))") -ne 'None') { $python = $found.Source }
    }
    if ($python) {
        # Phones store the rotation twice, in the picture and in EXIF; it must apply once
        $code = "from PIL import Image", "import pillow_heif", "pillow_heif.register_heif_opener()",
            "exif = Image.Exif()", "exif[0x0112] = 6",
            "Image.new('RGB', (120, 80), 'red').save('gen.heic', exif=exif.tobytes())",
            "data = open('gen.heic', 'rb').read()",
            "for order in 'little', 'big':",
            "    tag = [(0x0112).to_bytes(2, order) + (3).to_bytes(2, order) + (1).to_bytes(4, order) + n.to_bytes(2, order) for n in (1, 6)]",
            "    data = data.replace(*tag)",
            "    if tag[1] in data: break",
            "else: raise SystemExit('no EXIF orientation')",
            "open('gen.heic', 'wb').write(data)"
        [IO.File]::WriteAllLines((Join-Path $work 'heic.py'), [string[]]$code)
        & $python heic.py
        if ($LASTEXITCODE) { throw 'heic.py failed' }
        foreach ($n in 'IMG [1].HEIC', 'x.heif') { [IO.File]::Copy((Join-Path $work 'gen.heic'), (P $n)) }
        foreach ($f in 'jpg', 'avif', 'pdf') { Go image $f 'IMG [1].HEIC' x.heif; Check "heic $f $errorText" ($rc -eq 0) }
        $turned = & magick identify -format '%wx%h' 'my.dir/x.jpg'
        Check "heic turned once: $turned" ($turned -eq '80x120')
    } else { 'skip heic: no pillow-heif' }

    $samples = $env:EXPLORER_CONVERT_SAMPLES
    if ($samples) {
        [void](New-Item -ItemType Directory -Path (P samples))
        foreach ($file in Get-ChildItem -LiteralPath $samples -File) { Copy-Item -LiteralPath $file.FullName -Destination (P samples) }
        Go pdf compress samples/basic-en.pdf
        Check 'sample PDF: already compressed' ($rc -eq 1 -and $errorText -match 'Already compressed' -and -not $doneFile)
        Go pdf txt samples/basic-en.pdf
        Check 'sample PDF: text' ($rc -eq 0 -and (Size samples/basic-en.txt) -gt 200)
        Go video copy-mkv samples/bbb_short.mp4
        Check 'sample video: both audio tracks' ($rc -eq 0 -and
            @((Probe samples/bbb_short.mkv 'stream=codec_type') -match 'audio').Count -eq 2)
        Go video mute samples/bbb_short.mp4
        Check 'sample video: no sound' ($rc -eq 0 -and
            -not ((Probe 'samples/bbb_short (1).mp4' 'stream=codec_type') -match 'audio'))
        if (Find-Tool soffice) {
            foreach ($f in 'docx', 'odt', 'pdf') {
                Go office $f samples/basic-en.odt samples/basic-de.odt
                Check "sample documents: $f" ($rc -eq 0)
            }
            Go office pdf samples/basic-en.docx
            Check 'sample document: PDF from DOCX has text' ($rc -eq 0 -and
                [bool](& pdftotext 'my.dir/samples/basic-en (2).pdf' - | Select-String '\w{4}'))
            Go office xlsx samples/basic-en.odt
            Check 'sample document: not a spreadsheet' ($rc -eq 1 -and -not (Has samples/basic-en.xlsx))
        }
    } else { 'skip samples: EXPLORER_CONVERT_SAMPLES is not set' }
    if (Find-Tool soffice) {
        [IO.File]::WriteAllText((P 'w [1] ф.csv'), "a;b`n1;2")
        foreach ($f in 'ods', 'xlsx', 'pdf', 'csv') { Go office $f 'w [1] ф.csv'; Check "office $f" ($rc -eq 0) }
        Check 'office files' ((Has 'w [1] ф.ods') -and (Has 'w [1] ф.xlsx') -and (Has 'w [1] ф.pdf') -and (Has 'w [1] ф (1).csv'))
    } else {
        Go office pdf w.docx
        Check 'missing tool' ($rc -eq 1 -and $errorText -eq 'Not installed: soffice')
    }
    $changed = @($hashes.Keys | Where-Object { (Get-FileHash -LiteralPath $_).Hash -ne $hashes[$_] })
    Check 'originals intact' ($hashes.Count -eq 10 -and -not $changed)
    Check 'no leftovers' (-not (Get-ChildItem -LiteralPath $dir -Recurse -Force -Filter '.explorer-convert*') -and
        -not (Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'explorer-convert-*' |
        Where-Object { $_.CreationTimeUtc -ge $started }))
} finally {
    Set-Location $PSScriptRoot
    Remove-Item -LiteralPath $work -Recurse -Force
}
"Failed: $script:fails"
exit [int]($script:fails -gt 0)
