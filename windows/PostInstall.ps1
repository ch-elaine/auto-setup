<#
.SYNOPSIS
    Post-install automation for the baneberry45 unattended Windows 11 setup.

.DESCRIPTION
    Started automatically by FirstLogon.ps1 after the first sign-in, and once
    with -Specialize during Windows Setup. It can also be run by hand on an
    existing Windows 11 install (it elevates itself):
        powershell -ExecutionPolicy Bypass -File .\PostInstall.ps1

    During setup (-Specialize, runs as SYSTEM, no network):
      - stops desktop.ini creation (UseDesktopIniCache = 0)
      - enables .NET 3.5 (from the install USB), WSL and Virtual Machine Platform
      - gives the partition labelled "Data" the letter D:

    Stage 1 (first sign-in):
      - repeats the three steps above if anything was missed
      - installs the newest AMD Adrenalin driver for the RX 7800 XT
      - installs Lightshot, Discord, Steam, Firefox, Twinkle Tray,
        DirectX (web runtime), WSL and Docker Desktop with winget
      - runs Win11Debloat in its default ("recommended") mode
      - removes Microsoft Edge     (ShadowWhisperer/Remove-MS-Edge)
      - removes Windows Defender   (ionuttbara/windows-defender-remover) -> restart

    Stage 2 (after the restart):
      - makes sure the hypervisor runs (WSL2 and Docker need it)
      - retries anything that failed in stage 1
      - installs Ubuntu on WSL2
      - switches auto-logon back off and shows a summary

    Log:   C:\Windows\Setup\Scripts\PostInstall.log
    State: C:\Windows\Setup\Scripts\PostInstall.state.json
    -Retry re-runs only the steps that failed. -Reset starts over from stage 1.
#>
[CmdletBinding()]
param(
    [switch] $Specialize,
    [switch] $Retry,
    [switch] $Reset
)

# ================================ Settings ================================

$Apps = @(
    @{ Name = 'Lightshot';      Id = 'Skillbrains.Lightshot' }
    @{ Name = 'Discord';        Id = 'Discord.Discord' }
    @{ Name = 'Steam';          Id = 'Valve.Steam' }
    @{ Name = 'Firefox';        Id = 'Mozilla.Firefox' }
    @{ Name = 'Twinkle Tray';   Id = 'xanderfrangos.twinkletray' }
    # The winget package also offers a UWP runtime; --installer-type exe picks the
    # classic DirectX End-User Runtime web installer (dxwebsetup.exe) that games need.
    @{ Name = 'DirectX (web)';  Id = 'Microsoft.DirectX'; Extra = '--installer-type exe' }
    @{ Name = 'WSL';            Id = 'Microsoft.WSL' }
    @{ Name = 'Docker Desktop'; Id = 'Docker.DockerDesktop' }
)

$WslDistro      = 'Ubuntu'

$AmdDriverPage  = 'https://www.amd.com/en/support/downloads/drivers.html/graphics/radeon-rx/radeon-rx-7000-series/amd-radeon-rx-7800-xt.html'
$AmdUseNewest   = $true    # $true = newest driver on the page (may be "Optional"), $false = the "WHQL Recommended" one
$AmdFallbackUrl = 'https://drivers.amd.com/drivers/whql-amd-software-adrenalin-edition-26.8.1-win11-b.exe'

$RunDebloat     = $true
$RemoveEdge     = $true
$EdgeRemover    = 'Edge.bat'   # 'Both.bat' also removes WebView2 (breaks Roblox, the Xbox app, Tauri apps...)
$RemoveDefender = $true

# Password of this account, used only for auto sign-in across the restarts.
# The unattend file creates the account without a password, so this stays empty.
$AutoLogonPassword = ''

# ============================== Internals ==============================

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Self        = $PSCommandPath
$ScriptDir   = 'C:\Windows\Setup\Scripts'
$StateFile   = Join-Path $ScriptDir 'PostInstall.state.json'
$LogFile     = Join-Path $ScriptDir 'PostInstall.log'
$LogDir      = Join-Path $ScriptDir 'Logs'
$WorkDir     = Join-Path $env:SystemRoot 'Temp\PostInstall'
$Curl        = Join-Path $env:SystemRoot 'System32\curl.exe'
$UserAgent   = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36'
$WinlogonKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$RunOnceKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'

