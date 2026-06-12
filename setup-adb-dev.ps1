<#
.SYNOPSIS
    Validiert vorhandene OCI-Ressourcen (Compartment, Group) und legt eine
    Policy fuer die Verwaltung einer Autonomous Database (Dev/Always-Free) an.

.DESCRIPTION
    Das Skript:
      1. Liest die Tenancy-OCID aus ~/.oci/config
      2. Listet Identity Domains, Compartments und Groups
      3. Ermittelt OCIDs fuer das angegebene Compartment und die Gruppe
      4. Erzeugt eine policies/<PolicyName>.json mit den Statements
      5. Legt die Policy an (sofern noch nicht vorhanden)

.PARAMETER CompartmentName
    Name des Ziel-Compartments (Default: Markus_Dev)

.PARAMETER GroupName
    Name der Gruppe, die Rechte erhalten soll (Default: Grp-ADB-Dev-Admins)

.PARAMETER PolicyName
    Name der anzulegenden Policy (Default: Policy-ADB-Dev-Admins)

.PARAMETER DomainPrefix
    Optionaler Identity-Domain-Praefix fuer Policy-Statements
    (z.B. "MyDomain" -> 'MyDomain'/'GroupName'). Leer lassen, falls
    Default-Domain bzw. altes IAM-Modell ohne benannte Domains genutzt wird.

.PARAMETER WhatIfOnly
    Wenn gesetzt, wird die Policy NICHT angelegt, sondern nur die
    Statements-Datei erzeugt und alle Infos angezeigt (Trockenlauf).

.EXAMPLE
    .\setup-adb-dev.ps1

.EXAMPLE
    .\setup-adb-dev.ps1 -CompartmentName "Markus_Dev" -GroupName "Grp-ADB-Dev-Admins" -WhatIfOnly
#>

param(
    [string]$CompartmentName = "Markus_Dev",
    [string]$GroupName       = "Grp-ADB-Dev-Admins",
    [string]$PolicyName      = "Policy-ADB-Dev-Admins",
    [string]$DomainPrefix    = "",
    [switch]$WhatIfOnly
)

$ErrorActionPreference = "Stop"

# --- Tenancy-OCID aus Config lesen -----------------------------------------
$configPath = "$env:USERPROFILE\.oci\config"
if (-not (Test-Path $configPath)) {
    throw "OCI Config nicht gefunden unter $configPath. Bitte zuerst 'oci setup config' ausfuehren."
}
$tenancyId = (Get-Content $configPath | Select-String "^tenancy=").ToString().Split("=")[1].Trim()

Write-Host "=== Identity Domains ===" -ForegroundColor Cyan
$domains = (oci iam domain list --compartment-id $tenancyId | ConvertFrom-Json).data
$domains | Select-Object @{N='Name';E={$_.'display-name'}}, url | Format-Table -AutoSize

Write-Host "`n=== Compartments ===" -ForegroundColor Cyan
$compartments = (oci iam compartment list | ConvertFrom-Json).data
$compartments | Select-Object name, id | Format-Table -AutoSize

Write-Host "`n=== Groups ===" -ForegroundColor Cyan
$groups = (oci iam group list | ConvertFrom-Json).data
$groups | Select-Object name, id | Format-Table -AutoSize

# --- OCIDs ermitteln ---------------------------------------------------------
$devCompId = ($compartments | Where-Object { $_.name -eq $CompartmentName }).id
$groupId   = ($groups | Where-Object { $_.name -eq $GroupName }).id

if (-not $devCompId) { throw "Compartment '$CompartmentName' nicht gefunden." }
if (-not $groupId)   { throw "Gruppe '$GroupName' nicht gefunden." }

Write-Host "`n$CompartmentName Compartment-OCID: $devCompId"
Write-Host "$GroupName Group-OCID: $groupId"

# --- Gruppenname fuer Policy-Statements (mit optionalem Domain-Praefix) -----
if ($DomainPrefix -ne "") {
    $groupRef = "'$DomainPrefix'/'$GroupName'"
} else {
    $groupRef = $GroupName
}

# --- Policy-Statements erzeugen ---------------------------------------------
$policiesDir = Join-Path $PSScriptRoot "policies"
if (-not (Test-Path $policiesDir)) {
    New-Item -ItemType Directory -Path $policiesDir | Out-Null
}
$statementsPath = Join-Path $policiesDir "$PolicyName.json"

$statements = @(
    "Allow group $groupRef to manage autonomous-database-family in compartment $CompartmentName",
    "Allow group $groupRef to manage autonomous-backups in compartment $CompartmentName",
    "Allow group $groupRef to use virtual-network-family in compartment $CompartmentName"
)

$statements | ConvertTo-Json | Out-File -Encoding utf8 $statementsPath
Write-Host "`nStatements-Datei erzeugt: $statementsPath" -ForegroundColor Green
Get-Content $statementsPath

if ($WhatIfOnly) {
    Write-Host "`n-WhatIfOnly gesetzt: Policy wird NICHT angelegt." -ForegroundColor Yellow
    return
}

# --- Pruefen, ob Policy bereits existiert ------------------------------------
$policies = (oci iam policy list --compartment-id $devCompId | ConvertFrom-Json).data
$existing = ($policies | Where-Object { $_.name -eq $PolicyName }).id

if ($existing) {
    Write-Host "`nPolicy '$PolicyName' existiert bereits (OCID: $existing)." -ForegroundColor Yellow
    Write-Host "Aktualisiere Statements..." -ForegroundColor Yellow
    oci iam policy update `
        --policy-id $existing `
        --statements "file://$statementsPath" `
        --force
} else {
    Write-Host "`n=== Policy anlegen ===" -ForegroundColor Cyan
    oci iam policy create `
        --compartment-id $devCompId `
        --name $PolicyName `
        --description "Berechtigungen fuer Entwicklungs-ADB in $CompartmentName" `
        --statements "file://$statementsPath"
}

Write-Host "`nFertig." -ForegroundColor Green