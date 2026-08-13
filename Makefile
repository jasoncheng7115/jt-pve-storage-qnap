PACKAGE = jt-pve-storage-qnap

# Versioning: the patch number increments per release and runs to .99 before
# the minor number moves — 0.1.0, 0.1.1, ... 0.1.99, then 0.2.0. Keep this in
# step with debian/changelog; release-check refuses when they disagree.
VERSION = 0.1.0

DESTDIR =
PREFIX   = /usr
PERL5DIR = $(DESTDIR)$(PREFIX)/share/perl5
BINDIR   = $(DESTDIR)$(PREFIX)/bin

# Discovered rather than hard-coded: a hand-maintained module list would drift
# out of sync with debian/ and the syntax-check target.
PERL_MODULES = $(shell find lib -type f -name '*.pm' 2>/dev/null | sort)
BIN_SCRIPTS  = $(shell find bin -type f ! -name '.gitkeep' 2>/dev/null | sort)
UNIT_TESTS   = $(wildcard t/*.t)

# Paths scanned by the guards below.
GUARD_PATHS = lib bin debian docs t $(wildcard tools) Makefile README.md README_zh-TW.md \
              CHANGELOG.md CHANGELOG_zh-TW.md

.PHONY: all install uninstall test syntax unit \
        check-multipath-flush check-secrets check-tool-paths critic \
        og-image check-og-image check-site check-bilingual check-publish \
        release-check deb clean

all:
	@echo "Nothing to build. Run 'make install', 'make test' or 'make deb'."

install:
	@set -e; for f in $(PERL_MODULES); do \
		rel=$${f#lib/}; \
		install -d $(PERL5DIR)/$$(dirname $$rel); \
		install -m 0644 $$f $(PERL5DIR)/$$rel; \
		echo "  installed $(PERL5DIR)/$$rel"; \
	done
	@set -e; for f in $(BIN_SCRIPTS); do \
		install -d $(BINDIR); \
		install -m 0755 $$f $(BINDIR)/; \
		echo "  installed $(BINDIR)/$$(basename $$f)"; \
	done

uninstall:
	rm -f  $(PERL5DIR)/PVE/Storage/Custom/QNAPSANPlugin.pm
	rm -rf $(PERL5DIR)/PVE/Storage/Custom/QNAP/
	@for f in $(BIN_SCRIPTS); do rm -f $(BINDIR)/$$(basename $$f); done

test: syntax unit check-multipath-flush check-secrets check-tool-paths
	@echo "All checks passed."

# Modules that subclass PVE::Storage::Plugin cannot be compiled without a
# Proxmox VE installation. On a build host or CI runner that is expected, and
# reporting it as a failure would train everyone to ignore this target — so
# only that specific cause is tolerated, and it is named in the output.
syntax:
	@echo "Running Perl syntax checks..."
	@set -e; skipped=0; for f in $(PERL_MODULES) $(BIN_SCRIPTS); do \
		out=$$(perl -Ilib -c $$f 2>&1) || { \
			if echo "$$out" | grep -qE "Can't locate PVE/|Base class package \"PVE::"; then \
				echo "  skipped $$f (needs Proxmox VE)"; \
				skipped=1; \
				continue; \
			fi; \
			missing=$$(echo "$$out" | sed -n "s/.*Can't locate \([A-Za-z0-9_\/]*\)\.pm.*/\1/p" | head -1); \
			if [ -n "$$missing" ]; then \
				echo "$$out"; \
				echo ""; \
				echo "  $$(echo $$missing | sed 's|/|::|g') is a RUNTIME DEPENDENCY of this"; \
				echo "  plugin, not an optional extra. On Debian:"; \
				echo "    apt install libwww-perl liblwp-protocol-https-perl libxml-libxml-perl"; \
				exit 1; \
			fi; \
			echo "$$out"; \
			exit 1; \
		}; \
		echo "  checking $$f ... OK"; \
	done; \
	if [ "$$skipped" = "1" ]; then \
		echo "  NOTE: some modules were skipped. Run 'make syntax' on a"; \
		echo "        Proxmox VE node to check them."; \
	fi

unit:
	@if [ -n "$(strip $(UNIT_TESTS))" ]; then \
		echo "Running unit tests..."; \
		prove -Ilib $(UNIT_TESTS); \
	else \
		echo "No unit tests yet (t/*.t)."; \
	fi

# `.perlcriticrc` records, with a reason for each, the policies this project
# deliberately violates — `return undef` is required by the three-valued safety
# contract, and the `_not_a_method` guard must read @_ before unpacking it. Read
# that file before switching anything else off.
critic:
	@if command -v perlcritic >/dev/null 2>&1; then \
		perlcritic --profile .perlcriticrc lib/ bin/ \
			&& echo "  OK: perlcritic severity 4 is clean."; \
	else \
		echo "  perlcritic is not installed (apt install libperl-critic-perl)"; \
	fi

# `multipath -F` (capital F) must NEVER be used: it flushes EVERY unused
# multipath map on the node, including maps belonging to other storages and
# other vendors. Only ever flush one named map with lowercase
# `multipath -f <name>`. Prose that forbids the command is allowed through: such
# a line must carry never (any case) / 不得 / 不要 / 不會 / 絕不 / 禁止.
check-multipath-flush:
	@echo "Checking for forbidden system-wide multipath operations..."
	@hits=$$(grep -rnE "multipath[[:space:]]+(-[A-Za-z]*F|--flush)|(multipathd|MULTIPATHD)['\", ]*(remove|del)['\", ]+(maps|multipaths)" \
		$(GUARD_PATHS) --exclude-dir=.git --binary-files=without-match 2>/dev/null \
		| grep -viE 'never|不得|不要|不會|絕不|禁止' || true); \
	if [ -n "$$hits" ]; then \
		echo "ERROR: forbidden node-wide multipath operation found:"; \
		echo "$$hits" | sed 's/^/  /'; \
		echo ""; \
		echo "These remove EVERY unused map on the node, including other"; \
		echo "vendors' storage. Act on one named map instead:"; \
		echo "  multipath -f <map name>"; \
		exit 1; \
	fi; \
	echo "  OK: no node-wide multipath flush found."

# A credential in a URL ends up in logs, in every proxy in between and in any
# shell history that reproduces the call. This plugin never builds a URL that
# carries one — not in code, not in an example, not in a log line.
# A line that forbids it must say so (never / 不得 / 不要).
check-secrets:
	@echo "Checking for credentials in URLs..."
	@hits=$$(grep -rnE "(pwd|passwd|password|CHAPPasswd|mutualCHAPPasswd)=[^&\"' ]*['\"&]?" \
		$(GUARD_PATHS) --exclude-dir=.git --binary-files=without-match 2>/dev/null \
		| grep -E "https?://|query_string|GET|url" \
		| grep -viE 'never|不得|不要|不會|絕不|禁止' || true); \
	if [ -n "$$hits" ]; then \
		echo "ERROR: a credential may be travelling in a URL:"; \
		echo "$$hits" | sed 's/^/  /'; \
		exit 1; \
	fi; \
	echo "  OK: no credential found in a URL."

# Every external command must reach the tool resolver, never $ENV{PATH}.
#
# A PVE daemon has NO PATH at all — measured on pvestatd, pvedaemon, pveproxy
# and pve-ha-lrm in the related projects — so exec falls back to /bin:/usr/bin
# and every tool this plugin runs lives in /usr/sbin. A command spawned any
# other way than through run_cmd() bypasses Command::tool_path and fails only
# when someone drives the operation from the web interface instead of a shell.
check-tool-paths:
	@echo "Checking that no command bypasses the tool resolver..."
	@bad=0; \
	for f in $(PERL_MODULES) $(BIN_SCRIPTS); do \
		case "$$f" in *"/QNAP/Command.pm") continue;; esac; \
		hits=$$(perl -ne 'next if /^\s*#/; print "$$.: $$_" if /\b(?:system|exec|open3|readpipe)\s*\(/ || /qx\{/' "$$f"); \
		if [ -n "$$hits" ]; then \
			echo "  ERROR: $$f spawns a process outside the command runner:"; \
			echo "$$hits" | sed 's/^/      /'; \
			bad=1; \
		fi; \
	done; \
	if [ "$$bad" = "1" ]; then \
		echo "         Route it through Command::run_cmd, which resolves an"; \
		echo "         absolute path. A PVE daemon has no PATH."; \
		exit 1; \
	fi; \
	echo "  OK: every external command goes through the resolver."


