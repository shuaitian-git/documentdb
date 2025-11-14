/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/bson_init.h
 *
 * Exports related to shared library initialization for the bson type.
 *
 *-------------------------------------------------------------------------
 */
#ifndef BSON_INIT_H
#define BSON_INIT_H

#include <stdbool.h>

void InstallBsonMemVTables(void);

void InitDocumentDBCoreConfigurations(const char *prefix);

extern bool BsonTextUseJsonRepresentation;
extern bool EnableCollation;
extern bool SkipBsonArrayTraverseOptimization;

#endif
