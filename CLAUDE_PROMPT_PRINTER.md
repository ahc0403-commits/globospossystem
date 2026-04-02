Project: /Users/andreahn/globos_pos_system
Task: Implement thermal receipt printer integration for Xprinter XP-K200W.

## Hardware Spec (Confirmed - ADR-008)
- Model: Xprinter XP-K200W
- Connection: WiFi TCP (same network as Android tablet)
- Port: 9100
- Paper: 80mm
- Protocol: ESC/POS
- Flutter package: esc_pos_utils_plus (ALREADY in pubspec.yaml)

## Architecture
```
XP-K200W (WiFi, TCP:9100)
  ↑
Android tablet (cashier)
  ↑
Flutter PrinterService → esc_pos_utils_plus → Socket(ip, 9100)
  ↑
Cashier screen → payment complete → auto print receipt
```

## Platform Rules
- Android: Full TCP WiFi printing
- macOS: Full TCP WiFi printing  
- Web: NO printing (kIsWeb → NoopPrinterService, show "프린터는 앱에서만 지원됩니다" toast)

---

## Task 1: PrinterService Abstract Interface

Create: lib/core/hardware/printer_service.dart

```dart
import 'dart:typed_data';

abstract class PrinterService {
  bool get isSupported;
  Future<bool> testConnection(String ip, {int port = 9100});
  Future<PrintResult> printReceipt(String ip, List<int> bytes, {int port = 9100});
}

enum PrintResult { success, connectionFailed, printFailed, notSupported }
```

---

## Task 2: WiFi TCP Printer Implementation

Create: lib/core/hardware/wifi_printer_service.dart

```dart
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'printer_service.dart';

class WifiPrinterService implements PrinterService {
  @override
  bool get isSupported => !kIsWeb;

  @override
  Future<bool> testConnection(String ip, {int port = 9100}) async {
    if (kIsWeb) return false;
    try {
      final socket = await Socket.connect(
        ip, port,
        timeout: const Duration(seconds: 3),
      );
      await socket.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<PrintResult> printReceipt(String ip, List<int> bytes, {int port = 9100}) async {
    if (kIsWeb) return PrintResult.notSupported;
    try {
      final socket = await Socket.connect(
        ip, port,
        timeout: const Duration(seconds: 5),
      );
      socket.add(bytes);
      await socket.flush();
      await socket.close();
      return PrintResult.success;
    } on SocketException {
      return PrintResult.connectionFailed;
    } catch (_) {
      return PrintResult.printFailed;
    }
  }
}

PrinterService createPrinterService() => WifiPrinterService();
```

---

## Task 3: Receipt Builder

Create: lib/core/hardware/receipt_builder.dart

This class builds ESC/POS bytes for a receipt using esc_pos_utils_plus.

