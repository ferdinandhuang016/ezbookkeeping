param(
    [string]$ImageName = "ezbookkeeping",
    [string]$Version = "2.0.0-danggui",
    [string]$OutputDirectory = "tmp",
    [string]$Platform = "linux/amd64",
    [string]$SkipTests = "TestGenerateUuids_30TimesIn3Seconds"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Docker {
    param([string[]]$Arguments)

    & docker @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "Docker command failed with exit code $LASTEXITCODE."
    }
}

$repoRoot = $PSScriptRoot
$sourceDockerfile = Join-Path $repoRoot "Dockerfile"
$packageJson = Join-Path $repoRoot "package.json"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'The "docker" command is required.'
}

if (-not (Test-Path -LiteralPath $sourceDockerfile) -or -not (Test-Path -LiteralPath $packageJson)) {
    throw "Run this script from an ezBookkeeping source checkout."
}

$applicationVersion = (Get-Content -LiteralPath $packageJson -Raw | ConvertFrom-Json).version

if (-not $Version.StartsWith("$applicationVersion-")) {
    throw "Image version '$Version' must retain application version '$applicationVersion'."
}

$imageTag = "${ImageName}:$Version"
$outputRoot = if ([IO.Path]::IsPathRooted($OutputDirectory)) {
    [IO.Path]::GetFullPath($OutputDirectory)
} else {
    [IO.Path]::GetFullPath((Join-Path $repoRoot $OutputDirectory))
}
$archivePath = Join-Path $outputRoot "$ImageName-$Version.tar"
$temporaryId = [Guid]::NewGuid().ToString("N")
$temporaryDockerfile = Join-Path $repoRoot "Dockerfile.package-$temporaryId"
$temporaryIgnore = "$temporaryDockerfile.dockerignore"
$utf8WithoutBom = [Text.UTF8Encoding]::new($false)

try {
    $dockerfileContent = [IO.File]::ReadAllText($sourceDockerfile).Replace("`r`n", "`n")
    $copyMarker = "COPY . .`n"
    $copyCount = ([regex]::Matches($dockerfileContent, [regex]::Escape($copyMarker))).Count

    if ($copyCount -ne 2) {
        throw "Expected two source COPY instructions in Dockerfile, found $copyCount."
    }

    $dockerfileContent = $dockerfileContent.Replace(
        $copyMarker,
        "$copyMarker" + "RUN find . -type f -name '*.sh' -exec sed -i 's/\r$//' {} +`n"
    )
    $entrypointCommand = "RUN chmod +x /docker-entrypoint.sh"

    if (-not $dockerfileContent.Contains($entrypointCommand)) {
        throw "Expected entrypoint permission command was not found in Dockerfile."
    }

    $dockerfileContent = $dockerfileContent.Replace(
        $entrypointCommand,
        "RUN sed -i 's/\r$//' /docker-entrypoint.sh && chmod +x /docker-entrypoint.sh"
    )

    $ignoreContent = @(
        "node_modules"
        "flutter_app"
        "artwork"
        ".planning"
        "dist"
        "tmp"
        ".ruff_cache"
        "findings.md"
        "progress.md"
        "task_plan.md"
    ) -join "`n"

    [IO.File]::WriteAllText($temporaryDockerfile, $dockerfileContent, $utf8WithoutBom)
    [IO.File]::WriteAllText($temporaryIgnore, "$ignoreContent`n", $utf8WithoutBom)
    [IO.Directory]::CreateDirectory($outputRoot) | Out-Null

    $buildUnixTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $buildDate = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $buildArguments = @(
        "build"
        "--platform", $Platform
        "--file", $temporaryDockerfile
        "--tag", $imageTag
        "--build-arg", "RELEASE_BUILD=1"
        "--build-arg", "BUILD_PIPELINE=1"
        "--build-arg", "BUILD_UNIXTIME=$buildUnixTime"
        "--build-arg", "BUILD_DATE=$buildDate"
    )

    if ($SkipTests) {
        $buildArguments += @("--build-arg", "SKIP_TESTS=$SkipTests")
    }

    $buildArguments += $repoRoot

    Write-Host "Building $imageTag for $Platform..."
    Invoke-Docker $buildArguments

    Write-Host "Saving $imageTag to $archivePath..."
    Invoke-Docker @("image", "save", "--output", $archivePath, $imageTag)
    Invoke-Docker @("image", "load", "--input", $archivePath)

    $versionOutput = & docker run --rm --entrypoint /ezbookkeeping/ezbookkeeping $imageTag --version

    if ($LASTEXITCODE -ne 0) {
        throw "Image version verification failed with exit code $LASTEXITCODE."
    }

    $archive = Get-Item -LiteralPath $archivePath
    $sha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash

    Write-Host ""
    Write-Host "Image:   $imageTag"
    Write-Host "Archive: $archivePath"
    Write-Host "Size:    $([math]::Round($archive.Length / 1MB, 2)) MiB"
    Write-Host "SHA-256: $sha256"
    Write-Host "Version: $versionOutput"
} finally {
    Remove-Item -LiteralPath $temporaryDockerfile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temporaryIgnore -Force -ErrorAction SilentlyContinue
}
