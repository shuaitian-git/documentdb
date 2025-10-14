SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET citus.next_shard_id TO 5880000;
SET documentdb.next_collection_id TO 588000;
SET documentdb.next_collection_index_id TO 588000;

set documentdb.enablePrepareUnique to on;

-- if documentdb_extended_rum exists, set alternate index handler
SELECT pg_catalog.set_config('documentdb.alternate_index_handler_name', 'extended_rum', false), extname FROM pg_extension WHERE extname = 'documentdb_extended_rum';

SELECT documentdb_api_internal.create_indexes_non_concurrently('prep_unique_db', '{ "createIndexes": "collection", "indexes": [ { "name": "a_1", "key": { "a": 1 }, "storageEngine": { "enableOrderedIndex": true, "buildAsUnique": true } } ] }', TRUE);

\d documentdb_data.documents_588001;

-- inserting and querying works fine.
select COUNT(documentdb_api.insert_one('prep_unique_db', 'collection', FORMAT('{ "_id": %s, "a": %s, "b": %s }', i, i, 100-i)::bson)) FROM generate_series(1, 100) i;

-- insert a duplicate, should not fail
SELECT documentdb_api.insert_one('prep_unique_db', 'collection', '{ "_id": 101, "a": 1 }');

ANALYZE documentdb_data.documents_588001;

set citus.propagate_set_commands to 'local';

BEGIN;
set local documentdb.enableExtendedExplainPlans to on;
set local enable_seqscan to off;
EXPLAIN (ANALYZE ON, VERBOSE ON, COSTS OFF, TIMING OFF, SUMMARY OFF) select document FROM bson_aggregation_find('prep_unique_db', '{ "find": "collection", "filter": {"a": {"$gt": 2}} }');
ROLLBACK;

BEGIN;
set local documentdb.enableExtendedExplainPlans to on;
set local documentdb.enableIndexOrderByPushdown to on;
EXPLAIN (ANALYZE ON, VERBOSE ON, COSTS OFF, TIMING OFF, SUMMARY OFF) select document FROM bson_aggregation_find('prep_unique_db', '{ "find": "collection", "filter": {"a": {"$gt": 2}}, "sort": {"a": 1} }');
ROLLBACK;


-- multiple fields work fine
SELECT documentdb_api_internal.create_indexes_non_concurrently('prep_unique_db', '{ "createIndexes": "collection", "indexes": [ { "name": "a_1_b_1", "key": { "a": 1, "b": 1 }, "storageEngine": { "enableOrderedIndex": true, "buildAsUnique": true } } ] }', TRUE);

SELECT bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('prep_unique_db', '{ "listIndexes": "collection" }') ORDER BY 1;

\d documentdb_data.documents_588001;
ANALYZE documentdb_data.documents_588001;

BEGIN;
set local documentdb.enableExtendedExplainPlans to on;
set local enable_seqscan to off;
EXPLAIN (ANALYZE ON, VERBOSE ON, COSTS OFF, TIMING OFF, SUMMARY OFF) select document FROM bson_aggregation_find('prep_unique_db', '{ "find": "collection", "filter": {"a": {"$gt": 2}, "b": 3} }');
ROLLBACK;

