/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Mixed Reality Capture — RealityMixerVisionPro inlined into one TU
 * (avoids CMake/pbxproj regenerate). TCP :13370.
 */

import ARKit
import Foundation
import Metal
import OSLog
import RealityKit
import simd
import VideoToolbox
import QuartzCore
import Darwin

#if os(visionOS)

let logger = Logger(subsystem: "MixedRealityCapture", category: "general")


// ---- SwiftSocket/Socket.swift ----
//
//  Copyright (c) <2014>, skysent
//  All rights reserved.
//
//  Redistribution and use in source and binary forms, with or without
//  modification, are permitted provided that the following conditions are met:
//  1. Redistributions of source code must retain the above copyright
//  notice, this list of conditions and the following disclaimer.
//  2. Redistributions in binary form must reproduce the above copyright
//  notice, this list of conditions and the following disclaimer in the
//  documentation and/or other materials provided with the distribution.
//  3. All advertising materials mentioning features or use of this software
//  must display the following acknowledgement:
//  This product includes software developed by skysent.
//  4. Neither the name of the skysent nor the
//  names of its contributors may be used to endorse or promote products
//  derived from this software without specific prior written permission.
//
//  THIS SOFTWARE IS PROVIDED BY skysent ''AS IS'' AND ANY
//  EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
//  WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
//  DISCLAIMED. IN NO EVENT SHALL skysent BE LIABLE FOR ANY
//  DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
//  (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
//  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
//  ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
//  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
//  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//


public typealias Byte = UInt8

open class Socket {
  
    public let address: String
    internal(set) public var port: Int32
    public var fd: Int32?
  
    public init(address: String, port: Int32) {
        self.address = address
        self.port = port
    }
  
}

public enum SocketError: Error {
    case queryFailed
    case connectionClosed
    case connectionTimeout
    case unknownError
}

// ---- SwiftSocket/Result.swift ----

public enum Result {
  case success
  case failure(Error)
  
  public var isSuccess: Bool {
    switch self {
    case .success:
      return true
    case .failure:
      return false
    }
  }
    
  public var isFailure: Bool {
    return !isSuccess
  }
 
  public var error: Error? {
    switch self {
    case .success:
      return nil
    case .failure(let error):
      return error
    }
  }
}

// ---- SwiftSocket/TCPClient.swift ----
//
//  Copyright (c) <2014>, skysent
//  All rights reserved.
//
//  Redistribution and use in source and binary forms, with or without
//  modification, are permitted provided that the following conditions are met:
//  1. Redistributions of source code must retain the above copyright
//  notice, this list of conditions and the following disclaimer.
//  2. Redistributions in binary form must reproduce the above copyright
//  notice, this list of conditions and the following disclaimer in the
//  documentation and/or other materials provided with the distribution.
//  3. All advertising materials mentioning features or use of this software
//  must display the following acknowledgement:
//  This product includes software developed by skysent.
//  4. Neither the name of the skysent nor the
//  names of its contributors may be used to endorse or promote products
//  derived from this software without specific prior written permission.
//
//  THIS SOFTWARE IS PROVIDED BY skysent ''AS IS'' AND ANY
//  EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
//  WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
//  DISCLAIMED. IN NO EVENT SHALL skysent BE LIABLE FOR ANY
//  DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
//  (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
//  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
//  ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
//  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
//  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//


@_silgen_name("ytcpsocket_connect") private func c_ytcpsocket_connect(_ host:UnsafePointer<Byte>,port:Int32,timeout:Int32) -> Int32
@_silgen_name("ytcpsocket_close") private func c_ytcpsocket_close(_ fd:Int32) -> Int32
@_silgen_name("ytcpsocket_bytes_available") private func c_ytcpsocket_bytes_available(_ fd:Int32) -> Int32
@_silgen_name("ytcpsocket_send") private func c_ytcpsocket_send(_ fd:Int32,buff:UnsafePointer<Byte>,len:Int32) -> Int32
@_silgen_name("ytcpsocket_pull") private func c_ytcpsocket_pull(_ fd:Int32,buff:UnsafePointer<Byte>,len:Int32,timeout:Int32) -> Int32
@_silgen_name("ytcpsocket_listen") private func c_ytcpsocket_listen(_ address:UnsafePointer<Int8>,port:Int32)->Int32
@_silgen_name("ytcpsocket_accept") private func c_ytcpsocket_accept(_ onsocketfd:Int32,ip:UnsafePointer<Int8>,port:UnsafePointer<Int32>,timeout:Int32) -> Int32
@_silgen_name("ytcpsocket_port") private func c_ytcpsocket_port(_ fd:Int32) -> Int32

open class TCPClient: Socket {
    /*
     * connect to server
     * return success or fail with message
     */
    open func connect(timeout: Int) -> Result {
        let rs: Int32 = c_ytcpsocket_connect(self.address, port: Int32(self.port), timeout: Int32(timeout))
        if rs > 0 {
            self.fd = rs
            return .success
        } else {
            switch rs {
            case -1:
                return .failure(SocketError.queryFailed)
            case -2:
                return .failure(SocketError.connectionClosed)
            case -3:
                return .failure(SocketError.connectionTimeout)
            default:
                return .failure(SocketError.unknownError)
            }
        }
    }

    /*
    * close socket
    * return success or fail with message
    */
    open func close() {
        guard let fd = self.fd else { return }
        
        _ = c_ytcpsocket_close(fd)
        self.fd = nil
    }
    
    /*
    * send data
    * return success or fail with message
    */
    open func send(data: [Byte]) -> Result {
        guard let fd = self.fd else { return .failure(SocketError.connectionClosed) }
        
        let sendsize: Int32 = c_ytcpsocket_send(fd, buff: data, len: Int32(data.count))
        if Int(sendsize) == data.count {
           return .success
        } else {
            return .failure(SocketError.unknownError)
        }
    }
    
    /*
    * send string
    * return success or fail with message
    */
    open func send(string: String) -> Result {
        guard let fd = self.fd else { return .failure(SocketError.connectionClosed) }
      
        let sendsize = c_ytcpsocket_send(fd, buff: string, len: Int32(strlen(string)))
        if sendsize == Int32(strlen(string)) {
            return .success
        } else {
            return .failure(SocketError.unknownError)
        }
    }
    
