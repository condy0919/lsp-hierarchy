EASK ?= eask

compile:
	$(EASK) compile

install:
	$(EASK) install-deps --dev

lint:
	$(EASK) lint package

test: install
	$(EASK) test ert ./test/lsp-hierarchy-test.el

.PHONY: compile lint test

# Local Variables:
# tab-width: 8
# End:
