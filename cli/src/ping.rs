//! `ping`: connect, `Hello`, then `Ping` → `Pong` `count` times, printing
//! the round-trip time of each.

use std::time::Instant;

use haotrannas_core::message::Message;

use crate::connection::{ClientError, Transport, open_connection, unexpected_reply};

/// Device name the cli gives in `Hello`.
const CLI_DEVICE_NAME: &str = "haotrannas-cli";

/// Runs the ping and prints one line per step on stdout.
pub async fn run_ping(
    server_address: &str,
    transport: &Transport,
    ping_count: u32,
) -> Result<(), ClientError> {
    let mut connection = open_connection(server_address, transport, CLI_DEVICE_NAME).await?;
    let server_hello = &connection.server_hello;
    println!(
        "connected: {} ({}), device {}",
        server_hello.server_name, server_hello.server_software, server_hello.device_id
    );
    for _ in 0..ping_count {
        let sent_at = Instant::now();
        match connection.request(&Message::Ping).await? {
            Message::Pong => {
                let round_trip_ms = sent_at.elapsed().as_secs_f64() * 1000.0;
                println!("Pong in {round_trip_ms:.2} ms");
            }
            other => return Err(unexpected_reply(&other)),
        }
    }
    connection.close().await;
    Ok(())
}
