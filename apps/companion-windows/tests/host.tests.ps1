#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$hostCmd = Join-Path $root 'host.cmd'

function Assert-Equal { param($Actual, $Expected, [string]$Name)
    if ($Actual -cne $Expected) { throw "$Name`: expected '$Expected', got '$Actual'" }
}
function Read-Exact { param($Stream, [byte[]]$Buffer, [int]$Count)
    $offset = 0; while ($offset -lt $Count) { $read = $Stream.Read($Buffer, $offset, $Count - $offset); if ($read -le 0) { throw 'host closed its output unexpectedly' }; $offset += $read }
}
function Send-Frame { param($Stream, [byte[]]$Payload)
    $Stream.Write([BitConverter]::GetBytes([uint32]$Payload.Length), 0, 4); $Stream.Write($Payload, 0, $Payload.Length); $Stream.Flush()
}
function Read-Frame { param($Stream)
    $header = New-Object byte[] 4; Read-Exact $Stream $header 4
    $payload = New-Object byte[] ([int][BitConverter]::ToUInt32($header, 0)); Read-Exact $Stream $payload $payload.Length
    return ([Text.Encoding]::UTF8.GetString($payload) | ConvertFrom-Json)
}

$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = $env:ComSpec
$psi.Arguments = '/d /s /c ""' + $hostCmd + '""'
$psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
$process = New-Object Diagnostics.Process; $process.StartInfo = $psi
if (-not $process.Start()) { throw 'could not start host.cmd' }
try {
    $input = $process.StandardInput.BaseStream; $output = $process.StandardOutput.BaseStream
    $hello = [Text.Encoding]::UTF8.GetBytes('{"type":"hello"}'); Send-Frame $input $hello
    Assert-Equal (Read-Frame $output).ok $true 'hello'

    Send-Frame $input ([byte[]](0x7b, 0xff, 0x7d))
    $invalid = Read-Frame $output; Assert-Equal $invalid.ok $false 'invalid UTF-8 result'; Assert-Equal $invalid.error 'invalid-utf8' 'invalid UTF-8 error'

    Send-Frame $input ([Text.Encoding]::UTF8.GetBytes('{"type":"arm"}'))
    $arm = Read-Frame $output; Assert-Equal $arm.ok $false 'non-Chrome arm result'; Assert-Equal $arm.error 'browser-not-chrome' 'non-Chrome arm error'

    Send-Frame $input ([Text.Encoding]::UTF8.GetBytes('{"type":"read-code"}'))
    Assert-Equal (Read-Frame $output).error 'not-armed' 'read without an active attempt'
    Assert-Equal ($process.WaitForExit(3000)) $true 'host exits after the read response with stdin still open'
    Write-Output 'host protocol tests passed'
} finally {
    if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
    $process.Dispose()
}
