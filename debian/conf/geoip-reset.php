<?php
/**
 * Make Matomo refresh its GeoIP 2 database at the next scheduled run.
 *
 * Called by finish-setup, once, after a database was moved out of the code tree at
 * the switch from the old matomo package. Under that package the monthly update
 * could not write into misc/, so the file is as old as the day it was put there, while
 * Matomo's record of the last update says otherwise. Forgetting that record is what
 * makes the updater run again at the next scheduled task, if an update URL is
 * configured; nothing else is touched.
 */
define('PIWIK_DOCUMENT_ROOT', '/usr/share/matomo');
require_once PIWIK_DOCUMENT_ROOT . '/bootstrap.php';
define('PIWIK_INCLUDE_PATH', PIWIK_DOCUMENT_ROOT);
require_once PIWIK_INCLUDE_PATH . '/core/bootstrap.php';
$env = new \Piwik\Application\Environment(null);
$env->init();
\Piwik\Option::delete(\Piwik\Plugins\GeoIp2\GeoIP2AutoUpdater::LAST_RUN_TIME_OPTION_NAME);
echo "GeoIP 2 updater: last-run record cleared, the next scheduled run updates the database.\n";
