# Scenario 01 : Create Tenant VMs and attach to SDN VM Network


## Objective

In this scenario, you have been asked to create two Windows Server Datacenter tenant VMs in a SDN VM Network. These tenant VMs will only be able to talk with one another.

You come up with the following action plan:

1. Create a SDN VM Network named **TenantNetwork1** in Windows Admin Center with a Address Prefix of **192.172.0.0/16**

2. Carve out a subnet named **TenantSubnet1** from the **TenantNetwork1** Address Prefix that you just created. This subnet will be: **192.172.33.0/24**

3. Create the VHDX files for VMs **TenantVM1** and **TenantVM2** on the Cluster Storage in the S2D cluster: **SDNCluster**

4. In Windows Admin Center, create **TenantVM1** and **TenantVM2** virtual machines and then connect their network adapters to **TenantSubnet1**

5. Run Ping tests to validate VXLAN communication between both VMs.


# Step 01:   Create a SDN VM Network named **TenantNetwork1** in Windows Admin Center with a Address Prefix of **192.172.0.0/16**

1. Log into **Console** using RDP

2. Open the link to Windows Admin Center on the desktop

3. In **Windows Admin Center**, add a **Hyper-Converged Cluster Connection** to SDNCluster and your network controller if you haven't already done so.

![alt text](res/1-01.png "Add Hyper-Converged Cluster Connection")

4. Navigate to **Windows Admin Center -> sdncluster -> Virtual Networks**. In **Virtual Networks**, select **Inventory**.

5. In **Inventory** select **+ New**

![alt text](res/1-02.png "Inventory Screen for Virtual Networks")

6. In the Virtual Network dialog, fill in the following and then click **Submit**:

|   |   |
|---|---|
| Virtual Network Name:  |  **TenantNetwork1**  |
| Address Prefixes:  | add  **192.172.0.0/16**  |
| Subnet Name: | add **TenantSubnet1**   |
| Subnet Address Prefix: | add **192.172.33.0/24**  |

7. Wait about a minute and then you should see the following in your Virtual Networks inventory:

![alt text](res/1-03.png "Inventory Screen for Virtual Networks")

8. Step 01 is now complete.



# Step 02: Carve out a subnet named **TenantSubnet1** from the **TenantNetwork1** Address Prefix that you just created. This subnet will be: **192.172.33.0/24**

1. In the **Console** VM, open a **PowerShell** console with Admin rights.

2. In the PowerShell console, navigate to ``C:\SCRIPTS\Scenarios\01_Create_TenantVMs\``

3. Run ``.\01_Create_TenantVMs.ps1``

4. Wait for the script to successfully complete

> This script copies the GUI.VHDX to folders on the C:\ClusterStorage\<volume>\ drive, injects answer files that specify the VM's Name, Product Key, and also disables Windows Firewall so you can easily perform a ping test.

5. Step 02 is now complete.



# Step 03: Create **TenantVM1** and **TenantVM2** virtual machines and then connect their network adapters to **TenantSubnet1**

1. Go to **Windows Admin Center**

2. Navigate to **Windows Admin Center -> sdncluster -> Virtual Machines**. In **Virtual Machines**, select **Inventory**.

3. In **Inventory** select **+ New**

![alt text](res/1-04.png "Inventory Screen for Virtual Machines")

4. Fill in the **New Virtual Machine Dialog with the following and then click **Create**:

 | Setting   | Value  |
|---|---|
| Name:  |  **TenantVM1 |
| Generation:  | **Generation 2**  |
| Host:    | *Leave Default*    |
| Path:   | *Leave Default*     |
| Virtual Processor Count:   |  **2**  |
| Memory:   | **2GB**   |
| Use dynamic memory:   |  *selected*  |
| Network adapter:   | **sdnSwitch**  |
| Virtual Network:   | **TenantNetwork1**   |
| Virtual Subnet:  |  **TenantSubnet1 (192.172.33.0/24)**  |
| IP Address:   |  **192.172.33.4**  |
| Storage:   | *select* **Add disk**   |
| Use an existing virtual hard disk:   | *Select*   |
| Path:   | **C:\ClusterStorage\S2D_vDISK1\TenantVM1\GUI.vhdx**   |

>

5. Repeat the last step, except enter the values for **TenantVM2**:

 | Setting   | Value  |
|---|---|
| Name:  |  **TenantVM2 |
| Generation:  | **Generation 2**  |
| Host:    | *Leave Default*    |
| Path:   | *Leave Default*     |
| Virtual Processor Count:   |  **2**  |
| Memory:   | **2GB**   |
| Use dynamic memory:   |  *selected*  |
| Network adapter:   | **sdnSwitch**  |
| Virtual Network:   | **TenantNetwork1**   |
| Virtual Subnet:  |  **TenantSubnet1 (192.172.33.0/24)**  |
| IP Address:   |  **192.172.33.5**  |
| Storage:   | *select* **Add disk**   |
| Use an existing virtual hard disk:   | *Select*   |
| Path:   | **C:\ClusterStorage\S2D_vDISK1\TenantVM2\GUI.vhdx**   |

6. After both VMs have been created, start both of them and then continute onto the next step.

![alt text](res/1-05.png "Inventory Screen for Virtual Machines")



# Step 04: Run Ping tests to validate VXLAN communication between both VMs.

1. Using Windows Admin Center's **RDP Connection** or **Hyper-V Administrator**  log into **TenantVM1 (192.172.33.4)**

2. From a **CMD** Prompt or a Windows PowerShell prompt, Try pinging **TenantVM2**.

3. If you are successful, then you have successfully created a TenantVM Network and have two Hyper-V virtual machines communicating over that network.