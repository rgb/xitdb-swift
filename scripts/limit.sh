# Sourced by scripts/check.sh, which sets `platform` (Darwin or Linux) first.
#
# Every run of the tests has a time limit. Nothing ended a test that waited for ever:
# the gate sat there until somebody looked, and what the test was waiting in was gone
# when they ended it. A run that passes its limit is looked at before it is ended, so
# that the gate's output says where it stood: on macOS a sample of the test process, on
# Linux each of its threads by name and state. Then the run is killed with everything
# below it, and the step fails.
#
# SwiftPM runs the tests in a process of its own, its helper on macOS
# (swiftpm-testing-helper) and the tests' runner on Linux (XitDBTests-test-runner);
# ending `swift test` alone leaves that process behind with every thread it had. It is
# below `swift test`, so it is killed with it, and test_processes_left names any that
# is still there afterwards.
#
# A limit is for the run and not for a build: each `swift test` in the gate is given
# `--skip-build` after a build of its own, so that a cold build is not what runs out of
# time. The simulator's runs build as they go, and their limit allows for it.
#
# What holds this, and what does not. The gate tries the limit at every run, on macOS
# and on Linux, with a test planted to sleep (the step "A run of the tests that does not
# end is ended" in check.sh): the run ended, the look in the output, no test process
# left. On an iOS simulator it is not tried by the gate, where it would cost a minute
# and a half each time; it was tried by hand, and is tried again like this, after the
# gate's simulator build, with the first iPhone the gate would take:
#
#     platform=Darwin; source scripts/limit.sh
#     limited 90 env TEST_RUNNER_XITDB_GATE_PLANT_A_TEST_WITHOUT_END=1 \
#         xcodebuild test-without-building -scheme xitdb-swift-Package \
#         -destination "platform=iOS Simulator,name=iPhone 17" \
#         -derivedDataPath .build/xcodebuild-ios -configuration Release \
#         -only-testing:XitDBTests/GatePlantTests
#
# (`TEST_RUNNER_` carries the variable into the simulator.) It has to give 124 after 90
# seconds with a sample of the simulator's test process in its output, and leave no
# xctest agent of this package behind: the simulator ends its test process when
# xcodebuild is killed.

# The processes whose parent is the one given.
children_of() {
    if [ "$platform" = Darwin ]; then
        pgrep -P "$1" 2>/dev/null || true
    else
        # The container has no pgrep. "pid (name) state parent …": the name may hold
        # spaces and brackets, so the parent is read after the last ")".
        local stat pid
        for stat in /proc/[0-9]*/stat; do
            if [ "$(sed 's/.*) [A-Za-z] \([0-9]*\) .*/\1/' "$stat" 2>/dev/null)" = "$1" ]; then
                pid=${stat#/proc/}
                echo "${pid%/stat}"
            fi
        done
    fi
}

# Every process below one, the deepest first.
descendants() {
    local child
    for child in $(children_of "$1"); do
        descendants "$child"
        echo "$child"
    done
}

# The words a process was started with.
command_of() {
    if [ "$platform" = Darwin ]; then
        ps -o command= -p "$1" 2>/dev/null || true
    else
        tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null || true
    fi
}

# The process that runs the tests of a run: below `swift test` it is SwiftPM's helper
# on macOS, or xctest with the bundle, and the tests' runner on Linux.
#
# An iOS simulator's test process is not below xcodebuild: launchd_sim starts it, and
# it is Xcode's xctest agent with no arguments, so nothing in a command line says whose
# tests it runs. It is known by the test bundle it has open, which lies in this
# package's derived data; a simulator run of another project beside this one has
# another bundle open and is left alone.
simulator_agent="iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest"
test_process_of() {
    local pid
    for pid in $(descendants "$1"); do
        case "$(command_of "$pid")" in
        *swiftpm-testing-helper* | *-test-runner* | *.xctest*)
            echo "$pid"
            return
            ;;
        esac
    done
    if [ "$platform" = Darwin ]; then
        for pid in $(pgrep -f "$simulator_agent" 2>/dev/null || true); do
            if lsof -p "$pid" 2>/dev/null | grep -q "$PWD/.build/xcodebuild-ios"; then
                echo "$pid"
                return
            fi
        done
    fi
}

# What a process is doing: on macOS a sample of it, on Linux each thread's name, its
# state (R running, S sleeping, D waiting for a drive) and how many there are of each.
look_at() {
    echo "---- the test process $1, when its time was up:"
    if [ "$platform" = Darwin ]; then
        sample "$1" 1 2>/dev/null | sed -n '/^Call graph:/,/^Total number in stack/p' || true
    else
        local thread
        for thread in /proc/"$1"/task/*; do
            echo "$(cat "$thread/comm" 2>/dev/null) $(sed 's/.*) \([A-Za-z]\) .*/\1/' "$thread/stat" 2>/dev/null)"
        done | LC_ALL=C sort | uniq -c
    fi
    echo "----"
}

# The processes that run this package's tests and are still there. There must be none
# once a run has ended or has been ended.
test_processes_left() {
    if [ "$platform" = Darwin ]; then
        pgrep -f "swiftpm-testing-helper.*$PWD/" 2>/dev/null || true
    else
        local pid
        for pid in /proc/[0-9]*; do
            case "$(tr '\0' ' ' <"$pid/cmdline" 2>/dev/null)" in
            "$PWD/"*-test-runner* | *"$PWD/"*.xctest*) echo "${pid#/proc/}" ;;
            esac
        done
    fi
}

# limited <seconds> <command…>: runs a command and gives its status, or ends it when
# its time is up, after a look at its test process, and gives 124.
limited() {
    local seconds=$1
    shift
    "$@" &
    local runner=$! began=$SECONDS watched left
    while kill -0 "$runner" 2>/dev/null; do
        if [ $((SECONDS - began)) -ge "$seconds" ]; then
            echo
            echo "error: the run did not end within $seconds seconds: $*"
            watched=$(test_process_of "$runner")
            if [ -n "$watched" ]; then
                look_at "$watched"
            else
                echo "---- no test process was found below it"
            fi
            # shellcheck disable=SC2046
            kill -9 $(descendants "$runner") "$runner" ${watched:+"$watched"} 2>/dev/null || true
            wait "$runner" 2>/dev/null || true
            for left in $(test_processes_left); do
                kill -9 "$left" 2>/dev/null || true
            done
            return 124
        fi
        sleep 0.2
    done
    wait "$runner"
}
