param([switch]$SelfTest, [string]$PreviewDirectory, [string]$PreviewRoot, [string]$PreviewAep, [string]$PreviewSample,
      [switch]$EnsureShortcuts, [string[]]$ShortcutFolders)
# AE AutoSet settings window: pick a work, pick cut folders, copy the request for Codex or Claude.
# Registering a work reads its master AEP without After Effects and suggests every setting.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

$script:SkillRoot = Split-Path $PSScriptRoot -Parent
$script:EngineExe = Join-Path $script:SkillRoot 'assets\AE-AutoSet_TeamKit\tools\bin\AE_TimesheetSession.exe'
$script:DevSource = Join-Path $script:SkillRoot 'AE_TimesheetAuto'
# The development tree ships the Python source; worker installs only carry the frozen engine.
$script:UseDevEngine = ($env:AE_AUTOSET_DEV_ENGINE -eq 'python') -or (Test-Path -LiteralPath (Join-Path $script:DevSource 'helper\persistent_session.py'))
$script:IconPath = Join-Path $PSScriptRoot 'AE-AutoSet.ico'
$script:StateDir = Join-Path $env:LOCALAPPDATA 'AE-AutoSet'
$script:StatePath = Join-Path $script:StateDir 'settings.json'

if (-not ('AEAutoSet.CutRow' -as [type])) {
Add-Type -TypeDefinition @'
using System.ComponentModel;
namespace AEAutoSet {
  public class CutRow : INotifyPropertyChanged {
    private bool isChecked;
    public bool IsChecked { get { return isChecked; } set { if (isChecked != value) { isChecked = value; Raise("IsChecked"); } } }
    public bool Selectable { get; set; }
    public string Name { get; set; }
    public string Output { get; set; }
    public string Badge { get; set; }
    public string Kind { get; set; }
    public string Reason { get; set; }
    public string Path { get; set; }
    public string PackId { get; set; }
    public string Status { get; set; }
    public event PropertyChangedEventHandler PropertyChanged;
    private void Raise(string name) { PropertyChangedEventHandler handler = PropertyChanged; if (handler != null) handler(this, new PropertyChangedEventArgs(name)); }
  }
}
'@
}

# ---------------------------------------------------------------- language
# Korean is the source text. app\lang.json holds the Japanese, English and Chinese versions, keyed by
# the Korean sentence; {0}, {1} ... are filled in by L. A missing entry shows the Korean text.
$script:LangNames = [ordered]@{ en = 'English'; ko = '한국어'; ja = '日本語'; zh = '简体中文' }  # order shown in the picker
function Get-UiLanguage {
    if ($env:AE_AUTOSET_LANG -and $script:LangNames.Contains([string]$env:AE_AUTOSET_LANG)) { return [string]$env:AE_AUTOSET_LANG }
    if ($SelfTest) { return 'ko' }
    try {
        $saved = [string](Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json).language
        if ($saved -and $script:LangNames.Contains($saved)) { return $saved }
    } catch {}
    # First start: follow the Windows display language.
    $system = [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName
    if ($script:LangNames.Contains($system)) { return $system }
    return 'en'
}
# Every table is loaded once so the language can change while the window stays open.
$script:AllStrings = @{}
try {
    $all = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'lang.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($code in @($script:LangNames.Keys)) {
        if ($code -eq 'ko' -or -not $all.$code) { continue }
        $table = @{}
        foreach ($entry in $all.$code.PSObject.Properties) { $table[$entry.Name] = [string]$entry.Value }
        $script:AllStrings[$code] = $table
    }
} catch {}
# Japanese and Chinese need their own UI fonts; Malgun Gothic stays as a fallback for Korean work names.
$script:LangFonts = @{ ko = 'Segoe UI, Malgun Gothic'; en = 'Segoe UI, Malgun Gothic'
                       ja = 'Segoe UI, Yu Gothic UI, Meiryo UI, Malgun Gothic'; zh = 'Segoe UI, Microsoft YaHei UI, Malgun Gothic' }
function Set-LanguageStrings([string]$Code) {
    $script:Lang = $Code
    $script:Strings = if ($script:AllStrings.ContainsKey($Code)) { $script:AllStrings[$Code] } else { @{} }
    $script:UiFont = $script:LangFonts[$Code]
}
Set-LanguageStrings (Get-UiLanguage)
function L([string]$Text) {
    $value = if ($script:Strings.ContainsKey($Text)) { $script:Strings[$Text] } else { $Text }
    if ($args.Count) { return [string]::Format($value, [object[]]$args) }
    return $value
}
# Window definitions keep Korean attribute text; it is swapped just before the XAML is parsed.
function Convert-XamlText([string]$Text) {
    if (-not $script:Strings.Count) { return $Text }
    $evaluator = [Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Groups[1].Value + (L $m.Groups[2].Value) + '"' }
    return [regex]::Replace($Text, '(\b(?:Text|Content|ToolTip|Title|Header)=")([^"]*[\uAC00-\uD7A3][^"]*)"', $evaluator)
}

. (Join-Path $PSScriptRoot 'Runner.ps1')

# ---------------------------------------------------------------- state / engine

function Read-State {
    $state = [ordered]@{ afterfx = ''; last_root = ''; last_work = ''; target = 'codex'; shortcuts = ''
                         claude_model = ''; claude_effort = ''; codex_model = ''; codex_effort = ''; language = '' }
    $folders = [ordered]@{}
    if (Test-Path -LiteralPath $script:StatePath) {
        try {
            $saved = Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($key in @($state.Keys)) { if ($saved.$key) { $state[$key] = [string]$saved.$key } }
            if ($saved.character_fx_folders) {
                foreach ($entry in $saved.character_fx_folders.PSObject.Properties) { if ($entry.Value) { $folders[$entry.Name] = [string]$entry.Value } }
            }
        } catch {}
    }
    $state['character_fx_folders'] = $folders
    $versions = [ordered]@{}
    try {
        if ($saved -and $saved.claude_versions) {
            foreach ($entry in $saved.claude_versions.PSObject.Properties) { if ($entry.Value) { $versions[$entry.Name] = [string]$entry.Value } }
        }
    } catch {}
    $state['claude_versions'] = $versions
    return $state
}
function Save-State {
    if ($SelfTest) { return }  # self-tests never touch the worker's real settings
    New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
    [IO.File]::WriteAllText($script:StatePath, ($script:State | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
}
function Join-Arguments([string[]]$Values) {
    ($Values | ForEach-Object { '"' + ([string]$_).TrimEnd('\').Replace('"', '\"') + '"' }) -join ' '
}
function Invoke-Engine([string[]]$Arguments) {
    $info = New-Object Diagnostics.ProcessStartInfo
    if ($script:UseDevEngine) {
        $info.FileName = 'python'
        $info.Arguments = '-m helper.persistent_session ' + (Join-Arguments $Arguments)
        $info.WorkingDirectory = $script:DevSource
        $info.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    } else {
        $info.FileName = $script:EngineExe
        $info.Arguments = Join-Arguments $Arguments
        $info.WorkingDirectory = Split-Path $script:EngineExe
    }
    $info.EnvironmentVariables['AE_AUTOSET_LANG'] = $script:Lang  # scan reasons and errors in the window's language
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $info.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $process = [Diagnostics.Process]::Start($info)
    $output = $process.StandardOutput.ReadToEnd()
    $errors = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    try { $result = $output | ConvertFrom-Json } catch { throw ((L '엔진 응답을 읽지 못했습니다. ') + $errors) }
    if (-not $result.ok) { throw [string]$result.error }
    return $result
}
function Find-AfterEffects {
    $root = Join-Path $env:ProgramFiles 'Adobe'
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    @(Get-ChildItem -LiteralPath $root -Directory -Filter 'Adobe After Effects *' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'Support Files\AfterFX.exe' } |
        Where-Object { Test-Path -LiteralPath $_ })
}
function Get-AeLabel([string]$Path) {
    $match = [regex]::Match($Path, 'After Effects (\d{4}|\w+)')
    if ($match.Success) { return 'After Effects ' + $match.Groups[1].Value }
    return 'After Effects'
}

# ---------------------------------------------------------------- shared look

$script:Styles = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <!-- Dark palette: near-black surfaces, light gray text, one orange accent. -->
  <SolidColorBrush x:Key="Page" Color="#0E0E10"/>
  <SolidColorBrush x:Key="Card" Color="#161618"/>
  <SolidColorBrush x:Key="Raised" Color="#222225"/>
  <SolidColorBrush x:Key="Line" Color="#26262A"/>
  <SolidColorBrush x:Key="LineStrong" Color="#34343A"/>
  <SolidColorBrush x:Key="Ink" Color="#FAFAFA"/>
  <SolidColorBrush x:Key="Muted" Color="#A1A1A8"/>
  <SolidColorBrush x:Key="Faint" Color="#6C6C75"/>
  <SolidColorBrush x:Key="Accent" Color="#F09E0F"/>
  <SolidColorBrush x:Key="AccentSoft" Color="#2A1D07"/>
  <Style x:Key="Label" TargetType="TextBlock">
    <Setter Property="Foreground" Value="{StaticResource Muted}"/><Setter Property="FontSize" Value="12.5"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Margin" Value="0,0,0,8"/>
  </Style>
  <Style x:Key="Hint" TargetType="TextBlock">
    <Setter Property="Foreground" Value="{StaticResource Muted}"/><Setter Property="FontSize" Value="12"/><Setter Property="TextWrapping" Value="Wrap"/>
  </Style>
  <Style x:Key="Base" TargetType="Button">
    <Setter Property="Foreground" Value="{StaticResource Ink}"/><Setter Property="Background" Value="#1A1A1C"/>
    <Setter Property="BorderBrush" Value="{StaticResource LineStrong}"/><Setter Property="Padding" Value="14,0"/>
    <Setter Property="Height" Value="34"/><Setter Property="FontSize" Value="13"/><Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="Box" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="Background" Value="#242426"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource Base}">
    <Setter Property="Foreground" Value="#111113"/><Setter Property="Background" Value="#FAFAFA"/>
    <Setter Property="Height" Value="40"/><Setter Property="FontSize" Value="14"/><Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Padding" Value="22,0"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="Box" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="Background" Value="#E4E4E7"/></Trigger>
            <Trigger Property="IsEnabled" Value="False">
              <Setter TargetName="Box" Property="Background" Value="#26262A"/><Setter Property="Foreground" Value="#6C6C75"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="Link" TargetType="Button">
    <Setter Property="Foreground" Value="{StaticResource Muted}"/><Setter Property="FontSize" Value="12.5"/><Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Margin" Value="0,0,18,0"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <TextBlock x:Name="Text" Text="{Binding Content, RelativeSource={RelativeSource TemplatedParent}}" Foreground="{TemplateBinding Foreground}"/>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Text" Property="Foreground" Value="#F09E0F"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="More" TargetType="Button">
    <Setter Property="Cursor" Value="Hand"/><Setter Property="Foreground" Value="{StaticResource Muted}"/><Setter Property="FontSize" Value="15"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="Box" Background="Transparent" CornerRadius="6" Width="26" Height="24">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-3,0,0"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="Background" Value="#2A2A2E"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="SideLabel" TargetType="TextBlock">
    <Setter Property="Foreground" Value="{StaticResource Faint}"/><Setter Property="FontSize" Value="11.5"/><Setter Property="FontWeight" Value="SemiBold"/>
  </Style>
  <Style x:Key="SideAdd" TargetType="Button">
    <Setter Property="Foreground" Value="{StaticResource Muted}"/><Setter Property="FontSize" Value="13"/><Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="Box" Background="Transparent" CornerRadius="8" Padding="10,8">
            <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="Background" Value="#1A1A1C"/><Setter Property="Foreground" Value="{StaticResource Ink}"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="WorkCard" TargetType="RadioButton">
    <Setter Property="Cursor" Value="Hand"/><Setter Property="Margin" Value="0,0,0,2"/><Setter Property="Foreground" Value="{StaticResource Ink}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Border x:Name="Box" Background="Transparent" CornerRadius="8" Padding="8,7">
            <ContentPresenter/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="Background" Value="#1A1A1C"/></Trigger>
            <Trigger Property="IsChecked" Value="True"><Setter TargetName="Box" Property="Background" Value="#242426"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="Segment" TargetType="RadioButton">
    <Setter Property="Cursor" Value="Hand"/><Setter Property="FontSize" Value="12.5"/><Setter Property="Foreground" Value="{StaticResource Muted}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Border x:Name="Box" Background="Transparent" CornerRadius="6" Padding="12,5">
            <ContentPresenter x:Name="Text" HorizontalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsChecked" Value="True"><Setter TargetName="Box" Property="Background" Value="#2C2C30"/><Setter Property="Foreground" Value="{StaticResource Ink}"/></Trigger>
            <Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="{StaticResource Ink}"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style TargetType="TextBox">
    <Setter Property="Height" Value="32"/><Setter Property="Padding" Value="8,0"/><Setter Property="VerticalContentAlignment" Value="Center"/>
    <Setter Property="FontSize" Value="13"/><Setter Property="Foreground" Value="{StaticResource Ink}"/><Setter Property="Background" Value="#121214"/>
    <Setter Property="BorderBrush" Value="{StaticResource LineStrong}"/><Setter Property="BorderThickness" Value="1"/>
    <Setter Property="CaretBrush" Value="{StaticResource Ink}"/><Setter Property="SelectionBrush" Value="{StaticResource Accent}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="TextBox">
          <Border x:Name="Box" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
            <ScrollViewer x:Name="PART_ContentHost" Focusable="False" Margin="{TemplateBinding Padding}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="#4A4A52"/></Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style TargetType="ComboBoxItem">
    <Setter Property="Foreground" Value="{StaticResource Ink}"/><Setter Property="Padding" Value="10,6"/><Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ComboBoxItem">
          <Border x:Name="Box" Background="Transparent" CornerRadius="6" Padding="{TemplateBinding Padding}" Margin="4,1">
            <ContentPresenter/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="Box" Property="Background" Value="#26262A"/></Trigger>
            <Trigger Property="IsSelected" Value="True"><Setter Property="Foreground" Value="{StaticResource Accent}"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style TargetType="ComboBox">
    <Setter Property="Height" Value="32"/><Setter Property="FontSize" Value="13"/><Setter Property="VerticalContentAlignment" Value="Center"/>
    <Setter Property="Foreground" Value="{StaticResource Ink}"/><Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ComboBox">
          <Grid>
            <ToggleButton Focusable="False" ClickMode="Press" IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
              <ToggleButton.Template>
                <ControlTemplate TargetType="ToggleButton">
                  <Border x:Name="Box" Background="#161618" BorderBrush="#34343A" BorderThickness="1" CornerRadius="8">
                    <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,1,11,0" Data="M0,0 L4,4 L8,0" Stroke="#A1A1A8" StrokeThickness="1.4"/>
                  </Border>
                  <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="#4A4A52"/></Trigger>
                    <Trigger Property="IsChecked" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="#F09E0F"/></Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate>
              </ToggleButton.Template>
            </ToggleButton>
            <ContentPresenter IsHitTestVisible="False" Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                              Margin="10,0,28,0" VerticalAlignment="Center" HorizontalAlignment="Left"/>
            <Popup x:Name="PART_Popup" IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
              <Border Background="#1A1A1C" BorderBrush="#34343A" BorderThickness="1" CornerRadius="8" Margin="0,4,0,0" Padding="0,4"
                      MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}" MaxHeight="{TemplateBinding MaxDropDownHeight}">
                <ScrollViewer><ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/></ScrollViewer>
              </Border>
            </Popup>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style TargetType="CheckBox">
    <Setter Property="Foreground" Value="{StaticResource Muted}"/><Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="CheckBox">
          <StackPanel Orientation="Horizontal" Background="Transparent">
            <Border x:Name="Box" Width="16" Height="16" CornerRadius="4" BorderThickness="1" BorderBrush="#4A4A52" Background="#121214" VerticalAlignment="Center">
              <Path x:Name="Mark" Data="M3,7.5 L6,10.5 L11.5,4.5" Stroke="#111113" StrokeThickness="2" Visibility="Collapsed"/>
            </Border>
            <ContentPresenter x:Name="Text" Margin="8,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="#8A8A92"/></Trigger>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="Box" Property="Background" Value="#F09E0F"/><Setter TargetName="Box" Property="BorderBrush" Value="#F09E0F"/>
              <Setter TargetName="Mark" Property="Visibility" Value="Visible"/>
            </Trigger>
            <Trigger Property="HasContent" Value="False"><Setter TargetName="Text" Property="Visibility" Value="Collapsed"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.3"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style TargetType="GridViewColumnHeader">
    <Setter Property="Foreground" Value="{StaticResource Faint}"/><Setter Property="FontSize" Value="12"/><Setter Property="HorizontalContentAlignment" Value="Left"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="GridViewColumnHeader">
          <Border Background="Transparent" BorderBrush="{StaticResource Line}" BorderThickness="0,0,0,1" Padding="8,7">
            <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"/>
          </Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style TargetType="ScrollBar">
    <Setter Property="Background" Value="Transparent"/><Setter Property="Width" Value="10"/><Setter Property="MinWidth" Value="10"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ScrollBar">
          <Track x:Name="PART_Track" IsDirectionReversed="True">
            <Track.Thumb>
              <Thumb>
                <Thumb.Template>
                  <ControlTemplate TargetType="Thumb">
                    <Border x:Name="T" Background="#3A3A40" CornerRadius="3" Margin="2"/>
                    <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="T" Property="Background" Value="#55555C"/></Trigger></ControlTemplate.Triggers>
                  </ControlTemplate>
                </Thumb.Template>
              </Thumb>
            </Track.Thumb>
          </Track>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
    <Style.Triggers>
      <Trigger Property="Orientation" Value="Horizontal">
        <Setter Property="Width" Value="Auto"/><Setter Property="MinWidth" Value="0"/><Setter Property="Height" Value="10"/>
        <Setter Property="Template">
          <Setter.Value>
            <ControlTemplate TargetType="ScrollBar">
              <Track x:Name="PART_Track">
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb"><Border Background="#3A3A40" CornerRadius="3" Margin="2"/></ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </ControlTemplate>
          </Setter.Value>
        </Setter>
      </Trigger>
    </Style.Triggers>
  </Style>
  <Style TargetType="ToolTip">
    <Setter Property="Foreground" Value="{StaticResource Ink}"/><Setter Property="Background" Value="#1F1F22"/><Setter Property="BorderBrush" Value="#34343A"/>
    <Setter Property="FontSize" Value="12"/><Setter Property="Padding" Value="9,6"/>
  </Style>
  <Style x:Key="Menu" TargetType="ContextMenu">
    <Setter Property="OverridesDefaultStyle" Value="True"/><Setter Property="HasDropShadow" Value="False"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ContextMenu">
          <Border Background="#1A1A1C" BorderBrush="#34343A" BorderThickness="1" Padding="4">
            <StackPanel IsItemsHost="True"/>
          </Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
    <Style.Resources>
      <Style TargetType="MenuItem">
        <Setter Property="Foreground" Value="#FAFAFA"/><Setter Property="FontSize" Value="13"/><Setter Property="Cursor" Value="Hand"/>
        <Setter Property="Template">
          <Setter.Value>
            <ControlTemplate TargetType="MenuItem">
              <Border x:Name="Box" Background="Transparent" CornerRadius="6" Padding="12,6" MinWidth="120">
                <ContentPresenter ContentSource="Header"/>
              </Border>
              <ControlTemplate.Triggers>
                <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="Box" Property="Background" Value="#26262A"/></Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate>
          </Setter.Value>
        </Setter>
      </Style>
    </Style.Resources>
  </Style>
</ResourceDictionary>
'@

Add-Type -Namespace AEAutoSet -Name Dwm -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);' -ErrorAction SilentlyContinue
function New-Xaml([string]$Text) {
    # Styles must exist while the XAML is parsed, so they are injected as window resources.
    $resources = '<Window.Resources>' + $script:Styles + '</Window.Resources>'
    $Text = (Convert-XamlText $Text).Replace('FontFamily="Segoe UI, Malgun Gothic"', 'FontFamily="' + $script:UiFont + '"')
    $index = $Text.IndexOf('<Grid x:Name="Root"')
    $result = [Windows.Markup.XamlReader]::Parse($Text.Insert($index, $resources))
    # Dark title bar on Windows 10 20H1+ / 11 (ignored elsewhere).
    $result.Add_SourceInitialized({ param($sender, $e)
        try {
            $handle = (New-Object Windows.Interop.WindowInteropHelper $sender).Handle
            $on = 1; [void][AEAutoSet.Dwm]::DwmSetWindowAttribute($handle, 20, [ref]$on, 4)
            $caption = 0x00100E0E; [void][AEAutoSet.Dwm]::DwmSetWindowAttribute($handle, 35, [ref]$caption, 4)
        } catch {}
    })
    if (Test-Path -LiteralPath $script:IconPath) {
        try { $result.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$script:IconPath) } catch {}
    }
    return $result
}

