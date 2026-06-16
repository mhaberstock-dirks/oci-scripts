<#
.SYNOPSIS
    Provisioniert eine Always-Free Autonomous Database im OCI Free Tier.

.DESCRIPTION
    Das Skript:
      1. Liest die Konfiguration aus ~/.oci/config
      2. Ermittelt die Compartment-OCID anhand des Namens
      3. Prueft, ob eine ADB mit dem angegebenen DbName bereits existiert (idempotent)
      4. Legt die ADB als Always-Free-Instanz an (1 OCPU, 20 GB, oeffentlicher Endpoint)
      5. Optional: konfiguriert eine IP-Whitelist (ACL) fuer den Public Endpoint
      6. Wartet auf State AVAILABLE (ausser bei -NoWait)

.PARAMETER CompartmentName
    Name des Ziel-Compartments (Default: Markus_Dev)

.PARAMETER DisplayName
    Anzeigename der ADB in der OCI Console (Default: ADB-Dev)

.PARAMETER DbName
    Datenbankname: nur Buchstaben und Ziffern, maximal 14 Zeichen (Default: ADBDEV)

.PARAMETER DbWorkload
    Workload-Typ: OLTP (Autonomous Transaction Processing, ATP) oder
    DW (Autonomous Data Warehouse, ADW). Default: OLTP

.PARAMETER WhitelistIPs
    Optionale IP-Adressen oder CIDR-Bloecke fuer den Public Endpoint (ACL).
    Leer = kein ACL (alle IPs erlaubt). Beispiel: @("203.0.113.5", "10.0.0.0/8")

.PARAMETER AdminPassword
    Admin-Passwort als SecureString (12-30 Zeichen, mind. je 1 Gross-/Kleinbuchstabe,
    Ziffer und Sonderzeichen). Wird interaktiv abgefragt, wenn nicht angegeben.

.PARAMETER NoWait
    Wenn gesetzt, wartet das Skript nicht auf State AVAILABLE.
    Die Provisionierung laeuft im Hintergrund; Fortschritt in der OCI Console sichtbar.

.PARAMETER WhatIf
    Trockenlauf: zeigt alle Parameter an, legt aber keine ADB an.

.EXAMPLE
    .\create-adb-dev.ps1

.EXAMPLE
    .\create-adb-dev.ps1 -WhitelistIPs @("203.0.113.0/24") -WhatIf

.EXAMPLE
    .\create-adb-dev.ps1 -DisplayName "MyADB" -DbName "MYADB" -NoWait
#>

param(
    [string]$CompartmentName = "Markus_Dev",
    [string]$DisplayName     = "ADB-Dev",
    [string]$DbName          = "ADBDEV",
    [string]$DbWorkload      = "OLTP",
    [string[]]$WhitelistIPs  = @(),
    [securestring]$AdminPassword,
    [switch]$NoWait,
    [switch]$WhatIf 
)
$ErrorActionPreference = "Stop"

# --- Konfiguration pruefen ------------------------------------------------
$configPath = "$env:USERPROFILE\.oci\config"
if (-not (Test-Path $configPath)) {
    throw "OCI Config nicht gefunden unter $configPath. Bitte zuerst 'oci setup config' ausfuehren."
}
$tenancyId = (Get-Content $configPath | Select-String '^tenancy\s*=' | Select-Object -First 1).ToString().Split('=', 2)[1].Trim()

# --- Compartments laden und Compartment-OCID ermitteln --------------------
Write-Host "=== Compartments ===" -ForegroundColor Cyan
$compartments = (oci iam compartment list --compartment-id $tenancyId | ConvertFrom-Json).data
$compartments | Select-Object name, id | Format-Table -AutoSize

$devCompId = ($compartments | Where-Object { $_.name -eq $CompartmentName }).id
if (-not $devCompId) { throw "Compartment '$CompartmentName' nicht gefunden." }
Write-Host "$CompartmentName Compartment-OCID: $devCompId"

