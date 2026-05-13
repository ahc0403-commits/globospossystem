import 'package:flutter/material.dart';
import '../../core/layout/platform_info.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:go_router/go_router.dart';

import '../../core/layout/adaptive_layout.dart';
import '../../core/ui/toast/toast.dart';
import '../../main.dart';
import '../../widgets/app_nav_bar.dart';
import '../../widgets/offline_banner.dart';
import '../../core/utils/permission_utils.dart';
import '../auth/auth_provider.dart';
import 'tabs/attendance_tab.dart';
import 'tabs/inventory_tab.dart';
import 'tabs/menu_tab.dart';
import 'tabs/qc_tab.dart';
import 'tabs/reports_tab.dart';
import 'tabs/settings_tab.dart';
import 'tabs/staff_tab.dart';
import 'tabs/tables_tab.dart';
import '../delivery/screens/delivery_settlement_tab.dart';
import 'tabs/einvoice_tab.dart';

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

    if (PlatformInfo.isWebOrDesktop) {
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
      const InventoryTab(),
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
    final liveOps = <ToastSidebarItem>[
      const ToastSidebarItem(
        icon: Icons.table_restaurant,
        label: 'Tables',
        urgency: ToastSidebarUrgency.live,
        itemKey: Key('nav_tables'),
      ),
      const ToastSidebarItem(
        icon: Icons.restaurant_menu,
        label: 'Menu',
        urgency: ToastSidebarUrgency.live,
        itemKey: Key('nav_menu'),
      ),
    ];

    final backOffice = <ToastSidebarItem>[
      const ToastSidebarItem(
        icon: Icons.people,
        label: 'Staff',
        urgency: ToastSidebarUrgency.backOffice,
        itemKey: Key('nav_staff'),
      ),
      const ToastSidebarItem(
        icon: Icons.bar_chart,
        label: 'Reports',
        urgency: ToastSidebarUrgency.backOffice,
        itemKey: Key('nav_reports'),
      ),
      const ToastSidebarItem(
        icon: Icons.access_time,
        label: 'Attendance',
        urgency: ToastSidebarUrgency.backOffice,
        itemKey: Key('nav_attendance'),
      ),
      const ToastSidebarItem(
        icon: Icons.inventory_2_outlined,
        label: 'Inventory',
        urgency: ToastSidebarUrgency.backOffice,
        itemKey: Key('nav_inventory'),
      ),
      const ToastSidebarItem(
        icon: Icons.fact_check,
        label: 'QC',
        urgency: ToastSidebarUrgency.backOffice,
        itemKey: Key('nav_qc'),
      ),
      const ToastSidebarItem(
        icon: Icons.settings,
        label: 'Settings',
        urgency: ToastSidebarUrgency.backOffice,
        itemKey: Key('nav_settings'),
      ),
    ];

    final exceptions = <ToastSidebarItem>[];
    if (PermissionUtils.canAccessDeliverySettlement(role)) {
      exceptions.add(
        const ToastSidebarItem(
          icon: Icons.delivery_dining,
          label: 'Deliberry Settlement',
          urgency: ToastSidebarUrgency.exception,
          itemKey: Key('nav_delivery_settlement'),
        ),
      );
    }
    exceptions.add(
      const ToastSidebarItem(
        icon: Icons.receipt_long,
        label: 'E-Invoice',
        urgency: ToastSidebarUrgency.exception,
        itemKey: Key('nav_einvoice'),
      ),
    );

    return [
      ToastSidebarGroup(title: 'Live Operations', items: liveOps),
      ToastSidebarGroup(title: 'Back Office', items: backOffice),
      ToastSidebarGroup(title: 'Exceptions', items: exceptions),
    ];
  }

  List<BottomNavigationBarItem> _mobileNavItemsForRole(String? role) {
    final items = <BottomNavigationBarItem>[
      const BottomNavigationBarItem(
        icon: Icon(Icons.table_restaurant),
        label: 'Tables',
      ),
      const BottomNavigationBarItem(
        icon: Icon(Icons.restaurant_menu),
        label: 'Menu',
      ),
      const BottomNavigationBarItem(icon: Icon(Icons.people), label: 'Staff'),
      const BottomNavigationBarItem(
        icon: Icon(Icons.bar_chart),
        label: 'Reports',
      ),
      const BottomNavigationBarItem(
        icon: Icon(Icons.access_time),
        label: 'Attendance',
      ),
      const BottomNavigationBarItem(
        icon: Icon(Icons.inventory_2_outlined),
        label: 'Inventory',
      ),
      const BottomNavigationBarItem(icon: Icon(Icons.fact_check), label: 'QC'),
      const BottomNavigationBarItem(
        icon: Icon(Icons.settings),
        label: 'Settings',
      ),
    ];

    if (PermissionUtils.canAccessDeliverySettlement(role)) {
      items.add(
        const BottomNavigationBarItem(
          icon: Icon(Icons.delivery_dining),
          label: 'Deliberry',
        ),
      );
    }

    items.add(
      const BottomNavigationBarItem(
        icon: Icon(Icons.receipt_long),
        label: 'E-Invoice',
      ),
    );
    return items;
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
      title: isSuperAdminView ? 'ADMIN VIEW' : 'GLOBOS POS',
      groups: groups,
      selectedIndex: safeIndex,
      onItemSelected: (index) => setState(() => _currentIndex = index),
      topBarLeading: isSuperAdminView
          ? IconButton(
              icon: const Icon(Icons.arrow_back, color: AppColors.amber500),
              tooltip: 'Back to System Admin',
              onPressed: () => context.go('/super-admin'),
            )
          : null,
      topBarTrailing: isSuperAdminView
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const AppNavBar(),
                const SizedBox(width: 10),
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.statusOccupied.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.statusOccupied),
                  ),
                  child: Text(
                    'SUPER ADMIN MODE',
                    style: GoogleFonts.notoSansKr(
                      color: AppColors.statusOccupied,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            )
          : const AppNavBar(),
      bottomItems: isSuperAdminView
          ? null
          : [
              ToastSidebarItem(
                icon: Icons.logout,
                label: 'Logout',
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
    final navItems = _mobileNavItemsForRole(role);
    final safeIndex = _currentIndex.clamp(0, tabs.length - 1);

    return Scaffold(
      key: const Key('admin_root'),
      backgroundColor: AppColors.surface0,
      appBar: AppBar(
        backgroundColor: AppColors.surface0,
        elevation: 0,
        leading: isSuperAdminView
            ? IconButton(
                icon: const Icon(Icons.arrow_back, color: AppColors.amber500),
                tooltip: 'Back to System Admin',
                onPressed: () => context.go('/super-admin'),
              )
            : null,
        title: Text(
          isSuperAdminView ? 'ADMIN VIEW' : 'GLOBOS POS',
          style: AppTextStyles.operationalTitle(
            size: 24,
            color: AppColors.amber500,
          ),
        ),
        actions: [
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: Center(child: AppNavBar()),
          ),
          if (isSuperAdminView)
            Container(
              margin: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.statusOccupied.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.statusOccupied),
              ),
              child: Text(
                'SUPER ADMIN MODE',
                style: GoogleFonts.notoSansKr(
                  color: AppColors.statusOccupied,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          if (!isSuperAdminView)
            IconButton(
              key: const Key('logout_button'),
              onPressed: () => ref.read(authProvider.notifier).logout(),
              icon: const Icon(Icons.logout),
              color: AppColors.textPrimary,
              tooltip: 'Logout',
            ),
        ],
      ),
      body: Column(
        children: [
          const OfflineBanner(),
          Expanded(
            child: IndexedStack(index: safeIndex, children: tabs),
          ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: safeIndex,
        onTap: (index) {
          if (index >= tabs.length) {
            return;
          }
          setState(() => _currentIndex = index);
        },
        type: BottomNavigationBarType.fixed,
        backgroundColor: AppColors.surface1,
        selectedItemColor: AppColors.amber500,
        unselectedItemColor: AppColors.textSecondary,
        items: navItems,
      ),
    );
  }
}
