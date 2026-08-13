import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/ui/toast/toast.dart';
import '../../main.dart';
import '../report/menu_sales_analytics.dart';
import '../report/menu_sales_analytics_panel.dart';
import 'widgets/paperless_operations_dashboard.dart';

class PaperlessOperationsAnalyticsScreen extends StatelessWidget {
  const PaperlessOperationsAnalyticsScreen({
    super.key,
    required this.storeId,
    required this.startDate,
    required this.endDate,
  });

  final String storeId;
  final DateTime startDate;
  final DateTime endDate;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('paperless_operations_analytics_screen'),
      backgroundColor: AppColors.surface0,
      appBar: AppBar(
        title: Text(paperlessOperationsTitle(context)),
        backgroundColor: AppColors.surface0,
        surfaceTintColor: Colors.transparent,
      ),
      body: SafeArea(
        child: ToastResponsiveScrollBody(
          key: const Key('paperless_operations_analytics_scroll'),
          maxWidth: 1460,
          padding: const EdgeInsets.all(16),
          children: [
            PaperlessOperationsDashboard(
              storeId: storeId,
              startDate: startDate,
              endDate: endDate,
            ),
          ],
        ),
      ),
    );
  }
}

class MenuSalesAnalyticsScreen extends StatelessWidget {
  const MenuSalesAnalyticsScreen({super.key, required this.params});

  final MenuSalesAnalyticsParams params;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('menu_sales_analytics_screen'),
      backgroundColor: AppColors.surface0,
      appBar: AppBar(
        title: Text(context.l10n.menuSalesAnalyticsTitle),
        backgroundColor: AppColors.surface0,
        surfaceTintColor: Colors.transparent,
      ),
      body: SafeArea(
        child: ToastResponsiveScrollBody(
          key: const Key('menu_sales_analytics_scroll'),
          maxWidth: 1460,
          padding: const EdgeInsets.all(16),
          children: [
            MenuSalesAnalyticsPanel(
              params: params,
              currency: NumberFormat('#,###', 'vi_VN'),
            ),
          ],
        ),
      ),
    );
  }
}
