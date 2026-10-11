//
//  FFmpegAssetTrack.swift
//  KSPlayer
//
//  Created by kintan on 2023/2/12.
//

import AVFoundation
import FFmpegKit
import Libavformat

public class FFmpegAssetTrack: MediaPlayerTrack {
    public private(set) var trackID: Int32 = 0
    public let codecName: String
    public var name: String = ""
    public private(set) var languageCode: String?
    public var nominalFrameRate: Float = 0
    public private(set) var avgFrameRate = Timebase.defaultValue
    public private(set) var realFrameRate = Timebase.defaultValue
    public private(set) var bitRate: Int64 = 0
    public let mediaType: AVFoundation.AVMediaType
    public let formatName: String?
    public let bitDepth: Int32
    private var stream: UnsafeMutablePointer<AVStream>?
    var startTime = CMTime.zero
    var codecpar: AVCodecParameters
    var timebase: Timebase = .defaultValue
    let bitsPerRawSample: Int32
    // audio
    public let audioDescriptor: AudioDescriptor?
    // subtitle
    public let isImageSubtitle: Bool
    public var delay: TimeInterval = 0
    var subtitle: SyncPlayerItemTrack<SubtitleFrame>?
    // video
    public private(set) var rotation: Int16 = 0
    public var dovi: DOVIDecoderConfigurationRecord?
    public let fieldOrder: FFmpegFieldOrder
    public let formatDescription: CMFormatDescription?
    var closedCaptionsTrack: FFmpegAssetTrack?
    let isConvertNALSize: Bool
    var seekByBytes = false
    public var description: String {
        var description = codecName
        if let formatName {
            description += ", \(formatName)"
        }
        if bitsPerRawSample > 0 {
            description += "(\(bitsPerRawSample.kmFormatted) bit)"
        }
        if let audioDescriptor {
            description += ", \(audioDescriptor.sampleRate)Hz"
            description += ", \(audioDescriptor.channel.description)"
        }
        if let formatDescription {
            if mediaType == .video {
                let naturalSize = formatDescription.naturalSize
                description += ", \(Int(naturalSize.width))x\(Int(naturalSize.height))"
                description += String(format: ", %.2f fps", nominalFrameRate)
            }
        }
        if bitRate > 0 {
            description += ", \(bitRate.kmFormatted)bps"
        }
        if let language {
            description += "(\(language))"
        }
        return description
    }

    convenience init?(stream: UnsafeMutablePointer<AVStream>) {
        // `codecpar` is imported as an implicitly unwrapped optional, but
        // FFmpeg leaves it NULL for streams it has no parser for (e.g. the
        // `bin_data` streams present in many DVB/MPEG-TS muxes). This
        // initialiser is already failable, so skip the stream rather than
        // trapping — createCodec's compactMap drops it.
        guard let codecpar = stream.pointee.codecpar?.pointee else { return nil }
        // [NewTV] 只解析 音/视/字幕 三类轨。DVB/MPEG-TS 的 bin_data / teletext
        // 数据轨 codecpar 半填充（NULL profile name、野 sideData、野 extradata_size），
        // init(codecpar:) 读这些字段会解引用野指针并可能**写坏堆** —— 后台线程越界
        // 写后，主线程（Flutter 引擎定时器）摸到损坏对象 SIGSEGV（Runner-2026-10-11
        // -133518.ips）。createCodec 本来也只会从中挑 音/视/字幕，数据轨直接拒绝零损失。
        guard codecpar.codec_type == AVMEDIA_TYPE_AUDIO
                || codecpar.codec_type == AVMEDIA_TYPE_VIDEO
                || codecpar.codec_type == AVMEDIA_TYPE_SUBTITLE else {
            return nil
        }
        self.init(codecpar: codecpar)
        self.stream = stream
        let metadata = toDictionary(stream.pointee.metadata)
        if let value = metadata["variant_bitrate"] ?? metadata["BPS"], let bitRate = Int64(value) {
            self.bitRate = bitRate
        }
        trackID = stream.pointee.index
        var timebase = Timebase(stream.pointee.time_base)
        if timebase.num <= 0 || timebase.den <= 0 {
            timebase = Timebase(num: 1, den: 1000)
        }
        if stream.pointee.start_time != Int64.min {
            startTime = timebase.cmtime(for: stream.pointee.start_time)
        }
        self.timebase = timebase
        avgFrameRate = Timebase(stream.pointee.avg_frame_rate)
        realFrameRate = Timebase(stream.pointee.r_frame_rate)
        if mediaType == .audio {
            nominalFrameRate = Self.audioNominalFrameRate(
                sampleRate: codecpar.sample_rate,
                frameSize: codecpar.frame_size,
                codecID: codecpar.codec_id
            )
        } else {
            if stream.pointee.duration > 0, stream.pointee.nb_frames > 0, stream.pointee.nb_frames != stream.pointee.duration {
                nominalFrameRate = Float(stream.pointee.nb_frames) * Float(timebase.den) / Float(stream.pointee.duration) * Float(timebase.num)
            } else if avgFrameRate.den > 0, avgFrameRate.num > 0 {
                nominalFrameRate = Float(avgFrameRate.num) / Float(avgFrameRate.den)
            } else {
                nominalFrameRate = 24
            }
        }

        if let value = metadata["language"], value != "und" {
            languageCode = value
        } else {
            languageCode = nil
        }
        if let value = metadata["title"] {
            name = value
        } else {
            name = languageCode ?? codecName
        }
        // AV_DISPOSITION_DEFAULT
        if mediaType == .subtitle {
            isEnabled = !isImageSubtitle || stream.pointee.disposition & AV_DISPOSITION_FORCED == AV_DISPOSITION_FORCED
            if stream.pointee.disposition & AV_DISPOSITION_HEARING_IMPAIRED == AV_DISPOSITION_HEARING_IMPAIRED {
                name += "(hearing impaired)"
            }
        }
        //        var buf = [Int8](repeating: 0, count: 256)
        //        avcodec_string(&buf, buf.count, codecpar, 0)
    }

