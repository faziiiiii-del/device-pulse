#!/bin/sh
# Xcode Cloud runs this after cloning the repo and before resolving
# dependencies/opening the project. project.yml is this project's source of
# truth; DevicePulse.xcodeproj is committed too (Xcode Cloud needs it present
# to detect the project when a workflow is first created), but regenerating
# it here guards against the committed copy drifting out of sync with
# project.yml on any given commit.
set -e

brew install xcodegen

cd "$CI_PRIMARY_REPOSITORY_PATH"
xcodegen generate
