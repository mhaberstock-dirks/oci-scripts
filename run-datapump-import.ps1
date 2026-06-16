<#
.SYNOPSIS
    Importiert eine Dump-Datei aus Object Storage per SQLcl dp-Kommando in die ADB.

.DESCRIPTION
    Das Skript:
      1. Ermittelt den Object-Storage-Namespace und die Region aus ~/.oci/config
      2. Baut die Dump-URI zusammen
      3. Fuehrt den Data-Pump-Import per SQLcl 'dp import' aus
      4. Mit -NoExec: generiert den PL/SQL-Block ohne Job anzulegen (Vorab-Pruefung)

    Voraussetzung: DBMS_CLOUD-Credential muss existieren (create-import-credential.ps1).
    SQLcl ('sql') muss im PATH verfuegbar sein.
    TNS-Konfiguration (tnsnames.ora + Wallet) muss eingerichtet sein.

.PARAMETER BucketName
    Name des Object-Storage-Buckets (Default: migration-bucket)

.PARAMETER DumpFile
    Name der Dump-Datei im Bucket (Default: DIRKSPZM32-260615.DMP)

.PARAMETER SourceSchema
    Quell-Schema, das importiert werden soll (Default: DIRKSPZM32)

.PARAMETER DbName
    Datenbankname - wird zur Ableitung des Standard-TNS-Alias verwendet
    (Default: ADBDEV -> TNS-Alias: ADBDEV_HIGH)

.PARAMETER TnsAlias
    TNS-Alias fuer die SQLcl-Verbindung.
    Default: <DbName>_HIGH (z.B. ADBDEV_HIGH)

.PARAMETER CredName
    Name des DBMS_CLOUD-Credentials in der ADB (Default: IMPORT_CRED_NATIVE)

.PARAMETER JobName
    Name des Data-Pump-Jobs (Default: IMPORT_<SOURCESCHEMA>)

.PARAMETER AdminPassword
    Admin-Passwort der ADB als SecureString.
    Wird interaktiv abgefragt, wenn nicht angegeben.

.PARAMETER NoExec
    Trockenlauf auf DB-Seite: generiert den PL/SQL-Import-Block und zeigt ihn an,
    legt aber keinen Job an (-noexec true -verbose true).
    Nuetzlich zur Syntax-Pruefung vor dem echten Import.

.PARAMETER WhatIf
    PowerShell-Trockenlauf: zeigt alle Parameter an, verbindet sich aber nicht.

.EXAMPLE
    # Vorab-Pruefung (kein Job wird angelegt):
    .\run-datapump-import.ps1 -NoExec

.EXAMPLE
    # Echter Import:
    .\run-datapump-import.ps1

.EXAMPLE
    .\run-datapump-import.ps1 -DumpFile "MYSCHEMA-260615.DMP" -SourceSchema "MYSCHEMA" -NoExec
#>

# CredName ist ein DB-Objektname (z.B. "IMPORT_CRED_NATIVE"), kein Geheimnis.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingPlainTextForPassword', 'CredName',
    Justification = 'CredName ist ein DB-Objektname, kein Secret (z.B. IMPORT_CRED_NATIVE)')]
