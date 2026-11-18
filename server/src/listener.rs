//! TLS listener: binds the port, accepts TCP connections, runs the TLS
//! handshake (tokio-rustls, mutual TLS) and spawns one session task per
//! connection. Stops on Ctrl-C / SIGTERM.
