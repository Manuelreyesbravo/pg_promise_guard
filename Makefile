EXTENSION    = pg_promise_guard
DATA         = pg_promise_guard--0.1.0.sql \
               pg_promise_guard--0.2.0.sql \
               pg_promise_guard--0.1.0--0.2.0.sql \
               pg_promise_guard--0.2.0--0.2.1.sql \
               pg_promise_guard--0.2.1--0.2.2.sql \
               pg_promise_guard--0.2.2--0.2.3.sql \
               pg_promise_guard--0.2.3--0.2.4.sql
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
.PHONY: check-pgtemp
check-pgtemp:
	@PG_CONFIG=$(PG_CONFIG) bash ./test/pg_temp.sh

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