    /*
    *
    * send nsdata
    */
    open func send(data: Data) -> Result {
        guard let fd = self.fd else { return .failure(SocketError.connectionClosed) }
      
        var buff = [Byte](repeating: 0x0,count: data.count)
        (data as NSData).getBytes(&buff, length: data.count)
        let sendsize = c_ytcpsocket_send(fd, buff: buff, len: Int32(data.count))
        if sendsize == Int32(data.count) {
            return .success
        } else {
            return .failure(SocketError.unknownError)
        }
    }
    
    /*
    * read data with expect length
    * return success or fail with message
    */
    open func read(_ expectlen:Int, timeout:Int = -1) -> [Byte]? {
        guard let fd:Int32 = self.fd else { return nil }
      
        var buff = [Byte](repeating: 0x0,count: expectlen)
        let readLen = c_ytcpsocket_pull(fd, buff: &buff, len: Int32(expectlen), timeout: Int32(timeout))
        if readLen <= 0 { return nil }
        let rs = buff[0...Int(readLen-1)]
        let data: [Byte] = Array(rs)
      
        return data
    }

    /*
    * gets byte available for reading
    */
    open func bytesAvailable() -> Int32? {
        guard let fd:Int32 = self.fd else { return nil }

        let bytesAvailable = c_ytcpsocket_bytes_available(fd);

        if (bytesAvailable < 0) {
            return nil
        }

        return bytesAvailable
    }
}

open class TCPServer: Socket {

    open func listen() -> Result {
        let fd = c_ytcpsocket_listen(self.address, port: Int32(self.port))
        if fd > 0 {
            self.fd = fd
            
            // If port 0 is used, get the actual port number which the server is listening to
            if (self.port == 0) {
                let p = c_ytcpsocket_port(fd)
                if (p == -1) {
                    return .failure(SocketError.unknownError)
                } else {
                    self.port = p
                }
            }
            
            return .success
        } else {
            return .failure(SocketError.unknownError)
        }
    }
    
    open func accept(timeout :Int32 = 0) -> TCPClient? {
        guard let serferfd = self.fd else { return nil }
        
        var buff: [Int8] = [Int8](repeating: 0x0,count: 16)
        var port: Int32 = 0
        let clientfd: Int32 = c_ytcpsocket_accept(serferfd, ip: &buff, port: &port, timeout: timeout)
        
        guard clientfd >= 0 else { return nil }
        guard let address = String(cString: buff, encoding: String.Encoding.utf8) else { return nil }
        
        let client = TCPClient(address: address, port: port)
        client.fd = clientfd
            
        return client
    }
    
    open func close() {
        guard let fd: Int32=self.fd else { return }
      
        _ = c_ytcpsocket_close(fd)
        self.fd = nil
    }
}

// ---- Protocol.swift ----
//
//  Protocol.swift
//  RealityMixerExample
//
//


enum MRCProtocol {
    static let protocolIdentifier: UInt32 = 13371337
}

enum PayloadType: UInt32, RawRepresentable {
    case cameraUpdate = 1
    case buttonPress = 2
    case videoData = 11
}

// ---- Math.swift ----
//
//  Math.swift
//  RealityMixerExample
//
//


public typealias Vector3 = simd_float3

public extension Vector3 {

    var magnitudeSquared: Float {
        x*x + y*y + z*z
    }

    var norm: Float {
        sqrtf(magnitudeSquared)
    }

    var normalized: Vector3 {
        normalize(self)
    }

    func cross(_ other: Vector3) -> Vector3 {
        simd.cross(self, other)
    }

    func dot(_ other: Vector3) -> Float {
        simd.dot(self, other)
    }

    static func * (_ lhs: Vector3, _ rhs: Float) -> Vector3 {
        .init(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs)
    }
}

public typealias Vector4 = simd_float4

public extension Vector4 {

    var xyz: Vector3 {
        .init(x: x, y: y, z: z)
    }
}

public typealias Quaternion = simd_quatf

public extension Quaternion {

    var x: Float { vector.x }
    var y: Float { vector.y }
    var z: Float { vector.z }
    var w: Float { vector.w }

    var eulerAngles: Vector3 {
        let sinr_cosp = 2.0 * (w * x + y * z)
        let cosr_cosp = 1.0 - 2.0 * (x * x + y * y)
        let roll = atan2(sinr_cosp, cosr_cosp)

        let sinp = 2.0 * (w * y - z * x)
        let pitch = abs(sinp) >= 1.0 ? copysign(.pi/2.0, sinp):asin(sinp)

        let siny_cosp = 2.0 * (w * z + x * y)
        let cosy_cosp = 1.0 - 2.0 * (y * y + z * z)
        let yaw = atan2(siny_cosp, cosy_cosp)

        return Vector3(x: roll, y: pitch, z: yaw)
    }

    static func * (_ lhs: Quaternion, _ rhs: Vector3) -> Vector3 {
        let num = lhs.x * 2.0
        let num2 = lhs.y * 2.0
        let num3 = lhs.z * 2.0
        let num4 = lhs.x * num
        let num5 = lhs.y * num2
        let num6 = lhs.z * num3
        let num7 = lhs.x * num2
        let num8 = lhs.x * num3
        let num9 = lhs.y * num3
        let num10 = lhs.w * num
        let num11 = lhs.w * num2
        let num12 = lhs.w * num3

        return .init(
            x: (1.0 - (num5 + num6)) * rhs.x + (num7 - num12) * rhs.y + (num8 + num11) * rhs.z,
            y: (num7 + num12) * rhs.x + (1.0 - (num4 + num6)) * rhs.y + (num9 - num10) * rhs.z,
            z: (num8 - num11) * rhs.x + (num9 + num10) * rhs.y + (1.0 - (num4 + num5)) * rhs.z
        )
    }

    init(rotationMatrix m: simd_float4x4) {
        self = simd_quatf(m)
    }

    init(x: Float, y: Float, z: Float, w: Float) {
        self.init(vector: .init(x: x, y: y, z: z, w: w))
    }

    static let identity = Quaternion(x: 0, y: 0, z: 0, w: 1)
}

public struct Pose {
    public let position: Vector3
    public let rotation: Quaternion

    public var inverse: Pose {
        let inverseRotation = rotation.inverse

        return .init(
            position: inverseRotation * (-1.0 * position),
            rotation: inverseRotation
        )
    }

    public static func * (_ lhs: Pose, _ rhs: Pose) -> Pose {
        .init(
            position: lhs.position + (lhs.rotation * rhs.position),
            rotation: lhs.rotation * rhs.rotation
        )
    }

    public static let identity = Pose(position: .zero, rotation: .identity)