# ---------------------------------------------------------------- desktop / start menu shortcuts

function Update-Shortcuts([bool]$CreateMissing) {
    # Shortcuts are per PC and per Windows user, so each worker's first launch creates them.
    # A shortcut the worker deleted is not recreated unless AE AutoSet.cmd is used again.
    $folders = if ($ShortcutFolders) { @($ShortcutFolders | ForEach-Object { $_ -split ',' } | Where-Object { $_ }) } else {
        @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))
    }
    $script_ = Join-Path $PSScriptRoot 'AE-AutoSet.ps1'
    $target = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $script_ + '"'
    $shell = New-Object -ComObject WScript.Shell
    $made = @()
    foreach ($folder in $folders) {
        if (-not $folder -or -not (Test-Path -LiteralPath $folder -PathType Container)) { continue }
        $path = Join-Path $folder 'AE AutoSet.lnk'
        $exists = Test-Path -LiteralPath $path
        if (-not $exists -and -not $CreateMissing) { continue }
        $link = $shell.CreateShortcut($path)
        # Update only our own shortcut, e.g. after the skill folder moved.
        if ($exists -and ($link.Arguments -notlike '*AE-AutoSet.ps1*')) { continue }
        if ($exists -and $link.Arguments -eq $arguments -and $link.IconLocation -like ($script:IconPath + '*')) { continue }
        $link.TargetPath = $target
        $link.Arguments = $arguments
        $link.WorkingDirectory = $script:SkillRoot
        $link.IconLocation = $script:IconPath + ',0'
        $link.Description = (L 'AE AutoSet 작업 요청 만들기')
        $link.WindowStyle = 7
        $link.Save()
        $made += $path
    }
    return $made
}
function Find([object]$Root, [string]$Name) { $Root.FindName($Name) }
function Show-Message([string]$Text, [string]$Title = 'AE AutoSet') {
    if ($SelfTest) { Write-Host ('[message] ' + $Text); return }
    [void][Windows.MessageBox]::Show($Text, $Title)
}

# ---------------------------------------------------------------- main window

$mainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="AE AutoSet" Width="1060" Height="800" MinWidth="900" MinHeight="640"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI, Malgun Gothic" Background="#0E0E10" Foreground="#FAFAFA">
  <Grid x:Name="Root" Background="#0E0E10">
    <Grid.ColumnDefinitions><ColumnDefinition Width="236"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

    <!-- Left: works, AI and model -->
    <Border Grid.Column="0" Background="#0A0A0B" BorderBrush="{StaticResource Line}" BorderThickness="0,0,1,0" Padding="14,20,14,16">
      <DockPanel>
        <StackPanel DockPanel.Dock="Top">
          <TextBlock Text="AE AutoSet" FontSize="18" FontWeight="SemiBold" Margin="6,0,0,0"/>
          <Border x:Name="AeChip" HorizontalAlignment="Left" CornerRadius="10" Padding="9,3" Margin="6,8,0,0" Cursor="Hand" ToolTip="After Effects 실행 파일을 바꾸려면 누르세요">
            <TextBlock x:Name="AeStatus" FontSize="11.5" TextWrapping="Wrap"/>
          </Border>
          <Border Background="#1A1A1C" CornerRadius="8" Padding="3" Margin="0,18,0,0">
            <UniformGrid Columns="2">
              <RadioButton x:Name="TargetCodex" Content="Codex" GroupName="Target" Style="{StaticResource Segment}"/>
              <RadioButton x:Name="TargetClaude" Content="Claude" GroupName="Target" Style="{StaticResource Segment}"/>
            </UniformGrid>
          </Border>
          <TextBlock Text="작품" Style="{StaticResource SideLabel}" Margin="8,22,0,6"/>
        </StackPanel>
        <StackPanel DockPanel.Dock="Bottom" Margin="0,12,0,0">
          <TextBlock Text="모델" Style="{StaticResource SideLabel}" Margin="8,0,0,6"/>
          <ComboBox x:Name="AiModel" Height="32" FontSize="12.5"
                    ToolTip="(권장)은 가장 성능 좋은 최신 모델이에요. 크레딧을 아끼려면 낮은 모델을 고를 수 있지만 시트 판독이 틀릴 수 있어요."/>
          <TextBlock Text="추론" Style="{StaticResource SideLabel}" Margin="8,12,0,6"/>
          <ComboBox x:Name="AiEffort" Height="32" FontSize="12.5"
                    ToolTip="추론이 높을수록 꼼꼼하게 판독하지만 시간과 크레딧을 더 써요. 권장은 xhigh예요."/>
          <TextBlock Text="언어 · Language" Style="{StaticResource SideLabel}" Margin="8,12,0,6"/>
          <ComboBox x:Name="UiLanguage" Height="32" FontSize="12.5" ToolTip="바꾸면 바로 그 언어로 바뀌어요."/>
        </StackPanel>
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="WorkPanel"/>
        </ScrollViewer>
      </DockPanel>
    </Border>

    <!-- Right: folder, cuts and run -->
    <Grid Grid.Column="1" Margin="28,22,28,20">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <StackPanel Grid.Row="0" Margin="0,0,0,16">
        <TextBlock Text="컷 폴더" FontSize="20" FontWeight="SemiBold"/>
        <TextBlock Text="작품을 고르고 컷 폴더를 넣은 뒤 작업 시작을 누르면 AI가 시트를 읽고 AE 작업까지 해요." Style="{StaticResource Hint}" Margin="0,4,0,0"/>
        <Border x:Name="SetupPanel" Visibility="Collapsed" Background="#1C1708" BorderBrush="#4A3810" BorderThickness="1" CornerRadius="10" Padding="16,12" Margin="0,16,0,0">
          <StackPanel>
            <TextBlock Text="처음 쓰기 전에 준비할 게 있어요" FontSize="14" FontWeight="SemiBold" Foreground="#F2B54A"/>
            <TextBlock Text="PC마다 한 번만 하면 돼요. 왼쪽 위에서 쓸 AI(Codex/Claude)를 먼저 고르세요." Style="{StaticResource Hint}" Margin="0,2,0,10"/>
            <DockPanel Margin="0,0,0,8">
              <Button x:Name="SetupAe" DockPanel.Dock="Right" Content="AfterFX.exe 선택" Style="{StaticResource Base}" Height="30"/>
              <TextBlock x:Name="SetupAeMark" Width="22" FontSize="14" VerticalAlignment="Center"/>
              <TextBlock x:Name="SetupAeText" VerticalAlignment="Center" FontSize="13"/>
            </DockPanel>
            <DockPanel Margin="0,0,0,8">
              <Button x:Name="SetupInstall" DockPanel.Dock="Right" Content="설치" Style="{StaticResource Base}" Height="30"/>
              <TextBlock x:Name="SetupCliMark" Width="22" FontSize="14" VerticalAlignment="Center"/>
              <TextBlock x:Name="SetupCliText" VerticalAlignment="Center" FontSize="13"/>
            </DockPanel>
            <DockPanel>
              <Button x:Name="SetupLogin" DockPanel.Dock="Right" Content="로그인" Style="{StaticResource Base}" Height="30"/>
              <TextBlock x:Name="SetupLoginMark" Width="22" FontSize="14" VerticalAlignment="Center"/>
              <TextBlock x:Name="SetupLoginText" VerticalAlignment="Center" FontSize="13"/>
            </DockPanel>
            <TextBlock x:Name="SetupProgress" Style="{StaticResource Hint}" Margin="22,8,0,0" Visibility="Collapsed"/>
          </StackPanel>
        </Border>
      </StackPanel>

      <StackPanel Grid.Row="1">
        <Border x:Name="DropZone" AllowDrop="True" Background="#161618" CornerRadius="12" Padding="14,10" BorderBrush="{StaticResource LineStrong}" BorderThickness="1">
          <DockPanel>
            <Button x:Name="BrowseFolder" DockPanel.Dock="Right" Content="찾아보기" Style="{StaticResource Base}" VerticalAlignment="Top"/>
            <Button x:Name="OpenPath" DockPanel.Dock="Right" Content="열기" Style="{StaticResource Base}" Margin="0,0,8,0" VerticalAlignment="Top"/>
            <StackPanel VerticalAlignment="Center" Margin="0,0,8,0">
              <Grid>
                <TextBox x:Name="FolderBox" Height="34" AllowDrop="True"/>
                <TextBlock x:Name="FolderPlaceholder" Text="경로를 붙여넣기(Ctrl+V) 하거나 폴더를 끌어다 놓으세요" IsHitTestVisible="False"
                           Foreground="#6C6C75" FontSize="13" Margin="10,0,0,0" VerticalAlignment="Center"/>
              </Grid>
              <TextBlock x:Name="FolderHint" Text="한 컷만 하려면 그 컷 폴더를, 여러 컷은 상위 폴더를 넣으면 돼요. 탐색기에서 폴더를 복사(Ctrl+C)해서 붙여넣어도 돼요." Style="{StaticResource Hint}" Margin="0,4,0,0"/>
            </StackPanel>
          </DockPanel>
        </Border>
      </StackPanel>

      <Border Grid.Row="2" Background="#161618" CornerRadius="12" BorderBrush="{StaticResource Line}" BorderThickness="1" Margin="0,14,0,0">
        <Grid>
          <ListView x:Name="CutList" BorderThickness="0" Background="Transparent" Foreground="#FAFAFA" Margin="4" ScrollViewer.HorizontalScrollBarVisibility="Disabled">
            <ListView.ItemContainerStyle>
              <Style TargetType="ListViewItem">
                <Setter Property="HorizontalContentAlignment" Value="Stretch"/><Setter Property="Padding" Value="2,6"/>
                <Setter Property="ToolTip" Value="{Binding Reason}"/>
                <Setter Property="Template">
                  <Setter.Value>
                    <ControlTemplate TargetType="ListViewItem">
                      <Border x:Name="Row" Background="Transparent" CornerRadius="6" Padding="{TemplateBinding Padding}" Margin="0,1">
                        <GridViewRowPresenter VerticalAlignment="Center"/>
                      </Border>
                      <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Row" Property="Background" Value="#1C1C1F"/></Trigger>
                        <Trigger Property="IsSelected" Value="True"><Setter TargetName="Row" Property="Background" Value="#202024"/></Trigger>
                      </ControlTemplate.Triggers>
                    </ControlTemplate>
                  </Setter.Value>
                </Setter>
                <Style.Triggers>
                  <DataTrigger Binding="{Binding Selectable}" Value="False"><Setter Property="Foreground" Value="#6C6C75"/></DataTrigger>
                </Style.Triggers>
              </Style>
            </ListView.ItemContainerStyle>
            <ListView.View>
              <GridView>
                <GridViewColumn Width="36">
                  <GridViewColumn.Header>
                    <CheckBox x:Name="CheckAllBox" ToolTip="작업 가능한 컷 전체 선택 / 해제"/>
                  </GridViewColumn.Header>
                  <GridViewColumn.CellTemplate>
                    <DataTemplate><CheckBox IsChecked="{Binding IsChecked, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" IsEnabled="{Binding Selectable}"/></DataTemplate>
                  </GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Header="컷" Width="170" DisplayMemberBinding="{Binding Name}"/>
                <GridViewColumn Header="만들어질 파일" Width="230" DisplayMemberBinding="{Binding Output}"/>
                <GridViewColumn Header="상태" Width="250">
                  <GridViewColumn.CellTemplate>
                    <DataTemplate>
                      <StackPanel Orientation="Horizontal">
                        <Border x:Name="Chip" CornerRadius="9" Padding="8,1" Background="#222225">
                          <TextBlock x:Name="ChipText" Text="{Binding Badge}" FontSize="11.5" Foreground="#A1A1A8"/>
                        </Border>
                        <TextBlock Text="{Binding Reason}" FontSize="11.5" Foreground="#828287" Margin="8,0,0,0" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" MaxWidth="150"/>
                      </StackPanel>
                      <DataTemplate.Triggers>
                        <DataTrigger Binding="{Binding Kind}" Value="ready">
                          <Setter TargetName="Chip" Property="Background" Value="#0E2A1A"/><Setter TargetName="ChipText" Property="Foreground" Value="#4ADE80"/>
                        </DataTrigger>
                        <DataTrigger Binding="{Binding Kind}" Value="warn">
                          <Setter TargetName="Chip" Property="Background" Value="#2A1F08"/><Setter TargetName="ChipText" Property="Foreground" Value="#F2B54A"/>
                        </DataTrigger>
                        <DataTrigger Binding="{Binding Kind}" Value="error">
                          <Setter TargetName="Chip" Property="Background" Value="#2D1414"/><Setter TargetName="ChipText" Property="Foreground" Value="#F87171"/>
                        </DataTrigger>
                      </DataTemplate.Triggers>
                    </DataTemplate>
                  </GridViewColumn.CellTemplate>
                </GridViewColumn>
              </GridView>
            </ListView.View>
          </ListView>
          <TextBlock x:Name="EmptyText" Text="폴더를 고르면 컷 목록이 여기에 나와요." Style="{StaticResource Hint}" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="13"/>
        </Grid>
      </Border>

      <DockPanel Grid.Row="3" Margin="2,10,0,16">
        <TextBlock x:Name="CountText" FontSize="12.5" Foreground="#A1A1A8" Margin="0,0,16,0"/>
        <CheckBox x:Name="Rework" Content="재작업 포함" FontSize="12.5" Foreground="#A1A1A8" VerticalAlignment="Center"
                  ToolTip="체크하면 이미 결과가 있는 컷도 고를 수 있어요. 기존 결과는 지우지 않고 _sessions 폴더에 보관한 뒤 다시 만들어요."/>
        <Button x:Name="Rescan" Content="새로 고침" Style="{StaticResource Link}" HorizontalAlignment="Right"/>
      </DockPanel>

      <StackPanel Grid.Row="4">
        <StackPanel Orientation="Horizontal">
          <Button x:Name="RunWork" Content="작업 시작" Style="{StaticResource Primary}"/>
          <Button x:Name="CopyRequest" Content="요청 복사" Style="{StaticResource Base}" Height="40" Margin="8,0,0,0"
                  ToolTip="AI 채팅창에 직접 붙여넣어 진행하려면 요청 문장을 복사하세요"/>
          <StackPanel VerticalAlignment="Center" Margin="14,0,0,0">
            <TextBlock x:Name="AiStatus" Style="{StaticResource Hint}" MaxWidth="380"/>
            <Button x:Name="AiSetup" Content="설치·로그인 방법" Style="{StaticResource Link}" Visibility="Collapsed" Margin="0,2,0,0" HorizontalAlignment="Left"/>
          </StackPanel>
        </StackPanel>
        <Border x:Name="RunPanel" Visibility="Collapsed" Background="#161618" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="10" Padding="14,10" Margin="0,12,0,0">
          <DockPanel>
            <DockPanel DockPanel.Dock="Top" Margin="0,0,0,8">
              <Button x:Name="StopRun" DockPanel.Dock="Right" Content="중지" Style="{StaticResource Base}" Height="30"/>
              <Button x:Name="OpenLog" DockPanel.Dock="Right" Content="전체 기록" Style="{StaticResource Link}" VerticalAlignment="Center"/>
              <TextBlock x:Name="RunTime" DockPanel.Dock="Right" FontSize="12.5" FontWeight="Normal" Foreground="{StaticResource Muted}"
                         VerticalAlignment="Center" Margin="0,0,12,0" Text="00:00"/>
              <TextBlock x:Name="RunTitle" FontSize="13.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
            </DockPanel>
            <TextBox x:Name="RunLog" Height="150" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                     FontSize="12" BorderThickness="0" Background="#0E0E10" Padding="8,6" VerticalContentAlignment="Stretch" Foreground="#A1A1A8"/>
          </DockPanel>
        </Border>
        <Border x:Name="Banner" Visibility="Collapsed" Background="#0E2A1A" CornerRadius="8" Padding="12,8" Margin="0,12,0,0">
          <TextBlock x:Name="BannerText" Foreground="#4ADE80" FontSize="12.5" TextWrapping="Wrap"/>
        </Border>
      </StackPanel>
    </Grid>
  </Grid>
