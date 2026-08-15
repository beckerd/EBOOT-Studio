//
//  ContentView.swift
//  EBOOT Studio
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

// Deep blueprint blue used for headings and rules on the white paper cards.
private let blueprintInk = Color(red: 0.10, green: 0.30, blue: 0.72)

struct ContentView: View {
    @State private var pbp: PBPFile?
    @State private var sourceURL: URL?
    @State private var isDirty = false
    @State private var isTargeted = false
    @State private var hoverTint: Color? = nil
    @State private var errorMessage: String?
    @State private var titleText: String = ""
    @State private var titleAvailable: Bool = false
    @State private var conversionRequest: ConversionRequest?

    // Bundles the "open the converter" trigger and its pre-loaded URLs into
    // a single Identifiable value so the sheet presentation is atomic with
    // its payload (no risk of the sheet opening before the URLs are set).
    struct ConversionRequest: Identifiable {
        let id = UUID()
        let urls: [URL]
    }
    @State private var isSaving = false
    @State private var saveProgress: Double = 0
    @State private var savedFileURL: URL?
    @State private var saveTaskToken: CancelToken?
    @State private var isLoading = false
    @State private var loadProgress: Double = 0
    @State private var loadTaskToken: CancelToken?

    // Reference type so background threads can flip cancellation cooperatively.
    final class CancelToken {
        var isCancelled = false
    }

    var body: some View {
        Group {
            if pbp != nil {
                editorView
            } else {
                dropView
            }
        }
        .frame(minWidth: 560, minHeight: 440)
        .overlay {
            if isSaving {
                progressOverlay(title: "Saving…", icon: "square.and.arrow.down.fill", progress: saveProgress) {
                    cancelSave()
                }
            } else if isLoading {
                progressOverlay(title: "Opening…", icon: "arrow.down.doc.fill", progress: loadProgress) {
                    cancelLoad()
                }
            } else if let url = savedFileURL {
                savedConfirmation(url: url)
            }
        }
        .alert("Error", isPresented: showError, presenting: errorMessage) { _ in
            Button("OK") { errorMessage = nil }
        } message: { message in
            Text(message)
        }
        .sheet(item: $conversionRequest) { request in
            ConvertPSXView(
                initialURLs: request.urls,
                onConverted: { url in
                    conversionRequest = nil
                    loadPBP(from: url)
                },
                onCancel: {
                    conversionRequest = nil
                }
            )
        }
    }

