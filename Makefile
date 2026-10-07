# Makefile for Matomo (Piwik) package construction
#
# This is what you mostly need to know about this Makefile
# * make release: When a new release has been published
# * make upload: To upload your debian package
# * make commitrelease: To commit your debian/changelog
# * make builddeb: To rebuild your debian package. debian/changelog is not updated
# * make checkdeb: To check the package compliance using lintian
#
# Options are:
# * RELEASE_VERSION=x.y.z Specify which package version you want to build
# * RELEASE_CHANGELOG=x.y.z Specify which package version you want to get changelog from

URL		= https://builds.matomo.org
# The key that signs the release tarballs: "Matomo <hello@matomo.org>", RSA-4096,
# created 2022-02-23. Asserted below rather than merely offered to gpg, since a bare
# "gpg --verify" accepts any key present in the keyring.
FINGERPRINT	= F529A27008477483777FC23D63BB30D0E5D2C749

# Upstream's version as the changelog names it: the epoch and the Debian revision
# are both dropped, since neither appears in the name of an upstream archive.
CURRENT_VERSION	:= $(shell head -1 debian/changelog | sed 's/.*(//;s/).*//;s/^[0-9]*://;s/-[^-]*$$//')
DEB_ARCH := $(shell dpkg-architecture -qDEB_BUILD_ARCH)

ifndef DEB_VERSION
DEB_VERSION := $(shell head -n 1 debian/changelog | sed 's/.*(//;s/).*//;')
endif

ifndef DEB_STATUS
DEB_STATUS := $(shell head -n 1 debian/changelog | awk '{print $$3}' | sed 's/;//g')
endif

# Upstream's latest, and its ONLY job is to decide whether a release newer than the
# changelog exists -- which is what "make release" asks. Assigned lazily, so a plain
# package build makes no request at all; only the targets that compare versions do.
#
# It is deliberately NOT what gets built. Those are two different questions, and
# conflating them means a build started after upstream publishes silently packages the
# new release under the changelog's version number: the .deb says 5.14.0-1 and carries
# 5.14.1. BUILD_VERSION below answers the build question.
ifndef RELEASE_VERSION
RELEASE_VERSION	= $(shell curl -sfL $(URL)/LATEST)
endif

ifndef RELEASE_CHANGELOG
RELEASE_CHANGELOG	:= $(RELEASE_VERSION)
endif

RELEASE_VERSION_GREATER = $(shell ./debian/scripts/vercomp.sh $(RELEASE_VERSION) $(CURRENT_VERSION))
RELEASE_VERSION_LOWER = $(shell ./debian/scripts/vercomp.sh $(RELEASE_VERSION) $(CURRENT_VERSION))

# Which of the two extensions upstream published for this release. The archive
# already sitting here answers the question without a request: this is evaluated on
# every make invocation, including the ones that only print a version, so probing the
# network each time means hundreds of requests over a build campaign -- enough for the
# publisher's CDN to start answering 403.
#
# The probe itself is a one-byte ranged GET rather than a HEAD, because the CDN
# refuses HEAD.
# What this build packages: the version at the head of debian/changelog, always. A
# rebuild is reproducible from the changelog alone, and "make release" still works --
# it rewrites the changelog first, so by the time the package is built this follows.
BUILD_VERSION	:= $(CURRENT_VERSION)

ifndef PW_ARCHIVE_EXT
PW_ARCHIVE_EXT	:= $(shell \
	if [ -f matomo-$(BUILD_VERSION).tar.gz ]; then echo 'tar.gz'; \
	elif [ -f matomo-$(BUILD_VERSION).zip ]; then echo 'zip'; \
	elif curl -sfL -r 0-0 -o /dev/null $(URL)/matomo-$(BUILD_VERSION).tar.gz; then echo 'tar.gz'; \
	else echo 'zip'; fi )
endif

# Upstream's second publication of the same signed artefact, used only as a
# fallback in checkfetch.
GH_URL		= https://github.com/matomo-org/matomo/releases/download/$(BUILD_VERSION)

ARCHIVE		= matomo-$(BUILD_VERSION).$(PW_ARCHIVE_EXT)
SIG		= matomo-$(BUILD_VERSION).$(PW_ARCHIVE_EXT).asc

DESTDIR		= /
DIST		= stable
URGENCY		= high

MAKE_OPTS	= -s

INSTALL		= /usr/bin/install

.PHONY		: checkfetch fixperms checkversions release checkenv builddeb checkdeb checkdebdetail newrelease newversion changelog history clean upload

