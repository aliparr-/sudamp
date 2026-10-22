import AVFoundation
nonisolated(unsafe) var calls = 0
nonisolated func make() -> AVAudioEngine {
    let engine = AVAudioEngine()
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let src = AVAudioSourceNode(format: fmt) { _, _, _, abl in
        let b = UnsafeMutableAudioBufferListPointer(abl)
        for x in b { memset(x.mData, 0, Int(x.mDataByteSize)) }
        calls += 1
        return noErr
    }
    engine.attach(src); engine.connect(src, to: engine.mainMixerNode, format: fmt)
    engine.mainMixerNode.outputVolume = 0
    try! engine.start()
    return engine
}
let e = make()
Thread.sleep(forTimeInterval: 1.5)
print("survived, render calls:", calls)
e.stop()
