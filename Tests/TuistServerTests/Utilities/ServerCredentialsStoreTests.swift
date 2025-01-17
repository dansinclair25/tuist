import Foundation
import TuistSupport
import XCTest

@testable import TuistServer
@testable import TuistSupportTesting

final class ServerCredentialsStoreTests: TuistUnitTestCase {
    var subject: ServerCredentialsStore!

    override func setUp() {
        super.setUp()
    }

    override func tearDown() {
        subject = nil
        super.tearDown()
    }

    func test_crud() throws {
        // Given
        let temporaryDirectory = try temporaryPath()
        let subject = ServerCredentialsStore(
            fileHandler: FileHandler.shared,
            configDirectory: temporaryDirectory
        )
        let credentials = ServerCredentials(token: "token")
        let serverURL = URL(string: "https://tuist.io")!

        // When/Then
        try subject.store(credentials: credentials, serverURL: serverURL)
        XCTAssertEqual(try subject.read(serverURL: serverURL), credentials)
        try subject.delete(serverURL: serverURL)
        XCTAssertEqual(try subject.read(serverURL: serverURL), nil)
    }
}
