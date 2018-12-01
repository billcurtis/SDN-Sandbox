# Version 1.0

<#
.SYNOPSIS 

    This script:
    
     1. 
   

    After running this script, follow the directions in the README.md file for this scenario.
#>


[CmdletBinding(DefaultParameterSetName = "NoParameters")]

param(

    [Parameter(Mandatory = $true, ParameterSetName = "ConfigurationFile")]
    [String] $ConfigurationDataFile = 'C:\SCRIPTS\NestedSDN-Config.psd1'

)

$configureBGP = $false

Import-Module NetworkController

$ErrorActionPreference = "Stop"
$VerbosePreference = "Continue"

# Load in the configuration file.
$SDNConfig = Import-PowerShellDataFile $ConfigurationDataFile
if (!$SDNConfig) {Throw "Place Configuration File in the root of the scripts folder or specify the path to the Configuration file."}

# Set Credential Object
$domainCred = new-object -typename System.Management.Automation.PSCredential `
    -argumentlist (($SDNConfig.SDNDomainFQDN.Split(".")[0]) + "\administrator"), `
(ConvertTo-SecureString $SDNConfig.SDNAdminPassword -AsPlainText -Force)





#Set Variables

$uri = "https://NC01.$($SDNConfig.SDNDomainFQDN)"
$fqdn = $SDNConfig.SDNDomainFQDN
$VMNetwork = "VMNetwork1"
$VMSubnet = "VMSubnet1"
$vGatewayName = "L3Connection"
$vLogicalNetName = "VLAN_200_Network"
$vLogicalSubnetName = "VLAN_200_Subnet"
$gwConnectionName = "L3GW" 



# Retrieve the Gateway Pool configuration  

$gwPool = Get-NetworkControllerGatewayPool -ConnectionUri $uri 

 
# Retrieve the Tenant Virtual Network configuration  

$Vnet = Get-NetworkControllerVirtualNetwork -ConnectionUri $uri  -ResourceId $VMNetwork


# Retrieve the Tenant Virtual Subnet configuration 
 
$RoutingSubnet = Get-NetworkControllerVirtualSubnet -ConnectionUri $uri  -ResourceId $VMSubnet -VirtualNetworkID $vnet.ResourceId   


# Create a new object for Tenant Virtual Gateway 
 
$VirtualGWProperties = New-Object Microsoft.Windows.NetworkController.VirtualGatewayProperties   
  
# Update Gateway Pool reference 
 
$VirtualGWProperties.GatewayPools = @()   
$VirtualGWProperties.GatewayPools += $gwPool   
  
# Specify the Virtual Subnet that is to be used for routing between the gateway and Virtual Network
   
$VirtualGWProperties.GatewaySubnets = @()   
$VirtualGWProperties.GatewaySubnets += $RoutingSubnet 
  
# Update the rest of the Virtual Gateway object properties
  
$VirtualGWProperties.RoutingType = "Dynamic"   
$VirtualGWProperties.NetworkConnections = @()   
$VirtualGWProperties.BgpRouters = @()   
  
# Add the new Virtual Gateway for tenant 
  
$virtualGW = New-NetworkControllerVirtualGateway -ConnectionUri $uri  -ResourceId $vGatewayName -Properties $VirtualGWProperties -Force


##################
# For a L3 forwarding network connection to work properly, you must configure a corresponding logical network.
##################


# Create a new object for the Logical Network to be used for L3 Forwarding
  
$lnProperties = New-Object Microsoft.Windows.NetworkController.LogicalNetworkProperties  

$lnProperties.NetworkVirtualizationEnabled = $false  
$lnProperties.Subnets = @()  

# Create a new object for the Logical Subnet to be used for L3 Forwarding and update properties  

$logicalsubnet = New-Object Microsoft.Windows.NetworkController.LogicalSubnet  
$logicalsubnet.ResourceId = $vLogicalSubnetName
$logicalsubnet.Properties = New-Object Microsoft.Windows.NetworkController.LogicalSubnetProperties  
$logicalsubnet.Properties.VlanID = 200  
$logicalsubnet.Properties.AddressPrefix = "192.168.200.0/24"  
$logicalsubnet.Properties.DefaultGateways = "192.168.200.1"  