</Window>
'@

$script:State = Read-State
$script:Packs = @()
$script:Rows = New-Object 'System.Collections.ObjectModel.ObservableCollection[AEAutoSet.CutRow]'
$script:ScanRoot = ''
$script:ScanSingle = $false
$script:SelectedWork = ''

$window = New-Xaml $mainXaml
$ui = @{}
foreach ($name in 'Root','AeChip','AeStatus','WorkPanel','DropZone','BrowseFolder','OpenPath','FolderBox','FolderPlaceholder','FolderHint','CutList','EmptyText',
                  'CountText','CheckAllBox','Rescan','Rework','TargetCodex','TargetClaude','CopyRequest','Banner','BannerText',
                  'RunWork','AiStatus','AiSetup','AiModel','AiEffort','RunPanel','StopRun','OpenLog','RunTitle','RunTime','RunLog',
                  'SetupPanel','SetupAe','SetupAeMark','SetupAeText','SetupInstall','SetupCliMark','SetupCliText',
                  'SetupLogin','SetupLoginMark','SetupLoginText','SetupProgress','UiLanguage') { $ui[$name] = Find $window $name }
$ui.CutList.ItemsSource = $script:Rows

function Update-AeStatus {
    $path = $script:State.afterfx
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { $path = @(Find-AfterEffects) | Select-Object -First 1 }
    $converter = New-Object Windows.Media.BrushConverter
    if ($path) {
        $script:AfterFx = $path
        $ui.AeStatus.Text = (L '{0} 연결됨' (Get-AeLabel $path))
        $ui.AeStatus.Foreground = $converter.ConvertFrom('#4ADE80'); $ui.AeChip.Background = $converter.ConvertFrom('#0E2A1A')
    } else {
        $script:AfterFx = ''
        $ui.AeStatus.Text = (L 'After Effects를 찾지 못했어요 · 눌러서 선택')
        $ui.AeStatus.Foreground = $converter.ConvertFrom('#F87171'); $ui.AeChip.Background = $converter.ConvertFrom('#2D1414')
    }
}

function Update-Count {
    $total = $script:Rows.Count
    $checked = @($script:Rows | Where-Object { $_.IsChecked }).Count
    $ready = @($script:Rows | Where-Object { $_.Selectable }).Count
    $ui.EmptyText.Visibility = if ($total) { 'Collapsed' } else { 'Visible' }
    $ui.CountText.Text = if ($total) { L '폴더 {0}개 중 작업 가능 {1}개 · {2}개 선택' $total $ready $checked } else { '' }
    $ui.RunWork.Content = if ($checked) { L '작업 시작 ({0}컷)' $checked } else { L '작업 시작' }
    $busy = [bool]$script:AiRun.running
    $ui.RunWork.IsEnabled = ($checked -gt 0) -and -not $busy
    $ui.CopyRequest.IsEnabled = ($checked -gt 0) -and -not $busy
    # The header box shows checked only when every cut that can be worked on is checked.
    $ui.CheckAllBox.IsChecked = ($ready -gt 0) -and ($checked -eq $ready)
    $ui.CheckAllBox.IsEnabled = ($ready -gt 0) -and -not $busy
}

function Get-Badge($Scene) {
    switch ($Scene.status) {
        'ready'        { return @((L '작업 가능'), 'ready') }
        'exists'       { return @((L '완료됨'), 'warn') }
        'previous_run' { return @((L '이전 기록'), 'warn') }
        'multi_cut'    { return @((L '여러 컷'), 'warn') }
        'no_sheet'     { return @((L '시트 없음'), 'warn') }
        'protected'    { return @((L '양식 컷'), 'muted') }
        'error'        { return @((L '확인 필요'), 'error') }
        default        { return @((L '작품 규칙 밖'), 'muted') }
    }
}

function Set-Rows {
    $script:Rows.Clear()
    foreach ($scene in @($script:ScanResult.scenes)) {
        $badge = Get-Badge $scene
        $row = New-Object AEAutoSet.CutRow
        $row.Name = $scene.name; $row.Path = $scene.path; $row.PackId = [string]$scene.pack_id
        $row.Output = if ($scene.output_aep) { $scene.output_aep } else { '—' }
        $row.Badge = $badge[0]; $row.Kind = $badge[1]; $row.Reason = if ($scene.status -eq 'ready') { '' } else { [string]$scene.reason }
        $otherWork = $script:SelectedWork -and $scene.pack_id -and ($scene.pack_id -ne $script:SelectedWork)
        if ($otherWork) { $row.Badge = (L '다른 작품 · {0}' $scene.pack_id); $row.Kind = 'muted'; $row.Reason = (L '선택한 작품이 아니에요') }
        $row.Status = [string]$scene.status
        # Finished or previously started cuts are offered only when the worker asks for rework.
        $reworkable = $ui.Rework.IsChecked -and ($scene.status -eq 'exists' -or $scene.status -eq 'previous_run')
        $row.Selectable = (($scene.status -eq 'ready') -or $reworkable) -and -not $otherWork
        $row.IsChecked = ($scene.status -eq 'ready') -and -not $otherWork
        $row.add_PropertyChanged({ Update-Count })
        $script:Rows.Add($row)
    }
    Update-Count
}

function Select-WorkCard([string]$Id) {
    $script:SelectedWork = $Id
    foreach ($card in $ui.WorkPanel.Children) { if ($card.Tag -is [string]) { $card.IsChecked = ($card.Tag -eq $Id) } }
}

function Load-Packs([switch]$Cached) {
    $ui.WorkPanel.Children.Clear()
    # A language change only redraws the cards; the registered works are the same.
    if (-not ($Cached -and $script:Packs)) {
        try { $result = Invoke-Engine @('packs'); $script:Packs = @($result.packs) } catch { $script:Packs = @(); Show-Message $_.Exception.Message }
    }
    foreach ($pack in $script:Packs) {
        $card = New-Object Windows.Controls.RadioButton
        $card.Style = $window.FindResource('WorkCard'); $card.GroupName = 'Work'; $card.Tag = [string]$pack.id
        $brush = New-Object Windows.Media.BrushConverter
        $stack = New-Object Windows.Controls.StackPanel; $stack.VerticalAlignment = 'Center'
        $title = New-Object Windows.Controls.TextBlock; $title.Text = [string]$pack.name; $title.FontSize = 13.5; $title.FontWeight = 'SemiBold'
        $title.TextTrimming = 'CharacterEllipsis'
        $sub = New-Object Windows.Controls.TextBlock; $sub.Text = [string]$pack.id + ' · ' + [string]$pack.scene_pattern; $sub.FontSize = 11
        $sub.Foreground = $brush.ConvertFrom('#828287'); $sub.Margin = '0,1,0,0'; $sub.TextTrimming = 'CharacterEllipsis'
        $stack.Children.Add($title) | Out-Null; $stack.Children.Add($sub) | Out-Null
        # A small badge with the work code, like a project avatar.
        $badge = New-Object Windows.Controls.Border; $badge.Width = 28; $badge.Height = 28; $badge.CornerRadius = 7
        $badge.Background = $brush.ConvertFrom('#2A1D07'); $badge.Margin = '0,0,10,0'; $badge.VerticalAlignment = 'Center'
        $mark = New-Object Windows.Controls.TextBlock; $code = [string]$pack.id
        $mark.Text = $code.Substring(0, [Math]::Min(3, $code.Length)); $mark.FontSize = 10.5; $mark.FontWeight = 'Bold'
        $mark.Foreground = $brush.ConvertFrom('#F09E0F'); $mark.HorizontalAlignment = 'Center'; $mark.VerticalAlignment = 'Center'
        $badge.Child = $mark
        # The ⋯ button opens this work's menu; it does not select the card.
        $more = New-Object Windows.Controls.Button
        $more.Style = $window.FindResource('More'); $more.Content = [string][char]0x22EF; $more.Tag = [string]$pack.id
        $more.ToolTip = (L '더보기'); $more.VerticalAlignment = 'Center'; $more.Margin = '6,0,-4,0'
        $menu = New-Object Windows.Controls.ContextMenu
        $menu.Style = $window.FindResource('Menu')
        foreach ($entry in @(@((L '설정 수정'), 'edit'), @((L '삭제'), 'remove'))) {
            $item = New-Object Windows.Controls.MenuItem
            $item.Header = $entry[0]; $item.Tag = @([string]$pack.id, $entry[1])
            $item.Add_Click({ param($sender, $e)
                if ($sender.Tag[1] -eq 'edit') { Edit-Work $sender.Tag[0] } else { Remove-Work $sender.Tag[0] }
            })
            $menu.Items.Add($item) | Out-Null
        }
        $more.ContextMenu = $menu
        $more.Add_Click({ param($sender, $e)
            $sender.ContextMenu.PlacementTarget = $sender
            $sender.ContextMenu.Placement = 'Bottom'
            $sender.ContextMenu.IsOpen = $true
            $e.Handled = $true
        })
        $body = New-Object Windows.Controls.DockPanel
        [Windows.Controls.DockPanel]::SetDock($more, 'Right')
        $body.Children.Add($more) | Out-Null; $body.Children.Add($badge) | Out-Null; $body.Children.Add($stack) | Out-Null
        $card.Content = $body
        $card.Add_Checked({ param($sender, $e) $script:SelectedWork = [string]$sender.Tag; $script:State.last_work = $script:SelectedWork; if ($script:ScanResult) { Set-Rows } })
        $ui.WorkPanel.Children.Add($card) | Out-Null
    }
    $add = New-Object Windows.Controls.Button
    $add.Style = $window.FindResource('SideAdd'); $add.Content = (L '+  새 작품'); $add.Margin = '0,4,0,0'
    $add.Add_Click({ Open-Register $null })
    $ui.WorkPanel.Children.Add($add) | Out-Null
    $known = @($script:Packs | ForEach-Object { [string]$_.id })
    if ($script:State.last_work -and ($known -contains $script:State.last_work)) { Select-WorkCard $script:State.last_work }
    elseif ($known.Count) { Select-WorkCard $known[0] }
}

