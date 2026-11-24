import AVFoundation
import Foundation
import SafariServices
import UIKit
import WebKit

/// The wrapped browser.
///
/// Most of this file exists because of specific, documented failures in the app
/// we are cloning. Each one is annotated with the symptom it prevents — none of
/// this is defensive boilerplate.
final class WrappedWebViewController: UIViewController {

    private let session: WebSession
    private let startURL: URL
    private let engineSource: String
    private let bundleRaw: Data
    private let settings: [String: Bool]
    private let telemetry: Bool
    private let onBridge: (BridgeMessage) -> Void

    private var webView: WKWebView!
    private var restorationState: Data?
    private var refreshControl: UIRefreshControl?
    private var progressView: UIProgressView!
    private var progressObservation: NSKeyValueObservation?

    init(session: WebSession,
         startURL: URL,
         dataStore: WKWebsiteDataStore,
         engineSource: String,
         bundleRaw: Data,
         settings: [String: Bool],
         telemetry: Bool,
         onBridge: @escaping (BridgeMessage) -> Void) {
        self.session = session
        self.startURL = startURL
        self.engineSource = engineSource
        self.bundleRaw = bundleRaw
        self.settings = settings
        self.telemetry = telemetry
        self.onBridge = onBridge
        super.init(nibName: nil, bundle: nil)
        configure(dataStore: dataStore)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    // MARK: - Configuration

    private func configure(dataStore: WKWebsiteDataStore) {
        let controller = WKUserContentController()

        // The engine runs at documentStart so blocking CSS lands before first
        // paint. Injecting at documentEnd would let a Reel render and then
        // vanish, and that flicker is what makes a blocker feel broken.
        let config = engineConfigJSON()
        let bootstrap = """
        window.__NOSCROLL_CONFIG = \(config);
        \(engineSource)
        """
        controller.addUserScript(WKUserScript(source: bootstrap,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        controller.add(BridgeHandler(onBridge), name: "noscroll")

        let nativeTouchStyleScript = """
        (function() {
            var h = (location.hostname || '').toLowerCase();
            var p = (location.pathname || '').toLowerCase();
            if (h === 'appleid.apple.com' || h === 'accounts.google.com' || h === 'consent.google.com' ||
                h === 'accounts.youtube.com' || h === 'login.microsoftonline.com' ||
                h.endsWith('.accounts.google.com') ||
                p.startsWith('/accounts/') || p.startsWith('/challenge/') || p.startsWith('/oauth/') ||
                p.startsWith('/signin') || p.startsWith('/login') || p.startsWith('/emailsignup') ||
                p.startsWith('/recover') || p.startsWith('/two_factor') || p.startsWith('/2fa') ||
                p.startsWith('/verify')) {
                return;
            }
            if (document.getElementById('noscroll-native-touch')) return;
            var style = document.createElement('style');
            style.id = 'noscroll-native-touch';
            style.textContent = `
                * {
                    -webkit-tap-highlight-color: transparent !important;
                }
                nav, header, footer, [role="navigation"], [role="tablist"], [role="button"], button {
                    -webkit-touch-callout: none !important;
                }
            `;
            var target = document.head || document.documentElement;
            if (target) {
                target.appendChild(style);
            } else {
                document.addEventListener('DOMContentLoaded', function() {
                    var t = document.head || document.documentElement;
                    if (t && !document.getElementById('noscroll-native-touch')) t.appendChild(style);
                });
            }
        })();
        """
        controller.addUserScript(WKUserScript(source: nativeTouchStyleScript,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))

        let cfg = WKWebViewConfiguration()
        cfg.userContentController = controller
        cfg.websiteDataStore = dataStore

        // Without these, video plays fullscreen-only and is silent unless the
        // ringer is on.
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []

        // Apple 2.5.6: WKWebView only. We use the stock mobile user agent
        // unmodified — a custom UA is a fingerprint that raises the rate of
        // "suspicious login attempt" checkpoints against our users' accounts.
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
    }

    private func engineConfigJSON() -> String {
        let bundleJSON = String(data: bundleRaw, encoding: .utf8) ?? "{}"
        let settingsJSON = (try? JSONSerialization.data(withJSONObject: settings))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        { "bundle": \(bundleJSON), "settings": \(settingsJSON), "telemetry": \(telemetry) }
        """
    }

    // MARK: - Lifecycle

    override func loadView() {
        let container = UIView()
        container.backgroundColor = .systemBackground

        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)

        progressView = UIProgressView(progressViewStyle: .bar)
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.progressTintColor = UIColor(red: 20/255.0, green: 20/255.0, blue: 20/255.0, alpha: 1.0)
        progressView.trackTintColor = .clear
        progressView.alpha = 0.0
        container.addSubview(progressView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            progressView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2.5)
        ])

        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureAudioSession()
        setupRefreshControl()
        setupProgressObserver()
        restoreOrLoad()

        NotificationCenter.default.addObserver(
            self, selector: #selector(saveState),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
    }

    private func setupRefreshControl() {
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        webView.scrollView.refreshControl = refresh
        self.refreshControl = refresh
    }

    @objc private func handleRefresh() {
        guard let url = webView.url,
              let host = url.host,
              !host.isEmpty,
              url.absoluteString != "about:blank" else {
            webView.load(URLRequest(url: homeURL()))
            return
        }
        webView.reload()
    }

    private func setupProgressObserver() {
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.updateProgress(Float(webView.estimatedProgress))
            }
        }
    }

    private func updateProgress(_ progress: Float) {
        if progress >= 1.0 {
            progressView.setProgress(1.0, animated: true)
            UIView.animate(withDuration: 0.25, delay: 0.1, options: .curveEaseOut, animations: { [weak self] in
                self?.progressView.alpha = 0.0
            }, completion: { [weak self] _ in
                guard let self = self else { return }
                if self.progressView.alpha == 0.0 {
                    self.progressView.setProgress(0.0, animated: false)
                }
            })
        } else if progress > 0.0 {
            progressView.layer.removeAllAnimations()
            progressView.alpha = 1.0
            progressView.setProgress(progress, animated: true)
        }
    }

    private func dismissProgress() {
        if progressView.alpha > 0.0 {
            progressView.layer.removeAllAnimations()
            UIView.animate(withDuration: 0.2, animations: {
                self.progressView.alpha = 0.0
            }, completion: { [weak self] _ in
                guard let self = self else { return }
                if self.progressView.alpha == 0.0 {
                    self.progressView.setProgress(0.0, animated: false)
                }
            })
        }
    }

    deinit {
        progressObservation?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    /// Video that plays silently unless the ringer is on is an audio-session
    /// problem, not a WebKit one.
    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    /// iOS reaps the WebView process under memory pressure. Without restoration,
    /// switching to an authenticator app during 2FA and coming back produces a
    /// white screen and forces a restart — which blocks login entirely. That is
    /// the worst failure of a wrapped web app, because the user cannot get past it.
    private func restoreOrLoad() {
        if let state = restorationState ?? UserDefaults.standard.data(forKey: stateKey) {
            webView.interactionState = state
            return
        }
        webView.load(URLRequest(url: homeURL()))
    }

    private var stateKey: String { "noscroll.state.\(session.id.uuidString)" }

    @objc private func saveState() {
        if let state = webView.interactionState as? Data {
            restorationState = state
            UserDefaults.standard.set(state, forKey: stateKey)
        }
    }

    /// Supplied by the caller from the service definition. It used to be a
    /// switch over two hardcoded cases with `default: instagram`, which sent
    /// all six other services to Instagram.
    private func homeURL() -> URL { startURL }

    /// The service's own domains, from the `match` patterns of its rule bundle (ServiceLinks, NoScrollCore).
    private lazy var serviceDomains: [String] = {
        let match = (try? JSONDecoder().decode(RuleBundle.self, from: bundleRaw))?.services[session.service]?.match ?? []
        let domains = ServiceLinks.domains(fromMatch: match)
        return domains.isEmpty ? [startURL.host?.lowercased() ?? ""].filter { !$0.isEmpty } : domains
    }()

    /// A link that leaves the service: the in-app Safari sheet shows it. The web view never shows another site.
    private func openOutside(_ url: URL) {
        guard presentedViewController == nil else { return }
        let safari = SFSafariViewController(url: url)
        safari.dismissButtonStyle = .close
        present(safari, animated: true)
    }
}

// MARK: - Navigation delegate

extension WrappedWebViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        // Main frame only: iframes are ads or embeds, which stay in the web view.
        guard navigationAction.targetFrame?.isMainFrame ?? true else {
            decisionHandler(.allow)
            return
        }

        // Internal navigation stays inside the web view.
        if ServiceLinks.staysInApp(url, serviceDomains: serviceDomains) {
            decisionHandler(.allow)
            return
        }

        // An external link: cancel navigation in the web view and show it in the Safari sheet.
        decisionHandler(.cancel)
        openOutside(url)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        progressView.layer.removeAllAnimations()
        progressView.alpha = 1.0
        progressView.setProgress(Float(webView.estimatedProgress), animated: true)
        saveState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        dismissProgress()
        refreshControl?.endRefreshing()
        saveState()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        dismissProgress()
        refreshControl?.endRefreshing()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        dismissProgress()
        refreshControl?.endRefreshing()
    }
}

// MARK: - UI delegate

/// WKUIDelegate is MANDATORY, not optional. Without these callbacks, `<input
/// type=file>` pickers and getUserMedia fail *silently*, and "upload a video to
/// a post or story" stops working. The feature looks broken rather than
/// unsupported.
extension WrappedWebViewController: WKUIDelegate {

    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // Prompt the user via the system permission sheet rather than silently
        // denying. Requires NSCameraUsageDescription / NSMicrophoneUsageDescription.
        decisionHandler(.prompt)
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank inside a wrapper should navigate in place, not vanish.
        if let url = navigationAction.request.url, navigationAction.targetFrame == nil {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}

// MARK: - Bridge

enum BridgeMessage {
    case probe(ruleId: String, expected: Int, actual: Int, bundleVersion: Int)
    case blocked(ruleId: String, count: Int)
    case route(path: String, blocked: Bool)
    case authSurface(active: Bool)
    case breakage(ruleId: String, detail: String)
    case ready(bundleVersion: Int, service: String)
}

private final class BridgeHandler: NSObject, WKScriptMessageHandler {
    private let onMessage: (BridgeMessage) -> Void
    init(_ onMessage: @escaping (BridgeMessage) -> Void) { self.onMessage = onMessage }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any],
              let type = dict["type"] as? String else { return }

        switch type {
        case "probe":
            onMessage(.probe(ruleId: dict["ruleId"] as? String ?? "",
                             expected: dict["expected"] as? Int ?? 0,
                             actual: dict["actual"] as? Int ?? 0,
                             bundleVersion: dict["bundleVersion"] as? Int ?? 0))
        case "blocked":
            onMessage(.blocked(ruleId: dict["ruleId"] as? String ?? "",
                               count: dict["count"] as? Int ?? 0))
        case "route":
            onMessage(.route(path: dict["path"] as? String ?? "",
                             blocked: dict["blocked"] as? Bool ?? false))
        case "auth-surface":
            onMessage(.authSurface(active: dict["active"] as? Bool ?? false))
        case "breakage":
            onMessage(.breakage(ruleId: dict["ruleId"] as? String ?? "",
                                detail: dict["detail"] as? String ?? ""))
        case "ready":
            onMessage(.ready(bundleVersion: dict["bundleVersion"] as? Int ?? 0,
                             service: dict["service"] as? String ?? ""))
        default:
            break
        }
    }
}
