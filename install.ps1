param([switch]$Uninstall, [switch]$ClassicMenu, [switch]$ModernMenu)
$ErrorActionPreference = 'Stop'
$target = Join-Path $env:LOCALAPPDATA 'explorer-convert'
$hkcu = [Microsoft.Win32.Registry]::CurrentUser
$classes = 'Software\Classes'
$types = "$classes\SystemFileAssociations"
$verb = 'ExplorerConvert'

$video = '.mp4', '.m4v', '.mkv', '.webm', '.avi', '.mov', '.wmv', '.flv', '.mpg', '.mpeg', '.ts', '.mts', '.m2ts', '.3gp', '.ogv', '.vob'
$audio = '.mp3', '.m4a', '.aac', '.opus', '.ogg', '.oga', '.flac', '.wav', '.wma', '.aiff', '.aif', '.mka', '.ac3', '.amr'
$image = '.jpg', '.jpeg', '.jfif', '.png', '.webp', '.gif', '.bmp', '.tif', '.tiff', '.avif', '.jxl', '.svg', '.ico',
    '.heic', '.heif', '.dng', '.cr2', '.cr3', '.nef', '.arw', '.raf', '.orf', '.rw2', '.pef', '.srw'

# '-' draws a separator before the next action
$menus = @(
    @{ Name = 'video'; Kind = 'video'; Extensions = $video
        Actions = @('h264', 'MP4'), @('vp9', 'WebM'), @('gif', 'GIF'), @('mp3', 'MP3 (audio only)'), '-',
            @('copy-mp4', 'MP4 (no re-encoding)'), @('10mb', 'MP4, up to 10 MB'), '-',
            @('mute', 'Remove sound'), @('rotate-left', 'Rotate left'), @('rotate-right', 'Rotate right'), @('srt', 'Extract subtitles (SRT)'), '-', @('ask', 'More options…') }
    @{ Name = 'audio'; Kind = 'audio'; Extensions = $audio
        Actions = @('mp3', 'MP3'), @('m4a', 'M4A'), @('opus', 'Opus'), @('ogg', 'OGG'), @('flac', 'FLAC'), @('wav', 'WAV'), '-', @('ask', 'More options…') }
    @{ Name = 'image'; Kind = 'image'; Extensions = $image
        Actions = @('jpg', 'JPG'), @('png', 'PNG'), @('webp', 'WebP'), @('avif', 'AVIF'), @('jxl', 'JXL'), '-',
            @('pdf', 'PDF'), @('pdf-one', 'PDF (one file)'), '-', @('ask', 'More options…') }
    @{ Name = 'pdf'; Kind = 'pdf'; Extensions = , '.pdf'
        Actions = @('png', 'PNG'), @('jpg', 'JPG'), @('txt', 'TXT'), '-',
            @('merge', 'Merge into one PDF'), @('split', 'Split into pages'), @('compress', 'Compress'), @('ocr', 'Recognize text (OCR)') }
    @{ Name = 'document'; Kind = 'office'; Extensions = '.odt', '.docx', '.doc', '.rtf'; Actions = @('pdf', 'PDF'), @('docx', 'DOCX'), @('odt', 'ODT') }
    @{ Name = 'spreadsheet'; Kind = 'office'; Extensions = '.ods', '.xlsx', '.xls', '.csv'
        Actions = @('pdf', 'PDF'), @('xlsx', 'XLSX'), @('ods', 'ODS'), @('csv', 'CSV') }
    @{ Name = 'presentation'; Kind = 'office'; Extensions = '.odp', '.pptx', '.ppt'; Actions = @('pdf', 'PDF'), @('pptx', 'PPTX'), @('odp', 'ODP') }
    @{ Name = 'ebook'; Kind = 'ebook'; Extensions = '.epub', '.mobi', '.azw3', '.fb2'
        Actions = @('epub', 'EPUB'), @('mobi', 'MOBI'), @('azw3', 'AZW3'), @('pdf', 'PDF'), @('txt', 'TXT') }
)

function Remove-IfEmpty($path) {
    $key = $hkcu.OpenSubKey($path)
    if (-not $key) { return }
    $empty = $key.SubKeyCount -eq 0 -and $key.ValueCount -eq 0
    $key.Close()
    if ($empty) { $hkcu.DeleteSubKey($path) }
}

function Remove-Menu {
    $key = $hkcu.OpenSubKey($types)
    if ($key) {
        foreach ($ext in $key.GetSubKeyNames()) {
            $own = $hkcu.OpenSubKey("$types\$ext\shell\$verb")
            if (-not $own) { continue }
            $own.Close()
            $hkcu.DeleteSubKeyTree("$types\$ext\shell\$verb")
            Remove-IfEmpty "$types\$ext\shell"
            Remove-IfEmpty "$types\$ext"
        }
        $key.Close()
    }
    foreach ($menu in $menus) { $hkcu.DeleteSubKeyTree("$classes\$verb.$($menu.Name)", $false) }
}

