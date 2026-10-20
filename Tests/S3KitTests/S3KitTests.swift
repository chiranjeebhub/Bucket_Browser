import Foundation
@testable import S3Kit
import XCTest

final class S3EncodingTests: XCTestCase {
    func testEncodeLeavesOnlyUnreserved() {
        XCTAssertEqual(S3Encoding.encode("a b/c+d~e_f.g-h"), "a%20b%2Fc%2Bd~e_f.g-h")
        XCTAssertEqual(S3Encoding.encode("ü"), "%C3%BC")
    }

    func testEncodePathKeepsSlashes() {
        XCTAssertEqual(S3Encoding.encodePath("photos/2024 trip/IMG#1.jpg"), "photos/2024%20trip/IMG%231.jpg")
    }

    func testCanonicalQuerySortsAndHandlesEmptyValues() {
        XCTAssertEqual(S3Encoding.canonicalQuery([("uploadId", "x/y"), ("partNumber", "2")]), "partNumber=2&uploadId=x%2Fy")
        XCTAssertEqual(S3Encoding.canonicalQuery([("uploads", nil)]), "uploads=")
    }
}

final class S3PathTests: XCTestCase {
    func testName() {
        XCTAssertEqual(S3Path.name(of: "a/b/c.txt"), "c.txt")
        XCTAssertEqual(S3Path.name(of: "a/b/"), "b")
        XCTAssertEqual(S3Path.name(of: "top"), "top")
    }

    func testParent() {
        XCTAssertEqual(S3Path.parent(of: "a/b/c.txt"), "a/b/")
        XCTAssertEqual(S3Path.parent(of: "a/b/"), "a/")
        XCTAssertEqual(S3Path.parent(of: "a/"), "")
        XCTAssertEqual(S3Path.parent(of: "file"), "")
    }

    func testAncestors() {
        XCTAssertEqual(S3Path.ancestors(of: ""), [""])
        XCTAssertEqual(S3Path.ancestors(of: "a/b/"), ["", "a/", "a/b/"])
    }

    func testEmptyComponentsArePreserved() {
        XCTAssertEqual(S3Path.ancestors(of: "a//"), ["", "a/", "a//"])
        XCTAssertEqual(S3Path.ancestors(of: "/x/"), ["", "/", "/x/"])
        XCTAssertEqual(S3Path.name(of: "a//"), "")
        XCTAssertEqual(S3Path.parent(of: "a//"), "a/")
        XCTAssertEqual(S3Path.parent(of: "a//file"), "a//")
    }
}

final class S3ClientURLTests: XCTestCase {
    let credentials = S3Credentials(accessKeyID: "a", secretAccessKey: "b")

    func testAWSVirtualHostedURL() throws {
        let client = S3Client(configuration: .aws(region: "eu-west-1"), credentials: credentials)
        let url = try client.makeURL(bucket: "my-bucket", key: "dir/file name.txt", query: [], region: "eu-west-1", forcePathStyle: false)
        XCTAssertEqual(url.absoluteString, "https://my-bucket.s3.eu-west-1.amazonaws.com/dir/file%20name.txt")
    }

    func testAWSDottedBucketUsesPathStyle() throws {
        let client = S3Client(configuration: .aws(region: "us-east-1"), credentials: credentials)
        let url = try client.makeURL(bucket: "my.bucket", key: "k", query: [], region: "us-east-1", forcePathStyle: false)
        XCTAssertEqual(url.absoluteString, "https://s3.us-east-1.amazonaws.com/my.bucket/k")
    }

    func testR2PathStyleURL() throws {
        let client = S3Client(configuration: .r2(accountID: "ABC123"), credentials: credentials)
        let url = try client.makeURL(bucket: "media", key: nil, query: [("prefix", "a b/"), ("list-type", "2")], region: "auto", forcePathStyle: false)
        XCTAssertEqual(url.absoluteString, "https://abc123.r2.cloudflarestorage.com/media?list-type=2&prefix=a%20b%2F")
    }

    func testR2EUJurisdictionEndpoint() {
        XCTAssertEqual(R2Jurisdiction.eu.endpoint(accountID: "abc")?.absoluteString, "https://abc.eu.r2.cloudflarestorage.com")
    }

