# Soty relay installer for Windows.
#
# The relay host is a Linux x86-64 binary, so Windows runs it in a small
# Docker container (Docker Desktop). No admin rights are needed when Docker
# is already installed; -InstallDocker uses winget and requires admin.
#
#   powershell -ExecutionPolicy Bypass -File .\install-relay-windows.ps1
#   powershell -ExecutionPolicy Bypass -File .\install-relay-windows.ps1 `
#       -Port 3100 -Announce wss://relay.example.com/soty-ws
#   powershell -ExecutionPolicy Bypass -File .\install-relay-windows.ps1 -InstallDocker
#   powershell -ExecutionPolicy Bypass -File .\install-relay-windows.ps1 -Uninstall [-Purge]

[CmdletBinding()]
param(
    [int]$Port = 3100,
    [string]$Listen = "0.0.0.0",
    [string]$Announce = "",
    [string[]]$Peer = @(),
    [string]$Name = "soty-host",
    [string]$Version = "",
    [string]$Url = "",
    [string]$DataDir = "",
    [switch]$InstallDocker,
    [switch]$NoVerify,
    [switch]$NoService,
    [switch]$Uninstall,
    [switch]$Purge
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Fail([string]$Message) { Write-Host "error: $Message" -ForegroundColor Red; exit 1 }

if (-not $DataDir) {
    $DataDir = Join-Path $env:LOCALAPPDATA "Soty\relay"
}

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

function Test-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    & cmd.exe /c "docker info >nul 2>&1" | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Start-DockerDaemon {
    $desktop = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
    if (Test-Path $desktop) {
        Write-Step "запускаю Docker Desktop"
        Start-Process -FilePath $desktop | Out-Null
        for ($i = 0; $i -lt 60; $i++) {
            if (Test-Docker) { return $true }
            Start-Sleep -Seconds 2
        }
    }
    return $false
}

$Image = "soty-host:local"
$ImageDir = Join-Path $DataDir "image"
$DataSub = Join-Path $DataDir "data"
$Binary = Join-Path $ImageDir "dtm_host"
$Dockerfile = Join-Path $ImageDir "Dockerfile"

function Invoke-Uninstall {
    Write-Step "удаляю контейнер $Name"
    try { & docker rm -f $Name 2>&1 | Out-Null } catch { }
    try { & docker rmi $Image 2>&1 | Out-Null } catch { }
    Remove-Item -Force -ErrorAction SilentlyContinue $Binary, $Dockerfile
    if ($Purge) {
        Write-Step "удаляю данные: $DataDir"
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $DataDir
    } else {
        Write-Host "    данные сохранены: $DataSub (удалить: -Purge)"
    }
    Write-Host "==> удалено"
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    if ($InstallDocker) {
        if (-not $IsAdmin) {
            Fail "для установки Docker Desktop запусти PowerShell от администратора (или поставь Docker вручную)"
        }
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Fail "winget не найден. Поставь Docker Desktop: https://www.docker.com/products/docker-desktop/"
        }
        Write-Step "устанавливаю Docker Desktop через winget"
        & winget install -e --id Docker.DockerDesktop --silent --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { Fail "winget не смог установить Docker Desktop (код $LASTEXITCODE)" }
        Write-Host "Docker Desktop установлен. Запусти его (возможно, потребуется перезагрузка) и повтори скрипт."
        exit 0
    }
    Write-Host @"
Docker не найден. Варианты:
  1) Docker Desktop: https://www.docker.com/products/docker-desktop/
     затем повтори этот скрипт.
  2) С правами администратора:
     powershell -ExecutionPolicy Bypass -File .\install-relay-windows.ps1 -InstallDocker
"@ -ForegroundColor Yellow
    exit 2
}

if (-not (Test-Docker)) {
    if (-not (Start-DockerDaemon)) { Fail "Docker daemon не запущен" }
}

$osType = ""
try { $osType = (& docker info --format "{{.OSType}}" 2>$null | Out-String).Trim() } catch { }
if ($osType -and $osType -ne "linux") {
    Fail "Docker Desktop работает в режиме Windows containers; переключи его на Linux containers"
}

if ($Uninstall) {
    Invoke-Uninstall
    exit 0
}

