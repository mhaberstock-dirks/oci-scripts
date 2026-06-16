<#
.SYNOPSIS
    Legt eine vollstaendige OCI-Benutzerumgebung an (User, Compartment, Group, Policy).

.DESCRIPTION
    Idempotentes Skript: Jeder Schritt wird nur ausgefuehrt, wenn der jeweilige
    Zustand noch nicht existiert. Mehrfachaufrufe sind sicher.

    Das Skript:
      1. Legt einen OCI-IAM-Benutzer an (oder verwendet einen bestehenden)
      2. Legt ein Compartment direkt unter der Tenancy-Root an
      3. Legt eine Group an
      4. Fuegt den Benutzer der Group hinzu (falls noch kein Mitglied)
      5. Legt eine Policy an: "manage all-resources in compartment <Name>"
         (oder aktualisiert eine bestehende Policy)

    Nach dem Aufruf kann der Benutzer mit seinen eigenen OCI-CLI-Credentials
    die Skripte create-adb-dev.ps1, setup-migration-bucket.ps1 und
    run-datapump-import.ps1 verwenden (jeweils mit -CompartmentName <Name>).

    Voraussetzung: Aufruf durch einen Tenant-Administrator mit entsprechenden
    IAM-Rechten (manage users, manage compartments, manage groups, manage policies
    in tenancy).

.PARAMETER UserName
    OCI-Benutzername (Pflichtparameter).
    Darf nur ASCII-Zeichen enthalten (keine Leerzeichen, keine Sonderzeichen
    ausser Bindestrich und Unterstrich).
    Wird zur Ableitung von Compartment-, Group- und Policy-Namen verwendet.

.PARAMETER UserEmail
    E-Mail-Adresse des Benutzers (empfohlen, optional).

.PARAMETER CompartmentName
    Name des anzulegenden Compartments. Default: <UserName>_Dev

.PARAMETER GroupName
    Name der anzulegenden Group. Default: Grp-<UserName>-Dev

.PARAMETER PolicyName
    Name der anzulegenden Policy. Default: Policy-<UserName>-Dev

.PARAMETER Description
    Freitext-Beschreibung fuer User, Compartment und Group.
    Default: "Entwicklungsumgebung fuer <UserName>"

.PARAMETER WhatIf
    Trockenlauf: zeigt alle geplanten Aktionen an, nimmt aber keine Aenderungen vor.

.EXAMPLE
    .\create-user-env.ps1 -UserName "MaxMustermann" -UserEmail "max@example.com"

.EXAMPLE
    .\create-user-env.ps1 -UserName "MaxMustermann" -WhatIf

.EXAMPLE
    .\create-user-env.ps1 -UserName "MaxMustermann" -CompartmentName "MaxDev" -GroupName "Grp-MaxDev"
#>

