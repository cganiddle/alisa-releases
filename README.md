# Alisa — versions publiées

Ce dépôt contient uniquement les **binaires signés** de l'agent et du proxy
[Alisa](https://alisa.netmonitoring.be) (onglet *Releases*) et les **scripts d'installation**
(`install/`). Il est alimenté automatiquement par la chaîne de publication d'Alisa.

Chaque release fournit, pour chaque plateforme, `alisa-agent-<os>-<arch>` et
`alisa-proxy-<os>-<arch>`, ainsi que `SHA256SUMS` et sa signature ed25519
`SHA256SUMS.sig`. Les scripts d'installation et la mise à jour automatique vérifient
l'empreinte et la signature avant toute installation.

Installation : voir [`install/README.md`](install/README.md) ou la commande affichée dans
l'interface d'Alisa (Proxies › Ajouter un proxy, Hôtes › Ajouter un agent).

Logiciel propriétaire : © Net System srl, tous droits réservés — https://net-system.be.
L'usage des binaires est réservé aux titulaires d'une licence Alisa.
