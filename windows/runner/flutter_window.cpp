#include <winsock2.h>
#include <iphlpapi.h>

#include "flutter_window.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <optional>
#include <vector>

#include "flutter/generated_plugin_registrant.h"

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
              !interface_row.InterfaceAndOperStatusFlags.HardwareInterface ||
              interface_row.InterfaceAndOperStatusFlags.FilterInterface ||
              interface_row.InterfaceAndOperStatusFlags.NotMediaConnected ||
              interface_row.InterfaceAndOperStatusFlags.EndPointInterface) {
            continue;
          }
          if (adapter->IfType == IF_TYPE_ETHERNET_CSMACD) {
            wired_connected = true;
          } else if (adapter->IfType == IF_TYPE_IEEE80211) {
            wireless_connected = true;
          }
        }

        flutter::EncodableMap capabilities;
        capabilities[flutter::EncodableValue("wiredConnected")] =
            flutter::EncodableValue(wired_connected);
        capabilities[flutter::EncodableValue("wirelessConnected")] =
            flutter::EncodableValue(wireless_connected);
        result->Success(flutter::EncodableValue(capabilities));
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
