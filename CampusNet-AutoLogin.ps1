#Requires -Version 7.0
[CmdletBinding(DefaultParameterSetName = 'Setup')]
param(
    [Parameter(ParameterSetName = 'Setup')]
    [switch] $Setup,
    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [switch] $Run,
    [Parameter(Mandatory, ParameterSetName = 'Check')]
    [switch] $Check,
    [Parameter(Mandatory, ParameterSetName = 'Update')]
    [switch] $Update
)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'This program requires Windows.' }

$installDir = Join-Path $env:LOCALAPPDATA 'CampusNet-AutoLogin'
$installedScript = Join-Path $installDir 'CampusNet-AutoLogin.ps1'
$credentialPath = Join-Path $installDir 'credential.xml'
$logPath = Join-Path $installDir 'last-run.json'
$taskName = 'CampusNet-AutoLogin'
$origin = 'http://58.53.199.144:8001'
$probeUrl = 'http://www.msftconnecttest.com/connecttest.txt'
$curl = Join-Path ([Environment]::SystemDirectory) 'curl.exe'

function Get-CampusProbe {
    $addresses = @(Get-NetIPConfiguration |
        Where-Object { $_.IPv4DefaultGateway.NextHop -contains '100.64.0.1' } |
        ForEach-Object { $_.IPv4Address.IPAddress } |
        Sort-Object -Unique)
    if ($addresses.Count -ne 1) {
        return @{ Status = 'campus_interface_unavailable' }
    }

    $sourceIp = $addresses[0]
    $argsForCurl = @('--disable', '--silent', '--noproxy', '*', '--ipv4',
        '--interface', $sourceIp, '--max-time', '4', '--max-filesize', '65536',
        '--write-out', '\nCampusNetMeta:%{http_code}:%{redirect_url}\n', $probeUrl)
    $reply = @(& $curl @argsForCurl)
    if ($LASTEXITCODE -ne 0 -or $reply[-1] -notmatch '^CampusNetMeta:(\d{3}):(.*)$') {
        return @{ Status = 'probe_unreachable'; SourceIp = $sourceIp }
    }

    $httpStatus = [int] $Matches[1]
    $redirect = $Matches[2]
    $result = @{ Status = 'unexpected_response'; SourceIp = $sourceIp; HttpStatus = $httpStatus }
    if ($httpStatus -eq 200 -and
        (($reply | Select-Object -SkipLast 1) -join '').Trim() -ceq 'Microsoft Connect Test') {
        $result.Status = 'already_online'
    } elseif ($httpStatus -in @(301, 302, 303, 307, 308)) {
        $result.Status = 'unrecognized_redirect'
        $uri = $null
        if ([uri]::TryCreate($redirect, [UriKind]::Absolute, [ref] $uri) -and
            $uri.GetLeftPart([UriPartial]::Authority) -ceq $origin -and
            $uri.AbsolutePath -eq '/' -and -not $uri.UserInfo) {
            $query = [System.Web.HttpUtility]::ParseQueryString($uri.Query)
            $values = $query.GetValues('userip')
            if ($values.Count -eq 1 -and $values[0] -ceq $sourceIp) {
                $result.Status = 'portal_detected'
                $result.PortalUri = $uri
            }
        }
    }
    $result
}

function Get-ValuePattern($element) {
    $pattern = $null
    if ($element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref] $pattern)) {
        $pattern
    }
}

function Find-Control($root, $type, [string] $name) {
    $a = [System.Windows.Automation.AutomationElement]
    $conditions = [System.Windows.Automation.Condition[]] @(
        [System.Windows.Automation.PropertyCondition]::new($a::ControlTypeProperty, $type)
        [System.Windows.Automation.PropertyCondition]::new($a::NameProperty, $name)
        [System.Windows.Automation.PropertyCondition]::new($a::IsOffscreenProperty, $false)
    )
    $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.AndCondition]::new($conditions))
}