function ConvertTo-FolderPath([string]$Text) {
    # Accept "Copy as path" quotes, trailing spaces, and a file inside the folder.
    if (-not $Text) { return '' }
    $line = (($Text -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
    if (-not $line) { return '' }
    $value = $line.Trim().Trim('"', "'").Trim()
    if ($value -and (Test-Path -LiteralPath $value -PathType Leaf)) { $value = Split-Path $value -Parent }
    return $value
}
function Set-FolderHint([string]$Text, [bool]$IsError = $false) {
    $ui.FolderHint.Text = $Text
    $ui.FolderHint.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFrom($(if ($IsError) { '#F87171' } else { '#A1A1A8' }))
}
function Scan-Folder([string]$Path) {
    $Path = ConvertTo-FolderPath $Path
    if (-not $Path) { return }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Set-FolderHint (L '폴더를 찾을 수 없어요: {0}' $Path) $true; return }
    $window.Cursor = 'Wait'
    try {
        $script:ScanResult = Invoke-Engine @('scan', '--root', $Path)
        $script:ScanRoot = [string]$script:ScanResult.root
        $script:ScanSingle = [bool]$script:ScanResult.single
        $ui.FolderBox.Text = $script:ScanRoot
        $ui.FolderBox.CaretIndex = $ui.FolderBox.Text.Length
        Set-FolderHint $(if ($script:ScanSingle) { L '컷 폴더 하나를 읽었어요.' } else { L '상위 폴더 안의 컷들을 찾았어요. 작업할 컷만 체크하세요.' })
        $script:State.last_root = $script:ScanRoot
        # Pick the work most cuts belong to, so a first-time user rarely has to choose.
        $counts = @($script:ScanResult.scenes | Where-Object { $_.pack_id } | Group-Object pack_id | Sort-Object Count -Descending)
        if ($counts.Count) { Select-WorkCard ([string]$counts[0].Name) }
        Set-Rows
        $ui.Banner.Visibility = 'Collapsed'
    } catch { Show-Message $_.Exception.Message } finally { $window.Cursor = $null }
}

function Build-Request([switch]$NoPrefix) {
    $chosen = @($script:Rows | Where-Object { $_.IsChecked })
    if (-not $chosen.Count) { return $null }
    $prefix = if ($NoPrefix) { 'AE AutoSet:' } elseif ($ui.TargetClaude.IsChecked) { '/ae-autoset' } else { '$ae-autoset' }
    # Every request form carries the rework permission when a chosen cut already has results.
    $rework = @($chosen | Where-Object { $_.Status -eq 'exists' -or $_.Status -eq 'previous_run' }).Count
    $suffix = if ($rework) { L ' (기존 결과 재작업)' } else { '' }
    if ($script:ScanSingle) { return "$prefix `"$($script:ScanRoot)`" " + (L '작업 진행') + $suffix }
    $names = ($chosen | ForEach-Object { $_.Name }) -join ', '
    $allReady = @($script:Rows | Where-Object { $_.Selectable }).Count
    if ($chosen.Count -eq $allReady -and $chosen.Count -eq @($script:Rows | Where-Object { $_.PackId }).Count) {
        return "$prefix `"$($script:ScanRoot)`" " + (L '작업 진행') + $suffix
    }
    return "$prefix `"$($script:ScanRoot)`" " + (L '에서 다음 컷만 작업 진행: {0}' $names) + $suffix
}

$ui.CheckAllBox.Add_Click({
    $on = [bool]$ui.CheckAllBox.IsChecked
    foreach ($row in $script:Rows) { $row.IsChecked = $on -and $row.Selectable }
    Update-Count
})
$ui.Rework.Add_Click({ if ($script:ScanResult) { Set-Rows } })
$ui.Rescan.Add_Click({ if ($script:ScanRoot) { Scan-Folder $script:ScanRoot } })
$ui.BrowseFolder.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = (L '컷 폴더 또는 컷들이 들어 있는 상위 폴더를 고르세요')
    if ($script:State.last_root -and (Test-Path -LiteralPath $script:State.last_root)) { $dialog.SelectedPath = $script:State.last_root }
    if ($dialog.ShowDialog() -eq 'OK') { Scan-Folder $dialog.SelectedPath }
})
$ui.DropZone.Add_DragOver({ param($s, $e) $e.Effects = 'Copy'; $e.Handled = $true })
$ui.DropZone.Add_Drop({ param($s, $e)
    $paths = $e.Data.GetData([Windows.DataFormats]::FileDrop)
    if ($paths -and $paths.Count) { Scan-Folder ([string]$paths[0]) }
})
# A TextBox handles drops itself, so folder drops are caught before it.
$ui.FolderBox.Add_PreviewDragOver({ param($s, $e) if ($e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) { $e.Effects = 'Copy'; $e.Handled = $true } })
$ui.FolderBox.Add_PreviewDrop({ param($s, $e)
    $paths = $e.Data.GetData([Windows.DataFormats]::FileDrop)
    if ($paths -and $paths.Count) { $e.Handled = $true; Scan-Folder ([string]$paths[0]) }
})
$ui.FolderBox.Add_TextChanged({
    $ui.FolderPlaceholder.Visibility = if ($ui.FolderBox.Text) { 'Collapsed' } else { 'Visible' }
})
$ui.FolderBox.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { $e.Handled = $true; Scan-Folder $ui.FolderBox.Text } })
$ui.FolderBox.Add_LostKeyboardFocus({
    $typed = ConvertTo-FolderPath $ui.FolderBox.Text
    if ($typed -and $typed -ne $script:ScanRoot -and (Test-Path -LiteralPath $typed -PathType Container)) { Scan-Folder $typed }
})
# Pasting a path reads the folder right away.
[Windows.DataObject]::AddPastingHandler($ui.FolderBox, [Windows.DataObjectPastingEventHandler]{
    param($s, $e)
    $null = $window.Dispatcher.BeginInvoke([Action]{ Scan-Folder $ui.FolderBox.Text }, [Windows.Threading.DispatcherPriority]::Background)
})
# Ctrl+V anywhere: a path as text, or a folder copied in Explorer (Ctrl+C).
$window.Add_PreviewKeyDown({ param($s, $e)
    if ($e.Key -ne 'V' -or -not ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control)) { return }
    if ([Windows.Clipboard]::ContainsFileDropList()) {
        $files = [Windows.Clipboard]::GetFileDropList()
        if ($files.Count) { $e.Handled = $true; Scan-Folder ([string]$files[0]) }
        return
    }
    $focused = [Windows.Input.Keyboard]::FocusedElement
    if ($focused -is [Windows.Controls.TextBox] -or $focused -is [Windows.Controls.ComboBox]) { return }
    if ([Windows.Clipboard]::ContainsText()) { $e.Handled = $true; Scan-Folder ([Windows.Clipboard]::GetText()) }
})
$ui.OpenPath.Add_Click({ Scan-Folder $ui.FolderBox.Text })
$ui.CopyRequest.Add_Click({
    $text = Build-Request
    if (-not $text) { return }
    if (-not $SelfTest) { [Windows.Clipboard]::SetText($text) }
    $target = if ($ui.TargetClaude.IsChecked) { 'Claude' } else { 'Codex' }
    $ui.BannerText.Text = (L '복사했어요. {0} 채팅창에 붙여넣고 보내면 작업이 시작돼요.' $target) + "`n" + $text
    $ui.Banner.Visibility = 'Visible'
    Save-State
})
$ui.TargetCodex.Add_Checked({ $script:State.target = 'codex'; Fill-AiChoices; Update-AiStatus })
$ui.TargetClaude.Add_Checked({ $script:State.target = 'claude'; Fill-AiChoices; Update-AiStatus })

# Model / reasoning pickers. The "(권장)" entry (id '') is the default: newest top model, xhigh. Picks are saved per PC.
function Set-ComboOptions($Combo, $Options, [string]$Selected) {
    $Combo.Items.Clear()
    $index = -1; $recommended = 0
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $item = New-Object Windows.Controls.ComboBoxItem
        $item.Content = $Options[$i].text; $item.Tag = $Options[$i].id
        [void]$Combo.Items.Add($item)
        if ($Options[$i].id -eq '') { $recommended = $i }
        if ($Selected -and $Options[$i].id -eq $Selected) { $index = $i }
    }
    $Combo.SelectedIndex = $(if ($index -ge 0) { $index } else { $recommended })
}
function Fill-AiChoices {
    $script:FillingAi = $true
    try {
        $target = Get-Target
        $model = [string]$script:State[$target + '_model']
        Set-ComboOptions $ui.AiModel (Get-AiModelOptions $target) $model
        $model = [string]$ui.AiModel.SelectedItem.Tag
        $script:State[$target + '_model'] = $model
        Set-ComboOptions $ui.AiEffort (Get-AiEffortOptions $target $model) ([string]$script:State[$target + '_effort'])
        $script:State[$target + '_effort'] = [string]$ui.AiEffort.SelectedItem.Tag
    } finally { $script:FillingAi = $false }
}
$ui.AiModel.Add_SelectionChanged({
    if ($script:FillingAi -or -not $ui.AiModel.SelectedItem) { return }
    $target = Get-Target
    $script:State[$target + '_model'] = [string]$ui.AiModel.SelectedItem.Tag
    Fill-AiChoices; Save-State; Update-AiStatus
})
$ui.AiEffort.Add_SelectionChanged({
    if ($script:FillingAi -or -not $ui.AiEffort.SelectedItem) { return }
    $script:State[(Get-Target) + '_effort'] = [string]$ui.AiEffort.SelectedItem.Tag
    Save-State; Update-AiStatus
})

# Language: each name in its own language. Changing it switches the open window to that language.
$script:FillingLang = $true
foreach ($code in $script:LangNames.Keys) {
    $item = New-Object Windows.Controls.ComboBoxItem
    $item.Content = $script:LangNames[$code]; $item.Tag = $code
    [void]$ui.UiLanguage.Items.Add($item)
    if ($code -eq $script:Lang) { $ui.UiLanguage.SelectedItem = $item }
}
$script:FillingLang = $false
$ui.UiLanguage.Add_SelectionChanged({
    if ($script:FillingLang -or -not $ui.UiLanguage.SelectedItem) { return }
    $code = [string]$ui.UiLanguage.SelectedItem.Tag
    if ($code -eq $script:Lang) { return }
    $script:State.language = $code
    Save-State
    $window.Cursor = 'Wait'
    try { Switch-UiLanguage $code } catch { Show-Message $_.Exception.Message } finally { $window.Cursor = $null }
})

# The window stays open: every text it shows is looked up again in the new language.
function Get-UiTemplates {
    # Sentences with {0}, {1}... as shown in the current language, to recognise them once filled in.
    $list = foreach ($key in @($script:AllStrings.Values | ForEach-Object { $_.Keys } | Where-Object { $_ -match '\{\d\}' } | Sort-Object -Unique)) {
        $shown = L $key
        $parts = [regex]::Split($shown, '\{(\d)\}')
        $pattern = ''; $order = @()
        for ($i = 0; $i -lt $parts.Count; $i++) { if ($i % 2) { $pattern += '(.*?)'; $order += [int]$parts[$i] } else { $pattern += [regex]::Escape($parts[$i]) } }
        [pscustomobject]@{ key = $key; order = $order; literal = ($shown -replace '\{\d\}', '').Length
                           regex = New-Object Text.RegularExpressions.Regex(('^' + $pattern + '$'), [Text.RegularExpressions.RegexOptions]::Singleline) }
    }
    return @($list | Where-Object { $_.literal -ge 2 } | Sort-Object literal -Descending)
}
function Convert-UiValue($Value, $Reverse, $Templates) {
    if ($Value -isnot [string] -or -not $Value) { return $null }
    $new = $null
    if ($Reverse) { $key = $null; if ($Reverse.TryGetValue($Value, [ref]$key)) { $new = L $key } }
    elseif ($script:Strings.ContainsKey($Value)) { $new = L $Value }
    if ($null -eq $new) {
        foreach ($template in $Templates) {
            $match = $template.regex.Match($Value)
            if (-not $match.Success) { continue }
            $values = New-Object object[] (($template.order | Measure-Object -Maximum).Maximum + 1)
            for ($i = 0; $i -lt $template.order.Count; $i++) { $values[$template.order[$i]] = $match.Groups[$i + 1].Value }
            $new = [string]::Format((L $template.key), $values); break
        }
    }
    if ($null -eq $new -or $new -ceq $Value) { return $null }
    return $new
}
function Update-UiTree($Node, $Reverse, $Templates, [string]$OldFont) {
    if ($Node -isnot [Windows.DependencyObject]) { return }
    $fontProperty = [Windows.Documents.TextElement]::FontFamilyProperty
    if ($OldFont) {
        $font = $Node.ReadLocalValue($fontProperty)
        if ($font -is [Windows.Media.FontFamily] -and $font.Source -eq $OldFont) { $Node.SetValue($fontProperty, (New-Object Windows.Media.FontFamily($script:UiFont))) }
    }
    $bound = { param($property) [Windows.Data.BindingOperations]::IsDataBound($Node, $property) }
    if ($Node -is [Windows.Controls.TextBlock] -and $Node.Inlines.Count -le 1 -and -not (& $bound ([Windows.Controls.TextBlock]::TextProperty))) {
        $new = Convert-UiValue $Node.Text $Reverse $Templates; if ($null -ne $new) { $Node.Text = $new }
    } elseif ($Node -is [Windows.Documents.Run] -and -not (& $bound ([Windows.Documents.Run]::TextProperty))) {
        $new = Convert-UiValue $Node.Text $Reverse $Templates; if ($null -ne $new) { $Node.Text = $new }
    }
    if ($Node -is [Windows.Window]) { $new = Convert-UiValue $Node.Title $Reverse $Templates; if ($null -ne $new) { $Node.Title = $new } }
    if ($Node -is [Windows.Controls.ContentControl] -and -not (& $bound ([Windows.Controls.ContentControl]::ContentProperty))) {
        $new = Convert-UiValue $Node.Content $Reverse $Templates; if ($null -ne $new) { $Node.Content = $new }
    }
    if ($Node -is [Windows.Controls.HeaderedItemsControl] -or $Node -is [Windows.Controls.HeaderedContentControl]) {
        $new = Convert-UiValue $Node.Header $Reverse $Templates; if ($null -ne $new) { $Node.Header = $new }
    }
    if ($Node -is [Windows.FrameworkElement] -and -not (& $bound ([Windows.FrameworkElement]::ToolTipProperty))) {
        $new = Convert-UiValue $Node.ToolTip $Reverse $Templates; if ($null -ne $new) { $Node.ToolTip = $new }
    }
    if ($Node -is [Windows.Controls.ListView] -and $Node.View -is [Windows.Controls.GridView]) {
        foreach ($column in $Node.View.Columns) { $new = Convert-UiValue $column.Header $Reverse $Templates; if ($null -ne $new) { $column.Header = $new } }
    }
    foreach ($child in @([Windows.LogicalTreeHelper]::GetChildren($Node))) { Update-UiTree $child $Reverse $Templates $OldFont }
}
function Switch-UiLanguage([string]$Code) {
    if ($Code -eq $script:Lang) { return }
    $oldFont = $script:UiFont
    $reverse = $null  # text shown now -> Korean source sentence
    if ($script:Lang -ne 'ko') {
        $reverse = New-Object 'Collections.Generic.Dictionary[string,string]'
        foreach ($key in $script:Strings.Keys) { $value = $script:Strings[$key]; if ($value -and -not $reverse.ContainsKey($value)) { $reverse[$value] = $key } }
    }
    $templates = Get-UiTemplates
    Set-LanguageStrings $Code
    $script:TopLabel = (L '(맨 위에 놓기)')
    $script:NoCamera = (L '카메라 없음 (카메라 이동은 작업자가 처리)')
    Update-UiTree $window $reverse $templates $(if ($oldFont -ne $script:UiFont) { $oldFont } else { '' })
    # Parts the code builds: status lines, model lists, work cards and the cut list.
    Update-AeStatus
    try { Fill-AiChoices; Update-AiStatus } catch {}
    try { Update-SetupPanel } catch {}
    $checked = @($script:Rows | Where-Object { $_.IsChecked } | ForEach-Object { $_.Name })
    if ($script:ScanRoot) { try { $script:ScanResult = Invoke-Engine @('scan', '--root', $script:ScanRoot) } catch {} }
    Load-Packs -Cached
    if ($script:ScanResult) {
        Set-Rows
        foreach ($row in $script:Rows) { $row.IsChecked = $row.Selectable -and ($checked -contains $row.Name) }
    }
    Update-Count
}

