# Version 1.0

<#
.SYNOPSIS 

    This script shows you how to configure and enable iDNS in SDN.

 
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


# STEP01: Install and configure DNS Server

Write-Verbose "First, we need to install a DNS Server, we could use the DC's DNS server, but that would be a little messy. Let's create a DNS server on the admincenter VM..."

Install-WindowsFeature -Name DNS -IncludeManagementTools -ComputerName AdminCenter | Out-Null

Write-Verbose "Now we need to create a Zone for our new DNS server"

$VerbosePreference = "SilentlyContinue"
Import-Module DnsServer
$VerbosePreference = "Continue"

Add-DnsServerPrimaryZone -Name "tenantsdn.local" -ZoneFile "tenantsdn.dns" -ComputerName admincenter

Write-Verbose "Now we need to create a forwarder to our other DNS server"

Add-DnsServerForwarder -IPAddress $SDNConfig.SDNLABDNS -ComputerName admincenter


# STEP02: Configure iDNS information in Network Controller

Write-Verbose "Getting the IP for AdminCenter"

$adminCenterIP = (Test-Connection -Count 1 -ComputerName admincenter).IPV4Address.IPAddressToString

Write-Verbose "Getting URI for Network Controller"

$uri = "https://nc01.$($SDNConfig.SDNDomainFQDN)"

Write-Verbose "Setting URI for the iDNS configuration settings in Network Controller"

$dnsUri = "$uri/networking/v1/iDnsServer/configuration"

Write-Verbose "Getting current network controller credentials"

$VerbosePreference = "SilentlyContinue"
Import-Module NetworkController
$VerbosePreference = "Continue"

$domainNetBIOS = ($SDNConfig.SDNDomainFQDN).Split('.')[0]
$NCCredentials = Get-NetworkControllerCredential -ConnectionUri $uri 

# This is roundabout way of getting the resource reference stored in Network Controller, it is always going to be /credentials/NCHostUser
# in the SDN Sandbox, but in production, you will want to interrogate NC to find the actual value as the ResourceRef can be different
# depending on how NC was installed.

$NCCredential = ($NCCredentials | Where-Object {$_.properties.username -match "$domainNetBIOS\\Administrator"}).ResourceRef
$VerbosePreference = "Continue"

Write-Verbose "Generating JSON File"

$content = "application/json; charset=UTF-8"

$payload = @"
{
      "properties": {
        "connections": [
          {
            "managementAddresses": [
              "$adminCenterIP"
            ],
            "credential": {
              "resourceRef": "$NCCredential"
            },
            "credentialType": "usernamePassword"
          }
        ],
        "zone": "tenantsdn.local"
      }
    }
"@

Write-Verbose "Posting iDNS config to Network Controller"

$params = @{

    Uri         = $dnsUri
    Method      = 'Put'
    Credential  = $domainCred
    Body        = $payload
    ContentType = $content

}

Invoke-RestMethod @params -UseBasicParsing -DisableKeepAlive | Out-Null 

# STEP03: Configure the DNS Proxy registry setting on the Hyper-V Hosts

$SDNHosts = @("SDNHOST1", "SDNHOST2", "SDNHOST3")

foreach ($SDNHost in $SDNHosts) {

    Invoke-Command -ComputerName $SDNHost -ArgumentList $adminCenterIP -ScriptBlock {

        $VerbosePreference = "Continue"

        # Stop the NC Host Agent
        Write-Verbose "Stopping NC Host Agent on $env:ComputerName"
        Stop-Service NcHostAgent -Force


        # Set a lot of registry settings
        $adminCenterIP = $args[0]
        New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NcHostAgent\Parameters\Plugins\Vnet" -Name InfraServices -Force  | Out-Null
        New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NcHostAgent\Parameters\Plugins\Vnet\InfraServices" -Name DnsProxyService -Force  | Out-Null
        $DNSProxyService = "HKLM:\SYSTEM\CurrentControlSet\Services\NcHostAgent\Parameters\Plugins\Vnet\InfraServices\DnsProxyService"
        New-ItemProperty -Name Port -Value 53 -PropertyType DWord -path $DNSProxyService -Force  | Out-Null
        New-ItemProperty -Name ProxyPort -Value 53 -PropertyType DWord -Path $DNSProxyService -Force  | Out-Null
        New-ItemProperty -Name IP -Value "169.254.169.254" -PropertyType String -Path $DNSProxyService -Force  | Out-Null
        New-ItemProperty -Name MAC -Value “aa-bb-cc-aa-bb-cc” -PropertyType String -Path $DNSProxyService -Force | Out-Null


        $DNSProxy = "HKLM:\SYSTEM\CurrentControlSet\Services\DNSProxy\Parameters"
        New-Item -Path $DNSProxy -Force | Out-Null
        New-ItemProperty -Name Forwarders -Value $adminCenterIP -PropertyType String -Path $DNSProxy -Force | Out-Null

        # If we are on 2016 SDN, then we need to add a start value to the DNSProxy Service which has been moved in 2019

        $OSver = Get-WmiObject Win32_OperatingSystem | Where-Object {$_.Name -match "Windows Server 2016"}

        If ($OSver) {

            $DNSProxyRoot = "HKLM:\SYSTEM\CurrentControlSet\Services\DNSProxy"
            Set-ItemProperty -Value 2 -Name Start -Path $DNSProxyRoot -Force

        }


        # Start the Services

        Write-Verbose "Starting NC Host Agent on $env:ComputerName"
        Start-Service NcHostAgent 

        Write-Verbose "Starting Software Load Balancer Host Agent on $env:ComputerName"
        Start-Service SlbHostAgent

        # Start the DNS Proxy Service if we are using Server 2016

        if ($OSver) { 

            Write-Verbose "Starting DNS Host Proxy on $env:ComputerName"
            Start-Service -Name DnsProxy 

        }


    }



}
