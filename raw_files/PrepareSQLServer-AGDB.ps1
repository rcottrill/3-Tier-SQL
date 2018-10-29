configuration SQLServerDBDsc
{
    param
    (
        [Parameter(Mandatory)]
        [String]$DomainName,

		[String]$DomainNetbiosName=(Get-NetBIOSName -DomainName $DomainName),

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
        [String]$witnessStorageBlobEndpoint,

        [Parameter(Mandatory=$true)]
        [String]$witnessStorageAccountKey,

        [Int]$RetryCount=20,
        [Int]$RetryIntervalSec=30
    )

    Import-DscResource -ModuleName xStorage, PSDesiredStateConfiguration, xSmbShare, xComputerManagement, xNetworking, xActiveDirectory, xFailoverCluster, SqlServer, SqlServerDsc

    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainNetbiosName}\$($Admincreds.UserName)", $Admincreds.Password)

    $ipcomponents = $ClusterIP.Split('.')
    $ipcomponents[3] = [convert]::ToString(([convert]::ToInt32($ipcomponents[3])) + 1)
    $ipdummy = $ipcomponents -join "."
    $ClusterNameDummy = "c" + $ClusterName

    $suri = [System.uri]$witnessStorageBlobEndpoint
    $uricomp = $suri.Host.split('.')

    $witnessStorageAccount = $uriComp[0]
    $witnessEndpoint = $uricomp[-3] + "." + $uricomp[-2] + "." + $uricomp[-1]

    $computerName = $env:COMPUTERNAME
    $domainUserName = $DomainCreds.UserName.ToString()

    Node localhost
    {
        if ($ClusterOwnerNode -eq $env:COMPUTERNAME)
        {
            xWaitforDisk Disk2
            {
                DiskId = 2
                RetryIntervalSec = 60
                RetryCount = 20
            }

            xDisk FVolume
            {
                DiskId = 2
                DriveLetter = 'F'
                FSLabel = 'Data'
                FSFormat = 'NTFS'
                DependsOn = '[xWaitForDisk]Disk2'
            }

            File BackupDirectory
            {
                Ensure = "Present" 
                Type = "Directory" 
                DestinationPath = "F:\Backup"
                # DependsOn = '[SqlAGReplica]AddReplica'    
            }

            xSMBShare DBBackupShare
            {
                Name = "DBBackup"
                Path = "F:\Backup"
                Ensure = "Present"
                FullAccess = $DomainCreds.UserName
                Description = "Backup share for SQL Server"
                DependsOn = "[File]BackupDirectory"
            }

            SqlDatabase Create_Database
            {
                Ensure       = 'Present'
                ServerName   = $env:COMPUTERNAME
                InstanceName = 'MSSQLSERVER'
                Name         = 'Ha-Sample'
                PsDscRunAsCredential    = $DomainCreds
                DependsOn               = "[xSMBShare]DBBackupShare"
            }
            
            SqlAGDatabase AddDatabaseToAG
            {
                AvailabilityGroupName   = $ClusterName
                BackupPath              = "\\" + $env:COMPUTERNAME + "\DBBackup"
                DatabaseName            = 'Ha-Sample'
                InstanceName            = 'MSSQLSERVER'
                ServerName              = $env:COMPUTERNAME
                Ensure                  = 'Present'
                ProcessOnlyOnActiveNode = $true
                PsDscRunAsCredential    = $DomainCreds
                DependsOn = "[SqlDatabase]Create_Database"
            }
        }

        LocalConfigurationManager 
        {
            RebootNodeIfNeeded = $true
        }
    }
}

function Get-NetBIOSName
{ 
    [OutputType([string])]
    param(
        [string]$DomainName
    )

    if ($DomainName.Contains('.')) {
        $length=$DomainName.IndexOf('.')
        if ( $length -ge 16) {
            $length=15
        }
        return $DomainName.Substring(0,$length)
    }
    else {
        if ($DomainName.Length -gt 15) {
            return $DomainName.Substring(0,15)
        }
        else {
            return $DomainName
        }
    }
}