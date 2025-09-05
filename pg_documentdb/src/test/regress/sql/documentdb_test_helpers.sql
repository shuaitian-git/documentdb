CREATE SCHEMA documentdb_test_helpers;

SELECT datname, datcollate, datctype, pg_encoding_to_char(encoding), datlocprovider FROM pg_database;

-- Check if recreating the extension works
DROP EXTENSION IF EXISTS documentdb;

-- Install the latest available documentdb_api version
CREATE EXTENSION documentdb CASCADE;

-- binary version should return the installed version after recreating the extension
SELECT documentdb_api.binary_version() = (SELECT REPLACE(extversion, '-', '.') FROM pg_extension where extname = 'documentdb_core');

-- Wait for the background worker to be launched in the `regression` database
-- When the extension is loaded, this isn't created yet. 
CREATE OR REPLACE PROCEDURE documentdb_test_helpers.wait_for_background_worker()
AS $$
DECLARE 
  v_bg_worker_app_name text := NULL;
BEGIN
  LOOP
    SELECT application_name INTO v_bg_worker_app_name FROM pg_stat_activity WHERE application_name = 'documentdb_bg_worker_leader';
    IF v_bg_worker_app_name IS NOT NULL THEN
      RETURN;
    END IF;

    COMMIT; -- This is needed so that we grab a fresh snapshot of pg_stat_activity
    PERFORM pg_sleep_for('100 ms');
  END LOOP;
END
$$
LANGUAGE plpgsql;

CALL documentdb_test_helpers.wait_for_background_worker();

-- validate background worker is launched
SELECT application_name FROM pg_stat_activity WHERE application_name = 'documentdb_bg_worker_leader';

-- query documentdb_api_catalog.collection_indexes for given collection
CREATE OR REPLACE FUNCTION documentdb_test_helpers.get_collection_indexes(
    p_database_name text,
    p_collection_name text,
    OUT collection_id bigint,
    OUT index_id integer,
    OUT index_spec_as_bson documentdb_core.bson,
    OUT index_is_valid bool)
RETURNS SETOF RECORD
AS $$
BEGIN
  RETURN QUERY
  SELECT ci.collection_id, ci.index_id,
         documentdb_api_internal.index_spec_as_bson(ci.index_spec),
         ci.index_is_valid
  FROM documentdb_api_catalog.collection_indexes AS ci
  WHERE ci.collection_id = (SELECT hc.collection_id FROM documentdb_api_catalog.collections AS hc
                            WHERE collection_name = p_collection_name AND
                                  database_name = p_database_name)
  ORDER BY ci.index_id;
END;
$$ LANGUAGE plpgsql;

-- query pg_index for the documents table backing given collection
CREATE OR REPLACE FUNCTION documentdb_test_helpers.get_data_table_indexes (
    p_database_name text,
    p_collection_name text)
RETURNS TABLE (LIKE pg_index)
AS $$
DECLARE
  v_collection_id bigint;
  v_data_table_name text;
BEGIN
  SELECT collection_id INTO v_collection_id
  FROM documentdb_api_catalog.collections
  WHERE collection_name = p_collection_name AND
        database_name = p_database_name;

  v_data_table_name := format('documentdb_data.documents_%s', v_collection_id);

  RETURN QUERY
  SELECT * FROM pg_index WHERE indrelid = v_data_table_name::regclass;
END;
$$ LANGUAGE plpgsql;

-- Returns the command (without "CONCURRENTLY" option) used to create given
-- index on a collection.
CREATE FUNCTION documentdb_test_helpers.documentdb_index_get_pg_def(
    p_database_name text,
    p_collection_name text,
    p_index_name text)
RETURNS SETOF TEXT
AS
$$
BEGIN
    RETURN QUERY
    SELECT pi.indexdef
    FROM documentdb_api_catalog.collection_indexes hi,
         documentdb_api_catalog.collections hc,
         pg_indexes pi
    WHERE hc.database_name = p_database_name AND
          hc.collection_name = p_collection_name AND
          (hi.index_spec).index_name = p_index_name AND
          hi.collection_id = hc.collection_id AND
          pi.indexname = concat('documents_rum_index_', index_id::text) AND
          pi.schemaname = 'documentdb_data';
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION documentdb_test_helpers.drop_primary_key(p_database_name text, p_collection_name text)
RETURNS void
AS $$
DECLARE
  v_collection_id bigint;
