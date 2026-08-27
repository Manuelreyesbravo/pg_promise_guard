EXTENSION    = pg_promise_guard
DATA         = pg_promise_guard--0.1.0.sql
PG_CONFIG   ?= pg_config

# Un solo installcheck y sin dependencias: la extensión lee únicamente los
# catálogos del sistema, así que la prueba corre en cualquier PostgreSQL. Es la
# lección de pg_recall_guard aplicada desde el día uno — un installcheck que
# falla por algo que el usuario no tiene entrena a ignorarlo.
REGRESS      = basic
REGRESS_OPTS = --inputdir=test --outputdir=test

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
