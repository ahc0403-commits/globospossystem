import 'package:flutter/material.dart';
import '../../core/layout/platform_info.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/layout/adaptive_layout.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast.dart';
import '../../widgets/app_nav_bar.dart';
import '../../widgets/offline_banner.dart';
import '../../core/utils/permission_utils.dart';
import '../auth/auth_provider.dart';
import 'tabs/attendance_tab.dart';
import 'tabs/menu_tab.dart';
import 'tabs/qc_tab.dart';
import 'tabs/reports_tab.dart';
import 'tabs/settings_tab.dart';
import 'tabs/staff_tab.dart';
import 'tabs/tables_tab.dart';
import '../delivery/screens/delivery_settlement_tab.dart';
import 'tabs/einvoice_tab.dart';
import '../inventory_purchase/inventory_purchase_screen.dart';

class AdminScreen extends ConsumerStatefulWidget {
  const AdminScreen({
    super.key,
    this.overrideRestaurantId,
    this.initialTabIndex = 0,
  });

  /// super_admin이 특정 레스토랑 admin 화면을 볼 때 사용
  final String? overrideRestaurantId;
  final int initialTabIndex;

  @override
  ConsumerState<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends ConsumerState<AdminScreen> {
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialTabIndex;
  }

  @override
  Widget build(BuildContext context) {
    final isSuperAdminView = widget.overrideRestaurantId != null;
    final role = ref.watch(authProvider).role;
    final viewport = MediaQuery.sizeOf(context);
    final useDesktopShell =
        PlatformInfo.isWebOrDesktop &&
        viewport.width >= 720 &&
        viewport.shortestSide >= 600;

    if (useDesktopShell) {
      return _buildWebDesktopLayout(context, isSuperAdminView, role);
    }

    return _buildMobileLayout(context, isSuperAdminView, role);
  }

  List<Widget> _tabsForRole(String? role) {
    final tabs = <Widget>[
      const TablesTab(),
      const MenuTab(),
      const StaffTab(),
      const ReportsTab(),
      const AttendanceTab(),
      const InventoryPurchaseScreen(),
      const QcTab(),
      const SettingsTab(),
    ];

    if (PermissionUtils.canAccessDeliverySettlement(role)) {
      tabs.add(const DeliverySettlementTab());
    }

    tabs.add(const EinvoiceTab());
    return tabs;
  }

  /// Operational sidebar groups. Order across groups MUST match the
  /// existing flat tab order (Tables, Menu, Staff, Reports, Attendance,
  /// Inventory, QC, Settings, [Deliberry], E-Invoice) because the
  /// selected-index/tab mapping is positional. Grouping is expressive
  /// only — the `ToastSidebar` adapter flattens groups while preserving
  /// order, so shell behavior is unchanged.
  List<ToastSidebarGroup> _sidebarGroupsForRole(String? role) {
    final l10n = context.l10n;
    final liveOps = <ToastSidebarItem>[
      ToastSidebarItem(
        icon: Icons.table_restaurant,
        label: l10n.tables,
        urgency: ToastSidebarUrgency.live,
        helperLabel: l10n.adminNavTablesHelper,
        itemKey: const Key('nav_tables'),
      ),
      ToastSidebarItem(
        icon: Icons.restaurant_menu,
        label: l10n.menu,
        urgency: ToastSidebarUrgency.live,
        helperLabel: l10n.adminNavMenuHelper,
        itemKey: const Key('nav_menu'),
      ),
    ];

    final backOffice = <ToastSidebarItem>[
      ToastSidebarItem(
        icon: Icons.people,
        label: l10n.staff,
        urgency: ToastSidebarUrgency.backOffice,
        helperLabel: l10n.adminNavStaffHelper,
        itemKey: const Key('nav_staff'),
      ),
      ToastSidebarItem(
        icon: Icons.bar_chart,
        label: l10n.reports,
        urgency: ToastSidebarUrgency.backOffice,
        helperLabel: l10n.adminNavReportsHelper,
        itemKey: const Key('nav_reports'),
      ),
      ToastSidebarItem(
        icon: Icons.access_time,
        label: l10n.attendance,
        urgency: ToastSidebarUrgency.backOffice,
        helperLabel: l10n.adminNavAttendanceHelper,
        itemKey: const Key('nav_attendance'),
      ),
      ToastSidebarItem(
        icon: Icons.inventory_2_outlined,
        label: l10n.inventory,
        urgency: ToastSidebarUrgency.backOffice,
        helperLabel: l10n.adminNavInventoryHelper,
        itemKey: const Key('nav_inventory'),
      ),
      ToastSidebarItem(
        icon: Icons.fact_check,
        label: l10n.navQuality,
        urgency: ToastSidebarUrgency.backOffice,
        helperLabel: l10n.adminNavQcHelper,
        itemKey: const Key('nav_qc'),
      ),
      ToastSidebarItem(
        icon: Icons.settings,
        label: l10n.settings,
        urgency: ToastSidebarUrgency.backOffice,
        helperLabel: l10n.adminNavSettingsHelper,
        itemKey: const Key('nav_settings'),
      ),
    ];

    final exceptions = <ToastSidebarItem>[];
    if (PermissionUtils.canAccessDeliverySettlement(role)) {
      exceptions.add(
        ToastSidebarItem(
          icon: Icons.delivery_dining,
          label: l10n.deliberrySettlement,
          urgency: ToastSidebarUrgency.exception,
          helperLabel: l10n.adminNavDeliverySettlementHelper,
          itemKey: const Key('nav_delivery_settlement'),
        ),
      );
    }
    exceptions.add(
      ToastSidebarItem(
        icon: Icons.receipt_long,
        label: l10n.eInvoice,
        urgency: ToastSidebarUrgency.exception,
        helperLabel: l10n.adminNavEinvoiceHelper,
        itemKey: const Key('nav_einvoice'),
      ),
    );

    return [
      ToastSidebarGroup(
        title: l10n.adminWorkflowLiveOperations,
        items: liveOps,
      ),
      ToastSidebarGroup(title: l10n.adminWorkflowBackOffice, items: backOffice),
      ToastSidebarGroup(title: l10n.adminWorkflowExceptions, items: exceptions),
    ];
  }

