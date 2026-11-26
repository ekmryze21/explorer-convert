param([string]$Kind, [string]$Format, [string]$Batch)
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
. (Join-Path $PSScriptRoot 'core.ps1')

$script:title = T 'Convert'
$script:icon = New-Object Drawing.Icon (Join-Path $PSScriptRoot 'explorer-convert.ico')
$script:window = $null
$script:notify = $null

# The launcher starts this process hidden, and Windows applies that to the first window it shows.
# The decoy must keep its taskbar button, without one it does not count
$decoy = New-Object Windows.Forms.Form
$decoy.Opacity = 0
$decoy.Show()
$decoy.Dispose()

# Colors follow the Windows app theme
$personalize = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue
$script:dark = $personalize.AppsUseLightTheme -eq 0
$script:colors = if ($script:dark) {
    @{ Back = '#222226'; Card = '#343437'; Field = '#454549'; Off = '#5A5A5F'; Text = '#FFFFFF'; Accent = '#5B67CF' }
} else {
    @{ Back = '#FAFAFB'; Card = '#FFFFFF'; Field = '#EDEDF0'; Off = '#B9B9C0'; Text = '#2E2E32'; Accent = '#5B67CF' }
}
$script:xaml = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'window.xaml'))
if ($script:dark) {
    Add-Type -Namespace ExplorerConvert -Name Dwm -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);'
}

function New-Window([string]$heading, [string]$status) {
    $window = [Windows.Markup.XamlReader]::Parse($script:xaml)
    foreach ($name in $script:colors.Keys) {
        $window.Resources[$name] = (New-Object Windows.Media.BrushConverter).ConvertFromString($script:colors[$name])
    }
    $decoder = [Windows.Media.Imaging.BitmapDecoder]::Create([Uri](Join-Path $PSScriptRoot 'explorer-convert.ico'), 'None', 'OnLoad')
    $window.Icon = $decoder.Frames[0]
    $window.FindName('Logo').Source = $decoder.Frames | Sort-Object PixelWidth | Select-Object -Last 1
    $window.Title = $script:title
    $window.FindName('Heading').Text = $heading
    $window.FindName('Status').Text = $status
    $window.MaxHeight = [Windows.SystemParameters]::WorkArea.Height
    $window.Topmost = $true
    $window.Add_ContentRendered({ [void]$this.Activate(); $this.Topmost = $false })
    if ($script:dark) {
        # 20 is DWMWA_USE_IMMERSIVE_DARK_MODE; older Windows 10 ignores it
        $window.Add_SourceInitialized({
            $on = 1
            $handle = (New-Object Windows.Interop.WindowInteropHelper $this).Handle
            [void][ExplorerConvert.Dwm]::DwmSetWindowAttribute($handle, 20, [ref]$on, 4)
        })
    }
    $window
}

function Add-Card($window) {
    $card = New-Object Windows.Controls.Border
    $card.CornerRadius = New-Object Windows.CornerRadius 12
    $card.Padding = New-Object Windows.Thickness 14, 4, 14, 4
    $card.Margin = New-Object Windows.Thickness 0, 0, 0, 16
    $card.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, 'Card')
    $card.Child = New-Object Windows.Controls.StackPanel
    [void]$window.FindName('Body').Children.Add($card)
    $card.Child
}

function Add-Row($card, [string]$label, [string]$type) {
    $row = New-Object Windows.Controls.DockPanel
    $row.Margin = New-Object Windows.Thickness 0, 7, 0, 7
    $control = New-Object "Windows.Controls.$type"
    [Windows.Automation.AutomationProperties]::SetName($control, $label)
    if ($type -ne 'CheckBox') { $control.Width = 190 }
    [Windows.Controls.DockPanel]::SetDock($control, 'Right')
    $text = New-Object Windows.Controls.TextBlock
    $text.Text = $label
    $text.VerticalAlignment = 'Center'
    $text.TextWrapping = 'Wrap'
    $text.Margin = New-Object Windows.Thickness 0, 0, 12, 0
    [void]$row.Children.Add($control)
    [void]$row.Children.Add($text)
    [void]$card.Children.Add($row)
    $control
}

function Add-Button($window, [string]$text, [bool]$accent) {
    $button = New-Object Windows.Controls.Button
    $button.Content = $text
    $button.HorizontalAlignment = 'Center'
    if ($accent) {
        $button.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, 'Accent')
        $button.Foreground = [Windows.Media.Brushes]::White
    }
    [void]$window.FindName('Body').Children.Add($button)
    $button
}

