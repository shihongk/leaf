import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves local image files to the reading view as `leaf-file:///absolute/path`.
/// The page itself lives in the app bundle, so relative images (resolved against the
/// document's folder in JS) are fetched through this handler. Only image types are served.
final class LocalFileSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "leaf-file"
    private static let allowed: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tif", "tiff",
                                               "heic", "heif", "ico", "avif"]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return fail(task) }
        let path = url.path.removingPercentEncoding ?? url.path
        let fileURL = URL(fileURLWithPath: path)
        let ext = fileURL.pathExtension.lowercased()
        guard Self.allowed.contains(ext), let data = try? Data(contentsOf: fileURL) else { return fail(task) }
        let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        let response = URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func fail(_ task: WKURLSchemeTask) {
        task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
    }
}
