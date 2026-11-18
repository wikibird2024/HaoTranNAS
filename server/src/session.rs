//! One task per connection: reads frames, drives the core session state
//! machine, enforces the handshake and idle timeouts, passes requests to the
//! handlers and writes replies in order.
