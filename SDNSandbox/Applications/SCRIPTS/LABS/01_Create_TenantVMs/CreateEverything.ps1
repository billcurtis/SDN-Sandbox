
# Version 1.0

<#
.SYNOPSIS 

    This script:
    
     1. Creates two Windows Server (Desktop Experience) VHD files for TenantVM1 and TenantVM2, injects a unattend.xml
     2. Creates the TenantVM1 and TenantVM2 virtual machines
     3. Adds TenantVM1 and TenantVM2 to the SDNCluster
     4. Creates an ACL in Network Controller to allow all traffic.
     5. Creates a VM Network and VM Subnet in Network Controller, and adds the AllowAll ACL.
     6. Creates TenantVM1 and TenantVM2 Network Interfaces in Network Controller
     7. Sets the port profiles on TenantVM1 and TenantVM2 Interfaces
   

    After running this script, follow the directions in the README.md file for this scenario.
#>


[CmdletBinding(DefaultParameterSetName = "NoParameters")]

param(

    [Parameter(Mandatory = $true, ParameterSetName = "ConfigurationFile")]
    [String] $ConfigurationDataFile = 'C:\SCRIPTS\NestedSDN-Config.psd1'

)


$ErrorActionPreference = "Stop"
$VerbosePreference = "Continue"

# Load in the configuration file.
$SDNConfig = Import-PowerShellDataFile $ConfigurationDataFile
if (!$SDNConfig) {Throw "Place Configuration File in the root of the scripts folder or specify the path to the Configuration file."}

# Set Credential Object
$domainCred = new-object -typename System.Management.Automation.PSCredential `
    -argumentlist (($SDNConfig.SDNDomainFQDN.Split(".")[0]) + "\administrator"), `
(ConvertTo-SecureString $SDNConfig.SDNAdminPassword -AsPlainText -Force)

# Set fqdn
$fqdn = $SDNConfig.SDNDomainFQDN


Invoke-Command -ComputerName SDNHOST1 -Credential $domainCred -ScriptBlock {


    $ErrorActionPreference = "Stop"
    $VerbosePreference = "Continue"


    # Create TENANTVM1 and TENANTVM2 VHDX files

    Write-Verbose "Copying Over VHDX files for TenantVMs. This can take some time..."

    $OSver = Get-WmiObject Win32_OperatingSystem | Where-Object {$_.Name -match "Windows Server 2019"}

    If ($OSVer) {$csvfolder = "S2D_vDISK1"}
    else {$csvfolder = "Volume1"}

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

        Copy-Item -Path '\\console\C$\VHDs\GUI.vhdx' -Destination $tenantpath.FullName -Force

        # Inject Answer File
        Write-Verbose "Injecting Answer File for TenantVM $VMName..."

        $params = @{

            Path     = 'D:\'
            Name     = $TenantVM
            ItemType = 'Directory'

        }


        $MountPath = New-Item @params -Force


        $ImagePath = "\\sdncluster\ClusterStorage`$\$csvfolder\$VMName\GUI.vhdx"

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
        $sysinfo = [PSCustomObject]@{ComputerName = $VMName}
        $sysinfo | ConvertTo-Html | Out-File  "$($MountPath.FullName)\inetpub\wwwroot\iisstart.htm" -Force

        # Dismount Image with Commit

        Write-Verbose "Committing and Dismounting Image..."
        Dismount-WindowsImage -Path $MountPath.FullName -Save | Out-Null

    }

}


# Add Virtual Machines

Write-Verbose "Creating Virtual Machines"

# Tenant VM1
New-VM -Name TenantVM1 -ComputerName SDNHOST3 -VHDPath C:\ClusterStorage\S2D_vDISK1\TenantVM1\GUI.vhdx -MemoryStartupBytes 1GB -Generation 2 | Out-Null
Set-VM -Name TenantVM1 -ComputerName SDNHOST3 -ProcessorCount 4 | Out-Null

# Tenant VM2

New-VM -Name TenantVM2 -ComputerName SDNHOST1 -VHDPath C:\ClusterStorage\S2D_vDISK1\TenantVM2\GUI.vhdx -MemoryStartupBytes 1GB -Generation 2 | Out-Null
Set-VM -Name TenantVM2 -ComputerName SDNHOST1 -ProcessorCount 4


Write-Verbose "Setting Static MAC on Tenant VMs "

Set-VMNetworkAdapter -VMName TenantVM1 -ComputerName SDNHOST3 -StaticMacAddress "00-11-22-33-44-55" | Out-Null
Set-VMNetworkAdapter -VMName TenantVM2 -ComputerName SDNHOST1 -StaticMacAddress "00-11-22-33-44-56" | Out-Null

Write-Verbose "Connecting VMswitch to the VMNetwork Adapters on the Tenant VMs "

Get-VMNetworkAdapter -ComputerName SDNHOST3 -VMName TenantVM1 | Connect-VMNetworkAdapter -SwitchName sdnSwitch | Out-Null
Get-VMNetworkAdapter -ComputerName SDNHOST1 -VMName TenantVM2 | Connect-VMNetworkAdapter -SwitchName sdnSwitch | Out-Null



