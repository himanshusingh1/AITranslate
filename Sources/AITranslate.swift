//
//  AITranslate.swift
//
//
//  Created by Paul MacRory on 3/7/24.
//

import ArgumentParser
import OpenAI
import Foundation

@main
struct AITranslate: AsyncParsableCommand {
  static let systemPrompt =
    """
    You are a translator tool that translates UI strings for a software application.
    Your inputs will be a source language, a target language, the original text, and
    optionally some context to help you understand how the original text is used within
    the application. Each piece of information will be inside some XML-like tags.
    In your response include *only* the translation, and do not include any metadata, tags, 
    periods, quotes, or new lines, unless included in the original text.
    """


  @Argument(transform: URL.init(fileURLWithPath:))
  var inputFile: URL?

  @Option(
    name: .shortAndLong,
    help: ArgumentHelp("A comma separated list of language codes (must match the language codes used by xcstrings)"), 
    transform: { input in
      input.split(separator: ",")
        .map { String($0).trimmingCharacters(in: .whitespaces) }
    }
  )
  var languages: [String] = ["ar", "en", "de", "es", "fr", "pt", "tr", "ur", "zh", "hi"]

  @Option(
    name: .shortAndLong,
    help: ArgumentHelp("Your OpenAI API key, see: https://platform.openai.com/api-keys")
  )
  var openAIKey: String?

  @Flag(name: .shortAndLong, help: "Enable verbose output")
  var verbose: Bool = false

  @Flag(
    name: .long,
    help: ArgumentHelp("By default a backup of the input will be created. When this flag is provided, the backup is skipped.")
  )
  var skipBackup: Bool = false

  @Flag(
    name: .shortAndLong,
    help: ArgumentHelp("Forces all strings to be translated, even if an existing translation is present.")
  )
  var force: Bool = false

  @Flag(
    name: .long,
    help: ArgumentHelp("Skips generating Swift file with enums for localization keys after translation completion.")
  )
  var skipSwiftEnums: Bool = false

  @Flag(
    name: .long,
    help: ArgumentHelp("Generate only Swift file with enums for localization keys without performing translations.")
  )
  var swiftOnly: Bool = false

  @Flag(
    name: .long,
    help: ArgumentHelp("Run in interactive mode to guide you through the process step by step.")
  )
  var interactive: Bool = false

  lazy var openAI: OpenAI? = {
    guard let apiKey = openAIKey else { return nil }
    let configuration = OpenAI.Configuration(
      token: apiKey,
      organizationIdentifier: nil,
      timeoutInterval: 60.0
    )

    return OpenAI(configuration: configuration)
  }()

  var numberOfTranslationsProcessed = 0

  mutating func run() async throws {
    do {
      // Handle interactive mode
      if interactive {
        try await runInteractiveMode()
        return
      }

      guard let inputFile = inputFile else {
        throw ValidationError("Input file is required for non-interactive mode. Use --interactive for guided mode.")
      }
      
      let dict = try JSONDecoder().decode(
        StringsDict.self,
        from: try Data(contentsOf: inputFile)
      )

      // If swiftOnly mode, just generate Swift file and exit
      if swiftOnly {
        try generateSwiftEnumsFile(from: dict, inputFileURL: inputFile)
        print("[✅] Swift file generated successfully")
        return
      }

      // Validate API key is provided for translation mode
      guard let _ = openAIKey else {
        throw ValidationError("OpenAI API key is required for translation mode. Use --swift-only to generate only Swift files.")
      }
      
      // Validate languages are provided for translation mode
      guard !languages.isEmpty else {
        throw ValidationError("Languages must be specified for translation mode. Use --swift-only to generate only Swift files.")
      }

      let totalNumberOfTranslations = dict.strings.count * languages.count
      let start = Date()
      var previousPercentage: Int = -1

      for entry in dict.strings {
        try await processEntry(
          key: entry.key,
          localizationGroup: entry.value,
          sourceLanguage: dict.sourceLanguage
        )

        let fractionProcessed = (Double(numberOfTranslationsProcessed) / Double(totalNumberOfTranslations))
        let percentageProcessed = Int(fractionProcessed * 100)

        // Print the progress at 10% intervals.
        if percentageProcessed != previousPercentage, percentageProcessed % 10 == 0 {
          print("[⏳] \(percentageProcessed)%")
          previousPercentage = percentageProcessed
        }

        numberOfTranslationsProcessed += languages.count
        
      }

      try save(dict, to: inputFile)

      // Generate Swift enums unless skipped
      if !skipSwiftEnums {
        try generateSwiftEnumsFile(from: dict, inputFileURL: inputFile)
      }

      let formatter = DateComponentsFormatter()
      formatter.allowedUnits = [.hour, .minute, .second]
      formatter.unitsStyle = .full
      let formattedString = formatter.string(from: Date().timeIntervalSince(start))!

      print("[✅] 100% \n[⏰] Translations time: \(formattedString)")
    } catch let error {
      throw error
    }
  }

