import 'package:flutter/material.dart';

import 'app_empty_state.dart';

class AppSliverPage extends StatelessWidget {
  final String title;
  final bool showEmptyState;
  final IconData emptyIcon;
  final String emptyTitle;
  final String emptySubtitle;
  final Widget contentSliver;

  const AppSliverPage({
    super.key,
    required this.title,
    required this.showEmptyState,
    required this.emptyIcon,
    required this.emptyTitle,
    required this.emptySubtitle,
    required this.contentSliver,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Text(
                title,
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          if (showEmptyState)
            SliverFillRemaining(
              hasScrollBody: false,
              child: AppEmptyState(
                icon: emptyIcon,
                title: emptyTitle,
                subtitle: emptySubtitle,
              ),
            )
          else
            contentSliver,
        ],
      ),
    );
  }
}