-- test error paths
SELECT documentdb_api_internal.create_indexes_non_concurrently('prep_unique_db', '{"createIndexes": "collection", "indexes": [{"key": {"a": 1 }, "storageEngine": { "enableOrderedIndex": false, "buildAsUnique": true }, "name": "invalid"}]}',true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('prep_unique_db', '{"createIndexes": "collection", "indexes": [{"key": {"b": 1 }, "unique": true, "storageEngine": { "enableOrderedIndex": true, "buildAsUnique": true }, "name": "invalid"}]}',true);


-- Now that we have indexes with builtAsUnique, test prepareUnique.
SELECT documentdb_api.coll_mod('prep_unique_db', 'collection', '{ "collMod": "collection", "index": { "name": "a_1", "prepareUnique": true } }');

\d documentdb_data.documents_588001;

-- inserting a duplicate should fail now.
SELECT documentdb_api.insert_one('prep_unique_db', 'collection', '{ "_id": 102, "a": 1 }');

-- but we already have a duplicate because prepareUnique doesn't enforce uniqueness on existing data.
SELECT document from documentdb_data.documents_588001 where document @@ '{"a": 1}';

-- sharding should work.
SELECT documentdb_api.shard_collection('{ "shardCollection": "prep_unique_db.collection", "key": { "_id": "hashed" } }');

set citus.show_shards_for_app_name_prefixes to '*';

\d documentdb_data.documents_588001_5880006;

-- list indexes, a_1_b_1 index should have buildAsUnique but a_1 should be prepareUnique after sharding.
SELECT bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('prep_unique_db', '{ "listIndexes": "collection" }') ORDER BY 1;

-- now convert a_1_b_1 index to prepareUnique
SELECT documentdb_api.coll_mod('prep_unique_db', 'collection', '{ "collMod": "collection", "index": { "name": "a_1_b_1", "prepareUnique": true } }');

\d documentdb_data.documents_588001_5880004;

-- now unshard the collection
SELECT documentdb_api.unshard_collection('{ "unshardCollection": "prep_unique_db.collection" }');

\d documentdb_data.documents_588001;

SELECT bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('prep_unique_db', '{ "listIndexes": "collection" }') ORDER BY 1;

-- now create another index with buildAsUnique, then convert and drop the collection
SELECT documentdb_api_internal.create_indexes_non_concurrently('prep_unique_db', '{ "createIndexes": "collection", "indexes": [ { "name": "c_1", "key": { "c": 1 }, "storageEngine": { "enableOrderedIndex": true, "buildAsUnique": true } } ] }', TRUE);
SELECT documentdb_api.coll_mod('prep_unique_db', 'collection', '{ "collMod": "collection", "index": { "name": "c_1", "prepareUnique": true } }');

\d documentdb_data.documents_588001;

SELECT documentdb_api.drop_collection('prep_unique_db', 'collection');

-- test error paths for prepareUnique
SELECT documentdb_api_internal.create_indexes_non_concurrently('prep_unique_db', '{ "createIndexes": "collection", "indexes": [ { "name": "d_1", "key": { "d": 1 }, "storageEngine": { "enableOrderedIndex": true } } ] }', TRUE);
SELECT documentdb_api.coll_mod('prep_unique_db', 'collection', '{ "collMod": "collection", "index": { "name": "d_1", "prepareUnique": true } }');

-- try to set prepareUnique to false
-- TODO: this can be supported in future if needed.
SELECT documentdb_api.coll_mod('prep_unique_db', 'collection', '{ "collMod": "collection", "index": { "name": "d_1", "prepareUnique": false } }');

-- now create a unique index and a prepareUnique index on different fields, and let's compare the pg_constraint entries.
SELECT documentdb_api_internal.create_indexes_non_concurrently('prep_unique_db', '{ "createIndexes": "collection", "indexes": [ { "name": "e_1", "key": { "e": 1 }, "unique": true, "storageEngine": { "enableOrderedIndex": true } },
                                                                                                                                { "name": "f_1", "key": { "f": 1 }, "storageEngine": { "enableOrderedIndex": true, "buildAsUnique": true } } ] }', TRUE);

-- test this one with the forceUpdateIndexInline GUC
SET documentdb.forceUpdateIndexInline TO on;
SELECT documentdb_api.coll_mod('prep_unique_db', 'collection', '{ "collMod": "collection", "index": { "name": "f_1", "prepareUnique": true } }');
RESET documentdb.forceUpdateIndexInline;

-- now compare the pg_constraint entries for the two indexes
SELECT 
    c1.conname AS conname1,
    c2.conname AS conname2,
    c1.contype AS contype1,
    c2.contype AS contype2,
    c1.conkey AS conkey1,
    c2.conkey AS conkey2,
    (c1.conexclop = c2.conexclop) AS conexclop_equal
FROM pg_constraint c1
JOIN pg_constraint c2 
  ON c1.conrelid = c2.conrelid
WHERE c1.conrelid = 'documentdb_data.documents_588002'::regclass
  AND c1.conname::text like '%_rum_%'
  AND c1.oid < c2.oid
ORDER BY c1.conname, c2.conname;

-- running prepareUnique again should be a no-op
SELECT documentdb_api.coll_mod('prep_unique_db', 'collection', '{ "collMod": "collection", "index": { "name": "f_1", "prepareUnique": true } }');

-- list indexes there we should not see buildAsUnique.
SELECT bson_dollar_unwind(cursorpage, '$cursor.firstBatch') FROM documentdb_api.list_indexes_cursor_first_page('prep_unique_db', '{ "listIndexes": "collection" }') ORDER BY 1;

\d documentdb_data.documents_588002;

-- turn off feature, should fail
set documentdb.enablePrepareUnique to off;
SELECT documentdb_api.coll_mod('prep_unique_db', 'collection', '{ "collMod": "collection", "index": { "name": "f_1", "prepareUnique": true } }');
