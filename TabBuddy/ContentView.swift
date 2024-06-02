import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var fileURL: URL? = nil
    @State private var fontSize: CGFloat = 18
    @State private var scrollSpeed: CGFloat = 0
    @State private var currentScale: CGFloat = 1.0
    @State private var isAutoScrolling: Bool = false
    @State private var timer: Timer?
    @State private var scrollViewProxy: UIScrollView?
    @State private var textViewProxy: UITextView?
    @State private var isDocumentPickerPresented: Bool = false

    var monospacedFont: Font {
        Font(UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular))
    }

    var body: some View {
        VStack {
            HStack {
                Button(action: {
                    self.isDocumentPickerPresented = true
                }) {
                    Text("Select File")
                        .font(.title3)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }.padding(.horizontal)
                Text("Scroll Speed")
                Slider(value: $scrollSpeed, in: 0...5, step: 0.1, onEditingChanged: { editing in
                    if editing {
                        stopAutoScroll()
                    } else {
                        startAutoScroll()
                    }
                }).padding(.horizontal)
            }.padding()
            
            if let fileURL = fileURL {
                if fileURL.pathExtension.lowercased() == "pdf" {
                    TabPDFView(url: fileURL, scrollViewProxy: $scrollViewProxy)
                        .padding()
                        .id(fileURL)
                } else {
                    TabText(fontSize: $fontSize, content: readFileContent(fileURL: fileURL), textViewProxy: $textViewProxy)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    let delta = value / self.currentScale
                                    self.currentScale = value
                                    fontSize *= delta
                                    stopAutoScroll()
                                }
                                .onEnded { _ in
                                    self.currentScale = 1.0
                                    startAutoScroll()
                                }
                        )
                        .padding()
                        .id(fileURL)
                }
            } else {
                Text("No file selected")
                    .padding()
            }
        }
        .fileImporter(
            isPresented: $isDocumentPickerPresented,
            allowedContentTypes: [.pdf, .plainText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                print("Document selected: \(url)")
                self.fileURL = url
            case .failure(let error):
                print("Document selection failed: \(error.localizedDescription)")
            }
        }
    }

    private func readFileContent(fileURL: URL) -> String {
        do {
            print("Loading TXT: \(fileURL)")
            
            guard fileURL.startAccessingSecurityScopedResource() else {
                 return "Failed to load content: Failed to get permissions."
            }
            
            return try String(contentsOf: fileURL)
        } catch {
            return "Failed to load content: \(error.localizedDescription)"
        }
    }

    private func startAutoScroll() {
        stopAutoScroll()
        guard scrollSpeed > 0 else { return }
        isAutoScrolling = true
        timer = Timer.scheduledTimer(withTimeInterval: (6 - scrollSpeed) / 35, repeats: true) { _ in
            if fileURL?.pathExtension.lowercased() == "pdf" {
                guard let scrollView = scrollViewProxy else { return }
                let currentOffset = scrollView.contentOffset.y
                let newOffset = min(currentOffset + 1, scrollView.contentSize.height - scrollView.bounds.size.height)
                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: newOffset), animated: false)
            } else {
                guard let textView = textViewProxy else { return }
                let currentOffset = textView.contentOffset.y
                let newOffset = min(currentOffset + 1, textView.contentSize.height - textView.bounds.size.height)
                textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: newOffset), animated: false)
            }
        }
    }

    private func stopAutoScroll() {
        timer?.invalidate()
        timer = nil
        isAutoScrolling = false
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
