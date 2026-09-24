<#
Provisions the Pokedex SharePoint lists: Pokemon, PokeDexEntry, Pokemon_Type
Run this once against a target site before running the data import script.
#>

. .\SharePointParams.ps1
$ErrorActionPreference = 'stop'
$SharePointParams = Get-SharePointParams # Dot Source the SharePoint Param Script

$ClientId = $ClientId = $SharePointParams.ClientId
$SiteUrl = $SharePointParams.SiteURL

Connect-PnPOnline $SiteUrl -Interactive -ClientId $ClientId

# ------------------------------------------------------------
# 1. Create the lists
# ------------------------------------------------------------

$ListsToCreate = @(
    $SharePointParams.List_Region, 
    $SharePointParams.List_Pokemon_Type,
    $SharePointParams.List_Pokemon,
    $SharePointParams.List_PokeDexEntry
)

foreach ($ListName in $ListsToCreate) {
    if (-not (Get-PnPList -Identity $ListName -ErrorAction SilentlyContinue)) {
        Write-Host "Creating list: $ListName" -ForegroundColor Blue
        New-PnPList -Title $ListName -Template GenericList -OnQuickLaunch | Out-Null
    }
    else {
        Write-Host "List already exists: $ListName" -ForegroundColor Yellow
    }
}

# ------------------------------------------------------------
# First List in Array
# ------------------------------------------------------------

Add-PnPField -List $SharePointParams.List_Region -InternalName "RegionId"      -DisplayName "RegionId"      -Type Number -AddToDefaultView
Add-PnPField -List $SharePointParams.List_Region -InternalName "Generation"    -DisplayName "Generation"    -Type Text   -AddToDefaultView

# ------------------------------------------------------------
# Second List in Array
# ------------------------------------------------------------

Add-PnPField -List $SharePointParams.List_Pokemon_Type -InternalName "PokemonTypeId" -DisplayName "PokemonTypeId" -Type Number -AddToDefaultView

# ------------------------------------------------------------
# Third  List in Array
# ------------------------------------------------------------

Add-PnPField -List $SharePointParams.List_Pokemon -InternalName "PokedexID"    -DisplayName "PokedexID"    -Type Number -AddToDefaultView
Add-PnPField -List $SharePointParams.List_Pokemon -InternalName "HeightInches" -DisplayName "HeightInches" -Type Number -AddToDefaultView
Add-PnPField -List $SharePointParams.List_Pokemon -InternalName "WeightLbs"    -DisplayName "WeightLbs"    -Type Number -AddToDefaultView
Add-PnPField -List $SharePointParams.List_Pokemon -InternalName "Types"        -DisplayName "Types"        -Type Text   -AddToDefaultView
Add-PnPField -List $SharePointParams.List_Pokemon -InternalName "Color"        -DisplayName "Color"        -Type Text   -AddToDefaultView
Add-PnPField -List $SharePointParams.List_Pokemon -InternalName "Type1"        -DisplayName "Type1"        -Type Text   -AddToDefaultView
Add-PnPField -List $SharePointParams.List_Pokemon -InternalName "Type2"        -DisplayName "Type2"        -Type Text   -AddToDefaultView
Add-PnPField -List $SharePointParams.List_Pokemon -InternalName "JapaneseName" -DisplayName "JapaneseName" -Type Text   -AddToDefaultView
Add-PnPField -List $SharePointParams.List_Pokemon -InternalName "EnglishName"  -DisplayName "EnglishName"  -Type Text   -AddToDefaultView
Add-PnPField -List $SharePointParams.List_Pokemon -InternalName "FrenchName"   -DisplayName "FrenchName"   -Type Text   -AddToDefaultView
Add-PnPField -List $SharePointParams.List_Pokemon -InternalName "SpeciesID"    -DisplayName "SpeciesID"    -Type Number -AddToDefaultView
Add-PnPField -List $SharePointParams.List_Pokemon -InternalName "RegionID"     -DisplayName "RegionID"     -Type Number -AddToDefaultView
Add-PnPField -List $SharePointParams.List_Pokemon -InternalName "CaptureRate"  -DisplayName "CaptureRate"  -Type Number -AddToDefaultView
Add-PnPField -List $SharePointParams.List_Pokemon -InternalName "GrowthRate"   -DisplayName "GrowthRate"   -Type Text   -AddToDefaultView
Add-PnPField -List $SharePointParams.List_Pokemon -InternalName "SpriteNormalURL" -DisplayName "SpriteNormalURL" -Type URL -AddToDefaultView
Add-PnPField -List $SharePointParams.List_Pokemon -InternalName "SpriteShinyURL" -DisplayName "SpriteShinyURL" -Type URL -AddToDefaultView

# Lookup to Region list
Add-PnPField -List $SharePointParams.List_Pokemon -InternalName "Region" -DisplayName "Region" -Type Lookup
Set-PnPField -List $SharePointParams.List_Pokemon -Identity "Region" -Values @{
    LookupList  = (Get-PnPList $SharePointParams.List_Region).Id.ToString()
    LookupField = "Title"
}

# ------------------------------------------------------------
# Fourth  List in Array
# ------------------------------------------------------------

Add-PnPField -List $SharePointParams.List_PokeDexEntry -InternalName "PokedexID"   -DisplayName "PokedexID"   -Type Number -AddToDefaultView
Add-PnPField -List $SharePointParams.List_PokeDexEntry -InternalName "GameVersion" -DisplayName "GameVersion" -Type Text   -AddToDefaultView
Add-PnPField -List $SharePointParams.List_PokeDexEntry -InternalName "Data" -DisplayName "Data" -Type Note   -AddToDefaultView

# Lookup to Pokemon list, showing PokedexID as the secondary display field

Add-PnPField -List $SharePointParams.List_PokeDexEntry -InternalName "Pokemon" -DisplayName "Pokemon" -Type Lookup
Set-PnPField -List $SharePointParams.List_PokeDexEntry -Identity "Pokemon" -Values @{
    LookupList  = (Get-PnPList $SharePointParams.List_Pokemon).Id.ToString()
    LookupField = "Title"
}

Write-Host "`nProvisioning complete." -ForegroundColor Green