# ---------------------------------------------------------------- run with Claude Code / Codex

$script:AiRun = @{ running = $false }
$script:RunsDir = if ($SelfTest) { Join-Path ([IO.Path]::GetTempPath()) 'ae-autoset-selftest-runs' } else { Join-Path $script:StateDir 'runs' }

function Get-Target { if ($ui.TargetClaude.IsChecked) { 'claude' } else { 'codex' } }

function Update-AiStatus {
    $target = Get-Target
    $label = $script:AiLabels[$target]
    $exe = Find-AiCli $target
    $script:AiCli = $exe
    $ui.AiSetup.Visibility = 'Collapsed'
    $script:AiLogin = $null
    if (-not $exe) {
        $ui.AiStatus.Text = (L '{0} 프로그램이 아직 없어요. 위 준비 칸에서 설치하세요.' $label)
        Update-SetupPanel; return
    }
    $script:AiLogin = Test-AiLogin $target $exe
    if ($script:AiLogin -eq $false) {
        $ui.AiStatus.Text = (L '{0}에 로그인이 필요해요. 위 준비 칸에서 로그인하세요.' $label)
        Update-SetupPanel; return
    }
    $ui.AiStatus.Text = (L '{0} ({1})로 바로 실행해요.' $label (Get-AiModelChoice $target).label)
    Update-SetupPanel
}

function Show-AiSetup {
    $target = Get-Target
    if ($target -eq 'claude') {
        $install = 'irm https://claude.ai/install.ps1 | iex'
        $login = 'claude auth login'
        $text = L "Claude Code 프로그램(CLI)을 한 번 설치하고 로그인하면 돼요.`n`n1. PowerShell을 열고 설치 명령을 붙여넣어 실행하세요. (관리자 권한 필요 없음)`n   {0}`n2. 설치가 끝나면 PowerShell에서 로그인하세요.`n   {1}`n3. 이 창을 다시 열면 '작업 시작'을 쓸 수 있어요.`n`n[예]를 누르면 설치 명령을 복사해요." $install $login
    } else {
        $install = 'irm https://chatgpt.com/codex/install.ps1 | iex'
        $login = 'codex login'
        $text = L "Codex 프로그램(CLI)을 한 번 설치하고 로그인하면 돼요.`n`n1. PowerShell을 열고 설치 명령을 붙여넣어 실행하세요.`n   {0}`n2. 설치가 끝나면 PowerShell을 새로 열고 로그인하세요. (ChatGPT 계정)`n   {1}`n3. 이 창을 다시 열면 '작업 시작'을 쓸 수 있어요.`n`n[예]를 누르면 설치 명령을 복사해요." $install $login
    }
    $answer = [Windows.MessageBox]::Show($text, (L 'AE AutoSet · 설치 방법'), 'YesNo')
    if ([string]$answer -eq 'Yes') { [Windows.Clipboard]::SetText($install) }
}

function Add-RunLog([string]$Text) {
    if (-not $Text) { return }
    $ui.RunLog.AppendText($(if ($ui.RunLog.Text) { "`r`n" } else { '' }) + $Text)
    $ui.RunLog.ScrollToEnd()
}

function Set-Busy([bool]$Busy) {
    $script:AiRun.running = $Busy
    foreach ($control in 'WorkPanel', 'DropZone', 'CutList', 'TargetCodex', 'TargetClaude', 'AiModel', 'AiEffort', 'UiLanguage', 'CheckAllBox', 'Rescan', 'Rework') { $ui[$control].IsEnabled = -not $Busy }
    $ui.StopRun.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' }
    Update-Count
}

function Start-AiRun {
    $target = Get-Target
    $label = $script:AiLabels[$target]
    if (-not $script:AiCli) { Update-AiStatus }
    if (-not $script:AiCli -or $script:AiLogin -eq $false) {
        Update-SetupPanel
        if (-not $SelfTest) { Show-Message (L '{0} 준비가 필요해요. 위 준비 칸에서 설치·로그인을 마쳐 주세요.' $label) }
        return
    }
    $request = Build-Request -NoPrefix
    if (-not $request) { return }
    $names = @($script:Rows | Where-Object { $_.IsChecked } | ForEach-Object { $_.Name })
    $message = (L '{0}로 {1}컷 작업을 시작할까요?' $label $names.Count) + "`n`n" + (($names | Select-Object -First 8) -join ', ') + $(if ($names.Count -gt 8) { ' …' } else { '' }) +
               "`n`n" + (L '작업 중에는 After Effects 창이 열리고, 끝날 때까지 이 창에서 진행 상황을 볼 수 있어요. 대상 AE 프로젝트는 그동안 편집하지 마세요.') +
               $(if ($target -eq 'codex') { "`n`n" + (L 'Codex는 이 방식에서 PC 전체 권한으로 실행돼요(After Effects를 띄우기 위해 필요). 지침에는 AE AutoSet 작업만 하도록 적혀 있어요.') } else { '' })
    if (-not $SelfTest -and [string]([Windows.MessageBox]::Show($message, 'AE AutoSet', 'OKCancel')) -ne 'OK') { return }
    try {
        $command = Get-AiCommand $target $script:AiCli $script:ScanRoot $script:SkillRoot
        $prompt = New-AiPrompt $request $script:SkillRoot $target
    } catch { Show-Message $_.Exception.Message; return }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:AiRun = @{ running = $true; target = $target; label = $label; session = ''; final = ''; done = $false; isError = $false;
                       denied = @(); stderr = @(); started = Get-Date; stopped = $false; log = (Join-Path $script:RunsDir ($stamp + '-' + $target + '.log')) }
    $script:LastCommand = $command; $script:LastPrompt = $prompt
    $ui.RunLog.Clear(); $ui.Banner.Visibility = 'Collapsed'; $ui.RunPanel.Visibility = 'Visible'
    $script:AiRun.titleBase = (L '{0} 작업 중 · {1}컷' $label $names.Count)
    $ui.RunTitle.Text = $script:AiRun.titleBase
    $ui.RunTime.Text = '00:00'
    Add-RunLog (L '요청: {0}' $request)
    Set-Busy $true
    $script:Runner = New-Object AEAutoSet.AiRunner
    try {
        $script:Runner.Start($command.file, $command.arguments, $command.cwd, $prompt, $command.env, $script:AiRun.log)
    } catch {
        Add-RunLog (L '! 시작하지 못했어요: {0}' $_.Exception.Message); Set-Busy $false; return
    }
    $script:RunTimer.Start()
}

function Complete-AiRun {
    $script:RunTimer.Stop()
    # A newer Claude version seen in this run updates the model list labels.
    if ($script:AiRun.versionChanged) { Save-State; try { Fill-AiChoices; Update-AiStatus } catch {} }
    $ui.RunTime.Text = Format-Elapsed ((Get-Date) - $script:AiRun.started)
    $code = $script:Runner.ExitCode
    if ($script:AiRun.stopped) { $ui.RunTitle.Text = (L '중지했어요') }
    elseif ($script:AiRun.isError -or ($code -ne 0 -and -not $script:AiRun.done)) { $ui.RunTitle.Text = (L '문제가 있어 끝났어요') }
    else { $ui.RunTitle.Text = (L '작업 완료') }
    # Codex already showed its final message in the stream; Claude reports it only in the result event.
    if ($script:AiRun.final -and $script:AiRun.target -eq 'claude') { Add-RunLog ("`r`n" + $script:AiRun.final.Trim()) }
    if ($script:AiRun.denied.Count) { Add-RunLog (L '! 허용하지 않은 동작은 막았어요: {0}' (($script:AiRun.denied | Select-Object -Unique) -join ', ')) }
    if (-not $script:AiRun.done -and -not $script:AiRun.stopped -and $script:AiRun.stderr.Count) {
        Add-RunLog ('! ' + (($script:AiRun.stderr | Select-Object -Last 4) -join ' / '))
    }
    if ($script:AiRun.stopped) { Add-RunLog (L '중지했어요. After Effects가 이미 받은 컷은 계속 저장될 수 있으니 AE 창을 확인하세요.') }
    Set-Busy $false
    if ($script:ScanRoot -and -not $SelfTest) {
        $keep = $ui.RunLog.Text; Scan-Folder $script:ScanRoot
        $ui.RunLog.Text = $keep; $ui.RunLog.ScrollToEnd(); $ui.RunPanel.Visibility = 'Visible'
    }
}

$script:RunTimer = New-Object Windows.Threading.DispatcherTimer
$script:RunTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:RunTimer.Add_Tick({ Receive-AiOutput })

# Elapsed time as mm:ss, or hh:mm:ss from one hour on (e.g. 01:15:03).
function Format-Elapsed([TimeSpan]$Span) {
    $hours = [int][math]::Floor($Span.TotalHours)
    if ($hours -gt 0) { return '{0:00}:{1:00}:{2:00}' -f $hours, $Span.Minutes, $Span.Seconds }
    return '{0:00}:{1:00}' -f $Span.Minutes, $Span.Seconds
}

function Receive-AiOutput {
    if ($script:AiRun.running -and $script:AiRun.titleBase) {
        $ui.RunTime.Text = Format-Elapsed ((Get-Date) - $script:AiRun.started)
    }
    foreach ($raw in $script:Runner.Drain()) {
        foreach ($text in @(ConvertFrom-AiLine $script:AiRun.target $raw)) { Add-RunLog $text }
    }
    if ($script:Runner.Finished) { Complete-AiRun }
}

# ---------------------------------------------------------------- first-run setup panel

$script:Setup = @{ busy = $false; waitingLogin = $false; deadline = $null }
$script:InstallCommands = @{
    claude = 'irm https://claude.ai/install.ps1 | iex'
    codex  = 'irm https://chatgpt.com/codex/install.ps1 | iex'
}

function Set-SetupRow([string]$Row, [bool]$Done, [string]$Text, [bool]$ShowButton) {
    $converter = New-Object Windows.Media.BrushConverter
    $ui[$Row + 'Mark'].Text = if ($Done) { [string][char]0x2714 } else { [string][char]0x25CB }
    $ui[$Row + 'Mark'].Foreground = $converter.ConvertFrom($(if ($Done) { '#4ADE80' } else { '#F2B54A' }))
    $ui[$Row + 'Text'].Text = $Text
}

# Shows the panel only while something the chosen AI run needs is missing.
function Update-SetupPanel {
    $target = Get-Target
    $label = $script:AiLabels[$target]
    $aeReady = [bool]$script:AfterFx
    Set-SetupRow 'SetupAe' $aeReady $(if ($aeReady) { L '{0} 연결됨' (Get-AeLabel $script:AfterFx) } else { L 'After Effects를 찾지 못했어요. 설치돼 있다면 AfterFX.exe를 골라 주세요.' }) $true
    $ui.SetupAe.Visibility = if ($aeReady) { 'Collapsed' } else { 'Visible' }
    $cliReady = [bool]$script:AiCli
    Set-SetupRow 'SetupCli' $cliReady $(if ($cliReady) { L '{0} 프로그램 설치됨' $label } else { L '{0} 프로그램(CLI)을 설치해요. 관리자 권한 없이 1~2분이면 끝나요.' $label }) $true
    $ui.SetupInstall.Visibility = if ($cliReady) { 'Collapsed' } else { 'Visible' }
    $loginReady = $cliReady -and ($script:AiLogin -ne $false)
    $loginText = if (-not $cliReady) { L '설치가 끝나면 로그인해요.' }
                 elseif ($loginReady) { L '{0} 로그인됨' $label }
                 elseif ($target -eq 'claude') { L 'Claude 계정으로 로그인해요. 브라우저가 열리면 로그인만 하면 돼요.' }
                 else { L 'ChatGPT 계정으로 로그인해요. 브라우저가 열리면 로그인만 하면 돼요.' }
    Set-SetupRow 'SetupLogin' $loginReady $loginText $true
    $ui.SetupLogin.Visibility = if ($cliReady -and -not $loginReady) { 'Visible' } else { 'Collapsed' }
    foreach ($button in 'SetupAe', 'SetupInstall', 'SetupLogin') { $ui[$button].IsEnabled = -not $script:Setup.busy }
    $ui.SetupPanel.Visibility = if ($aeReady -and $cliReady -and $loginReady -and -not $script:Setup.busy) { 'Collapsed' } else { 'Visible' }
}

function Set-SetupProgress([string]$Text) {
    $ui.SetupProgress.Text = $Text
    $ui.SetupProgress.Visibility = if ($Text) { 'Visible' } else { 'Collapsed' }
}

function Start-CliInstall {
    $target = Get-Target
    $label = $script:AiLabels[$target]
    $answer = [Windows.MessageBox]::Show((L "{0} 프로그램을 공식 설치 스크립트로 설치할게요.`n`n{1}`n`n이 Windows 사용자 계정에만 설치되고 관리자 권한은 필요 없어요." $label $script:InstallCommands[$target]), (L 'AE AutoSet · 설치'), 'OKCancel')
    if ([string]$answer -ne 'OK') { return }
    $environment = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    $environment['CODEX_NON_INTERACTIVE'] = '1'
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -Command "' + $script:InstallCommands[$target] + '"'
    $script:Setup.busy = $true; $script:Setup.target = $target; $script:Setup.lines = @()
    $script:SetupRunner = New-Object AEAutoSet.AiRunner
    try {
        $script:SetupRunner.Start($powershell, $arguments, $env:USERPROFILE, '', $environment, (Join-Path $script:RunsDir ('install-' + $target + '.log')))
    } catch { $script:Setup.busy = $false; Show-Message (L '설치를 시작하지 못했어요: {0}' $_.Exception.Message); Update-SetupPanel; return }
    Set-SetupProgress (L '{0} 설치 중…' $label)
    Update-SetupPanel
    $script:SetupTimer.Start()
}

function Start-CliLogin {
    $target = Get-Target
    if (-not $script:AiCli) { return }
    $arguments = if ($target -eq 'claude') { 'auth login' } else { 'login' }
    # A visible console: the CLI opens the browser and may show a code or a link there.
    try { Start-Process -FilePath $script:AiCli -ArgumentList $arguments -WorkingDirectory $env:USERPROFILE | Out-Null }
    catch { Show-Message (L '로그인 창을 열지 못했어요: {0}' $_.Exception.Message); return }
    $script:Setup.busy = $true; $script:Setup.waitingLogin = $true; $script:Setup.target = $target
    $script:Setup.deadline = (Get-Date).AddMinutes(10); $script:Setup.nextCheck = (Get-Date).AddSeconds(4)
    Set-SetupProgress (L '브라우저에서 로그인하세요. 끝나면 여기서 자동으로 확인해요. (검은 창이 열리면 안내를 따르세요)')
    Update-SetupPanel
    $script:SetupTimer.Start()
}

function Receive-SetupProgress {
    if ($script:Setup.waitingLogin) {
        if ((Get-Date) -lt $script:Setup.nextCheck) { return }
        $script:Setup.nextCheck = (Get-Date).AddSeconds(4)
        $script:AiLogin = Test-AiLogin $script:Setup.target $script:AiCli
        if ($script:AiLogin -eq $true -or (Get-Date) -gt $script:Setup.deadline) {
            $script:SetupTimer.Stop(); $script:Setup.busy = $false; $script:Setup.waitingLogin = $false
            Set-SetupProgress $(if ($script:AiLogin -eq $true) { L '로그인을 확인했어요.' } else { L '로그인을 확인하지 못했어요. 다시 로그인을 눌러 주세요.' })
            Update-AiStatus
        }
        return
    }
    foreach ($raw in $script:SetupRunner.Drain()) {
        $line = $raw.Substring(1).Trim()
        if ($line) { $script:Setup.lines += $line; Set-SetupProgress ((L '{0} 설치 중…' $script:AiLabels[$script:Setup.target]) + ' ' + $line) }
    }
    if ($script:SetupRunner.Finished) {
        $script:SetupTimer.Stop(); $script:Setup.busy = $false
        Update-AiStatus
        if ($script:AiCli) { Set-SetupProgress (L '설치가 끝났어요. 이제 로그인하세요.') }
        else {
            $tail = ($script:Setup.lines | Select-Object -Last 2) -join ' / '
            Set-SetupProgress ((L '설치를 끝내지 못했어요. 보안 프로그램이 막았을 수 있어요. ') + $tail)
        }
    }
}

