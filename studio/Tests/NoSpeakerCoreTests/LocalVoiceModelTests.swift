import Foundation
import Testing
@testable import NoSpeakerCore

@Test func localVoiceNamesRejectTraversalAndInvalidNames() {
    for name in ["../voice.onnx",".hidden.onnx","x/y.onnx","x\\y.onnx","x\n.onnx",".onnx","voice.txt",String(repeating:"a",count:201)+".onnx"] {
        #expect(!LocalVoiceModel.validName(name))
    }
    #expect(LocalVoiceModel.validName("tr_TR-test.onnx"))
}

@Test func localVoiceModelRequiresMatchingRegularFilesAndValidAudioConfiguration() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at:dir,withIntermediateDirectories:false)
    defer { try? fm.removeItem(at:dir) }
    let model = dir.appendingPathComponent("tr_TR-test.onnx")
    let config = URL(fileURLWithPath:model.path+".json")
    #expect(!LocalVoiceModel.validPair(model))
    try Data([1,2,3]).write(to:model)
    #expect(!LocalVoiceModel.validPair(model))
    for invalid in ["{}","not-json","{\"audio\":{\"sample_rate\":1}}","{\"audio\":{\"sample_rate\":true}}","{\"audio\":{\"sample_rate\":100000}}"] {
        try Data(invalid.utf8).write(to:config)
        #expect(!LocalVoiceModel.validPair(model))
    }
    let valid = Data("{\"audio\":{\"sample_rate\":22050}}".utf8)
    try valid.write(to:config)
    #expect(LocalVoiceModel.validPair(model))
    try Data().write(to:model)
    #expect(!LocalVoiceModel.validPair(model))
    try Data([1]).write(to:model)
    try fm.removeItem(at:config)
    let other = dir.appendingPathComponent("other.json")
    try valid.write(to:other)
    try fm.createSymbolicLink(at:config,withDestinationURL:other)
    #expect(!LocalVoiceModel.validPair(model))
    try fm.removeItem(at:config)
    try valid.write(to:config)
    try fm.removeItem(at:model)
    try fm.createSymbolicLink(at:model,withDestinationURL:other)
    #expect(!LocalVoiceModel.validPair(model))
}
