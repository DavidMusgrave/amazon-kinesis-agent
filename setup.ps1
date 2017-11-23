param
(
	[Parameter(Mandatory=$true)]
    [ValidateSet("build","install","uninstall","installservice")]
	[string]$Action
)
#region functions
function Get-Chocolatey
{
    $installed = $true
    try 
    {
        choco
    }
    catch 
    {
        $installed = $false
    }
    if (-not $installed)
    {
        try 
        {
            Set-ExecutionPolicy AllSigned
            Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1')) | Out-Null  
        }
        catch 
        {
            return $false
        }
    }
    return $true   
}
function Get-Usage
{
    @"
    To install Kinesis agent, type:
        setup.ps1 -Install
    To uninstall Kinesis agent, type:
        setup.ps1 -Uninstall
"@ | Out-Host
}
function Test-IsAdmin
{
    return (New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(`
        [System.Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Assert-Runtime
{
    # DM - bypass this test for now..
    return $true

    # only tested on windows 10 so far
    [array]$supportedPlatforms = @("win32nt")
    if (!($supportedPlatforms -icontains $PSVersionTable.Platform))
    {
        throw "Supported platforms are '$($supportedPlatforms)', '$($PSVersionTable.Platform)' is not supported."
        break
    }
    [array]$supportedPSVersions = @("6.0.0-beta")
    if (!($supportedPSVersions -icontains $PSVersionTable.PSVersion))
    {
        throw "Supported PSVersions are '$($supportedPSVersions)', '$($PSVersionTable.PSVersion)' is not supported."
        break
    }
    return $true
}
function Get-SetupVariables
{
    $retVal = $null
    switch ($PSVersionTable.Platform)
    {
        "win32nt" {
            $retVal = [PSCustomObject]@{
                "daemon_name" = "aws-kinesis-agent";
                "agent_user_name" = "aws-kinesis-agent-user";
                "bin_dir" = "/usr/bin";
                "cron_dir" = "/etc/cron.d";
                "config_dir" = "/etc/aws-kinesis";
                "jar_dir" = "/usr/share/$($daemon_name)/lib";
                "dependencies_dir" = "$($PSScriptRoot)\dependencies";
                "log_dir" = "/var/log/$($daemon_name)";
                "state_dir" = "/var/run/$($daemon_name)";
                "agent_service" = "$($init_dir)/$($daemon_name)";
            }
        }
    }

    # DM - bypassing this for now..
    $retVal = [PSCustomObject]@{
                "daemon_name" = "aws-kinesis-agent";
                "agent_user_name" = "aws-kinesis-agent-user";
                "bin_dir" = "/usr/bin";
                "cron_dir" = "/etc/cron.d";
                "config_dir" = "/etc/aws-kinesis";
                "jar_dir" = "/usr/share/$($daemon_name)/lib";
                "dependencies_dir" = "$($PSScriptRoot)\dependencies";
                "log_dir" = "/var/log/$($daemon_name)";
                "state_dir" = "/var/run/$($daemon_name)";
                "agent_service" = "$($init_dir)/$($daemon_name)";
            }


    return $retVal
}
function Get-JarDependencyList
{
    $aws_java_sdk_version = "1.11.28"
    return @(        
        "com.amazonaws:aws-java-sdk-core:$($aws_java_sdk_version)",
        "com.amazonaws:aws-java-sdk-kinesis:$($aws_java_sdk_version)",
        "com.amazonaws:aws-java-sdk-cloudwatch:$($aws_java_sdk_version)",
        "com.amazonaws:aws-java-sdk-sts:$($aws_java_sdk_version)",
        "com.fasterxml.jackson.core:jackson-annotations:2.6.3",
        "com.fasterxml.jackson.core:jackson-core:2.6.3",
        "com.fasterxml.jackson.core:jackson-databind:2.6.3",
        "com.fasterxml.jackson.dataformat:jackson-dataformat-cbor:2.6.3",
        "com.google.code.findbugs:jsr305:3.0.1",
        "com.google.guava:guava:18.0",
        "org.apache.httpcomponents:httpclient:4.5.1",
        "org.apache.httpcomponents:httpclient-cache:4.5.1",
        "org.apache.httpcomponents:httpmime:4.5.1",
        "org.apache.httpcomponents:httpcore:4.4.3",
        "org.apache.httpcomponents:httpcore-ab:4.4.3",
        "org.apache.httpcomponents:httpcore-nio:4.4.3",
        "commons-cli:commons-cli:1.2",
        "commons-codec:commons-codec:1.6",
        "commons-logging:commons-logging-adapters:1.1",
        "commons-logging:commons-logging-api:1.1",
        "org.apache.commons:commons-lang3:3.4",
        "log4j:log4j:1.2.17",
        "org.slf4j:slf4j-api:1.7.12",
        "org.slf4j:slf4j-log4j12:1.7.12",
        "com.beust:jcommander:1.48",
        "org.xerial:sqlite-jdbc:3.8.11.2",
        "joda-time:joda-time:2.8.2",
        "org.projectlombok:lombok:1.16.6"
    )
}
function Get-JarUrl
{
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$Package
    )
    $baseUrl = "http://search.maven.org/remotecontent?filepath="
    $groupId = $Package.Split(':')[0]
    $artifactId = $Package.Split(':')[1]
    $version = $Package.Split(':')[2]
    $path = $groupId.Replace('.', '/')
    $jar_name = "$($artifactId)-$($version).jar"    
    $url = "$($baseUrl)$($path)/$($artifactId)/$($version)/$($jar_name)"
    return $url
}
function Get-Jar
{
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$Url,
        [Parameter(Mandatory=$true)]
        [string]$TargetFolder
    )
    if (!(Test-Path $TargetFolder))
    {
        New-Item -Path $TargetFolder -ItemType Directory | Out-Null
    }
    $splits = $url.Split('/')
    $fileName = $splits[($splits.Count - 1)]
    $target = "$($TargetFolder)/$($fileName)"
    if (Test-Path $target)
    {
        "file '$($target)' already exists..." | Out-Host
    }
    else 
    {
        "downloading '$($Url)' to path '$($target)'" | Out-Host
        Invoke-WebRequest -Uri $Url -UseBasicParsing -Method Get -OutFile $target
    }
}
function Get-Nssm
{
    $url = "http://nssm.cc/ci/nssm-2.24-101-g897c7ad.zip"
    $output = "$($PSScriptRoot)\nssm.zip"
    $folder = "$($PSScriptRoot)\nssm"
    if (!(Test-Path $folder))
    {
        New-Item -Path $folder -item Directory | Out-Null
        Invoke-WebRequest -Uri $url -UseBasicParsing -OutFile $output
        Expand-Archive -Path $output -DestinationPath $folder
    }    
    return "$($folder)\nssm-2.24-101-g897c7ad\win64\nssm.exe"
}
function Get-Ant
{
    $installed = $true
    try 
    {
        $o = ant -h | Out-Null
    }
    catch 
    {
        $installed = $false
    }
    if (-not $installed)
    {
        choco install ant -y
        refreshenv
    }
    return $true
}
function Get-Java
{
    if (-not ($ENV:JAVA_HOME))
    {
        choco install jdk8 -y
        refreshenv
    }
}
function build
{
    param
    (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$SetupVariables,
        [Parameter(Mandatory=$true)]
        [array]$JarDependencies
    )
    # download jars
    $JarDependencies | ForEach-Object {
        Get-Jar -Url (Get-JarUrl -Package $_) -TargetFolder $SetupVariables.dependencies_dir
    }

    # ant build
    ant
    if ($LASTEXITCODE -ne 0)
    {
        throw "An error occured during ant build"
        break
    }
}
function install
{
    param
    (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$SetupVariables,
        [Parameter(Mandatory=$true)]
        [array]$JarDependencies,
        [Parameter(Mandatory=$true)]
        [string]$NssmPath
    )

    uninstall @PSBoundParameters

    "Installing Kinesis Agent ..." | Out-Host

    build -SetupVariables $SetupVariables -JarDependencies $JarDependencies

    $jarPath = "$($PSScriptRoot)\ant_build\lib\AWSKinesisStreamingDataAgent-1.1.jar"
    & $NssmPath "install" $SetupVariables.daemon_name "java" "-cp ""$SetupVariables.dependencies_dir/*;$($jarPath)"" ""com.amazon.kinesis.streaming.agent.Agent"""
    #& $NssmPath "start" $SetupVariables.daemon_name
}
function uninstall
{
    param
    (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$SetupVariables,
        [Parameter(Mandatory=$true)]
        [array]$JarDependencies,
        [Parameter(Mandatory=$true)]
        [string]$NssmPath
    )

    # remove service if it exists
    if ($service = Get-Service -Name $SetupVariables.daemon_name -ErrorAction SilentlyContinue)
    {
        "Stopping service '$($SetupVariables.daemon_name)'" | Out-Host
        $service | Stop-Service
        & $NssmPath "remove" "$($SetupVariables.daemon_name)" "confirm"
    }
}
function installservice
{
    param
    (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$SetupVariables,
        [Parameter(Mandatory=$true)]
        [string]$NssmPath
    )
    $jarPath = "$($PSScriptRoot)\ant_build\lib\AWSKinesisStreamingDataAgent-1.1.jar"
    & $NssmPath "install" $SetupVariables.daemon_name "java" "-cp ""$($SetupVariables.dependencies_dir)/*;$($jarPath)"" ""com.amazon.kinesis.streaming.agent.Agent"""
}
#endregion

#region checks
# check is elevated
if (!(Test-IsAdmin))
{
    throw "This script must be run with elevated permissions"
    break
}
#check runtime
if (!(Assert-Runtime))
{
    throw "Runtime has not been tested."
    break
}
#endregion

#region variable setup
Set-Location $PSScriptRoot
$SetupVars = Get-SetupVariables
$JarDependencies = Get-JarDependencyList
#endregion

#region main
# get chocolatey
if (!(Get-Chocolatey))
{
    throw "An error occured whilst install chocolatey, cannot continue."
    break
}
#region installs
# install ant
Get-Ant
# install java
Get-Java
# get nssm
$nssmPath = Get-Nssm
#endregion

# run main routines
switch ($Action.ToLower())
{
    "build" {build -SetupVariables $SetupVars -JarDependencies $JarDependencies}
    "install" {install -SetupVariables $SetupVars -JarDependencies $JarDependencies -NssmPath $nssmPath}
    "uninstall" {uninstall -SetupVariables $SetupVars -JarDependencies $JarDependencies -NssmPath $nssmPath}
    "installservice" {installservice -SetupVariables $SetupVars -NssmPath $nssmPath}
    default {Get-Usage}
}
#endregion