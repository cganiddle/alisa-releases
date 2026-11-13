# Installer un proxy ou un agent

Principe (voir [ADR 0002](../../docs/adr/0002-enrolement-et-mise-a-jour.md)) :

1. On installe le proxy ou l'agent **sans aucun secret** : seule l'adresse du serveur central
   est nécessaire (par défaut `alisa.netmonitoring.be:5443`).
2. Au démarrage, le nœud génère son identité et **s'annonce au serveur central**. Le script
   affiche son **code de vérification** (`XXXX-XXXX`).
3. Dans l'interface Alisa, l'administrateur **approuve le proxy** (nom de fonctionnement,
   adresse que les agents utiliseront) ou **associe l'agent à un proxy**, après avoir vérifié
   que le code affiché est identique.
4. L'agent ne fonctionne qu'une fois associé : il reçoit alors l'adresse de son proxy et ne
   parle plus qu'à lui.
5. Ensuite, proxies et agents **se mettent à jour automatiquement** (binaires signés), selon
   la politique choisie dans l'interface (*Mises à jour*).

Les scripts téléchargent la version demandée (la dernière par défaut) depuis les
[releases GitHub](https://github.com/cganiddle/alisa-releases/releases), **vérifient son empreinte
SHA-256**, écrivent la configuration, installent le service système (relance automatique en
cas d'échec) et le démarrent.

## Proxy

Linux (systemd), en root :

```bash
curl -fsSL https://raw.githubusercontent.com/cganiddle/alisa-releases/main/install/install.sh | sudo bash -s -- proxy
```

Windows (PowerShell **administrateur**) :

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/cganiddle/alisa-releases/main/install/install.ps1))) -Component proxy
```

Le proxy écoute par défaut sur **toutes les interfaces, port 5100** : ouvrez ce port (TCP)
aux agents dans le pare-feu de la machine. Il doit pouvoir joindre le serveur central (port
5443) et, pour les mises à jour, `github.com` (HTTPS).

**Traps SNMP et syslog** (facultatif, activés depuis l'interface : Proxies → « Traps et
syslog ») : ouvrez aux équipements **UDP 162** (traps) et **UDP/TCP 514** (syslog), ou les
ports choisis. Le service tourne en root (Linux, macOS) ou SYSTEM (Windows) et peut donc
écouter ces ports privilégiés ; si vous le faites tourner sous un autre compte, voir
[`docs/events.md`](../../docs/events.md) (`CAP_NET_BIND_SERVICE`).

## Agent

Linux et macOS, en root :

```bash
curl -fsSL https://raw.githubusercontent.com/cganiddle/alisa-releases/main/install/install.sh | sudo bash -s -- agent
```

Windows (PowerShell **administrateur**) :

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/cganiddle/alisa-releases/main/install/install.ps1))) -Component agent
```

Depuis `cmd.exe` (console par défaut de Server Core et Hyper-V Server ; l'erreur « & était
inattendu » signale qu'on est dans cmd) :

```bat
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm https://raw.githubusercontent.com/cganiddle/alisa-releases/main/install/install.ps1))) -Component agent"
```

Sur un hôte **Hyper-V**, l'agent standard suffit : ajoutez ensuite un check « Hyper-V » pour
superviser les machines virtuelles ([`docs/hyperv.md`](../../docs/hyperv.md)).

L'agent doit pouvoir joindre le serveur central (port 5443) pour s'enrôler, puis son proxy
(port 5100). Il n'a pas besoin d'accès Internet ensuite : ses mises à jour passent par le proxy.

**État SMART des disques** (facultatif, agent ≥ 0.3.19) : installez smartmontools ≥ 7
(`apt install smartmontools`, `dnf install smartmontools`, `brew install smartmontools`, ou
l'installateur Windows de smartmontools.org). L'agent le détecte seul et relève la santé des
disques toutes les 30 minutes. Le RAID logiciel Linux (`/proc/mdstat`) est relevé sans rien
installer.

## Revoir le code de vérification

```bash
sudo alisa-agent enrollment          # ou : sudo alisa-proxy enrollment
```

```powershell
& 'C:\Program Files\Alisa\alisa-agent.exe' enrollment
```

## Options

| `install.sh` | `install.ps1` | Effet |
|---|---|---|
| `--server hôte:port` | `-Server` | Serveur central (défaut `alisa.netmonitoring.be:5443`) |
| `--version vX.Y.Z` | `-Version` | Version précise (défaut : dernière publiée) |
| `--ca-file chemin` | `-CaFile` | CA privée du serveur central |
| `--listen :5100` | `-Listen` | Proxy : adresse d'écoute pour les agents |
| `--proxy-tls` | `-ProxyTls` | Agent : le proxy présente un certificat (sinon connexion en clair, réservée à un réseau local de confiance) |
| `--proxy-ca-file chemin` | `-ProxyCaFile` | Agent : CA ayant signé le certificat du proxy (implique TLS) |
| `--force-config` | `-ForceConfig` | Réécrit la configuration existante |

`ALISA_DOWNLOAD_BASE` (variable d'environnement) remplace l'URL de téléchargement : miroir
interne ou serveur de test.

## Mise à jour et désinstallation

- **Mise à jour** : automatique (politique réglée dans l'interface, *Mises à jour*). Relancer
  la commande d'installation force la dernière version tout en conservant configuration et
  identité.
- **Désinstaller** : `sudo alisa-agent stop && sudo alisa-agent uninstall` (idem `alisa-proxy`),
  puis supprimer le binaire, la configuration et l'état (voir ci-dessous). Supprimer l'état
  donne au nœud une **nouvelle identité** : il faudra l'approuver/l'associer de nouveau.

## Emplacements

| | Binaire | Configuration | Identité (secret) |
|---|---|---|---|
| Linux (agent) | `/usr/local/bin/alisa-agent` | `/etc/alisa/agent.yaml` | `/var/lib/alisa-agent/state.json` |
| Linux (proxy) | `/usr/local/bin/alisa-proxy` | `/etc/alisa/proxy.yaml` | `/var/lib/alisa-proxy/state.json` |
| macOS | `/usr/local/bin/alisa-agent` | `/Library/Application Support/Alisa/agent.yaml` | `/Library/Application Support/Alisa/state/state.json` |
| Windows | `C:\Program Files\Alisa\alisa-{agent,proxy}.exe` | `C:\ProgramData\Alisa\{agent,proxy}.yaml` | `C:\ProgramData\Alisa\state\` (agent), `…\proxy-cache\` (proxy) |

À chaque mise à jour automatique, le binaire précédent est conservé en `.old`.

Les binaires macOS et Windows ne sont pas encore signés par Apple/Microsoft (ils sont signés
par la clé de release Alisa, vérifiée par la mise à jour automatique) : le script retire
l'attribut de quarantaine sous macOS ; Windows SmartScreen peut demander une confirmation.
