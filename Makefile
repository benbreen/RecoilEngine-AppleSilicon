# Beyond All Reason — macOS packaging entry points.
#
# Thin wrappers over packaging/release-build.sh (the single source of truth for
# how the distributable is built). Everything real lives in that script; these
# targets exist so the build is discoverable and one-command.
#
#   make app            # build + package (headless-safe): ad-hoc Beyond All
#                       # Reason.app + .zip + .dmg. Fast; no GPU/content/long
#                       # tests. Runs on THIS Mac; won't pass Gatekeeper elsewhere.
#   make certify        # certify tier (needs an Apple Silicon GPU + content):
#                       # build + package + replay-determinism cert + GPU driver
#                       # smoke. This is the long one (tens of minutes).
#   make release        # Developer ID signed + notarized + CERTIFIED distributable
#                       #   IDENTITY="Developer ID Application: NAME (TEAMID)" \
#                       #   NOTARY_PROFILE=<keychain-profile> make release
#   make engine-dist    # the Recoil engine port alone (no BAR helper/branding):
#                       #   signed engine bundle -> Recoil-macos-<ver>-port<p>.zip
#   make engine         # just the engine binary (no bundle) — build + sync gates
#   make clean-artifacts# remove staged bundles/zips/dmgs
#
# Tiers mirror upstream Recoil CI: the build workflow only builds + packages;
# gameplay/replay validation is separate and opt-in. Build machines use `make
# app`; certification runs on a real Apple Silicon Mac. See README.md
# "Building the macOS app". Full flag surface: packaging/release-build.sh.

IDENTITY ?=
NOTARY_PROFILE ?=
VERSION  ?=
ONLINE   ?=

VERSION_ARG := $(if $(VERSION),--version "$(VERSION)",)
ONLINE_ARG  := $(if $(ONLINE),--enable-online,)

.DEFAULT_GOAL := help
.PHONY: help app engine-dist certify release engine test clean-artifacts

help:
	@echo "macOS packaging (details: README.md 'Building the macOS app'):"
	@echo "  make app       build + package the BAR helper app -> release-artifacts/BAR Launcher.app (+ .zip/.dmg)"
	@echo "  make engine-dist  package the Recoil engine alone (no BAR helper/branding) -> Recoil-macos-*.zip"
	@echo "                 fast, headless-safe, ad-hoc signed (this Mac only)"
	@echo "  make certify   app + replay-determinism cert + GPU driver smoke (needs an Apple Silicon Mac)"
	@echo "  make release   Developer ID signed + notarized + certified distributable"
	@echo "                 IDENTITY=\"Developer ID Application: NAME (TEAMID)\" NOTARY_PROFILE=<profile> make release"
	@echo "  make engine    just the engine binary (no bundle)"
	@echo "  make clean-artifacts   remove staged bundles/zips/dmgs"
	@echo "  ONLINE=1 make ...      enable online play (disabled by default pending approval)"

app:
	packaging/release-build.sh $(VERSION_ARG) $(ONLINE_ARG)

engine-dist:
	packaging/release-build.sh --profile engine $(VERSION_ARG)

certify:
	packaging/release-build.sh --certify $(VERSION_ARG) $(ONLINE_ARG)

release:
	@test -n "$(IDENTITY)" || { echo "release: set IDENTITY=\"Developer ID Application: ...\" (and NOTARY_PROFILE for notarization)"; exit 2; }
	packaging/release-build.sh \
	  --certify \
	  --identity "$(IDENTITY)" \
	  $(if $(NOTARY_PROFILE),--notary-profile "$(NOTARY_PROFILE)",) \
	  $(VERSION_ARG) $(ONLINE_ARG)

engine:
	scripts/build-engine.sh

test:
	packaging/test/message-check-test.sh
	packaging/test/launcher-test.sh

clean-artifacts:
	rm -rf "release-artifacts/BAR Launcher.app" release-artifacts/*.zip release-artifacts/*.dmg
