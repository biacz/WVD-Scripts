Function CleanVariables {
    Get-Variable | Where-Object { $startupVariables -notcontains $_.Name } | ForEach-Object {
        try { Remove-Variable -Name "$($_.Name)" -Force -Scope "global" -ErrorAction SilentlyContinue -WarningAction SilentlyContinue }
        catch { }
    }
}

# cleaning up variables from old runs
Write-Output "Cleaning variables"
CleanVariables

# declaring variables
Write-Output "Declaring variables"
$rds, $wvdv1, $wvdv2, $out, $az_subs, $noAzureVM, $vms, $AllWVDS = @()

# initializing variables
Write-Output "Initializing variables"
$AzureADServicePrincipalCredentials = ""
$AzureADServicePrincipal = ""
$credentials = New-Object System.Management.Automation.PSCredential($AzureADServicePrincipal, (ConvertTo-SecureString $AzureADServicePrincipalCredentials -AsPlainText -Force))
$tenant = ""
$aadtenantid = ""
$brokerURL = "https://rdbroker.wvd.microsoft.com"
$fqdn = ""

# connecting to WVD classic broker
Write-Output "Connecting to WVD classic broker $brokerURL"
Add-RdsAccount -DeploymentUrl $brokerURL -Credential $credentials -aadtenantid $aadtenantid -ServicePrincipal 

$ErrorActionPreference = "Continue"

# retrieving all sessions hosts from WVD classic broker
Write-Output "Querying WVD classic data"
$rds = Get-RdsHostPool -TenantName $tenant | ForEach-Object { Get-RdsSessionHost -TenantName $tenant -HostPoolName $_.HostPoolName -verbose }

Write-Output "Creating WVD classic report"
$wvdv1 = $rds | % {
    [PSCustomObject]@{
        AZName          = $_.SessionHostName -replace $fqdn, ""
        SessionHostName = $_.SessionHostName
        SubscriptionId  = $($_.AzureResourceId).Split("/")[2]
        ResourceGroup   = $($_.AzureResourceId).Split("/")[4]
        HostPoolName    = $_.HostPoolName
        AssignedUser    = $_.AssignedUser
        LastHeartBeat   = $_.LastHeartBeat
        AllowNewSession = $_.AllowNewSession
        SessionActive   = $_.Sessions
        Status          = $_.Status
        WVDVersion      = "V1"
    }
}

# Querying all enabled subscriptions and looping through them to retrieve VM objects
Write-Output "Querying all enabled subscriptions and looping through them to retrieve VM objects"
get-azsubscription | ? State -eq "Enabled" | ForEach-Object {
    set-azcontext -SubscriptionObject $_
    $sub = $_.Name
    $vms += get-azvm -status
    
    # Retrieving all pools from WVD
    write-output "Retrieving all pools from WVD subscription $sub"
    $AllPools = Get-AzWVDHostPool | Select-Object *

    foreach ($Item in $AllPools) {
        $PoolName = $Item.Name
        $ResourceGroup = $($($Item.ApplicationGroupReference).Split("/"))[4]
        # Retrieving all sessionhosts from WVD
        write-output "Retrieving all sessionhosts from WVD subscription $sub"
        $AllHosts = Get-AzWvdSessionHost -ResourceGroupName $ResourceGroup -HostPoolName $PoolName
        Write-Output "Creating WVD report for subscription $sub"
        $wvdv2 += $AllHosts | % {
            $HostInfo = $($_.Id).Split("/")
            [PSCustomObject]@{
                AZName          = $HostInfo[10] -replace $fqdn, ""
                SessionHostName = $HostInfo[10]
                SubscriptionId  = $HostInfo[2]
                ResourceGroup   = $HostInfo[4]
                HostPoolName    = $HostInfo[8]
                AssignedUser    = $_.AssignedUser
                LastHeartBeat   = $_.LastHeartBeat
                AllowNewSession = $_.AllowNewSession
                SessionActive   = $_.Session
                Status          = $_.Status
                WVDVersion      = "V2"
            }
        }
    }
}

# Combining old and new WVD data
Write-Output "Creating WVD full report"
$AllWVDS += $wvdv1
$AllWVDS += $wvdv2

# Combining all reports
Write-Output "Creating final report by adding VM data"
$out = foreach ($vm in $vms) {
    $thisRDS = $AllWVDS | ? { $_.AZName -eq $vm.Name }
    if ($thisRDS) { 
        $user = if ($_.AssignedUser -ne $null) {
            # Querying user details from AD
            Get-ADUser -Filter "UserPrincipalName -eq '$($_.AssignedUser)'" -Properties Department, EmployeeId, extensionAttribute15 
        }
    }
    [PSCustomObject]@{
        #Azure Details
        AZVMName        = $vm.Name
        AZVMID          = $vm.Id
        AZVMDiskId      = $vm.StorageProfile.OsDisk.ManagedDisk.Id
        Region          = $vm.Location
        HardwareProfile = $vm.HardwareProfile.VmSize
        ResourceGroup   = $vm.ResourceGroupName
        PowerState      = $vm.PowerState
        
        #WVD Details
        SessionHostName = $thisRDS.SessionHostName
        HostPoolName    = $thisRDS.HostPoolName
        AssignedUser    = $thisRDS.AssignedUser
        LastHeartBeat   = $thisRDS.LastHeartBeat
        AllowNewSession = $thisRDS.AllowNewSession
        SessionActive   = $thisRDS.SessionActive
        Status          = $thisRDS.Status
        WVDVersion      = $thisRDS.WVDVersion

        #User Details
        Department      = $user.Department -replace ",", ""
        CostCenter      = $user.extensionAttribute15
        EmployeeID      = $user.EmployeeId        
    }
}