Write-Verbose "Starting the Tenant VMs
"
# Start the VMs
Start-VM -Name TenantVM1 -ComputerName SDNHOST3
Start-VM -Name TenantVM2 -ComputerName SDNHOST1


Write-Verbose "Getting MAC Addresses of the NICs for the VMs so we can create NC objects "
# Get the MACs
$TenantVM1Mac = (Get-VMNetworkAdapter -VMName TenantVM1 -ComputerName SDNHOST3).MacAddress
$TenantVM2Mac = (Get-VMNetworkAdapter -VMName TenantVM2 -ComputerName SDNHOST1).MacAddress

Write-Verbose " Adding VMs to our SDNCLUSTER "

$VerbosePreference = "SilentlyContinue"
Import-Module FailoverClusters
$VerbosePreference = "Continue"


Add-ClusterVirtualMachineRole -VMName TenantVM1 -Cluster SDNCLUSTER | Out-Null
Add-ClusterVirtualMachineRole -VMName TenantVM2 -Cluster SDNCLUSTER | Out-Null


# Import Network Controller Module
$VerbosePreference = "SilentlyContinue"
Import-Module NetworkController
$VerbosePreference = "Continue"

# Create ACL in Network Controller to Allow All
Write-Verbose "Creating AllowAll ACL"

$uri = "https://NC01.$($SDNConfig.SDNDomainFQDN)"


$ruleproperties = new-object Microsoft.Windows.NetworkController.AclRuleProperties  
$ruleproperties.Protocol = "All"  
$ruleproperties.SourcePortRange = "0-65535"  
$ruleproperties.DestinationPortRange = "0-65535"  
$ruleproperties.Action = "Allow"  
$ruleproperties.SourceAddressPrefix = "*"  
$ruleproperties.DestinationAddressPrefix = "*"  
$ruleproperties.Priority = "100"  
$ruleproperties.Type = "Inbound"  
$ruleproperties.Logging = "Enabled"  
$aclrule1 = new-object Microsoft.Windows.NetworkController.AclRule  
$aclrule1.Properties = $ruleproperties  
$aclrule1.ResourceId = "AllowAll_Inbound"  
$ruleproperties = new-object Microsoft.Windows.NetworkController.AclRuleProperties  
$ruleproperties.Protocol = "All"  
$ruleproperties.SourcePortRange = "0-65535"  
$ruleproperties.DestinationPortRange = "0-65535"  
$ruleproperties.Action = "Allow"  
$ruleproperties.SourceAddressPrefix = "*"  
$ruleproperties.DestinationAddressPrefix = "*"  
$ruleproperties.Priority = "110"  
$ruleproperties.Type = "Outbound"  
$ruleproperties.Logging = "Enabled"  
$aclrule2 = new-object Microsoft.Windows.NetworkController.AclRule  
$aclrule2.Properties = $ruleproperties  
$aclrule2.ResourceId = "AllowAll_Outbound"  
$acllistproperties = new-object Microsoft.Windows.NetworkController.AccessControlListProperties  
$acllistproperties.AclRules = @($aclrule1, $aclrule2)  
New-NetworkControllerAccessControlList -ResourceId "AllowAll" -Properties $acllistproperties -ConnectionUri $uri -Force


# Create VM Network in Network Controller
Write-Verbose "Creating the VM Network vmNetwork1 in NC with a subnet named vmSubnet1"

#Find the HNV Provider Logical Network 

$VMNetworkName = "vmNetwork1"
$VMSubnetName = "vmSubnet1"
$VMNetworkPrefix = '192.172.0.0/16' 
$VMSubnetPrefix = '192.172.33.0/24'

$logicalnetworks = Get-NetworkControllerLogicalNetwork -ConnectionUri $uri  
foreach ($ln in $logicalnetworks) {  
    if ($ln.Properties.NetworkVirtualizationEnabled -eq "True") {  
        $HNVProviderLogicalNetwork = $ln  
    }  
}   

#Find the Access Control List to user per virtual subnet
Write-Verbose "Getting the AllowAll ACL to apply to this VM Network"  

$acllist = Get-NetworkControllerAccessControlList -ConnectionUri $uri -ResourceId "AllowAll"  

#Create the Virtual Subnet

Write-Verbose "Creating the Virtual Subnet $VMSubnetName"

$vsubnet = new-object Microsoft.Windows.NetworkController.VirtualSubnet  
$vsubnet.ResourceId = $VMSubnetName  
$vsubnet.Properties = new-object Microsoft.Windows.NetworkController.VirtualSubnetProperties  
$vsubnet.Properties.AccessControlList = $acllist  
$vsubnet.Properties.AddressPrefix = $VMSubnetPrefix  

#Create the Virtual Network  

Write-Verbose "Creating the Virtual Network $VMNetworkName"

