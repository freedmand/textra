import subprocess
import os
import tempfile
import shutil
from distutils.dir_util import copy_tree

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
        stderr=subprocess.STDOUT,
    )

    # Get the stdout and stderr
    stdout = result.stdout.decode("utf-8")

    return stdout


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
    output = run_command(textra_command, temp_dir)

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
    return output, new_file_contents


# textra -> should result in no files produced
output, files = run_test("textra")
assert not files, "Expected no output files"

# textra docp1.png -> should result in docp1.txt
output, files = run_test("textra docp1.png")
assert len(files) == 1, "Should have extracted 1 file"
assert has_content(files["docp1.txt"])

# textra docp1.png doc2.png -> should be an error (no output directory)
output, files = run_test("textra docp1.png docp2.png")
assert "must be a directory" in output
assert not files, "Expected no output files"

# textra docp1.png doc2.png doc.txt -> should be an error (no output directory)
output, files = run_test("textra docp1.png docp2.png doc.txt")
assert "must be a directory" in output
assert not files, "Expected no output files"

# textra docp1.png doc2.png doc-{}.txt -> should be an error (no output directory)
output, files = run_test("textra docp1.png docp2.png doc-{}.txt")
assert "must be a directory" in output
assert not files, "Expected no output files"

# textra docp1.png docp2.png docp3.png output -> should result in output/docp1.txt, output/docp2.txt, output/docp3.txt
output, files = run_test("textra docp1.png docp2.png docp3.png output")
assert len(files) == 3, "Should have extracted 3 files"
assert has_content(files["output/docp1.txt"])
assert has_content(files["output/docp2.txt"])
assert has_content(files["output/docp3.txt"])

# textra doc_3.pdf -> should result in doc_3/1.txt, doc_3/2.txt, doc_3/3.txt
output, files = run_test("textra doc_3.pdf")
assert len(files) == 3, "Should have extracted 3 files"
assert has_content(files["doc_3/1.txt"])
assert has_content(files["doc_3/2.txt"])
assert has_content(files["doc_3/3.txt"])

# textra doc_3.pdf output -> should result in output/1.txt, output/2.txt, output/3.txt
output, files = run_test("textra doc_3.pdf output")
assert len(files) == 3, "Should have extracted 3 files"
assert has_content(files["output/1.txt"])
assert has_content(files["output/2.txt"])
assert has_content(files["output/3.txt"])

# textra doc_3.pdf output-{}.txt -> should result in output-1.txt, output-2.txt, output-3.txt
output, files = run_test("textra doc_3.pdf output-{}.txt")
assert len(files) == 3, "Should have extracted 3 files"
assert has_content(files["output-1.txt"])
assert has_content(files["output-2.txt"])
assert has_content(files["output-3.txt"])

# textra doc_3.pdf output.txt -> should result in an error (must contain a pattern)
output, files = run_test("textra doc_3.pdf output.txt")
assert "must contain a pattern" in output
assert not files, "Expected no output files"

# textra zzz -> should result in an error (does not exist)
output, files = run_test("textra zzz")
assert "does not exist" in output
assert not files, "Expected no output files"

# textra test_empty_dir -> should result in an error (is a directory)
output, files = run_test("textra test_empty_dir")
assert "is a directory" in output
assert not files, "Expected no output files"

print("ALL TESTS PASSED")
