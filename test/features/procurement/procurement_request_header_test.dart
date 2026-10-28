import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/procurement/procurement_presentation.dart';
import 'package:globos_pos_system/features/procurement/procurement_process_labels.dart';

void main() {
  test(
    'Bunsik PR displays the selected department and preserves the actor',
    () {
      final actor = {
        'display_name': 'Binh Thanh PR team',
        'subject_id': 'original',
      };
      final data = <String, dynamic>{
        'restaurant_id': '8bc9eef5-dcd5-46b1-b931-23f77132322c',
        'store_name': 'BunsikClub Binh Thanh',
        'created_actor': actor,
        'request_department_name': 'Bếp Bunsik',
      };
      final header = procurementRequestHeader(data);
      expect(header['store_name'], 'BUNSIKCLUB');
      expect(
        header['store_address'],
        '69/1A2 Nguyễn Gia Trí, phường Thạnh Mỹ Tây',
      );
      expect(header['requester_label'], 'requestDepartment');
      expect(header['requester_value'], 'Bếp Bunsik');
      expect(data['store_name'], 'BunsikClub Binh Thanh');
      expect(data['created_actor'], same(actor));
      expect(actor['display_name'], 'Binh Thanh PR team');
    },
  );

  test(
    'selected department spelling is preserved rather than renamed to a mockup alias',
    () {
      for (final name in ['Bếp Bunsik', 'Bếp BunsikClub']) {
        final header = procurementRequestHeader({
          'restaurant_id': '8bc9eef5-dcd5-46b1-b931-23f77132322c',
          'store_name': 'BunsikClub Binh Thanh',
          'request_department_name': name,
          'created_actor': {'display_name': 'Registered requesting account'},
        });
        expect(header['requester_value'], name);
      }
      expect(
        procurementRequestHeader({
          'restaurant_id': '8bc9eef5-dcd5-46b1-b931-23f77132322c',
          'store_name': 'BunsikClub Binh Thanh',
          'created_actor': {'display_name': 'Registered requesting account'},
        })['requester_value'],
        'Registered requesting account',
      );
    },
  );

  test(
    'Jeongabok PR uses its supplied title and address without inventing a department',
    () {
      final header = procurementRequestHeader({
        'restaurant_id': '273b057e-3b69-46e3-93c1-6194c2802849',
        'store_name': 'JeonGabok Binh Thanh',
        'created_actor': {'display_name': 'Registered requester'},
      });
      expect(header['store_name'], 'JEONGABOK (TOÀN GIA PHÚC)');
      expect(
        header['store_address'],
        '29A Nguyễn Gia Trí, phường Thạnh Mỹ Tây',
      );
      expect(header['requester_value'], 'Registered requester');
      expect(header['requester_label'], 'requester');
    },
  );

  test(
    'similar names in other stores do not acquire a different store identity',
    () {
      final header = procurementRequestHeader({
        'restaurant_id': 'another-store',
        'store_name': 'BunsikClub SAMPLE',
        'created_actor': {'display_name': 'Original requester'},
      });
      expect(header['store_name'], 'BunsikClub SAMPLE');
      expect(header.containsKey('store_address'), false);
      expect(header['requester_label'], 'requester');
      expect(header['requester_value'], 'Original requester');
    },
  );

  test('department label is available in all three document languages', () {
    expect(procurementProcessLabel('requestDepartment', 'ko'), '요청 부서');
    expect(
      procurementProcessLabel('requestDepartment', 'en'),
      'Requesting department',
    );
    expect(
      procurementProcessLabel('requestDepartment', 'vi'),
      'Bộ phận yêu cầu',
    );
  });
}
