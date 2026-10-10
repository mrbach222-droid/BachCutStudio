import SwiftUI
import AVFoundation

enum ExportFormat: String, CaseIterable { case mp4 = "MP4", mov = "MOV", gif = "GIF"
    var fileExtension: String { rawValue.lowercased() }
    var fileType: AVFileType { self == .mov ? .mov : .mp4 }
}
struct ExportOptions: Equatable {
    var format: ExportFormat = .mp4
    var resolution = 1080
    var fps = 30
    var bitrateMbps = 10
    static let resolutions = [480, 720, 1080, 1440, 2160]
    static let frameRates = [24, 25, 30, 50, 60]
    static let bitrates = [5, 10, 20, 50, 100]
    func validate(duration: Double) throws {
        guard duration.isFinite, duration > 0 else { throw StudioError.message("Dự án không có video") }
        if format == .gif {
            guard [240, 360, 480].contains(resolution), [5, 10].contains(fps), duration <= 30.001 else {
                throw StudioError.message("GIF hỗ trợ tối đa 30 giây, 480p và 10 fps. Hãy cắt ngắn dự án hoặc chọn video.")
            }
        } else {
            guard Self.resolutions.contains(resolution), Self.frameRates.contains(fps), Self.bitrates.contains(bitrateMbps) else { throw StudioError.message("Thiết lập xuất không hợp lệ") }
        }
    }
    func canvas(aspect: Double) throws -> CGSize {
        guard aspect.isFinite, aspect > 0 else { throw StudioError.message("Tỷ lệ video không hợp lệ") }
        let width = aspect >= 1 ? Double(resolution) * aspect : Double(resolution)
        let height = aspect >= 1 ? Double(resolution) : Double(resolution) / aspect
        guard max(width, height) <= 4096 else { throw StudioError.message("Tỷ lệ này vượt khung 4096 pixel. Hãy giảm độ phân giải.") }
        return CGSize(width: max(2, (width / 2).rounded() * 2), height: max(2, (height / 2).rounded() * 2))
    }
    func estimatedBytes(duration: Double) -> Double { duration * (Double(bitrateMbps) * 1_000_000 + 128_000) / 8 }
}

struct ExportSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var options = ExportOptions()
    @State private var started = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Định dạng", selection: $options.format) { ForEach(ExportFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).accessibilityIdentifier("exportFormat")
                }.disabled(model.busy)
                Section("Chất lượng") {
                    Picker("Độ phân giải", selection: $options.resolution) {
                        ForEach(options.format == .gif ? [240, 360, 480] : ExportOptions.resolutions, id: \.self) { Text($0 == 2160 ? "4K · 2160p" : $0 == 1440 ? "2K · 1440p" : "\($0)p").tag($0) }
                    }.accessibilityIdentifier("exportResolution")
                    Picker("Tốc độ khung hình", selection: $options.fps) {
                        ForEach(options.format == .gif ? [5, 10] : ExportOptions.frameRates, id: \.self) { Text("\($0) fps").tag($0) }
                    }.accessibilityIdentifier("exportFPS")
                    if options.format != .gif {
                        Picker("Tốc độ bit", selection: $options.bitrateMbps) { ForEach(ExportOptions.bitrates, id: \.self) { Text("\($0) Mbps").tag($0) } }.accessibilityIdentifier("exportBitrate")
                    }
                }.disabled(model.busy)
                Section {
                    Text("Độ phân giải tính theo cạnh ngắn. Tỷ lệ khung hình theo dự án; nâng độ phân giải không tạo thêm chi tiết nguồn.").font(.caption)
                    if options.format == .gif {
                        Text("GIF lặp liên tục, không có âm thanh; tối đa 30 giây, 480p và 10 fps.").font(.caption)
                    } else {
                        Text("Video H.264 · Âm thanh AAC\nDung lượng ước tính: \(options.estimatedBytes(duration: model.duration) / 1_000_000, specifier: "%.1f") MB; thực tế thay đổi theo nội dung.").font(.caption)
                    }
                }
                if started {
                    Section {
                        ProgressView(value: model.exportFraction)
                        Text(model.progress).font(.caption).accessibilityIdentifier("exportStatus")
                        if model.busy { Button("Hủy xuất", role: .destructive) { model.cancelExport() }.accessibilityIdentifier("cancelExport") }
                    }
                }
            }
            .navigationTitle("Xuất file")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Quay lại") { dismiss() }.disabled(model.busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xuất") { started = true; model.startExport(options: options) }
                        .disabled(model.busy || model.rendering || (options.format == .gif && model.duration > 30.001))
                        .accessibilityIdentifier("confirmExport")
                }
            }
            .onChange(of: options.format) { format in
                options.resolution = format == .gif ? 480 : 1080
                options.fps = format == .gif ? 10 : 30
            }
            .onChange(of: model.exportedURL) { if started && $0 != nil { dismiss() } }
        }.interactiveDismissDisabled(model.busy).tint(.cyan)
    }
}
