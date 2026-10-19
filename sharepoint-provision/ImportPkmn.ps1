<#
Adds the Pokemon from the PokeAPI to the SharePoint List
Stores each Pokemon's sprite image URLs (SpriteNormalURL / SpriteShinyURL) from the PokeAPI; no images are downloaded
Change the $Limit variable to how many Pokemon you want to fetch
#>
$ErrorActionPreference = 'stop'
. .\SharePointParams.ps1 # Dot Source the SharePoint Param Script

$SharePointParams = Get-SharePointParams 

$ClientId = $SharePointParams.ClientId
$SiteUrl = $SharePointParams.SiteURL

$ExportFilePath = Join-Path $(Resolve-Path ..\data) -ChildPath "ListOfPokemon.csv"
$PokedexExportFilePath = Join-Path $(Resolve-Path ..\data) -ChildPath "PokedexEntries.csv"

$BaseUrl = "https://pokeapi.co/api/v2/pokemon/"
$Limit = 1400
$Offset = 0

$SP_Lists = @{
    Pokemon      = $SharePointParams.List_Pokemon
    Region       = $SharePointParams.List_Region
    PokeDexEntry = $SharePointParams.List_PokeDexEntry
    Pokemon_Type = $SharePointParams.List_Pokemon_Type
}

# ------------------------------------------------------------
# Functions (must be defined before first use below)
# ------------------------------------------------------------

function Get-ProperCase {
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    process {
        if ([string]::IsNullOrWhiteSpace($Text)) {
            return $Text
        }
        return (Get-Culture).TextInfo.ToTitleCase($Text.ToLower())
    }
}

function Convert-HectogramsToPounds {
    param (
        [double]$Hectograms
    )

    $conversionFactor = 0.220462
    $pounds = $Hectograms * $conversionFactor
    return [math]::Round($pounds, 4)
}

# ------------------------------------------------------------
# Connect
# ------------------------------------------------------------

Connect-PnPOnline $SiteUrl -Interactive -ClientId $ClientId

# ------------------------------------------------------------
# Bulk remove items from these lists (order matters if lookups reference each other)
# ------------------------------------------------------------

$ListsToClear = @($SP_Lists.Pokemon, $SP_Lists.Region, $SP_Lists.PokeDexEntry, $SP_Lists.Pokemon_Type)

# First pass: gather item counts for every list so we can show one combined summary
$ListItemsByName = @{}

foreach ($ListName in $ListsToClear) {
    $ListItemsByName[$ListName] = Get-PnPListItem -List $ListName 
}

$ListsWithItems = $ListsToClear | Where-Object { $ListItemsByName[$_].Count -gt 0 }

if ($ListsWithItems.Count -gt 0) {

    Write-Host "This will delete items from the following list(s):" -ForegroundColor Yellow
    foreach ($ListName in $ListsWithItems) {
        Write-Host "  - $ListName ($($ListItemsByName[$ListName].Count) item(s))" -ForegroundColor Yellow
    }

    $Confirmation = Read-Host "Type 'y' to confirm deletion for ALL of the above"

    if ($Confirmation -eq 'y') {
        foreach ($ListName in $ListsWithItems) {
            $listItems = $ListItemsByName[$ListName]
            $BatchDelete = New-PnPBatch
            $listItems | ForEach-Object { Remove-PnPListItem -List $ListName -Identity $_.Id -Batch $BatchDelete }
            Invoke-PnPBatch -Batch $BatchDelete
            Write-Host "Deleted $($listItems.Count) item(s) from '$ListName'." -ForegroundColor Green
        }
    }
    else {
        Write-Host "Deletion cancelled. No lists were modified." -ForegroundColor Cyan
    }
}
else {
    Write-Host "All lists are already empty. Nothing to delete." -ForegroundColor DarkGray
}

# ------------------------------------------------------------
# Import the Region data
# ------------------------------------------------------------

$RegionUri = "https://pokeapi.co/api/v2/region"
$Regions = (Invoke-RestMethod $RegionUri).results

foreach ($Region in $Regions) {

    $RegionDetails = Invoke-RestMethod -Uri $Region.url

    $RegionHash = [ordered]@{
        Title      = Get-ProperCase -Text $Region.name
        RegionId   = Split-Path $Region.url -Leaf
        Generation = $RegionDetails.main_generation.name
    }

    Add-PnPListItem -List $SP_Lists.Region -Values $RegionHash | Out-Null
}

$GetRegions = Get-PnPListItem -List $SP_Lists.Region

# ------------------------------------------------------------
# Import the Types
# ------------------------------------------------------------

$TypeUri = "https://pokeapi.co/api/v2/type/"
$Types = (Invoke-RestMethod $TypeUri).results

$BatchType = New-PnPBatch

foreach ($Type in $Types) {

    $TypeHash = @{
        Title         = Get-ProperCase -Text $Type.name
        PokemonTypeId = Split-Path $Type.url -Leaf
    }

    Add-PnPListItem -List $SP_Lists.Pokemon_Type -Values $TypeHash -Batch $BatchType
}

Invoke-PnPBatch $BatchType

# ------------------------------------------------------------
# Import the Pokemon
# ------------------------------------------------------------

