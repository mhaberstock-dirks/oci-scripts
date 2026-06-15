<#
.SYNOPSIS
    Erzeugt ein SQL-Skript zum Anlegen eines nativen OCI-Credentials in der ADB.

.DESCRIPTION
    Das Skript:
      1. Liest OCI-Konfigurationswerte aus ~/.oci/config (user, tenancy,
         fingerprint, key_file, region)
      2. Liest den privaten API-Schluessel und entfernt PEM-Header/Footer
      3. Generiert eine SQL-Datei mit DBMS_CLOUD.CREATE_CREDENTIAL (native
         OCI-Credentials - empfohlene Methode fuer OCI Object Storage)
      4. Ergaenzt die SQL-Datei um einen LIST_OBJECTS-Verbindungstest
      5. Gibt Hinweise zum Ausfuehren in SQLcl und zum sicheren Loeschen

    WARNUNG: Die generierte SQL-Datei enthaelt den privaten API-Schluessel im
    Klartext. Nach Gebrauch sofort loeschen (Remove-Item <Pfad>).

    Die Datei wird in %TEMP% abgelegt (nicht im Repository).

.PARAMETER CredentialName
    Name des DB-Credentials (Default: IMPORT_CRED_NATIVE)

.PARAMETER BucketNamespace
    OCI Object Storage Namespace (Default: fry7uzt0fb8e)

.PARAMETER BucketName
    Name des Object Storage Buckets (Default: migration-bucket)

.PARAMETER DumpFile
    Name der Dump-Datei im Bucket (Default: DIRKSPZM32-260615.DMP)

.PARAMETER SourceSchema
    Quell-Schema fuer den Data-Pump-Import (Default: DIRKSPZM32)

.PARAMETER OutputFile
    Pfad fuer die generierte SQL-Datei.
    Default: %TEMP%\create_cred_<Zeitstempel>.sql

.PARAMETER WhatIf
    Trockenlauf: zeigt alle Parameter an, generiert aber keine Datei.

.EXAMPLE
    .\create-import-credential.ps1

.EXAMPLE
    .\create-import-credential.ps1 -CredentialName "IMPORT_CRED_NATIVE" -WhatIf

.EXAMPLE
    .\create-import-credential.ps1 -DumpFile "SCHEMA-260615.DMP" -SourceSchema "MYSCHEMA"
#>

