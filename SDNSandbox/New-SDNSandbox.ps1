﻿<#
.SYNOPSIS 
    Deploys and configures a minimal Microsoft SDN infrastructure in a Hyper-V
    Nested Environment for training purposes. This deployment method is not
    supported for production purposes.

.EXAMPLE
    .\New-SDNSandbox.ps1
    Reads in the configuration from SDNSandbox-Config.psd1 that contains a hash table 
    of settings data that will in same root as New-SDNSandbox.ps1
  
.EXAMPLE
    .\New-SDNSandbox.ps1 -Delete $true
     Removes the VMs and VHDs of the Azure Stack HCI Sandbox installation. (Note: Some files will
     remain after deletion.)

.NOTES
    Prerequisites:

    * All Hyper-V hosts must have Hyper-V enabled and the Virtual Switch 
    already created with the same name (if using Multiple Hosts). If you are
    using a single host, a Internal VM Switch will be created.

    * 250gb minimum of hard drive space if a single host installation. 150GB 
      minimum of drive space per Hyper-V host if using multiple hosts.

    * 256gb RAM - This can be tweaked, but this script was developed on a 128GB system,

    * If you wish the environment to have internet access, create a Hyper-V VMswitch on
       your host that maps to a NIC on a network that has internet access. 
       The network should use DHCP.

    * 2 VHDX (GEN2) files will need to be specified. 

        1. GUI.VHDX - Sysprepped Desktop Experience version of Windows Server 2025
           Standard/Datacenter.

        2. CORE.VHDX - Generalized\ version of Windows Server 2025 Datacenter Core. 
          

    * The SDNSandbox-Config.psd1 will need to be edited to include product keys for the
      installation media. If using VL Media, you can use a 2025 cient KMS key for the product 
      key. Additionally,      please ensure that the NAT settings are filled in to specify the
      Hyper-V switch allowing internet access.
          
#>



[CmdletBinding(DefaultParameterSetName = "NoParameters")]

