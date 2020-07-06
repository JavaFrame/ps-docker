<#
A half assed docker implementation in powershell
Version: 0.1
Authors: Sebastian Zumbrunn
#>

<#
Docker Api
#>

<#
.DESCRIPTION 
The url where the jwt tokens should be requested from
#>
$script:dockerAuthUrl = "https://auth.docker.io/token";

<#
.DESCRIPTION
A class which contains the ContainerDef, ContainerManifest and 
metadata, like the command, entrypoint and environmenet variable.
The metadata are only those which are actually needed for the current functionality.
#>
class ContainerConfig {
    [ContainerDef]$definition
    [ContainerManifest]$manifest
    [string[]]$env
    [string[]]$entrypoint
    [string[]]$cmd
}

<#
.DESCRIPTION
Contains the container definition of the manifest, the sha digest string of the file system
layers and the config layer
#>
class ContainerManifest {
    [ContainerDef]$definition
    [string[]]$layers
    [string]$configLayer
}

<#
The structured form of a container defintion (like library/ubuntu:latest).
It can be created from the ConvertTo-ContainerDef command which parses
a string

The ToString method will convert the class back into the string representation
#>
class ContainerDef {
    [string]$registryUrl = "registry-1.docker.io"
    [string]$library = "library"
    [string]$image
    [string]$tag = "latest"

