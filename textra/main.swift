//
//  main.swift
//  textra
//
//  Created by Dylan Freedman on 11/28/22.
//

import Foundation
import Vision
import VisionKit
import Speech
import AVFoundation
import Darwin
import Foundation
import AppKit

// MARK: - Types

/// A representation of the arguments passed to the command-line interface
struct CLIInput {
    /// Whether to show help
    var help: Bool = false
    /// Whether to print version
    var version: Bool = false
    /// Whether to run in silent mode
    var silent: Bool = false
    /// Input files to convert
    var inputFiles: [InputFile] = []
}

/// An input file to convert and output
struct InputFile {
    /// The input paths
    var inputFiles: [ConvertFile] = []
    /// Whether to explicitly output to stdout
    var outputStdout: Bool = false
    /// Locations to output full text
    var outputFullText: [String] = []
    /// Locations to output individual page text
    var outputPageText: [String] = []
    /// Locations to output individual page position JSONs
    var outputPositions: [String] = []
    /// Whether local output should be suppressed (this is set globally, not by the user)
    var suppress = false
    
    /// Whether to output to stdout (calculated as true if no options are specified)
    var shouldOutputToStdout: Bool {
        get {
            // Should output to stdout if explicitly specified
            // OR if no options were specified
            outputStdout || (outputFullText.count == 0 && outputPageText.count == 0 && outputPositions.count == 0)
        }
    }
    /// Whether it should extract full page text
    var shouldExtractFullPageText: Bool {
        get {
            shouldOutputToStdout || outputFullText.count > 0 || outputPageText.count > 0
        }
    }
    /// Whether it should extract positional page text
    var shouldExtractPositionalText: Bool {
        get {
            outputPositions.count > 0
        }
    }
}

/// A file that is being converted
enum ConvertFile {
    /// A PDF file with a path
    case pdf(filePath: String)
    /// An image (PNG, JPG, etc.) file with a path
    case image(filePath: String)
    /// An audio (WAV, MP3, etc.) file with a path
    case audio(filePath: String)
    
    /// The underlying file path for the file
    var filePath: String {
        get {
            switch self {
            case .pdf(let filePath): return filePath
            case .image(let filePath): return filePath
            case .audio(let filePath): return filePath
            }
        }
    }
    
    /// Whether the file is a multipage document
    var isMultipage: Bool {
        get {
            switch self {
            case .pdf: return true
            default: return false
            }
        }
    }
}

/// An update with conversion progress and status
enum ConvertResponse {
    /// An update with page number, text, positions, and an amount to adjust the progress bar
    case update(pageNum: Int?, pageText: String?, pagePositions: String?, progressPushValue: Double?)
    /// An error encountered in conversion
    case error(message: String)
}

// MARK: - Conversion functions

/// Metadata to inject in positional text extraction
let textraInfo = [
    "program": "textra",
    "version": VERSION
]

/// Multiplier to duration in number of seconds to get a fake "number of pages" for use in progress bars
let AUDIO_DURATION_FACTOR = 1.0 / 3.0

/**
 Formats a duration in seconds as a mm:ss or hh:mm:ss string
 
 - Parameter duration: The duration in seconds
 - Returns: The duration expressed as a formatted string
 */
func formatDuration(_ duration: Double) -> String {
    let hours = Int(duration / 3600)
    let minutes = Int((duration.truncatingRemainder(dividingBy: 3600)) / 60)
    let seconds = Int(duration.truncatingRemainder(dividingBy: 60))
    
    if hours > 0 {
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    } else {
        return String(format: "%02d:%02d", minutes, seconds)
    }
}


/**
 Gets the page count of a convert file
 
 - Parameter convertFile: The file to extract page count for
 - Returns: A tuple of the number of pages in the file (1 if an image/audio), and the weight of the number (page count if just an image/pdf, or the duration adjusted if an audio file)
 */
func getPageCount(convertFile: ConvertFile) -> (Int, Double)? {
    switch convertFile {
    case .pdf(let filePath):
        // Extract page count from PDF file
        let pdfDocument = CGPDFDocument(URL(fileURLWithPath: filePath) as CFURL)
        if let _pdfDocument = pdfDocument {
            return (_pdfDocument.numberOfPages, Double(_pdfDocument.numberOfPages))
        } else {
            return nil
        }
    case .image:
        // Images are just single pages
        return (1, 1)
    case .audio(let filePath):
        // Audio is just a single object, but get its duration to determine weight
        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: filePath))
            return (1, Double(audioPlayer.duration))
        } catch {
            return nil
        }
    }
}

/**
 Extracts a JSON document of positional text from the image
 
 - Parameter image: The image from which to extract positional text
 - Returns: A tuple of a stringified JSON document of the positional image and the combined text of the extraction, or nil if extraction failed
 */
func extractPositionalTextFromImage(_ image: CGImage) -> (String, String)? {
    var positionalJson: [[String: Any]]? = nil
    var fullText: [String] = []
    let request = VNRecognizeTextRequest { (request, error) in
        guard let observations = request.results as? [VNRecognizedTextObservation] else {
            return
        }
        
        positionalJson = []
        
        // Get the recognized text and its location from the observations
        for observation in observations {
            if let recognizedText = observation.topCandidates(1).first {
                fullText.append(recognizedText.string)
                positionalJson?.append(["observation": [
                    "text": recognizedText.string,
                    "confidence": recognizedText.confidence,
                    "bounds": [
                        "x1": observation.topLeft.x,
                        "y1": observation.topLeft.y,
                        "x2": observation.bottomRight.x,
                        "y2": observation.bottomRight.y
                    ]
                ]])
            }
        }
    }
    
    // Create an image request handler
    let handler = VNImageRequestHandler(cgImage: image)
    
    do {
        try handler.perform([request])
        if let _positionalJson = positionalJson {
            // Get full text from the positional text
            let combinedFullText = fullText.joined(separator: "\n")
            
            // Return pretty-printed JSON
            let data = try JSONSerialization.data(withJSONObject: ["observations": _positionalJson, "info": textraInfo], options: .prettyPrinted)
            if let _jsonString = String(data: data, encoding: String.Encoding.utf8) {
                return (_jsonString, combinedFullText)
            } else {
                return nil
            }
        } else {
            return nil
        }
    } catch {
        return nil
    }
}

