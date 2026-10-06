#requires -Version 5.1
<#
    WinCare - WPF front end
    ---------------------------------------------------------------------------
    * Windows 11 look: system theme (light/dark), system accent color,
      dark title bar, Segoe UI Variable / Segoe Fluent Icons.
    * Every operation runs in a background runspace: the UI never freezes.
    * All text comes from ../lang/*.json. This file is ASCII-only.
    * Language / theme changes rebuild the window in place.
#>
param(
    # Screenshot mode (documentation and visual checks). Read-only: no button is
    # pressed and no setting is saved. Example:
    #   powershell -STA -File src\WinCare.ps1 -ScreenshotDir docs\screenshots -Language en -Theme dark
    [string]$ScreenshotDir = '',
    [string]$Language = '',
    [string]$Theme = '',
    [string]$CapturePages = 'NavOverview,NavCleanup,NavHealth,NavDisks,NavNetwork,NavActivity,NavSettings',
    [int]$Height = 0,
    [int]$Width = 0
)

$ErrorActionPreference = 'Stop'

$script:AppName    = 'WinCare'
$script:AppVersion = '1.3.0'
$script:ProjectUrl = 'https://github.com/borasavkar/WinCare'

$script:Root      = Split-Path -Parent $PSScriptRoot
$script:CorePath  = Join-Path $PSScriptRoot 'Core.psm1'
$script:LangDir   = Join-Path $script:Root 'lang'
$script:ConfigDir = Join-Path $env:APPDATA $script:AppName
$script:ConfigFile= Join-Path $script:ConfigDir 'settings.json'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

if (-not (Test-Path -LiteralPath $script:CorePath) -or -not (Test-Path -LiteralPath (Join-Path $script:LangDir 'en.json'))) {
    [void][System.Windows.MessageBox]::Show("Missing files. Expected:`n$script:CorePath`n$script:LangDir\en.json", $script:AppName, 'OK', 'Error')
    exit 1
}
Import-Module $script:CorePath -Force -DisableNameChecking

# =============================================================================
#  Settings
# =============================================================================
function Read-Settings {
    $s = [pscustomobject]@{ Language = ''; Theme = 'system' }
    try {
        if (Test-Path -LiteralPath $script:ConfigFile) {
            $j = [IO.File]::ReadAllText($script:ConfigFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($j.Language) { $s.Language = [string]$j.Language }
            if ($j.Theme)    { $s.Theme    = [string]$j.Theme }
        }
    } catch { }
    if (-not $s.Language) { $s.Language = Get-DefaultLanguageCode -Directory $script:LangDir }
    $s
}

function Save-Settings {
    try {
        if (-not (Test-Path -LiteralPath $script:ConfigDir)) { New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null }
        $json = [pscustomobject]@{ Language = $script:Settings.Language; Theme = $script:Settings.Theme } | ConvertTo-Json
        [IO.File]::WriteAllText($script:ConfigFile, $json, (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

$script:Settings = Read-Settings
if ($Language) { $script:Settings.Language = $Language }
if ($Theme)    { $script:Settings.Theme    = $Theme }
Initialize-Language -Directory $script:LangDir -Code $script:Settings.Language

if (-not $ScreenshotDir -and -not (Test-IsAdmin)) {
    [void][System.Windows.MessageBox]::Show((T 'app.needAdmin'), $script:AppName, 'OK', 'Warning')
    exit 1
}

# =============================================================================
#  Theme
# =============================================================================
function Test-SystemDark {
    try { return ((Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction Stop).AppsUseLightTheme -eq 0) }
    catch { return $true }
}

function Get-AccentColor {
    try {
        $a = (Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\DWM' -ErrorAction Stop).AccentColor
        return ('#{0:X2}{1:X2}{2:X2}' -f ($a -band 0xFF), (($a -shr 8) -band 0xFF), (($a -shr 16) -band 0xFF))
    } catch { return '#0067C0' }
}

function Get-Palette {
    $dark = switch ($script:Settings.Theme) { 'dark' { $true } 'light' { $false } default { Test-SystemDark } }
    $script:IsDark = $dark
    if ($dark) {
        $p = @{
            Bg='#202020'; Side='#1A1A1A'; Card='#2B2B2B'; CardAlt='#323232'; Stroke='#3A3A3A'; StrokeSoft='#333333'
            Text='#FFFFFF'; Text2='#C8C8C8'; Text3='#8A8A8A'; Hover='#2D2D2D'; Selected='#353535'
            Good='#6CCB5F'; GoodSoft='#1E3A1E'; Warn='#FCE100'; WarnSoft='#3D3712'; Bad='#FF99A4'; BadSoft='#442726'
            Btn='#373737'; BtnHover='#3D3D3D'; Scrim='#99000000'; Log='#1C1C1C'
        }
    } else {
        $p = @{
            Bg='#F3F3F3'; Side='#EBEBEB'; Card='#FFFFFF'; CardAlt='#F9F9F9'; Stroke='#E3E3E3'; StrokeSoft='#EDEDED'
            Text='#1B1B1B'; Text2='#5C5C5C'; Text3='#8B8B8B'; Hover='#E4E4E4'; Selected='#DCDCDC'
            Good='#0F7B0F'; GoodSoft='#DFF6DD'; Warn='#9D5D00'; WarnSoft='#FFF4CE'; Bad='#C42B1C'; BadSoft='#FDE7E9'
            Btn='#FBFBFB'; BtnHover='#F0F0F0'; Scrim='#66000000'; Log='#FAFAFA'
        }
    }
    $p.Accent = Get-AccentColor
    $p
}

# =============================================================================
#  Cleanup item type (live two-way binding, live totals)
# =============================================================================
if (-not ('WcCleanupItem' -as [type])) {
    Add-Type -ReferencedAssemblies PresentationCore, WindowsBase, System.Xaml -TypeDefinition @'
using System.ComponentModel;
using System.Windows;
public class WcCleanupItem : INotifyPropertyChanged {
    private bool _selected; private double _bytes; private string _size = "";
    public string Key { get; set; }
    public string Title { get; set; }
    public string Description { get; set; }
    public string Warning { get; set; }
    public Visibility WarningVisibility { get { return string.IsNullOrEmpty(Warning) ? Visibility.Collapsed : Visibility.Visible; } }
    public bool Selected { get { return _selected; } set { _selected = value; Raise("Selected"); } }
    public double Bytes  { get { return _bytes; }    set { _bytes = value;    Raise("Bytes"); } }
    public string SizeText { get { return _size; }   set { _size = value;     Raise("SizeText"); } }
    public event PropertyChangedEventHandler PropertyChanged;
    private void Raise(string n) { var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(n)); }
}
'@
}

if (-not ('WcShell' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class WcShell {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string id);
}
'@
}
# Own taskbar identity: WinCare is not grouped with other PowerShell windows
try { [void][WcShell]::SetCurrentProcessExplicitAppUserModelID('borasavkar.WinCare') } catch { }

if (-not ('WcDwm' -as [type])) {
    Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class WcDwm {
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int s);
}
'@
}

# =============================================================================
#  XAML
# =============================================================================
$script:XamlTemplate = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="@AppName@" Width="1120" Height="740" MinWidth="960" MinHeight="620"
        WindowStartupLocation="CenterScreen" Background="@Bg@"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14"
        TextOptions.TextFormattingMode="Display" UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <SolidColorBrush x:Key="Bg" Color="@Bg@"/>          <SolidColorBrush x:Key="Side" Color="@Side@"/>
    <SolidColorBrush x:Key="Card" Color="@Card@"/>      <SolidColorBrush x:Key="CardAlt" Color="@CardAlt@"/>
    <SolidColorBrush x:Key="Stroke" Color="@Stroke@"/>  <SolidColorBrush x:Key="StrokeSoft" Color="@StrokeSoft@"/>
    <SolidColorBrush x:Key="Text" Color="@Text@"/>      <SolidColorBrush x:Key="Text2" Color="@Text2@"/>
    <SolidColorBrush x:Key="Text3" Color="@Text3@"/>    <SolidColorBrush x:Key="Hover" Color="@Hover@"/>
    <SolidColorBrush x:Key="Selected" Color="@Selected@"/>
    <SolidColorBrush x:Key="Accent" Color="@Accent@"/>
    <SolidColorBrush x:Key="Good" Color="@Good@"/>      <SolidColorBrush x:Key="GoodSoft" Color="@GoodSoft@"/>
    <SolidColorBrush x:Key="Warn" Color="@Warn@"/>      <SolidColorBrush x:Key="WarnSoft" Color="@WarnSoft@"/>
    <SolidColorBrush x:Key="Bad" Color="@Bad@"/>        <SolidColorBrush x:Key="BadSoft" Color="@BadSoft@"/>
    <SolidColorBrush x:Key="Btn" Color="@Btn@"/>        <SolidColorBrush x:Key="BtnHover" Color="@BtnHover@"/>
    <SolidColorBrush x:Key="Scrim" Color="@Scrim@"/>    <SolidColorBrush x:Key="Log" Color="@Log@"/>
    <FontFamily x:Key="Icons">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>
    <FontFamily x:Key="Display">Segoe UI Variable Display, Segoe UI</FontFamily>

    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="{StaticResource Display}"/><Setter Property="FontSize" Value="28"/>
      <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Foreground" Value="{StaticResource Text}"/>
    </Style>
    <Style x:Key="H2" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="{StaticResource Display}"/><Setter Property="FontSize" Value="16"/>
      <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Foreground" Value="{StaticResource Text}"/>
    </Style>
    <Style x:Key="Body" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Text}"/><Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="Sub" TargetType="TextBlock">
      <Setter Property="FontSize" Value="13"/><Setter Property="Foreground" Value="{StaticResource Text2}"/>
      <Setter Property="TextWrapping" Value="Wrap"/><Setter Property="LineHeight" Value="19"/>
    </Style>
    <Style x:Key="Caption" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/><Setter Property="Foreground" Value="{StaticResource Text3}"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="State" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12.5"/><Setter Property="Foreground" Value="{StaticResource Text2}"/>
      <Setter Property="Margin" Value="0,6,0,0"/><Setter Property="TextWrapping" Value="Wrap"/>
      <Style.Triggers><Trigger Property="Text" Value=""><Setter Property="Visibility" Value="Collapsed"/></Trigger></Style.Triggers>
    </Style>
    <Style x:Key="Cmd" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Cascadia Mono, Consolas"/><Setter Property="FontSize" Value="11.5"/>
      <Setter Property="Foreground" Value="{StaticResource Text3}"/><Setter Property="Margin" Value="0,6,0,0"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="Input" TargetType="TextBox">
      <Setter Property="Foreground" Value="{StaticResource Text}"/><Setter Property="Background" Value="{StaticResource Btn}"/>
      <Setter Property="CaretBrush" Value="{StaticResource Text}"/><Setter Property="FontFamily" Value="Cascadia Mono, Consolas"/>
      <Setter Property="FontSize" Value="12.5"/><Setter Property="Padding" Value="10,7"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="TextBox">
          <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="6">
            <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="Pill" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource Text}"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,8,8"/><Setter Property="MinWidth" Value="56"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Border x:Name="b" CornerRadius="6" Padding="14,7" Background="{StaticResource Btn}" BorderBrush="{StaticResource Stroke}" BorderThickness="1">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{StaticResource BtnHover}"/></Trigger>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="b" Property="Background" Value="{StaticResource Accent}"/>
              <Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/>
              <Setter Property="Foreground" Value="White"/>
            </Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="Icon" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="{StaticResource Icons}"/><Setter Property="FontSize" Value="16"/>
      <Setter Property="VerticalAlignment" Value="Center"/><Setter Property="Foreground" Value="{StaticResource Text2}"/>
    </Style>

    <Style x:Key="CardBox" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource Card}"/><Setter Property="BorderBrush" Value="{StaticResource Stroke}"/>
      <Setter Property="BorderThickness" Value="1"/><Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="20"/><Setter Property="Margin" Value="0,0,0,12"/>
    </Style>
    <Style x:Key="Row" TargetType="Border" BasedOn="{StaticResource CardBox}">
      <Setter Property="Padding" Value="20,16"/><Setter Property="Margin" Value="0,0,0,6"/>
    </Style>

    <Style x:Key="Primary" TargetType="Button">
      <Setter Property="Foreground" Value="White"/><Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Padding" Value="22,10"/>
      <Setter Property="MinWidth" Value="120"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.9"/></Trigger>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.75"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="Secondary" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Text}"/><Setter Property="Background" Value="{StaticResource Btn}"/>
      <Setter Property="Padding" Value="18,9"/><Setter Property="MinWidth" Value="96"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{StaticResource Stroke}"
                  BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{StaticResource BtnHover}"/></Trigger>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.8"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="Subtle" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Accent}"/><Setter Property="Padding" Value="10,6"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" Background="Transparent" CornerRadius="6" Padding="{TemplateBinding Padding}">
            <ContentPresenter VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{StaticResource Hover}"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="Tile" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/><Setter Property="Margin" Value="0,0,12,0"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" Background="{StaticResource Card}" BorderBrush="{StaticResource Stroke}"
                  BorderThickness="1" CornerRadius="8" Padding="18,16">
            <ContentPresenter/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{StaticResource CardAlt}"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>

    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource Text}"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="8,1"/><Setter Property="GroupName" Value="nav"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Grid Height="38">
            <Border x:Name="bg" CornerRadius="6" Background="Transparent"/>
            <Border x:Name="pill" Width="3" Height="16" CornerRadius="2" Background="{StaticResource Accent}"
                    HorizontalAlignment="Left" Visibility="Collapsed"/>
            <StackPanel Orientation="Horizontal" Margin="14,0,0,0" VerticalAlignment="Center">
              <TextBlock Text="{TemplateBinding Tag}" FontFamily="{StaticResource Icons}" FontSize="16" Width="30"
                         VerticalAlignment="Center" Foreground="{TemplateBinding Foreground}"/>
              <ContentPresenter VerticalAlignment="Center"/>
            </StackPanel>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bg" Property="Background" Value="{StaticResource Hover}"/></Trigger>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="bg" Property="Background" Value="{StaticResource Selected}"/>
              <Setter TargetName="pill" Property="Visibility" Value="Visible"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="Choice" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource Text}"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,0,4"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Border x:Name="b" CornerRadius="6" Padding="12,10" Background="Transparent">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Grid Width="20" Height="20" VerticalAlignment="Center">
                <Ellipse x:Name="ring" Stroke="{StaticResource Text3}" StrokeThickness="1.5"/>
                <Ellipse x:Name="dot" Width="10" Height="10" Fill="White" Visibility="Collapsed"/>
              </Grid>
              <ContentPresenter Grid.Column="1" Margin="12,0,0,0" VerticalAlignment="Center"/>
            </Grid>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{StaticResource Hover}"/></Trigger>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="ring" Property="Fill" Value="{StaticResource Accent}"/>
              <Setter TargetName="ring" Property="Stroke" Value="{StaticResource Accent}"/>
              <Setter TargetName="dot" Property="Visibility" Value="Visible"/>
            </Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Text}"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="CheckBox">
          <StackPanel Orientation="Horizontal" Background="Transparent">
            <Border x:Name="box" Width="20" Height="20" CornerRadius="4" BorderThickness="1.5"
                    BorderBrush="{StaticResource Text3}" Background="Transparent" VerticalAlignment="Center">
              <TextBlock x:Name="tick" Text="&#xE73E;" FontFamily="{StaticResource Icons}" FontSize="12"
                         Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
            </Border>
            <ContentPresenter x:Name="cp" Margin="12,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
          <ControlTemplate.Triggers>
            <Trigger Property="Content" Value="{x:Null}"><Setter TargetName="cp" Property="Margin" Value="0"/></Trigger>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="box" Property="BorderBrush" Value="{StaticResource Text2}"/></Trigger>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="box" Property="Background" Value="{StaticResource Accent}"/>
              <Setter TargetName="box" Property="BorderBrush" Value="{StaticResource Accent}"/>
              <Setter TargetName="tick" Property="Visibility" Value="Visible"/>
            </Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>

    <Style x:Key="Thumb" TargetType="Thumb">
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Thumb">
          <Border x:Name="t" CornerRadius="3" Background="{StaticResource Text3}" Opacity="0.5"/>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="t" Property="Opacity" Value="0.85"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="12"/><Setter Property="MinWidth" Value="12"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ScrollBar">
          <Grid Background="Transparent">
            <Track x:Name="PART_Track" IsDirectionReversed="True" Margin="3,6">
              <Track.Thumb><Thumb Style="{StaticResource Thumb}"/></Track.Thumb>
            </Track>
          </Grid>
        </ControlTemplate>
      </Setter.Value></Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/><Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="12"/><Setter Property="MinHeight" Value="12"/>
          <Setter Property="Template"><Setter.Value>
            <ControlTemplate TargetType="ScrollBar">
              <Grid Background="Transparent">
                <Track x:Name="PART_Track" Margin="6,3"><Track.Thumb><Thumb Style="{StaticResource Thumb}"/></Track.Thumb></Track>
              </Grid>
            </ControlTemplate>
          </Setter.Value></Setter>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="Page" TargetType="ScrollViewer">
      <Setter Property="VerticalScrollBarVisibility" Value="Auto"/><Setter Property="Padding" Value="36,28,24,16"/>
    </Style>
    <Style x:Key="Bar" TargetType="ProgressBar">
      <Setter Property="Height" Value="6"/><Setter Property="Maximum" Value="100"/>
      <Setter Property="Background" Value="{StaticResource StrokeSoft}"/><Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ProgressBar">
          <Grid>
            <Border x:Name="PART_Track" CornerRadius="3" Background="{TemplateBinding Background}"/>
            <Border x:Name="PART_Indicator" CornerRadius="3" Background="{TemplateBinding Foreground}" HorizontalAlignment="Left"/>
          </Grid>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="248"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

    <!-- ============ SIDEBAR ============ -->
    <Border Grid.Column="0" Grid.RowSpan="2" Background="{StaticResource Side}">
      <DockPanel>
        <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="22,24,16,22">
          <Grid Width="32" Height="32">
            <Border CornerRadius="8" Background="{StaticResource Accent}">
              <TextBlock Text="&#xEA18;" FontFamily="{StaticResource Icons}" FontSize="17" Foreground="White"
                         HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <Image x:Name="LogoImage" RenderOptions.BitmapScalingMode="HighQuality"/>
          </Grid>
          <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="@AppName@" FontFamily="{StaticResource Display}" FontSize="17" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
            <TextBlock x:Name="TxtSideVersion" Text="" FontSize="11.5" Foreground="{StaticResource Text3}"/>
          </StackPanel>
        </StackPanel>
        <RadioButton x:Name="NavSettings" DockPanel.Dock="Bottom" Style="{StaticResource Nav}" Tag="&#xE713;" Content="[[nav.settings]]" Margin="8,1,8,14"/>
        <StackPanel>
          <RadioButton x:Name="NavOverview" Style="{StaticResource Nav}" Tag="&#xE80F;" Content="[[nav.overview]]" IsChecked="True"/>
          <RadioButton x:Name="NavCleanup"  Style="{StaticResource Nav}" Tag="&#xE74D;" Content="[[nav.cleanup]]"/>
          <RadioButton x:Name="NavHealth"   Style="{StaticResource Nav}" Tag="&#xEA18;" Content="[[nav.health]]"/>
          <RadioButton x:Name="NavDisks"    Style="{StaticResource Nav}" Tag="&#xEDA2;" Content="[[nav.disks]]"/>
          <RadioButton x:Name="NavNetwork"  Style="{StaticResource Nav}" Tag="&#xE839;" Content="[[nav.network]]"/>
          <RadioButton x:Name="NavActivity" Style="{StaticResource Nav}" Tag="&#xE81C;" Content="[[nav.activity]]"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- ============ PAGES ============ -->
    <Grid Grid.Column="1" Grid.Row="0">

      <!-- OVERVIEW -->
      <ScrollViewer x:Name="PageOverview" Style="{StaticResource Page}">
        <StackPanel MaxWidth="1000">
          <TextBlock Text="[[overview.title]]" Style="{StaticResource H1}" Margin="0,0,0,20"/>

          <Border Style="{StaticResource CardBox}" Padding="24">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <Border x:Name="HeroBadge" Width="56" Height="56" CornerRadius="28" Background="{StaticResource CardAlt}" VerticalAlignment="Center">
                <TextBlock x:Name="HeroIcon" Text="&#xE895;" FontFamily="{StaticResource Icons}" FontSize="26"
                           Foreground="{StaticResource Text2}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <StackPanel Grid.Column="1" Margin="20,0,20,0" VerticalAlignment="Center">
                <TextBlock x:Name="HeroTitle" Text="[[overview.checking]]" FontFamily="{StaticResource Display}" FontSize="21"
                           FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/>
                <TextBlock x:Name="HeroSub" Text="" Style="{StaticResource Sub}" Margin="0,4,0,0"/>
              </StackPanel>
              <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                <Button x:Name="BtnDeep" Style="{StaticResource Secondary}" Content="[[overview.deep]]" Margin="0,0,8,0"
                        ToolTip="[[overview.deep.tip]]"/>
                <Button x:Name="BtnQuick" Style="{StaticResource Primary}" Content="[[overview.quick]]"
                        ToolTip="[[overview.quick.tip]]"/>
              </StackPanel>
            </Grid>
          </Border>

          <Grid Margin="0,0,-12,12">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Button x:Name="TileClean" Grid.Column="0" Style="{StaticResource Tile}">
              <StackPanel>
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="&#xE74D;" Style="{StaticResource Icon}" FontSize="14"/>
                  <TextBlock Text="[[tile.clean]]" Style="{StaticResource Caption}" Margin="8,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>
                <TextBlock x:Name="TileCleanValue" Text="..." FontFamily="{StaticResource Display}" FontSize="22" FontWeight="SemiBold" Foreground="{StaticResource Text}" Margin="0,10,0,2"/>
                <TextBlock x:Name="TileCleanSub" Text="" Style="{StaticResource Caption}"/>
              </StackPanel>
            </Button>
            <Button x:Name="TileDisks" Grid.Column="1" Style="{StaticResource Tile}">
              <StackPanel>
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="&#xEDA2;" Style="{StaticResource Icon}" FontSize="14"/>
                  <TextBlock Text="[[tile.disks]]" Style="{StaticResource Caption}" Margin="8,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>
                <TextBlock x:Name="TileDisksValue" Text="..." FontFamily="{StaticResource Display}" FontSize="22" FontWeight="SemiBold" Foreground="{StaticResource Text}" Margin="0,10,0,2"/>
                <TextBlock x:Name="TileDisksSub" Text="" Style="{StaticResource Caption}"/>
              </StackPanel>
            </Button>
            <Button x:Name="TileProtect" Grid.Column="2" Style="{StaticResource Tile}">
              <StackPanel>
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="&#xEA18;" Style="{StaticResource Icon}" FontSize="14"/>
                  <TextBlock Text="[[tile.protection]]" Style="{StaticResource Caption}" Margin="8,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>
                <TextBlock x:Name="TileProtectValue" Text="..." FontFamily="{StaticResource Display}" FontSize="22" FontWeight="SemiBold" Foreground="{StaticResource Text}" Margin="0,10,0,2"/>
                <TextBlock x:Name="TileProtectSub" Text="" Style="{StaticResource Caption}"/>
              </StackPanel>
            </Button>
            <Button x:Name="TileNet" Grid.Column="3" Style="{StaticResource Tile}">
              <StackPanel>
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="&#xE839;" Style="{StaticResource Icon}" FontSize="14"/>
                  <TextBlock Text="[[tile.network]]" Style="{StaticResource Caption}" Margin="8,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>
                <TextBlock x:Name="TileNetValue" Text="..." FontFamily="{StaticResource Display}" FontSize="22" FontWeight="SemiBold" Foreground="{StaticResource Text}" Margin="0,10,0,2"/>
                <TextBlock x:Name="TileNetSub" Text="" Style="{StaticResource Caption}"/>
              </StackPanel>
            </Button>
          </Grid>

          <Border x:Name="CardAttention" Style="{StaticResource CardBox}" Visibility="Collapsed">
            <StackPanel>
              <TextBlock Text="[[overview.attention]]" Style="{StaticResource H2}" Margin="0,0,0,12"/>
              <ItemsControl x:Name="ListAttention">
                <ItemsControl.ItemTemplate>
                  <DataTemplate>
                    <Grid Margin="0,0,0,10">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="30"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="{Binding Glyph}" FontFamily="{StaticResource Icons}" FontSize="15" Foreground="{Binding Brush}" VerticalAlignment="Top" Margin="0,2,0,0"/>
                      <StackPanel Grid.Column="1">
                        <TextBlock Text="{Binding Title}" Style="{StaticResource Body}"/>
                        <TextBlock Text="{Binding Detail}" Style="{StaticResource Caption}" Margin="0,2,0,0"/>
                      </StackPanel>
                    </Grid>
                  </DataTemplate>
                </ItemsControl.ItemTemplate>
              </ItemsControl>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource CardBox}" Padding="20,16">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock Text="&#xEC4A;" Style="{StaticResource Icon}" FontSize="18"/>
              <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="14,0,16,0">
                <TextBlock Text="[[speed.title]]" Style="{StaticResource Body}" FontWeight="SemiBold"/>
                <TextBlock x:Name="OvSpeedSub" Text="[[speed.never]]" Style="{StaticResource Caption}" Margin="0,2,0,0"/>
              </StackPanel>
              <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,20,0">
                <StackPanel Orientation="Horizontal" Margin="0,0,18,0" ToolTip="[[speed.down]]">
                  <TextBlock Text="&#xE896;" Style="{StaticResource Icon}" FontSize="13" Margin="0,0,6,0"/>
                  <TextBlock x:Name="OvDown" Text="-" FontFamily="{StaticResource Display}" FontSize="17" FontWeight="SemiBold" Foreground="{StaticResource Text}" VerticalAlignment="Center"/>
                  <TextBlock Text="[[speed.mbps]]" Style="{StaticResource Caption}" VerticalAlignment="Center" Margin="4,2,0,0"/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0,0,18,0" ToolTip="[[speed.up]]">
                  <TextBlock Text="&#xE898;" Style="{StaticResource Icon}" FontSize="13" Margin="0,0,6,0"/>
                  <TextBlock x:Name="OvUp" Text="-" FontFamily="{StaticResource Display}" FontSize="17" FontWeight="SemiBold" Foreground="{StaticResource Text}" VerticalAlignment="Center"/>
                  <TextBlock Text="[[speed.mbps]]" Style="{StaticResource Caption}" VerticalAlignment="Center" Margin="4,2,0,0"/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0" ToolTip="[[speed.ping]]">
                  <TextBlock Text="&#xE916;" Style="{StaticResource Icon}" FontSize="13" Margin="0,0,6,0"/>
                  <TextBlock x:Name="OvPing" Text="-" FontFamily="{StaticResource Display}" FontSize="17" FontWeight="SemiBold" Foreground="{StaticResource Text}" VerticalAlignment="Center"/>
                  <TextBlock Text="[[speed.ms]]" Style="{StaticResource Caption}" VerticalAlignment="Center" Margin="4,2,0,0"/>
                </StackPanel>
              </StackPanel>
              <Button x:Name="BtnSpeedOverview" Grid.Column="3" Style="{StaticResource Secondary}" Content="[[speed.start]]" VerticalAlignment="Center"/>
            </Grid>
          </Border>

          <Border Style="{StaticResource CardBox}">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <StackPanel Grid.Column="0" Margin="0,0,12,0">
                <TextBlock Text="[[sys.os]]" Style="{StaticResource Caption}"/>
                <TextBlock x:Name="TxtOs" Text="..." Style="{StaticResource Body}" Margin="0,4,0,0"/>
              </StackPanel>
              <StackPanel Grid.Column="1" Margin="0,0,12,0">
                <TextBlock Text="[[sys.memory]]" Style="{StaticResource Caption}"/>
                <TextBlock x:Name="TxtMem" Text="..." Style="{StaticResource Body}" Margin="0,4,0,0"/>
              </StackPanel>
              <StackPanel Grid.Column="2">
                <TextBlock Text="[[sys.uptime]]" Style="{StaticResource Caption}"/>
                <TextBlock x:Name="TxtUptime" Text="..." Style="{StaticResource Body}" Margin="0,4,0,0"/>
              </StackPanel>
            </Grid>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- CLEANUP -->
      <Grid x:Name="PageCleanup" Visibility="Collapsed" Margin="36,28,24,16">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Margin="0,0,0,18">
          <TextBlock Text="[[cleanup.title]]" Style="{StaticResource H1}"/>
          <TextBlock Text="[[cleanup.sub]]" Style="{StaticResource Sub}" Margin="0,6,0,0"/>
        </StackPanel>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Padding="0,0,12,0">
          <ItemsControl x:Name="ListCleanup">
            <ItemsControl.ItemTemplate>
              <DataTemplate>
                <Border Style="{StaticResource Row}">
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <CheckBox IsChecked="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" VerticalAlignment="Center" Margin="0,0,16,0"/>
                    <StackPanel Grid.Column="1" VerticalAlignment="Center">
                      <TextBlock Text="{Binding Title}" Style="{StaticResource Body}"/>
                      <TextBlock Text="{Binding Description}" Style="{StaticResource Caption}" Margin="0,3,0,0"/>
                      <TextBlock Text="{Binding Warning}" Visibility="{Binding WarningVisibility}" FontSize="12"
                                 Foreground="{StaticResource Warn}" TextWrapping="Wrap" Margin="0,4,0,0"/>
                    </StackPanel>
                    <TextBlock Grid.Column="2" Text="{Binding SizeText}" FontWeight="SemiBold" Foreground="{StaticResource Text}"
                               VerticalAlignment="Center" Margin="16,0,0,0"/>
                  </Grid>
                </Border>
              </DataTemplate>
            </ItemsControl.ItemTemplate>
          </ItemsControl>
        </ScrollViewer>
        <Border Grid.Row="2" Style="{StaticResource CardBox}" Margin="0,10,12,0" Padding="20,14">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel VerticalAlignment="Center">
              <TextBlock Text="[[cleanup.selected]]" Style="{StaticResource Caption}"/>
              <TextBlock x:Name="TxtCleanTotal" Text="..." FontFamily="{StaticResource Display}" FontSize="20" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
            </StackPanel>
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
              <Button x:Name="BtnRemeasure" Style="{StaticResource Subtle}" Content="[[cleanup.remeasure]]" Margin="0,0,10,0"/>
              <Button x:Name="BtnClean" Style="{StaticResource Primary}" Content="[[cleanup.clean]]"/>
            </StackPanel>
          </Grid>
        </Border>
      </Grid>

      <!-- HEALTH -->
      <ScrollViewer x:Name="PageHealth" Style="{StaticResource Page}" Visibility="Collapsed">
        <StackPanel MaxWidth="1000">
          <TextBlock Text="[[health.title]]" Style="{StaticResource H1}"/>
          <TextBlock Text="[[health.sub]]" Style="{StaticResource Sub}" Margin="0,6,0,20"/>
          <TextBlock Text="[[health.sec.check]]" Style="{StaticResource H2}" Margin="0,0,0,4"/>
          <TextBlock Text="[[health.sec.check.desc]]" Style="{StaticResource Caption}" Margin="0,0,0,10"/>
          <Border Style="{StaticResource Row}">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="36"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBlock Text="&#xE9D2;" Style="{StaticResource Icon}" VerticalAlignment="Top" Margin="0,2,0,0"/>
              <StackPanel Grid.Column="1" Margin="0,0,16,0">
                <TextBlock Text="[[health.check]]" Style="{StaticResource Body}"/>
                <TextBlock Text="[[health.check.desc]]" Style="{StaticResource Caption}" Margin="0,3,0,0"/>
                <TextBlock Text="DISM /Online /Cleanup-Image /CheckHealth" Style="{StaticResource Cmd}"/>
                <Grid Margin="0,8,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Ellipse x:Name="HistDotCheckHealth" Width="7" Height="7" Fill="{StaticResource Text3}" VerticalAlignment="Top" Margin="0,5,8,0"/>
                  <TextBlock x:Name="HistCheckHealth" Grid.Column="1" Text="" FontSize="12" Foreground="{StaticResource Text2}" TextWrapping="Wrap"/>
                </Grid>
                <TextBlock x:Name="TxtCheckState" Text="" Style="{StaticResource State}"/>
              </StackPanel>
              <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Top">
                <Button x:Name="BtnCheck" Style="{StaticResource Secondary}" Content="[[action.run]]"/>
              </StackPanel>
            </Grid>
          </Border>
          <Border Style="{StaticResource Row}">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="36"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBlock Text="&#xE721;" Style="{StaticResource Icon}" VerticalAlignment="Top" Margin="0,2,0,0"/>
              <StackPanel Grid.Column="1" Margin="0,0,16,0">
                <TextBlock Text="[[health.scan]]" Style="{StaticResource Body}"/>
                <TextBlock Text="[[health.scan.desc]]" Style="{StaticResource Caption}" Margin="0,3,0,0"/>
                <TextBlock Text="DISM /Online /Cleanup-Image /ScanHealth" Style="{StaticResource Cmd}"/>
                <Grid Margin="0,8,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Ellipse x:Name="HistDotScanHealth" Width="7" Height="7" Fill="{StaticResource Text3}" VerticalAlignment="Top" Margin="0,5,8,0"/>
                  <TextBlock x:Name="HistScanHealth" Grid.Column="1" Text="" FontSize="12" Foreground="{StaticResource Text2}" TextWrapping="Wrap"/>
                </Grid>
                <TextBlock x:Name="TxtScanState" Text="" Style="{StaticResource State}"/>
              </StackPanel>
              <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Top">
                <Button x:Name="BtnScan" Style="{StaticResource Secondary}" Content="[[action.scan]]"/>
              </StackPanel>
            </Grid>
          </Border>
          <Border Style="{StaticResource Row}">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="36"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBlock Text="&#xE930;" Style="{StaticResource Icon}" VerticalAlignment="Top" Margin="0,2,0,0"/>
              <StackPanel Grid.Column="1" Margin="0,0,16,0">
                <TextBlock Text="[[health.verify]]" Style="{StaticResource Body}"/>
                <TextBlock Text="[[health.verify.desc]]" Style="{StaticResource Caption}" Margin="0,3,0,0"/>
                <TextBlock Text="sfc /verifyonly" Style="{StaticResource Cmd}"/>
                <Grid Margin="0,8,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Ellipse x:Name="HistDotSfcVerify" Width="7" Height="7" Fill="{StaticResource Text3}" VerticalAlignment="Top" Margin="0,5,8,0"/>
                  <TextBlock x:Name="HistSfcVerify" Grid.Column="1" Text="" FontSize="12" Foreground="{StaticResource Text2}" TextWrapping="Wrap"/>
                </Grid>
                <TextBlock x:Name="TxtVerifyState" Text="" Style="{StaticResource State}"/>
              </StackPanel>
              <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Top">
                <Button x:Name="BtnVerify" Style="{StaticResource Secondary}" Content="[[action.run]]"/>
              </StackPanel>
            </Grid>
          </Border>
          <Border Style="{StaticResource Row}">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="36"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBlock Text="&#xE9D9;" Style="{StaticResource Icon}" VerticalAlignment="Top" Margin="0,2,0,0"/>
              <StackPanel Grid.Column="1" Margin="0,0,16,0">
                <TextBlock Text="[[health.wmi]]" Style="{StaticResource Body}"/>
                <TextBlock Text="[[health.wmi.desc]]" Style="{StaticResource Caption}" Margin="0,3,0,0"/>
                <TextBlock Text="winmgmt /verifyrepository" Style="{StaticResource Cmd}"/>
                <Grid Margin="0,8,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Ellipse x:Name="HistDotWmiVerify" Width="7" Height="7" Fill="{StaticResource Text3}" VerticalAlignment="Top" Margin="0,5,8,0"/>
                  <TextBlock x:Name="HistWmiVerify" Grid.Column="1" Text="" FontSize="12" Foreground="{StaticResource Text2}" TextWrapping="Wrap"/>
                </Grid>
                <TextBlock x:Name="TxtWmiState" Text="" Style="{StaticResource State}"/>
              </StackPanel>
              <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Top">
                <Button x:Name="BtnWmi" Style="{StaticResource Secondary}" Content="[[action.check]]"/>
              </StackPanel>
            </Grid>
          </Border>
          <Border Style="{StaticResource Row}">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="36"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBlock Text="&#xECAA;" Style="{StaticResource Icon}" VerticalAlignment="Top" Margin="0,2,0,0"/>
              <StackPanel Grid.Column="1" Margin="0,0,16,0">
                <TextBlock Text="[[health.apps]]" Style="{StaticResource Body}"/>
                <TextBlock Text="[[health.apps.desc]]" Style="{StaticResource Caption}" Margin="0,3,0,0"/>
                <TextBlock Text="winget upgrade" Style="{StaticResource Cmd}"/>
                <Grid Margin="0,8,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Ellipse x:Name="HistDotApps" Width="7" Height="7" Fill="{StaticResource Text3}" VerticalAlignment="Top" Margin="0,5,8,0"/>
                  <TextBlock x:Name="HistApps" Grid.Column="1" Text="" FontSize="12" Foreground="{StaticResource Text2}" TextWrapping="Wrap"/>
                </Grid>
                <TextBlock x:Name="TxtAppsState" Text="" Style="{StaticResource State}"/>
              </StackPanel>
              <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Top">
                <Button x:Name="BtnApps" Style="{StaticResource Secondary}" Content="[[action.check]]"/>
              </StackPanel>
            </Grid>
          </Border>
          <TextBlock Text="[[health.sec.repair]]" Style="{StaticResource H2}" Margin="0,22,0,4"/>
          <TextBlock Text="[[health.sec.repair.desc]]" Style="{StaticResource Caption}" Margin="0,0,0,10"/>
          <Border Style="{StaticResource Row}">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="36"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBlock Text="&#xE90F;" Style="{StaticResource Icon}" VerticalAlignment="Top" Margin="0,2,0,0"/>
              <StackPanel Grid.Column="1" Margin="0,0,16,0">
                <TextBlock Text="[[health.repair]]" Style="{StaticResource Body}"/>
                <TextBlock Text="[[health.repair.desc]]" Style="{StaticResource Caption}" Margin="0,3,0,0"/>
                <TextBlock Text="DISM /Online /Cleanup-Image /RestoreHealth" Style="{StaticResource Cmd}"/>
                <Grid Margin="0,8,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Ellipse x:Name="HistDotRestoreHealth" Width="7" Height="7" Fill="{StaticResource Text3}" VerticalAlignment="Top" Margin="0,5,8,0"/>
                  <TextBlock x:Name="HistRestoreHealth" Grid.Column="1" Text="" FontSize="12" Foreground="{StaticResource Text2}" TextWrapping="Wrap"/>
                </Grid>
                <TextBlock x:Name="TxtRepairState" Text="" Style="{StaticResource State}"/>
              </StackPanel>
              <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Top">
                <Button x:Name="BtnRepair" Style="{StaticResource Secondary}" Content="[[action.repair]]"/>
              </StackPanel>
            </Grid>
          </Border>
          <Border Style="{StaticResource Row}">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="36"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBlock Text="&#xE8B7;" Style="{StaticResource Icon}" VerticalAlignment="Top" Margin="0,2,0,0"/>
              <StackPanel Grid.Column="1" Margin="0,0,16,0">
                <TextBlock Text="[[health.sfc]]" Style="{StaticResource Body}"/>
                <TextBlock Text="[[health.sfc.desc]]" Style="{StaticResource Caption}" Margin="0,3,0,0"/>
                <TextBlock Text="sfc /scannow" Style="{StaticResource Cmd}"/>
                <Grid Margin="0,8,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Ellipse x:Name="HistDotSfcScan" Width="7" Height="7" Fill="{StaticResource Text3}" VerticalAlignment="Top" Margin="0,5,8,0"/>
                  <TextBlock x:Name="HistSfcScan" Grid.Column="1" Text="" FontSize="12" Foreground="{StaticResource Text2}" TextWrapping="Wrap"/>
                </Grid>
                <TextBlock x:Name="TxtSfcState" Text="" Style="{StaticResource State}"/>
              </StackPanel>
              <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Top">
                <Button x:Name="BtnSfc" Style="{StaticResource Secondary}" Content="[[action.repair]]"/>
              </StackPanel>
            </Grid>
          </Border>
          <Border Style="{StaticResource Row}">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="36"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBlock Text="&#xE8A5;" Style="{StaticResource Icon}" VerticalAlignment="Top" Margin="0,2,0,0"/>
              <StackPanel Grid.Column="1" Margin="0,0,16,0">
                <TextBlock Text="[[health.scanfile]]" Style="{StaticResource Body}"/>
                <TextBlock Text="[[health.scanfile.desc]]" Style="{StaticResource Caption}" Margin="0,3,0,0"/>
                <TextBlock Text="sfc /scanfile=&lt;file&gt;" Style="{StaticResource Cmd}"/>
                <Grid Margin="0,12,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBox x:Name="TxtScanPath" Style="{StaticResource Input}" Text="C:\Windows\System32\"/>
                  <Button x:Name="BtnBrowse" Grid.Column="1" Style="{StaticResource Subtle}" Content="[[action.browse]]" Margin="8,0,0,0"/>
                </Grid>
                <Grid Margin="0,8,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Ellipse x:Name="HistDotScanFile" Width="7" Height="7" Fill="{StaticResource Text3}" VerticalAlignment="Top" Margin="0,5,8,0"/>
                  <TextBlock x:Name="HistScanFile" Grid.Column="1" Text="" FontSize="12" Foreground="{StaticResource Text2}" TextWrapping="Wrap"/>
                </Grid>
                <TextBlock x:Name="TxtScanFileState" Text="" Style="{StaticResource State}"/>
              </StackPanel>
              <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Top">
                <Button x:Name="BtnScanFile" Style="{StaticResource Secondary}" Content="[[action.scan]]"/>
              </StackPanel>
            </Grid>
          </Border>
          <Border Style="{StaticResource Row}">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="36"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBlock Text="&#xE90F;" Style="{StaticResource Icon}" VerticalAlignment="Top" Margin="0,2,0,0"/>
              <StackPanel Grid.Column="1" Margin="0,0,16,0">
                <TextBlock Text="[[health.wmifix]]" Style="{StaticResource Body}"/>
                <TextBlock Text="[[health.wmifix.desc]]" Style="{StaticResource Caption}" Margin="0,3,0,0"/>
                <TextBlock Text="winmgmt /salvagerepository" Style="{StaticResource Cmd}"/>
                <Grid Margin="0,8,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Ellipse x:Name="HistDotWmiSalvage" Width="7" Height="7" Fill="{StaticResource Text3}" VerticalAlignment="Top" Margin="0,5,8,0"/>
                  <TextBlock x:Name="HistWmiSalvage" Grid.Column="1" Text="" FontSize="12" Foreground="{StaticResource Text2}" TextWrapping="Wrap"/>
                </Grid>
                <TextBlock x:Name="TxtWmiFixState" Text="" Style="{StaticResource State}"/>
              </StackPanel>
              <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Top">
                <Button x:Name="BtnWmiFix" Style="{StaticResource Secondary}" Content="[[action.repair]]"/>
              </StackPanel>
            </Grid>
          </Border>
          <TextBlock Text="[[health.sec.updates]]" Style="{StaticResource H2}" Margin="0,22,0,4"/>
          <TextBlock Text="[[health.sec.updates.desc]]" Style="{StaticResource Caption}" Margin="0,0,0,10"/>
          <Border Style="{StaticResource Row}">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="36"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBlock Text="&#xE896;" Style="{StaticResource Icon}" VerticalAlignment="Top" Margin="0,2,0,0"/>
              <StackPanel Grid.Column="1" Margin="0,0,16,0">
                <TextBlock Text="[[health.comp]]" Style="{StaticResource Body}"/>
                <TextBlock Text="[[health.comp.desc]]" Style="{StaticResource Caption}" Margin="0,3,0,0"/>
                <TextBlock Text="DISM /Online /Cleanup-Image /StartComponentCleanup" Style="{StaticResource Cmd}"/>
                <Grid Margin="0,8,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Ellipse x:Name="HistDotComponentCleanup" Width="7" Height="7" Fill="{StaticResource Text3}" VerticalAlignment="Top" Margin="0,5,8,0"/>
                  <TextBlock x:Name="HistComponentCleanup" Grid.Column="1" Text="" FontSize="12" Foreground="{StaticResource Text2}" TextWrapping="Wrap"/>
                </Grid>
                <TextBlock x:Name="TxtCompState" Text="" Style="{StaticResource State}"/>
              </StackPanel>
              <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Top">
                <Button x:Name="BtnAnalyze" Style="{StaticResource Subtle}" Content="[[action.analyze]]" Margin="0,0,8,0"/>
                <Button x:Name="BtnComp" Style="{StaticResource Secondary}" Content="[[action.clean]]"/>
              </StackPanel>
            </Grid>
          </Border>
          <TextBlock Text="[[health.sec.boot]]" Style="{StaticResource H2}" Margin="0,22,0,4"/>
          <TextBlock Text="[[health.sec.boot.desc]]" Style="{StaticResource Caption}" Margin="0,0,0,10"/>
          <Border Style="{StaticResource Row}">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="36"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBlock Text="&#xE7E8;" Style="{StaticResource Icon}" VerticalAlignment="Top" Margin="0,2,0,0"/>
              <StackPanel Grid.Column="1" Margin="0,0,16,0">
                <TextBlock Text="[[health.boot]]" Style="{StaticResource Body}"/>
                <TextBlock x:Name="TxtBootInfo" Text="" Style="{StaticResource Caption}" Margin="0,3,0,0"/>
                <TextBox x:Name="TxtBootCmds" Style="{StaticResource Input}" IsReadOnly="True" AcceptsReturn="True" Margin="0,12,0,0"/>
                <TextBlock Text="[[health.boot.note]]" Style="{StaticResource Caption}" Margin="0,8,0,0"/>
              </StackPanel>
              <StackPanel Grid.Column="2" VerticalAlignment="Top">
                <Button x:Name="BtnRecovery" Style="{StaticResource Secondary}" Content="[[health.boot.restart]]"/>
              </StackPanel>
            </Grid>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- DISKS -->
      <ScrollViewer x:Name="PageDisks" Style="{StaticResource Page}" Visibility="Collapsed">
        <StackPanel MaxWidth="1000">
          <TextBlock Text="[[disks.title]]" Style="{StaticResource H1}"/>
          <TextBlock Text="[[disks.sub]]" Style="{StaticResource Sub}" Margin="0,6,0,20"/>

          <ItemsControl x:Name="ListVolumes">
            <ItemsControl.ItemTemplate>
              <DataTemplate>
                <Border Style="{StaticResource Row}">
                  <StackPanel>
                    <Grid Margin="0,0,0,10">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                      <TextBlock Text="{Binding Title}" Style="{StaticResource Body}" FontWeight="SemiBold" VerticalAlignment="Center"/>
                      <Border Grid.Column="1" CornerRadius="4" Background="{StaticResource CardAlt}" BorderBrush="{StaticResource Stroke}"
                              BorderThickness="1" Padding="7,1" Margin="10,0,0,0" HorizontalAlignment="Left" VerticalAlignment="Center">
                        <TextBlock Text="{Binding Media}" FontSize="11" Foreground="{StaticResource Text2}"/>
                      </Border>
                      <TextBlock Grid.Column="2" Text="{Binding Detail}" Style="{StaticResource Caption}" VerticalAlignment="Center"/>
                    </Grid>
                    <ProgressBar Style="{StaticResource Bar}" Value="{Binding Used}" Foreground="{Binding BarBrush}"/>
                    <TextBlock Text="{Binding DiskLine}" Style="{StaticResource Caption}" Margin="0,8,0,0"/>
                  </StackPanel>
                </Border>
              </DataTemplate>
            </ItemsControl.ItemTemplate>
          </ItemsControl>

          <TextBlock Text="[[disks.maintenance]]" Style="{StaticResource H2}" Margin="0,22,0,10"/>
          <Border Style="{StaticResource Row}">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="36"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBlock Text="&#xE9F9;" Style="{StaticResource Icon}" VerticalAlignment="Top" Margin="0,2,0,0"/>
              <StackPanel Grid.Column="1" Margin="0,0,16,0">
                <TextBlock Text="[[disks.fs]]" Style="{StaticResource Body}"/>
                <TextBlock Text="[[disks.fs.desc]]" Style="{StaticResource Caption}" Margin="0,3,0,0"/>
                <Grid Margin="0,8,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Ellipse x:Name="HistDotVolumeScan" Width="7" Height="7" Fill="{StaticResource Text3}" VerticalAlignment="Top" Margin="0,5,8,0"/>
                  <TextBlock x:Name="HistVolumeScan" Grid.Column="1" Text="" FontSize="12" Foreground="{StaticResource Text2}" TextWrapping="Wrap"/>
                </Grid>
                <TextBlock x:Name="TxtFsState" Text="" Style="{StaticResource State}"/>
              </StackPanel>
              <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                <Button x:Name="BtnFsFix" Style="{StaticResource Subtle}" Content="[[disks.fs.fix]]" Margin="0,0,8,0" Visibility="Collapsed"/>
                <Button x:Name="BtnFsScan" Style="{StaticResource Secondary}" Content="[[action.scan]]"/>
              </StackPanel>
            </Grid>
          </Border>
          <Border Style="{StaticResource Row}">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="36"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBlock Text="&#xE945;" Style="{StaticResource Icon}" VerticalAlignment="Top" Margin="0,2,0,0"/>
              <StackPanel Grid.Column="1" Margin="0,0,16,0">
                <TextBlock Text="[[disks.opt]]" Style="{StaticResource Body}"/>
                <TextBlock Text="[[disks.opt.desc]]" Style="{StaticResource Caption}" Margin="0,3,0,0"/>
                <Grid Margin="0,8,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Ellipse x:Name="HistDotOptimize" Width="7" Height="7" Fill="{StaticResource Text3}" VerticalAlignment="Top" Margin="0,5,8,0"/>
                  <TextBlock x:Name="HistOptimize" Grid.Column="1" Text="" FontSize="12" Foreground="{StaticResource Text2}" TextWrapping="Wrap"/>
                </Grid>
                <TextBlock x:Name="TxtOptState" Text="" Style="{StaticResource State}"/>
                <CheckBox x:Name="ChkDefrag" Content="[[disks.opt.hdd]]" Margin="0,12,0,0" FontSize="13"/>
              </StackPanel>
              <Button x:Name="BtnOptimize" Grid.Column="2" Style="{StaticResource Secondary}" Content="[[action.optimize]]" VerticalAlignment="Top"/>
            </Grid>
          </Border>
          <Border Style="{StaticResource Row}">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="36"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBlock Text="&#xEDA2;" Style="{StaticResource Icon}" VerticalAlignment="Top" Margin="0,2,0,0"/>
              <StackPanel Grid.Column="1" Margin="0,0,16,0">
                <TextBlock Text="[[disks.chk]]" Style="{StaticResource Body}"/>
                <TextBlock Text="[[disks.chk.desc]]" Style="{StaticResource Caption}" Margin="0,3,0,0"/>
                <TextBlock Text="[[disks.chk.drive]]" Style="{StaticResource Caption}" Margin="0,14,0,8"/>
                <WrapPanel x:Name="DrivePanel"/>
                <TextBlock Text="[[disks.chk.mode]]" Style="{StaticResource Caption}" Margin="0,6,0,4"/>
                <RadioButton x:Name="ChkModeF"   Style="{StaticResource Choice}" GroupName="chkmode" Content="[[disks.chk.f]]" IsChecked="True"/>
                <RadioButton x:Name="ChkModeR"   Style="{StaticResource Choice}" GroupName="chkmode" Content="[[disks.chk.r]]"/>
                <RadioButton x:Name="ChkModeFrx" Style="{StaticResource Choice}" GroupName="chkmode" Content="[[disks.chk.frx]]"/>
                <TextBlock x:Name="TxtChkCmd" Text="" Style="{StaticResource Cmd}" FontSize="12.5" Foreground="{StaticResource Text2}"/>
                <Grid Margin="0,8,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Ellipse x:Name="HistDotChkdsk" Width="7" Height="7" Fill="{StaticResource Text3}" VerticalAlignment="Top" Margin="0,5,8,0"/>
                  <TextBlock x:Name="HistChkdsk" Grid.Column="1" Text="" FontSize="12" Foreground="{StaticResource Text2}" TextWrapping="Wrap"/>
                </Grid>
                <TextBlock x:Name="TxtChkState" Text="" Style="{StaticResource State}"/>
              </StackPanel>
              <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Top">
                <Button x:Name="BtnChkdsk" Style="{StaticResource Secondary}" Content="[[action.run]]"/>
              </StackPanel>
            </Grid>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- NETWORK -->
      <ScrollViewer x:Name="PageNetwork" Style="{StaticResource Page}" Visibility="Collapsed">
        <StackPanel MaxWidth="1000">
          <TextBlock Text="[[net.title]]" Style="{StaticResource H1}"/>
          <TextBlock Text="[[net.sub]]" Style="{StaticResource Sub}" Margin="0,6,0,20"/>
          <Border Style="{StaticResource CardBox}" Padding="24">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <Border x:Name="NetBadge" Width="48" Height="48" CornerRadius="24" Background="{StaticResource CardAlt}">
                <TextBlock x:Name="NetIcon" Text="&#xE839;" FontFamily="{StaticResource Icons}" FontSize="20" Foreground="{StaticResource Text2}"
                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <StackPanel Grid.Column="1" Margin="18,0,16,0" VerticalAlignment="Center">
                <TextBlock x:Name="TxtNetMain" Text="..." FontFamily="{StaticResource Display}" FontSize="18" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                <TextBlock x:Name="TxtNetSub" Text="" Style="{StaticResource Sub}" Margin="0,3,0,0"/>
              </StackPanel>
              <Button x:Name="BtnNetCheck" Grid.Column="2" Style="{StaticResource Secondary}" Content="[[action.recheck]]" VerticalAlignment="Center"/>
            </Grid>
          </Border>
          <Border Style="{StaticResource CardBox}" Padding="24">
            <StackPanel>
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel Margin="0,0,16,0">
                  <TextBlock Text="[[speed.title]]" Style="{StaticResource H2}"/>
                  <TextBlock Text="[[speed.desc]]" Style="{StaticResource Caption}" Margin="0,4,0,0"/>
                </StackPanel>
                <Button x:Name="BtnSpeed" Grid.Column="1" Style="{StaticResource Primary}" Content="[[speed.start]]" VerticalAlignment="Top"/>
              </Grid>
              <Grid Margin="0,20,0,0">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0">
                  <TextBlock Text="[[speed.down]]" Style="{StaticResource Caption}"/>
                  <StackPanel Orientation="Horizontal" Margin="0,6,0,0">
                    <TextBlock x:Name="SpdDown" Text="-" FontFamily="{StaticResource Display}" FontSize="26" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                    <TextBlock Text="[[speed.mbps]]" Style="{StaticResource Caption}" VerticalAlignment="Bottom" Margin="6,0,0,5"/>
                  </StackPanel>
                </StackPanel>
                <StackPanel Grid.Column="1">
                  <TextBlock Text="[[speed.up]]" Style="{StaticResource Caption}"/>
                  <StackPanel Orientation="Horizontal" Margin="0,6,0,0">
                    <TextBlock x:Name="SpdUp" Text="-" FontFamily="{StaticResource Display}" FontSize="26" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                    <TextBlock Text="[[speed.mbps]]" Style="{StaticResource Caption}" VerticalAlignment="Bottom" Margin="6,0,0,5"/>
                  </StackPanel>
                </StackPanel>
                <StackPanel Grid.Column="2">
                  <TextBlock Text="[[speed.ping]]" Style="{StaticResource Caption}"/>
                  <StackPanel Orientation="Horizontal" Margin="0,6,0,0">
                    <TextBlock x:Name="SpdPing" Text="-" FontFamily="{StaticResource Display}" FontSize="26" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                    <TextBlock Text="[[speed.ms]]" Style="{StaticResource Caption}" VerticalAlignment="Bottom" Margin="6,0,0,5"/>
                  </StackPanel>
                </StackPanel>
                <StackPanel Grid.Column="3">
                  <TextBlock Text="[[speed.jitter]]" Style="{StaticResource Caption}"/>
                  <StackPanel Orientation="Horizontal" Margin="0,6,0,0">
                    <TextBlock x:Name="SpdJitter" Text="-" FontFamily="{StaticResource Display}" FontSize="26" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                    <TextBlock Text="[[speed.ms]]" Style="{StaticResource Caption}" VerticalAlignment="Bottom" Margin="6,0,0,5"/>
                  </StackPanel>
                </StackPanel>
              </Grid>
              <TextBlock x:Name="TxtSpeedInfo" Text="" Style="{StaticResource Caption}" Margin="0,14,0,0"/>
              <Grid Margin="0,8,0,0">
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <Ellipse x:Name="HistDotSpeedTest" Width="7" Height="7" Fill="{StaticResource Text3}" VerticalAlignment="Top" Margin="0,5,8,0"/>
                <TextBlock x:Name="HistSpeedTest" Grid.Column="1" Text="" FontSize="12" Foreground="{StaticResource Text2}" TextWrapping="Wrap"/>
              </Grid>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Row}">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="36"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBlock Text="&#xE774;" Style="{StaticResource Icon}" VerticalAlignment="Top" Margin="0,2,0,0"/>
              <StackPanel Grid.Column="1" Margin="0,0,16,0">
                <TextBlock Text="[[net.dns]]" Style="{StaticResource Body}"/>
                <TextBlock Text="[[net.dns.desc]]" Style="{StaticResource Caption}" Margin="0,3,0,0"/>
                <Grid Margin="0,8,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Ellipse x:Name="HistDotDns" Width="7" Height="7" Fill="{StaticResource Text3}" VerticalAlignment="Top" Margin="0,5,8,0"/>
                  <TextBlock x:Name="HistDns" Grid.Column="1" Text="" FontSize="12" Foreground="{StaticResource Text2}" TextWrapping="Wrap"/>
                </Grid>
              </StackPanel>
              <Button x:Name="BtnDns" Grid.Column="2" Style="{StaticResource Secondary}" Content="[[action.clear]]" VerticalAlignment="Center"/>
            </Grid>
          </Border>
          <Border Style="{StaticResource Row}">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="36"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBlock Text="&#xE72C;" Style="{StaticResource Icon}" VerticalAlignment="Top" Margin="0,2,0,0"/>
              <StackPanel Grid.Column="1" Margin="0,0,16,0">
                <TextBlock Text="[[net.adapter]]" Style="{StaticResource Body}"/>
                <TextBlock Text="[[net.adapter.desc]]" Style="{StaticResource Caption}" Margin="0,3,0,0"/>
                <Grid Margin="0,8,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Ellipse x:Name="HistDotAdapter" Width="7" Height="7" Fill="{StaticResource Text3}" VerticalAlignment="Top" Margin="0,5,8,0"/>
                  <TextBlock x:Name="HistAdapter" Grid.Column="1" Text="" FontSize="12" Foreground="{StaticResource Text2}" TextWrapping="Wrap"/>
                </Grid>
              </StackPanel>
              <Button x:Name="BtnAdapter" Grid.Column="2" Style="{StaticResource Secondary}" Content="[[action.restart]]" VerticalAlignment="Center"/>
            </Grid>
          </Border>
          <TextBlock Text="[[net.advanced]]" Style="{StaticResource H2}" Margin="0,22,0,4"/>
          <TextBlock Text="[[net.advanced.desc]]" Style="{StaticResource Caption}" Margin="0,0,0,10"/>
          <Border Style="{StaticResource Row}">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="36"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBlock Text="&#xE968;" Style="{StaticResource Icon}" Foreground="{StaticResource Warn}" VerticalAlignment="Top" Margin="0,2,0,0"/>
              <StackPanel Grid.Column="1" Margin="0,0,16,0">
                <TextBlock Text="[[net.winsock]]" Style="{StaticResource Body}"/>
                <TextBlock Text="[[net.winsock.desc]]" Style="{StaticResource Caption}" Margin="0,3,0,0"/>
                <TextBlock Text="netsh winsock reset" Style="{StaticResource Cmd}"/>
                <Grid Margin="0,8,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Ellipse x:Name="HistDotWinsock" Width="7" Height="7" Fill="{StaticResource Text3}" VerticalAlignment="Top" Margin="0,5,8,0"/>
                  <TextBlock x:Name="HistWinsock" Grid.Column="1" Text="" FontSize="12" Foreground="{StaticResource Text2}" TextWrapping="Wrap"/>
                </Grid>
                <TextBlock x:Name="TxtWinsockState" Text="" Style="{StaticResource State}"/>
              </StackPanel>
              <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Top">
                <Button x:Name="BtnWinsock" Style="{StaticResource Secondary}" Content="[[action.reset]]"/>
              </StackPanel>
            </Grid>
          </Border>
          <Border Style="{StaticResource Row}">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="36"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBlock Text="&#xE839;" Style="{StaticResource Icon}" Foreground="{StaticResource Warn}" VerticalAlignment="Top" Margin="0,2,0,0"/>
              <StackPanel Grid.Column="1" Margin="0,0,16,0">
                <TextBlock Text="[[net.ipreset]]" Style="{StaticResource Body}"/>
                <TextBlock Text="[[net.ipreset.desc]]" Style="{StaticResource Caption}" Margin="0,3,0,0"/>
                <TextBlock Text="netsh int ip reset" Style="{StaticResource Cmd}"/>
                <Grid Margin="0,8,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Ellipse x:Name="HistDotIpReset" Width="7" Height="7" Fill="{StaticResource Text3}" VerticalAlignment="Top" Margin="0,5,8,0"/>
                  <TextBlock x:Name="HistIpReset" Grid.Column="1" Text="" FontSize="12" Foreground="{StaticResource Text2}" TextWrapping="Wrap"/>
                </Grid>
                <TextBlock x:Name="TxtIpState" Text="" Style="{StaticResource State}"/>
              </StackPanel>
              <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Top">
                <Button x:Name="BtnIpReset" Style="{StaticResource Secondary}" Content="[[action.reset]]"/>
              </StackPanel>
            </Grid>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- ACTIVITY -->
      <Grid x:Name="PageActivity" Visibility="Collapsed" Margin="36,28,24,16">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <Grid Margin="0,0,12,18">
          <StackPanel>
            <TextBlock Text="[[activity.title]]" Style="{StaticResource H1}"/>
            <TextBlock Text="[[activity.sub]]" Style="{StaticResource Sub}" Margin="0,6,0,0"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Bottom">
            <Button x:Name="BtnClearLog" Style="{StaticResource Subtle}" Content="[[activity.clear]]" Margin="0,0,8,0"/>
            <Button x:Name="BtnSaveLog" Style="{StaticResource Secondary}" Content="[[activity.save]]"/>
          </StackPanel>
        </Grid>
        <Border Grid.Row="1" Background="{StaticResource Card}" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="8" Margin="0,0,12,0">
          <ScrollViewer x:Name="LogScroll" VerticalScrollBarVisibility="Auto" Padding="6">
            <ItemsControl x:Name="ListLog">
              <ItemsControl.ItemTemplate>
                <DataTemplate>
                  <Grid Margin="12,7">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="70"/><ColumnDefinition Width="28"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <TextBlock Text="{Binding Time}" FontFamily="Cascadia Mono, Consolas" FontSize="12" Foreground="{StaticResource Text3}" VerticalAlignment="Top" Margin="0,1,0,0"/>
                    <TextBlock Grid.Column="1" Text="{Binding Glyph}" FontFamily="{StaticResource Icons}" FontSize="13" Foreground="{Binding Brush}" VerticalAlignment="Top" Margin="0,2,0,0"/>
                    <TextBlock Grid.Column="2" Text="{Binding Text}" Style="{StaticResource Body}" FontSize="13"/>
                  </Grid>
                </DataTemplate>
              </ItemsControl.ItemTemplate>
            </ItemsControl>
          </ScrollViewer>
        </Border>
      </Grid>

      <!-- SETTINGS -->
      <ScrollViewer x:Name="PageSettings" Style="{StaticResource Page}" Visibility="Collapsed">
        <StackPanel MaxWidth="1000">
          <TextBlock Text="[[settings.title]]" Style="{StaticResource H1}" Margin="0,0,0,20"/>
          <Border Style="{StaticResource CardBox}">
            <StackPanel>
              <TextBlock Text="[[settings.language]]" Style="{StaticResource H2}"/>
              <TextBlock Text="[[settings.language.desc]]" Style="{StaticResource Caption}" Margin="0,4,0,12"/>
              <StackPanel x:Name="LangPanel"/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource CardBox}">
            <StackPanel>
              <TextBlock Text="[[settings.theme]]" Style="{StaticResource H2}"/>
              <TextBlock Text="[[settings.theme.desc]]" Style="{StaticResource Caption}" Margin="0,4,0,12"/>
              <RadioButton x:Name="ThemeSystem" Style="{StaticResource Choice}" GroupName="theme" Content="[[settings.theme.system]]"/>
              <RadioButton x:Name="ThemeLight"  Style="{StaticResource Choice}" GroupName="theme" Content="[[settings.theme.light]]"/>
              <RadioButton x:Name="ThemeDark"   Style="{StaticResource Choice}" GroupName="theme" Content="[[settings.theme.dark]]"/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource CardBox}">
            <StackPanel>
              <TextBlock Text="[[settings.about]]" Style="{StaticResource H2}"/>
              <TextBlock x:Name="TxtAbout" Text="" Style="{StaticResource Sub}" Margin="0,8,0,0"/>
              <TextBlock Text="[[settings.about.desc]]" Style="{StaticResource Caption}" Margin="0,8,0,0"/>
              <TextBlock x:Name="TxtProject" Text="" FontSize="13" Foreground="{StaticResource Accent}" Margin="0,10,0,0" Cursor="Hand"/>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>
    </Grid>

    <!-- ============ STATUS BAR + LIVE OUTPUT ============ -->
    <Border Grid.Column="1" Grid.Row="1" Background="{StaticResource Bg}" BorderBrush="{StaticResource StrokeSoft}" BorderThickness="0,1,0,0" Padding="36,10,36,12">
      <StackPanel>
        <Border x:Name="LivePanel" Visibility="Collapsed" Background="{StaticResource Log}" BorderBrush="{StaticResource Stroke}"
                BorderThickness="1" CornerRadius="8" Padding="16,12,16,12" Margin="0,4,0,10">
          <StackPanel>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBlock Text="&#xE756;" FontFamily="{StaticResource Icons}" FontSize="13" Foreground="{StaticResource Accent}" VerticalAlignment="Center" Margin="0,0,10,0"/>
              <TextBlock x:Name="LiveCmd" Grid.Column="1" Text="" FontFamily="Cascadia Mono, Consolas" FontSize="12.5" FontWeight="SemiBold"
                         Foreground="{StaticResource Text}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
              <TextBlock x:Name="LiveTime" Grid.Column="2" Text="00:00" FontFamily="Cascadia Mono, Consolas" FontSize="12"
                         Foreground="{StaticResource Text3}" VerticalAlignment="Center" Margin="12,0,0,0"/>
            </Grid>
            <Grid x:Name="LiveBarRow" Margin="0,12,0,2" Visibility="Collapsed">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <ProgressBar x:Name="LiveBar" Style="{StaticResource Bar}" Foreground="{StaticResource Accent}" VerticalAlignment="Center"/>
              <TextBlock x:Name="LivePct" Grid.Column="1" Text="" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}"
                         MinWidth="48" TextAlignment="Right" Margin="12,0,0,0"/>
            </Grid>
            <TextBlock x:Name="LiveLines" Text="" FontFamily="Cascadia Mono, Consolas" FontSize="11.5" Foreground="{StaticResource Text2}"
                       TextWrapping="NoWrap" TextTrimming="CharacterEllipsis" LineHeight="18" Margin="26,10,0,0"/>
            <TextBlock x:Name="LiveRaw" Text="" FontFamily="Cascadia Mono, Consolas" FontSize="11.5" Foreground="{StaticResource Text3}"
                       TextTrimming="CharacterEllipsis" Margin="26,2,0,0"/>
          </StackPanel>
        </Border>
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <TextBlock x:Name="StatusIcon" Text="&#xE73E;" FontFamily="{StaticResource Icons}" FontSize="13" Foreground="{StaticResource Good}" VerticalAlignment="Center" Margin="0,0,10,0"/>
          <StackPanel Grid.Column="1" VerticalAlignment="Center">
            <TextBlock x:Name="StatusText" Text="[[status.ready]]" FontSize="12.5" Foreground="{StaticResource Text2}" TextTrimming="CharacterEllipsis"/>
            <ProgressBar x:Name="StatusBar" IsIndeterminate="True" Height="2" Margin="0,6,0,0" Visibility="Collapsed"
                         Foreground="{StaticResource Accent}" Background="Transparent" BorderThickness="0"/>
          </StackPanel>
          <Button x:Name="BtnLiveToggle" Grid.Column="2" Style="{StaticResource Subtle}" Content="[[live.hide]]" Visibility="Collapsed" Margin="12,0,0,0"/>
          <Button x:Name="BtnStop" Grid.Column="3" Style="{StaticResource Subtle}" Content="[[status.stop]]" Visibility="Collapsed" Margin="4,0,0,0"/>
        </Grid>
      </StackPanel>
    </Border>

    <!-- ============ DIALOG ============ -->
    <Grid x:Name="Dialog" Grid.ColumnSpan="2" Grid.RowSpan="2" Background="{StaticResource Scrim}" Visibility="Collapsed">
      <Border Background="{StaticResource Card}" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="10"
              Width="460" HorizontalAlignment="Center" VerticalAlignment="Center">
        <StackPanel>
          <StackPanel Margin="26,24,26,22">
            <TextBlock x:Name="DlgTitle" Text="" Style="{StaticResource H2}" FontSize="19"/>
            <TextBlock x:Name="DlgText" Text="" Style="{StaticResource Sub}" FontSize="13.5" Margin="0,12,0,0"/>
          </StackPanel>
          <Border Background="{StaticResource CardAlt}" CornerRadius="0,0,10,10" BorderBrush="{StaticResource StrokeSoft}" BorderThickness="0,1,0,0" Padding="22,18">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="10"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Button x:Name="DlgOk" Grid.Column="0" Style="{StaticResource Primary}" Content="OK"/>
              <Button x:Name="DlgCancel" Grid.Column="2" Style="{StaticResource Secondary}" Content="Cancel"/>
            </Grid>
          </Border>
        </StackPanel>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

# =============================================================================
#  Background work (runspace + queue pumped by a DispatcherTimer)
# =============================================================================
$script:Shared = [hashtable]::Synchronized(@{
    Queue = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
    Busy = $false; Done = $false; Result = $null
})
$script:LiveHidden = $false; $script:LiveStart = $null; $script:LiveBuffer = $null; $script:LiveTitle = ''
$script:Job = $null; $script:JobHandle = $null; $script:OnDone = $null; $script:OnDoneHistory = ''; $script:Stopped = $false; $script:History = $null
$script:DriveButtons = @(); $script:SelectedDrive = $null; $script:RestartRecovery = $false

$script:ActionButtons = @('BtnQuick','BtnDeep','BtnClean','BtnRemeasure','BtnCheck','BtnScan','BtnRepair','BtnSfc',
                          'BtnApps','BtnAnalyze','BtnComp','BtnFsScan','BtnFsFix','BtnOptimize','BtnNetCheck','BtnDns',
                          'BtnAdapter','ThemeSystem','ThemeLight','ThemeDark','BtnVerify','BtnWmi','BtnWmiFix','BtnBrowse',
                          'BtnScanFile','BtnChkdsk','BtnWinsock','BtnIpReset','BtnRecovery','BtnSpeed','BtnSpeedOverview','ChkModeF','ChkModeR','ChkModeFrx','TxtScanPath')

function Get-Brush([string]$Key) { $script:Win.FindResource($Key) }

function Set-Busy([bool]$Busy, [string]$Text) {
    foreach ($n in $script:ActionButtons) { if ($script:Ui[$n]) { $script:Ui[$n].IsEnabled = -not $Busy } }
    foreach ($rb in $script:LangButtons) { $rb.IsEnabled = -not $Busy }
    foreach ($rb in $script:DriveButtons) { $rb.IsEnabled = -not $Busy }
    $script:Ui.StatusBar.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' }
    $script:Ui.BtnStop.Visibility   = if ($Busy) { 'Visible' } else { 'Collapsed' }
    $script:Ui.BtnLiveToggle.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' }
    if (-not $Busy) { $script:Ui.LivePanel.Visibility = 'Collapsed'; $script:LiveStart = $null }
    $script:Ui.StatusIcon.Text       = if ($Busy) { [string][char]0xE895 } else { [string][char]0xE73E }
    $script:Ui.StatusIcon.Foreground = if ($Busy) { Get-Brush 'Accent' } else { Get-Brush 'Good' }
    if ($Text) { $script:Ui.StatusText.Text = $Text }
}

function Add-Log([string]$Text, [string]$Kind = 'info') {
    $map = @{
        ok    = @([char]0xE73E, 'Good'); warn = @([char]0xE7BA, 'Warn'); error = @([char]0xEA39, 'Bad')
        step  = @([char]0xE76C, 'Accent'); info = @([char]0xE946, 'Text3')
    }
    $m = $map[$Kind]; if (-not $m) { $m = $map['info'] }
    $script:LogItems.Add([pscustomobject]@{
        Time = (Get-Date).ToString('HH:mm:ss'); Glyph = [string]$m[0]; Brush = (Get-Brush $m[1]); Text = $Text; Kind = $Kind
    })
    $script:LogStore.Add([pscustomobject]@{ Time = (Get-Date).ToString('HH:mm:ss'); Kind = $Kind; Text = $Text })
    if ($script:Ui.LogScroll) { $script:Ui.LogScroll.ScrollToEnd() }
}

# --- Live output panel -----------------------------------------------------
function Start-LiveSection([string]$Title) {
    $script:LiveTitle = $Title
    $script:LiveBuffer = New-Object System.Collections.Generic.List[string]
    $script:LiveStart = Get-Date
    $script:Ui.LiveCmd.Text = $Title
    $script:Ui.LiveLines.Text = ''
    $script:Ui.LiveRaw.Text = ''
    $script:Ui.LivePct.Text = ''
    $script:Ui.LiveBar.Value = 0
    $script:Ui.LiveBarRow.Visibility = 'Collapsed'
    $script:Ui.LiveTime.Text = '00:00'
    if (-not $script:LiveHidden) { $script:Ui.LivePanel.Visibility = 'Visible' }
}

function Add-LiveLine([string]$Line) {
    # $null check, not -not: an EMPTY list is falsy in PowerShell and would never fill up
    if ($null -eq $script:LiveBuffer -or -not $Line) { return }
    $script:LiveBuffer.Add($Line.Trim())
    while ($script:LiveBuffer.Count -gt 5) { $script:LiveBuffer.RemoveAt(0) }
    $script:Ui.LiveLines.Text = ($script:LiveBuffer -join "`n")
}

function Set-LivePercent([double]$Percent, [string]$Raw) {
    $script:Ui.LiveBarRow.Visibility = 'Visible'
    $script:Ui.LiveBar.Value = $Percent
    $script:Ui.LivePct.Text = T 'live.percent' ([math]::Round($Percent))
    if ($Raw) { $script:Ui.LiveRaw.Text = $Raw }
    $script:Ui.StatusText.Text = "$($script:LiveTitle)   $($script:Ui.LivePct.Text)"
}

function Receive-Message($m) {
    if ($m.Kind -eq 'live') {
        if ($null -ne $m.Percent) { Set-LivePercent ([double]$m.Percent) $m.Text }
        elseif ($m.Text) { Add-LiveLine $m.Text }
        return
    }
    Add-Log $m.Text $m.Kind
    switch ($m.Kind) {
        'step'  { Start-LiveSection ($m.Text -replace '^>\s*', ''); $script:Ui.StatusText.Text = $m.Text }
        'info'  { Add-LiveLine $m.Text }
        default { Add-LiveLine $m.Text; $script:Ui.StatusText.Text = $m.Text }
    }
}

function Invoke-Background {
    param([Parameter(Mandatory)][scriptblock]$Work, [string]$Title, [scriptblock]$Done, [hashtable]$Params = @{}, [string]$History = '')
    if ($script:Shared.Busy) { return }
    $script:Shared.Busy = $true; $script:Shared.Done = $false; $script:Shared.Result = $null
    $script:OnDone = $Done
    $script:OnDoneHistory = $History
    Set-Busy $true $Title
    if ($Title) { Add-Log $Title 'step'; Start-LiveSection $Title }

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('Shared', $script:Shared)
    $rs.SessionStateProxy.SetVariable('CorePath', $script:CorePath)
    $rs.SessionStateProxy.SetVariable('LangDir', $script:LangDir)
    $rs.SessionStateProxy.SetVariable('LangCode', $script:Settings.Language)
    $rs.SessionStateProxy.SetVariable('Params', $Params)

    $wrapper = {
        param($Body)
        try {
            Import-Module $CorePath -Force -DisableNameChecking -ErrorAction Stop
            Initialize-Language -Directory $LangDir -Code $LangCode
            $Notify = { param($m) $Shared.Queue.Enqueue($m) }
            $Shared.Result = & ([scriptblock]::Create($Body)) $Notify $Params
        } catch {
            $Shared.Queue.Enqueue([pscustomobject]@{ Text = "$($_.Exception.Message)"; Kind = 'error'; Time = Get-Date })
        } finally { $Shared.Done = $true }
    }
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($wrapper).AddArgument($Work.ToString())
    $script:Job = $ps; $script:JobHandle = $ps.BeginInvoke()
}

function Invoke-Pump {
    if ($script:LiveStart -and $script:Ui.LivePanel.Visibility -eq 'Visible') {
        $e = (Get-Date) - $script:LiveStart
        $script:Ui.LiveTime.Text = if ($e.TotalHours -ge 1) { $e.ToString('h\:mm\:ss') } else { $e.ToString('mm\:ss') }
    }
    while ($script:Shared.Queue.Count -gt 0) {
        $m = $script:Shared.Queue.Dequeue()
        if ($m) { Receive-Message $m }
    }
    if ($script:Shared.Busy -and $script:Shared.Done) {
        $script:Shared.Busy = $false
        try { $script:Job.EndInvoke($script:JobHandle) } catch { }
        try { $script:Job.Runspace.Close(); $script:Job.Dispose() } catch { }
        $script:Job = $null
        Set-Busy $false (T 'status.ready')
        if ($script:OnDoneHistory -and -not $script:Stopped) { Save-Run $script:OnDoneHistory (Get-ResultOk $script:Shared.Result) }
        $script:OnDoneHistory = ''; $script:Stopped = $false
        $cb = $script:OnDone; $script:OnDone = $null
        if ($cb) { try { & $cb $script:Shared.Result } catch { Add-Log $_.Exception.Message 'error' } }
    }
}

# =============================================================================
#  Dialog
# =============================================================================
function Show-Dialog {
    param([string]$Title, [string]$Text, [string]$Ok, [string]$Cancel, [scriptblock]$OnOk)
    $script:Ui.DlgTitle.Text = $Title
    $script:Ui.DlgText.Text  = $Text
    $script:Ui.DlgOk.Content = if ($Ok) { $Ok } else { T 'dialog.ok' }
    if ($Cancel) { $script:Ui.DlgCancel.Content = $Cancel; $script:Ui.DlgCancel.Visibility = 'Visible'; [System.Windows.Controls.Grid]::SetColumnSpan($script:Ui.DlgOk, 1) }
    else { $script:Ui.DlgCancel.Visibility = 'Collapsed'; [System.Windows.Controls.Grid]::SetColumnSpan($script:Ui.DlgOk, 3) }
    $script:DialogAction = $OnOk
    $script:Ui.Dialog.Visibility = 'Visible'
    [void]$script:Ui.DlgOk.Focus()
}
function Close-Dialog([bool]$Confirmed) {
    $script:Ui.Dialog.Visibility = 'Collapsed'
    $a = $script:DialogAction; $script:DialogAction = $null
    if ($Confirmed -and $a) { & $a }
}
function Confirm-Action([string]$Title, [string]$Text, [string]$Ok, [scriptblock]$OnOk) {
    Show-Dialog -Title $Title -Text $Text -Ok $Ok -Cancel (T 'dialog.cancel') -OnOk $OnOk
}

# =============================================================================
#  Data -> UI
# =============================================================================
function Format-Duration([timespan]$t) {
    if ($t.TotalDays -ge 1) { return (T 'time.daysHours' $t.Days $t.Hours) }
    T 'time.hoursMinutes' $t.Hours $t.Minutes
}

function Show-Page([string]$Name) {
    foreach ($p in $script:Pages.Values) { $script:Ui[$p].Visibility = 'Collapsed' }
    $script:Ui[$script:Pages[$Name]].Visibility = 'Visible'
}

function Update-CleanupTotal {
    $sum = [double]0; $n = 0
    foreach ($i in $script:CleanItems) { if ($i.Selected) { $sum += $i.Bytes; $n++ } }
    $script:Ui.TxtCleanTotal.Text = Format-Size $sum
    $script:Ui.BtnClean.IsEnabled = (-not $script:Shared.Busy) -and ($n -gt 0)
}

function New-CleanupItems {
    $list = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    $keys = @((Get-CleanupTargets | ForEach-Object { $_.Key }) + 'Delivery' + 'RecycleBin')
    foreach ($k in $keys) {
        $i = New-Object WcCleanupItem
        $i.Key = $k; $i.Title = T "clean.$k.name"; $i.Description = T "clean.$k.desc"
        if ($k -eq 'RecycleBin') { $i.Warning = T 'clean.RecycleBin.warn'; $i.Selected = $false } else { $i.Selected = $true }
        $i.SizeText = '...'
        $i.add_PropertyChanged({ param($s, $e) if ($e.PropertyName -eq 'Selected') { Update-CleanupTotal } })
        $list.Add($i)
    }
    $script:CleanItems = $list
    $script:Ui.ListCleanup.ItemsSource = $list
}

function Set-CleanupSizes($Data) {
    $bytes = @{}
    foreach ($r in @($Data.Cleanup)) { $bytes[$r.Key] = $r.Bytes }
    $bytes['Delivery'] = $Data.Delivery.Bytes
    $bytes['RecycleBin'] = $Data.Recycle.Bytes
    foreach ($i in $script:CleanItems) {
        $b = [double]$bytes[$i.Key]
        $i.Bytes = $b
        $i.SizeText = if ($b -gt 0) { Format-Size $b } else { T 'cleanup.empty' }
    }
    Update-CleanupTotal
}

function Update-FromRefresh($Data) {
    if (-not $Data) { return }
    $script:LastData = $Data
    $sys = $Data.System; $sec = $Data.Security; $net = $Data.Network

    # System
    $script:Ui.TxtOs.Text = if ($sys.DisplayVersion) { "$($sys.OsName) $($sys.DisplayVersion)" } else { $sys.OsName }
    $script:Ui.TxtMem.Text = T 'sys.memory.value' (Format-Size $sys.RamBytes) $sys.MemoryPercent
    $script:Ui.TxtUptime.Text = Format-Duration $sys.Uptime
    $script:Ui.TxtSideVersion.Text = "v$($script:AppVersion)"
    $script:Ui.TxtAbout.Text = T 'settings.about.version' $script:AppVersion "$($sys.OsName) $($sys.DisplayVersion)" $sys.Build

    # Cleanup
    Set-CleanupSizes $Data
    $reclaim = [double]0
    foreach ($i in $script:CleanItems) { if ($i.Key -ne 'RecycleBin') { $reclaim += $i.Bytes } }
    $script:Ui.TileCleanValue.Text = Format-Size $reclaim
    $script:Ui.TileCleanSub.Text = T 'tile.clean.sub'

    # Disks
    $disks = @($Data.Disks); $bad = @($disks | Where-Object { $_.Problem })
    $script:Ui.TileDisksValue.Text = T 'tile.disks.value' ($disks.Count - $bad.Count) $disks.Count
    $sysVol = @($Data.Volumes) | Where-Object { $_.Letter -eq $env:SystemDrive.TrimEnd(':') } | Select-Object -First 1
    $script:Ui.TileDisksSub.Text = if ($sysVol) { T 'tile.disks.sub' $sysVol.Letter (Format-Size $sysVol.Free) } else { '' }

    $vols = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    foreach ($v in @($Data.Volumes)) {
        $mediaText = switch ($v.Media) { 'SSD' { 'SSD' } 'HDD' { 'HDD' } default { T 'disks.media.unknown' } }
        $lineParts = @()
        $vd = $disks | Where-Object { "$($_.Id)" -eq "$($v.DiskId)" } | Select-Object -First 1
        if ($vd) {
            $lineParts += $vd.Name
            if ($null -ne $vd.Temperature) { $lineParts += (T 'disks.temp' $vd.Temperature) }
            if ($null -ne $vd.Wear) { $lineParts += (T 'disks.wear' $vd.Wear) }
            $lineParts += if ($vd.Problem) { T 'disks.health.bad' } else { T 'disks.health.ok' }
        }
        $barKey = if ($v.UsedPercent -ge 90) { 'Bad' } elseif ($v.UsedPercent -ge 80) { 'Warn' } else { 'Accent' }
        $title = if ($v.Label) { "$($v.Letter):  $($v.Label)" } else { "$($v.Letter):" }
        $vols.Add([pscustomobject]@{
            Title = $title; Media = $mediaText; Used = $v.UsedPercent; BarBrush = (Get-Brush $barKey)
            Detail = T 'disks.free' (Format-Size $v.Free) (Format-Size $v.Total)
            DiskLine = ($lineParts -join '  |  ')
        })
    }
    $script:Ui.ListVolumes.ItemsSource = $vols

    Update-DrivePills @($Data.Volumes)
    $fw = if ($sys.Firmware) { $sys.Firmware } else { 'UEFI' }
    $script:Ui.TxtBootInfo.Text = T 'health.boot.desc' $fw
    $cmds = @('bootrec /scanos', 'bootrec /rebuildbcd', 'bcdboot C:\Windows')
    if ($fw -ne 'UEFI') { $cmds = @('bootrec /fixmbr', 'bootrec /fixboot') + $cmds }
    $script:Ui.TxtBootCmds.Text = $cmds -join "`r`n"

    $opt = $Data.Optimize
    $script:Ui.TxtOptState.Text = if ($opt.Known) { T 'disks.opt.last' ($opt.LastRun.ToString('d', (Get-AppCulture))) $opt.DaysAgo } else { '' }

    # Protection
    if ($null -eq $sec.ProtectionOn) {
        $script:Ui.TileProtectValue.Text = T 'tile.protection.unknown'; $script:Ui.TileProtectSub.Text = T 'tile.protection.thirdparty'
    } elseif ($sec.ProtectionOn) {
        $script:Ui.TileProtectValue.Text = T 'tile.protection.on'; $script:Ui.TileProtectSub.Text = T 'tile.protection.sig' $sec.SignatureAge
    } else {
        $script:Ui.TileProtectValue.Text = T 'tile.protection.off'; $script:Ui.TileProtectSub.Text = T 'tile.protection.offsub'
    }

    # Network
    Update-Network $net

    # Attention
    $att = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    $add = { param($g, $b, $t, $d) $att.Add([pscustomobject]@{ Glyph = [string][char]$g; Brush = (Get-Brush $b); Title = $t; Detail = $d }) }
    foreach ($d in $bad) { & $add 0xE7BA 'Bad' (T 'att.disk' $d.Name) ((@($d.Warnings) + $d.Health) -join ' | ') }
    foreach ($v in @($Data.Volumes | Where-Object { $_.Low })) { & $add 0xE7BA 'Warn' (T 'att.lowspace' $v.Letter $v.FreePercent) (T 'att.lowspace.d') }
    if ($sec.ProtectionOn -eq $false) { & $add 0xE7BA 'Bad' (T 'att.protection') (T 'att.protection.d') }
    elseif ($sec.SignatureAge -gt 3) { & $add 0xE7BA 'Warn' (T 'att.signature' $sec.SignatureAge) (T 'att.signature.d') }
    if ($sec.RebootRequired) { & $add 0xE7BA 'Warn' (T 'att.reboot') ($sec.RebootReasons -join ', ') }
    if ($net.Status -ne 'OK') { & $add 0xE7BA 'Bad' (T 'att.network') (T "net.state.$($net.Status)") }
    if ($sys.Uptime.TotalDays -gt 7) { & $add 0xE946 'Text3' (T 'att.uptime' ([int]$sys.Uptime.TotalDays)) (T 'att.uptime.d') }
    if ($sec.UnexpectedShutdowns -gt 0) { & $add 0xE946 'Warn' (T 'att.shutdown' $sec.UnexpectedShutdowns) (T 'att.shutdown.d') }
    $script:Ui.ListAttention.ItemsSource = $att
    $script:Ui.CardAttention.Visibility = if ($att.Count) { 'Visible' } else { 'Collapsed' }

    $serious = @($att | Where-Object { $_.Glyph -eq [string][char]0xE7BA }).Count
    if ($serious -eq 0) {
        $script:Ui.HeroTitle.Text = T 'overview.healthy'
        $script:Ui.HeroIcon.Text = [string][char]0xE73E
        $script:Ui.HeroIcon.Foreground = Get-Brush 'Good'; $script:Ui.HeroBadge.Background = Get-Brush 'GoodSoft'
    } else {
        $script:Ui.HeroTitle.Text = T 'overview.issues' $serious
        $script:Ui.HeroIcon.Text = [string][char]0xE7BA
        $script:Ui.HeroIcon.Foreground = Get-Brush 'Warn'; $script:Ui.HeroBadge.Background = Get-Brush 'WarnSoft'
    }
    $script:Ui.HeroSub.Text = T 'overview.lastcheck' ((Get-Date).ToString('t', (Get-AppCulture)))
    Update-HistoryView
}

function Update-DrivePills($Volumes) {
    $prev = $script:SelectedDrive
    $script:Ui.DrivePanel.Children.Clear()
    $script:DriveButtons = New-Object System.Collections.Generic.List[object]
    $style = $script:Win.FindResource('Pill')
    foreach ($v in $Volumes) {
        if ($v.FileSystem -ne 'NTFS') { continue }
        $rb = New-Object System.Windows.Controls.RadioButton
        $rb.Style = $style; $rb.GroupName = 'drive'; $rb.Tag = $v.Letter
        $rb.Content = if ($v.Label) { "$($v.Letter):  $($v.Label)" } else { "$($v.Letter):" }
        $rb.IsChecked = if ($prev) { $v.Letter -eq $prev } else { $v.IsSystem }
        $rb.IsEnabled = -not $script:Shared.Busy
        $rb.Add_Checked({ param($s, $e) $script:SelectedDrive = [string]$s.Tag; Update-ChkPreview })
        [void]$script:Ui.DrivePanel.Children.Add($rb)
        $script:DriveButtons.Add($rb)
    }
    if (-not $prev) { $sys = $Volumes | Where-Object { $_.IsSystem } | Select-Object -First 1; if ($sys) { $script:SelectedDrive = $sys.Letter } }
    Update-ChkPreview
}

function Get-ChkMode {
    if ($script:Ui.ChkModeR.IsChecked) { return 'r' }
    if ($script:Ui.ChkModeFrx.IsChecked) { return 'frx' }
    'f'
}

function Update-ChkPreview {
    $sw = switch (Get-ChkMode) { 'r' { '/r' } 'frx' { '/f /r /x' } default { '/f' } }
    $d = if ($script:SelectedDrive) { $script:SelectedDrive } else { $env:SystemDrive.TrimEnd(':') }
    $script:Ui.TxtChkCmd.Text = "chkdsk ${d}: $sw"
}

function Request-Restart([string]$Title, [string]$Text, [switch]$Recovery) {
    Show-Dialog -Title $Title -Text $Text -Ok (T 'restart.now') -Cancel (T 'restart.later') -OnOk {
        $a = if ($script:RestartRecovery) { @('/r', '/o', '/t', '5') } else { @('/r', '/t', '5') }
        try { Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\shutdown.exe') -ArgumentList $a -WindowStyle Hidden }
        catch { Add-Log $_.Exception.Message 'error' }
    }
    $script:RestartRecovery = [bool]$Recovery
}

# =============================================================================
#  Run history and advice ("when did it last run, is it needed now?")
# =============================================================================
$script:HistoryKeys = @('CheckHealth','ScanHealth','SfcVerify','WmiVerify','Apps','RestoreHealth','SfcScan','ScanFile',
                        'WmiSalvage','ComponentCleanup','VolumeScan','Optimize','Chkdsk','Dns','Adapter','Winsock','IpReset','SpeedTest')

function Get-ResultOk($Result) {
    $items = @($Result | Where-Object { $null -ne $_ })
    if (-not $items.Count) { return $null }
    if ($items.Count -gt 1 -and -not @($items | Where-Object { -not $_.PSObject.Properties['Ok'] }).Count) {
        return -not @($items | Where-Object { -not $_.Ok }).Count          # e.g. optimize: every drive OK
    }
    $x = $items[-1]
    if ($x -is [bool]) { return $x }
    if ($x.PSObject.Properties['Scheduled'] -and $x.Scheduled) { return $true }
    foreach ($p in 'Ok', 'Healthy', 'Consistent', 'Clean') {
        if ($x.PSObject.Properties[$p]) { if ($null -eq $x.$p) { return $null }; return [bool]$x.$p }
    }
    if ($x.PSObject.Properties['Supported']) { if (-not $x.Supported -or $x.TimedOut) { return $null }; return ($x.Count -eq 0) }
    if ($x.PSObject.Properties['Status']) { return ($x.Status -eq 'OK') }
    if ($x.PSObject.Properties['Code']) { return ($x.Code -le 1) }
    $null
}

function Save-Run([string]$Key, $Ok) {
    Write-RunRecord -Key $Key -Ok $Ok
    $script:History = Read-RunHistory
    Update-HistoryView
}

function Format-Ago($Time) {
    if (-not $Time) { return (T 'hist.never') }
    $days = [int]((Get-Date).Date - $Time.Date).TotalDays
    if ($days -le 0) { return (T 'hist.today' $Time.ToString('t', (Get-AppCulture))) }
    if ($days -eq 1) { return (T 'hist.yesterday') }
    T 'hist.daysAgo' $days
}

function Test-NewerFailure([string]$CheckKey, [string]$FixKey) {
    # True when CheckKey's latest run found a problem that FixKey has not run after.
    $c = $script:History[$CheckKey]
    if (-not $c -or $c.Ok -ne $false) { return $false }
    $f = $script:History[$FixKey]
    return (-not $f -or $f.Time -lt $c.Time)
}

function Get-Advice([string]$Key) {
    $h = $script:History[$Key]
    $age = if ($h) { ((Get-Date) - $h.Time).TotalDays } else { [double]::MaxValue }
    $due = {
        param([int]$Days)
        if (-not $h) { return @('due', (T 'rec.never')) }
        if ($age -gt $Days) { return @('due', (T 'rec.due' ([int]$age))) }
        @('ok', (T 'rec.ok'))
    }
    $data = $script:LastData
    $netBad = ($data -and $data.Network -and $data.Network.Status -ne 'OK')
    $checks = 'CheckHealth', 'ScanHealth', 'SfcVerify', 'WmiVerify', 'VolumeScan'
    if ($checks -contains $Key -and $h -and $h.Ok -eq $false) { return @('warn', (T 'rec.problem')) }

    switch ($Key) {
        'CheckHealth' { return & $due 7 }
        'ScanHealth'  { return & $due 30 }
        'SfcVerify'   { return & $due 30 }
        'WmiVerify'   { return & $due 90 }
        'VolumeScan'  { return & $due 30 }
        'Apps'        { return & $due 7 }
        'RestoreHealth' {
            if ((Test-NewerFailure 'CheckHealth' 'RestoreHealth') -or (Test-NewerFailure 'ScanHealth' 'RestoreHealth')) { return @('due', (T 'rec.afterFailure')) }
            return @('cond', (T 'rec.onlyOnProblem'))
        }
        'SfcScan' {
            if (Test-NewerFailure 'SfcVerify' 'SfcScan') { return @('due', (T 'rec.afterFailure')) }
            $rh = $script:History['RestoreHealth']
            if ($rh -and $rh.Ok -and (-not $h -or $h.Time -lt $rh.Time)) { return @('due', (T 'rec.afterRepair')) }
            return @('cond', (T 'rec.onlyOnProblem'))
        }
        'WmiSalvage' {
            if (Test-NewerFailure 'WmiVerify' 'WmiSalvage') { return @('due', (T 'rec.afterFailure')) }
            return @('cond', (T 'rec.onlyOnProblem'))
        }
        'Chkdsk' {
            if (Test-NewerFailure 'VolumeScan' 'Chkdsk') { return @('due', (T 'rec.afterFailure')) }
            return @('cond', (T 'rec.onlyOnProblem'))
        }
        'ScanFile' { return @('cond', (T 'rec.onDemand')) }
        'SpeedTest' { return @('cond', (T 'rec.speed')) }
        'ComponentCleanup' {
            $lastClean = $null
            if ($h) { $lastClean = $h.Time }
            if ($data -and $data.WinCompTask -and (-not $lastClean -or $data.WinCompTask -gt $lastClean)) { $lastClean = $data.WinCompTask }
            $upd = if ($data) { $data.LastUpdate } else { $null }
            if ($upd -and (-not $lastClean -or $upd.Date -gt $lastClean.Date)) {
                return @('due', (T 'rec.update' $upd.ToString('d', (Get-AppCulture))))
            }
            if ($data -and $data.WinCompTask -and (-not $h -or $data.WinCompTask -gt $h.Time)) {
                return @('ok', (T 'rec.windowsDid' (Format-Ago $data.WinCompTask)))
            }
            return @('ok', (T 'rec.ok'))
        }
        'Optimize' {
            if ($data -and $data.Optimize.Known -and $data.Optimize.DaysAgo -le 7) { return @('ok', (T 'rec.windowsDid' (Format-Ago $data.Optimize.LastRun))) }
            return & $due 7
        }
        { $_ -in 'Dns', 'Adapter', 'Winsock', 'IpReset' } {
            if ($netBad) { return @('due', (T 'rec.netNow')) }
            return @('cond', (T 'rec.netOnly'))
        }
    }
    @('cond', '')
}

function Start-SpeedTest {
    Invoke-Background -Title (T 'speed.running') -Work { param($n, $p) Test-InternetSpeed -Notify $n } -Done {
        param($r)
        if (-not $r) { return }
        if ($r.Ok) {
            $detail = [pscustomobject]@{ Down = $r.DownMbps; Up = $r.UpMbps; Ping = $r.PingMs; Jitter = $r.JitterMs; Server = $r.Server
                                         DownMB = [math]::Round($r.DownBytes / 1MB); UpMB = [math]::Round($r.UpBytes / 1MB) }
        } else {
            # A failed attempt (e.g. offline) must not erase the last good result
            $prev = $script:History['SpeedTest']
            $detail = if ($prev) { $prev.Detail } else { $null }
        }
        Write-RunRecord -Key 'SpeedTest' -Ok $r.Ok -Detail $detail
        $script:History = Read-RunHistory
        Update-HistoryView
    }
}

function Update-SpeedView {
    # One test, one history record, two views: Network page and Overview card
    $h = $script:History['SpeedTest']
    if (-not $h) { $script:Ui.OvSpeedSub.Text = T 'speed.never'; return }
    $when = Format-Ago $h.Time
    $d = $h.Detail
    if ($d) {
        $c = Get-AppCulture
        $ping = if ($null -ne $d.Ping)   { ([double]$d.Ping).ToString('N0', $c) } else { '-' }
        $jit  = if ($null -ne $d.Jitter) { ([double]$d.Jitter).ToString('N0', $c) } else { '-' }
        $srv  = if ($d.Server) { $d.Server } else { '-' }
        $script:Ui.SpdDown.Text = Format-Mbps $d.Down;  $script:Ui.OvDown.Text = Format-Mbps $d.Down
        $script:Ui.SpdUp.Text   = Format-Mbps $d.Up;    $script:Ui.OvUp.Text   = Format-Mbps $d.Up
        $script:Ui.SpdPing.Text = $ping;                $script:Ui.OvPing.Text = $ping
        $script:Ui.SpdJitter.Text = $jit
        $script:Ui.TxtSpeedInfo.Text = T 'speed.info' $srv $d.DownMB $d.UpMB
        $script:Ui.OvSpeedSub.Text = T 'speed.last' $when $srv
    }
    if ($h.Ok -eq $false) {
        # Previous good values stay on screen; say that the latest attempt failed
        $script:Ui.OvSpeedSub.Text = T 'speed.lastFailed' $when
        $script:Ui.TxtSpeedInfo.Text = T 'speed.lastFailed' $when
    }
}

function Update-HistoryView {
    if (-not $script:Ui) { return }
    if ($null -eq $script:History) { $script:History = Read-RunHistory }
    $dueCount = 0
    foreach ($k in $script:HistoryKeys) {
        $txt = $script:Ui["Hist$k"]; $dot = $script:Ui["HistDot$k"]
        if (-not $txt) { continue }
        $adv = Get-Advice $k
        $h = $script:History[$k]
        $when = Format-Ago $(if ($h) { $h.Time } else { $null })
        $last = if ($k -eq 'SpeedTest') { T 'hist.last' $when }
                elseif ($h -and $h.Ok -eq $true) { T 'hist.lastOk' $when }
                elseif ($h -and $h.Ok -eq $false) { T 'hist.lastProblem' $when }
                else { T 'hist.last' $when }
        $txt.Text = if ($adv[1]) { "$($adv[1])   |   $last" } else { $last }
        $dot.Fill = Get-Brush $(switch ($adv[0]) { 'due' { 'Accent' } 'warn' { 'Warn' } 'ok' { 'Good' } default { 'Text3' } })
        if ($adv[0] -in 'due', 'warn') { $dueCount++ }
    }
    Update-SpeedView
    if ($script:LastData -and $script:Ui.HeroSub) {
        $base = T 'overview.lastcheck' ((Get-Date).ToString('t', (Get-AppCulture)))
        $script:Ui.HeroSub.Text = if ($dueCount) { "$base   |   $(T 'overview.recommended' $dueCount)" } else { "$base   |   $(T 'overview.uptodate')" }
    }
}

function Update-Network($net) {
    $script:Ui.TxtNetMain.Text = T "net.state.$($net.Status)"
    $parts = @(); if ($net.Description) { $parts += $net.Description }; if ($net.IP) { $parts += $net.IP }; if ($net.Speed) { $parts += $net.Speed }
    $script:Ui.TxtNetSub.Text = $parts -join '  |  '
    $ok = ($net.Status -eq 'OK')
    $script:Ui.NetBadge.Background = Get-Brush ($(if ($ok) { 'GoodSoft' } else { 'BadSoft' }))
    $script:Ui.NetIcon.Foreground  = Get-Brush ($(if ($ok) { 'Good' } else { 'Bad' }))
    $script:Ui.TileNetValue.Text = if ($ok) { T 'tile.network.ok' } else { T 'tile.network.bad' }
    $script:Ui.TileNetSub.Text = if ($net.IP) { $net.IP } else { T "net.state.$($net.Status)" }
}

# Shared background bodies (strings, because they run in another runspace)
$script:RefreshWork = {
    param($Notify, $P)
    $cleanup = @(foreach ($t in Get-CleanupTargets) { Invoke-CleanupTarget -Target $t })
    [pscustomobject]@{
        System   = Get-SystemInfo
        Disks    = @(Get-DiskHealth)
        Volumes  = @(Get-VolumeInfo)
        Security = Get-SecurityStatus
        Network  = Test-Network
        Optimize = Get-OptimizeStatus
        Cleanup  = $cleanup
        Delivery = Get-DeliveryCacheSize
        Recycle  = Get-RecycleBinSize
        LastUpdate  = Get-LastUpdateDate
        WinCompTask = Get-ComponentCleanupTask
    }
}

function Start-Refresh([string]$Title) {
    if (-not $Title) { $Title = T 'status.refreshing' }
    Invoke-Background -Title $Title -Work $script:RefreshWork -Done { param($r) Update-FromRefresh $r; if ($r) { Add-Log $script:Ui.HeroTitle.Text 'ok' } }
}

$script:CleanWork = {
    param($Notify, $P)
    $before = Get-FreeSpace
    $count = 0; $bytes = [double]0
    $svc = $false
    if ($P.Keys -contains 'WUCache') { $svc = Stop-UpdateServices -Notify $Notify }
    foreach ($t in Get-CleanupTargets) {
        if ($P.Keys -notcontains $t.Key) { continue }
        $r = Invoke-CleanupTarget -Target $t -Apply -Notify $Notify
        $count += $r.Count; $bytes += $r.Bytes
    }
    if ($svc) { Start-UpdateServices -Notify $Notify }
    if ($P.Keys -contains 'Delivery')   { $r = Clear-DeliveryCache -Notify $Notify; $count += $r.Count; $bytes += $r.Bytes }
    if ($P.Keys -contains 'RecycleBin') { $r = Clear-RecycleBinSafe -Notify $Notify; $count += $r.Count; $bytes += $r.Bytes }
    if ($P.Dns) { Clear-DnsCache -Notify $Notify | Out-Null }
    if ($P.Check) { $c = Test-ComponentStore -Notify $Notify } else { $c = $null }
    [pscustomobject]@{ Count = $count; Bytes = $bytes; Check = $c }
}

$script:DeepWork = {
    param($Notify, $P)
    $count = 0; $bytes = [double]0
    $svc = Stop-UpdateServices -Notify $Notify
    foreach ($t in Get-CleanupTargets) { $r = Invoke-CleanupTarget -Target $t -Apply -Notify $Notify; $count += $r.Count; $bytes += $r.Bytes }
    if ($svc) { Start-UpdateServices -Notify $Notify }
    $r = Clear-DeliveryCache -Notify $Notify; $count += $r.Count; $bytes += $r.Bytes
    Clear-DnsCache -Notify $Notify | Out-Null
    $check = Test-ComponentStore -Notify $Notify
    $repair = $null
    if ($check.Healthy -eq $false) { $repair = Repair-ComponentStore -Notify $Notify }
    $sfc = Invoke-Sfc -Mode scannow -Notify $Notify
    # Old update files are removed only from a healthy (or freshly repaired) store
    $comp = $null
    if ($check.Healthy -or ($repair -and $repair.Ok)) { $comp = Invoke-ComponentCleanup -Notify $Notify; $bytes += $comp.Bytes }
    $vol = Test-VolumeHealth -Notify $Notify
    foreach ($v in Get-VolumeInfo) { if ($v.Media -eq 'SSD') { Invoke-Optimize -Letter $v.Letter -Notify $Notify | Out-Null } }
    $net = Test-Network
    if ($net.Status -eq 'OK') { Send-Progress $Notify (T 'msg.net.ok') 'ok' } else { Send-Progress $Notify (T 'msg.net.bad' (T "net.state.$($net.Status)")) 'warn' }
    [pscustomobject]@{ Count = $count; Bytes = $bytes; Check = $check; Repair = $repair; Sfc = $sfc; Comp = $comp; Volume = $vol; Network = $net }
}

# =============================================================================
#  Window construction
# =============================================================================
function New-MainWindow {
    $script:Initializing = $true
    $pal = Get-Palette
    $script:Palette = $pal
    $x = $script:XamlTemplate.Replace('@AppName@', $script:AppName)
    foreach ($k in $pal.Keys) { $x = $x.Replace("@$k@", $pal[$k]) }
    $x = [regex]::Replace($x, '\[\[([A-Za-z0-9_.]+)\]\]', [Text.RegularExpressions.MatchEvaluator]{
        param($m) [Security.SecurityElement]::Escape((T $m.Groups[1].Value))
    })

    [xml]$doc = $x
    $script:Win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $doc))

    # Named elements. Names are read from the XAML text: XmlNode.Name can return
    # the tag name instead of x:Name. Template-internal names resolve to null.
    $script:Ui = @{}
    foreach ($m in [regex]::Matches($x, 'x:Name="([^"]+)"')) {
        $n = $m.Groups[1].Value
        if (-not $script:Ui.ContainsKey($n)) { $el = $script:Win.FindName($n); if ($null -ne $el) { $script:Ui[$n] = $el } }
    }

    # App icon (window, taskbar, sidebar). Missing assets are not fatal.
    try {
        $icoPath = Join-Path $script:Root 'assets\WinCare.ico'
        $pngPath = Join-Path $script:Root 'assets\icon-256.png'
        if (Test-Path -LiteralPath $icoPath) {
            $script:Win.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object Uri $icoPath))
        }
        if (Test-Path -LiteralPath $pngPath) {
            $bi = New-Object System.Windows.Media.Imaging.BitmapImage
            $bi.BeginInit(); $bi.CacheOption = 'OnLoad'; $bi.UriSource = New-Object Uri $pngPath; $bi.EndInit()
            $script:Ui.LogoImage.Source = $bi
        }
    } catch { }

    if ($script:Bounds) {
        $script:Win.WindowStartupLocation = 'Manual'
        $script:Win.Left = $script:Bounds.Left; $script:Win.Top = $script:Bounds.Top
        $script:Win.Width = $script:Bounds.Width; $script:Win.Height = $script:Bounds.Height
        if ($script:Bounds.Max) { $script:Win.WindowState = 'Maximized' }
    }

    $script:Win.Add_SourceInitialized({
        try {
            $h = (New-Object System.Windows.Interop.WindowInteropHelper($script:Win)).Handle
            $dark = [int]$(if ($script:IsDark) { 1 } else { 0 })
            [void][WcDwm]::DwmSetWindowAttribute($h, 20, [ref]$dark, 4)          # immersive dark title bar
            $c = [System.Windows.Media.ColorConverter]::ConvertFromString($script:Palette.Bg)
            $colorRef = [int]($c.R) -bor ([int]($c.G) -shl 8) -bor ([int]($c.B) -shl 16)
            [void][WcDwm]::DwmSetWindowAttribute($h, 35, [ref]$colorRef, 4)      # caption color = background
        } catch { }
    })

    # Logs survive rebuilds
    if (-not $script:LogStore) { $script:LogStore = New-Object System.Collections.Generic.List[object] }
    $script:LogItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    $script:Ui.ListLog.ItemsSource = $script:LogItems
    $old = $script:LogStore.ToArray(); $script:LogStore.Clear()   # @() on a List[object] throws in PS 5.1
    foreach ($e in $old) { Add-Log $e.Text $e.Kind }

    # Navigation
    $script:Pages = [ordered]@{
        NavOverview = 'PageOverview'; NavCleanup = 'PageCleanup'; NavHealth = 'PageHealth'; NavDisks = 'PageDisks'
        NavNetwork = 'PageNetwork'; NavActivity = 'PageActivity'; NavSettings = 'PageSettings'
    }
    foreach ($n in $script:Pages.Keys) {
        $script:Ui[$n].Add_Checked({ param($s, $e) Show-Page $s.Name })
    }
    $script:Ui.TileClean.Add_Click({ $script:Ui.NavCleanup.IsChecked = $true })
    $script:Ui.TileDisks.Add_Click({ $script:Ui.NavDisks.IsChecked = $true })
    $script:Ui.TileProtect.Add_Click({ $script:Ui.NavHealth.IsChecked = $true })
    $script:Ui.TileNet.Add_Click({ $script:Ui.NavNetwork.IsChecked = $true })

    # Dialog
    $script:Ui.DlgOk.Add_Click({ Close-Dialog $true })
    $script:Ui.DlgCancel.Add_Click({ Close-Dialog $false })
    $script:Win.Add_PreviewKeyDown({
        param($s, $e)
        if ($script:Ui.Dialog.Visibility -eq 'Visible' -and $e.Key -eq 'Escape') { Close-Dialog $false; $e.Handled = $true }
    })

    Register-Handlers

    # Settings page
    $script:LangButtons = New-Object System.Collections.Generic.List[object]
    $style = $script:Win.FindResource('Choice')
    foreach ($l in (Get-AvailableLanguages -Directory $script:LangDir)) {
        $rb = New-Object System.Windows.Controls.RadioButton
        $rb.Style = $style; $rb.GroupName = 'lang'; $rb.Tag = $l.Code
        $rb.Content = if ($l.NativeName -and $l.NativeName -ne $l.Name) { "$($l.NativeName)  ($($l.Name))" } else { $l.Name }
        $rb.IsChecked = ($l.Code -eq $script:Settings.Language)
        $rb.Add_Checked({ param($s, $e)
            if ($script:Initializing -or $s.Tag -eq $script:Settings.Language) { return }
            $script:Settings.Language = [string]$s.Tag; Save-Settings; Request-Rebuild
        })
        [void]$script:Ui.LangPanel.Children.Add($rb)
        $script:LangButtons.Add($rb)
    }
    switch ($script:Settings.Theme) { 'light' { $script:Ui.ThemeLight.IsChecked = $true } 'dark' { $script:Ui.ThemeDark.IsChecked = $true } default { $script:Ui.ThemeSystem.IsChecked = $true } }
    foreach ($pair in @(@('ThemeSystem','system'), @('ThemeLight','light'), @('ThemeDark','dark'))) {
        $script:Ui[$pair[0]].Tag = $pair[1]
        $script:Ui[$pair[0]].Add_Checked({ param($s, $e)
            if ($script:Initializing -or $s.Tag -eq $script:Settings.Theme) { return }
            $script:Settings.Theme = [string]$s.Tag; Save-Settings; Request-Rebuild
        })
    }
    $script:Ui.TxtProject.Text = $script:ProjectUrl
    $script:Ui.TxtProject.Add_MouseLeftButtonUp({ try { Start-Process $script:ProjectUrl } catch { } })

    # Cleanup items + pump
    New-CleanupItems
    $script:Timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromMilliseconds(100)
    $script:Timer.Add_Tick({ Invoke-Pump })
    $script:Timer.Start()

    $script:Win.Add_Closing({
        $script:Bounds = @{ Left = $script:Win.RestoreBounds.Left; Top = $script:Win.RestoreBounds.Top
                            Width = $script:Win.RestoreBounds.Width; Height = $script:Win.RestoreBounds.Height
                            Max = ($script:Win.WindowState -eq 'Maximized') }
    })
    $script:Win.Add_Closed({
        try { $script:Timer.Stop() } catch { }
        if ($script:Job) { try { $script:Job.Stop(); $script:Job.Dispose() } catch { } ; $script:Job = $null; $script:Shared.Busy = $false }
    })

    if ($script:ReturnToSettings) { $script:Ui.NavSettings.IsChecked = $true; $script:ReturnToSettings = $false }
    $script:Initializing = $false
    Update-CleanupTotal
}

function Register-Screenshots {
    if (-not (Test-Path -LiteralPath $ScreenshotDir)) { New-Item -ItemType Directory -Path $ScreenshotDir -Force | Out-Null }
    if ($Width -gt 0) { $script:Win.Width = $Width }
    if ($Height -gt 0) { $script:Win.WindowStartupLocation = 'Manual'; $script:Win.Top = 0; $script:Win.MaxHeight = 6000; $script:Win.Height = $Height }
    $script:ShotPages = @($CapturePages.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $script:ShotIndex = -1; $script:ShotWait = 0
    $script:ShotTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ShotTimer.Interval = [TimeSpan]::FromMilliseconds(700)
    $script:ShotTimer.Add_Tick({
        if ((-not $script:LastData -or $script:Shared.Busy) -and $script:ShotWait -lt 150) { $script:ShotWait++; return }
        if ($script:ShotIndex -ge 0) {
            $pg = $script:ShotPages[$script:ShotIndex]
            $name = '{0}-{1}-{2}.png' -f $script:Settings.Language, $script:Settings.Theme, ($pg -replace '^Nav', '').ToLowerInvariant()
            Save-WindowImage (Join-Path $ScreenshotDir $name)
            # Text dump of the run-history lines, for automated checks
            $lines = foreach ($k in $script:HistoryKeys) { if ($script:Ui["Hist$k"]) { "{0,-17} {1}" -f $k, $script:Ui["Hist$k"].Text } }
            [IO.File]::WriteAllLines((Join-Path $ScreenshotDir ($name -replace '\.png$', '-history.txt')), [string[]]$lines, (New-Object Text.UTF8Encoding($true)))
        }
        $script:ShotIndex++
        if ($script:ShotIndex -ge $script:ShotPages.Count) { $script:ShotTimer.Stop(); $script:Rebuild = $false; $script:Win.Close(); return }
        if ($script:ShotIndex -gt 0 -and $script:ShotPages[$script:ShotIndex - 1] -eq 'Live') { Set-Busy $false 'Ready' }
        $next = $script:ShotPages[$script:ShotIndex]
        if ($next -eq 'Live') { Show-LiveDemo } else { $script:Ui[$next].IsChecked = $true }
    })
    $script:Win.Add_ContentRendered({ $script:ShotTimer.Start() })
}

function Show-LiveDemo {
    # Screenshot mode only: shows the live panel with sample output (nothing is run)
    Set-Busy $true ''
    Start-LiveSection 'DISM /Online /Cleanup-Image /RestoreHealth'
    $script:LiveStart = (Get-Date).AddSeconds(-252)
    $script:Ui.LiveTime.Text = '04:12'
    foreach ($l in 'Deployment Image Servicing and Management tool', 'Version: 10.0.26100.1', 'Image Version: 10.0.26300.9550') { Add-LiveLine $l }
    Set-LivePercent 42 '[=====================42.0%                          ]'
}

function Save-WindowImage([string]$Path) {
    $script:Win.UpdateLayout()
    $c = $script:Win.Content; $w = [int]$c.ActualWidth; $h = [int]$c.ActualHeight
    $dv = New-Object System.Windows.Media.DrawingVisual; $dc = $dv.RenderOpen()
    $dc.DrawRectangle($script:Win.Background, $null, (New-Object System.Windows.Rect 0, 0, $w, $h))
    # 1:1 mapping: by default a VisualBrush scales the visual's full bounds, including
    # parts that overflow the window (clipped on screen), which squashed the image.
    $vb = New-Object System.Windows.Media.VisualBrush $c
    $vb.Stretch = 'None'; $vb.AlignmentX = 'Left'; $vb.AlignmentY = 'Top'
    $vb.ViewboxUnits = 'Absolute'; $vb.Viewbox = New-Object System.Windows.Rect 0, 0, $w, $h
    $vb.ViewportUnits = 'Absolute'; $vb.Viewport = New-Object System.Windows.Rect 0, 0, $w, $h
    $dc.DrawRectangle($vb, $null, (New-Object System.Windows.Rect 0, 0, $w, $h))
    $dc.Close()
    $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap $w, $h, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($dv)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $fs = [IO.File]::Create($Path); try { $enc.Save($fs) } finally { $fs.Close() }
}

function Request-Rebuild {
    $script:Rebuild = $true
    $script:ReturnToSettings = $true
    $script:Win.Close()
}

# =============================================================================
#  Event handlers
# =============================================================================
function Register-Handlers {
    $u = $script:Ui

    $u.BtnLiveToggle.Add_Click({
        $script:LiveHidden = -not $script:LiveHidden
        $script:Ui.LivePanel.Visibility = if ($script:LiveHidden) { 'Collapsed' } else { 'Visible' }
        $script:Ui.BtnLiveToggle.Content = if ($script:LiveHidden) { T 'live.show' } else { T 'live.hide' }
    })

    $u.BtnStop.Add_Click({
        if ($script:Job) { try { $script:Job.Stop() } catch { }; $script:Stopped = $true; Add-Log (T 'status.stopped') 'warn'; $script:Shared.Done = $true }
    })

    $u.BtnQuick.Add_Click({
        $keys = @{}; foreach ($i in $script:CleanItems) { if ($i.Key -ne 'RecycleBin') { $keys[$i.Key] = $true } }
        $keys['Dns'] = $true; $keys['Check'] = $true
        Invoke-Background -Title (T 'quick.running') -Work $script:CleanWork -Params $keys -Done {
            param($r)
            if (-not $r) { return }
            Save-Run 'Cleanup' $true; Save-Run 'Dns' $true; Save-Run 'QuickCare' $true
            if ($r.Check) { Save-Run 'CheckHealth' $r.Check.Healthy }
            Add-Log (T 'quick.done' (Format-Size $r.Bytes) $r.Count) 'ok'
            $chk = if ($r.Check.Healthy -eq $false) { T 'quick.done.checkbad' } else { T 'quick.done.checkok' }
            Show-Dialog -Title (T 'quick.done.title') -Text ((T 'quick.done' (Format-Size $r.Bytes) $r.Count) + "`n`n" + $chk)
            Start-Refresh
        }
    })

    $u.BtnDeep.Add_Click({
        Confirm-Action (T 'deep.confirm.title') (T 'deep.confirm.text') (T 'deep.confirm.ok') {
            Invoke-Background -Title (T 'deep.running') -Work $script:DeepWork -Done {
                param($r)
                if (-not $r) { return }
                $lines = @(
                    (T 'deep.result.space' (Format-Size $r.Bytes))
                    (T 'deep.result.store' $(if ($r.Check.Healthy -ne $false) { T 'result.ok' } elseif ($r.Repair.Ok) { T 'result.repaired' } else { T 'result.problem' }))
                    (T 'deep.result.sfc'   $(if ($r.Sfc.Ok) { T 'result.ok' } else { T 'result.problem' }))
                    (T 'deep.result.updates' $(if ($r.Comp -and $r.Comp.Ok) { T 'result.cleaned' } elseif ($r.Comp) { T 'result.problem' } else { T 'result.skipped' }))
                    (T 'deep.result.disk'  $(if ($r.Volume.Clean -ne $false) { T 'result.ok' } else { T 'result.problem' }))
                    (T 'deep.result.net'   (T "net.state.$($r.Network.Status)"))
                )
                Save-Run 'Cleanup' $true; Save-Run 'Dns' $true; Save-Run 'DeepCare' $true
                if ($r.Check)  { Save-Run 'CheckHealth' $r.Check.Healthy }
                if ($r.Repair) { Save-Run 'RestoreHealth' $r.Repair.Ok }
                if ($r.Sfc)    { Save-Run 'SfcScan' $r.Sfc.Ok }
                if ($r.Comp)   { Save-Run 'ComponentCleanup' $r.Comp.Ok }
                if ($r.Volume) { Save-Run 'VolumeScan' $r.Volume.Clean }
                Save-Run 'Optimize' $true
                Add-Log (T 'deep.done') 'ok'
                Show-Dialog -Title (T 'deep.done') -Text ($lines -join "`n")
                Start-Refresh
            }
        }
    })

    $u.BtnRemeasure.Add_Click({ Start-Refresh (T 'cleanup.measuring') })

    $u.BtnClean.Add_Click({
        $keys = @{}; foreach ($i in $script:CleanItems) { if ($i.Selected) { $keys[$i.Key] = $true } }
        if ($keys.Count -eq 0) { return }
        $run = {
            $k = @{}; foreach ($i in $script:CleanItems) { if ($i.Selected) { $k[$i.Key] = $true } }
            Invoke-Background -History 'Cleanup' -Title (T 'cleanup.running') -Work $script:CleanWork -Params $k -Done {
                param($r)
                if (-not $r) { return }
                Show-Dialog -Title (T 'cleanup.done.title') -Text (T 'cleanup.done.text' (Format-Size $r.Bytes) $r.Count)
                Start-Refresh (T 'cleanup.measuring')
            }
        }
        if ($keys.ContainsKey('RecycleBin')) {
            $rb = $script:CleanItems | Where-Object { $_.Key -eq 'RecycleBin' } | Select-Object -First 1
            Confirm-Action (T 'recycle.confirm.title') (T 'recycle.confirm.text' (Format-Size $rb.Bytes)) (T 'recycle.confirm.ok') $run
        } else { & $run }
    })

    $u.BtnCheck.Add_Click({
        Invoke-Background -History 'CheckHealth' -Title (T 'msg.check.running') -Work { param($n,$p) Test-ComponentStore -Notify $n } -Done {
            param($r) if (-not $r) { return }
            $script:Ui.TxtCheckState.Text = if ($r.Healthy) { T 'health.check.ok' } else { T 'health.check.bad' $r.Code }
        }
    })
    $u.BtnScan.Add_Click({
        Invoke-Background -History 'ScanHealth' -Title (T 'msg.scan.running') -Work { param($n,$p) Invoke-ScanHealth -Notify $n } -Done {
            param($r) if (-not $r) { return }
            $script:Ui.TxtScanState.Text = if ($r.Healthy) { T 'health.scan.ok' } else { T 'health.scan.bad' }
        }
    })
    $u.BtnRepair.Add_Click({
        Confirm-Action (T 'repair.confirm.title') (T 'repair.confirm.text') (T 'action.repair') {
            Invoke-Background -History 'RestoreHealth' -Title (T 'msg.repair.running') -Work { param($n,$p) Repair-ComponentStore -Notify $n } -Done {
                param($r) if (-not $r) { return }
                $script:Ui.TxtRepairState.Text = if ($r.Ok) { T 'health.repair.ok' } else { T 'health.repair.bad' $r.Code }
            }
        }
    })
    $u.BtnSfc.Add_Click({
        Invoke-Background -History 'SfcScan' -Title (T 'msg.sfc.running') -Work { param($n,$p) Invoke-Sfc -Mode scannow -Notify $n } -Done {
            param($r) if (-not $r) { return }
            $script:Ui.TxtSfcState.Text = if ($r.Ok) { T 'health.sfc.ok' } else { T 'health.sfc.bad' $r.Code }
        }
    })
    $u.BtnApps.Add_Click({
        Invoke-Background -History 'Apps' -Title (T 'msg.apps.running') -Work { param($n,$p) Get-OutdatedApps } -Done {
            param($r) if (-not $r) { return }
            $script:Ui.TxtAppsState.Text =
                if (-not $r.Supported) { T 'health.apps.nowinget' }
                elseif ($r.TimedOut)   { T 'health.apps.timeout' }
                elseif ($r.Count -gt 0) { T 'health.apps.some' $r.Count }
                else { T 'health.apps.none' }
            Add-Log $script:Ui.TxtAppsState.Text $(if ($r.Count -gt 0) { 'warn' } else { 'ok' })
        }
    })
    $u.BtnAnalyze.Add_Click({
        Invoke-Background -Title (T 'msg.analyze.running') -Work { param($n,$p) Get-ComponentStoreAnalysis -Notify $n } -Done {
            param($r) $script:Ui.TxtCompState.Text = (@($r) -join "`n")
        }
    })
    $u.BtnComp.Add_Click({
        Confirm-Action (T 'comp.confirm.title') (T 'comp.confirm.text') (T 'action.clean') {
            Invoke-Background -History 'ComponentCleanup' -Title (T 'msg.comp.running') -Work { param($n,$p) Invoke-ComponentCleanup -Notify $n } -Done {
                param($r) if (-not $r) { return }
                $script:Ui.TxtCompState.Text = if ($r.Ok) { T 'msg.comp.ok' (Format-Size $r.Bytes) } else { T 'msg.comp.bad' $r.Code }
            }
        }
    })

    $u.BtnFsScan.Add_Click({
        Invoke-Background -History 'VolumeScan' -Title (T 'msg.vol.running' $env:SystemDrive.TrimEnd(':')) -Work { param($n,$p) Test-VolumeHealth -Notify $n } -Done {
            param($r) if (-not $r) { return }
            if ($r.Clean -eq $true) { $script:Ui.TxtFsState.Text = T 'disks.fs.ok'; $script:Ui.BtnFsFix.Visibility = 'Collapsed' }
            elseif ($r.Clean -eq $false) { $script:Ui.TxtFsState.Text = T 'disks.fs.bad'; $script:Ui.BtnFsFix.Visibility = 'Visible' }
            else { $script:Ui.TxtFsState.Text = T 'disks.fs.fail' }
        }
    })
    $u.BtnFsFix.Add_Click({
        Confirm-Action (T 'spotfix.confirm.title') (T 'spotfix.confirm.text') (T 'spotfix.confirm.ok') {
            Invoke-Background -Title (T 'disks.fs.fix') -Work { param($n,$p) Repair-VolumeSpotFix -Notify $n } -Done {
                param($r) $script:Ui.TxtFsState.Text = T 'disks.fs.scheduled'; $script:Ui.BtnFsFix.Visibility = 'Collapsed'
            }
        }
    })
    $u.BtnOptimize.Add_Click({
        $p = @{ Defrag = [bool]$script:Ui.ChkDefrag.IsChecked }
        Invoke-Background -History 'Optimize' -Title (T 'msg.opt.running') -Params $p -Work {
            param($n, $p)
            $res = @(); foreach ($v in Get-VolumeInfo) { $res += Invoke-Optimize -Letter $v.Letter -Defrag:$p.Defrag -Notify $n }; $res
        } -Done {
            param($r)
            $ssd = @($r | Where-Object { $_.Action -eq 'trim' -and $_.Ok }).Count
            $hdd = @($r | Where-Object { $_.Action -eq 'defrag' -and $_.Ok }).Count
            $script:Ui.TxtOptState.Text = T 'disks.opt.done' $ssd $hdd
            Add-Log $script:Ui.TxtOptState.Text 'ok'
        }
    })

    $u.BtnNetCheck.Add_Click({
        Invoke-Background -Title (T 'net.checking') -Work { param($n,$p) Test-Network } -Done { param($r) if ($r) { Update-Network $r; Add-Log (T "net.state.$($r.Status)") $(if ($r.Status -eq 'OK') { 'ok' } else { 'warn' }) } }
    })
    $u.BtnDns.Add_Click({ Invoke-Background -History 'Dns' -Title (T 'net.dns') -Work { param($n,$p) Clear-DnsCache -Notify $n } })
    $u.BtnAdapter.Add_Click({
        Confirm-Action (T 'adapter.confirm.title') (T 'adapter.confirm.text') (T 'action.restart') {
            Invoke-Background -History 'Adapter' -Title (T 'net.adapter') -Work { param($n,$p) Restart-NetworkAdapter -Notify $n; Test-Network } -Done {
                param($r) $last = @($r)[-1]; if ($last -and $last.PSObject.Properties['Status']) { Update-Network $last }
            }
        }
    })

    $u.BtnVerify.Add_Click({
        Invoke-Background -History 'SfcVerify' -Title (T 'msg.verify.running') -Work { param($n,$p) Invoke-Sfc -Mode verifyonly -Notify $n } -Done {
            param($r) if (-not $r) { return }
            $script:Ui.TxtVerifyState.Text = if ($r.Ok) { T 'health.verify.ok' } else { T 'health.verify.bad' $r.Code }
        }
    })
    $u.BtnWmi.Add_Click({
        Invoke-Background -History 'WmiVerify' -Title (T 'msg.wmi.running') -Work { param($n,$p) Test-WmiRepository -Notify $n } -Done {
            param($r) if (-not $r) { return }
            $script:Ui.TxtWmiState.Text = if ($r.Consistent) { T 'health.wmi.ok' } else { T 'health.wmi.bad' $r.Code }
        }
    })
    $u.BtnWmiFix.Add_Click({
        Confirm-Action (T 'wmifix.confirm.title') (T 'wmifix.confirm.text') (T 'action.repair') {
            Invoke-Background -History 'WmiSalvage' -Title (T 'msg.wmifix.running') -Work { param($n,$p) Repair-WmiRepository -Notify $n } -Done {
                param($r) if (-not $r) { return }
                $script:Ui.TxtWmiFixState.Text = if ($r.Ok) { T 'msg.wmifix.ok' } else { T 'msg.wmifix.bad' $r.Code }
            }
        }
    })
    $u.BtnBrowse.Add_Click({
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.InitialDirectory = Join-Path $env:SystemRoot 'System32'
        $dlg.Filter = (T 'health.scanfile.filter') + '|*.dll;*.exe;*.sys;*.ocx;*.cpl;*.mui|*.*|*.*'
        if ($dlg.ShowDialog($script:Win)) { $script:Ui.TxtScanPath.Text = $dlg.FileName }
    })
    $u.BtnScanFile.Add_Click({
        $path = $script:Ui.TxtScanPath.Text.Trim().Trim('"')
        if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { $script:Ui.TxtScanFileState.Text = T 'msg.scanfile.missing' $path; return }
        Invoke-Background -History 'ScanFile' -Title (T 'msg.scanfile.running') -Params @{ Path = $path } -Work { param($n,$p) Invoke-SfcScanFile -Path $p.Path -Notify $n } -Done {
            param($r) if (-not $r) { return }
            $script:Ui.TxtScanFileState.Text = if ($r.Ok) { T 'msg.scanfile.ok' $r.Path } else { T 'msg.scanfile.bad' $r.Path $r.Code }
        }
    })
    foreach ($m in 'ChkModeF', 'ChkModeR', 'ChkModeFrx') { $u[$m].Add_Checked({ Update-ChkPreview }) }
    $u.BtnChkdsk.Add_Click({
        $d = if ($script:SelectedDrive) { $script:SelectedDrive } else { $env:SystemDrive.TrimEnd(':') }
        $mode = Get-ChkMode
        $isSys = ($d -ieq $env:SystemDrive.TrimEnd(':'))
        $text = if ($isSys) { T 'chkdsk.confirm.system' $script:Ui.TxtChkCmd.Text } else { T 'chkdsk.confirm.data' $script:Ui.TxtChkCmd.Text $d }
        if ($mode -ne 'f') { $text += "`n`n" + (T 'chkdsk.confirm.slow') }
        Confirm-Action (T 'chkdsk.confirm.title') $text (T 'action.run') {
            $p = @{ Letter = $script:SelectedDrive; Mode = (Get-ChkMode) }
            if (-not $p.Letter) { $p.Letter = $env:SystemDrive.TrimEnd(':') }
            Invoke-Background -History 'Chkdsk' -Title $script:Ui.TxtChkCmd.Text -Params $p -Work { param($n,$p) Invoke-Chkdsk -Letter $p.Letter -Mode $p.Mode -Notify $n } -Done {
                param($r) if (-not $r) { return }
                if ($r.Scheduled) {
                    $script:Ui.TxtChkState.Text = T 'msg.chkdsk.scheduled' $r.Letter
                    Request-Restart (T 'chkdsk.restart.title') (T 'chkdsk.restart.text')
                } else {
                    $script:Ui.TxtChkState.Text = if ($r.Code -le 1) { T 'msg.chkdsk.done' $r.Letter } else { T 'msg.chkdsk.bad' $r.Letter $r.Code }
                }
            }
        }
    })
    $u.BtnWinsock.Add_Click({
        Confirm-Action (T 'netreset.confirm.title') (T 'netreset.confirm.text' 'netsh winsock reset') (T 'action.reset') {
            Invoke-Background -History 'Winsock' -Title 'netsh winsock reset' -Params @{ Part = 'winsock' } -Work { param($n,$p) Reset-NetworkStack -Part $p.Part -Notify $n } -Done {
                param($r) if (-not $r) { return }
                $script:Ui.TxtWinsockState.Text = if ($r.Ok) { T 'msg.netreset.ok' } else { T 'msg.netreset.bad' $r.Code }
                if ($r.Ok) { Request-Restart (T 'netreset.restart.title') (T 'netreset.restart.text') }
            }
        }
    })
    $u.BtnIpReset.Add_Click({
        Confirm-Action (T 'netreset.confirm.title') (T 'netreset.confirm.text' 'netsh int ip reset') (T 'action.reset') {
            Invoke-Background -History 'IpReset' -Title 'netsh int ip reset' -Params @{ Part = 'ip' } -Work { param($n,$p) Reset-NetworkStack -Part $p.Part -Notify $n } -Done {
                param($r) if (-not $r) { return }
                $script:Ui.TxtIpState.Text = if ($r.Ok) { T 'msg.netreset.ok' } else { T 'msg.netreset.bad' $r.Code }
                if ($r.Ok) { Request-Restart (T 'netreset.restart.title') (T 'netreset.restart.text') }
            }
        }
    })
    $u.BtnRecovery.Add_Click({
        Request-Restart (T 'recovery.confirm.title') (T 'recovery.confirm.text') -Recovery
    })

    $u.BtnSpeed.Add_Click({ Start-SpeedTest })
    $u.BtnSpeedOverview.Add_Click({ Start-SpeedTest })

    $u.BtnClearLog.Add_Click({ $script:LogItems.Clear(); $script:LogStore.Clear() })
    $u.BtnSaveLog.Add_Click({
        try {
            $desk = [Environment]::GetFolderPath('Desktop'); if (-not $desk) { $desk = $env:USERPROFILE }
            $path = Join-Path $desk ("{0}-report-{1}.txt" -f $script:AppName, (Get-Date -Format 'yyyyMMdd-HHmmss'))
            $sb = New-Object System.Text.StringBuilder
            [void]$sb.AppendLine("$($script:AppName) $($script:AppVersion) - $(T 'report.title')")
            [void]$sb.AppendLine("$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $env:COMPUTERNAME")
            [void]$sb.AppendLine(('-' * 60))
            foreach ($e in $script:LogStore) { [void]$sb.AppendLine(("{0}  {1,-5}  {2}" -f $e.Time, $e.Kind.ToUpper(), $e.Text)) }
            [IO.File]::WriteAllText($path, $sb.ToString(), (New-Object Text.UTF8Encoding($true)))
            Show-Dialog -Title (T 'report.saved') -Text $path
        } catch { Show-Dialog -Title (T 'report.failed') -Text $_.Exception.Message }
    })
}

# =============================================================================
#  Main loop (rebuilds the window on language / theme change)
# =============================================================================
$script:Rebuild = $true
$first = $true
while ($script:Rebuild) {
    $script:Rebuild = $false
    Initialize-Language -Directory $script:LangDir -Code $script:Settings.Language
    New-MainWindow
    if ($first) { Add-Log (T 'app.started' $script:AppVersion) 'info'; $first = $false }
    if ($script:LastData) { Update-FromRefresh $script:LastData }
    $script:Win.Add_ContentRendered({ if (-not $script:LastData) { Start-Refresh } })
    if ($ScreenshotDir) { Register-Screenshots }
    [void]$script:Win.ShowDialog()
}
