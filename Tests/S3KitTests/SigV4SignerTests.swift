import Foundation
@testable import S3Kit
import XCTest

/// Test vectors from the AWS "Signature Version 4 Signing Process" examples for S3.
final class SigV4SignerTests: XCTestCase {
    let credentials = S3Credentials(accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
    let date = Date(timeIntervalSince1970: 1_369_353_600) // 2013-05-24T00:00:00Z

    func testTimestamps() {
        let (amzDate, dateStamp) = SigV4Signer.timestamps(for: date)
        XCTAssertEqual(amzDate, "20130524T000000Z")
        XCTAssertEqual(dateStamp, "20130524")
    }

    func testGetObjectWithRange() {
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!)
        request.httpMethod = "GET"
        request.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        SigV4Signer(credentials: credentials, region: "us-east-1").sign(&request, payloadHash: SigV4Signer.emptyPayloadHash, date: date)

        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, "
                + "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, "
                + "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
        )
    }

    func testListObjectsQueryIsCanonicalized() {
        // Deliberately out of order: the signer must sort query parameters.
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/?prefix=J&max-keys=2")!)
        request.httpMethod = "GET"
        SigV4Signer(credentials: credentials, region: "us-east-1").sign(&request, payloadHash: SigV4Signer.emptyPayloadHash, date: date)

        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")!.hasSuffix(
            "Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7"
        ))
    }

    func testPresignedURL() {
        let url = URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!
        let presigned = SigV4Signer(credentials: credentials, region: "us-east-1").presign(url: url, expires: 86400, date: date)
        let query = URLComponents(url: presigned, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "X-Amz-Signature" }?.value,
                       "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404")
        XCTAssertEqual(query.first { $0.name == "X-Amz-Credential" }?.value,
                       "AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request")
    }

    func testSessionTokenIsSigned() {
        let temporary = S3Credentials(accessKeyID: "AKID", secretAccessKey: "secret", sessionToken: "token")
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/a")!)
        SigV4Signer(credentials: temporary, region: "us-east-1").sign(&request, payloadHash: SigV4Signer.emptyPayloadHash, date: date)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-security-token"), "token")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")!.contains("x-amz-security-token"))
    }

    func testEmptyPayloadHash() {
        XCTAssertEqual(SigV4Signer.sha256Hex(Data()), SigV4Signer.emptyPayloadHash)
    }
}
