SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET citus.next_shard_id TO 58000000;
SET documentdb.next_collection_id TO 58000;
SET documentdb.next_collection_index_id TO 58000;

SELECT COUNT(documentdb_api.insert_one('countdb', 'countcoll', bson_build_document('_id'::text, i, 'value'::text, i))) FROM generate_series(1, 200) i;

SELECT documentdb_api_internal.create_indexes_non_concurrently('countdb', '{ "createIndexes": "countcoll", "indexes": [ { "key": { "a": 1 }, "name": "a_1" }] }', TRUE);

ANALYZE documentdb_data.documents_58001;

SELECT document FROM bson_aggregation_count('countdb', '{ "count": "countcoll" }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_count('countdb', '{ "count": "countcoll" }');

SELECT document FROM bson_aggregation_count('countdb', '{ "count": "countcoll", "query": {} }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_count('countdb', '{ "count": "countcoll", "query": {} }');

SELECT document FROM bson_aggregation_count('countdb', '{ "count": "countcoll", "query": {}, "limit": 1000 }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_count('countdb', '{ "count": "countcoll", "query": {}, "limit": 1000 }');

SELECT document FROM bson_aggregation_count('countdb', '{ "count": "countcoll", "query": {}, "limit": 100 }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_count('countdb', '{ "count": "countcoll", "query": {}, "limit": 100 }');

SELECT document FROM bson_aggregation_count('countdb', '{ "count": "countcoll", "query": { "$alwaysTrue": 1 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_count('countdb', '{ "count": "countcoll", "query": { "$alwaysTrue": 1 } }');

SELECT document FROM bson_aggregation_count('countdb', '{ "count": "countcoll", "query": { "$alwaysFalse": 1 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_count('countdb', '{ "count": "countcoll", "query": { "$alwaysFalse": 1 } }');

BEGIN;
set local client_min_messages to DEBUG1;
set local documentdb.forceRunDiagnosticCommandInline to on;

-- here we only query count metadata
SELECT document FROM bson_aggregation_count('countdb', '{ "count": "countcoll", "query": {} }');

-- here we get storage & index sizes
SELECT documentdb_api.coll_stats('countdb', 'countcoll');

-- test it out for collstats aggregation too
SELECT document FROM bson_aggregation_pipeline('countdb', '{ "aggregate": "countcoll", "pipeline": [ { "$collStats": { "count": {} }} ] }');

SELECT document FROM bson_aggregation_pipeline('countdb', '{ "aggregate": "countcoll", "pipeline": [ { "$collStats": { "storageStats": {} }} ] }');

ROLLBACK;