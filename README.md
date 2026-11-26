<img src="explorer-convert.svg" width="96" alt="">

# explorer-convert

Adds a **Convert to…** submenu to the Windows Explorer context menu for video, audio, images, PDF and office documents. Results are saved next to the originals, which are never modified or overwritten.

A Windows version of [dolphin-convert](https://github.com/ekmryze21/dolphin-convert).

| Files | Formats |
| --- | --- |
| Video | MP4 (H.264, H.265, AV1), WebM (VP9), GIF, MP3, MP4 and MKV without re-encoding |
| Audio | MP3, M4A, Opus, OGG, FLAC, WAV |
| Images | JPG, PNG, WebP, AVIF, JXL, TIFF, GIF, BMP, ICO, PDF (one per image, or all images in one) |
| PDF | PNG and JPG (a folder if there are several pages), TXT |
| Documents | PDF, DOCX, ODT |
| Spreadsheets | PDF, XLSX, ODS, CSV (first sheet) |
| Presentations | PDF, PPTX, ODP |

Common conversions are one click away. **More options…** (video, audio, images) adds quality, and where it applies maximum height, trimming, a target file size, metadata removal and GPU encoding. Format, quality, height, metadata and GPU choices are remembered.

Available in English, Ukrainian, German, Spanish, French, Polish, Dutch and Catalan, following the system language.

## Where is the menu?

On Windows 11 the submenu is in the classic menu: **Show more options**, or **Shift + right click**. On Windows 10 it is in the normal context menu.

## Requirements

- Windows 10 or 11 with Windows PowerShell 5.1 (built in) and Windows Script Host enabled (the default)
- [FFmpeg](https://ffmpeg.org/download.html) for video and audio, and for AVIF images
- [ImageMagick 7](https://imagemagick.org/script/download.php#windows) for images
- [Poppler](https://github.com/oschwartz10612/poppler-windows/releases) for PDF
- [LibreOffice](https://www.libreoffice.org/download/) for office documents, optional

```powershell
winget install -e --id Gyan.FFmpeg
winget install -e --id ImageMagick.ImageMagick
winget install -e --id oschwartz10612.Poppler
winget install -e --id TheDocumentFoundation.LibreOffice
```

The tools' own installers may ask for administrator rights; explorer-convert itself needs none.

## Install

[Download](../../archive/HEAD.zip) and unpack the repository, open PowerShell in its folder and run:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

This changes the execution policy for that one command only. The program is copied to `%LOCALAPPDATA%\explorer-convert` and the menu is registered for the current user. Any missing tool is listed with the command that installs it. After changing the system language or switching between light and dark mode, run the installer again to update the menu.

## Notes

- Files selected together are converted together, pages of a joint PDF go in natural name order (2 before 10). The same action started on two selections within a few seconds is treated as one.
- Explorer hands over at most 100 files. Larger selections are read from the Explorer window, which does not work for files on the desktop itself: select up to 100 there.
- Trimming without re-encoding cuts at the nearest keyframe.
- GPU encoding (NVENC, QSV or AMF) applies to H.264 and H.265 and falls back to the CPU. A target size always uses the CPU.
- Animated images are converted as their first frame.
- Converting from AVIF drops transparency; converting to AVIF keeps it.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
```

## Development

`powershell -ExecutionPolicy Bypass -File test.ps1` runs real conversions in a temporary folder with stubbed dialogs. It also runs in PowerShell 7 on Linux, without the launcher part. Add languages in `lang.json`.

## License

[MIT](LICENSE)
