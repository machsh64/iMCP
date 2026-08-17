import AppKit
import SwiftUI

struct ConnectionApprovalView: View {
    let clientName: String
    let onApprove: (Bool) -> Void  // Bool parameter is for "always trust"
    let onDeny: () -> Void

    @State private var alwaysTrust = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Icon
            Image(.menuIconOn)
                .resizable()
                .foregroundColor(.accentColor)
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)

            // Title
            Text("Client Connection Request")
                .font(.title2)
                .fontWeight(.semibold)

            // Message
            VStack(alignment: .leading, spacing: 8) {
                Text("Allow \"\(clientName)\" to connect to iMCP?")

                Text("This will give the client access to enabled services.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
            }

            // Always trust checkbox
            HStack(alignment: .firstTextBaseline) {
                Toggle("Always trust this client", isOn: $alwaysTrust)
                    .toggleStyle(CheckboxToggleStyle())
                Spacer()
            }
            .padding(.bottom, 20)

            // Buttons
            HStack(spacing: 12) {
                Button("Deny") {
                    onDeny()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button("Allow") {
                    onApprove(alwaysTrust)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400, height: 300)
        .fixedSize()
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .shadow(radius: 10)
    }
}

struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                .foregroundColor(configuration.isOn ? .accentColor : .secondary)
                .accessibilityLabel(
                    configuration.isOn ? "Always trust this client, checked" : "Always trust this client, unchecked"
                )
                .onTapGesture {
                    configuration.isOn.toggle()
                }

            configuration.label
                .onTapGesture {
                    configuration.isOn.toggle()
                }
        }
    }
}

@MainActor
class ConnectionApprovalWindowController: NSObject, NSWindowDelegate {
    /// 每个窗口独立的审批上下文，支持多个客户端并发审批
    private final class ApprovalContext {
        var onApprove: (Bool) -> Void
        var onDeny: () -> Void
        var hasResolved = false

        init(onApprove: @escaping (Bool) -> Void, onDeny: @escaping () -> Void) {
            self.onApprove = onApprove
            self.onDeny = onDeny
        }
    }

    private var windows: [NSWindow] = []
    private var contexts: [ObjectIdentifier: ApprovalContext] = [:]

    func showApprovalWindow(
        clientName: String,
        onApprove: @escaping (Bool) -> Void,
        onDeny: @escaping () -> Void
    ) {
        let context = ApprovalContext(onApprove: onApprove, onDeny: onDeny)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.title = "Connection Request"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.isMovableByWindowBackground = false
        window.titlebarAppearsTransparent = false
        // 监听窗口关闭（用户点红色关闭按钮）→ 触发 deny
        window.delegate = self

        // 创建 SwiftUI 视图，按钮回调通过 resolve 统一处理
        let approvalView = ConnectionApprovalView(
            clientName: clientName,
            onApprove: { [weak self, weak window] alwaysTrust in
                guard let self, let window else { return }
                self.resolve(
                    window: window,
                    context: context,
                    approved: true,
                    alwaysTrust: alwaysTrust
                )
            },
            onDeny: { [weak self, weak window] in
                guard let self, let window else { return }
                self.resolve(
                    window: window,
                    context: context,
                    approved: false,
                    alwaysTrust: false
                )
            }
        )

        window.contentViewController = NSHostingController(rootView: approvalView)

        // Store references（每个窗口独立，互不覆盖）
        windows.append(window)
        contexts[ObjectIdentifier(window)] = context

        // 每次弹出时平铺窗口，避免重叠
        positionWindow(window, offsetBy: CGFloat(windows.count - 1) * 24)

        // Activate the app first
        NSApp.activate(ignoringOtherApps: true)

        // Show the window
        window.makeKeyAndOrderFront(nil)
    }

    /// 统一处理审批结果（按钮点击或窗口关闭）
    private func resolve(
        window: NSWindow,
        context: ApprovalContext,
        approved: Bool,
        alwaysTrust: Bool
    ) {
        guard !context.hasResolved else { return }
        context.hasResolved = true
        if approved {
            context.onApprove(alwaysTrust)
        } else {
            context.onDeny()
        }
        closeWindow(window)
    }

    /// 用户点击红色关闭按钮时触发（未通过按钮 resolve → 视为 Deny）
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            let context = contexts[ObjectIdentifier(window)]
        else { return }
        resolve(window: window, context: context, approved: false, alwaysTrust: false)
    }

    private func closeWindow(_ window: NSWindow) {
        window.close()
        contexts.removeValue(forKey: ObjectIdentifier(window))
        windows.removeAll { $0 === window }
    }

    /// 将窗口平铺居中定位，避免多窗口重叠
    private func positionWindow(_ window: NSWindow, offsetBy offset: CGFloat) {
        window.center()
        guard let screen = NSScreen.main else { return }
        let screenRect = screen.visibleFrame
        let windowRect = window.frame
        let x = (screenRect.width - windowRect.width) / 2 + screenRect.origin.x + offset
        let y = (screenRect.height - windowRect.height) / 2 + screenRect.origin.y - offset
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

#Preview {
    ConnectionApprovalView(
        clientName: "Claude Desktop",
        onApprove: { alwaysTrust in
            print("Approved with always trust: \(alwaysTrust)")
        },
        onDeny: {
            print("Denied")
        }
    )
    .frame(width: 500, height: 400)
}
