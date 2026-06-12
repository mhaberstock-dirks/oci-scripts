# OCI Scripts

Sammlung von PowerShell-Skripten zur Verwaltung von OCI-Ressourcen
(Compartments, Groups, Policies, Autonomous Database) im
Free-Tier-/Entwicklungskontext.

## Voraussetzungen

- OCI CLI installiert und konfiguriert (`oci setup config`)
  - Getestet mit: `oci iam region list`
- PowerShell 5.1 oder 7
- Bestehender Identity Domain, Compartment und Group (siehe unten)

## Verzeichnisstruktur

```
oci-scripts/
├── .gitignore
├── README.md
├── setup-adb-dev.ps1       # Validierung + Policy-Setup
└── policies/
    └── *.json              # generierte Policy-Statements (auto-generiert)
```

## Nutzung

### Standard (mit Default-Werten)

```powershell
.\setup-adb-dev.ps1
```

Defaults:
- Compartment: `Markus_Dev`
- Group: `Grp-ADB-Dev-Admins`
- Policy-Name: `Policy-ADB-Dev-Admins`

### Mit anderen Namen

```powershell
.\setup-adb-dev.ps1 -CompartmentName "Anderes_Compartment" -GroupName "Andere_Gruppe" -PolicyName "Andere_Policy"
```

### Falls der Tenant benannte Identity Domains nutzt

```powershell
.\setup-adb-dev.ps1 -DomainPrefix "MeinDomainName"
```

### Trockenlauf (nur anzeigen, nichts anlegen)

```powershell
.\setup-adb-dev.ps1 -WhatIfOnly
```

## Was das Skript tut

1. Listet Identity Domains, Compartments und Groups zur Übersicht
2. Ermittelt die OCIDs für Compartment und Group anhand des Namens
3. Erzeugt `policies/<PolicyName>.json` mit den Policy-Statements
4. Legt die Policy an – oder aktualisiert sie, falls sie bereits existiert

## Policy-Statements (Standard)

```
Allow group <Group> to manage autonomous-database-family in compartment <Compartment>
Allow group <Group> to manage autonomous-backups in compartment <Compartment>
Allow group <Group> to use virtual-network-family in compartment <Compartment>
```

## Hinweise

- **Free Tier**: Beim Provisionieren der ADB unbedingt "Always Free" auswählen,
  sonst werden Kosten/Trial-Guthaben verwendet.
- Es wird empfohlen, für die ADB einen **Public Endpoint mit ACL** zu nutzen,
  um auf VCN/Subnet-Konfiguration verzichten zu können.
- Sensible Dateien (`*.pem`, `config`) liegen unter `~/.oci/` und werden
  durch `.gitignore` ausgeschlossen.

## Nächste Schritte (TODO)

- [ ] Skript zur Provisionierung der Always-Free ADB
- [ ] Skript zum Download des Wallets
- [ ] Skript zur Validierung der DB-Verbindung