param(
    [string]$CredentialName  = "IMPORT_CRED_NATIVE",
    [string]$BucketNamespace = "fry7uzt0fb8e",
    [string]$BucketName      = "migration-bucket",
    [string]$DumpFile        = "DIRKSPZM32-260615.DMP",
    [string]$SourceSchema    = "DIRKSPZM32",
    [string]$OutputFile      = "",
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

# --- OCI-Konfiguration lesen -------------------------------------------------
$configPath = "$env:USERPROFILE\.oci\config"
if (-not (Test-Path $configPath)) {
    throw "OCI Config nicht gefunden unter $configPath. Bitte zuerst 'oci setup config' ausfuehren."
}

$configLines = Get-Content $configPath

function Get-IniValue {
    param([string[]]$Lines, [string]$Key)
    $match = ($Lines | Select-String "^$Key\s*=" | Select-Object -First 1).ToString()
    if (-not $match) { throw "Schluessel '$Key' nicht in ~/.oci/config gefunden." }
    return $match.Split('=', 2)[1].Trim()
}

$userOcid    = Get-IniValue $configLines 'user'
$tenancyOcid = Get-IniValue $configLines 'tenancy'
$fingerprint = Get-IniValue $configLines 'fingerprint'
$region      = Get-IniValue $configLines 'region'
$keyFile     = Get-IniValue $configLines 'key_file'

# ~ in Pfad expandieren (PowerShell 5.1 expandiert ~ nicht in allen Kontexten)
if ($keyFile -match '^~[/\\]') {
    $keyFile = Join-Path $HOME $keyFile.Substring(2)
}

# --- Passphrase-Warnung ------------------------------------------------------
$ppLine = ($configLines | Select-String '^pass_phrase\s*=' | Select-Object -First 1)
if ($ppLine) {
    $ppVal = $ppLine.ToString().Split('=', 2)[1].Trim()
    if ($ppVal -ne '') {
        Write-Warning "API-Key ist passphrase-geschuetzt. DBMS_CLOUD.CREATE_CREDENTIAL erwartet einen unverschluesselten Key (PKCS#8 ohne Passphrase)."
    }
}

# --- Privaten Schluessel lesen und aufbereiten -------------------------------
if (-not (Test-Path $keyFile)) {
    throw "API-Key nicht gefunden: $keyFile"
}
$keyLines       = Get-Content $keyFile
$privateKeyBody = (
    $keyLines |
    Where-Object { $_ -notmatch '^-----' -and $_.Trim() -ne '' } |
    ForEach-Object { $_.Trim() }
) -join ''

# --- URI zusammensetzen ------------------------------------------------------
$bucketUri = "https://objectstorage.$region.oraclecloud.com/n/$BucketNamespace/b/$BucketName/o/"
$dumpUri   = $bucketUri + $DumpFile
$jobName   = "IMPORT_" + $SourceSchema.ToUpper()

# --- Ausgabepfad bestimmen ---------------------------------------------------
if (-not $OutputFile) {
    $ts         = Get-Date -Format 'yyyyMMdd_HHmmss'
    $OutputFile = Join-Path $env:TEMP "create_cred_$ts.sql"
}

# --- Parameter anzeigen ------------------------------------------------------
Write-Host "`n=== Credential-Parameter ===" -ForegroundColor Cyan
Write-Host "  Credential Name : $CredentialName"
Write-Host "  user_ocid       : $userOcid"
Write-Host "  tenancy_ocid    : $tenancyOcid"
Write-Host "  fingerprint     : $fingerprint"
Write-Host "  key_file        : $keyFile"
Write-Host "  region          : $region"
Write-Host "  Bucket-URI      : $bucketUri"
Write-Host "  Dump-URI        : $dumpUri"
Write-Host "  SQL-Ausgabe     : $OutputFile"

if ($WhatIf) {
    Write-Host "`n-WhatIf gesetzt: SQL-Datei wird NICHT erzeugt." -ForegroundColor Yellow
    return
}

# --- SQL-Skript generieren ---------------------------------------------------
$sql = @"
-- ============================================================
-- WARNUNG: Diese Datei enthaelt einen privaten API-Schluessel.
-- Sofort nach Gebrauch loeschen: Remove-Item '$OutputFile'
-- Erzeugt: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
-- ============================================================

SET DEFINE OFF

-- Credential loeschen falls bereits vorhanden (Fehler wird ignoriert)
BEGIN
  DBMS_CLOUD.DROP_CREDENTIAL(credential_name => '$CredentialName');
EXCEPTION WHEN OTHERS THEN NULL;
END;
/

-- Natives OCI-Credential anlegen
BEGIN
  DBMS_CLOUD.CREATE_CREDENTIAL(
    credential_name => '$CredentialName',
    user_ocid       => '$userOcid',
    tenancy_ocid    => '$tenancyOcid',
    private_key     => '$privateKeyBody',
    fingerprint     => '$fingerprint'
  );
END;
/

-- Verbindungstest: Bucket-Inhalte auflisten
-- Erwartet: Dump-Datei sichtbar, kein HTTP 401 / ORA-20401
-- Bei HTTP 403: IAM-Policy pruefen (Object Storage read fuer den OCI-User)
SELECT object_name, bytes
FROM TABLE(
  DBMS_CLOUD.LIST_OBJECTS(
    credential_name => '$CredentialName',
    location_uri    => '$bucketUri'
  )
);

-- ============================================================
-- Referenz: dp-Import-Befehl (in SQLcl ausfuehren, nicht hier)
-- ============================================================
-- Vorab-Pruefung (kein Job wird angelegt):
-- dp import -dumpuri "$dumpUri" -credential $CredentialName -schemas $SourceSchema -segmentattributes false -jobname $jobName -noexec true -verbose true
--
-- Echter Import (erst ausfuehren wenn LIST_OBJECTS erfolgreich):
-- dp import -dumpuri "$dumpUri" -credential $CredentialName -schemas $SourceSchema -segmentattributes false -jobname $jobName
"@

$sql | Set-Content -Path $OutputFile -Encoding ascii

# --- Naechste Schritte ausgeben ----------------------------------------------
Write-Host ""
Write-Host "SQL-Datei erzeugt: $OutputFile" -ForegroundColor Green
Write-Host ""
Write-Host "!!! WARNUNG: Datei enthaelt privaten API-Schluessel im Klartext !!!" -ForegroundColor Red
Write-Host ""
Write-Host "=== Naechste Schritte ===" -ForegroundColor Cyan
Write-Host "1. SQLcl mit ADB verbinden (Wallet-Pfad ggf. anpassen):"
Write-Host "   sql admin@<tns-alias>"
Write-Host "2. SQL-Skript ausfuehren:"
Write-Host "   @$OutputFile"
Write-Host "3. LIST_OBJECTS-Ergebnis pruefen:"
Write-Host "   - Sichtbar + kein Fehler -> weiter zu Schritt 4"
Write-Host "   - ORA-20401 (HTTP 401/403) -> IAM-Policy fuer OCI-User pruefen:"
Write-Host "     Allow <user/group> to read objects in compartment <compartment>"
Write-Host "4. Datei loeschen:"
Write-Host "   Remove-Item '$OutputFile'"
Write-Host "5. dp-Import-Befehl aus dem SQL-Kommentar kopieren und in SQLcl ausfuehren."
Write-Host ""
Write-Host "Fertig." -ForegroundColor Green
