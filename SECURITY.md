# Security

## Reporting a vulnerability

**Do not open a public issue.** Report it privately, by either:

* GitHub's private vulnerability reporting: the **Security** tab of this
  repository, then **Report a vulnerability**; or
* email to **manuelreyesbravo@gmail.com**, subject starting with
  `[pg_promise_guard security]`.

Please include the PostgreSQL version, the pg_promise_guard version (`SELECT
extversion FROM pg_extension WHERE extname = 'pg_promise_guard'`), and the
smallest sequence of statements that shows it. A case in the style of
`test/sql/*.sql` is ideal, because it becomes a regression test.

You will get an acknowledgement within 72 hours. A confirmed issue is fixed
before it is disclosed, gets a regression case, and is credited to you in the
CHANGELOG unless you prefer otherwise.

## What counts

This extension scans your schema for guarantees it declares but has silently
stopped enforcing, and reports them. The report this project most wants is a way
to make it miss a guarantee that has in fact stopped being enforced, or a way
for a role to read, store or alter what it should not be able to.

## Supported versions

The latest release. Fixes are not backported while the project is pre-1.0.