    public init(position: Vector3, rotation: Quaternion) {
        self.position = position
        self.rotation = rotation
    }

    public init(_ m: simd_float4x4) {
        let position = simd_make_float3(m.columns.3)
        self.position = Vector3(position.x, position.y, position.z)
        self.rotation = Quaternion(rotationMatrix: m)
    }
}

extension simd_float4x4 {

    var forwardVector: Vector3 {
        Vector3(columns.2.x, columns.2.y, columns.2.z).normalized
    }

//    var rightVector: Vector3 {
//        Vector3(columns.0.x, columns.0.y, columns.0.z).normalized
//    }
//
//    var upVector: Vector3 {
//        Vector3(columns.1.x, columns.1.y, columns.1.z).normalized
//    }
}

// ---- CameraIntrinsic.swift ----
//
//  CameraIntrinsic.swift
//  RealityMixerExample
//
//


struct CameraIntrinsic {
    let imageSize: CGSize
    let verticalFOV: Float
}

// ---- Payloads.swift ----
//
//  Payloads.swift
//  RealityMixerExample
//
//


struct VideoDataPayload {
    // Header
    let magic = MRCProtocol.protocolIdentifier
    let payloadType: UInt32 = PayloadType.videoData.rawValue
    let payloadLength: UInt32

    var headerData: Data {
        let length = MemoryLayout<VideoDataPayload>.size
        var copy = self
        let data = Data(bytes: &copy, count: length)
        return data
    }

    static func makePayload(encodedVideoData: Data) -> Data {
        let header = Self.init(payloadLength: UInt32(encodedVideoData.count)).headerData
        return header + encodedVideoData
    }
}

// ---- ReceivedFrame.swift ----
//
//  ReceivedFrame.swift
//  RealityMixerExample
//
//


struct ReceivedFrame {
    static let protocolIdentifier: UInt32 = MRCProtocol.protocolIdentifier

    struct FrameHeader {
        let protocolIdentifier: UInt32
        let payloadType: UInt32
        let payloadLength: UInt32
    }

    let payloadType: UInt32
    let data: Data
    let length: Int

    init?(from data: Data) {
        let headerLength = MemoryLayout<FrameHeader>.size
        guard data.count >= headerLength else { return nil }

        let headerData = data.subdata(in: 0 ..< headerLength)
        let header = headerData.withUnsafeBytes({ $0.load(as: FrameHeader.self) })
        let totalLength = (headerLength + Int(header.payloadLength))

        guard header.protocolIdentifier == ReceivedFrame.protocolIdentifier else {
            // Error....
            return nil
        }

        guard data.count >= totalLength else {
            return nil
        }

        self.payloadType = header.payloadType
        self.data = data.subdata(in: headerLength ..< totalLength)
        self.length = totalLength
    }
}

final class FrameCollection {
    private let semaphore = DispatchSemaphore(value: 1)
    private var data = Data()
    private var frames: [ReceivedFrame] = []

    func add(data: Data) {
        semaphore.wait()
        self.data.append(data)

        while let frame = ReceivedFrame(from: self.data) {
            frames.append(frame)

            if self.data.count > frame.length {
                self.data = self.data.advanced(by: frame.length)
            } else {
                self.data = .init()
            }
        }
        semaphore.signal()
    }

    func next() -> ReceivedFrame? {
        semaphore.wait()
        let nextFrame = frames.isEmpty ? nil:frames.removeFirst()
        semaphore.signal()
        return nextFrame
    }
}

// ---- ReceivedPayload.swift ----
//
//  ReceivedPayload.swift
//  RealityMixerExample
//
//


enum ReceivedPayload {

    struct CameraUpdate {
        let px: Float32
        let py: Float32
        let pz: Float32
        let qx: Float32
        let qy: Float32
        let qz: Float32
        let qw: Float32

        let cameraWidth: UInt32
        let cameraHeight: UInt32
        let cameraVerticalFOV: Float32
    }

    case cameraUpdate(Pose, CGSize, _ verticalFOV: Float)
    case buttonPress(UInt8)

    init?(from frame: ReceivedFrame) {
        guard let payloadType = PayloadType(rawValue: frame.payloadType) else { return nil }

        switch payloadType {
        case .cameraUpdate:
            guard frame.data.count == MemoryLayout<CameraUpdate>.size else { return nil }
            let cameraUpdate = frame.data.withUnsafeBytes({ $0.load(as: CameraUpdate.self) })
            let pose = Pose(
                position: .init(x: cameraUpdate.px, y: cameraUpdate.py, z: cameraUpdate.pz),
                rotation: .init(x: cameraUpdate.qx, y: cameraUpdate.qy, z: cameraUpdate.qz, w: cameraUpdate.qw)
            )
            let imageSize = CGSize(
                width: Int(cameraUpdate.cameraWidth),
                height: Int(cameraUpdate.cameraHeight)
            )
            let verticalFOV = Float(cameraUpdate.cameraVerticalFOV)
            self = .cameraUpdate(pose, imageSize, verticalFOV)
        case .buttonPress:
            guard frame.data.count == MemoryLayout<UInt8>.size else { return nil }
            self = .buttonPress([UInt8](frame.data)[0])
        default:
            return nil
        }
    }
}

// ---- MixedRealityServer.swift ----
//
//  MixedRealityServer.swift
//  RealityMixerExample
//
//


protocol MixedRealityServerDelegate: AnyObject {
    func didReceiveButtonPress(_ button: UInt8)
    func didReceiveCameraUpdate(_ pose: Pose, imageSize: CGSize, verticalFOV: Float)
}

final class MixedRealityServer {
    weak var delegate: MixedRealityServerDelegate?
    private let port: Int32 = 13370

    private var server: TCPServer?
    private var client: TCPClient?

    private var serverThread: Thread?

    private var frameCollection = FrameCollection()

    func terminate() {
        /* Closing the listen fd unblocks accept(); Thread.cancel() does not. */
        let listen = server
        let connected = client
        serverThread?.cancel()
        connected?.close()
        listen?.close()
        client = nil
        server = nil
        serverThread = nil
        frameCollection = .init()
    }