    private func savedConfirmation(url: URL) -> some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.green)

                Text("Saved")
                    .font(.system(.title, design: .rounded).weight(.semibold))

                VStack(spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(url.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 300)

                HStack(spacing: 10) {
                    Button("Continue Editing") {
                        savedFileURL = nil
                    }
                    .controlSize(.large)
                    Button("Done") {
                        savedFileURL = nil
                        resetToEmpty()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 6)
            }
            .padding(28)
            .frame(minWidth: 340)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
            )
        }
    }

    private func progressOverlay(title: String, icon: String, progress: Double, onCancel: (() -> Void)?) -> some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView(value: progress) {
                    HStack {
                        Image(systemName: icon)
                        Text(title)
                            .font(.headline)
                    }
                }
                .progressViewStyle(.linear)
                .frame(width: 300)
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let onCancel = onCancel {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
            )
        }
    }

    private var showError: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    // MARK: - Empty state

    private var dropView: some View {
        // On the blueprint backdrop, blue tints vanish — hover feedback is
        // white for PBP/generic drops and orange for convertible disc files.
        let activeTint: Color = hoverTint == .orange ? .orange : .white
        return ZStack {
            blueprintBackground

            // Kept outside blueprintBackground's ignoresSafeArea so the
            // corner glyphs stay inside the dashed drop border.
            shapeWatermarks

            // Full-canvas hover wash; the dashed border below marks the
            // whole window as a drop target.
            activeTint.opacity(isTargeted ? 0.08 : 0)
                .animation(.easeInOut(duration: 0.15), value: isTargeted)

            VStack(spacing: 36) {
                Spacer(minLength: 20)

                hero

                VStack(spacing: 10) {
                    WorkflowRow(
                        icon: "photo.on.rectangle.angled",
                        title: "Edit a PBP",
                        subtitle: "Swap the icon, backgrounds, and rename an existing EBOOT.PBP.",
                        tint: .accentColor,
                        action: openPBP
                    )
                    WorkflowRow(
                        icon: "opticaldisc.fill",
                        title: "Convert PSX → PSP",
                        subtitle: "Turn a PSX disc rip (BIN/CUE, CCD/IMG/SUB, or ECM) into a fresh EBOOT.PBP.",
                        tint: .orange,
                        action: { conversionRequest = ConversionRequest(urls: []) }
                    )
                }
                .frame(maxWidth: 460)

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    isTargeted ? activeTint : Color.white.opacity(0.35),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: [7, 5])
                )
                .padding(12)
                .animation(.easeInOut(duration: 0.15), value: isTargeted)
                .allowsHitTesting(false)
        )
        .onDrop(of: [.fileURL], delegate: EmptyStateDropDelegate(
            isTargeted: $isTargeted,
            hoverTint: $hoverTint,
            onDrop: { urls in routeDroppedURLs(urls) }
        ))
    }

    // Blueprint backdrop matching the app icon: deep blue gradient, a
    // drafting grid, and faint PlayStation shape outlines in the corners.
    private var blueprintBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.32, blue: 0.68),
                    Color(red: 0.04, green: 0.18, blue: 0.46)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            Canvas { context, size in
                let minorSpacing: CGFloat = 24
                let majorEvery = 4
                var index = 0
                var x: CGFloat = 0
                while x <= size.width {
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    let isMajor = index % majorEvery == 0
                    context.stroke(line, with: .color(.white.opacity(isMajor ? 0.10 : 0.04)), lineWidth: 1)
                    x += minorSpacing
                    index += 1
                }
                index = 0
                var y: CGFloat = 0
                while y <= size.height {
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y))
                    line.addLine(to: CGPoint(x: size.width, y: y))
                    let isMajor = index % majorEvery == 0
                    context.stroke(line, with: .color(.white.opacity(isMajor ? 0.10 : 0.04)), lineWidth: 1)
                    y += minorSpacing
                    index += 1
                }
            }
        }
        .ignoresSafeArea()
    }

    // The □ △ ○ ✕ outlines sketched onto the icon's blueprint corners.
    private var shapeWatermarks: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "square")
                Image(systemName: "triangle")
                Image(systemName: "circle")
                Image(systemName: "xmark")
            }
            .font(.system(size: 22, weight: .light))
            .foregroundStyle(.white.opacity(0.18))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(30)

            HStack(spacing: 16) {
                Image(systemName: "xmark")
                Image(systemName: "circle")
                Image(systemName: "triangle")
                Image(systemName: "square")
            }
            .font(.system(size: 17, weight: .light))
            .foregroundStyle(.white.opacity(0.12))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(26)
        }
        .allowsHitTesting(false)
    }

    // Typographic lockup from the app icon: "EBOOT" on a glossy blue pill
    // with "STUDIO" in italics beneath it.
    private var hero: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Text("EBOOT")
                    .font(.system(size: 34, weight: .heavy))
                    .kerning(2)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.32, green: 0.58, blue: 0.95),
                                        Color(red: 0.10, green: 0.30, blue: 0.72)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(.white.opacity(0.85), lineWidth: 2)
                            )
                            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                    )

                Text("STUDIO")
                    .font(.system(size: 26, weight: .thin))
                    .italic()
                    .kerning(3)
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
            }

            Text("Drop a file to begin, or pick a workflow.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.75))
        }
    }

    private func routeDroppedURLs(_ urls: [URL]) {
        if let pbp = urls.first(where: { $0.pathExtension.lowercased() == "pbp" }) {
            loadPBP(from: pbp)
            return
        }
        guard !urls.isEmpty else { return }
        conversionRequest = ConversionRequest(urls: urls)
    }

    // MARK: - Editor

    private var editorView: some View {
        ZStack {
            blueprintBackground
            editorContent
        }
    }

    private var editorContent: some View {
        VStack(spacing: 0) {
            header
            Color.white.opacity(0.15)
                .frame(height: 1)
            ScrollView {
                VStack(spacing: 12) {
                    titleSection
                    ImageSlotView(
                        title: "Game Icon",
                        sectionName: "ICON0.PNG",
                        recommendedSize: "144 × 80",
                        detail: "The icon shown in the PSP's game list. This is the one everyone sees.",
                        data: pbp?.sections["ICON0.PNG"] ?? Data(),
                        onDownload: { downloadSection("ICON0.PNG") },
                        onReplace: { url in replaceSection("ICON0.PNG", from: url) }
                    )
                    ImageSlotView(
                        title: "Background",
                        sectionName: "PIC1.PNG",
                        recommendedSize: "480 × 272",
                        detail: "Full-screen backdrop shown behind the menu while the game is highlighted.",
                        data: pbp?.sections["PIC1.PNG"] ?? Data(),
                        onDownload: { downloadSection("PIC1.PNG") },
                        onReplace: { url in replaceSection("PIC1.PNG", from: url) }
                    )
                    ImageSlotView(
                        title: "Info Panel (optional)",
                        sectionName: "PIC0.PNG",
                        recommendedSize: "310 × 180",
                        detail: "Small panel drawn on top of the background when highlighted. Most games leave this empty.",
                        data: pbp?.sections["PIC0.PNG"] ?? Data(),
                        onDownload: { downloadSection("PIC0.PNG") },
                        onReplace: { url in replaceSection("PIC0.PNG", from: url) }
                    )
                }
                .padding(12)
            }
        }
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("App Name")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(blueprintInk)
                Text("PARAM.SFO · TITLE")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
            }

            blueprintInk.opacity(0.15)
                .frame(height: 1)
            TextField("Displayed name on the PSP", text: $titleText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .disabled(!titleAvailable)
                .onChange(of: titleText) { _, _ in
                    if titleAvailable { isDirty = true }
                }
            if !titleAvailable {
                Text("This PBP has no PARAM.SFO section, so the title can't be edited.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.93))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 3)
        )
        // White "paper" card on the blueprint, like the empty state's rows.
        .environment(\.colorScheme, .light)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "gamecontroller.fill")
                .font(.title3)
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(sourceURL?.lastPathComponent ?? "EBOOT.PBP")
                        .font(.subheadline.weight(.semibold))
                    if isDirty {
                        Text("• Edited")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let sourceURL = sourceURL {
                    Text(sourceURL.deletingLastPathComponent().path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Button("Start Over", action: resetToEmpty)
                .controlSize(.small)
            Button("Save As…", action: savePBP)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut("s", modifiers: [.command])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // Translucent black wash so the header controls stand out from the
        // blueprint backdrop.
        .background(Color.black.opacity(0.30))
        // The blueprint backdrop is always dark blue, so header text and
        // buttons render in dark appearance regardless of system scheme.
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Actions

    private func openPBP() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let pbpType = UTType(filenameExtension: "pbp") ?? .data
        panel.allowedContentTypes = [pbpType]
        if panel.runModal() == .OK, let url = panel.url {
            loadPBP(from: url)
        }
    }

    private func handlePBPDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url = url else { return }
            DispatchQueue.main.async {
                loadPBP(from: url)
            }
        }
        return true
    }

    private func resetToEmpty() {
        pbp = nil
        sourceURL = nil
        isDirty = false
        titleText = ""
        titleAvailable = false
        errorMessage = nil
    }

    private func loadPBP(from url: URL) {
        // Kick off cancellable, chunked background read so the UI stays
        // responsive when the file lives on slow removable media.
        let token = CancelToken()
        loadTaskToken = token
        isLoading = true
        loadProgress = 0

        DispatchQueue.global(qos: .userInitiated).async {
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }

            let result: Result<PBPFile, Error>
            do {
                let data = try readInChunks(url: url, cancel: token) { p in
                    DispatchQueue.main.async {
                        if !token.isCancelled { loadProgress = p }
                    }
                }
                if token.isCancelled {
                    DispatchQueue.main.async {
                        if loadTaskToken === token { isLoading = false }
                    }
                    return
                }
                result = .success(try PBPFile(data: data))
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                guard loadTaskToken === token else { return }
                isLoading = false
                loadTaskToken = nil
                switch result {
                case .success(let file):
                    pbp = file
                    sourceURL = url
                    isDirty = false
                    if let existing = file.title {
                        titleText = existing
                        titleAvailable = true
                    } else {
                        titleText = ""
                        titleAvailable = false
                    }
                case .failure(let error):
                    errorMessage = "Could not open file: \(error.localizedDescription)"
                }
            }
        }
    }

    private func cancelLoad() {
        loadTaskToken?.isCancelled = true
        loadTaskToken = nil
        isLoading = false
    }

    // Reads a file in 4 MB chunks, checking the cancel token between chunks
    // so a slow read can be aborted without corruption.
    private func readInChunks(url: URL, cancel: CancelToken, progress: @escaping (Double) -> Void) throws -> Data {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let total = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        guard total > 0 else {
            throw NSError(domain: "EBOOTStudio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "File is empty."])
        }
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }

        var data = Data()
        data.reserveCapacity(Int(total))
        let chunkSize = 4 * 1024 * 1024
        var read: UInt64 = 0
        while read < total {
            if cancel.isCancelled { throw CancellationError() }
            let want = min(UInt64(chunkSize), total - read)
            let chunk = fh.readData(ofLength: Int(want))
            if chunk.isEmpty { break }
            data.append(chunk)
            read += UInt64(chunk.count)
            progress(Double(read) / Double(total))
        }
        return data
    }

    private func savePBP() {
        guard var pbp = pbp else { return }
        if titleAvailable {
            do {
                try pbp.setTitle(titleText)
            } catch {
                errorMessage = "Could not update title: \(error.localizedDescription)"
                return
            }
        }
        let panel = NSSavePanel()
        // No allowedContentTypes: the panel would append a lowercase ".pbp"
        // to the already-uppercase "EBOOT.PBP" name.
        panel.nameFieldStringValue = sourceURL?.lastPathComponent ?? "EBOOT.PBP"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let data = pbp.serialize()
        let finalPBP = pbp

        let token = CancelToken()
        saveTaskToken = token
        isSaving = true
        saveProgress = 0

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try writeInChunks(data: data, to: url, cancel: token) { p in
                    DispatchQueue.main.async {
                        if !token.isCancelled { saveProgress = p }
                    }
                }
                if token.isCancelled {
                    // Clean up the partially-written destination.
                    try? FileManager.default.removeItem(at: url)
                    DispatchQueue.main.async {
                        if saveTaskToken === token {
                            isSaving = false
                            saveTaskToken = nil
                        }
                    }
                    return
                }
                DispatchQueue.main.async {
                    guard saveTaskToken === token else { return }
                    self.pbp = finalPBP
                    isDirty = false
                    sourceURL = url
                    isSaving = false
                    saveTaskToken = nil
                    saveProgress = 1
                    savedFileURL = url
                }
            } catch {
                DispatchQueue.main.async {
                    guard saveTaskToken === token else { return }
                    isSaving = false
                    saveTaskToken = nil
                    errorMessage = "Save failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func cancelSave() {
        saveTaskToken?.isCancelled = true
        saveTaskToken = nil
        isSaving = false
    }

    // Writes `data` to `url` in 4 MB chunks with cancellation checks.
    private func writeInChunks(data: Data, to url: URL, cancel: CancelToken, progress: @escaping (Double) -> Void) throws {
        if !FileManager.default.createFile(atPath: url.path, contents: nil) {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES),
                          userInfo: [NSLocalizedDescriptionKey: "Could not create \(url.lastPathComponent)."])
        }
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }

        let chunkSize = 4 * 1024 * 1024
        var offset = 0
        while offset < data.count {
            if cancel.isCancelled { throw CancellationError() }
            let end = min(offset + chunkSize, data.count)
            fh.write(data[offset..<end])
            offset = end
            progress(Double(offset) / Double(data.count))
        }
        try fh.synchronize()
    }

    private func downloadSection(_ section: String) {
        guard let data = pbp?.sections[section], !data.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = section
        panel.allowedContentTypes = [.png]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                errorMessage = "Could not save image: \(error.localizedDescription)"
            }
        }
    }

    private func replaceSection(_ section: String, from url: URL) {
        guard var updated = pbp else { return }

        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        let newData: Data
        do {
            newData = try Data(contentsOf: url)
        } catch {
            errorMessage = "Could not read replacement file: \(error.localizedDescription)"
            return
        }

        guard PNGInspector.isPNG(newData) else {
            errorMessage = PBPError.notAPNG.localizedDescription
            return
        }

        if let current = updated.sections[section], !current.isEmpty,
           let currentSize = PNGInspector.dimensions(current),
           let newSize = PNGInspector.dimensions(newData),
           currentSize != newSize {
            errorMessage = PBPError.dimensionMismatch(
                expectedWidth: currentSize.width,
                expectedHeight: currentSize.height,
                gotWidth: newSize.width,
                gotHeight: newSize.height
            ).localizedDescription
            return
        }

        updated.sections[section] = newData
        pbp = updated
        isDirty = true
    }
}

