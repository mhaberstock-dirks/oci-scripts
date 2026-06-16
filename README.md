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
├── create-adb-dev.ps1      # Provisionierung der Always-Free ADB
├── get-adb-wallet.ps1      # Download des ADB-Wallets
├── policies/
│   └── *.json              # generierte Policy-Statements (auto-generiert)
└── wallet/                 # Wallet-ZIPs + Inhalte (.gitignore)
    └── <DbName>/
        ├── wallet_<DbName>.zip
        └── contents/       # entpackt (nur bei -Unzip)
```

## Nutzung

### 1. Policy-Setup (einmalig)

```powershell
.\setup-adb-dev.ps1
# Trockenlauf:
.\setup-adb-dev.ps1 -WhatIf
```

Defaults: Compartment `Markus_Dev`, Group `Grp-ADB-Dev-Admins`, Policy `Policy-ADB-Dev-Admins`

### 2. ADB provisionieren (idempotent)

```powershell
.\create-adb-dev.ps1
# Mit IP-Whitelist (ACL):
.\create-adb-dev.ps1 -WhitelistIPs @("203.0.113.0/24")
# Ohne Warten auf AVAILABLE:
.\create-adb-dev.ps1 -NoWait
# Trockenlauf:
.\create-adb-dev.ps1 -WhatIf
```

Defaults: Compartment `Markus_Dev`, DisplayName `ADB-Dev`, DbName `ADBDEV`, Workload `OLTP`

### 3. Wallet herunterladen

```powershell
# Per Compartment + DbName (Default):
.\get-adb-wallet.ps1
# Per OCID (direkt aus create-adb-dev.ps1-Ausgabe):
.\get-adb-wallet.ps1 -AdbOcid "ocid1.autonomousdatabase.oc1..."
# Mit automatischem Entpacken:
.\get-adb-wallet.ps1 -Unzip
# Trockenlauf:
.\get-adb-wallet.ps1 -WhatIf
```

### setup-adb-dev.ps1 – weitere Optionen

```powershell
.\setup-adb-dev.ps1 -CompartmentName "Anderes_Compartment" -GroupName "Andere_Gruppe" -PolicyName "Andere_Policy"
# Falls der Tenant benannte Identity Domains nutzt:
.\setup-adb-dev.ps1 -DomainPrefix "MeinDomainName"
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

- [x] Skript zur Provisionierung der Always-Free ADB
- [x] Skript zum Download des Wallets
- [ ] Skript zur Validierung der DB-Verbindung