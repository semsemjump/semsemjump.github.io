// Encode the reel: PNG frames -> H.264, then lay the game's music and sound effects under it.
//
//   swiftc -swift-version 5 -O promo/encode.swift -o /tmp/encode
//   /tmp/encode <framesDir> <sfx.json> <assetsDir> <out.mp4>
//
// Music: main theme 0–9.9 s, boss theme 9.7–14 s, title theme 13.8–25 s (short crossfades, fade out at the end).
// Levels were set with promo/loudness.swift: the three themes differ by ~4 dB at the source (main −19.6, boss −15.8,
// title −15.5 dBFS RMS). Gains bring each section to roughly −17…−19 dBFS RMS (the boss and dash sections carry
// extra effects, so their music sits a little lower); effects peak around −10 dBFS and the mix stays below −1.5 dBFS.
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

let args = CommandLine.arguments
guard args.count == 5 else { print("usage: encode <framesDir> <sfx.json> <assetsDir> <out.mp4>"); exit(2) }
let framesDir = URL(fileURLWithPath: args[1]), sfxURL = URL(fileURLWithPath: args[2])
let assets = URL(fileURLWithPath: args[3]), outURL = URL(fileURLWithPath: args[4])
let fps: Int32 = 30, W = 1080, H = 1920
let wait = DispatchSemaphore(value: 0)
func sec(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }

// ---------- 1. frames -> silent video ----------
let silent = outURL.deletingLastPathComponent().appendingPathComponent("reel_video_only.mp4")
try? FileManager.default.removeItem(at: silent)
let writer = try AVAssetWriter(outputURL: silent, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
  AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
  AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000,
                                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                                    AVVideoMaxKeyFrameIntervalKey: 30],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
  kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
  kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)
let frames = try FileManager.default.contentsOfDirectory(atPath: framesDir.path).filter { $0.hasSuffix(".png") }.sorted()
for (i, name) in frames.enumerated() {
  autoreleasepool {
    let src = CGImageSourceCreateWithURL(framesDir.appendingPathComponent(name) as CFURL, nil)!
    let image = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    let pb = buffer!
    CVPixelBufferLockBaseAddress(pb, [])
    let c = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: W, height: H, bitsPerComponent: 8,
                      bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    c.interpolationQuality = .none
    c.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
    CVPixelBufferUnlockBaseAddress(pb, [])
    while !input.isReadyForMoreMediaData { usleep(2000) }
    adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
  }
}
input.markAsFinished()
writer.finishWriting { wait.signal() }
wait.wait()
guard writer.status == .completed else { print("video failed:", writer.error as Any); exit(1) }
print("video: \(frames.count) frames")

// ---------- 2. composition: video + music + sound effects ----------
let comp = AVMutableComposition()
let video = AVURLAsset(url: silent)
let length = video.duration
let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
try vTrack.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: video.tracks(withMediaType: .video)[0], at: .zero)
var mixParams: [AVMutableAudioMixInputParameters] = []

func addMusic(_ file: String, from: Double, to: Double, volume: Float, fadeIn: Double, fadeOut: Double) throws {
  let asset = AVURLAsset(url: assets.appendingPathComponent("music/\(file)"))
  let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
  try track.insertTimeRange(CMTimeRange(start: .zero, duration: sec(to - from)), of: asset.tracks(withMediaType: .audio)[0], at: sec(from))
  let p = AVMutableAudioMixInputParameters(track: track)
  p.setVolume(0, at: .zero)
  p.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume, timeRange: CMTimeRange(start: sec(from), duration: sec(fadeIn)))
  p.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0, timeRange: CMTimeRange(start: sec(to - fadeOut), duration: sec(fadeOut)))
  mixParams.append(p)
}
let total = length.seconds
try addMusic("mus_main.m4a", from: 0, to: 9.9, volume: 1.0, fadeIn: 0.05, fadeOut: 0.3)
try addMusic("mus_boss.m4a", from: 9.7, to: 14.0, volume: 0.5, fadeIn: 0.2, fadeOut: 0.3)
try addMusic("mus_title.m4a", from: 13.8, to: total, volume: 0.55, fadeIn: 0.3, fadeOut: 1.2)

// sound effects go on as many tracks as needed so none of them overlap within a track
struct Sfx: Decodable { let t: Double; let name: String }
let sfx = try JSONDecoder().decode([Sfx].self, from: Data(contentsOf: sfxURL)).sorted { $0.t < $1.t }
let volumes: [String: Float] = ["step": 0.3, "hit": 0.3, "coin": 0.35, "bossin": 0.3, "bossdown": 0.4, "record": 0.5]
var lanes: [(track: AVMutableCompositionTrack, params: AVMutableAudioMixInputParameters, end: Double)] = []
for e in sfx where e.t < total {
  let asset = AVURLAsset(url: assets.appendingPathComponent("sfx/\(e.name).wav"))
  guard let src = asset.tracks(withMediaType: .audio).first else { continue }
  let dur = min(asset.duration.seconds, e.name == "step" ? 0.3 : 1.2, total - e.t)
  var lane = lanes.firstIndex { $0.end <= e.t }
  if lane == nil {
    let tr = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
    lanes.append((tr, AVMutableAudioMixInputParameters(track: tr), 0)); lane = lanes.count - 1
  }
  let l = lanes[lane!]
  if e.t > l.end { l.track.insertEmptyTimeRange(CMTimeRange(start: sec(l.end), end: sec(e.t))) }
  try l.track.insertTimeRange(CMTimeRange(start: .zero, duration: sec(dur)), of: src, at: sec(e.t))
  l.params.setVolume(volumes[e.name] ?? 0.5, at: sec(e.t))
  lanes[lane!].end = e.t + dur
}
mixParams += lanes.map { $0.params }
print("sfx: \(sfx.count) cues on \(lanes.count) tracks")

let mix = AVMutableAudioMix()
mix.inputParameters = mixParams
try? FileManager.default.removeItem(at: outURL)
let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality)!
export.outputURL = outURL
export.outputFileType = .mp4
export.audioMix = mix
export.timeRange = CMTimeRange(start: .zero, duration: length)
export.exportAsynchronously { wait.signal() }
wait.wait()
guard export.status == .completed else { print("export failed:", export.error as Any); exit(1) }
try? FileManager.default.removeItem(at: silent)
print("done:", outURL.path)
