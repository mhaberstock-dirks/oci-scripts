<#
.SYNOPSIS
    Laedt das Wallet-ZIP fuer eine Autonomous Database herunter und erzeugt
    passende TNSNAMES.ORA-Eintraege mit MY_WALLET_DIR-Direktive.

.DESCRIPTION
    Das Skript:
      1. Ermittelt die ADB-OCID (direkt per -AdbOcid oder per Compartment + DbName)
      2. Laedt das Wallet als ZIP nach <WalletDir>\wallet_<DbName>.zip
      3. Liest die Verbindungsstrings aus der OCI API
      4. Schreibt <WalletDir>\tnsnames_entries.txt  -- TNS-Eintraege mit MY_WALLET_DIR
         und <WalletDir>\sqlnet_safe.txt            -- sicherer SQLNET.ORA-Block

    Die Integration in eine bestehende Oracle Net-Konfiguration (tnsnames.ora,
    sqlnet.ora) erfolgt manuell. Das Entpacken des Wallet-ZIP ebenfalls.
    MY_WALLET_DIR erlaubt datenbankspezifische Wallet-Verzeichnisse ohne globale
    WALLET_LOCATION in sqlnet.ora (setzt Oracle Client 19c oder hoeher voraus).

    Das Wallet-Verzeichnis enthaelt sensitive Dateien und ist per .gitignore
    vom Repository ausgeschlossen.

.PARAMETER AdbOcid
    OCID der Autonomous Database. Wenn angegeben, werden CompartmentName und
    DbName fuer die Suche nicht benoetigt.

.PARAMETER CompartmentName
    Name des Compartments (Default: Markus_Dev).
    Wird ignoriert, wenn AdbOcid angegeben ist.

.PARAMETER DbName
    Datenbankname zum Suchen der ADB (Default: ADBDEV).
    Wird ignoriert, wenn AdbOcid angegeben ist.

.PARAMETER WalletDir
    Zielverzeichnis fuer Wallet-ZIP und Hilfsdateien.
    Default: .\wallet\<DbName>
    Dieses Verzeichnis wird auch als MY_WALLET_DIR in den TNS-Eintraegen
    verwendet – ZIP dort entpacken, bevor Verbindungen hergestellt werden.

.PARAMETER WalletPassword
    Passwort zum Schutz des Wallet-ZIP (min. 8 Zeichen, mind. 1 Buchstabe + 1 Ziffer).
    Wird interaktiv abgefragt, wenn nicht angegeben.

.PARAMETER WhatIf
    Trockenlauf: zeigt alle Parameter an, laedt aber kein Wallet herunter.

.EXAMPLE
    .\get-adb-wallet.ps1

.EXAMPLE
    .\get-adb-wallet.ps1 -AdbOcid "ocid1.autonomousdatabase.oc1..."

.EXAMPLE
    .\get-adb-wallet.ps1 -WalletDir "C:\oracle\wallets\ADBDEV" -WhatIf
#>