function Find-PortalDocument([uri] $expected, [ref] $browserWindow,
    [IntPtr] $OnlyWindow = [IntPtr]::Zero, [switch] $EntryOnly, [switch] $LoginResult) {
    $a = [System.Windows.Automation.AutomationElement]
    $documentType = [System.Windows.Automation.ControlType]::Document
    $condition = [System.Windows.Automation.PropertyCondition]::new($a::ControlTypeProperty, $documentType)
    $documentName = if ($LoginResult) { '校园宽带业务' } else { '校园宽带' }
    foreach ($handle in (Get-EdgeWindows)) {
        if ($OnlyWindow -ne [IntPtr]::Zero -and $handle -ne $OnlyWindow) { continue }
        try {
            $window = $a::FromHandle($handle)
            foreach ($doc in $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)) {
                if ($doc.Current.IsOffscreen) { continue }
                if (-not $EntryOnly -and $doc.Current.Name -ne $documentName) { continue }
                $value = Get-ValuePattern $doc
                $uri = $null
                if (-not $value -or
                    -not [uri]::TryCreate($value.Current.Value, [UriKind]::Absolute, [ref] $uri) -or
                    $uri.GetLeftPart([UriPartial]::Authority) -cne $origin -or $uri.UserInfo) { continue }
                if ($EntryOnly) {
                    if (-not $uri.Equals($expected)) { continue }
                    if ($browserWindow) { $browserWindow.Value = $handle }
                    return $doc
                }
                if (-not $LoginResult -and
                    ($uri.AbsolutePath -cne '/style/school_hbct/pc/index.jsp' -or
                    -not [System.Web.HttpUtility]::ParseQueryString($uri.Query).Get('paramStr'))) { continue }

                # Verify the visible frame belongs to the exact portal entry seen on this run.
                $parent = [System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($doc)
                while ($parent -and $parent.Current.ControlType -ne [System.Windows.Automation.ControlType]::Window) {
                    if ($parent.Current.ControlType -eq $documentType) {
                        $parentValue = Get-ValuePattern $parent
                        $outerUri = $null
                        if ($parentValue -and
                            [uri]::TryCreate($parentValue.Current.Value, [UriKind]::Absolute, [ref] $outerUri) -and
                            $outerUri.Equals($expected)) {
                            if ($browserWindow) { $browserWindow.Value = $handle }
                            return $doc
                        }
                    }
                    $parent = [System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($parent)
                }
            }
        } catch [System.Windows.Automation.ElementNotAvailableException] {
            continue
        }
    }
}

function Invoke-PortalButton($element) {
    $pattern = $null
    if (-not $element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref] $pattern)) {
        throw 'button_invoke_unavailable'
    }
    $pattern.Invoke()
}

