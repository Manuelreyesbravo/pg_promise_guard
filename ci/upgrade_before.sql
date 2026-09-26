-- Run by ci/upgrade_check.sh on the OLD version, before ALTER EXTENSION
-- UPDATE: a promise broken while the old version was installed.  A failed
-- CREATE UNIQUE INDEX CONCURRENTLY leaves the index behind, invalid.
CREATE TABLE ci_broken (v int);
INSERT INTO ci_broken VALUES (1), (1);
\set ON_ERROR_STOP off
CREATE UNIQUE INDEX CONCURRENTLY ci_broken_v ON ci_broken (v);
