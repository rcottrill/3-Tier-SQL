configuration ConfigureSecondDC
{
   param
    (
        [Parameter(Mandatory)]
        [String]$DC01IP,

         [Parameter(Mandatory)]
        [String]$DC02IP,

        [Parameter(Mandatory)]
        [String]$DomainName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds,

        [Int]$RetryCount=20,
        [Int]$RetryIntervalSec=30
    )

    Import-DscResource -ModuleName xActiveDirectory, xPendingReboot, xNetworking

    [System.Management.Automation.PSCredential ]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)
    $Interface=Get-NetAdapter|Where Name -Like "Ethernet*"|Select-Object -First 1
    $InterfaceAlias=$($Interface.Name)


    Node localhost
    {
        LocalConfigurationManager
        {
            RebootNodeIfNeeded = $true
        }

        WindowsFeature ADDSInstall
        {
            Ensure = "Present"
            Name = "AD-Domain-Services"
        }

        WindowsFeature ADDSTools
        {
            Ensure = "Present"
            Name = "RSAT-ADDS-Tools"
            DependsOn = "[WindowsFeature]ADDSInstall"
        }

        WindowsFeature ADAdminCenter
        {
            Ensure = "Present"
            Name = "RSAT-AD-AdminCenter"
            DependsOn = "[WindowsFeature]ADDSTools"
        }

        xDnsServerAddress DnsServerAddress
        {
            Address        = $DC01IP, $DC02IP
            InterfaceAlias = $InterfaceAlias
            AddressFamily  = 'IPv4'
            DependsOn="[WindowsFeature]ADDSInstall"
        }

        xWaitForADDomain DscForestWait
        {
            DomainName = $DomainName
            DomainUserCredential= $DomainCreds
            RetryCount = $RetryCount
            RetryIntervalSec = $RetryIntervalSec
        }

        xADDomainController DC2
        {
            DomainName = $DomainName
            DomainAdministratorCredential = $DomainCreds
            SafemodeAdministratorPassword = $DomainCreds
            DatabasePath = "C:\Windows\NTDS"
            LogPath = "C:\Windows\NTDS"
            SysvolPath = "C:\Windows\SYSVOL"
            DependsOn = "[xWaitForADDomain]DscForestWait"
        }

        Script UpdateDNSForwarder
        {
            SetScript =
            {
                Write-Verbose -Verbose "Getting DNS forwarding rule..."
                Add-DnsServerForwarder -IPAddress '8.8.8.8' -PassThru
                Add-DnsServerForwarder -IPAddress '8.8.4.4' -PassThru
                Write-Verbose -Verbose "End of UpdateDNSForwarder script..."
            }
            GetScript =  { @{} }
            TestScript = {$false}
            DependsOn = "[xADDomainController]DC2"
        }

        xPendingReboot RebootAfterPromotion {
            Name = "RebootAfterDCPromotion"
            DependsOn = "[xADDomainController]DC2"
        }

        Script UpdateADSite
        {
            SetScript =
            {
                Write-Verbose -Verbose "Renaiming Defalt Site.."
                Get-ADObject -Identity “CN=Default-First-Site-Name,CN=Sites,$((Get-ADRootDSE).ConfigurationNamingContext)" | Rename-ADObject -NewName Azure
                New-ADReplicationSubnet -Name "10.0.1.0/24" -Site Azure -Location "Azure Cloud"
                Write-Verbose -Verbose "Finished Renaiming Defalt Site.."
            }
            GetScript =  { @{} }
            TestScript = {$false}
            DependsOn = "[xPendingReboot]RebootAfterPromotion"
        }

    }
}