param(
    [Parameter(Mandatory = $true, ParameterSetName = "ConfigurationFile")]
    [String] $ConfigurationDataFile = '.\SDNSandbox-Config.psd1',
    [Parameter(Mandatory = $false, ParameterSetName = "Delete")]
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
        if (!$testconnection) { Write-Error "Failed to ping $HypervHost"; break }
    
        # Check Hyper-V Host 
        $HypHost = Get-VMHost -ComputerName $HypervHost -ErrorAction Ignore
        if ($HypHost) { Write-Verbose "$HypervHost Hyper-V Connectivity verified" }
        if (!$HypHost) { Write-Error "Cannot connect to hypervisor on system $HypervHost"; break }
    
        # Check HostVMPath
        $DriveLetter = $HostVMPath.Split(':')
        $testpath = Test-Path (("\\$HypervHost\") + ($DriveLetter[0] + "$") + ($DriveLetter[1])) -ErrorAction Ignore
        if ($testpath) { Write-Verbose "$HypervHost's $HostVMPath path verified" }
        if (!$testpath) { Write-Error "Cannot connect to $HostVMPath on system $HypervHost"; break }

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
    
        New-VMSwitch -SwitchType Internal -MinimumBandwidthMode None -Name $pswitchname | Out-Null
    
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
    
    Else { Write-Verbose "Internal Switch $pswitchname already exists. Not creating a new internal switch." }
    
}
    
function New-HostvNIC {
    
    param (

        $SDNConfig,
        $localCred
    )

    $ErrorActionPreference = "Stop"

    $SBXIP = 250

    foreach ($SDNSwitchHost in $SDNConfig.MultipleHyperVHostNames) {

        Write-Verbose "Creating vNIC on $SDNSwitchHost"

        Invoke-Command -ComputerName $SDNSwitchHost -ArgumentList $SDNConfig, $SBXIP -ScriptBlock {

            $SDNConfig = $args[0]
            $SBXIP = $args[1]

            $vnicName = $SDNConfig.MultipleHyperVHostExternalSwitchName + "-SBXAccess"
    

            $params = @{

                SwitchName = $SDNConfig.MultipleHyperVHostExternalSwitchName
                Name       = $vnicName

            }
    
            Add-VMNetworkAdapter -ManagementOS @params | Out-Null
            

            Set-VMNetworkAdapterVlan -ManagementOS -Trunk -NativeVlanId 0 -AllowedVlanIdList 1-200
  
            $IP = ($SDNConfig.MGMTSubnet.TrimEnd("0/24")) + $SBXIP
            $prefix = $SDNConfig.MGMTSubnet.Split("/")[1]
            $gateway = $SDNConfig.BGPRouterIP_MGMT.TrimEnd("/24")
            $DNS = $SDNConfig.SDNLABDNS

            $NetAdapter = Get-NetAdapter | Where-Object { $_.Name -match $vnicName }[0]

            $params = @{

                AddressFamily  = "IPv4"
                IPAddress      = $IP
                PrefixLength   = $Prefix
                DefaultGateway = $Gateway
            
            }

            $NetAdapter | New-NetIPAddress @params | Out-Null
            $NetAdapter | Set-DnsClientServerAddress -ServerAddresses $DNS | Out-Null

        }

        $SBXIP--
    
    }
    
}
    
function Test-VHDPath {

    Param (

        $guiVHDXPath,
        $coreVHDXPath
    )

    $Result = Get-ChildItem -Path $guiVHDXPath -ErrorAction Ignore  
    if (!$result) { Write-Host "Path $guiVHDXPath was not found!" -ForegroundColor Red ; break }
    $Result = Get-ChildItem -Path $coreVHDXPath -ErrorAction Ignore  
    if (!$result) { Write-Host "Path $coreVHDXPath was not found!" -ForegroundColor Red ; break }

}
    
function Select-VMHostPlacement {
    
    Param($MultipleHyperVHosts, $sdnHOSTs)    
    
    $results = @()
    
    Write-Host "Note: if using a NAT switch for internet access, please choose the host that has the external NAT Switch for VM: SDNMGMT." `
        -ForegroundColor Yellow
    
    foreach ($sdnHOST in $sdnHOSTs) {
    
        Write-Host "`nOn which server should I put $sdnHOST ?" -ForegroundColor Green
    
        $i = 0
        foreach ($HypervHost in $MultipleHyperVHosts) {
    
            Write-Host "`n $i. Hyper-V Host: $HypervHost" -ForegroundColor Yellow
            $i++
        }
    
        $MenuOption = Read-Host "`nSelect the Hyper-V Host and then press Enter" 
    
        $results = $results + [pscustomobject]@{SDNHOST = $sdnHOST; VMHost = $MultipleHyperVHosts[$MenuOption] }
    
    }
    
    return $results
     
}
    
function Select-SingleHost {

    Param (

        $sdnHOSTs

    )

    $results = @()
    foreach ($sdnHOST in $sdnHOSTs) {

        $results = $results + [pscustomobject]@{SDNHOST = $sdnHOST; VMHost = $env:COMPUTERNAME }
    }

    Return $results

}
    
function Copy-VHDXtoHosts {

    Param (

        $MultipleHyperVHosts, 
        $guiVHDXPath, 
        $coreVHDXPath, 
        $HostVMPath

    )
        
    foreach ($HypervHost in $MultipleHyperVHosts) { 

        $DriveLetter = $HostVMPath.Split(':')
        $path = (("\\$HypervHost\") + ($DriveLetter[0] + "$") + ($DriveLetter[1]))
        Write-Verbose "Copying $guiVHDXPath to $path"
        Copy-Item -Path $guiVHDXPath -Destination "$path\GUI.vhdx" -Force | Out-Null
        Write-Verbose "Copying $coreVHDXPath to $path"
        Copy-Item -Path $coreVHDXPath -Destination "$path\Core.vhdx" -Force | Out-Null

    }
}
    
function Copy-VHDXtoHost {

    Param (

        $guiVHDXPath, 
        $HostVMPath, 
        $coreVHDXPath

    )

    Write-Verbose "Copying $guiVHDXPath to $HostVMPath\GUI.VHDX"
    Copy-Item -Path $guiVHDXPath -Destination "$HostVMPath\GUI.VHDX" -Force | Out-Null
    Write-Verbose "Copying $coreVHDXPath to $HostVMPath\CORE.VHDX"
    Copy-Item -Path $coreVHDXPath -Destination "$HostVMPath\CORE.VHDX" -Force | Out-Null

      
    
}
    
function Get-guiVHDXPath {
    
    Param (

        $guiVHDXPath, 
        $HostVMPath

    )

    $ParentVHDXPath = $HostVMPath + 'GUI.vhdx'
    return $ParentVHDXPath

}
    
function Get-coreVHDXPath {

    Param (

        $coreVHDXPath, 
        $HostVMPath

    )

    $ParentVHDXPath = $HostVMPath + 'CORE.vhdx'
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

        $sdnHOST, 
        $VMHost, 
        $HostVMPath, 
        $VMSwitch,
        $SDNConfig

    )
    
   
    $parentpath = "$HostVMPath\GUI.vhdx"
    $coreparentpath = "$HostVMPath\CORE.vhdx"

    $vmMac = Invoke-Command -ComputerName $VMHost -ScriptBlock {    

        $VerbosePreference = "SilentlyContinue"

        Import-Module Hyper-V

        $VerbosePreference = "Continue"

        $sdnHOST = $using:SDNHOST
        $VMHost = $using:VMHost        
        $HostVMPath = $using:HostVMPath
        $VMSwitch = $using:VMSwitch
        $parentpath = $using:parentpath
        $coreparentpath = $using:coreparentpath
        $SDNConfig = $using:SDNConfig                         
        $S2DDiskSize = $SDNConfig.S2D_Disk_Size
        $NestedVMMemoryinGB = $SDNConfig.NestedVMMemoryinGB
        $sdnMGMTMemoryinGB = $SDNConfig.sdnMGMTMemoryinGB
    
        # Create Differencing Disk. Note: SDNMGMT is GUI

        if ($sdnHOST -eq "SDNMGMT") {

            $VHDX1 = New-VHD -ParentPath $parentpath -Path "$HostVMPath\$sdnHOST.vhdx" -Differencing
            Write-Verbose -Message "Resizing OS DISK"
            Resize-VHD -Path "$HostVMPath\$sdnHOST.vhdx" -SizeBytes 130GB           
             
            $VHDX2 = New-VHD -Path "$HostVMPath\$sdnHOST-Data.vhdx" -SizeBytes 268435456000 -Dynamic
            $NestedVMMemoryinGB = $sdnMGMTMemoryinGB
        }
    
        Else { 
           
            $VHDX1 = New-VHD -ParentPath $coreparentpath -Path "$HostVMPath\$sdnHOST.vhdx" -Differencing 
            $VHDX2 = New-VHD -Path "$HostVMPath\$sdnHOST-Data.vhdx" -SizeBytes 268435456000 -Dynamic
    
            # Create S2D Storage       

            New-VHD -Path "$HostVMPath\$sdnHOST-S2D_Disk1.vhdx" -SizeBytes $S2DDiskSize -Dynamic | Out-Null
            New-VHD -Path "$HostVMPath\$sdnHOST-S2D_Disk2.vhdx" -SizeBytes $S2DDiskSize -Dynamic | Out-Null
            New-VHD -Path "$HostVMPath\$sdnHOST-S2D_Disk3.vhdx" -SizeBytes $S2DDiskSize -Dynamic | Out-Null
            New-VHD -Path "$HostVMPath\$sdnHOST-S2D_Disk4.vhdx" -SizeBytes $S2DDiskSize -Dynamic | Out-Null
            New-VHD -Path "$HostVMPath\$sdnHOST-S2D_Disk5.vhdx" -SizeBytes $S2DDiskSize -Dynamic | Out-Null
            New-VHD -Path "$HostVMPath\$sdnHOST-S2D_Disk6.vhdx" -SizeBytes $S2DDiskSize -Dynamic | Out-Null    
    
        }    
    
        #Create Nested VM

        $params = @{

            Name               = $sdnHOST
            MemoryStartupBytes = $NestedVMMemoryinGB 
            VHDPath            = $VHDX1.Path 
            SwitchName         = $VMSwitch
            Generation         = 2

        }

        New-VM @params | Out-Null
        Add-VMHardDiskDrive -VMName $sdnHOST -Path $VHDX2.Path
    
        if ($sdnHOST -ne "SDNMGMT") {

            Add-VMHardDiskDrive -Path "$HostVMPath\$sdnHOST-S2D_Disk1.vhdx" -VMName $sdnHOST | Out-Null
            Add-VMHardDiskDrive -Path "$HostVMPath\$sdnHOST-S2D_Disk2.vhdx" -VMName $sdnHOST | Out-Null
            Add-VMHardDiskDrive -Path "$HostVMPath\$sdnHOST-S2D_Disk3.vhdx" -VMName $sdnHOST | Out-Null
            Add-VMHardDiskDrive -Path "$HostVMPath\$sdnHOST-S2D_Disk4.vhdx" -VMName $sdnHOST | Out-Null
            Add-VMHardDiskDrive -Path "$HostVMPath\$sdnHOST-S2D_Disk5.vhdx" -VMName $sdnHOST | Out-Null
            Add-VMHardDiskDrive -Path "$HostVMPath\$sdnHOST-S2D_Disk6.vhdx" -VMName $sdnHOST | Out-Null

        }
    
        Set-VM -Name $sdnHOST -ProcessorCount 4 -AutomaticStartAction Start
        Get-VMNetworkAdapter -VMName $sdnHOST | Rename-VMNetworkAdapter -NewName "SDN"
        Get-VMNetworkAdapter -VMName $sdnHOST | Set-VMNetworkAdapter -DeviceNaming On -StaticMacAddress  ("{0:D12}" -f ( Get-Random -Minimum 0 -Maximum 99999 ))
        Add-VMNetworkAdapter -VMName $sdnHOST -Name SDN2 -DeviceNaming On -SwitchName $VMSwitch
        $vmMac = ((Get-VMNetworkAdapter -Name SDN -VMName $sdnHOST).MacAddress) -replace '..(?!$)', '$&-'
        Write-Verbose "Virtual Machine FABRIC NIC MAC is = $vmMac"

        if ($sdnHOST -ne "SDNMGMT") {

            Add-VMNetworkAdapter -VMName $sdnHOST -SwitchName $VMSwitch -DeviceNaming On -Name StorageA
            Add-VMNetworkAdapter -VMName $sdnHOST -SwitchName $VMSwitch -DeviceNaming On -Name StorageB


        }

        Get-VM $sdnHOST | Set-VMProcessor -ExposeVirtualizationExtensions $true
        Get-VM $sdnHOST | Set-VMMemory -DynamicMemoryEnabled $false
        Get-VM $sdnHOST | Get-VMNetworkAdapter | Set-VMNetworkAdapter -MacAddressSpoofing On

        

        Set-VMNetworkAdapterVlan -VMName $sdnHOST -VMNetworkAdapterName SDN -Trunk -NativeVlanId 0 -AllowedVlanIdList 1-200
        Set-VMNetworkAdapterVlan -VMName $sdnHOST -VMNetworkAdapterName SDN2 -Trunk -NativeVlanId 0 -AllowedVlanIdList 1-200  

        if ($sdnHOST -ne "SDNMGMT") {

            Set-VMNetworkAdapterVlan -VMName $sdnHOST -VMNetworkAdapterName StorageA -Access -VlanId $SDNConfig.StorageAVLAN 
            Set-VMNetworkAdapterVlan -VMName $sdnHOST -VMNetworkAdapterName StorageB -Access -VlanId $SDNConfig.StorageBVLAN 


        }


        Enable-VMIntegrationService -VMName $sdnHOST -Name "Guest Service Interface"
        return $vmMac

    }
    
    
    return $vmMac          

}
    
function Add-Files {
    
    Param(
        $VMPlacement, 
        $HostVMPath, 
        $SDNConfig,
        $guiVHDXPath,
        $coreVHDXPath,
        $vmMacs
    )
    
    $corevhdx = 'CORE.vhdx'
    $guivhdx = 'GUI.vhdx'
    
    foreach ($sdnHOST in $VMPlacement) {
    
        # Get Drive Paths 

        $HypervHost = $sdnHOST.VMHost
        $DriveLetter = $HostVMPath.Split(':')
        $path = (("\\$HypervHost\") + ($DriveLetter[0] + "$") + ($DriveLetter[1]) + "\" + $sdnHOST.SDNHOST + ".vhdx")       

        # Install Hyper-V Offline

        Write-Verbose "Performing offline installation of Hyper-V to path $path"
        Install-WindowsFeature -Vhd $path -Name Hyper-V, RSAT-Hyper-V-Tools, Hyper-V-Powershell -Confirm:$false | Out-Null
        Start-Sleep -Seconds 20       

    
        # Mount VHDX

        Write-Verbose "Mounting VHDX file at $path"
        [string]$MountedDrive = (Mount-VHD -Path $path -Passthru | Get-Disk | Get-Partition | Get-Volume).DriveLetter
        $MountedDrive = $MountedDrive.Replace(" ", "")

        # Get Assigned MAC Address so we know what NIC to assign a static IP to
        $vmMac = ($vmMacs | Where-Object { $_.Hostname -eq $sdnHOST.SDNHOST }).vmMac

   
        # Inject Answer File

        Write-Verbose "Injecting answer file to $path"
    
        $sdnHOSTComputerName = $sdnHOST.SDNHOST
        $sdnHOSTIP = $SDNConfig.($sdnHOSTComputerName + "IP")
        $SDNAdminPassword = $SDNConfig.SDNAdminPassword
        $SDNDomainFQDN = $SDNConfig.SDNDomainFQDN
        $SDNLABDNS = $SDNConfig.SDNLABDNS    
        $SDNLabRoute = $SDNConfig.SDNLABRoute         
        $ProductKey = $SDNConfig.GUIProductKey

        # Only inject product key if host is SDNMGMT
        $SDNMGMTProdKey = $null
        if ($sdnHOST.SDNHOST -eq "SDNMGMT") { $SDNMGMTProdKey = "<ProductKey>$ProductKey</ProductKey>" }
            
 
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
<ComputerName>$sdnHOSTComputerName</ComputerName>
$SDNMGMTProdKey
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
<Identifier>$vmMac</Identifier>
<Ipv4Settings>
<DhcpEnabled>false</DhcpEnabled>
</Ipv4Settings>
<UnicastIpAddresses>
<IpAddress wcm:action="add" wcm:keyValue="1">$sdnHOSTIP</IpAddress>
</UnicastIpAddresses>
<Routes>
<Route wcm:action="add">
<Identifier>1</Identifier>
<NextHopAddress>$SDNLabRoute</NextHopAddress>
<Prefix>0.0.0.0/0</Prefix>
<Metric>100</Metric>
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
<Identifier>$vmMac</Identifier>
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
        if (!$PantherDir) { New-Item -Path ($MountedDrive + ":\Windows\Panther") -ItemType Directory -Force | Out-Null }
    
        Set-Content -Value $UnattendXML -Path ($MountedDrive + ":\Windows\Panther\Unattend.xml") -Force
    
        # Inject VMConfigs and create folder structure if host is SDNMGMT

        if ($sdnHOST.SDNHOST -eq "SDNMGMT") {

            # Creating folder structure on SDNMGMT

            Write-Verbose "Creating VMs\Base folder structure on SDNMGMT"
            New-Item -Path ($MountedDrive + ":\VMs\Base") -ItemType Directory -Force | Out-Null

            Write-Verbose "Injecting VMConfigs to $path"
            Copy-Item -Path .\SDNSandbox-Config.psd1 -Destination ($MountedDrive + ":\") -Recurse -Force
            New-Item -Path ($MountedDrive + ":\") -Name VMConfigs -ItemType Directory -Force | Out-Null
            Copy-Item -Path $guiVHDXPath -Destination ($MountedDrive + ":\VMs\Base\GUI.vhdx") -Force
            Copy-Item -Path $coreVHDXPath -Destination ($MountedDrive + ":\VMs\Base\CORE.vhdx") -Force
            Copy-Item -Path .\Applications\SCRIPTS -Destination ($MountedDrive + ":\VmConfigs") -Recurse -Force
            Copy-Item -Path .\Applications\SDNEXAMPLES -Destination ($MountedDrive + ":\VmConfigs") -Recurse -Force
            #Copy-Item -Path '.\Applications\Windows Admin Center' -Destination ($MountedDrive + ":\VmConfigs") -Recurse -Force  

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
        Start-VM -ComputerName $VMHost.VMhost -Name $VMHost.SDNHOST

    }    
} 
    
function New-DataDrive {

    param (

        $VMPlacement, 
        $SDNConfig,
        $localCred
        
    )

    foreach ($SDNVM in $VMPlacement) {

        Invoke-Command -ComputerName $SDNVM.VMHost  -ScriptBlock {

            $VerbosePreference = "Continue"
            Write-Verbose "Onlining, partitioning, and formatting Data Drive on $($Using:SDNVM.SDNHOST)"

            $localCred = new-object -typename System.Management.Automation.PSCredential -argumentlist "Administrator" `
                , (ConvertTo-SecureString $using:SDNConfig.SDNAdminPassword   -AsPlainText -Force)   

            Invoke-Command -VMName $using:SDNVM.SDNHOST -Credential $localCred -ScriptBlock {

                Set-Disk -Number 1 -IsOffline $false | Out-Null
                Initialize-Disk -Number 1 | Out-Null
                New-Partition -DiskNumber 1 -UseMaximumSize -AssignDriveLetter | Out-Null
                Format-Volume -DriveLetter D | Out-Null

            }                      
        }
    }    
}
    
function Test-SDNHOSTVMConnection {

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
    
                $testconnection = Invoke-Command -VMName $using:SDNVM.SDNHOST -ScriptBlock { Get-Process } -Credential $localCred -ErrorAction Ignore
    
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
    
    $natSwitchTarget = $VMPlacement | Where-Object { $_.SDNHOST -eq "SDNMGMT" }
    
    Add-VMNetworkAdapter -VMName $natSwitchTarget.SDNHOST -ComputerName $natSwitchTarget.VMHost -DeviceNaming On 

    $params = @{

        VMName       = $natSwitchTarget.SDNHOST
        ComputerName = $natSwitchTarget.VMHost
    }

    Get-VMNetworkAdapter @params | Where-Object { $_.Name -match "Network" } | Connect-VMNetworkAdapter -SwitchName $SDNConfig.natHostVMSwitchName
    Get-VMNetworkAdapter @params | Where-Object { $_.Name -match "Network" } | Rename-VMNetworkAdapter -NewName "NAT"
    
    Get-VM @params | Get-VMNetworkAdapter -Name NAT | Set-VMNetworkAdapter -MacAddressSpoofing On
    
    <# Should not need this anymore

    if ($SDNConfig.natVLANID) {
    
        Get-VM @params | Get-VMNetworkAdapter -Name NAT | Set-VMNetworkAdapterVlan -Access -VlanId $natVLANID | Out-Null
    
    }

    #>
    
    #Create PROVIDER NIC in order for NAT to work from SLB/MUX and RAS Gateways

    Add-VMNetworkAdapter @params -Name PROVIDER -DeviceNaming On -SwitchName $SwitchName
    Get-VM @params | Get-VMNetworkAdapter -Name PROVIDER | Set-VMNetworkAdapter -MacAddressSpoofing On
    Get-VM @params | Get-VMNetworkAdapter -Name PROVIDER | Set-VMNetworkAdapterVlan -Access -VlanId $SDNConfig.providerVLAN | Out-Null    
    
    #Create VLAN 200 NIC in order for NAT to work from L3 Connections

    Add-VMNetworkAdapter @params -Name VLAN200 -DeviceNaming On -SwitchName $SwitchName
    Get-VM @params | Get-VMNetworkAdapter -Name VLAN200 | Set-VMNetworkAdapter -MacAddressSpoofing On
    Get-VM @params | Get-VMNetworkAdapter -Name VLAN200 | Set-VMNetworkAdapterVlan -Access -VlanId $SDNConfig.vlan200VLAN | Out-Null    

    
    #Create Simulated Internet NIC in order for NAT to work from L3 Connections

    Add-VMNetworkAdapter @params -Name simInternet -DeviceNaming On -SwitchName $SwitchName
    Get-VM @params | Get-VMNetworkAdapter -Name simInternet | Set-VMNetworkAdapter -MacAddressSpoofing On
    Get-VM @params | Get-VMNetworkAdapter -Name simInternet | Set-VMNetworkAdapterVlan -Access -VlanId $SDNConfig.simInternetVLAN | Out-Null

    
}  
    
function Resolve-Applications {

    Param (

        $SDNConfig
    )
    
    # Verify Product Keys

    Write-Verbose "Performing simple validation of Product Keys"
    $guiResult = $SDNConfig.GUIProductKey -match '^([A-Z0-9]{5}-){4}[A-Z0-9]{5}$'
    $coreResult = $SDNConfig.COREProductKey -match '^([A-Z0-9]{5}-){4}[A-Z0-9]{5}$'
    
    if (!$guiResult) { Write-Error "Cannot validate or find the product key for the Windows Server Datacenter Desktop Experience." }


    # Are we on Server Core?
    $regKey = "hklm:/software/microsoft/windows nt/currentversion"
    $Core = (Get-ItemProperty $regKey).InstallationType -eq "Server Core"
    If ($Core) {
    
        Write-Warning "You might not want to run the Azure Stack HCI OS Sandbox on Server Core, getting remote access to the AdminCenter VM may require extra configuration."
        Start-Sleep -Seconds 5

    }
    
    
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
    
                        Write-Error "There is a mismatch in the MTU value for the external switch and the value in the SDNSandbox-Config.psd1 data file."  
    
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


    # Set base number for Storage IPs
    $int = 9


    foreach ($SDNVM in $VMPlacement) {

    
        # Increment Storage IPs

        $int++


        Invoke-Command -ComputerName $SDNVM.VMHost -ScriptBlock {

            Invoke-Command -VMName $using:SDNVM.SDNHOST -ArgumentList $using:SDNConfig, $using:localCred, $using:int  -ScriptBlock {

                $SDNConfig = $args[0]
                $localCred = $args[1]
                $int = $args[2]
                $VerbosePreference = "SilentlyContinue"


                # Create IP Address of Storage Adapters

                $storageAIP = $sdnconfig.storageAsubnet.Replace("0/24", $int)
                $storageBIP = $sdnconfig.storageBsubnet.Replace("0/24", $int)


                # Set Name and IP Addresses on Storage Interfaces
                $storageNICs = Get-NetAdapterAdvancedProperty | Where-Object { $_.DisplayValue -match "Storage" }

                foreach ($storageNIC in $storageNICs) {

                    Rename-NetAdapter -Name $storageNIC.Name -NewName  $storageNIC.DisplayValue        

                }

                $storageNICs = Get-Netadapter | Where-Object { $_.Name -match "Storage" }

                foreach ($storageNIC in $storageNICs) {

                    If ($storageNIC.Name -eq 'StorageA') { New-NetIPAddress -InterfaceAlias $storageNIC.Name -IPAddress $storageAIP -PrefixLength 24 | Out-Null }  
                    If ($storageNIC.Name -eq 'StorageB') { New-NetIPAddress -InterfaceAlias $storageNIC.Name -IPAddress $storageBIP -PrefixLength 24 | Out-Null }  

                }




                # Enable WinRM

                Write-Verbose "Enabling Windows Remoting in $env:COMPUTERNAME"
                $VerbosePreference = "SilentlyContinue" 
                Set-Item WSMan:\localhost\Client\TrustedHosts *  -Confirm:$false -Force
                Enable-PSRemoting | Out-Null
                $VerbosePreference = "Continue" 

                Start-Sleep -Seconds 60

                if ($env:COMPUTERNAME -ne "SDNMGMT") {
                `
                        Write-Verbose "Installing Network Controller on $env:COMPUTERNAME"
                    Install-WindowsFeature -Name NetworkController -IncludeAllSubFeature -IncludeManagementTools -ComputerName $env:COMPUTERNAME -Credential $localCred | Out-Null  
                    Write-Verbose "Installing and Configuring Failover Clustering on $env:COMPUTERNAME"
                    $VerbosePreference = "SilentlyContinue"
                    Install-WindowsFeature -Name Failover-Clustering -IncludeAllSubFeature -IncludeManagementTools -ComputerName $env:COMPUTERNAME -Credential $localCred | Out-Null



                }

                # Enable CredSSP and MTU Settings

                Invoke-Command -ComputerName localhost -Credential $localCred -ScriptBlock {

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
 
            } -Credential $using:localCred

        }

    }

}

function Set-SDNMGMT {

    param (

        $SDNConfig,
        $localCred,
        $domainCred

    )

    $SDNMGMTIP = $SDNConfig.SDNMGMTIP.Replace('/24', '')

    # Sleep to get around race condition on fast systems
    Start-Sleep -Seconds 10

    Invoke-Command -ComputerName SDNMGMT -Credential $localCred  -ScriptBlock {

        # Creds

        $localCred = $using:localCred
        $domainCred = $using:domainCred
        $SDNConfig = $using:SDNConfig

        # Set variables

        $ParentDiskPath = "C:\VMs\Base\"
        $vmpath = "D:\VMs\"
        $OSVHDX = "GUI.vhdx"
        $coreOSVHDX = "CORE.vhdx"
        $VMStoragePathforOtherHosts = $SDNConfig.HostVMPath
        $SourcePath = 'C:\VMConfigs'
        $Assetspath = "$SourcePath\Assets"

        $ErrorActionPreference = "Stop"
        $VerbosePreference = "Continue"
        $WarningPreference = "SilentlyContinue"

        # Disable Fabric2 Network Adapter
        
        $fabTwo = $null
        while ($fabTwo -ne 'Disabled') {
            $VerbosePreference = "SilentlyContinue"
            Write-Verbose "Disabling Fabric2 Adapter"
            Get-Netadapter FABRIC2 | Disable-NetAdapter -Confirm:$false | Out-Null
            $fabTwo = (Get-Netadapter -Name FABRIC2).Status 

        }
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

            New-VMSwitch  -AllowManagementOS $true -Name "vSwitch-Fabric" -NetAdapterName FABRIC -MinimumBandwidthMode None | Out-Null

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
                $simInternetIP = $SDNConfig.BGPRouterIP_SimulatedInternet.TrimEnd("1/24") + "254"
                $simInternetGW = $SDNConfig.BGPRouterIP_SimulatedInternet.TrimEnd("/24")
                $simInternetPFX = $SDNConfig.BGPRouterIP_SimulatedInternet.Split("/")[1]

                New-VMSwitch -SwitchName NAT -SwitchType Internal -MinimumBandwidthMode None | Out-Null
                New-NetIPAddress -IPAddress $natIP -PrefixLength $Prefix -InterfaceAlias "vEthernet (NAT)" | Out-Null
                New-NetNat -Name NATNet -InternalIPInterfaceAddressPrefix $natSubnet | Out-Null

                $VerbosePreference = "Continue"
                Write-Verbose "Configuring Provider NIC on $env:COMPUTERNAME"
                $VerbosePreference = "SilentlyContinue"

                $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "PROVIDER" }
                Rename-NetAdapter -name $NIC.name -newname "PROVIDER" | Out-Null
                New-NetIPAddress -InterfaceAlias "PROVIDER" –IPAddress $provIP -PrefixLength $provpfx | Out-Null

                <#
                $index = (Get-WmiObject Win32_NetworkAdapter | Where-Object { $_.netconnectionid -eq "PROVIDER" }).InterfaceIndex
                $NetInterface = Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.InterfaceIndex -eq $index }     
                $NetInterface.SetGateways($tranpfx) | Out-Null
                #>

                $VerbosePreference = "Continue"
                Write-Verbose "Configuring VLAN200 NIC on $env:COMPUTERNAME"
                $VerbosePreference = "SilentlyContinue"

                $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "VLAN200" }
                Rename-NetAdapter -name $NIC.name -newname "VLAN200" | Out-Null
                New-NetIPAddress -InterfaceAlias "VLAN200" –IPAddress $vlan200IP -PrefixLength $vlanpfx | Out-Null

                <#
                $index = (Get-WmiObject Win32_NetworkAdapter | Where-Object { $_.netconnectionid -eq "VLAN200" }).InterfaceIndex
                $NetInterface = Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.InterfaceIndex -eq $index }     
                $NetInterface.SetGateways($vlanGW) | Out-Null
                #>

                $VerbosePreference = "Continue"
                Write-Verbose "Configuring simulatedInternet NIC on $env:COMPUTERNAME"
                $VerbosePreference = "SilentlyContinue"


                $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "simInternet" }
                Rename-NetAdapter -name $NIC.name -newname "simInternet" | Out-Null
                New-NetIPAddress -InterfaceAlias "simInternet" –IPAddress $simInternetIP -PrefixLength $simInternetPFX | Out-Null

                <#
                $index = (Get-WmiObject Win32_NetworkAdapter | Where-Object { $_.netconnectionid -eq "simInternet" }).InterfaceIndex
                $NetInterface = Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.InterfaceIndex -eq $index }     
                $NetInterface.SetGateways($simInternetGW) | Out-Null
                #>

                Write-Verbose "Making NAT Work"


                $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" `
                | Where-Object { $_.RegistryValue -eq "Network Adapter" -or $_.RegistryValue -eq "NAT" }

                Rename-NetAdapter -name $NIC.name -newname "Internet" | Out-Null 

                $internetIP = $SDNConfig.natHostSubnet.Replace("0/24", "5")
                $internetGW = $SDNConfig.natHostSubnet.Replace("0/24", "1")

                Start-Sleep -Seconds 30

                $internetIndex = (Get-NetAdapter | Where-Object { $_.Name -eq "Internet" }).ifIndex

                Start-Sleep -Seconds 30

                New-NetIPAddress -IPAddress $internetIP -PrefixLength 24 -InterfaceIndex $internetIndex -DefaultGateway $internetGW -AddressFamily IPv4 | Out-Null
                Set-DnsClientServerAddress -InterfaceIndex $internetIndex -ServerAddresses ($SDNConfig.natDNS) | Out-Null

                #Enable Large MTU

                $VerbosePreference = "Continue"
                Write-Verbose "Configuring MTU on all Adapters"
                $VerbosePreference = "SilentlyContinue"
                Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.Name -ne "Ethernet" } | Set-NetAdapterAdvancedProperty `
                    -RegistryValue $SDNConfig.SDNLABMTU -RegistryKeyword "*JumboPacket"
                $VerbosePreference = "Continue"

                Start-Sleep -Seconds 30

                #Provision Public and Private VIP Route
 
                New-NetRoute -DestinationPrefix $SDNConfig.PublicVIPSubnet -NextHop $provGW -InterfaceAlias PROVIDER | Out-Null

                # Remove Gateway from Fabric NIC
                Write-Verbose "Removing Gateway from Fabric NIC" 
                $index = (Get-WmiObject Win32_NetworkAdapter | Where-Object { $_.netconnectionid -match "vSwitch-Fabric" }).InterfaceIndex
                Remove-NetRoute -InterfaceIndex $index -DestinationPrefix "0.0.0.0/0" -Confirm:$false

                # Resize SDNMGMT's OS partition.
                Write-Verbose -Message "Resizing SDNMGMTS's OS partition"

                $recoveryPartition = Get-Partition | Where-Object { $_.type -eq "Recovery" }

                If ($recoveryPartition) {

                    $params = @{

                        DiskNumber      = 0
                        PartitionNumber = $recoveryPartition.PartitionNumber 
                        Confirm         = $false

                    }

                    Remove-Partition @params

                }

                $basicPartition = Get-Partition | Where-Object { $_.type -eq "Basic" -and $_.DiskNumber -eq 0 }

                $size = Get-PartitionSupportedSize -DiskNumber 0 -PartitionNumber $basicPartition.PartitionNumber

                if ($size.SizeMax -ge 10) {

                    $params = @{

                        DiskNumber      = 0
                        PartitionNumber = $basicPartition.PartitionNumber 
                        Confirm         = $false
                        Size            = $size.SizeMax

                    }

                    Resize-Partition @params
            
                }          

            }

        }

        Catch {

            throw $_

        }

    }

    # Provision DC

    Write-Verbose "Provisioning Domain Controller in Managment VM"

    # Provision BGP TOR Router
    Write-Verbose -Message "Provisioning BGPTOR Router VM."
    New-RouterVM -SDNConfig $SDNConfig -localCred $localCred -domainCred $domainCred | Out-Null

    # Provision Domain Controller 
    Write-Verbose "Provisioning Domain Controller VM"
    New-DCVM -SDNConfig $SDNConfig -localCred $localCred -domainCred $domainCred | Out-Null

    # Join SDNHOSTs to Domain 

    Invoke-Command -VMName SDNMGMT -Credential $localCred -ScriptBlock {

        $SDNConfig = $using:SDNConfig
        $VerbosePreference = "Continue"

        function AddSDNHOSTToDomain {

            Param (

                $IP,
                $localCred, 
                $domainCred, 
                $sdnHOSTName, 
                $SDNConfig

            )

            Write-Verbose "Joining host $sdnHOSTName ($ip) to domain"

            Try {
                                 
                $ErrorActionPreference = "Silently Continue"

                $sdnHOSTTest = Test-Connection $IP -Quiet

                While (!$sdnHOSTTest) {
                    Write-Host "Unable to contact computer $sdnHOSTname at $IP. Please make sure the system is contactable before continuing and the Press Enter to continue." `
                        -ForegroundColor Red
                    pause
                    $sdnHOSTTest = Test-Connection $sdnHOSTName -Quiet -Count 1                      
                }

                
                $ErrorActionPreference = "SilentlyContinue"

                $params = @{

                    ComputerName = $IP
                    Credential   = $localCred
                    ArgumentList = ($domainCred, $SDNConfig.SDNDomainFQDN)
                }


                $job = Invoke-Command @params -ScriptBlock { 
                    
                    Write-Host "Joining Domain"
                    $ErrorActionPreference = "SilentlyContinue"
                    Add-Computer -DomainName $args[1] -Credential $args[0] -ErrorAction SilentlyContinue
                    Restart-Computer -Force -Confirm:$false
                   
                    
                } -ErrorAction SilentlyContinue

                # While ($Job.JobStateInfo.State -ne "Completed") { Start-Sleep -Seconds 10 }
                    
                Write-Verbose -Message "Sleeping for 20 seconds"
                Start-Sleep -Seconds 20
                Write-Verbose "Getting joined domain"
                $DomainJoined = (Get-WmiObject -ComputerName $ip -Credential $localcred -Class win32_computersystem -ErrorAction SilentlyContinue).domain
                
                While ($DomainJoined -ne $SDNConfig.SDNDomainFQDN) {

                    Write-Verbose -Message "Rebooting VM as it is not showing as domain joined"
                    Get-VM -Name $sdnHOSTName | Restart-Vm -Force
                    Start-Sleep -Seconds 60

                }
                
                
                Get-VM $sdnHOSTName | Restart-Vm -Force -Wait -Verbose
                Write-Verbose "Sleeping 60 Seconds to let VM Reboot."
                Start-Sleep -Seconds 60

            }

            Catch { 

                Write-Host "Exception was expected, but we should be ok."
                Get-VM $sdnHOSTName | Restart-Vm -Force -Wait
                Write-Verbose "Sleeping 60 Seconds to let VM Reboot."
                Start-Sleep -Seconds 60

            }
            Finally {

                $ErrorActionPreference = "Stop"

            }

        }

        # Set VM Path for Physical Hosts

        Try {

            $SDNHOST1 = $SDNConfig.SDNHOST1IP.Split("/")[0]
            $SDNHOST2 = $SDNConfig.SDNHOST2IP.Split("/")[0]

            Write-Verbose "Setting VMStorage Path for all Hosts"
          
            Invoke-Command -ComputerName $SDNHOST1 -ArgumentList $VMStoragePathforOtherHosts `
                -ScriptBlock { Set-VMHost -VirtualHardDiskPath $args[0] -VirtualMachinePath $args[0] } `
                -Credential $using:localCred -AsJob | Out-Null
            Invoke-Command -ComputerName $SDNHOST2  -ArgumentList $VMStoragePathforOtherHosts `
                -ScriptBlock { Set-VMHost -VirtualHardDiskPath $args[0] -VirtualMachinePath $args[0] } `
                -Credential $using:localCred -AsJob | Out-Null


            # 2nd pass
            Invoke-Command -ComputerName $SDNHOST1 -ArgumentList $VMStoragePathforOtherHosts `
                -ScriptBlock { Set-VMHost -VirtualHardDiskPath $args[0] -VirtualMachinePath $args[0] } `
                -Credential $using:localCred -AsJob | Out-Null
            Invoke-Command -ComputerName $SDNHOST2 -ArgumentList $VMStoragePathforOtherHosts `
                -ScriptBlock { Set-VMHost -VirtualHardDiskPath $args[0] -VirtualMachinePath $args[0] } `
                -Credential $using:localCred -AsJob | Out-Null

            # Enable Enhanced Session Mode
            Set-VMHost -EnableEnhancedSessionMode $True


        }

        Catch {

            throw $_

        }

        #Add SDNHOSTS to domain

        Try {

            Write-Verbose "Adding SDN Hosts to the Domain"
            AddSDNHOSTToDomain -IP $SDNHOST1 -localCred $using:localCred -domainCred $using:domainCred -SDNHOSTName SDNHOST1 -SDNConfig $SDNConfig
            AddSDNHOSTToDomain -IP $SDNHOST2 -localCred $using:localCred -domainCred $using:domainCred -SDNHOSTName SDNHOST2 -SDNConfig $SDNConfig

        }

        Catch {

            throw $_

        }

    } | Out-Null


    # See if we can get netroute that we don't like

    $VerbosePreference = "SilentlyContinue"
    Import-Module NetTCPIP
    $VerbosePreference = "Continue"
    $internetgw = ($SDNConfig.MGMTSubnet).TrimEnd("0/24") + "1"
    Write-Verbose -Message "Deleting Net-Route for Internal Network $internetgw"
    Get-NetRoute | Where-Object { $_.Nexthop -match $internetgw -and $_.InterfaceAlias -match "Internal" } | Remove-NetRoute -Confirm:$false 
 

    # Provision Admincenter

    Write-Verbose "Provisioning admincenter VM"
    New-AdminCenterVM -SDNConfig $SDNConfig -localCred $localCred -domainCred $domainCred | Out-Null


}

