import '../../main.dart';
import 'restaurant_sales_export.dart';

class RestaurantSalesExportService {
  Future<RestaurantSalesExport> load(String businessDate) async {
    final response = await supabase.rpc(
      'get_restaurant_daily_sales_export',
      params: {'p_business_date': businessDate},
    );
    if (response is! Map) {
      throw const FormatException('RESTAURANT_EXPORT_INVALID_RESPONSE');
    }
    return createRestaurantSalesExport(Map<String, dynamic>.from(response));
  }
}

final restaurantSalesExportService = RestaurantSalesExportService();
