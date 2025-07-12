import SwiftUI
import PDFKit

struct TabPDFView: View {
    let url: URL
    @Binding var scrollViewProxy: UIScrollView?
    @State private var pdfDocument: PDFDocument? = nil
    @State private var isLoading = true

    var body: some View {
        ZStack {
            if let document = pdfDocument {
                InternalPDFView(document: document, scrollViewProxy: $scrollViewProxy)
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

            DispatchQueue.main.async {
                self.pdfDocument = document
                self.isLoading = false
            }
        }
    }
}

private struct InternalPDFView: UIViewRepresentable {
    let document: PDFDocument
    @Binding var scrollViewProxy: UIScrollView?

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = document
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
        // No-op
    }
}