    [string]ToString() {
        return ("{0}/{1}/{2}:{3}" -f $this.registryUrl, $this.library, $this.image, $this.tag)
    }
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
    if ($splitted.Length -gt 1) {
        $obj.library = $splitted[0]
        $imgPlusTag = $splitted[1];
    }
    else {
        $obj.library = "library"
        $imgPlusTag = $splitted[0];
    }
    # check if tag exists in string
    $splitted = $imgPlusTag.Split(":")
    $obj.image = $splitted[0];
    if ($splitted.Length -gt 1) {
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
function Get-AuthToken([ContainerDef] $def, [string]$scope = "pull") {
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
function Get-AuthHeaderObj([ContainerDef] $def, [string]$scope = "pull", [string] $type = "application/vnd.docker.distribution.manifest.v2+json") {
    $token = Get-AuthToken $def $scope
    return @{ "Authorization" = "Bearer $token"; "Accept" = $type } 
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
    [OutputType([ContainerConfig])]
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



<# Container startup code #>

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
    $tempFolderPath = "./$($def.image)-$($def.tag)-$(New-Guid)"
    New-Item -Type Directory $tempFolderPath | Out-Null
    return (Resolve-Path $tempFolderPath).Path
}

<#
.DESCRIPTION
Unzips all layers 

#>
function Expand-Layers([string] $layerFolderPath, [ContainerManifest] $manifest) {
    $folders = @()
    $layers = $manifest.layers
    foreach ($layer in $layers) {
        if($layer.Contains(":")) {
            $shalessName = ($layer -split ":")[1]
        } else {
            $shalessName = $layer
        }
        $layerTarPath = "$layerFolderPath/$layer.tar"
        $layerOutPath = "$layerFolderPath/$shalessName"
        New-Item -ItemType Directory $layerOutPath | Out-Null

        # untar layer
        tar -xvzf "$layerTarPath" -C "$layerOutPath" | Out-Null
        $folders += $layerOutPath
    }
    return $folders
}


<#
.DESCRIPTION
Escapes the colon (:) and backslash (\) in the given path for the overlayfs parameter.
The expected input ist a path, which may contain colons or backslashes, but not
the full -o argument of overlayfs

.PARAMETER path
the path to either the workdir, upperdir or lowerdir

#>
function ConvertTo-EscapedOverlayFsParameter([string]$path) {
    $chars = $path.ToCharArray()
    $escapedString = "";
    foreach ($letter in $chars) {
        if ($letter -eq '\') {
            $escapedString += "\\"
        }
        elseif ($letter -eq ':') {
            $escapedString += "\:"
        }
        else {
            $escapedString += $letter;
        }
    }
    return "`"$escapedString`"";
}

<#
.SYNOPSIS 
Tries to download the given image and run it

.DESCRIPTION
Tries to download the given image, extract the layers, and then run the given command or the predefined command if the
command parameter is empty

.PARAMETER runUnprivileged
Unshare is executed without sudo

.PARAMETER runInBackground
The stopContainer.sh script isn't automaticly executed at the end

.PARAMETER defStr
A container definition, like "ubuntu:latest", "library/ubuntu" or just "ubuntu"

.PARAMETER command
The command which should be executed. If empty, the command from the container config is executed

.INPUTS
None. You cannot pipe object to Invoke-Container

.OUTPUTS
The status updates printed for the user

.EXAMPLE
"Invoke-Container -runUnprivileged ubuntu:18.04" downloads the ubuntu 18.04 docker image and runs the
in the container predefined command.

.EXAMPLE
With "Invoke-Container -runUnprivileged ubuntu:18.04 echo hi" the image will be downloaded and instead of the
predefined command, "echo hi" will be run
#>
function Invoke-Container {
    [CmdletBinding()]
    Param(
        [switch] $runUnprivileged,
        [switch] $runInBackground,
        [Parameter(Mandatory=$true)]
        [string] $defStr,
        [Parameter(ValueFromRemainingArguments)]
        [string[]] $command = $null
    )
    $containerDef = ConvertTo-ContainerDef $defStr
    # fetch manifest
    $manifest = Get-Manifest $containerDef
    
    # get or create folder for container
    $containerPath = Get-ContainerFolder $containerDef
    Write-Host "Download container $defStr to $containerPath"

    # extract all layers from the manifest to pull them
    New-Item -ItemType Directory "$containerPath/layers" | Out-Null
    $layers = $manifest.layers
    foreach ($layer in $layers) {
        $layerLocation = "$containerPath/layers/$layer.tar"
        echo "Download layer $layer"
        Save-Layer $containerDef $layer $layerLocation
    }

    # get container config
    $containerConfig = Get-ContainerConfig $containerDef $manifest

    echo "Prepare container $($containerDef.ToString())"
    

    #prepare exeuction command of the container
    $containerExecCommand = "";
    if ($containerConfig.entrypoint.Length -gt 0) {
        $containerExecCommand += '"' + ($containerConfig.entrypoint -join '" "') + '" ';
    }
    if ($command -ne $null) {
        $containerExecCommand += $command -join " "
    }
    else {
        $containerExecCommand += '"' + ($containerConfig.cmd -join '" "') + '"'
    }

    echo "Start container with command `"$containerExecCommand`""

    # untars all layers to the layers folder
    $layerFolders = Expand-Layers "$containerPath/layers" $manifest
    New-Item -ItemType Directory "$containerPath/work" | Out-Null
    New-Item -ItemType Directory "$containerPath/upperOverlayFs" | Out-Null

    $rootFsDir = $containerPath + "/rootfs"
    New-Item -ItemType Directory $rootFsDir | Out-Null

    # construct overlay fs mount command
    # reverse layers because the overlayfs "lowerdir" argument expects the layers in reverse
    [array]::Reverse($layerFolders)
    $lowerDirs = ($layerFolders | % {ConvertTo-EscapedOverlayFsParameter $_}) -join ":"
    # mount overlayfs
    echo "Mount overlayfs (password is required)"
    sudo mount -t overlay overlay -o lowerdir=$lowerDirs,upperdir="$containerPath/upperOverlayFs",workdir="$containerPath/work" "$rootFsDir";
    

    $unshareBashScript = ""
    # mount standart file systems (like proc, sysfs or tmpfs)
    $unshareBashScript += "mkdir `"$rootFsDir/proc`"; `nmkdir `"$rootFsDir/sys`"; `nmkdir `"$rootFsDir/tmp`"; `n"
    # generate mount proc, sysfs and tmpfs commands
    $unshareBashScript += "mount -t proc none `"$rootFsDir/proc`"; `nmount -t sysfs none `"$rootFsDir/sys`"; `nmount -t tmpfs none `"$rootFsDir/tmp`";`n"
    # generate environmenets variable
    $unshareBashScript += ($containerConfig.env -join "`n") | % {"export $_"}
    $unshareBashScript += "`n"
    # change root into rootfs
    $unshareBashScript +=  "echo 'change root into root fs and executing command'`n"
    $unshareBashScript += "chroot `"$rootFsDir`" $containerExecCommand; `n"

    # generate bootstrapScript.sh path and write the script to disk
    $bootstrapScriptPath = "$containerPath/bootstrapScript.sh"
    $unshareBashScript | Set-Content $bootstrapScriptPath

    # generate stop script
    echo "generating stop Script"
    $stopBashScript = "#!/bin/bash`n"
    # generates umount commands
    $stopBashScript +=  "sudo umount '$rootFsDir'; `nrm -rf '$containerPath'; `n"
    # writes stopScript.sh to disk
    $stopBashScript | Set-Content "$containerPath/stopScript.sh"

    chmod 777 "$containerPath/stopScript.sh"

    # unshare bootstrap script
    if($runUnprivileged) {
        echo "Bootstraping Container with unpriviliged user"
        unshare --mount --net --uts --ipc --pid --fork --user --map-root-user bash `"$bootstrapScriptPath`"
    } else {
        sudo chown -R root:root "$containerPath"

        echo "Bootstraping Container with priviliged user"
        sudo unshare --mount --net --uts --ipc --pid --fork --map-root-user bash `"$bootstrapScriptPath`"
    }

    if(-not $runInBackground) {
        echo "Start cleanup"
        bash "$containerPath/stopScript.sh"
    } else {
        echo "continuing running the container"
        echo "Run stopScript.sh in the container folder"
    }
}