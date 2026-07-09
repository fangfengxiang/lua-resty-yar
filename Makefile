OPENRESTY_PREFIX ?= /usr/local/openresty

PREFIX ?=          /usr/local
LUA_LIB_DIR ?=     $(PREFIX)/lib/lua/$(LUA_VERSION)
INSTALL ?= install

.PHONY: all test install lint

all: ;

install: all
	$(INSTALL) -d $(DESTDIR)$(LUA_LIB_DIR)/resty/yar/server
	$(INSTALL) lib/resty/yar/*.lua $(DESTDIR)$(LUA_LIB_DIR)/resty/yar
	$(INSTALL) lib/resty/yar/server/*.lua $(DESTDIR)$(LUA_LIB_DIR)/resty/yar/server

lint:
	luacheck lib/

test: all
	PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$$PATH prove -I../test-nginx/lib -r t
