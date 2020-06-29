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

#$script:globalSettings = Read-Settings

$script:dockerAuthUrl = "https://auth.docker.io/token";

<#
Docker Api
#>

class ContainerConfig {
    [ContainerDef]$definition
    [ContainerManifest]$manifest
    [string[]]$env
    [string[]]$entrypoint
    [string[]]$cmd
}

class ContainerManifest {
    [ContainerDef]$definition
    [string[]]$layers
    [string]$configLayer
}

class ContainerDef {
    [string]$registryUrl = "registry-1.docker.io"
    [string]$library = "library"
    [string]$image
    [string]$tag = "latest"
}

<#
.DESCRIPTION
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

<#
.DESCRIPTION
Gets an auth token for the given scope and the given container definition.
The token is (currently) only useable for the official docker registry (e.g. registry.docker.io)

.OUTPUTS
System.String. The token
#>
function Get-AuthToken([ContainerDef] $def, [string]$scope="pull") {
    $response = Invoke-RestMethod "$dockerAuthUrl`?service=registry.docker.io&scope=repository:$($def.library)/$($def.image):$scope"
    return $response.token
}

<#
.DESCRIPTION
Creates a hashtable with the authorization and accept header. The $type parameter is used as the accept header's value.
The container definition and the $scope parmeter are used to feed the Get-AuthToken function and get a token 

.OUTPUTS
[hashtable] the hashtable with the described headers
#>
function Get-AuthHeaderObj([ContainerDef] $def, [string]$scope="pull", [string] $type = "application/vnd.docker.distribution.manifest.v2+json") {
    $token = Get-AuthToken $def $scope
    return @{ "Authorization" = "Bearer $token"; "Accept" = $type} 
}

<#
.DESCRIPTION
Fetches the manifest of a given Container Definition and fills it into an ContainerManifest class, which 
is returend

.OUTPUTS
ContainerManifest. An object of the type ContainerManifest with the manifest from the given ContainerDef
#>
function Get-Manifest([ContainerDef] $def) {
    [OutputType([ContainerManifest])]
    $headers = Get-AuthHeaderObj $def
    $obj = Invoke-RestMethod "https://$($def.registryUrl)/v2/$($def.library)/$($def.image)/manifests/$($def.tag)" -Headers $headers
    $manifest = [ContainerManifest]::new()
    $manifest.definition = $def
    $manifest.layers = $obj.layers | % digest
    $manifest.configLayer = $obj.config.digest
    return $manifest
}

<#
.DESCRIPTION
Downloads and saves the layer with the given sha value from the given ContainerDef and
saves it to the given $path
#>
function Save-Layer([ContainerDef] $def, [string] $shaLayer, [string] $path) {
    $url = "https://$($def.registryUrl)/v2/$($def.library)/$($def.image)/blobs/$shaLayer"
    $headers = Get-AuthHeaderObj $def
    Invoke-WebRequest $url -Headers $headers -OutFile $path -UseBasicParsing
}

<#
.DESCRIPTION
Downloads the config from the given ContainerDef and ContainerManifest and saves it into a ContainerConfig

.OUTPUTS
ContainerConfig. A ContainerConfig object with the received values
#>
function Get-ContainerConfig([ContainerDef] $def, [ContainerManifest] $manifest) {
    $url = "https://$($def.registryUrl)/v2/$($def.library)/$($def.image)/blobs/$($manifest.configLayer)"
    $headers = Get-AuthHeaderObj $def
    $response = Invoke-RestMethod $url -Headers $headers
    $config = [ContainerConfig]::new()
    $config.definition = $def
    $config.manifest = $manifest
    $config.entrypoint = $response.config.Entrypoint
    $config.cmd = $response.config.Cmd
    $config.env = $response.config.Env
    return $config
}

<#
.DESCRIPTION
Gets the folder where the layers of a container should be stored.
The folder path is generated and then created if it doesn't already exist.
The returned folder doesn't have to be empty, but it can

.OUTPUTS
System.String. The path to the container folder
#>
function Get-ContainerFolder([ContainerDef] $def) {
    #$tempFolderPath = "/tmp/$(New-Guid)"
    $tempFolderPath = "./$($def.image):$($def.tag)-$(New-Guid)"
    New-Item -Type Directory $tempFolderPath | Out-Null
    return $tempFolderPath
}

<#
.DESCRIPTION
Tries to download the given image and run it

.PARAMETER defStr
A container definition, like "ubuntu:latest", "library/ubuntu" or just "ubuntu"

.PARAMETER command
The command which should be executed. If empty, the command from the container config is executed

#>
function Invoke-Container {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [string] $defStr,
        [string] $command=$null
    )
    $containerDef = ConvertTo-ContainerDef $defStr
    # fetch manifest
    $manifest = Get-Manifest $containerDef
    
    # get or create folder for container
    $containerPath = Get-ContainerFolder $containerDef
    Write-Host "Download container $defStr to $containerPath"

    # extract all layers from the manifest to pull them
    $layers = $manifest.layers
    foreach ($layer in $layers) {
        $layerLocation = "$containerPath/$layer.tar"
        echo "Download layer $layer"
        Save-Layer $containerDef $layer $layerLocation
    }

    # get container config
    $containerConfig = Get-ContainerConfig $containerDef $manifest
}