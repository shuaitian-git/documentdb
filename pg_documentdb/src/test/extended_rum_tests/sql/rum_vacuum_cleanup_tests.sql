SET search_path TO documentdb_api_catalog, documentdb_core, public;
SET documentdb.next_collection_id TO 400;
SET documentdb.next_collection_index_id TO 400;


CREATE OR REPLACE FUNCTION documentdb_api_internal.rum_prune_empty_entries_on_index(index_relid regclass)
RETURNS void
LANGUAGE c
AS '$libdir/pg_documentdb_extended_rum_core', 'documentdb_rum_prune_empty_entries_on_index';

ALTER SYSTEM set autovacuum to off;
SELECT pg_reload_conf();

SELECT name, setting, reset_val, boot_val FROM pg_settings WHERE name in ('documentdb_rum.track_incomplete_split', 'documentdb_rum.fix_incomplete_split');

SELECT documentdb_api.drop_collection('pvacuum_db', 'pclean');
SELECT COUNT(documentdb_api.insert_one('pvacuum_db', 'pclean',  FORMAT('{ "_id": %s, "a": %s }', i, i)::bson)) FROM generate_series(1, 1000) AS i;

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'pvacuum_db',
    '{ "createIndexes": "pclean", "indexes": [ { "key": { "a": 1 }, "name": "a_1", "enableCompositeTerm": true } ] }', TRUE);


-- use the index - 
set documentdb_rum.vacuum_cleanup_entries to off;
set documentdb.enableExtendedExplainPlans to on;
set documentdb.forceDisableSeqScan to on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF) SELECT document FROM bson_aggregation_count('pvacuum_db', '{ "count": "pclean", "query": { "a": { "$exists": true } } }') $cmd$);

-- drop all the rows now
reset documentdb.forceDisableSeqScan;
DELETE FROM documentdb_data.documents_401 WHERE object_id >= '{ "": 10 }';
set documentdb.forceDisableSeqScan to on;

-- query again (should return 10 rows with 1000 loops)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF) SELECT document FROM bson_aggregation_count('pvacuum_db', '{ "count": "pclean", "query": { "a": { "$exists": true } } }') $cmd$);

-- vacuum the collection
VACUUM (FREEZE ON, INDEX_CLEANUP ON, DISABLE_PAGE_SKIPPING ON) documentdb_data.documents_401;

-- query again (should return 10 rows but still with 1000 loops since we don't clean entries).
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF) SELECT document FROM bson_aggregation_count('pvacuum_db', '{ "count": "pclean", "query": { "a": { "$exists": true } } }') $cmd$);

reset documentdb.forceDisableSeqScan;
SELECT COUNT(documentdb_api.insert_one('pvacuum_db', 'pclean',  FORMAT('{ "_id": %s, "a": %s }', i, i)::bson)) FROM generate_series(1001, 2000) AS i;
DELETE FROM documentdb_data.documents_401 WHERE object_id >= '{ "": 1010 }';
set documentdb.forceDisableSeqScan to on;

-- now set the guc to clean the entries
set documentdb_rum.vacuum_cleanup_entries to on;
VACUUM (FREEZE ON, INDEX_CLEANUP ON, DISABLE_PAGE_SKIPPING ON) documentdb_data.documents_401;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF) SELECT document FROM bson_aggregation_count('pvacuum_db', '{ "count": "pclean", "query": { "a": { "$exists": true } } }') $cmd$);

-- repeat one more time
reset documentdb.forceDisableSeqScan;
SELECT COUNT(documentdb_api.insert_one('pvacuum_db', 'pclean',  FORMAT('{ "_id": %s, "a": %s }', i, i)::bson)) FROM generate_series(2001, 3000) AS i;
DELETE FROM documentdb_data.documents_401 WHERE object_id >= '{ "": 2010 }';
set documentdb.forceDisableSeqScan to on;

-- now set the guc to clean the entries
set documentdb_rum.vacuum_cleanup_entries to on;
VACUUM (FREEZE ON, INDEX_CLEANUP ON, DISABLE_PAGE_SKIPPING ON) documentdb_data.documents_401;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF) SELECT document FROM bson_aggregation_count('pvacuum_db', '{ "count": "pclean", "query": { "a": { "$exists": true } } }') $cmd$);

reset documentdb.forceDisableSeqScan;

