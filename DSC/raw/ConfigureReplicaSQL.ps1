configuration ConfigureReplicaSQL
{
    param
    (
        [Parameter(Mandatory)]
        [String]$DomainName,

         [Parameter(Mandatory)]
        [String]$VMName,

        [Parameter(Mandatory)]
        [String]$VMRole,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$SQLServiceCreds,

        [Parameter(Mandatory=$true)]
        [String]$ClusterName,

        [Parameter(Mandatory=$true)]
        [String]$ClusterOwnerNode,

        [Parameter(Mandatory=$true)]
        [String]$ClusterIP,

        [Int]$RetryCount=20,
        [Int]$RetryIntervalSec=30
    )

    Import-DscResource -ModuleName PSDesiredStateConfiguration,xDnsServer, xDatabase, StorageDSC, ComputerManagementDsc,xPendingReboot, xSmbShare, NetworkingDsc, xActiveDirectory, xFailoverCluster, SqlServer, SqlServerDsc, xStorage
   [System.Management.Automation.PSCredential ]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)
   [System.Management.Automation.PSCredential ]$LocalCreds = New-Object System.Management.Automation.PSCredential ("${VMName}\$($Admincreds.UserName)", $Admincreds.Password)
   [System.Management.Automation.PSCredential ]$SQLCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($SQLServiceCreds.UserName)", $SQLServiceCreds.Password)
   [System.Management.Automation.PSCredential ]$LocalCreds2 = New-Object System.Management.Automation.PSCredential ("$($Admincreds.UserName)", $Admincreds.Password)

    $CIP = "$($ClusterIP.split('.')[0]).$($ClusterIP.split('.')[1]).$($ClusterIP.split('.')[2]).$([int]($ClusterIP.split('.')[3])+1)"


    Node $AllNodes.Where{$VMRole -eq "ReplicaSQL"}.Nodename
    {

        LocalConfigurationManager
        {
            RebootNodeIfNeeded = $true
        }

        WindowsFeature FC
        {
            Name = "Failover-Clustering"
            Ensure = "Present"
        }

        WindowsFeature RSATDNS
        {
            Name = "RSAT-DNS-Server"
            Ensure = "Present"
        }

        WindowsFeature FailoverClusterTools 
        { 
            Ensure = "Present" 
            Name = "RSAT-Clustering-Mgmt"
            DependsOn = "[WindowsFeature]FC"
        } 

        WindowsFeature FCPS
        {
            Name = "RSAT-Clustering-PowerShell"
            Ensure = "Present"
            DependsOn = "[WindowsFeature]FailoverClusterTools"
        }

        WindowsFeature FCPSCMD
        {
            Ensure    = 'Present'
            Name      = 'RSAT-Clustering-CmdInterface'
            DependsOn = '[WindowsFeature]FCPS'
        }

        WindowsFeature ADPS
        {
            Name = "RSAT-AD-PowerShell"
            Ensure = "Present"
        }

        xWaitForADDomain DscForestWait
        {
            DomainName = $DomainName
            DomainUserCredential= $DomainCreds
            RetryCount = $RetryCount
            RetryIntervalSec = $RetryIntervalSec
        }

        xWaitForDisk Disk2
        {
             DiskId = 2
             RetryIntervalSec = $RetryIntervalSec
             RetryCount = $RetryCount
        }

        xDisk ADDataDisk
        {
             DiskId = 2
             DriveLetter = 'F'
             DependsOn = "[WaitForDisk]Disk2"
             FSLabel = 'SQLData'
        }


        Computer JoinDomain
        {
            Name       = $VMName
            DomainName = $DomainName
            Credential = $DomainCreds
        }


        Firewall DatabaseEngineFirewallRule
        {
            Direction = "Inbound"
            Name = "SQL-Server-Database-Engine-TCP-In"
            DisplayName = "SQL Server Database Engine (TCP-In)"
            Description = "Inbound rule for SQL Server to allow TCP traffic for the Database Engine."
            Group = "SQL Server"
            Enabled = "True"
            Protocol = "TCP"
            LocalPort = "1433"
            Ensure = "Present"
        }

        Firewall DatabaseMirroringFirewallRule
        {
            Direction = "Inbound"
            Name = "SQL-Server-Database-Mirroring-TCP-In"
            DisplayName = "SQL Server Database Mirroring (TCP-In)"
            Description = "Inbound rule for SQL Server to allow TCP traffic for the Database Mirroring."
            Group = "SQL Server"
            Enabled = "True"
            Protocol = "TCP"
            LocalPort = "5022"
            Ensure = "Present"
        }

        Firewall ListenerFirewallRule
        {
            Direction = "Inbound"
            Name = "SQL-Server-Availability-Group-Listener-TCP-In"
            DisplayName = "SQL Server Availability Group Listener (TCP-In)"
            Description = "Inbound rule for SQL Server to allow TCP traffic for the Availability Group listener."
            Group = "SQL Server"
            Enabled = "True"
            Protocol = "TCP"
            LocalPort = "59999"
            Ensure = "Present"
        }

        xPendingReboot RebootAfterDomainJoin {
            Name = "RebootAfterDomainJoin"
            DependsOn = "[Computer]JoinDomain"
        }


        Group AddSQLToAdmin{
            GroupName='Administrators'
            DependsOn= '[xPendingReboot]RebootAfterDomainJoin'
            Ensure= 'Present'
            MembersToInclude= "$($DomainName.split('.')[0])\$($SQLServiceCreds.UserName)"

        }


          ServiceSet SQLService
        {
            Name        = @("MSSQLSERVER")
            StartupType = "Automatic"
            State       = "Running"
        }

        SqlServerLogin AddDomainAdminAccountToSqlServer
        {
            Name = "$($DomainName.split('.')[0])\$($Admincreds.UserName)"
            LoginType = "WindowsUser"
			ServerName = $VMName
			InstanceName = "MSSQLSERVER"
            PsDscRunAsCredential = $LocalCreds
        }

        SqlServerLogin AddSQLAdminAccountToSqlServer
        {
            Name = "$($DomainName.split('.')[0])\$($SQLServiceCreds.UserName)"
            LoginType = "WindowsUser"
			ServerName = $VMName
			InstanceName = "MSSQLSERVER"
            PsDscRunAsCredential = $LocalCreds
        }

        SqlServerLogin AddClusterSvcAccountToSqlServer
        {
            Name = "NT SERVICE\ClusSvc"
            LoginType = "WindowsUser"
			ServerName = $VMName
			InstanceName = "MSSQLSERVER"
        }

                SqlServerRole Add_ServerRole_AdminSql
        {
            Ensure               = 'Present'
            ServerRoleName       = 'sysadmin'
            MembersToInclude     = "$($DomainName.split('.')[0])\$($Admincreds.UserName)", "$($DomainName.split('.')[0])\$($SQLServiceCreds.UserName)", "NT SERVICE\ClusSvc"
            ServerName           = $VMName
            InstanceName         = "MSSQLSERVER"
            PsDscRunAsCredential = $LocalCreds
        }

        SqlServiceAccount SetServiceAcccount_User
        {
			ServerName = $VMName
			InstanceName = "MSSQLSERVER"
            ServiceType    = 'DatabaseEngine'
            ServiceAccount = $SQLCreds
            RestartService = $true
            DependsOn = "[SqlServerRole]Add_ServerRole_AdminSql"
        }

        
         Script SetSPN
            {
            GetScript = { 
                return @{ 'Result' = $true }
            }

            SetScript = {

            $Name = $Using:VMName
            $Username = $Using:SQLCreds.Username
            $DomainName = $Using:DomainName

             $SPN1 =  "MSSQLSvc/$($Name):1433" 
              $SPN2 = "$($DomainName)\$($Username)"
              $CMD1 = "setspn -a $($SPN1) $($SPN2)"

              $SPN3 =  "MSSQLSvc/$($Name).$($DomainName):1433" 
              $SPN4 = "$($DomainName)\$($Username)"
              $CMD2 = "setspn -a $($SPN3) $($SPN4)"
              Invoke-Expression $CMD1
              Invoke-Expression $CMD2

            }

            TestScript = {
                $Name = $Using:VMName
            $Username = $Using:SQLCreds.Username
            $DomainName = $Using:DomainName

             $SPN1 =  "MSSQLSvc/$($Name):1433" 
              $SPN2 = "$($DomainName)\$($Username)"
              $CMD1 = "setspn -a $($SPN1) $($SPN2)"

              $SPN3 =  "MSSQLSvc/$($Name).$($DomainName):1433" 
              $SPN4 = "$($DomainName)\$($Username)"
              $CMD2 = "setspn -a $($SPN3) $($SPN4)"

              $SPNCheck = setspn -l SQLAdmin 


            $Output = $SPNCheck | foreach {
        $parts = $_ -split "\n"
        New-Object -Type PSObject -Property @{
            SPN = $parts[0].replace('	','') 
        }
        }

       ($Output.SPN -contains $SPN1) -and ($Output.SPN -contains $SPN3)

            }

            DependsOn = "[SqlServiceAccount]SetServiceAcccount_User"
            PsDscRunAsCredential = $LocalCreds
        }

        File DB {
            Type = 'Directory'
            DestinationPath = 'F:\Microsoft SQL Server\DB'
            Ensure = "Present"
            DependsOn = "[Disk]ADDataDisk"
        }

        File Logs {
            Type = 'Directory'
            DestinationPath = 'F:\Microsoft SQL Server\Logs'
            Ensure = "Present"
            DependsOn = "[Disk]ADDataDisk"
        }

        File Backup {
            Type = 'Directory'
            DestinationPath = 'F:\Microsoft SQL Server\BackUp'
            Ensure = "Present"
            DependsOn = "[Disk]ADDataDisk"
        }

        xSMBShare DBBackupShare
            {
                Name = "DBBackup"
                Path = 'F:\Microsoft SQL Server\BackUp'
                Ensure = "Present"
                FullAccess = "$($DomainCreds.UserName)", "$($LocalCreds.UserName)", "$($SQLCreds.UserName)"
                Description = "Backup share for SQL Server"
                DependsOn = "[File]Backup"
            }

               SqlDatabaseDefaultLocation Set_SqlDatabaseDefaultDirectory_Data
        {
            ServerName           = $VMName
            InstanceName         = "MSSQLSERVER"
            ProcessOnlyOnActiveNode = $true
            Type                    = 'Data'
            Path                    = 'F:\Microsoft SQL Server\DB'
            PsDscRunAsCredential    = $LocalCreds
            DependsOn = "[File]DB"
        }

        SqlDatabaseDefaultLocation Set_SqlDatabaseDefaultDirectory_Log
        {
          ServerName           = $VMName
            InstanceName         = "MSSQLSERVER"
            ProcessOnlyOnActiveNode = $true
            Type                    = 'Log'
            Path                    = 'F:\Microsoft SQL Server\Logs'
            PsDscRunAsCredential    = $LocalCreds
            DependsOn = "[File]Logs"
        }

        SqlDatabaseDefaultLocation Set_SqlDatabaseDefaultDirectory_Backup
        {
            ServerName           = $VMName
            InstanceName         = "MSSQLSERVER"
            ProcessOnlyOnActiveNode = $true
            Type                    = 'Backup'
            Path                    = 'F:\Microsoft SQL Server\BackUp'
            PsDscRunAsCredential    = $LocalCreds
            DependsOn = "[File]BackUp"
        }

        SqlDatabase CreateDemoDB
            {
                Ensure       = 'Present'
                ServerName   = $VMName
                InstanceName = 'MSSQLSERVER'
                Name         = 'Ha-Sample-DB'
                PsDscRunAsCredential    = $DomainCreds
                DependsOn               = "[xSMBShare]DBBackupShare"
            }


               SqlDatabaseOwner SetSQLAdmin
        {
            Name                 = "$($DomainName.split('.')[0])\$($SQLServiceCreds.UserName)"
            Database             = 'Ha-Sample-DB'
            ServerName           = $VMName
            InstanceName         = 'MSSQLSERVER'
            PsDscRunAsCredential = $DomainCreds
            DependsOn               = "[SqlDatabase]CreateDemoDB"
        }

        xWaitForCluster WaitForCluster
        {
            Name             = $ClusterName
            RetryIntervalSec = 10
            RetryCount       = 60
            DependsOn        = "[WindowsFeature]FCPSCMD"
        }


         Script AddToCluster
            {

                GetScript = { 
                    return @{ 'Result' = $true }
                }
                SetScript = {

                Add-ClusterNode -Name $Using:VMName -Cluster $Using:ClusterOwnerNode -NoStorage

                }
                TestScript = {
                    $Nodes = Get-ClusterNode -Cluster $Using:ClusterOwnerNode | where {$_.Name -eq $Using:VMName}
                    $Nodes -contains $Using:VMName -and $Nodes.State -notcontains 'Down'
                }
                DependsOn = "[xWaitForCluster]WaitForCluster"
                PsDscRunAsCredential = $DomainCreds
            }

            SqlAlwaysOnService EnableAlwaysOn
            {
                Ensure               = 'Present'
                ServerName           = $VMName
                InstanceName         = 'MSSQLSERVER'
                RestartTimeout       = 120
                DependsOn = "[Script]AddToCluster"
            }



           


            # Create a DatabaseMirroring endpoint
            SqlServerEndpoint HADREndpoint
            {
                EndPointName         = 'HADR'
                Ensure               = 'Present'
                Port                 = 5022
                ServerName           = $VMName
                InstanceName         = 'MSSQLSERVER'
                DependsOn            = "[SqlAlwaysOnService]EnableAlwaysOn"
            }

         
            SqlAGReplica AddReplica
            {
                Ensure                     = 'Present'
                Name                       = $VMName
                AvailabilityGroupName      = $ClusterName
                ServerName                 = $VMName
                InstanceName               = 'MSSQLSERVER'
                PrimaryReplicaServerName   =  $ClusterOwnerNode
                PrimaryReplicaInstanceName = 'MSSQLSERVER'
                DependsOn                  = '[SqlServerEndpoint]HADREndpoint'
                PsDscRunAsCredential = $LocalCreds


            }



            Script EnableDBRep
            {

            GetScript = { 
                return @{ 'Result' = $true }
            }

            SetScript = {
                

             $DB = "Ha-Sample-DB"

             $PathAG = "SQLSERVER:\SQL\SQLVM-02\DEFAULT\AvailabilityGroups\SQLCLuster"
             $PathDB = "SQLSERVER:\SQL\$($Using:VMName)\DEFAULT\AvailabilityGroups\$($Using:ClusterName)\AvailabilityDatabases\$($DB)"
             $BackupoLoc = "\\$($Using:ClusterOwnerNode)\DBBackup"

[System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.SMO') | out-null 
$srv = new-object ('Microsoft.SqlServer.Management.Smo.Server') "$($Using:VMName)" 


# Create database backup  
Backup-SqlDatabase -Database $DB -BackupFile "$BackupoLoc\$DB.bak" -ServerInstance $Using:ClusterOwnerNode -Credential $LocalCreds2
# Create log backup  
Backup-SqlDatabase -Database $DB -BackupAction "Log" -BackupFile "$BackupoLoc\$DB.trn" -ServerInstance $Using:ClusterOwnerNode -Credential $LocalCreds2
# Restore database backup   
Restore-SqlDatabase -Database $DB -BackupFile "$BackupoLoc\$DB.bak" -NoRecovery -ServerInstance "$($Using:VMName)" -ReplaceDatabase -Credential $LocalCreds2
# Restore log backup   
Restore-SqlDatabase -Database $DB -BackupFile  "$BackupoLoc\$DB.trn" -RestoreAction "Log" -NoRecovery –ServerInstance "$($Using:VMName)" -Credential $LocalCreds2
   
   

            }

            TestScript = {
                $PathAGRep = "SQLSERVER:\SQL\SQLVM-02\DEFAULT\AvailabilityGroups\SQLCLuster\AvailabilityReplicas\SQLVM-02"
                $TestRep = Test-SqlAvailabilityReplica -Path $PathAGRep
                $TestRep.HealthState -eq "Healthy"
            }

            DependsOn = "[SqlAGReplica]AddReplica"
            PsDscRunAsCredential = $LocalCreds2
        }
        
Script EnableDBRepPart2
            {

            GetScript = { 
                return @{ 'Result' = $true }
            }

            SetScript = {
             
             Invoke-Command -ComputerName SQLVM-02 -ScriptBlock {
             
             $DB = "Ha-Sample-DB"
             $PathAG = "SQLSERVER:\SQL\SQLVM-02\DEFAULT\AvailabilityGroups\SQLCluster"
             $PathDB = "SQLSERVER:\SQL\SQLVM-02\DEFAULT\AvailabilityGroups\SQLCluster\AvailabilityDatabases\$($DB)"


           Add-SqlAvailabilityDatabase -Path $PathAG -Database $DB -Confirm:$False
           Resume-SqlAvailabilityDatabase -Path $PathDB -Confirm:$False
        }

            }

            TestScript = {
                $PathAGRep = "SQLSERVER:\SQL\SQLVM-02\DEFAULT\AvailabilityGroups\SQLCLuster\AvailabilityReplicas\SQLVM-02"
                $TestRep = Test-SqlAvailabilityReplica -Path $PathAGRep
                $TestRep.HealthState -eq "Healthy"
            }

            DependsOn = "[Script]EnableDBRep"
            PsDscRunAsCredential = $SQLCreds
        }


    }
}
