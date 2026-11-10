#Requires -Version 7.0
[CmdletBinding(DefaultParameterSetName = 'Setup')]
param(
    [Parameter(ParameterSetName = 'Setup')]
    [switch] $Setup,
    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [switch] $Run,
    [Parameter(Mandatory, ParameterSetName = 'Check')]
    [switch] $Check
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

function Find-PortalDocument([uri] $expected) {
    $a = [System.Windows.Automation.AutomationElement]
    $documentType = [System.Windows.Automation.ControlType]::Document
    $condition = [System.Windows.Automation.PropertyCondition]::new($a::ControlTypeProperty, $documentType)
    foreach ($edge in (Get-Process msedge -ErrorAction SilentlyContinue)) {
        if ($edge.MainWindowHandle -eq [IntPtr]::Zero) { continue }
        try {
            $window = $a::FromHandle($edge.MainWindowHandle)
            foreach ($doc in $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)) {
                if ($doc.Current.IsOffscreen -or $doc.Current.Name -ne '校园宽带') { continue }
                $value = Get-ValuePattern $doc
                $uri = $null
                if (-not $value -or
                    -not [uri]::TryCreate($value.Current.Value, [UriKind]::Absolute, [ref] $uri) -or
                    $uri.GetLeftPart([UriPartial]::Authority) -cne $origin -or $uri.UserInfo -or
                    $uri.AbsolutePath -cne '/style/school_hbct/pc/index.jsp' -or
                    -not [System.Web.HttpUtility]::ParseQueryString($uri.Query).Get('paramStr')) { continue }

                # Verify the visible frame belongs to the exact portal entry seen on this run.
                $parent = [System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($doc)
                while ($parent -and $parent.Current.ControlType -ne [System.Windows.Automation.ControlType]::Window) {
                    if ($parent.Current.ControlType -eq $documentType) {
                        $parentValue = Get-ValuePattern $parent
                        $outerUri = $null
                        if ($parentValue -and
                            [uri]::TryCreate($parentValue.Current.Value, [UriKind]::Absolute, [ref] $outerUri) -and
                            $outerUri.Equals($expected)) { return $doc }
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

function Close-EdgeWindows {
    $sessionId = (Get-Process -Id $PID).SessionId
    $edgeIds = [uint32[]] @(Get-Process msedge -ErrorAction SilentlyContinue |
        Where-Object SessionId -eq $sessionId | Select-Object -ExpandProperty Id)
    $windows = [CampusPortalKeyboard]::FindEdgeWindows($edgeIds)
    if ($windows.Count -eq 0) { return 'no_edge_windows_found' }
    foreach ($window in $windows) {
        [CampusPortalKeyboard]::RequestWindowClose($window, $edgeIds)
    }
    for ($i = 0; $i -lt 15; $i++) {
        if ([CampusPortalKeyboard]::FindEdgeWindows($edgeIds).Count -eq 0) { return 'closed' }
        Start-Sleep -Milliseconds 200
    }
    return 'edge_windows_remain'
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
    $account = (Read-Host '校园网账号').Trim()
    if (-not $account) { throw '账号不能为空。' }
    $secret = Read-Host '校园网密码' -AsSecureString
    if ($secret.Length -eq 0) { throw '密码不能为空。' }

    [void][IO.Directory]::CreateDirectory($installDir)
    if ($PSCommandPath -ne $installedScript) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $installedScript
    }
    $tempCredential = "$credentialPath.$PID.tmp"
    try {
        [pscredential]::new($account, $secret) | Export-Clixml -LiteralPath $tempCredential
        [IO.File]::Move($tempCredential, $credentialPath, $true)
    } finally {
        $secret.Dispose()
    }

    $pwsh = (Get-Process -Id $PID).Path
    $storeAlias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
    if ($pwsh -like '*\WindowsApps\Microsoft.PowerShell_*' -and
        (Test-Path -LiteralPath $storeAlias)) { $pwsh = $storeAlias }
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute $pwsh -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -File "' + $installedScript + '" -Run') -WorkingDirectory $installDir
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 3)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host '配置完成。下线后运行 Start-ScheduledTask -TaskName CampusNet-AutoLogin 立即测试。'
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
    if (-not (Test-Path -LiteralPath $credentialPath)) {
        $result.status = 'credential_missing'
        return
    }

    $result.status = 'browser_unavailable'
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $edgePath = Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'
    if (-not (Test-Path -LiteralPath $edgePath)) { return }
    Start-Process -FilePath $edgePath -ArgumentList ('"' + $probe.PortalUri.AbsoluteUri + '"')

    $result.status = 'portal_form_unavailable'
    $buttonType = [System.Windows.Automation.ControlType]::Button
    $editType = [System.Windows.Automation.ControlType]::Edit
    $tabOpened = $false
    for ($i = 0; $i -lt 30; $i++) {
        $doc = Find-PortalDocument $probe.PortalUri
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
    Initialize-PortalKeyboard
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
    $doc = Find-PortalDocument $probe.PortalUri
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
    }
} catch {
    # UI automation exceptions can contain page text. Keep the current stage only.
    $result.errorType = $_.Exception.GetType().Name
} finally {
    $result.finishedAt = [DateTimeOffset]::Now.ToString('o')
    $tempLog = "$logPath.$PID.tmp"
    $result | ConvertTo-Json | Set-Content -LiteralPath $tempLog -Encoding utf8
    [IO.File]::Move($tempLog, $logPath, $true)
}
