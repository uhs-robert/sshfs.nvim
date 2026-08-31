.PHONY: test lint format

# Run the unit test suite. Pass PATTERN=<substring> to run a subset:
#   make test PATTERN=mount_point
test:
	nvim -l tests/run.lua $(PATTERN)

lint:
	stylua --check lua/ tests/

format:
	stylua lua/ tests/
