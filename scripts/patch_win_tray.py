#!/usr/bin/env python3
"""Inject native Win32 System Tray (minimize to tray on X close + right-click menu) into Flutter Windows runner."""
import pathlib


def main():
    hdr_p = pathlib.Path("windows/runner/flutter_window.h")
    cpp_p = pathlib.Path("windows/runner/flutter_window.cpp")

    hdr = hdr_p.read_text(encoding="utf-8")
    if "shellapi.h" not in hdr:
        hdr = "#include <shellapi.h>\n" + hdr
    if "allow_real_close_" not in hdr:
        hdr = hdr.replace(
            "std::unique_ptr<flutter::FlutterViewController> flutter_controller_;",
            "std::unique_ptr<flutter::FlutterViewController> flutter_controller_;\n"
            "  bool allow_real_close_ = false;\n"
            "  bool tray_added_ = false;\n"
            "  NOTIFYICONDATAW tray_nid_{};",
            1,
        )
    hdr_p.write_text(hdr, encoding="utf-8")

    cpp = cpp_p.read_text(encoding="utf-8")
    if '"resource.h"' not in cpp:
        cpp = '#include "resource.h"\n' + cpp

    tray_init = (
        "  // v2.5.1: Native Win32 System Tray\n"
        "  tray_nid_.cbSize = sizeof(NOTIFYICONDATAW);\n"
        "  tray_nid_.hWnd = GetHandle();\n"
        "  tray_nid_.uID = 1001;\n"
        "  tray_nid_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;\n"
        "  tray_nid_.uCallbackMessage = WM_APP + 42;\n"
        "  tray_nid_.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));\n"
        '  wcscpy_s(tray_nid_.szTip, L"Mayak P2P");\n'
        "  tray_added_ = Shell_NotifyIconW(NIM_ADD, &tray_nid_) != FALSE;\n"
        "  return true;"
    )
    assert "  return true;" in cpp, "OnCreate return true anchor missing"
    cpp = cpp.replace("  return true;", tray_init, 1)

    tray_destroy = (
        "  if (tray_added_) {\n"
        "    Shell_NotifyIconW(NIM_DELETE, &tray_nid_);\n"
        "    tray_added_ = false;\n"
        "  }\n"
        "  Win32Window::OnDestroy();"
    )
    assert "  Win32Window::OnDestroy();" in cpp, "OnDestroy anchor missing"
    cpp = cpp.replace("  Win32Window::OnDestroy();", tray_destroy, 1)

    tray_msg = (
        "  switch (message) {\n"
        "    case WM_CLOSE:\n"
        "      if (!allow_real_close_) {\n"
        "        ShowWindow(hwnd, SW_HIDE);\n"
        "        return 0;\n"
        "      }\n"
        "      break;\n"
        "    case WM_APP + 42: {\n"
        "      if (lparam == WM_LBUTTONUP || lparam == WM_LBUTTONDBLCLK) {\n"
        "        ShowWindow(hwnd, SW_SHOW);\n"
        "        ShowWindow(hwnd, SW_RESTORE);\n"
        "        SetForegroundWindow(hwnd);\n"
        "        return 0;\n"
        "      }\n"
        "      if (lparam == WM_RBUTTONUP || lparam == WM_CONTEXTMENU) {\n"
        "        POINT pt;\n"
        "        GetCursorPos(&pt);\n"
        "        HMENU menu = CreatePopupMenu();\n"
        '        AppendMenuW(menu, MF_STRING, 2001, L"\\u041e\\u0442\\u043a\\u0440\\u044b\\u0442\\u044c \\u041c\\u0430\\u044f\\u043a");\n'
        '        AppendMenuW(menu, MF_STRING, 2002, L"\\u0421\\u0432\\u0435\\u0440\\u043d\\u0443\\u0442\\u044c \\u0432 \\u0442\\u0440\\u0435\\u0439");\n'
        "        AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);\n"
        '        AppendMenuW(menu, MF_STRING, 2003, L"\\u0412\\u044b\\u0445\\u043e\\u0434 \\u0438\\u0437 \\u041c\\u0430\\u044f\\u043a\\u0430");\n'
        "        SetForegroundWindow(hwnd);\n"
        "        UINT cmd = TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_NONOTIFY | TPM_RETURNCMD, pt.x, pt.y, 0, hwnd, nullptr);\n"
        "        DestroyMenu(menu);\n"
        "        if (cmd == 2001) {\n"
        "          ShowWindow(hwnd, SW_SHOW);\n"
        "          ShowWindow(hwnd, SW_RESTORE);\n"
        "          SetForegroundWindow(hwnd);\n"
        "        } else if (cmd == 2002) {\n"
        "          ShowWindow(hwnd, SW_HIDE);\n"
        "        } else if (cmd == 2003) {\n"
        "          allow_real_close_ = true;\n"
        "          if (tray_added_) {\n"
        "            Shell_NotifyIconW(NIM_DELETE, &tray_nid_);\n"
        "            tray_added_ = false;\n"
        "          }\n"
        "          PostMessage(hwnd, WM_CLOSE, 0, 0);\n"
        "        }\n"
        "        return 0;\n"
        "      }\n"
        "      break;\n"
        "    }"
    )
    assert "  switch (message) {" in cpp, "MessageHandler switch anchor missing"
    cpp = cpp.replace("  switch (message) {", tray_msg, 1)
    cpp_p.write_text(cpp, encoding="utf-8")
    print("OK: Windows System Tray injected into flutter_window.h/.cpp")


if __name__ == "__main__":
    main()
