import SwiftUI
import PDFKit

struct TabPDFView: View {
    let url: URL
    @Binding var scrollViewProxy: UIScrollView?
    @State private var pdfDocument: PDFDocument? = nil
    @State private var isLoading = true
    @State private var isLightBackground = false
    @Environment(\.colorScheme) private var colorScheme

    private var shouldInvert: Bool {
        colorScheme == .dark && isLightBackground
    }

    var body: some View {
        ZStack {
            if let document = pdfDocument {
                if shouldInvert {
                    InternalPDFView(document: document,
                                   scrollViewProxy: $scrollViewProxy,
                                   forceWhiteBackground: true)
                        .colorInvert()
                } else {
                    InternalPDFView(document: document,
                                   scrollViewProxy: $scrollViewProxy,
                                   forceWhiteBackground: false)
                }
            } else {
                ProgressView("Loading PDF...")
                    .progressViewStyle(CircularProgressViewStyle())
            }
        }
        .onAppear {
            loadPDF()
        }
    }

    private func loadPDF() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard url.startAccessingSecurityScopedResource() else { return }

            let document = PDFDocument(url: url)
            let isLight = document.map { Self.hasLightBackground($0) } ?? false

            DispatchQueue.main.async {
                self.pdfDocument = document
                self.isLightBackground = isLight
                self.isLoading = false
            }
        }
    }

    /// Renders a small thumbnail of the first page and samples border pixels
    /// to decide whether the PDF has a light (white) background.
    private static func hasLightBackground(_ document: PDFDocument) -> Bool {
        guard let page = document.page(at: 0) else { return false }
        let size = CGSize(width: 36, height: 36)
        let thumb = page.thumbnail(of: size, for: .mediaBox)
        guard let cgImage = thumb.cgImage else { return false }

        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0 else { return false }

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.draw(cgImage, in: CGRect(origin: .zero,
                                     size: CGSize(width: w, height: h)))

        var brightness: CGFloat = 0
        var count = 0

        // sample top and bottom edges
        for x in stride(from: 0, to: w, by: max(1, w / 8)) {
            for y in [0, h - 1] {
                let i = (y * w + x) * 4
                brightness += (CGFloat(pixels[i]) + CGFloat(pixels[i+1]) + CGFloat(pixels[i+2]))
                             / (3.0 * 255.0)
                count += 1
            }
        }
        // sample left and right edges
        for y in stride(from: 0, to: h, by: max(1, h / 8)) {
            for x in [0, w - 1] {
                let i = (y * w + x) * 4
                brightness += (CGFloat(pixels[i]) + CGFloat(pixels[i+1]) + CGFloat(pixels[i+2]))
                             / (3.0 * 255.0)
                count += 1
            }
        }

        return count > 0 && brightness / CGFloat(count) > 0.85
    }
}

private struct InternalPDFView: UIViewRepresentable {
    let document: PDFDocument
    @Binding var scrollViewProxy: UIScrollView?
    var forceWhiteBackground: Bool

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical

        if forceWhiteBackground {
            pdfView.backgroundColor = .white
        }

        DispatchQueue.main.async {
            if let scrollView = pdfView.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView {
                self.scrollViewProxy = scrollView
            }
        }

        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if forceWhiteBackground {
            uiView.backgroundColor = .white
        }
    }
}
