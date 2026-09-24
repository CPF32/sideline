import SwiftUI
import UIKit

/// Lightweight chrome for the SIDELINE title — not AppState, so pulls don't re-render the whole tab.
@MainActor
final class NavPullChrome: ObservableObject {
    static let shared = NavPullChrome()

    @Published private(set) var progress: CGFloat = 0

    private var lastEmitted: CGFloat = -1

    func setProgress(_ value: CGFloat) {
        let clamped = min(1, max(0, value))
        // Skip tiny changes — cutting SwiftUI churn mid-drag.
        if abs(clamped - lastEmitted) < 0.012, clamped != 0, clamped != 1 { return }
        lastEmitted = clamped
        progress = clamped
    }

    func reset() {
        lastEmitted = -1
        progress = 0
    }
}

/// Custom pull-to-refresh: tracks UIScrollView rubber-band and drives `NavPullChrome`.
struct SidelinePullRefreshScrollModifier: ViewModifier {
    var threshold: CGFloat = 96
    var action: () async -> Void

    @State private var armed = false
    @State private var isRunning = false

    func body(content: Content) -> some View {
        content
            .background {
                ScrollPullDistanceReader { pull in
                    handle(pull: pull)
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .onDisappear {
                if !isRunning {
                    NavPullChrome.shared.reset()
                }
                armed = false
            }
    }

    private func handle(pull: CGFloat) {
        if isRunning {
            NavPullChrome.shared.setProgress(1)
            return
        }

        NavPullChrome.shared.setProgress(pull / threshold)

        if pull >= threshold {
            armed = true
        }

        if armed, pull < threshold * 0.55, !isRunning {
            armed = false
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            Task { await runRefresh() }
        }

        if pull < 2 {
            armed = false
        }
    }

    @MainActor
    private func runRefresh() async {
        guard !isRunning else { return }
        isRunning = true
        NavPullChrome.shared.setProgress(1)
        defer {
            isRunning = false
            NavPullChrome.shared.reset()
        }
        await action()
    }
}

/// Finds the enclosing UIScrollView and reports pull distance past the top.
private struct ScrollPullDistanceReader: UIViewRepresentable {
    var onPull: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPull: onPull)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onPull = onPull
        context.coordinator.attach(from: uiView)
    }

    final class Coordinator {
        var onPull: (CGFloat) -> Void
        private weak var scrollView: UIScrollView?
        private var observation: NSKeyValueObservation?
        private var lastPull: CGFloat = -1

        init(onPull: @escaping (CGFloat) -> Void) {
            self.onPull = onPull
        }

        deinit {
            observation?.invalidate()
        }

        func attach(from view: UIView) {
            if scrollView != nil { return }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                if let scroll = Self.findScrollView(from: view) {
                    self.bind(scroll)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak view] in
                    guard let self, let view, self.scrollView == nil else { return }
                    if let scroll = Self.findScrollView(from: view) {
                        self.bind(scroll)
                    }
                }
            }
        }

        private func bind(_ scroll: UIScrollView) {
            scrollView = scroll
            observation?.invalidate()
            observation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
                guard let self else { return }
                let insetTop = scroll.adjustedContentInset.top
                let pull = max(0, -(scroll.contentOffset.y + insetTop))
                // Drop near-duplicate samples on the scroll thread before hopping to main.
                if abs(pull - self.lastPull) < 0.5, pull > 1 { return }
                self.lastPull = pull
                if Thread.isMainThread {
                    self.onPull(pull)
                } else {
                    DispatchQueue.main.async {
                        self.onPull(pull)
                    }
                }
            }
        }

        private static func findScrollView(from view: UIView) -> UIScrollView? {
            var node: UIView? = view.superview
            while let current = node {
                if let scroll = current as? UIScrollView {
                    return scroll
                }
                if let scroll = firstScrollView(in: current) {
                    return scroll
                }
                node = current.superview
            }
            return nil
        }

        private static func firstScrollView(in root: UIView) -> UIScrollView? {
            var queue: [UIView] = root.subviews
            var i = 0
            while i < queue.count {
                let v = queue[i]
                i += 1
                if let s = v as? UIScrollView { return s }
                queue.append(contentsOf: v.subviews)
            }
            return nil
        }
    }
}

extension View {
    func sidelinePullToRefresh(
        threshold: CGFloat = 96,
        perform action: @escaping () async -> Void
    ) -> some View {
        modifier(SidelinePullRefreshScrollModifier(threshold: threshold, action: action))
    }

    func sidelinePullRefreshReader() -> some View { self }
}