# CreateSubKey opens an existing key; New-Item -Force would wipe it
function Set-Key($path, $values) {
    $key = $hkcu.CreateSubKey($path)
    foreach ($name in $values.Keys) { $key.SetValue($name, $values[$name]) }
    $key.Close()
}

# An empty server for the Windows 11 menu makes Explorer show the classic one
$modern = "$classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}"
$settings = 'Software\explorer-convert'

function Test-Key($path) {
    $key = $hkcu.OpenSubKey($path)
    if ($key) { $key.Close() }
    [bool]$key
}

function Enable-ClassicMenu {
    if (Test-Key "$modern\InprocServer32") {
        Write-Host 'The classic menu is already on'
        return $false
    }
    Set-Key "$modern\InprocServer32" @{ '' = '' }
    Set-Key $settings @{ ClassicMenu = 1 }
    Write-Host 'The classic menu is on'
    $true
}

function Disable-ClassicMenu {
    $changed = Test-Key $modern
    $hkcu.DeleteSubKeyTree($modern, $false)
    $hkcu.DeleteSubKeyTree($settings, $false)
    $changed
}

function Read-YesNo($question) {
    if ([Console]::IsInputRedirected -or -not [Environment]::UserInteractive) { return $false }
    try { (Read-Host "$question [y/N]") -match '^\s*y' } catch { $false }  # -NonInteractive
}

function Restart-Explorer {
    if (-not (Read-YesNo 'Restart Explorer now? Open folder windows will close.')) {
        Write-Host 'Restart Explorer or sign out to see the change'
        return
    }
    $session = (Get-Process -Id $PID).SessionId
    Get-Process explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session } | Stop-Process -Force
    Start-Sleep -Seconds 3
    # Windows normally starts it again by itself
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session })) { Start-Process explorer.exe }
}

$windows11 = [Environment]::OSVersion.Version.Build -ge 22000
if (@($Uninstall, $ClassicMenu, $ModernMenu | Where-Object { $_ }).Count -gt 1) { throw 'Use one option at a time' }
if ($ClassicMenu) {
    if (-not $windows11) { Write-Host 'Only Windows 11 has the new menu'; return }
    if (Enable-ClassicMenu) { Restart-Explorer }
    return
}
if ($ModernMenu) {
    if (Disable-ClassicMenu) { Write-Host 'The Windows 11 menu is on'; Restart-Explorer }
    return
}

Remove-Menu
if ($Uninstall) {
    # Leave the classic menu alone if it was turned on elsewhere
    if ((Test-Key $settings) -and (Disable-ClassicMenu)) { Write-Host 'The Windows 11 menu is on'; Restart-Explorer }
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    return
}

[void](New-Item -ItemType Directory -Path $target -Force)
foreach ($name in 'launch.js', 'core.ps1', 'explorer-convert.ps1', 'window.xaml', 'explorer-convert.ico', 'menu-light.ico', 'menu-dark.ico', 'lang.json', 'VERSION') {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $target -Force
    Unblock-File -LiteralPath (Join-Path $target $name)
}

. (Join-Path $target 'core.ps1')
# Windows does not recolor menu icons, so pick the one that suits the app theme
$light = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue).AppsUseLightTheme
$menuIcon = Join-Path $target $(if ($light -eq 0) { 'menu-dark.ico' } else { 'menu-light.ico' })
$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
foreach ($menu in $menus) {
    $submenu = "$verb.$($menu.Name)"
    # Keys are shown in name order, hence the number. The default selection model stops at 15 files.
    $n = 0
    $separator = $false
    foreach ($action in $menu.Actions) {
        if ($action -is [string]) { $separator = $true; continue }
        $format, $label = $action
        if (@(Get-ActionTools $menu.Kind $format | Where-Object { -not (Find-Tool $_) })) { continue }
        $path = '{0}\{1}\shell\{2:d2}{3}' -f $classes, $submenu, $n, $format
        $values = @{ MUIVerb = T $label; MultiSelectModel = 'Player' }
        if ($separator -and $n) { $values.CommandFlags = 0x20 }
        Set-Key $path $values
        Set-Key "$path\command" @{ '' = "`"$wscript`" //nologo //E:JScript `"$target\launch.js`" $($menu.Kind) $format `"%1`"" }
        $separator = $false
        $n++
    }
    if (-not $n) { continue }
    foreach ($ext in $menu.Extensions) {
        Set-Key "$types\$ext\shell\$verb" @{ MUIVerb = T 'Convert to…'; Icon = $menuIcon; ExtendedSubCommandsKey = $submenu; MultiSelectModel = 'Player' }
    }
}
Write-Host "explorer-convert $([IO.File]::ReadAllText((Join-Path $target 'VERSION')).Trim()) installed to $target"

