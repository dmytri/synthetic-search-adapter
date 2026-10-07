BINARY  := synthetic-search-adapter
PREFIX  ?= /usr/local
UNITDIR ?= /etc/systemd/system
CONFDIR ?= /etc/synthetic-search-adapter
DESTDIR ?=

.PHONY: all build vet fmt test smoke install uninstall restart clean

all: build

build:
	go build -trimpath -o $(BINARY) .

vet:
	go vet ./...

fmt:
	gofmt -l -w .

test: vet build
	@echo "build + vet OK"

# Smoke-test every route of a RUNNING adapter.
smoke:
	./smoke.sh

# Install as a system service (run with sudo). Idempotent: an existing key
# file is never overwritten.
install: build
	install -Dm755 $(BINARY)         $(DESTDIR)$(PREFIX)/bin/$(BINARY)
	install -Dm644 $(BINARY).service $(DESTDIR)$(UNITDIR)/$(BINARY).service
	install -d -m755                 $(DESTDIR)$(CONFDIR)
	@if [ -f $(DESTDIR)$(CONFDIR)/adapter.env ]; then \
		echo "kept existing $(CONFDIR)/adapter.env"; \
	else \
		install -m600 adapter.env.example $(DESTDIR)$(CONFDIR)/adapter.env; \
		echo "wrote $(CONFDIR)/adapter.env — set SYNTHETIC_API_KEY before starting"; \
	fi
	-systemctl daemon-reload
	@echo
	@echo "next:"
	@echo "  sudoedit $(CONFDIR)/adapter.env          # set SYNTHETIC_API_KEY"
	@echo "  sudo systemctl enable --now $(BINARY)"

uninstall:
	-systemctl disable --now $(BINARY).service
	rm -f $(DESTDIR)$(UNITDIR)/$(BINARY).service $(DESTDIR)$(PREFIX)/bin/$(BINARY)
	-systemctl daemon-reload
	@echo "removed. key file kept at $(CONFDIR)/adapter.env"

restart:
	sudo systemctl restart $(BINARY)

clean:
	rm -f $(BINARY)
