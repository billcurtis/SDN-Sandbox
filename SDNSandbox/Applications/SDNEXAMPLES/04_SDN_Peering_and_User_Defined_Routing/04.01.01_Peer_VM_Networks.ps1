<#
.DESCRIPTION 

This script will peer two virtual networks together. The script will peer TenantNetwork1 to WebNetwork1 and WebNetwork1 to TenantNetwork1.


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
$uri = "https://NC.$($SDNConfig.SDNDomainFQDN)"
$networkcontroller = "NC.$($SDNConfig.SDNDomainFQDN)"

# Part 01: Peer TenantNetwork1 to WebNetwork1

$SourceVMNetwork = 'TenantNetwork1'

# Virtual Network to Peer with
$peerVMNetwork = 'webNetwork1'
$resourceIDforPeering = 'TenantNetwork1-to-webNetwork1'

$peeringProperties = New-Object Microsoft.Windows.NetworkController.VirtualNetworkPeeringProperties
$vnet2 = Get-NetworkControllerVirtualNetwork -ConnectionUri $uri -ResourceId $peerVMNetwork
$peeringProperties.remoteVirtualNetwork = $vnet2

#Indicate whether communication between the two virtual networks
$peeringProperties.allowVirtualnetworkAccess = $true

#Indicates whether forwarded traffic is allowed across the vnets
$peeringProperties.allowForwardedTraffic = $true

#Indicates whether the peer virtual network can access this virtual networks gateway
$peeringProperties.allowGatewayTransit = $false

#Indicates whether this virtual network uses peer virtual networks gateway
$peeringProperties.useRemoteGateways = $false

$Param = @{

    ConnectionUri    = $uri
    VirtualNetworkId = $SourceVMNetwork
    ResourceId       = $resourceIDforPeering
    Properties       = $peeringProperties

}

New-NetworkControllerVirtualNetworkPeering @Param -Force -Confirm:$false


# Part 02: Peer  WebNetwork1 to TenantNetwork1

$SourceVMNetwork = 'webNetwork1'

# Virtual Network to Peer with
$peerVMNetwork = 'TenantNetwork1'
$resourceIDforPeering = 'webNetwork1-to-TenantNetwork1'

$peeringProperties = New-Object Microsoft.Windows.NetworkController.VirtualNetworkPeeringProperties
$vnet2 = Get-NetworkControllerVirtualNetwork -ConnectionUri $uri -ResourceId $peerVMNetwork
$peeringProperties.remoteVirtualNetwork = $vnet2

#Indicate whether communication between the two virtual networks
$peeringProperties.allowVirtualnetworkAccess = $true

#Indicates whether forwarded traffic is allowed across the vnets
$peeringProperties.allowForwardedTraffic = $true

#Indicates whether the peer virtual network can access this virtual networks gateway
$peeringProperties.allowGatewayTransit = $false

#Indicates whether this virtual network uses peer virtual networks gateway
$peeringProperties.useRemoteGateways = $false

$Param = @{

    ConnectionUri    = $uri
    VirtualNetworkId = $SourceVMNetwork
    ResourceId       = $resourceIDforPeering
    Properties       = $peeringProperties

}

New-NetworkControllerVirtualNetworkPeering @Param -Force -Confirm:$false

