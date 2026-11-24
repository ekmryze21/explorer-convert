param([string]$Kind, [string]$Format, [string]$Batch)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
. (Join-Path $PSScriptRoot 'core.ps1')

$script:title = T 'Convert'
$script:icon = [Drawing.SystemIcons]::Application
$script:window = $null
$script:notify = $null

# The launcher starts this process hidden, and Windows applies that to the first window it shows.
# The decoy must keep its taskbar button, without one it does not count
$decoy = New-Object Windows.Forms.Form
$decoy.Opacity = 0
$decoy.Show()
$decoy.Dispose()

function New-Window([int]$width, [int]$height) {
    $form = New-Object Windows.Forms.Form
    $form.Text = $script:title
    $form.ClientSize = New-Object Drawing.Size $width, $height
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.StartPosition = 'CenterScreen'
    $form.Font = [Drawing.SystemFonts]::MessageBoxFont
    $form.TopMost = $true
    $form.Add_Shown({ $this.Activate(); $this.TopMost = $false })
    $form
}

function Add-Control($form, [string]$type, [int]$x, [int]$y, [int]$width, [int]$height, [string]$text) {
    $control = New-Object "Windows.Forms.$type"
    $control.SetBounds($x, $y, $width, $height)
    $control.Text = $text
    $form.Controls.Add($control)
    $control
}

function Show-Options([string]$kind, [string[]]$formats, $saved, [int]$count) {
    $form = New-Window 420 100
    $script:optionsY = 12
    [void](Add-Control $form Label 12 $script:optionsY 396 22 "$(T 'Selected files'): $count")
    $script:optionsY += 30

    function Add-Row([string]$label, [string]$type) {
        $l = Add-Control $form Label 12 ($script:optionsY + 3) 170 22 "${label}:"
        $l.AutoEllipsis = $true
        $c = Add-Control $form $type 186 $script:optionsY 222 24 ''
        $c.AccessibleName = $label
        $script:optionsY += 32
        $c
    }
    function Add-Combo([string]$label, [string[]]$items, [int]$selected) {
        $c = Add-Row $label ComboBox
        $c.DropDownStyle = 'DropDownList'
        [void]$c.Items.AddRange($items)
        $c.SelectedIndex = $selected
        $c
    }
    function Add-Check([string]$label, [bool]$checked) {
        $c = Add-Control $form CheckBox 12 $script:optionsY 396 24 $label
        $c.Checked = $checked
        $script:optionsY += 28
        $c
    }

    $heights = 0, 1080, 720, 480
    $formatBox = Add-Combo (T 'Format') @($formats | ForEach-Object { Get-Label $kind $_ }) ([array]::IndexOf($formats, $saved.Format))
    $qualityBox = Add-Combo (T 'Quality') @((T 'High'), (T 'Normal'), (T 'Small file')) $saved.Quality
    $heightBox = $startBox = $endBox = $sizeBox = $gpuBox = $null
    if ($kind -in 'video', 'image') { $heightBox = Add-Combo (T 'Max height') @((T 'Original'), '1080', '720', '480') ([array]::IndexOf($heights, $saved.Height)) }
    if ($kind -in 'video', 'audio') {
        $startBox = Add-Row "$(T 'Start') (0:15)" TextBox
        $endBox = Add-Row "$(T 'End') (1:30)" TextBox
    }
    if ($kind -eq 'video') {
        $sizeBox = Add-Row (T 'Target size, MB') TextBox
        $gpuBox = Add-Check (T 'Use GPU') $saved.Gpu
    }
    $stripBox = Add-Check (T 'Remove metadata') $saved.Strip

    $ok = Add-Control $form Button 308 ($script:optionsY + 8) 100 28 'OK'
    $ok.DialogResult = 'OK'
    $form.AcceptButton = $ok
    $form.CancelButton = New-Object Windows.Forms.Button  # Escape closes the dialog
    $form.CancelButton.DialogResult = 'Cancel'
    $form.CancelButton.SetBounds(-100, -100, 10, 10)
    $form.CancelButton.TabStop = $false
    $form.Controls.Add($form.CancelButton)
    $form.ClientSize = New-Object Drawing.Size 420, ($script:optionsY + 48)
    $result = $form.ShowDialog()
    $form.Dispose()
    if ($result -ne 'OK') { return $null }

    $text = { param($box) if ($box) { $box.Text.Trim() } else { '' } }
    @{
        Format = $formats[$formatBox.SelectedIndex]
        Quality = $qualityBox.SelectedIndex
        Height = if ($heightBox) { $heights[$heightBox.SelectedIndex] } else { 0 }
        Start = & $text $startBox
        End = & $text $endBox
        Size = & $text $sizeBox
        Gpu = [bool]($gpuBox -and $gpuBox.Checked)
        Strip = $stripBox.Checked
    }
}

