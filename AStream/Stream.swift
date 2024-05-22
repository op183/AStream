//
//  Stream.swift
//  AStream
//
//  Created by Ivo Vacek on 22/05/2024.
//

import Foundation
import ArgumentParser
import AudioStreaming
import AVFoundation
import Combine


@main
struct Stream: AsyncParsableCommand {
    
    @Option(name: .shortAndLong, parsing: .unconditional, help: "In range -120.0 ... 0.0 dB. The average acoustic power above which a new recording should start.")
    var recordAveragePowerThreshold: Float32 = -50.0
    
    @Option(name: .shortAndLong, parsing: .unconditional, help: "In range -120.0 ... 0.0 dB. The peak acoustic power below which the recording should stop. If not specified, the record threshold is used.")
    var silencePeakHoldLevel: Float32?
    //let helper = Helper()
    
    @Option(name: .shortAndLong, help: "Path where to store audio recording. If not provided, the stream will record audio in the current directory.")
    var outputDirectory: String?
    
    @Flag(name: .shortAndLong, help: "mute audible output (silent recording mode)")
    var muteAudioOutput: Int
    
    @Argument(help: "URL of streaming audio")
    var url: String
    
}


@propertyWrapper
public struct SynchronizedLock<Value> {
    private var value: Value
    private var lock = NSLock()
    
    public var wrappedValue: Value {
        get { lock.synchronized { value } }
        set { lock.synchronized { value = newValue } }
    }
    
    public init(wrappedValue value: Value) {
        self.value = value
    }
}

private extension NSLock {
    
    @discardableResult
    func synchronized<T>(_ block: () -> T) -> T {
        lock()
        defer { unlock() }
        return block()
    }
}


class VOXRecorder {
    
    let recordAveragePowerThreshold: Float32
    let silencePeakHoldLevel: Float32
    var userDir: String
    var format: AVAudioFormat
    
    @SynchronizedLock var flag = false
    @SynchronizedLock var audioFile: AVAudioFile?
    
    let player = AudioPlayer()
    let mixer = AVAudioMixerNode()
    
    init(recordAveragePowerThreshold: Float32, silencePeakHoldLevel: Float32, userDir: String?) throws {
        self.recordAveragePowerThreshold = recordAveragePowerThreshold
        self.silencePeakHoldLevel = silencePeakHoldLevel
        
        // create user dir if not exist
        if let ud = userDir {
            try FileManager.default.createDirectory(atPath: "\(ud)", withIntermediateDirectories: true)
            self.userDir = "\(ud)"
        } else {
            self.userDir = "./"
        }
        
        // get format and set metering mode on engines input
        format = player.mainMixerNode.outputFormat(forBus: 0)
        setMeteringEnabled(enabled: true)
        // attach mixer and install vox recording tap on it
        player.attach(node: mixer)
        mixer.installTap(onBus: 0, bufferSize: 4096, format: nil) {[weak self] buffer, time in
            guard let self = self else {
                return
            }
            Task {
                let (l,p) = self.updateMeters()
                let v = l > self.recordAveragePowerThreshold
                if !self.flag && v { // flag == false and rms > treshold
                    self.flag.toggle()
                    self.record()
                }
                if self.flag && p < self.silencePeakHoldLevel { // flag == true and peak level < threshold
                    self.flag.toggle()
                    self.stopRecord()
                }
            }
            try? self.audioFile?.write(from: buffer)
        }
        
    }
    
    func setMeteringEnabled(enabled: Bool) {
        var on1: UInt32 = (enabled) ? 1 : 0
        let node = unsafeBitCast(player.mainMixerNode, to: AVAudioIONode.self)
        if let unit = node.audioUnit {
            AudioUnitSetProperty(unit, kAudioUnitProperty_MeteringMode, kAudioUnitScope_Input, 0, &on1, UInt32(MemoryLayout.size(ofValue: on1)))
        }
    }
    
    func updateMeters()->(AudioUnitParameterValue, AudioUnitParameterValue) {
        var levelL: AudioUnitParameterValue = -160
        var levelR: AudioUnitParameterValue = -160
        var peakL: AudioUnitParameterValue = -160
        var peakR: AudioUnitParameterValue = -160
        let node = unsafeBitCast(player.mainMixerNode, to: AVAudioIONode.self)
        if let unit = node.audioUnit {
            AudioUnitGetParameter(unit, kMultiChannelMixerParam_PreAveragePower + 0, kAudioUnitScope_Input, 0, &levelL)
            AudioUnitGetParameter(unit, kMultiChannelMixerParam_PreAveragePower + 1, kAudioUnitScope_Input, 0, &levelR)
            AudioUnitGetParameter(unit, kMultiChannelMixerParam_PrePeakHoldLevel + 0, kAudioUnitScope_Input, 0, &peakL)
            AudioUnitGetParameter(unit, kMultiChannelMixerParam_PrePeakHoldLevel + 1, kAudioUnitScope_Input, 0, &peakR)
        }
        return (max(levelL, levelR), max(peakL, peakR))
    }
    
