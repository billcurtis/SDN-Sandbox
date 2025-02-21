        # Load Balancer Name
        $ResourceID = 'LB1'

        
        # Create VIP
        $publicIPProperties = new-object Microsoft.Windows.NetworkController.PublicIpAddressProperties
        $publicIPProperties.PublicIPAllocationMethod = "dynamic"
        $publicIPProperties.IdleTimeoutInMinutes = 4
        $publicIP = New-NetworkControllerPublicIpAddress -ResourceId "MyPIP" -Properties $publicIPProperties -ConnectionUri $uri -force
        

        # Clear variables
        $LoadBalancerProperties = $null
        $FrontEnd = $null
        $BackEnd = $null
        $lbrule = $null

        # Set Variables
        $FrontEndName = "DefaultAll"
        $BackendName = "vmNetwork1"

        $LoadBalancerProperties = new-object Microsoft.Windows.NetworkController.LoadBalancerProperties

        # Create a front-end IP configuration

        $LoadBalancerProperties.frontendipconfigurations += $FrontEnd = new-object Microsoft.Windows.NetworkController.LoadBalancerFrontendIpConfiguration
        $FrontEnd.properties = new-object Microsoft.Windows.NetworkController.LoadBalancerFrontendIpConfigurationProperties
        $FrontEnd.resourceId = $FrontEndName
        $FrontEnd.ResourceRef = "/loadbalancers/$Resourceid/frontendipconfigurations/$FrontEndName"
        $FrontEnd.properties.PublicIPAddress = $PublicIP

        # Create a back-end address pool

        $BackEnd = new-object Microsoft.Windows.NetworkController.LoadBalancerBackendAddressPool
        $BackEnd.properties = new-object Microsoft.Windows.NetworkController.LoadBalancerBackendAddressPoolProperties
        $BackEnd.resourceId = $BackendName
        $BackEnd.ResourceRef = "/loadbalancers/$Resourceid/BackEndAddressPools/$BackendName"
        $LoadBalancerProperties.backendAddressPools += $BackEnd

        # Create the Load Balancing Rules

        $LoadBalancerProperties.loadbalancingRules += $lbrule = new-object Microsoft.Windows.NetworkController.LoadBalancingRule
        $lbrule.properties = new-object Microsoft.Windows.NetworkController.LoadBalancingRuleProperties
        $lbrule.ResourceId = "webserver1"
        $lbrule.properties.frontendipconfigurations += $FrontEnd
        $lbrule.properties.backendaddresspool = $BackEnd 
        $lbrule.properties.protocol = "TCP"
        $lbrule.properties.frontendPort = 80
        $lbrule.properties.backendPort = 80
        $lbrule.properties.IdleTimeoutInMinutes = 4

        $LoadBalancerProperties.loadbalancingRules += $lbrule = new-object Microsoft.Windows.NetworkController.LoadBalancingRule
        $lbrule.properties = new-object Microsoft.Windows.NetworkController.LoadBalancingRuleProperties
        $lbrule.ResourceId = "RDP"
        $lbrule.properties.frontendipconfigurations += $FrontEnd
        $lbrule.properties.backendaddresspool = $BackEnd 
        $lbrule.properties.protocol = "TCP"
        $lbrule.properties.frontendPort = 3389
        $lbrule.properties.backendPort = 3389
        $lbrule.properties.IdleTimeoutInMinutes = 4

        $loadBalancerProperties.OutboundNatRules = @(new-object Microsoft.Windows.NetworkController.LoadBalancerOutboundNatRule)
        $loadBalancerProperties.OutboundNatRules[0].properties = @{}
        $loadBalancerProperties.OutboundNatRules[0].ResourceId = "onat1"
        $loadBalancerProperties.OutboundNatRules[0].properties.frontendipconfigurations = @()
        $loadBalancerProperties.OutboundNatRules[0].properties.frontendipconfigurations = $FrontEnd
        $loadBalancerProperties.OutboundNatRules[0].properties.backendaddresspool = $BackEnd
        $loadBalancerProperties.OutboundNatRules[0].properties.protocol = "ALL"



        # Create LB1

        $lb = New-NetworkControllerLoadBalancer -ConnectionUri $uri -ResourceId $ResourceID -Properties $LoadBalancerProperties -Force



        # Add Network Interfaces
       $acllist = Get-NetworkControllerAccessControlList -ConnectionUri $uri -ResourceId "AllowAll"  


        $lbresourceid = "LB1"
        $lb = (Invoke-WebRequest -Headers @{"Accept"="application/json"} -ContentType "application/json; charset=UTF-8" -Method "Get" -Uri "$uri/Networking/v1/loadbalancers/$lbresourceid" -DisableKeepAlive -UseBasicParsing).content | convertfrom-json


        $nic = get-networkcontrollernetworkinterface  -connectionuri $uri -resourceid "TenantVM1_Ethernet1"
        $nic.properties.IpConfigurations[0].properties.LoadBalancerBackendAddressPools += $lb.properties.backendaddresspools[0]
        $nic.Properties.IpConfigurations.Properties.AccessControlList = $acllist
 

        new-networkcontrollernetworkinterface  -connectionuri $uri -resourceid "TenantVM1_Ethernet1" -properties $nic.properties -force