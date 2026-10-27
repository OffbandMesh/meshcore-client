#include "flutter_window.h"

#include <windows.h>

#include <flutter/standard_method_codec.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  // Destroy the controller with the member ALREADY null. (#984)
  //
  // This destructor is reached without OnDestroy() having run whenever the
  // message loop ends before the window is destroyed. windowManager.destroy()
  // does exactly that: in window_manager 0.5.2, Destroy() is only
  // PostQuitMessage(0), so WM_DESTROY is never sent and OnDestroy()'s safe
  // reset never happens.
  //
  // Left to the member destructor, the controller was deleted by
  // ~unique_ptr, which in MSVC does NOT null the pointer first (reset() does).
  // While the engine tore down, the still-live top-level window received a
  // message, MessageHandler saw a non-null flutter_controller_, and forwarded
  // into the half-destroyed view: FlutterWindowsView::GetEngine read freed
  // memory and the app crashed on close.
  //
  // Moving it out leaves flutter_controller_ null for the whole teardown, so
  // MessageHandler's guard holds no matter which path ended the loop.
  auto controller = std::move(flutter_controller_);
  controller.reset();
}

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

  // Taskbar flash channel - Dart flashes the taskbar button on a new message
  // when the window isn't focused (see lib/services/windows_taskbar_service.dart).
  taskbar_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "meshcore_open/windows_taskbar",
          &flutter::StandardMethodCodec::GetInstance());
  taskbar_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "flash") {
          HWND hwnd = GetHandle();
          if (hwnd != nullptr && GetForegroundWindow() != hwnd) {
            FLASHWINFO info = {};
            info.cbSize = static_cast<UINT>(sizeof(info));
            info.hwnd = hwnd;
            info.dwFlags = FLASHW_TRAY | FLASHW_TIMERNOFG;
            info.uCount = 0;
            info.dwTimeout = 0;
            FlashWindowEx(&info);
          }
          result->Success();
        } else {
          result->NotImplemented();
        }
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
