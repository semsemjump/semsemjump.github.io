// Measure loudness of audio files (or the audio of a video): overall RMS / peak in dBFS, and per-window RMS.
//
//   swiftc -swift-version 5 -O promo/loudness.swift -o /tmp/loudness
//   /tmp/loudness <file> [windowSeconds] [from] [to]
import AVFoundation
import Foundation

let args = CommandLine.arguments
let url = URL(fileURLWithPath: args[1])
let window = args.count > 2 ? Double(args[2])! : 0
let from = args.count > 3 ? Double(args[3])! : 0
let to = args.count > 4 ? Double(args[4])! : .infinity

let asset = AVURLAsset(url: url)
let track = asset.tracks(withMediaType: .audio)[0]
let reader = try AVAssetReader(asset: asset)
let rate = 44100.0
let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
  AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
  AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
])
reader.add(out)
if to.isFinite || from > 0 { reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 44100), end: CMTime(seconds: min(to, asset.duration.seconds), preferredTimescale: 44100)) }
reader.startReading()
var samples: [Float] = []
while let buf = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buf) {
  var len = 0; var ptr: UnsafeMutablePointer<Int8>?
  CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
  ptr!.withMemoryRebound(to: Float.self, capacity: len / 4) { samples.append(contentsOf: UnsafeBufferPointer(start: $0, count: len / 4)) }
}
func db(_ v: Double) -> String { v <= 0 ? "-inf" : String(format: "%6.1f", 20 * log10(v)) }
func stats(_ s: ArraySlice<Float>) -> (rms: Double, peak: Double) {
  var sum = 0.0, peak = 0.0
  for v in s { let a = Double(abs(v)); sum += a * a; peak = max(peak, a) }
  return (s.isEmpty ? 0 : sqrt(sum / Double(s.count)), peak)
}
let all = stats(samples[...])
let clipped = samples.filter { abs($0) >= 0.999 }.count
print("\(url.lastPathComponent): \(String(format: "%.2f", Double(samples.count) / rate))s  RMS \(db(all.rms)) dBFS  peak \(db(all.peak)) dBFS  clipped samples \(clipped)")
if window > 0 {
  let n = Int(window * rate)
  var i = 0
  while i < samples.count {
    let st = stats(samples[i..<min(i + n, samples.count)])
    let t = from + Double(i) / rate
    let bar = String(repeating: "#", count: max(0, Int((20 * log10(max(st.rms, 1e-6)) + 40) / 1.5)))
    print(String(format: "%5.1fs", t), "RMS", db(st.rms), "peak", db(st.peak), bar)
    i += n
  }
}