  mutating func processEntry(
    key: String,
    localizationGroup: LocalizationGroup,
    sourceLanguage: String
  ) async throws {
    for lang in languages {
      let localizationEntries = localizationGroup.localizations ?? [:]
      let unit = localizationEntries[lang]

      // Nothing to do.
      if let unit, unit.hasTranslation, force == false {
        continue
      }

      // Skip the ones with variations/substitutions since they are not supported.
      if let unit, unit.isSupportedFormat == false {
        print("[⚠️] Unsupported format in entry with key: \(key)")
        continue
      }

      // The source text can either be the key or an explicit value in the `localizations`
      // dictionary keyed by `sourceLanguage`.
      let sourceText = localizationEntries[sourceLanguage]?.stringUnit?.value ?? key

      guard let openAI = openAI else {
        throw ValidationError("OpenAI client not available")
      }
      
      let result = try await performTranslation(
        sourceText,
        from: sourceLanguage,
        to: lang,
        context: localizationGroup.comment,
        openAI: openAI
      )

      localizationGroup.localizations = localizationEntries
      localizationGroup.localizations?[lang] = LocalizationUnit(
        stringUnit: StringUnit(
          state: result == nil ? "error" : "translated",
          value: result ?? ""
        )
      )
    }
  }

  func save(_ dict: StringsDict, to fileURL: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    let data = try encoder.encode(dict)

    try backupInputFileIfNecessary(fileURL: fileURL)
    try data.write(to: fileURL)
  }

  func backupInputFileIfNecessary(fileURL: URL) throws {
    if skipBackup == false {
      let backupFileURL = fileURL.appendingPathExtension("original")

      try? FileManager.default.trashItem(
        at: backupFileURL,
        resultingItemURL: nil
      )

      try FileManager.default.moveItem(
        at: fileURL,
        to: backupFileURL
      )
    }
  }

  func generateSwiftEnumsFile(from dict: StringsDict, inputFileURL: URL) throws {
    let fileName = inputFileURL.deletingPathExtension().lastPathComponent
    let swiftFileName = "\(fileName).swift"
    let outputURL = inputFileURL.deletingLastPathComponent().appendingPathComponent(swiftFileName)
    
    var swiftContent = "//\n//  \(swiftFileName)\n//\n//  Generated by AITranslate\n//\n\nimport Foundation\n\n"
    swiftContent += "extension String {\n"
    swiftContent += "  struct \(fileName) {\n"
    
    // Sort keys for consistent output
    let sortedKeys = dict.strings.keys.sorted()
    
    for key in sortedKeys {
      let propertyName = convertToEnumCaseName(key)
      
      // Check if the key contains format specifiers
      if hasFormatSpecifiers(key: key, dict: dict) {
        // Generate a function for keys with format specifiers
        swiftContent += "    static func \(propertyName)("
        
        // Extract format specifiers and create parameters
        let parameters = extractFormatSpecifiers(key: key, dict: dict)
        if !parameters.isEmpty {
          swiftContent += parameters.joined(separator: ", ")
        }
        
        swiftContent += ") -> String {\n"
        swiftContent += "      let format = NSLocalizedString(\"\"\"\n\(key)\n\"\"\", comment: \"\"\"\n\(key)\n\"\"\")\n"
        
        if !parameters.isEmpty {
          let paramNames = parameters.map { $0.components(separatedBy: ":")[0] }
          swiftContent += "      return String(format: format, \(paramNames.joined(separator: ", ")))\n"
        } else {
          swiftContent += "      return format\n"
        }
        
        swiftContent += "    }\n\n"
      } else {
        // Generate a static property for simple keys
        swiftContent += "    static let \(propertyName) = NSLocalizedString(\"\"\"\n\(key)\n\"\"\", comment: \"\"\"\n\(key)\n\"\"\")\n"
      }
    }
    
    swiftContent += "  }\n"
    swiftContent += "}\n"
    
    try swiftContent.write(to: outputURL, atomically: true, encoding: .utf8)
    print("[📝] Generated Swift file: \(swiftFileName)")
  }
  
