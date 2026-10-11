import SwiftUI

struct AudioEnvelopeSheet: View {
    let length: Double
    let apply: (Double, Double, Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var volume: Double
    @State private var incoming: Double
    @State private var outgoing: Double
    init(sound: AudioSegment, length: Double, apply: @escaping (Double, Double, Double) -> Void) {
        self.length = length; self.apply = apply
        let fades = AudioEnvelope.bounded(fadeIn: sound.fadeIn, fadeOut: sound.fadeOut, length: length)
        _volume = State(initialValue: sound.volume)
        _incoming = State(initialValue: fades.fadeIn); _outgoing = State(initialValue: fades.fadeOut)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Âm lượng · \(Int((volume * 100).rounded()))%") {
                    Slider(value: $volume, in: 0...1).accessibilityIdentifier("audioGain")
                }
                Section("Vào dần · " + formatTime(incoming)) {
                    Slider(value: $incoming, in: 0...max(0.001, length - outgoing)).accessibilityIdentifier("audioFadeIn")
                    HStack {
                        Text(formatTime(incoming)).monospacedDigit().accessibilityIdentifier("audioFadeInTime")
                        Spacer()
                        Button("Vào 1 giây") { incoming = min(1, max(0, length - outgoing)) }.accessibilityIdentifier("fadeInOneSecond")
                    }.buttonStyle(.borderless)
                }
                Section("Ra dần · " + formatTime(outgoing)) {
                    Slider(value: $outgoing, in: 0...max(0.001, length - incoming)).accessibilityIdentifier("audioFadeOut")
                    HStack {
                        Text(formatTime(outgoing)).monospacedDigit().accessibilityIdentifier("audioFadeOutTime")
                        Spacer()
                        Button("Ra 1 giây") { outgoing = min(1, max(0, length - incoming)) }.accessibilityIdentifier("fadeOutOneSecond")
                    }.buttonStyle(.borderless)
                }
                Button("Tắt vào/ra dần") { incoming = 0; outgoing = 0 }.accessibilityIdentifier("clearAudioFades")
                Text("Áp dụng cho đoạn nhạc đã chọn. Âm lượng thay đổi dần ở đầu và cuối đoạn, trong cả xem trước và video xuất.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("Âm thanh").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Hủy") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Áp dụng") { apply(volume, incoming, outgoing); dismiss() }.accessibilityIdentifier("applyAudioEnvelope")
                }
            }
        }.presentationDetents([.large])
    }
}
