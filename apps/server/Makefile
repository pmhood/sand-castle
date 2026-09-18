# Checks for the Sand Castle server. The CI workflow runs these same targets, the same way
# .github/workflows/agent-image.yml runs images/agent/Makefile's.

NPM ?= npm

.PHONY: check lint test build start
check: lint test build

lint: node_modules
	$(NPM) run lint

test: node_modules
	$(NPM) test

build: node_modules
	$(NPM) run build

# Runs what `build` produced. Not part of `check`; it is here so the documented way to start
# the server is the same shape as the documented way to check it.
start: build
	$(NPM) start

# `npm ci` rather than `npm install`: it installs exactly what package-lock.json names and
# refuses to edit the lockfile, so a clean checkout and a developer's stale node_modules end up
# identical. The touch makes the directory newer than its inputs, so this re-runs only when the
# manifest or the lockfile changes.
node_modules: package.json package-lock.json
	$(NPM) ci
	@touch node_modules
