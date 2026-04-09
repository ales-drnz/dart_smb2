import 'dart:async';
import 'package:dart_smb2/dart_smb2.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/server_config.dart';

/// State of the active SMB connection.
class Smb2ConnectionState {
  final ServerConfig? config;
  final Smb2Pool? pool;
  final bool connecting;
  final String? error;

  Smb2ConnectionState({
    this.config,
    this.pool,
    this.connecting = false,
    this.error,
  });

  bool get isConnected => pool != null;

  Smb2ConnectionState copyWith({
    ServerConfig? config,
    Smb2Pool? pool,
    bool? connecting,
    String? error,
    bool clearPool = false,
    bool clearError = false,
  }) {
    return Smb2ConnectionState(
      config: config ?? this.config,
      pool: clearPool ? null : (pool ?? this.pool),
      connecting: connecting ?? this.connecting,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class ConnectionNotifier extends Notifier<Smb2ConnectionState> {
  @override
  Smb2ConnectionState build() {
    return Smb2ConnectionState();
  }

  Future<void> connect(ServerConfig config) async {
    // If already connected to the same server, do nothing
    if (state.config == config && state.isConnected) return;

    state = state.copyWith(config: config, connecting: true, clearError: true, clearPool: true);

    try {
      final pool = await Smb2Pool.connect(
        host: config.host,
        share: config.shareName,
        user: config.user.isNotEmpty ? config.user : null,
        password: config.password.isNotEmpty ? config.password : null,
        domain: config.domain.isNotEmpty ? config.domain : null,
        workers: 2,
        seal: config.seal,
        signing: config.signing,
        version: config.version,
      );
      state = state.copyWith(pool: pool, connecting: false);
    } catch (e) {
      state = state.copyWith(error: e.toString(), connecting: false, clearPool: true);
    }
  }

  Future<void> disconnect() async {
    if (state.pool != null) {
      await state.pool!.disconnect();
    }
    state = state.copyWith(clearPool: true, clearError: true);
  }
}

final connectionProvider = NotifierProvider<ConnectionNotifier, Smb2ConnectionState>(() {
  return ConnectionNotifier();
});
