import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CoreTransferable

struct ImportedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("photo-" + UUID().uuidString + "." + ext)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return ImportedMovie(url: destination)
        }
    }
}

struct StudioHome: View {
    @State private var showingEditor = false
    private let ink = Color(red: 0.055, green: 0.067, blue: 0.09)
    private let accent = Color(red: 0.08, green: 0.82, blue: 0.9)
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 23) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("BÁCHCUT").font(.system(size: 28, weight: .black, design: .rounded))
                            Text("STUDIO").font(.system(size: 14, weight: .bold, design: .rounded)).tracking(5).foregroundStyle(accent)
                        }
                        Spacer()
                        Image(systemName: "person.crop.circle").font(.title2).foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.top, 12)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Make every frame count.").font(.title2.bold())
                        Text("Dựng video theo cách của bạn · Không watermark").font(.subheadline).foregroundStyle(.white.opacity(0.65))
                    }
                    Button { showingEditor = true } label: {
                        HStack {
                            Image(systemName: "plus.app.fill").font(.largeTitle)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Dự án mới").font(.title3.bold())
                                Text("Chọn video từ Ảnh hoặc Tệp").font(.caption).foregroundStyle(.black.opacity(0.68))
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.title3.bold())
                        }
                        .foregroundStyle(.black)
                        .padding(22)
                        .frame(maxWidth: .infinity)
                        .background(LinearGradient(colors: [accent, Color(red: 0.53, green: 0.97, blue: 0.95)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                    }.buttonStyle(.plain)
                    HStack(spacing: 12) {
                        miniFeature("Cắt ghép", icon: "scissors")
                        miniFeature("Landscape Pro", icon: "rectangle.landscape")
                        miniFeature("Xuất MP4", icon: "square.and.arrow.up")
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("KHÔNG GIAN LÀM VIỆC").font(.caption.bold()).tracking(2).foregroundStyle(.gray)
                        HStack(spacing: 14) {
                            Image(systemName: "film.stack.fill").font(.title).foregroundStyle(accent).frame(width: 48, height: 48)
                                .background(accent.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Video Editor").font(.headline)
                                Text("Timeline, preview và xuất video trên iPhone").font(.caption).foregroundStyle(.gray)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.gray)
                        }.padding(16).background(.white.opacity(0.055)).clipShape(RoundedRectangle(cornerRadius: 18))
                            .onTapGesture { showingEditor = true }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("BÁCHCUT STUDIO LAB").font(.caption.bold()).tracking(2).foregroundStyle(accent)
                        Text("Landscape Pro").font(.title2.bold())
                        Text("Xoay ngang iPhone để mở rộng không gian timeline, thao tác với clip dễ dàng hơn.")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        .background(LinearGradient(colors: [Color.blue.opacity(0.24), Color.white.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                }.padding(20)
            }
            .background(ink.ignoresSafeArea())
            .foregroundStyle(.white)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showingEditor) { EditorScreen() }
        }
        .tint(accent)
        .preferredColorScheme(.dark)
    }
    private func miniFeature(_ title: String, icon: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon).font(.title2).foregroundStyle(accent)
            Text(title).font(.caption2).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).frame(height: 90)
        .background(.white.opacity(0.055)).clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct LibraryVideoButton: View {
    @ObservedObject var model: EditorModel
    @State private var picked: [PhotosPickerItem] = []
    @State private var loading = false
    var body: some View {
        PhotosPicker(selection: $picked, maxSelectionCount: 0, matching: .videos, photoLibrary: .shared()) {
            Label(loading ? "Đang nhập…" : "Thư viện", systemImage: "photo.on.rectangle")
        }
        .disabled(loading)
        .onChange(of: picked) { items in
            guard !items.isEmpty else { return }
            loading = true
            Task {
                for item in items {
                    do {
                        if let movie = try await item.loadTransferable(type: ImportedMovie.self) {
                            await model.add(url: movie.url)
                        } else {
                            model.progress = "Không đọc được video này từ Thư viện"
                        }
                    } catch {
                        model.progress = "Không nhập được: " + error.localizedDescription
                    }
                }
                picked = []
                loading = false
            }
        }
    }
}
