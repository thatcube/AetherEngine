// Tests/AetherEngineTests/PacketRingBufferTests.swift
import XCTest
@testable import AetherEngine

final class PacketRingBufferTests: XCTestCase {
    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("prbtest-\(ProcessInfo.processInfo.globallyUniqueString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    func testAppendAndKeyframeSeek() throws {
        let ring = try PacketRingBuffer(windowSeconds: 10, scratch: tmpDir())
        try ring.append(pts: 0, isKeyframe: true,  bytes: Data([0]))
        try ring.append(pts: 1, isKeyframe: false, bytes: Data([1]))
        try ring.append(pts: 2, isKeyframe: true,  bytes: Data([2]))
        try ring.append(pts: 3, isKeyframe: false, bytes: Data([3]))
        XCTAssertEqual(try ring.keyframePts(atOrBefore: 3.5), 2)
        XCTAssertEqual(try ring.packets(fromPts: 2).map(\.pts), [2, 3])
    }
    func testEvictsOutsideWindow() throws {
        let ring = try PacketRingBuffer(windowSeconds: 5, scratch: tmpDir())
        for i in 0...20 { try ring.append(pts: Double(i), isKeyframe: i % 2 == 0, bytes: Data([UInt8(i)])) }
        // edge 20, window 5 -> oldest retained must keep a keyframe at/below 15
        XCTAssertLessThanOrEqual(try XCTUnwrap(ring.oldestPts), 15)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(ring.oldestPts), 13)
    }
    func testReplayBytesRoundTrip() throws {
        let ring = try PacketRingBuffer(windowSeconds: 10, scratch: tmpDir())
        try ring.append(pts: 0, isKeyframe: true, bytes: Data([9, 8, 7]))
        XCTAssertEqual(try ring.packets(fromPts: 0).first?.bytes, Data([9, 8, 7]))
    }
}