-- insert some entries to create posting trees.
SELECT COUNT(documentdb_api.insert_one('pvacuum_db', 'pclean',  FORMAT('{ "_id": -%s, "a": 500 }', i)::bson)) FROM generate_series(1, 3000) AS i;

-- now delete everything includig posting tree entries.
DELETE FROM documentdb_data.documents_401 WHERE object_id < '{ "": 2000 }';

set documentdb.forceDisableSeqScan to on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF) SELECT document FROM bson_aggregation_count('pvacuum_db', '{ "count": "pclean", "query": { "a": { "$exists": true } } }') $cmd$);

-- now set the guc to clean up entry pages
set documentdb_rum.prune_rum_empty_pages to on;
set client_min_messages to DEBUG1;
VACUUM (FREEZE ON, INDEX_CLEANUP ON, DISABLE_PAGE_SKIPPING ON) documentdb_data.documents_401;
reset client_min_messages;

-- delete one more row to ensure vacuum has a chance to clean up
reset documentdb.forceDisableSeqScan;
DELETE FROM documentdb_data.documents_401 WHERE object_id <= '{ "": 2000 }';
set client_min_messages to DEBUG1;
VACUUM (FREEZE ON, INDEX_CLEANUP ON, DISABLE_PAGE_SKIPPING ON) documentdb_data.documents_401;
reset client_min_messages;

set documentdb.forceDisableSeqScan to on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF) SELECT document FROM bson_aggregation_count('pvacuum_db', '{ "count": "pclean", "query": { "a": { "$exists": true } } }') $cmd$);

-- introduce dead pages and use the repair functions to clean up the index.
reset documentdb.forceDisableSeqScan;
CALL documentdb_api.drop_indexes('pvacuum_db', '{ "dropIndexes": "pclean", "index": "a_1" }');
TRUNCATE documentdb_data.documents_401;

-- now repeat without the vacuum
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'pvacuum_db',
    '{ "createIndexes": "pclean", "indexes": [ { "key": { "a": 1 }, "name": "a_1", "enableCompositeTerm": true } ] }', TRUE);

\d documentdb_data.documents_401

-- insert 3000 docs
SELECT COUNT(documentdb_api.insert_one('pvacuum_db', 'pclean',  FORMAT('{ "_id": %s, "a": %s }', i, i)::bson)) FROM generate_series(1, 3000) AS i;

set documentdb.forceDisableSeqScan to on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF) SELECT document FROM bson_aggregation_count('pvacuum_db', '{ "count": "pclean", "query": { "a": { "$exists": true } } }') $cmd$);
reset documentdb.forceDisableSeqScan;

-- delete 3000 docs
set documentdb_rum.vacuum_cleanup_entries to off;
set documentdb_rum.prune_rum_empty_pages to off;
DELETE FROM documentdb_data.documents_401;
VACUUM (FREEZE ON, INDEX_CLEANUP ON, DISABLE_PAGE_SKIPPING ON) documentdb_data.documents_401;

-- we should have a lot of empty pages
set documentdb.forceDisableSeqScan to on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF) SELECT document FROM bson_aggregation_count('pvacuum_db', '{ "count": "pclean", "query": { "a": { "$exists": true } } }') $cmd$);
reset documentdb.forceDisableSeqScan;

-- call the repair function.
set documentdb_rum.vacuum_cleanup_entries to on;
SELECT documentdb_api_internal.rum_prune_empty_entries_on_index('documentdb_data.documents_rum_index_403'::regclass);

-- should have fewer entries due to pruning.
set documentdb.forceDisableSeqScan to on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF) SELECT document FROM bson_aggregation_count('pvacuum_db', '{ "count": "pclean", "query": { "a": { "$exists": true } } }') $cmd$);
reset documentdb.forceDisableSeqScan;

set documentdb_rum.prune_rum_empty_pages to on;
SELECT documentdb_api_internal.rum_prune_empty_entries_on_index('documentdb_data.documents_rum_index_403'::regclass);

set documentdb.forceDisableSeqScan to on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, VERBOSE OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF) SELECT document FROM bson_aggregation_count('pvacuum_db', '{ "count": "pclean", "query": { "a": { "$exists": true } } }') $cmd$);
reset documentdb.forceDisableSeqScan;

ALTER SYSTEM set autovacuum to on;
SELECT pg_reload_conf();