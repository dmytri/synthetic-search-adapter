BINARY  := synthetic-search-adapter
PREFIX  ?= /usr/local
UNITDIR ?= /etc/systemd/system
CONFDIR ?= /etc/synthetic-search-adapter
DESTDIR ?=

.PHONY: all build vet fmt test smoke install uninstall clean

all: build

build:
	go build -trimpath -o $(BINARY) .

vet:
	go vet ./...

fmt:
	gofmt -l -w .

test: vet build
	@echo "build + vet OK"

# Smoke test against a RUNNING adapter (start it yourself first).
smoke:
	./smoke.sh

# System install (root). Does not overwrite an existing key file.
install: build
	install -Dm755 $(BINARY)            $(DESTDIR)$(PREFIX)/bin/$(BINARY)
	install -Dm644 $(BINARY).service    $(DESTDIR)$(UNITDIR)/$(BINARY).service
	install -d -m755                    $(DESTDIR)$(CONFDIR)
	@if [ -f $(DESTDIR)$(CONFDIR)/adapter.env ]; then \
		echo "kept existing $(CONFDIR)/adapter.env"; \
	else \
		install -m600 adapter.env.example $(DESTDIR)$(CONFDIR)/adapter.env; \
		echo "wrote $(CONFDIR)/adapter.env — EDIT IT and set SYNTHETIC_API_KEY"; \
	fi
	-systemctl daemon-reload
	@echo "installed. next: sudoedit $(CONFDIR)/adapter.env && sudo systemctl enable --now $(BINARY)"

uninstall:
	-systemctl disable --now $(BINARY).service
	rm -f $(DESTDIR)$(UNITDIR)/$(BINARY).service
	rm -f $(DESTDIR)$(PREFIX)/bin/$(BINARY)
	-systemctl daemon-reload
	@echo "removed. config kept at $(CONFDIR)/adapter.env (delete manually if unwanted)"

clean:
	rm -f $(BINARY)
