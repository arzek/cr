PREFIX ?= /usr/local/bin
SCRIPT := $(CURDIR)/cr.sh

.PHONY: install uninstall

install:
	@chmod +x $(SCRIPT)
	@ln -sf $(SCRIPT) $(PREFIX)/cr
	@echo "Installed: $(PREFIX)/cr → $(SCRIPT)"

uninstall:
	@rm -f $(PREFIX)/cr
	@echo "Uninstalled: $(PREFIX)/cr"
