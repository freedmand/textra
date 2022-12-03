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

// MARK: - Types

/// An input to the convert script
enum ConvertInput {
    /// A PDF to convert to text
    case pdf(filePath: String)
    /// Images to convert to text
    case images(filePaths: Array<String>)
}

/// A file that is being converted
enum ConvertFile {
    /// A PDF file with a path
    case pdf(filePath: String)
    /// An image (PNG, JPG, etc.) file with a path
    case image(filePath: String)
}

/// An output to the convert script
enum ConvertOutput {
    /// A directory in which to store converted text files (name inferred)
    case directory(directoryPath: String)
    /// A template file path at which to write converted page texts
    case path(filePattern: String)
}

/// An input and output to the convert script
struct ConvertRequest {
    /// The input to the convert script
    var input: ConvertInput
    /// The output to the convert script
    var output: ConvertOutput
}

/// An update with conversion progress and status
enum ConvertResponse {
    /// An update with page number and text
    case update(pageNum: Int?, pageText: String)
    /// An error encountered in conversion
    case error(message: String)
}

// MARK: - Conversion functions

/**
 Convert an image to a text page
 
 - Parameter sourceURL: The URL of the image
 - Parameter callback: A callback function that is invoked with conversion progress and status
 */
func convertImage(at sourceURL: URL, callback: (ConvertResponse) -> Void) async {
    if #available(macOS 13.0, *) {
        // Initialize image analyzer
        let configuration = ImageAnalyzer.Configuration([.text])
        let analyzer = ImageAnalyzer()
        
        do {
            // Extract text
            let analysis = try await analyzer.analyze(imageAt: sourceURL, orientation: .up, configuration: configuration)
            callback(.update(pageNum: nil, pageText: analysis.transcript))
        } catch {
            callback(.error(message: "Error extracting text from page"))
        }
    } else {
        // Not supported on earlier MacOS versions
        callback(.error(message: "MacOS version not supported. Please upgrade to MacOS 13.0"))
    }
}

/**
 Converts a PDF to text pages
 
 - Parameter sourceURL: The URL of the PDF document
 - Parameter dpi: The dpi to scan the document for OCR
 - Parameter callback: A callback function that is invoked with conversion progress and status
 */
func convertPDF(at sourceURL: URL, dpi: CGFloat = 600, callback: (ConvertResponse) -> Void) async {
    if #available(macOS 13.0, *) {
        // Initialize image analyzer
        let configuration = ImageAnalyzer.Configuration([.text])
        let analyzer = ImageAnalyzer()
        
        let pdfDocument = CGPDFDocument(sourceURL as CFURL)!
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
        
        // Go through each page of the PDF document
        for i in Progress(1...pdfDocument.numberOfPages) {
            // Get page
            let pdfPage = pdfDocument.page(at: i)!
            
            // Get media box
            let mediaBoxRect = pdfPage.getBoxRect(.mediaBox)
            let scale = dpi / 72.0
            let width = Int(mediaBoxRect.width * scale)
            let height = Int(mediaBoxRect.height * scale)
            
            // Write pdf page to image
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo)!
            context.interpolationQuality = .high
            context.setFillColor(.white)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            context.drawPDFPage(pdfPage)
            
            let image = context.makeImage()!
            
            do {
                // Extract text
                let analysis = try await analyzer.analyze(image, orientation: .up, configuration: configuration)
                callback(.update(pageNum: i, pageText: analysis.transcript))
            } catch {
                callback(.error(message: "Error extracting text from page \(i)"))
            }
        }
    } else {
        // Not supported on earlier MacOS versions
        callback(.error(message: "MacOS version not supported. Please upgrade to MacOS 13.0"))
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
        return "\(base)\(add)"
    } else {
        return "\(base)\(add).\(ext)"
    }
}

/**
 Adds a page number into a pattern
 
 - Parameter filePattern: A file pattern like `page-{}.txt` or `page.txt`
 - Parameter pageNum: The page number
 - Returns: The pattern with page number added. In both cases in the example `filePattern`, the resulting injection if `pageNum` is `1` would be `page-1.txt`
 */
func expandPageInPattern(filePattern: String, pageNum: Int) -> String {
    if filePattern.contains("{}") {
        return filePattern.replacingOccurrences(of: "{}", with: "\(pageNum)")
    } else {
        // Append page number after base name, before extension
        return addToPath(path: filePattern, add: "-\(pageNum)")
    }
}

