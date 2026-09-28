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
        end =
          lines.firstIndex(where: isTableHeader).map(leadingCommentStart(before:))
          ?? lines.endIndex
      }
    }
    guard let start else { return }
    let sectionStart = table.isEmpty ? 0 : start + 1
    let sectionEnd = end ?? lines.endIndex
    if let index = assignmentIndex(for: key, in: sectionStart..<sectionEnd) {
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
    return assignmentIndex(for: key, in: sectionStart..<sectionEnd) != nil
  }

  func render() -> String {
    lines.joined(separator: newline) + (hasFinalNewline ? newline : "")
  }

  private func range(of table: String, occurrence: Int = 0) -> (Int?, Int?) {
    guard !table.isEmpty else {
      return (
        0,
        lines.firstIndex(where: isTableHeader).map(leadingCommentStart(before:)) ?? lines.endIndex
      )
    }
    let matches = lines.indices.filter { index in
      guard let header = tableHeader(in: lines[index]) else { return false }
      return header.name == table && header.isArray == (table == "rules")
    }
    guard matches.indices.contains(occurrence) else { return (nil, nil) }
    let header = matches[occurrence]
    let end =
      lines[(header + 1)...].firstIndex(where: isTableHeader)
      .map(leadingCommentStart(before:)) ?? lines.endIndex
    return (header, end)
  }

  private func ranges(of table: String) -> [Range<Int>] {
    let starts = lines.indices.filter { index in
      guard let header = tableHeader(in: lines[index]) else { return false }
      return header.name == table && header.isArray
    }
    return starts.enumerated().map { offset, start in
      let nextHeader = lines[(start + 1)...].firstIndex(where: isTableHeader)
      let nextArray = starts.dropFirst(offset + 1).first(where: {
        $0 < (nextHeader ?? lines.endIndex)
      })
      let end = (nextArray ?? nextHeader).map(leadingCommentStart(before:)) ?? lines.endIndex
      return leadingCommentStart(before: start)..<end
    }
  }

  private func isTableHeader(_ line: String) -> Bool {
    tableHeader(in: line) != nil
  }

  private func tableHeader(in line: String) -> (name: String, isArray: Bool)? {
    let uncommented = commentStart(in: line).map { line[..<$0] } ?? line[...]
    let value = uncommented.trimmingCharacters(in: .whitespaces)
    guard value.hasPrefix("["), value.hasSuffix("]") else { return nil }
    let isArray = value.hasPrefix("[[") && value.hasSuffix("]]") && value.count > 4
    guard isArray || !value.hasPrefix("[[") else { return nil }
    let rawName = String(value.dropFirst(isArray ? 2 : 1).dropLast(isArray ? 2 : 1))
    let name = rawName.trimmingCharacters(in: .whitespaces)
    if name.first == "\"", name.last == "\"", name.count >= 2 {
      return (
        String(name.dropFirst().dropLast())
          .replacingOccurrences(of: "\\\"", with: "\"")
          .replacingOccurrences(of: "\\\\", with: "\\"),
        isArray
      )
    }
    if name.first == "'", name.last == "'", name.count >= 2 {
      return (String(name.dropFirst().dropLast()), isArray)
    }
    return (name, isArray)
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
    if key.first == "'", key.last == "'", key.count >= 2 {
      return String(key.dropFirst().dropLast())
    }
    return key
  }

  private func assignmentIndex(for key: String, in range: Range<Int>) -> Int? {
    var index = range.lowerBound
    while index < range.upperBound {
      if assignmentKey(in: lines[index]) == key { return index }
      if let equals = firstEquals(in: lines[index]) {
        index = min(assignmentEnd(after: index, equals: equals).0, range.upperBound)
      } else {
        index += 1
      }
    }
    return nil
  }

  private func leadingCommentStart(before header: Int) -> Int {
    var commentEnd = header
    while commentEnd > 0,
      lines[commentEnd - 1].trimmingCharacters(in: .whitespaces).isEmpty
    {
      commentEnd -= 1
    }
    var start = commentEnd
    while start > 0,
      lines[start - 1].trimmingCharacters(in: .whitespaces).hasPrefix("#")
    {
      start -= 1
    }
    return start < commentEnd ? start : header
  }

  private func assignmentEnd(after startLine: Int, equals: String.Index) -> (
    Int, [(line: Int, text: String)]
  ) {
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
    var quote: Character?
    var escaped = false
    for index in line.indices {
      let character = line[index]
      if escaped {
        escaped = false
      } else if character == "\\", quote == "\"" {
        escaped = true
      } else if let currentQuote = quote, character == currentQuote {
        quote = nil
      } else if quote == nil, character == "\"" || character == "'" {
        quote = character
      } else if character == "=", quote == nil {
        return index
      } else if character == "#", quote == nil {
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
    var quote: Character?
    var escaped = false
    for index in line.indices {
      let character = line[index]
      if escaped {
        escaped = false
      } else if character == "\\", quote == "\"" {
        escaped = true
      } else if let currentQuote = quote, character == currentQuote {
        quote = nil
      } else if quote == nil, character == "\"" || character == "'" {
        quote = character
      } else if character == "#", quote == nil {
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
