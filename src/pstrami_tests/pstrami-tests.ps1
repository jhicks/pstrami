Get-Module -Name pstrami | Remove-Module

$fullPathIncFileName = $MyInvocation.MyCommand.Definition
$currentScriptName = $MyInvocation.MyCommand.Name
$currentExecutingPath = $fullPathIncFileName.Replace("\$currentScriptName", "")

Import-Module (resolve-path "$currentExecutingPath\..\pstrami\pstrami.psm1")
Function Test.Can_load_config_file()
{
    #Arrange
    #Act
    Load-Configuration  "$currentExecutingPath\..\pstrami\pstrami.config.ps1"
	$Actual = Get-Environments
    
    #Assert

    if( -not ($Actual.length -gt 0))
	{
		throw "enviornment did not load"
	}	
}

Test.Can_load_config_file
