# textra

A command-line application to convert images and PDF files of images to text using Apple's Vision text recognition API.

![A terminal window showing the text: | % textra ~/The-Mueller-Report.pdf | Converting the specified PDF file and outputting text at the directory "~/The-Mueller-Report" | 16 of 448 [-      ] ETA: 00:05:21 (at 1.34 it/s)](https://user-images.githubusercontent.com/306095/205505079-e0371055-29dc-4913-97e4-a57782bb4a5c.png)

## Installation

Textra requires Mac OS version 13 or greater to access the latest Vision APIs.

The easiest way to install `textra` is to open a terminal window and run the following command:

```sh
curl -L https://github.com/freedmand/textra/raw/main/install.sh | bash
```

Alternatively, download the latest [release](https://github.com/freedmand/textra/releases), unzip it, and place the `textra` executable somewhere on your `$PATH` variable.

## Usage

```sh
textra FILE1 [FILE2...]
```

### Arguments

`FILE1 [FILE2...]`: One or more files to be converted. If multiple files are provided, the last file must be the output directory or a pattern containing an output path.

### Examples

```sh
textra image.png
textra image1.png image2.png output-dir/
textra document.pdf
textra document.pdf output-dir/
textra document.pdf page-{}.txt
```
