import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
        // URL resource values may cache metadata on macOS. Inspect the
        // current directory entry without following a final symlink.
        #if canImport(Darwin) || canImport(Glibc)
        var info = stat()
        let result = url.path.withCString { lstat($0,&info) }
        return result == 0 && (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) &&
            info.st_size > 0 && info.st_size <= Int64(maxBytes)
        #else
        guard let info = try? FileManager.default.attributesOfItem(atPath:url.path),
              info[.type] as? FileAttributeType == .typeRegular,
              let size = info[.size] as? NSNumber else { return false }
        return size.int64Value > 0 && size.int64Value <= Int64(maxBytes)
        #endif
    }
}
