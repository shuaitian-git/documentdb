SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

CREATE SCHEMA value_ordered_test_schema;

-- converts index term bytea to bson with flags
CREATE FUNCTION value_ordered_test_schema.gin_bson_index_term_to_bson(bytea) 
RETURNS bson
LANGUAGE c
AS '$libdir/pg_documentdb', 'gin_bson_index_term_to_bson';


-- debug function to read index pages
CREATE OR REPLACE FUNCTION value_ordered_test_schema.documentdb_rum_page_get_entries(page bytea, firstEntryType Oid)
RETURNS SETOF jsonb
LANGUAGE c
AS '$libdir/pg_documentdb_extended_rum_core', 'documentdb_rum_page_get_entries';

SET documentdb.next_collection_id TO 300;
SET documentdb.next_collection_index_id TO 300;

set documentdb.defaultUseCompositeOpClass to on;

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_odb', '{ "createIndexes": "comp_value_ordering", "indexes": [ { "name": "path1_1", "key": { "path1": 1 } }, { "name": "path1_-1", "key": { "path1": -1 } } ] }', TRUE);

-- insert only even values
set documentdb.enableValueOnlyIndexTerms to off;
SELECT COUNT(documentdb_api.insert_one('comp_odb', 'comp_value_ordering', bson_build_document('_id'::text, i, 'path1'::text, i * 2))) FROM generate_series(1, 10) i;

-- now set the GUC to on and insert only odd terms
set documentdb.enableValueOnlyIndexTerms to on;
SELECT COUNT(documentdb_api.insert_one('comp_odb', 'comp_value_ordering', bson_build_document('_id'::text, i + 10, 'path1'::text, (i * 2) - 1))) FROM generate_series(1, 10) i;

-- now walk the index terms and assert that they're ordered correctly and every odd term is value only
SELECT entry->> 'offset',
    value_ordered_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea)
        FROM value_ordered_test_schema.documentdb_rum_page_get_entries(public.get_raw_page('documentdb_data.documents_rum_index_302', 1), 'bytea'::regtype) entry;

SELECT entry->> 'offset',
    value_ordered_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea)
        FROM value_ordered_test_schema.documentdb_rum_page_get_entries(public.get_raw_page('documentdb_data.documents_rum_index_303', 1), 'bytea'::regtype) entry;

-- note that the terms are co-comparable - adding even values again does not add new terms
set documentdb.enableValueOnlyIndexTerms to on;
SELECT COUNT(documentdb_api.insert_one('comp_odb', 'comp_value_ordering', bson_build_document('_id'::text, i + 20, 'path1'::text, i * 2))) FROM generate_series(1, 10) i;

-- count should be 30
SELECT COUNT(*) FROM documentdb_api.collection('comp_odb', 'comp_value_ordering');

SELECT entry->> 'offset',
    value_ordered_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea)
        FROM value_ordered_test_schema.documentdb_rum_page_get_entries(public.get_raw_page('documentdb_data.documents_rum_index_302', 1), 'bytea'::regtype) entry;

SELECT entry->> 'offset',
    value_ordered_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea)
        FROM value_ordered_test_schema.documentdb_rum_page_get_entries(public.get_raw_page('documentdb_data.documents_rum_index_303', 1), 'bytea'::regtype) entry;

-- same is true when factoring in truncation.
TRUNCATE documentdb_data.documents_301;

-- insert with value only terms
set documentdb.enableValueOnlyIndexTerms to on;
SELECT documentdb_api.insert_one('comp_odb', 'comp_value_ordering', bson_build_document('_id'::text, 'trunc1'::text, 'path1'::text, ('abcde' || repeat('z', 3000) || '1')::text));

-- insert with value off terms
set documentdb.enableValueOnlyIndexTerms to off;
SELECT documentdb_api.insert_one('comp_odb', 'comp_value_ordering', bson_build_document('_id'::text, 'trunc2'::text, 'path1'::text, ('zyxwv' || repeat('z', 3000) || '1')::text));

-- now insert the other value with opposite flags
set documentdb.enableValueOnlyIndexTerms to off;
SELECT documentdb_api.insert_one('comp_odb', 'comp_value_ordering', bson_build_document('_id'::text, 'trunc3'::text, 'path1'::text, ('abcde' || repeat('z', 3000) || '1')::text));

-- insert with value off terms
set documentdb.enableValueOnlyIndexTerms to on;
SELECT documentdb_api.insert_one('comp_odb', 'comp_value_ordering', bson_build_document('_id'::text, 'trunc4'::text, 'path1'::text, ('zyxwv' || repeat('z', 3000) || '1')::text));

-- add non-truncated versions with that prefix with one with the flag and one not.
set documentdb.enableValueOnlyIndexTerms to off;
SELECT documentdb_api.insert_one('comp_odb', 'comp_value_ordering', bson_build_document('_id'::text, 'trunc5'::text, 'path1'::text, ('abcde' || repeat('z', 10) || '1')::text));

-- insert with value off terms
set documentdb.enableValueOnlyIndexTerms to on;
SELECT documentdb_api.insert_one('comp_odb', 'comp_value_ordering', bson_build_document('_id'::text, 'trunc6'::text, 'path1'::text, ('zyxwv' || repeat('z', 10) || '1')::text));


-- count should be 6
SELECT COUNT(*) FROM documentdb_api.collection('comp_odb', 'comp_value_ordering');

-- should have only 2 index terms with the truncation flags on (one value only, the other one not) and the lengths should match, and non-truncated sort before truncated
SELECT entry->> 'offset',
    value_ordered_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) ->> '$flags',
    length(value_ordered_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea)::bytea),
    SUBSTRING(value_ordered_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) ->> '$', 0, 15)
        FROM value_ordered_test_schema.documentdb_rum_page_get_entries(public.get_raw_page('documentdb_data.documents_rum_index_302', 1), 'bytea'::regtype) entry;

SELECT entry->> 'offset',
    value_ordered_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) ->> '$flags',
    length(value_ordered_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea)::bytea),
    SUBSTRING(value_ordered_test_schema.gin_bson_index_term_to_bson((entry->>'firstEntry')::bytea) ->> '$', 0, 15)
        FROM value_ordered_test_schema.documentdb_rum_page_get_entries(public.get_raw_page('documentdb_data.documents_rum_index_303', 1), 'bytea'::regtype) entry;
