/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
A fixed-size binary packet representing spatial controller state for two hands,
designed for transmission over a FoveatedStreaming message channel.

Binary layout (100 bytes, little-endian, C-compatible):

  Offset  Size  Type     Field
  ------  ----  ------   -----
  0       2     UInt16   magic = 0x5343 ("SC")
  2       1     UInt8    version = 1
  3       1     UInt8    activeHands (bit 0 = left, bit 1 = right)

  --- Left Hand (48 bytes) ---
  4       2     UInt16   buttons (bitmask)
  6       2     UInt16   reserved
  8       4     Float32  thumbstickX  [-1, 1]
  12      4     Float32  thumbstickY  [-1, 1]
  16      4     Float32  trigger      [0, 1]
  20      4     Float32  grip         [0, 1]
  24      4     Float32  positionX
  28      4     Float32  positionY
  32      4     Float32  positionZ
  36      4     Float32  rotationX    (quaternion)
  40      4     Float32  rotationY
  44      4     Float32  rotationZ
  48      4     Float32  rotationW

  --- Right Hand (48 bytes, same layout at offset 52) ---

  Total: 100 bytes

Button bitmask (per hand):
  Bit 0:  buttonA          (Right: Circle,   Left: Triangle)
  Bit 1:  buttonB          (Right: Cross,    Left: Square)
  Bit 2:  trigger          (digital)
  Bit 3:  grip             (digital)
  Bit 4:  thumbstickClick
  Bit 5:  menu
  Bit 6:  touchButtonA     (capacitive)
  Bit 7:  touchButtonB     (capacitive)
  Bit 8:  touchTrigger     (capacitive)
  Bit 9:  touchGrip        (capacitive)
  Bit 10: touchThumbstick  (capacitive)

C/C++ reference struct for the PC-side parser:

  #pragma pack(push, 1)
  typedef struct {
      uint16_t buttons;
      uint16_t reserved;
      float thumbstickX, thumbstickY;
      float trigger, grip;
      float posX, posY, posZ;
      float rotX, rotY, rotZ, rotW;
  } SpatialControllerHand;   // 48 bytes

  typedef struct {
      uint16_t magic;         // 0x5343
      uint8_t  version;       // 1
      uint8_t  activeHands;   // bitmask
      SpatialControllerHand left;
      SpatialControllerHand right;
  } SpatialControllerPacket;  // 100 bytes
  #pragma pack(pop)
*/

import Foundation

// MARK: - Haptic Event Packet (server → client)

/*
Binary layout (20 bytes, little-endian, packed):

  Offset  Size  Type     Field
  ------  ----  ------   -----
  0       2     UInt16   magic = 0x4856 ("HV")
  2       1     UInt8    version = 1
  3       1     UInt8    hand (0 = left, 1 = right)
  4       8     UInt64   durationNs (nanoseconds, 0 = minimum)
  12      4     Float32  frequency  (Hz, 0 = default)
  16      4     Float32  amplitude  (0.0–1.0)

  Total: 20 bytes

C/C++ reference struct:

  #pragma pack(push, 1)
  typedef struct {
      uint16_t magic;         // 0x4856
      uint8_t  version;       // 1
      uint8_t  hand;          // 0 = left, 1 = right
      uint64_t duration_ns;   // nanoseconds
      float    frequency;     // Hz
      float    amplitude;     // 0.0–1.0
  } HapticEventPacket;        // 20 bytes
  #pragma pack(pop)
*/

struct HapticEventPacket {
    static let magic: UInt16 = 0x4856 // "HV"
    static let version: UInt8 = 1
    static let packetSize = 20

    var hand: UInt8 = 0        // 0 = left, 1 = right
    var durationNs: UInt64 = 0
    var frequency: Float = 0
    var amplitude: Float = 0

    var isLeft: Bool { hand == 0 }

    var durationSeconds: Double {
        durationNs == 0 ? 0.032 : Double(durationNs) / 1_000_000_000.0
    }

    static func deserialize(from data: Data) -> HapticEventPacket? {
        guard data.count >= packetSize else { return nil }
        func readInteger<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
            var value: T = 0
            _ = withUnsafeMutableBytes(of: &value) { rawBuffer in
                data.copyBytes(to: rawBuffer, from: offset..<(offset + MemoryLayout<T>.size))
            }
            return T(littleEndian: value)
        }

        let magic = readInteger(UInt16.self, at: 0)
        let version = data[2]
        guard magic == Self.magic, version == Self.version else { return nil }

        var packet = HapticEventPacket()
        packet.hand = data[3]
        packet.durationNs = readInteger(UInt64.self, at: 4)
        packet.frequency = Float(bitPattern: readInteger(UInt32.self, at: 12))
        packet.amplitude = Float(bitPattern: readInteger(UInt32.self, at: 16))
        return packet
    }
}

// MARK: - Controller Input Packet (client → server)

struct SpatialControllerPacket {
    static let magic: UInt16 = 0x5343 // "SC"
    static let version: UInt8 = 1
    static let packetSize = 100

    struct ActiveHands {
        static let left:  UInt8 = 1 << 0
        static let right: UInt8 = 1 << 1
    }

    struct ButtonMask {
        static let buttonA:         UInt16 = 1 << 0
        static let buttonB:         UInt16 = 1 << 1
        static let trigger:         UInt16 = 1 << 2
        static let grip:            UInt16 = 1 << 3
        static let thumbstickClick: UInt16 = 1 << 4
        static let menu:            UInt16 = 1 << 5
        // Capacitive touch
        static let touchButtonA:    UInt16 = 1 << 6
        static let touchButtonB:    UInt16 = 1 << 7
        static let touchTrigger:    UInt16 = 1 << 8
        static let touchGrip:       UInt16 = 1 << 9
        static let touchThumbstick: UInt16 = 1 << 10
    }

    struct HandState {
        var buttons: UInt16 = 0
        var thumbstickX: Float = 0
        var thumbstickY: Float = 0
        var trigger: Float = 0
        var grip: Float = 0
        var positionX: Float = 0
        var positionY: Float = 0
        var positionZ: Float = 0
        var rotationX: Float = 0
        var rotationY: Float = 0
        var rotationZ: Float = 0
        var rotationW: Float = 1 // identity quaternion

        func serialize(into data: inout Data) {
            withUnsafeBytes(of: buttons.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt16(0).littleEndian) { data.append(contentsOf: $0) } // reserved
            withUnsafeBytes(of: thumbstickX.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: thumbstickY.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: trigger.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: grip.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: positionX.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: positionY.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: positionZ.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: rotationX.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: rotationY.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: rotationZ.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: rotationW.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
    }

    var activeHands: UInt8 = 0
    var left = HandState()
    var right = HandState()

    func serialize() -> Data {
        var data = Data(capacity: Self.packetSize)
        withUnsafeBytes(of: Self.magic.littleEndian) { data.append(contentsOf: $0) }
        data.append(Self.version)
        data.append(activeHands)
        left.serialize(into: &data)
        right.serialize(into: &data)
        return data
    }
}
