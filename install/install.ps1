<#
=============================================================================
 Alisa — installation (ou mise à jour) d'un agent ou d'un proxy sous Windows
-----------------------------------------------------------------------------
 À lancer dans PowerShell **en administrateur** :

   Agent :
     & ([scriptblock]::Create((irm https://raw.githubusercontent.com/net-system-srl/alisa-releases/main/install/install.ps1))) -Component agent

   Proxy :
     & ([scriptblock]::Create((irm https://raw.githubusercontent.com/net-system-srl/alisa-releases/main/install/install.ps1))) -Component proxy

 Aucun secret à fournir : le nœud s'annonce au serveur central et affiche un code
 de vérification. Approuvez-le (proxy) ou associez-le à un proxy (agent) dans
 l'interface Alisa, en vérifiant ce code.

 Options : -Server hôte:port (défaut alisa.re:5443), -Version vX.Y.Z
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
    [string]$Server = 'alisa.re:5443',
    [string]$Listen = ':5100',
    [string]$Version = 'latest',
    [string]$CaFile,
    [switch]$ProxyTls,
    [string]$ProxyCaFile,
    [switch]$ForceConfig
)

$ErrorActionPreference = 'Stop'
# -Server passé explicitement (Update-ServerAddress).
$ServerGiven = $PSBoundParameters.ContainsKey('Server')
Set-StrictMode -Version Latest
$Repo = 'net-system-srl/alisa-releases'

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

# Processus encore en cours sur le binaire installé (service en cours d'arrêt, relance
# automatique, lancement manuel « run »…). Tant qu'il en reste un, Windows refuse d'écraser
# l'exécutable (« section mappée utilisateur ouverte »).
function Get-AlisaProcess {
    Get-Process -Name $binName -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and ($_.Path -ieq $binPath) }
}

# « stop » rend la main avant la fin du processus : on attend jusqu'à 30 s, puis on le force.
function Wait-AlisaExit {
    for ($i = 0; $i -lt 30 -and (Get-AlisaProcess); $i++) { Start-Sleep -Seconds 1 }
    $left = @(Get-AlisaProcess)
    if ($left.Count -gt 0) {
        Info "Arrêt forcé de $binName (PID $($left.Id -join ', '))"
        $left | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
}

# Copie du nouveau binaire. Si l'ancien est encore chargé (le service a pu être relancé
# entre-temps par la récupération automatique), Windows permet de le renommer : il part en
# .old et le nouveau prend sa place ; l'ancien disparaît au prochain redémarrage du service.
function Install-Binary([string]$Source) {
    try {
        Copy-Item -Force $Source $binPath -ErrorAction Stop
    }
    catch [System.IO.IOException] {
        Info "Binaire encore utilisé : l'ancien est renommé en $binName.exe.old"
        Remove-Item -Force -ErrorAction SilentlyContinue "$binPath.old"
        Move-Item -Force $binPath "$binPath.old" -ErrorAction Stop
        Copy-Item -Force $Source $binPath -ErrorAction Stop
    }
}

# Valeurs entre guillemets simples YAML (une apostrophe est doublée).
function Quote([string]$Value) { "'" + $Value.Replace("'", "''") + "'" }

# Ancienne adresse du serveur central (avant le passage à alisa.re, docs/deployment.md).
$LegacyServer = 'alisa.netmonitoring.be:5443'

# Une configuration existante est conservée, sauf son server_address quand l'adresse
# demandée explicitement (-Server) diffère, ou quand elle vaut encore l'ancienne adresse :
# sans cela, relancer la commande d'installation garderait alisa.netmonitoring.be.
function Update-ServerAddress {
    # -Encoding UTF8 : Windows PowerShell 5.1 lirait sinon le fichier (sans BOM) en ANSI.
    $lines = @(Get-Content -LiteralPath $configPath -Encoding UTF8)
    $index = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^server_address:') { $index = $i; break }
    }
    if ($index -lt 0) { return }
    if ($lines[$index] -notmatch '^server_address:\s*[''"]?([^''"\s#]+)') { return }
    $current = $Matches[1]
    if ($current -eq $Server) { return }
    if (-not $ServerGiven -and $current -ne $LegacyServer) { return }
    Info "server_address mis à jour : $current → $Server"
    $lines[$index] = "server_address: $(Quote $Server)"
    # UTF-8 sans BOM, comme à la première écriture ; les droits du dossier sont hérités.
    [System.IO.File]::WriteAllLines($configPath, [string[]]$lines, (New-Object System.Text.UTF8Encoding $false))
}

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
        Update-ServerAddress
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
        Wait-AlisaExit
    }
    Install-Binary (Join-Path $tmp $asset)
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
