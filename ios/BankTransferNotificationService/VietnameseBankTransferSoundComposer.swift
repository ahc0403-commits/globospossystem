import AVFoundation
import Foundation

enum VietnameseBankTransferSoundComposerError: Error {
  case amountOutOfRange
  case missingAudioToken(String)
  case incompatibleAudioToken(String)
  case outputTooLong(TimeInterval)
}

enum VietnameseBankTransferSpeechTokens {
  static func make(for amount: Int64) throws -> [String] {
    guard (1...999_999_999).contains(amount) else {
      throw VietnameseBankTransferSoundComposerError.amountOutOfRange
    }

    var tokens = ["prefix"]
    let millions = Int(amount / 1_000_000)
    let thousands = Int((amount / 1_000) % 1_000)
    let units = Int(amount % 1_000)

    if millions > 0 {
      tokens.append(contentsOf: triplet(millions))
      tokens.append("trieu")
    }
    if thousands > 0 {
      tokens.append(
        contentsOf: triplet(
          thousands,
          includeLeadingHundreds: millions > 0 && thousands < 100
        )
      )
      tokens.append("nghin")
    }
    if units > 0 {
      tokens.append(
        contentsOf: triplet(
          units,
          includeLeadingHundreds: (millions > 0 || thousands > 0) && units < 100
        )
      )
    }

    tokens.append("suffix")
    return tokens
  }

  private static func triplet(
    _ value: Int,
    includeLeadingHundreds: Bool = false
  ) -> [String] {
    var tokens: [String] = []
    let hundreds = value / 100
    let tens = (value / 10) % 10
    let units = value % 10

    if hundreds > 0 || includeLeadingHundreds {
      tokens.append(digit(hundreds))
      tokens.append("tram")
    }

    if tens > 1 {
      tokens.append(digit(tens))
      tokens.append("muoi_hang_chuc")
    } else if tens == 1 {
      tokens.append("muoi")
    } else if units > 0 && (hundreds > 0 || includeLeadingHundreds) {
      tokens.append("le")
    }

    if units > 0 {
      if tens > 1 && units == 1 {
        tokens.append("mot_sau_muoi")
      } else if tens > 1 && units == 4 {
        tokens.append("tu")
      } else if tens >= 1 && units == 5 {
        tokens.append("lam")
      } else {
        tokens.append(digit(units))
      }
    }

    return tokens
  }

  private static func digit(_ value: Int) -> String {
    ["khong", "mot", "hai", "ba", "bon", "nam", "sau", "bay", "tam", "chin"][value]
  }
}

struct VietnameseBankTransferSoundComposer {
  static let maximumNotificationSoundDuration: TimeInterval = 29.5
  static let tokenGapSeconds: TimeInterval = 0.035

  func compose(
    amount: Int64,
    eventID: String,
    resourceDirectory: URL,
    outputDirectory: URL
  ) throws -> URL {
    let tokens = try VietnameseBankTransferSpeechTokens.make(for: amount)
    let sourceURLs = try tokens.map { token -> URL in
      let sourceURL = resourceDirectory.appendingPathComponent("\(token).mp3")
      guard FileManager.default.fileExists(atPath: sourceURL.path) else {
        throw VietnameseBankTransferSoundComposerError.missingAudioToken(token)
      }
      return sourceURL
    }

    try FileManager.default.createDirectory(
      at: outputDirectory,
      withIntermediateDirectories: true
    )
    let safeEventID = eventID.replacingOccurrences(
      of: "[^a-zA-Z0-9_-]",
      with: "-",
      options: .regularExpression
    )
    let outputURL = outputDirectory.appendingPathComponent(
      "sepay-\(safeEventID).caf"
    )
    try? FileManager.default.removeItem(at: outputURL)

    let firstInput = try AVAudioFile(forReading: sourceURLs[0])
    let sourceFormat = firstInput.processingFormat
    let outputSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: sourceFormat.sampleRate,
      AVNumberOfChannelsKey: sourceFormat.channelCount,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
    let output = try AVAudioFile(
      forWriting: outputURL,
      settings: outputSettings,
      commonFormat: .pcmFormatFloat32,
      interleaved: false
    )

    for (index, sourceURL) in sourceURLs.enumerated() {
      let input = try AVAudioFile(forReading: sourceURL)
      guard input.processingFormat.sampleRate == sourceFormat.sampleRate,
            input.processingFormat.channelCount == sourceFormat.channelCount
      else {
        throw VietnameseBankTransferSoundComposerError.incompatibleAudioToken(
          tokens[index]
        )
      }

      guard let buffer = AVAudioPCMBuffer(
        pcmFormat: input.processingFormat,
        frameCapacity: AVAudioFrameCount(input.length)
      ) else {
        throw VietnameseBankTransferSoundComposerError.incompatibleAudioToken(
          tokens[index]
        )
      }
      try input.read(into: buffer)
      try output.write(from: buffer)

      if index < sourceURLs.count - 1 {
        try writeSilence(
          seconds: Self.tokenGapSeconds,
          format: output.processingFormat,
          to: output
        )
      }
    }

    let duration = Double(output.length) / output.processingFormat.sampleRate
    guard duration <= Self.maximumNotificationSoundDuration else {
      try? FileManager.default.removeItem(at: outputURL)
      throw VietnameseBankTransferSoundComposerError.outputTooLong(duration)
    }
    return outputURL
  }

  private func writeSilence(
    seconds: TimeInterval,
    format: AVAudioFormat,
    to output: AVAudioFile
  ) throws {
    let frameCount = AVAudioFrameCount(format.sampleRate * seconds)
    guard frameCount > 0,
          let silence = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
          )
    else { return }
    silence.frameLength = frameCount
    if let channels = silence.floatChannelData {
      for channel in 0..<Int(format.channelCount) {
        channels[channel].initialize(repeating: 0, count: Int(frameCount))
      }
    }
    try output.write(from: silence)
  }
}
