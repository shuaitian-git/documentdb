#include "udfs/index_mgmt/create_index_background--0.108-0.sql"
#include "udfs/rum/bson_rum_text_path_adapter_funcs--0.24-0.sql"

GRANT UPDATE (indisvalid) ON pg_catalog.pg_index to __API_ADMIN_ROLE__;

-- if there's existing installations that were created before 0.108 we need to update the operator class to not depend on rum directly.
DO LANGUAGE plpgsql $cmd$
DECLARE text_ops_op_family oid;
BEGIN
    SELECT opf.oid INTO text_ops_op_family FROM pg_opfamily opf JOIN pg_namespace pgn ON opf.opfnamespace = pgn.oid where opf.opfname = 'bson_rum_text_path_ops' AND pgn.nspname = 'documentdb_api_catalog';

    UPDATE pg_amproc SET amproc = 'documentdb_api_internal.rum_extract_tsquery'::regproc WHERE amprocfamily = text_ops_op_family AND amprocnum = 3;
    UPDATE pg_amproc SET amproc = 'documentdb_api_internal.rum_tsquery_consistent'::regproc WHERE amprocfamily = text_ops_op_family AND amprocnum = 4;
    UPDATE pg_amproc SET amproc = 'documentdb_api_internal.rum_tsvector_config'::regproc WHERE amprocfamily = text_ops_op_family AND amprocnum = 6;
    UPDATE pg_amproc SET amproc = 'documentdb_api_internal.rum_tsquery_pre_consistent'::regproc WHERE amprocfamily = text_ops_op_family AND amprocnum = 7;
    UPDATE pg_amproc SET amproc = 'documentdb_api_internal.rum_tsquery_distance'::regproc WHERE amprocfamily = text_ops_op_family AND amprocnum = 8;
    UPDATE pg_amproc SET amproc = 'documentdb_api_internal.rum_ts_join_pos'::regproc WHERE amprocfamily = text_ops_op_family AND amprocnum = 10;
END;
$cmd$;