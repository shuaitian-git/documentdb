
#include "udfs/query/bson_dollar_evaluation--0.109-0.sql"

-- fix the return of gin_bson_compare which was created incorrectly.
UPDATE pg_proc SET prorettype = 'integer'::regtype WHERE proname = 'gin_bson_compare' AND pronamespace = 'documentdb_api_catalog'::regnamespace;