param(
    [string]$BucketName    = "migration-bucket",
    [string]$DumpFile      = "DIRKSPZM32-260615.DMP",
    [string]$SourceSchema  = "DIRKSPZM32",
    [string]$DbName        = "ADBDEV",
    [string]$TnsAlias      = "",
    [string]$CredName      = "IMPORT_CRED_NATIVE",
    [string]$JobName       = "",
    [securestring]$AdminPassword,
    [switch]$NoExec,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

# --- Konfiguration lesen -----------------------------------------------------
$configPath = "$env:USERPROFILE\.oci\config"
if (-not (Test-Path $configPath)) {
    throw "OCI Config nicht gefunden unter $configPath. Bitte zuerst 'oci setup config' ausfuehren."
}
$region = (Get-Content $configPath | Select-String '^region\s*=' | Select-Object -First 1).ToString().Split('=', 2)[1].Trim()

# --- Namespace, URIs und Defaults bestimmen ----------------------------------
$namespace = (oci os ns get | ConvertFrom-Json).data
$bucketUri = "https://objectstorage.$region.oraclecloud.com/n/$namespace/b/$BucketName/o/"
$dumpUri   = $bucketUri + $DumpFile

if (-not $TnsAlias) {
    $TnsAlias = ($DbName.ToUpper()) + "_HIGH"
}
if (-not $JobName) {
    $JobName = "IMPORT_" + $SourceSchema.ToUpper()
}

# --- Parameter anzeigen ------------------------------------------------------
Write-Host "`n=== Import-Parameter ===" -ForegroundColor Cyan
Write-Host "  Dump-URI        : $dumpUri"
Write-Host "  Schema          : $SourceSchema"
Write-Host "  DBMS_CLOUD-Cred : $CredName"
Write-Host "  Job-Name        : $JobName"
Write-Host "  TNS-Alias       : $TnsAlias"
Write-Host "  Modus           : $(if ($NoExec) {'-NoExec (Vorab-Pruefung, kein Job)'} else {'Echter Import'})"

if ($WhatIf) {
    Write-Host "`n-WhatIf gesetzt: Kein Import wird ausgefuehrt." -ForegroundColor Yellow
    return
}

if (-not $NoExec) {
    Write-Host ""
    Write-Host "ACHTUNG: Echter Import wird gestartet." -ForegroundColor Yellow
    Write-Host "Abbrechen mit Ctrl+C, Fortfahren mit Enter."
    $null = Read-Host
}

# --- Admin-Passwort abfragen (falls nicht uebergeben) ------------------------
if (-not $AdminPassword) {
    Write-Host ""
    $AdminPassword = Read-Host -AsSecureString "ADMIN-Passwort fuer $TnsAlias"
}

$bstr    = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassword)
$pwPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

# --- SQLcl-Skript mit dp-Kommando generieren ---------------------------------
$noexecFlag = if ($NoExec) { " -noexec true -verbose true" } else { "" }

$dpCmd = "dp import -dumpuri `"$dumpUri`" -credential $CredName -schemas $SourceSchema -segmentattributes false -jobname $JobName$noexecFlag"

$sql = @"
SET DEFINE OFF
$dpCmd
EXIT
"@

# --- SQLcl ausfuehren (temp-Datei wird automatisch geloescht) ----------------
$tmpFile = Join-Path $env:TEMP ([System.Guid]::NewGuid().ToString("N") + ".sql")
Write-Host "`n=== SQLcl-Verbindung: $TnsAlias ===" -ForegroundColor Cyan
if ($NoExec) {
    Write-Host "Vorab-Pruefung: PL/SQL-Block wird generiert (kein Import-Job)..." -ForegroundColor Yellow
} else {
    Write-Host "Import wird gestartet - dies kann mehrere Minuten dauern..." -ForegroundColor Yellow
}
try {
    $sql | Set-Content -Path $tmpFile -Encoding ascii
    & sql "admin/$pwPlain@$TnsAlias" "@$tmpFile"
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "SQLcl ist mit Exit-Code $LASTEXITCODE beendet worden."
    }
} finally {
    if (Test-Path $tmpFile) { Remove-Item -Path $tmpFile -Force }
    $pwPlain = $null
}

Write-Host "`nFertig." -ForegroundColor Green
if (-not $NoExec) {
    Write-Host "Fehler zu nicht unterstuetzten Objekttypen (ORA-39083, ORA-31685) sind bei ADB-Importen normal." -ForegroundColor Yellow
    Write-Host "Kritisch sind ORA-00001 (Unique-Constraint) und ORA-01950 (Quota)."
}