$script:Winget        = $null
$script:RebootPending = $false

# ------------------------------ Output ------------------------------

function Write-Section([string] $Text) { Write-Host ''; Write-Host "==== $Text ====" -ForegroundColor Cyan }
function Write-Info([string] $Text)    { Write-Host "  $Text" }
function Write-Warn([string] $Text)    { Write-Host "  ! $Text" -ForegroundColor Yellow }

# ------------------------------ Helpers ------------------------------

function Invoke-Native {
    # Runs a program, shows its output live in this window and returns its exit code.
    # Waits only for the program itself, not for apps it launches (Discord, Steam...).
    param(
        [Parameter(Mandatory = $true)] [string] $FilePath,
        [string] $Arguments,
        [string] $WorkingDirectory,
        [int] $TimeoutMinutes = 0,
        [switch] $NewWindow
    )
    $sp = @{ FilePath = $FilePath; PassThru = $true }
    if ($Arguments)        { $sp.ArgumentList = $Arguments }
    if ($WorkingDirectory) { $sp.WorkingDirectory = $WorkingDirectory }
    if (-not $NewWindow)   { $sp.NoNewWindow = $true }
    $p = Start-Process @sp
    $null = $p.Handle   # Windows PowerShell quirk: grab the handle now, or ExitCode is lost later
    if ($TimeoutMinutes -gt 0) {
        if (-not $p.WaitForExit($TimeoutMinutes * 60 * 1000)) {
            try { $p.Kill() } catch { }
            throw ('{0} did not finish within {1} minutes' -f (Split-Path -Leaf $FilePath), $TimeoutMinutes)
        }
    } else {
        $p.WaitForExit()
    }
    return [int] $p.ExitCode
}

function Get-File {
    param(
        [Parameter(Mandatory = $true)] [string] $Url,
        [Parameter(Mandatory = $true)] [string] $OutFile,
        [string] $Referer
    )
    $dir = Split-Path -Parent $OutFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $a = @('-L', '--fail', '--retry', '5', '--retry-delay', '5', '--connect-timeout', '30', '--progress-bar', '-A', $UserAgent, '-o', $OutFile)
    if ($Referer) { $a += @('-e', $Referer) }
    $a += $Url
    & $Curl @a
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutFile)) {
        throw "Download failed (curl exit code $LASTEXITCODE): $Url"
    }
}

function Get-LatestReleaseTag([string] $Repo) {
    # Reads the redirect of github.com/<repo>/releases/latest (no API rate limit).
    $headers = & $Curl -sSI --max-time 30 -A $UserAgent "https://github.com/$Repo/releases/latest"
    foreach ($h in @($headers)) {
        if ($h -match '^location:\s*\S*/releases/tag/([^\s/?#]+)') { return [uri]::UnescapeDataString($Matches[1]) }
    }
    return $null
}

function Test-Internet {
    $code = & $Curl -s -o NUL -w '%{http_code}' --max-time 10 'http://www.msftconnecttest.com/connecttest.txt'
    return ($code -eq '200')
}

function Wait-Internet {
    if (Test-Internet) { return }
    Write-Warn 'No internet connection. Plug in Ethernet or connect to Wi-Fi - setup continues by itself.'
    while (-not (Test-Internet)) { Start-Sleep -Seconds 10 }
    Write-Info 'Internet connection is up.'
}

function ConvertTo-EncodedCommand([string] $Command) {
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
}

function Initialize-Console {
    try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
    try {
        Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PostInstallNative {
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr h, out uint mode);
    [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr h, uint mode);
    [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);
    public static void DisableQuickEdit() {
        IntPtr h = GetStdHandle(-10);
        uint mode;
        if (GetConsoleMode(h, out mode)) { SetConsoleMode(h, (mode & ~0x40u) | 0x80u); }
    }
}
'@
    } catch { }
    # Clicking into a console window with QuickEdit on pauses the script - turn it off.
    try { [PostInstallNative]::DisableQuickEdit() } catch { }
    # ES_CONTINUOUS | ES_SYSTEM_REQUIRED: don't let the PC go to sleep in the middle of a download.
    try { [void] [PostInstallNative]::SetThreadExecutionState([uint32] 2147483649) } catch { }
}

