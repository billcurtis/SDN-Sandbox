@{

# This is the PowerShell datafile used to provide configuration information for the SDN Nested lab environment. Product keys and password are not encrypted and will be available on all hosts during installation.

# Multiple Host Setup Parameters
MultipleHyperVHosts = $false                             # Set to $true if deploying the Nested VM environment across multiple hosts. Set to $false if deploying to a single host. 
MultipleHyperVHostNames = @("XEON8","XEON9")             # Array of all of the hosts which make up the Nested VM environment. Only 2 or 4 hosts supported
MultipleHyperVHostExternalSwitchName = "ExternalSwitch"  # Name of the External Hyper-V VM Switch identical on all hosts.

# VHDX Paths 
guiVHDXPath = "C:\2019 VHDS\2019_GUI.vhdx"                          # This value controls the location of the GUI VHDX.  
coreVHDXPath = "C:\2019 VHDS\2019_CORE.vhdx"                        # This value controls the location of the Core VHDX.  
consoleVHDXPath = "C:\2019 VHDS\Console.vhdx"                       # This value controls the location of the Windows 10 Console VHDX.  

# SDN Lab Admin Password
SDNAdminPassword = "Lajolie36"                           # Password for all local and domain accounts. Do not include special characters in the password otherwise some unattended installs may fail.

# VM Configuration
HostVMPath = "V:\"                                       # This value controls the path where the Nested VMs will be stored on all hosts.
NestedVMMemoryinGB = 13GB                                # This value controls the amount of RAM for each Nested Hyper-V Host (SDNHOST1-3).
SDNMGMTMemoryinGB = 13GB                                 # This value controls the amount of RAM for the SDNMGMT Nested VM which contains only the Console, Router, Admincenter, and DC VMs.
InternalSwitch = "Fabrikam"                               # Name of internal switch that the SDN Lab VMs will use in Single Host mode. This only applies when using a single host.


# ProductKeys
COREProductKey =  "6XBNX-4JQGW-QX6QG-74P76-72V67"        # Product Key for Windows Server 2016-2019 Core Datacenter Installation
GUIProductKey =   "6XBNX-4JQGW-QX6QG-74P76-72V67"        # Product key for Windows Server 2016-2019 (Desktop Experience) Datacenter Installation
Win10ProductKey = "K6KXM-9DNM4-B4V79-WH2WM-7MJVR"        # Product key for Windows 10 Installation

# SDN Lab Domain
SDNDomainFQDN = "fabrikam.com"                          # Limit name (not the .com) to 14 characters as the name will be used as the NetBIOS name. 
DCName = "fabrikamDC"                                   # Name of the domain controller


# NAT Configuration
natConfigure = $true
natSubnet = "192.168.46.0/24"                            # This value is the subnet is the NAT router will use to route to  SDNMGMT to access the Internet. It can be any /24 subnet and is only used for routing.
natExternalVMSwitchName = "Internet"                     # Name of external virtual switch on the physical host that has access to the Internet.
natVLANID = 131                                          # VLAN ID (if needed) that for access to the external network that requires Internet access. (Note: The network will require DHCP).
natDNS = "1.1.1.1"                                       # DNS address for forwarding from Domain Controller.

# Global MTU
SDNLABMTU = 9014                                         # Controls the MTU for all Hosts. If using multiple physical hosts. Ensure that you have configured MTU on physical nics on the hosts to match this value.


#SDN Provisioning
ProvisionNC = $true                                      # Provisions Network Controller Automatically.
ConfigureBGPpeering = $true                              # Peers the GW and MUX VMs with the BGP-ToR-Router automatically if ProvisionNC = $true


################################################################################################################
# Edit at your own risk
################################################################################################################



# SDNMGMT Management VM's Memory Settings
MEM_DC = 2GB                                             # Memory provided for the Domain Controller VM
MEM_BGP = 2GB                                            # Memory provided for the BGP-ToR-Router
MEM_Console = 3GB                                        # Memory provided for the Windows 10 Console VM
MEM_WAC = 2GB                                            # Memory provided for the Windows Admin Center VM

#Cluster S2D Storage Disk Size (per disk)
S2D_Disk_Size = 80GB                                     # Disk size for each of the 4 dynamic VHD disks attached to the 3 SDNHOST VMs that will be used to create the SDNCLUSTER


# SDN Host IPs
SDNMGMTIP = "192.168.1.11/24"
SDNHOST1IP = "192.168.1.12/24"
SDNHOST2IP = "192.168.1.13/24"
SDNHOST3IP = "192.168.1.14/24"

# Physical Host Internal IP
PhysicalHostInternalIP = "192.168.1.10"

# SDN Lab DNS
SDNLABDNS = "192.168.1.254" 

# SDN Lab Gateway
SDNLABRoute = "192.168.1.1"

#Management IPs for Console and Domain Controller
DCIP =               "192.168.1.254/24"
CONSOLEIP =          "192.168.1.10/24"
WACIP =              "192.168.1.9/24"

# BGP Router Config
BGPRouterIP_MGMT =     "192.168.1.1/24"
BGPRouterIP_ProviderNetwork  = "172.16.0.1/24"
BGPRouterIP_VLAN200 =  "192.168.200.1/24"
BGPRouterASN = "65534"


# VLANs
providerVLAN = 12
vlan200VLAN = 200
mgmtVLAN = 0

# Subnets
MGMTSubnet= "192.168.1.0/24"
GRESubnet = "50.50.50.0/24"
ProviderSubnet = "172.16.0.0/24"
VLAN200Subnet = "192.168.200.0/24"
VLAN200VMNetworkSubnet = "192.168.44.0/24"

# VIP Subnets
PrivateVIPSubnet = "30.30.30.0/24" 
PublicVIPSubnet = "40.40.40.0/24"

# SDN ASN
SDNASN = 64512

# Windows Admin Center HTTPS Port
WACport = 443

# SDDCInstall
SDDCInstall = $true 

}