/**
 Convert a processed image to a text page
 
 - Parameter image: The processed image to conert
 - Parameter pageNum: The page number to convert
 - Parameter inputFile: The convert input which specifies output options
 - Parameter callback: A callback function that is invoked with conversion progress and status
 */
func convertProcessedImage(image: CGImage, pageNum: Int?, inputFile: InputFile, callback: (ConvertResponse) -> Void) async {
    // Extract using new VisionKit API if possible
    if #available(macOS 13.0, *) {
        // Initialize image analyzer
        let configuration = ImageAnalyzer.Configuration([.text])
        let analyzer = ImageAnalyzer()
        
        do {
            // Extract text
            var transcript: String? = nil
            var positionalJson: String? = nil
            // If extracting page text
            if inputFile.shouldExtractFullPageText {
                let analysis = try await analyzer.analyze(image, orientation: .up, configuration: configuration)
                transcript = analysis.transcript
            }
            // If extracting page positions
            if inputFile.shouldExtractPositionalText {
                if let (_positionalJson, _) = extractPositionalTextFromImage(image) {
                    positionalJson = _positionalJson
                } else {
                    callback(.error(message: "Error extracting positional text from page"))
                    return
                }
            }
            callback(.update(pageNum: pageNum, pageText: transcript, pagePositions: positionalJson, progressPushValue: nil))
        } catch {
            callback(.error(message: "Error extracting text from page"))
        }
    } else {
        // Extract text/positions using old Vision API
        // Grab both positional and full text (since it uses the same API; don't want to duplicate work
        if let (_positionalJson, _transcript) = extractPositionalTextFromImage(image) {
            // Only send what's requested
            let transcript: String? = inputFile.shouldExtractFullPageText ? _transcript : nil
            let positionalJson: String? = inputFile.shouldExtractPositionalText ? _positionalJson : nil
            
            callback(.update(pageNum: nil, pageText: transcript, pagePositions: positionalJson, progressPushValue: nil))
        } else {
            callback(.error(message: "Error extracting text from page"))
        }
    }
}

/**
 Convert an image to a text page
 
 - Parameter sourceURL: The URL of the image
 - Parameter inputFile: The convert input which specifies output options
 - Parameter callback: A callback function that is invoked with conversion progress and status
 */
func convertImage(at sourceURL: URL, inputFile: InputFile, callback: (ConvertResponse) -> Void) async {
    if let nsImage = NSImage(contentsOf: sourceURL), let image = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)  {
        // Simply run conversion
        await convertProcessedImage(image: image, pageNum: nil, inputFile: inputFile, callback: callback)
    } else {
        callback(.error(message: "Error opening image for text extraction"))
    }
}

/**
 Converts a PDF to text pages
 
 - Parameter sourceURL: The URL of the PDF document
 - Parameter inputFile: The convert input which specifies output options
 - Parameter dpi: The dpi to scan the document for OCR
 - Parameter callback: A callback function that is invoked with conversion progress and status
 */
func convertPDF(at sourceURL: URL, inputFile: InputFile, dpi: CGFloat = 600, callback: (ConvertResponse) -> Void) async {
    if let pdfDocument = CGPDFDocument(sourceURL as CFURL) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
        
        // Go through each page of the PDF document
        for i in 1...pdfDocument.numberOfPages {
            // Get page
            if let pdfPage = pdfDocument.page(at: i) {
                // Get media box
                let mediaBoxRect = pdfPage.getBoxRect(.mediaBox)
                let scale = dpi / 72.0
                let width = Int(mediaBoxRect.width * scale)
                let height = Int(mediaBoxRect.height * scale)
                
                // Write pdf page to image
                if let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo) {
                    context.interpolationQuality = .high
                    context.setFillColor(.white)
                    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                    context.scaleBy(x: scale, y: scale)
                    context.drawPDFPage(pdfPage)
                    
                    if let image = context.makeImage() {
                        // Run conversion
                        await convertProcessedImage(image: image, pageNum: i, inputFile: inputFile, callback: callback)
                    } else {
                        callback(.error(message: "Error converting page to image"))
                    }
                } else {
                    callback(.error(message: "Error initializing image context"))
                }
            } else {
                callback(.error(message: "Error loading pdf page"))
            }
        }
    } else {
        callback(.error(message: "Error loading pdf document"))
    }
}

/**
 Converts audio to a text page
 
 - Parameter sourceURL: The URL of the audio
 - Parameter inputFile: The convert input which specifies output options
 - Parameter callback: A callback function that is invoked with conversion progress and status
 */
