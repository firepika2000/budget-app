[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms
Set-Location -LiteralPath $PSScriptRoot

$engine = Join-Path $PSScriptRoot "start-windows.ps1"
$environmentFile = Join-Path $PSScriptRoot ".env"
if (-not (Test-Path -LiteralPath $engine -PathType Leaf)) {
    [System.Windows.MessageBox]::Show(
        "The ClearPocket Server manager is incomplete. Reinstall the downloaded package.",
        "ClearPocket Server", "OK", "Error"
    ) | Out-Null
    exit 1
}

[xml] $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="ClearPocket Server" Width="760" Height="650" MinWidth="680" MinHeight="560"
        WindowStartupLocation="CenterScreen" Background="#F7F7FA">
  <Grid Margin="28">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <StackPanel Grid.Row="0" Margin="0,0,0,22">
      <TextBlock Text="ClearPocket Server" FontSize="28" FontWeight="SemiBold"/>
      <TextBlock Text="Your private household budget server" FontSize="14" Foreground="#555" Margin="0,4,0,0"/>
    </StackPanel>

    <Border Name="SetupPanel" Grid.Row="1" Padding="20" CornerRadius="12" Background="White" Margin="0,0,0,18">
      <StackPanel>
        <TextBlock Text="First-time setup" FontSize="20" FontWeight="SemiBold"/>
        <TextBlock Text="Choose where your database, encrypted attachments, and recovery status will live. ClearPocket generates private secrets automatically." TextWrapping="Wrap" Margin="0,6,0,16" Foreground="#444"/>
        <TextBlock Text="Data folder" FontWeight="SemiBold"/>
        <DockPanel Margin="0,6,0,14">
          <Button Name="BrowseButton" Content="Browse…" DockPanel.Dock="Right" Padding="14,7" Margin="8,0,0,0"/>
          <TextBox Name="StorageBox" Padding="8" VerticalContentAlignment="Center"/>
        </DockPanel>
        <TextBlock Text="Public HTTPS hostname (optional)" FontWeight="SemiBold"/>
        <TextBox Name="HostBox" Padding="8" Margin="0,6,0,4" VerticalContentAlignment="Center"/>
        <TextBlock Text="Leave blank for this-PC-only setup. Remote iPhone pairing requires a DNS hostname that already points here; never expose raw port 8080." TextWrapping="Wrap" Foreground="#666" FontSize="12"/>
        <Button Name="ConfigureButton" Content="Set Up and Open Server" HorizontalAlignment="Left" Padding="18,9" Margin="0,18,0,0" Background="#2563EB" Foreground="White" FontWeight="SemiBold"/>
      </StackPanel>
    </Border>

    <Border Name="ManagePanel" Grid.Row="1" Padding="20" CornerRadius="12" Background="White" Margin="0,0,0,18" Visibility="Collapsed">
      <StackPanel>
        <TextBlock Text="Server controls" FontSize="20" FontWeight="SemiBold"/>
        <WrapPanel Margin="0,14,0,0">
          <Button Name="OpenButton" Content="Start &amp; Open" Padding="18,9" Margin="0,0,10,10" Background="#2563EB" Foreground="White" FontWeight="SemiBold"/>
          <Button Name="StatusButton" Content="Refresh Status" Padding="18,9" Margin="0,0,10,10"/>
          <Button Name="StopButton" Content="Stop Safely" Padding="18,9" Margin="0,0,10,10"/>
          <Button Name="DiagnosticsButton" Content="Create Diagnostics" Padding="18,9" Margin="0,0,10,10"/>
          <Button Name="LogsButton" Content="Recent Logs" Padding="18,9" Margin="0,0,10,10"/>
          <Button Name="AdvancedButton" Content="Backup, Restore &amp; Advanced…" Padding="18,9" Margin="0,0,10,10"/>
        </WrapPanel>
        <TextBlock Text="Stopping preserves the database, attachments, private configuration, and backups." TextWrapping="Wrap" Foreground="#666" FontSize="12" Margin="0,4,0,0"/>
      </StackPanel>
    </Border>

    <Border Grid.Row="2" Padding="16" CornerRadius="10" Background="#111827">
      <DockPanel>
        <TextBlock Name="StateText" DockPanel.Dock="Top" Text="Ready" Foreground="#93C5FD" FontWeight="SemiBold" Margin="0,0,0,8"/>
        <TextBox Name="OutputBox" IsReadOnly="True" TextWrapping="Wrap" AcceptsReturn="True"
                 VerticalScrollBarVisibility="Auto" Background="Transparent" BorderThickness="0"
                 Foreground="#E5E7EB" FontFamily="Consolas" FontSize="12"/>
      </DockPanel>
    </Border>
    <TextBlock Grid.Row="3" Text="ClearPocket keeps authority in your selected data folder. Reinstalling the manager never removes it." TextWrapping="Wrap" Foreground="#666" FontSize="12" Margin="0,14,0,0"/>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$setupPanel = $window.FindName("SetupPanel")
$managePanel = $window.FindName("ManagePanel")
$storageBox = $window.FindName("StorageBox")
$hostBox = $window.FindName("HostBox")
$outputBox = $window.FindName("OutputBox")
$stateText = $window.FindName("StateText")
$actionNames = @("BrowseButton", "ConfigureButton", "OpenButton", "StatusButton", "StopButton", "DiagnosticsButton", "LogsButton", "AdvancedButton")
$actionButtons = @{}
foreach ($name in $actionNames) { $actionButtons[$name] = $window.FindName($name) }

$storageBox.Text = Join-Path $env:LOCALAPPDATA "ClearPocket Server\Data"

function Set-ConfiguredView([bool] $Configured) {
    $setupPanel.Visibility = if ($Configured) { [Windows.Visibility]::Collapsed } else { [Windows.Visibility]::Visible }
    $managePanel.Visibility = if ($Configured) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
}

function Set-ActionsEnabled([bool] $Enabled) {
    foreach ($button in $actionButtons.Values) { $button.IsEnabled = $Enabled }
}

function Invoke-ManagerOperation([string] $Operation, [hashtable] $Environment = @{}) {
    Set-ActionsEnabled $false
    $stateText.Text = "$Operation in progress…"
    $outputBox.Text = ""
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $PSHOME "powershell.exe"
    $quotedEngine = '"' + $engine.Replace('"', '') + '"'
    $info.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $quotedEngine -Operation $Operation"
    $info.WorkingDirectory = $PSScriptRoot
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($entry in $Environment.GetEnumerator()) { $info.EnvironmentVariables[$entry.Key] = [string] $entry.Value }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    $append = {
        param($sender, $eventArguments)
        $line = $eventArguments.Data
        if ($null -ne $line) {
            $updateOutput = {
                $outputBox.AppendText($line + [Environment]::NewLine)
                $outputBox.ScrollToEnd()
            }.GetNewClosure()
            $window.Dispatcher.BeginInvoke([Action] $updateOutput) | Out-Null
        }
    }.GetNewClosure()
    $process.add_OutputDataReceived($append)
    $process.add_ErrorDataReceived($append)
    $process.EnableRaisingEvents = $true
    $process.add_Exited({
        param($sender, $eventArguments)
        $exitCode = $sender.ExitCode
        $completedOperation = $Operation
        $completedProcess = $sender
        $complete = {
            Set-ActionsEnabled $true
            if ($exitCode -eq 0) {
                Set-ConfiguredView (Test-Path -LiteralPath $environmentFile -PathType Leaf)
                $stateText.Text = "$completedOperation completed"
            } else {
                $stateText.Text = "$completedOperation needs attention"
            }
            $completedProcess.Dispose()
        }.GetNewClosure()
        $window.Dispatcher.BeginInvoke([Action] $complete) | Out-Null
    }.GetNewClosure())
    try {
        if (-not $process.Start()) { throw "The server manager process could not start." }
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()
    } catch {
        Set-ActionsEnabled $true
        $stateText.Text = "Action could not start"
        $outputBox.Text = $_.Exception.Message
        $process.Dispose()
    }
}

$actionButtons["BrowseButton"].Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Choose durable ClearPocket Server storage"
    $dialog.SelectedPath = $storageBox.Text
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $storageBox.Text = $dialog.SelectedPath }
    $dialog.Dispose()
})
$actionButtons["ConfigureButton"].Add_Click({
    if ([string]::IsNullOrWhiteSpace($storageBox.Text)) {
        $stateText.Text = "Choose a data folder before setup."
        return
    }
    Invoke-ManagerOperation "Configure" @{
        CLEARPOCKET_SETUP_STORAGE_ROOT = $storageBox.Text
        CLEARPOCKET_SETUP_PUBLIC_HOST = $hostBox.Text
    }
})
$actionButtons["OpenButton"].Add_Click({ Invoke-ManagerOperation "Open" })
$actionButtons["StatusButton"].Add_Click({ Invoke-ManagerOperation "Status" })
$actionButtons["StopButton"].Add_Click({ Invoke-ManagerOperation "Stop" })
$actionButtons["DiagnosticsButton"].Add_Click({ Invoke-ManagerOperation "Diagnostics" })
$actionButtons["LogsButton"].Add_Click({ Invoke-ManagerOperation "Logs" })
$actionButtons["AdvancedButton"].Add_Click({
    Start-Process -FilePath (Join-Path $PSScriptRoot "start-windows.cmd") -WorkingDirectory $PSScriptRoot
})

Set-ConfiguredView (Test-Path -LiteralPath $environmentFile -PathType Leaf)
if (Test-Path -LiteralPath $environmentFile -PathType Leaf) { Invoke-ManagerOperation "Status" }
$window.ShowDialog() | Out-Null
