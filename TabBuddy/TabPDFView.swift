import SwiftUI
import PDFKit

struct TabPDFView: UIViewRepresentable {
    let url: URL
    @Binding var scrollViewProxy: UIScrollView?

    func makeUIView(context: Context) -> PDFView {
        print("Loading PDF: \(url)")
        
        let pdfView = PDFView()
        guard url.startAccessingSecurityScopedResource() else {
             return pdfView
        }
        
        pdfView.document = PDFDocument(url: url)
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        
        DispatchQueue.main.async {
            if let scrollView = pdfView.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView {
                self.scrollViewProxy = scrollView
            }
        }
        
        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        // No updates needed as the document is static.
    }
}
