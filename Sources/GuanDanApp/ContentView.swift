import SwiftUI
import WebKit

/// WKWebView subclass that participates in responder chain for keyboard input
class KeyboardWKWebView: WKWebView {
    override var canBecomeFirstResponder: Bool { true }
    override var canResignFirstResponder: Bool { true }
}

struct ContentView: View {
    @EnvironmentObject var serverVM: ServerViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Top bar with server info
            serverBar

            // Web view showing the game client
            if serverVM.isServerRunning, !serverVM.serverURL.isEmpty {
                WebView(url: URL(string: "http://localhost:\(serverVM.port)")!)
                    .edgesIgnoringSafeArea(.bottom)
            } else {
                startPrompt
            }
        }
        .onAppear { serverVM.startServer() }
    }

    private var serverBar: some View {
        HStack {
            Circle()
                .fill(serverVM.isServerRunning ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text("分享地址: \(serverVM.serverURL)")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            ShareLink(item: "http://\(serverVM.serverURL)") {
                Image(systemName: "square.and.arrow.up")
                    .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.systemBackground).opacity(0.95))
    }

    private var startPrompt: some View {
        VStack(spacing: 20) {
            ProgressView()
            Text("正在启动服务器...")
                .font(.headline)
                .foregroundColor(.secondary)
        }
    }
}

/// WKWebView wrapper for SwiftUI
struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.preferences.isElementFullscreenEnabled = true
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let webView = KeyboardWKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.scrollView.keyboardDismissMode = .none
        webView.backgroundColor = UIColor(red: 0.10, green: 0.10, blue: 0.18, alpha: 1.0)
        webView.scrollView.backgroundColor = UIColor(red: 0.10, green: 0.10, blue: 0.18, alpha: 1.0)
        webView.navigationDelegate = context.coordinator; webView.uiDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let request = URLRequest(url: url)
        webView.load(request)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
            if let vc = webView.window?.rootViewController {
                vc.present(alert, animated: true)
            } else {
                completionHandler()
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("[WebView] Loaded: \(webView.url?.absoluteString ?? "?")")
        }
    }
}
