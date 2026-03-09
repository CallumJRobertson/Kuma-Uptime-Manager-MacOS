import SwiftUI
import WebKit

struct WebLoginSheet: View {
    let loginURL: URL
    let onCancel: () -> Void
    let onUseSession: ([HTTPCookie]) -> Void

    @State private var cookies: [HTTPCookie] = []
    @State private var sessionBridge = WebLoginSessionBridge()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                Spacer()
                Text(loginURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Use Session") {
                    sessionBridge.fetchCookies { freshCookies in
                        DispatchQueue.main.async {
                            cookies = freshCookies
                            onUseSession(relevantCookies(from: freshCookies, for: loginURL))
                        }
                    }
                }
            }
            .padding(12)

            Divider()

            EmbeddedWebLoginView(url: loginURL, cookies: $cookies, sessionBridge: sessionBridge)
        }
    }

    private func relevantCookies(from cookies: [HTTPCookie], for url: URL) -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return cookies }
        return cookies.filter { cookie in
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            return host == domain || host.hasSuffix(".\(domain)") || domain.hasSuffix(".\(host)")
        }
    }
}

private final class WebLoginSessionBridge {
    fileprivate var cookieReader: ((@escaping ([HTTPCookie]) -> Void) -> Void)?

    func fetchCookies(_ completion: @escaping ([HTTPCookie]) -> Void) {
        cookieReader?(completion) ?? completion([])
    }
}

private struct EmbeddedWebLoginView: NSViewRepresentable {
    let url: URL
    @Binding var cookies: [HTTPCookie]
    let sessionBridge: WebLoginSessionBridge

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.configureSessionBridge(with: webView)
        context.coordinator.prepareAndLoad(webView: webView, url: url)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: EmbeddedWebLoginView

        init(parent: EmbeddedWebLoginView) {
            self.parent = parent
        }

        func configureSessionBridge(with webView: WKWebView) {
            parent.sessionBridge.cookieReader = { [weak webView] completion in
                guard let webView else {
                    completion([])
                    return
                }
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    completion(cookies)
                }
            }
        }

        func prepareAndLoad(webView: WKWebView, url: URL) {
            guard let host = url.host?.lowercased() else {
                webView.load(URLRequest(url: url))
                return
            }

            let dataStore = webView.configuration.websiteDataStore
            let cookieStore = dataStore.httpCookieStore
            let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()

            cookieStore.getAllCookies { cookies in
                let matchingCookies = cookies.filter { cookie in
                    let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                    return host == domain || host.hasSuffix(".\(domain)") || domain.hasSuffix(".\(host)")
                }

                let group = DispatchGroup()
                for cookie in matchingCookies {
                    group.enter()
                    cookieStore.delete(cookie) {
                        group.leave()
                    }
                }

                dataStore.fetchDataRecords(ofTypes: allTypes) { records in
                    let matchingRecords = records.filter { record in
                        let name = record.displayName.lowercased()
                        return name == host || name.hasSuffix(".\(host)") || host.hasSuffix(".\(name)")
                    }

                    dataStore.removeData(ofTypes: allTypes, for: matchingRecords) {
                        group.notify(queue: .main) {
                            webView.load(URLRequest(url: url))
                        }
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                DispatchQueue.main.async {
                    self.parent.cookies = cookies
                }
            }
        }
    }
}
