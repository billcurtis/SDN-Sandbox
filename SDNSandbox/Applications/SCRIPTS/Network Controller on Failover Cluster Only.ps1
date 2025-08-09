
# Version 2.0

<#
.SYNOPSIS 

This script will install the Network Controller on a Failover Cluster only.

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

#enable kerb delegation 

Set-ADComputer -Identity (Get-ADComputer SDNHOST1) -PrincipalsAllowedToDelegateToAccount (Get-ADComputer admincenter)
Set-ADComputer -Identity (Get-ADComputer SDNHOST2) -PrincipalsAllowedToDelegateToAccount (Get-ADComputer admincenter)

# create folders
Invoke-Command -ComputerName SDNHOST1 -ScriptBlock {

New-Item -Path 'C:\ClusterStorage\Volume01\' -Name VHD -ItemType Directory -Force | Out-Null
New-Item -Path 'C:\ClusterStorage\Volume01\' -Name SDN -ItemType Directory -Force | Out-Null


} -Credential $domainCred

#Create Rest Name
$RestName = "nc.$($SDNConfig.SDNDomainFQDN)"
$FQDN = $SDNConfig.SDNDomainFQDN
$RestIPAddress = ($SDNConfig.MGMTSubnet).TrimEnd("0/24") + "110/24"


# Copy core vhd to SDN folder
# To do later....not necessary for this script.

$ErrorActionPreference = "Continue"

