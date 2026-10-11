class PrivateServerAccessKey {
  final String host;
  final String port;
  final String token;
  final String alias;

  const PrivateServerAccessKey({
    required this.host,
    required this.port,
    required this.token,
    this.alias = '',
  });

  Uri toUri(String shareHost, {required int expiresAt}) => Uri(
    scheme: 'https',
    host: shareHost,
    path: '/private-server',
    queryParameters: {
      'ip': host,
      'port': port,
      'token': token,
      'exp': expiresAt.toString(),
      'alias': alias,
    },
  );

  static PrivateServerAccessKey? parse(String text, {DateTime? now}) {
    final match = RegExp(
      r'''(?:https?://|lantern://|lantern//)[^\s<>"`]+''',
    ).firstMatch(text.trim());
    if (match == null) return null;
    var link = match.group(0)!;
    if (link.startsWith('lantern//')) {
      link = link.replaceFirst('lantern//', 'lantern://');
    }
    final uri = Uri.tryParse(link);
    if (uri == null) throw const FormatException('invalid_deep_link');
    final isPrivateServer = uri.scheme == 'lantern'
        ? uri.host == 'private-server'
        : uri.path == '/private-server';
    if (!isPrivateServer) return null;
    final fields = uri.queryParameters;
    final host = (fields['ip'] ?? '').trim();
    final port = int.tryParse(fields['port'] ?? '');
    final token = (fields['token'] ?? '').trim();
    if (host.isEmpty ||
        port == null ||
        port < 1 ||
        port > 65535 ||
        token.isEmpty) {
      throw const FormatException('invalid_deep_link');
    }
    final expiration = fields['exp'];
    if (expiration != null) {
      final expiresAt = int.tryParse(expiration);
      if (expiresAt == null) throw const FormatException('invalid_deep_link');
      if (expiresAt <= (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000) {
        throw const FormatException('deep_link_expired');
      }
    }
    return PrivateServerAccessKey(
      host: host,
      port: port.toString(),
      token: token,
      alias: fields['alias'] ?? fields['name'] ?? '',
    );
  }
}
