/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/commands/coll_mod.c
 *
 * Implementation of the collMod command.
 *-------------------------------------------------------------------------
 */
#include <postgres.h>
#include <executor/spi.h>
#include <fmgr.h>
#include <funcapi.h>
#include <catalog/pg_constraint.h>
#include <catalog/index.h>
#include <utils/builtins.h>
#include <utils/snapmgr.h>
#include <utils/lsyscache.h>

#include "commands/parse_error.h"
#include "commands/commands_common.h"
#include "utils/documentdb_errors.h"
#include "metadata/collection.h"
#include "api_hooks.h"
#include "metadata/index.h"
#include "metadata/metadata_cache.h"
#include "utils/guc_utils.h"
#include "utils/query_utils.h"
#include "utils/version_utils.h"
#include "utils/feature_counter.h"
#include "commands/coll_mod.h"

extern bool EnablePrepareUnique;
extern bool ForceUpdateIndexInline;


/* --------------------------------------------------------- */
/* Data-types */
/* --------------------------------------------------------- */

/*
 * Index specification option available for collMod till 5.0
 */
typedef struct
{
	pgbson *keyPattern;
	char *name;
	bool hidden;
	bool prepareUnique;
	int expireAfterSeconds;
} CollModIndexOptions;

/*
 * CollMod Database command specification options
 */
typedef struct
{
	const char *collectionName;

	/* Index update options */
	CollModIndexOptions index;

	/* A view definition it is a view */
	ViewDefinition viewDefinition;

	/* The name of the collection to colocate this collection with */
	bson_value_t colocationOptions;

	/* The validator for the collection */
	bson_value_t validator;

	/* The collection's validation level setting */
	char *validationLevel;

	/* The validation action for the collection */
	char *validationAction;

	/* TODO: Add more options when they are supported e.g.: Validators etc */
} CollModOptions;

typedef enum CollModSpecFlags
{
	HAS_NO_OPTIONS = 0,

	/* Index option specific flags to identify if options is provided */
	HAS_INDEX_OPTION = 1 << 0,                          /* Set if "index" is set */
	HAS_INDEX_OPTION_NAME = 1 << 1,                     /* Set if "index.name" is set */
	HAS_INDEX_OPTION_KEYPATTERN = 1 << 2,               /* Set if "index.keyPattern" is set */
	HAS_INDEX_OPTION_HIDDEN = 1 << 3,                   /* Set if "index.hidden" is set */
	HAS_INDEX_OPTION_EXPIRE_AFTER_SECONDS = 1 << 4,     /* Set if "index.expireAfterSeconds" is set */
	HAS_INDEX_OPTION_PREPARE_UNIQUE = 1 << 5,           /* Set if "index.prepareUnique" is set */

	/* Views update */
	HAS_VIEW_OPTION = 1 << 6,

	HAS_COLOCATION = 1 << 7,

	/* validation update */
	HAS_VALIDATION_OPTION = 1 << 8,

	/* TODO: More OPTIONS to follow */
} CollModSpecFlags;


/* --------------------------------------------------------- */
/* Forward declaration */
/* --------------------------------------------------------- */

static CollModSpecFlags ParseSpecSetCollModOptions(const pgbson *collModSpec,
												   CollModOptions *collModOptions);
static void ParseIndexSpecSetCollModOptions(bson_iter_t *indexSpecIter,
											CollModIndexOptions *collModIndexOptions,
											CollModSpecFlags *specFlags);
static void ModifyIndexSpecsInCollection(const MongoCollection *collection,
										 const CollModIndexOptions *indexOption,
										 const CollModSpecFlags *specFlags,
										 pgbson_writer *writer);
static void ModifyViewDefinition(Datum databaseDatum,
								 const MongoCollection *collection,
								 const ViewDefinition *viewDefinition,
								 pgbson_writer *writer);
static bool GetHiddenFlagFromOptions(pgbson *indexOptions);
static void GetPrepareUniqueFlagsFromOptions(pgbson *indexOptions, bool *buildAsUnique,
											 bool *prepareUnique);
static pgbson * UpdateOperationKeyInIndexOptions(pgbson *indexOptions,
												 IndexMetadataUpdateOperation operation,
												 bool newValue);
static void UpdatePostgresIndex(uint64_t collectionId, int indexId, int operation, bool
								value);
static void UpdatePostgresIndexOverride(uint64_t collectionId, int indexId, int operation,
										bool
										value);
static void UpdatePostgresIndexesForHide(List *indexOids, bool hidden);
static void UpdatePostgresIndexesForPrepareUnique(List *indexOids, bool prepareUnique);
static void RegisterExclusionInPgIndexCatalog(Oid indexoid);

/* --------------------------------------------------------- */
/* Top level exports */
/* --------------------------------------------------------- */

PG_FUNCTION_INFO_V1(command_coll_mod);

/*
 * command_coll_mod implements the functionality of collMod Database command
 * dbcommand/collMod.
 */
