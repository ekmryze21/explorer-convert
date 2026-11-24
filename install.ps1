param([switch]$Uninstall)
$ErrorActionPreference = 'Stop'
$target = Join-Path $env:LOCALAPPDATA 'explorer-convert'
$hkcu = [Microsoft.Win32.Registry]::CurrentUser
$classes = 'Software\Classes'
$types = "$classes\SystemFileAssociations"
$verb = 'ExplorerConvert'

$video = '.mp4', '.m4v', '.mkv', '.webm', '.avi', '.mov', '.wmv', '.flv', '.mpg', '.mpeg', '.ts', '.mts', '.m2ts', '.3gp', '.ogv', '.vob'
$audio = '.mp3', '.m4a', '.aac', '.opus', '.ogg', '.oga', '.flac', '.wav', '.wma', '.aiff', '.aif', '.mka', '.ac3', '.amr'
$image = '.jpg', '.jpeg', '.jfif', '.png', '.webp', '.gif', '.bmp', '.tif', '.tiff', '.avif', '.jxl', '.svg', '.ico'

# '-' draws a separator before the next action
$menus = @(
    @{ Name = 'video'; Kind = 'video'; Extensions = $video
        Actions = @('h264', 'MP4'), @('vp9', 'WebM'), @('gif', 'GIF'), @('mp3', 'MP3 (audio only)'), '-',
            @('copy-mp4', 'MP4 (no re-encoding)'), @('10mb', 'MP4, up to 10 MB'), '-', @('ask', 'More options…') }
    @{ Name = 'audio'; Kind = 'audio'; Extensions = $audio
        Actions = @('mp3', 'MP3'), @('m4a', 'M4A'), @('opus', 'Opus'), @('ogg', 'OGG'), @('flac', 'FLAC'), @('wav', 'WAV'), '-', @('ask', 'More options…') }
    @{ Name = 'image'; Kind = 'image'; Extensions = $image
        Actions = @('jpg', 'JPG'), @('png', 'PNG'), @('webp', 'WebP'), @('avif', 'AVIF'), @('jxl', 'JXL'), '-',
            @('pdf', 'PDF'), @('pdf-one', 'PDF (one file)'), '-', @('ask', 'More options…') }
    @{ Name = 'pdf'; Kind = 'pdf'; Extensions = , '.pdf'; Actions = @('png', 'PNG'), @('jpg', 'JPG'), @('txt', 'TXT') }
    @{ Name = 'document'; Kind = 'office'; Extensions = '.odt', '.docx', '.doc', '.rtf'; Actions = @('pdf', 'PDF'), @('docx', 'DOCX'), @('odt', 'ODT') }
    @{ Name = 'spreadsheet'; Kind = 'office'; Extensions = '.ods', '.xlsx', '.xls', '.csv'
        Actions = @('pdf', 'PDF'), @('xlsx', 'XLSX'), @('ods', 'ODS'), @('csv', 'CSV') }
    @{ Name = 'presentation'; Kind = 'office'; Extensions = '.odp', '.pptx', '.ppt'; Actions = @('pdf', 'PDF'), @('pptx', 'PPTX'), @('odp', 'ODP') }
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

Remove-Menu
if ($Uninstall) {
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    return
}

[void](New-Item -ItemType Directory -Path $target -Force)
foreach ($name in 'launch.js', 'core.ps1', 'explorer-convert.ps1', 'lang.json') {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $target -Force
    Unblock-File -LiteralPath (Join-Path $target $name)
}

. (Join-Path $target 'core.ps1')
$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
foreach ($menu in $menus) {
    $submenu = "$verb.$($menu.Name)"
    # Keys are shown in name order, hence the number. The default selection model stops at 15 files.
    $n = 0
    $separator = $false
    foreach ($action in $menu.Actions) {
        if ($action -is [string]) { $separator = $true; continue }
        $format, $label = $action
        $path = '{0}\{1}\shell\{2:d2}{3}' -f $classes, $submenu, $n, $format
        $values = @{ MUIVerb = T $label; MultiSelectModel = 'Player' }
        if ($separator) { $values.CommandFlags = 0x20 }
        Set-Key $path $values
        Set-Key "$path\command" @{ '' = "`"$wscript`" //nologo //E:JScript `"$target\launch.js`" $($menu.Kind) $format `"%1`"" }
        $separator = $false
        $n++
    }
    foreach ($ext in $menu.Extensions) {
        Set-Key "$types\$ext\shell\$verb" @{ MUIVerb = T 'Convert to…'; ExtendedSubCommandsKey = $submenu; MultiSelectModel = 'Player' }
    }
}
Write-Host "Installed to $target"

$packages = @(
    @{ Id = 'Gyan.FFmpeg'; Tools = 'ffmpeg', 'ffprobe' }
    @{ Id = 'ImageMagick.ImageMagick'; Tools = , 'magick' }
    @{ Id = 'oschwartz10612.Poppler'; Tools = 'pdftoppm', 'pdftotext', 'pdfunite' }
    @{ Id = 'TheDocumentFoundation.LibreOffice'; Tools = , 'soffice'; Note = ' (optional, only for office documents)' }
)
foreach ($package in $packages) {
    $missing = @($package.Tools | Where-Object { -not (Find-Tool $_) })
    if ($missing) {
        Write-Host "Missing: $($missing -join ', ')$($package.Note)"
        Write-Host "  winget install -e --id $($package.Id)"
    }
}
