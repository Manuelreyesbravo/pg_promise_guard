-- Run by ci/upgrade_check.sh on the UPGRADED database: the promise broken
-- before the upgrade must still be reported, and the verdict must say so.
SET search_path = promise_guard, public;
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM check_promises() WHERE kind = 'invalid_unique_index') THEN
    RAISE EXCEPTION 'the invalid unique index broken before the upgrade is not reported';
  END IF;
  IF promises_kept() THEN
    RAISE EXCEPTION 'promises_kept() is true with a broken promise in place';
  END IF;
END $$;