Datum
command_coll_mod(PG_FUNCTION_ARGS)
{
	if (PG_ARGISNULL(0))
	{
		ereport(ERROR, (errmsg("Database name must not be NULL")));
	}

	if (PG_ARGISNULL(1))
	{
		ereport(ERROR, (errmsg("collection name cannot be NULL")));
	}

	if (PG_ARGISNULL(2))
	{
		ereport(ERROR, (errmsg("collMod spec cannot be NULL")));
	}
	pgbson *collModSpec = PG_GETARG_PGBSON(2);

	ReportFeatureUsage(FEATURE_COMMAND_COLLMOD);

	/*
	 * TODO: Restrict collMod command access based on RBAC when it is available
	 */

	/*
	 * Acquire the appropriate lock on the collection for coll_mod.
	 * An exclusive lock is obtained on the collection's data table.
	 * Currently, only the collection itself is locked, since options that could affect
	 * other collections (such as viewOn, pipelines, or validators) are not yet supported.
	 */
	Datum databaseDatum = PG_GETARG_DATUM(0);

	/* Validate the collMod options received because GW only checks for valid collection name */
	CollModOptions collModOptions = { 0 };
	CollModSpecFlags specFlags = ParseSpecSetCollModOptions(collModSpec,
															&collModOptions);

	if (collModOptions.collectionName == NULL)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_FAILEDTOPARSE), (errmsg(
																		"Collection name of collMod options must be specified"))));
	}

	if (!PG_ARGISNULL(1))
	{
		const char *collectionName = TextDatumGetCString(PG_GETARG_DATUM(1));

		if (strcmp(collectionName, collModOptions.collectionName) != 0)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_BADVALUE),
							errmsg(
								"Collection name specified in the top level must match that in the spec")));
		}
	}

	MongoCollection *collection =
		GetMongoCollectionOrViewByNameDatum(databaseDatum,
											CStringGetTextDatum(
												collModOptions.collectionName),
											AccessExclusiveLock);

	if (collection == NULL)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_NAMESPACENOTFOUND),
						errmsg("The specified namespace does not exist")));
	}

	pgbson_writer writer;
	PgbsonWriterInit(&writer);
	PgbsonWriterAppendInt32(&writer, "ok", 2, 1);

	if (specFlags == HAS_NO_OPTIONS)
	{
		/* There are no operations requested, no-op */
		PG_RETURN_POINTER(PgbsonWriterGetPgbson(&writer));
	}

	if (specFlags & HAS_VIEW_OPTION)
	{
		ReportFeatureUsage(FEATURE_COMMAND_COLLMOD_VIEW);
		ModifyViewDefinition(databaseDatum, collection, &collModOptions.viewDefinition,
							 &writer);
	}
	else if (collection->viewDefinition != NULL)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_COMMANDNOTSUPPORTEDONVIEW),
						errmsg(
							"The namespace %s.%s refers to a view object rather than a collection",
							collection->name.databaseName,
							collection->name.collectionName)));
	}

	if (specFlags & HAS_INDEX_OPTION)
	{
		/* Index related modification requested */
		ModifyIndexSpecsInCollection(collection, &collModOptions.index,
									 &specFlags, &writer);
	}

	if (specFlags & HAS_COLOCATION)
	{
		ReportFeatureUsage(FEATURE_COMMAND_COLLMOD_COLOCATION);
		if (collection->viewDefinition != NULL)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INVALIDOPTIONS),
							errmsg("Cannot specify colocation on a view")));
		}

		HandleColocation(collection, &collModOptions.colocationOptions);
	}

	if (specFlags & HAS_VALIDATION_OPTION)
	{
		ReportFeatureUsage(FEATURE_COMMAND_COLLMOD_VALIDATION);

		/* if validationAction/validationLevel of collection is empty, it should be updated with customized or default value */
		if (collection->schemaValidator.validationAction == ValidationAction_Invalid)
		{
			collModOptions.validationAction = collModOptions.validationAction == NULL ?
											  "error" : collModOptions.validationAction;
		}
		if (collection->schemaValidator.validationLevel == ValidationLevel_Invalid)
		{
			collModOptions.validationLevel = collModOptions.validationLevel == NULL ?
											 "strict" : collModOptions.validationLevel;
		}

		UpsertSchemaValidation(databaseDatum, CStringGetTextDatum(
								   collModOptions.collectionName),
							   &collModOptions.validator,
							   collModOptions.validationLevel,
							   collModOptions.validationAction);
	}

	PG_RETURN_POINTER(PgbsonWriterGetPgbson(&writer));
}


/*
 * Parses the collMod Options received from GW, sets the option in `CollModOptions`
 * and also returns the `CollModSpecFlags` to represent which options were provided
 */
