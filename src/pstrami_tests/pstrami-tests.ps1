Get-Module -Name pstrami | Remove-Module
Import-Module .\src\pstrami\pstrami.psm1

Function Test.Can_load_config_file()
{
    #Arrange
    #Act
    Load-Configuration  ".\src\pstrami\pstrami.config.ps1"
	$Actual = Get-Environments
    
    #Assert

    if( -not ($Actual.length -gt 0))
	{
		throw "enviornment did not load"
	}	
}

Test.Can_load_config_file


