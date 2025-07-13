//
//  TabViewerView.swift
//  TabBuddy
//

import SwiftUI
import UniformTypeIdentifiers
import QuartzCore

struct TabViewerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.undoManager) private var undoManager

    @Binding var file: FileItem?
    @Binding var path: [AppPage]
    
    @State private var fontSize: CGFloat = 18
    @State private var scrollSpeed: CGFloat = 0
    @State private var currentScale: CGFloat = 1.0
    @State private var isAutoScrolling: Bool = false
    @State private var timer: Timer?
    @State private var scrollViewProxy: UIScrollView?
    @State private var textViewProxy: UITextView?
    @State private var textContent: String = "Loading…"
    
    @State private var displayLink: CADisplayLink?

    private var coordinator: ScrollCoordinator {
        ScrollCoordinator(
            scrollViewProxy: scrollViewProxy,
            textViewProxy: textViewProxy,
            currentFile: file,
            scrollSpeed: scrollSpeed
        )
    }

    var monospacedFont: Font {
        Font(UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular))
    }
    
    // local UI for rename / tag editing
    @State private var showRename = false
    @State private var newName    = ""
    @State private var showTags   = false
    @State private var hasAccess = false

    @MainActor
    private func loadText() {
        guard let url = file?.url else {
            textContent = NSLocalizedString("failed_load_permissions", comment: "")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let contents = try String(contentsOf: url)
                DispatchQueue.main.async {
                    textContent = contents
                }
            } catch {
                DispatchQueue.main.async {
                    textContent = error.localizedDescription
                }
            }
        }
    }
    
    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                header
                Divider()
                viewerBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .onAppear {
            // restore saved scroll speed for this file
            if let saved = file?.scrollSpeed {
                scrollSpeed = CGFloat(saved)
            }
            if !hasAccess {
                hasAccess = file?.url?.startAccessingSecurityScopedResource() ?? false
                loadText()
            } else {
                loadText()
            }
            // automatically start auto-scroll if a saved speed exists (delay to ensure PDF proxy is set)
            if scrollSpeed > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    startAutoScroll()
                }
            }
        }
        .onDisappear {
            if hasAccess {
                file?.url?.stopAccessingSecurityScopedResource()
                hasAccess = false
            }
            stopAutoScroll()
            // persist scrollSpeed on exit
            file?.scrollSpeed = Double(scrollSpeed)
            try? context.save()
        }
        .onChange(of: scrollViewProxy) { proxy in
            // restart auto-scroll for PDF when the proxy becomes available
            guard file?.url?.pathExtension.lowercased() == "pdf",
                  proxy != nil,
                  scrollSpeed > 0 else { return }
            DispatchQueue.main.async {
                // re-establish displayLink with the now-available scrollView
                stopAutoScroll()
                startAutoScroll()
            }
        }
        .sheet(isPresented: $showTags)   { TagEditorView(file: file!) }
            .sheet(isPresented: $showRename) { renameSheet               }
            .onDisappear { stopAutoScroll() }           // safety
    }
    
    private func startAutoScroll() {
        stopAutoScroll()
        guard scrollSpeed > 0 else { return }
        isAutoScrolling = true

        let link = CADisplayLink(target: coordinator, selector: #selector(ScrollCoordinator.handleScrollStep(_:)))

        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
        } else {
            link.preferredFramesPerSecond = 30
        }

        link.add(to: .current, forMode: .common)
        displayLink = link
    }

    private func stopAutoScroll() {
        displayLink?.invalidate()
        displayLink = nil
        isAutoScrolling = false
    }

    private func readFileContent(fileURL: URL) -> String {
        do {
            print("Loading TXT: \(fileURL)")
            
            guard fileURL.startAccessingSecurityScopedResource() else {
                return "\(LocalizedStringKey("failed_load_permissions"))"
            }
            
            return try String(contentsOf: fileURL)
        } catch {
            return error.localizedDescription
        }
    }
    
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Spacer(minLength: 8)

            // ★ favourite toggle
            Button {
                let wasFavorite = file!.isFavorite
                file!.isFavorite.toggle()
                try? context.save()

                undoManager?.registerUndo(withTarget: context) { ctx in
                    file!.isFavorite = wasFavorite
                    try? ctx.save()
                }
                undoManager?.setActionName(wasFavorite
                                          ? "Unfavorite File"
                                          : "Favorite File")
            } label: {
                Image(systemName: file!.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(file!.isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.borderless)

            // filename (tap to rename)
            Text(file!.filename)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            // tag chips (scrolls if they overflow)
            if ((file?.tags.isEmpty) == nil) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(file!.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.15), in: Capsule())
                        }
                    }
                }
            }

            Spacer(minLength: 8)

            // scroll-speed slider with fine-tune buttons
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.and.down")
                    .foregroundStyle(.secondary)
                Button {
                    // decrease speed by 1, clamped to 4
                    scrollSpeed = max(scrollSpeed - 1, 4)
                    // restart auto-scroll if currently scrolling
                    if isAutoScrolling {
                        stopAutoScroll()
                        startAutoScroll()
                    }
                } label: {
                    Image(systemName: "minus.circle")
                }
                Slider(value: $scrollSpeed,
                       in: 0...40,
                       step: 1,
                       onEditingChanged: { editing in
                           editing ? stopAutoScroll() : startAutoScroll()
                       })
                    .frame(width: 150)
                Button {
                    // increase speed by 1, clamped to 40
                    scrollSpeed = min(scrollSpeed + 1, 40)
                    if isAutoScrolling {
                        stopAutoScroll()
                        startAutoScroll()
                    }
                } label: {
                    Image(systemName: "plus.circle")
                }
            }
            Spacer(minLength: 8)

            // overflow menu
            Menu {
                Button("Rename…") { newName = file!.filename; showRename = true }
                Button("Edit Tags…") { showTags = true }
                Button("Close") { path.removeLast() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal)          // keeps existing 16-pt side insets
        }

        // --------------------------------------------------------------------
        @ViewBuilder
        private var viewerBody: some View {
            if file?.url?.pathExtension.lowercased() == "pdf" {
                if let url = file?.url {
                    TabPDFView(url: url, scrollViewProxy: $scrollViewProxy)
                        .padding()
                }
            } else {
                TabText(fontSize: $fontSize,
                        content: textContent,
                        textViewProxy: $textViewProxy)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                let delta = value / currentScale
                                currentScale = value
                                fontSize *= delta
                                stopAutoScroll()
                            }
                            .onEnded { _ in
                                currentScale = 1.0
                                startAutoScroll()
                            }
                    )
                    .padding()
            }
        }

        // --------------------------------------------------------------------
        private var renameSheet: some View {
            NavigationStack {
                Form {
                    TextField("File name", text: $newName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .navigationTitle("Rename")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: commitRename)
                            .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showRename = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }

        @MainActor
        private func commitRename() {
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let oldURL = file?.url else { return }

            let newURL = oldURL.deletingLastPathComponent()
                               .appendingPathComponent(trimmed)

            do {
                _ = oldURL.startAccessingSecurityScopedResource()
                defer { oldURL.stopAccessingSecurityScopedResource() }

                try FileManager.default.moveItem(at: oldURL, to: newURL)

                file?.bookmark = try newURL.bookmarkData()
                file?.filename = trimmed
                try context.save()
                showRename = false
            } catch {
                print("Rename failed:", error)
            }
        }
    }