// MARK: - Image Slot

private struct ImageSlotView: View {
    let title: String
    let sectionName: String
    let recommendedSize: String
    let detail: String
    let data: Data
    let onDownload: () -> Void
    let onReplace: (URL) -> Void

    @State private var isTargeted = false

    var body: some View {
        let image = data.isEmpty ? nil : NSImage(data: data)
        let pngSize = PNGInspector.dimensions(data)

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(blueprintInk)
                Text(sectionName)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Expected \(recommendedSize)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            blueprintInk.opacity(0.15)
                .frame(height: 1)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.05))
                    if let image = image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .padding(4)
                    } else {
                        VStack(spacing: 2) {
                            Image(systemName: "photo")
                                .font(.title3)
                            Text("No image")
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 160, height: 100)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            isTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                            style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: isTargeted ? [6] : [])
                        )
                )
                .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                    handleDrop(providers)
                }

                VStack(alignment: .leading, spacing: 4) {
                    if let pngSize = pngSize {
                        Label("\(pngSize.width) × \(pngSize.height) px", systemImage: "ruler")
                            .font(.caption)
                    }
                    Label("\(data.count) bytes", systemImage: "internaldrive")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Button {
                        onDownload()
                    } label: {
                        Label("Download", systemImage: "square.and.arrow.down")
                    }
                    .controlSize(.small)
                    .disabled(data.isEmpty)

                    Text("Drop a PNG on the preview to replace.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.93))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 3)
        )
        // White "paper" card on the blueprint, like the empty state's rows.
        .environment(\.colorScheme, .light)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url = url else { return }
            DispatchQueue.main.async {
                onReplace(url)
            }
        }
        return true
    }
}

