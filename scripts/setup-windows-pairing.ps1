#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$LaunchChrome
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$extensionId = 'anemmgjicegdokipehmlimfpfopckloc'
$bridgeHost = 'io.github.fanckush.betterpasswords.windows_pairing_bridge'
$pairingHost = 'io.github.fanckush.betterpasswords.windows_pairing'
$registryPath = 'HKCU:\Software\Google\Chrome\NativeMessagingHosts'
$manifestDir = Join-Path $env:LOCALAPPDATA 'Better Passwords Windows Pairing\NativeMessagingHosts'

if ($Uninstall) {
    foreach ($hostName in @($bridgeHost, $pairingHost)) {
        $key = Join-Path $registryPath $hostName
        $manifest = Join-Path $manifestDir "$hostName.json"
        if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key }
        if (Test-Path -LiteralPath $manifest) { Remove-Item -LiteralPath $manifest }
    }
    Write-Host 'Removed the Windows pairing fork registrations.'
    return
}

$bundleRoot = Split-Path -Parent $PSScriptRoot
$launcher = Join-Path $bundleRoot 'apps\companion-windows\host.cmd'
$reader = Join-Path $bundleRoot 'apps\companion-windows\host.ps1'
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf) -or
    -not (Test-Path -LiteralPath $reader -PathType Leaf)) {
    throw 'Keep the setup script and the apps folder together, then run setup again.'
}

# The Store package's execution alias survives iCloud updates. Use the package
# executable when the alias is off, as the upstream Windows setup does.
$helper = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\iCloudPasswordsExtensionHelper.exe'
if (-not ((Test-Path -LiteralPath $helper) -or [IO.File]::Exists($helper))) {
    $package = Get-AppxPackage -Name AppleInc.iCloud -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $package) {
        $helper = Join-Path $package.InstallLocation 'iCloud\iCloudPasswordsExtensionHelper.exe'
    }
    if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) {
        throw 'Install iCloud for Windows, enable Passwords, and turn on the iCloud Passwords Extension Helper app execution alias.'
    }
}

function Register-PairingHost([string]$Name, [string]$Description, [string]$Target) {
    $manifestPath = Join-Path $manifestDir "$Name.json"
    $manifest = @{
        name = $Name
        description = $Description
        path = $Target
        type = 'stdio'
        allowed_origins = @("chrome-extension://$extensionId/")
    }
    [IO.File]::WriteAllText($manifestPath, (ConvertTo-Json -InputObject $manifest), [Text.UTF8Encoding]::new($false))
    $key = Join-Path $registryPath $Name
    New-Item -Path $key -Force | Out-Null
    Set-Item -LiteralPath $key -Value $manifestPath
}

New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
Register-PairingHost $bridgeHost "Better Passwords fork: Apple's password helper" $helper
Register-PairingHost $pairingHost 'Better Passwords fork: Windows pairing code reader' $launcher
Write-Host 'Windows pairing is set up for the Better Passwords fork in Chrome.'

if ($LaunchChrome) {
    Start-Process -FilePath 'chrome.exe'
}
