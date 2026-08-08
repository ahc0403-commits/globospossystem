import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/hardware/printer_service.dart';
import 'package:globos_pos_system/features/settings/printer_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
  });

  test('LAN connection test uses the current IP and TCP port', () async {
    final service = _RecordingPrinterService();
    final notifier = PrinterNotifier(service: service);
    await Future<void>.delayed(Duration.zero);

    await notifier.testConnection(ip: '192.168.1.40', port: '9102');

    expect(service.testIp, '192.168.1.40');
    expect(service.testPort, 9102);
    expect(notifier.state.lastTestResult, isTrue);
  });

  test('LAN IP state changes before local persistence completes', () async {
    final notifier = PrinterNotifier(service: _RecordingPrinterService());
    await Future<void>.delayed(Duration.zero);

    final write = notifier.setIp(' 192.168.1.41 ');

    expect(notifier.state.printerIp, '192.168.1.41');
    await write;
  });

  test('LAN print uses the configured TCP port', () async {
    final service = _RecordingPrinterService();
    final notifier = PrinterNotifier(service: service);
    await Future<void>.delayed(Duration.zero);
    await notifier.setIp('192.168.1.42');
    await notifier.setPort('9103');

    final result = await notifier.print(const <int>[0x1b, 0x40]);

    expect(result, PrintResult.success);
    expect(service.printIp, '192.168.1.42');
    expect(service.printPort, 9103);
  });
}

class _RecordingPrinterService implements PrinterService {
  String? testIp;
  int? testPort;
  String? printIp;
  int? printPort;

  @override
  bool get isSupported => true;

  @override
  Future<bool> testConnection(String ip, {int port = 9100}) async {
    testIp = ip;
    testPort = port;
    return true;
  }

  @override
  Future<PrintResult> printReceipt(
    String ip,
    List<int> bytes, {
    int port = 9100,
  }) async {
    printIp = ip;
    printPort = port;
    return PrintResult.success;
  }
}
