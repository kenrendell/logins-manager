.POSIX:

PREFIX = /usr/local
BINDIR = $(DESTDIR)$(PREFIX)/bin
SRC    = logins.sh gen-random.lua

all:
	@printf "Try 'make install' (with root privilege if needed)\n"

install:
	@mkdir -p '${BINDIR}'
	@for name in ${SRC}; do cp -f "src/$${name}" "${BINDIR}/$${name%.*}" && chmod 755 "${BINDIR}/$${name%.*}"; done

uninstall:
	@for name in ${SRC}; do rm -f "${BINDIR}/$${name%.*}"; done

.PHONY: all install uninstall