```dart
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';

class ReceiptBuilder {
  static Future<List<int>> buildPaymentReceipt({
    required String restaurantName,
    required String tableNumber,
    required List<ReceiptItem> items,
    required double totalAmount,
    required String paymentMethod,
    required DateTime paidAt,
    bool isService = false,
  }) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(PaperSize.mm80, profile);
    List<int> bytes = [];

    // Header
    bytes += generator.text(
      restaurantName,
      styles: const PosStyles(bold: true, align: PosAlign.center, height: PosTextSize.size2, width: PosTextSize.size2),
    );
    bytes += generator.text(
      'GLOBOSVN POS',
      styles: const PosStyles(align: PosAlign.center),
    );
    bytes += generator.hr();

    // Table & date
    bytes += generator.row([
      PosColumn(text: '테이블 / Bàn: $tableNumber', width: 8),
      PosColumn(
        text: '${paidAt.hour.toString().padLeft(2,'0')}:${paidAt.minute.toString().padLeft(2,'0')}',
        width: 4,
        styles: const PosStyles(align: PosAlign.right),
      ),
    ]);
    bytes += generator.text(
      '${paidAt.year}-${paidAt.month.toString().padLeft(2,'0')}-${paidAt.day.toString().padLeft(2,'0')}',
      styles: const PosStyles(align: PosAlign.left),
    );
    bytes += generator.hr();

    // Items header
    bytes += generator.row([
      PosColumn(text: '메뉴 / Món', width: 6, styles: const PosStyles(bold: true)),
      PosColumn(text: 'SL', width: 2, styles: const PosStyles(bold: true, align: PosAlign.center)),
      PosColumn(text: 'Giá (₫)', width: 4, styles: const PosStyles(bold: true, align: PosAlign.right)),
    ]);
    bytes += generator.hr();

    // Items
    for (final item in items) {
      bytes += generator.row([
        PosColumn(text: item.name, width: 6),
        PosColumn(text: '${item.quantity}', width: 2, styles: const PosStyles(align: PosAlign.center)),
        PosColumn(
          text: _formatVnd(item.unitPrice * item.quantity),
          width: 4,
          styles: const PosStyles(align: PosAlign.right),
        ),
      ]);
    }

    bytes += generator.hr();

    // Total
    bytes += generator.row([
      PosColumn(
        text: isService ? 'DỊCH VỤ / 서비스' : 'TỔNG CỘNG / 합계',
        width: 6,
        styles: const PosStyles(bold: true),
      ),
      PosColumn(
        text: _formatVnd(totalAmount),
        width: 6,
        styles: const PosStyles(bold: true, align: PosAlign.right),
      ),
    ]);

    // Payment method
    final methodLabel = _methodLabel(paymentMethod);
    bytes += generator.text(
      'Thanh toán / 결제: $methodLabel',
      styles: const PosStyles(align: PosAlign.left),
    );

    if (isService) {
      bytes += generator.hr();
      bytes += generator.text(
        '* 서비스 제공 - 매출 미반영',
        styles: const PosStyles(align: PosAlign.center, italic: true),
      );
      bytes += generator.text(
        '* Phục vụ nội bộ - Không tính doanh thu',
        styles: const PosStyles(align: PosAlign.center, italic: true),
      );
    }

    bytes += generator.hr();
    bytes += generator.text(
      'Cảm ơn quý khách! / 감사합니다!',
      styles: const PosStyles(align: PosAlign.center),
    );
    bytes += generator.feed(2);
    bytes += generator.cut();

    return bytes;
  }

  static String _formatVnd(double amount) {
    final n = amount.toInt();
    final s = n.toString();
    final buffer = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buffer.write(',');
      buffer.write(s[i]);
    }
    return '${buffer.toString()}₫';
  }

  static String _methodLabel(String method) {
    switch (method) {
      case 'cash': return '현금 / Tiền mặt';
      case 'card': return '카드 / Thẻ';
      case 'pay': return '간편결제 / Ví điện tử';
      case 'service': return '서비스 / Dịch vụ';
      default: return method;
    }
  }
}

class ReceiptItem {
  final String name;
  final int quantity;
  final double unitPrice;

  const ReceiptItem({
    required this.name,
    required this.quantity,
    required this.unitPrice,
  });
}
```

---

## Task 4: Printer Provider

Create: lib/features/settings/printer_provider.dart

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/hardware/wifi_printer_service.dart';
import '../../core/hardware/printer_service.dart';

class PrinterState {
  final String printerIp;
  final bool isTesting;
  final bool? lastTestResult;
  final bool isPrinting;
  final String? error;

  const PrinterState({
    this.printerIp = '',
    this.isTesting = false,
    this.lastTestResult,
    this.isPrinting = false,
    this.error,
  });

  PrinterState copyWith({
    String? printerIp,
    bool? isTesting,
    bool? lastTestResult,
    bool? isPrinting,
    String? error,
    bool clearError = false,
    bool clearTestResult = false,
  }) => PrinterState(
    printerIp: printerIp ?? this.printerIp,
    isTesting: isTesting ?? this.isTesting,
    lastTestResult: clearTestResult ? null : (lastTestResult ?? this.lastTestResult),
    isPrinting: isPrinting ?? this.isPrinting,
    error: clearError ? null : (error ?? this.error),
  );
}

class PrinterNotifier extends StateNotifier<PrinterState> {
  PrinterNotifier() : super(const PrinterState()) {
    _loadSavedIp();
  }

  final _service = createPrinterService();
  static const _ipKey = 'printer_ip';

  Future<void> _loadSavedIp() async {
    final prefs = await SharedPreferences.getInstance();
    final ip = prefs.getString(_ipKey) ?? '';
    state = state.copyWith(printerIp: ip);
  }

