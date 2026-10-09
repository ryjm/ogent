# Recorder only: trace this fixture, never its actual makem child.
case "$0" in */test/makem-report-tests.sh) set -x ;; esac
