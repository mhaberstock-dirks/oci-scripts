<#
.SYNOPSIS
    Laedt das Wallet (TLS-Zertifikate + Connection-Strings) fuer eine
    Autonomous Database herunter.

.DESCRIPTION
    Das Skript:
      1. Ermittelt die ADB-OCID (direkt per -AdbOcid oder per Compartment + DbName)
      2. Laedt das Wallet als ZIP nach wallet\<DbName>\wallet_<DbName>.zip
      3. Optional: entpackt das Wallet in wallet\<DbName>\contents\ (-Unzip)

    Das Wallet enthaelt sensitive Dateien (Zertifikate, Verbindungsinformationen).
    Das Verzeichnis wallet\ ist per .gitignore vom Repository ausgeschlossen.

.PARAMETER AdbOcid
    OCID der Autonomous Database. Wenn angegeben, werden CompartmentName und
    DbName fuer die Suche nicht benoetigt.

.PARAMETER CompartmentName
    Name des Compartments, in dem die ADB liegt (Default: Markus_Dev).
    Wird ignoriert, wenn AdbOcid angegeben ist.

.PARAMETER DbName
    Datenbankname zum Suchen der ADB (Default: ADBDEV).
    Wird ignoriert, wenn AdbOcid angegeben ist.

.PARAMETER WalletDir
    Zielverzeichnis fuer das Wallet (Default: .\wallet\<DbName>)

.PARAMETER WalletPassword
    Passwort zum Schutz des Wallet-ZIP (min. 8 Zeichen, mind. 1 Buchstabe + 1 Ziffer).
    Wird interaktiv abgefragt, wenn nicht angegeben.

.PARAMETER Unzip
    Wenn gesetzt, wird das Wallet-ZIP nach dem Download in den Unterordner
    wallet\<DbName>\contents\ entpackt.

.PARAMETER WhatIf
    Trockenlauf: zeigt alle Parameter an, laedt aber kein Wallet herunter.

.EXAMPLE
    .\get-adb-wallet.ps1

.EXAMPLE
    .\get-adb-wallet.ps1 -AdbOcid "ocid1.autonomousdatabase.oc1..." -Unzip

.EXAMPLE
    .\get-adb-wallet.ps1 -DbName "ADBDEV" -WalletDir "C:\myapp\wallet" -WhatIf
#>

param(
    [string]$AdbOcid         = "",
    [string]$CompartmentName = "Markus_Dev",
    [string]$DbName          = "ADBDEV",
    [string]$WalletDir       = "",
    [securestring]$WalletPassword,
    [switch]$Unzip,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

# --- Konfiguration pruefen ------------------------------------------------
$configPath = "$env:USERPROFILE\.oci\config"
if (-not (Test-Path $configPath)) {
    throw "OCI Config nicht gefunden unter $configPath. Bitte zuerst 'oci setup config' ausfuehren."
}

# --- ADB-OCID ermitteln (falls nicht direkt angegeben) --------------------
if (-not $AdbOcid) {
    Write-Host "=== Suche ADB '$DbName' in Compartment '$CompartmentName' ===" -ForegroundColor Cyan

    $compartments = (oci iam compartment list | ConvertFrom-Json).data
    $devCompId    = ($compartments | Where-Object { $_.name -eq $CompartmentName }).id
    if (-not $devCompId) { throw "Compartment '$CompartmentName' nicht gefunden." }

    $dbs    = (oci db autonomous-database list --compartment-id $devCompId | ConvertFrom-Json).data
    $adbObj = $dbs | Where-Object { $_.'db-name' -eq $DbName }
    if (-not $adbObj) { throw "ADB mit DB-Name '$DbName' nicht gefunden in Compartment '$CompartmentName'." }

    $AdbOcid        = $adbObj.id
    $resolvedDbName = $adbObj.'db-name'
    Write-Host "ADB gefunden: $($adbObj.'display-name') (OCID: $AdbOcid, State: $($adbObj.'lifecycle-state'))"
} else {
    Write-Host "=== ADB-OCID direkt angegeben ===" -ForegroundColor Cyan
    $adbObj         = (oci db autonomous-database get --autonomous-database-id $AdbOcid | ConvertFrom-Json).data
    $resolvedDbName = if ($DbName -ne "ADBDEV" -or -not $DbName) { $DbName } else { $adbObj.'db-name' }
    Write-Host "ADB: $($adbObj.'display-name') / $($adbObj.'db-name') (State: $($adbObj.'lifecycle-state'))"
}

# --- Wallet-Pfad bestimmen ------------------------------------------------
if (-not $WalletDir) {
    $WalletDir = Join-Path $PSScriptRoot "wallet\$resolvedDbName"
}
$walletZip = Join-Path $WalletDir "wallet_$resolvedDbName.zip"

# --- Parameter anzeigen ---------------------------------------------------
$unzipText = if ($Unzip) { "ja  (-> wallet\$resolvedDbName\contents\)" } else { 'nein' }
Write-Host "`n=== Wallet-Parameter ===" -ForegroundColor Cyan
Write-Host "  ADB-OCID        : $AdbOcid"
Write-Host "  Zielverzeichnis : $WalletDir"
Write-Host "  ZIP-Datei       : $walletZip"
Write-Host "  Entpacken       : $unzipText"

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

# --- Optional entpacken --------------------------------------------------
if ($Unzip) {
    Write-Host "`n=== Wallet wird entpackt ===" -ForegroundColor Cyan
    $unzipDir = Join-Path $WalletDir "contents"
    if (-not (Test-Path $unzipDir)) {
        New-Item -ItemType Directory -Path $unzipDir | Out-Null
    }
    Expand-Archive -Path $walletZip -DestinationPath $unzipDir -Force
    $walletFiles = (Get-ChildItem $unzipDir | Select-Object -ExpandProperty Name) -join ", "
    Write-Host "Entpackt nach : $unzipDir" -ForegroundColor Green
    Write-Host "Dateien       : $walletFiles"
    Write-Host ""
    Write-Host "Hinweis: Das Verzeichnis 'wallet\' ist per .gitignore vom Repository ausgeschlossen." -ForegroundColor Yellow
}

Write-Host "`nFertig." -ForegroundColor Green