static CollModSpecFlags
ParseSpecSetCollModOptions(const pgbson *collModSpec,
						   CollModOptions *collModOptions)
{
	Assert(collModSpec != NULL && collModOptions != NULL);

	CollModSpecFlags specFlags = HAS_NO_OPTIONS;
	bool hasSchemaValidation = false;

	bson_iter_t iter;
	PgbsonInitIterator(collModSpec, &iter);
	while (bson_iter_next(&iter))
	{
		const char *key = bson_iter_key(&iter);
		const bson_value_t *value = bson_iter_value(&iter);
		if (strcmp(key, "collMod") == 0)
		{
			EnsureTopLevelFieldType("collMod.collMod", &iter, BSON_TYPE_UTF8);
			collModOptions->collectionName = bson_iter_utf8(&iter, NULL);
		}
		else if (strcmp(key, "index") == 0)
		{
			EnsureTopLevelFieldType("collMod.index", &iter, BSON_TYPE_DOCUMENT);
			bson_iter_t indexSpecIter;
			bson_iter_recurse(&iter, &indexSpecIter);
			ParseIndexSpecSetCollModOptions(&indexSpecIter, &(collModOptions->index),
											&specFlags);
			specFlags |= HAS_INDEX_OPTION;
		}
		else if (strcmp(key, "viewOn") == 0)
		{
			EnsureTopLevelFieldType("collMod.viewOn", &iter, BSON_TYPE_UTF8);
			specFlags |= HAS_VIEW_OPTION;
			collModOptions->viewDefinition.viewSource = pnstrdup(value->value.v_utf8.str,
																 value->value.v_utf8.len);
		}
		else if (strcmp(key, "pipeline") == 0)
		{
			EnsureTopLevelFieldType("collMod.pipeline", &iter, BSON_TYPE_ARRAY);
			collModOptions->viewDefinition.pipeline = *value;
		}
		else if (strcmp(key, "colocation") == 0)
		{
			EnsureTopLevelFieldType("collMod.colocation", &iter, BSON_TYPE_DOCUMENT);
			collModOptions->colocationOptions = *value;
			specFlags |= HAS_COLOCATION;
		}
		else if (strcmp(key, "validator") == 0)
		{
			const bson_value_t *validator = ParseAndGetValidatorSpec(&iter,
																	 "collMod.validator",
																	 &hasSchemaValidation);
			if (validator == NULL)
			{
				collModOptions->validator.value_type = BSON_TYPE_EOD;
			}
			else
			{
				collModOptions->validator = *validator;
			}
		}
		else if (strcmp(key, "validationLevel") == 0)
		{
			collModOptions->validationLevel = ParseAndGetValidationLevelOption(&iter,
																			   "collMod.validationLevel",
																			   &
																			   hasSchemaValidation);
		}
		else if (strcmp(key, "validationAction") == 0)
		{
			collModOptions->validationAction = ParseAndGetValidationActionOption(&iter,
																				 "collMod.validationAction",
																				 &
																				 hasSchemaValidation);
		}
		else if (IsCommonSpecIgnoredField(key))
		{
			/*
			 *  Silently ignore now, so that clients don't break
			 * TODO: implement "validationAction","validationLevel",
			 * "validator","viewOn", "pipeline", "expireAfterSeconds"
			 */
			elog(DEBUG1, "Command field not recognized: collMod.%s", key);
		}
		else
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_UNKNOWNBSONFIELD),
							errmsg(
								"The BSON field 'collMod.%s' is not recognized as a valid field.",
								key)));
		}
	}

	if (collModOptions->viewDefinition.pipeline.value_type != BSON_TYPE_EOD &&
		specFlags != HAS_VIEW_OPTION)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INVALIDOPTIONS),
						errmsg("collmod.pipeline requires collmod.viewOn")));
	}

	if (hasSchemaValidation)
	{
		specFlags |= HAS_VALIDATION_OPTION;
	}

	if ((specFlags & HAS_INDEX_OPTION) && (specFlags & HAS_INDEX_OPTION_PREPARE_UNIQUE))
	{
		/* prepareUnique cannot be specified with other collMod options, we should remove metadata flags. */
		CollModSpecFlags tmpFlags = specFlags &
									~HAS_INDEX_OPTION &
									~HAS_INDEX_OPTION_NAME &
									~HAS_INDEX_OPTION_KEYPATTERN &
									~HAS_INDEX_OPTION_PREPARE_UNIQUE;

		if (tmpFlags != 0)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INVALIDOPTIONS),
							errmsg(
								"collMod.prepareUnique cannot be specified with other collMod options")));
		}
	}

	return specFlags;
}


/*
 * This method only parses the index options for a collmod command
 */
