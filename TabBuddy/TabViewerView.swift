//
//  TabViewerView.swift
//  TabBuddy
//

import SwiftUI
import UniformTypeIdentifiers

struct TabViewerView: View {
    @Environment(\.modelContext) private var context

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

        do {
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }

            textContent = try String(contentsOf: url)
        } catch {
            textContent = error.localizedDescription
        }
    }
    
    var body: some View {
        VStack (spacing: 0) {
            header
            Divider()
            viewerBody
        }
        .onAppear {
            print("woo")
            if !hasAccess {
                print("yeah")
                hasAccess = file?.url?.startAccessingSecurityScopedResource() ?? false
                loadText()
            }
            else
            {
                print("nope")
                loadText()
            }
        }
        .onDisappear {
            if hasAccess {
                file?.url?.stopAccessingSecurityScopedResource()
                hasAccess = false
            }
            stopAutoScroll()
        }
        .sheet(isPresented: $showTags)   { TagEditorView(file: file!) }
            .sheet(isPresented: $showRename) { renameSheet               }
            .onDisappear { stopAutoScroll() }           // safety
    }
    
    private func startAutoScroll() {
        stopAutoScroll()
        guard scrollSpeed > 0 else { return }
        isAutoScrolling = true
        timer = Timer.scheduledTimer(withTimeInterval: (6 - scrollSpeed) / 35, repeats: true) { _ in
            if file?.url?.pathExtension.lowercased() == "pdf" {
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
                file!.isFavorite.toggle()
                try? context.save()
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

            // scroll-speed slider (narrow version)
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.and.down")
                    .foregroundStyle(.secondary)
                Slider(value: $scrollSpeed,
                       in: 0...5,
                       step: 0.1,
                       onEditingChanged: { editing in
                           editing ? stopAutoScroll() : startAutoScroll()
                       })
                    .frame(width: 110)                // small but usable
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
