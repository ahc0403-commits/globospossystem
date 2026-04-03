import 'package:flutter/material.dart';
import '../../core/layout/platform_info.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:go_router/go_router.dart';

import '../../core/layout/adaptive_layout.dart';
import '../../core/layout/web_sidebar_layout.dart';
import '../../main.dart';
import '../../widgets/offline_banner.dart';
import '../auth/auth_provider.dart';
import 'tabs/attendance_tab.dart';
import 'tabs/menu_tab.dart';
import 'tabs/reports_tab.dart';
import 'tabs/settings_tab.dart';
import 'tabs/staff_tab.dart';
import 'tabs/tables_tab.dart';

class AdminScreen extends ConsumerStatefulWidget {
  const AdminScreen({super.key, this.overrideRestaurantId});

  /// super_admin이 특정 레스토랑 admin 화면을 볼 때 사용
  final String? overrideRestaurantId;

  @override
  ConsumerState<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends ConsumerState<AdminScreen> {
  int _currentIndex = 0;

  static const List<Widget> _tabs = [
    TablesTab(),
    MenuTab(),
    StaffTab(),
    ReportsTab(),
    AttendanceTab(),
    SettingsTab(),
  ];

  @override
  Widget build(BuildContext context) {
    final isSuperAdminView = widget.overrideRestaurantId != null;

    if (PlatformInfo.isWebOrDesktop) {
      return _buildWebDesktopLayout(context, isSuperAdminView);
    }

    return _buildMobileLayout(context, isSuperAdminView);
  }

  Widget _buildWebDesktopLayout(BuildContext context, bool isSuperAdminView) {
    final items = <SidebarItem>[
      const SidebarItem(icon: Icons.table_restaurant, label: 'Tables'),
      const SidebarItem(icon: Icons.restaurant_menu, label: 'Menu'),
      const SidebarItem(icon: Icons.people, label: 'Staff'),
      const SidebarItem(icon: Icons.bar_chart, label: 'Reports'),
      const SidebarItem(icon: Icons.access_time, label: 'Attendance'),
      const SidebarItem(icon: Icons.settings, label: 'Settings'),
    ];

    return WebSidebarLayout(
      title: isSuperAdminView ? 'ADMIN VIEW' : 'GLOBOS POS',
      items: items,
      selectedIndex: _currentIndex,
      onItemSelected: (index) => setState(() => _currentIndex = index),
      topBarLeading: isSuperAdminView
          ? IconButton(
              icon: const Icon(Icons.arrow_back, color: AppColors.amber500),
              tooltip: '시스템 관리로 돌아가기',
              onPressed: () => context.go('/super-admin'),
            )
          : null,
      topBarTrailing: isSuperAdminView
          ? Container(
              margin: const EdgeInsets.symmetric(vertical: 12),
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
            )
          : null,
      bottomItems: isSuperAdminView
          ? null
          : [
              SidebarItem(
                icon: Icons.logout,
                label: 'Logout',
                onTap: () => ref.read(authProvider.notifier).logout(),
              ),
            ],
      body: Column(
        children: [
          const OfflineBanner(),
          Expanded(
            child: IndexedStack(index: _currentIndex, children: _tabs),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileLayout(BuildContext context, bool isSuperAdminView) {
    final showKioskItem =
        PlatformInfo.isKioskSupported;
    final navItems = <BottomNavigationBarItem>[
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
        icon: Icon(Icons.settings),
        label: 'Settings',
      ),
      if (showKioskItem)
        const BottomNavigationBarItem(
          icon: Icon(Icons.touch_app),
          label: 'Kiosk',
        ),
    ];

    return Scaffold(
      backgroundColor: AppColors.surface0,
      appBar: AppBar(
        backgroundColor: AppColors.surface0,
        elevation: 0,
        leading: isSuperAdminView
            ? IconButton(
                icon: const Icon(Icons.arrow_back, color: AppColors.amber500),
                tooltip: '시스템 관리로 돌아가기',
                onPressed: () => context.go('/super-admin'),
              )
            : null,
        title: Text(
          isSuperAdminView ? 'ADMIN VIEW' : 'GLOBOS POS',
          style: GoogleFonts.bebasNeue(
            color: AppColors.amber500,
            fontSize: 34,
            letterSpacing: 1.2,
          ),
        ),
        actions: [
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
            child: IndexedStack(index: _currentIndex, children: _tabs),
          ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          if (showKioskItem && index == navItems.length - 1) {
            context.go('/attendance-kiosk');
            return;
          }
          if (index >= _tabs.length) {
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