static void
ParseIndexSpecSetCollModOptions(bson_iter_t *indexSpecIter,
								CollModIndexOptions *collModIndexOptions,
								CollModSpecFlags *specFlags)
{
	Assert(indexSpecIter != NULL && collModIndexOptions != NULL);
	while (bson_iter_next(indexSpecIter))
	{
		const char *key = bson_iter_key(indexSpecIter);
		const bson_value_t *value = bson_iter_value(indexSpecIter);
		if (strcmp(key, "keyPattern") == 0)
		{
			EnsureTopLevelFieldType("collMod.index.keyPattern", indexSpecIter,
									BSON_TYPE_DOCUMENT);
			if (*specFlags & HAS_INDEX_OPTION_NAME)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INVALIDOPTIONS),
								errmsg(
									"Both name and key pattern cannot be present")));
			}
			collModIndexOptions->keyPattern = PgbsonInitFromDocumentBsonValue(value);
			*specFlags |= HAS_INDEX_OPTION_KEYPATTERN;
		}
		else if (strcmp(key, "name") == 0)
		{
			EnsureTopLevelFieldType("collMod.index.name", indexSpecIter, BSON_TYPE_UTF8);
			if (*specFlags & HAS_INDEX_OPTION_KEYPATTERN)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INVALIDOPTIONS),
								errmsg(
									"Both name and key pattern cannot be present")));
			}
			collModIndexOptions->name = palloc(value->value.v_utf8.len + 1);
			strcpy(collModIndexOptions->name, value->value.v_utf8.str);
			*specFlags |= HAS_INDEX_OPTION_NAME;
		}
		else if (strcmp(key, "hidden") == 0)
		{
			ReportFeatureUsage(FEATURE_COMMAND_COLLMOD_INDEX_HIDDEN);
			EnsureTopLevelFieldIsBooleanLike("collMod.index.hidden", indexSpecIter);
			collModIndexOptions->hidden = BsonValueAsBool(value);
			*specFlags |= HAS_INDEX_OPTION_HIDDEN;
		}
		else if (strcmp(key, "prepareUnique") == 0)
		{
			ReportFeatureUsage(FEATURE_COMMAND_COLLMOD_INDEX_PREPARE_UNIQUE);
			EnsureTopLevelFieldIsBooleanLike("collMod.index.prepareUnique",
											 indexSpecIter);
			collModIndexOptions->prepareUnique = BsonValueAsBool(value);
			*specFlags |= HAS_INDEX_OPTION_PREPARE_UNIQUE;
		}
		else if (strcmp(key, "expireAfterSeconds") == 0)
		{
			ReportFeatureUsage(FEATURE_COMMAND_COLLMOD_TTL_UPDATE);
			if (!BsonValueIsNumber(value))
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_TYPEMISMATCH),
								errmsg(
									"BSON field 'collMod.index.expireAfterSeconds' is the wrong type '%s', "
									"expected types '[long, int, decimal, double']",
									BsonTypeName(value->value_type))));
			}
			int64 expireAfterSeconds = BsonValueAsInt64(value);
			if (expireAfterSeconds < 0)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INVALIDOPTIONS),
								errmsg(
									"BSON field 'collMod.index.expireAfterSeconds' cannot be less than 0.")));
			}
			collModIndexOptions->expireAfterSeconds = (uint64) expireAfterSeconds;
			*specFlags |= HAS_INDEX_OPTION_EXPIRE_AFTER_SECONDS;
		}
		else
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_UNKNOWNBSONFIELD),
							errmsg(
								"The BSON field 'collMod.index.%s' is not recognized as a valid field.",
								key)));
		}
	}

	if ((*specFlags & HAS_INDEX_OPTION_NAME) != HAS_INDEX_OPTION_NAME &&
		(*specFlags & HAS_INDEX_OPTION_KEYPATTERN) != HAS_INDEX_OPTION_KEYPATTERN)
	{
		/* If no name or key pattern then error */
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INVALIDOPTIONS),
						errmsg("Must specify either index name or key pattern.")));
	}

	if ((*specFlags & HAS_INDEX_OPTION_EXPIRE_AFTER_SECONDS) !=
		HAS_INDEX_OPTION_EXPIRE_AFTER_SECONDS &&
		(*specFlags & HAS_INDEX_OPTION_HIDDEN) != HAS_INDEX_OPTION_HIDDEN &&
		(*specFlags & HAS_INDEX_OPTION_PREPARE_UNIQUE) != HAS_INDEX_OPTION_PREPARE_UNIQUE)
	{
		/* If hidden or expireAfterSeconds is not provided then error */
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INVALIDOPTIONS),
						errmsg("no expireAfterSeconds, hidden or prepareUnique field")));
	}
}


/*
 * Updates the ApiCatalogSchemaName.collection_indexes metadata table with the requested updates
 */
