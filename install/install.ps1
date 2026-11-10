<#
=============================================================================
 Alisa — installation (ou mise à jour) d'un agent ou d'un proxy sous Windows
-----------------------------------------------------------------------------
 À lancer dans PowerShell **en administrateur** :

   Agent :
     & ([scriptblock]::Create((irm https://raw.githubusercontent.com/cganiddle/alisa-releases/main/install/install.ps1))) -Component agent

   Proxy :
     & ([scriptblock]::Create((irm https://raw.githubusercontent.com/cganiddle/alisa-releases/main/install/install.ps1))) -Component proxy

 Aucun secret à fournir : le nœud s'annonce au serveur central et affiche un code
 de vérification. Approuvez-le (proxy) ou associez-le à un proxy (agent) dans
 l'interface Alisa, en vérifiant ce code.

 Options : -Server hôte:port (défaut alisa.netmonitoring.be:5443), -Version vX.Y.Z
           (défaut : dernière version), -CaFile <CA du serveur central>,
           -Listen ":5100" (proxy), -ProxyTls / -ProxyCaFile <chemin> (agent : le
           proxy présente un certificat), -ForceConfig (réécrit la configuration).

 Relancer le script met à jour le binaire et redémarre le service, en conservant
 la configuration et l'identité du nœud. Le binaire téléchargé est vérifié avec
 SHA256SUMS ; ensuite, les mises à jour sont automatiques.
=============================================================================
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('agent', 'proxy')][string]$Component,
    [string]$Server = 'alisa.netmonitoring.be:5443',
    [string]$Listen = ':5100',
    [string]$Version = 'latest',
    [string]$CaFile,
    [switch]$ProxyTls,
    [string]$ProxyCaFile,
    [switch]$ForceConfig
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Repo = 'cganiddle/alisa-releases'

function Info([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }

# Lance le binaire Alisa et renvoie son code de sortie, sans afficher sa sortie.
# Windows PowerShell 5.1 transforme toute écriture sur stderr d'un programme natif en
# erreur bloquante quand ErrorActionPreference = Stop : on l'assouplit le temps de l'appel.
function Invoke-Alisa([string[]]$Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $binPath @Arguments 2>&1 | Out-Null
        return $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
}

# Valeurs entre guillemets simples YAML (une apostrophe est doublée).
function Quote([string]$Value) { "'" + $Value.Replace("'", "''") + "'" }

# --- Prérequis ------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Lancez PowerShell en administrateur.'
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if ($ProxyCaFile) { $ProxyTls = $true }

$arch = switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { 'amd64' }
    'ARM64' { 'arm64' }
    default { throw "Architecture non prise en charge : $env:PROCESSOR_ARCHITECTURE" }
}
if ($Component -eq 'proxy' -and $arch -ne 'amd64') { throw 'Le proxy Windows est publié pour amd64 uniquement.' }

$binName    = "alisa-$Component"
$asset      = "$binName-windows-$arch.exe"
$installDir = Join-Path $env:ProgramFiles 'Alisa'
$binPath    = Join-Path $installDir "$binName.exe"
$configDir  = Join-Path $env:ProgramData 'Alisa'
$configPath = Join-Path $configDir "$Component.yaml"

# --- Téléchargement vérifié ------------------------------------------------------------
if ($env:ALISA_DOWNLOAD_BASE) { $base = $env:ALISA_DOWNLOAD_BASE }
elseif ($Version -eq 'latest') { $base = "https://github.com/$Repo/releases/latest/download" }
else { $base = "https://github.com/$Repo/releases/download/$Version" }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("alisa-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    Info "Téléchargement de $asset ($Version)"
    Invoke-WebRequest -UseBasicParsing -Uri "$base/$asset" -OutFile (Join-Path $tmp $asset)
    Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS" -OutFile (Join-Path $tmp 'SHA256SUMS')

    $line = Get-Content (Join-Path $tmp 'SHA256SUMS') | Where-Object { ($_ -split '\s+')[1] -in @($asset, "*$asset") } | Select-Object -First 1
    if (-not $line) { throw "$asset absent de SHA256SUMS" }
    $expected = ($line -split '\s+')[0].ToLowerInvariant()
    $actual = (Get-FileHash -Algorithm SHA256 (Join-Path $tmp $asset)).Hash.ToLowerInvariant()
    if ($expected -ne $actual) { throw "Empreinte SHA-256 invalide pour $asset : fichier corrompu ou altéré." }
    Info 'Empreinte SHA-256 vérifiée'

    # --- Dossiers et droits ------------------------------------------------------------
    # ProgramData\Alisa contient l'identité du nœud (secret) : accès réservé aux
    # administrateurs et à SYSTEM. SID plutôt que noms (localisés selon la langue de Windows).
    New-Item -ItemType Directory -Force -Path $configDir, $installDir | Out-Null
    icacls $configDir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' | Out-Null

    # --- Configuration (aucun secret) ----------------------------------------------------
    if ((Test-Path $configPath) -and -not $ForceConfig) {
        Info "Configuration existante conservée : $configPath"
    }
    else {
        $date = Get-Date -Format 'yyyy-MM-dd HH:mm'
        $serverTls = if ($CaFile) { "server_tls:`n  ca_file: $(Quote $CaFile)" } else { 'server_tls: {}   # magasin de certificats du système' }
        if ($Component -eq 'proxy') {
            $yaml = @"
# Configuration du proxy Alisa — générée par install.ps1 le $date.
server_address: $(Quote $Server)
$serverTls
listen: $(Quote $Listen)
cache_dir: $(Quote (Join-Path $configDir 'proxy-cache'))
spool_max_mb: 256
log_level: info
"@
        }
        else {
            if ($ProxyTls) {
                $proxyBlock = "proxy_tls:`n  enabled: true"
                if ($ProxyCaFile) { $proxyBlock += "`n  ca_file: $(Quote $ProxyCaFile)" }
            }
            else { $proxyBlock = "proxy_tls:`n  enabled: false   # proxy sans certificat : réseau local de confiance uniquement" }
            $yaml = @"
# Configuration de l'agent Alisa — générée par install.ps1 le $date.
server_address: $(Quote $Server)
$serverTls
$proxyBlock
buffer_max: 10000
scripts:
  enabled: false
  allowed_commands: []
  allowed_dirs: []
log_level: info
"@
        }
        Info "Écriture de la configuration : $configPath"
        [IO.File]::WriteAllText($configPath, $yaml, (New-Object Text.UTF8Encoding($false)))
    }

    # --- Binaire + service ---------------------------------------------------------------
    if (Test-Path $binPath) {
        Info 'Arrêt du service existant'
        Invoke-Alisa @('stop') | Out-Null
    }
    Copy-Item -Force (Join-Path $tmp $asset) $binPath
    Remove-Item -Force -ErrorAction SilentlyContinue "$binPath.old", "$binPath.failed"
    Info ("Installé : " + (& $binPath version))

    # Le service est créé avec la relance automatique en cas d'échec (nécessaire à
    # l'auto-mise à jour, qui se termine en erreur pour être relancée).
    if ((Invoke-Alisa @('install', '-config', $configPath)) -eq 0) { Info "Service $binName créé" }
    else { Info "Service $binName déjà présent" }
    if ((Invoke-Alisa @('start')) -ne 0 -and (Invoke-Alisa @('restart')) -ne 0) {
        throw "Le service ne démarre pas. Diagnostic : & '$binPath' run -config '$configPath'"
    }

    # --- Code de vérification ------------------------------------------------------------
    $enrollment = $null
    for ($i = 0; $i -lt 20 -and -not $enrollment; $i++) {
        Start-Sleep -Seconds 1
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $out = & $binPath enrollment -config $configPath 2>$null
        if ($LASTEXITCODE -eq 0) { $enrollment = ($out -join "`n") }
        $ErrorActionPreference = $previous
    }
    Write-Host ''
    if ($enrollment) {
        Write-Host ('─' * 62)
        Write-Host $enrollment -ForegroundColor Yellow
        Write-Host ('─' * 62)
        if ($Component -eq 'proxy') { Write-Host "→ Approuvez ce proxy dans l'interface Alisa (Proxies → En attente)" }
        else { Write-Host "→ Associez cet agent à un proxy dans l'interface Alisa (Hôtes → En attente)" }
        Write-Host "  en vérifiant que le code affiché est identique. Pour le revoir : & '$binPath' enrollment"
    }
    else {
        Write-Warning "Code de vérification pas encore disponible : & '$binPath' enrollment"
    }
    Write-Host ''
    Get-Service $binName | Format-Table -AutoSize Name, Status, StartType
    if ($Component -eq 'agent') {
        Write-Host "Journal : Get-Content '$configDir\agent.log' -Wait"
        Write-Host "L'agent doit pouvoir joindre $Server (enrôlement), puis son proxy (port 5100)."
    }
    else {
        Write-Host "Pensez à ouvrir le port $($Listen.Split(':')[-1]) (TCP) aux agents dans le pare-feu Windows."
        Write-Host "Traps SNMP et syslog (si activés dans l'interface) : ouvrez aussi UDP 162 et UDP/TCP 514 aux équipements."
    }
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
