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
            $lines = @(Get-ChildItem -LiteralPath $work -Filter *.result | ForEach-Object { [IO.File]::ReadAllLines($_.FullName) })
        } until ($lines.Count -ge 200 -or [DateTime]::UtcNow -gt $deadline)
        Start-Sleep -Seconds 3  # time for duplicates or late batches to show up
        foreach ($action in $expected.Keys) {
            $results = @(Get-ChildItem -LiteralPath $work -Filter "$action.*.result")
            $got = @($results | ForEach-Object { [IO.File]::ReadAllLines($_.FullName) })
            Check "$action`: one batch ($($results.Count))" ($results.Count -eq 1)
            Check "$action`: every path exactly once ($($got.Count))" ($got.Count -and -not (Compare-Object $expected[$action] $got -CaseSensitive))
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
    function Has($name) { (Test-Exists (P $name)) -and ([IO.Directory]::Exists((P $name)) -or (New-Object IO.FileInfo (P $name)).Length -gt 0) }
    function Size($name) { (New-Object IO.FileInfo (P $name)).Length }
    function Make($tool, $name, $arguments) {
        $list = $arguments -split ' '
        & $tool @list
        if ($LASTEXITCODE) { throw "$tool failed" }
        [IO.File]::Move((Join-Path $work "gen$([IO.Path]::GetExtension($name))"), (P $name))
    }
    function Probe($name, $entries) { @(& ffprobe -v error -show_entries $entries -of csv=p=0 -i (P $name)) }
    function Codec($name) { (& ffprobe -v error -select_streams v -show_entries stream=codec_name -of csv=p=0 -i (P $name) | Select-Object -First 1) }
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
    Check 'awkward names' ($rc -eq 0 -and (Has noext.mp3) -and (Has '-dash.mp3') -and (Has '-dash (1).mp3') -and (Has "$cyr.mp3") -and (Has '.hidden.mp3'))
    Check 'shows last file' ($doneFile -eq (P '.hidden.mp3') -and $doneText -eq 'Done: 5 of 5')
    Check 'per-file progress' ([bool]($progress -like '5 of 5: .hidden*'))
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
    Check 'image types' ([BitConverter]::ToString([IO.File]::ReadAllBytes((P 'i [x]%d.jpg')), 0, 3) -eq 'FF-D8-FF' -and (Text p.webp).Substring(8, 4) -eq 'WEBP')
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
    Check 'strip video' ($rc -eq 0 -and -not (& ffprobe -v error -show_format -show_streams -i (P 'm (1).mp4') | Select-String 'secret|2020-01'))
    Answer @{ Start = '0:01'; End = '0:03' }
    Go video ask '-dash.mkv'
    Check 'trim' ($rc -eq 0 -and [Math]::Floor([double]::Parse((Probe '-dash.mp4' 'format=duration')[0], [Globalization.CultureInfo]::InvariantCulture)) -eq 2)
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
    Check 'time' ((ConvertTo-Us '1:02:03.5') -eq 3723500000 -and (ConvertTo-Us '90') -eq 90000000 -and (ConvertTo-Us '1:30') -eq 90000000)

    Make ffmpeg big.mkv '-v error -f lavfi -i testsrc2=d=25:s=1280x720,noise=alls=60:allf=t -f lavfi -i sine=d=25 -c:v libx264 -preset ultrafast -qp 15 gen.mkv'
    foreach ($f in 'h264', 'h265', 'vp9') {
        Answer @{ Format = $f; Quality = 1; Height = 480; Size = '2' }
        Go video ask big.mkv
        $size = if ($doneFile) { (New-Object IO.FileInfo $doneFile).Length } else { 0 }
        Check "2 MB $f`: $size" ($rc -eq 0 -and $size -gt 0 -and $size -le 2000000)
    }
    Go video 10mb big.mkv
    $size = if ($doneFile) { (New-Object IO.FileInfo $doneFile).Length } else { 0 }
    Check "10 MB: $size" ($rc -eq 0 -and $size -le 10000000 -and $size -gt 5000000)
    Answer @{ Format = 'h265'; Quality = 1; Gpu = $true }
    Go video ask "$cyr.mkv"
    Check "GPU or fallback (found: $($script:gpu))" ($rc -eq 0 -and (Codec "$cyr.mp4") -eq 'hevc')
    [IO.File]::WriteAllText((P broken.mkv), 'broken')
    Go video h264 broken.mkv m.mp4
    Check 'failure does not stop the rest' ($rc -eq 1 -and -not (Has broken.mp4) -and $errorText -match 'broken\.mkv: .' -and $doneText -eq 'Done: 1 of 2')
    $script:tr = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'lang.json') -Raw -Encoding UTF8 | ConvertFrom-Json).uk
    Go image jpg p.avif
    Check 'Ukrainian' ($doneText -eq 'Готово: 1 з 1')
    $script:tr = $null

    Make ffmpeg long.mkv '-v error -f lavfi -i testsrc=d=120:s=1920x1080 -c:v mpeg4 gen.mkv'
    $script:cancelWhen = { ($script:progress | Select-Object -Last 1) -match '\(([1-9]|[1-9]\d)%\)$' }
    Go video h264 long.mkv
    Check 'cancel' ($rc -eq 1 -and $doneText -eq 'Canceled. Done: 0' -and -not (Has long.mp4) -and -not (Get-Process ffmpeg -ErrorAction Ignore))
    $script:cancelWhen = $null

    Check 'quoting' ((Get-QuotedArgument 'a b\') -ceq '"a b\\"' -and (Get-QuotedArgument 'a\"b') -ceq '"a\\\"b"' -and (Get-QuotedArgument '') -ceq '""')

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
    Check 'no leftovers' (-not (Get-ChildItem -LiteralPath $dir -Recurse -Force -Filter '.explorer-convert*') -and -not (Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'explorer-convert-*' | Where-Object { $_.CreationTimeUtc -ge $started }))
} finally {
    Set-Location $PSScriptRoot
    Remove-Item -LiteralPath $work -Recurse -Force
}
"Failed: $script:fails"
exit [int]($script:fails -gt 0)
