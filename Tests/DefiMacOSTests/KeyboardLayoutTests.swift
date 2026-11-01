import AppKit
import ApplicationServices
import Carbon
import DefiConfig
import Testing
@testable import DefiMacOS

// Real installed layouts keep the expectations honest: nothing here is a fixture that could
// drift from what macOS types. Chords are `modifiers-keycode`, written out by hand.
private let ansi: UInt32 = 91
private let jis: UInt32 = 201

@MainActor
private func installed(_ name: String, type: UInt32 = ansi) throws -> KeyboardLayout {
  try #require(keyboardLayout(inputSourceID: "com.apple.keylayout." + name, keyboardType: type))
}

private func chord(_ key: Key) -> String {
  let flags = CGEventFlags(rawValue: key.modifierBits)
  let names = [("ctrl", CGEventFlags.maskControl), ("alt", .maskAlternate), ("shift", .maskShift), ("cmd", .maskCommand)]
    .filter { flags.contains($0.1) }.map(\.0)
  return (names + [String(key.code)]).joined(separator: "-")
}

private func resolution(_ config: Config = Config(), _ layout: KeyboardLayout?) throws -> HotKeyResolution {
  try resolveHotKeys(
    config.keys, aliases: config.modifierCombinations, layout: layout, userWritten: Set(config.keyOverrides.keys))
}

/// Accelerator to chord, `inactive` when the binding holds none.
private func chords(_ config: Config = Config(), _ layout: KeyboardLayout?) throws -> [String: String] {
  let result = try resolution(config, layout)
  var chords = Dictionary(uniqueKeysWithValues: result.keys.map { ($0.value.accelerator, chord($0.key)) })
  for accelerator in result.inactive.keys { chords[accelerator] = "inactive" }
  return chords
}

private typealias Row = (accelerator: String, us: String, french: String, dvorak: String, jis: String)

// Mac French cannot type the bracket pair or `\` without Option-Shift. The pair stays on its own keys
// (33 and 30); `\` takes Option-Shift-/ (code 47).
private let defaultRows: [Row] = [
  ("ctrl-alt-f", "ctrl-alt-3", "ctrl-alt-3", "ctrl-alt-16", "ctrl-alt-3"),
  ("ctrl-alt-j", "ctrl-alt-38", "ctrl-alt-38", "ctrl-alt-8", "ctrl-alt-38"),
  ("ctrl-alt-k", "ctrl-alt-40", "ctrl-alt-40", "ctrl-alt-9", "ctrl-alt-40"),
  ("ctrl-alt-o", "ctrl-alt-31", "ctrl-alt-31", "ctrl-alt-1", "ctrl-alt-31"),
  ("ctrl-alt-r", "ctrl-alt-15", "ctrl-alt-15", "ctrl-alt-31", "ctrl-alt-15"),
  ("ctrl-alt-leftbracket", "ctrl-alt-33", "ctrl-alt-33", "ctrl-alt-27", "ctrl-alt-30"),
  ("ctrl-alt-rightbracket", "ctrl-alt-30", "ctrl-alt-30", "ctrl-alt-24", "ctrl-alt-42"),
  ("ctrl-alt-shift-leftbracket", "ctrl-alt-shift-33", "ctrl-alt-shift-33", "ctrl-alt-shift-27", "ctrl-alt-shift-30"),
  ("ctrl-alt-shift-rightbracket", "ctrl-alt-shift-30", "ctrl-alt-shift-30", "ctrl-alt-shift-24", "ctrl-alt-shift-42"),
  ("ctrl-alt-backslash", "ctrl-alt-42", "ctrl-alt-shift-47", "ctrl-alt-42", "ctrl-alt-93"),
  ("ctrl-alt-shift-backslash", "ctrl-alt-shift-42", "ctrl-alt-shift-42", "ctrl-alt-shift-42", "ctrl-alt-shift-93"),
  ("ctrl-alt-minus", "ctrl-alt-27", "ctrl-alt-24", "ctrl-alt-39", "ctrl-alt-27"),
  ("ctrl-alt-equal", "ctrl-alt-24", "ctrl-alt-44", "ctrl-alt-30", "ctrl-alt-shift-27"),
  ("ctrl-alt-comma", "ctrl-alt-43", "ctrl-alt-46", "ctrl-alt-13", "ctrl-alt-43"),
  ("ctrl-alt-period", "ctrl-alt-47", "ctrl-alt-shift-43", "ctrl-alt-14", "ctrl-alt-47"),
  ("ctrl-alt-semicolon", "ctrl-alt-41", "ctrl-alt-43", "ctrl-alt-6", "ctrl-alt-41"),
  ("ctrl-alt-quote", "ctrl-alt-39", "ctrl-alt-39", "ctrl-alt-12", "ctrl-alt-39"),
  // Digits and arrows never follow the layout.
  ("ctrl-alt-1", "ctrl-alt-18", "ctrl-alt-18", "ctrl-alt-18", "ctrl-alt-18"),
  ("ctrl-alt-shift-9", "ctrl-alt-shift-25", "ctrl-alt-shift-25", "ctrl-alt-shift-25", "ctrl-alt-shift-25"),
  ("ctrl-alt-left", "ctrl-alt-123", "ctrl-alt-123", "ctrl-alt-123", "ctrl-alt-123"),
]