$lnProperties.Subnets += $logicalsubnet  

# Add the new Logical Network to Network Controller  
$vlanNetwork = New-NetworkControllerLogicalNetwork -ConnectionUri $uri -ResourceId $vLogicalNetName -Properties $lnProperties -Force  



# Create a Network Connection JSON Object and add it to Network Controller.

# Create a new object for the Tenant Network Connection  
$nwConnectionProperties = New-Object Microsoft.Windows.NetworkController.NetworkConnectionProperties   

# Update the common object properties  
$nwConnectionProperties.ConnectionType = "L3"   
$nwConnectionProperties.OutboundKiloBitsPerSecond = 10000   
$nwConnectionProperties.InboundKiloBitsPerSecond = 10000   

# GRE specific configuration (leave blank for L3)  
$nwConnectionProperties.GreConfiguration = New-Object Microsoft.Windows.NetworkController.GreConfiguration   

# Update specific properties depending on the Connection Type  
$nwConnectionProperties.L3Configuration = New-Object Microsoft.Windows.NetworkController.L3Configuration   
$nwConnectionProperties.L3Configuration.VlanSubnet = $vlanNetwork.properties.Subnets[0]   

$nwConnectionProperties.IPAddresses = @()   
$localIPAddress = New-Object Microsoft.Windows.NetworkController.CidrIPAddress   
$localIPAddress.IPAddress = "192.168.200.254"   
$localIPAddress.PrefixLength = 24   
$nwConnectionProperties.IPAddresses += $localIPAddress   

$nwConnectionProperties.PeerIPAddresses = @("192.168.200.1")  

# Update the IPv4 Routes that are reachable over the site-to-site VPN Tunnel  

$ipv4RouteDestPrefixes = @("192.168.1.0/24", "192.172.0.0/24")

$nwConnectionProperties.Routes = @()  

foreach ($ipv4RouteDestPrefix in $ipv4RouteDestPrefixes) {

    $ipv4Route = New-Object Microsoft.Windows.NetworkController.RouteInfo
    $ipv4Route.DestinationPrefix = $ipv4RouteDestPrefix  
    $ipv4Route.metric = 10  
    $nwConnectionProperties.Routes += $ipv4Route   

}

# Add the new Network Connection for the tenant  
New-NetworkControllerVirtualGatewayNetworkConnection -ConnectionUri $uri -VirtualGatewayId $virtualGW.ResourceId -ResourceId $gwConnectionName -Properties $nwConnectionProperties -Force


if ($configureBGP) {

    ### Configure BGP

    # Create a new object for the Tenant BGP Router  
    $bgpRouterproperties = New-Object Microsoft.Windows.NetworkController.VGwBgpRouterProperties   

    # Update the BGP Router properties  
    $bgpRouterproperties.ExtAsNumber = "0.64513"   
    $bgpRouterproperties.RouterId = "192.172.33.3"   
    $bgpRouterproperties.RouterIP = @("192.172.33.3")   

    # Add the new BGP Router for the tenant  
    $bgpRouter = New-NetworkControllerVirtualGatewayBgpRouter -ConnectionUri $uri -VirtualGatewayId $virtualGW.ResourceId -ResourceId "BgpRouterL3" -Properties $bgpRouterProperties -Force

    # Add the BGPPeer (Which will be the BGP-ToR-Router VM)


    # Create a new object for Tenant BGP Peer  
    $bgpPeerProperties = New-Object Microsoft.Windows.NetworkController.VGwBgpPeerProperties   

    # Update the BGP Peer properties  
    $bgpPeerProperties.PeerIpAddress = "172.17.0.1"   
    #$bgpPeerProperties.AsNumber = 65534   
    $bgpPeerProperties.ExtAsNumber = "0.65534"   

    # Add the new BGP Peer for tenant  
    New-NetworkControllerVirtualGatewayBgpPeer -ConnectionUri $uri -VirtualGatewayId $virtualGW.ResourceId -BgpRouterName $bgpRouter.ResourceId -ResourceId "Contoso_Peer" -Properties $bgpPeerProperties -Force

} 
  