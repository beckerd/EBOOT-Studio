//
//  ConvertPSXView.swift
//  EBOOT Studio
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ConvertPSXView: View {
    var initialURLs: [URL] = []
    var onConverted: (URL) -> Void
    var onCancel: () -> Void

    @State private var didApplyInitial = false

    struct DiscRow: Identifiable {
        let id = UUID()
        // One or more .bin/.img/.iso/.ecm files. For multi-track PSX rips that
        // ship as split BINs, drop them all at once and they'll be streamed
        // in filename order.
        var imageURLs: [URL] = []
        var tocURL: URL?          // .cue or .ccd
        var subURL: URL?          // .sub (optional)
        var discID: String = "SLUS00000"

        var firstImageURL: URL? { imageURLs.first }
    }

    @State private var discs: [DiscRow] = [DiscRow()]
    @State private var title: String = ""
    @State private var useOriginalBootScreen = false
    @State private var isConverting = false
    @State private var progress: Double = 0
    @State private var statusMessage: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Convert PSX → PSP")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Title").font(.caption).foregroundStyle(.secondary)
                TextField("Game title", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Text("Discs").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    if discs.count < 5 { discs.append(DiscRow()) }
                } label: {
                    Label("Add Disc", systemImage: "plus")
                }
                .controlSize(.small)
                .disabled(discs.count >= 5)
            }

            VStack(spacing: 8) {
                ForEach(discs.indices, id: \.self) { i in
                    discRow(index: i)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Opening Screen").font(.caption).foregroundStyle(.secondary)
                Picker("Opening Screen", selection: $useOriginalBootScreen) {
                    Text("POPS default").tag(false)
                    Text("Original").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Keep the POPS splash shown at launch, or replace it with the classic boot screen.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if isConverting {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let msg = errorMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Convert…", action: startConversion)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConvert)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            guard !didApplyInitial else { return }
            didApplyInitial = true
            for url in initialURLs {
                accept(url, into: 0)
            }
        }
    }

    private var canConvert: Bool {
        !isConverting
            && !title.isEmpty
            && discs.allSatisfy { !$0.imageURLs.isEmpty && !$0.discID.isEmpty }
    }

    private func discRow(index i: Int) -> some View {
        let bg = Color.secondary.opacity(0.08)
        let disc = discs[i]
        let allExist = !disc.imageURLs.isEmpty && disc.imageURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        let binStatus: PillStatus
        if disc.imageURLs.isEmpty { binStatus = .requiredMissing }
        else if !allExist { binStatus = .notFound }
        else { binStatus = .provided }

        return HStack(alignment: .top, spacing: 10) {
            Text("\(i + 1)")
                .font(.caption.monospacedDigit())
                .frame(width: 18, height: 24, alignment: .center)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                imageFilesPill(disc: disc, status: binStatus)
                filePill(
                    label: tocLabel(disc.tocURL),
                    url: disc.tocURL,
                    status: disc.tocURL != nil ? .provided : .optionalMissing
                )
                filePill(
                    label: "SUB",
                    url: disc.subURL,
                    status: disc.subURL != nil ? .provided : .optionalMissing
                )
                if disc.imageURLs.isEmpty && disc.tocURL == nil && disc.subURL == nil {
                    Text("Drop the disc data (.bin/.img/.iso/.ecm) and optionally .cue/.ccd/.sub.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(bg))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4]))
            )
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDrop(providers, into: i)
            }

            VStack(spacing: 4) {
                TextField("SLUS00000", text: Binding(
                    get: { discs[i].discID },
                    set: { discs[i].discID = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)

                HStack(spacing: 4) {
                    Button("Choose…") { pickImage(for: i) }
                        .controlSize(.small)
                    Button {
                        discs[i].imageURLs = []
                        discs[i].tocURL = nil
                        discs[i].subURL = nil
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Clear this disc")
                    .disabled(disc.imageURLs.isEmpty && disc.tocURL == nil && disc.subURL == nil)
                    Button {
                        if discs.count > 1 { discs.remove(at: i) }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this disc row")
                    .disabled(discs.count <= 1)
                }
            }
        }
    }

    enum PillStatus {
        case provided            // green — user dropped/picked directly
        case notFound            // red — path was set but file doesn't exist
        case requiredMissing     // orange dashed — user still needs to add it
        case optionalMissing     // gray dashed — not needed but slot exists
    }

    private func imageFilesPill(disc: DiscRow, status: PillStatus) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: pillIcon(status))
                .foregroundStyle(pillColor(status))
                .frame(width: 14)
            Text("IMG")
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            if disc.imageURLs.isEmpty {
                Text("missing")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(disc.imageURLs.enumerated()), id: \.element) { _, url in
                        Text(url.lastPathComponent)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if disc.imageURLs.count > 1 {
                        Text("\(disc.imageURLs.count) files — streamed in order")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func filePill(label: String, url: URL?, status: PillStatus) -> some View {
        HStack(spacing: 6) {
            Image(systemName: pillIcon(status))
                .foregroundStyle(pillColor(status))
                .frame(width: 14)
            Text(label)
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            if let url = url {
                Text(url.lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let suffix = pillSuffix(status) {
                    Text(suffix)
                        .font(.caption2)
                        .foregroundStyle(pillColor(status))
                }
            } else {
                Text(status == .optionalMissing ? "not provided (optional)" : "missing")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
    }

    private func pillIcon(_ s: PillStatus) -> String {
        switch s {
        case .provided: return "checkmark.circle.fill"
        case .notFound: return "exclamationmark.triangle.fill"
        case .requiredMissing: return "circle.dashed"
        case .optionalMissing: return "circle.dashed"
        }
    }

    private func pillColor(_ s: PillStatus) -> Color {
        switch s {
        case .provided: return .green
        case .notFound: return .red
        case .requiredMissing: return .orange
        case .optionalMissing: return Color.secondary.opacity(0.6)
        }
    }

    private func pillSuffix(_ s: PillStatus) -> String? {
        s == .notFound ? "(not found)" : nil
    }

    private func tocLabel(_ url: URL?) -> String {
        guard let ext = url?.pathExtension.lowercased() else { return "TOC" }
        return ext == "ccd" ? "CCD" : "CUE"
    }

    // MARK: - File handling

    private func pickImage(for index: Int) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "bin") ?? .data,
            UTType(filenameExtension: "img") ?? .data,
            UTType(filenameExtension: "iso") ?? .data,
            UTType(filenameExtension: "ecm") ?? .data,
            UTType(filenameExtension: "cue") ?? .data,
            UTType(filenameExtension: "ccd") ?? .data,
            UTType(filenameExtension: "sub") ?? .data,
        ]
        if panel.runModal() == .OK, let url = panel.url {
            accept(url, into: index)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider], into index: Int) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url = url else { return }
                DispatchQueue.main.async { accept(url, into: index) }
            }
        }
        return !providers.isEmpty
    }

    private func accept(_ url: URL, into index: Int) {
        guard index < discs.count else { return }
        let ext = url.pathExtension.lowercased()

        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        switch ext {
        case "cue":
            discs[index].tocURL = url
            do {
                _ = try CueParser.parse(url: url)
                errorMessage = nil
            } catch {
                errorMessage = "Could not parse CUE: \(error.localizedDescription)"
            }
        case "ccd":
            discs[index].tocURL = url
            do {
                _ = try CCDParser.parseTOC(url: url)
                errorMessage = nil
            } catch {
                errorMessage = "Could not parse CCD: \(error.localizedDescription)"
            }
        case "bin", "iso", "img", "ecm":
            if !discs[index].imageURLs.contains(url) {
                discs[index].imageURLs.append(url)
                // Keep the ordering deterministic (by filename).
                discs[index].imageURLs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            }
        case "sub":
            discs[index].subURL = url
        default:
            errorMessage = "Unsupported file type. Pick a .bin/.img/.iso, .cue/.ccd, or .sub."
            return
        }
        if title.isEmpty {
            var stem = url.deletingPathExtension().lastPathComponent
            // Strip trailing "(Track N)" so multi-BIN drops get a clean title.
            if let range = stem.range(of: #"\s*\(Track\s*\d+\)\s*$"#, options: .regularExpression) {
                stem.removeSubrange(range)
            }
            title = stem
        }
    }

    // MARK: - Conversion

    private func startConversion() {
        errorMessage = nil

        var bootLogoPNG: Data? = nil
        if useOriginalBootScreen {
            guard let url = Bundle.main.url(forResource: "ps1_boot", withExtension: "png"),
                  let data = try? Data(contentsOf: url) else {
                errorMessage = "The bundled boot screen image is missing."
                return
            }
            bootLogoPNG = data
        }

        let panel = NSSavePanel()
        // No allowedContentTypes: the panel would append a lowercase ".pbp"
        // to the already-uppercase "EBOOT.PBP" name.
        panel.nameFieldStringValue = "EBOOT.PBP"
        panel.message = "Choose where to save the EBOOT.PBP"
        guard panel.runModal() == .OK, let outURL = panel.url else { return }

        var subLoadError: String?
        let discEntries: [PSXConversionOptions.Disc] = discs.compactMap { row in
            guard !row.imageURLs.isEmpty else { return nil }
            var toc: Data? = nil
            if let tocURL = row.tocURL, tocURL.pathExtension.lowercased() == "ccd" {
                toc = try? CCDParser.parseTOC(url: tocURL)
            }
            var sub: Data? = nil
            if let subURL = row.subURL {
                do {
                    sub = try SubchannelReader.load(url: subURL)
                } catch {
                    subLoadError = "SUB: \(error.localizedDescription)"
                }
            }
            return PSXConversionOptions.Disc(imageURLs: row.imageURLs, discID: row.discID, toc: toc, subchannel: sub)
        }

        if let msg = subLoadError {
            errorMessage = msg
            return
        }
        let options = PSXConversionOptions(
            discs: discEntries,
            outputURL: outURL,
            gameTitle: title,
            icon0PNG: nil,
            pic0PNG: nil,
            pic1PNG: nil,
            bootLogoPNG: bootLogoPNG
        )

        // Keep security-scoped access alive for every source URL until done.
        let scopedURLs = discEntries.flatMap { $0.imageURLs }
        let started = scopedURLs.map { $0.startAccessingSecurityScopedResource() }

        isConverting = true
        progress = 0
        statusMessage = "Starting…"

        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                for (u, s) in zip(scopedURLs, started) where s {
                    u.stopAccessingSecurityScopedResource()
                }
            }
            do {
                try PSXConverter.convert(options: options) { p, msg in
                    DispatchQueue.main.async {
                        progress = p
                        statusMessage = msg
                    }
                }
                DispatchQueue.main.async {
                    isConverting = false
                    onConverted(outURL)
                }
            } catch {
                DispatchQueue.main.async {
                    isConverting = false
                    errorMessage = "Conversion failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
