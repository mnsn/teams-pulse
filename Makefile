.PHONY: build test app package install uninstall run dump watch diagnose render demo-data demo demo-check screenshots icon signing-identity pppc-profile clean

# With only the Command Line Tools installed, the compiler sometimes misses Swift Testing's macro
# plugin (it lives in a subfolder), so point it there explicitly.
TESTING_PLUGINS := $(abspath $(dir $(shell xcrun --find swift))../lib/swift/host/plugins/testing)

# Made-up Teams notifications in Notification Center's layout (see scripts/make-demo-data.swift).
DEMO_DIR := $(abspath build/demo)
DEMO_ENV := TEAMS_PULSE_DB="$(DEMO_DIR)/db2/db" TEAMS_PULSE_STATE_DIR="$(DEMO_DIR)/state"
# The binary that demo-check runs: the debug build, unless scripts/check-app.sh passes a built app.
PULSE := .build/debug/TeamsPulse
SCREENSHOTS := menubar-light menubar-dark

build:
	swift build

test:
	swift test $(if $(wildcard $(TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS))

app:
	./scripts/build-app.sh

# What a release ships, in build/release: the universal app, checked and zipped, and its notes.
package:
	./scripts/package.sh

install:
	./scripts/build-app.sh --install

uninstall:
	-pgrep -f "/Teams Pulse.app/Contents/MacOS/TeamsPulse" | xargs kill 2>/dev/null
	rm -rf "$(HOME)/Applications/Teams Pulse.app"

# Creates the self-signed certificate every build is signed with, so Full Disk Access survives
# rebuilds. Run it once.
signing-identity:
	./scripts/make-signing-identity.sh

# A configuration profile that grants the app built here Full Disk Access, for an MDM to deploy.
pppc-profile: app
	./scripts/make-pppc-profile.sh

# The next four read your own Teams notifications, through Terminal's Full Disk Access.
run: build
	.build/debug/TeamsPulse

dump: build
	.build/debug/TeamsPulse --dump

watch: build
	.build/debug/TeamsPulse --watch

# Structure only: no names, messages or IDs. Safe to paste into an issue.
diagnose: build
	.build/debug/TeamsPulse --diagnose

render: build demo-data
	$(DEMO_ENV) .build/debug/TeamsPulse --render build/render

demo-data:
	swift scripts/make-demo-data.swift "$(DEMO_DIR)"

# Runs the app with the demo data instead of your own notifications. Ctrl-C quits.
demo: build demo-data
	$(DEMO_ENV) .build/debug/TeamsPulse

# Checks that the demo chats land in the expected lists. CI runs this.
demo-check: $(if $(filter command line,$(origin PULSE)),,build) demo-data
	@counts=$$($(DEMO_ENV) "$(PULSE)" --json | jq -cS .counts); \
	expected='{"chats":2,"groups":2}'; \
	if [ "$$counts" = "$$expected" ]; then echo "demo-check passed: $$counts"; \
	else echo "demo-check failed: expected $$expected, got $$counts" >&2; exit 1; fi

# Renders the README screenshots from the demo data, with summaries if Apple Intelligence is available.
screenshots: build demo-data
	$(DEMO_ENV) TEAMS_PULSE_RENDER_SUMMARIES=1 .build/debug/TeamsPulse --render build/screenshots
	mkdir -p docs/images
	for name in $(SCREENSHOTS); do cp build/screenshots/$$name.png docs/images/; done

icon:
	swift scripts/make-icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

clean:
	rm -rf .build build