  Future<void> setIp(String ip) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_ipKey, ip.trim());
    state = state.copyWith(printerIp: ip.trim(), clearTestResult: true);
  }

  Future<void> testConnection() async {
    if (state.printerIp.isEmpty) {
      state = state.copyWith(error: 'IP 주소를 먼저 입력해주세요.');
      return;
    }
    state = state.copyWith(isTesting: true, clearError: true, clearTestResult: true);
    final ok = await _service.testConnection(state.printerIp);
    state = state.copyWith(isTesting: false, lastTestResult: ok);
  }

  Future<PrintResult> print(List<int> bytes) async {
    if (state.printerIp.isEmpty) return PrintResult.connectionFailed;
    state = state.copyWith(isPrinting: true, clearError: true);
    final result = await _service.printReceipt(state.printerIp, bytes);
    state = state.copyWith(isPrinting: false);
    if (result == PrintResult.connectionFailed) {
      state = state.copyWith(error: '프린터 연결 실패. IP를 확인해주세요.');
    }
    return result;
  }
}

final printerProvider = StateNotifierProvider<PrinterNotifier, PrinterState>(
  (ref) => PrinterNotifier(),
);
```

Note: Add `shared_preferences` to pubspec.yaml:
```yaml
  shared_preferences: ^2.3.2
```

---

## Task 5: Settings Tab - Printer IP Input

In lib/features/admin/tabs/settings_tab.dart:

Add a "프린터 설정" section BEFORE the "Danger Zone" section:

```
Section: 프린터 설정 (영수증 프린터)

  Info text:
    "Xprinter XP-K200W WiFi 연결"
    "프린터와 태블릿이 같은 WiFi 네트워크에 있어야 합니다."

  IP Address TextField:
    - Label: "프린터 IP 주소"
    - Hint: "예: 192.168.1.100"
    - keyboardType: TextInputType.number
    - controller bound to printerProvider ip
    - onChanged: ref.read(printerProvider.notifier).setIp(value)

  Row of 2 buttons:
    Left: "연결 테스트" button (outlined, amber)
      - onTap: ref.read(printerProvider.notifier).testConnection()
      - when isTesting: show loading indicator
    Right: "테스트 출력" button (filled, amber)
      - onTap: print a test receipt with dummy data

  Status indicator below:
    - if lastTestResult == true: green dot + "연결됨"
    - if lastTestResult == false: red dot + "연결 실패"
    - if lastTestResult == null: grey dot + "미확인"
```

---

## Task 6: Auto-print after payment in Cashier Screen

In lib/features/cashier/cashier_screen.dart:

After successful payment (paymentSuccess == true):
1. Build receipt bytes using ReceiptBuilder.buildPaymentReceipt()
2. Call ref.read(printerProvider.notifier).print(bytes)
3. If print fails: show warning toast "결제 완료. 영수증 출력 실패 - 프린터를 확인해주세요."
4. If print succeeds: no extra notification (receipt prints silently)
5. If printerIp is empty: skip printing silently

To get order items for receipt:
- Use paymentState.selectedOrder (CashierOrder has items and totalAmount)
- Map CashierOrder.items to List<ReceiptItem>

Also add a "영수증 재출력" button in the order detail panel:
- Small outlined button, top right of the right panel
- Only shown when an order is selected
- Label: "🖨 영수증"
- Calls the same print logic

---

## Task 7: Web guard

In cashier_screen.dart and settings_tab.dart:
- Import: `import 'package:flutter/foundation.dart' show kIsWeb;`
- When kIsWeb and user taps print: show toast "프린터는 앱에서만 지원됩니다."

---

## Rules
- shared_preferences: add to pubspec.yaml and run flutter pub get
- Never hardcode printer IP in code
- All printer calls go through PrinterProvider, never directly from widgets
- Web: always noop/toast, never try TCP socket
- Run flutter analyze → fix ALL errors
- flutter build macos → must pass
- flutter build web --release → must pass
- flutter build apk --release → must pass
- git add -A && git commit -m "feat: XP-K200W WiFi printer integration - receipt builder, printer provider, settings IP config, auto-print on payment" && git push
