# !!!DO NOT MODIFY THIS FILE TO CUSTOMIZE THE DEPLOYMENT FOR SPECIFIC ENVIRONMENTS!!!
# Create a file named <ENV>.vars.ps1, where <ENV> is the environment you want to customize.

# Define default configuration here
$log_level = "DEBUG" # sample


######################## end of customizable configuration #####################

# weave in the environment specific vars files
if(test-path "$base_dir\$global:env.vars.ps1") {
	write-host "Loading $base_dir\$global:env.vars.ps1"
	. "$base_dir\$global:env.vars.ps1"
}

## place any configuration you don't want changed in the environment vars file below here.
## I usually create component, website, and database configuration structures here