static void
ModifyIndexSpecsInCollection(const MongoCollection *collection,
							 const CollModIndexOptions *indexOption,
							 const CollModSpecFlags *specFlags,
							 pgbson_writer *writer)
{
	StringInfo cmdStr = makeStringInfo();
	bool searchWithName = *specFlags & HAS_INDEX_OPTION_NAME;
	appendStringInfo(cmdStr,
					 "SELECT index_id, index_spec, index_is_valid "
					 "FROM %s.collection_indexes "
					 "WHERE collection_id = $2 AND (index_spec).%s = $1;",
					 ApiCatalogSchemaName,
					 searchWithName ? "index_name" : "index_key");

	int argCount = 2;
	Oid argTypes[2];
	Datum argValues[2];

	if (searchWithName)
	{
		argTypes[0] = TEXTOID;
		argValues[0] = CStringGetTextDatum(indexOption->name);
	}
	else
	{
		argTypes[0] = BsonTypeId();
		argValues[0] = PointerGetDatum(indexOption->keyPattern);
	}

	argTypes[1] = INT8OID;
	argValues[1] = UInt64GetDatum(collection->collectionId);

	/* all args are non-null */
	char *argNulls = NULL;
	bool readOnly = true;
	int numValues = 3;
	bool isNull[3];
	Datum results[3];
	ExtensionExecuteMultiValueQueryWithArgsViaSPI(cmdStr->data, argCount, argTypes,
												  argValues, argNulls, readOnly,
												  SPI_OK_SELECT, results, isNull,
												  numValues);
	if (isNull[0])
	{
		/* No matching index found with the criteria */
		ereport(ERROR,
				(errcode(ERRCODE_DOCUMENTDB_INDEXNOTFOUND),
				 errmsg("cannot find index %s for ns %s.%s",
						searchWithName ? indexOption->name : PgbsonToJsonForLogging(
							indexOption->keyPattern),
						collection->name.databaseName, collection->name.collectionName)));
	}

	IndexDetails indexDetails = { 0 };
	indexDetails.indexId = DatumGetInt32(results[0]);
	indexDetails.indexSpec = *DatumGetIndexSpec(results[1]);
	indexDetails.collectionId = collection->collectionId;

	bool isIndexValid = DatumGetBool(results[2]);

	BoolIndexOption oldHidden = BoolIndexOption_Undefined;
	BoolIndexOption newHidden = BoolIndexOption_Undefined;
	BoolIndexOption oldPrepareUnique = BoolIndexOption_Undefined;
	BoolIndexOption newPrepareUnique = BoolIndexOption_Undefined;
	int oldTTL = 0, newTTL = 0;

	bool updateNeeded = false;

	if ((*specFlags & HAS_INDEX_OPTION_EXPIRE_AFTER_SECONDS) ==
		HAS_INDEX_OPTION_EXPIRE_AFTER_SECONDS)
	{
		if (indexDetails.indexSpec.indexExpireAfterSeconds == NULL)
		{
			/* we doesn't allow non-TTL index to be converted to TTL index */
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INVALIDOPTIONS),
							errmsg("no expireAfterSeconds field to update")));
		}
		oldTTL = *(indexDetails.indexSpec.indexExpireAfterSeconds);
		newTTL = indexOption->expireAfterSeconds;
		if (oldTTL != newTTL)
		{
			*(indexDetails.indexSpec.indexExpireAfterSeconds) = newTTL;
			updateNeeded = true;
		}
	}

	if ((*specFlags & HAS_INDEX_OPTION_HIDDEN) == HAS_INDEX_OPTION_HIDDEN)
	{
		if (!ForceUpdateIndexInline && !IsClusterVersionAtleast(DocDB_V0, 108, 0))
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INVALIDOPTIONS),
							errmsg("hidden index option is not supported yet")));
		}

		if (!isIndexValid)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INVALIDOPTIONS),
							errmsg("cannot modify hidden field of an invalid index")));
		}

		if (strcmp(indexDetails.indexSpec.indexName, "_id_") == 0)
		{
			/* Also ensure that _id index can't be hidden */
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INVALIDOPTIONS),
							errmsg("cannot modify hidden field of the _id_ index")));
		}

		if (indexDetails.indexSpec.indexUnique == BoolIndexOption_True)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INVALIDOPTIONS),
							errmsg("cannot modify hidden field of a unique index")));
		}

		bool currentHidden = GetHiddenFlagFromOptions(
			indexDetails.indexSpec.indexOptions);
		if (currentHidden != indexOption->hidden)
		{
			oldHidden = currentHidden ? BoolIndexOption_True : BoolIndexOption_False;
			newHidden = indexOption->hidden ? BoolIndexOption_True :
						BoolIndexOption_False;

			/* Update the postgres index status */
			UpdatePostgresIndex(collection->collectionId,
								indexDetails.indexId,
								INDEX_METADATA_UPDATE_OPERATION_HIDDEN,
								indexOption->hidden);

			/* update the hidden field in indexOptions */
			indexDetails.indexSpec.indexOptions = UpdateOperationKeyInIndexOptions(
				indexDetails.indexSpec.indexOptions,
				INDEX_METADATA_UPDATE_OPERATION_HIDDEN, indexOption->hidden);
			updateNeeded = true;
		}
	}

	if ((*specFlags & HAS_INDEX_OPTION_PREPARE_UNIQUE) == HAS_INDEX_OPTION_PREPARE_UNIQUE)
	{
		if (!EnablePrepareUnique || (!ForceUpdateIndexInline && !IsClusterVersionAtleast(
										 DocDB_V0, 108, 0)))
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INVALIDOPTIONS),
							errmsg("prepareUnique index option is not supported yet")));
		}

		if (!isIndexValid)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INVALIDOPTIONS),
							errmsg(
								"cannot modify prepareUnique field of an invalid index")));
		}

		if (!indexOption->prepareUnique)
		{
			/* we can support this if needed. */
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INVALIDOPTIONS),
							errmsg("collMod.prepareUnique can only be set to true")));
		}

		bool isUnique = indexDetails.indexSpec.indexUnique == BoolIndexOption_True;

		if (!isUnique)
		{
			bool isBuildAsUnique = false;
			bool currentPrepareUnique = false;
			GetPrepareUniqueFlagsFromOptions(
				indexDetails.indexSpec.indexOptions, &isBuildAsUnique,
				&currentPrepareUnique);
			if (!isBuildAsUnique && !currentPrepareUnique)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INVALIDOPTIONS),
								errmsg(
									"index must be created with buildAsUnique option to be eligible for prepareUnique operation.")));
			}

			if (indexOption->prepareUnique != currentPrepareUnique)
			{
				oldPrepareUnique = currentPrepareUnique ? BoolIndexOption_True :
								   BoolIndexOption_False;
				newPrepareUnique = indexOption->prepareUnique ? BoolIndexOption_True :
								   BoolIndexOption_False;

				UpdatePostgresIndex(collection->collectionId,
									indexDetails.indexId,
									INDEX_METADATA_UPDATE_OPERATION_PREPARE_UNIQUE,
									indexOption->prepareUnique);

				indexDetails.indexSpec.indexOptions = UpdateOperationKeyInIndexOptions(
					indexDetails.indexSpec.indexOptions,
					INDEX_METADATA_UPDATE_OPERATION_PREPARE_UNIQUE,
					indexOption->prepareUnique);

				updateNeeded = true;
			}
		}
	}

	if (!updateNeeded)
	{
		/* No Op */
		return;
	}

	StringInfo updateCmdStr = makeStringInfo();
	appendStringInfo(updateCmdStr,
					 "UPDATE %s.collection_indexes SET index_spec = $1"
					 " WHERE index_id = $2;", ApiCatalogSchemaName);
	int updateArgCount = 2;
	Oid updateArgTypes[2];
	Datum updateArgValues[2];

	updateArgTypes[0] = IndexSpecTypeId();
	updateArgValues[0] = IndexSpecGetDatum(CopyIndexSpec(&indexDetails.indexSpec));

	updateArgTypes[1] = INT8OID;
	updateArgValues[1] = Int64GetDatum(indexDetails.indexId);

	/* all args are non-null */
	char *updateArgNulls = NULL;
	bool updateIsNull = true;
	RunQueryWithCommutativeWrites(updateCmdStr->data,
								  updateArgCount,
								  updateArgTypes, updateArgValues, updateArgNulls,
								  SPI_OK_UPDATE, &updateIsNull);

	if ((*specFlags & HAS_INDEX_OPTION_HIDDEN) == HAS_INDEX_OPTION_HIDDEN)
	{
		PgbsonWriterAppendBool(writer, "hidden_old",
							   10, GetBoolFromBoolIndexOptionDefaultTrue(oldHidden));
		PgbsonWriterAppendBool(writer, "hidden_new",
							   10, GetBoolFromBoolIndexOptionDefaultTrue(newHidden));
	}

	if ((*specFlags & HAS_INDEX_OPTION_EXPIRE_AFTER_SECONDS) ==
		HAS_INDEX_OPTION_EXPIRE_AFTER_SECONDS)
	{
		PgbsonWriterAppendInt64(writer, "expireAfterSeconds_old",
								22, oldTTL);
		PgbsonWriterAppendDouble(writer, "expireAfterSeconds_new",
								 22, (double) newTTL);
	}

	if ((*specFlags & HAS_INDEX_OPTION_PREPARE_UNIQUE) == HAS_INDEX_OPTION_PREPARE_UNIQUE)
	{
		PgbsonWriterAppendBool(writer, "prepareUnique_old",
							   17, GetBoolFromBoolIndexOptionDefaultTrue(
								   oldPrepareUnique));
		PgbsonWriterAppendBool(writer, "prepareUnique_new",
							   17, GetBoolFromBoolIndexOptionDefaultTrue(
								   newPrepareUnique));
	}
}