func convertAudio(at sourceURL: URL, inputFile: InputFile, callback: @escaping (ConvertResponse) -> Void) {
    if let recognizer = SFSpeechRecognizer() {
        // Ensure speech recognizer is valid
        if !recognizer.isAvailable {
            callback(.error(message: "Speech recognizer not available"))
            return
        }
        if !recognizer.supportsOnDeviceRecognition {
            callback(.error(message: "Speech recognizer does not support on-device recognition"))
            return
        }
        
        let recognitionRequest = SFSpeechURLRecognitionRequest(url: sourceURL)
        recognitionRequest.requiresOnDeviceRecognition = true
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.addsPunctuation = true
        
        let group = DispatchGroup()
        group.enter()
        
        // Collect a full transcription
        var collectedTranscription: [SFTranscription] = []
        
        // Keep track of the first iteration to print debug output with appropriate escape sequences
        var first = true
        var linesWritten = 0
        var clearSequence = ""
        let shouldPrintPartialText = !inputFile.suppress && isTerminal
        recognizer.recognitionTask(with: recognitionRequest, resultHandler: { (result, error) in
            guard let result = result else {
                callback(.error(message: "Could not recognize speech from audio"))
                group.leave()
                return
            }
            
            if error != nil {
                callback(.error(message: "An error occurred during speech recognition"))
                group.leave()
                return
            }
            
            if shouldPrintPartialText && !first {
                // Clear collected text
                print(clearSequence, terminator: "", to: &standardError)
            }
            first = false
            if shouldPrintPartialText {
                log("\(DIM_START)\(result.bestTranscription.formattedString)\(RESET)")
                // Get the number of lines to move up to reset text
                linesWritten = (result.bestTranscription.formattedString.count - 1) / getTerminalWidth() + 1
                // Change the clear sequence to move up that many lines and erase the terminal from cursor to end
                clearSequence = "\(String(repeating: "\u{001B}[F", count: linesWritten))\u{001B}[0J"
            }
            
            if result.bestTranscription.segments.count > 0 && result.bestTranscription.segments[0].confidence > 0 {
                // End of utterance
                if shouldPrintPartialText && !first {
                    // Clear collected text
                    print(clearSequence, terminator: "", to: &standardError)
                }
                first = true
                
                collectedTranscription.append(result.bestTranscription)
                // Get final transcript of last segment
                if let lastSegment = result.bestTranscription.segments.last {
                    // Push progress
                    callback(.update(pageNum: nil, pageText: result.bestTranscription.formattedString, pagePositions: nil, progressPushValue: result.isFinal ? nil : (lastSegment.timestamp + lastSegment.duration) * AUDIO_DURATION_FACTOR))
                }
            }
            
            
            // Handle final output
            if result.isFinal {
                var segments: [[String: Any]] = []
                for transcription in collectedTranscription {
                    var positionalChunks: [[String: Any]] = []
                    for segment in transcription.segments {
                        positionalChunks.append([
                            "text": segment.substring,
                            "confidence": segment.confidence,
                            "time": segment.timestamp,
                            "duration": segment.duration
                        ])
                    }
                    segments.append(["segment": positionalChunks])
                }
                
                do {
                    // Return pretty-printed JSON
                    let jsonData = try JSONSerialization.data(withJSONObject: ["segments": segments, "info": textraInfo], options: .prettyPrinted)
                    let positionalJson = String(data: jsonData, encoding: String.Encoding.utf8)
                    
                    callback(.update(pageNum: nil, pageText: nil, pagePositions: positionalJson, progressPushValue: nil))
                } catch {
                    callback(.error(message: "An error occurred collecting speech results"))
                }
                
                group.leave()
                return
            }
        })
        group.wait()
    } else {
        callback(.error(message: "Could not set up speech recognizer"))
    }
}

/**
 Handle converting an image, pdf, or audio file
 
 - Parameter convertFile: The file to be converted
 - Parameter inputFile: The convert input which specifies output options
 - Parameter callback: A callback function that is invoked with conversion progress and status
 */
func convertSubFile(_ convertFile: ConvertFile, inputFile: InputFile, callback: @escaping (ConvertResponse) -> Void) async {
    switch convertFile {
        // Handle image conversion
    case .image(let filePath): await convertImage(at: URL(fileURLWithPath: filePath), inputFile: inputFile, callback: callback)
        // Handle PDF conversion
    case .pdf(let filePath): await convertPDF(at: URL(fileURLWithPath: filePath), inputFile: inputFile, callback: callback)
    case .audio(let filePath):
        // Handle audio conversion
        convertAudio(at: URL(fileURLWithPath: filePath), inputFile: inputFile, callback: callback)
    }
}

// MARK: - File manipulation

/**
 Gets the last file component of a path name
 
 - Parameter filePath: The path to the file as a string
 - Returns: The base name of the filepath, before the extension, after the last trailing slash
 */
func baseFilename(filePath: String) -> String {
    return URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
}

/**
 Gets the full file path without an extension
 
 - Parameter filePath: The file path
 - Returns: The file path without an extension
 */
func filenameWithoutExtension(filePath: String) -> String {
    return URL(fileURLWithPath: filePath).deletingPathExtension().relativePath
}

/**
 Returns the lowercase extension of the file at the given file path.
 
 - Parameter filePath: The file path
 - Returns: The lowercase extension of the file at the given file path, or an empty string if the file has no extension
 */
func getLowercaseExtension(filePath: String) -> String {
    let url = URL(fileURLWithPath: filePath)
    let fileExtension = url.pathExtension
    return fileExtension.lowercased()
}

/**
 Adds a string to the path name before the file extension.
 
 - Parameter path: The original file path.
 - Parameter add: The string to be added to the path name before the file extension.
 - Returns: The modified file path with the added string before the file extension.
 */
func addToPath(path: String, add: String) -> String {
    let url = URL(fileURLWithPath: path)
    let base = url.deletingPathExtension().lastPathComponent
    let ext = url.pathExtension
    
    // If the file name doesn't have an extension, just return the
    // concatenation of the base name and the add string.
    if ext.isEmpty {
        return url.deletingLastPathComponent().appending(path: "\(base)\(add)").path(percentEncoded: false)
    } else {
        return url.deletingLastPathComponent().appending(path: "\(base)\(add).\(ext)").path(percentEncoded: false)
    }
}

/**
 Adds a page number or base file name into a pattern
 
 - Parameter filePattern: A file pattern like `page-{}.txt` or `page.txt`
 - Parameter replacement: The page number or base file name to insert
 - Parameter inputFile: The input CLI request
 - Returns: The pattern with page number/base file name added. In both cases in the example `filePattern`, the resulting injection if `replacement` is `1` would be `page-1.txt`
 */
func expandPageInPattern(filePattern: String, replacement: String, inputFile: InputFile) -> String {
    if filePattern.contains("{}") {
        return filePattern.replacingOccurrences(of: "{}", with: replacement)
    } else {
        if inputFile.inputFiles.count == 1 {
            // Special case: only 1, non-multipage file
            if !inputFile.inputFiles[0].isMultipage {
                // We can use file path literally
                return filePattern
            }
        }
        
        // Append page number after base name, before extension
        return addToPath(path: filePattern, add: "-\(replacement)")
    }
}

/**
 Normalize the specified file pattern. If the file pattern does not contain "{}" anywhere, add "-{}" to the base pathname
 
 - Parameter filePattern: The file pattern to normalize
 - Parameter inputFile: The input CLI request
 - Returns: The normalized file pattern
 */
func normalizePattern(_ filePattern: String, inputFile: InputFile) -> String {
    if filePattern.contains("{}") {
        return filePattern
    } else {
        if inputFile.inputFiles.count == 1 {
            // Special case: only 1, non-multipage file
            if !inputFile.inputFiles[0].isMultipage {
                // We can use file path literally
                return filePattern
            }
        }
        
        // Append page number after base name, before extension
        return addToPath(path: filePattern, add: "-{}")
    }
}

/**
 Gets the base file path to use in conversion
 
 - Parameter convertFile: The file to retrieve the base path for
 - Parameter pageNum: The page number of the file (only relevant for PDF)
 - Parameter numMultiPages: The number of multipage files that are getting converted
 - Parameter numSinglePages: The number of single page files that are getting converted
 */
func getPageBasePath(_ convertFile: ConvertFile, pageNum: Int, numMultiPages: Int, numSinglePages: Int) -> String {
    let baseName = baseFilename(filePath: convertFile.filePath)
    
    switch convertFile {
    case .pdf:
        if numMultiPages == 1 && numSinglePages == 0 {
            return "\(pageNum)"
        } else {
            // Multiple multipage docs, or a multipage doc and single page docs
            return "\(baseName)-\(pageNum)"
        }
    case .image:
        return baseName
    case .audio:
        return baseName
    }
}

/**
 Opens the specified file path for writing, creating intermediate directories if needed
 
 - Parameter filePath: The file path to open
 - Returns: A file handle if opening was successful; nil if not
 */
func openFileForWriting(filePath: String) -> FileHandle? {
    // Get the output directory from the file path
    let outputDirectory = (filePath as NSString).deletingLastPathComponent
    
    // Check if the output directory exists, and create it if it doesn't
    if !FileManager.default.fileExists(atPath: outputDirectory) {
        try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
    }
    
    // Check if file exists and create it if it doesn't
    if !FileManager.default.fileExists(atPath: filePath) {
        FileManager.default.createFile(atPath: filePath, contents: nil, attributes: nil)
    } else {
        // Clear it if it does exist
        if !writeText(filePath: filePath, pageText: "") {
            return nil
        }
    }
    
    do {
        return try FileHandle(forWritingTo: URL(fileURLWithPath: filePath))
    } catch {
        return nil
    }
}

/**
 Writes the specified page text to the specified file
 
 - Parameter filePath: The output file path
 - Parameter pageText: The page text to write to the file
 - Returns: Whether the write was successful
 */
func writeText(filePath: String, pageText: String) -> Bool {
    // Get the output directory from the file path
    let outputDirectory = (filePath as NSString).deletingLastPathComponent
    
    // Check if the output directory exists, and create it if it doesn't
    if !FileManager.default.fileExists(atPath: outputDirectory) {
        try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
    }
    
    // Write the page text to the file
    do {
        try pageText.write(toFile: filePath, atomically: true, encoding: .utf8)
        return true
    } catch {
        return false
    }
}

// MARK: - Conversion handlers

/// A colorful, formatted progress bar printer
struct ProgressPrinter: ProgressBarPrinter {
    var lastPrintedTime = 0.0
    
    init() {
        // the cursor is moved up before printing the progress bar.
        // have to move the cursor down one line initially.
        print("", to: &standardError)
    }
    
    mutating func display(_ progressBar: ProgressBar) {
        let currentTime = getTimeOfDay()
        if (currentTime - lastPrintedTime > 0.1 || progressBar.index == progressBar.count) {
            print("\u{1B}[1A\u{1B}[K\(GREEN_START)\(progressBar.value)\(RESET)", to: &standardError)
            lastPrintedTime = currentTime
        }
    }
}

/// A silent progress bar printer that does not print at all
struct SilentProgressPrinter: ProgressBarPrinter {
    mutating func display(_ progressBar: ProgressBar) {}
}

/**
 Runs the full conversion process given the CLI input
 
 - Parameter cliInput: The CLI input
 */
func convert(_ cliInput: CLIInput) async {
    // A local input object we can modify
    var input = cliInput
    
    // Whether to suppress any output or not
    let suppressOutput = input.silent
    
    // Get the total page count for progress bar
    var totalPageCount = 0
    var totalProgressValue = 0.0
    var totalFileCount = 0
    var pageCounts: [Int] = []
    var progressValues: [Double] = []
    var singlePageCounts: [Int] = []
    var multiPageCounts: [Int] = []
    var plan: String = ""
    for (i, inputFile) in input.inputFiles.enumerated() {
        // Set suppress flag
        input.inputFiles[i].suppress = suppressOutput
        
        // Track number of single/multipage items
        var numSinglePageItems = 0
        var numMultiPageItems = 0
        
        // Assemble a text description of an input plan
        var inputPlan: [String] = []
        for convertFile in inputFile.inputFiles {
            if convertFile.isMultipage {
                // Track number of multi page items
                numMultiPageItems += 1
            } else {
                // Track number of single page items
                numSinglePageItems += 1
            }
            
            totalFileCount += 1
            let pageCount = getPageCount(convertFile: convertFile)
            if let _pageCount = pageCount {
                // Sum page count of sub files
                totalPageCount += _pageCount.0
                // Decide to factor in audio correction or not
                let progressValue = _pageCount.0 == 1 && _pageCount.1 != 1 ? _pageCount.1 * AUDIO_DURATION_FACTOR : _pageCount.1
                totalProgressValue += progressValue
                pageCounts.append(_pageCount.0)
                progressValues.append(progressValue)
                
                inputPlan.append("\(_pageCount.0 > 1 ? "(\(_pageCount.0) pg) " : _pageCount.0 == 1 && _pageCount.1 != 1 ? "(\(formatDuration(_pageCount.1))) " : "")\(DIM_START)\(convertFile.filePath)\(RESET)")
            } else {
                // Error opening file to extract pages
                logError(message: "Could not open file \"\(convertFile.filePath)\"; it may be invalid or corrupted.")
                printUsage()
                return
            }
        }
        
        // Assemble an output plan
        var outputPlan: [String] = []
        if inputFile.shouldOutputToStdout {
            outputPlan.append("standard out")
        }
        for outputFullText in inputFile.outputFullText {
            outputPlan.append("full text \(DIM_START)\(outputFullText)\(RESET)")
        }
        for outputPageText in inputFile.outputPageText {
            outputPlan.append("page text \(DIM_START)\(normalizePattern(outputPageText, inputFile: inputFile))\(RESET)")
        }
        for positionText in inputFile.outputPositions {
            outputPlan.append("positional page JSON \(DIM_START)\(normalizePattern(positionText, inputFile: inputFile))\(RESET)")
        }
        
        plan += "\n\(BOLD_START)Converting:\(RESET)\n\(inputPlan.map({"- Input \($0)"}).joined(separator: "\n"))\n"
        plan += "\(outputPlan.map({"- Output \($0)"}).joined(separator: "\n"))\n"
        
        // Update single/multi page counts
        singlePageCounts.append(numSinglePageItems)
        multiPageCounts.append(numMultiPageItems)
    }
    
    if !suppressOutput {
        // Print the conversion plan
        log(plan)
    }
    
    // Set up the progress bar
    let progressPrinter: ProgressBarPrinter = suppressOutput ? SilentProgressPrinter() : ProgressPrinter()
    var progressBar = ProgressBar(count: totalProgressValue, visibleCount: totalPageCount, configuration: nil, printer: progressPrinter)
    // Start the initial print
    progressBar.setValue(index: 0, visibleIndex: 0)
    
    // Keep track of current page offset
    var pageOffset = 0
    var progressOffset = 0.0
    var pageCountIndex = 0
    // Go through each chain of inputs/outputs
    for (inputFileIndex, inputFile) in input.inputFiles.enumerated() {
        // Get number of items with single/multiple pages
        let singlePageCount = singlePageCounts[inputFileIndex]
        let multiPageCount = multiPageCounts[inputFileIndex]
        
        // Gather handles to write output
        var writeHandles: [FileHandle] = []
        if inputFile.shouldOutputToStdout {
            // Use the standard out channel as a write handle
            writeHandles.append(FileHandle.standardOutput)
        }
        for fullTextOutputPath in inputFile.outputFullText {
            // Open a full text output path file handle for writing
            if let _fileHandle = openFileForWriting(filePath: fullTextOutputPath) {
                writeHandles.append(_fileHandle)
            } else {
                // Could not open file
                logError(message: "Could not open file for writing: \"\(fullTextOutputPath)\"")
                printUsage()
                return
            }
        }
        
        // Go through each file that is to be converted
        for convertFile in inputFile.inputFiles {
            var error: String? = nil
            
            await convertSubFile(convertFile, inputFile: inputFile, callback: {(convertResponse: ConvertResponse) in
                switch convertResponse {
                case .error(let message):
                    // Handle error
                    error = message
                case .update(let pageNum, let pageText, let pagePositions, let progressPushValue):
                    // Skip if error
                    if error != nil {
                        break
                    }
                    
                    // Update progress
                    if let _pageNum = pageNum {
                        progressBar.setValue(index: progressOffset + Double(_pageNum), visibleIndex: pageOffset + _pageNum)
                    } else {
                        // Use progress push update explicitly (for audio files)
                        if let _progressValue = progressPushValue {
                            progressBar.setValue(index: progressOffset + _progressValue, visibleIndex: pageOffset)
                        }
                    }
                    
                    // Write any page text needed for stdout/full page text
                    if let _pageText = pageText {
                        for writeHandle in writeHandles {
                            writeHandle.write(_pageText)
                            writeHandle.write("\n\n")
                            do {
                                try writeHandle.synchronize()
                            } catch {
                                logError(message: "Unexpected error writing to file")
                                printUsage()
                                return
                            }
                        }
                    }
                    
                    // Write any page/positional page text needed
                    let pageBasePath = getPageBasePath(convertFile, pageNum: pageNum ?? 0, numMultiPages: multiPageCount, numSinglePages: singlePageCount)
                    
                    // Page text
                    if let _pageText = pageText {
                        for pageTextOutputPath in inputFile.outputPageText {
                            // Expand page text output patterns and write
                            let fullPath = expandPageInPattern(filePattern: pageTextOutputPath, replacement: pageBasePath, inputFile: inputFile)
                            
                            if !writeText(filePath: fullPath, pageText: _pageText) {
                                logError(message: "Unexpected error: failed to write text to file")
                                printUsage()
                                return
                            }
                        }
                    }
                    
                    // Positional page text
                    if let _pagePositions = pagePositions {
                        for positionalTextOutputPath in inputFile.outputPositions {
                            // Expand page text output patterns and write
                            let fullPath = expandPageInPattern(filePattern: positionalTextOutputPath, replacement: pageBasePath, inputFile: inputFile)
                            
                            if !writeText(filePath: fullPath, pageText: _pagePositions) {
                                logError(message: "Unexpected error: failed to write positional text to file")
                                printUsage()
                                return
                            }
                        }
                    }
                }
            })
            
            if let _error = error {
                // Handle error by quitting
                logError(message: _error)
                printUsage()
                return
            }
            
            // Update page count offset
            pageOffset += pageCounts[pageCountIndex]
            progressOffset += progressValues[pageCountIndex]
            pageCountIndex += 1
            progressBar.setValue(index: progressOffset, visibleIndex: pageOffset)
        }
    }
}

// MARK: - Terminal utilities

// Write up std error
var standardError = FileHandle.standardError

extension FileHandle: TextOutputStream {
    public func write(_ string: String) {
        let data = Data(string.utf8)
        self.write(data)
    }
}

/// Whether the program is running in a terminal or not
let isTerminal = isatty(STDOUT_FILENO) == 1 && isatty(STDERR_FILENO) == 1

/// The terminal red format code
let RED_START = isTerminal ? "\u{001B}[0;31m" : ""
/// The terminal green format code
let GREEN_START = isTerminal ? "\u{001B}[32m" : ""
/// The terminal bold format code
let BOLD_START = isTerminal ? "\u{001B}[1m" : ""
/// The terminal dim format code
let DIM_START = isTerminal ? "\u{001B}[2m" : ""
/// The terminal code to reset formatting
let RESET = isTerminal ? "\u{001B}[0m" : ""

/**
 Get the width of the current terminal
 
 - Parameter defaultWidth: The default number of columns if the method fails (80)
 - Returns: The width of the terminal in columns, or the default width if unavailable
 */
func getTerminalWidth(defaultWidth: Int = 80) -> Int {
    var w = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 {
        return Int(w.ws_col)
    }
    
    // Fallback
    return defaultWidth
}

/**
 - Parameter char: A character
 - Returns: Whether the character is a space character that wraps
 */
func isSpace(_ char: Character) -> Bool {
    return char == " "
}


/**
 Converts the specified text to format blocks of spaces and text content that can be used downstream for text wrapping tasks.
 
 - Parameter text: The text to convert to format blocks
 - Returns: The format blocks for downstream text wrapping
 */
func textToFormatBlocks(text: String) -> [(type: String, text: String)] {
    // Build up blocks
    var blocks: [(type: String, text: String)] = []
    if text.isEmpty { return blocks }
    
    // Set up the initial state
    let characters = Array(text)
    var prevBlock = 0
    var i = 0
    var prevEncountered = isSpace(characters[0]) ? "space" : "text"
    
    /// A utility function to flush the currently collected characters to a space or text block
    func flush() {
        let blockText = String(characters[prevBlock..<i])
        if blockText.isEmpty { return }
        blocks.append((type: prevEncountered, text: blockText))
        prevBlock = i
        prevEncountered = prevEncountered == "space" ? "text" : "space"
    }
    
    while i < characters.count {
        // Go through each character
        let c = characters[i]
        if prevEncountered == "text" && isSpace(c) {
            // Push text
            flush()
        } else if prevEncountered == "space" && !isSpace(c) {
            // Push space
            flush()
        }
        i += 1
    }
    flush()
    
    return blocks
}

/**
 A utility function to remove terminal ANSI escape codes from text
 
 - Parameter string: The text to clean
 - Returns: The cleaned text without ANSI escape codes
 */
func removeAnsiEscapeCodes(_ string: String) -> String {
    // Define a regular expression that matches ANSI escape codes
    let pattern = "\u{001B}\\[[\\d;]*[^\\d;]"
    
    // Use the `NSRegularExpression` class to create a regular expression object
    // from the pattern and use it to match all ANSI escape codes in the input string
    let regex = try! NSRegularExpression(pattern: pattern)
    let range = NSRange(string.startIndex..., in: string)
    return regex.stringByReplacingMatches(in: string, range: range, withTemplate: "")
}

/**
 Maps an index into a given string to the appropriate position in the string if counting ANSI escape codes
 
 - Parameter string: The source string, complete with potential ANSI escape codes
 - Parameter index: The index into the source string (ignoring the ANSI escape codes)
 - Returns: The mapped index into the source string that includes the ANSI escape codes
 */
func mapAnsiTextIndex(string: String, index: Int) -> Int {
    var stringIndex = 0
    var escapeCodeStart = -1
    
    for (i, char) in string.enumerated() {
        if escapeCodeStart >= 0 {
            // We are currently inside an ANSI escape code.
            if char == "m" {
                // This is the end of the escape code.
                escapeCodeStart = -1
            }
        } else if char == "\u{001B}" {
            // This is the start of an ANSI escape code.
            escapeCodeStart = i
        }
        
        if i == index {
            // This is the target index.
            return stringIndex
        }
        
        if escapeCodeStart < 0 {
            // We are not currently inside an ANSI escape code, so
            // this character counts towards the string index.
            stringIndex += 1
        }
    }
    
    return stringIndex
}

/**
 Word wraps text to the specified width. ANSI escape codes are ignored in wrapping.
 */
func wordWrap(text: String, width: Int = 80) -> String {
    if width <= 0 { return text }
    // Convert the text to a series of alternating word and space objects
    let blocks = textToFormatBlocks(text: text)
    var newBlocks: [(type: String, text: String)] = []
    
    var linePosition = 0
    var first = true
    for block in blocks {
        if linePosition + removeAnsiEscapeCodes(block.text).count >= width {
            if block.type == "space" {
                // Dealing with a space that puts us over the edge
                // Convert to newline
                newBlocks.append((type: "space", text: "\n"))
                linePosition = 0
            } else {
                // Dealing with text that puts us over the edge
                if linePosition != 0 {
                    // The previous block is a space that we will convert to newline
                    newBlocks[newBlocks.count - 1].text = "\n"
                }
                
                // Add the text block in, word wrapping if needed
                var newBlock = block
                while removeAnsiEscapeCodes(newBlock.text).count >= width {
                    // Add what we can
                    let newIndex = mapAnsiTextIndex(string: newBlock.text, index: width)
                    let index = newBlock.text.index(newBlock.text.startIndex, offsetBy: newIndex)
                    let substring = String(newBlock.text[..<index])
                    newBlocks.append((type: "text", text: substring))
                    // Push a newline
                    newBlocks.append((type: "space", text: "\n"))
                    newBlock.text.removeFirst(width)
                }
                // Push the remaining text normally
                newBlocks.append(newBlock)
                linePosition = removeAnsiEscapeCodes(newBlock.text).count
            }
        } else {
            if block.type == "space" && linePosition == 0 && !first {
                // Skip leading space
            } else {
                newBlocks.append(block)
                linePosition += removeAnsiEscapeCodes(block.text).count
            }
        }
        
        first = false
    }
    
    // Return the collected text
    return newBlocks.map { $0.text }.joined()
}

/**
 Prints text to stderr, wrapping words if they would overflow in the terminal.
 
 - Parameter text: The text to print
 */
func printWrap(_ text: String) {
    print(wordWrap(text: text, width: getTerminalWidth(defaultWidth: 80)), to: &standardError)
}

func log(_ text: String) {
    print(text, to: &standardError)
}

/**
 Logs an error message in the appropriate format
 
 - Parameter message: The error message
 */
func logError(message: String) {
    printWrap("\(RED_START)ERROR: \(message)\(RESET)\n")
}

/**
 Prints the usage instructions for the application
 */
func printUsage(advanced: Bool = false) {
    printWrap("\n\(BOLD_START)textra\(RESET) is a command-line application to convert images, PDF files of images, and audio files to text using Apple's APIs.\(RESET)\n")
    printWrap("\(GREEN_START)\(BOLD_START)Usage:\(RESET) \(BOLD_START)textra [options] FILE1 [FILE2...] [outputOptions]\(RESET)\n")
    printWrap("\(GREEN_START)\(BOLD_START)Options:\(RESET)")
    printWrap("  \(BOLD_START)-h\(RESET), \(BOLD_START)--help\(RESET)             Show advanced help")
    printWrap("  \(BOLD_START)-s\(RESET), \(BOLD_START)--silent\(RESET)           Suppress non-essential output")
    if advanced {
        printWrap("  \(BOLD_START)-v\(RESET), \(BOLD_START)--version\(RESET)          Show version number")
    }
    printWrap("\(GREEN_START)\(BOLD_START)Output options:\(RESET)")
    printWrap("  \(BOLD_START)-x\(RESET), \(BOLD_START)--outputStdout\(RESET)     Output everything to stdout (default)")
    printWrap("  \(BOLD_START)-o\(RESET), \(BOLD_START)--outputText\(RESET)       Output everything to a single text file")
    printWrap("  \(BOLD_START)-t\(RESET), \(BOLD_START)--outputPageText\(RESET)   Output each file/page to a text file")
    printWrap("  \(BOLD_START)-p\(RESET), \(BOLD_START)--outputPositions\(RESET)  Output positional text for each file/page to json (experimental; results may differ from page text)\n")
    printWrap("\(GREEN_START)\(BOLD_START)Examples:\(RESET)")
    printWrap("  \(BOLD_START)textra\(RESET) image.png")
    printWrap("  \(BOLD_START)textra\(RESET) page1.png page2.png \(BOLD_START)-o\(RESET) combined.txt")
    printWrap("  \(BOLD_START)textra\(RESET) doc.pdf \(BOLD_START)-o\(RESET) doc.txt \(BOLD_START)-t\(RESET) doc/page-{}.txt\(advanced ? "" : "\n")")
    if advanced {
        printWrap("  \(BOLD_START)textra\(RESET) image1.png \(BOLD_START)-o\(RESET) text1.txt image2.png \(BOLD_START)-o\(RESET) text2.txt")
        printWrap("  \(BOLD_START)textra\(RESET) image.png \(BOLD_START)--outputPositions\(RESET) positionalText.json\n")
        printWrap("\(GREEN_START)\(BOLD_START)Instructions:\(RESET)")
        printWrap("To use \(BOLD_START)textra\(RESET), you must provide at least one input file.\n")
        printWrap("\(BOLD_START)textra\(RESET) will then extract all the text from the inputted image/PDF/audio files. By default, \(BOLD_START)textra\(RESET) will print the output to stdout, where it can be viewed or piped into another program.\n")
        printWrap("You can use the output options above at any point to extract the specified files to disk in various formats. For instance, \"textra doc.png -o page.txt -p page.json\" will extract \"doc.png\" in two formats: as page text to \"page.txt\" and as positional text to \"page.json\".\n")
        printWrap("You can punctuate chains of inputs with output options to finely control where multiple extracted documents will end up. For example, \"textra doc.png -o image.txt speech.mp3 -o audio.txt\" will extract \"doc.png\" to \"image.txt\" and \"speech.mp3\" to \"audio.txt\" respectively.\n")
        printWrap("For output options that write to each page (\(BOLD_START)-t, -p\(RESET)), \(BOLD_START)textra\(RESET) allows an output path that contains curly braces \(BOLD_START){}\(RESET). These braces will be substituted with page numbers in the case of a PDF file, base file names in the case of image files, or \(BOLD_START)baseFileName-pageNumber\(RESET) in the case of multiple PDF files. Without specifying the braces, \(BOLD_START)textra\(RESET) will append a dash followed by the page number/base file name to the specified path.\n")
    } else {
        printWrap("Type \(BOLD_START)textra -h\(RESET) for more detailed help and advanced options.\n")
    }
}

/**
 Converts the specified path to a convert file
 
 - Parameter path: The path to wrap
 - Returns: The corresponding ConvertFile object, or nil if the format is unsupported
 */
func filePathToConvertFile(_ path: String) -> ConvertFile? {
    let fileExt = getLowercaseExtension(filePath: path)
    let optionalUti = UTType(filenameExtension: fileExt)
    if let uti = optionalUti {
        // Check the UT type conformity to get file type
        if uti.conforms(to: .pdf) {
            return .pdf(filePath: path)
        } else if uti.conforms(to: .image) {
            return .image(filePath: path)
        } else if uti.conforms(to: .audio) || uti.conforms(to: .audiovisualContent) {
            return .audio(filePath: path)
        }
    }
    return nil
}

/**
 The main function for the CLI
 
 - Parameter args: The command-line args (ignoring the program name first arg)
 */
func main(args: [String]) async {
    if args.count == 0 {
        // Must specify args
        printUsage()
        return
    }
    
    // Iterate through each arg and build up a CLI input
    var input = CLIInput()
    
    var i = 0
    while i < args.count {
        switch args[i] {
        case "-h", "--help":
            input.help = true
        case "-v", "--version":
            input.version = true
        case "-s", "--silent":
            input.silent = true
        case "-x", "--outputStdout":
            if input.inputFiles.last != nil {
                input.inputFiles[input.inputFiles.count - 1].outputStdout = true
            } else {
                logError(message: "Must specify input files before output options")
                printUsage()
                return
            }
        case "-o", "--outputText":
            i += 1
            if i < args.count {
                if input.inputFiles.last != nil {
                    input.inputFiles[input.inputFiles.count - 1].outputFullText.append(args[i])
                } else {
                    logError(message: "Must specify input files before output options")
                    printUsage()
                    return
                }
            } else {
                logError(message: "Must specify an output file after \(BOLD_START)\(args[i - 1])\(RESET)")
                printUsage()
                return
            }
        case "-t", "--outputPageText":
            i += 1
            if i < args.count {
                if input.inputFiles.last != nil {
                    input.inputFiles[input.inputFiles.count - 1].outputPageText.append(args[i])
                } else {
                    logError(message: "Must specify input files before output options")
                    printUsage()
                    return
                }
            } else {
                logError(message: "Must specify an output file after \(BOLD_START)\(args[i - 1])\(RESET)")
                printUsage()
                return
            }
        case "-p", "--outputPositions":
            i += 1
            if i < args.count {
                if input.inputFiles.last != nil {
                    input.inputFiles[input.inputFiles.count - 1].outputPositions.append(args[i])
                } else {
                    logError(message: "Must specify input files before output options")
                    printUsage()
                    return
                }
            } else {
                logError(message: "Must specify an output file after \(BOLD_START)\(args[i - 1])\(RESET)")
                printUsage()
                return
            }
        default:
            if args[i].starts(with: "-") {
                logError(message: "Invalid argument specified: \(BOLD_START)\(args[i])\(RESET)")
                printUsage()
                return
            } else {
                // Collect input files
                var inputFile = InputFile()
                while i < args.count && !args[i].starts(with: "-") {
                    let convertFile = filePathToConvertFile(args[i])
                    if let file = convertFile {
                        inputFile.inputFiles.append(file)
                    } else {
                        logError(message: "Invalid file specified \"\(args[i])\". This file type is not supported.")
                    }
                    i += 1
                }
                i -= 1
                input.inputFiles.append(inputFile)
            }
        }
        i += 1
    }
    
    if input.help {
        if args.count > 1 {
            logError(message: "No other arguments should be specified with \(BOLD_START)-h/--help\(RESET)")
        }
        
        // Show advanced help and exit
        printUsage(advanced: true)
        return
    }
    if input.version {
        if args.count > 1 {
            logError(message: "No other arguments should be specified with \(BOLD_START)-v/--version\(RESET)")
        }
        
        // Show version number and exit
        printWrap(VERSION)
        return
    }
    
    // Ensure there are input files
    if input.inputFiles.count == 0 {
        // Show help and exit
        printUsage()
        return
    }
    
    await convert(input)
}

await main(args: Array(CommandLine.arguments[1...]))
