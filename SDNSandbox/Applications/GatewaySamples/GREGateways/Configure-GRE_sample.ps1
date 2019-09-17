# Version 1.0

<#
.SYNOPSIS 

    This script:

     1. This script will create a GRE Gateway Network Connection to the GRE-Target VM as well as peer the GRE 
        connection to a BGP router that is located on the GRE-Target virtual machine. After this script is run, you 
        should be able to connect to resources on the Management Network. You will have to configure iDNS 
        (script is available) if you want to perform functions such as joining the domain, etc.
    
     2. Assumes that you have the defaults in your configuration file for the GRE network and Management Network.
        You can change the properties below to fit your deployment of the SDN Sandbox.

     3. Assumes that you have not deployed any other Gateways to the active Gateway VM.

     4. Assumes that you have deployed TenantVM1 and TenantVM2 as well as attached them to a VM Network.

    I have tried to comment as much as possible in this script on the parameters network controller requires
    in order to create a GRE connection. Email sdnblackbelt@microsoft.com if you require any clarification or have 
    questions regarding GRE Gateways. 

    After running this script, follow the directions in the README.md file for this scenario.
#>


[CmdletBinding(DefaultParameterSetName = "NoParameters")]

param(

    [Parameter(Mandatory = $true, ParameterSetName = "ConfigurationFile")]
    [String] $ConfigurationDataFile = 'C:\SCRIPTS\NestedSDN-Config.psd1'

)

$VerbosePreference = "SilentlyContinue"
Import-Module NetworkController

$ErrorActionPreference = "Stop"
$VerbosePreference = "Continue"

# Load in the configuration file.
$SDNConfig = Import-PowerShellDataFile $ConfigurationDataFile
if (!$SDNConfig) {Throw "Place Configuration File in the root of the scripts folder or specify the path to the Configuration file."}

# Set Credential Objects

$localCred = new-object -typename System.Management.Automation.PSCredential `
    -argumentlist "administrator", (ConvertTo-SecureString $SDNConfig.SDNAdminPassword -AsPlainText -Force)


# Set Connection IPs
####################

$uri = "https://NC01.$($SDNConfig.SDNDomainFQDN)"  # This is the URI for Network Controller
$VMNetwork = "VMNetwork1"                          # This is the VM Network that will use the L3 Gateway
$VMSubnet = "VMSubnet1"                            # This is the VM Subnet that will use the L3 Gateway
$vGatewayName = "GREGateway"                       # Name that will be used for the Gateway resource ID. This can be any string.
$gwConnectionName = "GREConnection"                # Name that will be used for the Gateway Connection that will be created for the L3 Gateway. This can be any string.
$greKey = "1234"                                   # Ensure that this key matches the key in script:
$greIP = "192.168.1.1"                             # Endpoint that the GRE GW connection is going to try connect to.


# Routes
########

# These are the routes that ONLY will be routable OUT of the VM Nework through the GRE Gateway

$ipv4RouteDestPrefixes = @("192.168.1.0/24")      # This is the route for the Management Network.


#########################
#  Creating the Gateway #
######################### 

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

$params = @{

    ConnectionUri = $uri
    ResourceId    = $vGatewayName
    Properties    = $VirtualGWProperties

}
  
$virtualGW = New-NetworkControllerVirtualGateway @params -Force


#############################################
#  Creating GRE VPN S2S Network Connection  #
#############################################


#Create a new object for the Tenant Network Connection  
$nwConnectionProperties = New-Object Microsoft.Windows.NetworkController.NetworkConnectionProperties   

# Update the common object properties  
$nwConnectionProperties.ConnectionType = "GRE"   
$nwConnectionProperties.OutboundKiloBitsPerSecond = 10000   
$nwConnectionProperties.InboundKiloBitsPerSecond = 10000   

# Update specific properties depending on the Connection Type  
$nwConnectionProperties.GreConfiguration = New-Object Microsoft.Windows.NetworkController.GreConfiguration   
$nwConnectionProperties.GreConfiguration.GreKey = $greKey  

# Update the IPv4 Routes that are reachable over the site-to-site VPN Tunnel  
$nwConnectionProperties.Routes = @()  

foreach ($ipv4RouteDestPrefix in $ipv4RouteDestPrefixes) {

    $ipv4Route = New-Object Microsoft.Windows.NetworkController.RouteInfo
    $ipv4Route.DestinationPrefix = $ipv4RouteDestPrefix  
    $ipv4Route.metric = 256  
    $nwConnectionProperties.Routes += $ipv4Route

}  

# Tunnel Destination (Remote Endpoint) Address  
$nwConnectionProperties.DestinationIPAddress = $greIP.Split("/")[0] 

# L3 specific configuration (leave blank for GRE)  
$nwConnectionProperties.L3Configuration = New-Object Microsoft.Windows.NetworkController.L3Configuration   
$nwConnectionProperties.IPAddresses = @()   
$nwConnectionProperties.PeerIPAddresses = @()   

# Add the new Network Connection for the tenant

$params = @{

    ConnectionUri    = $uri
    VirtualGatewayId = $virtualGW.ResourceId
    ResourceId       = $gwConnectionName
    Properties       = $nwConnectionProperties

}
  
New-NetworkControllerVirtualGatewayNetworkConnection @params -Force


$params = @{

    ConnectionUri = $uri
    ResourceId    = $vGatewayName

}

#Remove-NetworkControllerVirtualGateway @params