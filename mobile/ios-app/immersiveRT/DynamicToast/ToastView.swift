import SwiftUI

extension View {
    /// duration
    ///
    /// `forceStatusBarHidden`: an ADDITIONAL, independent reason to keep the
    /// status bar hidden regardless of whether a toast is currently
    /// presented (D-13/connected-session chrome, `ActiveSessionView.swift`).
    /// See `DynamicIslandToastViewModifier`'s doc comment for why this has
    /// to live here rather than as a separate `.statusBar(hidden:)`/
    /// `.toolbar(.hidden, for: .statusBar)` modifier applied elsewhere.
    @ViewBuilder
    func dynamicIslandToast(
        isPresented: Binding<Bool>,
        duration: TimeInterval? = nil,
        forceStatusBarHidden: Bool = false,
        value: Toast
    ) -> some View {
        self.modifier(
            DynamicIslandToastViewModifier(
                isPresented: isPresented,
                duration: duration,
                value: value,
                forceStatusBarHidden: forceStatusBarHidden
            )
        )
    }
}

/// PLATFORM NOTE (on-device bug report: "you didn't hide the status bar" —
/// this held even after switching to SwiftUI's native `.statusBar(hidden:)`
/// modifier on `ActiveSessionView`'s own content): this toast overlay window
/// (`PassThroughWindow`, tag 1009) is created once, the FIRST time ANY
/// `dynamicIslandToast(...)` call site appears on screen (`ContentView`
/// always has one, so it exists from app launch), is cached/reused for the
/// app's whole lifetime via the `windowScene.windows.first(where: { $0.tag
/// == 1009 })` lookup in `createOverlayWindow(_:)` below, and sits ABOVE the
/// main `WindowGroup` window at the same window level. Because it is a
/// SEPARATE `UIWindow` with its OWN `rootViewController`
/// (`CustomHostingView`), its `prefersStatusBarHidden` — previously driven
/// ONLY by whether a toast happens to be presented — wins over ANY
/// status-bar preference set on the main window's content, including both
/// the earlier `UIViewControllerRepresentable`-forwarding attempt AND
/// SwiftUI's native `.statusBar(hidden:)`/`.toolbar(.hidden, for:
/// .statusBar)` modifiers, which only affect the main window. There is only
/// one real fix: route the "should the status bar be hidden" decision
/// through THIS window's controller too. `forceStatusBarHidden` is that
/// route — the actual visible-status-bar state is
/// `isPresented || forceStatusBarHidden`, computed in `updateStatusBar()`.
struct DynamicIslandToastViewModifier : ViewModifier {
    @Binding var isPresented: Bool
    var duration: TimeInterval?
    var value: Toast
    var forceStatusBarHidden: Bool = false
    // View Properties
    @State private var overlayWindow: PassThroughWindow?
    @State private var overlayController: CustomHostingView?
    @State private var dismissTask: Task<Void, Never>?
    func body(content: Content) -> some View {
        content
            .background(WindowExtractor { mainWindow in
                createOverlayWindow(mainWindow)
            })
            .onChange(of: isPresented, initial: true) {
                oldValue, newValue in guard let overlayWindow else {return}
                if newValue {
                    // Setting Current Toast
                    overlayWindow.toast = value
                }
                overlayWindow.isPresented = newValue
                updateStatusBar()
                scheduleAutoDismiss(newValue)
            }
            // `forceStatusBarHidden` can flip independently of any toast
            // ever being presented (e.g. a session connecting with no
            // toast on screen) — needs its own trigger to reach the
            // overlay window's controller.
            .onChange(of: forceStatusBarHidden, initial: true) { _, _ in
                updateStatusBar()
            }
        // If the toast is closed outside we need to update the isPresented Property as well
            .onChange(of: overlayWindow?.isPresented) { oldValue, newValue in if let newValue, let overlayWindow, overlayWindow.toast?.id == value.id, newValue != isPresented {
                isPresented = false
            }}
    }

    private func updateStatusBar() {
        overlayController?.isStatusBarHidden = isPresented || forceStatusBarHidden
    }
    
