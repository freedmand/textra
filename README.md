# textra

A command-line application to convert images and PDF files of images to text using Apple's Vision text recognition API.

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
