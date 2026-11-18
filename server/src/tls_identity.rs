//! The server's own TLS identity: loads `tls/cert.pem` and `tls/key.pem`,
//! or creates a self-signed pair on `init`. Prints its fingerprint for
//! clients to pin.