function Invoke-RestMethodWithRetry {
    param(
        [Parameter(Mandatory)]
        [string]$Uri,
        [string]$Method = 'Get',
        [int]$MaxRetries = 4,
        [int]$DelaySeconds = 2
    )

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return Invoke-RestMethod -Method $Method -Uri $Uri
        }
        catch {
            if ($attempt -ge $MaxRetries) {
                Write-Error "Failed after $attempt attempts calling $Uri : $_"
                throw
            }
            Write-Warning "Attempt $attempt failed for $Uri . Retrying in $DelaySeconds seconds..."
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

$PokemonList = (Invoke-RestMethod -Method Get -Uri "$BaseUrl`?offset=$Offset&limit=$Limit").results

$Results = @()
$PokedexBatch = New-PnPBatch
$PokemonBatchCreate = New-PnPBatch
$PokdexResults=  @()

foreach ($Pokemon in $PokemonList) {

    Write-Host "Gathering data on $($Pokemon.name): $($Pokemon.url)" -ForegroundColor Cyan
    $PkmnData = Invoke-RestMethodWithRetry -Uri $Pokemon.url
    $SpriteNormal = $PkmnData.sprites.front_default
    $ShinyFrontSprite = $PkmnData.sprites.front_shiny

    $Species   = Invoke-RestMethodWithRetry -Uri $PkmnData.species.url
    $Generation = Invoke-RestMethodWithRetry -Uri $Species.generation.url

    Start-Sleep -Seconds 2
    $Pounds = Convert-HectogramsToPounds -Hectograms $PkmnData.weight

    $PkmnName = $PkmnData.name
    $ProperName = $PkmnName.Substring(0, 1).ToUpper() + $PkmnName.Substring(1)
      
    $TypeIdArray = @()
    $PkmnData.types.type.url | ForEach-Object {
        $TypeIdArray += ($_ -split '/')[-2]
    }

    $Region = Get-ProperCase -Text $Generation.main_region.name
    $RegionLookUp = ($GetRegions | Where-Object { $_.FieldValues.Title -eq $Region } | Select-Object -First 1)
    $Color = Get-ProperCase -Text $Species.color.name
    $Type1 = Get-ProperCase -Text $PkmnData.types[0].type.name
    $Type2 = Get-ProperCase -Text $PkmnData.types[1].type.name
    $SpriteNormalURL = $SpriteNormal
    $SpriteShinyURL = $ShinyFrontSprite
    $CaptureRate = $Species.capture_rate
    $GrowthRate = $Species.growth_rate.name
    $JapaneseName = ($Species.names | Where-Object { $_.language.name -eq "ja" }).Name
    $EnglishName = ($Species.names | Where-Object { $_.language.name -eq "en" }).Name
    $FrenchName = ($Species.names | Where-Object { $_.language.name -eq "fr" }).Name
    $Weight = [math]::Round($Pounds, 2) -as [string]
    $Height = [math]::Round($PkmnData.height * 3.93700787, 2) -as [string]

    $PokemonHash = [ordered]@{
        PokedexID    = $PkmnData.id -as [int]
        Title        = $ProperName
        CaptureRate = $CaptureRate -as [int]
        GrowthRate = $GrowthRate -as [string]
        HeightInches = $Height
        WeightLbs    = $Weight
        Types        = $TypeIdArray -join ';'
        Region       = $RegionLookUp.Id -as [int]
        RegionID     = $RegionLookUp.FieldValues.RegionId -as [int]
        Color        = $Color
        EnglishName  = $EnglishName
        JapaneseName = $JapaneseName
        FrenchName   = $FrenchName
        Type1        = $Type1
        Type2        = $Type2
        SpriteNormalURL = $SpriteNormalURL
        SpriteShinyURL  = $SpriteShinyURL
        SpeciesID    = $(Split-Path $PkmnData.species.url -Leaf) -as [int]
    }

    $Results += New-Object -TypeName psobject -Property $PokemonHash

    # Filter the English Pokedex Entry for the Pokemon - add to hash for batch upload later

    $EnglishEntries = $Species.flavor_text_entries | Where-Object { $_.language.name -eq "en" }
    try {


        Add-PnPListItem -List $SP_Lists.Pokemon -Values $PokemonHash -Batch $PokemonBatchCreate

        $PokeDexHash = [ordered]@{
        Title = $ProperName
        PokedexID   = $PkmnData.id -as [int]
        Data =  $EnglishEntries | ConvertTo-Json
        }

        $PokdexResults += New-Object -TypeName psobject -Property  $PokeDexHash    
    } 
    catch {
        Write-Warning "Failed to add item for $ProperName : $_"
    }

    $SpriteNormal = $null
    $ShinyFrontSprite  = $null
}

# Send Batch Pokedex Data

Invoke-PnPBatch $PokemonBatchCreate

# Get Pokemon Post Batch Run - we need the ids for the lookup for the Pokedex list

$PokemonEntries = Get-PnPListItem -List $SP_Lists.Pokemon

# Loop through PokeDex Entries to setup batch create

Write-Host "Uploading Pokedex data to list $($SP_Lists.PokeDexEntry)"

Foreach ($DexEntry in $PokdexResults){

    $PokemonLookup = $PokemonEntries | Where-Object {$_.FieldValues.PokedexID -eq $DexEntry.PokedexID} | Select-Object -First 1

    If($PokemonLookup){

        $PokeDexHash2 = [ordered]@{
        Title = $DexEntry.Title
        Pokemon = $PokemonLookup.Id
        PokedexID   = $DexEntry.PokedexID
        Data =  $DexEntry.Data
        }

        Add-PnPListItem -List $SP_Lists.PokeDexEntry -Values $PokeDexHash2 -Batch $PokedexBatch

    }

}

# Run the Batch Operation to Add the Pokedex Entries

Invoke-PnPBatch $PokedexBatch

# Export the results to CSV files

$Results | Export-Csv $ExportFilePath -NoTypeInformation
$PokdexResults | Export-Csv $PokedexExportFilePath -NoTypeInformation