    // Auto dismiss: hides the toast after the optional duration, cancelling if it's dismissed or re-presented first
    private func scheduleAutoDismiss(_ isPresented: Bool) {
        dismissTask?.cancel()
        dismissTask = nil
        guard isPresented, let duration else { return }
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self.isPresented = false
        }
    }

    private func createOverlayWindow(_ mainWindow: UIWindow) {
        guard let windowScene = mainWindow.windowScene else { return }

        if let window = windowScene.windows.first(where: {$0.tag == 1009}) as? PassThroughWindow {
            print("Using Already Existing Window")
            self.overlayWindow = window
            self.overlayController = window.rootViewController as? CustomHostingView
        } else{
            let overlayWindow = PassThroughWindow(windowScene: windowScene)
            overlayWindow.backgroundColor = .clear
            overlayWindow.isHidden = false
            overlayWindow.isUserInteractionEnabled = true
            overlayWindow.tag = 1009
            createRootController(overlayWindow)

            self.overlayWindow = overlayWindow
        }
        // `overlayController` was nil (window not created yet) when the
        // initial isPresented/forceStatusBarHidden onChange fired at
        // attachment time, so that update was silently dropped — apply the
        // current combined state now that the controller actually exists.
        updateStatusBar()
    }
    
    private func createRootController(_ window: PassThroughWindow) {
        let hostingController = CustomHostingView(rootView: ToastView(window: window))
        
        hostingController.view.backgroundColor = .clear
        window.rootViewController = hostingController
        
        self.overlayController = hostingController
    }
}

struct ToastView: View {
    var window: PassThroughWindow
    var body: some View {
        GeometryReader{
            let safeArea = $0.safeAreaInsets
            let size = $0.size
            
            // Dynamic Island
            let haveDynamicIsland: Bool = safeArea.top >= 59
            let dynamicIslandWidth: CGFloat = 124.666
            let dynamicIslandHeight: CGFloat = 36
            let topOffset: CGFloat = 11.1666
            + max((safeArea.top - 59),0)
            
            // Expanded Properties
            let expandedWidth: CGFloat = size.width - 20
            let expandedHeight: CGFloat = haveDynamicIsland ? 90 : 70
            let scaleX: CGFloat = isExpanded ? 1 : (dynamicIslandWidth / expandedWidth)
            let scaleY: CGFloat = isExpanded ? 1 : (dynamicIslandHeight / expandedHeight)
            
            ZStack {
                ConcentricRectangle(corners: .concentric(minimum: .fixed(30)), isUniform: true)
                    .fill(Color.black)
                    .overlay {
                        ToastContent(haveDynamicIsland)
                            // Keeping the exact expanded size and using the scale to shrink and fit
                            // Avoids any text wraps and other such things
                            .frame(width: expandedWidth, height: expandedHeight)
                            .scaleEffect(x: scaleX, y: scaleY)
                    }
                    .frame(width: isExpanded ? expandedWidth : dynamicIslandWidth, height: isExpanded ? expandedHeight : dynamicIslandHeight)
                    .offset(
                        y: haveDynamicIsland ? topOffset : (isExpanded ? safeArea.top + 10 : -80))
                    // For Non Dynamic Island Based Phones
                    .opacity(haveDynamicIsland ? 1 : (isExpanded ? 1 : 0))
                    // For Dynamic Island Based Phones
                    // Showing capsule when the effect is active and hiding it when it's not
                    .animation(.linear(duration: 0.02).delay(isExpanded ? 0 : 0.28)) {
                        content in content.opacity(haveDynamicIsland ? isExpanded ? 1 : 0 : 1)
                    }
                    .geometryGroup()
                    .contentShape(.rect)
                    .gesture(DragGesture().onEnded{
                        value in if value.translation.height < 0 {
                            // Dismiss
                            window.isPresented = false
                        }
                    })
                
            }
            .frame(maxWidth: .infinity,maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .animation(.bouncy(duration: 0.3,extraBounce: 0), value: isExpanded)
        }
    }
    
    // Toast View Content
    @ViewBuilder
    func ToastContent(_ haveDynamicIsland: Bool) -> some View {
        if let toast = window.toast {
            HStack(spacing: 10) {
                Image(systemName: toast.symbol)
                    .font(toast.symbolFont)
                    .foregroundStyle(toast.symbolForegroundStyle.0, toast.symbolForegroundStyle.1).symbolEffect(.wiggle,options: .default.speed(1.5), value: isExpanded)
                    .frame(width: 50)
                
                VStack(alignment: .leading, spacing: 4) {
                    if haveDynamicIsland{
                        Spacer(minLength: 0)
                    }
                    
                    Text(toast.title).font(.callout).fontWeight(.semibold).foregroundStyle(.white)
                    
                    Text(toast.message).font(.caption).foregroundStyle(.white.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, haveDynamicIsland ? 12 : 0)
                .lineLimit(1)
            }
            .padding(.horizontal, 20)
            .compositingGroup()
            .blur(radius: isExpanded ? 0 : 5)
            .opacity(isExpanded ? 1 : 0)
        }
    }
    
    var isExpanded: Bool {
        window.isPresented
    }
}

#Preview {
    ContentView()
}