    func play(url: String) async throws {
        guard let url = URL(string: url) else {
            throw URLError(.badURL)
        }
        
        if url.scheme?.lowercased() != "http" && url.scheme?.lowercased() != "https"{
            print(url)
            let _url = URL(fileURLWithPath: url.absoluteString)
            //print(_url)
            player.play(url: _url)
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: req)
        struct HTTPError: Error, CustomStringConvertible {
            var description: String
            var status: Int
            init(status: Int, req: URLRequest) {
                self.status = status
                self.description = "\(status) \(req) \(HTTPURLResponse.localizedString(forStatusCode: status))"
            }
        }
        let resp = response as! HTTPURLResponse
        let status = resp.statusCode
        guard (200...299).contains(status) else {
            throw HTTPError(status: status, req: req)
        }
        
        req.httpMethod = "GET"
        if(url.lastPathComponent.hasSuffix(".pls")) {
            print(".pls req")
            let (data, _) = try await URLSession.shared.data(for: req)
            if let sarr = String(data: data, encoding: .utf8)?.split(whereSeparator: { c in
                c.isNewline
            }).filter({ txt in
                txt.hasPrefix("File")
            }).compactMap({ surl in
                surl.split(whereSeparator: { c in
                    c == Character("=")
                }).last
            }) {
                guard !sarr.isEmpty else {
                    throw URLError(.badURL)
                }
                for surl in sarr {
                    if let url = URL(string: String(surl)) {
                        print(url)
                        player.queue(url: url)
                    }
                }
                player.playNextInQueue()
                return
            }
        } else {
            player.play(url: url)
        }
    }
    
    func stop() {
        player.stop(clearQueue: true)
    }
    
    func record() {
        //format = player.mainMixerNode.outputFormat(forBus: 0)
        
        let settings = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount
        ] as [String : Any]
        
        let formater = DateFormatter()
        formater.timeZone = TimeZone(identifier: "UTC")
        formater.dateFormat = "yy_MM_dd_HH-mm-ss.SSZ"
        let fileName = "\(formater.string(from: Date())).m4a"
        print("\(fileName)")
        let outputUrl = URL(fileURLWithPath: "\(userDir)/\(fileName)")
        //
        // thread safe, will open the file and start recording
        do {
            audioFile = try AVAudioFile(
                forWriting: outputUrl,
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved)
        } catch {
            print("Unable to create audio file with error \(error)")
        }
    }
    
    func stopRecord() {
        // thread safe, will stop recording and close the file
        audioFile = nil
    }
    
    deinit {
        stop()
        stopRecord()
        mixer.removeTap(onBus: 0)
        player.frameFiltering.removeAll()
        player.detachCustomAttachedNodes()
        print("Bye-Bye ...")
    }
}


extension Stream {
    // see https://viewsourcecode.org/snaptoken/kilo/02.enteringRawMode.html
    func enableRawMode(fileHandle: FileHandle) -> termios {
        var raw = termios()
        tcgetattr(fileHandle.fileDescriptor, &raw)
        let original = raw
        raw.c_lflag &= ~(UInt(ECHO | ICANON))
        tcsetattr(fileHandle.fileDescriptor, TCSAFLUSH, &raw);
        return original
    }
    
    func restoreRawMode(fileHandle: FileHandle, originalTerm: termios) {
        var term = originalTerm
        tcsetattr(fileHandle.fileDescriptor, TCSAFLUSH, &term);
    }
    
    mutating func run() async throws {
        
        let stdIn = FileHandle.standardInput
        var char: UInt8 = 0
        let term = enableRawMode(fileHandle: stdIn)
        defer {
            restoreRawMode(fileHandle: stdIn, originalTerm: term)
        }
        
        print("Wellcome \(NSFullUserName())")
        let rd = outputDirectory ?? FileManager.default.currentDirectoryPath.description
        print("Recording directory   : \(rd)")
        //print("Recording directory  : /Users/\(NSUserName())/rtf")
        print("Record threshold     : \(recordAveragePowerThreshold) dB")
        print("Stop record threshold: \(silencePeakHoldLevel ?? recordAveragePowerThreshold) dB")
        print("Silent recording     : \(muteAudioOutput == 0 ? "OFF" : "ON")\n")
        print("Press <Ctrl-D> to exit, <M> to toggle silent recording\n")
        
        // create recorder
        let voxRecorder = try VOXRecorder(recordAveragePowerThreshold: recordAveragePowerThreshold, silencePeakHoldLevel: silencePeakHoldLevel ?? recordAveragePowerThreshold, userDir: outputDirectory)
       
        voxRecorder.player.volume = Float(muteAudioOutput == 0 ? 1 : 0)
        try await voxRecorder.play(url: url)
        
        while read(stdIn.fileDescriptor, &char, 1) == 1 {
            if char == 0x04 { // detect EOF (Ctrl+D)
                break
            }
            if char == 109 { // <M>
                muteAudioOutput =  muteAudioOutput == 0 ? 1 : 0
                voxRecorder.player.volume = Float(muteAudioOutput == 0 ? 1 : 0)
                print("Silent recording     : \(muteAudioOutput == 0 ? "OFF" : "ON")\n")
            }
            // don't echo stdin, just ignore the rest
        }
        
    }
    
}

