OPENRESTY_PREFIX ?= /usr/local/openresty

PREFIX ?=          /usr/local
LUA_LIB_DIR ?=     $(PREFIX)/lib/lua/$(LUA_VERSION)
INSTALL ?= install

# Test suites — each category in a separate .t file
TEST_SUITE_BDD         = t/bdd.t
TEST_SUITE_FUNCTIONAL = t/functional.t
TEST_SUITE_INTEGRATION = t/integration.t
TEST_SUITE_E2E        = t/e2e.t
TEST_SUITE_PERFORMANCE = t/performance.t
TEST_SUITE_CHAOS      = t/chaos.t
TEST_SUITE_LEGACY     = t/client.t t/http.t t/tcp.t t/observability.t

PROVE ?= prove
PROVE_OPTS ?= -r

.PHONY: all test install lint stylua-check opm-build
.PHONY: test-bdd test-functional test-integration test-e2e test-performance test-chaos test-legacy benchmark
.PHONY: coverage

all: ;

install: all
	$(INSTALL) -d $(DESTDIR)$(LUA_LIB_DIR)/resty/yar/server
	$(INSTALL) lib/resty/yar/*.lua $(DESTDIR)$(LUA_LIB_DIR)/resty/yar
	$(INSTALL) lib/resty/yar/server/*.lua $(DESTDIR)$(LUA_LIB_DIR)/resty/yar/server

lint:
	luacheck lib/

stylua-check:
	stylua --check lib/ t/

test: all
	PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$$PATH $(PROVE) -I../test-nginx/lib $(PROVE_OPTS) t

test-bdd: all
	PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$$PATH $(PROVE) -I../test-nginx/lib $(TEST_SUITE_BDD)

test-functional: all
	PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$$PATH $(PROVE) -I../test-nginx/lib $(TEST_SUITE_FUNCTIONAL)

test-integration: all
	PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$$PATH $(PROVE) -I../test-nginx/lib $(TEST_SUITE_INTEGRATION)

test-e2e: all
	PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$$PATH $(PROVE) -I../test-nginx/lib $(TEST_SUITE_E2E)

test-performance: all
	PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$$PATH $(PROVE) -I../test-nginx/lib $(TEST_SUITE_PERFORMANCE)

test-chaos: all
	PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$$PATH $(PROVE) -I../test-nginx/lib $(TEST_SUITE_CHAOS)

test-legacy: all
	PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$$PATH $(PROVE) -I../test-nginx/lib $(TEST_SUITE_LEGACY)

benchmark: all
	PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$$PATH $(OPENRESTY_PREFIX)/bin/resty \
	  --lua-path '$(CURDIR)/lib/?.lua;$(CURDIR)/../lua-yar/src/?.lua;;' \
	  t/benchmark/serialization.lua

opm-build:
	opm build

coverage:
	@echo "Running tests with luacov coverage..."
	@test -f "$$(luarocks path --lr-path 2>/dev/null)/luacov.lua" || \
	  test -f "$$(luarocks path --lua-version 5.1 --lr-path 2>/dev/null)/luacov.lua" || \
	  { echo "Install luacov: luarocks install luacov"; exit 1; }
	LUA_PATH="$$(luarocks path --lr-path 2>/dev/null || luarocks path --lua-version 5.1 --lr-path 2>/dev/null);$(CURDIR)/lib/?.lua;$(CURDIR)/../lua-yar/src/?.lua;;" \
	  PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$$PATH \
	  $(PROVE) -I../test-nginx/lib $(PROVE_OPTS) t
	luacov lib/resty/yar/
	@echo "Coverage report: luacov.report.out"