@MainActor
struct KeyboardLayoutResolverTests {
  @Test
  func usAndUsInternationalKeepEveryDefaultOnItsPhysicalKey() throws {
    let physical = try configuredHotKeys(Config()).mapValues(\.command)
    for name in ["US", "USInternational-PC"] {
      let resolved = try configuredHotKeys(Config(), layout: installed(name)).mapValues(\.command)
      #expect(resolved == physical, "\(name)")
    }
  }

  @Test(arguments: ["US", "French", "Dvorak"])
  func defaultsLandOnTheKeysTheLayoutPrints(name: String) throws {
    let result = try chords(Config(), installed(name))
    for row in defaultRows {
      let expected = name == "US" ? row.us : name == "French" ? row.french : row.dvorak
      #expect(result[row.accelerator] == expected, "\(name) \(row.accelerator)")
    }
  }

  @Test
  func japaneseKeyboardUsesTheKeysItPrints() throws {
    #expect(KBGetLayoutType(Int16(jis)) == OSType(kKeyboardJIS))
    let result = try chords(Config(), installed("ABC", type: jis))
    for row in defaultRows { #expect(result[row.accelerator] == row.jis, "JIS \(row.accelerator)") }
  }

  @Test
  func nilLayoutIsTheTodayTable() throws {
    let names = Array(acceleratorKeyCodes.keys)
    let keys = Dictionary(uniqueKeysWithValues: names.map { ("ctrl-alt-shift-" + $0, "diagnostic-mark") })
    let result = try resolveHotKeys(keys, aliases: [:], layout: nil)
    #expect(result.inactive.isEmpty)
    for name in names {
      let code = try #require(acceleratorKeyCodes[name])
      #expect(result.keys.contains { chord($0.key) == "ctrl-alt-shift-\(code)" && $0.value.accelerator == "ctrl-alt-shift-" + name }, "\(name)")
    }
  }

  // Hand-derived from `com.apple.keylayout.German`: `\` needs Option-Shift-7, which is
  // ctrl-alt-shift-7, and Shift-# is claimed by `'`. Shift-backslash cannot follow backslash to
  // key 42, so it takes the first key printing a symbol that is free with Control, Option and Shift: `´` at 24.
  @Test
  func germanShiftedBackslashTakesTheFirstFreeSymbolKey() throws {
    let result = try chords(Config(), installed("German"))
    #expect(result["ctrl-alt-shift-backslash"] == "ctrl-alt-shift-24")
    #expect(result["ctrl-alt-backslash"] == "ctrl-alt-42")
  }

  // Spanish: `\` is Option-6 (the 6 key) and `'` holds key 42, so the first free key printing a symbol
  // is `<` at 50, after `=` `-` and the bracket pair's `` ` `` and `´`. Swedish: `´` at 24 is free.
  @Test(arguments: [("Spanish", "ctrl-alt-50"), ("Swedish", "ctrl-alt-24")])
  func backslashFallsBackToTheFirstFreeSymbolKey(name: String, expected: String) throws {
    #expect(try chords(Config(), installed(name))["ctrl-alt-backslash"] == expected)
  }

  // UCKeyTranslate prints a character for key 10 (§) and keys 93 and 94 on every keyboard type, but
  // only ISO keyboards have the first and only JIS keyboards the others.
  @Test
  func keysTheHardwareLacksPrintNothing() throws {
    let iso: UInt32 = 92
    #expect(try installed("ABC", type: ansi).characters[[]]?[10] == nil)
    #expect(try installed("ABC", type: jis).characters[[]]?[10] == nil)
    #expect(try installed("ABC", type: iso).characters[[]]?[10] == "§")
    #expect(try installed("ABC", type: jis).characters[[]]?[50] == nil)
    #expect(try installed("ABC", type: ansi).characters[[]]?[50] == "`")
    #expect(try installed("ABC", type: ansi).characters[[]]?[93] == nil)
    #expect(try installed("ABC", type: iso).characters[[]]?[94] == nil)
    #expect(try installed("ABC", type: jis).characters[[]]?[93] == "¥")
  }

  @Test
  func everyDefaultResolvesOnEveryInstalledAsciiLayout() throws {
    let configs = [
      Config(),
      Config(modifierCombinations: ["hyper": "alt+cmd+ctrl"], defaultKeyModifier: "hyper"),
    ]
    let sources = TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
    var read = 0
    for source in sources {
      guard let ascii = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable),
        CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(ascii).takeUnretainedValue()),
        let id = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
      else { continue }
      let name = Unmanaged<CFString>.fromOpaque(id).takeUnretainedValue() as String
      for type in [ansi, jis] {
        guard let layout = keyboardLayout(inputSourceID: name, keyboardType: type) else { continue }
        read += 1
        for config in configs {
          let result = try resolution(config, layout)
          #expect(result.inactive.count == 0, "\(name) \(type) \(config.defaultKeyModifier): \(result.inactive)")
          #expect(result.keys.count == config.keys.count, "\(name) \(type) \(config.defaultKeyModifier)")
        }
      }
    }
    #expect(read > 40)
    #expect(configs[1].keys.keys.contains("hyper-shift-rightbracket"))
  }

  @Test
  func lettersFollowTheLayoutAndFallBackToTheirOwnKey() throws {
    // Without an `o` on the base layer, the table name keeps its physical key.
    let withoutO = KeyboardLayout(characters: [[]: [3: "f", 31: "x"]])
    let result = try chords(Config(), withoutO)
    #expect(result["ctrl-alt-f"] == "ctrl-alt-3")
    #expect(result["ctrl-alt-o"] == "ctrl-alt-31")
    let onlyUpper = KeyboardLayout(characters: [[]: [:], .shift: [5: "o"]])
    #expect(try chords(Config(), onlyUpper)["ctrl-alt-o"] == "ctrl-alt-31")
  }

  @Test
  func commandChordsReadTheCommandLayer() throws {
    let layout = try installed("DVORAK-QWERTYCMD")
    let config = Config(keys: ["ctrl-alt-cmd-f": "maximize-column"])
    let result = try chords(config, layout)
    #expect(result["ctrl-alt-f"] == "ctrl-alt-16")
    #expect(result["ctrl-alt-cmd-f"] == "ctrl-alt-cmd-3")
  }

  // Command-Q and Command-W close; they sit where the Command layer prints q and w. Mac French prints
  // them on keys 0 and 6, and Dvorak-QWERTY⌘ keeps the QWERTY positions under Command.
  @Test
  func closeWindowKeysFollowTheCommandLayer() throws {
    #expect(closeWindowKeyCodes(layout: nil) == [12, 13])
    #expect(closeWindowKeyCodes(layout: try installed("US")) == [12, 13])
    #expect(closeWindowKeyCodes(layout: try installed("French")) == [0, 6])
    #expect(closeWindowKeyCodes(layout: try installed("Dvorak")) == [7, 43])
    #expect(closeWindowKeyCodes(layout: try installed("DVORAK-QWERTYCMD")) == [12, 13])
    // A layout without the letters keeps the physical keys.
    #expect(closeWindowKeyCodes(layout: KeyboardLayout(characters: [[]: [0: "a"]])) == [12, 13])
    #expect(try resolution(Config(), try installed("French")).closeWindowKeyCodes == [0, 6])
  }

  @Test
  func keypadCodesAreNeverScanned() throws {
    let config = Config(keys: ["alt-slash": "maximize-column"])
    #expect(try chords(config, installed("French"))["alt-slash"] == "alt-shift-47")
  }

  @Test
  func literalsOnFrench() throws {
    let config = Config(keys: ["alt-é": "maximize-column", "ctrl-alt-é": "toggle-floating", "ctrl-alt-ù": "toggle-floating"])
    let french = try installed("French")
    let result = try resolution(config, french)
    let byAccelerator = Dictionary(uniqueKeysWithValues: result.keys.map { ($0.value.accelerator, chord($0.key)) })
    #expect(byAccelerator["alt-é"] == "alt-19")
    #expect(byAccelerator["ctrl-alt-ù"] == "ctrl-alt-39")
    // The digit row wins: workspace 2 already holds ctrl-alt-19.
    // A binding the user wrote holds its character ahead of the generated digit.
    #expect(byAccelerator["ctrl-alt-é"] == "ctrl-alt-19")
    #expect(result.inactive == ["ctrl-alt-2": .held(by: "ctrl-alt-é")])
    // The digit row holds `'` at 21 and the literal took quote's physical key 39, so quote takes
    // the first free key printing a symbol: 18 to 24 are the digit row and `-`, and 27 is `)`.
    #expect(byAccelerator["ctrl-alt-quote"] == "ctrl-alt-27")
  }

  @Test
  func theDaemonPathAlsoRanksWhatTheUserWroteFirst() throws {
    let config = Config(keys: ["ctrl-alt-é": "maximize-column"])
    let keys = try configuredHotKeys(config, layout: installed("French"))
    #expect(keys[Key(code: 19, flags: CGEventFlags([.maskControl, .maskAlternate]).rawValue)]?.command == "maximize-column")
    #expect(keys.values.filter { $0.accelerator == "ctrl-alt-2" }.isEmpty)
  }

  @Test
  func literalsOnJapaneseKeyboard() throws {
    let layout = try installed("ABC", type: jis)
    let config = Config(keys: ["ctrl-alt-¥": "maximize-column", "ctrl-alt-_": "toggle-floating"])
    let result = try chords(config, layout)
    #expect(result["ctrl-alt-¥"] == "ctrl-alt-93")
    #expect(result["ctrl-alt-_"] == "ctrl-alt-94")
    // ¥ took the key backslash would use, and `]` took its physical key, so backslash takes the
    // first key printing a symbol: `^` at 24.
    #expect(result["ctrl-alt-backslash"] == "ctrl-alt-24")
  }

  @Test
  func literalsOnUs() throws {
    let config = Config(keys: ["ctrl-alt-_": "maximize-column", "ctrl-alt-é": "toggle-floating"])
    let result = try resolution(config, installed("US"))
    #expect(result.keys.contains { $0.value.accelerator == "ctrl-alt-_" && chord($0.key) == "ctrl-alt-shift-27" })
    #expect(result.inactive == ["ctrl-alt-é": .absentFromLayout])
  }

  @Test
  func aCharacterBindingBeatsAPositionalOneOnTheSameChord() throws {
    // `m` printed on the semicolon key: the letter keeps it, semicolon looks elsewhere.
    let layout = KeyboardLayout(characters: [[]: [41: "m"]])
    let config = Config(keys: ["ctrl-alt-m": "maximize-column", "ctrl-alt-semicolon": "join-window left"])
    let result = try chords(config, layout)
    #expect(result["ctrl-alt-m"] == "ctrl-alt-41")
    #expect(result["ctrl-alt-semicolon"] == "ctrl-alt-0")
  }

  @Test
  func aFallbackNeverTakesAChordAnotherCharacterNeeds() throws {
    // `quote` sorts before `semicolon`, but its physical fallback (39) is where `;` is printed.
    let layout = KeyboardLayout(characters: [[]: [39: ";"]])
    let config = Config(keys: ["ctrl-alt-quote": "join-window right", "ctrl-alt-semicolon": "join-window left"])
    let result = try chords(config, layout)
    #expect(result["ctrl-alt-semicolon"] == "ctrl-alt-39")
    #expect(result["ctrl-alt-quote"] == "ctrl-alt-0")
  }

  @Test
  func bracketPairStaysOnItsOwnKeysWhenEitherNeedsAddedModifiers() throws {
    // On French neither bracket is typed plain, and Option-Shift-5 is the digit 5 chord.
    let result = try chords(Config(), installed("French"))
    #expect(result["ctrl-alt-leftbracket"] == "ctrl-alt-33")
    #expect(result["ctrl-alt-rightbracket"] == "ctrl-alt-30")
    #expect(result["ctrl-alt-shift-leftbracket"] == "ctrl-alt-shift-33")
    #expect(result["ctrl-alt-shift-rightbracket"] == "ctrl-alt-shift-30")
    // `[` is plain on key 5 but `]` is not: the plain one gives up its character with it.
    let mixed = KeyboardLayout(characters: [[]: [5: "["], [.shift, .option]: [6: "]"]])
    let both = try resolveHotKeys(
      ["ctrl-alt-leftbracket": "a", "ctrl-alt-rightbracket": "b"], aliases: [:], layout: mixed)
    #expect(both.keys.map { "\(chord($0.key)) \($0.value.accelerator)" }.sorted()
      == ["ctrl-alt-30 ctrl-alt-rightbracket", "ctrl-alt-33 ctrl-alt-leftbracket"])
    // Bound alone, a bracket keeps looking for its character.
    let alone = try resolveHotKeys(["ctrl-alt-leftbracket": "a"], aliases: [:], layout: mixed)
    #expect(alone.keys.map { chord($0.key) } == ["ctrl-alt-5"])
  }

  @Test
  func aShiftedSymbolFollowsItsSiblingsKeyWhenFree() throws {
    // `x` holds key 27, so minus falls to the first free key, 0. Shift-minus would take its own
    // physical key 27 with Shift, but it follows minus to key 0 instead.
    let layout = KeyboardLayout(characters: [[]: [0: "a", 27: "x"]])
    let bound = ["ctrl-alt-x": "a", "ctrl-alt-minus": "b", "ctrl-alt-shift-minus": "c"]
    let result = try resolveHotKeys(bound, aliases: [:], layout: layout)
    #expect(result.keys.map { "\(chord($0.key)) \($0.value.accelerator)" }.sorted()
      == ["ctrl-alt-0 ctrl-alt-minus", "ctrl-alt-27 ctrl-alt-x", "ctrl-alt-shift-0 ctrl-alt-shift-minus"])
  }

  @Test
  func unknownLiteralsAreInactiveOnlyForThatBinding() throws {
    let config = Config(keys: ["ctrl-alt-ж": "maximize-column"])
    let result = try resolution(config, installed("US"))
    #expect(result.inactive == ["ctrl-alt-ж": .absentFromLayout])
    #expect(result.keys.count == Config().keys.count)
  }

  @Test
  func malformedAcceleratorsStillFail() {
    #expect(throws: HotKeyError.invalidAccelerator("ctrl-alt-unknown")) {
      try resolveHotKeys(["ctrl-alt-unknown": "maximize-column"], aliases: [:], layout: nil)
    }
  }
}

