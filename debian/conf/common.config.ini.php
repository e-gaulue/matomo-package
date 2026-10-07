; <?php exit; ?> DO NOT REMOVE THIS LINE
;
; Settings this package sets for you, which you can override.
;
; Matomo merges three files, in this order: config/global.ini.php from the code tree
; (upstream's defaults, shipped unmodified), then this file, then config.ini.php -- your
; own file, the only one Matomo ever writes to. So anything you set in config.ini.php
; wins over what is here, and nothing Matomo does through its interface can touch this
; file.

[General]

; Matomo's own one-click updater, off by default here because apt is in charge of the
; code: /usr/share/matomo belongs to root and holds exactly what the package put there,
; which is how dpkg's record keeps describing what is on disk.
;
; Turning this to 1 is a legitimate choice -- see "Updating Matomo" in
; /usr/share/doc/matomo-vanilla/README.Debian -- but the setting alone is not enough:
; Matomo also needs to be able to write the code tree, and it cannot. Set it in
; config.ini.php rather than here, and give the web server ownership of the tree:
;
;     sudo chown -R www-data:www-data /usr/share/matomo
;
; Without that, Matomo refuses before it writes anything and names the directories it
; could not write ("Some folders are not writable..."). Nothing is left half-updated.
enable_auto_update = 0
