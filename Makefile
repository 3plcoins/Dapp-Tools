CFLAGS = -O2 -g -Wall -Werror -fPIC -lsecp256k1
all: libethjet.a
%.a: ethjet.o tinykeccak.o; ar r $@ $^
install: libethjet.a ethjet.h
	mkdir -p $(PREFIX)/{lib,include}
	cp libethjet.a $(PREFIX)/lib
	cp ethjet.h $(PREFIX)/include
