# AI Translate

A powerful utility that parses an Xcode `.xcstrings` file, uses ChatGPT to translate each entry, and generates Swift code for easy localization access. It supports both interactive and command-line modes.

This tool is hardcoded to use ChatGPT-4. While ChatGPT3.5 is significantly less expensive, it does not provide satisfactory results. Selecting a model via a command-line flag has been deliberately omitted for this reason, thus ensuring this tool does not contribute to a proliferation of poor translations in apps on Apple platforms.  

Please note that is **very strongly** recommend to have translations tested by a qualified human as even ChatGPT-4 will almost certainly not produce perfect results.

## Features

- 🌍 **Interactive Mode**: Step-by-step guided process
- 🔄 **Translation**: Multi-language localization using OpenAI GPT-4
- 📝 **Swift Code Generation**: Automatic Swift enum generation for type-safe localization
- 🌐 **Default Languages**: Pre-configured with 10 common languages (ar,en,de,es,fr,pt,tr,ur,zh,hi)
- ⚡ **Rate Limiting**: Built-in 1-second delay to respect OpenAI API limits
- 🛡️ **Safe String Handling**: Uses triple quotes for complex localization keys
- 📁 **Backup Support**: Automatic backup of original files

## Installation

### Option 1: Build and Install System-Wide

1. **Clone the repository:**
   ```bash
   git clone https://github.com/yourusername/AITranslate.git
   cd AITranslate
   ```

2. **Build the release version:**
   ```bash
   swift build -c release
   ```

3. **Install system-wide:**
   ```bash
   # Option A: Install to /usr/local/bin (requires sudo)
   sudo cp .build/release/ai-translate /usr/local/bin/
   
   # Option B: Install to user directory (recommended)
   mkdir -p ~/.local/bin
   cp .build/release/ai-translate ~/.local/bin/
   echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
   source ~/.zshrc
   ```

4. **Verify installation:**
   ```bash
   ai-translate --help
   ```

### Option 2: Run from Source

Simply pull this repo, then run the following command from the repo root folder:

```bash
swift run ai-translate --interactive
```

## Usage

### Interactive Mode (Recommended)

The easiest way to use AI Translate is through interactive mode:

```bash
ai-translate --interactive
```

This will guide you through:
1. Choosing your operation (Swift only, Translation only, or Both)
2. Selecting your `.xcstrings` file
3. Entering your OpenAI API key (if needed)
4. Choosing target languages (defaults to 10 common languages)

### Command Line Mode

For advanced users who prefer command-line arguments:

```bash
# Full translation with Swift generation
ai-translate input.xcstrings --languages en,es,fr --open-ai-key YOUR_KEY

# Swift file generation only (no API key needed)
ai-translate input.xcstrings --swift-only

# Translation only (no Swift generation)
ai-translate input.xcstrings --languages en,es --open-ai-key YOUR_KEY --skip-swift-enums
```

### Command Line Options

```
USAGE: ai-translate [<input-file>] [--languages <languages>] [--open-ai-key <open-ai-key>] [--verbose] [--skip-backup] [--force] [--skip-swift-enums] [--swift-only] [--interactive]

ARGUMENTS:
  <input-file>              Path to your .xcstrings file

OPTIONS:
  -l, --languages <languages>
                          A comma separated list of language codes (default: ar,en,de,es,fr,pt,tr,ur,zh,hi)
  -o, --open-ai-key <open-ai-key>
                          Your OpenAI API key, see: https://platform.openai.com/api-keys
  -v, --verbose           Enable verbose output
  --skip-backup           By default a backup of the input will be created. When this flag is provided, the backup is skipped.
  -f, --force             Forces all strings to be translated, even if an existing translation is present.
  --skip-swift-enums      Skips generating Swift file with enums for localization keys after translation completion.
  --swift-only            Generate only Swift file with enums for localization keys without performing translations.
  --interactive           Run in interactive mode to guide you through the process step by step.
  -h, --help              Show help information.
```

## Generated Swift Code

The tool generates Swift code with type-safe access to your localizations:

```swift
extension String {
  struct Localizable {
    static let welcomeMessage = NSLocalizedString("""
Welcome to our app!
""", comment: """
Welcome to our app!
""")
    
    static func accountDeletionMessage(param1: String, param2: String) -> String {
      let format = NSLocalizedString("""
AccountDeletionScreen/Hi, Delete my entire account record, along with associated personal data.
My Email is %@
 customer id %@
Thanks.
""", comment: """
AccountDeletionScreen/Hi, Delete my entire account record, along with associated personal data.
My Email is %@
 customer id %@
Thanks.
""")
      return String(format: format, param1, param2)
    }
  }
}
```

## Missing Features

This tool supports all the features that I currently use personally, which are not all of the features supported by `xcstrings` (for example, I have not tested plural strings, or strings that vary by device). Pull requests are welcome to add those missing features.