  func convertToEnumCaseName(_ key: String) -> String {
    // Convert key to valid Swift enum case name
    // First, normalize whitespace and newlines
    let normalizedKey = normalizeWhitespaceAndNewlines(key)
    
    // Remove special characters and convert to camelCase
    let components = normalizedKey.components(separatedBy: CharacterSet.alphanumerics.inverted)
    let filteredComponents = components.filter { !$0.isEmpty }
    
    if filteredComponents.isEmpty {
      return "key"
    }
    
    let firstComponent = filteredComponents[0].lowercased()
    let remainingComponents = filteredComponents.dropFirst().map { $0.capitalized }
    
    var result = firstComponent + remainingComponents.joined()
    
    // Handle Swift reserved keywords
    result = handleReservedKeywords(result)
    
    // Handle names starting with numbers
    result = handleNumericPrefix(result)
    
    return result
  }
  
  func normalizeWhitespaceAndNewlines(_ key: String) -> String {
    // Replace newlines, tabs, and multiple spaces with underscores
    let newlineReplaced = key.replacingOccurrences(of: "\n", with: "_")
    let tabReplaced = newlineReplaced.replacingOccurrences(of: "\t", with: "_")
    let carriageReturnReplaced = tabReplaced.replacingOccurrences(of: "\r", with: "_")
    
    // Replace forward slashes with underscores
    let slashReplaced = carriageReturnReplaced.replacingOccurrences(of: "/", with: "_")
    
    // Replace other common special characters with underscores
    let specialCharsReplaced = slashReplaced.replacingOccurrences(of: "\\", with: "_")
      .replacingOccurrences(of: ":", with: "_")
      .replacingOccurrences(of: ";", with: "_")
      .replacingOccurrences(of: ",", with: "_")
      .replacingOccurrences(of: ".", with: "_")
      .replacingOccurrences(of: "!", with: "_")
      .replacingOccurrences(of: "?", with: "_")
      .replacingOccurrences(of: "(", with: "_")
      .replacingOccurrences(of: ")", with: "_")
      .replacingOccurrences(of: "[", with: "_")
      .replacingOccurrences(of: "]", with: "_")
      .replacingOccurrences(of: "{", with: "_")
      .replacingOccurrences(of: "}", with: "_")
      .replacingOccurrences(of: "\"", with: "_")
      .replacingOccurrences(of: "'", with: "_")
      .replacingOccurrences(of: "`", with: "_")
      .replacingOccurrences(of: "~", with: "_")
      .replacingOccurrences(of: "@", with: "_")
      .replacingOccurrences(of: "#", with: "_")
      .replacingOccurrences(of: "$", with: "_")
      .replacingOccurrences(of: "%", with: "_")
      .replacingOccurrences(of: "^", with: "_")
      .replacingOccurrences(of: "&", with: "_")
      .replacingOccurrences(of: "*", with: "_")
      .replacingOccurrences(of: "+", with: "_")
      .replacingOccurrences(of: "=", with: "_")
      .replacingOccurrences(of: "|", with: "_")
      .replacingOccurrences(of: "<", with: "_")
      .replacingOccurrences(of: ">", with: "_")
    
    // Replace multiple consecutive spaces with single underscore
    let spaceNormalized = specialCharsReplaced.replacingOccurrences(of: "  ", with: " ")
    let spaceReplaced = spaceNormalized.replacingOccurrences(of: " ", with: "_")
    
    // Replace multiple consecutive underscores with single underscore
    let underscoreNormalized = spaceReplaced.replacingOccurrences(of: "__", with: "_")
    
    // Remove leading/trailing underscores
    let trimmed = underscoreNormalized.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    
    return trimmed.isEmpty ? "key" : trimmed
  }
  
  func handleReservedKeywords(_ name: String) -> String {
    let reservedKeywords = [
      "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import",
      "init", "inout", "internal", "let", "open", "operator", "private", "precedencegroup",
      "protocol", "public", "rethrows", "static", "struct", "subscript", "typealias", "var",
      "break", "case", "catch", "continue", "default", "defer", "do", "else", "fallthrough",
      "for", "guard", "if", "in", "repeat", "return", "switch", "throw", "try", "where", "while",
      "as", "Any", "catch", "false", "is", "nil", "super", "self", "Self", "true", "associativity",
      "convenience", "dynamic", "didSet", "final", "get", "infix", "indirect", "lazy", "left",
      "mutating", "none", "nonmutating", "optional", "override", "postfix", "precedence",
      "prefix", "Protocol", "required", "right", "set", "Type", "unowned", "weak", "willSet"
    ]
    
    if reservedKeywords.contains(name) {
      return "_\(name)"
    }
    
    return name
  }
  
