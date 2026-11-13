#Requires -Version 5.1
[CmdletBinding()]
param(
    # Chrome passes the extension origin through the .cmd wrapper in the live
    # Windows host setup. The remaining native-messaging argument is normally
    # --parent-window=<HWND>; accept it but never use caller-supplied PIDs.
    [Parameter(Position = 0)][string]$Origin,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$RemainingArguments
)

# PowerShell 5.1 native-messaging host. stdout is reserved for framed JSON.
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$script:MaxFrameBytes = 1024 * 1024
$script:ReadTimeoutMilliseconds = 5000
$script:Utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$script:State = [pscustomobject]@{
    Armed = $false
    Used = $false
    ChromePid = $null
    BrowserOrigin = $null
    HelperPids = @()
    BaselineWindows = @{}
}
$script:UiReady = $false
$script:UiError = $null

function Send-Response {
    param([Parameter(Mandatory = $true)]$Value)
    $json = $Value | ConvertTo-Json -Compress -Depth 4
    $payload = $script:Utf8Strict.GetBytes($json)
    $length = [BitConverter]::GetBytes([uint32]$payload.Length)
    $output = [Console]::OpenStandardOutput()
    try {
        $output.Write($length, 0, 4)
        $output.Write($payload, 0, $payload.Length)
        $output.Flush()
    }
    finally { $output.Dispose() }
}
function Send-Failure {
    param([Parameter(Mandatory = $true)][string]$Error, [Parameter(Mandatory = $true)][string]$Message)
    Send-Response ([pscustomobject]@{ ok = $false; error = $Error; message = $Message })
}
function Read-Exact {
    param([Parameter(Mandatory = $true)]$Stream, [Parameter(Mandatory = $true)][byte[]]$Buffer, [Parameter(Mandatory = $true)][int]$Count)
    $offset = 0
    while ($offset -lt $Count) {
        $read = $Stream.Read($Buffer, $offset, $Count - $offset)
        if ($read -le 0) { return $false }
        $offset += $read
    }
    return $true
}
function Read-Request {
    param([Parameter(Mandatory = $true)]$Stream)
    $header = New-Object byte[] 4
    if (-not (Read-Exact -Stream $Stream -Buffer $header -Count 4)) { return $null }
    $length = [BitConverter]::ToUInt32($header, 0)
    if ($length -gt $script:MaxFrameBytes) {
        return [pscustomobject]@{ Invalid = $true; Error = 'protocol-too-large'; Message = 'The native message was too large.' }
    }
    $payload = New-Object byte[] ([int]$length)
    if (-not (Read-Exact -Stream $Stream -Buffer $payload -Count ([int]$length))) {
        return [pscustomobject]@{ Invalid = $true; Error = 'protocol-truncated'; Message = 'The native message ended early.' }
    }
    try { $jsonText = $script:Utf8Strict.GetString($payload) }
    catch { return [pscustomobject]@{ Invalid = $true; Error = 'invalid-utf8'; Message = 'The native message was not valid UTF-8.' } }
    try { $request = ConvertFrom-Json -InputObject $jsonText }
    catch { return [pscustomobject]@{ Invalid = $true; Error = 'invalid-json'; Message = 'The native message was not valid JSON.' } }
    if ($null -eq $request -or $request -is [array] -or $null -eq $request.PSObject.Properties['type'] -or $request.type -isnot [string] -or [string]::IsNullOrWhiteSpace($request.type)) {
        return [pscustomobject]@{ Invalid = $true; Error = 'invalid-request'; Message = 'The native request needs a type.' }
    }
    return $request
}