/*
 * Updates the view definition of an existing collection view
 * With the new view definition provided.
 * Validates the view definition and ensures it is valid first.
 * If it is, replaces the view definition in the target collection.
 */
static void
ModifyViewDefinition(Datum databaseDatum,
					 const MongoCollection *collection,
					 const ViewDefinition *viewDefinition,
					 pgbson_writer *writer)
{
	if (collection->viewDefinition == NULL)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INVALIDOPTIONS),
						errmsg("ns %s.%s is a collection, not a view",
							   collection->name.databaseName,
							   collection->name.collectionName)));
	}

	if (viewDefinition->viewSource != NULL &&
		viewDefinition->pipeline.value_type == BSON_TYPE_EOD)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INVALIDOPTIONS),
						errmsg(
							"Both 'viewOn' and 'pipeline' must be specified when altering a view while authorization is active")));
	}

	ValidateViewDefinition(
		databaseDatum, collection->name.collectionName, viewDefinition);

	/* View definition is valid, now update */
	pgbson *viewDefBson = CreateViewDefinition(viewDefinition);

	StringInfo query = makeStringInfo();
	appendStringInfo(query, "UPDATE %s.collections "
							" set view_definition = $3 WHERE database_name = $1 AND collection_name = $2",
					 ApiCatalogSchemaName);

	Oid argsTypes[3] = { TEXTOID, TEXTOID, BsonTypeId() };
	Datum argValues[3] = {
		databaseDatum, CStringGetTextDatum(collection->name.collectionName),
		PointerGetDatum(viewDefBson)
	};

	int nargs = 3;
	char *argNulls = NULL;
	bool isNullIgnore = false;
	RunQueryWithCommutativeWrites(query->data, nargs, argsTypes, argValues, argNulls,
								  SPI_OK_UPDATE, &isNullIgnore);
}


static bool
GetHiddenFlagFromOptions(pgbson *indexOptions)
{
	if (indexOptions == NULL)
	{
		return false;
	}

	bson_iter_t iter;
	PgbsonInitIterator(indexOptions, &iter);
	while (bson_iter_next(&iter))
	{
		const char *key = bson_iter_key(&iter);
		const bson_value_t *value = bson_iter_value(&iter);
		if (strcmp(key, "hidden") == 0)
		{
			if (value->value_type != BSON_TYPE_BOOL)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_TYPEMISMATCH),
								errmsg(
									"BSON field 'hidden' is the wrong type '%s', expected type 'bool'",
									BsonTypeName(value->value_type))));
			}
			return value->value.v_bool;
		}
	}

	return false;
}


