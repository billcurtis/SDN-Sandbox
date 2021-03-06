
@{
   ScriptVersion = '2.0'
   VHDPath = 'D:\VHDS'
   VHDFile = 'Core.vhdx'
   VMLocation = 'D:\SDNVMS'
   JoinDomain = 'contoso.com'
   ManagementVLANID = '0'
   ManagementSubnet = '192.168.1.0/24'
   ManagementGateway = '192.168.1.1'
   ManagementDNS = @(
'192.168.1.254'
   )
   DomainJoinUsername = 'contoso\Administrator'
   DomainJoinSecurePassword = '01000000d08c9ddf0115d1118c7a00c04fc297eb01000000bfb9f8ffed053d4790ef486ea05fbdca0000000002000000000003660000c000000010000000da22102e96cfbd97ce3fda2f10d7be180000000004800000a000000010000000b5c084035ddeb48651b6da8c8e0fec7518000000e23ffa7a1c1a374315ebc598aef98c56cf1e8971ffde3f9414000000f7ba3152a3301cb3e0e98d47bfd508d8595f0084'
   LocalAdminSecurePassword = '01000000d08c9ddf0115d1118c7a00c04fc297eb01000000bfb9f8ffed053d4790ef486ea05fbdca0000000002000000000003660000c000000010000000e78482632017da6841c7972ad4b095500000000004800000a0000000100000007979ec3c66987608e9b7a7811714e6d418000000f2ca34dfe3ac982a4a022fa788ce6c1941eb9fcfec9e44ee14000000f85239c92723b06cb8b1d091735b20ba5f133dae'
   LocalAdminDomainUser = 'contoso\administrator'
   RestName = 'CTL-NC01.contoso.com'
   HyperVHosts = @('sdnhost2.contoso.com', 'sdnhost3.contoso.com', 'sdnhost4.contoso.com' )
   NCs = @(
      @{
         ComputerName = 'CTL-NC01'
         HostName = 'sdnhost2.contoso.com'
         ManagementIP = '192.168.1.60'
         MACAddress = '00:1D:D8:B7:1C:00'
      }
   )
   Muxes = @(
      @{
         ComputerName = 'CTL-Mux01'
         HostName = 'sdnhost3.contoso.com'
         ManagementIP = '192.168.1.61'
         MACAddress = '00-1D-D8-B7-1C-01'
         PAIPAddress = '172.16.0.4'
         PAMACAddress = '00-1D-D8-B7-1C-02'
      }
   )
   Gateways = @(
      @{
         ComputerName = 'CTL-GW01'
         HostName = 'sdnhost4.contoso.com'
         ManagementIP = '192.168.1.62'
         MACAddress = '00-1D-D8-B7-1C-03'
         FrontEndIp = '172.16.0.5'
         FrontEndMac = '00-1D-D8-B7-1C-04'
         BackEndMac = '00-1D-D8-B7-1C-05'
      },
      @{
         ComputerName = 'CTL-GW02'
         HostName = 'sdnhost2.contoso.com'
         ManagementIP = '192.168.1.63'
         MACAddress = '00-1D-D8-B7-1C-06'
         FrontEndIp = '172.16.0.6'
         FrontEndMac = '00-1D-D8-B7-1C-07'
         BackEndMac = '00-1D-D8-B7-1C-08'
      }
   )
   NCUsername = 'contoso\administrator'
   NCSecurePassword = '01000000d08c9ddf0115d1118c7a00c04fc297eb01000000bfb9f8ffed053d4790ef486ea05fbdca0000000002000000000003660000c000000010000000588ad780091191f3a4af6cf02a5ca36c0000000004800000a000000010000000a7e68dcb23a258b78b1d0bdbf5e448ba1800000025a7b8e625c0b854db3b66444216a0e478472dec3c78fbd014000000a9d4eab56e2b0579ce6909281996d7c9db6ce6bb'
   PAVLANID = '12'
   PASubnet = '172.16.0.0/24'
   PAGateway = '172.16.0.1'
   PAPoolStart = '172.16.0.5'
   PAPoolEnd = '172.16.0.254'
   SDNMacPoolStart = '00-1D-D8-B7-1C-09'
   SDNMacPoolEnd = '00:1D:D8:B7:1F:FF'
   SDNASN = '64512'
   Routers = @(
      @{
         RouterASN = '65534'
         RouterIPAddress = '172.16.0.1'
      }
   )
   PrivateVIPSubnet = '30.30.30.0/24'
   PublicVIPSubnet = '40.40.40.0/24'
   PoolName = 'DefaultAll'
   GRESubnet = '50.50.50.0/24'
   Capacity = '10000'
}