    func startServer() {
        terminate()

        let server = TCPServer(address: "0.0.0.0", port: port)
        self.server = server

        let serverThread = Thread(block: { [weak self] in
            switch server.listen() {
            case .success:
                logger.log("MRC TCP listening on :13370")
                /* Re-accept after iPad disconnect / retry. One-shot accept left
                 * the port bound with no client after the first hangup. */
                while !Thread.current.isCancelled {
                    guard let client = server.accept() else { break }
                    logger.log("Accepted MRC client \(client.address)")
                    self?.client?.close()
                    self?.client = client
                    while !Thread.current.isCancelled {
                        guard let data = client.read(32, timeout: 0), data.count > 0 else {
                            break
                        }
                        self?.frameCollection.add(data: .init(data))
                    }
                    client.close()
                    if self?.client?.fd == nil || self?.client?.fd == client.fd {
                        self?.client = nil
                    }
                }
            case .failure(let error):
                logger.error("Failed to listen: \(error)")
            }
        })

        serverThread.start()
        self.serverThread = serverThread
    }

    func update() {
        while let frame = frameCollection.next() {
            if let payload = ReceivedPayload(from: frame) {
                process(payload: payload)
            } else {
                // Unknown payload type...
            }
        }
    }

    func send(data: Data) {
        _ = client?.send(data: data)
    }

    private func process(payload: ReceivedPayload) {
        switch payload {
        case .buttonPress(let button):
            delegate?.didReceiveButtonPress(button)
        case let .cameraUpdate(pose, imageSize, verticalFOV):
            delegate?.didReceiveCameraUpdate(pose, imageSize: imageSize, verticalFOV: verticalFOV)
        }
    }

    init() {
    }

    deinit {
        terminate()
    }
}

// ---- VideoEncoder.swift ----
//
//  VideoEncoder.swift
//  RealityMixerExample
//
//


final class VideoEncoder {
    let size: CGSize
    private var compressionSession: VTCompressionSession
    private var pixelBuffer: CVPixelBuffer
    private var finalized = false

    private let width: Int
    private let height: Int

    public init?(
        size: CGSize,
        frameRate: Int,
        bitRate: Int
    ) {
        self.size = size
        var session: VTCompressionSession?

        let sourceImageBufferAttributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA as CFNumber] as CFDictionary

        VTCompressionSessionCreate(
            nil,
            Int32(size.width),
            Int32(size.height),
            kCMVideoCodecType_H264,
            nil,
            sourceImageBufferAttributes,
            nil,
            nil,
            nil,
            &session
        )

        guard let session = session else {
            return nil
        }

        var err: OSStatus = noErr

        err = VTSessionSetProperty(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel)

        if err != noErr {
            logger.warning("VTSessionSetProperty(kVTCompressionPropertyKey_ProfileLevel) failed (\(err))")
        }

        err = VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        if noErr != err {
            logger.warning("VTSessionSetProperty(kVTCompressionPropertyKey_RealTime) failed (\(err))")
        }

        err = VTSessionSetProperty(session, kVTCompressionPropertyKey_AverageBitRate, bitRate as CFNumber)
        if noErr != err {
            logger.warning("VTSessionSetProperty(kVTCompressionPropertyKey_AverageBitRate) failed (\(err))")
        }

        let byteLimit = (Double(bitRate) / 8 * 1.5) as CFNumber
        let secLimit = Double(1.0) as CFNumber
        let limitsArray = [ byteLimit, secLimit ] as CFArray
        err = VTSessionSetProperty(session, kVTCompressionPropertyKey_DataRateLimits, limitsArray)
        if noErr != err {
            logger.warning("Warning: VTSessionSetProperty(kVTCompressionPropertyKey_DataRateLimits) failed (\(err))")
        }

        var pixelBuffer: CVPixelBuffer?
        let pixelFormat = kCVPixelFormatType_32BGRA

        self.width = Int(size.width)
        self.height = Int(size.height)

        let attributes: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat
        ]

        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attributes as CFDictionary,
            &pixelBuffer
        )

        guard let pixelBuffer else {
            return nil
        }

        self.compressionSession = session
        self.pixelBuffer = pixelBuffer
    }

    func didEncodeFrame(frame: CMSampleBuffer) -> Data {

        //----AVCC to Elem stream-----//
        let elementaryStream = NSMutableData()

        //1. check if CMBuffer had I-frame
        var isIFrame:Bool = false
        let attachmentsArray:CFArray = CMSampleBufferGetSampleAttachmentsArray(frame, false)!
        //check how many attachments
        if ( CFArrayGetCount(attachmentsArray) > 0 ) {
            let dict = CFArrayGetValueAtIndex(attachmentsArray, 0)
            let dictRef: CFDictionary = unsafeBitCast(dict, to: CFDictionary.self)
            //get value
            let value = CFDictionaryGetValue(dictRef, unsafeBitCast(kCMSampleAttachmentKey_NotSync, to: UnsafeRawPointer.self))
            if ( value != nil ){
                //print("IFrame found...")
                isIFrame = true
            }
        }

        //2. define the start code
        let nStartCodeLength:size_t = 4
        let nStartCode:[UInt8] = [0x00, 0x00, 0x00, 0x01]

        //3. write the SPS and PPS before I-frame
        if ( isIFrame == true ){
            let description: CMFormatDescription = CMSampleBufferGetFormatDescription(frame)!
            //how many params
            var numParams: size_t = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, 0, nil, nil, &numParams, nil)

            //write each param-set to elementary stream
            for i in 0..<numParams {
                var parameterSetPointer: UnsafePointer<UInt8>?
                var parameterSetLength: Int = 0

                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, i, &parameterSetPointer, &parameterSetLength, nil, nil)

                elementaryStream.append(nStartCode, length: nStartCodeLength)
                elementaryStream.append(parameterSetPointer!, length: parameterSetLength)
            }
        }

        //4. Get a pointer to the raw AVCC NAL unit data in the sample buffer
        var blockBufferLength: Int = 0
        var bufferDataPointer: UnsafeMutablePointer<Int8>?

        CMBlockBufferGetDataPointer(CMSampleBufferGetDataBuffer(frame)!, 0, nil, &blockBufferLength, &bufferDataPointer)

        //print("Block length = ", blockBufferLength)

        //5. Loop through all the NAL units in the block buffer
        var bufferOffset:size_t = 0
        let AVCCHeaderLength: Int = 4
        while (bufferOffset < (blockBufferLength - AVCCHeaderLength) ) {
            // Read the NAL unit length
            var NALUnitLength:UInt32 =  0
            memcpy(&NALUnitLength, bufferDataPointer! + bufferOffset, AVCCHeaderLength)
            //Big-Endian to Little-Endian
            NALUnitLength = CFSwapInt32(NALUnitLength)
            if ( NALUnitLength > 0 ){
                //print("NALUnitLen = ", NALUnitLength)
                // Write start code to the elementary stream
                elementaryStream.append(nStartCode, length: nStartCodeLength)
                // Write the NAL unit without the AVCC length header to the elementary stream
                elementaryStream.append(bufferDataPointer! + bufferOffset + AVCCHeaderLength, length: Int(NALUnitLength))
                // Move to the next NAL unit in the block buffer
                bufferOffset += AVCCHeaderLength + size_t(NALUnitLength);
            }
        }

        return Data(elementaryStream)
    }

     func encodeFrame(
        _ frame: MTLTexture,
        presentationTime: Double,
        duration: Double,
        completedFrame: @escaping (_ encodedFrame: Data) -> Void
     ) {
         guard !finalized else {
             return
         }

         CVPixelBufferLockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: 0))

         guard let pixelBufferBytes = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return
         }

         let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
         let region = MTLRegionMake2D(0, 0, self.width, self.height)

         // Assuming the size of the frame is correct!

         // FIXME: We shouldn't modify this CVPixelBuffer while a `VTCompressionSessionEncodeFrame`
         // operation is still running...
         frame.getBytes(pixelBufferBytes, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)

         CVPixelBufferUnlockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: 0))

         let presentationCMTime = CMTime(value: Int64(presentationTime * 1000), timescale: 1000)
         let durationCMTime = CMTime(value: Int64(duration * 1000), timescale: 1000)

         VTCompressionSessionEncodeFrameWithOutputHandler(
             compressionSession,
             pixelBuffer,
             presentationCMTime,
             durationCMTime,
             nil,
             nil, { [weak self] status, infoFlags, sampleBuffer in
                 guard let self = self,
                     let sampleBuffer = sampleBuffer
                 else { return }

                 let result = self.didEncodeFrame(frame: sampleBuffer)
                 completedFrame(result)
             }
         )
     }

     func finalize() {
         guard !finalized else { return }
         finalized = true

         // Consider finishing remaining frames
         VTCompressionSessionInvalidate(compressionSession)
     }
}