/**
 Gets the appropriate output file path given an input convert file, a convert output file, an optional page number
 
 - Parameter convertFile: The input file to convert (an image or PDF)
 - Parameter output: The output file specification
 - Parameter pageNum: An optional page number
 - Returns: The desired output file path given all those parameters
 */
func getFilePath(convertFile: ConvertFile, output: ConvertOutput, pageNum: Int?) -> String {
    switch output {
    case .directory(let directoryPath):
        // Handle directory file path
        switch convertFile {
        case .pdf(let filePath):
            if let _pageNum = pageNum {
                // In a PDF with directory, output as directory/{page}.txt
                
                return NSString.path(withComponents: [directoryPath, "\(_pageNum).txt"])
            } else {
                // If for an unknown reason page number is not extracted, output directory/pdfName.txt
                return NSString.path(withComponents: [directoryPath, "\(baseFilename(filePath: filePath)).txt"])
            }
        case .image(let filePath):
            // If just an image, output directory/imageName.txt
            return NSString.path(withComponents: [directoryPath, "\(baseFilename(filePath: filePath)).txt"])
        }
    case .path(let filePattern):
        // Handle file pattern
        switch convertFile {
        case .pdf:
            if let _pageNum = pageNum {
                // In a PDF with page number, examine the pattern
                // page-{}.txt -> page-1.txt, page-2.txt, ...
                // page.txt -> page-1.txt, page-2.txt, ...
                return expandPageInPattern(filePattern: filePattern, pageNum: _pageNum)
            } else {
                // If for an unknown reason page number is not extracted, output the pattern
                return filePattern
            }
        case .image:
            // Just return the file to write to
            return filePattern
        }
    }
}

/**
 Converts a file path alone to a convert input
 
 - Parameter filePath: The input file path
 - Returns: A convert input, which is a PDF if that extension is detected, otherwise an image
 */
func pathToConvertInput(filePath: String) -> ConvertInput {
    if getLowercaseExtension(filePath: filePath) == "pdf" {
        return .pdf(filePath: filePath)
    } else {
        return .images(filePaths: [filePath])
    }
}

/**
 Writes the specified page text to the specified file
 
 - Parameter filePath: The output file path
 - Parameter pageText: The page text to write to the file
 */
func writeText(filePath: String, pageText: String) {
    // Get the output directory from the file path
    let outputDirectory = (filePath as NSString).deletingLastPathComponent
    
    // Check if the output directory exists, and create it if it doesn't
    if !FileManager.default.fileExists(atPath: outputDirectory) {
        try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
    }
    
    // Write the page text to the file
    do {
        try pageText.write(toFile: filePath, atomically: true, encoding: .utf8)
    } catch {
        print("Failed to write text to file: \(error)")
    }
}

// MARK: - Conversion handlers

func validateConvertRequest(convertRequest: ConvertRequest) -> Bool {
    switch (convertRequest.input, convertRequest.output) {
    case (.images(let filePaths), .path):
        if filePaths.count > 1 {
            logError(message: "If specifying multiple images, output must be a directory")
            printUsage()
            return false
        }
    case (.pdf, .path(let filePattern)):
        if !filePattern.contains("{}") {
            logError(message: "If converting a PDF, output must contain a pattern with \"{}\" which will get replaced with page number")
            printUsage()
            return false
        }
    default:
        return true
    }
    // Fallback
    return true
}

/**
 Run OCR and convert images/PDFs to text
 
 - Parameter convertRequest: The convert request defining the task
 */
func convert(convertRequest: ConvertRequest) async {
    // Validate the convert request
    if !validateConvertRequest(convertRequest: convertRequest) {
        return
    }
    
    // Print the convert request
    printConvertRequest(convertRequest: convertRequest)
    
    switch convertRequest.input {
    case .pdf(let filePath):
        await convertPDF(at: URL(fileURLWithPath: filePath), callback: {(convertResponse: ConvertResponse) in
            handleConvertResponse(convertFile: .pdf(filePath: filePath) , output: convertRequest.output, convertResponse: convertResponse)
        })
    case .images(let filePaths):
        for filePath in Progress(filePaths) {
            await convertImage(at: URL(fileURLWithPath: filePath), callback: {(convertResponse: ConvertResponse) in
                handleConvertResponse(convertFile: .image(filePath: filePath), output: convertRequest.output, convertResponse: convertResponse)
            })}
    }
}

/**
 Fully handle a convert update, writing page text and logging error messages if needed.
 
 - Parameter convertFile: The convert file from the update
 - Parameter output: The convert output
 - Parameter convertResponse: The response from page conversion
 */