  Widget _buildWebDesktopLayout(
    BuildContext context,
    bool isSuperAdminView,
    String? role,
  ) {
    final tabs = _tabsForRole(role);
    final groups = _sidebarGroupsForRole(role);
    final safeIndex = _currentIndex.clamp(0, tabs.length - 1);

    return ToastSidebar(
      key: const Key('admin_root'),
      title: isSuperAdminView
          ? context.l10n.adminViewTitle
          : context.l10n.appTitle,
      groups: groups,
      selectedIndex: safeIndex,
      onItemSelected: (index) => setState(() => _currentIndex = index),
      topBarLeading: isSuperAdminView
          ? IconButton(
              icon: const Icon(Icons.arrow_back, color: PosColors.accent),
              tooltip: context.l10n.backToSystemAdmin,
              onPressed: () => context.go('/super-admin'),
            )
          : null,
      topBarTrailing: isSuperAdminView
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const AppNavBar(),
                const SizedBox(width: 10),
                ToastStatusBadge(
                  label: context.l10n.superAdminMode,
                  color: PosColors.warning,
                  compact: true,
                ),
              ],
            )
          : const AppNavBar(),
      bottomItems: isSuperAdminView
          ? null
          : [
              ToastSidebarItem(
                icon: Icons.logout,
                label: context.l10n.logout,
                urgency: ToastSidebarUrgency.backOffice,
                itemKey: const Key('logout_button'),
                onTap: () => ref.read(authProvider.notifier).logout(),
              ),
            ],
      body: Column(
        children: [
          const OfflineBanner(),
          Expanded(
            child: IndexedStack(index: safeIndex, children: tabs),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileLayout(
    BuildContext context,
    bool isSuperAdminView,
    String? role,
  ) {
    final tabs = _tabsForRole(role);
    final groups = _sidebarGroupsForRole(role);
    final safeIndex = _currentIndex.clamp(0, tabs.length - 1);

    return ToastSidebar(
      key: const Key('admin_root'),
      title: isSuperAdminView
          ? context.l10n.adminViewTitle
          : context.l10n.appTitle,
      groups: groups,
      selectedIndex: safeIndex,
      onItemSelected: (index) => setState(() => _currentIndex = index),
      topBarLeading: isSuperAdminView
          ? IconButton(
              icon: const Icon(Icons.arrow_back, color: PosColors.accent),
              tooltip: context.l10n.backToSystemAdmin,
              onPressed: () => context.go('/super-admin'),
            )
          : null,
      topBarTrailing: isSuperAdminView
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const AppNavBar(),
                const SizedBox(width: 8),
                ToastStatusBadge(
                  label: context.l10n.superAdminMode,
                  color: PosColors.warning,
                  compact: true,
                ),
              ],
            )
          : const AppNavBar(),
      bottomItems: isSuperAdminView
          ? null
          : [
              ToastSidebarItem(
                icon: Icons.logout,
                label: context.l10n.logout,
                urgency: ToastSidebarUrgency.backOffice,
                itemKey: const Key('logout_button'),
                onTap: () => ref.read(authProvider.notifier).logout(),
              ),
            ],
      body: Column(
        children: [
          const OfflineBanner(),
          Expanded(
            child: IndexedStack(index: safeIndex, children: tabs),
          ),
        ],
      ),
    );
  }
}
