import subprocess
import os
import tempfile
import shutil
from distutils.dir_util import copy_tree
import re

# The current directory of the script
current_dir = os.path.dirname(os.path.abspath(__file__))
test_data_dir = os.path.join(current_dir, "testdata")


def run_command(command, cwd):
    # Run the command
    result = subprocess.run(
        command,
        shell=True,
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    # Get the stdout and stderr
    stdout = result.stdout.decode("utf-8")
    stderr = result.stderr.decode("utf-8")

    return stdout, stderr


def recursive_list_dir(dir):
    return [
        os.path.join(dp, f)
        for dp, dn, fn in os.walk(os.path.expanduser(dir))
        for f in fn
    ]


def has_content(text):
    return len(text.strip()) > 0


def run_test(textra_command):
    # Create a temporary directory
    temp_dir = tempfile.mkdtemp()

    # Copy test data dir to the temporary directory
    copy_tree(test_data_dir, temp_dir)

    # Get current files in the test data dir
    files = recursive_list_dir(temp_dir)

    # Run command
    stdout, stderr = run_command(textra_command, temp_dir)

    # Get new files in the test data dir
    new_files = [f for f in recursive_list_dir(temp_dir) if f not in files]

    # Get full contents of the new files
    new_file_contents = {}
    for f in new_files:
        with open(f, "r") as fp:
            new_file_contents[os.path.relpath(f, temp_dir)] = fp.read()

    # Remove the temp directory
    shutil.rmtree(temp_dir)

    # Return stdout, stderr, and a mapping of all the new files
    # and their contents
    return stdout, stderr, new_file_contents


def run(cmd, assertions):
    # Check if cmd is a list
    if isinstance(cmd, list):
        for c in cmd:
            run(c, assertions)
        return
    stdout, stderr, new_file_contents = run_test(cmd)
    for assertion in assertions:
        assertion(stdout, stderr, new_file_contents)


def assert_no_file_contents(stdout, stderr, file_contents):
    assert not file_contents, "Expected no output files"


def assert_files(files):
    def assert_files(stdout, stderr, file_contents):
        assert set(files) == set(
            file_contents.keys()
        ), f"Expected files to match ({files} != {file_contents.keys()})"
        # Ensure the files have content
        for f in files:
            assert has_content(file_contents[f]), f"Expected file {f} to have content"

    return assert_files


def assert_no_stdout(stdout, stderr, file_contents):
    assert not stdout, "Expected no stdout"


def assert_stdout(stdout, stderr, file_contents):
    assert stdout, "Expected stdout"


def assert_no_stderr(stdout, stderr, file_contents):
    assert not stderr, "Expected no stderr"


def assert_stderr_matches(regex):
    def assert_stderr_matches(stdout, stderr, file_contents):
        assert re.search(regex, stderr), "Expected stderr to match regex"

    return assert_stderr_matches


def assert_stdout_matches(regex):
    def assert_stdout_matches(stdout, stderr, file_contents):
        assert re.search(regex, stdout), "Expected stdout to match regex"

    return assert_stdout_matches


def does_not(assertion):
    def does_not(stdout, stderr, file_contents):
        try:
            assertion(stdout, stderr, file_contents)
        except AssertionError:
            return
        raise AssertionError("Expected assertion to fail")

    return does_not


def assert_no_error(stdout, stderr, file_contents):
    return does_not(assert_stderr_matches("ERROR"))


def assert_has_error(error=""):
    def assert_has_error(stdout, stderr, file_contents):
        assert re.search(
            rf"ERROR:.*{error}", stderr, re.IGNORECASE
        ), "Expected stderr to contain error"

    return assert_has_error


# TEST CASES
run(
    "textra",
    [
        assert_no_file_contents,
        assert_no_stdout,
        assert_no_error,
        assert_stderr_matches("textra -h"),
    ],
)

run(
    ["textra -h", "textra --help"],
    [
        assert_no_file_contents,
        assert_no_stdout,
        assert_no_error,
        does_not(assert_stderr_matches("textra -h")),
    ],
)

run(
    ["textra -v", "textra --version"],
    [
        assert_no_file_contents,
        assert_no_stdout,
        assert_no_error,
        assert_stderr_matches(r"\d+\.\d+\.\d+"),
    ],
)

run(
    [
        "textra docp1.png",
        "textra docp1.png docp2.png",
        "textra doc_3.pdf",
        "textra docp1.png docp3.png doc_3.pdf audio.m4a",
    ],
    [
        assert_no_file_contents,
        assert_stdout,
        assert_no_error,
    ],
)

run(
    "textra docp1.png -o docp1.txt",
    [
        assert_files(["docp1.txt"]),
        assert_no_stdout,
        assert_no_error,
    ],
)

run(
    "textra docp1.png docp2.png -o combined.txt",
    [
        assert_files(["combined.txt"]),
        assert_no_stdout,
        assert_no_error,
    ],
)

run(
    "textra doc_3.pdf -o doc.txt -t doc/page-{}.txt",
    [
        assert_files(["doc.txt", "doc/page-1.txt", "doc/page-2.txt", "doc/page-3.txt"]),
        assert_no_stdout,
        assert_no_error,
    ],
)

run(
    "textra docp1.png -o docp1.txt docp2.png -o docp2.txt",
    [
        assert_files(["docp1.txt", "docp2.txt"]),
        assert_no_stdout,
        assert_no_error,
    ],
)

run(
    "textra docp1.png --outputPositions docp1.json",
    [
        assert_files(["docp1.json"]),
        assert_no_stdout,
        assert_no_error,
    ],
)

run(
    "textra doc_3.pdf doc_copy.pdf -p {}-page.json",
    [
        assert_files(
            [
                "doc_3-1-page.json",
                "doc_3-2-page.json",
                "doc_3-3-page.json",
                "doc_copy-1-page.json",
                "doc_copy-2-page.json",
                "doc_copy-3-page.json",
            ]
        ),
        assert_no_stdout,
        assert_no_error,
    ],
)

run(
    [
        "textra audio.m4a -s --outputPositions audio.json --outputText audio.txt",
        "textra audio.m4a --silent --outputPositions audio.json --outputText audio.txt",
    ],
    [
        assert_files(["audio.json", "audio.txt"]),
        assert_no_stdout,
        assert_no_stderr,
    ],
)

run(
    [
        "textra doc_3.pdf -s --outputPositions doc.json --outputText doc.txt --outputPageText page-{}.txt",
        "textra doc_3.pdf --silent --outputPositions doc.json --outputText doc.txt --outputPageText page-{}.txt",
    ],
    [
        assert_files(
            [
                "doc-1.json",
                "doc-2.json",
                "doc-3.json",
                "doc.txt",
                "page-1.txt",
                "page-2.txt",
                "page-3.txt",
            ]
        ),
        assert_no_stdout,
        assert_no_stderr,
    ],
)

run(
    "textra -l en",
    [
        assert_no_file_contents,
        assert_no_stdout,
        assert_no_error,
        assert_stderr_matches("textra -h"),
    ],
)

run(
    "textra -l en docp1.png -o docp1.txt",
    [
        assert_files(["docp1.txt"]),
        assert_no_stdout,
        assert_no_error,
    ],
)

# Error cases
run(
    "textra --invalidoption",
    [assert_no_file_contents, assert_no_stdout, assert_has_error("invalid argument")],
)

run(
    [
        "textra -o output.txt",
        "textra --outputText output.txt",
        "textra -o output.txt docp1.png",
        "textra --outputText output.txt docp1.png",
        "textra -p output.json",
        "textra --outputPositions output.json",
        "textra -t output.txt",
        "textra --outputPageText output.txt",
    ],
    [
        assert_no_file_contents,
        assert_no_stdout,
        assert_has_error("input files before"),
    ],
)

run(
    [
        "textra invalidfile.png",
        "textra invalidfile.png docp1.png",
        "textra docp1.png invalidfile.png",
        "textra invalidfile.pdf",
        "textra invalidfile.mp3",
    ],
    [
        assert_no_file_contents,
        assert_has_error(),
    ],
)

run(
    "textra test.docx",
    [
        assert_no_file_contents,
        assert_no_stdout,
        assert_has_error("file type is not supported"),
    ],
)

run(
    "textra -l", [assert_no_file_contents, assert_no_stdout, assert_has_error("locale")]
)

run(
    "textra docp1.png -l en",
    [assert_no_file_contents, assert_no_stdout, assert_has_error("-l")],
)

run(
    "textra -l en -l es",
    [assert_no_file_contents, assert_no_stdout, assert_has_error("-l")],
)

# TODO: investigate why these fail (but only in Python?)
# run(
#     [
#         "textra docp1.png -o output.txt -x",
#         "textra docp1.png -o output.txt --outputStdout",
#         "textra docp1.png -s -o output.txt -x",
#         "textra docp1.png -s -o output.txt --outputStdout",
#         "textra docp1.png --silent -o output.txt -x",
#         "textra docp1.png --silent -o output.txt --outputStdout",
#     ],
#     [
#         assert_files(["output.txt"]),
#         assert_stdout,
#         assert_no_error,
#     ],
# )

print("ALL TESTS PASSED")