static void
GetPrepareUniqueFlagsFromOptions(pgbson *indexOptions, bool *buildAsUnique,
								 bool *prepareUnique)
{
	if (indexOptions == NULL || buildAsUnique == NULL || prepareUnique == NULL)
	{
		return;
	}

	*buildAsUnique = false;
	*prepareUnique = false;

	bson_iter_t iter;
	PgbsonInitIterator(indexOptions, &iter);
	while (bson_iter_next(&iter))
	{
		const char *key = bson_iter_key(&iter);
		const bson_value_t *value = bson_iter_value(&iter);
		if (strcmp(key, "prepareUnique") == 0)
		{
			if (value->value_type != BSON_TYPE_BOOL)
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_TYPEMISMATCH),
								errmsg(
									"BSON field 'prepareUnique' is the wrong type '%s', expected type 'bool'",
									BsonTypeName(value->value_type))));
			}

			*prepareUnique = value->value.v_bool;
		}
		else if (strcmp(key, "buildAsUnique") == 0)
		{
			if (!BsonTypeIsNumberOrBool(value->value_type))
			{
				ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_TYPEMISMATCH),
								errmsg(
									"BSON field 'buildAsUnique' is the wrong type '%s', expected type 'bool'",
									BsonTypeName(value->value_type))));
			}

			*buildAsUnique = BsonValueAsBool(value);
		}
	}
}


static pgbson *
UpdateOperationKeyInIndexOptions(pgbson *indexOptions, IndexMetadataUpdateOperation
								 operation, bool newValue)
{
	pgbson_writer writer;
	PgbsonWriterInit(&writer);

	bool writtenOperation = false;
	bool removeBuildAsUnique = false;
	const char *opKey = NULL;
	uint32_t opKeyLen = 0;
	switch (operation)
	{
		case INDEX_METADATA_UPDATE_OPERATION_HIDDEN:
		{
			opKey = "hidden";
			opKeyLen = 6;
			break;
		}

		case INDEX_METADATA_UPDATE_OPERATION_PREPARE_UNIQUE:
		{
			opKey = "prepareUnique";
			opKeyLen = 13;
			removeBuildAsUnique = true;
			break;
		}

		default:
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg("unknown index metadata update operation: %d",
								   operation)));
	}

	if (indexOptions != NULL)
	{
		bson_iter_t iter;
		PgbsonInitIterator(indexOptions, &iter);
		while (bson_iter_next(&iter))
		{
			const char *key = bson_iter_key(&iter);
			const bson_value_t *value = bson_iter_value(&iter);
			if (strcmp(key, opKey) == 0)
			{
				writtenOperation = true;

				if (newValue)
				{
					/* Only serialize for true */
					PgbsonWriterAppendBool(&writer, opKey, opKeyLen, newValue);
				}
			}
			else if (removeBuildAsUnique && strcmp(key, "buildAsUnique") == 0)
			{
				/* skip this */
			}
			else
			{
				PgbsonWriterAppendValue(&writer, key, strlen(key), value);
			}
		}
	}

	if (newValue && !writtenOperation)
	{
		/* Only serialize for true */
		PgbsonWriterAppendBool(&writer, opKey, opKeyLen, newValue);
	}

	if (IsPgbsonWriterEmptyDocument(&writer))
	{
		/* No options */
		return NULL;
	}

	return PgbsonWriterGetPgbson(&writer);
}


static void
UpdatePostgresIndex(uint64_t collectionId, int indexId, int operation, bool value)
{
	if (ForceUpdateIndexInline)
	{
		bool ignoreMissingShards = false;
		UpdatePostgresIndexCore(collectionId, indexId, operation, value,
								ignoreMissingShards);
	}
	else
	{
		UpdatePostgresIndexWithOverride(collectionId, indexId, operation, value,
										UpdatePostgresIndexOverride);
	}
}


static void
UpdatePostgresIndexOverride(uint64_t collectionId, int indexId, int operation, bool value)
{
	bool ignoreMissingShards = false;
	UpdatePostgresIndexCore(collectionId, indexId, operation, value, ignoreMissingShards);
}


void
UpdatePostgresIndexCore(uint64_t collectionId, int indexId, IndexMetadataUpdateOperation
						operation, bool value, bool
						ignoreMissingShards)
{
	/* First get the OID of the index */
	char postgresIndexName[NAMEDATALEN] = { 0 };
	pg_sprintf(postgresIndexName, DOCUMENT_DATA_TABLE_INDEX_NAME_FORMAT, indexId);
	Oid indexOid = get_relname_relid(postgresIndexName, ApiDataNamespaceOid());

	List *indexOidList = NIL;
	indexOidList = lappend_oid(indexOidList, indexOid);

	/* Add any additional shard OIDs needed for this */
	indexOidList = list_concat(indexOidList,
							   GetShardIndexOids(collectionId, indexId,
												 ignoreMissingShards));

	switch (operation)
	{
		case INDEX_METADATA_UPDATE_OPERATION_HIDDEN:
		{
			UpdatePostgresIndexesForHide(indexOidList, value);
			break;
		}

		case INDEX_METADATA_UPDATE_OPERATION_PREPARE_UNIQUE:
		{
			UpdatePostgresIndexesForPrepareUnique(indexOidList, value);
			break;
		}

		default:
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg("unknown index metadata update operation: %d",
								   operation)));
	}
}