function Initialize-PortalKeyboard {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class CampusPortalKeyboard {
    [StructLayout(LayoutKind.Sequential)]
    private struct Input { public uint Type; public InputData Data; }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputData {
        [FieldOffset(0)] public Keyboard Key;
        [FieldOffset(0)] public Mouse Mouse;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Keyboard {
        public ushort VirtualKey, Scan;
        public uint Flags, Time;
        public UIntPtr Extra;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Mouse {
        public int X, Y;
        public uint Data, Flags, Time;
        public UIntPtr Extra;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, Input[] inputs, int size);

    private delegate bool WindowCallback(IntPtr hwnd, IntPtr data);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(WindowCallback callback, IntPtr data);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hwnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hwnd, StringBuilder name, int size);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WTSSendMessage(IntPtr server, int sessionId, string title, int titleBytes,
        string message, int messageBytes, int style, int timeout, out int response,
        [MarshalAs(UnmanagedType.Bool)] bool wait);

    public static bool NotifyFailure(int sessionId, string message) {
        const string title = "校园网自动登录";
        return WTSSendMessage(IntPtr.Zero, sessionId, title, title.Length * 2,
            message, message.Length * 2, 0x30, 25, out _, false);
    }

    public static IntPtr[] FindEdgeWindows(uint[] processIds) {
        var ids = new HashSet<uint>(processIds);
        var windows = new List<IntPtr>();
        EnumWindows((hwnd, _) => {
            GetWindowThreadProcessId(hwnd, out uint pid);
            if (!ids.Contains(pid) || !IsWindowVisible(hwnd)) return true;
            var name = new StringBuilder(64);
            GetClassName(hwnd, name, name.Capacity);
            if (name.ToString() == "Chrome_WidgetWin_1") windows.Add(hwnd);
            return true;
        }, IntPtr.Zero);
        return windows.ToArray();
    }

    public static void RequestWindowClose(IntPtr hwnd, uint[] processIds) {
        GetWindowThreadProcessId(hwnd, out uint pid);
        if (Array.IndexOf(processIds, pid) >= 0)
            PostMessage(hwnd, 0x0010, IntPtr.Zero, IntPtr.Zero);
    }

    private static Input Key(ushort virtualKey, ushort scan, uint flags) {
        return new Input { Type = 1, Data = new InputData {
            Key = new Keyboard { VirtualKey = virtualKey, Scan = scan, Flags = flags }
        }};
    }

    public static void Replace(string text) {
        var inputs = new Input[4 + 2 * text.Length];
        inputs[0] = Key(0x11, 0, 0);
        inputs[1] = Key(0x41, 0, 0);
        inputs[2] = Key(0x41, 0, 2);
        inputs[3] = Key(0x11, 0, 2);
        for (int i = 0; i < text.Length; i++) {
            inputs[4 + 2 * i] = Key(0, text[i], 4);
            inputs[5 + 2 * i] = Key(0, text[i], 6);
        }
        if (SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>()) != inputs.Length)
            throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    public static void MoveFocusForward() {
        var inputs = new[] { Key(0x09, 0, 0), Key(0x09, 0, 2) };
        if (SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>()) != inputs.Length)
            throw new Win32Exception(Marshal.GetLastWin32Error());
    }
}
'@
}

