
# Import Modules and Other Components Required for Execution
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
# Warn User of ClearText Storage and Transmission
Write-Host -ForegroundColor Red "#############################################################################################"
Write-Host -ForegroundColor Red "NOTICE: This Script records and sends passwords in clear text. Use from trusted source only." 
Write-Host -ForegroundColor Red "#############################################################################################"
# Collect Environment Variables 
Write-Host -ForegroundColor White "Provide Hosting Domain Number. NOTE: This will be the VLAN and UUID number for this client."
Write-Host -NoNewLine -ForegroundColor White "Use Only the number value (e.g use 34 for domain34 which is hosting customer number 34):  "
$Hosting_Domain = Read-Host
Write-Host -ForegroundColor White "Provide A Short Suffix For Identifying The Customer (e.g Contoso for Contoso International LLP): "
Write-Host -ForegroundColor Yellow "Note: Do not use special characters"
$Hosting_Suffix = Read-Host
# Collect Credentials and Perform Connection to vCenter Server # 
$VIServer = "FILL_IN_VCS_IP_OR_URL"
Write-Host -ForegroundColor White "Enter Domain Credentials (e.g CORP\Username): "
Write-Host -ForegroundColor Yellow "Your user account must be a domain admin or higher privilege to execute."
Write-Host -ForegroundColor Yellow "This credential is stored as a protected system string"

$VICred = Get-Credential
Write-Host -ForegroundColor White "Connecting to "$VIServer "as vCenter Target."
$VIConnection = Connect-VIServer $VIServer -Credential $VICred -WarningAction SilentlyContinue
# vhosting infrastructure
$ComputeLocation = "Cluster_NAME_HERE"
$DatacenterName = "DATACENTER_NAME_HERE"
$cluster = Get-Cluster -Server $VIConnection -Name $ComputeLocation
$vmhost = $Cluster | Get-VMHost | Select -First 1
Write-Host -ForegroundColor White "VM Host: "$vmhost
Write-Host -ForegroundColor White "VM Cluster: "$cluster
$DSC_Name = "Hosted-D"+$Hosting_Domain+"-"+$Hosting_Suffix
New-DatastoreCluster -Name $DSC_Name -Location $DatacenterName 
Set-DatastoreCluster -DatastoreCluster $DSC_Name -IOLatencyThresholdMillisecond 15 -SdrsAutomationLevel FullyAutomated -SpaceUtilizationThresholdPercent 80 -IOLoadBalanceEnabled $true
# Acquire Parameters For Storage Volume 
$NimbleIPs = @("FILL_IN_IP_HERE","FILL_IN_IP2_HERE")
$i = 1
$Nimble_VOLNAME = "Hosted-D" + $Hosting_Domain + "-SRV"
Write-Host -ForegroundColor Green "Nimble Storage Volume: " $Nimble_VOLNAME
Write-Host -NoNewLine -ForegroundColor White "Enter Size of Volume in MegaBytes (e.g 4TB would be 4000000): "
$Nimble_VOLSIZE = Read-Host
$Nimble_VOLSIZETB = [math]::Round($Nimble_VOLSIZE / 1024000,2)
Write-Host -ForegroundColor Green "Nimble Storage Volume Size is:"$Nimble_VOLSIZE"MB or"$Nimble_VOLSIZETB"TB"
Write-Host -NoNewLine -ForegroundColor White "Enter Nimble Password: "
$NimblePW = Read-Host

