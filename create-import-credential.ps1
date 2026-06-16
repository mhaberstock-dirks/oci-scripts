<#
.SYNOPSIS
    Legt ein natives OCI-Credential (DBMS_CLOUD) in der ADB an.

.DESCRIPTION
    Das Skript:
      1. Liest OCI-Konfigurationswerte aus ~/.oci/config (user, tenancy,
         fingerprint, key_file, region)
      2. Liest den privaten API-Schluessel aus der konfigurierten PEM-Datei
      3. Generiert das SQL fuer DBMS_CLOUD.CREATE_CREDENTIAL im Speicher
      4. Verbindet sich per SQLcl und fuehrt das SQL direkt aus
      5. Prueft die Verbindung zum Bucket per DBMS_CLOUD.LIST_OBJECTS

    Kein Secret wird in einer Datei gespeichert. Das SQL-Skript existiert
    nur als temporaere Datei waehrend der Ausfuehrung und wird in einem
    finally-Block automatisch geloescht.

    Voraussetzung: SQLcl ('sql') muss im PATH verfuegbar sein.
    Die TNS-Konfiguration (tnsnames.ora + Wallet) muss eingerichtet sein
    (siehe get-adb-wallet.ps1).

    -TnsAlias ist ein Pflichtparameter. Ohne ihn wird eine Usage-Meldung
    ausgegeben und das Skript beendet.

.PARAMETER TnsAlias
    TNS-Alias fuer die SQLcl-Verbindung (z.B. ADBDEV_HIGH, ADBDEV_MEDIUM).
    Muss einem Eintrag in der tnsnames.ora entsprechen.
    Pflichtparameter - ohne Angabe wird die Usage-Meldung ausgegeben.

.PARAMETER BucketName
    Name des Object-Storage-Buckets (Default: migration-bucket)

.PARAMETER CredName
    Name des anzulegenden DBMS_CLOUD-Credentials in der ADB
    (Default: IMPORT_CRED_NATIVE)

.PARAMETER AdminPassword
    Admin-Passwort der ADB als SecureString.
    Wird interaktiv abgefragt, wenn nicht angegeben.

.PARAMETER WhatIf
    Trockenlauf: zeigt alle Parameter an, nimmt aber keine Aenderungen vor.

.EXAMPLE
    .\create-import-credential.ps1 -TnsAlias ADBDEV_HIGH

.EXAMPLE
    .\create-import-credential.ps1 -TnsAlias ADBDEV_MEDIUM -BucketName other-bucket

.EXAMPLE
    .\create-import-credential.ps1 -TnsAlias ADBDEV_HIGH -WhatIf
#>

# CredName ist ein DB-Objektname (z.B. "IMPORT_CRED_NATIVE"), kein Geheimnis.
# PSScriptAnalyzer faellt auf "Cred" als Praefix herein.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingPlainTextForPassword', 'CredName',
    Justification = 'CredName ist ein DB-Objektname, kein Secret (z.B. IMPORT_CRED_NATIVE)')]
