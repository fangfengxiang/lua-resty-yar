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

# Canned recipe: run prove, capture exit code, clean up Nginx runtime artifacts
define run_test_and_clean
	@ret=0; \
	PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$$PATH $(PROVE) -I../test-nginx/lib $(1) || ret=$$?; \
	$(MAKE) --no-print-directory clean; \
	exit $$ret
endef

.PHONY: all test install lint stylua-check opm-build
.PHONY: test-bdd test-functional test-integration test-e2e test-performance test-chaos test-legacy benchmark
.PHONY: coverage clean

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
	$(call run_test_and_clean,$(PROVE_OPTS) t)

test-bdd: all
	$(call run_test_and_clean,$(TEST_SUITE_BDD))

test-functional: all
	$(call run_test_and_clean,$(TEST_SUITE_FUNCTIONAL))

test-integration: all
	$(call run_test_and_clean,$(TEST_SUITE_INTEGRATION))

test-e2e: all
	$(call run_test_and_clean,$(TEST_SUITE_E2E))

test-performance: all
	$(call run_test_and_clean,$(TEST_SUITE_PERFORMANCE))

test-chaos: all
	$(call run_test_and_clean,$(TEST_SUITE_CHAOS))

test-legacy: all
	$(call run_test_and_clean,$(TEST_SUITE_LEGACY))

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
	@ret=0; \
	LUA_PATH="$$(luarocks path --lr-path 2>/dev/null || luarocks path --lua-version 5.1 --lr-path 2>/dev/null);$(CURDIR)/lib/?.lua;$(CURDIR)/../lua-yar/src/?.lua;;" \
	PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$$PATH \
	  $(PROVE) -I../test-nginx/lib $(PROVE_OPTS) t || ret=$$?; \
	luacov lib/resty/yar/; \
	$(MAKE) --no-print-directory clean; \
	echo "Coverage report: luacov.report.out"; \
	exit $$ret

clean:
	@echo "Cleaning runtime and build artifacts..."
	# Nginx runtime artifacts (temp dirs, logs, pid files)
	rm -rf t/servroot
	find examples -type d \( -name 'client_body_temp' -o -name 'fastcgi_temp' \
	  -o -name 'proxy_temp' -o -name 'scgi_temp' -o -name 'uwsgi_temp' \
	  -o -name 'logs' \) -prune -exec rm -rf {} + 2>/dev/null || true
	find examples -name 'nginx.pid' -delete 2>/dev/null || true
	# Build artifacts
	rm -rf site
	rm -f *.opm
	rm -f luacov.stats.out luacov.report.out luacov.report.*.out
