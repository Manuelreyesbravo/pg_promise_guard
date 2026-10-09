EXTENSION    = pg_promise_guard
DATA         = pg_promise_guard--0.1.0.sql \
               pg_promise_guard--0.2.0.sql \
               pg_promise_guard--0.1.0--0.2.0.sql \
               pg_promise_guard--0.2.0--0.2.1.sql \
               pg_promise_guard--0.2.1--0.2.2.sql \
               pg_promise_guard--0.2.2--0.2.3.sql \
               pg_promise_guard--0.2.3--0.2.4.sql \
               pg_promise_guard--0.2.4--0.2.5.sql \
               pg_promise_guard--0.2.5--0.2.6.sql \
               pg_promise_guard--0.2.6--0.2.7.sql \
               pg_promise_guard--0.2.7--0.2.8.sql
PG_CONFIG   ?= pg_config

# Un solo installcheck y sin dependencias: la extensión lee únicamente los
# catálogos del sistema, así que la prueba corre en cualquier PostgreSQL. Es la
# lección de pg_recall_guard aplicada desde el día uno — un installcheck que
# falla por algo que el usuario no tiene entrena a ignorarlo.
REGRESS      = basic
REGRESS_OPTS = --inputdir=test --outputdir=test

# Can a temporary table of the session that evaluates hide a broken promise? It
# could, through pg_temp, until 0.2.4. Needs a second role, so it is not part of
# installcheck; run it against the throwaway cluster of test/cluster.sh.
# Does an installation that began at 0.1.0 (in public, before the schema was fixed)
# reach the current version and work? ci/upgrade_check.sh cannot see it.
.PHONY: check-desde-010
check-desde-010:
	@PG_CONFIG=$(PG_CONFIG) bash ./test/desde_010.sh

.PHONY: check-pgtemp
check-pgtemp:
	@PG_CONFIG=$(PG_CONFIG) bash ./test/pg_temp.sh

# The Medium and Low findings of the external audit of 0.2.5, each against its control.
.PHONY: check-audit
check-audit:
	@PG_CONFIG=$(PG_CONFIG) bash ./test/audit.sh

# Every suite in SUITES, in a throwaway cluster built from PG_CONFIG's binaries and
# stopped afterwards, whatever the suites answered. PostgreSQL 18 or later: the
# cluster loads this checkout through extension_control_path. CI runs exactly
# this on 18 and 19.
SUITES = check-pgtemp check-desde-010 check-audit
.PHONY: check-suites
check-suites:
	@PG_CONFIG=$(PG_CONFIG) bash ./test/cluster.sh init
	@PG_CONFIG=$(PG_CONFIG) bash ./test/cluster.sh start
	@st=0; for s in $(SUITES); do echo "== $$s"; \
	    $(MAKE) --no-print-directory $$s PG_CONFIG=$(PG_CONFIG) || st=1; done; \
	 PG_CONFIG=$(PG_CONFIG) bash ./test/cluster.sh stop; exit $$st

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