@MainActor
struct KeyboardLayoutLabelTests {
  private func label(_ accelerator: String, _ layout: KeyboardLayout, _ config: Config = Config()) -> String {
    shortcutKeyLabel(
      accelerator, aliases: [:], resolved: ShortcutResolution(config: config, layout: layout))
  }

  @Test
  func labelsNameTheKeyActuallyPressed() throws {
    let french = try installed("French")
    #expect(label("ctrl-alt-period", french) == "⌃⌥⇧;")
    #expect(label("ctrl-alt-rightbracket", french) == "⌃⌥$")
    #expect(label("ctrl-alt-leftbracket", french) == "⌃⌥^")
    #expect(label("ctrl-alt-1", french) == "⌃⌥1")
    #expect(label("ctrl-alt-backslash", try installed("ABC", type: jis)) == "⌃⌥¥")
  }

  @Test
  func inactiveShortcutsSayWhy() throws {
    let config = Config(keys: ["ctrl-alt-é": "maximize-column"])
    #expect(label("ctrl-alt-é", try installed("French"), config) == "⌃⌥É")
    #expect(label("ctrl-alt-2", try installed("French"), config) == "Held by ⌃⌥É")
    #expect(label("ctrl-alt-é", try installed("US"), config) == "Not on this layout")
  }

