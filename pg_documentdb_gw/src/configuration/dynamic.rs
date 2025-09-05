/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/configuration/dynamic.rs
 *
 *-------------------------------------------------------------------------
 */

use std::fmt::Debug;

use async_trait::async_trait;
use bson::RawBson;

use crate::startup::{AUTHENTICATION_MAX_CONNECTIONS, SYSTEM_REQUESTS_MAX_CONNECTIONS};

use super::version::Version;

pub const POSTGRES_RECOVERY_KEY: &str = "IsPostgresInRecovery";

/// Used for configurations which can change during runtime.
#[async_trait]
pub trait DynamicConfiguration: Send + Sync + Debug {
    async fn get_str(&self, key: &str) -> Option<String>;
    async fn get_bool(&self, key: &str, default: bool) -> bool;
    async fn get_i32(&self, key: &str, default: i32) -> i32;
    async fn equals_value(&self, key: &str, value: &str) -> bool;
    fn topology(&self) -> RawBson;
    async fn enable_developer_explain(&self) -> bool;
    async fn max_connections(&self) -> usize;

    // Needed to downcast to concrete type
    fn as_any(&self) -> &dyn std::any::Any;

    async fn enable_change_streams(&self) -> bool {
        self.get_bool("enableChangeStreams", false).await
    }

    async fn enable_connection_status(&self) -> bool {
        self.get_bool("enableConnectionStatus", false).await
    }

    async fn enable_verbose_logging_gateway(&self) -> bool {
        self.get_bool("enableVerboseLoggingGateway", false).await
    }

    async fn index_build_sleep_milli_secs(&self) -> i32 {
        self.get_i32("indexBuildWaitSleepTimeInMilliSec", 1000)
            .await
    }

    async fn is_postgres_writable(&self) -> bool {
        !self.get_bool(POSTGRES_RECOVERY_KEY, false).await
    }

    async fn is_read_only_for_disk_full(&self) -> bool {
        self.get_bool("default_transaction_read_only", false).await
    }

    async fn is_replica_cluster(&self) -> bool {
        (self.get_bool(POSTGRES_RECOVERY_KEY, false).await
            && self
                .equals_value("citus.use_secondary_nodes", "always")
                .await)
            || self.get_bool("simulateReadReplica", false).await
    }

    async fn max_write_batch_size(&self) -> i32 {
        self.get_i32("maxWriteBatchSize", 100000).await
    }

    async fn read_only(&self) -> bool {
        self.get_bool("readOnly", false).await
    }

    async fn send_shutdown_responses(&self) -> bool {
        self.get_bool("SendShutdownResponses", false).await
    }

    async fn server_version(&self) -> Version {
        self.get_str("serverVersion")
            .await
            .as_deref()
            .and_then(Version::parse)
            .unwrap_or(Version::Seven)
    }

    async fn system_connection_budget(&self) -> usize {
        let min_system_connections =
            (SYSTEM_REQUESTS_MAX_CONNECTIONS + AUTHENTICATION_MAX_CONNECTIONS) as i32;
        let system_connection_budget = self
            .get_i32("systemConnectionBudget", min_system_connections)
            .await;
        system_connection_budget as usize
    }

    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "")
    }
}
