PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
LIBEXECDIR ?= $(PREFIX)/libexec
DATADIR ?= $(PREFIX)/share
APPDIR ?= $(DATADIR)/inir-files
DESTDIR ?=
EXEC_PATH ?= $(BINDIR)/inir-files

CARGO ?= cargo
ARCH ?= $(shell uname -m)
VERSION ?= $(shell sed -n 's/^version = "\(.*\)"/\1/p' core/Cargo.toml | head -n 1)
DIST ?= dist
TARBALL_NAME = inir-files-$(VERSION)-$(ARCH)

QML_DIRS = services kit views i18n

.PHONY: all build test install uninstall dist clean

all: build

build:
	$(CARGO) build --release --locked --manifest-path core/Cargo.toml

test:
	$(CARGO) test --release --locked --manifest-path core/Cargo.toml

install: build
	install -Dm755 bin/inir-files "$(DESTDIR)$(BINDIR)/inir-files"
	install -Dm755 core/target/release/inir-files-core "$(DESTDIR)$(LIBEXECDIR)/inir-files-core"
	install -Dm644 shell.qml "$(DESTDIR)$(APPDIR)/shell.qml"
	@for dir in $(QML_DIRS); do \
		install -dm755 "$(DESTDIR)$(APPDIR)/$$dir"; \
		for f in "$$dir"/*; do \
			[ -f "$$f" ] && install -Dm644 "$$f" "$(DESTDIR)$(APPDIR)/$$f"; \
		done; \
	done
	install -Dm644 data/inir-files.desktop "$(DESTDIR)$(DATADIR)/applications/inir-files.desktop"
	install -dm755 "$(DESTDIR)$(DATADIR)/dbus-1/services"
	sed 's|^Exec=.*|Exec=$(EXEC_PATH) --service|' data/inir-files.FileManager1.service \
		> "$(DESTDIR)$(DATADIR)/dbus-1/services/inir-files.FileManager1.service"
	chmod 644 "$(DESTDIR)$(DATADIR)/dbus-1/services/inir-files.FileManager1.service"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/inir-files"
	rm -f "$(DESTDIR)$(LIBEXECDIR)/inir-files-core"
	rm -f "$(DESTDIR)$(DATADIR)/applications/inir-files.desktop"
	rm -f "$(DESTDIR)$(DATADIR)/dbus-1/services/inir-files.FileManager1.service"
	rm -rf "$(DESTDIR)$(APPDIR)"

dist: build
	rm -rf "$(DIST)/$(TARBALL_NAME)"
	$(MAKE) install \
		DESTDIR="$(abspath $(DIST)/$(TARBALL_NAME))" \
		PREFIX="" \
		BINDIR="/bin" \
		LIBEXECDIR="/libexec" \
		DATADIR="/share" \
		EXEC_PATH="/usr/local/bin/inir-files"
	install -Dm644 LICENSE "$(DIST)/$(TARBALL_NAME)/LICENSE"
	install -Dm644 README.md "$(DIST)/$(TARBALL_NAME)/README.md"
	tar -C "$(DIST)" -cf - "$(TARBALL_NAME)" | gzip -9 -n > "$(DIST)/$(TARBALL_NAME).tar.gz"
	(cd "$(DIST)" && sha256sum "$(TARBALL_NAME).tar.gz" > "$(TARBALL_NAME).tar.gz.sha256")

clean:
	$(CARGO) clean --manifest-path core/Cargo.toml
	rm -rf "$(DIST)"
