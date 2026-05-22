#!/usr/bin/env python3

from pathlib import Path
from subprocess import run
import os
import sys
import yaml
import getopt

def clone_tree():
	try:
		makefile = eve +"/Makefile"
		if Path(makefile).is_file():
			print("### EVE checkout is already present. Please run --rebase")
			sys.exit(-1)

		print("### Cloning tree")
		Path(eve).mkdir(exist_ok=True, parents=True)
		if git_ref != "":
			run(["git", "clone", "--reference", git_ref, config["repo"], eve], check=True)
		else:
			run(["git", "clone", config["repo"], eve], check=True)
		print("### Clone done")
	except:
		print("### Cloning the tree failed")
		sys.exit(1)

def fetch_tree():
	try:
		makefile = eve +"/Makefile"
		if not Path(makefile).is_file():
			print("### EVE checkout is not present. Please run --setup")
			sys.exit(-1)

		print("### Fetch tree")
		os.chdir(eve)
		run(["git", "fetch"], check=True)
		print("### Fetch done")
	except:
		print("### Fetching the tree failed")
		sys.exit(1)
	finally:
		os.chdir(base_dir)

def reset_tree():
	try:
		print("### Resetting tree")
		os.chdir(eve)
		run(
			["git", "checkout", config["branch"]], check=True,
		)
		run(
			["git", "reset", "--hard", config.get("revision", config["branch"])],
			check=True,
		)
		run(
			["../cache-setup.sh", config.get("revision", config["branch"])],
			check=True,
		)
		print("### Reset done")
	except:
		print("### Resetting tree failed")
		sys.exit(1)
	finally:
		os.chdir(base_dir)

def setup_tree():
	try:
		print("### Applying patches")

		patches = []
		for folder in config.get("patch_folders", []):
			patch_folder = base_dir / folder
			if not patch_folder.is_dir():
				print(f"Patch folder {patch_folder} not found")
				sys.exit(-1)

			print(f"Adding patches from {patch_folder}")

			patches.extend(
				sorted(list((base_dir / folder).glob("*.patch")), key=os.path.basename)
		)

		print(f"Found {len(patches)} patches")

		os.chdir(eve)

		for patch in patches:
			run(["git", "am", "-3", str(base_dir / patch)], check=True)
		print("### Patches done")

		# Replace eve/profiles with a symlink to the repo's profiles/,
		# so profile YAMLs stay editable on the repo root.
		run(["rm", "-rf", "profiles"], check=True)
		run(["ln", "-s", str(base_dir / "profiles"), "profiles"], check=True)
		print("### Profiles linked from repo")
	except:
		print("### Setting up the tree failed")
		sys.exit(1)
	finally:
		os.chdir(base_dir)

def update_patches():
	import tempfile
	import shutil
	try:
		print("### Updating patches")
		patches_dir = base_dir / "patches"
		with tempfile.TemporaryDirectory() as tmpdir:
			os.chdir(eve)
			run(
				["git", "format-patch", "--no-numbered", config.get("revision", config["branch"]), "-o", tmpdir],
				check=True,
			)
			os.chdir(base_dir)
			patches_dir.mkdir(exist_ok=True)
			new_names = set()
			for new_patch in sorted(Path(tmpdir).glob("*.patch")):
				new_names.add(new_patch.name)
				dst = patches_dir / new_patch.name
				if dst.exists():
					with open(new_patch) as f:
						new_lines = f.read().splitlines(keepends=True)
					with open(dst) as f:
						old_lines = f.read().splitlines(keepends=True)
					# Line 1 is "From <sha> Mon Sep 17 00:00:00 2001". The
					# <sha> changes on every git-am replay even when the
					# patch's substantive content (author, date, subject,
					# body, diff) is unchanged. Skip rewriting the file in
					# that case so re-running --update is a clean no-op
					# when nothing actually changed.
					if new_lines[1:] == old_lines[1:]:
						continue
				shutil.copy2(new_patch, dst)
			# Drop any patches that fell out of the series.
			for existing in patches_dir.glob("*.patch"):
				if existing.name not in new_names:
					existing.unlink()
		print("### Updating done")
	except:
		print("### updating failed failed")
		sys.exit(1)
	finally:
		os.chdir(base_dir)


base_dir = Path.cwd().absolute()
setup = False
update = False
rebase = False
config = "config.yml"
eve = "eve"
git_ref = ""

try:
	opts, args = getopt.getopt(sys.argv[1:], "srd:c:f:u2", ["setup", "rebase", "config=", "folder=", "reference=", "update", "20x", "directory=" ])
except getopt.GetoptError as err:
	print(err)
	sys.exit(2)


for o, a in opts:
	if o in ("-s", "--setup"):
		setup = True
	elif o in ("-r", "--rebase"):
		rebase = True
	elif o in ("-u", "--update"):
		update = True
	elif o in ("-c", "--config"):
		config = a
	elif o in ("--reference"):
		git_ref = a
	elif o in ("-d", "--directory"):
		eve = a
	else:
		assert False, "unhandled option"

if not Path(config).is_file():
	print(f"Missing {config}")
	sys.exit(1)
config = yaml.safe_load(open(config))

if "output_dir" in config:
	eve = config["output_dir"]

if setup:
	clone_tree()
	reset_tree()
	setup_tree()
elif rebase:
	fetch_tree()
	reset_tree()
	setup_tree()
elif update:
	update_patches()
