-- Dev-only provisioning of every Phase 2 service database (mirrors each service's
-- scripts/provision-roles.sql with one throwaway password). Runs once, on the first start
-- of an empty data directory, as the compose superuser.

-- identity, orders, sync: the services connect as the superuser and SET ROLE to
-- identity_app / orders_app (created by their migrations) so row-level security applies.
CREATE DATABASE identity;
CREATE DATABASE orders;
CREATE DATABASE sync;

-- tenancy: migrator owns, app is DML only, vendor reads the directory tables, relay reads the outbox.
CREATE ROLE tenancy_migrator LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB PASSWORD 'hostry-dev-only';
CREATE ROLE tenancy_app      LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB PASSWORD 'hostry-dev-only';
CREATE ROLE tenancy_vendor   LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB PASSWORD 'hostry-dev-only';
CREATE ROLE tenancy_relay    LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB PASSWORD 'hostry-dev-only';
CREATE DATABASE tenancy OWNER tenancy_migrator;

-- catalog
CREATE ROLE catalog_migrator LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB PASSWORD 'hostry-dev-only';
CREATE ROLE catalog_app      LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB PASSWORD 'hostry-dev-only';
CREATE ROLE catalog_relay    LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB PASSWORD 'hostry-dev-only';
CREATE DATABASE catalog OWNER catalog_migrator;

-- billing
CREATE ROLE billing_migrator LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB PASSWORD 'hostry-dev-only';
CREATE ROLE billing_app      LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB PASSWORD 'hostry-dev-only';
CREATE ROLE billing_global   LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB PASSWORD 'hostry-dev-only';
CREATE ROLE billing_relay    LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB PASSWORD 'hostry-dev-only';
CREATE DATABASE billing OWNER billing_migrator;

-- platform_meta: the restore epoch that hostry-restore stamps before services start
-- (go-common restore.EpochSchema). Dev stamps the genesis epoch; readers are read-only.
CREATE ROLE platform_reader LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB PASSWORD 'hostry-dev-only';
CREATE DATABASE platform_meta;
\connect platform_meta
CREATE TABLE restore_epoch (
  epoch_id         text        PRIMARY KEY,
  recovered_to     timestamptz,
  requested_target text        NOT NULL DEFAULT '',
  stamped_at       timestamptz NOT NULL,
  pg_timeline      bigint      NOT NULL DEFAULT 0,
  class            text        NOT NULL DEFAULT '',
  reason           text        NOT NULL DEFAULT ''
);
INSERT INTO restore_epoch (epoch_id, stamped_at, class) VALUES ('genesis', now(), 'genesis');
GRANT SELECT ON restore_epoch TO platform_reader;
