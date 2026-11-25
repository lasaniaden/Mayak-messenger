#!/usr/bin/env python3
"""Inject native Win32 System Tray, Single-Instance Mutex (no duplicate tray icons), and --minimized support into Flutter Windows runner."""
import pathlib


def main():
    # 1. Patch windows/runner/main.cpp with Single-Instance Win32 Mutex
    main_cpp_p = pathlib.Path("windows/runner/main.cpp")
    main_cpp = main_cpp_p.read_text(encoding="utf-8")
    if "MayakMeshSingleInstanceMutex_v3" not in main_cpp:
        anchor = "int APIENTRY wWinMain("
        assert anchor in main_cpp, "wWinMain anchor missing in main.cpp"
        idx = main_cpp.index("{", main_cpp.index(anchor)) + 1
        mutex_code = (
            "\n  // v3.1.6: Single-Instance protection with --updated graceful handoff wait\n"
            '  bool isUpdatedRelaunch = (command_line != nullptr && ::wcsstr(command_line, L"--updated") != nullptr);\n'
            '  HANDLE hSingleMutex = nullptr;\n'
            "  for (int attempt = 0; attempt < (isUpdatedRelaunch ? 30 : 1); ++attempt) {\n"
            '    hSingleMutex = ::CreateMutexW(nullptr, TRUE, L"Local\\\\MayakMeshSingleInstanceMutex_v3");\n'
            "    if (hSingleMutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {\n"
            "      if (isUpdatedRelaunch && attempt < 29) {\n"
            "        ::CloseHandle(hSingleMutex);\n"
            "        hSingleMutex = nullptr;\n"
            "        ::Sleep(200);\n"
            "        continue;\n"
            "      }\n"
            '      HWND existing = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", nullptr);\n'
            "      if (existing != nullptr) {\n"
            "        ::PostMessageW(existing, WM_APP + 102, 0, 0);\n"
            "        ::ShowWindow(existing, SW_SHOW);\n"
            "        ::ShowWindow(existing, SW_RESTORE);\n"
            "        ::SetForegroundWindow(existing);\n"
            "      }\n"
            "      ::CloseHandle(hSingleMutex);\n"
            "      return EXIT_SUCCESS;\n"
            "    }\n"
            "    break;\n"
            "  }\n"
        )
        main_cpp = main_cpp[:idx] + mutex_code + main_cpp[idx:]
        main_cpp_p.write_text(main_cpp, encoding="utf-8")

    # 2. Patch flutter_window.h
    hdr_p = pathlib.Path("windows/runner/flutter_window.h")
    cpp_p = pathlib.Path("windows/runner/flutter_window.cpp")

    hdr = hdr_p.read_text(encoding="utf-8")
    if "shellapi.h" not in hdr:
        if '#include "win32_window.h"' in hdr:
            hdr = hdr.replace('#include "win32_window.h"', '#include "win32_window.h"\n#include <windows.h>\n#include <shellapi.h>', 1)
        else:
            hdr = "#include <windows.h>\n#include <shellapi.h>\n" + hdr
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

    # 3. Patch flutter_window.cpp
    cpp = cpp_p.read_text(encoding="utf-8")
    if '"resource.h"' not in cpp:
        cpp = '#include "resource.h"\n' + cpp

    tray_init = (
        "  // v3.0.0: Native Win32 System Tray + --minimized autostart support\n"
        "  tray_nid_.cbSize = sizeof(NOTIFYICONDATAW);\n"
        "  tray_nid_.hWnd = GetHandle();\n"
        "  tray_nid_.uID = 1001;\n"
        "  tray_nid_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;\n"
        "  tray_nid_.uCallbackMessage = WM_APP + 42;\n"
        "  tray_nid_.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));\n"
        '  wcscpy_s(tray_nid_.szTip, L"Mayak P2P");\n'
        "  tray_added_ = Shell_NotifyIconW(NIM_ADD, &tray_nid_) != FALSE;\n"
        "  const wchar_t* cmd_line = GetCommandLineW();\n"
        '  if (cmd_line != nullptr && wcsstr(cmd_line, L"--minimized") != nullptr) {\n'
        "    ShowWindow(GetHandle(), SW_HIDE);\n"
        "  }\n"
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
        "    case WM_APP + 102:\n"
        "      ShowWindow(hwnd, SW_SHOW);\n"
        "      ShowWindow(hwnd, SW_RESTORE);\n"
        "      SetForegroundWindow(hwnd);\n"
        "      return 0;\n"
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
    print("OK: Windows Single-Instance + System Tray + --minimized injected")


if __name__ == "__main__":
    main()
