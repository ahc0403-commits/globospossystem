import AVFoundation
import Foundation

@main
enum VerifyIOSBankTransferSoundComposer {
  static func main() throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 3 else {
      throw VerificationError.invalidArguments
    }

    let resourceDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let outputDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
    let expectedTokens = [
      "prefix", "chin", "muoi_hang_chuc", "ba", "nghin", "bon",
      "tram", "nam", "muoi_hang_chuc", "sau", "suffix",
    ]
    let tokens = try VietnameseBankTransferSpeechTokens.make(for: 93_456)
    guard tokens == expectedTokens else {
      throw VerificationError.tokenMismatch(tokens)
    }

    let output = try VietnameseBankTransferSoundComposer().compose(
      amount: 93_456,
      eventID: "verification",
      resourceDirectory: resourceDirectory,
      outputDirectory: outputDirectory
    )
    let audio = try AVAudioFile(forReading: output)
    let duration = Double(audio.length) / audio.processingFormat.sampleRate
    guard duration > 0,
          duration <= VietnameseBankTransferSoundComposer.maximumNotificationSoundDuration
    else {
      throw VerificationError.invalidDuration(duration)
    }
    print("PASS iOS notification sound composition: \(duration)s")
  }

  enum VerificationError: Error {
    case invalidArguments
    case tokenMismatch([String])
    case invalidDuration(TimeInterval)
  }
}
