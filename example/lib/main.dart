import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models/server_config.dart';
import 'pages/servers_page.dart';
import 'pages/tree_explorer_page.dart';
import 'pages/read_tests_page.dart';
import 'pages/write_tests_page.dart';
import 'theme/app_theme.dart';
import 'navigation/app_navigation.dart';

void main() => runApp(const ProviderScope(child: App()));

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'dart_smb2',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      scrollBehavior: AppTheme.scrollBehavior,
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _storageKey = 'smb2_servers';

  final List<ServerConfig> _servers = [];
  int _currentIndex = 0;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_storageKey);
    if (raw != null) {
      _servers.addAll(raw.map((s) => ServerConfig.fromJson(jsonDecode(s) as Map<String, dynamic>)));
    }
    setState(() => _loaded = true);
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_storageKey, _servers.map((s) => jsonEncode(s.toJson())).toList());
  }

  void _onServersChanged() {
    setState(() {});
    _save();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final pages = [
      ServersPage(
        servers: _servers,
        onChanged: _onServersChanged,
      ),
      const TreeExplorerPage(),
      ReadTestsPage(servers: _servers),
      WriteTestsPage(servers: _servers),
    ];

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: pages,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) => setState(() => _currentIndex = i),
        destinations: AppNavigation.destinations,
      ),
    );
  }
}
