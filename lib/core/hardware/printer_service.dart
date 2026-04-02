abstract class PrinterService {
  bool get isSupported;
  Future<bool> testConnection(String ip, {int port = 9100});
  Future<PrintResult> printReceipt(
    String ip,
    List<int> bytes, {
    int port = 9100,
  });
}

enum PrintResult { success, connectionFailed, printFailed, notSupported }
