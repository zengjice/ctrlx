#if os(macOS) || os(iOS)
    import AVFoundation
    import CtrlxNetworking
    import Foundation

    /// Converters retain partial packets; each audio stream owns its own actor.
    package actor BrowserAudioCodec {
        private var encoder: AVAudioConverter?
        private var decoder: AVAudioConverter?

        package init() { }

        package static var pcmFormat: AVAudioFormat {
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: RemoteBrowserAudio.sampleRate,
                channels: RemoteBrowserAudio.channels,
                interleaved: true
            )!
        }

        private static var aacFormat: AVAudioFormat {
            AVAudioFormat(settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: RemoteBrowserAudio.sampleRate,
                AVNumberOfChannelsKey: RemoteBrowserAudio.channels,
            ])!
        }

        package func encode(_ pcm: Data) throws -> (packets: [Data], cookie: Data?) {
            guard !pcm.isEmpty, pcm.count <= 8_192 * 8, pcm.count.isMultiple(of: 8) else {
                throw AudioError.invalidData
            }
            if encoder == nil {
                encoder = AVAudioConverter(from: Self.pcmFormat, to: Self.aacFormat)
                encoder?.bitRate = 96_000
            }
            guard let encoder else { throw AudioError.unavailable }
            let input = AVAudioPCMBuffer(pcmFormat: Self.pcmFormat, frameCapacity: UInt32(pcm.count / 8))!
            input.frameLength = input.frameCapacity
            pcm.copyBytes(to: input.mutableAudioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: UInt8.self), count: pcm.count)
            let output = AVAudioCompressedBuffer(
                format: encoder.outputFormat,
                packetCapacity: UInt32(RemoteBrowserAudio.maximumPackets),
                maximumPacketSize: encoder.maximumOutputPacketSize
            )
            var supplied = false
            var error: NSError?
            let status = encoder.convert(to: output, error: &error) { _, state in
                guard !supplied else { state.pointee = .noDataNow
                    return nil
                }
                supplied = true
                state.pointee = .haveData
                return input
            }
            if let error {
                throw error
            }
            guard status != .error else { throw AudioError.invalidData }
            let packets = (0..<Int(output.packetCount)).map { index -> Data in
                let description = output.packetDescriptions![index]
                return Data(bytes: output.data.advanced(by: Int(description.mStartOffset)), count: Int(description.mDataByteSize))
            }
            return (packets, encoder.magicCookie)
        }

        package func decode(_ packets: [Data], cookie: Data?) throws -> Data {
            guard
                !packets.isEmpty, packets.count <= RemoteBrowserAudio.maximumPackets,
                packets.allSatisfy({ !$0.isEmpty && $0.count <= 4_096 }), (cookie?.count ?? 0) <= 1_024 else {
                throw AudioError.invalidData
            }
            if decoder == nil {
                decoder = AVAudioConverter(from: Self.aacFormat, to: Self.pcmFormat)
                decoder?.magicCookie = cookie
            }
            guard let decoder else { throw AudioError.unavailable }
            let input = AVAudioCompressedBuffer(format: decoder.inputFormat, packetCapacity: UInt32(packets.count), maximumPacketSize: 4_096)
            var offset = 0
            for (index, packet) in packets.enumerated() {
                packet.copyBytes(to: input.data.advanced(by: offset).assumingMemoryBound(to: UInt8.self), count: packet.count)
                input.packetDescriptions![index] = AudioStreamPacketDescription(mStartOffset: Int64(offset), mVariableFramesInPacket: 1_024, mDataByteSize: UInt32(packet.count))
                offset += packet.count
            }
            input.packetCount = UInt32(packets.count)
            input.byteLength = UInt32(offset)
            let output = AVAudioPCMBuffer(pcmFormat: Self.pcmFormat, frameCapacity: UInt32((packets.count + 2) * 1_024))!
            var supplied = false
            var error: NSError?
            let status = decoder.convert(to: output, error: &error) { _, state in
                guard !supplied else { state.pointee = .noDataNow
                    return nil
                }
                supplied = true
                state.pointee = .haveData
                return input
            }
            if let error {
                throw error
            }
            guard status != .error else { throw AudioError.invalidData }
            return Data(bytes: output.audioBufferList.pointee.mBuffers.mData!, count: Int(output.frameLength) * 8)
        }

        enum AudioError: LocalizedError {
            case unavailable
            case invalidData
            var errorDescription: String? {
                switch self {
                case .unavailable: "Browser audio conversion is unavailable on this device."
                case .invalidData: "Invalid browser audio packet."
                }
            }
        }
    }
#endif