param(
    [string]$TnsAlias      = "",
    [string]$BucketName    = "migration-bucket",
    [string]$CredName      = "IMPORT_CRED_NATIVE",
    [securestring]$AdminPassword,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

# --- Pflichtparameter pruefen ------------------------------------------------
if (-not $TnsAlias) {
    Write-Host @"

VERWENDUNG: .\create-import-credential.ps1 -TnsAlias <alias> [Optionen]

Legt ein natives OCI-Credential in der ADB an und prueft die Verbindung
zum Object-Storage-Bucket (DBMS_CLOUD.CREATE_CREDENTIAL + LIST_OBJECTS).

PFLICHT:
  -TnsAlias <alias>      TNS-Alias fuer die SQLcl-Verbindung
                         (Eintrag aus tnsnames.ora, z.B. ADBDEV_HIGH)

OPTIONAL:
  -BucketName <name>     Object-Storage-Bucket  (Default: migration-bucket)
  -CredName <name>       DB-Credential-Name     (Default: IMPORT_CRED_NATIVE)
  -AdminPassword         Admin-Passwort als SecureString (sonst interaktiv)
  -WhatIf                Trockenlauf: zeigt Parameter, verbindet nicht

BEISPIELE:
  .\create-import-credential.ps1 -TnsAlias ADBDEV_HIGH
  .\create-import-credential.ps1 -TnsAlias ADBDEV_HIGH -WhatIf
  .\create-import-credential.ps1 -TnsAlias ADBDEV_MEDIUM -BucketName other-bucket

"@
    exit 1
}

# --- Konfiguration pruefen ---------------------------------------------------
$configPath = "$env:USERPROFILE\.oci\config"
if (-not (Test-Path $configPath)) {
    throw "OCI Config nicht gefunden unter $configPath. Bitte zuerst 'oci setup config' ausfuehren."
}
$configLines = Get-Content $configPath

function Get-IniValue {
    param([string[]]$Lines, [string]$Key)
    $match = ($Lines | Select-String "^$Key\s*=" | Select-Object -First 1)
    if (-not $match) { throw "Schluessel '$Key' nicht in ~/.oci/config gefunden." }
    return $match.ToString().Split('=', 2)[1].Trim()
}

$userOcid    = Get-IniValue $configLines 'user'
$tenancyOcid = Get-IniValue $configLines 'tenancy'
$fingerprint = Get-IniValue $configLines 'fingerprint'
$region      = Get-IniValue $configLines 'region'
$keyFile     = Get-IniValue $configLines 'key_file'

# ~ in Pfad expandieren (PowerShell 5.1 unterstuetzt ~ nicht in allen Kontexten)
if ($keyFile -match '^~[/\\]') {
    $keyFile = Join-Path $HOME $keyFile.Substring(2)
}

# --- Passphrase-Warnung ------------------------------------------------------
$ppLine = ($configLines | Select-String '^pass_phrase\s*=' | Select-Object -First 1)
if ($ppLine) {
    $ppVal = $ppLine.ToString().Split('=', 2)[1].Trim()
    if ($ppVal -ne '') {
        Write-Warning "API-Key ist passphrase-geschuetzt. DBMS_CLOUD.CREATE_CREDENTIAL erwartet einen unverschluesselten PKCS#8-Key."
    }
}

# --- Privaten Schluessel lesen und aufbereiten --------------------------------
if (-not (Test-Path $keyFile)) {
    throw "API-Key-Datei nicht gefunden: $keyFile"
}
$keyLines       = Get-Content $keyFile
$privateKeyBody = (
    $keyLines |
    Where-Object { $_ -notmatch '^-----' -and $_.Trim() -ne '' } |
    ForEach-Object { $_.Trim() }
) -join ''

# --- Object-Storage-Namespace und Bucket-URI bestimmen -----------------------
$namespace = (oci os ns get | ConvertFrom-Json).data
$bucketUri = "https://objectstorage.$region.oraclecloud.com/n/$namespace/b/$BucketName/o/"

# --- Parameter anzeigen ------------------------------------------------------
Write-Host "`n=== Credential-Parameter ===" -ForegroundColor Cyan
Write-Host "  TNS-Alias       : $TnsAlias"
Write-Host "  Credential Name : $CredName"
Write-Host "  user_ocid       : $userOcid"
Write-Host "  tenancy_ocid    : $tenancyOcid"
Write-Host "  fingerprint     : $fingerprint"
Write-Host "  key_file        : $keyFile"
Write-Host "  region          : $region"
Write-Host "  Namespace       : $namespace"
Write-Host "  Bucket-URI      : $bucketUri"

if ($WhatIf) {
    Write-Host "`n-WhatIf gesetzt: Kein Credential wird angelegt." -ForegroundColor Yellow
    return
}

# --- Admin-Passwort abfragen (falls nicht uebergeben) ------------------------
if (-not $AdminPassword) {
    Write-Host ""
    $AdminPassword = Read-Host -AsSecureString "ADMIN-Passwort fuer $TnsAlias"
}

$bstr    = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassword)
$pwPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

# --- SQL generieren und per SQLcl ausfuehren ---------------------------------
$sql = @"
WHENEVER SQLERROR EXIT FAILURE
SET DEFINE OFF

-- Credential loeschen falls bereits vorhanden (Fehler wird ignoriert)
BEGIN
  DBMS_CLOUD.DROP_CREDENTIAL(credential_name => '$CredName');
EXCEPTION WHEN OTHERS THEN NULL;
END;
/

-- Natives OCI-Credential anlegen
BEGIN
  DBMS_CLOUD.CREATE_CREDENTIAL(
    credential_name => '$CredName',
    user_ocid       => '$userOcid',
    tenancy_ocid    => '$tenancyOcid',
    private_key     => '$privateKeyBody',
    fingerprint     => '$fingerprint'
  );
END;
/

-- Verbindungstest: Bucket-Inhalte auflisten
-- Kein ORA-20401 (HTTP 401/403) = Authentifizierung erfolgreich
SELECT object_name, bytes
FROM TABLE(
  DBMS_CLOUD.LIST_OBJECTS(
    credential_name => '$CredName',
    location_uri    => '$bucketUri'
  )
);

EXIT
"@

$tmpFile = Join-Path $env:TEMP ([System.Guid]::NewGuid().ToString("N") + ".sql")
Write-Host "`n=== SQLcl-Verbindung: $TnsAlias ===" -ForegroundColor Cyan
Write-Host "Credential wird angelegt und Bucket-Verbindung geprueft..."
try {
    $sql | Set-Content -Path $tmpFile -Encoding ascii
    & sql "admin/$pwPlain@$TnsAlias" "@$tmpFile"
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "SQLcl ist mit Exit-Code $LASTEXITCODE beendet worden."
    }
} finally {
    if (Test-Path $tmpFile) { Remove-Item -Path $tmpFile -Force }
    $pwPlain        = $null
    $privateKeyBody = $null
}

Write-Host "`nFertig." -ForegroundColor Green
Write-Host "Naechster Schritt: .\run-datapump-import.ps1 -TnsAlias $TnsAlias" -ForegroundColor Cyan