func handleConvertResponse(convertFile: ConvertFile, output: ConvertOutput, convertResponse: ConvertResponse) {
    switch convertResponse {
    case .update(let pageNum, let pageText):
        // Write the page text
        writeText(filePath: getFilePath(convertFile: convertFile, output: output, pageNum: pageNum), pageText: pageText)
    case .error(let message):
        // Log an error
        logError(message: message)
    }
}

// MARK: - Terminal utilities

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
 Logs an error message in the appropriate format
 
 - Parameter message: The error message
 */
func logError(message: String) {
    print("\u{001B}[0;31mERROR: \(message)\u{001B}[0m\n")
}

/**
 Logs a convert request in human-readable form
 
 - Parameter convertRequest: The convert request to log
 */
func printConvertRequest(convertRequest: ConvertRequest) {
    // Build up an input phrase
    var input = ""
    switch convertRequest.input {
    case .pdf:
        input = "PDF file"
    case .images(let filePaths):
        if filePaths.count == 1 {
            input = "image file"
        } else {
            input = "image files"
        }
    }
    
    // Build up an output phrase
    var output = ""
    switch convertRequest.output {
    case .directory(let directoryPath):
        output = "directory \"\(directoryPath)\""
    case .path(let filePattern):
        output = "path \(filePattern)"
    }
    
    print("\u{001B}[32mConverting the specified \(input) and outputting text at the \(output)\u{001B}[0m")
}

/**
 Prints the usage instructions for the application
 */
func printUsage() {
    print("\u{001B}[32mUsage:\u{001B}[0m \u{001B}[1mtextra\u{001B}[0m FILE1 [FILE2...]\n")
    print("\u{001B}[1mtextra\u{001B}[0m is a command-line application to convert images and PDF files of images to text using Apple's Vision text recognition API.\n")
    print("\u{001B}[32mArguments:\u{001B}[0m")
    print(" \u{001B}[1mFILE1 [FILE2...]\u{001B}[0m One or more files to be converted.\n")
    print("If multiple files are provided, the last file must be the output directory or a pattern containing an output path.\n")
    print("\u{001B}[32mExamples:\u{001B}[0m")
    print("- \u{001B}[1mtextra\u{001B}[0m image.png")
    print("- \u{001B}[1mtextra\u{001B}[0m image1.png image2.png output-dir/")
    print("- \u{001B}[1mtextra\u{001B}[0m document.pdf")
    print("- \u{001B}[1mtextra\u{001B}[0m document.pdf output-dir/")
    print("- \u{001B}[1mtextra\u{001B}[0m document.pdf page-{}.txt")
}

func main(args: [String]) async {
    if args.count == 0 {
        // Must specify args
        printUsage()
        return
    } else if args.count == 1 {
        let inputPath = args[0]
        let input = pathToConvertInput(filePath: inputPath)
        
        // Derive the output path from the input path
        let output: ConvertOutput
        switch input {
        case .pdf:
            // PDF input results in output directory
            output = .directory(directoryPath: filenameWithoutExtension(filePath: inputPath))
        case .images:
            // Single image input results in single txt file output
            output = .path(filePattern: "\(filenameWithoutExtension(filePath: inputPath)).txt")
        }
        
        // Run conversion
        await convert(convertRequest: .init(input: input, output: output))
    } else {
        let potentialOutput = args.last!
        let files = args.dropLast()
                
        let input: ConvertInput
        
        // Determine if files is a single pdf or collection of images
        if files.allSatisfy({
            let ext = getLowercaseExtension(filePath: $0)
            return ext != "pdf" && ext != ""
        }) {
            // All image files
            input = .images(filePaths: Array(files))
        } else if files.count == 1 && getLowercaseExtension(filePath: files[0]) == "pdf" {
            // PDF file
            input = .pdf(filePath: files[0])
        } else {
            logError(message: "Input files (\(files)) must all be images or be a single PDF")
            printUsage()
            return
        }
        
        // Ensure it's either a directory or txt file
        let potentialOutputExt = getLowercaseExtension(filePath: potentialOutput)
        if potentialOutputExt == "" {
            // Run conversion with directory
            await convert(convertRequest: .init(input: input, output: .directory(directoryPath: potentialOutput)))
        } else if potentialOutputExt == "txt" {
            // Run conversion with text output pattern
            await convert(convertRequest: .init(input: input, output: .path(filePattern: potentialOutput)))
        } else {
            // Invalid
            logError(message: "Output file (last file specified) must be a directory or .txt file")
            printUsage()
            return
        }
    }
}

await main(args: Array(CommandLine.arguments[1...]))
