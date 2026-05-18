import XCTest

@testable import AgentCLIKit

final class ShellArgumentParserTests: XCTestCase {
    func testParsesWhitespaceAndQuotes() throws {
        let arguments = try ShellArgumentParser.parse("--model \"Claude Sonnet\" --flag 'two words'")

        XCTAssertEqual(arguments, ["--model", "Claude Sonnet", "--flag", "two words"])
    }

    func testParsesEscapedCharacters() throws {
        let arguments = try ShellArgumentParser.parse(#"--path ~/A\ Folder --literal \"quoted\""#)

        XCTAssertEqual(arguments, ["--path", "~/A Folder", "--literal", "\"quoted\""])
    }

    func testPreservesEmptyQuotedArguments() throws {
        let arguments = try ShellArgumentParser.parse(#"--message "" --name ''"#)

        XCTAssertEqual(arguments, ["--message", "", "--name", ""])
    }

    func testKeepsBackslashesInsideSingleQuotes() throws {
        let arguments = try ShellArgumentParser.parse(#"--path 'A\Folder' --quoted "A\"B""#)

        XCTAssertEqual(arguments, ["--path", #"A\Folder"#, "--quoted", #"A"B"#])
    }

    func testThrowsForUnterminatedQuote() {
        XCTAssertThrowsError(try ShellArgumentParser.parse(#"--model "unterminated"#)) { error in
            XCTAssertEqual(error as? AgentCLIError, .unterminatedQuote(#"--model "unterminated"#))
        }
    }
}
