import Foundation

public enum LocalVoiceModel {
    public static func validName(_ name: String) -> Bool {
        !name.hasPrefix(".") && name.hasSuffix(".onnx") &&
        name.utf8.count <= 200 && name.count > 5 &&
        !name.contains("/") && !name.contains("\\") &&
        !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    public static func validPair(_ model: URL) -> Bool {
        guard model.isFileURL, validName(model.lastPathComponent) else { return false }
        let config = URL(fileURLWithPath:model.path+".json")
        guard regularFile(model, maxBytes: 512*1024*1024),
              regularFile(config,maxBytes:1024*1024),
              let data = try? Data(contentsOf:config),
              let object = try? JSONSerialization.jsonObject(with:data),
              let json = object as? [String:Any],
              let audio = json["audio"] as? [String:Any],
              let rate = audio["sample_rate"] as? Double,
              rate.isFinite, (8000...96000).contains(rate) else { return false }
        return true
    }

    private static func regularFile(_ url:URL,maxBytes:Int) -> Bool {
        guard let info = try? url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]),
              info.isRegularFile == true, info.isSymbolicLink != true,
              let size = info.fileSize, size > 0, size <= maxBytes else { return false }
        return true
    }
}
