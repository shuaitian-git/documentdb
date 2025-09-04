/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/lib.rs
 *
 *-------------------------------------------------------------------------
 */

use either::Either::{Left, Right};
use openssl::ssl::{
    Ssl, SslAcceptor, SslAcceptorBuilder, SslMethod, SslOptions, SslSessionCacheMode,
    SslVerifyMode, SslVersion,
};
use rand::Rng;
use socket2::TcpKeepalive;
use std::{pin::Pin, sync::Arc, time::Duration};
use tokio::{
    io::AsyncWriteExt,
    net::{TcpListener, TcpStream},
};
use tokio_openssl::SslStream;
use tokio_util::sync::CancellationToken;
use uuid::Builder;

use crate::{
    configuration::CertificateProvider,
    context::{ConnectionContext, RequestContext, ServiceContext},
    error::{DocumentDBError, ErrorCode, Result},
    postgres::PgDataClient,
    protocol::header::Header,
    requests::{request_tracker::RequestTracker, Request, RequestIntervalKind},
    responses::{CommandError, Response},
    telemetry::TelemetryProvider,
};

pub use crate::postgres::QueryCatalog;

// TCP keepalive configuration constants
const TCP_KEEPALIVE_TIME_SECS: u64 = 180;
const TCP_KEEPALIVE_INTERVAL_SECS: u64 = 60;

pub mod auth;
pub mod bson;
pub mod configuration;
pub mod context;
pub mod error;
pub mod explain;
pub mod postgres;
pub mod processor;
pub mod protocol;
pub mod requests;
pub mod responses;
pub mod shutdown_controller;
pub mod startup;
pub mod telemetry;

/// Runs the DocumentDB gateway server, accepting and handling incoming connections.
///
/// This function sets up a TCP listener and SSL context, then continuously accepts
/// new connections until the cancellation token is triggered. Each connection is
/// handled in a separate async task.
///
/// # Arguments
///
/// * `service_context` - The service configuration and context
/// * `telemetry` - Optional telemetry provider for metrics and logging
/// * `token` - Cancellation token to gracefully shutdown the gateway
/// * `cipher_map` - Optional function to map cipher names to numeric codes
///
/// # Returns
///
/// Returns `Ok(())` on successful shutdown, or an error if the server fails to start
/// or encounters a fatal error during operation.
///
/// # Errors
///
/// This function will return an error if:
/// * Failed to bind to the specified address and port
/// * SSL context creation fails
/// * Any other fatal gateway initialization error occurs
pub async fn run_gateway<T>(
    service_context: ServiceContext,
    telemetry: Option<Box<dyn TelemetryProvider>>,
    token: CancellationToken,
    cipher_map: Option<fn(Option<&str>) -> i32>,
) -> Result<()>
where
    T: PgDataClient,
{
    // TCP configuration part
    let tcp_listener = TcpListener::bind(format!(
        "{}:{}",
        if service_context.setup_configuration().use_local_host() {
            "127.0.0.1"
        } else {
            "[::]"
        },
        service_context.setup_configuration().gateway_listen_port(),
    ))
    .await?;

    let tcp_keepalive = TcpKeepalive::new()
        .with_time(Duration::from_secs(TCP_KEEPALIVE_TIME_SECS))
        .with_interval(Duration::from_secs(TCP_KEEPALIVE_INTERVAL_SECS));

    // Listen for new tcp connections until token is not cancelled
    loop {
        match handle_connection::<T>(
            service_context.clone(),
            telemetry.clone(),
            (&tcp_listener, &tcp_keepalive),
            // populate a child cancellation token so we can't shutdown gateway from the connection layer,
            // instead we will close connections upon gateway shutdown
            token.child_token(),
            cipher_map,
        )
        .await
        {
            Err(e) => log::error!("[], Failed to accept a connection: {:?}", e),
            Ok(true) => continue,
            Ok(false) => break Ok(()),
        }
    }
}

/// Creates a secure SSL/TLS stream wrapper around an existing TCP stream.
///
/// This function takes an SSL context and a TCP stream, combining them to establish
/// a secure communication channel. The resulting `SslStream` provides encrypted
/// communication over the underlying TCP connection.
///
/// # Arguments
///
/// * `ssl_ctx` - The SSL context containing TLS configuration and certificates
/// * `stream` - The underlying TCP stream to be wrapped with SSL/TLS encryption
///
/// # Returns
///
/// Returns a `Result` containing the configured `SslStream` on success, or an error
/// if the SSL stream creation fails.
///
/// # Errors
///
/// This function will return an error if:
/// * The SSL handshake fails
/// * The underlying stream is in an invalid state
/// * Certificate validation fails
/// * Any other SSL/TLS configuration issues occur
async fn convert_to_ssl_stream(
    ssl_acceptor: Arc<SslAcceptor>,
    stream: TcpStream,
) -> Result<SslStream<TcpStream>> {
    // for more context see https://github.com/tokio-rs/tokio-openssl/blob/master/src/test.rs
    let ssl_session = Ssl::new(ssl_acceptor.context())?;
    let mut ssl_stream = SslStream::new(ssl_session, stream)?;
    Pin::new(&mut ssl_stream).accept().await?;

    Ok(ssl_stream)
}

