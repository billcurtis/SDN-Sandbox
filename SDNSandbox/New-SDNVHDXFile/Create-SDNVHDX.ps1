
<#

.SYNOPSIS 
  Generates a VHDX Image from ISO as well as applies updates if a folder path 
  specified.

.EXAMPLE
    .\New-SDNSandbox.ps1
    Reads in the configuration from NestedSDN-Config.psd1 that contains a hash table 
    of settings data that will in same root as New-SDNSandbox.ps1

#>

param(

    [Parameter(Mandatory=$true,ParameterSetName="CreateSDNVHDX")]
    [String] $ConvertWindowsImagePathModule,
    [Parameter(Mandatory=$false,ParameterSetName="CreateSDNVHDX")]
    [String] $UpdatesPath

    )    


$ErrorActionPreference = "Stop"
$VerbosePreference = "Continue"

$vhdxversions = @("GUI","CORE","Console")

$vhdname = $vhdxversions | Out-GridView -OutputMode Single -Title "Choose the VHDX type that you will generate and then click OK."

If (!$vhdname) {Write-Error "You did not choose an Image Type. Exiting";break}

# Get the ISO

Write-Host "Please select the Windows $vhdname ISO file." -ForegroundColor Yellow
Add-Type -AssemblyName System.Windows.Forms
$FileBrowser = New-Object System.Windows.Forms.OpenFileDialog -Property @{

    Multiselect = $false 
    Filter      = "$vhdname ISO Image (*.ISO)|*.iso"
}
 
[void]$FileBrowser.ShowDialog()

If (!$FileBrowser) {Write-Error "You did not choose an ISO. Exiting";break}

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
-OutputMode Single).ImageName 


# Make sure that you imported the Convert-WindowsImage Module and placed it in the root of the VHDXCreation Directory
# (download from https://gallery.technet.microsoft.com/scriptcenter/Convert-WindowsImageps1-0fe23a8f)
# Written by Pronichkin


Import-Module $ConvertWindowsImagePathModule


# Get filename to save vhdx as...

$SaveFileDialog = New-Object windows.forms.savefiledialog   
    $SaveFileDialog.initialDirectory = [System.IO.Directory]::GetCurrentDirectory()   
    $SaveFileDialog.title = "Save VHDX to Disk"     
    $SaveFileDialog.filter = "VHDX File|*.vhdx" 
    $SaveFileDialog.filter = "VHDX File|*.vhdx" 
    $SaveFileDialog.ShowHelp = $True       
    $VHDPath = $SaveFileDialog.ShowDialog()  
      
    if($VHDPath -ne "OK") { Write-Error "File Save Dialog Cancelled!" ;exit } 


# Generate VHDX from WIM

Write-Verbose "Generating VHDX from WIM."

$param = @{

Sourcepath = $WindowsDVD.FullName
Edition = $SelectedImage
VHDFormat = 'VHDX'
SizeBytes = 127GB
VHDPath = $VHDPath

}

Convert-WindowsImage @param

# Dismount ISO

Dismount-DiskImage -ImagePath $isoimagepath


# Perform Windows Updates

$accesspaths1 = Get-Partition | Select-Object AccessPaths
Mount-VHD -Path $VHDPath
$accesspaths2 = Get-Partition | Select-Object AccessPaths
$Path = ((Compare-Object $accesspaths1 $accesspaths2 -Property AccessPaths).AccessPaths)[0].Trim(":\")
#Set-Volume -DriveLetter $Path -NewFileSystemLabel SDNHOST

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

