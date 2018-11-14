# New-SDNVHDXFile

## Description
New-SDNVHDXFile is a graphically driven PowerShell script designed to assist you in creating the necessary VHDX files for the SDN Sandbox. New-SDNVHDXFile will attach to an ISO, Create a VHDX image based on your selections, and then apply any updates in a folder that you specify.

## Requirements

New-SDNVHDXFile requires the [Convert-WindowsImage](https://gallery.technet.microsoft.com/scriptcenter/Convert-WindowsImageps1-0fe23a8f) PowerShell Module to work correctly.

## Usage

1. Download [Convert-WindowsImage](https://gallery.technet.microsoft.com/scriptcenter/Convert-WindowsImageps1-0fe23a8f) and place ``Convert-WindowsImage.ps1`` in the same folder as ``Create-SDNVHDX.ps1``
2. Download any updates that you want applied to the image and place them in a local folder of your choosing on a machine that has Hyper-V 2016 or higher installed.
3. Run ``.\New-SDNVHDXFile.ps1 -UpdatesPath '.\<Your Update Folder>``
4. Follow the GUI prompts to select your ISO, Image Index, and then output VHDXName, then click OK.
5. Your VHDX will then be created and updated to the patch level you desire.

> **Note:** Some updates will cause the DISM installer to fail or hang when applied with other existing updates. If you are trying to create a Windows Server 2016 Datacenter VHDX image with the May 2018 Cumulative update and attempt to apply additional future updates, you may run into failure.
