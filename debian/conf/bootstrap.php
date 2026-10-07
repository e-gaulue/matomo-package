<?php

/**
 * Debian integration for matomo-vanilla, and the only file this package adds to
 * /usr/share/matomo. Everything else in that directory is upstream's release,
 * byte for byte.
 *
 * Matomo loads this file from the document root, before its own core/bootstrap.php,
 * from all three entry points -- index.php, console and piwik.php (the tracker).
 * That is upstream's documented hook, which is why nothing here requires patching
 * a single upstream file.
 *
 * PIWIK_USER_PATH is what separates "the code" from "this installation's writable
 * state". Setting it moves three things out of the code tree at once:
 *
 *     PIWIK_USER_PATH/config/config.ini.php   this installation's configuration
 *     PIWIK_USER_PATH/tmp                     caches, sessions, compiled templates
 *     PIWIK_USER_PATH/misc/user               files an administrator uploads
 *
 * /var/lib/matomo/config is a symlink to /etc/matomo, so config.ini.php stays
 * exactly where it has always been and no existing installation has to move it.
 * The symlink lives outside /usr/share/matomo on purpose: that is the one place
 * Matomo's own updater never writes, so unpacking a new release over the tree can
 * no longer destroy the link -- which is precisely what used to break this package.
 *
 * global.ini.php is NOT affected: Matomo reads it from PIWIK_DOCUMENT_ROOT, so it
 * stays in the code tree as upstream's own unmodified file. That is what lets this
 * package ship upstream's integrity manifest as it is, instead of regenerating one.
 */

if (!defined('PIWIK_USER_PATH')) {
    define('PIWIK_USER_PATH', '/var/lib/matomo');
}

/*
 * Where extensions installed from the Marketplace live, and it is not the code tree.
 *
 * Matomo's Marketplace has to write a plugin's files somewhere. Left to itself that
 * somewhere is /usr/share/matomo/plugins, so the only way to let an administrator
 * install an extension would be to make part of the code tree writable by the web
 * server -- and a directory the web server can write to is a directory in which it
 * can displace an existing plugin and run its own code instead. That is the one
 * property this package exists to keep.
 *
 * These two settings are upstream's answer, and they separate the two concerns:
 *
 *   MATOMO_PLUGIN_DIRS      the directories Matomo LOADS plugins from
 *   MATOMO_PLUGIN_COPY_DIR  the single directory the Marketplace INSTALLS into
 *
 * So /var/lib/matomo/plugins belongs to www-data and holds what the administrator
 * installs, while /usr/share/matomo stays owned by root throughout, upstream's release
 * untouched. Both paths need the trailing slash: Matomo compares the copy directory
 * against its list of plugin directories by exact string, and builds that list with
 * one.
 *
 * webrootDirRelativeToMatomo is how Matomo builds URLs for a plugin's own JavaScript,
 * CSS and images, so it has to name a path the web server can reach: the symlink
 * plugins-ext, shipped beside this file. Matomo's integrity check does not object to
 * it, so nothing has to be declared anywhere -- checked both ways, against a planted
 * directory that the same check does report.
 */
$GLOBALS['MATOMO_PLUGIN_DIRS'] = array(
    array(
        'pluginsPathAbsolute'        => '/var/lib/matomo/plugins/',
        'webrootDirRelativeToMatomo' => 'plugins-ext',
    ),
);
$GLOBALS['MATOMO_PLUGIN_COPY_DIR'] = '/var/lib/matomo/plugins/';

/*
 * Where the GeoIP 2 / DB-IP databases live, and it is not the code tree either.
 *
 * Matomo resolves them through the container entry path.geoip2, which upstream
 * defines as misc/ inside the code tree: that is where the Marketplace-free
 * "automatic setup" of the GeoIp2 plugin downloads DB-IP Lite, and where the
 * monthly updater writes the next one. In this package the tree belongs to root,
 * so left as is, both would fail. StaticContainer::addDefinitions() is upstream's
 * hook for overriding container entries from outside -- its definitions are added
 * after every other source, so this one wins -- and the class has no dependency of
 * its own, so it can be loaded here, before Matomo's bootstrap and its autoloader.
 * The trailing slash is required: Matomo appends the file name to this value.
 */
require_once PIWIK_DOCUMENT_ROOT . '/core/Container/StaticContainer.php';
\Piwik\Container\StaticContainer::addDefinitions(array(
    'path.geoip2' => '/var/lib/matomo/geoip/',
));