/// Creates an SSL acceptor builder configured for the DocumentDB gateway.
///
/// This function sets up an SSL acceptor with appropriate security settings
/// for handling incoming TLS connections. It uses Mozilla's intermediate
/// TLS configuration to balance security and compatibility.
///
/// # Arguments
///
/// * `cert_provider` - Provider containing the certificate bundle (certificate, CA chain, private key)
///
/// # Returns
///
/// Returns a configured `SslAcceptorBuilder` ready to build an SSL acceptor.
///
/// # Errors
///
/// This function will return an error if:
/// * Certificate or private key loading fails
/// * SSL context configuration fails
/// * Certificate validation fails
/// * TLS version configuration is invalid
pub fn create_ssl_acceptor_builder(
    cert_provider: &CertificateProvider,
) -> Result<SslAcceptorBuilder> {
    // we use intermediate and not modern acceptor because we support TLS 1.2 clients
    // for more details on Mozilla's TLS recommendation see https://wiki.mozilla.org/Security/Server_Side_TLS
    // TODO: use different SslAcceptor depending on conditional compiling flags as part of the build script
    // currently we're forced by the host OS not to use v5 version
    let mut ssl_acceptor = SslAcceptor::mozilla_intermediate(SslMethod::tls_server())?;

    ssl_acceptor.set_private_key(cert_provider.bundle().private_key())?;
    ssl_acceptor.set_certificate(&cert_provider.bundle().certificate())?;

    for ca_cert in cert_provider.bundle().ca_chain() {
        ssl_acceptor.cert_store_mut().add_cert(ca_cert.clone())?;
    }

    // SSL server settings
    // we currently don't expect for all of the clients to have auth certs
    ssl_acceptor.set_verify(SslVerifyMode::NONE);
    ssl_acceptor.set_session_cache_mode(SslSessionCacheMode::SERVER);
    ssl_acceptor.set_min_proto_version(Some(SslVersion::TLS1_2))?;
    ssl_acceptor.set_max_proto_version(Some(SslVersion::TLS1_3))?;

    // SSL server options
    // we currently don't support session tickets for session resumption
    ssl_acceptor.set_options(SslOptions::NO_TICKET);
    ssl_acceptor.set_options(SslOptions::CIPHER_SERVER_PREFERENCE | SslOptions::PRIORITIZE_CHACHA);
    // since mozilla intermediate removes the TLS 1.3 option we need to put it back, since we support TLS 1.3
    // https://github.com/sfackler/rust-openssl/blob/3c2768548ff92e76e90fcb2b9c41a669046a6d5f/openssl/src/ssl/connector.rs#L282C1-L283C1
    ssl_acceptor.clear_options(SslOptions::NO_TLSV1_3);

    Ok(ssl_acceptor)
}

async fn handle_connection<T>(
    service_context: ServiceContext,
    telemetry: Option<Box<dyn TelemetryProvider>>,
    tcp_bundle: (&TcpListener, &TcpKeepalive),
    child_token: CancellationToken,
    cipher_map: Option<fn(Option<&str>) -> i32>,
) -> Result<bool>
where
    T: PgDataClient,
{
    let (tcp_listener, tcp_keepalive) = tcp_bundle;

    // SSL configuration part
    let cert_provider = service_context.get_certificate_provider();
    let ssl_ctx_builder = create_ssl_acceptor_builder(cert_provider)?;
    let ssl_acceptor = Arc::new(ssl_ctx_builder.build());

    // Wait for either a new connection or cancellation
    tokio::select! {
        // Receive the connection and spawn a thread which handles it
        stream_and_address = tcp_listener.accept() => {
            let (tcp_stream, peer_address) = stream_and_address?;
            log::info!("New TCP connection established.");

            // Configure TCP stream
            tcp_stream.set_nodelay(true)?;
            socket2::SockRef::from(&tcp_stream).set_tcp_keepalive(tcp_keepalive)?;

            let acceptor = Arc::clone(&ssl_acceptor);
            match convert_to_ssl_stream(acceptor, tcp_stream).await {
                Ok(ssl_stream) => {
                    // transition from service (gateway) level to the connection level
                    tokio::spawn(async move {
                        tokio::select! {
                            mut conn_ctx = ConnectionContext::new(
                                service_context,
                                telemetry,
                                peer_address.to_string(),
                                ssl_stream.ssl().version_str().to_string()
                            ) => {
                                conn_ctx.cipher_type = match cipher_map {
                                    Some(map) => map(ssl_stream.ssl().current_cipher().map(|cipher| cipher.name())),
                                    None => 0,
                                };

                                handle_stream::<T>(ssl_stream, conn_ctx).await;
                            }
                            _ = child_token.cancelled() => {}
                        }
                    });
                    Ok(true)
                }
                Err(e) => {
                    log::error!("Failed to create TLS connection: {}", e);
                    Err(DocumentDBError::internal_error(format!(
                        "SSL handshake failed: {}",
                        e
                    )))
                }
            }
        }
        _ = child_token.cancelled() => {
            Ok(false)
        }
    }
}