function Update-Progress([int]$percent, [string]$text) {
    if (-not $script:window) {
        $script:canceled = $false
        $script:window = New-Window 420 112
        $script:label = Add-Control $script:window Label 12 12 396 22 (T 'Converting')
        $script:label.AutoEllipsis = $true
        $script:label.UseMnemonic = $false
        $script:bar = Add-Control $script:window ProgressBar 12 38 396 22 ''
        $cancel = Add-Control $script:window Button 308 72 100 28 (T 'Cancel')
        $cancel.Add_Click({ $script:canceled = $true })
        $script:window.CancelButton = $cancel
        $script:window.Add_FormClosing({ $script:canceled = $true; $_.Cancel = $true })
        $script:window.Show()
    }
    if ($script:label.Text -ne $text) { $script:label.Text = $text }
    if ($script:bar.Value -ne $percent) { $script:bar.Value = $percent }
    [Windows.Forms.Application]::DoEvents()
    $script:canceled
}

function Close-Progress {
    if ($script:window) { $script:window.Dispose(); $script:window = $null }
}

function Show-Done([string]$text, [string]$file) {
    Close-Progress
    $script:notify = New-Object Windows.Forms.NotifyIcon
    $script:notify.Icon = $script:icon
    $script:notify.Text = 'explorer-convert'
    $script:notify.Visible = $true
    $script:notifyFile = $file
    $script:notifyOver = $false
    $open = {
        if ($script:notifyFile) { Start-Process explorer.exe "/select,`"$($script:notifyFile)`"" }
        $script:notifyOver = $true
    }
    $script:notify.Add_BalloonTipClicked($open)
    $script:notify.Add_Click($open)
    $script:notify.Add_BalloonTipClosed({ $script:notifyOver = $true })
    $script:notify.ShowBalloonTip(10000, $script:title, $text, 'Info')
}

function Show-Error([string]$text) {
    Close-Progress
    $form = New-Window 560 260
    $box = Add-Control $form TextBox 12 12 536 198 $text
    $box.Multiline = $true
    $box.ReadOnly = $true
    $box.ScrollBars = 'Vertical'
    $box.Select(0, 0)
    $ok = Add-Control $form Button 448 220 100 28 'OK'
    $ok.DialogResult = 'OK'
    $form.AcceptButton = $form.CancelButton = $ok
    $form.ActiveControl = $ok
    [void]$form.ShowDialog()
    $form.Dispose()
}

# Above 100 selected files Explorer passes only one of them, so ask it for the rest
function Get-Selection([string[]]$files) {
    if ($files.Count -ne 1) { return $files }
    foreach ($window in (New-Object -ComObject Shell.Application).Windows()) {
        try {
            $items = $window.Document.SelectedItems()
            if ($items.Count -le 100) { continue }
            $paths = @($items | ForEach-Object { $_.Path } | Where-Object { [IO.File]::Exists($_) })
            if ($paths -contains $files[0]) { return Get-PageOrder $paths }
        } catch { continue }  # not a folder window
    }
    $files
}

try {
    $code = Invoke-Convert $Kind $Format @(Get-Selection @(Read-Batch $Batch))
    # The notification is clickable only while this process lives
    $deadline = [DateTime]::UtcNow.AddMinutes(1)
    while ($script:notify -and -not $script:notifyOver -and [DateTime]::UtcNow -lt $deadline) {
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }
} finally {
    if ($script:notify) { $script:notify.Dispose() }
}
exit $code
