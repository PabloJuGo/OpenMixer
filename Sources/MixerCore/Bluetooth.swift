import Foundation
import IOBluetooth

public struct BluetoothAudioDevice: Identifiable, Equatable {
    public var id: String { address }
    public let name: String
    public let address: String
    public let connected: Bool
}

/// Paired Bluetooth audio devices and connect/disconnect, so headphones can be managed from the mixer.
public enum Bluetooth {
    private static func paired() -> [IOBluetoothDevice] { (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [] }

    public static func audioDevices() -> [BluetoothAudioDevice] {
        paired().filter { $0.deviceClassMajor == UInt32(kBluetoothDeviceClassMajorAudio) }
            .map { BluetoothAudioDevice(name: $0.nameOrAddress ?? "Unknown", address: $0.addressString ?? "", connected: $0.isConnected()) }
    }

    /// Runs on a background queue because IOBluetooth connection calls block.
    public static func setConnected(_ address: String, _ connect: Bool, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let d = paired().first(where: { $0.addressString == address }) else { return DispatchQueue.main.async { completion(false) } }
            let ok = connect ? d.openConnection() == kIOReturnSuccess : d.closeConnection() == kIOReturnSuccess
            DispatchQueue.main.async { completion(ok) }
        }
    }
}
