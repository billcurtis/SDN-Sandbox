# This script requires that 03.01_CreateWebServerVMs.ps1 was successfully run from the console vm.
# This script requires no other load balancers for WebServerVM1/2.
# Version 1.0

<#
.SYNOPSIS 

    This script:
    
     1. Creates a load balancer named OutboundNATMMembers that is used to allow outbound traffic from a specified static VIP.
     2. Assigns that VIP to WebServerVM1's network interface.
     
   

    After running this script, follow the directions in the README.md file for this scenario.
#>

[CmdletBinding(DefaultParameterSetName = "NoParameters")]

param(

    [Parameter(Mandatory = $true, ParameterSetName = "ConfigurationFile")]
    [String] $ConfigurationDataFile = 'C:\SCRIPTS\AzSHCISandbox-Config.psd1'

)


$ErrorActionPreference = "Stop"
$VerbosePreference = "Continue"

# Load in the configuration file.

$SDNConfig = Import-PowerShellDataFile $ConfigurationDataFile
if (!$SDNConfig) { Throw "Place Configuration File in the root of the scripts folder or specify the path to the Configuration file." }
$uri = "https://NC01.$($SDNConfig.SDNDomainFQDN)"

Invoke-Command -ComputerName NC01.contoso.com -ScriptBlock {

    $uri = $using:uri

    Import-Module NetworkController

    $ErrorActionPreference = "Stop"
    $VerbosePreference = "Continue"

    $LBResourceId = "OutboundNATMMembers" # This is the name that we are going to call the load balancer
    $VIPIP = "40.40.40.20" # This is the static VIP that we will assign from the VIP Logical Network (PublicVIP) that was created when SDN was installed.

    $VIPLogicalNetwork = get-networkcontrollerlogicalnetwork -ConnectionUri $uri -resourceid "PublicVIP" -PassInnerException

    $LoadBalancerProperties = new-object Microsoft.Windows.NetworkController.LoadBalancerProperties

    # Create the FrontEnd Configuration
    $FrontEndIPConfig = new-object Microsoft.Windows.NetworkController.LoadBalancerFrontendIpConfiguration
    $FrontEndIPConfig.ResourceId = "FE1"
    $FrontEndIPConfig.ResourceRef = "/loadBalancers/$LBResourceId/frontendIPConfigurations/$($FrontEndIPConfig.ResourceId)"

    $FrontEndIPConfig.Properties = new-object Microsoft.Windows.NetworkController.LoadBalancerFrontendIpConfigurationProperties
    $FrontEndIPConfig.Properties.Subnet = new-object Microsoft.Windows.NetworkController.Subnet
    $FrontEndIPConfig.Properties.Subnet.ResourceRef = $VIPLogicalNetwork.Properties.Subnets[0].ResourceRef
    $FrontEndIPConfig.Properties.PrivateIPAddress = $VIPIP
    $FrontEndIPConfig.Properties.PrivateIPAllocationMethod = "Static"

    $LoadBalancerProperties.FrontEndIPConfigurations += $FrontEndIPConfig

    # Create the BackEnd Configuration

    $BackEndAddressPool = new-object Microsoft.Windows.NetworkController.LoadBalancerBackendAddressPool
    $BackEndAddressPool.ResourceId = "BE1"
    $BackEndAddressPool.ResourceRef = "/loadBalancers/$LBResourceId/backendAddressPools/$($BackEndAddressPool.ResourceId)"
    $BackEndAddressPool.Properties = new-object Microsoft.Windows.NetworkController.LoadBalancerBackendAddressPoolProperties

    $LoadBalancerProperties.backendAddressPools += $BackEndAddressPool

    # Create the NAT Rule

    Write-Verbose "Creating NAT Rule"
    $OutboundNAT = new-object Microsoft.Windows.NetworkController.LoadBalancerOutboundNatRule
    $OutboundNAT.ResourceId = "onat1"

    $OutboundNAT.properties = new-object Microsoft.Windows.NetworkController.LoadBalancerOutboundNatRuleProperties
    $OutboundNAT.properties.frontendipconfigurations += $FrontEndIPConfig
    $OutboundNAT.properties.backendaddresspool = $BackEndAddressPool
    $OutboundNAT.properties.protocol = "ALL"

    $LoadBalancerProperties.OutboundNatRules += $OutboundNAT

    # Create the Load Balancer

    Write-Verbose "Creating Load Balancer"

    $param = @{

        ConnectionUri = $uri
        ResourceId    = $LBResourceId
        Properties    = $LoadBalancerProperties

    }

    $LoadBalancerResource = New-NetworkControllerLoadBalancer @param -Force -PassInnerException


    # Add to Network Interface attached to WebServerVM1 

    $lb = Get-NetworkControllerLoadBalancer -ResourceId $LBResourceId -ConnectionUri $uri

    Write-Verbose "Adding Config to WebServerVM1's NIC"

    # Add Configuration to WebServerVM1_Ethernet1

    $nic1 = get-networkcontrollernetworkinterface  -connectionuri $uri -resourceid "WebServerVM1_Ethernet1"
    $nic1.properties.IpConfigurations[0].properties.LoadBalancerBackendAddressPools += $lb.properties.backendaddresspools[0] 

    $param = @{

        ConnectionUri = $uri
        ResourceId    = "WebServerVM1_Ethernet1" 
        Properties    = $nic1.properties

    }

    new-networkcontrollernetworkinterface @param -force


    # Add Configuration to WebServerVM2_Ethernet1

    Write-Verbose "Adding Config to WebServerVM2's NIC"


    $nic1 = get-networkcontrollernetworkinterface  -connectionuri $uri -resourceid "WebServerVM2_Ethernet1"
    $nic1.properties.IpConfigurations[0].properties.LoadBalancerBackendAddressPools += $lb.properties.backendaddresspools[0] 

    $param = @{

        ConnectionUri = $uri
        ResourceId    = "WebServerVM2_Ethernet1" 
        Properties    = $nic1.properties

    }

    new-networkcontrollernetworkinterface @param -force



}