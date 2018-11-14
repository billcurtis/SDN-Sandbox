﻿<#
.SYNOPSIS 
    Deploys and configures a minimal Microsoft SDN infrastructure in a Hyper-V
    Nested Environment for training purposes. This deployment method is not
    supported for Production purposes.

.EXAMPLE
    .\New-SDNSandbox.ps1
    Reads in the configuration from NestedSDN-Config.psd1 that contains a hash table 
    of settings data that will in same root as New-SDNSandbox.ps1

.EXAMPLE
    .\New-SDNSandbox.ps1 -Delete $true
     Removes the VMs and VHDs of the SDN Sandbox installation. (Note: Some files will
     remain after deletion.)

.NOTES
    Prerequisites:

    * All Hyper-V hosts must have Hyper-V enabled and the Virtual Switch 
    already created with the same name (if using Multiple Hosts). If you are
    using a single host, a Internal VM Switch will be created.

    * 250gb minimum of hard drive space if a single host installation. 150GB 
      minimum of drive space per Hyper-V host if using multiple hosts.

    * 64gb of memory if single host. 32GB of memory per host if using 2 hosts,
      and 16gb of memory if using 4 hosts.

    * If using multiple Hyper-V hosts for the lab, then you will need to either
    use a dumb hub to connect the hosts or a switch with all defined VLANs
    trunked (12 and 200).

    * If you wish the environment to have internet access, create a VMswitch on
      the FIRST host that maps to a NIC on a network that has internet access. 
      The network should use DHCP.

    * 3 VHDX (GEN2) files will need to be specified. 

         1. GUI.VHDX - Sysprepped Desktop Experience version of Windows Server 2016/2019 
           Datacenter. (note: Server 2016 will require KB4103723 or higher updates to be
           applied. SDN is not available yet in the RTM version of 2019, but will be in the 
           future.)

        2. CORE.VHDX - Sysprepped Core version of Windows Server 2016/2019 Datacenter. 
           (note: Server 2016 will require KB4103723 or higher updates to be applied. 
           SDN is not enabled in the RTM version of 2019, but will be in the 
           future.)

        3. CONSOLE.VHDX - Sysprepped version of Windows 10.

    * The following files will be required to be downloaded and the installer packages 
      placed in the root of their respective folders:

        1. RSAT for the version of Windows Server that you are deploying.

        2. Latest version of Windows Admin Center


    * The NestedSDN-Config.psd1 will need to be edited to include product keys for the
      installation media. If using VL Media, use KMS keys for the product key. Additionally,
      please ensure that the NAT settings are filled in to specify the switch allowing 
      internet access.
          
#>


[CmdletBinding(DefaultParameterSetName="NoParameters")]

param(
    [Parameter(Mandatory=$true,ParameterSetName="ConfigurationFile")]
    [String] $ConfigurationDataFile = '.\NestedSDN-Config.psd1',
    [Parameter(Mandatory=$false,ParameterSetName="Delete")]
    [Bool] $Delete = $false
    ) 

#region functions