function Show-Options([string]$kind, [string[]]$formats, $saved, [int]$count) {
    $window = New-Window $script:title "$(T 'Selected files'): $count"
    function Add-Combo($card, [string]$label, [string[]]$items, [int]$selected) {
        $c = Add-Row $card $label ComboBox
        foreach ($item in $items) { [void]$c.Items.Add($item) }
        $c.SelectedIndex = $selected
        $c
    }

    $heights = 0, 1080, 720, 480
    $heightBox = $startBox = $endBox = $sizeBox = $gpuBox = $null
    $card = Add-Card $window
    $formatBox = Add-Combo $card (T 'Format') @($formats | ForEach-Object { Get-Label $kind $_ }) ([array]::IndexOf($formats, $saved.Format))
    $qualityBox = Add-Combo $card (T 'Quality') @((T 'High'), (T 'Normal'), (T 'Small file')) $saved.Quality
    if ($kind -in 'video', 'image') { $heightBox = Add-Combo $card (T 'Max height') @((T 'Original'), '1080', '720', '480') ([array]::IndexOf($heights, $saved.Height)) }
    if ($kind -in 'video', 'audio') {
        $card = Add-Card $window
        $startBox = Add-Row $card "$(T 'Start') (0:15)" TextBox
        $endBox = Add-Row $card "$(T 'End') (1:30)" TextBox
        if ($kind -eq 'video') { $sizeBox = Add-Row $card (T 'Target size, MB') TextBox }
    }
    $card = Add-Card $window
    if ($kind -eq 'video') {
        $gpuBox = Add-Row $card (T 'Use GPU') CheckBox
        $gpuBox.IsChecked = $saved.Gpu
    }
    $stripBox = Add-Row $card (T 'Remove metadata') CheckBox
    $stripBox.IsChecked = $saved.Strip

    $ok = Add-Button $window (T 'Convert') $true
    $ok.IsDefault = $true
    $ok.Add_Click({ [Windows.Window]::GetWindow($this).DialogResult = $true })
    $window.Add_PreviewKeyDown({
        if ($_.Key -eq 'Escape' -and -not ($_.OriginalSource -is [Windows.Controls.ComboBoxItem])) { $this.Close() }
    })
    if (-not $window.ShowDialog()) { return $null }

    $text = { param($box) if ($box) { $box.Text.Trim() } else { '' } }
    @{
        Format = $formats[$formatBox.SelectedIndex]
        Quality = $qualityBox.SelectedIndex
        Height = if ($heightBox) { $heights[$heightBox.SelectedIndex] } else { 0 }
        Start = & $text $startBox
        End = & $text $endBox
        Size = & $text $sizeBox
        Gpu = [bool]($gpuBox -and $gpuBox.IsChecked)
        Strip = [bool]$stripBox.IsChecked
    }
}

function Update-Progress([int]$percent, [string]$text) {
    if (-not $script:window) {
        $script:canceled = $false
        $script:closing = $false
        $script:window = New-Window (T 'Converting') ''
        $script:bar = New-Object Windows.Controls.ProgressBar
        $script:bar.Margin = New-Object Windows.Thickness 0, 0, 0, 20
        [void]$script:window.FindName('Body').Children.Add($script:bar)
        $cancel = Add-Button $script:window (T 'Cancel') $false
        $cancel.IsCancel = $true
        $cancel.Add_Click({ $script:canceled = $true })
        $script:window.Add_Closing({ if (-not $script:closing) { $script:canceled = $true; $_.Cancel = $true } })
        $script:window.Show()
    }
    $script:window.FindName('Status').Text = $text
    $script:bar.Value = $percent
    # Handles everything queued above background priority, like DoEvents
    $script:window.Dispatcher.Invoke([Action]{ }, [Windows.Threading.DispatcherPriority]::Background)
    $script:canceled
}

function Close-Progress {
    if ($script:window) {
        $script:closing = $true
        $script:window.Close()
        $script:window = $null
    }
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
    $window = New-Window (T 'Failed') ''
    $window.Width = 560
    $box = New-Object Windows.Controls.TextBox
    $box.Text = $text
    $box.IsReadOnly = $true
    $box.TextWrapping = 'Wrap'
    $box.MaxHeight = 260
    $box.VerticalScrollBarVisibility = 'Auto'
    $box.Margin = New-Object Windows.Thickness 0, 0, 0, 16
    [void]$window.FindName('Body').Children.Add($box)
    $ok = Add-Button $window 'OK' $true
    $ok.IsDefault = $ok.IsCancel = $true
    $ok.Add_Click({ [Windows.Window]::GetWindow($this).Close() })
    $window.Add_Loaded({ [void]$this.MoveFocus((New-Object Windows.Input.TraversalRequest Last)) })
    [void]$window.ShowDialog()
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
