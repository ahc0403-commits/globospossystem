import '../../main.dart';
import 'restaurant_sales_export.dart';

class RestaurantSalesExportService {
  Future<List<RestaurantSalesExport>> load(String businessDate) async {
    final response = await supabase.rpc(
      'get_restaurant_daily_sales_exports_by_tax_entity',
      params: {'p_business_date': businessDate},
    );
    if (response is! Map) {
      throw const FormatException('RESTAURANT_EXPORT_INVALID_RESPONSE');
    }
    return createRestaurantSalesExportsByTaxEntity(
      Map<String, dynamic>.from(response),
    );
  }
}

final restaurantSalesExportService = RestaurantSalesExportService();