// MARK: - Empty-state drop delegate

// Peeks at NSItemProvider.suggestedName during drag-enter to tint the outer
// dropzone based on what will happen: blue for a .pbp (Edit flow), orange for
// a disc file (Convert flow), or a generic accent if the type can't be
// determined from the suggested name.
private struct EmptyStateDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    @Binding var hoverTint: Color?
    let onDrop: ([URL]) -> Void

    private static let convertExtensions: Set<String> = [
        "bin", "cue", "ccd", "img", "iso", "ecm", "sub"
    ]

    func validateDrop(info: DropInfo) -> Bool {
        return info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
        hoverTint = tint(for: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        hoverTint = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        hoverTint = nil
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        let expected = providers.count
        var collected: [URL] = []
        var completed = 0
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    if let url = url { collected.append(url) }
                    completed += 1
                    if completed == expected { onDrop(collected) }
                }
            }
        }
        return true
    }

    private func tint(for info: DropInfo) -> Color? {
        let providers = info.itemProviders(for: [.fileURL])
        for p in providers {
            if let name = p.suggestedName {
                let ext = (name as NSString).pathExtension.lowercased()
                if ext == "pbp" { return .accentColor }
                if Self.convertExtensions.contains(ext) { return .orange }
            }
        }
        return nil
    }
}

// MARK: - Workflow row (white "paper" card on the blueprint backdrop)

// Styled after the app icon's document-on-blueprint motif: a white sheet
// sitting on the blue drafting grid, so it's forced to light appearance
// regardless of the system color scheme.
private struct WorkflowRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(tint.opacity(0.16))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 1.0 : 0.93))
                    .shadow(color: .black.opacity(0.25), radius: isHovered ? 8 : 4, y: 3)
            )
        }
        .buttonStyle(.plain)
        .environment(\.colorScheme, .light)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

#Preview {
    ContentView()
}