$vnetproperties = new-object Microsoft.Windows.NetworkController.VirtualNetworkProperties  
$vnetproperties.AddressSpace = new-object Microsoft.Windows.NetworkController.AddressSpace  
$vnetproperties.AddressSpace.AddressPrefixes = @($VMNetworkPrefix)  
$vnetproperties.LogicalNetwork = $HNVProviderLogicalNetwork  
$vnetproperties.Subnets = @($vsubnet)  
New-NetworkControllerVirtualNetwork -ResourceId $VMNetworkName -ConnectionUri $uri -Properties $vnetproperties -Force


# Add Network Interface Object for TenantVM1 in Nework Controller

Write-Verbose "Creating a Network Interface Object for TenantVM1 in NC"

$VMSubnetRef = (Get-NetworkControllerVirtualNetwork -ResourceId $VMNetworkName -ConnectionUri $uri).Properties.Subnets.ResourceRef

$vmnicproperties = new-object Microsoft.Windows.NetworkController.NetworkInterfaceProperties
$vmnicproperties.PrivateMacAddress = $TenantVM1Mac
$vmnicproperties.PrivateMacAllocationMethod = "Static" 
$vmnicproperties.IsPrimary = $true 

$ipconfiguration = new-object Microsoft.Windows.NetworkController.NetworkInterfaceIpConfiguration
$ipconfiguration.resourceid = "TenantVM1_IP1"
$ipconfiguration.properties = new-object Microsoft.Windows.NetworkController.NetworkInterfaceIpConfigurationProperties
$ipconfiguration.properties.PrivateIPAddress = “192.172.33.4”
$ipconfiguration.properties.PrivateIPAllocationMethod = "Static"
$ipconfiguration.Properties.AccessControlList = $acllist

$ipconfiguration.properties.Subnet = new-object Microsoft.Windows.NetworkController.Subnet
$ipconfiguration.properties.subnet.ResourceRef = $VMSubnetRef

$vmnicproperties.IpConfigurations = @($ipconfiguration)
New-NetworkControllerNetworkInterface –ResourceID “TenantVM1_Ethernet1” –Properties $vmnicproperties –ConnectionUri $uri -Force

$nic = Get-NetworkControllerNetworkInterface -ConnectionUri $uri -ResourceId TenantVM1_Ethernet1

Write-Verbose "Invoking command on the SDNHOST where TenantVM1 resides. Command will set the VFP extension so TenantVM1 will have access to the network."

Invoke-Command -ComputerName SDNHOST3 -ArgumentList $nic -ScriptBlock {

    $nic = $args[0]

    #The hardcoded Ids in this section are fixed values and must not change.
    $FeatureId = "9940cd46-8b06-43bb-b9d5-93d50381fd56"  # This value never changes.
 
    $vmNic = Get-VMNetworkAdapter -VMName “TenantVM1”
 
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



# Add Network Interface Object for TenantVM2 in Network Controller

Write-Verbose "Creating a Network Interface Object for TenantVM2 in NC"

$VMSubnetRef = (Get-NetworkControllerVirtualNetwork -ResourceId $VMNetworkName -ConnectionUri $uri).Properties.Subnets.ResourceRef

$vmnicproperties = new-object Microsoft.Windows.NetworkController.NetworkInterfaceProperties
$vmnicproperties.PrivateMacAddress = $TenantVM2Mac
$vmnicproperties.PrivateMacAllocationMethod = "Static" 
$vmnicproperties.IsPrimary = $true 

$ipconfiguration = new-object Microsoft.Windows.NetworkController.NetworkInterfaceIpConfiguration
$ipconfiguration.resourceid = "TenantVM2_IP1"
$ipconfiguration.properties = new-object Microsoft.Windows.NetworkController.NetworkInterfaceIpConfigurationProperties
$ipconfiguration.properties.PrivateIPAddress = “192.172.33.5”
$ipconfiguration.properties.PrivateIPAllocationMethod = "Static"
$ipconfiguration.Properties.AccessControlList = $acllist

$ipconfiguration.properties.Subnet = new-object Microsoft.Windows.NetworkController.Subnet
$ipconfiguration.properties.subnet.ResourceRef = $VMSubnetRef

$vmnicproperties.IpConfigurations = @($ipconfiguration)
New-NetworkControllerNetworkInterface –ResourceID “TenantVM2_Ethernet1” –Properties $vmnicproperties –ConnectionUri $uri -Force

$nic = Get-NetworkControllerNetworkInterface -ConnectionUri $uri -ResourceId TenantVM2_Ethernet1

Write-Verbose "Invoking command on the SDNHOST where TenantVM2 resides. Command will set the VFP extension so TenantVM2 will have access to the network."

Invoke-Command -ComputerName SDNHOST1 -ArgumentList $nic -ScriptBlock {

    $nic = $args[0]

    #The hardcoded Ids in this section are fixed values and must not change.
    $FeatureId = "9940cd46-8b06-43bb-b9d5-93d50381fd56"
 
    $vmNic = Get-VMNetworkAdapter -VMName “TenantVM2”
 
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


Write-Verbose "All done. TenantVM1 and TenantVM2 should be able to talk to one another."