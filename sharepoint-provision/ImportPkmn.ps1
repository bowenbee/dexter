<#
Adds the Pokemon from the PokeAPI to the SharePoint List
Downloads the Pokemone's Sprites to a local folder and uploads to Pokemon's Record
Change the $Limit variable to how many Pokemon you want to fetch
#>
$ErrorActionPreference = 'stop'
. .\SharePointParams.ps1 # Dot Source the SharePoint Param Script

$SharePointParams = Get-SharePointParams 

$ClientId = $SharePointParams.ClientId
$SiteUrl = $SharePointParams.SiteURL

$ExportFilePath = Join-Path $(Resolve-Path ..\data) -ChildPath "ListOfPokemon.csv"
$SpriteFolderPath = "..\data\Sprites"

if (!(Test-Path $SpriteFolderPath)) {
    New-Item -Path $SpriteFolderPath -ItemType Directory | Out-Null
}

$SpriteFolder = $(Resolve-Path $SpriteFolderPath).Path
$ShinySpriteFolder = Join-Path $SpriteFolder -ChildPath "shiny"

if (!(Test-Path $ShinySpriteFolder)) {
    New-Item -Path $ShinySpriteFolder -ItemType Directory | Out-Null
}

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

function Get-ImageWithRetry {
    param(
        [string]$Uri,
        [string]$OutFile,
        [int]$MaxRetries = 5
    )

    $attempt = 0
    while ($attempt -lt $MaxRetries) {
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -ErrorAction Stop
            return $true
        }
        catch {
            $response = $_.Exception.Response
            if ($response -and [int]$response.StatusCode -eq 429) {
                $retryAfter = $response.Headers["Retry-After"]
                $wait = if ($retryAfter) { [int]$retryAfter } else { [math]::Pow(2, $attempt) }
                Write-Warning "429 hit for $Uri. Waiting $wait seconds..."
                Start-Sleep -Seconds $wait
                $attempt++
            }
            else {
                Write-Warning "Failed to download $Uri : $_"
                return $false
            }
        }
    }
    Write-Warning "Max retries exceeded for $Uri"
    return $false
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

$ListsToClear = @($SP_Lists.Pokemon, $SP_Lists.Region, $SP_Lists.Pokemon_Type, $SP_Lists.PokeDexEntry)

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

$PokemonList = (Invoke-RestMethod -Method Get -Uri "$BaseUrl`?offset=$Offset&limit=$Limit").results

$Results = @()
$PokedexBatch = New-PnPBatch
$PokemonBatchCreate = New-PnPBatch
$PokdexResults=  @()
$SpritesResults  = @()

foreach ($Pokemon in $PokemonList) {

    Write-Host "Gathering data on $($Pokemon.name): $($Pokemon.url)" -ForegroundColor Cyan
    $PkmnData = Invoke-RestMethod -Method Get $Pokemon.url
    $SpriteNormal = $PkmnData.sprites.front_default
    $ShinyFrontSprite = $PkmnData.sprites.front_shiny 

    If($null -ne $SpriteNormal){

        $SpriteNormalPath = $(Join-Path -Path $SpriteFolder -ChildPath $(Split-Path $SpriteNormal -Leaf))
        $LocalSpriteFound = Test-Path $SpriteNormalPath

        If(!$LocalSpriteFound){

            Get-ImageWithRetry -Uri $SpriteNormal -OutFile $SpriteNormalPath | out-null
            Start-Sleep -Seconds 0.2

        }

    }

    If($null -ne $ShinyFrontSprite){
        $NewShinyFileName = "shiny-" + $(Split-Path -Path $ShinyFrontSprite -Leaf)
        $SpriteShinyPath = $(Join-Path -Path $ShinySpriteFolder -ChildPath $NewShinyFileName)
        $LocalShinySpriteFound = Test-Path $SpriteShinyPath

        If(!$LocalShinySpriteFound){

            Get-ImageWithRetry -Uri $ShinyFrontSprite -OutFile $SpriteShinyPath | out-null
            Start-Sleep -Seconds 0.2

        }
        
    }

    $Species = Invoke-RestMethod -Method Get -Uri $PkmnData.species.url
    $Generation = Invoke-RestMethod $Species.generation.url
    Start-Sleep -Seconds 1
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

    # Add the Sprites for the Batch Uploading Later

    $SpriteHash = [ordered] @{
        ID = $PkmnData.id
        Normal =  $SpriteNormalPath
        Shiny = $SpriteShinyPath 
    }

    $SpritesResults += New-Object -TypeName psobject -Property $SpriteHash
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

# Upload the Sprites

Foreach ($PokemonEntry in $PokemonEntries){
    
    $SpriteRecord = $SpritesResults | Where-Object {$_.ID -eq $PokemonEntry.FieldValues.PokedexID} | Select-Object -First 1
    
    If($null -ne $SpriteRecord.Normal){

        Write-Host "Uploading Sprites for $($PokemonEntry.FieldValues.PokedexID) - $($PokemonEntry.FieldValues.Title)"

        Set-PnPImageListItemColumn -List $SP_Lists.Pokemon -Identity $PokemonEntry.Id -Field "Sprite" -Path $SpriteRecord.Normal | Out-Null
    }

    If($null -ne $SpriteRecord.Shiny){

        Set-PnPImageListItemColumn -List $SP_Lists.Pokemon -Identity $PokemonEntry.Id -Field "SpriteShiny" -Path $SpriteRecord.Shiny | Out-Null
    }

}

$Results | Export-Csv $ExportFilePath -NoTypeInformation