$script:SetupTimer = New-Object Windows.Threading.DispatcherTimer
$script:SetupTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:SetupTimer.Add_Tick({ Receive-SetupProgress })
$ui.SetupInstall.Add_Click({ Start-CliInstall })
$ui.SetupLogin.Add_Click({ Start-CliLogin })
$ui.SetupAe.Add_Click({
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = 'After Effects (AfterFX.exe)|AfterFX.exe'
    if ($dialog.ShowDialog()) { $script:State.afterfx = $dialog.FileName; Save-State; Update-AeStatus; Update-SetupPanel }
})

$ui.RunWork.Add_Click({ Start-AiRun })
$ui.AiSetup.Add_Click({ Show-AiSetup })
$ui.StopRun.Add_Click({
    $answer = [Windows.MessageBox]::Show((L '작업을 중지할까요? 지금 처리 중인 컷은 끝까지 저장되지 않을 수 있어요.'), 'AE AutoSet', 'YesNo')
    if ([string]$answer -ne 'Yes') { return }
    $script:AiRun.stopped = $true
    $script:Runner.Stop()
})
$ui.OpenLog.Add_Click({ if ($script:AiRun.log -and (Test-Path -LiteralPath $script:AiRun.log)) { Start-Process notepad.exe -ArgumentList ('"' + $script:AiRun.log + '"') } })
$window.Add_Closing({ param($sender, $e)
    if ($script:AiRun.running) {
        $answer = [Windows.MessageBox]::Show((L '작업이 진행 중이에요. 창을 닫으면 작업도 중지돼요. 닫을까요?'), 'AE AutoSet', 'YesNo')
        if ([string]$answer -ne 'Yes') { $e.Cancel = $true; return }
        $script:AiRun.stopped = $true; $script:Runner.Stop()
    }
})
$ui.AeChip.Add_MouseLeftButtonUp({
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = 'After Effects (AfterFX.exe)|AfterFX.exe'
    if ($dialog.ShowDialog()) { $script:State.afterfx = $dialog.FileName; Save-State; Update-AeStatus }
})
function Edit-Work([string]$Id) {
    $pack = $script:Packs | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if ($pack) { Open-Register $pack }
}
function Remove-Work([string]$Id) {
    $answer = [Windows.MessageBox]::Show((L "{0} 작품을 목록에서 뺄까요?`n설정과 기초 AEP는 지우지 않고 projects\_removed 폴더에 보관해요." $Id), 'AE AutoSet', 'YesNo')
    if ($answer -ne 'Yes') { return }
    try {
        Invoke-Engine @('remove-pack', '--id', $Id) | Out-Null
        if ($script:State.last_work -eq $Id) { $script:State.last_work = '' }
        $script:SelectedWork = ''
        Load-Packs
        if ($script:ScanRoot) { Scan-Folder $script:ScanRoot }
    } catch { Show-Message $_.Exception.Message }
}
$window.Add_Closing({ Save-State })

# ---------------------------------------------------------------- register window

$registerXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="작품 등록" Width="700" Height="760" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" FontFamily="Segoe UI, Malgun Gothic" Background="#0E0E10" Foreground="#FAFAFA">
  <Grid x:Name="Root" Margin="28,22,28,20" Background="#0E0E10">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <StackPanel Grid.Row="0" Margin="0,0,0,14">
      <TextBlock x:Name="Heading" Text="새 작품 등록" FontSize="20" FontWeight="SemiBold"/>
      <TextBlock Text="기초 AEP를 읽어서 필요한 값을 미리 채워 둘게요. 맞는지 확인만 하면 돼요." Style="{StaticResource Hint}" Margin="0,4,0,0"/>
    </StackPanel>
    <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,16">
      <Border x:Name="Tab1" CornerRadius="10" Padding="14,5" Margin="0,0,6,0" Cursor="Hand" Background="Transparent"><TextBlock x:Name="TabText1" Text="1  기초 AEP" FontSize="12.5"/></Border>
      <Border x:Name="Tab2" CornerRadius="10" Padding="14,5" Margin="0,0,6,0" Cursor="Hand" Background="Transparent"><TextBlock x:Name="TabText2" Text="2  컴프 확인" FontSize="12.5"/></Border>
      <Border x:Name="Tab3" CornerRadius="10" Padding="14,5" Cursor="Hand" Background="Transparent"><TextBlock x:Name="TabText3" Text="3  이름 규칙" FontSize="12.5"/></Border>
    </StackPanel>

    <Border Grid.Row="2" Background="#161618" CornerRadius="10" BorderBrush="{StaticResource Line}" BorderThickness="1" Padding="20,18">
      <Grid>
        <StackPanel x:Name="Step1">
          <TextBlock Text="작품의 기초 AEP" Style="{StaticResource Label}"/>
          <DockPanel Margin="0,0,0,4">
            <Button x:Name="PickAep" DockPanel.Dock="Right" Content="파일 선택" Style="{StaticResource Base}" Margin="8,0,0,0"/>
            <TextBox x:Name="AepPath" IsReadOnly="True"/>
          </DockPanel>
          <TextBlock Text="000컷처럼 비어 있는 양식 AEP를 고르세요. 원본은 그대로 두고 복사본을 보관해요." Style="{StaticResource Hint}" Margin="0,0,0,18"/>
          <TextBlock Text="예시 컷 폴더 (권장)" Style="{StaticResource Label}"/>
          <DockPanel Margin="0,0,0,4">
            <Button x:Name="PickSample" DockPanel.Dock="Right" Content="폴더 선택" Style="{StaticResource Base}" Margin="8,0,0,0"/>
            <TextBox x:Name="SamplePath" IsReadOnly="True"/>
          </DockPanel>
          <TextBlock Text="실제 컷 폴더 하나를 고르면 컷 폴더 이름 규칙과 시트·LO 폴더 이름을 알아서 맞춰요." Style="{StaticResource Hint}" Margin="0,0,0,18"/>
          <Border Visibility="Collapsed" Background="#0E0E10" CornerRadius="8" Padding="14,12">
            <StackPanel>
              <CheckBox x:Name="CharacterFx" Content="캐릭터 FX 자동 적용" FontSize="13"/>
              <TextBlock Text="셀 색상으로 캐릭터를 찾으면 아래 폴더에서 그 캐릭터의 FX AEP를 가져와 적용해요." Style="{StaticResource Hint}" Margin="20,3,0,8"/>
              <DockPanel x:Name="FxRow" Margin="0,0,0,4">
                <Button x:Name="PickFx" DockPanel.Dock="Right" Content="폴더 선택" Style="{StaticResource Base}" Margin="8,0,0,0"/>
                <TextBox x:Name="FxFolder"/>
              </DockPanel>
              <TextBlock x:Name="FxHint" Text="FX 폴더 경로는 이 PC에만 저장돼요." Style="{StaticResource Hint}"/>
              <DockPanel Margin="0,8,0,0">
                <Button x:Name="OpenPackFolder" DockPanel.Dock="Right" Content="작품 폴더 열기" Style="{StaticResource Link}" Margin="12,0,0,0" VerticalAlignment="Center"/>
                <TextBlock x:Name="PaletteHint" Style="{StaticResource Hint}"/>
              </DockPanel>
            </StackPanel>
          </Border>
          <Border x:Name="AnalyzeBox" Visibility="Collapsed" Background="#2A1D07" CornerRadius="8" Padding="12,8" Margin="0,22,0,0">
            <TextBlock x:Name="AnalyzeText" Foreground="#F5B547" FontSize="12.5" TextWrapping="Wrap"/>
          </Border>
        </StackPanel>

        <ScrollViewer x:Name="Step2" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="170"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <TextBlock Grid.Row="0" Grid.ColumnSpan="2" x:Name="Step2Note" Style="{StaticResource Hint}" Margin="0,0,0,14"/>
            <TextBlock Grid.Row="1" Text="최상위 컴프" VerticalAlignment="Center"/>
            <ComboBox Grid.Row="1" Grid.Column="1" x:Name="MainComp" Margin="0,0,0,10"/>
            <TextBlock Grid.Row="2" Text="셀을 넣을 컴프" VerticalAlignment="Center"/>
            <ComboBox Grid.Row="2" Grid.Column="1" x:Name="CellComp" Margin="0,0,0,10"/>
            <TextBlock Grid.Row="3" Text="셀을 놓을 위치" VerticalAlignment="Center"/>
            <ComboBox Grid.Row="3" Grid.Column="1" x:Name="Anchor" Margin="0,0,0,10"/>
            <TextBlock Grid.Row="4" Text="LO를 넣을 컴프" VerticalAlignment="Center"/>
            <ComboBox Grid.Row="4" Grid.Column="1" x:Name="LoComp" Margin="0,0,0,10"/>
            <TextBlock Grid.Row="5" Text="카메라" VerticalAlignment="Center"/>
            <ComboBox Grid.Row="5" Grid.Column="1" x:Name="Camera" Margin="0,0,0,18"/>
            <TextBlock Grid.Row="6" Grid.ColumnSpan="2" Text="프로젝트 패널 폴더 (없으면 새로 만들어요)" Style="{StaticResource Label}"/>
            <TextBlock Grid.Row="7" Text="셀 소스 폴더" VerticalAlignment="Center"/>
            <ComboBox Grid.Row="7" Grid.Column="1" x:Name="FolderCel" IsEditable="True" Margin="0,0,0,10"/>
            <TextBlock Grid.Row="8" Text="셀 컴프 폴더" VerticalAlignment="Center"/>
            <ComboBox Grid.Row="8" Grid.Column="1" x:Name="FolderCelComp" IsEditable="True" Margin="0,0,0,10"/>
            <TextBlock Grid.Row="9" Text="LO 폴더" VerticalAlignment="Center"/>
            <ComboBox Grid.Row="9" Grid.Column="1" x:Name="FolderLo" IsEditable="True"/>
          </Grid>
        </ScrollViewer>

        <ScrollViewer x:Name="Step3" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="170"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <TextBlock Grid.Row="0" Text="작품 코드" VerticalAlignment="Center"/>
            <TextBox Grid.Row="0" Grid.Column="1" x:Name="PackId" Margin="0,0,0,10" ToolTip="영문·숫자 (예: XYZ)"/>
            <TextBlock Grid.Row="1" Text="작품 이름" VerticalAlignment="Center"/>
            <TextBox Grid.Row="1" Grid.Column="1" x:Name="PackName" Margin="0,0,0,16" ToolTip="카드에 보일 이름"/>
            <TextBlock Grid.Row="2" Text="컷 폴더 이름 규칙" VerticalAlignment="Top" Margin="0,7,0,0"/>
            <StackPanel Grid.Row="2" Grid.Column="1" Margin="0,0,0,12">
              <TextBox x:Name="Pattern"/>
              <TextBlock x:Name="PatternCheck" Style="{StaticResource Hint}" Margin="0,4,0,0"/>
            </StackPanel>
            <TextBlock Grid.Row="3" Text="저장할 AEP 이름" VerticalAlignment="Top" Margin="0,7,0,0"/>
            <StackPanel Grid.Row="3" Grid.Column="1" Margin="0,0,0,12">
              <TextBox x:Name="OutputAep"/>
              <TextBlock x:Name="OutputPreview" Style="{StaticResource Hint}" Margin="0,4,0,0"/>
            </StackPanel>
            <TextBlock Grid.Row="4" Text="최상위 컴프 새 이름" VerticalAlignment="Top" Margin="0,7,0,0"/>
            <StackPanel Grid.Row="4" Grid.Column="1" Margin="0,0,0,16">
              <TextBox x:Name="MainOut"/>
              <TextBlock x:Name="MainPreview" Style="{StaticResource Hint}" Margin="0,4,0,0"/>
            </StackPanel>
            <TextBlock Grid.Row="5" Text="시트 폴더 이름" VerticalAlignment="Center"/>
            <TextBox Grid.Row="5" Grid.Column="1" x:Name="SheetFolders" Margin="0,0,0,10" ToolTip="여러 개는 , 또는 / 로 구분. *는 아무 글자 (예: *sheet*, _sheet)"/>
            <TextBlock Grid.Row="6" Text="LO 폴더 이름" VerticalAlignment="Center"/>
            <TextBox Grid.Row="6" Grid.Column="1" x:Name="LoFolders" Margin="0,0,0,16" ToolTip="여러 개는 , 또는 / 로 구분 (예: LO / _lo)"/>
            <TextBlock Grid.Row="8" Grid.ColumnSpan="2" Text="{}{scene} = 컷 폴더 이름 그대로, {ep2} = 화수 2자리, {cut3} = 컷 번호 3자리&#x0a;폴더 이름: 여러 개는 , 또는 / 로 구분하고, *는 아무 글자예요 (*sheet* = 이름에 sheet가 들어간 폴더 전부)." Style="{StaticResource Hint}" Margin="0,10,0,0"/>
          </Grid>
        </ScrollViewer>
      </Grid>
    </Border>

    <DockPanel Grid.Row="3" Margin="0,16,0,0">
      <Button x:Name="Cancel" Content="취소" Style="{StaticResource Base}"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="Next" Content="저장" Style="{StaticResource Primary}" Height="34"/>
      </StackPanel>
    </DockPanel>
  </Grid>
</Window>
'@

$script:TopLabel = (L '(맨 위에 놓기)')
$script:NoCamera = (L '카메라 없음 (카메라 이동은 작업자가 처리)')