function New-DCVM {

    Param (

        $SDNConfig,
        $localCred,
        $domainCred

    )

    Invoke-Command -VMName SDNMGMT -Credential $domainCred -ScriptBlock {

        $SDNConfig = $using:SDNConfig
        $localcred = $using:localcred
        $domainCred = $using:domainCred
        $ParentDiskPath = "C:\VMs\Base\"
        $vmpath = "D:\VMs\"
        $OSVHDX = "GUI.vhdx"
        $coreOSVHDX = "CORE.vhdx"
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


        # Resize VHD
        Write-Verbose -Message "Resizing OS DISK"
        Resize-VHD -Path ($vmpath + $VMName + '\' + $VMName + '.vhdx') -SizeBytes 130GB


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
        Remove-Item "C:\TempMount" | Out-Null

        # Start Virtual Machine

        Write-Verbose "Starting Virtual Machine...this will take some time" 
        Start-VM -Name $VMName | Out-Null

        # Wait until the VM is restarted

        while ((Invoke-Command -VMName $VMName -Credential $using:domainCred { "Test" } `
                    -ea SilentlyContinue) -ne "Test") { Start-Sleep -Seconds 1 }

        Write-Verbose "Configuring Domain Controller VM and Installing Active Directory."

        $ErrorActionPreference = "SilentlyContinue"

        try {
            Invoke-Command -VMName $VMName -Credential $localCred -ArgumentList $SDNConfig -ScriptBlock {

                $SDNConfig = $args[0]

                $VerbosePreference = "Continue"
                $WarningPreference = "SilentlyContinue"
                $ErrorActionPreference = "SilentlyContinue"
                $DCName = $SDNConfig.DCName
                $IP = $SDNConfig.SDNLABDNS
                $PrefixLength = ($SDNConfig.SDNMGMTIP.split("/"))[1]
                $SDNLabRoute = $SDNConfig.SDNLABRoute
                $DomainFQDN = $SDNConfig.SDNDomainFQDN
                $DomainNetBiosName = $DomainFQDN.Split(".")[0]

                Write-Verbose "Configuring NIC Settings for Domain Controller"
                $VerbosePreference = "SilentlyContinue"
                $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq $DCName }
                Rename-NetAdapter -name $NIC.name -newname $DCName | Out-Null 
                New-NetIPAddress -InterfaceAlias $DCName –IPAddress $ip -PrefixLength $PrefixLength -DefaultGateway $SDNLabRoute | Out-Null
                Set-DnsClientServerAddress -InterfaceAlias $DCName -ServerAddresses $IP | Out-Null
                Install-WindowsFeature -name AD-Domain-Services –IncludeManagementTools | Out-Null
                $VerbosePreference = "Continue"

                Write-Verbose "Configuring Trusted Hosts"
                Set-Item WSMan:\localhost\Client\TrustedHosts * -Confirm:$false -Force

                Write-Verbose "Installing Active Directory Forest. This will take some time..."


        
                $SecureString = ConvertTo-SecureString $SDNConfig.SDNAdminPassword -AsPlainText -Force
                Write-Verbose "Installing Active Directory..." 

                $params = @{

                    DomainName                    = $DomainFQDN
                    DomainMode                    = 'Win2025'
                    DatabasePath                  = "C:\Domain"
                    DomainNetBiosName             = $DomainNetBiosName
                    SafeModeAdministratorPassword = $SecureString

                }


                Write-Output $params

            
                $VerbosePreference = "SilentlyContinue"
                Install-ADDSForest  @params -InstallDns -Confirm -Force -NoRebootOnCompletion  | Out-Null

            }
        }
        catch {

            Write-Verbose -Message "Exception caught! (Must be on Server 2022!)"
            Write-Verbose -Message "Sleeping for two minutes to give time for Active Directory to install."
            Start-Sleep -Seconds 120

        }

        Write-Verbose "Stopping $VMName"
        Get-VM $VMName | Stop-VM
        Write-Verbose "Starting $VMName"
        Get-VM $VMName | Start-VM 

        # Wait until DC is created and rebooted

        while ((Invoke-Command -VMName $VMName -Credential $using:domainCred `
                    -ArgumentList $SDNConfig.DCName { (Get-ADDomainController $args[0]).enabled } -ea SilentlyContinue) -ne $true) { Start-Sleep -Seconds 1 }

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

            if ($SDNConfig.natDNS) { Add-DnsServerForwarder $SDNConfig.natDNS }
            else { Add-DnsServerForwarder 8.8.8.8 }

            # resize os disk
            Write-Verbose -Message "Resizing OS partition"

            $recoveryPartition = Get-Partition | Where-Object { $_.type -eq "Recovery" }

            If ($recoveryPartition) {

                $params = @{

                    DiskNumber      = 0
                    PartitionNumber = $recoveryPartition.PartitionNumber 
                    Confirm         = $false

                }

                Remove-Partition @params

            }

            $basicPartition = Get-Partition | Where-Object { $_.type -eq "Basic" }

            $size = Get-PartitionSupportedSize -DiskNumber 0 -PartitionNumber $basicPartition.PartitionNumber

            if ($size.SizeMax -ge 10) {

                $params = @{

                    DiskNumber      = 0
                    PartitionNumber = $basicPartition.PartitionNumber 
                    Confirm         = $false
                    Size            = $size.SizeMax

                }

                Resize-Partition @params
            
            }          

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

    Invoke-Command -VMName SDNMGMT -Credential $localCred -ScriptBlock {

        $SDNConfig = $using:SDNConfig
        $localcred = $using:localcred
        $domainCred = $using:domainCred
        $ParentDiskPath = "C:\VMs\Base\"
        $vmpath = "D:\VMs\"
        $OSVHDX = "CORE.vhdx"
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
        Add-VMNetworkAdapter -VMName $VMName -Name SIMInternet -SwitchName vSwitch-Fabric -DeviceNaming On
        Set-VMNetworkAdapterVlan -VMName $VMName -VMNetworkAdapterName Provider -Access -VlanId $SDNConfig.providerVLAN
        Set-VMNetworkAdapterVlan -VMName $VMName -VMNetworkAdapterName VLAN200 -Access -VlanId $SDNConfig.vlan200VLAN
        Set-VMNetworkAdapterVlan -VMName $VMName -VMNetworkAdapterName SIMInternet -Access -VlanId $SDNConfig.simInternetVLAN
           
    
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
        $ProductKey = $SDNConfig.GUIProductKey
    
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

        while ((Invoke-Command -VMName $VMName -Credential $localcred { "Test" } -ea SilentlyContinue) -ne "Test") { Start-Sleep -Seconds 1 }    
    
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
            $simInternetIP = $SDNConfig.BGPRouterIP_SimulatedInternet.Split("/")[0]
            $simInternetPFX = $SDNConfig.BGPRouterIP_SimulatedInternet.Split("/")[1]
    
            # Renaming NetAdapters and setting up the IPs inside the VM using CDN parameters

            Write-Verbose "Configuring $env:COMPUTERNAME's Networking"
            $VerbosePreference = "SilentlyContinue"  
            $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "Mgmt" }
            Rename-NetAdapter -name $NIC.name -newname "Mgmt" | Out-Null
            New-NetIPAddress -InterfaceAlias "Mgmt" –IPAddress $MGMTIP -PrefixLength $MGMTPFX | Out-Null
            Set-DnsClientServerAddress -InterfaceAlias “Mgmt” -ServerAddresses $DNS] | Out-Null
            $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "PROVIDER" }
            Rename-NetAdapter -name $NIC.name -newname "PROVIDER" | Out-Null
            New-NetIPAddress -InterfaceAlias "PROVIDER" –IPAddress $PNVIP -PrefixLength $PNVPFX | Out-Null
            $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "VLAN200" }
            Rename-NetAdapter -name $NIC.name -newname "VLAN200" | Out-Null
            New-NetIPAddress -InterfaceAlias "VLAN200" –IPAddress $VLANIP -PrefixLength $VLANPFX | Out-Null
            $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "SIMInternet" }
            Rename-NetAdapter -name $NIC.name -newname "SIMInternet" | Out-Null
            New-NetIPAddress -InterfaceAlias "SIMInternet" –IPAddress $simInternetIP -PrefixLength $simInternetPFX | Out-Null      
    
            # if NAT is selected, configure the adapter
       
            if ($SDNConfig.natConfigure) {
    
                $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" `
                | Where-Object { $_.RegistryValue -eq "NAT" }
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
    
            # Configure Trusted Hosts

            Write-Verbose "Configuring Trusted Hosts"
            Set-Item WSMan:\localhost\Client\TrustedHosts * -Confirm:$false -Force
            
            
            # Installing Remote Access

            Write-Verbose "Installing Remote Access on $env:COMPUTERNAME" 
            $VerbosePreference = "SilentlyContinue"
            Install-RemoteAccess -VPNType RoutingOnly | Out-Null
    
            # Adding a BGP Router to the VM

            $VerbosePreference = "Continue"
            Write-Verbose "Installing BGP Router on $env:COMPUTERNAME"
            $VerbosePreference = "SilentlyContinue"

            $params = @{

                BGPIdentifier  = $PNVIP
                LocalASN       = $SDNConfig.BGPRouterASN
                TransitRouting = 'Enabled'
                ClusterId      = 1
                RouteReflector = 'Enabled'

            }

            Add-BgpRouter @params

            #Add-BgpRouter -BGPIdentifier $PNVIP -LocalASN $SDNConfig.BGPRouterASN `
            # -TransitRouting Enabled -ClusterId 1 -RouteReflector Enabled

            # Configure BGP Peers

            if ($SDNConfig.ConfigureBGPpeering) {

                Write-Verbose "Peering future MUX/GWs"

                $Mux01IP = ($SDNConfig.BGPRouterIP_ProviderNetwork.TrimEnd("1/24")) + "40"
                $GW01IP = ($SDNConfig.BGPRouterIP_ProviderNetwork.TrimEnd("1/24")) + "2"
                $GW02IP = ($SDNConfig.BGPRouterIP_ProviderNetwork.TrimEnd("1/24")) + "3"

                $params = @{

                    Name           = 'MUX01'
                    LocalIPAddress = $PNVIP
                    PeerIPAddress  = $Mux01IP
                    PeerASN        = $SDNConfig.SDNASN
                    OperationMode  = 'Mixed'
                    PeeringMode    = 'Automatic'
                }

                Add-BgpPeer @params -PassThru

                $params.Name = 'GW01'
                $params.PeerIPAddress = $GW01IP

                Add-BgpPeer @params -PassThru

                $params.Name = 'GW02'
                $params.PeerIPAddress = $GW02IP

                Add-BgpPeer @params -PassThru    

            }
    
            # Enable Large MTU

            Write-Verbose "Configuring MTU on all Adapters"
            Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Set-NetAdapterAdvancedProperty -RegistryValue $SDNConfig.SDNLABMTU -RegistryKeyword "*JumboPacket"   
    
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

    Invoke-Command -VMName SDNMGMT -Credential $localCred -ScriptBlock {

        $VMName = "admincenter"
        $ParentDiskPath = "C:\VMs\Base\"
        $VHDPath = "D:\VMs\"
        $OSVHDX = "GUI.vhdx"
        $BaseVHDPath = $ParentDiskPath + $OSVHDX
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

            ParentPath = $BaseVHDPath
            Path       = (($VHDPath) + ($VMName) + (".vhdx")) 
        }

        New-VHD -Differencing @params | out-null

        # MountVHDXFile

        $VerbosePreference = "SilentlyContinue"
        Import-Module DISM
        $VerbosePreference = "Continue"

        # Resize VHD
        Resize-VHD -Path (($VHDPath) + ($VMName) + (".vhdx")) -SizeBytes 130GB

        Write-Verbose "Mounting and Injecting Answer File into the $VMName VM." 
        New-Item -Path "C:\TempWACMount" -ItemType Directory | Out-Null
        Mount-WindowsImage -Path "C:\TempWACMount" -Index 1 -ImagePath (($VHDPath) + ($VMName) + (".vhdx")) | Out-Null

        # Copy Source Files

        Write-Verbose "Copying Application and Script Source Files to $VMName"
        # Copy-Item 'C:\VMConfigs\Windows Admin Center' -Destination C:\TempWACMount\ -Recurse -Force
        Copy-Item C:\VMConfigs\SCRIPTS -Destination C:\TempWACMount -Recurse -Force
        Copy-Item C:\VMConfigs\SDNEXAMPLES -Destination C:\TempWACMount -Recurse -Force
        New-Item -Path C:\TempWACMount\VHDs -ItemType Directory -Force | Out-Null
        Copy-Item C:\VMs\Base\CORE.vhdx -Destination C:\TempWACMount\VHDs -Force
        Copy-Item C:\VMs\Base\GUI.vhdx  -Destination  C:\TempWACMount\VHDs -Force

        # Apply Custom Unattend.xml file

        New-Item -Path C:\TempWACMount\windows -ItemType Directory -Name Panther -Force | Out-Null
        $Password = $SDNConfig.SDNAdminPassword
        $ProductKey = $SDNConfig.GUIProductKey
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

        # Enabling Remote Access on Admincenter VM
        Write-Verbose "Enabling Remote Access"
        Enable-WindowsOptionalFeature -Path C:\TempWACMount -FeatureName RasRoutingProtocols -All -LimitAccess | Out-Null
        Enable-WindowsOptionalFeature -Path C:\TempWACMount -FeatureName RemoteAccessPowerShell -All -LimitAccess | Out-Null

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
        Set-VMProcessor -VMName $VMname -Count 4
        set-vm -Name $VMName  -AutomaticStopAction TurnOff

        Write-Verbose "Starting $VMName VM."
        Start-VM -Name $VMName

        # Refresh Domain Cred

        $domainCred = new-object -typename System.Management.Automation.PSCredential `
            -argumentlist (($SDNConfig.SDNDomainFQDN.Split(".")[0]) + "\administrator"), `
        (ConvertTo-SecureString $SDNConfig.SDNAdminPassword -AsPlainText -Force)

        # Wait until the VM is restarted

        while ((Invoke-Command -VMName $VMName -Credential $domainCred { "Test" } `
                    -ea SilentlyContinue) -ne "Test") { Start-Sleep -Seconds 1 }

        # Finish Configuration

        Invoke-Command -VMName $VMName -Credential $domainCred -ArgumentList $SDNConfig, $VMName -ScriptBlock {

            $SDNConfig = $args[0]
            $VMName = $args[1]
            $Gateway = $SDNConfig.SDNLABRoute
            $VerbosePreference = "Continue"
            $ErrorActionPreference = "Stop"

            $VerbosePreference = "SilentlyContinue"
            Import-Module NetAdapter
            $VerbosePreference = "Continue"

            Write-Verbose "Configuring WSMAN Trusted Hosts"
            Set-Item WSMan:\localhost\Client\TrustedHosts * -Confirm:$false -Force
            Enable-WSManCredSSP -Role Client –DelegateComputer * -Force

            Write-Verbose "Rename Network Adapter in $VMName VM" 
            Get-NetAdapter | Rename-NetAdapter -NewName Fabric

            # Set Gateway
            $index = (Get-WmiObject Win32_NetworkAdapter | Where-Object { $_.netconnectionid -eq "Fabric" }).InterfaceIndex
            $NetInterface = Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.InterfaceIndex -eq $index }     
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


            # Enable Large MTU

            Write-Verbose "Configuring MTU on all Adapters"
            Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Set-NetAdapterAdvancedProperty -RegistryValue $SDNConfig.SDNLABMTU -RegistryKeyword "*JumboPacket"   


            # $PNVIP 

            $WACIP = $SDNConfig.WACIP.Split("/")[0]
    
            # Install RSAT-NetworkController

            $isAvailable = Get-WindowsFeature | Where-Object { $_.Name -eq 'RSAT-NetworkController' }

            if ($isAvailable) {

                $VerbosePreference = "SilentlyContinue"
                Import-Module ServerManager
                $VerbosePreference = "Continue"

                Write-Verbose "Installing RSAT-NetworkController"
                Install-WindowsFeature -Name RSAT-NetworkController -IncludeAllSubFeature -IncludeManagementTools | Out-Null

            }

            # Install Hyper-V RSAT

            Write-Verbose "Installing Hyper-V RSAT Tools"
            Install-WindowsFeature -Name RSAT-Hyper-V-Tools -IncludeAllSubFeature -IncludeManagementTools | Out-Null


            # Install RSAT AD Tools
            Write-Verbose "Installing Active Directory RSAT Tools"
            Install-WindowsFeature -Name  RSAT-ADDS -IncludeAllSubFeature -IncludeManagementTools | Out-Null

            # Install Failover Cluster RSAT Tools
            Write-Verbose "Installing Failover Clustering RSAT Tools"
            Install-WindowsFeature -Name  RSAT-Clustering-Mgmt, RSAT-Clustering-PowerShell -IncludeAllSubFeature -IncludeManagementTools | Out-Null

            # Install DNS RSAT Tool
            Write-Verbose "Installing DNS Server RSAT Tools"
            Install-WindowsFeature -Name RSAT-DNS-Server  -IncludeAllSubFeature -IncludeManagementTools | Out-Null

            # Install Network Controller
            Write-Verbose "Installing Network Controller binaries"
            Install-WindowsFeature -Name NetworkController  -IncludeAllSubFeature -IncludeManagementTools | Out-Null


            # Install VPN Routing
            $VerbosePreference = "Continue"
            Install-RemoteAccess -VPNType RoutingOnly | Out-Null
            $VerbosePreference = "SilentlyContinue"
            Start-Sleep -Seconds 60 

            # Resize Partition

            Write-Verbose -Message "Resizing Admincenter's partition"

            $recoveryPartition = Get-Partition | Where-Object { $_.type -eq "Recovery" }

            If ($recoveryPartition) {

                $params = @{

                    DiskNumber      = 0
                    PartitionNumber = $recoveryPartition.PartitionNumber 
                    Confirm         = $false

                }

                Remove-Partition @params

            }

            $basicPartition = Get-Partition | Where-Object { $_.type -eq "Basic" }

            $size = Get-PartitionSupportedSize -DiskNumber 0 -PartitionNumber $basicPartition.PartitionNumber

            if ($size.SizeMax -ge 10) {

                $params = @{

                    DiskNumber      = 0
                    PartitionNumber = $basicPartition.PartitionNumber 
                    Confirm         = $false
                    Size            = $size.SizeMax

                }

                Resize-Partition @params
            
            }          

            # Install Nuget
            Install-PackageProvider -Name Nuget -MinimumVersion 2.8.5.201 -Force

            # Install Azure PowerShell
            # Install-Module -Name Az -AllowClobber -SkipPublisherCheck -Force -Confirm:$false

            # Stop Server Manager from starting on boot
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\ServerManager" -Name "DoNotOpenServerManagerAtLogon" -Value 1
            
            # Request SSL Certificate for Windows Admin Center
            Write-Verbose "Generating SSL Certificate Request"

            # Create BGP Router
            $params = @{

                BGPIdentifier  = $WACIP
                LocalASN       = $SDNConfig.WACASN
                TransitRouting = 'Enabled'
                ClusterId      = 1
                RouteReflector = 'Enabled'

            }

            Add-BgpRouter @params

            

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
            $WACVMName = "admincenter"
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

            $VerbosePreference = "SilentlyContinue"            
            Register-PSSessionConfiguration @params
            $VerbosePreference = "Continue"

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


            $SDNConfig = Import-PowerShellDataFile -Path C:\SCRIPTS\SDNSandbox-Config.psd1



            # Install Windows Admin Center
            Write-Verbose "Creating Admin Center folder"
            New-Item -ItemType Directory -Path 'C:\Windows Admin Center' | Out-Null
            Write-Verbose "Downloading Windows Admin Center"
            $admincenterUri = $SDNConfig.admincenterUri
            Invoke-RestMethod -Method Get -Uri $admincenterUri -OutFile 'C:\Windows Admin Center\admincenter.exe' 
            $pfxThumbPrint = (Get-ChildItem -Path Cert:\LocalMachine\my | Where-Object { $_.FriendlyName -match "Nested SDN Windows Admin Cert" }).Thumbprint
            Write-Verbose "Thumbprint: $pfxThumbPrint"
            Write-Verbose "WACPort: $WACPort"
            $WindowsAdminCenterGateway = "https://admincenter." + $fqdn
            Write-Verbose $WindowsAdminCenterGateway
            Write-Verbose "Installing and Configuring Windows Admin Center"
            $PathResolve = Resolve-Path -Path 'C:\Windows Admin Center\*.exe'
            $arguments = "/Silent"
            Start-Process -FilePath $PathResolve -ArgumentList $arguments -PassThru 
            start-sleep -Seconds 5
            $isitinstalled = $false
            $i = 0
            while ($isitinstalled -eq $false) {

                $processTest = Get-Process | Where-Object { $_.ProcessName -eq "admincenter" }
                if ($processTest -or $i -ge 40) {
            
                    Write-Verbose -Message "Waiting for AdminCenter to finish installing. This will take awhile."
                    if ($i -ge 40) {

                        $processEnd = Get-Process | Where-Object { $_.ProcessName -eq "admincenter" }
                        Write-Verbose -Message "$i:Windows Admin Center installation timed out. Ending process."
                        if ($processEnd) { 
                        
                            Stop-Process -Name admincenter -Force -Confirm:$false 
                            Stop-Process -Name admincenter.tmp -Force -Confirm:$false 

                        }
                        $isitinstalled = $true

                    }
                    $i++
                   
                    Start-Sleep -Seconds 20
            
                }
                else {
            
                    Write-Verbose -Message "WAC installation appears to have completed."
                    $isitinstalled = $true

                }


            }
            Start-Sleep -Seconds 10
            Write-Verbose -Message "Importing Admin Center Configuration PowerShell Module"
            $VerbosePreference = "SilentlyContinue"
            Import-Module 'C:\Program Files\WindowsAdminCenter\PowerShellModules\Microsoft.WindowsAdminCenter.Configuration\Microsoft.WindowsAdminCenter.Configuration.psm1'
            $VerbosePreference = "Continue"
            Write-Verbose -Message "Setting Certificate for WAC Server"
            Set-WACCertificateSubjectName -Thumbprint $pfxThumbPrint

           
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
            $SENCIP = "nc." + $SDNConfig.SDNDomainFQDN    
            $SDNEXPLORER = "Set-Location 'C:\SCRIPTS\SDNExpress-Custom';.\SDNExplorer.ps1 -NCIP $SENCIP"    
            Set-Content -Value $SDNEXPLORER -Path 'C:\users\Public\Desktop\SDN Explorer.ps1' -Force

            # set links to scripts and sdn examples
            Write-Verbose "Creating Shortcut Scripts Folder"
            $TargetFile = "C:\SCRIPTS"
            $ShortcutFile = "C:\Users\Public\Desktop\SDN Scripts.lnk"
            $WScriptShell = New-Object -ComObject WScript.Shell
            $Shortcut = $WScriptShell.CreateShortcut($ShortcutFile)
            $Shortcut.TargetPath = $TargetFile
            $Shortcut.Save()

            Write-Verbose "Creating Shortcut Scripts Folder for SDN Examples"
            $TargetFile = "C:\SDNEXAMPLES"
            $ShortcutFile = "C:\Users\Public\Desktop\SDN Examples.lnk"
            $WScriptShell = New-Object -ComObject WScript.Shell
            $Shortcut = $WScriptShell.CreateShortcut($ShortcutFile)
            $Shortcut.TargetPath = $TargetFile
            $Shortcut.Save()
    
            # Set Network Profiles

            Get-NetConnectionProfile | Where-Object { $_.NetworkCategory -eq "Public" } `
            | Set-NetConnectionProfile -NetworkCategory Private | Out-Null    
    
            # Disable Automatic Updates

            $WUKey = "HKLM:\software\Policies\Microsoft\Windows\WindowsUpdate"
            New-Item -Path $WUKey -Force | Out-Null
            New-ItemProperty -Path $WUKey -Name AUOptions -PropertyType Dword -Value 2 `
                -Force | Out-Null 
                
                
            # installing admin center again....to get around buggy installer
            Write-Verbose -Message "Installing Admin Center again to get around installer bug"
            Start-Process -FilePath $PathResolve -ArgumentList $arguments -PassThru

            $isitinstalled = $false
            $i = 0
            while ($isitinstalled -eq $false) {

                $processTest = Get-Process | Where-Object { $_.ProcessName -eq "admincenter" }
                if ($processTest -or $i -ge 30) {
            
                    Write-Verbose -Message "Waiting for AdminCenter to finish installing. This will take awhile."
                    if ($i -ge 30) {

                        $processEnd = Get-Process | Where-Object { $_.ProcessName -eq "admincenter" }
                        #Write-Verbose -Message "Windows Admin Center installation timed out. Ending process."
                        #if ($processEnd) { Stop-Process -Name admincenter -Force -Confirm:$false }
                        $isitinstalled = $true

                    }
                    $i++
                    $i
                    Start-Sleep -Seconds 20
            
                }
                else {
            
                    Write-Verbose -Message "WAC installation appears to have completed."
                    $isitinstalled = $true

                }


            }
            
           
           
            # Disable Edge First Run Experience
           
            $registryPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
            $registryKey = "HideFirstRunExperience"

            if (-not (Test-Path $registryPath)) {
                New-Item -Path $registryPath -Force
            }

            Set-ItemProperty -Path $registryPath -Name $registryKey -Value 1 | Out-Null          
            
        } 

    } 

}

function New-HyperConvergedEnvironment {

    Param (

        $localCred,
        $domainCred

    )

    Invoke-Command -ComputerName Admincenter -Credential $domainCred -ScriptBlock {

        $SDNConfig = $Using:SDNConfig
        $sdnHOSTs = @("SDNHOST1", "SDNHOST2")

        $ErrorActionPreference = "Stop"
        $VerbosePreference = "Continue"

        $domainCred = new-object -typename System.Management.Automation.PSCredential `
            -argumentlist (($SDNConfig.SDNDomainFQDN.Split(".")[0]) + "\administrator"), `
        (ConvertTo-SecureString $SDNConfig.SDNAdminPassword -AsPlainText -Force)

        foreach ($sdnHOST in $sdnHOSTs) {

            Write-Verbose "Invoking Command on $sdnHOST"

            Invoke-Command -ComputerName $sdnHOST -ArgumentList $SDNConfig -Credential $using:domainCred  -ScriptBlock {

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


                    $params = @{

                        Name                  = $sdnswitchName
                        AllowManagementOS     = $true
                        NetAdapterName        = $sdnswitchteammembers
                        EnableEmbeddedTeaming = $true
                        MinimumBandwidthMode  = "Weight"

                    }

                    New-VMSwitch @params | Out-Null

                    # Set IP Config
                    Write-Verbose "Setting IP Configuration on $sdnswitchName"
                    $sdnswitchNIC = Get-Netadapter | Where-Object { $_.Name -match $sdnswitchName }

                    $params = @{

                        InterfaceIndex = $sdnswitchNIC.InterfaceIndex
                        IpAddress      = $sdnswitchIP 
                        PrefixLength   = $sdnswitchIPpfx 
                        AddressFamily  = 'IPv4'
                        DefaultGateway = $sdnswitchGW
                        ErrorAction    = 'SilentlyContinue'

                    }

                    New-NetIPAddress @params | Out-Null

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
                    Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Set-NetAdapterAdvancedProperty -RegistryValue $SDNConfig.SDNLABMTU -RegistryKeyword "*JumboPacket"   

                }

                $ErrorActionPreference = "Stop"

                $SDNConfig = $args[0]
                $sdnswitchteammembers = @("FABRIC", "FABRIC2")
                $sdnswitchIP = $SDNConfig.($env:COMPUTERNAME + "IP").Split("/")[0]
                $sdnswitchIPpfx = $SDNConfig.($env:COMPUTERNAME + "IP").Split("/")[1]
                $sdnswitchGW = $SDNConfig.BGPRouterIP_MGMT.Split("/")[0]

                $sdnswitchCheck = Get-VMSwitch | Where-Object { $_.Name -eq "sdnSwitch" }

                if ($sdnswitchCheck) { Write-Warning "Switch already exists on $env:COMPUTERNAME. Skipping this host." }
                else {

                    $params = @{

                        sdnswitchName        = 'sdnSwitch'
                        sdnswitchIP          = $sdnswitchIP
                        sdnswitchIPpfx       = $sdnswitchIPpfx
                        sdnswitchVLAN        = $SDNConfig.mgmtVLAN
                        sdnswitchGW          = $sdnswitchGW
                        sdnswitchDNS         = $SDNConfig.SDNLABDNS
                        sdnswitchteammembers = $sdnswitchteammembers

                    }

                    New-sdnSETSwitch  @params | out-null

                }

                
            } 

            try {
                $ErrorActionPreference = "SilentlyContinue"
                Write-Verbose "Rebooting SDN Host $sdnHOST"
                #Restart-Computer $sdnHOST -Force -Confirm:$false -Credential $using:domainCred
                Get-VM $sdnHOST | Restart-Vm -Force -Wait -ErrorAction SilentlyContinue
                Write-Verbose "Sleeping 60 Seconds to let VM Reboot."
                Start-Sleep -Seconds 60
            }
            catch {

                Write-Host "Handling the Exception"
                Get-VM $sdnHOST | Restart-Vm -Force -Wait
                Write-Verbose "Sleeping 60 Seconds to let VM Reboot."
                Start-Sleep -Seconds 60

            }
        }

        # Wait until all the SDNHOSTs have been restarted

        foreach ($sdnHOST in $sdnHOSTs) {

            Write-Verbose "Checking to see if $sdnHOST is up and online"
            while ((Invoke-Command -ComputerName $sdnHOST -Credential $using:domainCred { "Test" } `
                        -ea SilentlyContinue) -ne "Test") { Start-Sleep -Seconds 1 }

        }

    }

}

