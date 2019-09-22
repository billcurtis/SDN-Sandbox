# This script requires that 03.01_LoadBalanceWebServerVMs.ps1 was successfully run from the console vm.
# Version 1.0

<#
.SYNOPSIS 

    This script:
    
     1. Removes the load balancer WEBLB
     2. Removes the WEBLB-IP Public IP address.
   

    After running this script, follow the directions in the README.md file for this scenario.
#>

Remove-NetworkControllerLoadBalancer -ResourceId "WEBLB" -ConnectionUri $uri -Force
Remove-NetworkControllerPublicIpAddress -ResourceId WEBLB-IP -ConnectionUri $uri -Force