##############################
# Loop For Creating Storage  #
##############################
foreach ($NimbleIP in $NimbleIPs) {
# Nimble Configuration
$NimbleMGMT = $NimbleIP
$NimbleUser = "admin"
 
$data = @{
            username = $NimbleUser
            password = $NimblePW
        }
# Convert the Body Array to JSON for Rest API
$body = convertto-json (@{ data = $data})
# Generate Nimble Token for Rest API
$NimbleAuthURI = "https://" + $NimbleMGMT + ":5392/v1/tokens"
$token = Invoke-RestMethod -Uri $NimbleAUTHURI -Method Post -Body $body 
$token = $token.data.session_token
$header = @{ "X-Auth-Token" = $token }

###################
# Create a Volume #
###################
# Define Performance Policy_ID as well as format Variables to List
$perfpolicy = "034038334fffeea31800000000000000000000001c" # This is unique to an environment. It will need to be collected prior to executing.
$data = @{
    name = $Nimble_VOLNAME
    perfpolicy_id = $perfpolicy
    size = ($Nimble_VOLSIZE / 2)
    multi_initiator = "true"
}
# Structure API request with Volume Name, Performance Policy_ID and Size. Reuse body variable to save heap and pass token for authentication.
$body = convertto-json (@{ data = $data })
$NimbleStoreURI = "https://" + $NimbleMGMT + ":5392/v1/volumes"
$result = Invoke-RestMethod -Uri $NimbleStoreURI -Method Post -Body $body -Header $header
# Show Us The Results Of the Creation Command
$result.data | select name,size,description,target_name | format-table -autosize

###################
# Read Volume ID  #
###################
# Structure API request to get Volume ID. Reuse body variable to save heap and pass token for authentication.
$NimbleStoreIDURI = "https://" + $NimbleMGMT + ":5392/v1/volumes"
$NimbleVolumeList = Invoke-RestMethod -Uri $NimbleStoreIDURI -Method Get -header $header
$AccessPolicy_vol_id2 = $NimbleVolumeList.data | Where-Object {$_.name -eq "$Nimble_VOLNAME"} 

######################
# Read Get Access ID #
######################
# Structure API request and record data related to initiator group. Reuse body variable to save heap and pass token for authentication.
$NimbleAccessPolicyURI = "https://" + $NimbleMGMT + ":5392/v1/access_control_records/detail"
$AccessPolicy_result = Invoke-RestMethod -Uri $NimbleAccessPolicyURI -Method Get -Header $header
# Record the Initiator group ID and the Volume ID. Return it to us in readable format.
#$AccessPolicy_init_id2 = "024038334fffeea31800000000000000000000000a"  #Volume Access Initiator Group ID
$NimbleStoreURI = "https://" + $NimbleMGMT + ":5392/v1/initiator_groups/detail"
$result1 = Invoke-RestMethod -Uri $NimbleStoreURI -Method Get -Header $header
# Show Us The Results Of the Creation Command
#$result1.data | select full_name,id | format-table -autosize
$AccessPolicy_init_id1 = $result1.data | Where-Object {$_.full_name -eq "VCS05-Production-G10CLuster"}
Write-Host -ForegroundColor Green "Nimble Init Group Name: "$AccessPolicy_init_id1.id
Write-Host -ForegroundColor Green "Nimble Targeted Volume ID: "$AccessPolicy_vol_id2.id

#########################
# Create Access Policy  #
#########################
# Create Access Policy For Storage Above
$Access_Policy_Data = @{
apply_to = "volume"
initiator_group_id = $AccessPolicy_init_id1.id
vol_id = $AccessPolicy_vol_id2.id
}
$Access_Policy_Body = convertto-json (@{ data = $Access_Policy_Data})
$NimbleAccessPolicyURI_Post = "https://" + $NimbleMGMT + ":5392/v1/access_control_records"
$result_AccessPolicy = Invoke-RestMethod -Uri $NimbleAccessPolicyURI_Post -Method Post -Body $Access_Policy_Body -Header $header
############################
# Create VMWare Datastores #
############################
# vhosting storage configuration.
$cluster | Get-VMHost | Get-VMHostStorage -RescanAllHBA -RescanVmfs
$VMWareDatastore = "NBL0"+ $i +"-Hosted-D"+ $Hosting_Domain + "-SRV"
# $BlockCount is a long integer representing the conversion of MB to a matching number of 512 byte blocks. 
# This serves as a check/balance to ensure the right free disk is used in creating the datastore.
$BlockCount = (([long]$Nimble_VOLSIZE *[int]2) * [int]1024) / 2  #The division at the end is to split across the number of arrays.
$disk_list = (get-view (get-vmhost -name $vmhost | Get-View ).ConfigManager.DatastoreSystem).QueryAvailableDisksForVmfs($null)
$free_disk = $disk_list | Where-Object{$_.Capacity.Block -eq "$BlockCount"}
$disk_ca = ($free_disk).CanonicalName #Can be found by looking at the Identifier in vCenter.
$disk_ca1 = $disk_ca | Select -First 1
New-Datastore -vmhost $vmhost -Name $VMWareDatastore -Path $disk_ca1 -Vmfs -FileSystemVersion 6
Get-Datastore $VMWareDatastore | Move-Datastore -Destination $DSC_Name
$i = $i+1
}

############################
# Customize VMWare Cluster #
############################
# vhosting networking
$vSwitch_VLAN = [int]$Hosting_Domain
$vSwitch_val = "vSwitch0"
$hosting_VPG = "Domain"+$Hosting_Domain
$vmhosts = $cluster | Get-VMhost
 ForEach ($vmhost in $vmhosts)
 {
 Get-VirtualSwitch -VMhost $vmhost -Name $vSwitch_val | New-VirtualPortGroup -Name $hosting_VPG -VLanID $vSwitch_VLAN
 }
 
# vhosting Resource Pool and Organization
$vhost_folder = Get-Folder | Where-Object {$_.Name -eq "vHosting Customers"} | Select name,type,id,location
New-Folder -Name "vHostD$Hosting_Domain-$Hosting_Suffix" -Location $vhost_folder.name 
New-ResourcePool -Name "D$Hosting_Domain-$Hosting_Suffix" -Location $cluster 
Disconnect-VIServer -Server $VIServer -Confirm:$false

#########################
# Begin CiscoASA Config #
#########################
#We need to receive variables for Cisco Configuration here then write these to a blank file 
#to be read in by the function as raw formatted text.
#We can experiment with raw input outside this method but this has been confirmed to work.
#
$IOStreamPath = "H:\ASA_Commands.IOStream"
# Function built to send raw command text to ssh stream of Cisco ASA. Usage: ASA-SSH PATHTORAWIOSTREAM
#function ASA-SSH {
# Param ($command_list)
# 
# ssh -oKexAlgorithms=+diffie-hellman-group1-sha1 -c aes256-ctr admin@FILL_IN_ASAIP_HERE $command_list
#}
# Clear IOStream and Rebuild 
Write-Host -ForegroundColor White "Please enter the enable password (Not the logon password) for the Cisco ASA"
Write-Host -ForegroundColor Red "#############################################################################################"
Write-Host -ForegroundColor Red "NOTICE: This password is saved and transmitted in clear text. Use from trusted source only! #" 
Write-Host -ForegroundColor Red "#############################################################################################"
#$ASA_EnablePW = Read-Host
Write-Host -ForegroundColor Yellow "Clearing Previous IOStream..."
#Clear-Content $IOStreamPath
Write-Host -ForegroundColor Green "Building ASA Command Structure..."