$packages = @(
    @{ Get = 'winget install -e --id Gyan.FFmpeg'; Tools = 'ffmpeg', 'ffprobe' }
    @{ Get = 'winget install -e --id ImageMagick.ImageMagick'; Tools = , 'magick' }
    @{ Get = 'winget install -e --id oschwartz10612.Poppler'; Tools = 'pdftoppm', 'pdftotext', 'pdfunite', 'pdfseparate' }
    @{ Get = 'winget install -e --id TheDocumentFoundation.LibreOffice'; Tools = , 'soffice'; For = 'Office documents' }
    @{ Get = 'winget install -e --id calibre.calibre'; Tools = , 'ebook-convert'; For = 'E-books' }
    @{ Get = 'https://ghostscript.com/releases/gsdnld.html'; Tools = , 'gs'; For = 'PDF compression' }
    @{ Get = 'winget install -e --id tesseract-ocr.tesseract'; Tools = , 'tesseract'; For = 'Text recognition' }
    @{ Get = 'py -m pip install ocrmypdf'; Tools = , 'ocrmypdf'; For = 'Text recognition' }
)
$hint = @()
$missing = $false
foreach ($package in $packages) {
    $absent = @($package.Tools | Where-Object { -not (Find-Tool $_) })
    if (-not $absent) { continue }
    if ($package.For) {
        $hint += "  $($package.For): $($absent -join ', ')", "    $($package.Get)"
    } else {
        $missing = $true
        Write-Host "Missing: $($absent -join ', ')"
        Write-Host "  $($package.Get)"
    }
}
$tesseract = Find-Tool tesseract
if ($tesseract -and (Get-WinUserLanguageList).LanguageTag -match '^uk' -and @(& $tesseract --list-langs) -notcontains 'ukr') {
    $hint += "  Text recognition in Ukrainian: put ukr.traineddata into $(Join-Path (Split-Path $tesseract) 'tessdata')", '    https://github.com/tesseract-ocr/tessdata_fast'
}
if ($missing) { Write-Host 'Install them and run install.ps1 again: menus of missing tools are hidden' }
# Colors and picture of the logo
$logo = @(
    , @('Red', '            ⣾⣷⣶⣦⣄  ', '')
    , @('Red', '           ⢰⣿⣿⣿⣿⣿⣦ ', '')
    , @('Red', '           ⣾⣿⣿⣿⣿⣿⡏ ', '')
    , @('Red', '           ⠛⠛⠿⢿⣿⣿⠁ ', 'explorer-convert')
    , @('Blue', '      ⢀⣠⣤⣤⣤⣀⣠⣴⣶    ', '')
    , @('Blue', '  ⠰⢶⣿⣿⣿⣿⣿⣿⣿⣿⣿⠟⠁    ', '')
    , @('Blue', '    ⢹⣿⣿⣿⣿⣿⣿⠋⠁      ', 'Right-click a file in Explorer')
    , @('Blue', '    ⢸⣿⣿⡿⠛⢿⣿⡆       ', 'and choose')
    , @('Blue', '    ⠈⢿⣿⣧           ', '')
    , @('Blue', '      ⠹⣿⣿⡷⢦        ', '')
    , @('Blue', '       ⠿⠁          ', '')
)
function Show-Logo {
    if ([Console]::IsOutputRedirected) { return }
    $version = [IO.File]::ReadAllText((Join-Path $target 'VERSION')).Trim()
    Write-Host
    foreach ($row in $logo) {
        $color, $picture, $text = $row
        Write-Host "  $picture  " -ForegroundColor $color -NoNewline
        if ($text -eq 'explorer-convert') { Write-Host "$text $version is ready" }
        elseif ($text -eq 'and choose') { Write-Host "$text $(T "Convert to$([char]0x2026)")" }
        else { Write-Host $text }
    }
    Write-Host
}
Show-Logo
if ($hint) {
    Write-Host 'Optional. Install and run install.ps1 again to get:'
    $hint | Write-Host
}

if ($windows11 -and -not (Test-Key "$modern\InprocServer32")) {
    Write-Host 'On Windows 11 the menu is under Show more options (Shift + right click)'
    if (Read-YesNo 'Always open the classic menu instead of the new one?') {
        if (Enable-ClassicMenu) { Restart-Explorer }
    }
}
