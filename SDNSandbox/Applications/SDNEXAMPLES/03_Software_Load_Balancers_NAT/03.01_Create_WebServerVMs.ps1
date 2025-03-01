
# Version 1.0

<#
.SYNOPSIS 

    This script:
    
     1. Creates two Windows Server (Desktop Experience) VHD files for WebServerVM1 and WebServerVM2, injects a unattend.xml
     2. Creates the WebServerVM1 and WebServerVM2 virtual machines
     3. Adds WebServerVM1 and WebServerVM2 to the SDNCluster
     4. Creates a VM Network and VM Subnet in Network Controller
     5. Creates WebServerVM1 and WebServerVM2 Network Interfaces in Network Controller
     6. Sets the port profiles on WebServerVM1 and WebServerVM2 Interfaces
   

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


Invoke-Command -ComputerName SDNHOST1 -Credential $domainCred -ScriptBlock {


    $ErrorActionPreference = "Stop"
    $VerbosePreference = "Continue"


    # Create WebServerVM1 and WebServerVM2 VHDX files

    Write-Verbose "Copying Over VHDX files for TenantVMs. This can take some time..."

    $OSver = Get-WmiObject Win32_OperatingSystem | Where-Object { $_.Name -match "Windows Server 2019" }

    $csvfolder = "Volume01"

    $TenantVMs = @("WebServerVM1", "WebServerVM2")


    foreach ($TenantVM in $TenantVMs) {

        $Password = $using:SDNConfig.SDNAdminPassword
        $ProductKey = $using:SDNConfig.GUIProductKey
        $Domain = $using:fqdn
        $VMName = $TenantVM

        Write-Verbose "Domain = $Domain"
        Write-Verbose "VMName = $VMName"

        # Copy over GUI VHDX

        Write-Verbose "Copying GUI.VHDX for WebserverVM..."

        $params = @{

            Path     = "C:\ClusterStorage\$csvfolder"
            Name     = $TenantVM
            ItemType = 'Directory'

        }

        $tenantpath = New-Item @params -Force

        Copy-Item -Path 'C:\ClusterStorage\Volume01\VHD\GUI.VHDX' -Destination $tenantpath.FullName -Force

        # Inject Answer File
        Write-Verbose "Injecting Answer File for WebServerVM $VMName..."

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

        # Generate Unattend.xml

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

        # Copy Unattend.xml to Panther folder

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

# WebServerVM1
New-VM -Name WebServerVM1 -ComputerName SDNHOST2 -VHDPath C:\ClusterStorage\Volume01\WebServerVM1\GUI.vhdx -MemoryStartupBytes 1GB `
    -Generation 2 -Path C:\ClusterStorage\Volume01\WebServerVM1 | Out-Null

Set-VM -Name WebServerVM1 -ComputerName SDNHOST2 -ProcessorCount 4 | Out-Null

# WebServerVM2

New-VM -Name WebServerVM2 -ComputerName SDNHOST1 -VHDPath C:\ClusterStorage\Volume01\WebServerVM2\GUI.vhdx -MemoryStartupBytes 1GB `
    -Generation 2 -Path C:\ClusterStorage\Volume01\WebServerVM2 | Out-Null

Set-VM -Name WebServerVM2 -ComputerName SDNHOST1 -ProcessorCount 4


Write-Verbose "Setting Static MAC on Web Server VMs "

Set-VMNetworkAdapter -VMName WebServerVM1 -ComputerName SDNHOST2 -StaticMacAddress "00-11-22-33-44-60" | Out-Null
Set-VMNetworkAdapter -VMName WebServerVM2 -ComputerName SDNHOST1 -StaticMacAddress "00-11-22-33-44-61" | Out-Null

Write-Verbose "Connecting VMswitch to the VMNetwork Adapters on the Web Server VMs "

Get-VMNetworkAdapter -ComputerName SDNHOST2 -VMName WebServerVM1 | Connect-VMNetworkAdapter -SwitchName sdnSwitch | Out-Null
Get-VMNetworkAdapter -ComputerName SDNHOST1 -VMName WebServerVM2 | Connect-VMNetworkAdapter -SwitchName sdnSwitch | Out-Null



Write-Verbose "Starting the Web server VMs"
# Start the VMs
Start-VM -Name WebServerVM1 -ComputerName SDNHOST2
Start-VM -Name WebServerVM2 -ComputerName SDNHOST1


Write-Verbose "Getting MAC Addresses of the NICs for the VMs so we can create NC objects "
# Get the MACs
$WebServerVM1Mac = (Get-VMNetworkAdapter -VMName WebServerVM1 -ComputerName SDNHOST2).MacAddress
$WebServerVM2Mac = (Get-VMNetworkAdapter -VMName WebServerVM2 -ComputerName SDNHOST1).MacAddress

Write-Verbose " Adding VMs to our SDNCluster"

$VerbosePreference = "SilentlyContinue"
Import-Module FailoverClusters
$VerbosePreference = "Continue"


Add-ClusterVirtualMachineRole -VMName WebServerVM1 -Cluster SDNCluster | Out-Null
Add-ClusterVirtualMachineRole -VMName WebServerVM2 -Cluster SDNCluster | Out-Null


# Import Network Controller Module
$VerbosePreference = "SilentlyContinue"
Import-Module NetworkController
$VerbosePreference = "Continue"

$uri = "https://NC.$($SDNConfig.SDNDomainFQDN)"


# Create VM Network in Network Controller
Write-Verbose "Creating the VM Network vmNetwork1 in NC with a subnet named vmSubnet1"

#Find the HNV Provider Logical Network 

$VMNetworkName = "webNetwork1"
$VMSubnetName = "webSubnet1"
$VMNetworkPrefix = '10.3.0.0/16' 
$VMSubnetPrefix = '10.3.1.0/24'

$logicalnetworks = Get-NetworkControllerLogicalNetwork -ConnectionUri $uri  
foreach ($ln in $logicalnetworks) {  
    if ($ln.Properties.NetworkVirtualizationEnabled -eq "True") {  
        $HNVProviderLogicalNetwork = $ln  
    }  
}   


#Create the Virtual Subnet

Write-Verbose "Creating the Virtual Subnet $VMSubnetName"

$vsubnet = new-object Microsoft.Windows.NetworkController.VirtualSubnet  
$vsubnet.ResourceId = $VMSubnetName  
$vsubnet.Properties = new-object Microsoft.Windows.NetworkController.VirtualSubnetProperties  
#$vsubnet.Properties.AccessControlList = $acllist  
$vsubnet.Properties.AddressPrefix = $VMSubnetPrefix  

#Create the Virtual Network  

Write-Verbose "Creating the Virtual Network $VMNetworkName"

$vnetproperties = new-object Microsoft.Windows.NetworkController.VirtualNetworkProperties  
$vnetproperties.AddressSpace = new-object Microsoft.Windows.NetworkController.AddressSpace  
$vnetproperties.AddressSpace.AddressPrefixes = @($VMNetworkPrefix)  
$vnetproperties.LogicalNetwork = $HNVProviderLogicalNetwork  
$vnetproperties.Subnets = @($vsubnet)  
New-NetworkControllerVirtualNetwork -ResourceId $VMNetworkName -ConnectionUri $uri -Properties $vnetproperties -Force


# Add Network Interface Object for WebServerVM1 in Nework Controller

Write-Verbose "Creating a Network Interface Object for WebServerVM1 in NC"

$VMSubnetRef = (Get-NetworkControllerVirtualNetwork -ResourceId $VMNetworkName -ConnectionUri $uri).Properties.Subnets.ResourceRef

$vmnicproperties = new-object Microsoft.Windows.NetworkController.NetworkInterfaceProperties
$vmnicproperties.PrivateMacAddress = $WebServerVM1Mac
$vmnicproperties.PrivateMacAllocationMethod = "Static" 
$vmnicproperties.IsPrimary = $true 

$ipconfiguration = new-object Microsoft.Windows.NetworkController.NetworkInterfaceIpConfiguration
$ipconfiguration.resourceid = "WebServerVM1_IP1"
$ipconfiguration.properties = new-object Microsoft.Windows.NetworkController.NetworkInterfaceIpConfigurationProperties
$ipconfiguration.properties.PrivateIPAddress = '10.3.1.4'
$ipconfiguration.properties.PrivateIPAllocationMethod = "Static"
#$ipconfiguration.Properties.AccessControlList = $acllist

$ipconfiguration.properties.Subnet = new-object Microsoft.Windows.NetworkController.Subnet
$ipconfiguration.properties.subnet.ResourceRef = $VMSubnetRef

$vmnicproperties.IpConfigurations = @($ipconfiguration)
New-NetworkControllerNetworkInterface -ResourceID "WebServerVM1_Ethernet1" -Properties $vmnicproperties -ConnectionUri $uri -Force

$nic = Get-NetworkControllerNetworkInterface -ConnectionUri $uri -ResourceId WebServerVM1_Ethernet1

Write-Verbose "Invoking command on the SDNHOST where WebServerVM1 resides. Command will set the VFP extension so WebServerVM1 will have access to the network."

Invoke-Command -ComputerName SDNHOST2 -ArgumentList $nic -ScriptBlock {

    $nic = $args[0]

    #The hardcoded Ids in this section are fixed values and must not change.
    $FeatureId = "9940cd46-8b06-43bb-b9d5-93d50381fd56"  # This value never changes.
 
    $vmNic = Get-VMNetworkAdapter -VMName WebServerVM1
 
    $CurrentFeature = Get-VMSwitchExtensionPortFeature -FeatureId $FeatureId -VMNetworkAdapter $vmNic
 
    if ($CurrentFeature -eq $null) {
        $Feature = Get-VMSystemSwitchExtensionPortFeature -FeatureId $FeatureId
 
        $Feature.SettingData.ProfileId = "{$($nic.InstanceId)}"
        $Feature.SettingData.NetCfgInstanceId = "{00000000-0000-0000-0000-000000000000}" # This instance ID never changes.
        $Feature.SettingData.CdnLabelString = "Microsoft"
        $Feature.SettingData.CdnLabelId = 0
        $Feature.SettingData.ProfileName = "Microsoft SDN Port"
        $Feature.SettingData.VendorId = "{1FA41B39-B444-4E43-B35A-E1F7985FD548}"  # This vendor id never changes.
        $Feature.SettingData.VendorName = "NetworkController"
        $Feature.SettingData.ProfileData = 1
 
        Add-VMSwitchExtensionPortFeature -VMSwitchExtensionFeature  $Feature -VMNetworkAdapter $vmNic
    }
    else {
        $CurrentFeature.SettingData.ProfileId = "{$($nic.InstanceId)}"
        $CurrentFeature.SettingData.ProfileData = 1
 
        Set-VMSwitchExtensionPortFeature -VMSwitchExtensionFeature $CurrentFeature  -VMNetworkAdapter $vmNic
    }
}



# Add Network Interface Object for WebServerVM2 in Network Controller

Write-Verbose "Creating a Network Interface Object for WebServerVM1 in NC"

$VMSubnetRef = (Get-NetworkControllerVirtualNetwork -ResourceId $VMNetworkName -ConnectionUri $uri).Properties.Subnets.ResourceRef

$vmnicproperties = new-object Microsoft.Windows.NetworkController.NetworkInterfaceProperties
$vmnicproperties.PrivateMacAddress = $WebServerVM2Mac
$vmnicproperties.PrivateMacAllocationMethod = "Static" 
$vmnicproperties.IsPrimary = $true 

$ipconfiguration = new-object Microsoft.Windows.NetworkController.NetworkInterfaceIpConfiguration
$ipconfiguration.resourceid = "WebServerVM2_IP1"
$ipconfiguration.properties = new-object Microsoft.Windows.NetworkController.NetworkInterfaceIpConfigurationProperties
$ipconfiguration.properties.PrivateIPAddress = '10.3.1.5'
$ipconfiguration.properties.PrivateIPAllocationMethod = "Static"
#$ipconfiguration.Properties.AccessControlList = $acllist

$ipconfiguration.properties.Subnet = new-object Microsoft.Windows.NetworkController.Subnet
$ipconfiguration.properties.subnet.ResourceRef = $VMSubnetRef

$vmnicproperties.IpConfigurations = @($ipconfiguration)
New-NetworkControllerNetworkInterface -ResourceID 'WebServerVM2_Ethernet1' -Properties $vmnicproperties -ConnectionUri $uri -Force

$nic = Get-NetworkControllerNetworkInterface -ConnectionUri $uri -ResourceId WebServerVM2_Ethernet1

Write-Verbose "Invoking command on the SDNHOST where WebServerVM2 resides. Command will set the VFP extension so WebServerVM2 will have access to the network."

Invoke-Command -ComputerName SDNHOST1 -ArgumentList $nic -ScriptBlock {

    $nic = $args[0]

    #The hardcoded Ids in this section are fixed values and must not change.
    $FeatureId = "9940cd46-8b06-43bb-b9d5-93d50381fd56"
 
    $vmNic = Get-VMNetworkAdapter -VMName WebServerVM2 
 
    $CurrentFeature = Get-VMSwitchExtensionPortFeature -FeatureId $FeatureId -VMNetworkAdapter $vmNic
 
    if ($CurrentFeature -eq $null) {
        $Feature = Get-VMSystemSwitchExtensionPortFeature -FeatureId $FeatureId
 
        $Feature.SettingData.ProfileId = "{$($nic.InstanceId)}"
        $Feature.SettingData.NetCfgInstanceId = "{00000000-0000-0000-0000-000000000000}"
        $Feature.SettingData.CdnLabelString = "Microsoft"
        $Feature.SettingData.CdnLabelId = 0
        $Feature.SettingData.ProfileName = "Microsoft SDN Port"
        $Feature.SettingData.VendorId = "{1FA41B39-B444-4E43-B35A-E1F7985FD548}"
        $Feature.SettingData.VendorName = "NetworkController"
        $Feature.SettingData.ProfileData = 1
 
        Add-VMSwitchExtensionPortFeature -VMSwitchExtensionFeature  $Feature -VMNetworkAdapter $vmNic
    }
    else {
        $CurrentFeature.SettingData.ProfileId = "{$($nic.InstanceId)}"
        $CurrentFeature.SettingData.ProfileData = 1
 
        Set-VMSwitchExtensionPortFeature -VMSwitchExtensionFeature $CurrentFeature  -VMNetworkAdapter $vmNic
    }
}


Write-Verbose "All done. WebServerVM1 and WebServerVM2 should be able to talk to one another."