# ------------------------------ State ------------------------------

function Get-State {
    if (Test-Path -LiteralPath $StateFile) {
        try { return (Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json) }
        catch { Write-Warn 'State file is unreadable - starting from stage 1.' }
    }
    return [pscustomobject] @{ Stage = 1; HvAttempts = 0; Results = @() }
}

function Save-State {
    $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function Get-ResultStatus([string] $Name) {
    $r = @($State.Results) | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if ($r) { return $r.Status }
    return $null
}

function Set-Result([string] $Name, [string] $Status, [string] $Detail) {
    $r = @($State.Results) | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if ($r) {
        $r.Status = $Status
        $r.Detail = $Detail
    } else {
        $State.Results = @($State.Results) + [pscustomobject] @{ Name = $Name; Status = $Status; Detail = $Detail }
    }
    Save-State
}

function Invoke-Step([hashtable] $Step) {
    $name = $Step.Name
    if ((Get-ResultStatus $name) -in 'OK', 'SKIPPED') {
        Write-Host "  [already done] $name" -ForegroundColor DarkGray
        return
    }
    Write-Section $name
    $status = 'OK'
    $detail = ''
    try {
        $out  = & $Step.Action $Step
        $last = @($out) | Where-Object { $_ -is [string] } | Select-Object -Last 1
        if ($last) { $detail = $last }
        if ($detail -like 'SKIP:*') { $status = 'SKIPPED'; $detail = $detail.Substring(5).Trim() }
    } catch {
        $status = 'FAILED'
        $detail = $_.Exception.Message
    }
    Set-Result -Name $name -Status $status -Detail $detail
    $color = switch ($status) { 'OK' { 'Green' } 'SKIPPED' { 'DarkYellow' } default { 'Red' } }
    $suffix = ''
    if ($detail) { $suffix = ": $detail" }
    Write-Host "  -> $status$suffix" -ForegroundColor $color
}

# ------------------------- Resume / auto-logon -------------------------

function Set-Resume {
    if (-not (Test-Path $RunOnceKey)) { New-Item -Path $RunOnceKey | Out-Null }
    $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $Self
    Set-ItemProperty -Path $RunOnceKey -Name 'PostInstall' -Value $cmd
}

function Clear-Resume {
    Remove-ItemProperty -Path $RunOnceKey -Name 'PostInstall' -ErrorAction SilentlyContinue
}

function Enable-AutoLogon {
    Set-ItemProperty -Path $WinlogonKey -Name 'AutoAdminLogon'    -Value '1' -Type String
    Set-ItemProperty -Path $WinlogonKey -Name 'DefaultUserName'   -Value $env:USERNAME -Type String
    Set-ItemProperty -Path $WinlogonKey -Name 'DefaultDomainName' -Value $env:COMPUTERNAME -Type String
    Set-ItemProperty -Path $WinlogonKey -Name 'DefaultPassword'   -Value $AutoLogonPassword -Type String
    Remove-ItemProperty -Path $WinlogonKey -Name 'AutoLogonCount' -ErrorAction SilentlyContinue
}

function Disable-AutoLogon {
    Set-ItemProperty -Path $WinlogonKey -Name 'AutoAdminLogon' -Value '0' -Type String
    Remove-ItemProperty -Path $WinlogonKey -Name 'DefaultPassword' -ErrorAction SilentlyContinue
}

function Restart-Now([string] $Reason, [switch] $AlreadyScheduled) {
    Save-State
    Enable-AutoLogon
    Set-Resume
    Write-Section 'Restarting'
    Write-Info "$Reason. Setup continues automatically after Windows starts again."
    try { Stop-Transcript | Out-Null } catch { }
    if ($AlreadyScheduled) { Start-Sleep -Seconds 60 }   # the Defender remover restarts by itself
    $null = Invoke-Native -FilePath (Join-Path $env:SystemRoot 'System32\shutdown.exe') -Arguments "/r /t 15 /c `"Post-install setup: $Reason`""
}

# ============================ Step actions ============================

function Set-DesktopIniPolicy {
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    Set-ItemProperty -Path $key -Name 'UseDesktopIniCache' -Value 0 -Type DWord
    return 'UseDesktopIniCache = 0'
}

function Set-DataDriveLetter {
    # Gives the partition labelled "Data" on the Windows disk the letter D:.
    # If D: is taken (install USB, DVD drive...), that volume moves to a free letter first.
    $osDisk = (Get-Partition -DriveLetter $env:SystemDrive[0]).DiskNumber
    $data = Get-Partition -DiskNumber $osDisk |
        Where-Object { ($_ | Get-Volume -ErrorAction SilentlyContinue).FileSystemLabel -eq 'Data' } |
        Select-Object -First 1
    if (-not $data) { return 'SKIP: no partition labelled "Data" on the Windows disk' }
    if ([string] $data.DriveLetter -eq 'D') { return 'Data partition already is D:' }

    $taken = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter = 'D:'"
    if ($taken) {
        $used = @(Get-CimInstance -ClassName Win32_Volume | ForEach-Object { $_.DriveLetter }) +
                @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 2) })
        $free = 90..69 | ForEach-Object { '{0}:' -f [char] $_ } | Where-Object { $used -notcontains $_ } | Select-Object -First 1
        if (-not $free) { throw 'No free drive letter to move the current D: to.' }
        Set-CimInstance -InputObject $taken -Property @{ DriveLetter = $free }
        Write-Info "Moved volume '$($taken.Label)' from D: to $free"
    }
    $data | Set-Partition -NewDriveLetter 'D'
    return 'Data partition is now D:'
}

function Find-SxsSource {
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        if (-not $d.IsReady) { continue }
        $sxs = Join-Path $d.RootDirectory.FullName 'sources\sxs'
        if (Test-Path -Path (Join-Path $sxs '*netfx3*.cab')) { return $sxs }
    }
    return $null
}

function Enable-RequiredFeatures {
    $changed = @()
    foreach ($name in 'NetFx3', 'Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform') {
        $f = Get-WindowsOptionalFeature -Online -FeatureName $name
        if (-not $f) { Write-Warn "$name is not available on this Windows edition"; continue }
        if ([string] $f.State -in 'Enabled', 'EnablePending') { continue }
        $params = @{ Online = $true; FeatureName = $name; All = $true; NoRestart = $true }
        if ($name -eq 'NetFx3') {
            $sxs = Find-SxsSource
            if ($sxs) {
                $params.Source = $sxs
                $params.LimitAccess = $true
                Write-Info ".NET 3.5: using $sxs"
            } else {
                Write-Info '.NET 3.5: install media not found, downloading from Windows Update'
            }
        }
        Write-Info "Enabling $name..."
        $r = Enable-WindowsOptionalFeature @params
        if ($r.RestartNeeded) { $script:RebootPending = $true }
        $changed += $name
    }
    if ($changed) { return 'Enabled ' + ($changed -join ', ') }
    return 'Already enabled'
}

function Install-AmdDriver {
    $gpu = @(Get-CimInstance -ClassName Win32_PnPEntity -Filter "PNPClass = 'Display'" | Where-Object { $_.PNPDeviceID -like 'PCI\VEN_1002*' })
    if (-not $gpu) { return 'SKIP: no AMD graphics card detected' }
    Write-Info ('Found: ' + (($gpu | ForEach-Object { $_.Name }) -join ', '))

    # Read the RX 7800 XT driver page and pick the Adrenalin package link from it.
    $url = $null
    try {
        $html = (& $Curl -sSL --fail --max-time 60 -A $UserAgent -H 'Accept-Language: en-US,en;q=0.9' $AmdDriverPage) -join "`n"
        $found = @()
        $pattern = 'https://drivers\.amd\.com/drivers/whql-amd-software-adrenalin-edition-(\d+(?:\.\d+){1,3})-win1[01][\w.-]*?\.exe'
        foreach ($m in [regex]::Matches($html, $pattern)) {
            if (-not ($found | Where-Object { $_.Url -eq $m.Value })) {
                $found += [pscustomobject] @{ Url = $m.Value; Version = [version] $m.Groups[1].Value }
            }
        }
        if ($found) {
            if ($AmdUseNewest) { $url = ($found | Sort-Object -Property Version -Descending | Select-Object -First 1).Url }
            else               { $url = $found[0].Url }   # AMD lists "WHQL Recommended" first
        }
    } catch {
        Write-Warn "Could not read the AMD driver page: $($_.Exception.Message)"
    }
    if (-not $url) {
        $url = $AmdFallbackUrl
        Write-Warn 'No driver link found on the AMD page - using the fallback URL.'
    }
    Write-Info "Package: $url"

    $exe = Join-Path $WorkDir ([IO.Path]::GetFileName($url))
    Get-File -Url $url -OutFile $exe -Referer 'https://www.amd.com/en/support/download/drivers.html'
    $sig = Get-AuthenticodeSignature -FilePath $exe
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Advanced Micro Devices') {
        throw "The download is not a valid AMD-signed installer (signature: $($sig.Status)). AMD may have blocked the download."
    }

    Write-Info 'Installing silently - the screen may flicker or go black for a moment...'
    $code = Invoke-Native -FilePath $exe -Arguments '-install' -TimeoutMinutes 60

    # The package unpacks itself to C:\AMD and hands over to its own installer: wait for that too.
    Start-Sleep -Seconds 15
    $deadline = (Get-Date).AddMinutes(60)
    while ((Get-Date) -lt $deadline) {
        $busy = Get-CimInstance -ClassName Win32_Process | Where-Object { $_.ExecutablePath -like 'C:\AMD\*' }
        if (-not $busy) { break }
        Start-Sleep -Seconds 10
    }

    $drv = Get-CimInstance -ClassName Win32_PnPSignedDriver -Filter "DeviceClass = 'DISPLAY'" |
        Where-Object { $_.DeviceID -like 'PCI\VEN_1002*' -and $_.DriverProviderName -match 'Advanced Micro Devices|AMD' } |
        Select-Object -First 1
    if ($drv) { return "Driver $($drv.DriverVersion) installed" }
    if (Test-Path (Join-Path $env:ProgramFiles 'AMD\CNext\CNext\RadeonSoftware.exe')) { return "AMD Software installed (installer exit code $code)" }
    throw "AMD installer exit code $code, but no AMD display driver is active."
}

