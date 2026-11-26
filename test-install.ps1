# Installs for real into the current account with stubbed tools, then removes everything.
# Refuses to run over an existing installation.
$ErrorActionPreference = 'Stop'
$script:fails = 0
function Check($name, $ok) {
    if ($ok) { "ok   $name" } else { "FAIL $name"; $script:fails++ }
}
$classes = 'HKCU:\Software\Classes'
$modern = "$classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}"
$target = Join-Path $env:LOCALAPPDATA 'explorer-convert'
if ((Test-Path -LiteralPath $target) -or (Test-Path -LiteralPath $modern) -or (Test-Path HKCU:\Software\explorer-convert)) {
    'explorer-convert or the classic menu is already set up, nothing was tested'
    exit 1
}
$stubs = Join-Path ([IO.Path]::GetTempPath()) ('ec tools ' + [Guid]::NewGuid())
[void](New-Item -ItemType Directory -Path $stubs)
$path = $env:PATH
$env:EXPLORER_CONVERT_NO_SEARCH = '1'
$env:EXPLORER_CONVERT_LANG = 'uk'

function Install {
    $env:PATH = "$stubs;$env:SystemRoot\System32;$env:SystemRoot\System32\WindowsPowerShell\v1.0"
    $script:text = (& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'install.ps1') @args) -join "`n"
    $script:rc = $LASTEXITCODE
    $env:PATH = $path
}
function Stub { foreach ($name in $args) { [IO.File]::WriteAllText((Join-Path $stubs "$name.cmd"), '') } }
function Actions($menu) {
    if (-not (Test-Path -LiteralPath "$classes\ExplorerConvert.$menu")) { return '' }
    (Get-ChildItem -LiteralPath "$classes\ExplorerConvert.$menu\shell" | ForEach-Object { $_.PSChildName.Substring(2) }) -join ' '
}
function Menu($ext) { Test-Path -LiteralPath "$classes\SystemFileAssociations\$ext\shell\ExplorerConvert" }
$before = @(Get-ChildItem "$classes\SystemFileAssociations" -ErrorAction SilentlyContinue |
    ForEach-Object { $_.PSChildName }) -join ' '

try {
    Install
    Check 'nothing installed: no menus' ($rc -eq 0 -and -not (Menu .mp4) -and -not (Menu .pdf) -and -not (Menu .epub) -and
        (Actions video) -eq '')
    Check 'nothing installed: commands and hints' ($text -match 'Missing: ffmpeg, ffprobe' -and
        $text -match 'Optional\.' -and $text -match 'E-books: ebook-convert')

    Stub magick
    Install
    Check 'only ImageMagick' ((Menu .heic) -and (Menu .cr3) -and -not (Menu .mp4) -and
        (Actions image) -eq 'jpg png webp jxl pdf ask')
    Stub gswin64c
    Install
    $first = (Get-ItemProperty -LiteralPath "$classes\ExplorerConvert.pdf\shell\00compress" -ErrorAction SilentlyContinue)
    Check 'only Ghostscript: no separator on top' ((Actions pdf) -eq 'compress' -and $first -and -not $first.CommandFlags)
    Stub ocrmypdf
    Install
    Check 'ocrmypdf without Tesseract' ((Actions pdf) -eq 'compress')
    Stub ffmpeg
    Install
    Check 'ffmpeg without ffprobe' (-not (Menu .mp4) -and $text -match 'Missing: ffprobe')

    Stub ffprobe pdftoppm pdftotext pdfunite pdfseparate tesseract ebook-convert soffice
    [IO.File]::WriteAllText((Join-Path $stubs 'tesseract.cmd'), '@echo ukr')
    Install
    Check 'everything' ((Menu .mp4) -and (Menu .fb2) -and (Menu .docx) -and $text -notmatch 'Missing|Optional' -and
        (Actions video) -eq 'h264 vp9 gif mp3 copy-mp4 10mb mute rotate-left rotate-right srt ask' -and
        (Actions pdf) -eq 'png jpg txt merge split compress ocr' -and (Actions ebook) -eq 'epub mobi azw3 pdf txt')
    $label = (Get-ItemProperty -LiteralPath "$classes\ExplorerConvert.video\shell\06mute").MUIVerb
    Check "translated: $label" ($label.Length -and $label -ne 'Remove sound')
    $words = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'lang.json') -Raw -Encoding UTF8 |
        ConvertFrom-Json).uk.PSObject.Properties.Name
    $english = @(Get-ChildItem $classes | Where-Object { $_.PSChildName -like 'ExplorerConvert.*' } |
        ForEach-Object { Get-ChildItem -LiteralPath "$($_.PSPath)\shell" } |
        ForEach-Object { $_.GetValue('MUIVerb') } | Where-Object { $_ -in $words })
    Check "no English left: $english" (-not $english)
    Remove-Item (Join-Path $stubs 'ebook-convert.cmd')
    Install
    Check 'menu goes away with its program' (-not (Menu .epub) -and (Actions ebook) -eq '' -and (Menu .mp4))

    if ([Environment]::OSVersion.Version.Build -ge 22000) {
        Check 'classic menu is off by default' (-not (Test-Path -LiteralPath $modern))
        Install -ClassicMenu
        $server = Get-Item -LiteralPath "$modern\InprocServer32" -ErrorAction SilentlyContinue
        Check 'classic menu on' ($rc -eq 0 -and $server -and $server.GetValue('') -eq '')
        Install -ClassicMenu
        Check 'classic menu on twice' ($rc -eq 0 -and $text -match 'already')
        Install -ModernMenu
        Check 'modern menu back' ($rc -eq 0 -and -not (Test-Path -LiteralPath $modern))
        Install -ClassicMenu
        Install -Uninstall
        Check 'uninstall restores the menu' ($rc -eq 0 -and -not (Test-Path -LiteralPath $modern) -and
            -not (Test-Path HKCU:\Software\explorer-convert))
        [void](New-Item -Path "$modern\InprocServer32" -Force -Value '')
        Install
        Install -Uninstall
        Check "uninstall keeps someone else's choice" (Test-Path -LiteralPath "$modern\InprocServer32")
        Remove-Item -LiteralPath $modern -Recurse
    } else { 'skip classic menu: not Windows 11' }
    Install -Uninstall -ClassicMenu
    Check 'one option at a time' ($rc -ne 0 -and -not (Test-Path -LiteralPath $modern))
} finally {
    Install -Uninstall
    Remove-Item -LiteralPath $modern -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stubs -Recurse -Force
    $env:PATH = $path
}
$after = @(Get-ChildItem "$classes\SystemFileAssociations" -ErrorAction SilentlyContinue |
    ForEach-Object { $_.PSChildName }) -join ' '
Check 'nothing left behind' ($before -eq $after -and -not (Test-Path -LiteralPath $target) -and
    -not (Get-ChildItem $classes | Where-Object { $_.PSChildName -like 'ExplorerConvert*' }))
"Failed: $script:fails"
exit [int]($script:fails -gt 0)