/// Generates a unique activity ID for request tracking.
///
/// Creates a UUID-based activity ID by combining random bytes with the request ID.
/// The first 12 bytes are random, and the last 4 bytes contain the request ID
/// in big-endian format.
///
/// # Arguments
///
/// * `request_id` - The numeric request identifier to embed in the activity ID
///
/// # Returns
///
/// Returns a hyphenated UUID string suitable for request tracking and correlation.
pub fn get_activity_id(request_id: i32) -> String {
    let mut activity_id_bytes = [0u8; 16];
    let mut rng = rand::thread_rng();
    rng.fill(&mut activity_id_bytes[..12]);
    activity_id_bytes[12..].copy_from_slice(&request_id.to_be_bytes());
    let activity_id = Builder::from_random_bytes(activity_id_bytes).into_uuid();
    activity_id.hyphenated().to_string()
}

async fn handle_stream<T>(
    mut stream: SslStream<TcpStream>,
    mut connection_context: ConnectionContext,
) where
    T: PgDataClient,
{
    loop {
        match protocol::reader::read_header(&mut stream).await {
            Ok(Some(header)) => {
                let activity_id = get_activity_id(header.request_id);

                if let Err(e) =
                    handle_message::<T>(&mut connection_context, &header, &mut stream, &activity_id)
                        .await
                {
                    if let Err(e) = log_and_write_error(
                        &connection_context,
                        &header,
                        &e,
                        None,
                        &mut stream,
                        None,
                        &mut RequestTracker::new(),
                        &activity_id,
                    )
                    .await
                    {
                        log::error!(activity_id = activity_id.as_str(); "[{}] Couldn't reply with error {:?}", header.request_id, e);
                        break;
                    }
                }
            }

            Ok(None) => {
                log::info!("[{}] Connection closed", connection_context.connection_id);
                break;
            }

            // Failed to read a header, can't provide request id in the error so use connection id instead.
            Err(e) => {
                if let Err(e) = responses::writer::write_error_without_header(
                    &connection_context,
                    e,
                    &mut stream,
                )
                .await
                {
                    log::warn!(
                        "[C:{}] Couldn't reply with error {:?}",
                        connection_context.connection_id,
                        e
                    );
                    break;
                }
            }
        }
    }
}

async fn get_response<T>(
    request_context: &mut RequestContext<'_>,
    connection_context: &mut ConnectionContext,
) -> Result<Response>
where
    T: PgDataClient,
{
    let interop_and_sdk_start = request_context.tracker.start_timer();

    if !connection_context.auth_state.authorized
        || request_context.payload.request_type().handle_with_auth()
    {
        let response = auth::process::<T>(connection_context, request_context).await?;
        return Ok(response);
    }

    // Once authorized, make sure that there is a pool of pg clients for the user/password.
    connection_context.allocate_data_pool().await?;

    let service_context = Arc::clone(&connection_context.service_context);
    let data_client = T::new_authorized(&service_context, &connection_context.auth_state).await?;

    // Process the actual request
    let response =
        processor::process_request(request_context, connection_context, data_client).await?;

    request_context
        .tracker
        .record_duration(RequestIntervalKind::InteropAndSdk, interop_and_sdk_start);

    Ok(response)
}

