#if !defined(WINVER) || WINVER < 0x0A00
#undef WINVER
#define WINVER 0x0A00
#endif
#if !defined(_WIN32_WINNT) || _WIN32_WINNT < 0x0A00
#undef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#if !defined(NTDDI_VERSION) || NTDDI_VERSION < 0x0A000000
#undef NTDDI_VERSION
#define NTDDI_VERSION 0x0A000000
#endif

#include <winsock2.h>
#include <windows.h>
#include <netioapi.h>
#include <iphlpapi.h>
#include <winspool.h>

#include "flutter_window.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <optional>
#include <string>
#include <variant>
#include <vector>

#include "flutter/generated_plugin_registrant.h"

namespace {

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return std::wstring();
  }
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                       value.data(),
                                       static_cast<int>(value.size()), nullptr,
                                       0);
  if (size <= 0) {
    return std::wstring();
  }
  std::wstring result(size, L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(), size) <=
      0) {
    return std::wstring();
  }
  return result;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  network_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "globos/network_capabilities",
          &flutter::StandardMethodCodec::GetInstance());
  network_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "getNetworkCapabilities") {
          result->NotImplemented();
          return;
        }

        ULONG buffer_size = 15 * 1024;
        const ULONG flags = GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
                            GAA_FLAG_SKIP_DNS_SERVER;
        std::vector<unsigned char> buffer(buffer_size);
        auto* adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
        ULONG status = GetAdaptersAddresses(
            AF_INET, flags, nullptr, adapters, &buffer_size);
        if (status == ERROR_BUFFER_OVERFLOW) {
          buffer.resize(buffer_size);
          adapters =
              reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
          status = GetAdaptersAddresses(AF_INET, flags, nullptr, adapters,
                                        &buffer_size);
        }
        if (status != NO_ERROR) {
          result->Error("NETWORK_ADAPTER_QUERY_FAILED",
                        "Windows could not enumerate network adapters.");
          return;
        }

        bool wired_connected = false;
        bool wireless_connected = false;
        for (auto* adapter = adapters; adapter != nullptr;
             adapter = adapter->Next) {
          if (adapter->OperStatus != IfOperStatusUp ||
              adapter->FirstUnicastAddress == nullptr) {
            continue;
          }

          MIB_IF_ROW2 interface_row{};
          interface_row.InterfaceLuid = adapter->Luid;
          if (GetIfEntry2(&interface_row) != NO_ERROR ||
              interface_row.InterfaceAndOperStatusFlags.FilterInterface ||
              interface_row.InterfaceAndOperStatusFlags.NotMediaConnected) {
            continue;
          }
          if (adapter->IfType == IF_TYPE_IEEE80211) {
            wireless_connected = true;
          } else if (adapter->IfType != IF_TYPE_SOFTWARE_LOOPBACK &&
                     adapter->IfType != IF_TYPE_TUNNEL) {
            // Windows exposes USB, gigabit, dock and bridged Ethernet with
            // several interface types and does not consistently mark all of
            // them as HardwareInterface. Any active, non-filtered IPv4 link
            // that is not Wi-Fi/loopback/tunnel is usable for local printers.
            wired_connected = true;
          }
        }

        flutter::EncodableMap capabilities;
        capabilities[flutter::EncodableValue("wiredConnected")] =
            flutter::EncodableValue(wired_connected);
        capabilities[flutter::EncodableValue("wirelessConnected")] =
            flutter::EncodableValue(wireless_connected);
        result->Success(flutter::EncodableValue(capabilities));
      });
  usb_printer_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "globos/usb_printer",
          &flutter::StandardMethodCodec::GetInstance());
  usb_printer_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "printRaw") {
          result->NotImplemented();
          return;
        }

        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Error("USB_PRINTER_ARGUMENTS_INVALID",
                        "USB printer arguments are required.");
          return;
        }
        const auto name_it =
            arguments->find(flutter::EncodableValue("printerName"));
        const auto bytes_it = arguments->find(flutter::EncodableValue("bytes"));
        if (name_it == arguments->end() || bytes_it == arguments->end()) {
          result->Error("USB_PRINTER_ARGUMENTS_INVALID",
                        "Printer name and raw bytes are required.");
          return;
        }
        const auto* printer_name_utf8 =
            std::get_if<std::string>(&name_it->second);
        const auto* bytes =
            std::get_if<std::vector<uint8_t>>(&bytes_it->second);
        if (printer_name_utf8 == nullptr || printer_name_utf8->empty() ||
            bytes == nullptr || bytes->empty()) {
          result->Error("USB_PRINTER_ARGUMENTS_INVALID",
                        "Printer name and raw bytes must not be empty.");
          return;
        }

        const std::wstring printer_name = Utf8ToWide(*printer_name_utf8);
        if (printer_name.empty()) {
          result->Error("USB_PRINTER_NAME_INVALID",
                        "The Windows printer name is not valid UTF-8.");
          return;
        }

        HANDLE printer = nullptr;
        if (!OpenPrinterW(const_cast<LPWSTR>(printer_name.c_str()), &printer,
                          nullptr)) {
          result->Error("USB_PRINTER_OPEN_FAILED",
                        "Windows could not open the configured printer.");
          return;
        }

        wchar_t document_name[] = L"GLOBOS POS Receipt";
        wchar_t data_type[] = L"RAW";
        DOC_INFO_1W document_info{};
        document_info.pDocName = document_name;
        document_info.pDatatype = data_type;
        const DWORD document_id =
            StartDocPrinterW(printer, 1, reinterpret_cast<LPBYTE>(&document_info));
        if (document_id == 0) {
          ClosePrinter(printer);
          result->Error("USB_PRINTER_DOCUMENT_FAILED",
                        "Windows could not start the raw print document.");
          return;
        }

        bool ok = StartPagePrinter(printer) != FALSE;
        DWORD written = 0;
        if (ok) {
          ok = WritePrinter(printer, const_cast<uint8_t*>(bytes->data()),
                            static_cast<DWORD>(bytes->size()), &written) != FALSE &&
               written == static_cast<DWORD>(bytes->size());
          EndPagePrinter(printer);
        }
        EndDocPrinter(printer);
        ClosePrinter(printer);

        if (!ok) {
          result->Error("USB_PRINTER_WRITE_FAILED",
                        "Windows could not write all raw receipt bytes.");
          return;
        }
        result->Success(flutter::EncodableValue(true));
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  usb_printer_channel_.reset();
  network_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
