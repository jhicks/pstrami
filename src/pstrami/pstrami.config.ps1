## define your environments here or in .\environments.ps1

Environment "local" -servers @(
    Server "localhost" @("CheckEnvironment");
    ) -installPath "c:\installs\local"

if(Test-Path .\environments.ps1) {
    . .\environments.ps1
}

#### Roles ####
 
Role "CheckEnvironment" -Incremental {} -FullInstall {}
 
#### functions for loading & validating the vars file ####

function script:load-vars($relativeSourceDir) {
	new-variable -name base_dir -value (resolve-path .) -Option Constant
    
    if(Test-Path .\vars.ps1) {
        . .\vars.ps1
    }
}

#### functions for working with databases ####

function script:db-permissions($db_server, $db_name, $login, [switch]$reader, [switch]$writer) {
    load-sql-snapin

    add-db-user $db_server $db_name $login

    # give permissions db_datareader & db_datawriter
    if($reader) {
        invoke-sqlcmd -ServerInstance $db_server -Database $db_name -Query "EXEC sp_addrolemember 'db_datareader', '$login'"
    }
    
    if($writer) {
        invoke-sqlcmd -ServerInstance $db_server -Database $db_name -Query "EXEC sp_addrolemember 'db_datawriter', '$login'"
    }
}

function script:add-db-user($db_server, $db_name, $login) {
    load-sql-snapin

    # add user to the server
    $script = "use [master] if not exists(select * from sys.server_principals where name = N'$login') create login [$login] from windows"
    invoke-sqlcmd -ServerInstance $db_server -Query $script

    # add user to the db
    $script = "if exists (select * FROM sys.database_principals where name = N'$login') drop user [$login]"
    invoke-sqlcmd -ServerInstance $db_server -Database $db_name -Query $script
    
    $script = "create user [$login] for login [$login]"
    invoke-sqlcmd -ServerInstance $db_server -Database $db_name -Query $script
}

function script:load-sql-snapin() {
    if((Get-PSSnapin -Name SqlServerCmdletSnapin100 -ErrorAction SilentlyContinue) -eq $null) {
        Add-PSSnapin SqlServerCmdletSnapin100 
    }
}

#### functions for working with IIS sites ####

function script:CreateWebSite($web_app_config) {
    if((Get-Module -Name WebAdministration) -eq $null) {
        Import-Module WebAdministration
    }
    
    create-directory $web_app_config.InstallPath

    Remove-Website $web_app_config.SiteName -ErrorAction SilentlyContinue
    Remove-WebAppPool $web_app_config.SiteName -ErrorAction SilentlyContinue

    # create app pool
    $app_pool = new-webapppool $web_app_config.SiteName -Force
    $app_pool.managedRuntimeVersion = "v4.0"
    if($web_app_config.AppPoolUser -ne $null) {
        $app_pool.processModel.userName = $web_app_config.AppPoolUser.Username
        $app_pool.processModel.password = $web_app_config.AppPoolUser.Password
        $app_pool.processModel.identityType = 3
    }
    
    $app_pool | Set-Item
    
    start-webapppool $web_app_config.SiteName

    # create site
    $site = new-website $web_app_config.SiteName -physicalPath $web_app_config.InstallPath -ApplicationPool $web_app_config.SiteName -Force
    $site.Stop()
    get-webbinding -name $web_app_config.SiteName | remove-webbinding #remove the default bindings
    $web_app_config.Bindings | %{ new-webbinding -name $web_app_config.SiteName -ipaddress $_.ipaddress -port $_.port -hostheader $_.hostheader -protocol $_.protocol }
    
    start-sleep 2 # give IIS some time
    $site.Start()
}

function script:Set-AppOffline($destination) {
    Copy-Item -ErrorAction SilentlyContinue -Force "$destination\__app_offline.htm"  "$destination\app_offline.htm" | out-null
}

function script:Set-AppOnline($destination) {
    Remove-Item -ErrorAction SilentlyContinue -Force "$destination\app_offline.htm" | out-null
}

#### functions for working with the file system ####

function script:copy-files($source,$destination,$exclude=@()) {
    Copy-Item $source -Destination $destination -Exclude $exclude -recurse -force | out-null
}

function script:sync-files($source,$destination,$skip=@()) {
    $msdeployexe = "C:\Program` Files\IIS\Microsoft` Web` Deploy\msdeploy.exe"

    $arguments = @("-verb:sync";"-source:dirPath=$source";"-dest:dirPath=$destination")
    $skip | %{ 
        $arg = "-skip:"
        $_.GetEnumerator() | %{ $arg += $_.Key + "=" + $_.Value + "," }
        $arguments += $arg.trimend(",")
    }
    
    Write-Host "Syncing files between '$source' and '$destination'.  Arguments: $arguments"
    
    &"$msdeployexe" $arguments | out-null
}

