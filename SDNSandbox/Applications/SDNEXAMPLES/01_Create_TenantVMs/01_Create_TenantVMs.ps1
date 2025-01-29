﻿# Version 2.0

<#
.SYNOPSIS 

    This script:
    
     1. Creates two Windows Server (Desktop Experience) VHD files for TenantVM1 and TenantVM2, injects a unattend.xml
     2. Creates the TenantVM1 and TenantVM2 virtual machines
     3. Adds TenantVM1 and TenantVM2 to the SDNCluster
   

    After running this script, follow the directions in the README.md file for this scenario.
#>


[CmdletBinding(DefaultParameterSetName = "NoParameters")]

param(

    [Parameter(Mandatory = $true, ParameterSetName = "ConfigurationFile")]
    [String] $ConfigurationDataFile = 'C:\SCRIPTS\SDNSandbox-Config.psd1'

)


$ErrorActionPreference = "Stop"
$VerbosePreference = "Continue"

# Load in the configuration file.
$SDNConfig = Import-PowerShellDataFile $ConfigurationDataFile
if (!$SDNConfig) { Throw "Place Configuration File in the root of the scripts folder or specify the path to the Configuration file." }

# Set Credential Object
$domainCred = new-object -typename System.Management.Automation.PSCredential `
    -argumentlist (($SDNConfig.SDNDomainFQDN.Split(".")[0]) + "\administrator"), `
(ConvertTo-SecureString $SDNConfig.SDNAdminPassword -AsPlainText -Force)

# Set fqdn
$fqdn = $SDNConfig.SDNDomainFQDN

# Copy VHD File 
Write-Verbose "Copying GUI.VHDX"
Copy-Item -Path C:\VHDs\GUI.vhdx -Destination '\\SDNCluster\ClusterStorage$\Volume01\VHD' -Force | Out-Null


Invoke-Command -ComputerName SDNHost1 -Credential $domainCred -ScriptBlock {


    $ErrorActionPreference = "Stop"
    $VerbosePreference = "Continue"


    # Create TENANTVM1 and TENANTVM2 VHDX files

    Write-Verbose "Copying Over VHDX files for TenantVMs. This can take some time..."


    $csvfolder = "Volume01"     

    $TenantVMs = @("TenantVM1", "TenantVM2")


    foreach ($TenantVM in $TenantVMs) {

        $Password = $using:SDNConfig.SDNAdminPassword
        $ProductKey = $using:SDNConfig.GUIProductKey
        $Domain = $using:fqdn
        $VMName = $TenantVM

        Write-Verbose "Domain = $Domain"
        Write-Verbose "VMName = $VMName"

        # Copy over GUI VHDX

        Write-Verbose "Copying GUI.VHDX for TenantVM..."

        $params = @{

            Path     = "C:\ClusterStorage\$csvfolder"
            Name     = $TenantVM
            ItemType = 'Directory'

        }

        $tenantpath = New-Item @params -Force

        Copy-Item -Path 'C:\ClusterStorage\Volume01\VHD\GUI.VHDX' -Destination $tenantpath.FullName -Force

        # Inject Answer File
        Write-Verbose "Injecting Answer File for TenantVM $VMName..."

        $params = @{

            Path     = 'D:\'
            Name     = $TenantVM
            ItemType = 'Directory'

        }


        $MountPath = New-Item @params -Force


        $ImagePath = "\\SDNHost1\c$\ClusterStorage\Volume01\$VMName\GUI.vhdx"

        $params = @{

            ImagePath = $ImagePath
            Index     = 1
            Path      = $MountPath.FullName

        }

        $VerbosePreference = "SilentlyContinue"
        Mount-WindowsImage @params | Out-Null
        $VerbosePreference = "Continue"

        # Create Panther Folder
        Write-Verbose "Creating Panther folder.."

        $params = @{

            Path     = (($MountPath.FullName) + ("\Windows\Panther"))
            ItemType = 'Directory'

        }


        $pathPanther = New-Item @params -Force

        # Generate Panther Folder

        $unattend = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <ProductKey>$ProductKey</ProductKey>
            <ComputerName>$VMName</ComputerName>
            <RegisteredOwner>$ENV:USERNAME</RegisteredOwner>
        </component>
        <component name="Networking-MPSSVC-Svc" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <DomainProfile_EnableFirewall>false</DomainProfile_EnableFirewall>
            <PrivateProfile_EnableFirewall>false</PrivateProfile_EnableFirewall>
            <PublicProfile_EnableFirewall>false</PublicProfile_EnableFirewall>
        </component>
        <component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <fDenyTSConnections>false</fDenyTSConnections>
        </component>
        <component name="Microsoft-Windows-IE-ESC" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <IEHardenAdmin>false</IEHardenAdmin>
            <IEHardenUser>false</IEHardenUser>
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <UserAccounts>
                <AdministratorPassword>
                    <Value>$Password</Value>
                    <PlainText>true</PlainText>
                </AdministratorPassword>
            </UserAccounts>
            <TimeZone>Pacific Standard Time</TimeZone>
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <SkipUserOOBE>true</SkipUserOOBE>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Work</NetworkLocation>
                <ProtectYourPC>1</ProtectYourPC>
                <HideLocalAccountScreen>true</HideLocalAccountScreen>
            </OOBE>
        </component>
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <UserLocale>en-US</UserLocale>
            <SystemLocale>en-US</SystemLocale>
            <InputLocale>0409:00000409</InputLocale>
            <UILanguage>en-US</UILanguage>
        </component>
    </settings>
    <cpi:offlineImage cpi:source="" xmlns:cpi="urn:schemas-microsoft-com:cpi" />
</unattend>
"@


        $params = @{

            Value = $unattend
            Path  = $(($MountPath.FullName) + ("\Windows\Panther\Unattend.xml"))

        }


        Set-Content @params -Force

        #  Install IIS Web Server

        Write-Verbose "Installing IIS Web Server on $VMName"

        $params = @{
        
            Path        = $MountPath.FullName
            Featurename = 'IIS-WebServerRole'
        
        }
        
        Enable-WindowsOptionalFeature @params -All -LimitAccess | Out-Null
        
        
        Write-Verbose "Creating simple Web Page on $VMName"
        
        # Set Simple Web-Page
        $sysinfo = [PSCustomObject]@{ComputerName = $VMName }
        $sysinfo | ConvertTo-Html | Out-File  "$($MountPath.FullName)\inetpub\wwwroot\iisstart.htm" -Force

        # Dismount Image with Commit

        Write-Verbose "Committing and Dismounting Image..."
        Dismount-WindowsImage -Path $MountPath.FullName -Save | Out-Null

    }

}