param(
    [string]$AdbOcid         = "",
    [string]$CompartmentName = "Markus_Dev",
    [string]$DbName          = "ADBDEV",
    [string]$WalletDir       = "",
    [securestring]$WalletPassword,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

# --- Konfiguration pruefen ------------------------------------------------
$configPath = "$env:USERPROFILE\.oci\config"
if (-not (Test-Path $configPath)) {
    throw "OCI Config nicht gefunden unter $configPath. Bitte zuerst 'oci setup config' ausfuehren."
}
$tenancyId = (Get-Content $configPath | Select-String '^tenancy\s*=' | Select-Object -First 1).ToString().Split('=', 2)[1].Trim()

# --- ADB-OCID ermitteln ---------------------------------------------------
if (-not $AdbOcid) {
    Write-Host "=== Suche ADB '$DbName' in Compartment '$CompartmentName' ===" -ForegroundColor Cyan
    $compartments = (oci iam compartment list --compartment-id $tenancyId | ConvertFrom-Json).data
    $devCompId    = ($compartments | Where-Object { $_.name -eq $CompartmentName }).id
    if (-not $devCompId) { throw "Compartment '$CompartmentName' nicht gefunden." }

    $dbs        = (oci db autonomous-database list --compartment-id $devCompId | ConvertFrom-Json).data
    $adbSummary = $dbs | Where-Object { $_.'db-name' -eq $DbName }
    if (-not $adbSummary) { throw "ADB mit DB-Name '$DbName' nicht gefunden in '$CompartmentName'." }
    $AdbOcid = $adbSummary.id
} else {
    Write-Host "=== ADB-OCID direkt angegeben ===" -ForegroundColor Cyan
}

# --- Vollstaendige ADB-Infos inkl. Connection-Strings laden ---------------
Write-Host "Lade ADB-Konfiguration..." -ForegroundColor Cyan
$adbFull        = (oci db autonomous-database get --autonomous-database-id $AdbOcid | ConvertFrom-Json).data
$resolvedDbName = $adbFull.'db-name'
Write-Host "ADB: $($adbFull.'display-name') / $resolvedDbName (State: $($adbFull.'lifecycle-state'))"

# --- Pfade bestimmen ------------------------------------------------------
if (-not $WalletDir) {
    $WalletDir = Join-Path $PSScriptRoot "wallet\$resolvedDbName"
}
$walletZip     = Join-Path $WalletDir "wallet_$resolvedDbName.zip"
$tnsOutputPath = Join-Path $WalletDir "tnsnames_entries.txt"
$sqlnetOutPath = Join-Path $WalletDir "sqlnet_safe.txt"

# --- Parameter anzeigen ---------------------------------------------------
Write-Host "`n=== Wallet-Parameter ===" -ForegroundColor Cyan
Write-Host "  ADB-OCID        : $AdbOcid"
Write-Host "  Wallet-ZIP      : $walletZip"
Write-Host "  MY_WALLET_DIR   : $WalletDir  (ZIP dort entpacken)"
Write-Host "  TNS-Eintraege   : $tnsOutputPath"
Write-Host "  SQLNET-Snippet  : $sqlnetOutPath"

if ($WhatIf) {
    Write-Host "`n-WhatIf gesetzt: Wallet wird NICHT heruntergeladen." -ForegroundColor Yellow
    return
}

# --- Wallet-Passwort abfragen (falls nicht angegeben) --------------------
if (-not $WalletPassword) {
    Write-Host ""
    Write-Host "Passwort-Anforderungen: min. 8 Zeichen, mind. 1 Buchstabe und 1 Ziffer."
    $WalletPassword = Read-Host -AsSecureString "Wallet-Passwort"
}

$bstr    = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($WalletPassword)
$pwPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

# --- Zielverzeichnis anlegen ----------------------------------------------
if (-not (Test-Path $WalletDir)) {
    New-Item -ItemType Directory -Path $WalletDir | Out-Null
    Write-Host "Verzeichnis erstellt: $WalletDir"
}

# --- Wallet herunterladen -------------------------------------------------
Write-Host "`n=== Wallet wird heruntergeladen ===" -ForegroundColor Cyan
oci db autonomous-database generate-wallet `
    --autonomous-database-id $AdbOcid `
    --password               $pwPlain `
    --file                   $walletZip

$pwPlain = $null

if (-not (Test-Path $walletZip)) {
    throw "Wallet-Download fehlgeschlagen - Datei nicht gefunden: $walletZip"
}
$walletSizeKB = [math]::Round((Get-Item $walletZip).Length / 1KB, 1)
Write-Host "Wallet gespeichert: $walletZip ($walletSizeKB KB)" -ForegroundColor Green

# --- TNSNAMES.ORA-Eintraege mit MY_WALLET_DIR generieren ------------------
Write-Host "`n=== TNSNAMES.ORA-Eintraege (mit MY_WALLET_DIR) ===" -ForegroundColor Cyan

$connStrObj = $adbFull.'connection-strings'
$tnsList    = [System.Collections.Generic.List[string]]::new()

if ($connStrObj) {
    # Profilenamen und Deskriptoren: erst 'all-connection-strings' (neuere API),
    # dann Fallback auf bekannte Einzelfelder.
    if ($connStrObj.'all-connection-strings') {
        $profiles = $connStrObj.'all-connection-strings'.PSObject.Properties |
            Select-Object @{N='Name';E={$_.Name}}, @{N='Descriptor';E={$_.Value}}
    } else {
        $profiles = @('high','medium','low','tp','tpurgent') | ForEach-Object {
            $d = $connStrObj.$_
            if ($d) { [PSCustomObject]@{ Name = $_; Descriptor = $d } }
        }
    }

    $secOld = '(security=(ssl_server_dn_match=yes))'
    $secNew  = "(security=(ssl_server_dn_match=yes)(MY_WALLET_DIR=$WalletDir))"

    foreach ($p in $profiles) {
        $alias    = ($resolvedDbName + '_' + $p.Name).ToUpper()
        $tnsEntry = $p.Descriptor.Replace($secOld, $secNew)
        $line     = "$alias = $tnsEntry"
        Write-Host $line
        Write-Host ""
        $tnsList.Add($line)
    }
} else {
    Write-Host "Keine Connection-Strings verfuegbar (DB noch nicht AVAILABLE?)." -ForegroundColor Yellow
}

# --- Sicherer SQLNET.ORA-Block --------------------------------------------
Write-Host "=== Empfohlener SQLNET.ORA-Block ===" -ForegroundColor Cyan
$sqlnetBlock = @"
# SQLNET.ORA -- gemeinsame Oracle Net-Einstellungen
# Wallet-Verzeichnisse werden pro Verbindung per MY_WALLET_DIR in der
# tnsnames.ora gesteuert. Keine datenbankspezifischen Wallet-Parameter hier.

NAMES.DIRECTORY_PATH = (TNSNAMES, EZCONNECT)

# Minimale TLS-Version fuer alle TCPS-Verbindungen (nicht DB-spezifisch)
SSL_VERSION = 1.2 or higher

# NICHT setzen (wuerden alle Verbindungen global beeinflussen):
#   WALLET_LOCATION = ...
#   SQLNET.WALLET_OVERRIDE = TRUE
"@
Write-Host $sqlnetBlock

# --- Hilfsdateien schreiben -----------------------------------------------
if ($tnsList.Count -gt 0) {
    $tnsHeader = "# TNSNAMES.ORA - Eintraege fuer $resolvedDbName (Always Free, OCI)`n" +
                 "# Erzeugt: $(Get-Date -Format 'yyyy-MM-dd HH:mm')`n" +
                 "# ADB-OCID: $AdbOcid`n" +
                 "# Wallet-ZIP: $walletZip`n" +
                 "#`n" +
                 "# Voraussetzung: Oracle Client 19c+ (MY_WALLET_DIR-Unterstuetzung)`n" +
                 "# MY_WALLET_DIR zeigt auf das Verzeichnis, in das das Wallet-ZIP entpackt wurde.`n" +
                 "# Eintraege in %TNS_ADMIN%\tnsnames.ora kopieren.`n`n"
    ($tnsHeader + ($tnsList -join "`n`n")) | Set-Content -Path $tnsOutputPath -Encoding ascii
    Write-Host "`nTNSNAMES-Eintraege : $tnsOutputPath" -ForegroundColor Green
}

$sqlnetBlock | Set-Content -Path $sqlnetOutPath -Encoding ascii
Write-Host "SQLNET-Snippet     : $sqlnetOutPath" -ForegroundColor Green

# --- Naechste Schritte ----------------------------------------------------
Write-Host "`n=== Naechste Schritte ===" -ForegroundColor Cyan
Write-Host "1. Wallet-ZIP entpacken nach : $WalletDir"
Write-Host "   (Inhalt: cwallet.sso, ewallet.p12, tnsnames.ora, sqlnet.ora, ...)"
Write-Host "2. Eintraege aus tnsnames_entries.txt in %TNS_ADMIN%\tnsnames.ora kopieren."
Write-Host "3. SQLNET.ORA pruefen: sqlnet_safe.txt zeigt, was NICHT gesetzt werden sollte."
Write-Host "`nFertig." -ForegroundColor Green