// ---- MixedRealityRenderer.swift ----
//
//  MixedRealityRenderer.swift
//  RealityMixerExample
//
//


enum MixedRealityRendererError: Error {
    case unableToInstantiateMetalDevice
    case unableToInstantiateCommandQueue
    case unableToInstantiateTexture
    case unableToInstantiateComputePipeline
    case unableToInstantiateRealityRenderer(Error)
    case unableToInstantiateCommandBuffer
    case unableToMakeEvent
    case unableToInstantiateBlitEncoder
    case unableToInstantiateComputeEncoder
}

final class MixedRealityRenderer {

    let cameraIntrinsic: CameraIntrinsic

    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    let foregroundTexture: MTLTexture
    let backgroundTexture: MTLTexture
    let foregroundAlphaTexture: MTLTexture
    let backgroundAlphaTexture: MTLTexture
    let streamingTexture: MTLTexture

    let computePipelineState: MTLComputePipelineState

    private let parentEntity: Entity
    private let camera: PerspectiveCamera
    private let cameraNear: Float = 0.01
    private let cameraFar: Float = 100.0

    private let realityRenderer: RealityRenderer

    @MainActor
    init(cameraIntrinsic: CameraIntrinsic) throws {
        self.cameraIntrinsic = cameraIntrinsic

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MixedRealityRendererError.unableToInstantiateMetalDevice
        }

        self.device = device

        guard let commandQueue = device.makeCommandQueue() else {
            throw MixedRealityRendererError.unableToInstantiateCommandQueue
        }