    /// Audio `nominalFrameRate` derived from `sample_rate` / `frame_size`.
    ///
    /// `AVCodecParameters.frame_size` is audio-only and left at `0` by most
    /// demuxers (AAC/MP3/Opus/FLAC/Vorbis) until the first frame is decoded,
    /// and a `0` divisor traps Swift with a divide-by-zero. When it is unset,
    /// fall back to codec-aware constants (TRUEHD: 48, everything else: 1000)
    /// instead of deriving a frame size arithmetically. `sample_rate` can also
    /// be `0` pre-decode, so guard both before dividing — mirroring
    /// `AudioDescriptor`'s own `sampleRate <= 0` guard (`Resample.swift`).
    static func audioNominalFrameRate(sampleRate: Int32, frameSize: Int32, codecID: AVCodecID) -> Float {
        // Suggested by the maintainer: codec-aware fallbacks instead of deriving a
        // frame size from the stream timebase (whose den/num can integer-divide to 0).
        let effectiveFrameSize = frameSize > 0 ? frameSize : codecID == AV_CODEC_ID_TRUEHD ? 48 : 1000
        guard sampleRate > 0, effectiveFrameSize > 0 else {
            return 48
        }
        return max(Float(sampleRate / effectiveFrameSize), 48)
    }

    init?(codecpar: AVCodecParameters) {
        self.codecpar = codecpar
        bitRate = codecpar.bit_rate
        // codec_tag byte order is LSB first CMFormatDescription.MediaSubType(rawValue: codecpar.codec_tag.bigEndian)
        let codecType = codecpar.codec_id.mediaSubType
        var codecName = ""
        if let descriptor = avcodec_descriptor_get(codecpar.codec_id) {
            // [NewTV2] AVCodecDescriptor.name 在部分损坏的流里也是 NULL，
            // String(cString: NULL) 直接 EXC_BAD_ACCESS（Runner-2026-10-11-142555.ips）。
            if let codecDescrName = descriptor.pointee.name {
                codecName += String(cString: codecDescrName)
            }
            // [NewTV] AVProfile 终止项的 name 是 NULL；空 profile 数组首项即终止项，
            // String(cString:) 传 NULL 直接 EXC_BAD_ACCESS（直播流实测崩溃点之一）。
            if let profiles = descriptor.pointee.profiles, let profileName = profiles.pointee.name {
                codecName += " (\(String(cString: profileName)))"
            }
        } else {
            codecName = ""
        }
        self.codecName = codecName
        fieldOrder = FFmpegFieldOrder(rawValue: UInt8(codecpar.field_order.rawValue)) ?? .unknown
        var formatDescriptionOut: CMFormatDescription?
        if codecpar.codec_type == AVMEDIA_TYPE_AUDIO {
            mediaType = .audio
            audioDescriptor = AudioDescriptor(codecpar: codecpar)
            isConvertNALSize = false
            bitDepth = 0
            let layout = codecpar.ch_layout
            let channelsPerFrame = UInt32(layout.nb_channels)
            let sampleFormat = AVSampleFormat(codecpar.format)
            // [NewTV] 未知/损坏的 sample format 会让 av_get_bytes_per_sample 返回负值，
            // UInt32(负数) 在 Swift 里直接 trap（SIGTRAP）。钳到 0 保底。
            let bytesPerSample = UInt32(max(av_get_bytes_per_sample(sampleFormat), 0))
            let formatFlags = ((sampleFormat == AV_SAMPLE_FMT_FLT || sampleFormat == AV_SAMPLE_FMT_DBL) ? kAudioFormatFlagIsFloat : sampleFormat == AV_SAMPLE_FMT_U8 ? 0 : kAudioFormatFlagIsSignedInteger) | kAudioFormatFlagIsPacked
            var audioStreamBasicDescription = AudioStreamBasicDescription(mSampleRate: Float64(codecpar.sample_rate), mFormatID: codecType.rawValue, mFormatFlags: formatFlags, mBytesPerPacket: bytesPerSample * channelsPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerSample * channelsPerFrame, mChannelsPerFrame: channelsPerFrame, mBitsPerChannel: bytesPerSample * 8, mReserved: 0)
            _ = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &audioStreamBasicDescription, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescriptionOut)
            if let name = av_get_sample_fmt_name(sampleFormat) {
                formatName = String(cString: name)
            } else {
                formatName = nil
            }
        } else if codecpar.codec_type == AVMEDIA_TYPE_VIDEO {
            audioDescriptor = nil
            mediaType = .video
            if codecpar.nb_coded_side_data > 0, let sideDatas = codecpar.coded_side_data {
                // [NewTV] 真实流 side data 条目个位数；count 被拆流中途污染成
                // 天文数字时，照它遍历会沿数组越界扫整个堆。钳到 8 保底。
                let sideCount = min(Int(codecpar.nb_coded_side_data), 8)
                for i in 0 ..< sideCount {
                    let sideData = sideDatas[Int(i)]
                    // [NewTV] 直播流（DVB/MPEG-TS）的 side data 可能是 NULL 指针、
                    // 长度不足，或**整条 entry 就是越界读出来的垃圾**（count 被污染时）：
                    // 这时 data 是任意非 NULL 值、size 是任意数，`data != nil && size > 0`
                    // 这种字段校验根本挡不住 —— 校验通过、真去读的那一刻内存已被释放/改写
                    // （PAC failure，Runner-2026-10-11-120910 / 185142 的闪退点）。
                    // [NewTV4] 两道新闸：
                    //   ① 尺寸必须**精确**等于该类型规定值（真实流就是精确值，
                    //      垃圾 entry 极难恰好命中）；
                    //   ② 解析前先把那段字节**复制到自己的内存**再读，绝不直接
                    //      解引用 codecpar 里那个可能已失效的指针。
                    if sideData.type == AV_PKT_DATA_DOVI_CONF {
                        let expect = MemoryLayout<DOVIDecoderConfigurationRecord>.size
                        guard let sdData = sideData.data, sideData.size == expect else { continue }
                        // [NewTV4] 复制到**对齐的自有内存**再解析，不直接解引用可能已失效的
                        // 原缓冲。注意：DOVIDecoderConfigurationRecord 是导入的 C 结构体，
                        // Swift 只给了 8 参数的 memberwise init（没有无参 init），
                        // 所以不能 `DOVIDecoderConfigurationRecord()` 构造，
                        // 改为裸内存 load(as:)（按该类型 alignment 分配，避免未对齐读）。
                        let buf = UnsafeMutableRawPointer.allocate(
                            byteCount: expect,
                            alignment: MemoryLayout<DOVIDecoderConfigurationRecord>.alignment
                        )
                        defer { buf.deallocate() }
                        let out = buf.bindMemory(to: UInt8.self, capacity: expect)
                        for k in 0 ..< expect { out[k] = sdData[k] }
                        dovi = buf.load(as: DOVIDecoderConfigurationRecord.self)
                    } else if sideData.type == AV_PKT_DATA_DISPLAYMATRIX {
                        // av_display_rotation_get 固定读 9 个 Int32 = 36 字节
                        let expect = MemoryLayout<Int32>.size * 9
                        guard let sdData = sideData.data, sideData.size == expect else { continue }
                        var matrix = [Int32](repeating: 0, count: 9)
                        matrix.withUnsafeMutableBytes { dst in
                            guard let out = dst.bindMemory(to: UInt8.self).baseAddress else { return }
                            for k in 0 ..< expect { out[k] = sdData[k] }
                        }
                        let rawRotation = -av_display_rotation_get(matrix)
                        if rawRotation.isFinite {
                            let degrees = Int(rawRotation.rounded())
                            let normalized = ((degrees % 360) + 360) % 360
                            rotation = Int16(normalized)
                        } else {
                            rotation = 0
                        }
                    }
                }
            }
            let sar = codecpar.sample_aspect_ratio.size
            var extradataSize = Int32(0)
            var extradata = codecpar.extradata
            let atomsData: Data?
            // [NewTV] 直播流 codecpar.extradata_size 可能是负值/天文数字（拆流中途
            // 字段未填完），Data(bytes:count:) 按它野读直接 EXC_BAD_ACCESS。
            // 合法编解码 extradata 远小于 4MB，越界就当没有 extradata 走 else 分支。
            if let extradata, codecpar.extradata_size > 0, codecpar.extradata_size <= (4 << 20) {
                extradataSize = codecpar.extradata_size
                if extradataSize >= 5, extradata[4] == 0xFE {
                    extradata[4] = 0xFF
                    isConvertNALSize = true
                } else {
                    isConvertNALSize = false
                }
                atomsData = Data(bytes: extradata, count: Int(extradataSize))
            } else {
                if codecType.rawValue == kCMVideoCodecType_VP9 {
                    // ff_videotoolbox_vpcc_extradata_create
                    var ioContext: UnsafeMutablePointer<AVIOContext>?
                    guard avio_open_dyn_buf(&ioContext) == 0 else {
                        return nil
                    }
                    ff_isom_write_vpcc(nil, ioContext, nil, 0, &self.codecpar)
                    extradataSize = avio_close_dyn_buf(ioContext, &extradata)
                    guard let extradata else {
                        return nil
                    }
                    var data = Data()
                    var array: [UInt8] = [1, 0, 0, 0]
                    data.append(&array, count: 4)
                    data.append(extradata, count: Int(extradataSize))
                    atomsData = data
                } else {
                    atomsData = nil
                }
                isConvertNALSize = false
            }
            let format = AVPixelFormat(rawValue: codecpar.format)
            bitDepth = format.bitDepth
            let fullRange = codecpar.color_range == AVCOL_RANGE_JPEG
            let dic: NSMutableDictionary = [
                kCVImageBufferChromaLocationBottomFieldKey: kCVImageBufferChromaLocation_Left,
                kCVImageBufferChromaLocationTopFieldKey: kCVImageBufferChromaLocation_Left,
                kCMFormatDescriptionExtension_Depth: format.bitDepth * Int32(format.planeCount),
                kCMFormatDescriptionExtension_FullRangeVideo: fullRange,
                codecType.rawValue == kCMVideoCodecType_HEVC ? "EnableHardwareAcceleratedVideoDecoder" : "RequireHardwareAcceleratedVideoDecoder": true,
            ]
            // kCMFormatDescriptionExtension_BitsPerComponent
            if let atomsData {
                dic[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = [codecType.rawValue.avc: atomsData]
            }
            dic[kCVPixelBufferPixelFormatTypeKey] = format.osType(fullRange: fullRange)
            dic[kCVImageBufferPixelAspectRatioKey] = sar.aspectRatio
            dic[kCVImageBufferColorPrimariesKey] = codecpar.color_primaries.colorPrimaries as String?
            dic[kCVImageBufferTransferFunctionKey] = codecpar.color_trc.transferFunction as String?
            dic[kCVImageBufferYCbCrMatrixKey] = codecpar.color_space.ycbcrMatrix as String?
            // swiftlint:disable line_length
            _ = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: codecType.rawValue, width: codecpar.width, height: codecpar.height, extensions: dic, formatDescriptionOut: &formatDescriptionOut)
            // swiftlint:enable line_length
            if let name = av_get_pix_fmt_name(format) {
                formatName = String(cString: name)
            } else {
                formatName = nil
            }
        } else if codecpar.codec_type == AVMEDIA_TYPE_SUBTITLE {
            mediaType = .subtitle
            audioDescriptor = nil
            formatName = nil
            bitDepth = 0
            isConvertNALSize = false
            _ = CMFormatDescriptionCreate(allocator: kCFAllocatorDefault, mediaType: kCMMediaType_Subtitle, mediaSubType: codecType.rawValue, extensions: nil, formatDescriptionOut: &formatDescriptionOut)
        } else {
            bitDepth = 0
            return nil
        }
        formatDescription = formatDescriptionOut
        bitsPerRawSample = codecpar.bits_per_raw_sample
        isImageSubtitle = [AV_CODEC_ID_DVD_SUBTITLE, AV_CODEC_ID_DVB_SUBTITLE, AV_CODEC_ID_DVB_TELETEXT, AV_CODEC_ID_HDMV_PGS_SUBTITLE].contains(codecpar.codec_id)
        trackID = 0
    }

    func createContext(options: KSOptions) throws -> UnsafeMutablePointer<AVCodecContext> {
        try codecpar.createContext(options: options)
    }

    public var isEnabled: Bool {
        get {
            stream?.pointee.discard == AVDISCARD_DEFAULT
        }
        set {
            var discard = newValue ? AVDISCARD_DEFAULT : AVDISCARD_ALL
            if mediaType == .subtitle, !isImageSubtitle {
                discard = AVDISCARD_DEFAULT
            }
            stream?.pointee.discard = discard
        }
    }
}

extension FFmpegAssetTrack {
    var pixelFormatType: OSType? {
        let format = AVPixelFormat(codecpar.format)
        return format.osType(fullRange: formatDescription?.fullRangeVideo ?? false)
    }
}
