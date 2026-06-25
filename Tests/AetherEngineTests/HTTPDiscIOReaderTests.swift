// Remote disc-image IOReader over HTTP byte-range requests (#64 follow-up: network .iso playback).
// Pure helpers are unit-tested directly; read/seek correctness and disc detection over HTTP are
// tested against an in-process mock URLProtocol that serves byte ranges from fixture bytes, so no
// real network or server is involved.
import Foundation
import Testing
@testable import AetherEngine

// Serialized: the tests share MockRangeURLProtocol's static byte store keyed by URL; running them
// in parallel would let one test's fixture bytes answer another's request.
@Suite("HTTPDiscIOReader (#64 remote disc images)", .serialized)
struct HTTPDiscIOReaderTests {

    // MARK: - Pure helpers

    @Test("Range header spans the requested half-open window inclusively")
    func rangeHeader() {
        #expect(HTTPDiscIOReader.rangeHeader(offset: 0, length: 1) == "bytes=0-0")
        #expect(HTTPDiscIOReader.rangeHeader(offset: 2048, length: 4096) == "bytes=2048-6143")
    }

    @Test("Content-Range total is parsed; unknown size (*) is nil")
    func contentRange() {
        #expect(HTTPDiscIOReader.parseContentRangeTotal("bytes 0-0/12345") == 12345)
        #expect(HTTPDiscIOReader.parseContentRangeTotal("bytes 2048-6143/34960244736") == 34_960_244_736)
        #expect(HTTPDiscIOReader.parseContentRangeTotal("bytes 0-0/*") == nil)
        #expect(HTTPDiscIOReader.parseContentRangeTotal("garbage") == nil)
    }

    @Test("Disc-image URL detection gates the HTTP disc path")
    func discImageURL() {
        #expect(Demuxer.isDiscImageURL(URL(string: "https://h/movie.iso")!) == true)
        #expect(Demuxer.isDiscImageURL(URL(string: "https://h/MOVIE.ISO")!) == true)
        #expect(Demuxer.isDiscImageURL(URL(string: "https://h/disc.img")!) == true)
        #expect(Demuxer.isDiscImageURL(URL(string: "https://h/video.mp4")!) == false)
        #expect(Demuxer.isDiscImageURL(URL(string: "https://h/stream.m3u8")!) == false)
    }

    // MARK: - Read / seek over a mock range server

    private func makeReader(_ bytes: [UInt8]) -> HTTPDiscIOReader? {
        let url = URL(string: "http://disc.test/test.iso")!
        MockRangeURLProtocol.bytesByURL[url.absoluteString] = Data(bytes)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockRangeURLProtocol.self]
        return HTTPDiscIOReader(url: url, chunkSize: 4096, sessionConfiguration: config)
    }

    @Test("AVSEEK_SIZE returns the total size from the range probe")
    func sizeProbe() {
        let r = makeReader([UInt8](0..<200))
        #expect(r != nil)
        #expect(r?.seek(offset: 0, whence: 65536) == 200)  // AVSEEK_SIZE
    }

    @Test("Sequential and random reads return the exact source bytes")
    func reads() throws {
        let src = (0..<10_000).map { UInt8($0 & 0xff) }
        let r = try #require(makeReader(src))
        var out = [UInt8](repeating: 0, count: 6000)
        // sequential read across chunk boundaries (chunkSize 4096)
        let n1 = out.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 6000) }
        #expect(n1 > 0)
        #expect(Array(out[0..<Int(n1)]) == Array(src[0..<Int(n1)]))
        // random seek then read
        #expect(r.seek(offset: 8192, whence: SEEK_SET) == 8192)
        var out2 = [UInt8](repeating: 0, count: 100)
        let n2 = out2.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 100) }
        #expect(n2 == 100)
        #expect(Array(out2[0..<100]) == Array(src[8192..<8292]))
    }

    @Test("Reading at EOF returns 0; seek past end then read is empty")
    func eof() throws {
        let r = try #require(makeReader([UInt8](repeating: 7, count: 50)))
        #expect(r.seek(offset: 50, whence: SEEK_SET) == 50)
        var out = [UInt8](repeating: 0, count: 16)
        let n = out.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 16) }
        #expect(n == 0)
    }

    @Test("A server without range support fails init (caller falls back to streaming)")
    func noRangeSupport() {
        let url = URL(string: "http://disc.test/noRange.iso")!
        MockRangeURLProtocol.bytesByURL[url.absoluteString] = Data([1, 2, 3])
        MockRangeURLProtocol.disableRangeFor.insert(url.absoluteString)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockRangeURLProtocol.self]
        #expect(HTTPDiscIOReader(url: url, sessionConfiguration: config) == nil)
        MockRangeURLProtocol.disableRangeFor.remove(url.absoluteString)
    }

    // MARK: - Disc detection over HTTP

    @Test("DiscReader.wrap recognizes an ISO9660 disc read over HTTP")
    func discDetectionOverHTTP() throws {
        let disc = ISO9660Fixture.make(files: [
            .init(name: "VTS_01_1.VOB", length: 2048),
        ])
        let r = try #require(makeReader([UInt8](disc)))
        let wrapped = try DiscReader.wrap(r)
        #expect(wrapped != nil)
    }
}

/// In-process URLProtocol that answers `Range` requests from `bytesByURL`, returning 206 + a
/// `Content-Range` header, so HTTPDiscIOReader can be exercised without a real server.
final class MockRangeURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bytesByURL: [String: Data] = [:]
    nonisolated(unsafe) static var disableRangeFor: Set<String> = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let data = Self.bytesByURL[url.absoluteString] else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let total = data.count
        let rangeOnly = !Self.disableRangeFor.contains(url.absoluteString)
        var lower = 0, upper = total - 1, status = 200
        var headers: [String: String] = ["Content-Type": "application/octet-stream"]
        if rangeOnly, let rv = request.value(forHTTPHeaderField: "Range"),
           rv.hasPrefix("bytes=") {
            let parts = rv.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            lower = Int(parts.first ?? "0") ?? 0
            upper = (parts.count > 1 ? Int(parts[1]) : nil) ?? (total - 1)
            upper = min(upper, total - 1)
            status = 206
            headers["Content-Range"] = "bytes \(lower)-\(upper)/\(total)"
        }
        let slice = (lower <= upper && lower < total) ? data.subdata(in: lower..<(upper + 1)) : Data()
        headers["Content-Length"] = String(slice.count)
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: slice)
        client?.urlProtocolDidFinishLoading(self)
    }
}