# The card a link to the documentation site shows. The VERSION is baked into
# its badge, so it goes stale on every release — check-og-image fails when it is
# older than debian/changelog rather than trusting anyone to remember.
#
# The generator is a maintainer's tool and is not part of the repository, so
# this target only does anything on the machine releases are cut from.
og-image:
	@if [ -f tools/og-image.py ]; then \
		python3 tools/og-image.py $(VERSION); \
	else \
		echo "  skipped: the card generator is a maintainer's tool, not in the repository."; \
	fi

check-og-image:
	@echo "Checking the social card is not older than the changelog..."
	@if [ ! -f docs/og-image.png ]; then \
		echo "  ERROR: docs/og-image.png is missing. Run 'make og-image'."; exit 1; fi
	@if [ debian/changelog -nt docs/og-image.png ]; then \
		echo "  ERROR: docs/og-image.png is older than debian/changelog."; \
		echo "         Its badge carries the version, so it now shows the wrong one."; \
		echo "         Run 'make og-image'."; exit 1; fi
	@echo "  OK: the social card is current."

# THE TWO HALVES OF A BILINGUAL PAIR MUST MAKE THE SAME CLAIM.
#
# docs/index.html says everything twice and only one half is on screen at a
# time, so a correction applied to one is invisible in the other and a reader of
# the other language sees the version that was wrong. That is not hypothetical:
# it is how the related project shipped a requirements table that said one thing
# in English and another in Chinese. The check compares the FIGURES either half
# carries, which catches that class of error without understanding either
# language.
#
# The checker is a maintainer's tool and is not part of the repository; without
# it this target says so and passes, so a clone can still run release-check.
check-bilingual:
	@echo "Checking that both halves of every bilingual pair agree..."
	@if [ -f tools/check-bilingual.pl ]; then \
		perl tools/check-bilingual.pl docs/index.html; \
	else \
		echo "  skipped: the checker is a maintainer's tool, not in the repository."; \
	fi