RED		= \033[0;31m
GREEN		= \033[0;32m
NC		= \033[0m

# Fetch the matomo archive and its signature, verify the signature, unpack.
#
# curl and not wget: builds.matomo.org answers 403 to wget, whatever the request.
# Downloaded to .part and renamed on success, so a refused or interrupted fetch leaves
# no truncated archive for the next run to mistake for a good one. The GitHub release
# is upstream's other publication of the same artefact and stands in when the primary
# refuses; which one answered does not matter, since the signature assertion below is
# what decides whether the file is used.
checkfetch:
		@echo -n " [CURL] ... "
		@for f in "$(SIG)" "$(ARCHIVE)"; do \
			[ -f "$$f" ] && continue; \
			echo -n "$$f "; \
			curl -sfL --retry 2 -o "$$f.part" "$(URL)/$$f" \
			|| curl -sfL --retry 2 -o "$$f.part" "$(GH_URL)/$$f" \
			|| { rm -f "$$f.part"; echo ""; \
			     echo " [ERR] cannot fetch $$f from $(URL) nor $(GH_URL)"; exit 1; }; \
			mv "$$f.part" "$$f"; \
		done
		@echo "done."
		@gpgconf --kill dirmngr
# keys.gnupg.net was a CNAME onto the SKS keyserver pool, which was shut down in
# 2019; the name no longer resolves at all. On a machine that already has the key
# this line does nothing and the breakage is invisible, which is why it went
# unnoticed -- but on a fresh build host the fetch fails and the verification below
# then fails too, with the keyserver as the real cause and nothing saying so.
		@test ! -z "$(shell gpg --list-keys | grep $(FINGERPRINT))" \
			|| gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys $(FINGERPRINT) \
			|| gpg --keyserver hkps://keys.openpgp.org --recv-keys $(FINGERPRINT)
# Assert the signature was made by that key, instead of merely asking gpg whether
# *some* key in the keyring vouches for the tarball. The last field of VALIDSIG is
# the primary key fingerprint, so this still holds if upstream signs with a subkey.
		@echo -n " [GPG] verify $(FINGERPRINT)... "
		@gpg --status-fd 1 --verify $(SIG) 2>/dev/null \
			| awk '/^\[GNUPG:\] VALIDSIG /{ if ($$NF == "$(FINGERPRINT)") { print "ok."; found=1 } } END{ exit !found }' \
			|| { echo "$(RED)FAILED$(NC)"; \
			     echo "        $(RED)$(SIG) is not signed by $(FINGERPRINT).$(NC)"; \
			     echo "        $(RED)Signature details:$(NC)"; \
			     gpg --verify $(SIG) 2>&1 | sed 's/^/        /'; \
			     exit 1; }
		@echo " [RM] matomo/" && if [ -d "matomo" ]; then rm -rf "matomo"; fi
		@echo " [UNPACK] $(ARCHIVE)"
		@test "$(PW_ARCHIVE_EXT)" != "zip" || unzip -qq $(ARCHIVE)
		@test "$(PW_ARCHIVE_EXT)" != "tar.gz" || tar -zxf $(ARCHIVE)
# The unpacked tree must be the version the changelog claims. Without this the package
# can declare one version and ship another, which is a lie dpkg has no way to catch --
# and which this package's own preinst refuses on the next upgrade, having compared the
# two. Checked against the code rather than the file name, since a file can be renamed.
		@echo -n " [VER] tree is Matomo $(BUILD_VERSION)... "
		@sed -n "s/.*[[:space:]]VERSION[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" \
			matomo/core/Version.php | head -1 \
			| grep -qx '$(BUILD_VERSION)' \
			|| { echo "$(RED)FAILED$(NC)"; \
			     echo "        $(RED)debian/changelog says $(BUILD_VERSION), core/Version.php says$(NC)"; \
			     sed -n "s/.*[[:space:]]VERSION[[:space:]]*=[[:space:]]*'\([^']*\)'.*/        \1/p" \
			         matomo/core/Version.php | head -1; \
			     exit 1; }
		@echo "ok." 

# perform some cleanup tasks to remove extraneous files
# from the built package. Some (js)libs are dragged with
# examples and extra material that aren't required in the
# final package
# Upstream's archive carries one entry OUTSIDE matomo/ -- "How to install Matomo.html"
# at its top level -- which tar drops into the repository root. Left there, untracked,
# it makes githelp.sh refuse "make commitrelease". Removing it is this target's whole
# job: the tree itself is left alone, /usr/share/matomo being upstream's release as it
# ships it. If upstream ever ships something that does not belong in a package,
# lintian is what says so.
cleanup:
		@echo " [RM] stray archive entry at the repository root"
		@rm -f 'How to install Matomo.html'

# checkconfig is gone with the layout it policed. It compared the config/ files
# upstream ships against the lines mirroring them into /etc/matomo, to catch a new
# one being silently dropped. Nothing is mirrored any more: config/ stays in the tree
# as upstream's own directory, so a file appearing there is installed by the
# "matomo/config" line without anyone having to notice.

checkmatomoinstall:
	@echo -n " [CONF] Checking other files/dir... "
	@for F in $(shell cat debian/matomo-vanilla.install|grep ^matomo|cut -f1) ; do \
		echo -n "  * checking in matomo.install: $$F"; \
		if [ ! -e "$$F" ]; then \
			echo " $(RED)missing$(NC)."; \
			echo "1" >&2; \
		else \
			echo " $(GREEN)ok$(NC)."; \
		fi; \
	done 3>&2 2>&1 1>&3 | grep --silent "1" && exit 1 || echo >/dev/null

# Every entry at the root of the upstream tree must be accounted for in
# debian/matomo-vanilla.install, either installed or deliberately commented out, so that a
# file upstream starts shipping is never dropped without anyone noticing.
#
# This check used to be inert. It read:
#     if [ ! $(shell grep "^matomo/$$F" debian/matomo-vanilla.install) ]; then
# and make expands $(shell ...) once, while reading the file, before the loop
# exists and with $$F still unset. The grep therefore ran as "^matomo/" and its
# entire output was pasted into the recipe as literal words, so every iteration
# executed "[ ! word word word ... ]", which fails with "too many arguments" --
# and the check reported "ok" for everything, including entries genuinely absent
# from the file. Verified on 5.14.0: it passed "tmp", which debian/matomo-vanilla.install
# does not mention at all. Same shape as the manifest guard fixed for issue #150:
# a $(shell) inside a recipe cannot see a shell loop variable.
checkmatomorootdir:
	@echo " [CONF] Checking other files/dir... "
	@rc=0; for F in $$(ls matomo) ; do \
		echo -n "  * checking in root dir: $$F"; \
		if grep -q "^#\?matomo/$$F" debian/matomo-vanilla.install; then \
			echo " $(GREEN)ok$(NC)."; \
		else \
			echo " $(RED)missing from debian/matomo-vanilla.install$(NC)."; \
			rc=1; \
		fi; \
	done; \
	if [ $$rc -ne 0 ]; then \
		echo " $(RED)[CONF]$(NC) upstream ships something this package ignores without saying so."; \
		echo "        Install it, or comment the entry out in debian/matomo-vanilla.install with"; \
		echo "        a reason, which counts as accounted for."; \
		exit 1; \
	fi

# No fixsettings, no manifest regeneration. /usr/share/matomo is upstream's release,
# with one file added -- bootstrap.php -- and nothing modified, which is what lets
# upstream's own integrity manifest be shipped untouched.
#
# What used to live here: a sed turning "#!/usr/bin/python" into python3 in
# misc/log-analytics/import_logs.py. It was cosmetic the whole time. fixperms below
# makes every file 0644, so that script is not executable in this package and its
# shebang is never consulted; the documented way to run it here is
# "python3 /usr/share/matomo/misc/log-analytics/import_logs.py", which works whatever
# the first line says. Matomo itself never invokes it -- the only mention in the PHP
# source is a comment -- so python3 is a Recommends rather than a Depends.
# fix various file permissions
fixperms:
		@echo -n " [CHMOD] Fixing permissions... "
		@find $(DESTDIR) -type d -not -path "$(DESTDIR)/DEBIAN" -exec chmod 0755 {} \;
		@find $(DESTDIR) -type f -not -path "$(DESTDIR)/DEBIAN/*" -exec chmod 0644 {} \;
		@chmod 0755 $(DESTDIR)/usr/share/matomo/misc/cron/archive.sh
		@chmod 0755 $(DESTDIR)/usr/share/matomo/console
		@chmod 0755 $(DESTDIR)/usr/share/matomo-vanilla/finish-setup
#		@chmod 0755 $(DESTDIR)/usr/share/matomo/vendor/lox/xhprof/scripts/xhprofile.php
		@chmod 0755 $(DESTDIR)/usr/share/matomo/vendor/pear/archive_tar/sync-php4
#		@chmod 0755 $(DESTDIR)/usr/share/matomo/vendor/matomo/matomo-php-tracker/run_tests.sh
#		@chmod 0755 $(DESTDIR)/usr/share/matomo/vendor/szymach/c-pchart/coverage.sh
#		@chmod 0755 $(DESTDIR)/usr/share/matomo/vendor/twig/twig/drupal_test.sh
#		@chmod 0755 $(DESTDIR)/usr/share/matomo/vendor/wikimedia/less.php/bin/lessc
#		@chmod 0755 $(DESTDIR)/usr/share/matomo/vendor/symfony/error-handler/Resources/bin/extract-tentative-return-types.php
#		@chmod 0755 $(DESTDIR)/usr/share/matomo/vendor/symfony/error-handler/Resources/bin/patch-type-declarations
#		@chmod 0755 $(DESTDIR)/usr/share/matomo/vendor/symfony/var-dumper/Resources/bin/var-dump-server


		@echo "done."

# check lintian licenses so we can remove obsolete ones
checklintianlic:
	@echo " [DEB] Checking extra license files presence"
	@for F in $(shell cat debian/matomo-vanilla.lintian-overrides | grep extra-license-file | awk '{print $$3}' | tr -d "[]") ; do \
		echo -n "  * checking: $$F"; \
		if [ ! -f "$(DESTDIR)/$$F" ]; then \
			echo " $(RED)missing$(NC)."; \
			echo "1" >&2; \
		else \
			echo " $(GREEN)ok$(NC)."; \
		fi; \
	done 3>&2 2>&1 1>&3 | grep --silent "1" && exit 1 || echo >/dev/null

# check lintian licenses so we can remove obsolete ones
checklintianextralibs:
	@echo " [DEB] Checking for extra libs presence"
	@for F in $(shell cat debian/matomo-vanilla.lintian-overrides | grep -e embedded-javascript-library -e embedded-php-library | awk '{print $$NF}' | tr -d "[]") ; do \
		echo -n "  * checking: $$F"; \
		if [ ! -f "$(DESTDIR)/$$F" ]; then \
			echo " $(RED)missing$(NC)."; \
			echo "1" >&2; \
		else \
			echo " $(GREEN)ok$(NC)."; \
		fi; \
	done 3>&2 2>&1 1>&3 | grep --silent "1" && exit 1 || echo >/dev/null

# raise an error if the building version is lower that the head of debian/changelog
checkversions:
ifeq "$(RELEASE_VERSION_LOWER)" "1"
	@echo "$(RED)The version you're trying to build is older that the head of your changelog.$(NC)"
	@exit 1
endif

# create a new release either major or minor.
release:	checkenv checkversions
ifeq "$(RELEASE_VERSION_GREATER)" "2"
		@$(MAKE) newrelease
		@$(MAKE) history
else
		@$(MAKE) newversion
endif
		@debchange --changelog debian/changelog --release ''
		@$(MAKE) builddeb
		@$(MAKE) checkdebdetail

# check if the local environment is suitable to generate a package
# we check environment variables and a gpg private key matching
# these variables. this is necessary as we sign our packages.
checkenv:
ifndef DEBEMAIL
		@echo " [ENV] Missing environment variable DEBEMAIL"
		@exit 1
endif
ifndef DEBFULLNAME
		@echo " [ENV] Missing environment variable DEBFULLNAME"
		@exit 1
endif
		@echo " [GPG] Checking environment"
		@gpg --list-secret-keys "$(DEBFULLNAME) <$(DEBEMAIL)>" >/dev/null

# creates the .deb package and other related files
# all files are placed in ../
builddeb:	checkenv checkversions
		@echo -n " [PREP] Checking package status..."
ifeq "$(DEB_STATUS)" "UNRELEASED"
		@echo " $(RED)The package changelog marks the package as 'UNRELEASED'.$(NC)"
		@echo "        $(RED)run this command: debchange --changelog debian/changelog --release ''$(NC)"
		@exit 1
else
		@echo "$(GREEN)ok$(NC)."
endif

		@echo " [DPKG] Building packages..."
		dpkg-buildpackage -i '-Itmp' -I.git -I$(ARCHIVE) -rfakeroot


# check the generated .deb for consistency
# the filename is determines by the 1st line of debian/changelog
checkdeb:
		@echo " [LINTIAN] Checking package(s)..."
		@for P in $(shell cat debian/control | grep ^Package | awk '{print $$2}'); do \
			lintian --no-tag-display-limit --color auto -L ">=warning" -v -i ../$${P}_$(shell dpkg-parsechangelog | grep ^Version | awk '{print $$2}')_*.deb; \
		done

# check the generated .deb for consistency
# the filename is determines by the 1st line of debian/changelog
checkdebdetail:
		@echo " [LINTIAN] Checking package(s)..."
		@for P in $(shell cat debian/control | grep ^Package | awk '{print $$2}'); do \
			lintian --no-tag-display-limit --color auto -L ">=info" -v -i ../$${P}_$(shell dpkg-parsechangelog | grep ^Version | awk '{print $$2}')_*.deb; \
		done

# create a new release based on RELEASE_VERSION variable
newrelease:
		@debchange --changelog debian/changelog --urgency $(URGENCY) --package $(shell cat debian/control | grep ^Source | awk '{print $$2}') --newversion $(RELEASE_VERSION)-1 "Releasing Matomo $(RELEASE_VERSION)"

# creates a new version in debian/changelog
newversion:
		@debchange --changelog debian/changelog -i --urgency $(URGENCY)
		@debchange --changelog debian/changelog --force-distribution $(DIST) --urgency $(URGENCY) -r

# allow user to enter one or more changelog comment manually
changelog:
		@debchange --changelog debian/changelog --force-distribution $(DIST) --urgency $(URGENCY) -r
		@debchange --changelog debian/changelog -a

# fetch the history and add it to the debian/changelog
history:
		@bash debian/scripts/history.sh $(RELEASE_VERSION) $(RELEASE_CHANGELOG)

# clean for any previous / unwanted files from previous build
clean:
		@echo " [RM] matomo/ debian/tmp/ debian/matomo/ debian/matomo-vanilla/"
		@rm -rf matomo debian/tmp debian/matomo debian/matomo-vanilla

distclean:	clean
		@echo " [RM] matomo-*.tar.gz matomo-*.tar.gz.asc matomo-*.zip matomo-*.zip.asc"
		@rm -f matomo-*.tar.gz matomo-*.tar.gz.asc matomo-*.zip matomo-*.zip.asc

prepupload:
		@echo " [MKDIR] tmp/"
		@test -d tmp || mkdir tmp
		@test ! -f  $(ARCHIVE) || echo " [MV] $(ARCHIVE) => tmp/"
		@test ! -f  $(ARCHIVE) || mv $(ARCHIVE) tmp/
		@test ! -f  $(SIG) || echo " [MV] $(SIG) => tmp/"
		@test ! -f  $(SIG) || mv $(SIG) tmp/
		@test ! -f ../matomo_$(DEB_VERSION)_all.deb || echo " [MV] ../matomo_$(DEB_VERSION)_all.deb => tmp/"
		@test ! -f ../matomo_$(DEB_VERSION)_all.deb || mv ../matomo_$(DEB_VERSION)_all.deb $(CURDIR)/tmp/
		@test ! -f ../matomo_$(DEB_VERSION).dsc || echo " [MV] ../matomo_$(DEB_VERSION).dsc => tmp/"
		@test ! -f ../matomo_$(DEB_VERSION).dsc || mv ../matomo_$(DEB_VERSION).dsc $(CURDIR)/tmp/
		@test ! -f ../matomo_$(DEB_VERSION)_$(DEB_ARCH).changes || echo " [MV] ../matomo_$(DEB_VERSION)_$(DEB_ARCH).changes => tmp/"
		@test ! -f ../matomo_$(DEB_VERSION)_$(DEB_ARCH).changes || mv ../matomo_$(DEB_VERSION)_$(DEB_ARCH).changes $(CURDIR)/tmp/
		@test ! -f ../matomo_$(DEB_VERSION).tar.gz || echo " [MV] ../matomo_$(DEB_VERSION).tar.gz => tmp/"
		@test ! -f ../matomo_$(DEB_VERSION).tar.gz || mv ../matomo_$(DEB_VERSION).tar.gz $(CURDIR)/tmp/
		@test ! -f ../matomo_$(DEB_VERSION)_$(DEB_ARCH).buildinfo || echo " [MV] ../matomo_$(DEB_VERSION)_$(DEB_ARCH).buildinfo => tmp/"
		@test ! -f ../matomo_$(DEB_VERSION)_$(DEB_ARCH).buildinfo || mv ../matomo_$(DEB_VERSION)_$(DEB_ARCH).buildinfo $(CURDIR)/tmp/

upload:		prepupload
		@echo " [UPLOAD] => to matomo"
		@dupload --quiet --to matomo $(CURDIR)/tmp/matomo_$(DEB_VERSION)_$(DEB_ARCH).changes

commitrelease:
		@echo " [GIT] Commit release"
		@./debian/scripts/githelp.sh commitrelease