function Repair-Winget {
    Write-Info 'winget is missing or broken - installing it with the Microsoft.WinGet.Client module...'
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
    Install-Module -Name Microsoft.WinGet.Client -Repository PSGallery -Force -Scope AllUsers
    Import-Module -Name Microsoft.WinGet.Client -Force
    Repair-WinGetPackageManager -AllUsers -Latest -Force | Out-Null
}

function Find-Winget {
    $candidates = @(
        (Get-Command -Name 'winget.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    foreach ($c in $candidates) {
        try {
            $v = & $c --version
            if ($LASTEXITCODE -eq 0 -and $v) { $script:Winget = $c; return [string] $v }
        } catch { }
    }
    return $null
}

function Initialize-Winget {
    $version = Find-Winget
    for ($i = 1; -not $version -and $i -le 12; $i++) {
        if ($i -eq 1) { Write-Info 'Waiting for winget (App Installer) to finish registering...' }
        try { Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop } catch { }
        Start-Sleep -Seconds 10
        $version = Find-Winget
    }
    if (-not $version) {
        Repair-Winget
        $version = Find-Winget
        if (-not $version) { throw 'winget could not be found or installed.' }
    }
    $null = Invoke-Native -FilePath $script:Winget -Arguments 'source update --name winget' -TimeoutMinutes 10
    return "winget $version"
}

function Install-WingetApp([string] $Id, [string] $Extra) {
    # 0 = installed, 0x8A15002B = nothing newer to install, 0x8A150061 = already installed,
    # 0x8A150101 = installed, restart needed to finish
    $okCodes = @(0, -1978335189, -1978335135, -1978334975)
    $wgArgs = "install --exact --id $Id --source winget --silent --accept-package-agreements --accept-source-agreements"
    if ($Extra) { $wgArgs += " $Extra" }
    $code = 0
    for ($try = 1; $try -le 2; $try++) {
        $code = Invoke-Native -FilePath $script:Winget -Arguments $wgArgs -TimeoutMinutes 45
        if ($okCodes -contains $code) { return 'Installed' }
        Write-Warn ('winget exit code 0x{0:X8}' -f $code)
        Start-Sleep -Seconds 10
    }
    $listed = Invoke-Native -FilePath $script:Winget -Arguments "list --exact --id $Id --accept-source-agreements"
    if ($listed -eq 0) { return 'Installed (confirmed with winget list)' }
    throw ('winget failed with exit code 0x{0:X8}' -f $code)
}

function Install-DirectXDirect {
    $exe = Join-Path $WorkDir 'dxwebsetup.exe'
    Get-File -Url 'https://download.microsoft.com/download/1/7/1/1718ccc4-6315-4d8e-9543-8e28a4e18c4c/dxwebsetup.exe' -OutFile $exe
    $code = Invoke-Native -FilePath $exe -Arguments '/Q' -TimeoutMinutes 20
    if (@(0, -1442840576) -notcontains $code) { throw "dxwebsetup.exe exited with code $code" }
    return 'Installed with dxwebsetup.exe /Q'
}

$AppAction = {
    param($s)
    if (-not $script:Winget) { $null = Initialize-Winget }
    try {
        Install-WingetApp -Id $s.Id -Extra $s.Extra
    } catch {
        if ($s.Id -ne 'Microsoft.DirectX') { throw }
        Write-Warn "winget failed ($($_.Exception.Message)) - using Microsoft's direct download instead."
        Install-DirectXDirect
    }
}

function Add-DockerUser {
    if (-not (Get-LocalGroup -Name 'docker-users' -ErrorAction SilentlyContinue)) {
        throw 'The docker-users group does not exist yet (Docker Desktop is not installed).'
    }
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    try {
        Add-LocalGroupMember -Group 'docker-users' -Member $me -ErrorAction Stop
        return "$me added"
    } catch {
        if ($_.FullyQualifiedErrorId -like 'MemberExists*') { return "$me is already a member" }
        throw
    }
}

function Invoke-Win11Debloat {
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    # Runs in its own PowerShell window: the official launcher clears the screen and calls 'exit'.
    $cmd = "& ([scriptblock]::Create((Invoke-RestMethod -Uri 'https://debloat.raphi.re/' -UseBasicParsing))) -RunDefaults -Silent -LogPath '$LogDir'"
    $code = Invoke-Native -FilePath 'powershell.exe' -Arguments ('-NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + (ConvertTo-EncodedCommand $cmd)) -NewWindow -TimeoutMinutes 20
    if ($code -ne 0) { throw "Win11Debloat exited with code $code (log: $LogDir)" }
    return 'Default settings applied and default apps removed'
}

function Remove-Edge {
    $edgeExe = Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'
    if (-not (Test-Path $edgeExe)) { return 'SKIP: Edge is not installed' }
    $bat = Join-Path $WorkDir $EdgeRemover
    Get-File -Url "https://raw.githubusercontent.com/ShadowWhisperer/Remove-MS-Edge/main/Batch/$EdgeRemover" -OutFile $bat
    $code = Invoke-Native -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -Arguments ('/c ""{0}""' -f $bat) -WorkingDirectory $WorkDir -TimeoutMinutes 20
    if (Test-Path $edgeExe) { throw "Edge is still installed (remover exit code $code)" }
    return "Edge removed with $EdgeRemover"
}

function Remove-Defender {
    $repo = 'ionuttbara/windows-defender-remover'
    $tag  = Get-LatestReleaseTag $repo
    if ($tag) { $url = "https://github.com/$repo/archive/refs/tags/$tag.zip" }
    else      { $url = "https://github.com/$repo/archive/refs/heads/main.zip" }
    $zip  = Join-Path $WorkDir 'defender-remover.zip'
    $dest = Join-Path $WorkDir 'defender-remover'
    Get-File -Url $url -OutFile $zip
    if (Test-Path $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force
    $runner = Get-ChildItem -Path $dest -Recurse -Filter 'Script_Run.cmd' | Select-Object -First 1
    if (-not $runner) { throw 'Script_Run.cmd was not found in the download.' }
    # "y" = remove Defender antivirus + Windows Security app, no menu. The script restarts Windows itself.
    $code = Invoke-Native -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -Arguments ('/c ""{0}" y"' -f $runner.FullName) -WorkingDirectory $runner.DirectoryName -TimeoutMinutes 20
    return "Remover $(if ($tag) { $tag } else { 'main' }) finished (exit code $code)"
}

function Get-WslDistros {
    $wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
    $env:WSL_UTF8 = '1'
    $lines = @(& $wsl --list --quiet)
    return @($lines | ForEach-Object { ([string] $_ -replace "`0", '').Trim() } | Where-Object { $_ })
}

function Install-WslDistro {
    $wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
    if ((Get-WslDistros) -contains $WslDistro) { return "$WslDistro is already installed" }
    $null = Invoke-Native -FilePath $wsl -Arguments '--set-default-version 2' -TimeoutMinutes 5
    # --web-download: the Microsoft Store is removed by the unattend file, so download from the web.
    # --no-launch: Ubuntu asks for a Linux user name the first time you open it.
    $code = Invoke-Native -FilePath $wsl -Arguments "--install --distribution $WslDistro --no-launch --web-download" -TimeoutMinutes 30
    if ((Get-WslDistros) -notcontains $WslDistro) { throw "wsl --install failed (exit code $code)" }
    return "$WslDistro installed on WSL2"
}

function Test-Hypervisor {
    return [bool] (Get-CimInstance -ClassName Win32_ComputerSystem).HypervisorPresent
}

# ============================== Step lists ==============================

$Stage1Steps = @(
    @{ Name = 'Data partition as D:';                 Retry = $true; Action = { Set-DataDriveLetter } }
    @{ Name = 'Stop desktop.ini creation';            Retry = $true; Action = { Set-DesktopIniPolicy } }
    @{ Name = 'AMD Radeon driver';                    Retry = $true; Action = { Install-AmdDriver } }
    @{ Name = 'Features: .NET 3.5, WSL, VM Platform'; Retry = $true; Action = { Enable-RequiredFeatures } }
    @{ Name = 'winget';                               Retry = $true; Action = { Initialize-Winget } }
)
foreach ($a in $Apps) {
    $Stage1Steps += @{ Name = "Install $($a.Name)"; Retry = $true; Id = $a.Id; Extra = $a.Extra; Action = $AppAction }
}
$Stage1Steps += @{ Name = 'Add user to docker-users'; Retry = $true; Action = { Add-DockerUser } }
if ($RunDebloat) { $Stage1Steps += @{ Name = 'Win11Debloat (default mode)'; Retry = $true; Action = { Invoke-Win11Debloat } } }
if ($RemoveEdge) { $Stage1Steps += @{ Name = 'Remove Microsoft Edge';       Retry = $true; Action = { Remove-Edge } } }

$DefenderStep = @{ Name = 'Remove Windows Defender';      Retry = $false; Action = { Remove-Defender } }
$WslStep      = @{ Name = "Install $WslDistro on WSL2";  Retry = $true;  Action = { Install-WslDistro } }

# ================================ Stages ================================

function Invoke-Stage1 {
    Set-Resume   # if anything crashes or the PC restarts unexpectedly, carry on at next sign-in
    Wait-Internet
    foreach ($s in $Stage1Steps) { Invoke-Step $s }

    # The Defender remover restarts Windows by itself, so prepare stage 2 first.
    $State.Stage = 2
    Save-State
    Enable-AutoLogon
    Set-Resume
    if ($RemoveDefender -and (Get-ResultStatus $DefenderStep.Name) -ne 'OK') {
        Invoke-Step $DefenderStep
        if ((Get-ResultStatus $DefenderStep.Name) -eq 'OK') {
            Restart-Now -Reason 'Defender removal needs a restart' -AlreadyScheduled
            return
        }
    }
    Restart-Now -Reason 'Stage 1 finished'
}

function Invoke-Stage2 {
    Set-Resume
    Wait-Internet

    $hvName = 'Hypervisor (needed by WSL2 / Docker)'
    if (Test-Hypervisor) {
        Set-Result -Name $hvName -Status 'OK' -Detail 'Running'
    } elseif ([int] $State.HvAttempts -lt 1) {
        $State.HvAttempts = [int] $State.HvAttempts + 1
        $null = Invoke-Native -FilePath (Join-Path $env:SystemRoot 'System32\bcdedit.exe') -Arguments '/set hypervisorlaunchtype auto'
        Restart-Now -Reason 'Turning the hypervisor back on'
        return
    } else {
        Set-Result -Name $hvName -Status 'FAILED' -Detail 'Not running - enable SVM Mode (AMD-V) in the BIOS'
    }

    foreach ($s in $Stage1Steps) { if ($s.Retry) { Invoke-Step $s } }
    Invoke-Step $WslStep

    Write-Section 'Cleaning up'
    Disable-AutoLogon
    Clear-Resume
    foreach ($p in $WorkDir, 'C:\AMD') {
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $State.Stage = 'Done'
    Save-State
    Show-Summary
}

function Show-Summary {
    Write-Section 'Summary'
    @($State.Results) | Format-Table -Property Name, Status, Detail -AutoSize -Wrap | Out-String -Width 220 | Write-Host
    Write-Host '  Next steps:' -ForegroundColor Cyan
    Write-Info "- Open '$WslDistro' from the Start menu once to create your Linux user name and password."
    Write-Info '- Start Docker Desktop once; it finishes its own setup on the WSL2 backend.'
    Write-Info '- Choose Firefox as the default browser in Settings > Apps > Default apps.'
    if (@($State.Results | Where-Object { $_.Status -eq 'FAILED' })) {
        Write-Warn "Some steps failed. Fix the cause, then run:  powershell -ExecutionPolicy Bypass -File `"$Self`" -Retry"
    }
    if ($script:RebootPending) { Write-Warn 'Restart Windows once more to finish enabling Windows features.' }
    Write-Info "Full log: $LogFile"
    Write-Host ''
    [void] (Read-Host '  Press Enter to close this window')
}

# ================================= Main =================================

$principal = [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $Self
    if ($Retry) { $argList += ' -Retry' }
    if ($Reset) { $argList += ' -Reset' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    return
}

foreach ($dir in $ScriptDir, $LogDir, $WorkDir) {
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

if ($Specialize) {
    # Windows Setup, specialize pass: runs as SYSTEM, hidden, no network.
    # Output ends up in C:\Windows\Setup\Scripts\Specialize.log.
    foreach ($action in @({ Set-DesktopIniPolicy }, { Enable-RequiredFeatures }, { Set-DataDriveLetter })) {
        try { & $action } catch { "ERROR: $($_.Exception.Message)" }
    }
    return
}

if ($Reset -and (Test-Path -LiteralPath $StateFile)) { Remove-Item -LiteralPath $StateFile -Force }

Start-Transcript -LiteralPath $LogFile -Append | Out-Null
$Host.UI.RawUI.WindowTitle = 'Post-install setup - do not close this window'
Initialize-Console

$State = Get-State
if ($Retry) {
    $State.Stage = 2
    $State.HvAttempts = 0
    Save-State
}

Write-Host ''
Write-Host '  Post-install setup' -ForegroundColor Cyan
Write-Host '  This window installs drivers and apps and restarts the PC once or twice.' -ForegroundColor Cyan
Write-Host '  Leave it open; it carries on by itself after each restart.' -ForegroundColor Cyan

switch ([string] $State.Stage) {
    '1'     { Invoke-Stage1 }
    '2'     { Invoke-Stage2 }
    default {
        Write-Info 'Post-install has already finished. Use -Retry to re-run failed steps or -Reset to start over.'
        Start-Sleep -Seconds 10
    }
}

try { Stop-Transcript | Out-Null } catch { }