function script:create-directory($directory_name) {
    if(-not (test-path $directory_name)) {
        mkdir $directory_name -force | out-null
    } else {
        write-host ("WARNING: Cannot create directory {0} because it already exists!" -f $directory_name)
    }
}

function script:backup-directory($directory_name) {
    if(-not (test-Path $directory_name)) {
        write-host ("WARNING: Cannot backup directory {0} because it does not exist!" -f $directory_name)
        return $null
    }

    $backup_dir = $directory_name + "_bak"
    sync-files $directory_name $backup_dir
}

function script:delete-directory($directory_name) {
    rd $directory_name -recurse -force  -ErrorAction SilentlyContinue | out-null
}

#### functions for working with XML ####

function script:open-xml($filePath) {
    [xml] $fileXml = Get-Content $filePath
    return $fileXml
}

function script:peek-xml($filePath, $xpath, $namespaces = @{}) {
    [xml] $fileXml = Get-Content $filePath

    $node = get-xmlnode $fileXml $xpath $namespaces
    Assert ($node -ne $null) "could not find node @ $xpath"

    if($node.NodeType -eq "Element") {
        return $node.InnerText
    } else {
        return $node.Value
    }
}

function script:poke-xml($filePath, $xpath, $value, $namespaces = @{}) {
    [xml] $fileXml = Get-Content $filePath

    $node = get-xmlnode $fileXml $xpath $namespaces
    Assert ($node -ne $null) "could not find node @ $xpath"

    if($node.NodeType -eq "Element") {
        $node.InnerText = $value
    } else {
        $node.Value = $value
    }

    [Void]$fileXml.Save($filePath)
}

function script:get-xmlnode([xml]$fileXml, $xpath, $namespaces = @{}) {
    if($namespaces -ne $null -and $namespaces.Count -gt 0) {
        $ns = New-Object Xml.XmlNamespaceManager $fileXml.NameTable
        $namespaces.GetEnumerator() | %{ [Void]$ns.AddNamespace($_.Key,$_.Value) }
        $node = $fileXml.SelectSingleNode($xpath,$ns)
    } else {
        $node = $fileXml.SelectSingleNode($xpath)
    }

    return $node
}


# functions for working with queues
function delete-queue($server,$name) {
    $name = $server + '\private$\' + $name
    if ([System.Messaging.MessageQueue]::Exists($name) -eq $true) {
        [System.Messaging.MessageQueue]::Delete($name)
    }
}

############## config structures  ################

# structure for defining the configuration of a web application
function script:WebApp($install_path,$bindings,$app_pool_user,$site_name,$config = @()) {
    $obj = new-object Object
    $obj | add-member NoteProperty AppPoolUser $app_pool_user
    $obj | add-member NoteProperty Bindings $bindings
    $obj | add-member NoteProperty Config $config
    $obj | add-member NoteProperty InstallPath $install_path
    $obj | add-member NoteProperty SiteName $site_name
    
    return $obj
}

# structure for defining an IIS 7 web site binding
function script:WebSiteBinding($ipaddress,$port,$hostheader,$protocol) {
    $obj = new-object Object
    $obj | add-member NoteProperty ipaddress $ipaddress
    $obj | add-member NoteProperty port $port
    $obj | add-member NoteProperty hostheader $hostheader
    $obj | add-member NoteProperty protocol $protocol
    return $obj
}

# structure used for defining a user that a service or IIS app pool will run as
function script:Credentials($username,$password) {
    $obj = new-object Object
    $obj | add-member NoteProperty Username $username
    $obj | add-member NoteProperty Password $password
    return $obj
}

# structure for defning a database connection
function script:DatabaseConnection($server,$database,$credentials = $null) {
    $obj = new-object Object
    $obj | add-member NoteProperty Server $server
    $obj | add-member NoteProperty Database $database
    $obj | add-member NoteProperty Credentials $credentials
    
    $toConnectionString = [scriptblock] {
        $security = "Integrated Security=SSPI"
        if($this.Credentials -ne $null) {
            $security = "UserId=" + $this.Credentials.Username + ";Password=" + $this.Password
        }
        
        return "Data Source=" + $this.Server + ";Initial Catalog=" + $this.Database + ";" + $security + ";"
    }
    
    $obj | add-member ScriptProperty ConnectionString $toConnectionString
    
    return $obj
}

## structures for defining config files changes

function script:ConfigElement($filePath, $xpath, $value, $namespaces = @{}) {
    $obj = new-object Object
    $obj | add-member NoteProperty File $filePath
    $obj | add-member NoteProperty XPath $xpath
    $obj | add-member NoteProperty Value $value
    $obj | add-member NoteProperty Namespaces $namespaces
    return $obj
}

function script:ConnectionStringConfigElement($file,$name,$db) {
    return ConfigElement $file ("configuration/connectionStrings/add[@name='" + $name + "']/@connectionString") $db.ConnectionString
}

function script:AppSettingsConfigElement($file,$key,$value) {
    return ConfigElement $file ("configuration/appSettings/add[@key = '" + $key + "']/@value") $value
}