    func testCustomEndpointWithPort() throws {
        let config = S3Configuration(provider: .custom, region: "us-east-1", endpoint: URL(string: "http://localhost:9000"), usePathStyle: true)
        let client = S3Client(configuration: config, credentials: credentials)
        let url = try client.makeURL(bucket: "b", key: "k", query: [], region: "us-east-1", forcePathStyle: false)
        XCTAssertEqual(url.absoluteString, "http://localhost:9000/b/k")
        XCTAssertEqual(SigV4Signer.hostHeader(for: url), "localhost:9000")
    }
}

final class S3ResponseParserTests: XCTestCase {
    func testListBuckets() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListAllMyBucketsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Owner><ID>1</ID></Owner>
          <Buckets>
            <Bucket><Name>photos</Name><CreationDate>2024-01-02T03:04:05.000Z</CreationDate></Bucket>
            <Bucket><Name>backups</Name><CreationDate>2023-06-01T00:00:00Z</CreationDate></Bucket>
          </Buckets>
        </ListAllMyBucketsResult>
        """
        let buckets = try S3ResponseParser.buckets(from: Data(xml.utf8))
        XCTAssertEqual(buckets.map(\.name), ["photos", "backups"])
        XCTAssertNotNil(buckets[0].creationDate)
        XCTAssertNotNil(buckets[1].creationDate)
    }

    func testListObjectsV2() throws {
        let xml = """
        <ListBucketResult>
          <Name>b</Name><Prefix>docs/</Prefix><KeyCount>3</KeyCount>
          <IsTruncated>true</IsTruncated>
          <NextContinuationToken>abc==</NextContinuationToken>
          <Contents>
            <Key>docs/readme &amp; notes.txt</Key>
            <LastModified>2024-05-01T12:00:00.000Z</LastModified>
            <ETag>&quot;9b2cf535f27731c974343645a3985328&quot;</ETag>
            <Size>1234</Size>
            <StorageClass>STANDARD</StorageClass>
          </Contents>
          <CommonPrefixes><Prefix>docs/images/</Prefix></CommonPrefixes>
          <CommonPrefixes><Prefix>docs/old/</Prefix></CommonPrefixes>
        </ListBucketResult>
        """
        let page = try S3ResponseParser.listPage(from: Data(xml.utf8))
        XCTAssertTrue(page.isTruncated)
        XCTAssertEqual(page.nextContinuationToken, "abc==")
        XCTAssertEqual(page.listing.prefixes, ["docs/images/", "docs/old/"])
        XCTAssertEqual(page.listing.objects.count, 1)
        XCTAssertEqual(page.listing.objects[0].key, "docs/readme & notes.txt")
        XCTAssertEqual(page.listing.objects[0].size, 1234)
        XCTAssertEqual(page.listing.objects[0].etag, "9b2cf535f27731c974343645a3985328")
    }

    func testErrorDocument() {
        let xml = "<Error><Code>NoSuchBucket</Code><Message>The specified bucket does not exist</Message><RequestId>R1</RequestId></Error>"
        let error = S3Error.from(status: 404, data: Data(xml.utf8))
        XCTAssertEqual(error.code, "NoSuchBucket")
        XCTAssertEqual(error.statusCode, 404)
        XCTAssertEqual(error.errorDescription, "NoSuchBucket: The specified bucket does not exist (HTTP 404)")
    }

    func testCopyErrorInsideSuccessResponseThrows() {
        let xml = "<Error><Code>InternalError</Code><Message>We encountered an internal error.</Message></Error>"
        XCTAssertThrowsError(try S3ResponseParser.throwIfErrorDocument(Data(xml.utf8), status: 200))
        XCTAssertNoThrow(try S3ResponseParser.throwIfErrorDocument(Data("<CopyObjectResult/>".utf8), status: 200))
    }

    func testDeleteErrors() throws {
        let xml = "<DeleteResult><Error><Key>a</Key><Code>AccessDenied</Code><Message>Denied</Message></Error></DeleteResult>"
        let errors = try S3ResponseParser.deleteErrors(from: Data(xml.utf8))
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors[0].key, "a")
        XCTAssertEqual(errors[0].message, "AccessDenied: Denied")
    }

    func testXMLEscape() {
        XCTAssertEqual(xmlEscape("a<b>&\"c'"), "a&lt;b&gt;&amp;&quot;c&apos;")
    }

    func testHTTPDate() {
        let date = S3Dates.parseHTTPDate("Fri, 24 May 2013 00:00:00 GMT")
        XCTAssertEqual(date, Date(timeIntervalSince1970: 1_369_353_600))
    }
}
