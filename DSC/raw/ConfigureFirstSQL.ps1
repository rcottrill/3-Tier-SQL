configuration ConfigureFirstSQL
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

        [Parameter(Mandatory=$true)]
        [String]$witnessStorageName,

        [Parameter(Mandatory=$true)]
        [String]$witnessStorageBlobEndpoint,

        [Parameter(Mandatory=$true)]
        [String]$witnessStorageAccountKey,

        [Parameter(Mandatory=$true)]
        [String]$DC01IP,

        [Parameter(Mandatory=$true)]
        [String]$SiteCIDR,


        [Int]$RetryCount=20,
        [Int]$RetryIntervalSec=30
    )

    Import-DscResource -ModuleName PSDesiredStateConfiguration,xDnsServer, xDatabase, StorageDSC, ComputerManagementDsc,xPendingReboot, xSmbShare, NetworkingDsc, xActiveDirectory, xFailoverCluster, SqlServer, SqlServerDsc
   [System.Management.Automation.PSCredential ]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)
   [System.Management.Automation.PSCredential ]$LocalCreds = New-Object System.Management.Automation.PSCredential ("${VMName}\$($Admincreds.UserName)", $Admincreds.Password)
   [System.Management.Automation.PSCredential ]$SQLCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($SQLServiceCreds.UserName)", $Admincreds.Password)
    $CIP = "$($ClusterIP.split('.')[0]).$($ClusterIP.split('.')[1]).$($ClusterIP.split('.')[2]).$([int]($ClusterIP.split('.')[3])+1)"


    Node $AllNodes.Where{$VMRole -eq "FirstSQL"}.Nodename
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

        WaitForDisk Disk2
        {
             DiskId = 2
             RetryIntervalSec = $RetryIntervalSec
             RetryCount = $RetryCount
        }

        Disk ADDataDisk
        {
             DiskId = 2
             DriveLetter = 'F'
             DependsOn = "[WaitForDisk]Disk2"
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


        xADUser CreateSqlServerServiceAccount
        {
            DomainAdministratorCredential = $DomainCreds
            DomainName = $DomainName
            UserName = $SQLServicecreds.UserName
            Password = $SQLServicecreds
            Ensure = "Present"
            DependsOn = "[SqlServerLogin]AddDomainAdminAccountToSqlServer"
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

         xDnsRecord DNSClusterRecord
    {
        Name = $ClusterName
        Target = $CIP
        Zone = $DomainName
        Type = "ARecord"
        Ensure = "Present"
        DnsServer = $DomainName
        PsDscRunAsCredential = $DomainCreds
    }

      xCluster CreateCluster
            {
                Name                          = $ClusterName
                StaticIPAddress               = $CIP
                DomainAdministratorCredential = $DomainCreds
                DependsOn                     = "[WindowsFeature]FCPSCMD"
            }



            xClusterQuorum 'SetQuorumToNodeAndCloudMajority'
        {
            IsSingleInstance        = 'Yes'
            Type                    = 'NodeAndCloudMajority'
            Resource                = $witnessStorageName
            StorageAccountAccessKey = $witnessStorageAccountKey
            DependsOn               = "[xCluster]CreateCluster"
        }

        SqlAlwaysOnService EnableAlwaysOn
            {
                Ensure               = 'Present'
                ServerName           = $VMName
                InstanceName         = 'MSSQLSERVER'
                RestartTimeout       = 120
                DependsOn = "[xCluster]CreateCluster"
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

            # Create the availability group on the instance tagged as the primary replica
            SqlAG CreateAG
            {
                Ensure               = "Present"
                Name                 = $ClusterName
                ServerName           = $VMName
                InstanceName         = 'MSSQLSERVER'
                DependsOn            = "[SqlServerEndpoint]HADREndpoint","[SqlServerRole]Add_ServerRole_AdminSql"
                AvailabilityMode     = "SynchronousCommit"
                FailoverMode         = "Automatic" 
            }

            SqlAGListener AvailabilityGroupListener
            {
                Ensure               = 'Present'
                ServerName           = $ClusterOwnerNode
                InstanceName         = 'MSSQLSERVER'
                AvailabilityGroup    = $ClusterName
                Name                 = "$($ClusterName)AGL"
                IpAddress            = "$($ClusterIP)/255.255.255.224"
                Port                 = 1433
                PsDscRunAsCredential = $DomainCreds
                DependsOn            = "[SqlAG]CreateAG"
            }

             Script SetProbePort
            {

                GetScript = { 
                    return @{ 'Result' = $true }
                }
                SetScript = {
                    $ipResourceName = "$($using:ClusterName)_$($using:ClusterIP)"
                    $ipResource = Get-ClusterResource $ipResourceName
                    $clusterResource = Get-ClusterResource -Name $using:ClusterName 

                    Set-ClusterParameter -InputObject $ipResource -Name ProbePort -Value 59999

                    Stop-ClusterResource $ipResource
                    Stop-ClusterResource $clusterResource

                    Start-ClusterResource $clusterResource #This should be enough
                    Start-ClusterResource $ipResource #To be on the safe side

                }
                TestScript = {
                    $ipResourceName = "$($using:ClusterName)_$($using:ClusterIP)"
                    $resource = Get-ClusterResource $ipResourceName
                    $probePort = $(Get-ClusterParameter -InputObject $resource -Name ProbePort).Value
                    Write-Verbose "ProbePort = $probePort"
                    ($(Get-ClusterParameter -InputObject $resource -Name ProbePort).Value -eq 59999)
                }
                DependsOn = "[SqlAGListener]AvailabilityGroupListener"
                PsDscRunAsCredential = $DomainCreds
            }

               
         SqlDatabase Create_Database
            {
                Ensure       = 'Present'
                ServerName   = $VMName
                InstanceName = 'MSSQLSERVER'
                Name         = 'Ha-Sample-DB'
                PsDscRunAsCredential    = $DomainCreds
                DependsOn               = "[xSMBShare]DBBackupShare"
            }
            
            SqlAGDatabase AddDatabaseToAG
            {
                AvailabilityGroupName   = $ClusterName
                BackupPath              = "\\" + $VMName + "\DBBackup"
                DatabaseName            = 'Ha-Sample-DB'
                InstanceName            = 'MSSQLSERVER'
                ServerName              = $VMName
                Ensure                  = 'Present'
                ProcessOnlyOnActiveNode = $true
                PsDscRunAsCredential    = $DomainCreds
                DependsOn = "[SqlDatabase]Create_Database"
            }
        
    }
}