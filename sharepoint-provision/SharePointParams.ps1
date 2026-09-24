function Get-SharePointParams {

    <#
    .SYNOPSIS

    This is a helper script to input the desired Site and List Names to be refered during the Create Lists and Import Pokemon Scripts

    #>

    $params = [ordered]@{
        SiteURL           = ""
        List_Pokemon      = "Pokemon"
        List_Region       = "Region"
        List_PokeDexEntry = "PokeDexEntry"
        List_Pokemon_Type = "Pokemon_Type"
        ClientId = $Global:ClientID # Client Id used for PnP Authentication
    }

    foreach ($key in $params.Keys) {
        if ([string]::IsNullOrWhiteSpace($params[$key])) {
            throw "Missing required value for '$key' in Get-SharePointParams. Stopping script."
        }
    }

    return $params
}