function Ensure-UiAutomation {
    if ($script:UiReady) { return $true }
    if ($null -ne $script:UiError) { return $false }
    try {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
        $script:UiReady = $true
        return $true
    } catch {
        $script:UiError = $_.Exception.Message
        return $false
    }
}
function Get-ProcessSnapshot {
    try { return @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, ExecutablePath, CommandLine) }
    catch { try { return @(Get-WmiObject Win32_Process -Property ProcessId, ParentProcessId, Name, ExecutablePath, CommandLine) } catch { return @() } }
}
function Test-ChromeExecutable {
    param([AllowNull()][string]$Path)
    return (-not [string]::IsNullOrWhiteSpace($Path) -and $Path -match '(?i)\\Google\\Chrome\\Application\\chrome\.exe$')
}
function Test-AppleHelperExecutable {
    param([AllowNull()][string]$Name, [AllowNull()][string]$Path)
    if ($Name -ine 'iCloudPasswordsExtensionHelper.exe' -and $Name -ine 'iCloudPasswordsExtensionHelper') { return $false }
    return (-not [string]::IsNullOrWhiteSpace($Path) -and $Path -match '(?i)\\(?:WindowsApps\\AppleInc\.iCloud_[^\\]+_nzyj5cx40ttqa(?:\\iCloud)?|Common Files\\Apple\\Internet Services)\\iCloudPasswordsExtensionHelper\.exe$')
}
function Get-ProcessById {
    param([Parameter(Mandatory = $true)]$Snapshot, [Parameter(Mandatory = $true)][uint32]$Id)
    foreach ($process in @($Snapshot)) {
        if ([uint32]$process.ProcessId -eq $Id) { return $process }
    }
    return $null
}
function Get-ChromeAncestor {
    param([Parameter(Mandatory = $true)]$Snapshot, [Parameter(Mandatory = $true)][uint32]$StartPid)
    $seen = @{}
    $current = $StartPid
    while ($current -ne 0 -and -not $seen.ContainsKey($current)) {
        $seen[$current] = $true
        $process = Get-ProcessById -Snapshot $Snapshot -Id $current
        if ($null -eq $process) { return $null }
        if (([string]$process.Name -ieq 'chrome.exe' -or [string]$process.Name -ieq 'chrome') -and
            (Test-ChromeExecutable -Path ([string]$process.ExecutablePath))) {
            return [uint32]$process.ProcessId
        }
        $current = [uint32]$process.ParentProcessId
    }
    return $null
}
function Get-CommandLineOrigin {
    param([AllowNull()][string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $null }
    $matches = [regex]::Matches($CommandLine, '(?:\A|[\s"])((?:chrome-extension://)[a-p]{32}/)(?=\z|[\s"])')
    if ($matches.Count -ne 1) { return $null }
    return $matches[0].Groups[1].Value
}
function Get-HelperProcesses {
    param([Parameter(Mandatory = $true)]$Snapshot, [Parameter(Mandatory = $true)][uint32]$ChromePid, [Parameter(Mandatory = $true)][string]$Origin)
    $helpers = @()
    foreach ($process in @($Snapshot)) {
        if (-not (Test-AppleHelperExecutable -Name ([string]$process.Name) -Path ([string]$process.ExecutablePath))) { continue }
        if ((Get-ChromeAncestor -Snapshot $Snapshot -StartPid ([uint32]$process.ProcessId)) -ne $ChromePid) { continue }
        if ((Get-CommandLineOrigin -CommandLine ([string]$process.CommandLine)) -cne $Origin) { continue }
        $helpers += $process
    }
    return $helpers
}

function Get-DialogCandidates {
    param([Parameter(Mandatory = $true)][uint32[]]$HelperPids, [hashtable]$ExcludeWindows = @{}, [switch]$Baseline)
    $desktop = [System.Windows.Automation.AutomationElement]::RootElement
    $any = [System.Windows.Automation.Condition]::TrueCondition
    $dialogClass = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty, '#32770')
    $textType = [System.Windows.Automation.ControlType]::Text
    $buttonType = [System.Windows.Automation.ControlType]::Button
    $paneType = [System.Windows.Automation.ControlType]::Pane
    $codeShape = '\A[0-9]{3}\p{Zs}[0-9]{3}\z'
    $candidates = @()
    try {
        foreach ($dialog in $desktop.FindAll('Children', $dialogClass)) {
            try {
                $window = $dialog.Current
                $windowPid = [uint32]$window.ProcessId
                $windowHandle = [uint32]$window.NativeWindowHandle
                $windowKey = "${windowPid}:$windowHandle"
                if ($window.IsOffscreen -or $windowHandle -eq 0 -or $windowPid -notin $HelperPids -or $ExcludeWindows.ContainsKey($windowKey)) { continue }
                if ($Baseline) {
                    $candidates += $windowKey
                    continue
                }
                $hasPrompt = $false
                $hasDismiss = $false
                $codeControls = 0
                $pin = $null
                foreach ($child in $dialog.FindAll('Children', $any)) {
                    $info = $child.Current
                    if ($info.IsOffscreen -or [uint32]$info.ProcessId -ne $windowPid) { continue }
                    if (($info.ControlType -eq $textType -or $info.ControlType -eq $paneType) -and [string]$info.Name -match '(?i)\bEnter\s+this\s+verification\s+code\b.*?\bChrome\s+extension\b') { $hasPrompt = $true }
                    elseif (($info.ControlType -eq $buttonType -or $info.ControlType -eq $paneType) -and [string]$info.Name -ceq 'Dismiss') { $hasDismiss = $true }
                    elseif (($info.ControlType -eq $textType -or $info.ControlType -eq $paneType) -and [string]$info.Name -cmatch $codeShape) {
                        $codeControls++
                        $pin = ([string]$info.Name) -replace '\p{Zs}', ''
                    }
                }
                if ($hasPrompt -and $hasDismiss -and $codeControls -eq 1 -and $pin -match '\A[0-9]{6}\z') {
                    $candidates += [pscustomobject]@{ Code = $pin }
                }
            } catch { continue }
        }
    } catch { return @() }
    return $candidates
}
function Get-ChromeForHost {
    $snapshot = @(Get-ProcessSnapshot)
    $chromePid = Get-ChromeAncestor -Snapshot $snapshot -StartPid ([uint32]$PID)
    if ($null -eq $chromePid) { return $null }
    return [pscustomobject]@{ Pid = [uint32]$chromePid; Origin = $script:BrowserOrigin; Snapshot = $snapshot }
}
function Invoke-Arm {
    if ($script:State.Used) { return [pscustomobject]@{ ok = $false; error = 'already-used'; message = 'Pairing is already complete; reconnect the native host.' } }
    if ($script:State.Armed) { return [pscustomobject]@{ ok = $false; error = 'already-armed'; message = 'Pairing is already waiting for its verification code.' } }
    $browser = Get-ChromeForHost
    if ($null -eq $browser) { return [pscustomobject]@{ ok = $false; error = 'browser-not-chrome'; message = 'Open Better Passwords from Google Chrome to pair.' } }
    if ([string]::IsNullOrWhiteSpace($browser.Origin)) { return [pscustomobject]@{ ok = $false; error = 'browser-origin-missing'; message = 'Chrome did not identify the Better Passwords extension.' } }
    if (-not (Ensure-UiAutomation)) { return [pscustomobject]@{ ok = $false; error = 'ui-unavailable'; message = 'Windows accessibility is unavailable for the iCloud dialog.' } }
    $helpers = @(Get-HelperProcesses -Snapshot $browser.Snapshot -ChromePid $browser.Pid -Origin $browser.Origin)
    if ($helpers.Count -eq 0) {
        return [pscustomobject]@{ ok = $false; error = 'helper-not-found'; message = 'Could not find the iCloud helper for this extension. Enter the code manually.' }
    }
    $helperPids = @($helpers | ForEach-Object { [uint32]$_.ProcessId })
    $baseline = @{}
    foreach ($windowKey in @(Get-DialogCandidates -HelperPids $helperPids -Baseline)) {
        $baseline[$windowKey] = $true
    }
    $script:State.Armed = $true
    $script:State.ChromePid = $browser.Pid
    $script:State.BrowserOrigin = $browser.Origin
    $script:State.HelperPids = $helperPids
    $script:State.BaselineWindows = $baseline
    return [pscustomobject]@{ ok = $true }
}
function Invoke-ReadCode {
    if (-not $script:State.Armed -or $script:State.Used) { return [pscustomobject]@{ ok = $false; error = 'not-armed'; message = 'Pairing must be armed before reading its verification code.' } }
    $script:State.Armed = $false
    $script:State.Used = $true
    $deadline = [DateTime]::UtcNow.AddMilliseconds($script:ReadTimeoutMilliseconds)
    try {
        while ([DateTime]::UtcNow -lt $deadline) {
            $browser = Get-ChromeForHost
            if ($null -eq $browser -or $browser.Pid -ne $script:State.ChromePid -or $browser.Origin -cne $script:State.BrowserOrigin) {
                return [pscustomobject]@{ ok = $false; error = 'browser-not-chrome'; message = 'The original Chrome browser is no longer connected.' }
            }
            $helpers = @(Get-HelperProcesses -Snapshot $browser.Snapshot -ChromePid $browser.Pid -Origin $browser.Origin)
            $helperPids = @($helpers | ForEach-Object { [uint32]$_.ProcessId } | Where-Object { $_ -in $script:State.HelperPids })
            if ($helperPids.Count -eq 0) {
                return [pscustomobject]@{ ok = $false; error = 'helper-changed'; message = 'The iCloud helper changed during pairing. Enter the code manually.' }
            }
            $candidates = @(Get-DialogCandidates -HelperPids $helperPids -ExcludeWindows $script:State.BaselineWindows)
            if ($candidates.Count -eq 1) { return [pscustomobject]@{ ok = $true; code = [string]$candidates[0].Code } }
            if ($candidates.Count -gt 1) { return [pscustomobject]@{ ok = $false; error = 'ambiguous-code'; message = 'More than one new iCloud verification dialog is open.' } }
            Start-Sleep -Milliseconds 50
        }
        return [pscustomobject]@{ ok = $false; error = 'no-code'; message = 'No new iCloud verification code appeared in Chrome.' }
    } finally {
        $script:State.BaselineWindows = @{}
        $script:State.ChromePid = $null
        $script:State.BrowserOrigin = $null
        $script:State.HelperPids = @()
    }
}
function Invoke-Request {
    param([Parameter(Mandatory = $true)]$Request)
    if ($Request.PSObject.Properties['Invalid']) { return [pscustomobject]@{ ok = $false; error = [string]$Request.Error; message = [string]$Request.Message } }
    switch ([string]$Request.type) { 'hello' { return [pscustomobject]@{ ok = $true } }; 'arm' { return Invoke-Arm }; 'read-code' { return Invoke-ReadCode }; default { return [pscustomobject]@{ ok = $false; error = 'unknown-request'; message = 'The native request type is not supported.' } } }
}

$forwardedArguments = @()
if ($null -ne $Origin) { $forwardedArguments += $Origin }
if ($null -ne $RemainingArguments) { $forwardedArguments += $RemainingArguments }
$script:BrowserOrigin = Get-CommandLineOrigin -CommandLine ($forwardedArguments -join ' ')
$inputStream = [Console]::OpenStandardInput()
try {
    while ($true) {
        $request = Read-Request -Stream $inputStream
        if ($null -eq $request) { break }
        try {
            Send-Response -Value (Invoke-Request -Request $request)
        } catch {
            Send-Failure -Error 'internal-error' -Message 'The Windows pairing host could not complete the request.'
        }
        # Each port can serve one pairing attempt. Chrome starts a new host next time.
        if ($request.PSObject.Properties['type'] -and $request.type -ceq 'read-code') { break }
    }
} finally {
    $inputStream.Dispose()
}
