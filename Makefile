SHELL_FILES := $(shell git ls-files '*.sh')

.PHONY: lint fmt

# Check only. CI runs this target.
lint:
	shellcheck $(SHELL_FILES)
	shfmt -d $(SHELL_FILES)

# Rewrite the shell scripts in place.
fmt:
	shfmt -w $(SHELL_FILES)
