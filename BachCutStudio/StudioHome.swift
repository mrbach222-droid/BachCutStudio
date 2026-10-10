import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CoreTransferable

struct ImportedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in SentTransferredFile(movie.url) } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("photo-" + UUID().uuidString + "." + ext)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return ImportedMovie(url: destination)
        }
    }
}
struct StudioHome: View {
    @State private var projects: [StudioProject] = []
    @State private var current: StudioProject?
    @State private var error = ""
    @State private var pendingDelete: StudioProject?
    let accent = Color.cyan
    var store: ProjectStore {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitesting") {
            return ProjectStore(root: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("UITestData", isDirectory: true))
        }
        #endif
        return ProjectStore()
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("BÁCHCUT").font(.system(size: 30, weight: .black, design: .rounded))
                            Text("STUDIO").font(.caption.bold()).tracking(6).foregroundStyle(accent)
                        }
                        Spacer(); Image(systemName: "film.stack.fill").font(.largeTitle).foregroundStyle(accent)
                    }.padding(.top, 15)
                    Text("Make every frame count.").font(.title2.bold())
                    Text("Dựng video của bạn · Không watermark").font(.subheadline).foregroundStyle(.gray)
                    Button {
                        var p = StudioProject(); p.name = "Dự án " + Date().formatted(date: .abbreviated, time: .shortened)
                        do { try store.save(p); current = p } catch { self.error = error.localizedDescription }
                    } label: {
                        HStack {
                            Image(systemName: "plus.app.fill").font(.largeTitle)
                            VStack(alignment: .leading, spacing: 5) { Text("Dự án mới").font(.title3.bold()); Text("Nhập video từ Ảnh hoặc Tệp").font(.caption) }
                            Spacer(); Image(systemName: "arrow.up.right").font(.title3.bold())
                        }.foregroundStyle(.black).padding(22).frame(maxWidth: .infinity)
                            .background(LinearGradient(colors: [.cyan, Color(red: 0.55, green: 0.98, blue: 0.94)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                    }.buttonStyle(.plain).accessibilityIdentifier("newProject")
                    HStack(spacing: 10) {
                        feature("Nhiều lớp", "square.3.layers.3d")
                        feature("Landscape Pro", "rectangle")
                        feature("MP4 & Ảnh", "square.and.arrow.up")
                    }
                    HStack { Text("DỰ ÁN ĐÃ LƯU").font(.caption.bold()).tracking(2).foregroundStyle(.gray); Spacer(); Text("\(projects.count)").font(.caption) }
                    if projects.isEmpty { Text("Dự án tự lưu sau mỗi thao tác. Bắt đầu bằng một video bạn yêu thích.").font(.subheadline).foregroundStyle(.gray).padding(.vertical, 10) }
                    ForEach(projects) { project in
                        HStack(spacing: 12) {
                            Button { current = project } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "film.stack").font(.title2).foregroundStyle(accent).frame(width: 48, height: 48).background(accent.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 12))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(project.name).font(.headline).lineLimit(1)
                                        Text("\(project.clips.count) đoạn · " + formatTime(project.duration)).font(.caption).foregroundStyle(.gray)
                                        Text(project.modified.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.gray)
                                    }; Spacer()
                                }
                            }.buttonStyle(.plain).accessibilityIdentifier("openProject_" + project.id.uuidString)
                            Button(role: .destructive) { pendingDelete = project } label: { Image(systemName: "trash").padding(6) }.accessibilityLabel("Xóa dự án " + project.name)
                        }.padding(14).background(.white.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    Text("Xoay ngang iPhone để mở rộng timeline. Nhấn giữ dòng nhạc hoặc lớp phủ để đổi âm lượng hoặc xóa.").font(.caption).foregroundStyle(.gray)
                    if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange) }
                }.padding(20)
            }.background(Color(red: 0.045, green: 0.055, blue: 0.08).ignoresSafeArea()).foregroundStyle(.white)
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(isPresented: Binding(get: { current != nil }, set: { if !$0 { current = nil; reload() } })) {
                    if let current { EditorScreen(project: current, store: store) }
                }
                .task {
                    do {
                        #if DEBUG
                        if ProcessInfo.processInfo.arguments.contains("--uitesting-reset") { try? FileManager.default.removeItem(at: store.root) }
                        #endif
                        try store.prepare(); try store.migrateLegacy()
                        #if DEBUG
                        if ProcessInfo.processInfo.arguments.contains("--uitesting-fixture"), try store.list().isEmpty {
                            let media = store.mediaDirectory.appendingPathComponent("fixture.mov")
                            try await TestMedia.video(to: media, color: .red, duration: 8)
                            var p = StudioProject(); p.name = "Kiểm thử Studio"; p.clips = [VideoSegment(url: media, start: 0, end: 8)]
                            try store.save(p)
                        }
                        #endif
                        reload()
                    } catch { self.error = error.localizedDescription }
                }
                .alert("Xóa dự án?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                    Button("Quay lại", role: .cancel) { pendingDelete = nil }
                    Button("Xóa", role: .destructive) {
                        if let project = pendingDelete { do { try store.delete(project); reload() } catch { self.error = error.localizedDescription } }
                        pendingDelete = nil
                    }
                } message: { Text("Thao tác này xóa bản dựng đã lưu của dự án.") }
        }.tint(accent).preferredColorScheme(.dark)
    }
    func reload() { do { projects = try store.list() } catch { self.error = "Không đọc được danh sách dự án: " + error.localizedDescription } }
    func feature(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 8) { Image(systemName: icon).font(.title2).foregroundStyle(accent); Text(title).font(.caption2).multilineTextAlignment(.center) }
            .frame(maxWidth: .infinity).frame(height: 85).background(.white.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
struct LibraryVideoButton: View {
    @ObservedObject var model: EditorModel
    @State private var picked: [PhotosPickerItem] = []
    @State private var loading = false
    var body: some View {
        PhotosPicker(selection: $picked, maxSelectionCount: 30, matching: .videos, photoLibrary: .shared()) { Label(loading ? "Đang nhập…" : "Thư viện", systemImage: "photo.on.rectangle") }
            .disabled(loading || model.busy)
            .onChange(of: picked) { items in
                guard !items.isEmpty else { return }; loading = true
                Task { @MainActor in
                    for item in items {
                        do {
                            if let movie = try await item.loadTransferable(type: ImportedMovie.self) {
                                await model.add(url: movie.url)
                                try? FileManager.default.removeItem(at: movie.url)
                            } else { model.progress = "Không đọc được video từ Thư viện" }
                        } catch { model.progress = "Không nhập được: " + error.localizedDescription }
                    }
                    picked = []; loading = false
                }
            }
    }
}
