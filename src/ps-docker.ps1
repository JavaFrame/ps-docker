<#
A half assed docker implementation in powershell
Version: 0.1
Authors: Sebastian Zumbrunn
#>

<#Settings classes and functions#>
class Settings {

}

<#
.Description
Reads the settings either from the given path or if no path is given from ~/.config/ps-docker/settings.json
.Parameter [string]$path the path 
#>
function Read-Settings([string] $path = "~/.config/ps-docker/settings.json") {
    try {
        return [System.Web.Script.Serializatoin.JavaScriptSerializer]::new().Deserialize((Get-Content $path), [Settings])
    } catch {
        Write-Error "Couldn't read settings because of: $_"
    }
    return [Settings]::new();
}

function Write-Settings([Settings] $settingsObj, [string] $path = "~/.config/ps-docker/settings.json") {
    try {
        ConvertTo-Json $settingsObj | Set-Content $path
        return $true;
    } catch {
        Write-Error "Couldn't write settings because of: $_"
        return $false;
    }
}

$script:globalSettings = Read-Settings

$script:dockerAuthUrl = "https://auth.docker.io/token";

<#
Docker Api
#>

class Container {
    
}


class ContainerDef {
    [string]$registryUrl = "registry-1.docker.io"
    [string]$library = "library"
    [string]$image
    [string]$tag = "latest"
}

<#
Parses a docker image reference string (like ubuntu:latest or seppli/lewebseite:1.0) and 
returns a ContainerDef object. The registry is currently always "registry-1.docker.io" and can't
be changed (so custom-registry.ch/ubuntu:latest wouldn't work)
#>
function ConvertTo-ContainerDef([string] $dockerDef) {
    $obj = [ContainerDef]::new();
    $splitted = $dockerDef.Split("/", 2)
    $obj.image = $splitted[0];
    if($splitted.Length -gt 1) {
        $obj.library = $splitted[0]
        $imgPlusTag = $splitted[1];
    } else {
        $obj.library = "library"
        $imgPlusTag = $splitted[0];
    }
    # check if tag exists in string
    $splitted = $imgPlusTag.Split(":")
    $obj.image = $splitted[0];
    if($splitted.Length -gt 1) {
        $obj.tag = $splitted[1];
    } 

    return $obj;
}

function Get-AuthToken([ContainerDef] $def, [string]$scope="pull") {
    $response = Invoke-RestMethod "$dockerAuthUrl`?service=registry.docker.io&scope=repository:$($def.library)/$($def.image):$scope"
    return $response.token
}

function Get-AuthHeaderObj([ContainerDef] $def, [string]$scope="pull") {
    $token = Get-AuthToken $def
    return @{ "Authorization" = "Bearer $token" }
}

function Get-Manifest([ContainerDef] $def) {
    $headers = Get-AuthHeaderObj $def
    return Invoke-RestMethod "https://$($def.registryUrl)/v2/$($def.library)/$($def.image)/manifests/$($def.tag)" -Headers $headers
}

function Get-Layer([ContainerDef] $def, [string] $shaLayer) {
    $url = "https://$($def.registryUrl)/v2/$($def.library)/$($def.image)/blobs/$shaLayer"
    $headers = Get-AuthHeaderObj $def
    Invoke-WebRequest $url -Headers $headers
}

function Pull-Container([string] $name) {

}