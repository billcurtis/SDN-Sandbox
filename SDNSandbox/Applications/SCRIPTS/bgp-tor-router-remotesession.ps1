 [CmdletBinding(DefaultParameterSetName = "NoParameters")]

param(

    [Parameter(Mandatory = $true, ParameterSetName = "ConfigurationFile")]
    [String] $ConfigurationDataFile = 'C:\SCRIPTS\SDNSandbox-Config.psd1'

)

$ErrorActionPreference = "Stop"
$VerbosePreference = "Continue"

$server = "bgp-tor-router"

# Load in the configuration file.
$SDNConfig = Import-PowerShellDataFile $ConfigurationDataFile
if (!$SDNConfig) { Throw "Place Configuration File in the root of the scripts folder or specify the path to the Configuration file." }

# Set Credential Object
$localCred = new-object -typename System.Management.Automation.PSCredential `
    -argumentlist ("administrator"), `
(ConvertTo-SecureString $SDNConfig.SDNAdminPassword -AsPlainText -Force)

# Log into server
Enter-PSSession -ComputerName $server -Credential $localCred
