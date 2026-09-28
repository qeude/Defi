import Foundation

struct LosslessTOMLDocument {
  private var lines: [String]
  private let newline: String
  private var hasFinalNewline: Bool

  init(_ source: String) {
    newline = source.contains("\r\n") ? "\r\n" : "\n"
    hasFinalNewline = source.hasSuffix("\n")
    lines = source.components(separatedBy: newline)
    if hasFinalNewline { lines.removeLast() }
    if lines == [""] { lines.removeAll() }
  }

  mutating func set(table: String, key: String, value: String?, occurrence: Int = 0) {
    var (start, end) = range(of: table, occurrence: occurrence)
    if start == nil {
      guard table != "rules" else { return }
      if !table.isEmpty {
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
          lines.removeLast()
        }
        if !lines.isEmpty { lines.append("") }
        lines.append("[\(table)]")
        start = lines.count - 1
        end = lines.count
      } else {
        start = 0
        end = lines.firstIndex(where: isTableHeader) ?? lines.endIndex
      }
    }
    guard let start else { return }
    let sectionStart = table.isEmpty ? 0 : start + 1
    let sectionEnd = end ?? lines.endIndex
    if let index = lines[sectionStart..<sectionEnd].firstIndex(where: {
      assignmentKey(in: $0) == key
    }) {
      guard let equals = firstEquals(in: lines[index]) else { return }
      let (valueEnd, comments) = assignmentEnd(after: index, equals: equals)
      if let value {
        lines[index] = replacingValue(in: lines[index], with: value)
        if valueEnd > index + 1 {
          lines.removeSubrange((index + 1)..<valueEnd)
        }
        let continuationComments = comments.filter { $0.line > index }.map { $0.text }
        if !continuationComments.isEmpty {
          lines.insert(contentsOf: continuationComments, at: index + 1)
        }
      } else {
        lines.removeSubrange(index..<valueEnd)
        if !comments.isEmpty {
          lines.insert(contentsOf: comments.map { $0.text }, at: index)
        }
      }
      return
    }
    guard let value else { return }
    let insertion = "\(quoteKeyIfNeeded(key)) = \(value)"
    lines.insert(insertion, at: sectionEnd)
  }

  mutating func appendArrayTable(_ table: String, values: [(String, String)]) {
    guard !table.isEmpty else { return }
    while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
      lines.removeLast()
    }
    if !lines.isEmpty { lines.append("") }
    lines.append("[[\(table)]]")
    lines.append(contentsOf: values.map { "\(quoteKeyIfNeeded($0.0)) = \($0.1)" })
    hasFinalNewline = true
  }

  mutating func removeArrayTable(_ table: String, occurrence: Int) {
    let sections = ranges(of: table)
    guard sections.indices.contains(occurrence) else { return }
    lines.removeSubrange(sections[occurrence])
  }

  mutating func moveArrayTable(_ table: String, from source: Int, to destination: Int) {
    let sections = ranges(of: table)
    guard sections.indices.contains(source), sections.indices.contains(destination),
      source != destination
    else { return }
    let chunks = sections.map { Array(lines[$0]) }
    var reordered = chunks
    let moved = reordered.remove(at: source)
    reordered.insert(moved, at: destination)
    for index in sections.indices.reversed() {
      lines.replaceSubrange(sections[index], with: reordered[index])
    }
  }

  func contains(table: String, key: String, occurrence: Int = 0) -> Bool {
    let (start, end) = range(of: table, occurrence: occurrence)
    guard let start else {
      return false
    }
    let sectionStart = table.isEmpty ? 0 : start + 1
    let sectionEnd = end ?? lines.endIndex
    return lines[sectionStart..<sectionEnd].contains { assignmentKey(in: $0) == key }
  }

  func render() -> String {
    lines.joined(separator: newline) + (hasFinalNewline ? newline : "")
  }

  private func range(of table: String, occurrence: Int = 0) -> (Int?, Int?) {
    guard !table.isEmpty else {
      return (0, lines.firstIndex(where: isTableHeader) ?? lines.endIndex)
    }
    let matches = lines.indices.filter { index in
      guard let header = tableHeader(in: lines[index]) else { return false }
      return header.name == table && header.isArray == (table == "rules")
    }
    guard matches.indices.contains(occurrence) else { return (nil, nil) }
    let header = matches[occurrence]
    let end = lines[(header + 1)...].firstIndex(where: isTableHeader) ?? lines.endIndex
    return (header, end)
  }

  private func ranges(of table: String) -> [Range<Int>] {
    let starts = lines.indices.filter { index in
      guard let header = tableHeader(in: lines[index]) else { return false }
      return header.name == table && header.isArray
    }
    return starts.enumerated().map { offset, start in
      let nextArray = starts.dropFirst(offset + 1).first(where: { $0 > start })
      let nextHeader = lines[(start + 1)...].firstIndex(where: isTableHeader)
      let end = min(nextArray ?? lines.endIndex, nextHeader ?? lines.endIndex)
      return start..<end
    }
  }

  private func isTableHeader(_ line: String) -> Bool {
    let value = line.trimmingCharacters(in: .whitespaces)
    return value.hasPrefix("[") && value.hasSuffix("]")
  }

  private func tableName(in line: String) -> String? {
    guard let header = tableHeader(in: line), !header.isArray else { return nil }
    return header.name
  }

  private func tableHeader(in line: String) -> (name: String, isArray: Bool)? {
    let value = line.trimmingCharacters(in: .whitespaces)
    guard isTableHeader(value) else { return nil }
    if value.hasPrefix("[["), value.hasSuffix("]]"), value.count > 4 {
      return (String(value.dropFirst(2).dropLast(2)), true)
    }
    guard !value.hasPrefix("[[") else { return nil }
    return (String(value.dropFirst().dropLast()), false)
  }

  private func assignmentKey(in line: String) -> String? {
    guard let equals = firstEquals(in: line) else { return nil }
    let key = line[..<equals].trimmingCharacters(in: .whitespaces)
    guard !key.isEmpty else { return nil }
    if key.first == "\"", key.last == "\"", key.count >= 2 {
      return String(key.dropFirst().dropLast())
        .replacingOccurrences(of: "\\\"", with: "\"")
        .replacingOccurrences(of: "\\\\", with: "\\")
    }
    return key
  }

  private func assignmentEnd(after startLine: Int, equals: String.Index) -> (Int, [(line: Int, text: String)]) {
    var squareDepth = 0
    var curlyDepth = 0
    var quote: Character?
    var multilineQuote = false
    var escaped = false
    var comments: [(line: Int, text: String)] = []

    for lineIndex in startLine..<lines.endIndex {
      let line = lines[lineIndex]
      var index = lineIndex == startLine ? line.index(after: equals) : line.startIndex
      while index < line.endIndex {
        let remainder = line[index...]
        let character = line[index]
        if let currentQuote = quote {
          if multilineQuote, remainder.hasPrefix(String(repeating: currentQuote, count: 3)) {
            index = line.index(index, offsetBy: 3)
            quote = nil
            multilineQuote = false
            escaped = false
            continue
          }
          if escaped {
            escaped = false
          } else if currentQuote == "\"", character == "\\" {
            escaped = true
          } else if !multilineQuote, character == currentQuote {
            quote = nil
            escaped = false
          }
          index = line.index(after: index)
          continue
        }

        if character == "#" {
          comments.append((line: lineIndex, text: trailingComment(in: line)))
          break
        }
        if character == "\"" || character == "'" {
          let delimiter = String(repeating: character, count: 3)
          multilineQuote = remainder.hasPrefix(delimiter)
          quote = character
          index = line.index(index, offsetBy: multilineQuote ? 3 : 1)
          continue
        }
        switch character {
        case "[": squareDepth += 1
        case "]": squareDepth = max(0, squareDepth - 1)
        case "{": curlyDepth += 1
        case "}": curlyDepth = max(0, curlyDepth - 1)
        default: break
        }
        index = line.index(after: index)
      }
      if squareDepth == 0, curlyDepth == 0, quote == nil { return (lineIndex + 1, comments) }
    }
    return (lines.endIndex, comments)
  }

  private func firstEquals(in line: String) -> String.Index? {
    var quoted = false
    var escaped = false
    for index in line.indices {
      let character = line[index]
      if escaped {
        escaped = false
      } else if character == "\\", quoted {
        escaped = true
      } else if character == "\"" {
        quoted.toggle()
      } else if character == "=", !quoted {
        return index
      } else if character == "#", !quoted {
        return nil
      }
    }
    return nil
  }

  private func replacingValue(in line: String, with value: String) -> String {
    guard let equals = firstEquals(in: line) else { return line }
    let commentIndex = commentStart(in: line) ?? line.endIndex
    let beforeComment = line[..<commentIndex]
    let afterEquals = beforeComment[beforeComment.index(after: equals)...]
    let spaces = afterEquals.prefix(while: { $0 == " " || $0 == "\t" })
    let remainder = afterEquals.dropFirst(spaces.count)
    let comment = trailingComment(in: line)
    let remainderString = String(remainder)
    let trailing =
      comment.isEmpty
      ? String(remainderString.reversed().prefix(while: { $0 == " " || $0 == "\t" }).reversed())
      : ""
    return String(line[...equals]) + String(spaces) + value + trailing + comment
  }

  private func commentStart(in line: String) -> String.Index? {
    var quoted = false
    var escaped = false
    for index in line.indices {
      let character = line[index]
      if escaped {
        escaped = false
      } else if character == "\\", quoted {
        escaped = true
      } else if character == "\"" {
        quoted.toggle()
      } else if character == "#", !quoted {
        return index
      }
    }
    return nil
  }

  private func trailingComment(in line: String) -> String {
    guard let start = commentStart(in: line) else { return "" }
    let prefix = String(line[..<start])
    let spacing = String(prefix.reversed().prefix(while: { $0 == " " || $0 == "\t" }).reversed())
    return spacing + line[start...]
  }

  private func quoteKeyIfNeeded(_ key: String) -> String {
    guard key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
      return
        "\"\(key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
    return key
  }
}
