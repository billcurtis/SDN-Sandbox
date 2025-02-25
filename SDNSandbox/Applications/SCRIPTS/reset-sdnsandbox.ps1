<#

This script will remove all SDN components from the SDN Sandbox environment.

#>

[CmdletBinding(DefaultParameterSetName = "NoParameters")]

param(

    [Parameter(Mandatory = $true, ParameterSetName = "ConfigurationFile")]
    [String] $ConfigurationDataFile = 'C:\SCRIPTS\SDNSandbox-Config.psd1'

)

$ErrorActionPreference = "Stop"
$VerbosePreference = "Continue"

# load configuration file
$SDNConfig = Import-PowerShellDataFile $ConfigurationDataFile
if (!$SDNConfig) { Throw "Place Configuration File in the root of the scripts folder or specify the path to the Configuration file." }

# set creds
$domainCred = new-object -typename System.Management.Automation.PSCredential `
    -argumentlist (($SDNConfig.SDNDomainFQDN.Split(".")[0]) + "\administrator"), `
(ConvertTo-SecureString $SDNConfig.SDNAdminPassword -AsPlainText -Force)

$localCred = new-object -typename System.Management.Automation.PSCredential `
    -argumentlist ("administrator"), `
(ConvertTo-SecureString "Password01" -AsPlainText -Force)

 

$NCVMs = @("GW01,GW02", "Mux01", "NC")
$SDNHOSTS = @("SDNHOST1", "SDNHOST2")


# Remove all VM Cluster roles
Write-Host -Message "Removing all VM Cluster Resources from SDNCLUSTER"
Get-ClusterGroup -Cluster SDNCLUSTER | Where-Object { $_.GroupType -eq "VirtualMachine" } | Remove-ClusterGroup -Force -Confirm:$false -RemoveResources

# Remove All VMs
foreach ($SDNHOST in $SDNHOSTS) {

    Write-Verbose -Message "Removing all VMs"
    Get-VM -ComputerName $SDNHOST | Stop-VM -TurnOff 
    Get-VM -ComputerName $SDNHOST | Remove-VM -Force -Confirm:$false

}



$ErrorActionPreference = "SilentlyContinue"
Invoke-Command -ComputerName $SDNHOSTS[0] -ScriptBlock {

    $ErrorActionPreference = "SilentlyContinue"
    # Get rid of any SDNUninstall PSSession config if still exists
    Write-Host  "Getting rid of any PSSession Configurations"

    $isSession = Get-PSSessionConfiguration | Where-Object { $_.Name -eq "microsoft.sdnUnInstall" }
    if ($isSession) { Get-PSSessionConfiguration -Name microsoft.sdnUnInstall | Unregister-PSSessionConfiguration -Force }


    # Restart winrm service
    Write-Host "Restarting WinRM"
    Get-Service -Name WinRM | Restart-Service -PassThru }
Start-Sleep -Seconds 5

Invoke-Command -ComputerName $SDNHOSTS[0] -ScriptBlock {
 

    $params = @{

        Name                                = 'microsoft.sdnUnInstall'
        RunAsCredential                     = $Using:domainCred 
        MaximumReceivedDataSizePerCommandMB = 1000
        MaximumReceivedObjectSizeMB         = 1000
    }

    $VerbosePreference = "SilentlyContinue"            
    Register-PSSessionConfiguration @params
    $VerbosePreference = "Continue"


    $domainCred = $using:domainCred
    $localCred = $using:localCred

    Invoke-Command -ComputerName SDNHOST1 `
        -Credential $domainCred `
        -ConfigurationName microsoft.sdnUnInstall `
        -ArgumentList $domainCred, $localCred `
        -ScriptBlock {

        $domainCred = $args[0]
        $localCred = $args[1] 


        # run sdn unininstall
        $ErrorActionPreference = "SilentlyContinue"
        $isFC = Get-NetworkControllerOnFailoverCluster
        $ErrorActionPreference = "Stop"
        If ($isFC) {

            Uninstall-NetworkControllerOnFailoverCluster

        }
 

    }

    Get-PSSessionConfiguration -Name microsoft.sdnUnInstall | Unregister-PSSessionConfiguration -Force
    Stop-Cluster -Force -Confirm:$false

}
$ErrorActionPreference = "Continue"


# Delete SDN and VHD Directories
Remove-Item '\\sdnhost1\C$\ClusterStorage\Volume01\SDN' -Recurse -ErrorAction SilentlyContinue
Remove-Item '\\sdnhost1\C$\ClusterStorage\Volume01\VHD' -Recurse -ErrorAction SilentlyContinue

foreach ($SDNHOST in $SDNHOSTS) {
    Invoke-Command -ComputerName $SDNHOST -ScriptBlock {

        Remove-ItemProperty -path 'HKLM:\SYSTEM\CurrentControlSet\Services\NcHostAgent\Parameters\' -Name Connections  -ErrorAction SilentlyContinue
        Remove-ItemProperty -path 'HKLM:\SYSTEM\CurrentControlSet\Services\NcHostAgent\Parameters\' -Name NetworkControllerNodeNames -ErrorAction SilentlyContinue
        Uninstall-WindowsFeature -Name NetworkController -IncludeManagementTools -ErrorAction SilentlyContinue
        Uninstall-WindowsFeature -Name NetworkVirtualization -ErrorAction SilentlyContinue
        Disable-VMSwitchExtension -VMSwitchName "sdnSwitch" -Name "Microsoft Azure VFP Switch Extension" 
        Uninstall-Module SDNExpress -ErrorAction SilentlyContinue
        Write-Verbose -Message "Restarting $($using:sdnhost)"
        Restart-Computer -Force -Confirm:$false


    }
}


# Remove DNS entry for NC

$RestName = "nc.$($SDNConfig.SDNDomainFQDN)"
$FQDN = $SDNConfig.SDNDomainFQDN

$params = @{

    ComputerName = $SDNConfig.DCName
    Name         = "nc"
    ZoneName     = $FQDN
    RRtype       = "A"

}
$ErrorActionPreference = "SilentlyContinue"
Remove-DnsServerResourceRecord @params -ErrorAction SilentlyContinue -Force -Confirm:$false
$ErrorActionPreference = "Continue"




Write-Verbose -Message "Removing NC Certificate from AdminCenter VM - Confirmation Dialog may be behind screen."
$RestName = "nc.$($SDNConfig.SDNDomainFQDN)"
$cert = Get-ChildItem Cert:\CurrentUser\Root | Where-Object { $_.Subject -match $RestName }
$expression = "echo Y | CertUtil -delstore -f -user Root $($cert.Thumbprint)"
Invoke-Expression -Command $expression


Write-Host "Please wait a few minutes before redeploying SDN to let the cluster nodes reboot."