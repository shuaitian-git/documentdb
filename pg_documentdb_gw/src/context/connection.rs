/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/context/connection.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{
    sync::{
        atomic::{AtomicI64, Ordering},
        Arc,
    },
    time::Instant,
};

use bson::RawDocumentBuf;
use openssl::ssl::SslRef;

use crate::{
    auth::AuthState,
    configuration::DynamicConfiguration,
    context::{Cursor, CursorStoreEntry, ServiceContext},
    error::{DocumentDBError, Result},
    postgres::Connection,
    telemetry::TelemetryProvider,
};

pub struct ConnectionContext {
    pub start_time: Instant,
    pub connection_id: i64,
    pub service_context: Arc<ServiceContext>,
    pub auth_state: AuthState,
    pub requires_response: bool,
    pub client_information: Option<RawDocumentBuf>,
    pub transaction: Option<(Vec<u8>, i64)>,
    pub telemetry_provider: Option<Box<dyn TelemetryProvider>>,
    pub ip_address: String,
    pub cipher_type: i32,
    pub ssl_protocol: String,
}

static CONNECTION_ID: AtomicI64 = AtomicI64::new(0);

impl ConnectionContext {
    pub async fn get_cursor(&self, id: i64, username: &str) -> Option<CursorStoreEntry> {
        // If there is a transaction, get the cursor to its store
        if let Some((session_id, _)) = self.transaction.as_ref() {
            let transaction_store = self.service_context.transaction_store();
            if let Some((_, transaction)) =
                transaction_store.transactions.read().await.get(session_id)
            {
                return transaction
                    .cursors
                    .get_cursor((id, username.to_string()))
                    .await;
            }
        }

        self.service_context.get_cursor(id, username).await
    }

    pub async fn add_cursor(
        &self,
        conn: Option<Arc<Connection>>,
        cursor: Cursor,
        username: &str,
        db: &str,
        collection: &str,
        session_id: Option<Vec<u8>>,
    ) {
        let key = (cursor.cursor_id, username.to_string());
        let value = CursorStoreEntry {
            conn,
            cursor,
            db: db.to_string(),
            collection: collection.to_string(),
            timestamp: Instant::now(),
            session_id,
        };

        // If there is a transaction, add the cursor to its store
        if let Some((session_id, _)) = self.transaction.as_ref() {
            let transaction_store = self.service_context.transaction_store();
            if let Some((_, transaction)) =
                transaction_store.transactions.read().await.get(session_id)
            {
                transaction.cursors.add_cursor(key, value).await;
                return;
            }
        }

        // Otherwise add it to the service context
        self.service_context.add_cursor(key, value).await
    }

    pub fn new(
        service_context: ServiceContext,
        telemetry_provider: Option<Box<dyn TelemetryProvider>>,
        ip_address: String,
        tls_config: Option<&SslRef>,
    ) -> Self {
        let connection_id = CONNECTION_ID.fetch_add(1, Ordering::Relaxed);
        let tls_provider = service_context.tls_provider();

        let cipher_type = tls_config
            .map(|tls| tls_provider.ciphersuite_to_i32(tls.current_cipher()))
            .unwrap_or_default();

        let ssl_protocol = tls_config
            .map(|tls| tls.version_str().to_string())
            .unwrap_or_default();

        ConnectionContext {
            start_time: Instant::now(),
            connection_id,
            service_context: Arc::new(service_context),
            auth_state: AuthState::new(),
            requires_response: true,
            client_information: None,
            transaction: None,
            telemetry_provider,
            ip_address,
            cipher_type,
            ssl_protocol,
        }
    }

    pub async fn allocate_data_pool(&self) -> Result<()> {
        let username = self.auth_state.username()?;
        let password = self
            .auth_state
            .password
            .as_ref()
            .ok_or(DocumentDBError::internal_error(
                "Password is missing on pg connection acquisition".to_string(),
            ))?;

        self.service_context
            .allocate_data_pool(username, password)
            .await
    }

    pub fn dynamic_configuration(&self) -> Arc<dyn DynamicConfiguration> {
        self.service_context.dynamic_configuration()
    }
}