        self.commandQueue = commandQueue

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(cameraIntrinsic.imageSize.width),
            height: Int(cameraIntrinsic.imageSize.height),
            mipmapped: false
        )

        textureDescriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]

        guard let foregroundTexture = device.makeTexture(descriptor: textureDescriptor),
            let backgroundTexture = device.makeTexture(descriptor: textureDescriptor),
            let foregroundAlphaTexture = device.makeTexture(descriptor: textureDescriptor),
            let backgroundAlphaTexture = device.makeTexture(descriptor: textureDescriptor)
        else {
            throw MixedRealityRendererError.unableToInstantiateTexture
        }

        let streamingTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 2 * Int(cameraIntrinsic.imageSize.width),
            height: 2 * Int(cameraIntrinsic.imageSize.height),
            mipmapped: false
        )

        streamingTextureDescriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]

        guard let streamingTexture = device.makeTexture(descriptor: streamingTextureDescriptor) else {
            throw MixedRealityRendererError.unableToInstantiateTexture
        }

        self.foregroundTexture = foregroundTexture
        self.backgroundTexture = backgroundTexture
        self.foregroundAlphaTexture = foregroundAlphaTexture
        self.backgroundAlphaTexture = backgroundAlphaTexture
        self.streamingTexture = streamingTexture

        // Compute Pipeline for the Alpha Extractor shader (inlined; no SPM Bundle.module).
        let metalSrc = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void textureProcessingKernel(
            texture2d<float, access::read> inputTexture [[ texture(0) ]],
            texture2d<float, access::write> outputTexture [[ texture(1) ]],
            uint2 gid [[ thread_position_in_grid ]]) {
            if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) { return; }
            float4 color = inputTexture.read(gid);
            float4 alphaColor = float4(color.a, color.a, color.a, 1.0);
            outputTexture.write(alphaColor, gid);
        }
        """
        guard let defaultLibrary = try? device.makeLibrary(source: metalSrc, options: nil),
            let kernelFunction = defaultLibrary.makeFunction(name: "textureProcessingKernel"),
            let computePipelineState = try? device.makeComputePipelineState(function: kernelFunction)
        else {
            throw MixedRealityRendererError.unableToInstantiateComputePipeline
        }

        self.computePipelineState = computePipelineState

        self.parentEntity = Entity()
        self.camera = PerspectiveCamera()

        camera.camera.fieldOfViewInDegrees = cameraIntrinsic.verticalFOV

        do {
            let realityRenderer = try RealityKit.RealityRenderer()
            realityRenderer.cameraSettings.colorBackground = .color(.init(gray: 0.0, alpha: 0.0))

            realityRenderer.entities.append(parentEntity)

            realityRenderer.entities.append(camera)
            realityRenderer.activeCamera = camera
            realityRenderer.lighting.intensityExponent = 13.0

            self.realityRenderer = realityRenderer
        } catch {
            throw MixedRealityRendererError.unableToInstantiateRealityRenderer(error)
        }
    }

    @MainActor
    func render(
        referenceEntity: Entity,
        cameraTransform: Transform,
        devicePosition: Vector3
    ) throws -> MTLTexture {
        defer {
            let children = parentEntity.children
            children.forEach({ referenceEntity.addChild($0) })
        }

//        let clonedEntity = referenceEntity.clone(recursive: true)
        let children = referenceEntity.children

        parentEntity.children.forEach({ $0.removeFromParent() })
        children.forEach({ parentEntity.addChild($0) })

        camera.transform = cameraTransform

        // TODO: Receive camera offset from device
        // Approximate offset for iPhone 15 Pro
//        camera.position -= (cameraTransform.matrix.rightVector * 0.06)
//        camera.position += (cameraTransform.matrix.upVector * 0.015)

        let cameraForward = cameraTransform.matrix.forwardVector
        let cameraPosition = cameraTransform.translation

        let distance = -1.0 * (cameraForward.dot(devicePosition - cameraPosition))
        let projectedDistance = min(max(cameraNear, distance), cameraFar)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MixedRealityRendererError.unableToInstantiateCommandBuffer
        }

        // Rendering Foreground Texture
        camera.camera.near = cameraNear
        camera.camera.far = projectedDistance

        guard let event = device.makeEvent() else {
            throw MixedRealityRendererError.unableToMakeEvent
        }

        do {
            let descriptor = RealityKit.RealityRenderer.CameraOutput.Descriptor.singleProjection(
                colorTexture: foregroundTexture
            )

            try realityRenderer.updateAndRender(
                deltaTime: 0.0,
                cameraOutput: .init(descriptor),
                whenScheduled: { _ in
                },
                onComplete: { renderer in
                },
                actionsBeforeRender: [
                ],
                actionsAfterRender: [
                    .signal(event, value: 1)
                ]
            )
        } catch {
            print("Error: \(error)")
        }

        commandBuffer.encodeWaitForEvent(event, value: 1)

        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw MixedRealityRendererError.unableToInstantiateBlitEncoder
        }

        blitEncoder.copy(
            from: foregroundTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(
                width: foregroundTexture.width,
                height: foregroundTexture.height,
                depth: 1
            ),
            to: streamingTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )

        blitEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Rendering Background Texture
        camera.camera.near = projectedDistance
        camera.camera.far = cameraFar

        guard let backgroundCommandBuffer = commandQueue.makeCommandBuffer() else {
            throw MixedRealityRendererError.unableToInstantiateCommandBuffer
        }

        guard let backgroundEvent = device.makeEvent() else {
            throw MixedRealityRendererError.unableToMakeEvent
        }

        do {
            let descriptor = RealityKit.RealityRenderer.CameraOutput.Descriptor.singleProjection(
                colorTexture: backgroundTexture
            )

            try realityRenderer.updateAndRender(
                deltaTime: 0.0,
                cameraOutput: .init(descriptor),
                whenScheduled: { _ in
                },
                onComplete: { renderer in
                },
                actionsBeforeRender: [
                ],
                actionsAfterRender: [
                    .signal(backgroundEvent, value: 1)
                ]
            )
        } catch {
            print("Error: \(error)")
        }

        backgroundCommandBuffer.encodeWaitForEvent(backgroundEvent, value: 1)

        guard let backgroundBlitEncoder = backgroundCommandBuffer.makeBlitCommandEncoder() else {
            throw MixedRealityRendererError.unableToInstantiateBlitEncoder
        }

        backgroundBlitEncoder.copy(
            from: backgroundTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(
                width: backgroundTexture.width,
                height: backgroundTexture.height,
                depth: 1
            ),
            to: streamingTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: foregroundTexture.width, y: 0, z: 0)
        )

        backgroundBlitEncoder.endEncoding()

        backgroundCommandBuffer.commit()
        backgroundCommandBuffer.waitUntilCompleted()

        // Extract Alpha from Foreground Texture
        guard let alphaExtractionCommandBuffer = commandQueue.makeCommandBuffer() else {
            throw MixedRealityRendererError.unableToInstantiateCommandBuffer
        }

        try extractAlpha(
            commandBuffer: alphaExtractionCommandBuffer,
            inputTexture: foregroundTexture,
            outputTexture: foregroundAlphaTexture
        )

        guard let foregroundAlphaBlitEncoder = alphaExtractionCommandBuffer.makeBlitCommandEncoder() else {
            throw MixedRealityRendererError.unableToInstantiateBlitEncoder
        }

        foregroundAlphaBlitEncoder.copy(
            from: foregroundAlphaTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(
                width: foregroundAlphaTexture.width,
                height: foregroundAlphaTexture.height,
                depth: 1
            ),
            to: streamingTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: foregroundTexture.height, z: 0)
        )

        foregroundAlphaBlitEncoder.endEncoding()

        alphaExtractionCommandBuffer.commit()
        alphaExtractionCommandBuffer.waitUntilCompleted()

        // Extract Alpha from Background Texture
        guard let alphaBackgroundExtractionCommandBuffer = commandQueue.makeCommandBuffer() else {
            throw MixedRealityRendererError.unableToInstantiateCommandBuffer
        }

        try extractAlpha(
            commandBuffer: alphaBackgroundExtractionCommandBuffer,
            inputTexture: backgroundTexture,
            outputTexture: backgroundAlphaTexture
        )

        guard let backgroundAlphaBlitEncoder = alphaBackgroundExtractionCommandBuffer.makeBlitCommandEncoder() else {
            throw MixedRealityRendererError.unableToInstantiateBlitEncoder
        }

        backgroundAlphaBlitEncoder.copy(
            from: backgroundAlphaTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(
                width: backgroundAlphaTexture.width,
                height: backgroundAlphaTexture.height,
                depth: 1
            ),
            to: streamingTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: foregroundTexture.width, y: backgroundTexture.height, z: 0)
        )

        backgroundAlphaBlitEncoder.endEncoding()

        alphaBackgroundExtractionCommandBuffer.commit()
        alphaBackgroundExtractionCommandBuffer.waitUntilCompleted()

        return streamingTexture
    }

    private func extractAlpha(
        commandBuffer: MTLCommandBuffer,
        inputTexture: MTLTexture,
        outputTexture: MTLTexture
    ) throws {
        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MixedRealityRendererError.unableToInstantiateComputeEncoder
        }

        computeEncoder.setTexture(inputTexture, index: 0)
        computeEncoder.setTexture(outputTexture, index: 1)

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (inputTexture.width + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (inputTexture.height + threadGroupSize.height - 1) / threadGroupSize.height,
            depth: 1
        )

        computeEncoder.setComputePipelineState(computePipelineState)
        computeEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        computeEncoder.endEncoding()
    }
}

// ---- MixedRealityCaptureManager.swift ----
//
//  MixedRealityCaptureManager.swift
//  RealityMixerExample
//
//


public enum MixedRealityImageTracking {
    /* Blender uses SpectatorAlign-generated ReferenceImage; no SPM asset catalog. */
}

public protocol MixedRealityCaptureDelegate: AnyObject {
    var worldTracking: WorldTrackingProvider { get }
    func didUpdateCamera(pose: Pose)
}

public final class MixedRealityCaptureManager: NSObject {
    public var delegate: MixedRealityCaptureDelegate?

    private let server: MixedRealityServer

    private var displayLink: CADisplayLink?

    // Camera Tracking
    private var cameraExtrinsic: Pose?
    private(set) var imageAnchorToWorld: Pose?
    private(set) var cameraToWorld: Pose?

    // Device Tracking
    private(set) var devicePose: Pose?

    // Mixed Reality Rendering
    private var encoder: VideoEncoder?
    private var renderer: MixedRealityRenderer?

    // The Mixed Reality video will be rendered with
    // all the children of this entity.
    public var referenceEntity: Entity?

    let framesPerSecond: Double
    let bitRate: Int

    var cameraInWorldCoordinates: Pose? {
        guard let cameraExtrinsic, let cameraToWorld else { return nil }
        return cameraToWorld * cameraExtrinsic
    }

    public init(
        framesPerSecond: Int = 30,
        bitRate: Int = 5_000_000,
        delegate: MixedRealityCaptureDelegate? = nil
    ) {
        self.framesPerSecond = Double(max(min(framesPerSecond, 60), 30))
        self.bitRate = max(min(bitRate, 20_000_000), 500_000)

        self.delegate = delegate
        server = .init()
        super.init()
        server.delegate = self
        server.startServer()
        configureDisplayLink()
    }

    func shutdown() {
        displayLink?.invalidate()
        displayLink = nil
        encoder?.finalize()
        encoder = nil
        renderer = nil
        server.terminate()
    }

    private func configureDisplayLink() {
        let displayLink = CADisplayLink(target: self, selector: #selector(update(with:)))
        displayLink.preferredFramesPerSecond = Int(framesPerSecond)
        displayLink.add(to: .main, forMode: RunLoopMode.commonModes)
        self.displayLink = displayLink
    }

    private let serverSerialQueue: DispatchQueue = DispatchQueue(label: "serverSerialQueue", qos: .userInteractive)

    @MainActor
    @objc private func update(with sender: CADisplayLink) {
        server.update()

        if let deviceAnchor = delegate?.worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) {
            self.devicePose = Pose(deviceAnchor.originFromAnchorTransform)
        }

        guard let encoder,
           let renderer,
           let cameraInWorldCoordinates,
           let referenceEntity,
           let devicePose
        else {
            return
        }

        let cameraTransform = Transform(
            scale: .init(x: 1, y: 1, z: 1),
            rotation: cameraInWorldCoordinates.rotation,
            translation: cameraInWorldCoordinates.position
        )

        do {
            let frame = try renderer.render(
                referenceEntity: referenceEntity,
                cameraTransform: cameraTransform,
                devicePosition: devicePose.position
            )

            let presentationTime = 0.0
            let frameDuration = 1.0/framesPerSecond

            encoder.encodeFrame(frame, presentationTime: presentationTime, duration: frameDuration) { [weak self] data in
                self?.serverSerialQueue.async { [weak self] in
                    self?.server.send(data: VideoDataPayload.makePayload(encodedVideoData: data))
                }
            }
        } catch {
            logger.error("Failed to render frame: \(error)")
        }
    }

    @MainActor
    public func updateCameraPosition(with imageAnchor: ImageAnchor) {
        guard imageAnchor.isTracked else { return }
        ingestImageAnchorPose(Pose(imageAnchor.originFromAnchorTransform))
    }

    /** Blender SpectatorAlign / ImageTracking without ARKit ImageAnchor type. */
    @MainActor
    public func ingestImageAnchorPose(_ pose: Pose) {
        self.imageAnchorToWorld = pose

        if let cameraExtrinsic {
            updateCameraToWorld(cameraPose: cameraExtrinsic, imageAnchorToWorld: pose)

            if let cameraInWorldCoordinates {
                delegate?.didUpdateCamera(pose: cameraInWorldCoordinates)
            }
        }
    }

    private func updateCameraToWorld(
        cameraPose: Pose,
        imageAnchorToWorld: Pose
    ) {
        let flipAnchor = Pose(
            position: .init(0, 0, 0),
            rotation: .init(angle: -.pi/2.0, axis: .init(x: 1, y: 0, z: 0))
        )

        let cameraToAnchor = cameraPose.inverse
        self.cameraToWorld = imageAnchorToWorld * flipAnchor * cameraToAnchor
    }

    deinit {
        displayLink?.invalidate()
        encoder?.finalize()
        server.terminate()
    }
}

extension MixedRealityCaptureManager: @preconcurrency MixedRealityServerDelegate {

    func didReceiveButtonPress(_ button: UInt8) {

    }

    @MainActor
    func didReceiveCameraUpdate(
        _ pose: Pose,
        imageSize: CGSize,
        verticalFOV: Float
    ) {
        let hadExtrinsic = cameraExtrinsic != nil
        self.cameraExtrinsic = pose

        /* Always recompute when we have an image-anchor seed (lock pose). */
        if let imageAnchorToWorld {
            updateCameraToWorld(cameraPose: pose, imageAnchorToWorld: imageAnchorToWorld)
        }
        else if !hadExtrinsic {
            /* First camera packet without image anchor — wait for seed. */
        }

        if let cameraInWorldCoordinates {
            delegate?.didUpdateCamera(pose: cameraInWorldCoordinates)
        }

        if encoder == nil {
            self.encoder = VideoEncoder(
                size: .init(width: imageSize.width * 2, height: imageSize.height * 2),
                frameRate: Int(framesPerSecond),
                bitRate: bitRate
            )
        }

        if renderer == nil {
            do {
                self.renderer = try MixedRealityRenderer(
                    cameraIntrinsic: .init(imageSize: imageSize, verticalFOV: verticalFOV)
                )
            } catch {
                logger.error("Failed to instantiate renderer: \(error)")
                self.renderer = nil
            }
        }
    }
}

// ---- MRC UDP beacon (iPad auto-discovery, port 13371) ----
@_silgen_name("yudpsocket_client") private func c_yudpsocket_client() -> Int32
@_silgen_name("enable_broadcast") private func c_enable_broadcast(_ fd: Int32)
@_silgen_name("yudpsocket_sentto") private func c_yudpsocket_sentto(
  _ fd: Int32, buff: UnsafePointer<CChar>, len: Int32, ip: UnsafePointer<CChar>, port: Int32) -> Int32
@_silgen_name("yudpsocket_close") private func c_yudpsocket_close(_ fd: Int32) -> Int32

private enum MRCDiscovery {
  static let udpPort: Int32 = 13371
}

private final class MRCBeaconSender {
  private var task: Task<Void, Never>?

  func start(ip: String) {
    stop()
    guard !ip.isEmpty else { return }
    let message = "BLENDER_MRC|\(ip)|13370"
    task = Task.detached(priority: .utility) {
      let sock = c_yudpsocket_client()
      guard sock >= 0 else { return }
      defer { _ = c_yudpsocket_close(sock) }
      c_enable_broadcast(sock)
      let payload = Array(message.utf8CString)
      while !Task.isCancelled {
        payload.withUnsafeBufferPointer { buf in
          guard let base = buf.baseAddress else { return }
          _ = c_yudpsocket_sentto(sock, buff: base, len: Int32(strlen(base)), ip: "255.255.255.255", port: MRCDiscovery.udpPort)
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
    }
  }

  func stop() {
    task?.cancel()
    task = nil
  }
}

// ---- BlenderImmersiveMRCController ----
@MainActor
final class BlenderImmersiveMRCController: NSObject, ObservableObject {
  static let shared = BlenderImmersiveMRCController()

  @Published private(set) var statusText = "MRC: 待機"
  @Published private(set) var serverListening = false
  @Published private(set) var localIPv4: String = ""

  private weak var referenceEntity: Entity?
  private var manager: MixedRealityCaptureManager?
  private let worldTrackingProvider = WorldTrackingProvider()
  /** Borrowed from SharedAnchor — never run a parallel ARKitSession for MRC. */
  private weak var sharedWorldTracking: WorldTrackingProvider?
  private var mrcSession: ARKitSession?
  private var imageProvider: ImageTrackingProvider?
  private let beacon = MRCBeaconSender()

  private override init() { super.init() }

  func bindReferenceEntity(_ entity: Entity) {
    referenceEntity = entity
    manager?.referenceEntity = entity
    if manager == nil {
      statusText = "MRC: 参照接続（合わせロック後に開始）"
    }
  }

  func startAfterAlignLock(referenceImage: ReferenceImage?) async {
    /* Immersive already runs SharedAnchor/WorldMesh ARKitSessions.
     * Starting another session.run here throws → SIGABRT → immersive exits.
     * RealityMixer uses one session; we only start the TCP MRC server and
     * reuse SharedAnchor's WorldTrackingProvider when available. */
    if manager != nil {
      refreshLocalIP()
      statusText = "MRC: 稼働中 :13370 IP=\(localIPv4.isEmpty ? "?" : localIPv4)"
      return
    }

    /* Prefer SharedAnchor's already-running WorldTrackingProvider. */
    if let shared = BlenderImmersiveState.shared.sharedAnchor {
      sharedWorldTracking = shared.worldTrackingProviderForMRC
    }
    else {
      sharedWorldTracking = nil
    }

    let mgr = MixedRealityCaptureManager(framesPerSecond: 30, bitRate: 5_000_000, delegate: self)
    mgr.referenceEntity = referenceEntity
    /* Seed image-anchor pose from last tracked marker so camera updates
     * from iPad can resolve cameraToWorld without a second ImageTracking session. */
    if let marker = BlenderImmersiveSpectatorAlignController.shared.latestMarkerWorldPoseForMRC {
      mgr.ingestImageAnchorPose(Pose(marker))
    }
    manager = mgr
    serverListening = true
    refreshLocalIP()
    if !localIPv4.isEmpty {
      beacon.start(ip: localIPv4)
    }
    statusText = "MRC: 待ち受け :13370 IP=\(localIPv4.isEmpty ? "Wi‑Fi確認" : localIPv4)"
    _ = referenceImage /* unused: 2nd ImageTracking session crashes Immersive */
  }

  func stopServer() {
    beacon.stop()
    manager?.shutdown()
    manager = nil
    imageProvider = nil
    sharedWorldTracking = nil
    Task { await mrcSession?.stop() }
    mrcSession = nil
    serverListening = false
    statusText = "MRC: 停止"
  }

  private func consumeImageUpdates(_ provider: ImageTrackingProvider) async {
    for await update in provider.anchorUpdates {
      guard !Task.isCancelled else { return }
      let anchor = update.anchor
      if anchor.isTracked {
        manager?.ingestImageAnchorPose(Pose(anchor.originFromAnchorTransform))
      }
    }
  }

  private func refreshLocalIP() {
    var address = ""
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return }
    defer { freeifaddrs(ifaddr) }
    var ptr: UnsafeMutablePointer<ifaddrs>? = first
    while let p = ptr {
      defer { ptr = p.pointee.ifa_next }
      let iface = p.pointee
      /* Unconfigured interfaces have a NULL ifa_addr — lock-path crash. */
      guard let sa = iface.ifa_addr else { continue }
      guard sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
      let flags = Int32(iface.ifa_flags)
      if (flags & IFF_LOOPBACK) != 0 { continue }
      if (flags & IFF_UP) == 0 { continue }
      let name = String(cString: iface.ifa_name)
      guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
      var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      getnameinfo(sa, socklen_t(sa.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
      let ip = String(cString: hostname)
      if ip.hasPrefix("127.") || ip.isEmpty { continue }
      address = ip
      if name == "en0" { break }
    }
    localIPv4 = address
  }
}

extension BlenderImmersiveMRCController: MixedRealityCaptureDelegate {
  var worldTracking: WorldTrackingProvider {
    sharedWorldTracking ?? worldTrackingProvider
  }
  func didUpdateCamera(pose: Pose) { _ = pose }
}

#endif
