import Foundation

enum HostLaunchOptions {
    static func query(settings: StreamSettings) -> String {
        // Prefer the saved snapshot carried in settings, avoiding a global mutable mask.
        var query = "&remoteControllersBitmap=\(settings.controllerMask)&gcmap=\(settings.controllerMask)&gcpersist=\(settings.features.persistentGamepad ? 1 : 0)"
        if settings.enableHdr {
            query += "&hdrMode=1&clientHdrCapVersion=0&clientHdrCapSupportedFlagsInUint32=0&clientHdrCapMetaDataId=NV_STATIC_METADATA_TYPE_1&clientHdrCapDisplayData=0x0x0x0x0x0x0x0x0x0x0"
        }
        return query
    }
}