# Add Virtual Machines

Write-Verbose "Creating Virtual Machines"

# Tenant VM1
New-VM -Name TenantVM1 -ComputerName SDNHost2 -VHDPath C:\ClusterStorage\Volume01\TenantVM1\GUI.vhdx -MemoryStartupBytes 1GB `
    -Generation 2 ` -Path C:\ClusterStorage\Volume01\TenantVM1 | Out-Null

Set-VM -Name TenantVM1 -ComputerName SDNHost2 -ProcessorCount 4 | Out-Null

# Tenant VM2

New-VM -Name TenantVM2 -ComputerName SDNHost1 -VHDPath C:\ClusterStorage\Volume01\TenantVM2\GUI.vhdx -MemoryStartupBytes 1GB `
    -Generation 2 -Path C:\ClusterStorage\Volume01\TenantVM2  | Out-Null

Set-VM -Name TenantVM2 -ComputerName SDNHost1 -ProcessorCount 4


Write-Verbose "Setting Static MAC on Tenant VMs "

Set-VMNetworkAdapter -VMName TenantVM1 -ComputerName SDNHost2 -StaticMacAddress "00-11-22-33-44-55" | Out-Null
Set-VMNetworkAdapter -VMName TenantVM2 -ComputerName SDNHost1 -StaticMacAddress "00-11-22-33-44-56" | Out-Null

Write-Verbose "Connecting VMswitch to the VMNetwork Adapters on the Tenant VMs "

Get-VMNetworkAdapter -ComputerName SDNHost2 -VMName TenantVM1 | Connect-VMNetworkAdapter -SwitchName sdnSwitch | Out-Null
Get-VMNetworkAdapter -ComputerName SDNHost1 -VMName TenantVM2 | Connect-VMNetworkAdapter -SwitchName sdnSwitch | Out-Null



Write-Verbose "Starting the Tenant VMs
"
# Start the VMs
Start-VM -Name TenantVM1 -ComputerName SDNHost2
Start-VM -Name TenantVM2 -ComputerName SDNHost1


Write-Verbose "Getting MAC Addresses of the NICs for the VMs so we can create NC objects "
# Get the MACs
$TenantVM1Mac = (Get-VMNetworkAdapter -VMName TenantVM1 -ComputerName SDNHost2).MacAddress
$TenantVM2Mac = (Get-VMNetworkAdapter -VMName TenantVM2 -ComputerName SDNHost1).MacAddress

Write-Verbose " Adding VMs to our SDNCluster "

$VerbosePreference = "SilentlyContinue"
Import-Module FailoverClusters
$VerbosePreference = "Continue"


Add-ClusterVirtualMachineRole -VMName TenantVM1 -Cluster SDNCluster | Out-Null
Add-ClusterVirtualMachineRole -VMName TenantVM2 -Cluster SDNCluster | Out-Null