[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification='Value will be stored unencrypted in .env,
# and used only for transient local development environments', Scope='Function')]
#.\init.ps1 -InitEnv -LicenseXmlPath "C:\license\license.xml" -AdminPassword "b"

[CmdletBinding(DefaultParameterSetName = "no-arguments")]
Param (
    [Parameter(HelpMessage = "Enables initialization of values in the .env file, which may be placed in source control.",
        ParameterSetName = "env-init")]
    [switch]$InitEnv,

    [Parameter(Mandatory = $true,
        HelpMessage = "The path to a valid Sitecore license.xml file.",
        ParameterSetName = "env-init")]
    [string]$LicenseXmlPath,

    # We do not need to use [SecureString] here since the value will be stored unencrypted in .env,
    # and used only for transient local development environments.
    [Parameter(Mandatory = $true,
        HelpMessage = "Sets the sitecore\\admin password for this environment via environment variable.",
        ParameterSetName = "env-init")]
    [string]$AdminPassword,
	
    [Parameter(Mandatory = $false,
        HelpMessage = "Sets the instance topology",
        ParameterSetName = "env-init")]
    [ValidateSet("xp0","xp1","xm1")]
    [string]$Topology = "xm1"
)

$ErrorActionPreference = "Stop";
$workinDirectoryPath = ".\topology\sitecore-$Topology"

if ($InitEnv) {
    if (-not $LicenseXmlPath.EndsWith("license.xml")) {
        Write-Error "Sitecore license file must be named 'license.xml'."
    }
    if (-not (Test-Path $LicenseXmlPath)) {
        Write-Error "Could not find Sitecore license file at path '$LicenseXmlPath'."
    }
    # We actually want the folder that it's in for mounting
    $LicenseXmlPath = (Get-Item $LicenseXmlPath).Directory.FullName
}

Write-Host "Preparing your Sitecore Containers environment!" -ForegroundColor Green

################################################
# Retrieve and import SitecoreDockerTools module
################################################

# Check for Sitecore Gallery
Import-Module PowerShellGet
$SitecoreGallery = Get-PSRepository | Where-Object { $_.SourceLocation -eq "https://sitecore.myget.org/F/sc-powershell/api/v2" }
if (-not $SitecoreGallery) {
    Write-Host "Adding Sitecore PowerShell Gallery..." -ForegroundColor Green
    Register-PSRepository -Name SitecoreGallery -SourceLocation https://sitecore.myget.org/F/sc-powershell/api/v2 -InstallationPolicy Trusted
    $SitecoreGallery = Get-PSRepository -Name SitecoreGallery
}

# Install and Import SitecoreDockerTools
$dockerToolsVersion = "10.2.7"
Remove-Module SitecoreDockerTools -ErrorAction SilentlyContinue
if (-not (Get-InstalledModule -Name SitecoreDockerTools -RequiredVersion $dockerToolsVersion -ErrorAction SilentlyContinue)) {
    Write-Host "Installing SitecoreDockerTools..." -ForegroundColor Green
    Install-Module SitecoreDockerTools -RequiredVersion $dockerToolsVersion -Scope CurrentUser -Repository $SitecoreGallery.Name
}
Write-Host "Importing SitecoreDockerTools..." -ForegroundColor Green
Import-Module SitecoreDockerTools -RequiredVersion $dockerToolsVersion
Write-SitecoreDockerWelcome

##################################
# Configure TLS/HTTPS certificates
##################################

Push-Location docker\traefik\certs
try {
    $mkcert = ".\mkcert.exe"
    if ($null -ne (Get-Command mkcert.exe -ErrorAction SilentlyContinue)) {
        # mkcert installed in PATH
        $mkcert = "mkcert"
    } elseif (-not (Test-Path $mkcert)) {
        Write-Host "Downloading and installing mkcert certificate tool..." -ForegroundColor Green
        Invoke-WebRequest "https://github.com/FiloSottile/mkcert/releases/download/v1.4.1/mkcert-v1.4.1-windows-amd64.exe" -UseBasicParsing -OutFile mkcert.exe
        if ((Get-FileHash mkcert.exe).Hash -ne "1BE92F598145F61CA67DD9F5C687DFEC17953548D013715FF54067B34D7C3246") {
            Remove-Item mkcert.exe -Force
            throw "Invalid mkcert.exe file"
        }
    }
    Write-Host "Generating Traefik TLS certificate..." -ForegroundColor Green
    & $mkcert -install
    & $mkcert "*.headless.localhost"

    # stash CAROOT path for messaging at the end of the script
    $caRoot = "$(& $mkcert -CAROOT)\rootCA.pem"
    Write-Host "Setting NODE Extra CA Cert to $caRoot"
    setx NODE_EXTRA_CA_CERTS $caRoot    
}
catch {
    Write-Error "An error occurred while attempting to generate TLS certificate: $_"
}
finally {
    Pop-Location
}


################################
# Add Windows hosts file entries
################################

Write-Host "Adding Windows hosts file entries..." -ForegroundColor Green

Add-HostsEntry "cm.headless.localhost"
if ($Topology -ne "xp0") {
  Add-HostsEntry "cd.headless.localhost"
}

Add-HostsEntry "id.headless.localhost"
Add-HostsEntry "astro.headless.localhost"
Add-HostsEntry "nextjs.headless.localhost"
Add-HostsEntry "react.headless.localhost"
Add-HostsEntry "vue.headless.localhost"
Add-HostsEntry "angular.headless.localhost"


###############################
# Populate the environment file
###############################

if ($InitEnv) {
    Push-Location $workinDirectoryPath	
	
	##################
	# Firstly, create .env file from template for clean slate approach
	##################
	Write-Host "Creating .env file." -ForegroundColor Green
	Copy-Item ".\.env.template" ".\.env" -Force

    Write-Host "Populating required .env file values..." -ForegroundColor Green

    # HOST_LICENSE_FOLDER
    Set-EnvFileVariable "HOST_LICENSE_FOLDER" -Value "'${LicenseXmlPath}'"

    # CM_HOST
    Set-EnvFileVariable "CM_HOST" -Value "cm.headless.localhost"

    if ($Topology -ne "xp0") {
      # CD_HOST
      Set-EnvFileVariable "CD_HOST" -Value "cd.headless.localhost"
    }

    # ID_HOST
    Set-EnvFileVariable "ID_HOST" -Value "id.headless.localhost"

    # REPORTING_API_KEY = random 64-128 chars
    Set-EnvFileVariable "REPORTING_API_KEY" -Value (Get-SitecoreRandomString 128 -DisallowSpecial)

    # TELERIK_ENCRYPTION_KEY = random 64-128 chars
    Set-EnvFileVariable "TELERIK_ENCRYPTION_KEY" -Value (Get-SitecoreRandomString 128 -DisallowSpecial)

    # MEDIA_REQUEST_PROTECTION_SHARED_SECRET    
	Set-EnvFileVariable "MEDIA_REQUEST_PROTECTION_SHARED_SECRET" -Value (Get-SitecoreRandomString 64 -DisallowSpecial)    

    # SITECORE_IDSECRET = random 64 chars    
    Set-EnvFileVariable "SITECORE_IDSECRET" -Value (Get-SitecoreRandomString 64 -DisallowSpecial)
	
    # SITECORE GRAPHQL UPLOADMEDIAOPTIONS ENCRYPTIONKEY
    Set-EnvFileVariable "SITECORE_GRAPHQL_UPLOADMEDIAOPTIONS_ENCRYPTIONKEY" -Value (Get-SitecoreRandomString 16 -DisallowSpecial)

	$idCertPassword = Get-SitecoreRandomString 12 -DisallowSpecial

    # SITECORE_ID_CERTIFICATE	
    $idCertificate = (Get-SitecoreCertificateAsBase64String -DnsName "localhost" -Password (ConvertTo-SecureString -String $idCertPassword -Force -AsPlainText) -KeyLength 2048)
    Set-EnvFileVariable "SITECORE_ID_CERTIFICATE" -Value $idCertificate
	
	# SITECORE_ID_CERTIFICATE_PASSWORD
    Set-EnvFileVariable "SITECORE_ID_CERTIFICATE_PASSWORD" -Value $idCertPassword
    
    # SQL_SA_PASSWORD
    # Need to ensure it meets SQL complexity requirements    
    Set-EnvFileVariable "SQL_SA_PASSWORD" -Value (Get-SitecoreRandomString 19 -DisallowSpecial -EnforceComplexity)

    # SQL_SERVER
    Set-EnvFileVariable "SQL_SERVER" -Value mssql

    # SQL_SA_LOGIN
    Set-EnvFileVariable "SQL_SA_LOGIN" -Value sa

    # SITECORE_ADMIN_PASSWORD
    Set-EnvFileVariable "SITECORE_ADMIN_PASSWORD" -Value $AdminPassword

    # JSS editing secret, should be provided to CM and rendering host    
    Set-EnvFileVariable "JSS_EDITING_SECRET" -Value (Get-SitecoreRandomString 64 -DisallowSpecial)
	
    # Set the instance topology
    Set-EnvFileVariable "TOPOLOGY" -Value $Topology
    Write-Host "The instance topology: $Topology" -ForegroundColor Green

    Pop-Location
}

Write-Host "Done!" -ForegroundColor Green

Write-Host
Write-Host ("#"*75) -ForegroundColor Cyan
Write-Host
Write-Host "You will need to restart your terminal or VS Code for it to take effect." -ForegroundColor Cyan
Write-Host ("#"*75) -ForegroundColor Cyan