async fn handle_message<T>(
    connection_context: &mut ConnectionContext,
    header: &Header,
    stream: &mut SslStream<TcpStream>,
    activity_id: &str,
) -> Result<()>
where
    T: PgDataClient,
{
    // Read the request message off the stream
    let mut request_tracker = RequestTracker::new();

    let buffer_read_start = request_tracker.start_timer();
    let message = protocol::reader::read_request(header, stream).await?;

    if connection_context
        .dynamic_configuration()
        .send_shutdown_responses()
        .await
    {
        return Err(DocumentDBError::documentdb_error(
            ErrorCode::ShutdownInProgress,
            "Graceful shutdown requested".to_string(),
        ));
    }

    request_tracker.record_duration(RequestIntervalKind::BufferRead, buffer_read_start);

    let handle_request_start = request_tracker.start_timer();
    let format_request_start = request_tracker.start_timer();
    let request = protocol::reader::parse_request(&message, connection_context).await?;
    request_tracker.record_duration(RequestIntervalKind::FormatRequest, format_request_start);

    let request_info = request.extract_common()?;
    let mut request_context = RequestContext {
        activity_id,
        payload: &request,
        info: &request_info,
        tracker: &mut request_tracker,
    };

    let mut collection = String::new();
    let result = handle_request::<T>(
        connection_context,
        header,
        &mut request_context,
        stream,
        &mut collection,
    )
    .await;

    request_context
        .tracker
        .record_duration(RequestIntervalKind::HandleRequest, handle_request_start);

    if connection_context
        .dynamic_configuration()
        .enable_verbose_logging_in_gateway()
        .await
    {
        log::info!(
            activity_id = activity_id;
            "Latency for Mongo Request with ActivityId: {}, BufferRead={}ms, HandleRequest={}ms, FormatRequest={}ms, ProcessRequest={}ms, PostgresBeginTransaction={}ms, PostgresSetStatementTimeout={}ms, PostgresTransactionCommit={}ms, HandleResponse={}ms",
            activity_id,
            request_context.tracker.get_interval_elapsed_time(RequestIntervalKind::BufferRead),
            request_context.tracker.get_interval_elapsed_time(RequestIntervalKind::HandleRequest),
            request_context.tracker.get_interval_elapsed_time(RequestIntervalKind::FormatRequest),
            request_context.tracker.get_interval_elapsed_time(RequestIntervalKind::ProcessRequest),
            request_context.tracker.get_interval_elapsed_time(RequestIntervalKind::PostgresBeginTransaction),
            request_context.tracker.get_interval_elapsed_time(RequestIntervalKind::PostgresSetStatementTimeout),
            request_context.tracker.get_interval_elapsed_time(RequestIntervalKind::PostgresTransactionCommit),
            request_context.tracker.get_interval_elapsed_time(RequestIntervalKind::HandleResponse)
        );
    }

    // Errors in request handling are handled explicitly so that telemetry can have access to the request
    // Returns Ok afterwards so that higher level error telemetry is not invoked.
    if let Err(e) = result {
        if let Err(e) = log_and_write_error(
            connection_context,
            header,
            &e,
            Some(request_context.payload),
            stream,
            Some(collection),
            request_context.tracker,
            activity_id,
        )
        .await
        {
            log::error!(activity_id = activity_id; "[{}] Couldn't reply with error {:?}", header.request_id, e);
        }
    }

    Ok(())
}

async fn handle_request<T>(
    connection_context: &mut ConnectionContext,
    header: &Header,
    request_context: &mut RequestContext<'_>,
    stream: &mut SslStream<TcpStream>,
    collection: &mut String,
) -> Result<()>
where
    T: PgDataClient,
{
    *collection = request_context.info.collection().unwrap_or("").to_string();

    // Process the response for the message
    let response = get_response::<T>(request_context, connection_context).await?;

    let handle_response_start = request_context.tracker.start_timer();

    // Write the response back to the stream
    if connection_context.requires_response {
        responses::writer::write(header, &response, stream).await?;
        stream.flush().await?;
    }

    if let Some(telemetry) = connection_context.telemetry_provider.as_ref() {
        telemetry
            .emit_request_event(
                connection_context,
                header,
                Some(request_context.payload),
                Left(&response),
                collection.to_string(),
                request_context.tracker,
                request_context.activity_id,
            )
            .await;
    }

    request_context
        .tracker
        .record_duration(RequestIntervalKind::HandleResponse, handle_response_start);

    Ok(())
}

#[expect(clippy::too_many_arguments)]
async fn log_and_write_error(
    connection_context: &ConnectionContext,
    header: &Header,
    e: &DocumentDBError,
    request: Option<&Request<'_>>,
    stream: &mut SslStream<TcpStream>,
    collection: Option<String>,
    request_tracker: &mut RequestTracker,
    activity_id: &str,
) -> Result<()> {
    let error_response = CommandError::from_error(connection_context, e).await;
    let response = error_response.to_raw_document_buf()?;

    responses::writer::write_response(header, &response, stream).await?;

    log::error!(activity_id = activity_id; "Request failure: {e}");

    if let Some(telemetry) = connection_context.telemetry_provider.as_ref() {
        telemetry
            .emit_request_event(
                connection_context,
                header,
                request,
                Right((&error_response, response.as_bytes().len())),
                collection.unwrap_or_default(),
                request_tracker,
                activity_id,
            )
            .await;
    }

    Ok(())
}
