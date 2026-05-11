// ToastSidebar — non-invasive wrapper around WebSidebarLayout.
//
// Phase 1 constraint: do NOT change the existing shell behavior. So
// ToastSidebar models the Toast operational sidebar data shape
// (workflow grouping + urgency/helper/badge per item) and PROJECTS it
// down onto the existing `WebSidebarLayout` API. Today the projection
// flattens groups and drops urgency/helper/badge to label so the shell
// renders identically. When the shell is ready to be upgraded, this
// adapter is the only call site that needs to swap.
//
// "No fake counts" rule (handoff): a [ToastSidebarItem.badge] should
// only be set when the caller has a real provider-backed count. This
// primitive does not synthesize counts.

import 'package:flutter/material.dart';

import '../../layout/web_sidebar_layout.dart';

/// Urgency tier for a sidebar item. Drives ordering and (later) visual
/// weight. Phase 1 keeps visual weight identical to today; this enum is
/// reserved for the next pass.
enum ToastSidebarUrgency { live, exception, backOffice }

class ToastSidebarItem {
  const ToastSidebarItem({
    required this.icon,
    required this.label,
    this.urgency = ToastSidebarUrgency.backOffice,
    this.helper,
    this.helperLabel,
    this.badge,
    this.sectionLabel,
    this.onTap,
    this.itemKey,
  });

  final IconData icon;
  final String label;
  final ToastSidebarUrgency urgency;

  /// Short hover/help disclosure. Optional.
  final String? helper;

  /// Wave 1.5 caller-supplied helper string (used by shell callers that
  /// build flat item lists). Kept distinct from [helper] so existing
  /// call sites are unaffected; today's `_flatten` adapter renders
  /// neither.
  final String? helperLabel;

  /// Real provider-backed count, never synthesized. Null when no
  /// grounded signal exists.
  final int? badge;

  /// Caller-supplied section label for Wave 1.5 shell callers that
  /// emit flat item lists with embedded section headers (instead of
  /// the grouped [ToastSidebarGroup] API). Today's `_flatten` adapter
  /// reads grouping from [ToastSidebarGroup] only, so this field is
  /// stored but not rendered.
  final String? sectionLabel;

  final VoidCallback? onTap;
  final Key? itemKey;
}

class ToastSidebarGroup {
  const ToastSidebarGroup({required this.title, required this.items});
  final String title;
  final List<ToastSidebarItem> items;
}

/// ToastSidebar wraps WebSidebarLayout. It accepts grouped Toast items
/// and projects them onto the legacy flat [SidebarItem] list, which
/// preserves today's shell behavior exactly.
class ToastSidebar extends StatelessWidget {
  const ToastSidebar({
    super.key,
    required this.title,
    required this.groups,
    required this.selectedIndex,
    required this.onItemSelected,
    required this.body,
    this.topBarTrailing,
    this.topBarLeading,
    this.bottomItems,
  });

  final String title;
  final List<ToastSidebarGroup> groups;
  final int selectedIndex;
  final ValueChanged<int> onItemSelected;
  final Widget body;
  final Widget? topBarTrailing;
  final Widget? topBarLeading;
  final List<ToastSidebarItem>? bottomItems;

  ({List<SidebarItem> items, Map<int, String> headers}) _flatten() {
    final out = <SidebarItem>[];
    final headers = <int, String>{};
    for (final g in groups) {
      if (g.items.isEmpty) continue;
      headers[out.length] = g.title;
      for (final i in g.items) {
        out.add(
          SidebarItem(
            icon: i.icon,
            label: i.label,
            onTap: i.onTap,
            itemKey: i.itemKey,
          ),
        );
      }
    }
    return (items: out, headers: headers);
  }

  @override
  Widget build(BuildContext context) {
    final flat = _flatten();
    return WebSidebarLayout(
      title: title,
      items: flat.items,
      selectedIndex: selectedIndex,
      onItemSelected: onItemSelected,
      body: body,
      topBarTrailing: topBarTrailing,
      topBarLeading: topBarLeading,
      groupHeaders: flat.headers,
      bottomItems: bottomItems
          ?.map(
            (i) => SidebarItem(
              icon: i.icon,
              label: i.label,
              onTap: i.onTap,
              itemKey: i.itemKey,
            ),
          )
          .toList(),
    );
  }
}
