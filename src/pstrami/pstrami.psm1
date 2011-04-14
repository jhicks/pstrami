#--- deployment functions

function Deploy-Package{
    param(
        [string]$EnvironmentName,
        [string]$Package,
        [boolean]$Install=$false)
        
    Load-Configuration

    if(test-path .\pstrami_logs) {
		rmdir .\pstrami_logs -recurse | out-null
	}
	
	if(-not (test-path .\pstrami_logs)) {
		mkdir .\pstrami_logs | out-null
	}
	
    $package = resolve-path $package
    get-environments | ?{$_.Name -eq $EnvironmentName} | %{deploy-environment $_ $package $Install}
}

function deploy-environment($environment, [string]$package, [boolean]$Install=$false) {
    $index = 0
    $environment.Servers | %{
        install-remoteserver $index $_ $package $environment $Install
        $index++
    }
}

function Install-RemoteServer{
    param(
        [int] $index,
        [object]  $server,
        [string]  $packagePath,
        [object]  $environment,
        [boolean] $OneTime=0,
        [string] $successMessage = "Deployment Succeded")
    write-host "Install-RemoteServer"
    
    Send-Files $packagePath $server.Name $environment.InstallPath $server.Credential

    Create-RemoteBootstrapper $index $server.Name $environment.InstallPath $environmentName $OneTime | out-file .\pstrami_logs\bootstrap.bat -encoding ASCII
    
    $result = Invoke-RemoteCommand $server.Name (resolve-path .\pstrami_logs\bootstrap.bat) $server.Credential

    if(-not (select-string -InputObject $result -pattern $successMessage))
    {    
        write-host ("Install-RemoteServer Failed.  Check the logs @ " + (resolve-path .\pstrami_logs\bootstrap.bat)) -ForegroundColor Red
        exit '-1'
    }    
    write-host "Install-RemoteServer Succeeded"
}

function Invoke-RemoteCommand{
    param(  [string] $server,
            [string] $cmd,
            [string] $cred="")
    
    if($cred -ne "")
    {
        $cred = "," + $cred
    }
    $msdeployexe= "C:\Program` Files\IIS\Microsoft` Web` Deploy\msdeploy.exe"    
    $result = &"$msdeployexe" "-verb:sync" "-dest:auto,computername=$server$cred" "-source:runCommand=$cmd,waitInterval=2500,waitAttempts=1000"
    
    $result | out-file .\pstrami_logs\invoke-remotecommand.log -Append
    return $result    
}

function Send-Files{
    param(  [string] $packagePath,
            [string] $server,
            [string] $remotePackagePath,
            [string] $cred)
    write-host "Sending Files to $server : $remotePackagePath"        
    $msdeployexe= "C:\Program` Files\IIS\Microsoft` Web` Deploy\msdeploy.exe"    
   
    if($cred -ne "")
    {
        $cred = "," + $cred
    }

    &"$msdeployexe" "-verb:sync" "-source:dirPath=$packagePath" "-dest:dirPath=$remotePackagePath,computername=$server$cred" "-skip:objectName=dirPath,absolutePath=pstrami_logs" | out-file .\pstrami_logs\sync-package.log
    Get-Content .\pstrami_logs\sync-package.log | Select-Object -last 1 | out-default
}

function Create-RemoteBootstrapper{
    param(  [int] $index,
            [string]$serverName,
            [string] $remotePackagePath,
            [string] $EnvironmentName,
            [boolean] $OneTime=0)
    
    $fullinstall = 0
    
    if($OneTime -eq $true) {
        $fullinstall = 1
    }
    
    return '@echo off
    cd /D ' + $remotePackagePath + '
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy unrestricted -Command "& { try { import-module .\pstrami.psm1; Load-Configuration;Install-LocalServer ' + $index + ' ' + $serverName + ' ' + $remotePackagePath + ' ' + $EnvironmentName + ' ' + $fullinstall + '; } catch { write-host "ERROR: $Error" }; stop-process $pid; }'
}

#--- local install functions