  @Test
  func anAcceleratorAnotherAppHoldsSaysSo() throws {
    let resolved = ShortcutResolution(config: Config(), layout: try installed("US"), heldByAnotherApp: ["ctrl-alt-f"])
    #expect(shortcutKeyLabel("ctrl-alt-f", aliases: [:], resolved: resolved) == "Held by another app")
    #expect(shortcutKeyLabel("ctrl-alt-j", aliases: [:], resolved: resolved) == "⌃⌥J")
    #expect(resolved.resolution.inactive == ["ctrl-alt-f": .heldByAnotherApp])
  }

  @Test
  func anUnsavedAcceleratorIsLabelledFromItsOwnResolution() throws {
    #expect(label("ctrl-alt-ù", try installed("French")) == "⌃⌥Ù")
  }

  @Test
  func cheatsheetShowsTheResolvedKeys() throws {
    let rows = shortcutGroups(config: Config(), layout: try installed("French")).flatMap(\.rows)
    #expect(rows.contains { $0.action == "Last column" && $0.modifiers == "⌃⌥" && $0.key == "$" })
    #expect(rows.contains { $0.action == "Workspace 1–9" && $0.key == "1–9" })
  }

  @Test(arguments: ["US", "French", "Dvorak", "ABC"])
  func recordedKeysResolveBackToTheKeyPressed(name: String) throws {
    let layout = try installed(name, type: name == "ABC" ? jis : ansi)
    let modifiers: NSEvent.ModifierFlags = [.control, .option]
    for code in layoutScannedKeyCodes {
      guard let accelerator = recordedAccelerator(keyCode: code, modifiers: modifiers, layout: layout) else {
        // Only a key with no table name may stay unrecorded, e.g. French 93 printing a character that
        // an earlier key already prints.
        #expect(!acceleratorKeyCodes.values.contains(code), "\(name) \(code)")
        continue
      }
      let resolved = try resolveHotKeys([accelerator: ""], aliases: [:], layout: layout)
      #expect(resolved.keys.keys.map(chord) == ["ctrl-alt-\(code)"], "\(name) \(code) \(accelerator)")
    }
  }

