# minitools
A collection of System administration tools for debian based linux systems

All bash based tools, however some scripts point to other projects and may download python3 Scripts, 
an example of this is the speed test script, 



The script files are really bash scripts, the .sh at the end was removed to make the scripts name look cleaner, 


Scripts Folder - Has the sh files that are ready for use and have been tested 

Services - Are special scripts that need to ne run using cron jobs in the background


Changes and new scripts will be first posted into the testing branch, and merged to the main branch once ready,


#                          *** Quick Install Commands ***

* To only download the scripts to your system without saving them to /usr/bin but to a tmp folder use the command below
<pre>
```curl -sSL https://raw.githubusercontent.com/dberistain001/minitools/main/minitools_update_install_persistent | bash
```
</pre>


* To only download the scripts to your system without saving them to /usr/bin but to a tmp folder use the command below
<pre>
```curl -sSL https://raw.githubusercontent.com/dberistain001/minitools/main/minitools_download_only | bash
```
</pre>


#                     *** to install and uninstall minitools ***

minitools_update_install_persistent 
 * Will Install in persistent mode, this allows the user to install minitools and call them with tabtab auto-completion 

minitools_download_only
 * Install download only, this will only download the scripts which rhe user can then call from the download folder 

minitools_uninstall_persistent
* Uninstall persistent, This will remove the files that were installed by the install persistent script 