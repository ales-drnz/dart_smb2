import 'package:dart_smb2/dart_smb2.dart';

class ServerConfig {
  String name;
  String host;
  String share;
  String user;
  String password;
  String domain;
  bool seal;
  bool signing;
  Smb2Version version;

  ServerConfig({
    this.name = '',
    this.host = '',
    this.share = '',
    this.user = '',
    this.password = '',
    this.domain = '',
    this.seal = false,
    this.signing = false,
    this.version = Smb2Version.any,
  });

  ServerConfig copy() => ServerConfig(
    name: name,
    host: host,
    share: share,
    user: user,
    password: password,
    domain: domain,
    seal: seal,
    signing: signing,
    version: version,
  );

  String get _normalizedShareInput => share.replaceAll('\\', '/').trim();

  String get shareName {
    final normalized = _normalizedShareInput;
    if (normalized.isEmpty) return '';
    return normalized.split('/').firstWhere((s) => s.isNotEmpty, orElse: () => '');
  }

  String get basePath {
    final normalized = _normalizedShareInput;
    if (normalized.isEmpty) return '';
    final parts = normalized.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.length <= 1) return '';
    return parts.skip(1).join('/');
  }

  String get displayName => name.isNotEmpty ? name : '$host/$share';

  Map<String, dynamic> toJson() => {
    'name': name,
    'host': host,
    'share': share,
    'user': user,
    'password': password,
    'domain': domain,
    'seal': seal,
    'signing': signing,
    'version': version.name,
  };

  factory ServerConfig.fromJson(Map<String, dynamic> json) => ServerConfig(
    name: json['name'] as String? ?? '',
    host: json['host'] as String? ?? '',
    share: json['share'] as String? ?? '',
    user: json['user'] as String? ?? '',
    password: json['password'] as String? ?? '',
    domain: json['domain'] as String? ?? '',
    seal: json['seal'] as bool? ?? false,
    signing: json['signing'] as bool? ?? false,
    version: Smb2Version.values.asNameMap()[json['version'] as String?] ?? Smb2Version.any,
  );
}
