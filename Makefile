# A throwaway data directory keeps the run away from your own snapshots.
test:
	XDG_DATA_HOME=$$(mktemp -d) nvim --headless -u NONE -l tests/run.lua

# Rewrite tests/expected/ from the current rendering. Read the diff before
# committing it.
update:
	XDG_DATA_HOME=$$(mktemp -d) UPDATE=1 nvim --headless -u NONE -l tests/run.lua

.PHONY: test update