Invoke-Command -ComputerName SDNHOST1 -ScriptBlock {

$ErrorActionPreference = "Continue"

$SDNConfig = $using:SDNConfig
$domainUserName = ($SDNConfig.SDNDomainFQDN.Split(".")[0]) + "\administrator"
$paGateway = ($SDNConfig.ProviderSubnet).TrimEnd("0/24") + "1"
$paPoolStart = ($SDNConfig.ProviderSubnet).TrimEnd("0/24") + "2"
$paPoolEnd = ($SDNConfig.ProviderSubnet).TrimEnd("0/24") + "200"
$BGPRouterIP = ($SDNConfig.BGPRouterIP_ProviderNetwork.Split("/")[0])
$RestName = "nc.$($SDNConfig.SDNDomainFQDN)"
$RestIPAddress = ($SDNConfig.MGMTSubnet).TrimEnd("0/24") + "110/24"


# generate sdn data answer file
$sdndata = "
@{
    ScriptVersion        = '4.2'
    UseFCNC	= 1
    FCNCDBs = 'C:\ClusterStorage\Volume01\SDN'
    VHDPath              = 'C:\ClusterStorage\Volume01\vhd'
    VHDFile              = 'core.vhdx'
    VMLocation           = 'C:\ClusterStorage\Volume01\SDN'
    JoinDomain           =  '$($SDNConfig.SDNDomainFQDN)'
    SDNMacPoolStart      = '00-1D-D8-4F-00-00'
    SDNMacPoolEnd        = '00-1D-D8-4F-FF-FF'
    ManagementSubnet     = '$($SDNConfig.MGMTSubnet)'
    ManagementGateway    = '$($SDNConfig.SDNLABRoute)'
    ManagementDNS        = @('$($SDNConfig.SDNLABDNS)')
    ManagementVLANID     = 0
    DomainJoinUsername   = '$domainUserName'
    LocalAdminDomainUser = '$domainUserName'
    NCUsername           = '$domainUserName'
    RestName             =  '$($RestName)'
    RestIpAddress        =  '$($RestIPAddress)'
    UseCertBySubject = 1
    IsSiteAware = `$false
    NCs = @()
    Muxes = @()
    Gateways = @()

    HyperVHosts = @(
        'SDNHOST1', 
        'SDNHOST2' 
    )

    PASubnet             = '$($SDNConfig.ProviderSubnet)'
    PAVLANID             = '$($SDNConfig.providerVLAN)'
    PAGateway            = '$($paGateway)'
    PAPoolStart          = '$($paPoolStart)'
    PAPoolEnd            = '$($paPoolEnd)' 
    SDNASN               = '$($SDNConfig.SDNASN)'
    
    Routers = @(
        @{ RouterASN='$($SDNConfig.BGPRouterASN)'; RouterIPAddress='$($BGPRouterIP)'}
    )

    PrivateVIPSubnet     = '$($SDNConfig.PrivateVIPSubnet)'
    PublicVIPSubnet      = '$($SDNConfig.PublicVIPSubnet)'
    GRESubnet            = '$($SDNConfig.GRESubnet)'
    Capacity             = 10000000
    PoolName             = 'DefaultAll'
    ProductKey       = '$($SDNConfig.GUIProductKey)'
    SwitchName = 'sdnSwitch'
    VMMemory = 4GB
    VMProcessorCount = 4
    Locale           = ''
    TimeZone         = ''

    # Starting version 4.0 of sdnexpress, credentials cannot be passed via the scripts. The credentials must be entered manually or passed in. 
}
"

$sdndata | Set-Content -Path C:\ClusterStorage\Volume01\SDN\sdndata.psd1 -Force

# set cred objects
$domainCred = new-object -typename System.Management.Automation.PSCredential `
    -argumentlist (($SDNConfig.SDNDomainFQDN.Split(".")[0]) + "\administrator"), `
(ConvertTo-SecureString $SDNConfig.SDNAdminPassword -AsPlainText -Force)

$localCred = new-object -typename System.Management.Automation.PSCredential `
    -argumentlist ("administrator"), `
(ConvertTo-SecureString $SDNConfig.SDNAdminPassword -AsPlainText -Force)


# new config to avoid double hop - which I SHOULD NOT HAVE TO DO!!!!

  $params = @{

                Name                                = 'microsoft.SDNInstall'
                RunAsCredential                     = $Using:domainCred 
                MaximumReceivedDataSizePerCommandMB = 1000
                MaximumReceivedObjectSizeMB         = 1000
            }

            $VerbosePreference = "SilentlyContinue"            
            Register-PSSessionConfiguration @params
            $VerbosePreference = "Continue"

Invoke-Command -ComputerName SDNHOST1 `
-Credential $domainCred `
-ConfigurationName microsoft.SDNInstall `
-ArgumentList $domainCred, $localCred `
-ScriptBlock {

$domainCred = $args[0]
$localCred = $args[1]

# Install Nuget
Install-PackageProvider -Name Nuget -MinimumVersion 2.8.5.201 -Force

# install sdnexpress cmdlets
Install-Module SdnExpress -Confirm:$false -Force
Import-Module SdnExpress

# set location to folder
$scriptdir = (Get-ChildItem 'C:\Program Files\WindowsPowerShell\Modules\SdnExpress').Name
Set-Location -Path "C:\Program Files\WindowsPowerShell\Modules\SdnExpress\$scriptdir"

# run sdn install

$params = @{

ConfigurationDataFile = 'C:\ClusterStorage\Volume01\SDN\sdndata.psd1'
DomainJoinCredential = $domainCred
NCCredential = $domainCred
LocalAdminCredential = $localCred

}

.\SDNExpress.ps1 @params

}

Get-PSSessionConfiguration -Name microsoft.sdnInstall | Unregister-PSSessionConfiguration -Force

# Export Certificate

$expcert = Get-ChildItem Cert:\LocalMachine\My | Where-Object {$_.Subject -match $RestName}
Export-Certificate -Cert $expcert -FilePath 'C:\ClusterStorage\Volume01\SDN\nccert.cer'

} -Credential $domainCred


#Import NC Certificate

Write-Verbose -Message "Importing NC Certificate into Admincenter VM"
$params = @{
    FilePath = '\\sdnhost1\C$\ClusterStorage\Volume01\SDN\nccert.cer'
    CertStoreLocation = 'Cert:\CurrentUser\Root'
}
Import-Certificate @params -Confirm:$false 


# Create DNS A Record for network controller

$params = @{

ComputerName = $SDNConfig.DCName
Name = "nc"
ZoneName = $FQDN
IPV4Address = ($RestIPAddress.TrimEnd("/24"))

}

Add-DnsServerResourceRecordA @params

