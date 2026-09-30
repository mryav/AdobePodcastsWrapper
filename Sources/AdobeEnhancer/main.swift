import AppKit

// AppKit's startup path is main-thread-only; SwiftPM's synthesized entry point
// isn't main-actor isolated, so assert the isolation we already have.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    // NSApplication keeps only a weak reference to its delegate.
    objc_setAssociatedObject(application, "AdobeEnhancerDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    application.run()
}