static void
UpdatePostgresIndexesForHide(List *indexOids, bool hidden)
{
	ListCell *cell;
	foreach(cell, indexOids)
	{
		Oid currentIndexOid = lfirst_oid(cell);
		bool readOnly = false;
		int numArgs = 2;
		Datum args[2] = { BoolGetDatum(!hidden), ObjectIdGetDatum(currentIndexOid) };
		Oid argTypes[2] = { BOOLOID, OIDOID };


		/* all args are non-null */
		char *argNulls = NULL;
		bool resultIsNull;

		/* Update pg_class to set the indisvalid which removes it from query but not writes */
		ExtensionExecuteQueryWithArgsViaSPI(
			"UPDATE pg_catalog.pg_index SET indisvalid = $1 WHERE indexrelid = $2 RETURNING indexrelid",
			numArgs,
			argTypes,
			args,
			argNulls,
			readOnly,
			SPI_OK_UPDATE_RETURNING,
			&resultIsNull);

		if (resultIsNull)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg("failed to update hidden status for index oid %u",
								   currentIndexOid)));
		}
	}
}


/* Given a list of indexOids it updates them and registers a bson exclusion constraint for the owning table in pg_constraint catalog.
 * This is done using the CreateConstraintEntry function which will also update the pg_depend catalog to mark the table as the owner of the constraint.
 * If this is successful, the index will be marked as an exclusion index in the pg_index catalog.
 */
static void
UpdatePostgresIndexesForPrepareUnique(List *indexOids, bool prepareUnique)
{
	ListCell *cell;
	Oid namespace = ApiDataNamespaceOid();

	/* Unique indexes always have 2 exclusion operators, the bson_unique_index_equal and the bson_unique_shard_path_equal operators. */
	Oid excludeOperators[2];
	excludeOperators[0] = BsonUniqueIndexEqualOperatorId();
	excludeOperators[1] = BsonUniqueShardPathEqualOperatorId();

	if (!prepareUnique)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INVALIDOPTIONS),
						errmsg("prepareUnique can only be set to true")));
	}

	foreach(cell, indexOids)
	{
		Oid currentIndexOid = lfirst_oid(cell);
		Relation indexRel = index_open(currentIndexOid, AccessShareLock);
		IndexInfo *indexInfo = BuildIndexInfo(indexRel);
		const char *indexName = RelationGetRelationName(indexRel);
		Oid shardTableOid = indexRel->rd_index->indrelid;
		RelationClose(indexRel);

		if (indexInfo->ii_NumIndexAttrs != 2 || indexInfo->ii_NumIndexKeyAttrs != 2)
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg(
								"got an unexpected number of index attributes for a prepareUnique index with oid: %u and name: %s",
								currentIndexOid, indexName)));
		}


		CreateConstraintEntry(indexName, /* constraintName */
							  namespace, /* constraintNamespace */
							  CONSTRAINT_EXCLUSION, /* constraintType */
							  false, /* isDeferrable */
							  false, /* isDeferred */
#if PG_VERSION_NUM >= 180000
							  true, /* isEnforced */
#endif
							  true, /* isValidated */
							  InvalidOid, /* parentConstraintId */
							  shardTableOid, /* relationId */
							  indexInfo->ii_IndexAttrNumbers, /* constraintKey */
							  indexInfo->ii_NumIndexKeyAttrs, /* constraintKeyLength */
							  indexInfo->ii_NumIndexAttrs, /* numKeyAttrs */
							  InvalidOid, /* domainId */
							  currentIndexOid, /* constraintIndexId */
							  InvalidOid, /* foreignRelId */
							  NULL, /* foreignKey */
							  NULL, /* primaryEqOp */
							  NULL, /* primaryPrimaryEqOp */
							  NULL, /* foreignForeignEqOp */
							  0, /* foreignDeleteType */
							  ' ', /* foreignUpdateType */
							  ' ', /* foreignMatchType */
							  NULL, /* constraintBin */
							  0, /* constraintBinLength */
							  ' ', /* constraintSource */
							  excludeOperators, /* exclusionOp */
							  NULL, /* constraintPeriod */
							  NULL, /* constraintWithoutOverlaps */
							  true, /* isLocal */
							  0, /* inheritCount */
							  true, /* noInherit */
#if PG_VERSION_NUM >= 180000
							  false, /* conPeriod */
#endif
							  false /* isInternal */);

		RegisterExclusionInPgIndexCatalog(currentIndexOid);
	}
}


static void
RegisterExclusionInPgIndexCatalog(Oid indexoid)
{
	bool readOnly = false;
	int numArgs = 1;
	Datum args[1] = { ObjectIdGetDatum(indexoid) };
	Oid argTypes[1] = { OIDOID };


	/* all args are non-null */
	char *argNulls = NULL;
	bool resultIsNull;

	/* Update pg_index to set the indisexclusion to true */
	ExtensionExecuteQueryWithArgsViaSPI(
		"UPDATE pg_catalog.pg_index SET indisexclusion = true WHERE indexrelid = $1 RETURNING indexrelid",
		numArgs,
		argTypes,
		args,
		argNulls,
		readOnly,
		SPI_OK_UPDATE_RETURNING,
		&resultIsNull);

	if (resultIsNull)
	{
		ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
						errmsg(
							"failed to update indisexclusion status in pg_index for index oid %u",
							indexoid)));
	}
}