# THE PUBLISHED SITE MUST NOT CARRY A REAL ADDRESS OR HOSTNAME.
#
# A documentation page is the easiest place for a development environment to
# leak: an address from the machine the examples were run on reads exactly like
# an example, and nobody notices until it is indexed. Every address in the site
# and in the READMEs must come from RFC 5737's documentation ranges.
#
# `192.0.2.` is TEST-NET-1 and is the one this project uses. A private address —
# 10., 172.16-31., 192.168. — is what a real network looks like, so it is
# refused rather than merely discouraged.
check-site:
	@echo "Checking the published site for anything private..."
	@hits=$$(grep -rnE '\b(10\.[0-9]+\.[0-9]+\.[0-9]+|192\.168\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+)\b' \
		docs/index.html docs/*.md README.md README_zh-TW.md 2>/dev/null || true); \
	if [ -n "$$hits" ]; then \
		echo "ERROR: a private address appears in something that gets published:"; \
		echo "$$hits" | sed 's/^/  /'; \
		echo ""; \
		echo "Use RFC 5737's documentation range instead: 192.0.2.x"; \
		exit 1; \
	fi; \
	echo "  OK: no private address in the published documents."

# NOTHING THAT SHOULD NOT BE PUBLIC, in any file or in any commit message.
#
# The checker is a maintainer's tool and is not part of the repository; without
# it this target says so and passes.
check-publish:
	@echo "Checking that nothing unpublishable is about to be published..."
	@if [ -f tools/check-publish.pl ]; then \
		perl tools/check-publish.pl; \
	else \
		echo "  skipped: the checker is a maintainer's tool, not in the repository."; \
	fi

release-check: test critic check-og-image check-site check-bilingual check-publish
	@echo "Checking version consistency..."
	@deb_version=$$(dpkg-parsechangelog --show-field Version 2>/dev/null \
		| sed 's/-[0-9]*$$//'); \
	fail=0; \
	echo "  Makefile:         $(VERSION)"; \
	echo "  debian/changelog: $$deb_version"; \
	if [ -n "$$deb_version" ] && [ "$(VERSION)" != "$$deb_version" ]; then \
		echo "  ERROR: Makefile and debian/changelog disagree"; fail=1; \
	fi; \
	for f in $$(grep -l '^my \$$VERSION = ' bin/* | sort); do \
		v=$$(sed -n "s/^my \$$VERSION = '\(.*\)';/\1/p" $$f); \
		echo "  $$f:  $$v"; \
		if [ "$(VERSION)" != "$$v" ]; then \
			echo "  ERROR: Makefile and $$f disagree"; fail=1; \
		fi; \
		if ! grep -q "'version'" $$f; then \
			echo "  ERROR: $$f carries a \$$VERSION but has no --version option,"; \
			echo "         so the value above is one nobody can read."; \
			fail=1; \
		fi; \
	done; \
	for f in CHANGELOG.md CHANGELOG_zh-TW.md; do \
		if ! grep -q "\[$(VERSION)\]" $$f; then \
			echo "  ERROR: $$f has no entry for $(VERSION)"; fail=1; \
		else \
			echo "  $$f:  has an entry for $(VERSION)"; \
		fi; \
	done; \
	if [ "$$fail" = "1" ]; then \
		echo ""; \
		echo "A release whose files disagree about its own version is worse"; \
		echo "than no release. Fix the above, then run this again."; \
		exit 1; \
	fi; \
	badge=$$(sed -n 's/.*hero__badge">[[:space:]]*v\([^ <]*\).*/\1/p' docs/index.html | head -1); \
	echo "  docs site badge:  $$badge"; \
	if [ "$$badge" != "$(VERSION)" ]; then \
		echo "  ERROR: the Pages site badge says '$$badge'"; fail=1; \
	fi; \
	if [ "$$fail" = "1" ]; then exit 1; fi; \
	echo "  OK: every file agrees on $(VERSION), including the docs site"

deb:
	dpkg-buildpackage -us -uc -b

clean:
	rm -rf debian/$(PACKAGE)/
	rm -rf debian/.debhelper/
	rm -f  debian/debhelper-build-stamp
	rm -f  debian/files
	rm -f  debian/*.substvars
	rm -f  debian/*.log
