import AVFoundation

// Fades never overlap: shorten them proportionally when the audible interval is trimmed.
enum AudioEnvelope {
    static func bounded(fadeIn: Double, fadeOut: Double, length: Double) -> (fadeIn: Double, fadeOut: Double) {
        guard length.isFinite, length > 0 else { return (0, 0) }
        let incoming = fadeIn.isFinite ? max(0, fadeIn) : 0
        let outgoing = fadeOut.isFinite ? max(0, fadeOut) : 0
        let largest = max(incoming, outgoing)
        guard largest > 0 else { return (0, 0) }
        let relativeSum = incoming / largest + outgoing / largest
        if largest <= length / relativeSum { return (incoming, outgoing) }
        return (length * (incoming / largest) / relativeSum, length * (outgoing / largest) / relativeSum)
    }
    static func apply(to mix: AVMutableAudioMixInputParameters, sound: AudioSegment, start: Double, length: Double) {
        let fades = bounded(fadeIn: sound.fadeIn, fadeOut: sound.fadeOut, length: length)
        let volume = Float(min(1, max(0, sound.volume)))
        let beginning = MediaComposer.time(start), ending = MediaComposer.time(start + length)
        let incomingEnd = MediaComposer.time(start + fades.fadeIn)
        let outgoingStart = MediaComposer.time(start + length - fades.fadeOut)
        let hasIncoming = incomingEnd > beginning
        mix.setVolume(hasIncoming ? 0 : volume, at: beginning)
        if hasIncoming {
            mix.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume,
                              timeRange: CMTimeRange(start: beginning, end: incomingEnd))
        }
        if outgoingStart < ending {
            mix.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0,
                              timeRange: CMTimeRange(start: outgoingStart, end: ending))
        }
    }
}