  func handleNumericPrefix(_ name: String) -> String {
    // Check if the name starts with a number
    if let firstChar = name.first, firstChar.isNumber {
      return "_\(name)"
    }
    
    return name
  }
  
  func hasFormatSpecifiers(key: String, dict: StringsDict) -> Bool {
    // Check if the key itself contains format specifiers
    if key.contains("%@") || key.contains("%d") || 
       key.contains("%f") || key.contains("%s") ||
       key.contains("%c") || key.contains("%x") ||
       key.contains("%X") || key.contains("%o") ||
       key.contains("%u") || key.contains("%e") ||
       key.contains("%E") || key.contains("%g") ||
       key.contains("%G") || key.contains("%p") {
      return true
    }
    
    // Check if any localization value contains format specifiers
    guard let localizationGroup = dict.strings[key] else { return false }
    
    // Check all localizations for format specifiers
    let allLocalizations = localizationGroup.localizations ?? [:]
    for (_, localizationUnit) in allLocalizations {
      if let stringValue = localizationUnit.stringUnit?.value {
        if stringValue.contains("%@") || stringValue.contains("%d") || 
           stringValue.contains("%f") || stringValue.contains("%s") ||
           stringValue.contains("%c") || stringValue.contains("%x") ||
           stringValue.contains("%X") || stringValue.contains("%o") ||
           stringValue.contains("%u") || stringValue.contains("%e") ||
           stringValue.contains("%E") || stringValue.contains("%g") ||
           stringValue.contains("%G") || stringValue.contains("%p") {
          return true
        }
      }
    }
    
    return false
  }
  
  func extractFormatSpecifiers(key: String, dict: StringsDict) -> [String] {
    // First check if the key itself contains format specifiers
    if key.contains("%@") || key.contains("%d") || 
       key.contains("%f") || key.contains("%s") ||
       key.contains("%c") || key.contains("%x") ||
       key.contains("%X") || key.contains("%o") ||
       key.contains("%u") || key.contains("%e") ||
       key.contains("%E") || key.contains("%g") ||
       key.contains("%G") || key.contains("%p") {
      return extractParametersFromString(key)
    }
    
    // Extract format specifiers and create function parameters
    guard let localizationGroup = dict.strings[key] else { return [] }
    
    // Find the first localization with format specifiers
    let allLocalizations = localizationGroup.localizations ?? [:]
    for (_, localizationUnit) in allLocalizations {
      if let stringValue = localizationUnit.stringUnit?.value {
        return extractParametersFromString(stringValue)
      }
    }
    
    return []
  }
  
  func extractParametersFromString(_ string: String) -> [String] {
    var parameters: [String] = []
    var parameterIndex = 1
    
    // Find all format specifiers and create parameters
    let formatSpecifiers = ["%@", "%d", "%f", "%s", "%c", "%x", "%X", "%o", "%u", "%e", "%E", "%g", "%G", "%p"]
    
    for specifier in formatSpecifiers {
      let count = string.components(separatedBy: specifier).count - 1
      for _ in 0..<count {
        let parameterName = "param\(parameterIndex)"
        let parameterType = getParameterType(for: specifier)
        parameters.append("\(parameterName): \(parameterType)")
        parameterIndex += 1
      }
    }
    
    return parameters
  }
  
  func getParameterType(for specifier: String) -> String {
    switch specifier {
    case "%@":
      return "String"
    case "%d", "%o", "%u", "%x", "%X":
      return "Int"
    case "%f", "%e", "%E", "%g", "%G":
      return "Double"
    case "%c":
      return "Character"
    case "%s":
      return "String"
    case "%p":
      return "UnsafeRawPointer"
    default:
      return "String"
    }
  }

  func performTranslation(
    _ text: String,
    from source: String,
    to target: String,
    context: String? = nil,
    openAI: OpenAI
  ) async throws -> String? {

    // Skip text that is generally not translated.
    if text.isEmpty ||
        text.trimmingCharacters(
          in: .whitespacesAndNewlines
            .union(.symbols)
            .union(.controlCharacters)
        ).isEmpty {
      return text
    }

    var translationRequest = "<source>\(source)</source>"
    translationRequest += "<target>\(target)</target>"
    translationRequest += "<original>\(text)</original>"

    if let context {
      translationRequest += "<context>\(context)</context>"
    }

    let query = ChatQuery(
      messages: [
        .init(role: .system, content: Self.systemPrompt)!,
        .init(role: .user, content: translationRequest)!
      ],
      model: .gpt4_o
    )

    do {
      let result = try await openAI.chats(query: query)
      let translation = result.choices.first?.message.content?.string ?? text

      if verbose {
        print("[\(target)] " + text + " -> " + translation)
      }

      // Add 1-second delay to respect OpenAI API rate limits
      try await Task.sleep(nanoseconds: 1_000_000_000)

      return translation
    } catch let error {
      print("[❌] Failed to translate \(text) into \(target)")

      if verbose {
        print("[💥]" + error.localizedDescription)
      }

      return nil
    }
  }

