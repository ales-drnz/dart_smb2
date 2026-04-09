import 'package:flutter/material.dart';

class AppNavigation {
  static List<NavigationDestination> get destinations => const [
        NavigationDestination(
          icon: Icon(Icons.dns_outlined),
          selectedIcon: Icon(Icons.dns),
          label: 'Servers',
        ),
        NavigationDestination(
          icon: Icon(Icons.folder_outlined),
          selectedIcon: Icon(Icons.folder),
          label: 'Browse',
        ),
        NavigationDestination(
          icon: Icon(Icons.download_outlined),
          selectedIcon: Icon(Icons.download),
          label: 'Read',
        ),
        NavigationDestination(
          icon: Icon(Icons.upload_outlined),
          selectedIcon: Icon(Icons.upload),
          label: 'Write',
        ),
      ];
}