param(
    [string]$UserName        = "",
    [string]$UserEmail       = "",
    [string]$CompartmentName = "",
    [string]$GroupName       = "",
    [string]$PolicyName      = "",
    [string]$Description     = "",
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

# --- Pflichtparameter pruefen ------------------------------------------------
if (-not $UserName) {
    Write-Host @"

VERWENDUNG: .\create-user-env.ps1 -UserName <name> [Optionen]

Legt eine vollstaendige OCI-Benutzerumgebung an: User, Compartment, Group
und Policy (manage all-resources). Idempotent - Mehrfachaufruf ist sicher.

PFLICHT:
  -UserName <name>          OCI-Benutzername (ASCII, keine Leerzeichen)

OPTIONAL:
  -UserEmail <email>        E-Mail-Adresse (empfohlen)
  -CompartmentName <name>   Default: <UserName>_Dev
  -GroupName <name>         Default: Grp-<UserName>-Dev
  -PolicyName <name>        Default: Policy-<UserName>-Dev
  -Description <text>       Default: "Entwicklungsumgebung fuer <UserName>"
  -WhatIf                   Trockenlauf: zeigt Aktionen, nimmt keine Aenderungen vor

BEISPIELE:
  .\create-user-env.ps1 -UserName "MaxMustermann" -UserEmail "max@example.com"
  .\create-user-env.ps1 -UserName "MaxMustermann" -WhatIf

"@
    exit 1
}

# --- Defaults ableiten -------------------------------------------------------
if (-not $CompartmentName) { $CompartmentName = "${UserName}_Dev" }
if (-not $GroupName)       { $GroupName       = "Grp-${UserName}-Dev" }
if (-not $PolicyName)      { $PolicyName      = "Policy-${UserName}-Dev" }
if (-not $Description)     { $Description     = "Entwicklungsumgebung fuer $UserName" }

# --- Konfiguration lesen -----------------------------------------------------
$configPath = "$env:USERPROFILE\.oci\config"
if (-not (Test-Path $configPath)) {
    throw "OCI Config nicht gefunden unter $configPath. Bitte zuerst 'oci setup config' ausfuehren."
}
$tenancyId = (Get-Content $configPath | Select-String '^tenancy\s*=' | Select-Object -First 1).ToString().Split('=', 2)[1].Trim()

# --- Geplante Aktionen anzeigen ----------------------------------------------
$userDisplay = if ($UserEmail) { "$UserName <$UserEmail>" } else { $UserName }
Write-Host "`n=== Geplante Benutzerumgebung ===" -ForegroundColor Cyan
Write-Host "  User            : $userDisplay"
Write-Host "  Compartment     : $CompartmentName  (unter Tenancy-Root)"
Write-Host "  Group           : $GroupName"
Write-Host "  Policy          : $PolicyName"
Write-Host "  Policy-Statement: Allow group $GroupName to manage all-resources in compartment $CompartmentName"
Write-Host "  Beschreibung    : $Description"

if ($WhatIf) {
    Write-Host "`n-WhatIf gesetzt: Keine Aenderungen vorgenommen." -ForegroundColor Yellow
    return
}

# --- Bestehende IAM-Ressourcen laden -----------------------------------------
Write-Host "`n=== IAM-Ressourcen laden ===" -ForegroundColor Cyan
$allUsers  = (oci iam user list        --compartment-id $tenancyId --all | ConvertFrom-Json).data
$allComps  = (oci iam compartment list --compartment-id $tenancyId --all | ConvertFrom-Json).data
$allGroups = (oci iam group list       --compartment-id $tenancyId --all | ConvertFrom-Json).data
$allPols   = (oci iam policy list      --compartment-id $tenancyId --all | ConvertFrom-Json).data

# --- User --------------------------------------------------------------------
Write-Host "`n--- User: $UserName ---"
$existingUser = $allUsers | Where-Object { $_.name -eq $UserName }
if ($existingUser) {
    $userId = $existingUser.id
    Write-Host "  Existiert bereits." -ForegroundColor Yellow
    Write-Host "  OCID  : $userId"
    Write-Host "  State : $($existingUser.'lifecycle-state')"
} else {
    Write-Host "  Lege an..."
    $createArgs = @(
        "iam", "user", "create",
        "--compartment-id", $tenancyId,
        "--name",           $UserName,
        "--description",    $Description
    )
    if ($UserEmail) { $createArgs += @("--email", $UserEmail) }
    $newUser = (& oci @createArgs | ConvertFrom-Json).data
    $userId  = $newUser.id
    Write-Host "  Angelegt." -ForegroundColor Green
    Write-Host "  OCID  : $userId"
}

# --- Compartment -------------------------------------------------------------
Write-Host "`n--- Compartment: $CompartmentName ---"
$existingComp = $allComps | Where-Object { $_.name -eq $CompartmentName }
if ($existingComp) {
    $compId = $existingComp.id
    Write-Host "  Existiert bereits." -ForegroundColor Yellow
    Write-Host "  OCID  : $compId"
    Write-Host "  State : $($existingComp.'lifecycle-state')"
} else {
    Write-Host "  Lege an..."
    $newComp = (oci iam compartment create `
        --compartment-id $tenancyId `
        --name           $CompartmentName `
        --description    $Description | ConvertFrom-Json).data
    $compId = $newComp.id
    Write-Host "  Angelegt." -ForegroundColor Green
    Write-Host "  OCID  : $compId"
}

# --- Group -------------------------------------------------------------------
Write-Host "`n--- Group: $GroupName ---"
$existingGroup = $allGroups | Where-Object { $_.name -eq $GroupName }
if ($existingGroup) {
    $groupId = $existingGroup.id
    Write-Host "  Existiert bereits." -ForegroundColor Yellow
    Write-Host "  OCID  : $groupId"
} else {
    Write-Host "  Lege an..."
    $newGroup = (oci iam group create `
        --compartment-id $tenancyId `
        --name           $GroupName `
        --description    $Description | ConvertFrom-Json).data
    $groupId = $newGroup.id
    Write-Host "  Angelegt." -ForegroundColor Green
    Write-Host "  OCID  : $groupId"
}

# --- Mitgliedschaft ----------------------------------------------------------
Write-Host "`n--- Mitgliedschaft: $UserName in $GroupName ---"
$memberships = (oci iam group list-users --group-id $groupId --compartment-id $tenancyId | ConvertFrom-Json).data
$isMember    = $memberships | Where-Object { $_.'user-id' -eq $userId }
if ($isMember) {
    Write-Host "  Bereits Mitglied." -ForegroundColor Yellow
} else {
    Write-Host "  Fuege hinzu..."
    oci iam group add-user --group-id $groupId --user-id $userId | Out-Null
    Write-Host "  Hinzugefuegt." -ForegroundColor Green
}

# --- Policy ------------------------------------------------------------------
Write-Host "`n--- Policy: $PolicyName ---"
$policiesDir    = Join-Path $PSScriptRoot "policies"
if (-not (Test-Path $policiesDir)) {
    New-Item -ItemType Directory -Path $policiesDir | Out-Null
}
$statementsPath = Join-Path $policiesDir "$PolicyName.json"
$statements     = @("Allow group $GroupName to manage all-resources in compartment $CompartmentName")
$statements | ConvertTo-Json | Set-Content -Path $statementsPath -Encoding ascii

$existingPol = $allPols | Where-Object { $_.name -eq $PolicyName }
if ($existingPol) {
    Write-Host "  Existiert bereits - aktualisiere Statements..."
    oci iam policy update `
        --policy-id  $existingPol.id `
        --statements "file://$statementsPath" `
        --force | Out-Null
    Write-Host "  Aktualisiert." -ForegroundColor Green
} else {
    Write-Host "  Lege an..."
    oci iam policy create `
        --compartment-id $tenancyId `
        --name           $PolicyName `
        --description    $Description `
        --statements     "file://$statementsPath" | Out-Null
    Write-Host "  Angelegt." -ForegroundColor Green
}

# --- Zusammenfassung und naechste Schritte -----------------------------------
Write-Host "`n=== Benutzerumgebung eingerichtet ===" -ForegroundColor Green
Write-Host "  User-OCID       : $userId"
Write-Host "  Compartment-OCID: $compId"
Write-Host "  Compartment-Name: $CompartmentName"
Write-Host "  Group-OCID      : $groupId"

Write-Host "`n=== Naechste Schritte ===" -ForegroundColor Cyan
Write-Host "1. API-Key fuer $UserName generieren und hochladen:"
Write-Host "   oci iam user api-key upload --user-id $userId --key-file <pfad-zum-oeffentlichen-schluessel>"
Write-Host "   (oder: Benutzer richtet API-Key selbst in der OCI-Console ein)"
Write-Host "2. ~/.oci/config auf dem Rechner des Benutzers einrichten:"
Write-Host "   user=$userId"
Write-Host "   tenancy=<tenancy-ocid>"
Write-Host "   region=<region>"
Write-Host "   fingerprint=<fingerprint-des-api-key>"
Write-Host "   key_file=<pfad-zum-privaten-schluessel>"
Write-Host "3. ADB anlegen (als Benutzer, mit eigenem OCI-Profil):"
Write-Host "   .\create-adb-dev.ps1 -CompartmentName '$CompartmentName'"
Write-Host "4. Migration-Bucket anlegen:"
Write-Host "   .\setup-migration-bucket.ps1 -CompartmentName '$CompartmentName'"
Write-Host ""
Write-Host "Fertig." -ForegroundColor Green
