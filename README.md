World of Warcraft-style (ish) minipets in Sven Co-op!

# Chat commands
pet menu  
pet (petname)  
pet (petname) \<SCALE>  
pet off  

SCALE can be a number between 0.1 and the scale entry in pets.txt  
eg: 1.0 for headcrab and 0.25 for garg  

<BR>

# CVars
Can be put in server and map configs  

as_command .pets_hidechat - 0/1 Suppress player chat when using plugin. (default: 0)  

as_command .pets_hideinfo - 0/1 Suppress info chat from plugin. (default: 0)  

<BR>  


# Console Commands  
Admins only  

.pets_reload - For reloading pets.txt when editing existing pet entries (to test animations and set bone controllers without having to restart the map)  
Dont' use this when adding or removing pets, only for editing existing entries in pets.txt  
Restart the map when adding or removing pets  

# INSTALLATION  
1) Put pets.as and pets.txt in `svencoop_addon\scripts\plugins\`
2) Put the following in `svencoop\default_plugins.txt`:

```
    "plugin"
    {
        "name" "Pet Followers"
        "script" "pets"
    }
```