function Convert-PatternToRegex([string]$Pattern) {
    $cut = [regex]::Matches($Pattern, '\{cut(\d*)\}')
    if ($cut.Count -ne 1) { return $null }
    $escaped = [regex]::Escape($Pattern)
    $regex = [regex]::Replace($escaped, '\\\{(cut|ep)(\d*)\}', {
        param($m)
        $group = $m.Groups[1].Value; $digits = $m.Groups[2].Value
        if ($digits) { "(?<$group>\d{$digits})" } else { "(?<$group>\d+)" }
    })
    if ($Pattern.EndsWith($cut[0].Value)) { $regex += '[A-Za-z]*(?:_kari)?' }
    return '^' + $regex + '$'
}
function Render-Name([string]$Template, [string]$Scene, $Match) {
    $text = $Template.Replace('{scene}', $Scene)
    foreach ($token in 'cut', 'ep') {
        if ($Match.Groups[$token].Success) {
            $number = [int]$Match.Groups[$token].Value
            $text = [regex]::Replace($text, '\{' + $token + '(\d*)\}', { param($m) if ($m.Groups[1].Value) { $number.ToString('D' + $m.Groups[1].Value) } else { [string]$number } })
        }
    }
    return $text
}
function Split-Names([string]$Text) { @($Text -split '[,;/]' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
$script:DefaultSheetFolders = '*sheet*'

function Reg-Brush([string]$Hex) { (New-Object Windows.Media.BrushConverter).ConvertFrom($Hex) }

function Reg-ShowStep([int]$Number) {
    $r = $script:Reg.r
    $script:Reg.step = $Number
    # Tabs move freely; only the open tab is highlighted.
    foreach ($i in 1, 2, 3) {
        $r["Step$i"].Visibility = if ($i -eq $Number) { 'Visible' } else { 'Collapsed' }
        $r["Tab$i"].Background = if ($i -eq $Number) { Reg-Brush '#2A1D07' } else { Reg-Brush '#1C1C1F' }
        $r["TabText$i"].Foreground = if ($i -eq $Number) { Reg-Brush '#F5B547' } else { Reg-Brush '#A1A1A8' }
        $r["TabText$i"].FontWeight = if ($i -eq $Number) { 'SemiBold' } else { 'Normal' }
    }
    if ($Number -eq 3) { Reg-UpdatePreview }
}

function Reg-FillCombo($Combo, $Items, $Selected) {
    $Combo.Items.Clear()
    foreach ($item in @($Items)) { if ($item) { [void]$Combo.Items.Add([string]$item) } }
    if ($Selected -and -not $Combo.Items.Contains([string]$Selected)) { [void]$Combo.Items.Add([string]$Selected) }
    if ($Selected) { $Combo.SelectedItem = [string]$Selected; if ($Combo.IsEditable) { $Combo.Text = [string]$Selected } }
    elseif ($Combo.Items.Count) { $Combo.SelectedIndex = 0 }
}

function Reg-RefreshAnchors {
    $r = $script:Reg.r
    $comp = @($script:Reg.suggestion.aep.comps | Where-Object { $_.name -eq [string]$r.CellComp.SelectedItem }) | Select-Object -First 1
    $layers = @($script:TopLabel)
    foreach ($layer in @($comp.layers)) {
        if ($layer.name -and $layer.kind -ne 'camera' -and ([string]$layer.name).IndexOf([char]0xFFFD) -lt 0) { $layers += (L '{0} 바로 위' ([string]$layer.name)) }
    }
    $current = if ($script:Reg.anchor) { L '{0} 바로 위' $script:Reg.anchor } else { $script:TopLabel }
    Reg-FillCombo $r.Anchor $layers $current
}

function Reg-ApplyPack($Pack) {
    $r = $script:Reg.r
    $suggestion = $script:Reg.suggestion
    $comps = @($suggestion.aep.comps | Where-Object { -not $_.library } | ForEach-Object { [string]$_.name })
    $folders = @($suggestion.aep.folders | ForEach-Object { ([string]$_ -split '/')[-1] } | Sort-Object -Unique)
    Reg-FillCombo $r.MainComp $comps $Pack.comps.main
    Reg-FillCombo $r.CellComp $comps $Pack.comps.cell
    Reg-FillCombo $r.LoComp $comps $(if ($Pack.comps.lo) { $Pack.comps.lo } else { $Pack.comps.cell })
    $anchors = @($Pack.cell_anchor_layers | Where-Object { $_ })
    $script:Reg.anchor = if ($anchors.Count) { [string]$anchors[0] } else { '' }
    # Keep fallback anchors (e.g. DEMO: BG_blur, Camera Lens Blur, BL) while the first choice is unchanged.
    $script:Reg.anchorList = @($anchors | ForEach-Object { [string]$_ })
    Reg-RefreshAnchors
    $items = @($script:NoCamera); $selected = $script:NoCamera
    $script:Reg.cameras = @{}
    foreach ($camera in @($suggestion.pack.camera, $Pack.camera)) {
        if ($camera -and $camera.layer) {
            $label = (L "'{0}' 레이어 → {1} (역방향 카메라)" $camera.layer $camera.output_comp)
            if ($items -notcontains $label) { $items += $label; $script:Reg.cameras[$label] = $camera }
            if ($Pack.camera -and $camera.layer -eq $Pack.camera.layer) { $selected = $label }
        }
    }
    Reg-FillCombo $r.Camera $items $selected
    Reg-FillCombo $r.FolderCel $folders $Pack.project_folders.cell_footage
    Reg-FillCombo $r.FolderCelComp $folders $Pack.project_folders.cell_comp
    Reg-FillCombo $r.FolderLo $folders $Pack.project_folders.lo
    $r.PackId.Text = [string]$Pack.id
    $r.PackName.Text = [string]$Pack.name
    $r.Pattern.Text = [string]$Pack.scene_pattern
    $r.OutputAep.Text = [string]$Pack.output.aep
    $r.MainOut.Text = [string]$Pack.output.main_comp
    # Never show an empty box: the default rule is written out as *sheet*.
    $sheetText = (@($Pack.scene_folders.sheet) | Where-Object { $_ }) -join ', '
    $r.SheetFolders.Text = if ($sheetText) { $sheetText } else { $script:DefaultSheetFolders }
    $loText = (@($Pack.scene_folders.lo) | Where-Object { $_ }) -join ', '
    $r.LoFolders.Text = if ($loText) { $loText } else { 'LO' }
    if (-not $script:Reg.fxTouched) { $r.CharacterFx.IsChecked = [bool]$Pack.modules.character_fx }
    Reg-UpdateFx
    $count = @($suggestion.aep.comps | Where-Object { -not $_.library }).Count
    $r.Step2Note.Text = (L '{0}에서 컴프 {1}개를 읽었어요. 자동으로 고른 값이 맞는지 확인하세요.' $suggestion.aep.file $count)
}

function Reg-Analyze {
    $r = $script:Reg.r
    $aep = $r.AepPath.Text; $sample = $r.SamplePath.Text
    if (-not $aep) { Show-Message (L '기초 AEP를 먼저 고르세요.'); return $false }
    $key = $aep + '|' + $sample
    if ($script:Reg.analyzedKey -eq $key) { return $true }
    $script:Reg.dialog.Cursor = 'Wait'
    try {
        $arguments = @('inspect-template', '--aep', $aep)
        if ($sample) { $arguments += @('--sample-scene', $sample) }
        $script:Reg.suggestion = Invoke-Engine $arguments
        $script:Reg.analyzedKey = $key
        # Editing keeps the saved choices; the AEP read only refreshes the lists.
        $pack = if ($script:Reg.existingSpec) { $script:Reg.existingSpec } else { $script:Reg.suggestion.pack }
        Reg-ApplyPack $pack
        $notes = @()
        if ($script:Reg.suggestion.pack.camera) { $notes += (L "카메라 리그 '{0}'를 찾았어요." $script:Reg.suggestion.pack.camera.layer) }
        foreach ($warning in @($script:Reg.suggestion.aep.warnings)) { if ($warning) { $notes += [string]$warning.message } }
        $r.AnalyzeText.Text = (L '분석 완료 · 컴프와 폴더를 읽었어요.') + ' ' + ($notes -join ' ')
        $r.AnalyzeBox.Visibility = 'Visible'
        return $true
    } catch { Show-Message $_.Exception.Message; return $false } finally { $script:Reg.dialog.Cursor = $null }
}

function Reg-UpdatePreview {
    $r = $script:Reg.r
    $sample = if ($r.SamplePath.Text) { Split-Path $r.SamplePath.Text -Leaf } else { '' }
    $regex = Convert-PatternToRegex $r.Pattern.Text
    if (-not $regex) {
        $r.PatternCheck.Text = (L '{cut3}처럼 컷 번호 자리를 한 번 넣어야 해요.'); $r.PatternCheck.Foreground = Reg-Brush '#F87171'; return
    }
    if (-not $sample) {
        $r.PatternCheck.Text = (L '예시 컷 폴더가 없어서 미리보기를 건너뛰었어요.'); $r.PatternCheck.Foreground = Reg-Brush '#A1A1A8'
        $r.OutputPreview.Text = ''; $r.MainPreview.Text = ''; return
    }
    $match = [regex]::Match($sample, $regex, 'IgnoreCase')
    if ($match.Success) {
                $cutNumber = [string][int]$match.Groups['cut'].Value
            $r.PatternCheck.Text = if ($match.Groups['ep'].Success) { L '{0} → {1}화 {2}컷으로 인식' $sample ([string][int]$match.Groups['ep'].Value) $cutNumber } else { L '{0} → {1}컷으로 인식' $sample $cutNumber }
        $r.PatternCheck.Foreground = Reg-Brush '#4ADE80'
        $r.OutputPreview.Text = (L '예: {0}' (Render-Name $r.OutputAep.Text $sample $match))
        $r.MainPreview.Text = (L '예: {0}' (Render-Name $r.MainOut.Text $sample $match))
    } else {
        $r.PatternCheck.Text = (L '{0} 폴더가 이 규칙과 맞지 않아요.' $sample); $r.PatternCheck.Foreground = Reg-Brush '#F87171'
        $r.OutputPreview.Text = ''; $r.MainPreview.Text = ''
    }
}

function Reg-BuildSpec {
    $r = $script:Reg.r
    $anchorText = [string]$r.Anchor.SelectedItem
    $abovePattern = '^' + ([regex]::Escape((L '{0} 바로 위')) -replace '\\\{0\}', '(.+)') + '$'
    $anchors = @(if ($anchorText -and $anchorText -ne $script:TopLabel) { $m = [regex]::Match($anchorText, $abovePattern); if ($m.Success) { $m.Groups[1].Value } else { $anchorText } })
    $known = @($script:Reg.anchorList)
    if ($anchors.Count -and $known.Count -gt 1 -and $known[0] -eq $anchors[0]) { $anchors = $known }
    $cameraLabel = [string]$r.Camera.SelectedItem
    $camera = if ($cameraLabel -and $cameraLabel -ne $script:NoCamera) { $script:Reg.cameras[$cameraLabel] } else { $null }
    $sheets = @(Split-Names $r.SheetFolders.Text)
    $los = @(Split-Names $r.LoFolders.Text)
    $sheetValue = [object[]]@($script:DefaultSheetFolders); if ($sheets.Count) { $sheetValue = [object[]]$sheets }
    $loValue = [object[]]@('LO'); if ($los.Count) { $loValue = [object[]]$los }
    $id = $r.PackId.Text.Trim()
    return [ordered]@{
        pack_version = 2; id = $id; name = $(if ($r.PackName.Text.Trim()) { $r.PackName.Text.Trim() } else { $id })
        template = [IO.Path]::GetFileName($r.AepPath.Text); scene_pattern = $r.Pattern.Text.Trim()
        output = [ordered]@{ aep = $r.OutputAep.Text.Trim(); ardj = '{scene}.ardj'; main_comp = $r.MainOut.Text.Trim() }
        comps = [ordered]@{ main = [string]$r.MainComp.SelectedItem; cell = [string]$r.CellComp.SelectedItem; lo = [string]$r.LoComp.SelectedItem }
        camera = $(if ($camera) { [ordered]@{ layer = [string]$camera.layer; comp = [string]$camera.comp; output_comp = [string]$camera.output_comp } } else { $null })
        project_folders = [ordered]@{ cell_footage = $r.FolderCel.Text.Trim(); cell_comp = $r.FolderCelComp.Text.Trim(); lo = $r.FolderLo.Text.Trim() }
        cell_anchor_layers = $anchors
        scene_folders = [ordered]@{ sheet = $sheetValue; lo = $loValue }
        fps = 24
        modules = [ordered]@{ character_fx = [bool]$r.CharacterFx.IsChecked }
    }
}

function Reg-UpdateFx {
    $r = $script:Reg.r
    $on = [bool]$r.CharacterFx.IsChecked
    $r.FxRow.IsEnabled = $on
    $r.FxRow.Opacity = if ($on) { 1 } else { 0.5 }
    $folder = ConvertTo-FolderPath $r.FxFolder.Text
    if ($on -and $folder -and -not (Test-Path -LiteralPath $folder -PathType Container)) {
        $r.FxHint.Text = (L '폴더를 찾을 수 없어요: {0}' $folder); $r.FxHint.Foreground = Reg-Brush '#F87171'
    } elseif ($on -and -not $folder) {
        $r.FxHint.Text = (L 'FX 폴더 경로는 이 PC에만 저장돼요.'); $r.FxHint.Foreground = Reg-Brush '#A1A1A8'
    } else {
        $r.FxHint.Text = (L 'FX 폴더 경로는 이 PC에만 저장돼요.'); $r.FxHint.Foreground = Reg-Brush '#A1A1A8'
    }
    # The character palette sits in the work's own folder: projects\<code>\<code>_character_palette.json
    $pack = $script:Reg.existing
    $r.OpenPackFolder.Visibility = if ($pack) { 'Visible' } else { 'Collapsed' }
    if ($pack -and $pack.palette) {
        $r.PaletteHint.Text = (L '캐릭터 팔레트: {0}명 등록됨 ({1}_character_palette.json)' $pack.palette $pack.id)
        $r.PaletteHint.Foreground = Reg-Brush '#4ADE80'
    } elseif ($pack) {
        $r.PaletteHint.Text = (L '작품 폴더에 캐릭터 팔레트({0}_character_palette.json)가 없어요. 넣어야 캐릭터를 판별해요.' $pack.id)
        $r.PaletteHint.Foreground = Reg-Brush $(if ($on) { '#F2B54A' } else { '#A1A1A8' })
    } else {
        $code = if ($r.PackId.Text.Trim()) { $r.PackId.Text.Trim() } else { L '작품코드' }
        $r.PaletteHint.Text = (L '저장한 뒤 작품 폴더에 {0}_character_palette.json을 넣으면 캐릭터를 판별해요.' $code)
        $r.PaletteHint.Foreground = Reg-Brush '#A1A1A8'
    }
}

function Reg-OpenTab([int]$Number) {
    # Tabs 2 and 3 need the AEP read first; reading again only happens when the inputs changed.
    if ($Number -gt 1 -and -not (Reg-Analyze)) { return }
    Reg-ShowStep $Number
}

function Reg-Save {
    $r = $script:Reg.r
    if (-not (Reg-Analyze)) { return }
    $spec = Reg-BuildSpec
    if ($spec.id -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$') { Show-Message (L '작품 코드는 영문·숫자로 입력하세요 (예: XYZ).'); return }
    if (-not (Convert-PatternToRegex $spec.scene_pattern)) { Show-Message (L '컷 폴더 이름 규칙에 {cut3}처럼 컷 번호 자리를 넣어 주세요.'); return }
    $fxFolder = (ConvertTo-FolderPath $r.FxFolder.Text)
    if ($r.CharacterFx.IsChecked -and $fxFolder -and -not (Test-Path -LiteralPath $fxFolder -PathType Container)) {
        Reg-ShowStep 1; Show-Message (L '캐릭터 FX 폴더를 찾을 수 없어요: {0}' $fxFolder); return
    }
    $json = $spec | ConvertTo-Json -Depth 8
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('ae-autoset-pack-' + [guid]::NewGuid() + '.json')
    [IO.File]::WriteAllText($temp, $json, (New-Object Text.UTF8Encoding($false)))
    try {
        $arguments = @('register-pack', '--spec', $temp, '--aep', $r.AepPath.Text)
        $existing = $script:Reg.existing
        $replace = $existing -and ($existing.id -eq $spec.id)
        if (-not $replace -and ($script:Packs | Where-Object { $_.id -eq $spec.id })) {
            if ($SelfTest) { $answer = 'Yes' } else { $answer = [Windows.MessageBox]::Show((L '{0} 작품이 이미 있어요. 덮어쓸까요? 이전 설정은 보관돼요.' $spec.id), 'AE AutoSet', 'YesNo') }
            if ([string]$answer -ne 'Yes') { return }
            $replace = $true
        }
        if ($replace) { $arguments += '--replace' }
        if ($SelfTest) { Write-Host ('[register] ' + $json); Write-Host ('[fx folder] ' + $fxFolder); $script:Reg.spec = $json; $script:Reg.saved = $true; return }
        Invoke-Engine $arguments | Out-Null
        # The FX folder differs per PC, so it lives in this PC's settings, not in the shared work pack.
        if ($fxFolder) { $script:State.character_fx_folders[$spec.id] = $fxFolder } else { $script:State.character_fx_folders.Remove($spec.id) }
        Save-State
        $script:Reg.saved = $true
        $script:State.last_work = $spec.id
        $script:Reg.dialog.Close()
    } catch { Show-Message $_.Exception.Message } finally { Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue }
}

function Open-Register($ExistingPack) {
    $dialog = New-Xaml $registerXaml
    if (-not $SelfTest) { $dialog.Owner = $window }
    $r = @{}
    foreach ($name in 'Root','Heading','Tab1','Tab2','Tab3','TabText1','TabText2','TabText3','Step1','Step2','Step3','PickAep','AepPath','PickSample','SamplePath',
                      'AnalyzeBox','AnalyzeText','Step2Note','MainComp','CellComp','Anchor','LoComp','Camera','FolderCel','FolderCelComp','FolderLo',
                      'PackId','PackName','Pattern','PatternCheck','OutputAep','OutputPreview','MainOut','MainPreview','SheetFolders','LoFolders',
                      'CharacterFx','FxRow','PickFx','FxFolder','FxHint','PaletteHint','OpenPackFolder','Cancel','Next') { $r[$name] = Find $dialog $name }
    $script:Reg = @{ r = $r; dialog = $dialog; step = 1; suggestion = $null; analyzedKey = ''; existing = $ExistingPack;
                     existingSpec = $null; saved = $false; anchor = ''; cameras = @{} }

    foreach ($box in 'Pattern', 'OutputAep', 'MainOut') { $r[$box].Add_TextChanged({ Reg-UpdatePreview }) }
    $r.CellComp.Add_SelectionChanged({ if ($script:Reg.suggestion) { $script:Reg.anchor = ''; Reg-RefreshAnchors } })
    $r.PickAep.Add_Click({
        $picker = New-Object Microsoft.Win32.OpenFileDialog
        $picker.Filter = (L 'After Effects 프로젝트') + ' (*.aep)|*.aep'
        if ($picker.ShowDialog()) { $script:Reg.r.AepPath.Text = $picker.FileName; $script:Reg.r.AnalyzeBox.Visibility = 'Collapsed' }
    })
    $r.PickSample.Add_Click({
        $picker = New-Object System.Windows.Forms.FolderBrowserDialog
        $picker.Description = (L '이 작품의 컷 폴더 하나를 고르세요 (예: XYZ_03_214)')
        if ($picker.ShowDialog() -eq 'OK') { $script:Reg.r.SamplePath.Text = $picker.SelectedPath; $script:Reg.r.AnalyzeBox.Visibility = 'Collapsed' }
    })
    $r.Cancel.Add_Click({ $script:Reg.dialog.Close() })
    $r.Next.Add_Click({ Reg-Save })
    foreach ($i in 1, 2, 3) {
        $r["Tab$i"].Tag = $i
        $r["Tab$i"].Add_MouseLeftButtonUp({ param($sender, $e) Reg-OpenTab ([int]$sender.Tag) })
        $r["Tab$i"].Add_MouseEnter({ param($sender, $e) if ($script:Reg.step -ne [int]$sender.Tag) { $sender.Background = Reg-Brush '#26262A' } })
        $r["Tab$i"].Add_MouseLeave({ param($sender, $e) if ($script:Reg.step -ne [int]$sender.Tag) { $sender.Background = Reg-Brush '#1C1C1F' } })
    }

    $r.CharacterFx.Add_Click({ $script:Reg.fxTouched = $true; Reg-UpdateFx })
    $r.OpenPackFolder.Add_Click({ if ($script:Reg.existing -and (Test-Path -LiteralPath $script:Reg.existing.path)) { Start-Process explorer.exe -ArgumentList ('"' + $script:Reg.existing.path + '"') } })
    $r.FxFolder.Add_TextChanged({ if ($script:Reg.r.FxFolder.Text -and -not $script:Reg.r.CharacterFx.IsChecked) { $script:Reg.r.CharacterFx.IsChecked = $true; $script:Reg.fxTouched = $true }; Reg-UpdateFx })
    $r.PickFx.Add_Click({
        $picker = New-Object System.Windows.Forms.FolderBrowserDialog
        $picker.Description = (L '캐릭터별 FX AEP가 들어 있는 폴더를 고르세요')
        if ($script:Reg.r.FxFolder.Text -and (Test-Path -LiteralPath $script:Reg.r.FxFolder.Text)) { $picker.SelectedPath = $script:Reg.r.FxFolder.Text }
        if ($picker.ShowDialog() -eq 'OK') { $script:Reg.r.FxFolder.Text = $picker.SelectedPath }
    })
    if ($ExistingPack) {
        if ($script:State.character_fx_folders.Contains([string]$ExistingPack.id)) { $r.FxFolder.Text = [string]$script:State.character_fx_folders[[string]$ExistingPack.id] }
        $r.CharacterFx.IsChecked = [bool]$ExistingPack.character_fx
        $script:Reg.fxTouched = $true
        $r.Heading.Text = (L '작품 설정 수정 · {0}' $ExistingPack.id)
        $r.AepPath.Text = [string]$ExistingPack.template_path
        try { $script:Reg.existingSpec = Get-Content -LiteralPath (Join-Path $ExistingPack.path 'project.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    }
    Reg-ShowStep 1
    Reg-UpdateFx
    if ($SelfTest) { return }
    [void]$dialog.ShowDialog()
    if ($script:Reg.saved) { Load-Packs; if ($script:ScanRoot) { Scan-Folder $script:ScanRoot } }
}

# ---------------------------------------------------------------- start

Add-Type -AssemblyName System.Windows.Forms
function Save-Preview($Element, [string]$File, [int]$Width, [int]$Height) {
    $Element.Measure((New-Object Windows.Size($Width, $Height)))
    $Element.Arrange((New-Object Windows.Rect(0, 0, $Width, $Height)))
    $Element.UpdateLayout()
    # AE_AUTOSET_PREVIEW_SCALE=2 renders sharp images for the README.
    $scale = if ($env:AE_AUTOSET_PREVIEW_SCALE) { [double]$env:AE_AUTOSET_PREVIEW_SCALE } else { 1 }
    $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap([int]($Width * $scale), [int]($Height * $scale), (96 * $scale), (96 * $scale), [Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($Element)
    $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.File]::Create($File); try { $encoder.Save($stream) } finally { $stream.Close() }
}

Update-AeStatus
if ($script:State.target -eq 'claude') { $ui.TargetClaude.IsChecked = $true } else { $ui.TargetCodex.IsChecked = $true }
try { Fill-AiChoices } catch {}
Load-Packs
Update-Count
try { Update-AiStatus } catch { $ui.AiStatus.Text = '' }

if ($SelfTest) {
    if ($ShortcutFolders) {
        $made = @(Update-Shortcuts $true)
        if ($made.Count -ne @($ShortcutFolders | ForEach-Object { $_ -split ',' } | Where-Object { $_ }).Count) { throw 'Shortcuts were not created' }
        $link = (New-Object -ComObject WScript.Shell).CreateShortcut($made[0])
        if ($link.Arguments -notlike '*AE-AutoSet.ps1*' -or $link.IconLocation -notlike '*AE-AutoSet.ico*') { throw 'Shortcut target/icon is wrong' }
        if (@(Update-Shortcuts $false).Count) { throw 'An up-to-date shortcut must not be rewritten' }
        Remove-Item -LiteralPath $made[0]
        if (@(Update-Shortcuts $false).Count -or (Test-Path -LiteralPath $made[0])) { throw 'A deleted shortcut must not come back by itself' }
        Write-Output ('[shortcuts] ' + ($made -join ' | '))
    }
    $sample = Join-Path $script:SkillRoot 'SKILL.md'
    if ((ConvertTo-FolderPath ('"' + $script:SkillRoot + '"  ')) -ne $script:SkillRoot) { throw 'Quoted path was not accepted' }
    if ((ConvertTo-FolderPath $sample) -ne $script:SkillRoot) { throw 'A file path must resolve to its folder' }
    Scan-Folder 'Z:\does-not-exist'
    if ($ui.FolderHint.Text -ne (L '폴더를 찾을 수 없어요: {0}' 'Z:\does-not-exist')) { throw 'Missing folder must be reported inline' }
    if ($PreviewRoot) { Scan-Folder ('"' + $PreviewRoot + '"') }
    foreach ($card in @($ui.WorkPanel.Children | Where-Object { $_ -is [Windows.Controls.RadioButton] })) {
        $menu = $card.Content.Children[0].ContextMenu
        if (@($menu.Items | ForEach-Object { $_.Header }) -join '/' -ne ((L '설정 수정') + '/' + (L '삭제'))) { throw 'Work card menu is missing' }
    }
    # Language switch in the open window: no Korean left (work names aside), and Korean comes back unchanged.
    function Get-UiTexts($Node, [System.Collections.Generic.List[string]]$Found) {
        if ($Node -isnot [Windows.DependencyObject] -or $Node -is [Windows.Documents.Run] -or $Node -eq $ui.WorkPanel -or $Node -eq $ui.UiLanguage) { return }
        foreach ($name in 'Text', 'Content', 'ToolTip', 'Header', 'Title') {
            if ($Node -is [Windows.Controls.TextBox] -and $name -eq 'Text') { continue }
            $value = $Node.$name
            if ($value -is [string] -and $value) { $Found.Add($Node.GetType().Name + '.' + $name + '=' + $value) }
        }
        if ($Node -is [Windows.Controls.ListView] -and $Node.View -is [Windows.Controls.GridView]) { foreach ($column in $Node.View.Columns) { $Found.Add('Column=' + $column.Header) } }
        foreach ($child in @([Windows.LogicalTreeHelper]::GetChildren($Node))) { Get-UiTexts $child $Found }
    }
    $koreanTexts = New-Object 'System.Collections.Generic.List[string]'; Get-UiTexts $window $koreanTexts
    foreach ($code in 'ja', 'en', 'zh') {
        $ui.UiLanguage.SelectedItem = @($ui.UiLanguage.Items | Where-Object { $_.Tag -eq $code })[0]
        if ($script:Lang -ne $code) { throw "Language did not switch to $code" }
        $texts = New-Object 'System.Collections.Generic.List[string]'; Get-UiTexts $window $texts
        $left = @($texts | Where-Object { $_ -match '[가-힣]' })
        if ($left.Count) { throw ("Korean left after switching to ${code}: " + ($left -join ' | ')) }
        if ($window.FontFamily.Source -ne $script:LangFonts[$code]) { throw "Window font did not follow $code" }
        $firstRow = @($script:Rows)[0]
        Write-Output ("[language $code] " + $ui.RunWork.Content + ' | ' + $ui.AeStatus.Text + $(if ($firstRow) { ' | ' + $firstRow.Badge + ' / ' + $firstRow.Reason } else { '' }))
        if ($PreviewDirectory -and $code -eq 'ja') { New-Item -ItemType Directory -Path $PreviewDirectory -Force | Out-Null; Save-Preview $ui.Root (Join-Path $PreviewDirectory 'main-ja.png') 1060 780 }
    }
    $ui.UiLanguage.SelectedItem = @($ui.UiLanguage.Items | Where-Object { $_.Tag -eq 'ko' })[0]
    $restored = New-Object 'System.Collections.Generic.List[string]'; Get-UiTexts $window $restored
    $changed = @(Compare-Object @($koreanTexts) @($restored) | ForEach-Object { $_.SideIndicator + ' ' + $_.InputObject })
    if ($changed.Count) { throw ('Korean text changed after switching back: ' + ($changed -join ' | ')) }
    if ($env:AE_AUTOSET_TEST_PICK) {
        # "<model index>,<effort index>" picks entries in the model / reasoning lists.
        $picks = $env:AE_AUTOSET_TEST_PICK -split ','
        $ui.AiModel.SelectedIndex = [int]$picks[0]; $ui.AiEffort.SelectedIndex = [int]$picks[1]
        Write-Output ('[ai pick] ' + $ui.AiStatus.Text + ' | ' + (($ui.AiEffort.Items | ForEach-Object { $_.Content }) -join '/'))
    }
    if ($env:AE_AUTOSET_TEST_REWORK) {
        $ui.Rework.IsChecked = $true; Set-Rows
        foreach ($row in $script:Rows) { $row.IsChecked = ($env:AE_AUTOSET_TEST_REWORK -eq '*' -or $row.Name -eq $env:AE_AUTOSET_TEST_REWORK) -and $row.Selectable }
        Write-Output ('[rework rows] ' + (($script:Rows | ForEach-Object { $_.Name + ':' + $_.Status + ':' + $_.Selectable }) -join ' '))
    }
    $request = Build-Request
    Write-Output ('[request] ' + $request)
    if ($env:AE_AUTOSET_TEST_RUN -and $request) {
        if ($env:AE_AUTOSET_TEST_RUN -eq 'claude') { $ui.TargetClaude.IsChecked = $true } else { $ui.TargetCodex.IsChecked = $true }
        Start-AiRun
        $deadline = (Get-Date).AddSeconds(60)
        while ($script:AiRun.running -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200; Receive-AiOutput }
        Write-Output ('[run title] ' + $ui.RunTitle.Text + ' | ' + $ui.RunTime.Text)
        Write-Output ('[run log] ' + ($ui.RunLog.Text -replace "`r`n", ' | '))
        Write-Output ('[run args] ' + $script:LastCommand.arguments)
        if ($PreviewDirectory) { New-Item -ItemType Directory -Path $PreviewDirectory -Force | Out-Null; Save-Preview $ui.Root (Join-Path $PreviewDirectory 'run.png') 1060 900 }
    }
    if ($PreviewDirectory) {
        New-Item -ItemType Directory -Path $PreviewDirectory -Force | Out-Null
        # AE_AUTOSET_PREVIEW_LANG renders the screenshots in that language, without the copy banner.
        if ($env:AE_AUTOSET_PREVIEW_LANG) { $ui.UiLanguage.SelectedItem = @($ui.UiLanguage.Items | Where-Object { $_.Tag -eq $env:AE_AUTOSET_PREVIEW_LANG })[0] }
        elseif ($request) { $ui.CopyRequest.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent))) }
        Save-Preview $ui.Root (Join-Path $PreviewDirectory 'main.png') 1060 780
    }
    if ($env:AE_AUTOSET_TEST_EDIT -and $PreviewDirectory) {
        $pack = $script:Packs | Where-Object { $_.id -eq $env:AE_AUTOSET_TEST_EDIT } | Select-Object -First 1
        Open-Register $pack
        Write-Output ('[palette hint] ' + $script:Reg.r.PaletteHint.Text)
        Save-Preview $script:Reg.r.Root (Join-Path $PreviewDirectory 'edit1.png') 644 718
    }
    if ($PreviewAep) {
        Open-Register $null
        $script:Reg.r.AepPath.Text = $PreviewAep
        if ($PreviewSample) { $script:Reg.r.SamplePath.Text = $PreviewSample }
        if ($env:AE_AUTOSET_PREVIEW_FX) {
            $script:Reg.r.FxFolder.Text = $env:AE_AUTOSET_PREVIEW_FX
            if (-not $script:Reg.r.CharacterFx.IsChecked) { throw 'Typing an FX folder must turn character FX on' }
        }
        if ($PreviewDirectory) { Save-Preview $script:Reg.r.Root (Join-Path $PreviewDirectory 'register1.png') 644 718 }
        if (Reg-Analyze) {
            Reg-ShowStep 2
            if ($PreviewDirectory) { Save-Preview $script:Reg.r.Root (Join-Path $PreviewDirectory 'register2.png') 644 718 }
            Reg-ShowStep 3; Reg-UpdatePreview
            if ($PreviewDirectory) { Save-Preview $script:Reg.r.Root (Join-Path $PreviewDirectory 'register3.png') 644 718 }
            Reg-Save
        }
    }
    Write-Output 'self-test ok'
    return
}
if ($script:State.last_root -and (Test-Path -LiteralPath $script:State.last_root)) { Scan-Folder $script:State.last_root }
try {
    $firstRun = -not $script:State.shortcuts
    $created = @(Update-Shortcuts ($EnsureShortcuts -or $firstRun))
    if ($firstRun) { $script:State.shortcuts = 'created'; Save-State }
    if ($created.Count -and ($EnsureShortcuts -or $firstRun)) {
        $ui.BannerText.Text = (L '바탕화면과 시작 메뉴에 AE AutoSet 바로가기를 만들었어요. 다음부터는 그 아이콘으로 여세요.')
        $ui.Banner.Visibility = 'Visible'
    }
} catch {}
[void]$window.ShowDialog()
