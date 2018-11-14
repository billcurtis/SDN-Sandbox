$SDNConfig = Import-PowerShellDataFile  'C:\SDNEXPRESS (Nested Version)\NestedSDN-Config.psd1'

$ErrorActionPreference = "Stop"
$VerbosePreference = "Continue"


# Set Credential Object
$domainCred = new-object -typename System.Management.Automation.PSCredential `
    -argumentlist (($SDNConfig.SDNDomainFQDN.Split(".")[0]) + "\administrator"), `
(ConvertTo-SecureString $SDNConfig.SDNAdminPassword -AsPlainText -Force)

# Set fqdn
$fqdn = $SDNConfig.SDNDomainFQDN


Invoke-Command -ComputerName SDNHOST1 -Credential $domainCred -ScriptBlock {


$ErrorActionPreference = "Stop"
$VerbosePreference = "Continue"



# Create TENANTVM1 and TENANTVM2

Write-Verbose "Copying Over VHDX files for TenantVMs. This can take some time..."

$OSver = Get-WmiObject Win32_OperatingSystem | Where-Object {$_.Name -match "Windows Server 2019"}

If ($OSVer) {$csvfolder = "S2D_vDISK1"}
else {$csvfolder = "Volume1"}

$TenantVMs = @("TenantVM1","TenantVM2")


foreach ($TenantVM in $TenantVMs) {

$Password = $using:SDNConfig.SDNAdminPassword
$ProductKey = $using:SDNConfig.GUIProductKey
$Domain = $using:fqdn
$VMName = $TenantVM
$Gateway = "192.168.33.1"


# Copy over GUI VHDX

Write-Verbose "Copying GUI.VHDX for TenantVM..."
$tenantpath = New-Item -Path C:\ClusterStorage\$csvfolder -Name $TenantVM -ItemType Directory -Force

Copy-Item -Path '\\console\C$\VHDs\GUI.vhdx' -Destination $tenantpath.FullName -Force

# Inject Answer File
Write-Verbose "Injecting Answer File for TenantVM $VMName..."
$MountPath = New-Item -Path D:\ -Name $TenantVM -ItemType Directory -Force
$ImagePath = "\\sdncluster\ClusterStorage`$\$csvfolder\$VMName\GUI.vhdx"
Mount-WindowsImage -ImagePath $ImagePath -Index 1 -Path $MountPath.FullName | Out-Null

# Create Panther Folder
Write-Verbose "Creating Panther folder.."
$pathPanther = New-Item -Path (($MountPath.FullName) + ("\Windows\Panther")) -ItemType Directory -Force

# Generate Panther Folder

$unattend = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <ProductKey>$ProductKey</ProductKey>
            <ComputerName>$VMName</ComputerName>
            <RegisteredOwner>$ENV:USERNAME</RegisteredOwner>
        </component>
        <component name="Networking-MPSSVC-Svc" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <DomainProfile_EnableFirewall>false</DomainProfile_EnableFirewall>
            <PrivateProfile_EnableFirewall>false</PrivateProfile_EnableFirewall>
            <PublicProfile_EnableFirewall>false</PublicProfile_EnableFirewall>
        </component>
        <component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <fDenyTSConnections>false</fDenyTSConnections>
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

Set-Content -Value $unattend -Path $(($MountPath.FullName) + ("\Windows\Panther\Unattend.xml")) -Force
Write-Verbose "Commiting and Dismounting Image..."
Dismount-WindowsImage -Path $MountPath.FullName -Save | Out-Null


}

}