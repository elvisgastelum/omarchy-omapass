PLUGIN_ID  := elvisgastelum.omapass
REPO_URL   := https://github.com/elvisgastelum/omarchy-omapass.git
PLUGIN_DIR := $(HOME)/.config/omarchy/plugins/$(PLUGIN_ID)

.DEFAULT_GOAL := help
.PHONY: help install update uninstall enable disable test lint validate check dev

help: ## Show this help
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-10s %s\n", $$1, $$2}'

install: ## Install from GitHub and put it on the bar (omarchy plugin add)
	omarchy plugin add $(REPO_URL) --enable

update: ## Pull the latest version of the installed plugin
	omarchy plugin update $(PLUGIN_ID)

uninstall: ## Remove the plugin
	omarchy plugin remove $(PLUGIN_ID)

enable: ## Put the widget on the bar
	omarchy plugin enable $(PLUGIN_ID)

disable: ## Take the widget off the bar
	omarchy plugin disable $(PLUGIN_ID)

test: ## Run the tests and check the JSON files parse
	@if [ -n "$(wildcard tests/*.test.mjs)" ]; then for f in $(wildcard tests/*.test.mjs); do node "$$f" || exit 1; done; else echo "notice: no node tests"; fi
	@if [ -n "$(wildcard tests/*.test.sh)" ]; then for f in $(wildcard tests/*.test.sh); do bash "$$f" || exit 1; done; else echo "notice: no bash tests"; fi
	@for f in manifest.json $(wildcard i18n/*.json) $(shell find tests/fixtures -name '*.json' 2>/dev/null); do jq empty "$$f" || exit 1; done
	@echo "json ok"

SHELL_FILES := $(shell find bin -type f 2>/dev/null) $(wildcard tests/*.sh) $(shell find tests/mocks -type f 2>/dev/null)
QMLLINT ?= $(or $(shell command -v qmllint 2>/dev/null),$(wildcard /usr/lib/qt6/bin/qmllint))
QML_FILES := $(shell find . -name '*.qml' -not -path './.git/*' -not -path './.plans/*' 2>/dev/null)

# Only syntax categories: Omarchy's qs.* imports are not resolvable by plain qmllint.
lint: ## Run shellcheck (required) and qmllint (if installed)
	@command -v shellcheck >/dev/null 2>&1 || { echo "error: shellcheck is required (pacman -S shellcheck, or mise use -g shellcheck where pacman has none)"; exit 1; }
	shellcheck -x -P SCRIPTDIR $(SHELL_FILES)
	@if [ -z "$(QMLLINT)" ]; then echo "notice: qmllint not found; skipping QML lint"; \
	elif [ -z "$(QML_FILES)" ]; then echo "notice: no QML files; skipping QML lint"; \
	else $(QMLLINT) --ignore-settings --only-explicit-categories --syntax error --syntax.duplicate-ids error $(QML_FILES); fi

validate: ## Validate the manifest against Omarchy's plugin schema
	@if command -v omarchy >/dev/null 2>&1; then omarchy plugin validate .; else echo "notice: omarchy not found; skipping plugin validate"; fi

check: test lint validate ## Run test, lint and validate

dev: check ## Copy this working tree over the installed plugin and restart the shell
	@test -d "$(PLUGIN_DIR)" || { echo "Not installed; run 'make install' first."; exit 1; }
	@if [ "$(FORCE)" != 1 ]; then \
		test -e "$(PLUGIN_DIR)/.git" || { echo "WARNING: $(PLUGIN_DIR) is not a git checkout; 'make dev FORCE=1' overwrites it."; exit 1; }; \
		changes=$$(git -C "$(PLUGIN_DIR)" status --porcelain) && test -z "$$changes" || { echo "WARNING: $(PLUGIN_DIR) is dirty or git status failed; 'make dev FORCE=1' overwrites it."; exit 1; }; \
	fi
	rsync -a --delete --filter=':- .gitignore' --exclude .git --exclude .plans --exclude .claude --exclude CLAUDE.md --exclude .mcp.json ./ "$(PLUGIN_DIR)/"
	omarchy restart shell
