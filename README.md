# minitools
A collection of System administration tools for debian based linux systems

All bash based tools!

The files are separated in 3 Folders 

Scripts - Has the .sh files that are ready for use and have been tested 

Services - Are special scripts that need to ne run using cron jobs in the background

Changes and new scripts will be first posted into the testing branch, and merged to the main branch once ready,


*** Use the following commands to install and uninstall minitools ***

minitools_update_install_persistent 
 * Will Install in persistent mode, this allows the user to install minitools and call them with tabtab auto-completion 

minitools_download_only
 * Install download only, this will only download the scripts which rhe user can then call from the download folder 

minitools_uninstall_persistent
* Uninstall persistent, This will remove the files that were installed by the install persistent script 