BEGIN
    SELECT collection_id INTO v_collection_id
    FROM documentdb_api_catalog.collections
    WHERE collection_name = p_collection_name AND
          database_name = p_database_name;

    DELETE FROM documentdb_api_catalog.collection_indexes
    WHERE (index_spec).index_key operator(documentdb_core.=) '{"_id": 1}'::documentdb_core.bson AND
          collection_id = v_collection_id;
	EXECUTE format('ALTER TABLE documentdb_data.documents_%s DROP CONSTRAINT collection_pk_%s', v_collection_id, v_collection_id);
END;
$$ LANGUAGE plpgsql;

-- This is a helper for create_indexes_background. It performs the submission of index requests in background and wait for their completion.
CREATE OR REPLACE PROCEDURE documentdb_test_helpers.create_indexes_background(IN p_database_name text,
                                                        IN p_index_spec documentdb_core.bson,
                                                        INOUT retVal documentdb_core.bson DEFAULT null,
                                                        INOUT ok boolean DEFAULT false)
AS $procedure$
DECLARE
  create_index_response record;
  check_build_index_status record;
  completed boolean := false;
  indexBuildWaitSleepTimeInSec int := 2;
  indexRequest text;
BEGIN
  SET search_path TO documentdb_core,documentdb_api;
  SELECT * INTO create_index_response FROM documentdb_api.create_indexes_background(p_database_name, p_index_spec);
  COMMIT;

  IF create_index_response.ok THEN
    SELECT create_index_response.requests->>'indexRequest' INTO indexRequest;
    IF indexRequest IS NOT NULL THEN
      LOOP
          SELECT * INTO check_build_index_status FROM documentdb_api_internal.check_build_index_status(create_index_response.requests);
          IF check_build_index_status.ok THEN
            completed := check_build_index_status.complete;
            IF completed THEN
              ok := create_index_response.ok;
              retVal := create_index_response.retval;
              RETURN;
            END IF;
          ELSE
            ok := check_build_index_status.ok;
            retVal := check_build_index_status.retval;
            RETURN;
          END IF;

          COMMIT; -- COMMIT so that CREATE INDEX CONCURRENTLY does not wait for documentdb_distributed_test_helpers.create_indexes_background
          PERFORM pg_sleep_for('100 ms');
      END LOOP;
    ELSE
      ok := create_index_response.ok;
      retVal := create_index_response.retval;
      RETURN;
    END IF;
  ELSE
    ok := create_index_response.ok;
    retVal := create_index_response.retval;
  END IF;
END;
$procedure$
LANGUAGE plpgsql;

-- query pg_index for the documents table backing given collection
CREATE OR REPLACE FUNCTION documentdb_test_helpers.get_data_table_indexes (
    p_database_name text,
    p_collection_name text)
RETURNS TABLE (LIKE pg_index)
AS $$
DECLARE
  v_collection_id bigint;
  v_data_table_name text;
BEGIN
  SELECT collection_id INTO v_collection_id
  FROM documentdb_api_catalog.collections
  WHERE collection_name = p_collection_name AND
        database_name = p_database_name;

  v_data_table_name := format('documentdb_data.documents_%s', v_collection_id);

  RETURN QUERY
  SELECT * FROM pg_index WHERE indrelid = v_data_table_name::regclass;
END;
$$ LANGUAGE plpgsql;

-- count collection indexes grouping by "pg_index.indisprimary" attr
CREATE OR REPLACE FUNCTION documentdb_test_helpers.count_collection_indexes(
    p_database_name text,
    p_collection_name text)
RETURNS TABLE (
  index_type_is_primary boolean,
  index_type_count bigint
)
AS $$
BEGIN
  RETURN QUERY
  SELECT indisprimary, COUNT(*) FROM pg_index
  WHERE indrelid = (SELECT ('documentdb_data.documents_' || collection_id::text)::regclass
                    FROM documentdb_api_catalog.collections
                    WHERE database_name = p_database_name AND
                          collection_name = p_collection_name)
  GROUP BY indisprimary;
END;
$$ LANGUAGE plpgsql;