function Install-LocalServer {
    param([int] $index, [string]$serverName, [string] $packagePath,[string]$environmentName,[boolean]$OneTime=$false)
    
    set-location $packagePath
	
	dir modules\*.psm1 | Import-Module

    $global:env = $environmentName
    write-host "Deploying server $serverName ($index) for environment named $global:env"

    $environment = Get-Environments | ?{$_.Name -eq $environmentName}
    if($environment -eq $null) {
        write-host ("ERROR: Could not find environment " + $environmentName)
        return;
    }
    
    $server = $environment.Servers[$index]
    if($server -eq $null) { 
        write-host ("ERROR: No server defined @ index " + $index + " in environment " + $environmentName)
        return;
    }

    $global:server = $server
    $definedRoles = $script:context.Peek().roles
    
    $server.Roles | %{
        Assert ($definedRoles.ContainsKey($_.ToLower()) -eq $true) ("No role named " + $_ + " (" + $_.ToLower() + ") defined")
        $role = $definedRoles[$_.ToLower()]
        Assert ($role -ne $null) ("Could not load role " + $_ + " (" + $_.ToLower() + ")")
        
        execute-role $role $OneTime
    }

	write-host "Deployment Succeded"
}

function Execute-Role($role, [boolean]$fullinstall) {
    write-host ("Executing Role: {0}" -f $role.Name)
    
    
    if($fullinstall -eq $true) {
        invoke-command -scriptblock $role.FullInstall -ErrorAction Stop
    }

    invoke-command -scriptblock $role.Action -ErrorAction Stop
}

#--- configuration functions

function Load-Configuration {
	param([string]$configFile=".\pstrami.config.ps1")
	write-host "Loading Config from $configFile"

    if ($script:context -eq $null)
	{
		$script:context = New-Object System.Collections.Stack
	}
		
	$script:context.push(@{
        "roles" = @{}; #contains the deployment steps for each role        
        "environments" = @{};            
	})
    . $configFile
}

function Role {
    param(
    [Parameter(Position=0,Mandatory=1)]
    [string]$name = $null, 
    [Parameter(Position=1,Mandatory=1)]
    [scriptblock]$incremental = $null, 
    [Parameter(Position=1,Mandatory=1)]
    [scriptblock]$fullinstall = $null
    )
	$newTask = @{
		Name = $name
		Action = $incremental
        FullInstall = $fullinstall
	}
	
	$taskKey = $name.ToLower()
	
	Assert (-not $script:context.Peek().roles.ContainsKey($taskKey)) "Error: Role, $name, has already been defined."
	
	$script:context.Peek().roles.$taskKey = $newTask
}

function Server {
    param(
    [Parameter(Position=0,Mandatory=1)]
    [string]$name, 
    [Parameter(Position=1,Mandatory=1)]
    [string[]]
    $roles = $null,
    [string] $credential=""
    )
	$newTask = "" | select-object Name,Roles,Credential
    $newTask.Name = $name
	$newTask.Roles = $roles
	$newTask.Credential  = $credential
	
	return $newTask
}
	
function Environment {
    param(
    [Parameter(Position=0,Mandatory=1)]
    [string]$name, 
    [Parameter(Position=1,Mandatory=1)]
    [object[]]$servers ,
    [string] $installPath
    )
	$newTask = "" | select-object Name,Servers,InstallPath
	$newTask.Name = $name
	$newTask.Servers = $servers
    $newTask.InstallPath = $installPath
	
	
	$taskKey = $name.ToLower()
	
	Assert (-not $script:context.Peek().environments.ContainsKey($taskKey)) "Error: Environment, $name, has already been defined."
	
	$script:context.Peek().environments.$taskKey = $newTask
}

#--- general functions

function Assert { [CmdletBinding(
    SupportsShouldProcess=$False,
    SupportsTransactions=$False, 
    ConfirmImpact="None",
    DefaultParameterSetName="")]
	
	param(
	  [Parameter(Position=0,Mandatory=1)]$conditionToCheck,
	  [Parameter(Position=1,Mandatory=1)]$failureMessage
	)
	if (!$conditionToCheck) { throw $failureMessage }
}

function Get-Environments{
    return $script:context.Peek().environments.Values
}

function Get-Roles {
    return $script:context.Peek().roles.Values
}

Export-ModuleMember Load-Configuration, Deploy-Package, Install-LocalServer, Get-Environments, Get-Roles