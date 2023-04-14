# textra

A command-line application to extract text from images, PDFs, and audio files using Apple's Vision and Speech APIs.

![A terminal window showing the text: | % textra The-Mueller-Report.pdf -o report.txt | Converting: | - Input (448 pg) The-Mueller-Report.pdf | - Output full text report.txt | | 16 of 448 [-      ] ETA: 00:05:21 (at 1.34 it/s)](https://user-images.githubusercontent.com/306095/208481023-dded4395-5969-4401-ad08-b625eadd33bf.png)

## Installation

Textra requires Mac OS version 13 or greater to access the latest VisionKit APIs.

The easiest way to install `textra` is to open a terminal window and run the following command:

```sh
curl -L https://github.com/freedmand/textra/raw/main/install.sh | bash
```

Alternatively, download the latest [release](https://github.com/freedmand/textra/releases), unzip it, and place the `textra` executable somewhere on your `$PATH`.

## Usage

```sh
textra [options] FILE1 [FILE2...] [outputOptions]
```

### Options

**`-h`, `--help`**: Show advanced help

**`-s`, `--silent`**: Suppress non-essential output

**`-l`, `--locale`**: Specify a [locale](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPInternational/LanguageandLocaleIDs/LanguageandLocaleIDs.html) (e.g. en-US) for text recognition

**`-v`, `--version`**: Show version number

### Output options

**`-x`, `--outputStdout`**: Output everything to stdout (default)

**`-o`, `--outputText`**: Output everything to a single text file

**`-t`, `--outputPageText`**: Output each file/page to a text file

**`-p`, `--outputPositions`**: Output positional text for each file/page to json (experimental; results may differ from page text)

### Examples

`textra audio.mp3`: Extract the text from "audio.mp3" and output to stdout

`textra page1.png page2.png -o combined.txt`: Extract the text from "page1.png" and "page2.png" and output the combined text to "combined.txt"

`textra doc.pdf -o doc.txt -t doc/page-{}.txt`: Extract text from "doc.pdf" and output in two formats: 1) combined text of all the pages stored in "doc.txt" and 2) positional text from each page extracted at the pattern "doc/page-{}.txt" (e.g. "doc/page-1.txt", "doc/page-2.txt", etc.)

`textra image1.png -o text1.txt image2.png -o text2.txt`: Extract text from "image1.png" and output at "text1.txt"; extract text from "image2.png" and output at "text2.txt"

`textra image.png --outputPositions positionalText.json`: Extract positional text from "image.png" and output at "positionalText.json"

### Instructions

To use `textra`, you must provide at least one input file.

`textra` will then extract all the text from the inputted image/PDF/audio files. By default,
`textra` will print the output to stdout, where it can be viewed or piped into another
program.

You can use the output options above at any point to extract the specified files to disk in
various formats. For instance, `textra doc.png -o page.txt -p page.json` will extract
"doc.png" in two formats: as page text to "page.txt" and as positional text to "page.json".

You can punctuate chains of inputs with output options to finely control where multiple
extracted documents will end up. For example, `textra doc.png -o image.txt speech.mp3 -o
audio.txt` will extract "doc.png" to "image.txt" and "speech.mp3" to "audio.txt"
respectively.

For output options that write to each page (`-t`, `-p`), `textra` allows an output path that
contains curly braces `{}`. These braces will be substituted with page numbers in the case of a
PDF file, base file names in the case of image files, or `baseFileName-pageNumber` in the case
of multiple PDF files. Without specifying the braces, textra will append a dash followed by
the page number/base file name to the specified path.

## Troubleshooting

- **`ERROR: Speech recognizer does not support on-device recognition`**:

  If you get this error, you may need dictation enabled, which you can accomplish in **System Settings** -> **Keyboard** -> **Dictation** -> **Enable dictation**.

  Flipping the dictation setting may not immediately fix the error. If `textra` still provides this error or if you cannot toggle the setting, try clicking the "Edit" menu item from the top menu bar when you're in an application (e.g. Terminal) and clicking "Start dictation." This may prompt you to enable "Dictation" again, and a microphone prompt may appear (which you can immediately dismiss by clicking "Done").

  Try `textra` again. If it does work, you may safely disable dictation at any time in the system settings. If it does not, please file an issue.

## License

MIT

## Contributions

This repo is in early stages but contributions are welcome. Please submit an issue or feel free to fork and contribute a pull request.

## Credits

Many thanks to [Brandon Roberts](https://journa.host/@bxroberts) and [Marcos Huerta](https://vmst.io/@marcoshuerta) for their help and encouragement with positional text extraction.