  @Test
  func recordedNamesOnFrench() throws {
    let french = try installed("French")
    let modifiers: NSEvent.ModifierFlags = [.control, .option]
    #expect(recordedAccelerator(keyCode: 33, modifiers: modifiers, layout: french) == "alt-ctrl-^")
    #expect(recordedAccelerator(keyCode: 18, modifiers: modifiers, layout: french) == "alt-ctrl-1")
    #expect(recordedAccelerator(keyCode: 41, modifiers: modifiers, layout: french) == "alt-ctrl-m")
  }

  @Test
  func writtenShiftedSymbolWinsTheChordItsGeneratedSiblingWouldAdd() throws {
    let result = try resolveHotKeys(
      ["ctrl-alt-period": "generated", "ctrl-alt-shift-period": "written"], aliases: [:],
      layout: installed("French"), userWritten: ["ctrl-alt-shift-period"])
    #expect(result.keys.contains { chord($0.key) == "ctrl-alt-shift-43" && $0.value.command == "written" })
    #expect(result.keys.contains { chord($0.key) == "ctrl-alt-47" && $0.value.command == "generated" })
  }

  @Test
  func writtenShiftedSymbolOnTheBaseLayerWinsItsChord() throws {
    let result = try resolveHotKeys(
      ["ctrl-alt-period": "generated", "ctrl-alt-semicolon": "sibling", "ctrl-alt-shift-semicolon": "written"],
      aliases: [:], layout: installed("French"), userWritten: ["ctrl-alt-shift-semicolon"])
    #expect(result.keys.contains { chord($0.key) == "ctrl-alt-shift-43" && $0.value.command == "written" })
  }

  @Test
  func followerKeepsItsWrittenModifiers() throws {
    // `/` holds the chord `\\` would add, so `ctrl-backslash` takes its physical key and the follower joins it.
    let result = try resolveHotKeys(
      ["ctrl-alt-shift-slash": "a", "ctrl-backslash": "b", "ctrl-shift-backslash": "c"], aliases: [:],
      layout: installed("French"))
    #expect(result.keys.contains { chord($0.key) == "ctrl-42" && $0.value.command == "b" })
    #expect(result.keys.contains { chord($0.key) == "ctrl-shift-42" && $0.value.command == "c" })
  }
}
