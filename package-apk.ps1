param(
    [string]$OutputDirectory = "tmp",
    [string]$FlutterExecutable = "",
    [string]$JavaHome = "",
    [switch]$SkipTests
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Flutter {
    param([string[]]$Arguments)

    & $script:flutterExe @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "Flutter command failed with exit code $LASTEXITCODE."
    }
}

function Get-LocalProperty {
    param(
        [string[]]$Lines,
        [string]$Name
    )

    $prefix = "$Name="

    foreach ($line in $Lines) {
        if ($line.StartsWith($prefix, [StringComparison]::Ordinal)) {
            return $line.Substring($prefix.Length).Replace('\\', '\')
        }
    }

    return ""
}

$repoRoot = $PSScriptRoot
$flutterRoot = Join-Path $repoRoot "flutter_app"
$pubspecPath = Join-Path $flutterRoot "pubspec.yaml"
$localPropertiesPath = Join-Path $flutterRoot "android\local.properties"

if (-not (Test-Path -LiteralPath $pubspecPath -PathType Leaf)) {
    throw "Run this script from an ezBookkeeping source checkout."
}

$localProperties = if (Test-Path -LiteralPath $localPropertiesPath -PathType Leaf) {
    Get-Content -LiteralPath $localPropertiesPath
} else {
    @()
}

if (-not $FlutterExecutable) {
    $configuredFlutterSdk = Get-LocalProperty -Lines $localProperties -Name "flutter.sdk"

    if ($configuredFlutterSdk) {
        $FlutterExecutable = Join-Path $configuredFlutterSdk "bin\flutter.bat"
    } elseif ($env:FLUTTER_ROOT) {
        $FlutterExecutable = Join-Path $env:FLUTTER_ROOT "bin\flutter.bat"
    } else {
        $flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue

        if ($flutterCommand) {
            $FlutterExecutable = $flutterCommand.Source
        }
    }
}

if (-not $FlutterExecutable -or -not (Test-Path -LiteralPath $FlutterExecutable -PathType Leaf)) {
    throw 'Flutter was not found. Pass -FlutterExecutable or configure flutter.sdk in flutter_app\android\local.properties.'
}

$script:flutterExe = [IO.Path]::GetFullPath($FlutterExecutable)
$configuredAndroidSdk = Get-LocalProperty -Lines $localProperties -Name "sdk.dir"

if (-not $env:ANDROID_HOME -and $configuredAndroidSdk) {
    $env:ANDROID_HOME = $configuredAndroidSdk
}

if (-not $env:ANDROID_SDK_ROOT -and $env:ANDROID_HOME) {
    $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
}

if ($JavaHome) {
    $env:JAVA_HOME = [IO.Path]::GetFullPath($JavaHome)
} elseif (-not $env:JAVA_HOME -and (Test-Path -LiteralPath "D:\DEV-TOOLS\jdk21" -PathType Container)) {
    $env:JAVA_HOME = "D:\DEV-TOOLS\jdk21"
}

$pubspecContent = Get-Content -LiteralPath $pubspecPath -Raw
$versionMatch = [regex]::Match($pubspecContent, '(?m)^version:\s*([^\s#]+)')

if (-not $versionMatch.Success) {
    throw "Could not read the application version from $pubspecPath."
}

$applicationVersion = $versionMatch.Groups[1].Value
$outputRoot = if ([IO.Path]::IsPathRooted($OutputDirectory)) {
    [IO.Path]::GetFullPath($OutputDirectory)
} else {
    [IO.Path]::GetFullPath((Join-Path $repoRoot $OutputDirectory))
}
$sourceApk = Join-Path $flutterRoot "build\app\outputs\flutter-apk\app-release.apk"
$targetApk = Join-Path $outputRoot "ezbookkeeping-$applicationVersion-release.apk"

Push-Location $flutterRoot

try {
    Invoke-Flutter @("pub", "get", "--enforce-lockfile")
    Invoke-Flutter @("analyze", "--no-pub")

    if (-not $SkipTests) {
        Invoke-Flutter @("test", "--no-pub", "--reporter", "compact")
    }

    Invoke-Flutter @("build", "apk", "--release", "--no-pub")
} finally {
    Pop-Location
}

$currentPubspecContent = Get-Content -LiteralPath $pubspecPath -Raw
$currentVersionMatch = [regex]::Match($currentPubspecContent, '(?m)^version:\s*([^\s#]+)')

if (-not $currentVersionMatch.Success -or $currentVersionMatch.Groups[1].Value -ne $applicationVersion) {
    throw "The application version changed during packaging."
}

if (-not (Test-Path -LiteralPath $sourceApk -PathType Leaf)) {
    throw "Release APK was not produced at $sourceApk."
}

[IO.Directory]::CreateDirectory($outputRoot) | Out-Null
Copy-Item -LiteralPath $sourceApk -Destination $targetApk -Force

$artifact = Get-Item -LiteralPath $targetApk
$sha256 = (Get-FileHash -LiteralPath $targetApk -Algorithm SHA256).Hash

Write-Host ""
Write-Host "APK:     $targetApk"
Write-Host "Version: $applicationVersion"
Write-Host "Size:    $([math]::Round($artifact.Length / 1MB, 2)) MiB"
Write-Host "SHA-256: $sha256"