New-Item -ItemType Directory -Force -Path $ImageDir, $DataSub | Out-Null
$TmpDir = Join-Path ([IO.Path]::GetTempPath()) ("soty-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $TmpDir | Out-Null
$TmpBin = Join-Path $TmpDir "dtm_host"
$TmpJson = Join-Path $TmpDir "release.json"

try {
    $tag = ""
    if ($Version) { $tag = "v" + ($Version -replace "^[vV]", "") }

    if (-not $Url) {
        if ($tag) {
            $encTag = $tag.Replace("+", "%2B")
            $Url = "https://github.com/slavabars/soty/releases/download/$encTag/dtm_host.bin"
            $Api = "https://api.github.com/repos/slavabars/soty/releases/tags/$encTag"
        } else {
            $Url = "https://github.com/slavabars/soty/releases/latest/download/dtm_host.bin"
            $Api = "https://api.github.com/repos/slavabars/soty/releases/latest"
        }
    }

    Write-Step "скачиваю $Url"
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $TmpBin
    if (-not (Test-Path $TmpBin) -or (Get-Item $TmpBin).Length -eq 0) { Fail "скачался пустой файл" }

    $stream = [IO.File]::OpenRead($TmpBin)
    try {
        [byte[]]$magic = @(0, 0, 0, 0)
        $null = $stream.Read($magic, 0, 4)
    } finally {
        $stream.Close()
    }
    if (-not ($magic[0] -eq 0x7f -and $magic[1] -eq 0x45 -and $magic[2] -eq 0x4c -and $magic[3] -eq 0x46)) {
        Fail "это не ELF-бинарник Linux (получен не тот файл?)"
    }

    if (-not $NoVerify -and $Api) {
        $digest = ""
        try {
            Invoke-WebRequest -UseBasicParsing -Headers @{ "User-Agent" = "soty-installer" } -Uri $Api -OutFile $TmpJson
            $release = Get-Content -Raw $TmpJson | ConvertFrom-Json
            $asset = $release.assets | Where-Object { $_.name -eq "dtm_host.bin" } | Select-Object -First 1
            if ($asset -and $asset.digest) { $digest = ($asset.digest -replace "^sha256:", "") }
        } catch {
            Write-Host "warning: не удалось получить SHA-256 из GitHub API" -ForegroundColor Yellow
        }
        if ($digest) {
            $actual = (Get-FileHash -Algorithm SHA256 -Path $TmpBin).Hash.ToLowerInvariant()
            if ($actual -ne $digest.ToLowerInvariant()) {
                Fail "SHA-256 не совпал: $actual != $digest"
            }
            Write-Step "SHA-256 подтверждён: $actual"
        } else {
            Write-Host "warning: проверка SHA-256 пропущена" -ForegroundColor Yellow
        }
    }

    Copy-Item -Force $TmpBin $Binary
    $dockerfileText = @"
FROM --platform=linux/amd64 debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends libsqlite3-0 ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY dtm_host /usr/local/bin/dtm_host
ENTRYPOINT ["/usr/local/bin/dtm_host"]
"@
    $dockerfileText = $dockerfileText -replace "`r`n", "`n"
    [IO.File]::WriteAllText($Dockerfile, $dockerfileText, [Text.UTF8Encoding]::new($false))

    Write-Step "собираю образ $Image"
    & docker build --platform linux/amd64 -t $Image $ImageDir
    if ($LASTEXITCODE -ne 0) { Fail "docker build завершился с кодом $LASTEXITCODE" }

    $defaultAddr = "ws://$($env:COMPUTERNAME):$Port/ws"
    $addr = if ($Announce) { $Announce } else { $defaultAddr }

    $runArgs = @(
        "run", "-d", "--name", $Name, "--restart", "unless-stopped",
        "--platform", "linux/amd64",
        "-p", "${Listen}:${Port}:3100",
        "--mount", "type=bind,source=$($DataSub -replace '\\','/'),target=/data",
        $Image, "--db", "/data/host.db", "--listen", "0.0.0.0", "--port", "3100"
    )
    if ($Announce) { $runArgs += @("--announce", $Announce) }
    foreach ($p in $Peer) { $runArgs += @("--peer", $p) }

    if ($NoService) {
        Write-Host "==> образ готов: $Image"
        Write-Host "    запуск вручную:"
        Write-Host ("    docker " + ($runArgs -join " "))
        exit 0
    }

    try { & docker rm -f $Name 2>&1 | Out-Null } catch { }
    Write-Step "запускаю контейнер $Name"
    & docker @runArgs | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "docker run завершился с кодом $LASTEXITCODE" }

    $ed = ""
    for ($i = 0; $i -lt 20; $i++) {
        try { $log = (& docker logs $Name 2>&1 | Out-String) } catch { $log = "" }
        if ($log -match "ed25519\s+([0-9a-f]{64})") {
            $ed = $Matches[1]
            break
        }
        Start-Sleep -Seconds 1
    }

    $invite = ""
    if ($ed) {
        $encAddr = [Uri]::EscapeDataString($addr)
        $invite = "soty://host?addr=$encAddr&pk=$ed"
    }

    Write-Host ""
    Write-Host "==> Soty relay установлен (Windows, Docker)" -ForegroundColor Green
    Write-Host "    образ     $Image"
    Write-Host "    база      $DataSub\host.db"
    Write-Host "    endpoint  $addr"
    Write-Host "    статус    docker ps --filter name=$Name"
    Write-Host "    лог       docker logs -f $Name"
    Write-Host "    стоп      docker stop $Name"
    if ($ed) {
        Write-Host "    ed25519   $ed"
        Write-Host ""
        Write-Host "    invite для клиентов:"
        Write-Host "    $invite"
    } else {
        Write-Host "    ed25519   ещё не найден; проверь: docker logs $Name"
    }
    Write-Host ""
    Write-Host "    не удаляй ${DataSub}: в нём Ed25519-идентичность и пины клиентов"
} finally {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $TmpDir
}
