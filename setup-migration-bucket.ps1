<#
.SYNOPSIS
    Legt einen Object-Storage-Bucket an und laedt optional eine Dump-Datei hoch.

.DESCRIPTION
    Das Skript:
      1. Ermittelt den Object-Storage-Namespace der Tenancy
      2. Ermittelt die Compartment-OCID anhand des Namens
      3. Prueft, ob der Bucket bereits existiert (idempotent)
      4. Legt den Bucket an, falls noch nicht vorhanden
      5. Laedt optional eine lokale Dump-Datei hoch (-DumpFilePath)

    Verwendung: Einmaliger Setup-Schritt vor dem Data-Pump-Import.
    Wiederholbarer Aufruf ist sicher (idempotent).

.PARAMETER CompartmentName
    Name des Compartments, in dem der Bucket angelegt wird (Default: Markus_Dev)

.PARAMETER BucketName
    Name des Object-Storage-Buckets (Default: migration-bucket)

.PARAMETER DumpFilePath
    Optionaler lokaler Pfad zur Dump-Datei, die hochgeladen werden soll.
    Ohne Angabe wird nur der Bucket angelegt (oder bestehender Bucket bestaetigt).

.PARAMETER ObjectName
    Name des Objekts im Bucket. Default: Dateiname aus DumpFilePath.

.PARAMETER Overwrite
    Wenn gesetzt, wird ein vorhandenes gleichnamiges Objekt im Bucket ueberschrieben.
    Ohne diesen Schalter bricht das Skript ab, wenn das Objekt bereits existiert.

.PARAMETER WhatIf
    Trockenlauf: zeigt alle Parameter an, nimmt aber keine Aenderungen vor.

.EXAMPLE
    .\setup-migration-bucket.ps1

.EXAMPLE
    .\setup-migration-bucket.ps1 -DumpFilePath "C:\exports\MYSCHEMA-260615.DMP"

.EXAMPLE
    .\setup-migration-bucket.ps1 -CompartmentName "OtherComp" -BucketName "other-bucket" -DumpFilePath "C:\exports\DUMP.DMP" -WhatIf
#>

param(
    [string]$CompartmentName = "Markus_Dev",
    [string]$BucketName      = "migration-bucket",
    [string]$DumpFilePath    = "",
    [string]$ObjectName      = "",
    [switch]$Overwrite,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

# --- Konfiguration pruefen ---------------------------------------------------
$configPath = "$env:USERPROFILE\.oci\config"
if (-not (Test-Path $configPath)) {
    throw "OCI Config nicht gefunden unter $configPath. Bitte zuerst 'oci setup config' ausfuehren."
}
$tenancyId = (Get-Content $configPath | Select-String '^tenancy\s*=' | Select-Object -First 1).ToString().Split('=', 2)[1].Trim()
$region    = (Get-Content $configPath | Select-String '^region\s*='  | Select-Object -First 1).ToString().Split('=', 2)[1].Trim()

# --- Lokale Dump-Datei pruefen (falls angegeben) ----------------------------
$doUpload = $DumpFilePath -ne ''
if ($doUpload) {
    if (-not (Test-Path $DumpFilePath)) {
        throw "Dump-Datei nicht gefunden: $DumpFilePath"
    }
    if (-not $ObjectName) {
        $ObjectName = Split-Path $DumpFilePath -Leaf
    }
}

# --- Object-Storage-Namespace ermitteln --------------------------------------
Write-Host "=== Object Storage ===" -ForegroundColor Cyan
$namespace = (oci os ns get | ConvertFrom-Json).data
Write-Host "  Namespace : $namespace"
Write-Host "  Region    : $region"

# --- Compartments laden und Compartment-OCID ermitteln -----------------------
Write-Host "`n=== Compartments ===" -ForegroundColor Cyan
$compartments = (oci iam compartment list --compartment-id $tenancyId | ConvertFrom-Json).data
$compartments | Select-Object name, id | Format-Table -AutoSize

$devCompId = ($compartments | Where-Object { $_.name -eq $CompartmentName }).id
if (-not $devCompId) { throw "Compartment '$CompartmentName' nicht gefunden." }
Write-Host "$CompartmentName Compartment-OCID: $devCompId"

# --- Parameter anzeigen ------------------------------------------------------
$bucketUri = "https://objectstorage.$region.oraclecloud.com/n/$namespace/b/$BucketName/o/"

Write-Host "`n=== Parameter ===" -ForegroundColor Cyan
Write-Host "  Compartment : $CompartmentName"
Write-Host "  Namespace   : $namespace"
Write-Host "  Region      : $region"
Write-Host "  Bucket      : $BucketName"
Write-Host "  Bucket-URI  : $bucketUri"
if ($doUpload) {
    $fileSize = [math]::Round((Get-Item $DumpFilePath).Length / 1MB, 1)
    Write-Host "  Upload      : $DumpFilePath ($fileSize MB)"
    Write-Host "  Objekt-Name : $ObjectName"
    Write-Host "  Overwrite   : $(if ($Overwrite) {'ja'} else {'nein'})"
} else {
    Write-Host "  Upload      : kein (-DumpFilePath nicht angegeben)"
}

if ($WhatIf) {
    Write-Host "`n-WhatIf gesetzt: Keine Aenderungen vorgenommen." -ForegroundColor Yellow
    return
}

# --- Bucket anlegen (idempotent) ---------------------------------------------
Write-Host "`n=== Bucket ===" -ForegroundColor Cyan
$buckets  = (oci os bucket list --compartment-id $devCompId --namespace $namespace | ConvertFrom-Json).data
$existing = $buckets | Where-Object { $_.name -eq $BucketName }

if ($existing) {
    Write-Host "Bucket '$BucketName' existiert bereits." -ForegroundColor Yellow
} else {
    Write-Host "Lege Bucket '$BucketName' an..."
    oci os bucket create `
        --compartment-id $devCompId `
        --namespace      $namespace `
        --name           $BucketName | Out-Null
    Write-Host "Bucket '$BucketName' angelegt." -ForegroundColor Green
}

# --- Dump-Datei hochladen (optional) ----------------------------------------
if ($doUpload) {
    Write-Host "`n=== Datei-Upload ===" -ForegroundColor Cyan

    $objects     = (oci os object list --bucket-name $BucketName --namespace $namespace | ConvertFrom-Json).data
    $existingObj = $objects | Where-Object { $_.name -eq $ObjectName }

    if ($existingObj -and -not $Overwrite) {
        throw "Objekt '$ObjectName' existiert bereits in '$BucketName'. Verwende -Overwrite zum Ueberschreiben."
    }

    if ($existingObj) { Write-Host "Ueberschreibe vorhandenes Objekt '$ObjectName'..." }
    Write-Host "Lade hoch: $DumpFilePath -> $ObjectName ..."

    $uploadArgs = @(
        "os", "object", "put",
        "--bucket-name", $BucketName,
        "--namespace",   $namespace,
        "--name",        $ObjectName,
        "--file",        $DumpFilePath
    )
    if ($Overwrite) { $uploadArgs += "--force" }
    & oci @uploadArgs | Out-Null

    Write-Host "Upload abgeschlossen." -ForegroundColor Green
    Write-Host "  Dump-URI: $($bucketUri + $ObjectName)"
}

Write-Host "`nFertig." -ForegroundColor Green
