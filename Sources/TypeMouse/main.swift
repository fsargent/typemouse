import AppKit

let arguments = CommandLine.arguments

// Diagnostics can run inside the app bundle (`open TypeMouse.app --args --dump --out FILE`),
// so they use the app's own Accessibility permission instead of the terminal's.
if let i = arguments.firstIndex(of: "--out"), i + 1 < arguments.count {
    freopen(arguments[i + 1], "w", stdout)
    freopen(arguments[i + 1], "a", stderr)
    setvbuf(stdout, nil, _IOLBF, 0)
}

if arguments.contains("--help") {
    print("""
    TypeMouse: keyboard clicking and window switching.

      TypeMouse                     run the menu-bar app
      TypeMouse --dump [--app NAME] list click targets in an app's focused window, with timing
      TypeMouse --windows           list windows with their window-mode labels
      TypeMouse --disable-login-item  stop launching at login (run through `open`)
      --out FILE                  write diagnostics output to FILE
    """)
    exit(0)
}
if arguments.contains("--disable-login-item") {
    LoginItem.set(false)
    Log.flush()
    exit(0)
}
if arguments.contains("--dump") { exit(Diagnostics.dump(arguments)) }
if arguments.contains("--windows") { exit(Diagnostics.windows()) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