function Set-PortalText($field, [string] $text) {
    $field.SetFocus()
    $expectedId = $field.GetRuntimeId() -join ','
    for ($i = 0; $i -lt 10; $i++) {
        $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
        if ($focused -and ($focused.GetRuntimeId() -join ',') -ceq $expectedId) {
            [CampusPortalKeyboard]::Replace($text)
            return $true
        }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function Get-EdgeProcessIds {
    $sessionId = (Get-Process -Id $PID).SessionId
    Get-Process msedge -ErrorAction SilentlyContinue |
        Where-Object SessionId -eq $sessionId | Select-Object -ExpandProperty Id
}

function Get-EdgeWindows {
    [CampusPortalKeyboard]::FindEdgeWindows([uint32[]] @(Get-EdgeProcessIds))
}

function Close-EdgeWindows([IntPtr[]] $Only = @()) {
    $edgeIds = [uint32[]] @(Get-EdgeProcessIds)
    $windows = @([CampusPortalKeyboard]::FindEdgeWindows($edgeIds) |
        Where-Object { $Only.Count -eq 0 -or $_ -in $Only })
    if ($windows.Count -eq 0) { return 'no_edge_windows_found' }
    foreach ($window in $windows) {
        [CampusPortalKeyboard]::RequestWindowClose($window, $edgeIds)
    }
    for ($i = 0; $i -lt 15; $i++) {
        $remaining = @([CampusPortalKeyboard]::FindEdgeWindows($edgeIds) |
            Where-Object { $_ -in $windows })
        if ($remaining.Count -eq 0) { return 'closed' }
        Start-Sleep -Milliseconds 200
    }
    return 'edge_windows_remain'
}

function Send-LoginFailure([string] $status) {
    $detail = switch ($status) {
        'portal_rejected' { '认证页拒绝了登录。请检查账号、密码和校园网服务状态。' }
        'portal_form_unavailable' { '认证页没有及时显示登录表单。' }
        'submitted_unverified' { '已提交，但校园网仍未确认联网。' }
        'portal_returned_after_close' { '浏览器关闭后校园网重新要求认证。' }
        'credential_missing' { '本机还没有配置校园网凭据。' }
        default { '自动登录未完成。' }
    }
    $message = "$detail`n状态：$status`n日志：$logPath"
    $session = (Get-Process -Id $PID).SessionId
    if (-not ('CampusPortalKeyboard' -as [type])) { Initialize-PortalKeyboard }
    [CampusPortalKeyboard]::NotifyFailure($session, $message)
}

if ($Check) {
    $probe = Get-CampusProbe
    [pscustomobject] @{
        Status = $probe.Status
        SourceIp = $probe.SourceIp
        HttpStatus = $probe.HttpStatus
        TaskInstalled = [bool](Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue)
        CredentialConfigured = Test-Path -LiteralPath $credentialPath
    }
    if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Raw }
    return
}

if (-not $Run) {
    $existingTask = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
    if ($existingTask.State -eq 'Running') { throw '自动登录任务正在运行，请等本次运行结束后再更新。' }
    if ($Update -and (-not $existingTask -or -not (Test-Path -LiteralPath $credentialPath))) {
        throw '未找到已配置的校园网任务或凭据，请先用 -Setup 配置。'
    }
    [void][IO.Directory]::CreateDirectory($installDir)
    $pwsh = (Get-Process -Id $PID).Path
    $storeAlias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
    if ($pwsh -like '*\WindowsApps\Microsoft.PowerShell_*' -and
        (Test-Path -LiteralPath $storeAlias)) { $pwsh = $storeAlias }
    $hostExe = Join-Path ([Environment]::SystemDirectory) 'wscript.exe'
    $launcherPath = Join-Path $installDir 'Launch-CampusNet.js'
    $launcher = @'
var shell = new ActiveXObject("WScript.Shell");
var args = WScript.Arguments;
if (args.length !== 2) WScript.Quit(2);
var command = '"' + args.Item(0) + '" -NoProfile -NonInteractive ';
if (args.Item(1) === "--check") {
    command += '-Command "exit 0"';
} else {
    command += '-File "' + args.Item(1) + '" -Run';
}
WScript.Quit(shell.Run(command, 0, true));
'@
    [IO.File]::WriteAllText($launcherPath, $launcher, [Text.Encoding]::ASCII)
    $launcherArguments = '//B //NoLogo //E:JScript "{0}" "{1}"' -f $launcherPath, $pwsh
    $smokeTest = Start-Process -FilePath $hostExe -ArgumentList ($launcherArguments + ' --check') -PassThru -Wait
    if ($smokeTest.ExitCode -ne 0) { throw '后台启动器自检失败，计划任务未更新。' }

    if (-not $Update) {
        $account = (Read-Host '校园网账号').Trim()
        if (-not $account) { throw '账号不能为空。' }
        $secret = Read-Host '校园网密码' -AsSecureString
        $tempCredential = "$credentialPath.$PID.tmp"
        try {
            if ($secret.Length -eq 0) { throw '密码不能为空。' }
            [pscredential]::new($account, $secret) | Export-Clixml -LiteralPath $tempCredential
            [IO.File]::Move($tempCredential, $credentialPath, $true)
        } finally {
            $secret.Dispose()
        }
    }
    if ($PSCommandPath -ne $installedScript) {
        $tempScript = "$installedScript.$PID.tmp"
        Copy-Item -LiteralPath $PSCommandPath -Destination $tempScript
        [IO.File]::Move($tempScript, $installedScript, $true)
    }

    $action = New-ScheduledTaskAction -Execute $hostExe -Argument ($launcherArguments + ' "' + $installedScript + '"') -WorkingDirectory $installDir
    if ($Update) {
        Set-ScheduledTask -TaskName $taskName -TaskPath '\' -Action $action | Out-Null
    } else {
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 3)
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    }
    $oldProbe = Get-ScheduledTask -TaskName 'CampusNet-Probe' -TaskPath '\' -ErrorAction SilentlyContinue
    if ($oldProbe -and $oldProbe.State -ne 'Disabled') {
        Disable-ScheduledTask -InputObject $oldProbe | Out-Null
    }
    Write-Host '配置完成。后台启动器自检通过，旧探测任务已停用或不存在。'
    return
}