# --- Geplante Parameter anzeigen ------------------------------------------
$workloadLabel = if ($DbWorkload -eq "DW") { "ADW" } else { "ATP" }
Write-Host "`n=== ADB-Parameter ===" -ForegroundColor Cyan
Write-Host "  Compartment  : $CompartmentName"
Write-Host "  Display Name : $DisplayName"
Write-Host "  DB Name      : $DbName"
Write-Host "  Workload     : $DbWorkload ($workloadLabel)"
Write-Host "  Always Free  : ja  (1 OCPU, 20 GB Storage)"
Write-Host "  License      : LICENSE_INCLUDED"
if ($WhitelistIPs.Count -gt 0) {
    Write-Host "  IP-Whitelist : $($WhitelistIPs -join ', ')"
} else {
    Write-Host "  IP-Whitelist : keine (alle IPs erlaubt)"
}
Write-Host "  Warten       : $(if ($NoWait) {'nein (-NoWait)'} else {'ja  (bis AVAILABLE, max. 20 min)'})"

if ($WhatIf) {
    Write-Host "`n-WhatIf gesetzt: ADB wird NICHT angelegt." -ForegroundColor Yellow
    return
}

# --- Admin-Passwort abfragen (falls nicht uebergeben) ---------------------
if (-not $AdminPassword) {
    Write-Host ""
    Write-Host "Passwort-Anforderungen: 12-30 Zeichen, mind. je 1 Gross-/Kleinbuchstabe, Ziffer und Sonderzeichen."
    $AdminPassword = Read-Host -AsSecureString "ADMIN-Passwort"
}

# --- Pruefen, ob ADB bereits existiert (idempotent) -----------------------
Write-Host "`n=== Pruefe vorhandene Autonomous Databases ===" -ForegroundColor Cyan
$existingDbs = (oci db autonomous-database list --compartment-id $devCompId | ConvertFrom-Json).data

$existing = $existingDbs | Where-Object { $_.'db-name' -eq $DbName }
if ($existing) {
    Write-Host "ADB mit DB-Name '$DbName' existiert bereits (idempotent)." -ForegroundColor Yellow
    Write-Host "  OCID         : $($existing.id)"
    Write-Host "  Display Name : $($existing.'display-name')"
    Write-Host "  State        : $($existing.'lifecycle-state')"
    Write-Host "Keine Aenderung vorgenommen." -ForegroundColor Green
    return
}
Write-Host "Keine vorhandene ADB '$DbName' gefunden - wird neu angelegt."

# --- Passwort in Klartext (nur fuer den CLI-Aufruf, danach freigegeben) ---
$bstr    = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassword)
$pwPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

# --- Argument-Liste aufbauen ----------------------------------------------
# Hinweis ECPU-Modell: neuere OCI-Accounts verwenden ggf. ECPUs statt OCPUs.
# In dem Fall --cpu-core-count 1 durch --compute-count 2 ersetzen.
$ociArgs = @(
    "db", "autonomous-database", "create",
    "--compartment-id",           $devCompId,
    "--display-name",             $DisplayName,
    "--db-name",                  $DbName,
    "--admin-password",           $pwPlain,
    "--is-free-tier",             "true",
    "--cpu-core-count",           "1",
    "--data-storage-size-in-gbs", "20",
    "--db-workload",              $DbWorkload,
    "--license-model",            "LICENSE_INCLUDED"
)

if ($WhitelistIPs.Count -gt 0) {
    $ociArgs += @("--whitelisted-ips", ($WhitelistIPs | ConvertTo-Json -Compress))
}

if (-not $NoWait) {
    $ociArgs += @("--wait-for-state", "AVAILABLE", "--max-wait-seconds", "1200")
}

# --- ADB anlegen ----------------------------------------------------------
Write-Host "`n=== Autonomous Database wird angelegt ===" -ForegroundColor Cyan
if (-not $NoWait) {
    Write-Host "Bitte warten - Provisionierung kann bis zu 20 Minuten dauern..." -ForegroundColor Yellow
}

$adb     = (& oci @ociArgs | ConvertFrom-Json).data
$pwPlain = $null

Write-Host "`nADB erfolgreich angelegt:" -ForegroundColor Green
Write-Host "  OCID         : $($adb.id)"
Write-Host "  Display Name : $($adb.'display-name')"
Write-Host "  DB Name      : $($adb.'db-name')"
Write-Host "  State        : $($adb.'lifecycle-state')"
Write-Host "  Is Free Tier : $($adb.'is-free-tier')"

if ($adb.'connection-urls' -and $adb.'connection-urls'.'sql-dev-web-url') {
    Write-Host "  SQL Dev Web  : $($adb.'connection-urls'.'sql-dev-web-url')"
}

Write-Host "`nNaechster Schritt: .\get-adb-wallet.ps1 -AdbOcid '$($adb.id)'" -ForegroundColor Cyan
Write-Host "`nFertig." -ForegroundColor Green
