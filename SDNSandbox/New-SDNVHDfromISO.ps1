
<#

# Version 1.0.0

.SYNOPSIS 
  Generates a VHDX Image from ISO as well as applies updates if a folder path 
  specified.

.EXAMPLE
    .\New-SDNVHDSFROMISO.ps1
    .\New-SDNVHDSFROMISO.ps1 -UpdatesPath '.\MSU Updates'

    Starts up a GUI session to make selections of the VHDX file you wish to create.


#>

param(

    [Parameter(Mandatory = $false, ParameterSetName = "CreateSDNVHDX")]
    [String] $UpdatesPath

)    



# Check to see if we have Convert-WindowsImage
$isitthere = Get-Module WindowsImageTools
if (!$isitthere) { Install-Module WindowsImageTools }
Import-Module WindowsImageTools

# set preferences
$ErrorActionPreference = "Stop"
$VerbosePreference = "Continue"


$vhdxversions = @("GUI", "CORE")

$vhdname = $vhdxversions | Out-GridView -OutputMode Single -Title "Choose the VHDX type that you will generate and then click OK."

If (!$vhdname) {Write-Error "You did not choose an Image Type. Exiting"; break}

# Get the ISO

Write-Host "Please select the Windows $vhdname ISO file." -ForegroundColor Yellow
Add-Type -AssemblyName System.Windows.Forms
$FileBrowser = New-Object System.Windows.Forms.OpenFileDialog -Property @{

    Multiselect = $false 
    Filter      = "$vhdname ISO Image (*.ISO)|*.iso"
}
 
[void]$FileBrowser.ShowDialog()

If (!$FileBrowser) {Write-Error "You did not choose an ISO. Exiting"; break}

$isoimagepath = $FileBrowser.FileName;

# Mount ISO

Write-Verbose "Mounting Selected ISO."
Mount-DiskImage -ImagePath $isoimagepath
$CDVolumes = Get-Volume | Where-Object {$_.DriveType -eq "CD-ROM" -and $_.FileSystem -eq "UDF"}

$WindowsDVD = @()

Foreach ($CDVolume in $CDVolumes) {

    $WindowsDVD = Get-ChildItem -LiteralPath (($CDVolume.DriveLetter) + ":\") -Filter install.wim -Recurse

}

If ($WindowsDVD.Count -gt 1) {

    throw "More than one DVD drive is mounted on the system. Dismount all DVD drives and try again."

}

# Get WIM Image WIM Image

Write-Verbose "Importing Get-WindowsImage."
$WindowsImage = Get-WindowsImage -ImagePath $WindowsDVD.FullName 
$selectedImage = ($WindowsImage | Out-GridView -Title "Select the Image to use and then click OK" `
        -OutputMode Single).ImageIndex

# Get filename to save vhdx as...

$SaveFileDialog = New-Object windows.forms.savefiledialog   
$SaveFileDialog.initialDirectory = [System.IO.Directory]::GetCurrentDirectory()   
$SaveFileDialog.title = "Save VHDX to Disk"     
$SaveFileDialog.filter = "VHDX File|*.vhdx" 
$SaveFileDialog.filter = "VHDX File|*.vhdx" 
$SaveFileDialog.ShowHelp = $True       
$VHDPathResult = $SaveFileDialog.ShowDialog()  
      
if ($VHDPathResult -ne "OK") { Write-Error "File Save Dialog Cancelled!" ; exit }
else { $VHDPath = $SaveFileDialog.FileName } 


# Generate VHDX from WIM

Write-Verbose "Generating VHDX from WIM."

$param = @{

    SourcePath = $WindowsDVD.FullName
    Index   = $SelectedImage
    Size  =  100GB
    Path    = $VHDPath
    Force = $true
    DiskLayout = "UEFI"
    Dynamic = $true
}

Convert-Wim2VHD @param

# Dismount ISO

Write-Verbose "Dismounting $isoimagepath"
Dismount-DiskImage -ImagePath $isoimagepath

# Test to see if vhd was created

Test-Path $VHDPath

if (!$VHDPath) {Write-Error "VHD was not successfully created."}


# Perform Windows Updates

$accesspaths1 = Get-Partition | Select-Object AccessPaths
Mount-VHD -Path $VHDPath
$accesspaths2 = Get-Partition | Select-Object AccessPaths
$Path = ((Compare-Object $accesspaths1 $accesspaths2 -Property AccessPaths).AccessPaths)[0].Trim(":\")

$Updates = Get-ChildItem -Path $UpdatesPath -Filter "*.msu"

if ($Updates) {

    Write-Verbose "Applying any applicable updates in the update folder."
    Foreach ($Update in $Updates) {

        Add-WindowsPackage -PackagePath $Update.FullName -Path ($Path + ":\")

    }

}


Dismount-VHD -Path $VHDPath

# Dismount ISO

Dismount-DiskImage -ImagePath $isoimagepath

Write-Verbose "Finshed Generating VHDX Image $VHDPath"

$ErrorActionPreference = "Continue"
$VerbosePreference = "SilentlyContinue"