[void][IO.Directory]::CreateDirectory($installDir)
$result = [ordered] @{
    startedAt = [DateTimeOffset]::Now.ToString('o')
    status = 'starting'
    sourceIp = $null
    httpStatus = $null
    finishedAt = $null
}
$portalDetected = $false
$launchRequested = $false
$ownedWindow = [IntPtr]::Zero
try {
    for ($i = 0; $i -lt 12; $i++) {
        $probe = Get-CampusProbe
        $result.status = $probe.Status
        $result.sourceIp = $probe.SourceIp
        $result.httpStatus = $probe.HttpStatus
        if ($probe.Status -eq 'already_online') { return }
        if ($probe.Status -eq 'portal_detected') { break }
        Start-Sleep -Seconds 3
    }
    if ($probe.Status -ne 'portal_detected') { return }
    $portalDetected = $true
    if (-not (Test-Path -LiteralPath $credentialPath)) {
        $result.status = 'credential_missing'
        return
    }

    $result.status = 'browser_unavailable'
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $edgePath = Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'
    if (-not (Test-Path -LiteralPath $edgePath)) { return }
    Initialize-PortalKeyboard
    $result.status = 'portal_form_unavailable'
    $portalView = $null
    # Windows may already be opening its captive-portal page at sign-in.
    for ($i = 0; $i -lt 8; $i++) {
        $portalView = Find-PortalDocument $probe.PortalUri -EntryOnly
        if ($portalView) { break }
        Start-Sleep -Seconds 1
    }
    $existingWindows = @(Get-EdgeWindows)
    if (-not $portalView) {
        $portalView = Find-PortalDocument $probe.PortalUri -EntryOnly
    }
    if ($portalView) {
        $result.portalWindow = 'reused'
    } else {
        Start-Process -FilePath $edgePath -ArgumentList @('--new-window', ('"' + $probe.PortalUri.AbsoluteUri + '"'))
        $launchRequested = $true
        $result.portalWindow = 'opened'
    }

    $buttonType = [System.Windows.Automation.ControlType]::Button
    $editType = [System.Windows.Automation.ControlType]::Edit
    $tabOpened = $false
    $authenticationWindow = [IntPtr]::Zero
    for ($i = 0; $i -lt 30; $i++) {
        if ($launchRequested -and $ownedWindow -eq [IntPtr]::Zero) {
            $entryWindow = [IntPtr]::Zero
            $null = Find-PortalDocument $probe.PortalUri -EntryOnly -browserWindow ([ref] $entryWindow)
            if ($entryWindow -ne [IntPtr]::Zero -and $entryWindow -notin $existingWindows) {
                $ownedWindow = $entryWindow
            }
        }
        $doc = Find-PortalDocument $probe.PortalUri -browserWindow ([ref] $authenticationWindow)
        if ($doc) {
            $accountField = Find-Control $doc $editType '请输入账号'
            $passwordField = Find-Control $doc $editType '请输入密码'
            if ($accountField -and $passwordField -and $passwordField.Current.IsPassword) { break }

            if (-not $tabOpened) {
                $tab = Find-Control $doc $buttonType '账号密码登录'
                if ($tab) {
                    Invoke-PortalButton $tab
                    $tabOpened = $true
                }
            }
        }
        Start-Sleep -Seconds 1
    }
    if (-not $accountField -or -not $passwordField -or -not $passwordField.Current.IsPassword) { return }

    $result.status = 'form_controls_unavailable'
    $accountValue = Get-ValuePattern $accountField
    $submit = Find-Control $doc $buttonType '登录'
    if (-not $accountValue -or -not $submit -or $accountValue.Current.IsReadOnly) { return }

    $result.status = 'credential_or_input_unavailable'
    $credential = Import-Clixml -LiteralPath $credentialPath
    $result.status = 'account_focus_failed'
    if (-not (Set-PortalText $accountField $credential.UserName)) { return }
    $result.status = 'account_input_unverified'
    for ($i = 0; $i -lt 10 -and $accountValue.Current.Value -cne $credential.UserName; $i++) {
        Start-Sleep -Milliseconds 100
    }
    if ($accountValue.Current.Value -cne $credential.UserName) { return }
    $result.status = 'password_focus_failed'
    if (-not (Set-PortalText $passwordField $credential.GetNetworkCredential().Password)) { return }
    # Tab is queued after the password keystrokes. Wait for Edge to process it.
    [CampusPortalKeyboard]::MoveFocusForward()
    $passwordId = $passwordField.GetRuntimeId() -join ','
    $result.status = 'password_input_unconfirmed'
    $focusMoved = $false
    for ($i = 0; $i -lt 15; $i++) {
        $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
        if ($focused -and ($focused.GetRuntimeId() -join ',') -cne $passwordId) {
            $focusMoved = $true
            break
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not $focusMoved) { return }
    $doc = Find-PortalDocument $probe.PortalUri -OnlyWindow $authenticationWindow
    if (-not $doc) { return }
    $submit = Find-Control $doc $buttonType '登录'
    if (-not $submit) { return }
    $result.status = 'submit_unavailable'
    Invoke-PortalButton $submit
    $result.status = 'submitted_unverified'

    for ($i = 0; $i -lt 8; $i++) {
        Start-Sleep -Seconds 2
        $after = Get-CampusProbe
        $result.httpStatus = $after.HttpStatus
        if ($after.Status -eq 'already_online' -and $after.SourceIp -eq $probe.SourceIp) {
            $result.status = 'login_verified'
            $result.browserClose = Close-EdgeWindows
            $postClose = Get-CampusProbe
            $result.postCloseNetwork = $postClose.Status
            if ($postClose.Status -eq 'portal_detected' -and $postClose.SourceIp -eq $probe.SourceIp) {
                $result.status = 'portal_returned_after_close'
            }
            break
        }
        $portalResult = Find-PortalDocument $probe.PortalUri -OnlyWindow $authenticationWindow -LoginResult
        if ($portalResult -and (Find-Control $portalResult ([System.Windows.Automation.ControlType]::Text) '登录失败')) {
            $result.status = 'portal_rejected'
            break
        }
    }
} catch {
    # UI automation exceptions can contain page text. Keep the current stage only.
    $result.errorType = $_.Exception.GetType().Name
} finally {
    if (($portalDetected -or $result.sourceIp) -and $result.status -notin @('login_verified', 'already_online')) {
        if ($ownedWindow -ne [IntPtr]::Zero -and -not $result.browserClose) {
            try {
                $ownedPortal = Find-PortalDocument $probe.PortalUri -OnlyWindow $ownedWindow -EntryOnly
                if ($ownedPortal) {
                    $result.browserClose = Close-EdgeWindows -Only @($ownedWindow)
                } else {
                    $result.browserClose = 'portal_not_in_owned_window'
                }
            } catch {
                $result.browserClose = 'close_check_failed'
            }
        } elseif (-not $result.browserClose -and $result.portalWindow -eq 'reused') {
            $result.browserClose = 'reused_window_preserved'
        }
        try {
            $result.failureNotification = Send-LoginFailure $result.status
        } catch {
            $result.failureNotification = $false
        }
    }
    $result.finishedAt = [DateTimeOffset]::Now.ToString('o')
    $tempLog = "$logPath.$PID.tmp"
    $result | ConvertTo-Json | Set-Content -LiteralPath $tempLog -Encoding utf8
    [IO.File]::Move($tempLog, $logPath, $true)
}
