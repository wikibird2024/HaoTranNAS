/// Where a server can be reached: an IP address and a TCP port. Clients
/// connect by IP (spec §1), so no host names here.
library;

/// The server's default TLS port (spec §1).
const int defaultServerPort = 47100;

final class ServerAddress {
  const ServerAddress(this.host, [this.port = defaultServerPort]);

  /// `192.168.1.5:47100` or `192.168.1.5` (default port). Null when the
  /// text is not an address and a port in 1..65535. An IPv6 address needs
  /// brackets with a port: `[fd00::5]:47100`.
  static ServerAddress? tryParse(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final String host;
    String? portText;
    if (trimmed.startsWith('[')) {
      final closeIndex = trimmed.indexOf(']');
      if (closeIndex < 0) return null;
      host = trimmed.substring(1, closeIndex);
      final rest = trimmed.substring(closeIndex + 1);
      if (rest.isNotEmpty) {
        if (!rest.startsWith(':')) return null;
        portText = rest.substring(1);
      }
    } else if (':'.allMatches(trimmed).length == 1) {
      final separatorIndex = trimmed.indexOf(':');
      host = trimmed.substring(0, separatorIndex);
      portText = trimmed.substring(separatorIndex + 1);
    } else {
      host = trimmed;
    }
    if (host.isEmpty || host.contains(RegExp(r'\s'))) return null;
    final port = portText == null ? defaultServerPort : int.tryParse(portText);
    if (port == null || port < 1 || port > 65535) return null;
    return ServerAddress(host, port);
  }

  final String host;
  final int port;

  @override
  bool operator ==(Object other) =>
      other is ServerAddress && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => host.contains(':') ? '[$host]:$port' : '$host:$port';
}

/// The addresses remembered for the paired server (architecture §6):
/// the last LAN address that worked and the WireGuard address the user
/// set. mDNS results are not stored; they are asked for each time.
final class KnownAddresses {
  const KnownAddresses({this.lastLan, this.wireGuard});

  final ServerAddress? lastLan;
  final ServerAddress? wireGuard;

  KnownAddresses withLastLan(ServerAddress? address) =>
      KnownAddresses(lastLan: address, wireGuard: wireGuard);

  KnownAddresses withWireGuard(ServerAddress? address) =>
      KnownAddresses(lastLan: lastLan, wireGuard: address);

  @override
  bool operator ==(Object other) =>
      other is KnownAddresses &&
      other.lastLan == lastLan &&
      other.wireGuard == wireGuard;

  @override
  int get hashCode => Object.hash(lastLan, wireGuard);

  @override
  String toString() => 'last LAN $lastLan, WireGuard $wireGuard';
}