function New-SDNEnvironment {

    Param (

        $domainCred,
        $SDNConfig

    )

    Invoke-Command -ComputerName admincenter -Credential $domainCred -ScriptBlock {

        Register-PSSessionConfiguration -Name microsoft.SDNNestedSetup -RunAsCredential $domainCred -MaximumReceivedDataSizePerCommandMB 1000 -MaximumReceivedObjectSizeMB 1000 | Out-Null

        Invoke-Command -ComputerName localhost -Credential $Using:domainCred -ArgumentList $Using:domainCred, $Using:SDNConfig -ConfigurationName microsoft.SDNNestedSetup -ScriptBlock {

            
            $NCConfig = @{ }

            $ErrorActionPreference = "Stop"
            $VerbosePreference = "Continue"

            # Set Credential Object

            $domainCred = $args[0]
            $SDNConfig = $args[1]

            # Set fqdn

            $fqdn = $SDNConfig.SDNDomainFQDN

            if ($SDNConfig.ProvisionLegacyNC) {

                # Set NC Configuration Data

                $NCConfig.RestName = ("NC.") + $SDNConfig.SDNDomainFQDN
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
                $NCConfig.VHDFile = "CORE.vhdx"
                $NCConfig.VHDPath = "C:\VHDS"
                $NCConfig.ManagementSubnet = $SDNConfig.MGMTSubnet
                $NCConfig.ProductKey = $SDNConfig.COREProductKey

                $NCConfig.HyperVHosts = @("SDNHOST1.$fqdn", "SDNHOST2.$fqdn")

                $NCConfig.ManagementDNS = @(
                    ($SDNConfig.BGPRouterIP_MGMT.Split("/")[0].TrimEnd("1")) + "254"
                ) 

                $NCConfig.Muxes = @(

                    @{
                        ComputerName = 'Mux01'
                        HostName     = "SDNHOST2.$($SDNConfig.SDNDomainFQDN)"
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
                        HostName     = "SDNHOST2.$($SDNConfig.SDNDomainFQDN)"
                        FrontEndIP   = ($SDNConfig.BGPRouterIP_ProviderNetwork.TrimEnd("1/24")) + "5"
                        MACAddress   = "00-1D-D8-B7-1C-03"
                        FrontEndMac  = "00-1D-D8-B7-1C-04"
                        BackEndMac   = "00-1D-D8-B7-1C-05"
                    },

                    @{
                        ComputerName = "GW02"
                        ManagementIP = ($SDNConfig.BGPRouterIP_MGMT.TrimEnd("1/24")) + "63"
                        HostName     = "SDNHOST1.$($SDNConfig.SDNDomainFQDN)"
                        FrontEndIP   = ($SDNConfig.BGPRouterIP_ProviderNetwork.TrimEnd("1/24")) + "6"
                        MACAddress   = "00-1D-D8-B7-1C-06"
                        FrontEndMac  = "00-1D-D8-B7-1C-07"
                        BackEndMac   = "00-1D-D8-B7-1C-08"
                    }

                )

                $NCConfig.NCs = @{

                    MACAddress   = "00:1D:D8:B7:1C:00"
                    ComputerName = "NC"
                    HostName     = "SDNHOST2.$($SDNConfig.SDNDomainFQDN)"
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


    } 

}

function Delete-SDNSandbox {

    param (

        $VMPlacement,
        $SDNConfig,
        $SingleHostDelete

    )

    $VerbosePreference = "Continue"

    Write-Verbose "Deleting SDN Sandbox"

    foreach ($vm in $VMPlacement) {

        $sdnHOSTName = $vm.vmHost
        $VMName = $vm.SDNHOST

        Invoke-Command -ComputerName $sdnHOSTName -ArgumentList $VMName -ScriptBlock {

            $VerbosePreference = "SilentlyContinue"

            Import-Module Hyper-V

            $VerbosePreference = "Continue"
            $vmname = $args[0]

            # Delete SBXAccess vNIC (if present)
            $vNIC = Get-VMNetworkAdapter -ManagementOS | Where-Object { $_.Name -match "SBXAccess" }
            if ($vNIC) { $vNIC | Remove-VMNetworkAdapter -Confirm:$false }

            $sdnvm = Get-VM | Where-Object { $_.Name -eq $vmname }

            If (!$sdnvm) { Write-Verbose "Could not find $vmname to delete" }

            if ($sdnvm) {

                Write-Verbose "Shutting down VM: $sdnvm)"

                Stop-VM -VM $sdnvm -TurnOff -Force -Confirm:$false 
                $VHDs = $sdnvm | Select-Object VMId | Get-VHD
                Remove-VM -VM $sdnvm -Force -Confirm:$false 

                foreach ($VHD in $VHDs) {

                    Write-Verbose "Removing $($VHD.Path)"
                    Remove-Item -Path $VHD.Path -Force -Confirm:$false

                }

            }


        }

    }

    If ($SingleHostDelete -eq $true) {
        
        $RemoveSwitch = Get-VMSwitch | Where-Object { $_.Name -match $SDNConfig.InternalSwitch }

        If ($RemoveSwitch) {

            Write-Verbose "Removing Internal Switch: $($SDNConfig.InternalSwitch)"
            $RemoveSwitch | Remove-VMSwitch -Force -Confirm:$false

        }

    }

    Write-Verbose "Deleting RDP links"

    Remove-Item C:\Users\Public\Desktop\AdminCenter.lnk -Force -ErrorAction SilentlyContinue


    Write-Verbose "Deleting NetNAT"
    Get-NetNAT | Remove-NetNat -Confirm:$false

    Write-Verbose "Deleting Internal Switches"
    Get-VMSwitch | Where-Object { $_.SwitchType -eq "Internal" } | Remove-VMSwitch -Force -Confirm:$false


}

function Add-WACtenants {

    param (

        $SDNLabSystems,
        $SDNConfig,
        $domainCred

    )

    $VerbosePreference = "Continue"
    Write-Verbose "Invoking Command to add Windows Admin Center Tenants"

    Invoke-Command -ComputerName Admincenter -Credential $domainCred -ScriptBlock {   
     
        $domainCred = $using:domainCred
        $SDNLabSystems = $using:SDNLabSystems
        $SDNConfig = $using:SDNConfig
        $VerbosePreference = "Continue" 

        Invoke-Command -ComputerName admincenter -Credential $domainCred -ScriptBlock {
                     
        
            # Set Variables

            $SDNConfig = Import-PowerShellDataFile -Path C:\SCRIPTS\SDNSandbox-Config.psd1
            $fqdn = $SDNConfig.SDNDomainFQDN
            $SDNLabSystems = @("bgp-tor-router", "$($SDNConfig.DCName).$fqdn", "NC.$fqdn", "MUX01.$fqdn", "GW01.$fqdn", "GW02.$fqdn")
            $VerbosePreference = "Continue"
            $domainCred = new-object -typename System.Management.Automation.PSCredential `
                -argumentlist (($SDNConfig.SDNDomainFQDN.Split(".")[0]) + "\administrator"), `
            (ConvertTo-SecureString $SDNConfig.SDNAdminPassword -AsPlainText -Force)
 


            # Set Constrained Delegation for NC/MUX/GW Virtual Machines for Windows Admin Center

            $SDNvms = ("NC", "MUX01", "GW01", "GW02")

            $VerbosePreference = "Continue"

            foreach ($SDNvm in $SDNvms) {

                Write-Verbose "Setting Delegation for $SDNvm"
                $gateway = "AdminCenter"
                Write-Verbose "gateway = $gateway"
                $node = $SDNvm
                Write-Verbose "node = $node"
                $gatewayObject = Get-ADComputer -Identity $gateway -Credential $domainCred
                Write-Verbose "GatewayObject = $gatewayObject"
                $nodeObject = Get-ADComputer -Identity $node -Credential $domainCred
                Write-Verbose "nodeObject = $nodeObject"
                Set-ADComputer -Identity $nodeObject -PrincipalsAllowedToDelegateToAccount $gatewayObject -Credential $domainCred

            }



            foreach ($SDNLabSystem in $SDNLabSystems) {


                $json = [pscustomobject]@{

                    id   = "msft.sme.connection-type.server!$SDNLabSystem"
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

                    Uri         = $uri
                    Method      = 'Put'
                    Body        = $payload
                    ContentType = $content
                    Credential  = $domainCred

                }

                Invoke-RestMethod @param -UseBasicParsing -DisableKeepAlive | Out-Null

   
            }
        
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
        $VerbosePreference = "SilentlyContinue"
        $ErrorActionPreference = "Stop"


        Register-PSSessionConfiguration -Name microsoft.SDNNestedS2D -RunAsCredential $domainCred -MaximumReceivedDataSizePerCommandMB 1000 -MaximumReceivedObjectSizeMB 1000 | Out-Null

        Invoke-Command -ComputerName $Using:SDNClusterNode -ArgumentList $SDNConfig, $domainCred -Credential $domainCred -ConfigurationName microsoft.SDNNestedS2D -ScriptBlock {

            $SDNConfig = $args[0]
            $domainCred = $args[1]


            # Create S2D Cluster

            $SDNConfig = $args[0]
            $sdnHOSTs = @("SDNHOST1", "SDNHOST2")

            Write-Verbose "Creating Cluster: SDNCluster"

            $VerbosePreference = "SilentlyContinue"

            Import-Module FailoverClusters 
            Import-Module Storage

            $VerbosePreference = "Continue"

            $ClusterIP = ($SDNConfig.MGMTSubnet.TrimEnd("0/24")) + "252"
            $ClusterName = "SDNCluster"

            # Create Cluster

            $VerbosePreference = "SilentlyContinue"

            New-Cluster -Name $ClusterName -Node $sdnHOSTs -StaticAddress $ClusterIP `
                -NoStorage -WarningAction SilentlyContinue | Out-Null

            $VerbosePreference = "Continue"

            # Invoke Command to enable S2D on SDNCluster        
            
            Enable-ClusterS2D -Confirm:$false -Verbose

            # Wait for Cluster Performance History Volume to be Created
            while (!$PerfHistory) {

                Write-Verbose "Waiting for Cluster Performance History volume to come online."
                Start-Sleep -Seconds 10            
                $PerfHistory = Get-ClusterResource | Where-Object { $_.Name -match 'ClusterPerformanceHistory' }
                if ($PerfHistory) { Write-Verbose "Cluster Perfomance History volume online." }            

            }


            Write-Verbose "Setting Physical Disk Media Type"

            Get-PhysicalDisk | Where-Object { $_.Size -lt 127GB } | Set-PhysicalDisk -MediaType HDD | Out-Null

            $params = @{
            
                FriendlyName            = "Volume01" 
                FileSystem              = 'CSVFS_ReFS'
                StoragePoolFriendlyName = 'S2D on SDNCluster'
                ResiliencySettingName   = 'Mirror'
                PhysicalDiskRedundancy  = 1
                AllocationUnitSize      = 64KB
                
            }


            Write-Verbose "Creating Physical Disk"

            Start-Sleep -Seconds 60
            New-Volume @params -UseMaximumSize  | Out-Null

            # Set Virtual Environment Optimizations

            Write-Verbose "Setting Virtual Environment Optimizations"


             

            $VerbosePreference = "SilentlyContinue"
            Get-storagesubsystem clus* | set-storagehealthsetting -name “System.Storage.PhysicalDisk.AutoReplace.Enabled” -value “False”
            Set-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Services\spaceport\Parameters -Name HwTimeout -Value 0x00007530
            $VerbosePreference = "Continue"
           
            # Rename Storage Network Adapters

            Write-Verbose "Renaming Storage Network Adapters"

        (Get-Cluster -Name SDNCluster | Get-ClusterNetwork | Where-Object { $_.Address -eq ($sdnconfig.storageAsubnet.Replace('/24', '')) }).Name = 'StorageA'
        (Get-Cluster -Name SDNCluster | Get-ClusterNetwork | Where-Object { $_.Address -eq ($sdnconfig.storageBsubnet.Replace('/24', '')) }).Name = 'StorageB'
        (Get-Cluster -Name SDNCluster | Get-ClusterNetwork | Where-Object { $_.Address -eq ($sdnconfig.MGMTSubnet.Replace('/24', '')) }).Name = 'Public'


            # Set Allowed Networks for Live Migration

            Write-Verbose "Setting allowed networks for Live Migration"

            Get-ClusterResourceType -Name "Virtual Machine" -Cluster SDNCluster | Set-ClusterParameter -Cluster SDNCluster -Name MigrationExcludeNetworks `
                -Value ([String]::Join(";", (Get-ClusterNetwork -Cluster SDNCluster | Where-Object { $_.Name -notmatch "Storage" }).ID))

        } | Out-Null

    } 


}

function test-internetConnect {

    $testIP = '1.1.1.1'
    $ErrorActionPreference = "Stop"  
    $intConnect = Test-Connection -ComputerName $testip -Quiet -Count 2

    if (!$intConnect) {

        Write-Error "Unable to connect to Internet. An Internet connection is required."

    }

}

function set-hostnat {

    param (

        $SDNConfig
    )

    $VerbosePreference = "Continue" 

    $switchExist = Get-NetAdapter | Where-Object { $_.Name -match $SDNConfig.natHostVMSwitchName }

    if (!$switchExist) {

        Write-Verbose "Creating Internal NAT Switch: $($SDNConfig.natHostVMSwitchName)"
        # Create Internal VM Switch for NAT
        New-VMSwitch -Name $SDNConfig.natHostVMSwitchName -SwitchType Internal | Out-Null

        Write-Verbose "Applying IP Address to NAT Switch: $($SDNConfig.natHostVMSwitchName)"
        # Apply IP Address to new Internal VM Switch
        $intIdx = (Get-NetAdapter | Where-Object { $_.Name -match $SDNConfig.natHostVMSwitchName }).ifIndex
        $natIP = $SDNConfig.natHostSubnet.Replace("0/24", "1")

        New-NetIPAddress -IPAddress $natIP -PrefixLength 24 -InterfaceIndex $intIdx | Out-Null

        # Create NetNAT

        Write-Verbose "Creating new NETNAT"
        New-NetNat -Name $SDNConfig.natHostVMSwitchName  -InternalIPInterfaceAddressPrefix $SDNConfig.natHostSubnet | Out-Null

    }

}

function enable-singleSignOn {

    param (

        $SDNConfig
    )

    $domainCred = new-object -typename System.Management.Automation.PSCredential `
        -argumentlist (($SDNConfig.SDNDomainFQDN.Split(".")[0]) + "\administrator"), `
    (ConvertTo-SecureString $SDNConfig.SDNAdminPassword -AsPlainText -Force)

    Invoke-Command -ComputerName ("$($SDNConfig.DCName).$($SDNConfig.SDNDomainFQDN)") -ScriptBlock {

        Get-ADComputer -Filter * | Set-ADComputer -PrincipalsAllowedToDelegateToAccount (Get-ADComputer AdminCenter)


    } -Credential $domainCred

}

#endregion
   
#region Main
    
$WarningPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop" 

#Get Start Time
$starttime = Get-Date
   
    
# Import Configuration Module

$SDNConfig = Import-PowerShellDataFile -Path $ConfigurationDataFile
Copy-Item $ConfigurationDataFile -Destination .\Applications\SCRIPTS -Force

# Set VM Host Memory
$totalPhysicalMemory = (Get-CimInstance -ClassName 'Cim_PhysicalMemory' | Measure-Object -Property Capacity -Sum).Sum / 1GB
$availablePhysicalMemory = (([math]::Round(((((Get-Counter -Counter '\Hyper-V Dynamic Memory Balancer(System Balancer)\Available Memory For Balancing' -ComputerName $env:COMPUTERNAME).CounterSamples.CookedValue) / 1024) - 36) / 2))) * 1073741824
$SDNConfig.NestedVMMemoryinGB = $availablePhysicalMemory

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

# Define SDN host Names. Please do not change names as these names are hardcoded in the setup.
$sdnHOSTs = @("SDNMGMT", "SDNHOST1", "SDNHOST2")


# Delete configuration if specified

if ($Delete) {

    if ($SDNConfig.MultipleHyperVHosts) {

        $params = @{

            MultipleHyperVHosts = $SDNConfig.MultipleHyperVHostNames
            SDNHOSTs            = $sdnHOSTs    

        }       

        $VMPlacement = Select-VMHostPlacement @params
        $SingleHostDelete = $false
    }     
    elseif (!$SDNConfig.MultipleHyperVHosts) { 
    
        Write-Verbose "This is a single host installation"
        $VMPlacement = Select-SingleHost -SDNHOSTs $sdnHOSTs
        $SingleHostDelete = $true

    }

    Delete-SDNSandbox -SDNConfig $SDNConfig -VMPlacement $VMPlacement -SingleHostDelete $SingleHostDelete

    Write-Verbose "Successfully Removed the SDN Sandbox"
    exit

}
    
# Set Variables from config file

$NestedVMMemoryinGB = $SDNConfig.NestedVMMemoryinGB
$guiVHDXPath = $SDNConfig.guiVHDXPath
$coreVHDXPath = $SDNConfig.coreVHDXPath
$HostVMPath = $SDNConfig.HostVMPath
$InternalSwitch = $SDNConfig.InternalSwitch
$natDNS = $SDNConfig.natDNS
$natSubnet = $SDNConfig.natSubnet
$natConfigure = $SDNConfig.natConfigure   


$VerbosePreference = "SilentlyContinue" 
Import-Module Hyper-V 
$VerbosePreference = "Continue"
$ErrorActionPreference = "Stop"
    

# Enable PSRemoting

Write-Verbose "Enabling PS Remoting on client..."
$VerbosePreference = "SilentlyContinue"
Enable-PSRemoting
Set-Item WSMan:\localhost\Client\TrustedHosts * -Confirm:$false -Force
$VerbosePreference = "Continue"

# Verify Applications

Resolve-Applications -SDNConfig $SDNConfig

# Verify Internet Connectivity
test-internetConnect
    
# if single host installation, set up installation parameters

if (!$SDNConfig.MultipleHyperVHosts) {

    Write-Verbose "No Multiple Hyper-V Hosts defined. Using Single Hyper-V Host Installation"
    Write-Verbose "Testing VHDX Path"

    $params = @{

        guiVHDXPath  = $guiVHDXPath
        coreVHDXPath = $coreVHDXPath
    
    }

    Test-VHDPath @params

    Write-Verbose "Generating Single Host Placement"

    $VMPlacement = Select-SingleHost -SDNHOSTs $sdnHOSTs

    Write-Verbose "Creating Internal Switch"

    $params = @{

        pswitchname = $InternalSwitch
        SDNConfig   = $SDNConfig
    
    }

    New-InternalSwitch @params

    Write-Verbose "Creating NAT Switch"

    set-hostnat -SDNConfig $SDNConfig

    $VMSwitch = $InternalSwitch

    Write-Verbose "Getting local Parent VHDX Path"

    $params = @{

        guiVHDXPath = $guiVHDXPath
        HostVMPath  = $HostVMPath
    
    }


    $ParentVHDXPath = Get-guiVHDXPath @params

    Set-LocalHyperVSettings -HostVMPath $HostVMPath

    $params = @{

        coreVHDXPath = $coreVHDXPath
        HostVMPath   = $HostVMPath
    
    }

    $coreParentVHDXPath = Get-coreVHDXPath @params


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

        guiVHDXPath  = $guiVHDXPath
        coreVHDXPath = $coreVHDXPath
    
    }


    Test-VHDPath @params

    Write-Verbose "Generating Multiple Host Placement"

    $params = @{

        MultipleHyperVHosts = $SDNConfig.MultipleHyperVHostNames
        SDNHOSTs            = $sdnHOSTs
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


    $coreParentVHDXPath = Get-coreVHDXPath @params


    $VMSwitch = $SDNConfig.MultipleHyperVHostExternalSwitchName

    # Write-Verbose "Creating vNIC on $env:COMPUTERNAME"
    New-HostvNIC -SDNConfig $SDNConfig -localCred $localCred

}
    
    
# if multiple host installation, copy the parent VHDX file to the specified Parent VHDX Path

if ($SDNConfig.MultipleHyperVHosts) {

    Write-Verbose "Copying VHDX Files to Host"

    $params = @{

        MultipleHyperVHosts = $SDNConfig.MultipleHyperVHostNames
        coreVHDXPath        = $coreVHDXPath
        HostVMPath          = $HostVMPath
        guiVHDXPath         = $guiVHDXPath 

    }

    Copy-VHDXtoHosts @params
}
    
    
# if single host installation, copy the parent VHDX file to the specified Parent VHDX Path

if (!$SDNConfig.MultipleHyperVHosts) {

    Write-Verbose "Copying VHDX Files to Host"

    $params = @{

        coreVHDXPath = $coreVHDXPath
        HostVMPath   = $HostVMPath
        guiVHDXPath  = $guiVHDXPath 
    }

    Copy-VHDXtoHost @params
}
    
    
# Create Virtual Machines

$vmMacs = @()

foreach ($VM in $VMPlacement) {

    Write-Verbose "Generating the VM: $VM" 

    $params = @{

        VMHost     = $VM.VMHost
        SDNHOST    = $VM.SDNHOST
        HostVMPath = $HostVMPath
        VMSwitch   = $VMSwitch
        SDNConfig  = $SDNConfig

    }

    $vmMac = New-NestedVM @params

    Write-Verbose "Returned VMMac is $vmMac"

    $vmMacs += [pscustomobject]@{

        Hostname = $VM.SDNHOST
        vmMAC    = $vmMac

    }
        
}
    
# Inject Answer Files and Binaries into Virtual Machines

$params = @{

    VMPlacement  = $VMPlacement
    HostVMPath   = $HostVMPath
    SDNConfig    = $SDNConfig
    guiVHDXPath  = $guiVHDXPath
    coreVHDXPath = $coreVHDXPath
    vmMacs       = $vmMacs

}

Add-Files @params
    
# Start Virtual Machines

Start-SDNHOSTS -VMPlacement $VMPlacement
    
# Wait for SDNHOSTs to come online

Write-Verbose "Waiting for VMs to provision and then come online"

$params = @{

    VMPlacement = $VMPlacement
    localcred   = $localCred

}

Test-SDNHOSTVMConnection @params
    
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

    scriptpath  = 'Get-Netadapter ((Get-NetAdapterAdvancedProperty | Where-Object {$_.DisplayValue -eq "SDN"}).Name) | Rename-NetAdapter -NewName FABRIC'
    VMPlacement = $VMPlacement
    localcred   = $localCred

}

Start-PowerShellScriptsOnHosts @params

$params.scriptpath = 'Get-Netadapter ((Get-NetAdapterAdvancedProperty | Where-Object {$_.DisplayValue -eq "SDN2"}).Name) | Rename-NetAdapter -NewName FABRIC2'

Start-PowerShellScriptsOnHosts @params
    
# Restart Machines

$params.scriptpath = "Restart-Computer -Force"
Start-PowerShellScriptsOnHosts @params
Start-Sleep -Seconds 30
    
# Wait for SDNHOSTs to come online

Write-Verbose "Waiting for VMs to restart..."

$params = @{

    VMPlacement = $VMPlacement
    localcred   = $localCred

}

Test-SDNHOSTVMConnection @params
    
# This step has to be done as during the Hyper-V install as hosts reboot twice.

Write-Verbose "Ensuring that all VMs have been restarted after Hyper-V install.."
Test-SDNHOSTVMConnection @params
    
# Create NAT Virtual Switch on SDNMGMT

if ($natConfigure) {

    if (!$SDNConfig.MultipleHyperVHosts) { $SwitchName = $SDNConfig.InternalSwitch }
    else { $SwitchName = $SDNConfig.MultipleHyperVHostExternalSwitchName }
    
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
    
# Provision SDNMGMT VMs (DC, Router, and AdminCenter)

Write-Verbose  "Configuring Management VM"


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

    SDNConfig      = $SDNConfig
    DomainCred     = $domainCred
    SDNClusterNode = 'SDNHOST2'

}


New-SDNS2DCluster @params



# Install and Configure Network Controller if specified

If ($SDNConfig.ProvisionLegacyNC) {

    $params = @{

        SDNConfig  = $SDNConfig
        domainCred = $domainCred

    }

    New-SDNEnvironment @params

    # Add Systems to Windows Admin Center

    $fqdn = $SDNConfig.SDNDomainFQDN

    $SDNLabSystems = @("bgp-tor-router", "$($SDNConfig.DCName).$fqdn", "NC.$fqdn", "MUX01.$fqdn", "GW01.$fqdn", "GW02.$fqdn")

    # Add VMs for Domain Admin

    $params = @{

        SDNLabSystems = $SDNLabSystems 
        SDNConfig     = $SDNConfig
        domainCred    = $domainCred

    }

    #   Add-WACtenants @params


    # Add VMs for NC Admin

    $params.domainCred = $NCAdminCred

    #   Add-WACtenants @params

    # Enable Single Sign On

    Write-Verbose "Enabling Single Sign On in WAC"
    enable-singleSignOn -SDNConfig $SDNConfig 
    
}


# Finally - Add RDP Link to Desktop

Remove-Item C:\Users\Public\Desktop\AdminCenter.lnk -Force -ErrorAction SilentlyContinue
$wshshell = New-Object -ComObject WScript.Shell
$lnk = $wshshell.CreateShortcut("C:\Users\Public\Desktop\AdminCenter.lnk")
$lnk.TargetPath = "%windir%\system32\mstsc.exe"
$lnk.Arguments = "/v:AdminCenter"
$lnk.Description = "AdminCenter link for SDN Sandbox."
$lnk.Save()

$endtime = Get-Date

$timeSpan = New-TimeSpan -Start $starttime -End $endtime


Write-Verbose "`nSuccessfully deployed the SDN Sandbox"

Write-Host "Deployment time was $($timeSpan.Hours) hour and $($timeSpan.Minutes) minutes." -ForegroundColor Green
 
$ErrorActionPreference = "Continue"
$VerbosePreference = "SilentlyContinue"
$WarningPreference = "Continue"
    
#endregion     
 