  mutating func runInteractiveMode() async throws {
    print("🌍 Welcome to AITranslate Interactive Mode!")
    print(String(repeating: "=", count: 50))
    
    // Step 1: Ask for mode selection
    print("\n📋 What would you like to do?")
    print("1. Generate Swift file only (no translation)")
    print("2. Perform localization + generate Swift file")
    print("3. Perform localization only")
    
    let modeChoice = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    
    let shouldTranslate: Bool
    let shouldGenerateSwift: Bool
    
    switch modeChoice {
    case "1":
      shouldTranslate = false
      shouldGenerateSwift = true
      print("✅ Selected: Swift file generation only")
    case "2":
      shouldTranslate = true
      shouldGenerateSwift = true
      print("✅ Selected: Localization + Swift file generation")
    case "3":
      shouldTranslate = true
      shouldGenerateSwift = false
      print("✅ Selected: Localization only")
    default:
      print("❌ Invalid choice. Please run the program again and select 1, 2, or 3.")
      return
    }
    
    // Step 2: Ask for file path
    print("\n📁 Please enter the path to your .xcstrings file:")
    let filePath = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    
    guard !filePath.isEmpty else {
      print("❌ No file path provided. Exiting.")
      return
    }
    
    let fileURL = URL(fileURLWithPath: filePath)
    
    // Step 3: Validate file exists
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      print("❌ File not found at: \(fileURL.path)")
      return
    }
    
    // Step 4: Load and validate the file
    let dict: StringsDict
    do {
      dict = try JSONDecoder().decode(
        StringsDict.self,
        from: try Data(contentsOf: fileURL)
      )
      print("✅ Successfully loaded file: \(fileURL.lastPathComponent)")
    } catch {
      print("❌ Failed to load file: \(error.localizedDescription)")
      return
    }
    
    // Step 5: Ask for API key if translation is needed
    if shouldTranslate {
      print("\n🔑 Please enter your OpenAI API key:")
      let apiKey = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      
      guard !apiKey.isEmpty else {
        print("❌ No API key provided. Exiting.")
        return
      }
      
      openAIKey = apiKey
      print("✅ API key set")
    }
    
    // Step 6: Ask for languages if translation is needed
    if shouldTranslate {
      print("\n🌐 Languages to translate to (default: ar,en,de,es,fr,pt,tr,ur,zh,hi):")
      print("Press Enter to use defaults, or enter comma-separated language codes:")
      let languageInput = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      
      if !languageInput.isEmpty {
        languages = languageInput.split(separator: ",")
          .map { String($0).trimmingCharacters(in: .whitespaces) }
      }
      
      print("✅ Languages: \(languages.joined(separator: ", "))")
    }
    
    // Step 7: Perform the selected operations
    print("\n🚀 Starting process...")
    
    if shouldTranslate {
      // Perform translation
      let totalNumberOfTranslations = dict.strings.count * languages.count
      let start = Date()
      var previousPercentage: Int = -1
      
      for entry in dict.strings {
        try await processEntry(
          key: entry.key,
          localizationGroup: entry.value,
          sourceLanguage: dict.sourceLanguage
        )
        
        let fractionProcessed = (Double(numberOfTranslationsProcessed) / Double(totalNumberOfTranslations))
        let percentageProcessed = Int(fractionProcessed * 100)
        
        // Print the progress at 10% intervals.
        if percentageProcessed != previousPercentage, percentageProcessed % 10 == 0 {
          print("[⏳] \(percentageProcessed)%")
          previousPercentage = percentageProcessed
        }
        
        numberOfTranslationsProcessed += languages.count
      }
      
      try save(dict, to: fileURL)
      
      let formatter = DateComponentsFormatter()
      formatter.allowedUnits = [.hour, .minute, .second]
      formatter.unitsStyle = .full
      let formattedString = formatter.string(from: Date().timeIntervalSince(start))!
      
      print("[✅] 100% \n[⏰] Translations time: \(formattedString)")
    }
    
    if shouldGenerateSwift {
      // Generate Swift file
      try generateSwiftEnumsFile(from: dict, inputFileURL: fileURL)
    }
    
    print("\n🎉 Process completed successfully!")
  }
}
