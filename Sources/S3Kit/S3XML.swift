import Foundation

/// A minimal XML element tree, enough for S3's response documents.
public final class S3XMLNode {
    public let name: String
    public internal(set) var text: String = ""
    public internal(set) var children: [S3XMLNode] = []

    init(name: String) {
        self.name = name
    }

    public func child(_ name: String) -> S3XMLNode? {
        children.first { $0.name == name }
    }

    public func children(named name: String) -> [S3XMLNode] {
        children.filter { $0.name == name }
    }

    /// Text content of the first child with the given name.
    public func value(_ name: String) -> String? {
        child(name)?.text
    }

    public static func parse(_ data: Data) throws -> S3XMLNode {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        guard parser.parse(), let root = builder.root else {
            throw S3Error.invalidResponse(parser.parserError?.localizedDescription ?? "Could not parse XML response")
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: S3XMLNode?
        private var stack: [S3XMLNode] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let node = S3XMLNode(name: elementName)
            if let parent = stack.last {
                parent.children.append(node)
            } else {
                root = node
            }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            stack.removeLast()
        }
    }
}

/// Escapes text for inclusion in an XML request body.
func xmlEscape(_ string: String) -> String {
    var result = ""
    result.reserveCapacity(string.count)
    for character in string {
        switch character {
        case "&": result += "&amp;"
        case "<": result += "&lt;"
        case ">": result += "&gt;"
        case "\"": result += "&quot;"
        case "'": result += "&apos;"
        default: result.append(character)
        }
    }
    return result
}

enum S3Dates {
    static func parseISO8601(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    static func parseHTTPDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: string)
    }
}