function Get-HyperVHosts {

    param (

        [String[]]$MultipleHyperVHosts,
        [string]$HostVMPath
    )
    
    foreach ($HypervHost in $MultipleHyperVHosts) {

        # Check Network Connectivity
        Write-Verbose "Checking Network Connectivity for Host $HypervHost"
        $testconnection = Test-Connection -ComputerName $HypervHost -Quiet -Count 1
        if (!$testconnection) {Write-Error "Failed to ping $HypervHost"; break}
    
        # Check Hyper-V Host 
        $HypHost = Get-VMHost -ComputerName $HypervHost -ErrorAction Ignore
        if ($HypHost) {Write-Verbose "$HypervHost Hyper-V Connectivity verified"}
        if (!$HypHost) {Write-Error "Cannot connect to hypervisor on system $HypervHost"; break}
    
        # Check HostVMPath
        $DriveLetter = $HostVMPath.Split(':')
        $testpath = Test-Path (("\\$HypervHost\") + ($DriveLetter[0] + "$") + ($DriveLetter[1])) -ErrorAction Ignore
        if ($testpath) {Write-Verbose "$HypervHost's $HostVMPath path verified"}
        if (!$testpath) {Write-Error "Cannot connect to $HostVMPath on system $HypervHost"; break}

    }
    
} 
    
function Set-HyperVSettings {
    
    param (

        $MultipleHyperVHosts,
        $HostVMPath
    )
    
    foreach ($HypervHost in $MultipleHyperVHosts) {

        Write-Verbose "Configuring Hyper-V Settings on $HypervHost"

        $params = @{
        
            ComputerName              = $HypervHost
            VirtualHardDiskPath       = $HostVMPath
            VirtualMachinePath        = $HostVMPath
            EnableEnhancedSessionMode = $true

        }

        Set-VMhost @params
    
    }
    
}
    
function Set-LocalHyperVSettings {

    Param (

        [string]$HostVMPath
    )
    
    Write-Verbose "Configuring Hyper-V Settings on localhost"

    $params = @{

        VirtualHardDiskPath       = $HostVMPath
        VirtualMachinePath        = $HostVMPath
        EnableEnhancedSessionMode = $true

    }

    Set-VMhost @params  
}
    
function New-InternalSwitch {
    
    Param (

        $pswitchname, 
        $SDNConfig
    )
    
    $querySwitch = Get-VMSwitch -Name $pswitchname -ErrorAction Ignore
    
    if (!$querySwitch) {
    
        New-VMSwitch -SwitchType Internal -Name $pswitchname | Out-Null
    
        #Assign IP to Internal Switch
        $InternalAdapter = Get-Netadapter -Name "vEthernet ($pswitchname)"
        $IP = $SDNConfig.PhysicalHostInternalIP
        $Prefix = ($SDNConfig.SDNMGMTIP.Split("/"))[1]
        $Gateway = $SDNConfig.SDNLABRoute
        $DNS = $SDNConfig.SDNLABDNS
        
        $params = @{

            AddressFamily  = "IPv4"
            IPAddress      = $IP
            PrefixLength   = $Prefix
            DefaultGateway = $Gateway
            
        }
    
        $InternalAdapter | New-NetIPAddress @params | Out-Null
        $InternalAdapter | Set-DnsClientServerAddress -ServerAddresses $DNS | Out-Null
    
    }
    
    Else {Write-Verbose "Internal Switch $pswitchname already exists. Not creating a new internal switch."}
    
}
    
function New-HostvNIC {
    
    param (

        $SDNConfig
    )
    
    $vnicName = $SDNConfig.MultipleHyperVHostExternalSwitchName + "-Access"
    
    $isNIC = Get-VMNetworkAdapter -ManagementOS | Where-Object {$_.Name -match $vnicName}
    
    if (!$isNIC) {

        $params = @{

            SwitchName = $SDNConfig.MultipleHyperVHostExternalSwitchName
            Name       = $vnicName
        }
    
        Add-VMNetworkAdapter -ManagementOS @params | Out-Null
    
        $IP = ($SDNConfig.MGMTSubnet.TrimEnd("0/24")) + 10
        $prefix = $SDNConfig.MGMTSubnet.Split("/")[1]
        $gateway = $SDNConfig.BGPRouterIP_MGMT.TrimEnd("/24")
        $DNS = $SDNConfig.SDNLABDNS

        $NetAdapter = Get-NetAdapter | Where-Object {$_.Name -match $vnicName}[0]

        $params = @{

            AddressFamily  = "IPv4"
            IPAddress      = $IP
            PrefixLength   = $Prefix
            DefaultGateway = $Gateway
            
        }

        $NetAdapter | New-NetIPAddress @params | Out-Null
        $NetAdapter | Set-DnsClientServerAddress -ServerAddresses $DNS | Out-Null
    
    }
    
}
    
function Test-VHDPath {

    Param (

        $guiVHDXPath,
        $coreVHDXPath,
        $consoleVHDXPath
    )

    $Result = Get-ChildItem -Path $guiVHDXPath -ErrorAction Ignore  
    if (!$result) {Write-Host "Path $guiVHDXPath was not found!" -ForegroundColor Red ; break}
    $Result = Get-ChildItem -Path $coreVHDXPath -ErrorAction Ignore  
    if (!$result) {Write-Host "Path $coreVHDXPath was not found!" -ForegroundColor Red ; break}
    $Result = Get-ChildItem -Path $consoleVHDXPath -ErrorAction Ignore  
    if (!$result) {Write-Host "Path $consoleVHDXPath was not found!" -ForegroundColor Red ; break}

}
    
function Select-VMHostPlacement {
    
    Param($MultipleHyperVHosts, $SDNHosts)    
    
    $results = @()
    
    Write-Host "Note: if using a NAT switch for internet access, please choose the host that has the external NAT Switch for VM: SDNMGMT." `
        -ForegroundColor Yellow
    
    foreach ($SDNHost in $SDNHosts) {
    
        Write-Host "`nOn which server should I put $SDNHost ?" -ForegroundColor Green
    
        $i = 0
        foreach ($HypervHost in $MultipleHyperVHosts) {
    
            Write-Host "`n $i. Hyper-V Host: $HypervHost" -ForegroundColor Yellow
            $i++
        }
    
        $MenuOption = Read-Host "`nSelect the Hyper-V Host and then press Enter" 
    
        $results = $results + [pscustomobject]@{SDNHOST = $SDNHost; VMHost = $MultipleHyperVHosts[$MenuOption]}
    
    }
    
    return $results
     
}
    
function Select-SingleHost {

    Param (

        $SDNHosts

    )

    $results = @()
    foreach ($SDNHost in $SDNHosts) {

        $results = $results + [pscustomobject]@{SDNHOST = $SDNHost; VMHost = $env:COMPUTERNAME}
    }

    Return $results

}
    
function Copy-VHDXtoHosts {

    Param (

        $MultipleHyperVHosts, 
        $guiVHDXPath, 
        $coreVHDXPath, 
        $HostVMPath, 
        $consoleVHDXPath

    )
        
    foreach ($HypervHost in $MultipleHyperVHosts) { 

        $DriveLetter = $HostVMPath.Split(':')
        $path = (("\\$HypervHost\") + ($DriveLetter[0] + "$") + ($DriveLetter[1]))
        Write-Verbose "Copying $guiVHDXPath to $path"
        Copy-Item -Path $guiVHDXPath -Destination "$path\GUI.vhdx" -Force | Out-Null
        Write-Verbose "Copying $coreVHDXPath to $path"
        Copy-Item -Path $coreVHDXPath -Destination "$path\Core.vhdx" -Force | Out-Null
        Write-Verbose "Copying $consoleVHDXPath to $path"
        Copy-Item -Path $consoleVHDXPath -Destination "$path\Console.vhdx" -Force | Out-Null

    }
}
    
function Copy-VHDXtoHost {

    Param (

        $guiVHDXPath, 
        $HostVMPath, 
        $coreVHDXPath, 
        $consoleVHDXPath

    )

    Write-Verbose "Copying $guiVHDXPath to $HostVMPath GUI.VHDX"
    Copy-Item -Path $guiVHDXPath -Destination "$HostVMPath\GUI.VHDX" -Force | Out-Null
    Write-Verbose "Copying $coreVHDXPath to $HostVMPath\Core.VHDX"
    Copy-Item -Path $coreVHDXPath -Destination "$HostVMPath\Core.VHDX" -Force | Out-Null
    Write-Verbose "Copying $consoleVHDXPath to $HostVMPath\Console.VHDX"
    Copy-Item -Path $consoleVHDXPath -Destination "$HostVMPath\Console.VHDX" -Force | Out-Null    
    
}
    
function Get-guiVHDXPath {
    
    Param (

        $guiVHDXPath, 
        $HostVMPath

    )

    $ParentVHDXPath = $HostVMPath + 'GUI.vhdx'
    return $ParentVHDXPath

}
    
function Get-CoreVHDXPath {

    Param (

        $coreVHDXPath, 
        $HostVMPath

    )

    $ParentVHDXPath = $HostVMPath + 'Core.vhdx'
    return $ParentVHDXPath

}
    
function Get-ConsoleVHDXPath {

    Param (

        $ConsoleVHDXPath, 
        $HostVMPath

    )

    $ParentVHDXPath = $HostVMPath + 'Console.vhdx'
    return $ParentVHDXPath

}

function New-NestedVM {

    Param (

        $SDNHost, 
        $VMHost, 
        $HostVMPath, 
        $VMSwitch,
        $SDNConfig

    )
    
   
    $parentpath = "$HostVMPath\GUI.vhdx"
    $coreparentpath = "$HostVMPath\Core.vhdx"

    Invoke-Command -ComputerName $VMHost -ScriptBlock {    

        $VerbosePreference = "SilentlyContinue"

        Import-Module Hyper-V

        $VerbosePreference = "Continue"

        $SDNHost = $using:SDNHost
        $VMHost = $using:VMHost        
        $HostVMPath = $using:HostVMPath
        $VMSwitch = $using:VMSwitch
        $parentpath = $using:parentpath
        $coreparentpath = $using:coreparentpath
        $SDNConfig = $using:SDNConfig                         
        $S2DDiskSize = $SDNConfig.S2D_Disk_Size
        $NestedVMMemoryinGB = $SDNConfig.NestedVMMemoryinGB
        $SDNMGMTMemoryinGB = $SDNConfig.SDNMGMTMemoryinGB
    
        # Create Differencing Disk. Note: SDNMGMT is GUI in case of no access to Console VM from host.

        if ($SDNHost -eq "SDNMGMT") {

            $VHDX1 = New-VHD -ParentPath $parentpath -Path "$HostVMPath\$SDNHost.vhdx" -Differencing 
            $VHDX2 = New-VHD -Path "$HostVMPath\$SDNHost-Data.vhdx" -SizeBytes 268435456000 -Dynamic
            $NestedVMMemoryinGB = $SDNMGMTMemoryinGB
        }
    
        Else { 
           
            $VHDX1 = New-VHD -ParentPath $coreparentpath -Path "$HostVMPath\$SDNHost.vhdx" -Differencing 
            $VHDX2 = New-VHD -Path "$HostVMPath\$SDNHost-Data.vhdx" -SizeBytes 268435456000 -Dynamic
    
            # Create S2D Storage       

            New-VHD -Path "$HostVMPath\$SDNHost-S2D_Disk1.vhdx" -SizeBytes $S2DDiskSize -Dynamic | Out-Null
            New-VHD -Path "$HostVMPath\$SDNHost-S2D_Disk2.vhdx" -SizeBytes $S2DDiskSize -Dynamic | Out-Null
            New-VHD -Path "$HostVMPath\$SDNHost-S2D_Disk3.vhdx" -SizeBytes $S2DDiskSize -Dynamic | Out-Null
            New-VHD -Path "$HostVMPath\$SDNHost-S2D_Disk4.vhdx" -SizeBytes $S2DDiskSize -Dynamic | Out-Null   
    
        }    
    
        #Create Nested VM

        $params = @{

            Name               = $SDNHost
            MemoryStartupBytes = $NestedVMMemoryinGB 
            VHDPath            = $VHDX1.Path 
            SwitchName         = $VMSwitch
            Generation         = 2

        }

        New-VM @params | Out-Null
        Add-VMHardDiskDrive -VMName $SDNHost -Path $VHDX2.Path
    
        if ($SDNHost -ne "SDNMGMT") {

            Add-VMHardDiskDrive -Path "$HostVMPath\$SDNHost-S2D_Disk1.vhdx" -VMName $SDNHost | Out-Null
            Add-VMHardDiskDrive -Path "$HostVMPath\$SDNHost-S2D_Disk2.vhdx" -VMName $SDNHost | Out-Null
            Add-VMHardDiskDrive -Path "$HostVMPath\$SDNHost-S2D_Disk3.vhdx" -VMName $SDNHost | Out-Null
            Add-VMHardDiskDrive -Path "$HostVMPath\$SDNHost-S2D_Disk4.vhdx" -VMName $SDNHost | Out-Null

        }
    
        Set-VM -Name $SDNHost -ProcessorCount 4 -AutomaticStartAction Start
        Get-VMNetworkAdapter -VMName $SDNHost| Rename-VMNetworkAdapter -NewName "SDN"
        Add-VMNetworkAdapter -VMName $SDNHost
        Get-VMNetworkAdapter -VMName $SDNHost | Where-Object {$_.Name -match "Network"} | Connect-VMNetworkAdapter -SwitchName $VMSwitch
        Get-VMNetworkAdapter -VMName $SDNHost | Where-Object {$_.Name -match "Network"} | Rename-VMNetworkAdapter -NewName "SDN2"
        Get-VM $SDNHost| Set-VMProcessor -ExposeVirtualizationExtensions $true
        Get-VM $SDNHost | Set-VMMemory -DynamicMemoryEnabled $false
        Get-VM $SDNHost| Get-VMNetworkAdapter  | Set-VMNetworkAdapter -MacAddressSpoofing On
        Set-VMNetworkAdapterVlan -VMName $SDNHost -VMNetworkAdapterName SDN -Trunk -NativeVlanId 0 -AllowedVlanIdList 1-200
        Set-VMNetworkAdapterVlan -VMName $SDNHost -VMNetworkAdapterName SDN2 -Trunk -NativeVlanId 0 -AllowedVlanIdList 1-200
        Enable-VMIntegrationService -VMName $SDNHost -Name "Guest Service Interface"

    }          

}
    
function Add-Files {
    
    Param(
        $VMPlacement, 
        $HostVMPath, 
        $SDNConfig
    )
    
    $corevhdx = 'Core.vhdx'
    $guivhdx = 'GUI.vhdx'
    $consolevhdx = 'Console.vhdx'  
    
    foreach ($SDNHost in $VMPlacement) {
    
        # Get Drive Paths 

        $HypervHost = $SDNHost.VMHost
        $DriveLetter = $HostVMPath.Split(':')
        $path = (("\\$HypervHost\") + ($DriveLetter[0] + "$") + ($DriveLetter[1]) + "\" + $SDNHost.SDNHOST + ".vhdx")
    
        # Mount VHDX

        Write-Verbose "Mounting VHDX file at $path"
        [string]$MountedDrive = (Mount-VHD -Path $path -Passthru | Get-Disk | Get-Partition | Get-Volume).DriveLetter
        $MountedDrive = $MountedDrive.Replace(" ", "")
   
        # Inject Answer File

        Write-Verbose "Injecting answer file to $path"
    
        $SDNHostComputerName = $SDNHost.SDNHOST
        $SDNHostIP = $SDNConfig.($SDNHostComputerName + "IP")
        $SDNAdminPassword = $SDNConfig.SDNAdminPassword
        $SDNDomainFQDN = $SDNConfig.SDNDomainFQDN
        $SDNLABDNS = $SDNConfig.SDNLABDNS
        $SDNLabRoute = $SDNConfig.SDNLABRoute
    
        if ($SDNHostComputerName -eq "SDNMGMT") {$ProductKey = $SDNConfig.GUIProductKey}
        else {$ProductKey = $SDNConfig.COREProductKey}    
 
        $UnattendXML = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
<settings pass="specialize">
<component name="Networking-MPSSVC-Svc" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<DomainProfile_EnableFirewall>false</DomainProfile_EnableFirewall>
<PrivateProfile_EnableFirewall>false</PrivateProfile_EnableFirewall>
<PublicProfile_EnableFirewall>false</PublicProfile_EnableFirewall>
</component>
<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<ComputerName>$SDNHostComputerName</ComputerName>
<ProductKey>$ProductKey</ProductKey>
</component>
<component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<fDenyTSConnections>false</fDenyTSConnections>
</component>
<component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<UserLocale>en-us</UserLocale>
<UILanguage>en-us</UILanguage>
<SystemLocale>en-us</SystemLocale>
<InputLocale>en-us</InputLocale>
</component>
<component name="Microsoft-Windows-IE-ESC" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<IEHardenAdmin>false</IEHardenAdmin>
<IEHardenUser>false</IEHardenUser>
</component>
<component name="Microsoft-Windows-TCPIP" processorArchitecture="wow64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<Interfaces>
<Interface wcm:action="add">
<Identifier>Ethernet</Identifier>
<Ipv4Settings>
<DhcpEnabled>false</DhcpEnabled>
</Ipv4Settings>
<UnicastIpAddresses>
<IpAddress wcm:action="add" wcm:keyValue="1">$SDNHostIP</IpAddress>
</UnicastIpAddresses>
<Routes>
<Route wcm:action="add">
<Identifier>1</Identifier>
<NextHopAddress>$SDNLabRoute</NextHopAddress>
<Prefix>0.0.0.0/0</Prefix>
<Metric>20</Metric>
</Route>
</Routes>
</Interface>
</Interfaces>
</component>
<component name="Microsoft-Windows-DNS-Client" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<DNSSuffixSearchOrder>
<DomainName wcm:action="add" wcm:keyValue="1">$SDNDomainFQDN</DomainName>
</DNSSuffixSearchOrder>
<Interfaces>
<Interface wcm:action="add">
<DNSServerSearchOrder>
<IpAddress wcm:action="add" wcm:keyValue="1">$SDNLABDNS</IpAddress>
</DNSServerSearchOrder>
<Identifier>Ethernet</Identifier>
<DisableDynamicUpdate>false</DisableDynamicUpdate>
<DNSDomain>$SDNDomainFQDN</DNSDomain>
<EnableAdapterDomainNameRegistration>true</EnableAdapterDomainNameRegistration>
</Interface>
</Interfaces>
</component>
</settings>
<settings pass="oobeSystem">
<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<OOBE>
<HideEULAPage>true</HideEULAPage>
<SkipMachineOOBE>true</SkipMachineOOBE>
<SkipUserOOBE>true</SkipUserOOBE>
<HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
 </OOBE>
<UserAccounts>
<AdministratorPassword>
<Value>$SDNAdminPassword</Value>
<PlainText>true</PlainText>
</AdministratorPassword>
</UserAccounts>
</component>
</settings>
<cpi:offlineImage cpi:source="" xmlns:cpi="urn:schemas-microsoft-com:cpi" />
</unattend>
"@
 
        Write-Verbose "Mounted Disk Volume is: $MountedDrive" 
        $PantherDir = Get-ChildItem -Path ($MountedDrive + ":\Windows")  -Filter "Panther"
        if (!$PantherDir) {New-Item -Path ($MountedDrive + ":\Windows\Panther") -ItemType Directory -Force | Out-Null}
    
        Set-Content -Value $UnattendXML -Path ($MountedDrive + ":\Windows\Panther\Unattend.xml") -Force
    
        # Inject VMConfigs and create folder structure if host is SDNMGMT

        if ($SDNHost.SDNHOST -eq "SDNMGMT") {

            Write-Verbose "Injecting VMConfigs to $path"
            Copy-Item -Path .\NestedSDN-Config.psd1 -Destination ($MountedDrive + ":\") -Recurse -Force
            New-Item -Path ($MountedDrive + ":\") -Name VMConfigs -ItemType Directory -Force | Out-Null
            Copy-Item -Path .\VHDX\*.* -Destination ($MountedDrive + ":\VmConfigs") -Recurse -Force
            Copy-Item -Path .\Applications\SCRIPTS -Destination ($MountedDrive + ":\VmConfigs") -Recurse -Force
            Copy-Item -Path '.\Applications\Windows Admin Center' -Destination ($MountedDrive + ":\VmConfigs") -Recurse -Force
            Copy-Item -Path .\Applications\RSAT -Destination ($MountedDrive + ":\VmConfigs") -Recurse -Force    
    
            # Creating folder structure on SDNMGMT

            Write-Verbose "Creating VMs\Base folder structure on SDNMGMT"
            New-Item -Path ($MountedDrive + ":\VMs\Base") -ItemType Directory -Force | Out-Null
    
            # Move vhdx file to correct folder

            Write-Verbose "Creating VMConfigs folder structure on SDNMGMT"
            Move-Item -Path ($MountedDrive + ":\VMConfigs\$guivhdx") -Destination ($MountedDrive + ":\VMs\Base\") -Force
            Move-Item -Path ($MountedDrive + ":\VMConfigs\$corevhdx") -Destination ($MountedDrive + ":\VMs\Base\") -Force
            Move-Item -Path ($MountedDrive + ":\VMConfigs\$consolevhdx") -Destination ($MountedDrive + ":\VMs\Base\") -Force

        }
    
        # Dismount VHDX

        Write-Verbose "Dismounting VHDX File at path $path"
        Dismount-VHD $path
                                       
    }    
}
    
function Start-SDNHOSTS {

    Param(

        $VMPlacement

    )
    
    foreach ($VMHost in $VMPlacement) {

        Write-Verbose "Starting VM: $VMHost"
        Start-VM -ComputerName $VMHost.VMhost -Name $VMHost.SDNHost

    }    
} 
    
function New-DataDrive {

    param (

        $VMPlacement, 
        $SDNConfig,
        $localCred
        
    )

    foreach ($SDNVM in $VMPlacement) {

        Invoke-Command -ComputerName $SDNVM.VMHost -Credential $localCred -ScriptBlock {

            $VerbosePreference = "Continue"
            Write-Verbose "Onlining, partitioning, and formatting Data Drive on $($Using:SDNVM.SDNHOST)"

            $localCred = new-object -typename System.Management.Automation.PSCredential -argumentlist "Administrator" `
                , (ConvertTo-SecureString $using:SDNConfig.SDNAdminPassword   -AsPlainText -Force)   

            Invoke-Command -VMName $using:SDNVM.SDNHost -Credential $localCred -ScriptBlock {

                Set-Disk -Number 1 -IsOffline $false | Out-Null
                Initialize-Disk -Number 1 | Out-Null
                New-Partition -DiskNumber 1 -UseMaximumSize -AssignDriveLetter | Out-Null
                Format-Volume -DriveLetter D | Out-Null

            }                      
        }
    }    
}
    
function Test-SDNHostVMConnection {

    param (

        $VMPlacement, 
        $localCred

    )

    foreach ($SDNVM in $VMPlacement) {

        Invoke-Command -ComputerName $SDNVM.VMHost  -ScriptBlock {
            
            $VerbosePreference = "Continue"    
            
            $localCred = $using:localCred   
            $testconnection = $null
    
            While (!$testconnection) {
    
                $testconnection = Invoke-Command -VMName $using:SDNVM.SDNHOST -ScriptBlock {Get-Process} -Credential $localCred -ErrorAction Ignore
    
            }
        
            Write-Verbose "Successfully contacted $($using:SDNVM.SDNHOST)"
                         
        }
    }    
}

function Start-PowerShellScriptsOnHosts {

    Param (

        $VMPlacement, 
        $ScriptPath, 
        $localCred

    ) 
    
    foreach ($SDNVM in $VMPlacement) {

        Invoke-Command -ComputerName $SDNVM.VMHost  -ScriptBlock {
            
            $VerbosePreference = "Continue"    
            Write-Verbose "Executing Script: $($using:ScriptPath) on host $($using:SDNVM.SDNHOST)"     
            Invoke-Command -VMName $using:SDNVM.SDNHOST -ArgumentList $using:Scriptpath -ScriptBlock { Invoke-Expression -Command $args[0] } -Credential $using:localCred 
            
        }
    }
}
    
function New-NATSwitch {
    
    Param (

        $VMPlacement,
        $SwitchName,
        $SDNConfig

    )
    
    $natSwitchTarget = $VMPlacement | Where-Object {$_.SDNHOST -eq "SDNMGMT"}
    
    Add-VMNetworkAdapter -VMName $natSwitchTarget.SDNHOST -ComputerName $natSwitchTarget.VMHost

    $params = @{

        VMName       = $natSwitchTarget.SDNHOST
        ComputerName = $natSwitchTarget.VMHost
    }

    Get-VMNetworkAdapter @params | Where-Object {$_.Name -match "Network"} | Connect-VMNetworkAdapter -SwitchName $SDNConfig.natExternalVMSwitchName
    Get-VMNetworkAdapter @params | Where-Object {$_.Name -match "Network"} | Rename-VMNetworkAdapter -NewName "NAT"
    
    Get-VM @params | Get-VMNetworkAdapter -Name NAT | Set-VMNetworkAdapter -MacAddressSpoofing On
    
    if ($SDNConfig.natVLANID) {
    
        Get-VM @params | Get-VMNetworkAdapter -Name NAT | Set-VMNetworkAdapterVlan -Access -VlanId $natVLANID | Out-Null
    
    }
    
    #Create PROVIDER NIC in order for NAT to work from SLB/MUX and RAS Gateways

    Add-VMNetworkAdapter @params -Name PROVIDER -DeviceNaming On -SwitchName $SwitchName
    Get-VM @params | Get-VMNetworkAdapter -Name PROVIDER | Set-VMNetworkAdapter -MacAddressSpoofing On
    Get-VM @params | Get-VMNetworkAdapter -Name PROVIDER | Set-VMNetworkAdapterVlan -Access -VlanId $SDNConfig.providerVLAN | Out-Null    
    
    #Create VLAN 200 NIC in order for NAT to work from L3 Connections

    Add-VMNetworkAdapter @params -Name VLAN200 -DeviceNaming On -SwitchName $SwitchName
    Get-VM @params | Get-VMNetworkAdapter -Name VLAN200 | Set-VMNetworkAdapter -MacAddressSpoofing On
    Get-VM @params | Get-VMNetworkAdapter -Name VLAN200 | Set-VMNetworkAdapterVlan -Access -VlanId $SDNConfig.vlan200VLAN | Out-Null    
    
}  
    
function Resolve-Applications {

    Param (

        $SDNConfig
    )
    
    # Verify Product Keys

    Write-Verbose "Performing simple validation of Product Keys"
    $guiResult = $SDNConfig.GUIProductKey -match '^([A-Z0-9]{5}-){4}[A-Z0-9]{5}$'
    $coreResult = $SDNConfig.COREProductKey -match '^([A-Z0-9]{5}-){4}[A-Z0-9]{5}$'
    
    if (!$guiResult) {Write-Error "Cannot validate or find the product key for the Windows Server Datacenter Desktop Experience."}
    if (!$coreResult) {Write-Error "Cannot validate or find the product key for the Windows Server Datacenter Core."}
    
    # Verify RSAT

    Write-Verbose "Verifying RSAT"
    $isRSAT = Get-ChildItem -Path .\Applications\RSAT  -Filter *.MSU
    if (!$isRSAT) {Write-Error "Please check and ensure that you have correctly copied the file to \Applications\RSAT."}
    
}
        
function Get-PhysicalNICMTU {
    
    Param (
        
        $SDNConfig
    
    )
    
    foreach ($VMHost in $SDNConfig.MultipleHyperVHostNames) {
    
        Invoke-Command -ComputerName $VMHost  -ScriptBlock {
    
            $SDNConfig = $using:SDNConfig
    
            $VswitchNICs = (Get-VMSwitch -Name ($SDNConfig.MultipleHyperVHostExternalSwitchName)).NetAdapterInterfaceDescription
    
            if ($VswitchNICs) {
                foreach ($VswitchNIC in $VswitchNICs) {
    
                    $MTUSetting = (Get-NetAdapterAdvancedProperty -InterfaceDescription $VswitchNIC -RegistryKeyword '*JumboPacket').RegistryValue

                    if ($MTUSetting -ne $SDNConfig.SDNLABMTU) {
    
                        Write-Error "There is a mismatch in the MTU value for the external switch and the value in the NestedSDN-Config.psd1 data file."  
    
                    }
    
                }
    
            }
    
            else {
    
                Write-Error "The external switch was not found on $Env:COMPUTERNAME"
    
            }
    
        }    
    
    }
    
}

function Set-SDNserver {

    Param (

        $VMPlacement, 
        $SDNConfig, 
        $localCred 

    )

    foreach ($SDNVM in $VMPlacement) {

        Invoke-Command -VMName $SDNVM.SDNHOST -ScriptBlock {

            $SDNConfig = $using:SDNConfig
            $localCred = $using:localCred
            $VerbosePreference = "Continue"

            # Enable WinRM

            Write-Verbose "Enabling Windows Remoting"
            $VerbosePreference = "SilentlyContinue" 
            Set-Item WSMan:\localhost\Client\TrustedHosts *  -Confirm:$false -Force
            Enable-PSRemoting | Out-Null
            $VerbosePreference = "Continue" 

            Start-Sleep -Seconds 60

            Write-Verbose "Installing and Configuring Hyper-V on $env:COMPUTERNAME"
            $VerbosePreference = "SilentlyContinue"
            Install-WindowsFeature -Name Hyper-V -IncludeAllSubFeature -IncludeManagementTools -ComputerName $env:COMPUTERNAME  | Out-Null
            $VerbosePreference = "Continue"

            if ($env:COMPUTERNAME -ne "SDNMGMT") {

                Write-Verbose "Installing and Configuring Failover Clustering on $env:COMPUTERNAME"
                $VerbosePreference = "SilentlyContinue"
                Install-WindowsFeature -Name Failover-Clustering -IncludeAllSubFeature -IncludeManagementTools -ComputerName $env:COMPUTERNAME | Out-Null 

            }

            # Enable CredSSP and MTU Settings

            Invoke-Command -ComputerName localhost -Credential $using:localCred -ScriptBlock {

                $fqdn = $Using:SDNConfig.SDNDomainFQDN

                Write-Verbose "Enabling CredSSP on $env:COMPUTERNAME"
                Enable-WSManCredSSP -Role Server -Force
                Enable-WSManCredSSP -Role Client -DelegateComputer localhost -Force
                Enable-WSManCredSSP -Role Client -DelegateComputer $env:COMPUTERNAME -Force
                Enable-WSManCredSSP -Role Client -DelegateComputer $fqdn -Force
                Enable-WSManCredSSP -Role Client -DelegateComputer "*.$fqdn" -Force
                New-Item -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation `
                    -Name AllowFreshCredentialsWhenNTLMOnly -Force
                New-ItemProperty -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation\AllowFreshCredentialsWhenNTLMOnly `
                    -Name 1 -Value * -PropertyType String -Force 
            } -InDisconnectedSession | Out-Null
 
        } -Credential $localCred

    }

}

function Set-SDNMGMT {

    param (

        $SDNConfig,
        $localCred,
        $domainCred

    )

    Invoke-Command -ComputerName SDNMGMT -Credential $localCred -ScriptBlock {

        # Creds

        $localCred = $using:localCred
        $domainCred = $using:domainCred
        $SDNConfig = $using:SDNConfig

        # Set variables

        $ParentDiskPath = "C:\VMs\Base\"
        $vmpath = "D:\VMs\"
        $OSVHDX = "GUI.vhdx"
        $coreOSVHDX = "Core.vhdx"
        $consoleOSVHDX = "Console.vhdx" 
        $VMStoragePathforOtherHosts = $SDNConfig.HostVMPath
        $SourcePath = 'C:\VMConfigs'
        $Assetspath = "$SourcePath\Assets"

        $ErrorActionPreference = "Stop"
        $VerbosePreference = "Continue"
        $WarningPreference = "SilentlyContinue"

        # Disable Fabric2 Network Adapter
        $VerbosePreference = "SilentlyContinue"
        Get-Netadapter FABRIC2 | Disable-NetAdapter -Confirm:$false | Out-Null

        # Enable WinRM on SDNMGMT
        $VerbosePreference = "Continue"
        Write-Verbose "Enabling PSRemoting on $env:COMPUTERNAME"
        $VerbosePreference = "SilentlyContinue"
        Set-Item WSMan:\localhost\Client\TrustedHosts *  -Confirm:$false -Force
        Enable-PSRemoting | Out-Null
        

        #Disable ServerManager Auto-Start

        Get-ScheduledTask -TaskName ServerManager | Disable-ScheduledTask | Out-Null

        # Create Hyper-V Networking for SDNMGMT

        Import-Module Hyper-V 

        Try {

            $VerbosePreference = "Continue"
            Write-Verbose "Creating VM Switch on $env:COMPUTERNAME"

            New-VMSwitch -ComputerName localhost -AllowManagementOS $true -Name "vSwitch-Fabric" `
                -NetAdapterName FABRIC | Out-Null

            # Configure NAT on SDNMGMT

            if ($SDNConfig.natConfigure) {

                Write-Verbose "Configuring NAT on $env:COMPUTERNAME"

                $VerbosePreference = "SilentlyContinue"

                $natSubnet = $SDNConfig.natSubnet
                $Subnet = ($natSubnet.Split("/"))[0]
                $Prefix = ($natSubnet.Split("/"))[1]
                $natEnd = $Subnet.Split(".")
                $natIP = ($natSubnet.TrimEnd("0./$Prefix")) + (".1")
                $provIP = $SDNConfig.BGPRouterIP_ProviderNetwork.TrimEnd("1/24") + "254"
                $vlan200IP = $SDNConfig.BGPRouterIP_VLAN200.TrimEnd("1/24") + "250"
                $provGW = $SDNConfig.BGPRouterIP_ProviderNetwork.TrimEnd("/24")
                $vlanGW = $SDNConfig.BGPRouterIP_VLAN200.TrimEnd("/24")
                $provpfx = $SDNConfig.BGPRouterIP_ProviderNetwork.Split("/")[1]
                $vlanpfx = $SDNConfig.BGPRouterIP_VLAN200.Split("/")[1]

                New-VMSwitch -SwitchName NAT -SwitchType Internal | Out-Null
                New-NetIPAddress -IPAddress $natIP -PrefixLength $Prefix -InterfaceAlias "vEthernet (NAT)" | Out-Null
                New-NetNat -Name NATNet -InternalIPInterfaceAddressPrefix $natSubnet | Out-Null

                $VerbosePreference = "Continue"
                Write-Verbose "Configuring Provider NIC on $env:COMPUTERNAME"
                $VerbosePreference = "SilentlyContinue"

                $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object {$_.RegistryValue -eq "PROVIDER"}
                Rename-NetAdapter -name $NIC.name -newname "PROVIDER" | Out-Null
                New-NetIPAddress -InterfaceAlias "PROVIDER" –IPAddress $provIP -PrefixLength $provpfx| Out-Null

                $index = (Get-WmiObject Win32_NetworkAdapter | Where-Object {$_.netconnectionid -eq "PROVIDER"}).InterfaceIndex
                $NetInterface = Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object {$_.InterfaceIndex -eq $index}     
                $NetInterface.SetGateways($tranpfx) | Out-Null

                $VerbosePreference = "Continue"
                Write-Verbose "Configuring VLAN200 NIC on $env:COMPUTERNAME"
                $VerbosePreference = "SilentlyContinue"

                $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object {$_.RegistryValue -eq "VLAN200"}
                Rename-NetAdapter -name $NIC.name -newname "VLAN200" | Out-Null
                New-NetIPAddress -InterfaceAlias "VLAN200" –IPAddress $vlan200IP -PrefixLength $vlanpfx | Out-Null

                $index = (Get-WmiObject Win32_NetworkAdapter | Where-Object {$_.netconnectionid -eq "VLAN200"}).InterfaceIndex
                $NetInterface = Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object {$_.InterfaceIndex -eq $index}     
                $NetInterface.SetGateways($vlanGW) | Out-Null

                #Enable Large MTU

                $VerbosePreference = "Continue"
                Write-Verbose "Configuring MTU on all Adapters"
                $VerbosePreference = "SilentlyContinue"
                Get-NetAdapter | ? {$_.Status -eq "Up"} | Set-NetAdapterAdvancedProperty `
                    -RegistryValue $SDNConfig.SDNLABMTU -RegistryKeyword "*JumboPacket"
                $VerbosePreference = "Continue"

                Start-Sleep -Seconds 30

                #Provision Public and Private VIP Route
 
                New-NetRoute -DestinationPrefix $SDNConfig.PublicVIPSubnet -NextHop $provGW -InterfaceAlias PROVIDER | Out-Null

            }

        }

        Catch {

            throw $_

        }

    }

    # Provision DC

    Write-Host "Provisioning Domain Controller in Managment VM"

    # Provision BGP TOR Router

    New-RouterVM -SDNConfig $SDNConfig -localCred $localCred -domainCred $domainCred  | Out-Null

    # Provision Domain Controller 
    Write-Verbose "Provisioning Domain Controller VM"
    New-DCVM -SDNConfig $SDNConfig -localCred $localCred -domainCred $domainCred | Out-Null

    # Join SDNHOSTs to Domain 

    Invoke-Command -VMName SDNMGMT -Credential $localCred -ScriptBlock {

        $SDNConfig = $using:SDNConfig
        $VerbosePreference = "Continue"

        function AddSDNHostToDomain {

            Param (

                $IP,
                $localCred, 
                $domainCred, 
                $SDNHostName, 
                $SDNConfig

            )

            Write-Verbose "Joining host $SDNHostName ($ip) to domain"

            Try {

                $SDNHostTest = Test-Connection $IP -Quiet

                While (!$SDNHostTest) {
                    Write-Host "Unable to contact computer $SDNHostname at $IP. Please make sure the system is contactable before continuing and the Press Enter to continue." `
                        -ForegroundColor Red
                    pause
                    $SDNHostTest = Test-Connection $SDNHostName -Quiet -Count 1                      
                }

                While ($DomainJoined -ne $SDNConfig.SDNDomainFQDN) {

                    $params = @{

                        ComputerName = $IP
                        Credential   = $localCred
                        ArgumentList = ($domainCred, $SDNConfig.SDNDomainFQDN)
                    }


                    $job = Invoke-Command @params -ScriptBlock {add-computer -DomainName $args[1] -Credential $args[0]} -AsJob 

                    While ($Job.JobStateInfo.State -ne "Completed") {Start-Sleep -Seconds 10}
                    $DomainJoined = (Get-WmiObject -ComputerName $ip -Class win32_computersystem).domain
                }

                Restart-Computer -ComputerName $IP -Credential $localCred 

            }

            Catch { 

                throw $_

            }

        }

        # Set VM Path for Physical Hosts

        Try {

            $SDNHOST1 = $SDNConfig.SDNHOST1IP.Split("/")[0]
            $SDNHOST2 = $SDNConfig.SDNHOST2IP.Split("/")[0]
            $SDNHOST3 = $SDNConfig.SDNHOST3IP.Split("/")[0]

            Write-Verbose "Setting VMStorage Path for all Hosts"
          
            Invoke-Command -ComputerName $SDNHOST1 -ArgumentList $VMStoragePathforOtherHosts `
                -ScriptBlock {Set-VMHost -VirtualHardDiskPath $args[0] -VirtualMachinePath $args[0]} `
                -Credential $using:localCred -AsJob | Out-Null
            Invoke-Command -ComputerName $SDNHOST2  -ArgumentList $VMStoragePathforOtherHosts `
                -ScriptBlock {Set-VMHost -VirtualHardDiskPath $args[0] -VirtualMachinePath $args[0]} `
                -Credential $using:localCred -AsJob | Out-Null
            Invoke-Command -ComputerName $SDNHOST3 -ArgumentList $VMStoragePathforOtherHosts `
                -ScriptBlock {Set-VMHost -VirtualHardDiskPath $args[0] -VirtualMachinePath $args[0]} `
                -Credential $using:localCred -AsJob | Out-Null

            # 2nd pass
            Invoke-Command -ComputerName $SDNHOST1 -ArgumentList $VMStoragePathforOtherHosts `
                -ScriptBlock {Set-VMHost -VirtualHardDiskPath $args[0] -VirtualMachinePath $args[0]} `
                -Credential $using:localCred -AsJob | Out-Null
            Invoke-Command -ComputerName $SDNHOST2 -ArgumentList $VMStoragePathforOtherHosts `
                -ScriptBlock {Set-VMHost -VirtualHardDiskPath $args[0] -VirtualMachinePath $args[0]} `
                -Credential $using:localCred -AsJob | Out-Null
            Invoke-Command -ComputerName $SDNHOST3 -ArgumentList $VMStoragePathforOtherHosts `
                -ScriptBlock {Set-VMHost -VirtualHardDiskPath $args[0] -VirtualMachinePath $args[0]} `
                -Credential $using:localCred -AsJob | Out-Null

        }

        Catch {

            throw $_

        }

        #Add SDNHOSTS to domain

        Try {

            Write-Verbose "Adding SDN Hosts to the Domain"
            AddSDNHostToDomain -IP $SDNHOST1 -localCred $using:localCred -domainCred $using:domainCred -SDNHostName SDNHOST1 -SDNConfig $SDNConfig
            AddSDNHostToDomain -IP $SDNHOST2 -localCred $using:localCred -domainCred $using:domainCred -SDNHostName SDNHOST2 -SDNConfig $SDNConfig
            AddSDNHostToDomain -IP $SDNHOST3 -localCred $using:localCred -domainCred $using:domainCred -SDNHostName SDNHOST3 -SDNConfig $SDNConfig
        }

        Catch {

            throw $_

        }

    } | Out-Null

    # Provision Admincenter

    Write-Verbose "Provisioning Admin Center"
    New-AdminCenterVM -SDNConfig $SDNConfig -localCred $localCred -domainCred $domainCred | Out-Null

    # Provision Console

    Write-Verbose "Provisioning Console VM"
    New-ConsoleVM -SDNConfig $SDNConfig -localCred $localCred -domainCred $domainCred | Out-Null

}

function New-DCVM {

    Param (

        $SDNConfig,
        $localCred,
        $domainCred

    )

    Invoke-Command -VMName sdnmgmt -Credential $domainCred -ScriptBlock {

        $SDNConfig = $using:SDNConfig
        $localcred = $using:localcred
        $domainCred = $using:domainCred
        $ParentDiskPath = "C:\VMs\Base\"
        $vmpath = "D:\VMs\"
        $OSVHDX = "GUI.vhdx"
        $coreOSVHDX = "Core.vhdx"
        $consoleOSVHDX = "Console.vhdx" 
        $VMStoragePathforOtherHosts = $SDNConfig.HostVMPath
        $SourcePath = 'C:\VMConfigs'
        $VMName = $SDNConfig.DCName

        $ProgressPreference = "SilentlyContinue"
        $ErrorActionPreference = "Stop"
        $VerbosePreference = "Continue"
        $WarningPreference = "SilentlyContinue"

        # Create Virtual Machine

        Write-Verbose "Creating $VMName differencing disks"
        
        $params = @{

            ParentPath = ($ParentDiskPath + $OSVHDX)
            Path       = ($vmpath + $VMName + '\' + $VMName + '.vhdx')

        }

        New-VHD  @params -Differencing | Out-Null

        Write-Verbose "Creating $VMName virtual machine"
        
        $params = @{

            Name       = $VMName
            VHDPath    = ($vmpath + $VMName + '\' + $VMName + '.vhdx')
            Path       = ($vmpath + $VMName)
            Generation = 2

        }

        New-VM @params | Out-Null

        Write-Verbose "Setting $VMName Memory"

        $params = @{

            VMName               = $VMName
            DynamicMemoryEnabled = $true
            StartupBytes         = $SDNConfig.MEM_DC
            MaximumBytes         = $SDNConfig.MEM_DC
            MinimumBytes         = 500MB

        }


        Set-VMMemory @params | Out-Null

        Write-Verbose "Configuring $VMName's networking"

        Remove-VMNetworkAdapter -VMName $VMName -Name "Network Adapter" | Out-Null

        $params = @{

            VMName       = $VMName
            Name         = $SDNConfig.DCName
            SwitchName   = 'vSwitch-Fabric'
            DeviceNaming = 'On'

        }

        Add-VMNetworkAdapter @params | Out-Null
        Write-Verbose "Configuring $VMName's settings"
        Set-VMProcessor -VMName $VMName -Count 2 | Out-Null
        Set-VM -Name $VMName -AutomaticStartAction Start -AutomaticStopAction ShutDown | Out-Null

        # Inject Answer File

        Write-Verbose "Mounting and injecting answer file into the $VMName VM."        
        $VerbosePreference = "SilentlyContinue"

        New-Item -Path "C:\TempMount" -ItemType Directory | Out-Null
        Mount-WindowsImage -Path "C:\TempMount" -Index 1 -ImagePath ($vmpath + $VMName + '\' + $VMName + '.vhdx') | Out-Null

        $VerbosePreference = "Continue"
        Write-Verbose "Applying Unattend file to Disk Image..."

        $password = $SDNConfig.SDNAdminPassword
        $Unattend = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <servicing>
        <package action="configure">
            <assemblyIdentity name="Microsoft-Windows-Foundation-Package" version="10.0.14393.0" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="" />
            <selection name="ADCertificateServicesRole" state="true" />
            <selection name="CertificateServices" state="true" />
        </package>
    </servicing>
    <settings pass="specialize">
        <component name="Networking-MPSSVC-Svc" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <DomainProfile_EnableFirewall>false</DomainProfile_EnableFirewall>
            <PrivateProfile_EnableFirewall>false</PrivateProfile_EnableFirewall>
            <PublicProfile_EnableFirewall>false</PublicProfile_EnableFirewall>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <ComputerName>$VMName</ComputerName>
        </component>
        <component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <fDenyTSConnections>false</fDenyTSConnections>
        </component>
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <UserLocale>en-us</UserLocale>
            <UILanguage>en-us</UILanguage>
            <SystemLocale>en-us</SystemLocale>
            <InputLocale>en-us</InputLocale>
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <SkipMachineOOBE>true</SkipMachineOOBE>
                <SkipUserOOBE>true</SkipUserOOBE>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
            </OOBE>
            <UserAccounts>
                <AdministratorPassword>
                    <Value>$password</Value>
                    <PlainText>true</PlainText>
                </AdministratorPassword>
            </UserAccounts>
        </component>
    </settings>
    <cpi:offlineImage cpi:source="" xmlns:cpi="urn:schemas-microsoft-com:cpi" />
</unattend>
"@

        New-Item -Path C:\TempMount\windows -ItemType Directory -Name Panther -Force | Out-Null
        Set-Content -Value $Unattend -Path "C:\TempMount\Windows\Panther\Unattend.xml"  -Force

        Write-Verbose "Dismounting Windows Image"
        Dismount-WindowsImage -Path "C:\TempMount" -Save | Out-Null
        Remove-Item "C:\TempMount"  | Out-Null

        # Start Virtual Machine

        Write-Verbose "Starting Virtual Machine" 
        Start-VM -Name $VMName | Out-Null

        # Wait until the VM is restarted

        while ((Invoke-Command -VMName $VMName -Credential $using:domainCred {"Test"} `
                    -ea SilentlyContinue) -ne "Test") {Start-Sleep -Seconds 1}

        Write-Verbose "Configuring Domain Controller VM and Installing Active Directory."
        Invoke-Command -VMName $VMName -Credential $localCred -ArgumentList $SDNConfig -ScriptBlock {

            $SDNConfig = $args[0]

            $VerbosePreference = "Continue"
            $WarningPreference = "SilentlyContinue"
            $ErrorActionPreference = "Stop"

            $DCName = $SDNConfig.DCName
            $IP = $SDNConfig.SDNLABDNS
            $PrefixLength = ($SDNConfig.SDNMGMTIP.split("/"))[1]
            $SDNLabRoute = $SDNConfig.SDNLABRoute
            $DomainFQDN = $SDNConfig.SDNDomainFQDN
            $DomainNetBiosName = $DomainFQDN.Split(".")[0]

            Write-Verbose "Configuring NIC Settings for Domain Controller"
            $VerbosePreference = "SilentlyContinue"
            $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object {$_.RegistryValue -eq $DCName}
            Rename-NetAdapter -name $NIC.name -newname $DCName | Out-Null 
            New-NetIPAddress -InterfaceAlias $DCName –IPAddress $ip -PrefixLength $PrefixLength -DefaultGateway $SDNLabRoute | Out-Null
            Set-DnsClientServerAddress -InterfaceAlias $DCName -ServerAddresses $IP | Out-Null
            Install-WindowsFeature -name AD-Domain-Services –IncludeManagementTools | Out-Null
            $VerbosePreference = "Continue"

            Write-Verbose "Installing Active Directory Forest. This will take some time..."
        
            $SecureString = ConvertTo-SecureString $SDNConfig.SDNAdminPassword -AsPlainText -Force
            Write-Verbose "`n`n`n`n`n`n`nInstalling Active Directory..." 

            $params = @{

                DomainName                    = $DomainFQDN
                DomainMode                    = 'WinThreshold'
                DatabasePath                  = "C:\Domain"
                DomainNetBiosName             = $DomainNetBiosName
                SafeModeAdministratorPassword = $SecureString

            }


            Write-Output $params

            
            $VerbosePreference = "SilentlyContinue"

            Install-ADDSForest  @params -InstallDns -Confirm -Force -NoRebootOnCompletion | Out-Null

        }

        Write-Verbose "Stopping $VMName"
        Get-VM $VMName | Stop-VM
        Write-Verbose "Starting $VMName"
        Get-VM $VMName | Start-VM 

        # Wait until DC is created and rebooted

        while ((Invoke-Command -VMName $VMName -Credential $using:domainCred `
                    -ArgumentList $SDNConfig.DCName {(Get-ADDomainController $args[0]).enabled} -ea SilentlyContinue) -ne $true) {Start-Sleep -Seconds 1}

        $VerbosePreference = "Continue"
        Write-Verbose "Configuring User Accounts and Groups in Active Directory"

        Invoke-Command -VMName $VMName -Credential $using:domainCred -ArgumentList $SDNConfig -ScriptBlock {

            $SDNConfig = $args[0]
            $SDNDomainFQDN = $SDNConfig.SDNDomainFQDN

            $VerbosePreference = "Continue"
            $ErrorActionPreference = "Stop"
    
            $SecureString = ConvertTo-SecureString $SDNConfig.SDNAdminPassword -AsPlainText -Force


            $params = @{

                ComplexityEnabled = $false
                Identity          = $SDNConfig.SDNDomainFQDN
                MinPasswordLength = 0

            }


            Set-ADDefaultDomainPasswordPolicy @params

            $params = @{

                Name                  = 'NC Admin'
                GivenName             = 'NC'
                Surname               = 'Admin'
                SamAccountName        = 'NCAdmin'
                UserPrincipalName     = "NCAdmin@$SDNDomainFQDN"
                AccountPassword       = $SecureString
                Enabled               = $true
                ChangePasswordAtLogon = $false
                CannotChangePassword  = $true
                PasswordNeverExpires  = $true
            }

            New-ADUser @params

            $params.Name = 'NC Client'
            $params.Surname = 'Client'
            $params.SamAccountName = 'NCClient'
            $params.UserPrincipalName = "NCClient@$SDNDomainFQDN" 

            New-ADUser @params

            NEW-ADGroup –name “NCAdmins” –groupscope Global
            NEW-ADGroup –name “NCClients” –groupscope Global

            add-ADGroupMember "Domain Admins" "NCAdmin"
            add-ADGroupMember "NCAdmins" "NCAdmin"
            add-ADGroupMember "NCClients" "NCClient"
            add-ADGroupMember "NCClients" "Administrator"
            add-ADGroupMember "NCAdmins" "Administrator"

            # Set Administrator Account Not to Expire

            Get-ADUser Administrator | Set-ADUser -PasswordNeverExpires $true  -CannotChangePassword $true

            # Set DNS Forwarder

            Write-Verbose "Adding DNS Forwarders"
            $VerbosePreference = "SilentlyContinue"

            if ($SDNConfig.natDNS) {Add-DnsServerForwarder $SDNConfig.natDNS}
            else {Add-DnsServerForwarder 8.8.8.8}

            # Create Enterprise CA 

            $VerbosePreference = "Continue"
            Write-Verbose "Installing and Configuring Active Directory Certificate Services and Certificate Templates"
            $VerbosePreference = "SilentlyContinue"

            

            Install-WindowsFeature -Name AD-Certificate -IncludeAllSubFeature -IncludeManagementTools | Out-Null

            $params = @{

                CAtype              = 'EnterpriseRootCa'
                CryptoProviderName  = 'ECDSA_P256#Microsoft Software Key Storage Provider'
                KeyLength           = 256
                HashAlgorithmName   = 'SHA256'
                ValidityPeriod      = 'Years'
                ValidityPeriodUnits = 10
            }

            Install-AdcsCertificationAuthority @params -Confirm:$false | Out-Null

            # Give WebServer Template Enroll rights for Domain Computers

            $filter = "(CN=WebServer)"
            $ConfigContext = ([ADSI]"LDAP://RootDSE").configurationNamingContext
            $ConfigContext = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$ConfigContext"
            $ds = New-object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$ConfigContext", $filter)  
            $Template = $ds.Findone().GetDirectoryEntry() 

            if ($Template -ne $null) {
                $objUser = New-Object System.Security.Principal.NTAccount("Domain Computers") 
                $objectGuid = New-Object Guid 0e10c968-78fb-11d2-90d4-00c04f79dc55                     
                $ADRight = [System.DirectoryServices.ActiveDirectoryRights]"ExtendedRight"                     
                $ACEType = [System.Security.AccessControl.AccessControlType]"Allow"                     
                $ACE = New-Object System.DirectoryServices.ActiveDirectoryAccessRule -ArgumentList $objUser, $ADRight, $ACEType, $objectGuid                     
                $Template.ObjectSecurity.AddAccessRule($ACE)                     
                $Template.commitchanges()
            } 
 
            CMD.exe /c "certutil -setreg ca\ValidityPeriodUnits 8" | Out-Null
            Restart-Service CertSvc
            Start-Sleep -Seconds 60
 
            #Issue Certificate Template

            CMD.exe /c "certutil -SetCATemplates +WebServer"
 
        }
 
    }

}

function New-RouterVM {

    Param (

        $SDNConfig,
        $localCred,
        $domainCred

    )

    Invoke-Command -VMName sdnmgmt -Credential $localCred -ScriptBlock {

        $SDNConfig = $using:SDNConfig
        $localcred = $using:localcred
        $domainCred = $using:domainCred
        $ParentDiskPath = "C:\VMs\Base\"
        $vmpath = "D:\VMs\"
        $OSVHDX = "Core.vhdx"
        $VMStoragePathforOtherHosts = $SDNConfig.HostVMPath
        $SourcePath = 'C:\VMConfigs'
    
        $ProgressPreference = "SilentlyContinue"
        $ErrorActionPreference = "Stop"
        $VerbosePreference = "Continue"
        $WarningPreference = "SilentlyContinue"    
    
        $VMName = "bgp-tor-router"
    
        # Create Host OS Disk

        Write-Verbose "Creating $VMName differencing disks"

        $params = @{

            ParentPath = ($ParentDiskPath + $OSVHDX)
            Path       = ($vmpath + $VMName + '\' + $VMName + '.vhdx') 

        }

        New-VHD @params -Differencing | Out-Null
    
        # Create VM

        $params = @{

            Name       = $VMName
            VHDPath    = ($vmpath + $VMName + '\' + $VMName + '.vhdx')
            Path       = ($vmpath + $VMName)
            Generation = 2

        }

        Write-Verbose "Creating the $VMName VM."
        New-VM @params | Out-Null
    
        # Set VM Configuration

        Write-Verbose "Setting $VMName's VM Configuration"

        $params = @{

            VMName               = $VMName
            DynamicMemoryEnabled = $true
            StartupBytes         = $SDNConfig.MEM_BGP
            MaximumBytes         = $SDNConfig.MEM_BGP
            MinimumBytes         = 500MB
        }
   
        Set-VMMemory @params | Out-Null
        Remove-VMNetworkAdapter -VMName $VMName -Name "Network Adapter" | Out-Null 
        Set-VMProcessor -VMName $VMName -Count 2 | Out-Null
        set-vm -Name $VMName -AutomaticStopAction TurnOff | Out-Null
    
        # Configure VM Networking

        Write-Verbose "Configuring $VMName's Networking"
        Add-VMNetworkAdapter -VMName $VMName -Name Mgmt -SwitchName vSwitch-Fabric -DeviceNaming On
        Add-VMNetworkAdapter -VMName $VMName -Name Provider -SwitchName vSwitch-Fabric -DeviceNaming On
        Add-VMNetworkAdapter -VMName $VMName -Name VLAN200 -SwitchName vSwitch-Fabric -DeviceNaming On
        Set-VMNetworkAdapterVlan -VMName $VMName -VMNetworkAdapterName Provider -Access -VlanId $SDNConfig.providerVLAN
        Set-VMNetworkAdapterVlan -VMName $VMName -VMNetworkAdapterName VLAN200 -Access -VlanId $SDNConfig.vlan200VLAN    
    
        # Add NAT Adapter

        if ($SDNConfig.natConfigure) {

            Add-VMNetworkAdapter -VMName $VMName -Name NAT -SwitchName NAT -DeviceNaming On
        }    
    
        # Configure VM
        Set-VMProcessor -VMName $VMName  -Count 2
        Set-VM -Name $VMName -AutomaticStartAction Start -AutomaticStopAction ShutDown | Out-Null      
    
        # Inject Answer File

        Write-Verbose "Mounting Disk Image and Injecting Answer File into the $VMName VM." 
        New-Item -Path "C:\TempBGPMount" -ItemType Directory | Out-Null
        Mount-WindowsImage -Path "C:\TempBGPMount" -Index 1 -ImagePath ($vmpath + $VMName + '\' + $VMName + '.vhdx') | Out-Null
    
        New-Item -Path C:\TempBGPMount\windows -ItemType Directory -Name Panther -Force | Out-Null
    
        $Password = $SDNConfig.SDNAdminPassword
        $ProductKey = $SDNConfig.COREProductKey
    
        $Unattend = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
        <servicing>
            <package action="configure">
                <assemblyIdentity name="Microsoft-Windows-Foundation-Package" version="10.0.14393.0" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="" />
                <selection name="RemoteAccessServer" state="true" />
                <selection name="RasRoutingProtocols" state="true" />
            </package>
        </servicing>
        <settings pass="specialize">
            <component name="Networking-MPSSVC-Svc" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
                <DomainProfile_EnableFirewall>false</DomainProfile_EnableFirewall>
                <PrivateProfile_EnableFirewall>false</PrivateProfile_EnableFirewall>
                <PublicProfile_EnableFirewall>false</PublicProfile_EnableFirewall>
            </component>
            <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
                <ComputerName>$VMName</ComputerName>
            </component>
            <component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
                <fDenyTSConnections>false</fDenyTSConnections>
            </component>
            <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
                <UserLocale>en-us</UserLocale>
                <UILanguage>en-us</UILanguage>
                <SystemLocale>en-us</SystemLocale>
                <InputLocale>en-us</InputLocale>
            </component>
        </settings>
        <settings pass="oobeSystem">
            <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
                <OOBE>
                    <HideEULAPage>true</HideEULAPage>
                    <SkipMachineOOBE>true</SkipMachineOOBE>
                    <SkipUserOOBE>true</SkipUserOOBE>
                    <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                </OOBE>
                <UserAccounts>
                    <AdministratorPassword>
                        <Value>$Password</Value>
                        <PlainText>true</PlainText>
                    </AdministratorPassword>
                </UserAccounts>
            </component>
        </settings>
        <cpi:offlineImage cpi:source="" xmlns:cpi="urn:schemas-microsoft-com:cpi" />
    </unattend>    
"@
        Set-Content -Value $Unattend -Path "C:\TempBGPMount\Windows\Panther\Unattend.xml" -Force
    
        Write-Verbose "Enabling Remote Access"
        Enable-WindowsOptionalFeature -Path C:\TempBGPMount -FeatureName RasRoutingProtocols -All -LimitAccess | Out-Null
        Enable-WindowsOptionalFeature -Path C:\TempBGPMount -FeatureName RemoteAccessPowerShell -All -LimitAccess | Out-Null
        Write-Verbose "Dismounting Disk Image for $VMName VM." 
        Dismount-WindowsImage -Path "C:\TempBGPMount" -Save | Out-Null
        Remove-Item "C:\TempBGPMount"
    
        # Start the VM

        Write-Verbose "Starting $VMName VM."
        Start-VM -Name $VMName      
    
        # Wait for VM to be started

        while ((Invoke-Command -VMName $VMName -Credential $localcred {"Test"} -ea SilentlyContinue) -ne "Test") { Start-Sleep -Seconds 1}    
    
        Write-Verbose "Configuring $VMName" 
    
        Invoke-Command -VMName $VMName -Credential $localCred -ArgumentList $SDNConfig -ScriptBlock {
    
            $ErrorActionPreference = "Stop"
            $VerbosePreference = "Continue"
            $WarningPreference = "SilentlyContinue"
    
            $SDNConfig = $args[0]
            $Gateway = $SDNConfig.SDNLABRoute
            $DNS = $SDNConfig.SDNLABDNS
            $Domain = $SDNConfig.SDNDomainFQDN
            $natSubnet = $SDNConfig.natSubnet
            $natDNS = $SDNConfig.natSubnet
            $MGMTIP = $SDNConfig.BGPRouterIP_MGMT.Split("/")[0]
            $MGMTPFX = $SDNConfig.BGPRouterIP_MGMT.Split("/")[1]
            $PNVIP = $SDNConfig.BGPRouterIP_ProviderNetwork.Split("/")[0]
            $PNVPFX = $SDNConfig.BGPRouterIP_ProviderNetwork.Split("/")[1]
            $VLANIP = $SDNConfig.BGPRouterIP_VLAN200.Split("/")[0]
            $VLANPFX = $SDNConfig.BGPRouterIP_VLAN200.Split("/")[1]
    
            # Renaming NetAdapters and setting up the IPs inside the VM using CDN parameters

            Write-Verbose "Configuring $env:COMPUTERNAME's Networking"
            $VerbosePreference = "SilentlyContinue"  
            $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object {$_.RegistryValue -eq "Mgmt"}
            Rename-NetAdapter -name $NIC.name -newname "Mgmt"  | Out-Null
            New-NetIPAddress -InterfaceAlias "Mgmt" –IPAddress $MGMTIP -PrefixLength $MGMTPFX | Out-Null
            Set-DnsClientServerAddress -InterfaceAlias “Mgmt” -ServerAddresses $DNS] | Out-Null
            $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object {$_.RegistryValue -eq "PROVIDER"}
            Rename-NetAdapter -name $NIC.name -newname "PROVIDER" | Out-Null
            New-NetIPAddress -InterfaceAlias "PROVIDER" –IPAddress $PNVIP -PrefixLength $PNVPFX | Out-Null
            $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object {$_.RegistryValue -eq "VLAN200"}
            Rename-NetAdapter -name $NIC.name -newname "VLAN200" | Out-Null
            New-NetIPAddress -InterfaceAlias "VLAN200" –IPAddress $VLANIP -PrefixLength $VLANPFX | Out-Null    
    
            # if NAT is selected, configure the adapter
       
            if ($SDNConfig.natConfigure) {
    
                $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" `
                    | Where-Object {$_.RegistryValue -eq "NAT"}
                Rename-NetAdapter -name $NIC.name -newname "NAT" | Out-Null
                $Subnet = ($natSubnet.Split("/"))[0]
                $Prefix = ($natSubnet.Split("/"))[1]
                $natEnd = $Subnet.Split(".")
                $natIP = ($natSubnet.TrimEnd("0./$Prefix")) + (".10")
                $natGW = ($natSubnet.TrimEnd("0./$Prefix")) + (".1")
                New-NetIPAddress -InterfaceAlias "NAT" –IPAddress $natIP -PrefixLength $Prefix -DefaultGateway $natGW | Out-Null
                if ($natDNS) {
                    Set-DnsClientServerAddress -InterfaceAlias "NAT" -ServerAddresses $natDNS | Out-Null
                }
            }
    
            # Installing Remote Access

            Write-Verbose "Installing Remote Access on $env:COMPUTERNAME" 
            $VerbosePreference = "SilentlyContinue"
            Install-RemoteAccess -VPNType RoutingOnly | Out-Null
    
            # Adding a BGP Router to the VM

            $VerbosePreference = "Continue"
            Write-Verbose "Installing BGP Router on $env:COMPUTERNAME"
            $VerbosePreference = "SilentlyContinue"
            Add-BgpRouter -BGPIdentifier $PNVIP -LocalASN $SDNConfig.BGPRouterASN `
                -TransitRouting Enabled -ClusterId 1 -RouteReflector Enabled

            # Configure BGP Peers

            if ($SDNConfig.ConfigureBGPpeering -and $SDNConfig.ProvisionNC) {

                Write-Verbose "Peering future MUX/GWs"

                $Mux01IP = ($SDNConfig.BGPRouterIP_ProviderNetwork.TrimEnd("1/24")) + "4"
                $GW01IP = ($SDNConfig.BGPRouterIP_ProviderNetwork.TrimEnd("1/24")) + "5"
                $GW02IP = ($SDNConfig.BGPRouterIP_ProviderNetwork.TrimEnd("1/24")) + "6"

                $params = @{

                    Name           = 'MUX01'
                    LocalIPAddress = $PNVIP
                    PeerIPAddress  = $Mux01IP
                    PeerASN        = $SDNConfig.SDNASN
                    OperationMode  = 'Mixed'
                    PeeringMode    = 'Automatic'
                }

                Add-BgpPeer @params -PassThru

                $params.Name = GW01
                $params.PeerIPAddress = $GW01IP

                Add-BgpPeer @params -PassThru

                $params.Name = $GW02IP
                $params.PeerIPAddress = $GW02IP

                Add-BgpPeer @params -PassThru    

            }
    
            # Enable Large MTU

            Write-Verbose "Configuring MTU on all Adapters"
            Get-NetAdapter | Where-Object {$_.Status -eq "Up"} | Set-NetAdapterAdvancedProperty -RegistryValue $SDNConfig.SDNLABMTU -RegistryKeyword "*JumboPacket"   
    
        }     
    
        $ErrorActionPreference = "Continue"
        $VerbosePreference = "SilentlyContinue"
        $WarningPreference = "Continue"

    } -AsJob

}

function New-AdminCenterVM {

    Param (

        $SDNConfig,
        $localCred,
        $domainCred

    )

    Invoke-Command -VMName sdnmgmt -Credential $localCred -ScriptBlock {

        $VMName = "admincenter"
        $ParentDiskPath = "C:\VMs\Base\"
        $VHDPath = "D:\VMs\"
        $OSVHDX = "Core.vhdx"
        $BaseVHDPathCore = $ParentDiskPath + $OSVHDX
        $SDNConfig = $using:SDNConfig

        $ProgressPreference = "SilentlyContinue"
        $ErrorActionPreference = "Stop"
        $VerbosePreference = "Continue"
        $WarningPreference = "SilentlyContinue"

        # Set Credentials

        $localCred = $using:localCred
        $domainCred = $using:domainCred

        # Create Host OS Disk

        Write-Verbose "Creating $VMName differencing disks"

        $params = @{

            ParentPath = $BaseVHDPathCore
            Path       = (($VHDPath) + ($VMName) + (".vhdx")) 
        }

        New-VHD -Differencing @params | out-null

        # MountVHDXFile

        Write-Verbose "Mounting and Injecting Answer File into the $VMName VM." 
        New-Item -Path "C:\TempWACMount" -ItemType Directory | Out-Null
        Mount-WindowsImage -Path "C:\TempWACMount" -Index 1 -ImagePath (($VHDPath) + ($VMName) + (".vhdx")) | Out-Null

        # Copy Source Files

        Write-Verbose "Copying Application and Script Source Files to $VMName"
        Copy-Item 'C:\VMConfigs\Windows Admin Center' -Destination C:\TempWACMount\ -Recurse -Force

        # Apply Custom Unattend.xml file

        New-Item -Path C:\TempWACMount\windows -ItemType Directory -Name Panther -Force | Out-Null
        $Password = $SDNConfig.SDNAdminPassword
        $ProductKey = $SDNConfig.COREProductKey
        $Gateway = $SDNConfig.SDNLABRoute
        $DNS = $SDNConfig.SDNLABDNS
        $IPAddress = $SDNConfig.WACIP
        $Domain = $SDNConfig.SDNDomainFQDN

        $Unattend = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <ProductKey>$ProductKey</ProductKey>
            <ComputerName>$VMName</ComputerName>
            <RegisteredOwner>$ENV:USERNAME</RegisteredOwner>
        </component>
        <component name="Microsoft-Windows-TCPIP" processorArchitecture="wow64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <Interfaces>
                <Interface wcm:action="add">
                    <Ipv4Settings>
                        <DhcpEnabled>false</DhcpEnabled>
                        <RouterDiscoveryEnabled>true</RouterDiscoveryEnabled>
                    </Ipv4Settings>
                    <UnicastIpAddresses>
                        <IpAddress wcm:action="add" wcm:keyValue="1">$IPAddress</IpAddress>
                    </UnicastIpAddresses>
                    <Identifier>Ethernet</Identifier>
                    <Routes>
                        <Route wcm:action="add">
                            <Identifier>1</Identifier>
                            <NextHopAddress>$Gateway</NextHopAddress>
                        </Route>
                    </Routes>
                </Interface>
            </Interfaces>
        </component>
        <component name="Microsoft-Windows-DNS-Client" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <Interfaces>
                <Interface wcm:action="add">
                    <DNSServerSearchOrder>
                        <IpAddress wcm:action="add" wcm:keyValue="1">$DNS</IpAddress>
                    </DNSServerSearchOrder>
                    <Identifier>Ethernet</Identifier>
                    <DNSDomain>$Domain</DNSDomain>
                    <EnableAdapterDomainNameRegistration>true</EnableAdapterDomainNameRegistration>
                </Interface>
            </Interfaces>
        </component>
        <component name="Networking-MPSSVC-Svc" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <DomainProfile_EnableFirewall>false</DomainProfile_EnableFirewall>
            <PrivateProfile_EnableFirewall>false</PrivateProfile_EnableFirewall>
            <PublicProfile_EnableFirewall>false</PublicProfile_EnableFirewall>
        </component>
        <component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <fDenyTSConnections>false</fDenyTSConnections>
        </component>
        <component name="Microsoft-Windows-UnattendedJoin" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <Identification>
                <Credentials>
                    <Domain>$Domain</Domain>
                    <Password>$Password</Password>
                    <Username>Administrator</Username>
                </Credentials>
                <JoinDomain>$Domain</JoinDomain>
            </Identification>
        </component>
        <component name="Microsoft-Windows-IE-ESC" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <IEHardenAdmin>false</IEHardenAdmin>
            <IEHardenUser>false</IEHardenUser>
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <UserAccounts>
                <AdministratorPassword>
                    <Value>$Password</Value>
                    <PlainText>true</PlainText>
                </AdministratorPassword>
            </UserAccounts>
            <TimeZone>Pacific Standard Time</TimeZone>
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <SkipUserOOBE>true</SkipUserOOBE>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Work</NetworkLocation>
                <ProtectYourPC>1</ProtectYourPC>
                <HideLocalAccountScreen>true</HideLocalAccountScreen>
            </OOBE>
        </component>
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <UserLocale>en-US</UserLocale>
            <SystemLocale>en-US</SystemLocale>
            <InputLocale>0409:00000409</InputLocale>
            <UILanguage>en-US</UILanguage>
        </component>
    </settings>
    <cpi:offlineImage cpi:source="" xmlns:cpi="urn:schemas-microsoft-com:cpi" />
</unattend>
"@

        Set-Content -Value $Unattend -Path "C:\TempWACMount\Windows\Panther\Unattend.xml" -Force

        # Save Customizations and then dismount.

        Write-Verbose "Dismounting Disk"
        Dismount-WindowsImage -Path "C:\TempWACMount" -Save | Out-Null
        Remove-Item "C:\TempWACMount"

        # Create VM

        Write-Verbose "Creating the $VMName VM."

        $params = @{

            Name       = $VMName
            VHDPath    = (($VHDPath) + ($VMName) + (".vhdx")) 
            Path       = $VHDPath
            Generation = 2
        }

        New-VM @params | Out-Null

        $memory = $SDNConfig.MEM_WAC

        $params = @{

            VMName               = $VMName
            DynamicMemoryEnabled = $true
            StartupBytes         = $SDNConfig.MEM_WAC
            MaximumBytes         = $SDNConfig.MEM_WAC
            MinimumBytes         = 500mb 
        }

        Set-VMMemory @params | Out-Null
        Set-VM -Name $VMName -AutomaticStartAction Start -AutomaticStopAction ShutDown | Out-Null

        Write-Verbose "Configuring $VMName's Networking"
        Remove-VMNetworkAdapter -VMName $VMName -Name "Network Adapter"
        Add-VMNetworkAdapter -VMName $VMName -Name "Fabric" -SwitchName "vSwitch-Fabric" -DeviceNaming On

        Write-Verbose "Setting $VMName's VM Configuration"
        Set-VMProcessor -VMName $VMname -Count 2
        set-vm -Name $VMName  -AutomaticStopAction TurnOff

        Write-Verbose "Starting $VMName VM."
        Start-VM -Name $VMName

        # Wait until the VM is restarted

        while ((Invoke-Command -VMName $VMName -Credential $domainCred {"Test"} `
                    -ea SilentlyContinue) -ne "Test") {Start-Sleep -Seconds 1}

        # Finish Configuration

        Invoke-Command -VMName $VMName -Credential $domainCred -ArgumentList $SDNConfig -ScriptBlock {

            $SDNConfig = $args[0]
            $Gateway = $SDNConfig.SDNLABRoute
            $VerbosePreference = "Continue"
            $ErrorActionPreference = "Stop"

            Write-Verbose "Rename Network Adapter in $VMName VM" 
            Get-NetAdapter -Name Ethernet | Rename-NetAdapter -NewName Fabric

            # Set Gateway
            $index = (Get-WmiObject Win32_NetworkAdapter | Where-Object {$_.netconnectionid -eq "Fabric"}).InterfaceIndex
            $NetInterface = Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object {$_.InterfaceIndex -eq $index}     
            $NetInterface.SetGateways($Gateway) | Out-Null

            $fqdn = $SDNConfig.SDNDomainFQDN

            # Enable CredSSP

            $VerbosePreference = "SilentlyContinue" 
            Enable-PSRemoting -force
            Enable-WSManCredSSP -Role Server -Force
            Enable-WSManCredSSP -Role Client -DelegateComputer localhost -Force
            Enable-WSManCredSSP -Role Client -DelegateComputer $env:COMPUTERNAME -Force
            Enable-WSManCredSSP -Role Client -DelegateComputer $fqdn -Force
            Enable-WSManCredSSP -Role Client -DelegateComputer "*.$fqdn" -Force
            New-Item -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation `
                -Name AllowFreshCredentialsWhenNTLMOnly -Force
            New-ItemProperty -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation\AllowFreshCredentialsWhenNTLMOnly `
                -Name 1 -Value * -PropertyType String -Force

            $VerbosePreference = "Continue" 

            # Install RSAT-NetworkController

            $isAvailable = Get-WindowsFeature | Where-Object {$_.Name -eq 'RSAT-NetworkController'}

            if ($isAvailable) {

            Install-WindowsFeature -Name RSAT-NetworkController -IncludeAllSubFeature -IncludeManagementTools | Out-Null

            }


            # Set Gateway
            

            # Request SSL Certificate for Windows Admin Center

            Write-Verbose "Generating SSL Certificate Request"

            $RequestInf = @"
[Version] 
Signature="`$Windows NT$"

[NewRequest] 
Subject = "CN=AdminCenter.$fqdn"
Exportable = True
KeyLength = 2048                    
KeySpec = 1                     
KeyUsage = 0xA0               
MachineKeySet = True 
ProviderName = "Microsoft RSA SChannel Cryptographic Provider" 
ProviderType = 12 
SMIME = FALSE 
RequestType = CMC
FriendlyName = "Nested SDN Windows Admin Cert"

[Strings] 
szOID_SUBJECT_ALT_NAME2 = "2.5.29.17" 
szOID_ENHANCED_KEY_USAGE = "2.5.29.37" 
szOID_PKIX_KP_SERVER_AUTH = "1.3.6.1.5.5.7.3.1" 
szOID_PKIX_KP_CLIENT_AUTH = "1.3.6.1.5.5.7.3.2"
[Extensions] 
%szOID_SUBJECT_ALT_NAME2% = "{text}dns=admincenter.$fqdn" 
%szOID_ENHANCED_KEY_USAGE% = "{text}%szOID_PKIX_KP_SERVER_AUTH%,%szOID_PKIX_KP_CLIENT_AUTH%"
[RequestAttributes] 
CertificateTemplate= WebServer
"@

            New-Item C:\WACCert -ItemType Directory -Force | Out-Null
            Set-Content -Value $RequestInf -Path C:\WACCert\WACCert.inf -Force | Out-Null

            $WACdomainCred = new-object -typename System.Management.Automation.PSCredential `
                -argumentlist (($SDNConfig.SDNDomainFQDN.Split(".")[0]) + "\administrator"), (ConvertTo-SecureString $SDNConfig.SDNAdminPassword -AsPlainText -Force)
            $WACVMName = "AdminCenter"
            $DCFQDN = $SDNConfig.DCName + '.' + $SDNConfig.SDNDomainFQDN
            $WACport = $SDNConfig.WACport
            $SDNConfig = $Using:SDNConfig
            $fqdn = $SDNConfig.SDNDomainFQDN

            $params = @{

                Name                                = 'microsoft.SDNNested'
                RunAsCredential                     = $Using:domainCred 
                MaximumReceivedDataSizePerCommandMB = 1000
                MaximumReceivedObjectSizeMB         = 1000
            }

            Register-PSSessionConfiguration @params

            Write-Verbose "Requesting and installing SSL Certificate" 

            Invoke-Command -ComputerName $WACVMName -ConfigurationName microsoft.SDNNested -ArgumentList $WACVMName, $SDNConfig, $DCFQDN -Credential $WACdomainCred -ScriptBlock {

                $VMName = $args[0]
                $SDNConfig = $args[1]
                $DCFQDN = $args[2]
                $VerbosePreference = "Continue"
                $ErrorActionPreference = "Stop"

                # Get the CA Name

                $CertDump = certutil -dump
                $ca = ((((($CertDump.Replace('`', "")).Replace("'", "")).Replace(":", "=")).Replace('\', "")).Replace('"', "") `
                        | ConvertFrom-StringData).Name
                $CertAuth = $DCFQDN + '\' + $ca

                Write-Verbose "CA is: $ca"
                Write-Verbose "Certificate Authority is: $CertAuth"
                Write-Verbose "Certdump is $CertDump"

                # Request and Accept SSL Certificate

                Set-Location C:\WACCert
                certreq -f -new WACCert.inf WACCert.req
                certreq -config $CertAuth -attrib "CertificateTemplate:webserver" –submit WACCert.req  WACCert.cer 
                certreq -accept WACCert.cer
                certutil -store my

                Set-Location 'C:\'
                Remove-Item C:\WACCert -Recurse -Force

            } -Authentication Credssp

            # Install Windows Admin Center

            $pfxThumbPrint = (Get-ChildItem -Path Cert:\LocalMachine\my | Where-Object {$_.FriendlyName -match "Nested SDN Windows Admin Cert"}).Thumbprint
            Write-Verbose "Thumbprint: $pfxThumbPrint"
            Write-Verbose "WACPort: $WACPort"
            $WindowsAdminCenterGateway = "https://admincenter." + $fqdn
            Write-Verbose $WindowsAdminCenterGateway
            Write-Verbose "Installing and Configuring Windows Admin Center"
            $PathResolve = Resolve-Path -Path 'C:\Windows Admin Center\*.msi'
            $arguments = "/qn /L*v C:\log.txt SME_PORT=$WACport SME_THUMBPRINT=$pfxThumbPrint SSL_CERTIFICATE_OPTION=installed  SME_URL=$WindowsAdminCenterGateway"
            Start-Process -FilePath $PathResolve -ArgumentList $arguments -PassThru  | Wait-Process

        } 

    } -AsJob

}

function New-ConsoleVM {

    Param (

        $SDNConfig,
        $localCred,
        $domainCred

    )

    Invoke-Command -VMName sdnmgmt -Credential $localCred -ScriptBlock {
  
        $VMName = "console"
        $ParentDiskPath = "C:\VMs\Base\Console.vhdx"
        $VHDPath = "D:\VMs\Console" 
        $BaseVHDPathConsole = $ParentDiskPath + $consoleOSVHDX
        $SDNConfig = $Using:SDNConfig
    
        $ProgressPreference = "SilentlyContinue"
        $ErrorActionPreference = "Stop"
        $VerbosePreference = "Continue"
        $WarningPreference = "SilentlyContinue"
    
        function TestConnection {
    
    
            $testpath = $false
            While (!$testpath) {
    
                Write-Verbose "Attempting to contact console VM....."
    
                Start-Sleep -seconds 60
                $test = Test-Path -Path \\console\c$ 
    
                if ($test) {
    
                    Write-Verbose "$VMName Successfully Contacted." 
    
                    return
                }
    
            }
    
        }    
    
        # Set Credentials

        $localCred = $using:localCred
        $domainCred = $using:domainCred

        # Create Host OS Disk

        Write-Verbose "Creating $VMName differencing disks"

        $params = @{

            ParentPath = $BaseVHDPathConsole 
            Path       = (($VHDPath) + ($VMName) + (".vhdx"))
        }

        New-VHD -Differencing @params | out-null
    
        # MountVHDXFile

        Write-Verbose "Mounting and Injecting Answer File into the $VMName VM." 
        $VerbosePreference = "SilentlyContinue"

        New-Item -Path "C:\TempConsoleMount" -ItemType Directory | Out-Null
        Mount-WindowsImage -Path "C:\TempConsoleMount" -Index 1 -ImagePath (($VHDPath) + ($VMName) + (".vhdx")) | Out-Null
    
        # Copy Source Files
        $VerbosePreference = "Continue"
        Write-Verbose "Copying Application and Script Source Files to $VMName"
        Copy-Item C:\VMConfigs\SCRIPTS -Destination C:\TempConsoleMount -Recurse -Force
        Copy-Item C:\VMConfigs\RSAT -Destination C:\TempConsoleMount -Recurse -Force

        # Copy over VHD Files

        Write-Verbose "Copying over GUI and Core VHDX Files. This may take awhile..."
        New-Item  C:\TempConsoleMount -Name VHDs -ItemType Directory -Force | Out-Null
        Copy-Item C:\VMs\Base\Core.vhdx -Destination  C:\TempConsoleMount\VHDs
        Copy-Item C:\VMs\Base\GUI.vhdx -Destination  C:\TempConsoleMount\VHDs    
    
        # Apply Custom Unattend.xml file

        New-Item -Path C:\TempConsoleMount\windows -ItemType Directory -Name Panther -Force | Out-Null
        $Password = $SDNConfig.SDNAdminPassword
        $ProductKey = $SDNConfig.Win10ProductKey
        $Gateway = $SDNConfig.SDNLABRoute
        $DNS = $SDNConfig.SDNLABDNS
        $Domain = $SDNConfig.SDNDomainFQDN
        $ConsoleIP = $SDNConfig.CONSOLEIP
        $GatewayPrefix = $SDNConfig.BGPRouterIP_MGMT.Split("/")[1]    
    
        $Unattend = @"
    <?xml version="1.0" encoding="utf-8"?>
    <unattend xmlns="urn:schemas-microsoft-com:unattend">
        <settings pass="specialize">
            <component name="Networking-MPSSVC-Svc" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
                <DomainProfile_EnableFirewall>false</DomainProfile_EnableFirewall>
                <PrivateProfile_EnableFirewall>false</PrivateProfile_EnableFirewall>
                <PublicProfile_EnableFirewall>false</PublicProfile_EnableFirewall>
            </component>
            <component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
                <fDenyTSConnections>false</fDenyTSConnections>
            </component>
            <component name="Microsoft-Windows-UnattendedJoin" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
                <Identification>
                    <Credentials>
                        <Domain>$Domain</Domain>
                        <Password>$Password</Password>
                        <Username>Administrator</Username>
                    </Credentials>
                    <JoinDomain>$Domain</JoinDomain>
                </Identification>
            </component>
            <component name="Microsoft-Windows-TCPIP" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
                <Interfaces>
                    <Interface wcm:action="add">
                        <Identifier>Ethernet</Identifier>
                        <Ipv4Settings>
                            <DhcpEnabled>false</DhcpEnabled>
                        </Ipv4Settings>
                        <UnicastIpAddresses>
                            <IpAddress wcm:action="add" wcm:keyValue="1">192.168.1.8/24</IpAddress>
                        </UnicastIpAddresses>
                    </Interface>
                </Interfaces>
            </component>
            <component name="Microsoft-Windows-DNS-Client" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
                <Interfaces>
                    <Interface wcm:action="add">
                        <DNSServerSearchOrder>
                            <IpAddress wcm:action="add" wcm:keyValue="1">$DNS</IpAddress>
                        </DNSServerSearchOrder>
                        <DNSDomain>$Domain</DNSDomain>
                        <Identifier>Ethernet</Identifier>
                        <EnableAdapterDomainNameRegistration>true</EnableAdapterDomainNameRegistration>
                    </Interface>
                </Interfaces>
            </component>
            <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
                <ComputerName>$VMName</ComputerName>
            </component>
                    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
                <RunSynchronous>
                    <RunSynchronousCommand wcm:action="add">
                        <Order>1</Order>
                        <Description>Activate Local Admin Account</Description>
                        <Path>net user administrator /active:yes</Path>
                    </RunSynchronousCommand>
                </RunSynchronous>
            </component>
        </settings>
        <settings pass="oobeSystem">
            <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
                <AutoLogon>
                    <Password>
                        <Value>$Password</Value>
                        <PlainText>true</PlainText>
                    </Password>
                    <Enabled>true</Enabled>
                    <LogonCount>999</LogonCount>
                    <Username>Administrator</Username>
                    <Domain>$VMName</Domain>
                </AutoLogon>            
                <OOBE>
                    <HideEULAPage>true</HideEULAPage>
                    <HideLocalAccountScreen>true</HideLocalAccountScreen>
                    <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                    <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                    <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                    <NetworkLocation>Work</NetworkLocation>
                    <SkipUserOOBE>true</SkipUserOOBE>
                    <SkipMachineOOBE>true</SkipMachineOOBE>
                </OOBE>
                <UserAccounts>
                    <AdministratorPassword>
                        <Value>$Password</Value>
                        <PlainText>true</PlainText>
                    </AdministratorPassword>
                </UserAccounts>
            </component>
            <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
                <InputLocale>en-us</InputLocale>
                <SystemLocale>en-us</SystemLocale>
                <UILanguage>en-us</UILanguage>
                <UserLocale>en-us</UserLocale>
            </component>
        </settings>
        <cpi:offlineImage cpi:source="" xmlns:cpi="urn:schemas-microsoft-com:cpi" />
    </unattend>
"@

        Set-Content -Value $Unattend -Path "C:\TempConsoleMount\Windows\Panther\Unattend.xml" -Force    
    
        # Save Customizations and then dismount.

        Write-Verbose "Dismounting Disk"
        Dismount-WindowsImage -Path "C:\TempConsoleMount" -Save | Out-Null
        Remove-Item "C:\TempConsoleMount"
    
        # Create VM

        Write-Verbose "Creating the $VMName VM."

        $params = @{

            Name       = $VMName
            VHDPath    = (($VHDPath) + ($VMName) + (".vhdx")) 
            Path       = $VHDPath
            Generation = 2

        }

        New-VM @params| Out-Null

        $params = @{

            VMName               = $VMName
            DynamicMemoryEnabled = $true
            StartupBytes         = $SDNConfig.MEM_Console
            MaximumBytes         = $SDNConfig.MEM_Console
            MinimumBytes         = 500MB

        }

        Set-VMMemory @params | Out-Null
        Set-VM -Name $VMName -AutomaticStartAction Start -AutomaticStopAction ShutDown | Out-Null
    
        Write-Verbose "Configuring $VMName's Networking"
        Remove-VMNetworkAdapter -VMName $VMName -Name "Network Adapter"
        Add-VMNetworkAdapter -VMName $VMName -Name "Fabric" -SwitchName "vSwitch-Fabric" -DeviceNaming On
    
        Write-Verbose "Setting $VMName's VM Configuration"
        Set-VMProcessor -VMName $VMname -Count 2
        set-vm -Name $VMName  -AutomaticStopAction TurnOff    
    
        Write-Verbose "Starting $VMName VM."
        Start-VM -Name $VMName    
    
        # Ensure console is active

        TestConnection 
        Start-Sleep -Seconds 60    
     
        # Console Configuration
    
        Write-Verbose "Configuring $VMName VM" 
        Invoke-Command -VMName $VMName -ArgumentList $SDNConfig -ScriptBlock {
    
            Start-Sleep -Seconds 60
            $SDNConfig = $args[0]
            $fqdn = $SDNConfig.SDNDomainFQDN
            $VerbosePreference = "Continue"

            # Enable CredSSP
            $VerbosePreference = "SilentlyContinue" 
            Enable-PSRemoting -force
            Enable-WSManCredSSP -Role Server -Force
            Enable-WSManCredSSP -Role Client -DelegateComputer localhost -Force
            Enable-WSManCredSSP -Role Client -DelegateComputer $env:COMPUTERNAME -Force
            Enable-WSManCredSSP -Role Client -DelegateComputer $fqdn -Force
            Enable-WSManCredSSP -Role Client -DelegateComputer "*.$fqdn" -Force
            New-Item -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation `
                -Name AllowFreshCredentialsWhenNTLMOnly -Force
            New-ItemProperty -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation\AllowFreshCredentialsWhenNTLMOnly `
                -Name 1 -Value * -PropertyType String -Force
            $VerbosePreference = "SilentlyContinue" 
    
            # Install Windows RSAT

            Write-Verbose "Installing Windows RSAT" 
            $PathResolve = Resolve-Path -Path C:\RSAT\*.msu
            Unblock-File -Path $PathResolve -Confirm:$false | Out-Null
            $arguments = '/quiet /norestart'
            Start-Process -FilePath $PathResolve -ArgumentList $arguments -PassThru  | Wait-Process      
    
            # Enabling Hyper-V Tools

            Write-Verbose "Enabling Hyper-V Management Tools"
            $VerbosePreference = "SilentlyContinue"
            Enable-WindowsOptionalFeature -FeatureName Microsoft-Hyper-V-All -Online -NoRestart | Out-Null
            Disable-WindowsOptionalFeature -FeatureName Microsoft-Hyper-V -Online -NoRestart | Out-Null
            $VerbosePreference = "Continue"     
    
        } -Credential $domainCred

        Start-Sleep -Seconds 15
        Write-Verbose "Restarting $VMName"
        Get-VM $VMName | Stop-VM -Force -Confirm:$false
        Start-VM $VMName

        # Make Sure the Server is up

        TestConnection 
        Start-Sleep -Seconds 60 
    
        Write-Verbose "Configuring $VMName VM" 
        Invoke-Command -VMName $VMName -ArgumentList $SDNConfig -ScriptBlock {
    
            $SDNConfig = $args[0]
            $VerbosePreference = "Continue"  
        
            # Setting registry

            Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' `
                -Name AutoLogonCount -Value 0
            Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' `
                -Name DefaultDomainName -Value ($SDNConfig.SDNDomainFQDN)
    
            # Create a shortcut for Windows PowerShell ISE

            Write-Verbose "Creating Shortcut for PowerShell ISE"
            $TargetFile = "c:\windows\system32\WindowsPowerShell\v1.0\powershell_ise.exe"
            $ShortcutFile = "C:\Users\Public\Desktop\PowerShell ISE.lnk"
            $WScriptShell = New-Object -ComObject WScript.Shell
            $Shortcut = $WScriptShell.CreateShortcut($ShortcutFile)
            $Shortcut.TargetPath = $TargetFile
            $Shortcut.Save()

            # Create a shortcut for Windows PowerShell Console

            Write-Verbose "Creating Shortcut for PowerShell Console"
            $TargetFile = "c:\windows\system32\WindowsPowerShell\v1.0\powershell.exe"
            $ShortcutFile = "C:\Users\Public\Desktop\PowerShell.lnk"
            $WScriptShell = New-Object -ComObject WScript.Shell
            $Shortcut = $WScriptShell.CreateShortcut($ShortcutFile)
            $Shortcut.TargetPath = $TargetFile
            $Shortcut.Save()

            # Create a shortcut for Windows Admin Center

            Write-Verbose "Creating Shortcut for Windows Admin Center"

            if ($SDNConfig.WACport -ne "443") {$TargetPath = "https://admincenter." + $SDNConfig.SDNDomainFQDN + ":" + $SDNConfig.WACport}
            else {$TargetPath = "https://admincenter." + $SDNConfig.SDNDomainFQDN}
            $ShortcutFile = "C:\Users\Public\Desktop\Windows Admin Center.url"
            $WScriptShell = New-Object -ComObject WScript.Shell
            $Shortcut = $WScriptShell.CreateShortcut($ShortcutFile)
            $Shortcut.TargetPath = $TargetPath
            $Shortcut.Save()
    
            # Create Shortcut for Hyper-V Manager

            Write-Verbose "Creating Shortcut for Hyper-V Manager"
            Copy-Item -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Administrative Tools\Hyper-V Manager.lnk" `
                -Destination "C:\Users\Public\Desktop"

            # Create Shortcut for Failover-Cluster Manager

            Write-Verbose "Creating Shortcut for Failover-Cluster Manager"
            Copy-Item -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Administrative Tools\Failover Cluster Manager.lnk" `
                -Destination "C:\Users\Public\Desktop"

            # Create Shortcut for DNS

            Write-Verbose "Creating Shortcut for DNS Manager"
            Copy-Item -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Administrative Tools\DNS.lnk" `
                -Destination "C:\Users\Public\Desktop"

            # Create Shortcut for Active Directory Users and Computers

            Write-Verbose "Creating Shortcut for AD Users and Computers"
            Copy-Item -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Administrative Tools\Active Directory Users and Computers.lnk" `
                -Destination "C:\Users\Public\Desktop"
    
            # Set the SDNExplorer Script and place on desktop

            Write-Verbose "Configuring SDNExplorer"
            $SENCIP = "nc01." + $SDNConfig.SDNDomainFQDN    
            $SDNEXPLORER = "Set-Location 'C:\SCRIPTS\SDNExpress-Custom';.\SDNExplorer.ps1 -NCIP $SENCIP"    
            Set-Content -Value $SDNEXPLORER -Path 'C:\users\Public\Desktop\SDN Explorer.ps1' -Force
    
            # Set Network Profiles

            Get-NetConnectionProfile | Where-Object {$_.NetworkCategory -eq "Public"} `
                | Set-NetConnectionProfile -NetworkCategory Private | Out-Null    
    
            # Disable Automatic Updates

            $WUKey = "HKLM:\software\Policies\Microsoft\Windows\WindowsUpdate"
            New-Item -Path $WUKey -Force | Out-Null
            New-ItemProperty -Path $WUKey -Name AUOptions -PropertyType Dword -Value 2 `
                -Force | Out-Null      
    
            # Set Registry path to configure Microsoft Edge Home Page to GitHub

            $EdgeKey = "HKLM:\SOFTWARE\Policies\Microsoft\MicrosoftEdge\Internet Settings"
            New-Item -Path $EdgeKey -Force | Out-Null
            New-ItemProperty -Path $EdgeKey -Name DisableLockdownOfStartPages -PropertyType Dword `
                -Value 1 -Force | Out-Null
            New-ItemProperty -Path $EdgeKey -Name ProvisionedHomePages -PropertyType String `
                -Value ("https://github.com/Microsoft/SDN") -Force | Out-Null    
    
        } -Credential $domainCred

        Start-Sleep -Seconds 15
        Write-Verbose "Restarting $VMName"
        Get-VM $VMName | Stop-VM -Force -Confirm:$false
        Start-VM $VMName

        # Make Sure the Server is up

        TestConnection 
        Start-Sleep -Seconds 60 
    
        Invoke-Command -VMName $VMName -ArgumentList $SDNConfig, $domainCred -Credential $domainCred -ScriptBlock {

            $SDNConfig = $args[0]
            $domainCred = $args[1]
            $VerbosePreference = "Continue"

            # Set Kerberos Delegation

            Write-Verbose "Setting Kerberos Delegation"

            $VerbosePreference = "SilentlyContinue"
            Import-Module ActiveDirectory
            $serverstoDelegate = @("SDNHOST1", "SDNHOST2", "SDNHOST3", "Console")

            foreach ($server in $serverstoDelegate) {

                $server = Get-ADComputer -Identity $server
                Set-ADComputer -Identity $server -TrustedForDelegation $true
                $VerbosePreference = "Continue"

            }  
    
            # Add admincenter to to trusted zone in IE 

            $Domain = $SDNConfig.SDNDomainFQDN
    
            $Key = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains\$Domain\admincenter"
            New-Item $Key -Force | Out-Null
            New-ItemProperty -Path $Key -PropertyType DWord -Name https -Value 1 | Out-Null 
    
            # Rename Network Adapter

            $VerbosePreference = "SilentlyContinue"
            Get-NetAdapter -Name Ethernet | Rename-NetAdapter -NewName Fabric
            $VerbosePreference = "Continue"
    
            #Set Default Gateway

            Write-Verbose "Setting Default Gateway on $Env:COMPUTERNAME"  
            $index = (Get-WmiObject Win32_NetworkAdapter | Where-Object {$_.netconnectionid -eq "Fabric"}).InterfaceIndex
            $NetInterface = Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object {$_.InterfaceIndex -eq $index}     
            $NetInterface.SetGateways($SDNConfig.SDNLABRoute) | Out-Null
    
            # Set PowerShell Script Execution Policy

            Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine -Force -Confirm:$false
            Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope CurrentUser -Force -Confirm:$false
            Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope Process -Force -Confirm:$false 
 
        }

    
    } 

}

function New-HyperConvergedEnvironment {

    Param (

        $localCred,
        $domainCred

    )

    Invoke-Command -ComputerName Console -Credential $domainCred -ScriptBlock {

        $SDNConfig = $Using:SDNConfig
        $SDNHosts = @("SDNHOST1", "SDNHOST2", "SDNHOST3")

        $ErrorActionPreference = "Stop"
        $VerbosePreference = "Continue"

        $domainCred = new-object -typename System.Management.Automation.PSCredential `
            -argumentlist (($SDNConfig.SDNDomainFQDN.Split(".")[0]) + "\administrator"), `
        (ConvertTo-SecureString $SDNConfig.SDNAdminPassword -AsPlainText -Force)

        foreach ($SDNHost in $SDNHosts) {

            Invoke-Command -ComputerName $SDNHost -ArgumentList $SDNConfig -ScriptBlock {

                function New-sdnSETSwitch {

                    param (

                        $sdnswitchName, 
                        $sdnswitchIP, 
                        $sdnswitchIPpfx, 
                        $sdnswitchVLAN, 
                        $sdnswitchGW, 
                        $sdnswitchDNS, 
                        $sdnswitchteammembers

                    )

                    $VerbosePreference = "Continue"

                    Write-Verbose "Creating SET Hyper-V External Switch $sdnswitchName on host $env:COMPUTERNAME"

                    # Create Hyper-V Virtual Switch

                    $params = @{

                        Name                  = $sdnswitchName
                        AllowManagementOS     = $true
                        NetAdapterName        = $sdnswitchteammembers
                        EnableEmbeddedTeaming = $true

                    }

                    New-VMSwitch @params | Out-Null

                    # Set IP Config
                    Write-Verbose "Setting IP Configuration on $sdnswitchName"
                    $sdnswitchNIC = Get-Netadapter | Where-Object {$_.Name -match $sdnswitchName}

                    $params = @{

                        InterfaceIndex = $sdnswitchNIC.InterfaceIndex
                        IpAddress      = $sdnswitchIP 
                        PrefixLength   = $sdnswitchIPpfx 
                        AddressFamily  = 'IPv4'
                        DefaultGateway = $sdnswitchGW
                        ErrorAction    = 'SilentlyContinue'

                    }

                    New-NetIPAddress @params

                    # Set DNS

                    Set-DnsClientServerAddress -InterfaceIndex $sdnswitchNIC.InterfaceIndex -ServerAddresses ($sdnswitchDNS)

                    # Set VLAN 
 
                    Write-Verbose "Setting VLAN ($sdnswitchVLAN) on host vNIC"

                    $params = @{

                        IsolationMode        = 'Vlan'
                        DefaultIsolationID   = $sdnswitchVLAN 
                        AllowUntaggedTraffic = $true
                        VMNetworkAdapterName = $sdnswitchName

                    }

                    Set-VMNetworkAdapterIsolation -ManagementOS @params

                    # Disable Switch Extensions

                    Get-VMSwitchExtension -VMSwitchName $sdnswitchName | Disable-VMSwitchExtension | Out-Null

                    # Enable Large MTU

                    Write-Verbose "Configuring MTU on all Adapters"
                    Get-NetAdapter | Where-Object {$_.Status -eq "Up"} | Set-NetAdapterAdvancedProperty -RegistryValue $SDNConfig.SDNLABMTU -RegistryKeyword "*JumboPacket"   

                }

                $ErrorActionPreference = "Stop"

                $SDNConfig = $args[0]
                $sdnswitchteammembers = @("FABRIC", "FABRIC2")
                $sdnswitchIP = $SDNConfig.($env:COMPUTERNAME + "IP").Split("/")[0]
                $sdnswitchIPpfx = $SDNConfig.($env:COMPUTERNAME + "IP").Split("/")[1]
                $sdnswitchGW = $SDNConfig.BGPRouterIP_MGMT.Split("/")[0]

                $sdnswitchCheck = Get-VMSwitch | Where-Object {$_.Name -eq "sdnSwitch"}

                if ($sdnswitchCheck) {Write-Warning "Switch already exists on $env:COMPUTERNAME. Skipping this host."}
                else {

                    $params = @{

                        sdnswitchName = 'sdnSwitch'
                        sdnswitchIP = $sdnswitchIP
                        sdnswitchIPpfx = $sdnswitchIPpfx
                        sdnswitchVLAN = $SDNConfig.mgmtVLAN
                        sdnswitchGW = $sdnswitchGW
                        sdnswitchDNS = $SDNConfig.SDNLABDNS
                        sdnswitchteammembers = $sdnswitchteammembers

                    }

                    New-sdnSETSwitch  @params | out-null

                }

            }

            Write-Verbose "Rebooting SDN Host $SDNHost"
            Restart-Computer $SDNHost -Force -Confirm:$false

        }

        # Wait until all the SDNHOSTs have been restarted

        foreach ($SDNHost in $SDNHosts) {

            Write-Verbose "Checking to see if $SDNHOST is up and online"
            while ((Invoke-Command -ComputerName $SDNHost -Credential $domainCred {"Test"} `
                        -ea SilentlyContinue) -ne "Test") {Start-Sleep -Seconds 1}

        }

    }

}

function New-SDNEnvironment {

    Param (

        $domainCred,
        $SDNConfig

    )

    Invoke-Command -ComputerName Console -Credential $domainCred -ScriptBlock {

        Register-PSSessionConfiguration -Name microsoft.SDNNested -RunAsCredential $domainCred -MaximumReceivedDataSizePerCommandMB 1000 -MaximumReceivedObjectSizeMB 1000 | Out-Null

        Invoke-Command -ComputerName localhost -Credential $Using:domainCred -ArgumentList $Using:domainCred, $Using:SDNConfig -ConfigurationName microsoft.SDNNested -ScriptBlock {

            
            $NCConfig = @{}

            $ErrorActionPreference = "Stop"
            $VerbosePreference = "Continue"

            # Set Credential Object

            $domainCred = $args[0]
            $SDNConfig = $args[1]

            # Set fqdn

            $fqdn = $SDNConfig.SDNDomainFQDN

            if ($SDNConfig.ProvisionNC) {

                # Set NC Configuration Data

                $NCConfig.RestName = ("NC01.") + $SDNConfig.SDNDomainFQDN
                $NCConfig.PASubnet = $SDNConfig.ProviderSubnet
                $NCConfig.JoinDomain = $SDNConfig.SDNDomainFQDN
                $NCConfig.ManagementGateway = ($SDNConfig.BGPRouterIP_MGMT).Split("/")[0]
                $NCConfig.PublicVIPSubnet = $SDNConfig.PublicVIPSubnet
                $NCConfig.PrivateVIPSubnet = $SDNConfig.PrivateVIPSubnet
                $NCConfig.GRESubnet = $SDNConfig.GRESubnet
                $NCConfig.LocalAdminDomainUser = ($SDNConfig.SDNDomainFQDN.Split(".")[0]) + "\administrator"
                $NCConfig.DomainJoinUsername = ($SDNConfig.SDNDomainFQDN.Split(".")[0]) + "\administrator"
                $NCConfig.NCUsername = ($SDNConfig.SDNDomainFQDN.Split(".")[0]) + "\administrator"
                $NCConfig.SDNMacPoolStart = "00-1D-D8-B7-1C-09"
                $NCConfig.SDNMacPoolEnd = "00:1D:D8:B7:1F:FF"
                $NCConfig.PAGateway = ($SDNConfig.BGPRouterIP_ProviderNetwork.TrimEnd("1/24")) + "1"
                $NCConfig.PAPoolStart = ($SDNConfig.BGPRouterIP_ProviderNetwork.TrimEnd("1/24")) + "5"
                $NCConfig.PAPoolEnd = ($SDNConfig.BGPRouterIP_ProviderNetwork.TrimEnd("1/24")) + "254"
                $NCConfig.Capacity = "10000"
                $NCConfig.ScriptVersion = "2.0"
                $NCConfig.SDNASN = $SDNConfig.SDNASN
                $NCConfig.ManagementVLANID = $SDNConfig.mgmtVLAN
                $NCConfig.PAVLANID = $SDNConfig.providerVLAN
                $NCConfig.PoolName = "DefaultAll"
                $NCConfig.VMLocation = "D:\SDNVMS"
                $NCConfig.VHDFile = "Core.vhdx"
                $NCConfig.VHDPath = "C:\VHDS"
                $NCConfig.ManagementSubnet = $SDNConfig.MGMTSubnet
                $NCConfig.iDNSIPAddress = $SDNConfig.SDNLABDNS
                $NCConfig.iDNSMacAddress = “aa-bb-cc-aa-bb-cc”
                $NCConfig.TimeZone = (Get-TimeZone).id

                $NCConfig.HyperVHosts = @("sdnhost1.$fqdn", "sdnhost2.$fqdn", "sdnhost3.$fqdn" )

                $NCConfig.ManagementDNS = @(
                    ($SDNConfig.BGPRouterIP_MGMT.Split("/")[0].TrimEnd("1")) + "254"
                ) 

                $NCConfig.Muxes = @(

                    @{
                        ComputerName = 'Mux01'
                        HostName     = "sdnhost3.$($SDNConfig.SDNDomainFQDN)"
                        ManagementIP = ($SDNConfig.BGPRouterIP_MGMT.TrimEnd("1/24")) + "61"
                        MACAddress   = '00-1D-D8-B7-1C-01'
                        PAIPAddress  = ($SDNConfig.BGPRouterIP_ProviderNetwork.TrimEnd("1/24")) + "4"
                        PAMACAddress = '00-1D-D8-B7-1C-02'
                    }

                )

                $NCConfig.Gateways = @(

                    @{
                        ComputerName = "GW01"
                        ManagementIP = ($SDNConfig.BGPRouterIP_MGMT.TrimEnd("1/24")) + "62"
                        HostName     = "sdnhost2.$($SDNConfig.SDNDomainFQDN)"
                        FrontEndIP   = ($SDNConfig.BGPRouterIP_ProviderNetwork.TrimEnd("1/24")) + "5"
                        MACAddress   = "00-1D-D8-B7-1C-03"
                        FrontEndMac  = "00-1D-D8-B7-1C-04"
                        BackEndMac   = "00-1D-D8-B7-1C-05"
                    },

                    @{
                        ComputerName = "GW02"
                        ManagementIP = ($SDNConfig.BGPRouterIP_MGMT.TrimEnd("1/24")) + "63"
                        HostName     = "sdnhost1.$($SDNConfig.SDNDomainFQDN)"
                        FrontEndIP   = ($SDNConfig.BGPRouterIP_ProviderNetwork.TrimEnd("1/24")) + "6"
                        MACAddress   = "00-1D-D8-B7-1C-06"
                        FrontEndMac  = "00-1D-D8-B7-1C-07"
                        BackEndMac   = "00-1D-D8-B7-1C-08"
                    }

                )

                $NCConfig.NCs = @{

                    MACAddress   = "00:1D:D8:B7:1C:00"
                    ComputerName = "NC01"
                    HostName     = "sdnhost2.$($SDNConfig.SDNDomainFQDN)"
                    ManagementIP = ($SDNConfig.BGPRouterIP_MGMT.TrimEnd("1/24")) + "60"

                }

                $NCConfig.Routers = @(

                    @{

                        RouterASN       = $SDNConfig.BGPRouterASN
                        RouterIPAddress = ($SDNConfig.BGPRouterIP_ProviderNetwork).Split("/")[0]

                    }

                )

                # Start SDNExpress (Nested Version) Install

                Set-Location -Path 'C:\SCRIPTS\SDNExpress-Custom'

                $params = @{

                    ConfigurationData    = $NCConfig
                    DomainJoinCredential = $domainCred
                    LocalAdminCredential = $domainCred
                    NCCredential         = $domainCred

                }

                .\SDNExpress.ps1 @params

            }

        } -Authentication Credssp

        # Set Constrained Delegation for NC/MUX/GW Virtual Machines for Windows Admin Center

        $SDNvms = ("NC01", "MUX01", "GW01", "GW02")
     
        foreach ($SDNvm in $SDNvms) {

            Write-Verbose "Setting Delegation for $SDNvm"
            $gateway = "AdminCenter"
            $node = $SDNvm
            $gatewayObject = Get-ADComputer -Identity $gateway
            $nodeObject = Get-ADComputer -Identity $node
            Set-ADComputer -Identity $nodeObject -PrincipalsAllowedToDelegateToAccount $gatewayObject

        }

    } 

}

function Delete-SDNSandbox {

    param (

        $localCred,
        $SDNConfig

    )

$VerbosePreference = "Continue"

Write-Verbose "Deleting SDNSandbox"

# Get VM Placement

if ($SDNConfig.MultipleHyperVHosts) {

$VMPlacement = Select-VMHostPlacement -MultipleHyperVHosts $SDNConfig.MultipleHyperVHostNames  -SDNHosts $SDNHosts

}

elseif (!$SDNConfig.MultipleHyperVHosts) {

$VMPlacement = Select-SingleHost -SDNHosts $SDNHosts

}

foreach ($vm in $VMPlacement) {

Invoke-Command -ComputerName $vm.VMHost -Credential $localCred -ArgumentList $vm.SDNHOST -ScriptBlock {

Import-Module Hyper-V

$VerbosePreference = "Continue"
$vmname = $Using:vm.SDNHOST

$sdnvm = Get-VM | Where-Object {$_.Name -eq $vmname }

If (!$sdnvm) {Write-Verbose "Could not find $vmname to delete"}

if ($sdnvm) {

Write-Verbose "Shutting down VM: $sdnvm)"

Stop-VM -VM $sdnvm -TurnOff -Force -Confirm:$false 
$VHDs = $sdnvm | Select-Object VMId  | Get-VHD
Remove-VM -VM $sdnvm -Force -Confirm:$false 

foreach ($VHD in $VHDs) {

Write-Verbose "Removing $($VHD.Path)"
Remove-Item -Path $VHD.Path -Force -Confirm:$false

}

}


}


}

}

function Add-WACtenants {

param (

$SDNLabSystems,
$SDNConfig,
$domainCred

)

Write-Verbose "Invoking Command to add Windows Admin Center Tenants"

 Invoke-Command -ComputerName AdminCenter -Credential $domainCred -ScriptBlock {

 $domainCred = $using:domainCred
 $SDNLabSystems = $using:SDNLabSystems
 $SDNConfig = $using:SDNConfig
 
 $VerbosePreference = "Continue"

            foreach ($SDNLabSystem in $SDNLabSystems) {


            $json = [pscustomobject]@{

            id = "msft.sme.connection-type.server!$SDNLabSystem"
            name = $SDNLabSystem
            type = "msft.sme.connection-type.server"

            } | ConvertTo-Json


$payload = @"
[
$json
]
"@

            if ($SDNConfig.WACport -eq "443" -or !$SDNConfig.WACport) {

            $uri = "https://admincenter.$($SDNConfig.SDNDomainFQDN)/api/connections"

            }

            else {

            $uri = "https://admincenter.$($SDNConfig.SDNDomainFQDN):$($SDNConfig.WACport)/api/connections"

            }

            Write-Verbose "Adding Host: $SDNLabSystem"


            $param = @{

            Uri = $uri
            Method = 'Put'
            Body = $payload
            ContentType = $content
            Credential = $domainCred

            }

            Invoke-RestMethod @param -UseBasicParsing -DisableKeepAlive  | Out-Null

   
            }          

}

}

function New-SDNS2DCluster {

param (
        $SDNConfig,
        $domainCred,
        $SDNClusterNode

        )

        $VerbosePreference = "Continue" 
                
        Invoke-Command -ComputerName $SDNClusterNode -ArgumentList $SDNConfig, $domainCred -Credential $domainCred -ScriptBlock {
         
         $SDNConfig = $args[0]
         $domainCred = $args[1]
         $VerbosePreference = "Continue"
         $ErrorActionPreference = "Stop"


        Register-PSSessionConfiguration -Name microsoft.SDNNestedS2D -RunAsCredential $domainCred -MaximumReceivedDataSizePerCommandMB 1000 -MaximumReceivedObjectSizeMB 1000 | Out-Null

        Invoke-Command -ComputerName $Using:SDNClusterNode -ArgumentList $SDNConfig, $domainCred -Credential $domainCred -ConfigurationName microsoft.SDNNestedS2D -ScriptBlock {

         $SDNConfig = $args[0]
         $domainCred = $args[1]

        # Create S2D Cluster

        $SDNConfig = $args[0]
        $SDNHosts = @("SDNHOST1", "SDNHOST2", "SDNHOST3")

        Write-Verbose "Creating Cluster: SDNCLUSTER"

        $VerbosePreference = "SilentlyContinue"

        Import-Module FailoverClusters 

        $VerbosePreference = "Continue"

        $ClusterIP = ($SDNConfig.MGMTSubnet.TrimEnd("0/24")) + "253"
        $ClusterName = "SDNCLUSTER"

        # Create Cluster

        New-Cluster -Name $ClusterName -Node $SDNHosts -StaticAddress $ClusterIP `
            -NoStorage -WarningAction SilentlyContinue | Out-Null

        # Invoke Command to enable S2D on SDNCluster        

            Enable-ClusterS2D -CacheState Disabled -AutoConfig:0 -SkipEligibilityChecks -Confirm:$false  | Out-Null

            $params = @{

                StorageSubSystemFriendlyName = "*Clustered*"
                FriendlyName                 = 'SDN_S2D_Storage'
                ProvisioningTypeDefault      = 'Fixed'
                ResiliencySettingNameDefault = 'Simple'
                WriteCacheSizeDefault        = 0
            }

            New-StoragePool @params -PhysicalDisks (Get-PhysicalDisk | Where-Object {$_.CanPool -eq $true})  | Out-Null

            Get-PhysicalDisk | Where-Object {$_.Size -lt 127GB} | Set-PhysicalDisk -MediaType HDD | Out-Null

            $params = @{
            
                FriendlyName            = "S2D_vDISK1" 
                FileSystem              = 'CSVFS_ReFS'
                StoragePoolFriendlyName = 'SDN_S2D_Storage'
                ResiliencySettingName   = 'Parity'
                PhysicalDiskRedundancy  = 1
                
            }

            New-Volume @params -UseMaximumSize  | Out-Null

            # Set Virtual Environment Optimizations

            Get-storagesubsystem clus* | set-storagehealthsetting -name “System.Storage.PhysicalDisk.AutoReplace.Enabled” -value “False”
            Set-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Services\spaceport\Parameters -Name HwTimeout -Value 0x00007530

            }

        } 


        Invoke-Command -ComputerName Console -Credential $domainCred -ScriptBlock {


         $VerbosePreference = "Continue"
         $ErrorActionPreference = "Stop"
       
        # Set Kerberos Delegation for Admin Center

        $SDNHosts = ("SDNCLUSTER", "SDNHOST1", "SDNHOST2", "SDNHOST3", "CONSOLE")
     
        foreach ($SDNHost in $SDNHosts) {

            Write-Verbose "Setting Delegation for $SDNHOST"
            $gateway = "AdminCenter"
            $node = $SDNHost
            $gatewayObject = Get-ADComputer -Identity $gateway
            $nodeObject = Get-ADComputer -Identity $node
            Set-ADComputer -Identity $nodeObject -PrincipalsAllowedToDelegateToAccount $gatewayObject

        }
        # Set Default Path's in Hyper-V on the SDN Hosts

        $ClusterHosts = ("SDNHOST1", "SDNHOST2", "SDNHOST3")
            
        foreach ($SDNHost in $ClusterHosts) {

            Write-Verbose "Setting VM Path on $SDNHost"
         
            Invoke-Command -ComputerName $SDNHost -ScriptBlock {

                $OSver = Get-WmiObject Win32_OperatingSystem | Where-Object {$_.Name -match "Windows Server 2019"}

                if ($OSVer) {$csvfolder = "S2D_vDISK1"}
                else {$csvfolder = "Volume1"}

                # Install SDDC if not installed

                $SDDC = Get-ClusterResource | Where-Object {$_.Name -eq "SDDC Management"}
                if (!$SDDC) {

                    Write-Verbose "Attempting to add the SDDC Management Resource"

                    $params = @{

                        Name        = 'SDDC Management' 
                        dll         = "$env:SystemRoot\Cluster\sddcres.dll"
                        DisplayName = 'SDDC Management'
                        ErrorAction = 'Ignore'

                    }

                    Add-ClusterResourceType @params | Out-Null
                }

                # Move volume to get around mount point issues

                $VerbosePreference = "Continue"
                Write-Verbose "Moving disk to $env:COMPUTERNAME"
                Get-ClusterSharedVolume | Move-ClusterSharedVolume -Node $env:COMPUTERNAME | Out-Null

                $testpath = $false
                While (!$testpath) {

                    Write-Verbose "Testing to see if CSV is online and functional..."
                    Start-Sleep -seconds 10

                    $testpath = Test-Path "C:\ClusterStorage\$csvfolder"

                }

                Set-VMHost -VirtualHardDiskPath "C:\ClusterStorage\$csvfolder" -VirtualMachinePath "C:\ClusterStorage\$csvfolder"

            }
        }


        }



}

#endregion
   
#region Main
    
$WarningPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"    
    
# Import Configuration Module

$SDNConfig = Import-PowerShellDataFile -Path $ConfigurationDataFile
Copy-Item $ConfigurationDataFile -Destination .\Applications\SCRIPTS -Force

# Set-Credentials
$localCred = new-object -typename System.Management.Automation.PSCredential `
    -argumentlist "Administrator", (ConvertTo-SecureString $SDNConfig.SDNAdminPassword -AsPlainText -Force)

$domainCred = new-object -typename System.Management.Automation.PSCredential `
    -argumentlist (($SDNConfig.SDNDomainFQDN.Split(".")[0]) + "\Administrator"), `
     (ConvertTo-SecureString $SDNConfig.SDNAdminPassword  -AsPlainText -Force)

$NCAdminCred = new-object -typename System.Management.Automation.PSCredential `
    -argumentlist (($SDNConfig.SDNDomainFQDN.Split(".")[0]) + "\NCAdmin"), `
     (ConvertTo-SecureString $SDNConfig.SDNAdminPassword  -AsPlainText -Force)

$NCClientCred = new-object -typename System.Management.Automation.PSCredential `
    -argumentlist (($SDNConfig.SDNDomainFQDN.Split(".")[0]) + "\NCClient"), `
     (ConvertTo-SecureString $SDNConfig.SDNAdminPassword  -AsPlainText -Force)


# Delete configuration if specified

if ($Delete) {

$VerbosePreference = "Continue"

Delete-SDNSandbox  -localCred $localCred -SDNConfig $SDNConfig

Write-Verbose "Successfully Removed the SDN Sandbox"
exit

}
    
# Set Variables from config file

$NestedVMMemoryinGB = $SDNConfig.NestedVMMemoryinGB
$guiVHDXPath = $SDNConfig.guiVHDXPath
$coreVHDXPath = $SDNConfig.coreVHDXPath
$consoleVHDXPath = $SDNConfig.consoleVHDXPath
$HostVMPath = $SDNConfig.HostVMPath
$InternalSwitch = $SDNConfig.InternalSwitch
$natDNS = $SDNConfig.natDNS
$natSubnet = $SDNConfig.natSubnet
$natExternalVMSwitchName = $SDNConfig.natExternalVMSwitchName
$natVLANID = $SDNConfig.natVLANID
$natConfigure = $SDNConfig.natConfigure    
    
# Define SDN host Names. Please do not change names as these names are hardcoded in the setup.

$SDNHosts = @("SDNMGMT", "SDNHOST1", "SDNHOST2", "SDNHOST3")

$VerbosePreference = "SilentlyContinue" 
Import-Module Hyper-V 
$VerbosePreference = "Continue"
$ErrorActionPreference = "Stop"
    
# Verify Applications

Resolve-Applications -SDNConfig $SDNConfig
    
# if single host installation, set up installation parameters

if (!$SDNConfig.MultipleHyperVHosts) {

    Write-Verbose "No Multiple Hyper-V Hosts defined. Using Single Hyper-V Host Installation"
    Write-Verbose "Testing VHDX Path"

    $params = @{

        guiVHDXPath = $guiVHDXPath
        coreVHDXPath = $coreVHDXPath
    
    }

    Test-VHDPath @params

    Write-Verbose "Generating Single Host Placement"

    $VMPlacement = Select-SingleHost -SDNHosts $SDNHosts

    Write-Verbose "Creating Internal Switch"

    $params = @{

        pswitchname = $InternalSwitch
        SDNConfig = $SDNConfig
    
    }

    New-InternalSwitch @params

    $VMSwitch = $InternalSwitch

    Write-Verbose "Getting local Parent VHDX Path"

    $params = @{

        guiVHDXPath = $guiVHDXPath
        HostVMPath = $HostVMPath
    
    }


    $ParentVHDXPath = Get-guiVHDXPath @params

    Set-LocalHyperVSettings -HostVMPath $HostVMPath

    $params = @{

        coreVHDXPath = $coreVHDXPath
        HostVMPath = $HostVMPath
    
    }

    $coreParentVHDXPath = Get-CoreVHDXPath @params

    $params = @{

        consoleVHDXPath = $consoleVHDXPath
        HostVMPath = $HostVMPath
    
    }

    $consoleParentVHDXPath = Get-ConsoleVHDXPath @params

}
    
# if multiple host installation, set up installation parameters

if ($SDNConfig.MultipleHyperVHosts) {

    Write-Verbose "Multiple Hyper-V Hosts defined. Using Mutiple Hyper-V Host Installation"
    Get-PhysicalNICMTU -SDNConfig $SDNConfig

    $params = @{

        MultipleHyperVHosts = $SDNConfig.MultipleHyperVHostNames
        HostVMPath          = $HostVMPath
        
    }

    Get-HyperVHosts @params

    Write-Verbose "Testing VHDX Path"

    $params = @{

        guiVHDXPath     = $guiVHDXPath
        coreVHDXPath    = $coreVHDXPath
        consoleVHDXPath = $consoleVHDXPath
    
    }


    Test-VHDPath @params

    Write-Verbose "Generating Multiple Host Placement"

    $params = @{

        MultipleHyperVHosts = $SDNConfig.MultipleHyperVHostNames
        SDNHosts            = $SDNHosts
    }

    $VMPlacement = Select-VMHostPlacement @params

    Write-Verbose "Getting local Parent VHDX Path"

    $params = @{

        guiVHDXPath = $guiVHDXPath
        HostVMPath  = $HostVMPath
    
    }

    $ParentVHDXPath = Get-guiVHDXPath @params

    $params = @{

        MultipleHyperVHosts = $MultipleHyperVHosts
        HostVMPath          = $HostVMPath
    
    }

    Set-HyperVSettings @params


    $params = @{

        coreVHDXPath = $coreVHDXPath
        HostVMPath   = $HostVMPath
    
    }


    $coreParentVHDXPath = Get-CoreVHDXPath @params

    $params = @{

        consoleVHDXPath = $consoleVHDXPath
        HostVMPath      = $HostVMPath
    
    }

    $consoleParentVHDXPath = Get-ConsoleVHDXPath @params

    $VMSwitch = $SDNConfig.MultipleHyperVHostExternalSwitchName

    Write-Verbose "Creating vNIC on $env:COMPUTERNAME"
    New-HostvNIC -SDNConfig $SDNConfig

}
    
    
# if multiple host installation, copy the parent VHDX file to the specified Parent VHDX Path

if ($SDNConfig.MultipleHyperVHosts) {

    Write-Verbose "Copying VHDX Files to Host"

    $params = @{

        MultipleHyperVHosts = $SDNConfig.MultipleHyperVHostNames
        coreVHDXPath        = $coreVHDXPath
        HostVMPath          = $HostVMPath
        guiVHDXPath         = $guiVHDXPath 
        consoleVHDXPath     = $consoleVHDXPath
    }

    Copy-VHDXtoHosts @params
}
    
    
# if single host installation, copy the parent VHDX file to the specified Parent VHDX Path

if (!$SDNConfig.MultipleHyperVHosts) {

    Write-Verbose "Copying VHDX Files to Host"

    $params = @{

        coreVHDXPath    = $coreVHDXPath
        HostVMPath      = $HostVMPath
        guiVHDXPath     = $guiVHDXPath 
        consoleVHDXPath = $consoleVHDXPath
    }

    Copy-VHDXtoHost @params
}
    
    
# Create Virtual Machines

foreach ($VM in $VMPlacement) {

    Write-Verbose "Generating the VM: $VM" 

    $params = @{

        VMHost     = $VM.VMHost
        SDNHost    = $VM.SDNHOST
        HostVMPath = $HostVMPath
        VMSwitch   = $VMSwitch
        SDNConfig  = $SDNConfig

    }

    New-NestedVM @params
    
}
    
# Inject Answer Files and Binaries into Virtual Machines

$params = @{

    VMPlacement = $VMPlacement
    HostVMPath  = $HostVMPath
    SDNConfig   = $SDNConfig
}

Add-Files @params
    
# Start Virtual Machines

Start-SDNHOSTS -VMPlacement $VMPlacement
    
# Wait for SDNHosts to come online

Write-Verbose "Waiting for VMs to provision and then come online"

$params = @{

    VMPlacement = $VMPlacement
    localcred   = $localCred

}

Test-SDNHostVMConnection @params
    
# Online and Format Data Volumes on Virtual Machines

$params = @{

    VMPlacement = $VMPlacement
    SDNConfig   = $SDNConfig
    localcred   = $localCred

}

New-DataDrive @params
    
# Install SDN Host Software on NestedVMs

$params = @{

    SDNConfig   = $SDNConfig
    VMPlacement = $VMPlacement
    localcred   = $localCred

}

Set-SDNserver @params
    
# Rename NICs from Ethernet to FABRIC

$params = @{

    scriptpath  = "Get-Netadapter Ethernet | Rename-NetAdapter -NewName FABRIC"
    VMPlacement = $VMPlacement
    localcred   = $localCred

}

Start-PowerShellScriptsOnHosts @params

$params.scriptpath = "Get-Netadapter 'Ethernet 2' | Rename-NetAdapter -NewName FABRIC2"

Start-PowerShellScriptsOnHosts @params
    
# Restart Machines

$params.scriptpath = "Restart-Computer -Force"
Start-PowerShellScriptsOnHosts @params
Start-Sleep -Seconds 30
    
# Wait for SDNHosts to come online

Write-Verbose "Waiting for VMs to restart..."

$params = @{

    VMPlacement = $VMPlacement
    localcred = $localCred

}

Test-SDNHostVMConnection @params
    
# This step has to be done as during the Hyper-V install as hosts reboot twice.

Write-Verbose "Ensuring that all VMs have been restarted after Hyper-V install.."
Test-SDNHostVMConnection @params
    
# Create NAT Virtual Switch on SDNMGMT

if ($natConfigure) {

    if (!$SDNConfig.MultipleHyperVHosts) {$SwitchName = $SDNConfig.InternalSwitch}
    else {$SwitchName = $SDNConfig.MultipleHyperVHostExternalSwitchName}
    
    Write-Verbose "Creating NAT Switch on switch $SwitchName"
    $VerbosePreference = "SilentlyContinue"

    $params = @{

        SwitchName  = $SwitchName
        VMPlacement = $VMPlacement
        SDNConfig   = $SDNConfig
    }

    New-NATSwitch  @params
    $VerbosePreference = "Continue"

}
    
# Provision SDNMGMT VMs (DC, Router, AdminCenter, and console)

Write-Host  "Configuring Management VM" 

$params = @{

    SDNConfig  = $SDNConfig
    localCred  = $localCred
    domainCred = $domainCred

}

Set-SDNMGMT @params

# Provision Hyper-V Logical Switches and Create S2D Cluster on Hosts

$params = @{

    localCred  = $localCred
    domainCred = $domainCred

}

New-HyperConvergedEnvironment @params


# Create S2D Cluster

$params = @{

SDNConfig = $SDNConfig
DomainCred = $domainCred
SDNClusterNode = 'SDNHOST2'

}


New-SDNS2DCluster @params



# Install Network Controller (Custom SDN Express Script)

$params = @{

    SDNConfig  = $SDNConfig
    domainCred = $domainCred

}

New-SDNEnvironment @params

# Add Systems to Windows Admin Center

$fqdn = $SDNConfig.SDNDomainFQDN

$SDNLabSystems = @("bgp-tor-router", "$($SDNConfig.DCName).$fqdn", "NC01.$fqdn", "MUX01.$fqdn", "GW01.$fqdn", "GW02.$fqdn", "SDNMGMT")

# Add VMs for Domain Admin

$params = @{

    SDNLabSystems = $SDNLabSystems 
    SDNConfig     = $SDNConfig
    domainCred    = $domainCred

}

Add-WACtenants @params

# Add VMs for NC Admin

$params.domainCred = $NCAdminCred

Add-WACtenants @params




Write-Verbose "`nSuccessfully deployed SDNSandbox"
 
$ErrorActionPreference = "Continue"
$VerbosePreference = "SilentlyContinue"
$WarningPreference = "Continue"
    
#endregion    