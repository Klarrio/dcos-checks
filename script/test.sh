#!/bin/bash
# This script performs tests against the dcos-checks project, specifically:
#
#   * gofmt         (https://golang.org/cmd/gofmt)
#   * goimports     (https://godoc.org/cmd/goimports)
#   * golint        (https://github.com/golang/lint)
#   * go vet        (https://golang.org/cmd/vet)
#   * test coverage (https://blog.golang.org/cover)
#
# It outputs test and coverage reports in a way that Jenkins can understand,
# with test results in JUnit format and test coverage in Cobertura format.
# The reports are saved to build/component/{test-reports,coverage-reports}/*.xml
#
set -e
set -o pipefail
export PATH="${GOPATH}/bin:${PATH}"

if [ $# -ne 1 ]; then
    echo "usage: $0 test_suite"
    exit 1
fi

TEST_SUITE="$1"; shift

SOURCE_DIR=$(git rev-parse --show-toplevel)
BUILD_DIR="${SOURCE_DIR}/build"

function logmsg {
    echo -e "\n\n*** $1 ***\n"
}

function _gofmt {
    logmsg "Running 'gofmt' ..."
    test -z "$(gofmt -l -d $(find . -type f -name '*.go' -not -path './vendor/**') | tee /dev/stderr)"
}

function _goimports {
    logmsg "Running 'goimports' ..."
    go get -u golang.org/x/tools/cmd/goimports
    test -z "$(goimports -l -d $(find . -type f -name '*.go' -not -path "./vendor/**") | tee /dev/stderr)"
}

function _golint {
    local test_dirs="$1"
    local ignore_dirs="$2"
    logmsg "Running 'go lint' ..."
    go get -u github.com/golang/lint/golint
    test -z "$(golint $test_dirs | grep -v vendor | grep -v $ignore_dirs | tee /dev/stderr)"
}

function _govet {
    local packages="$@"
    logmsg "Running 'go vet' ..."
    go vet $(go list . ./... | grep -v vendor) | tee /dev/stderr
}

function _dockerd {
    logmsg "Launching dockerd"
    dockerd > /dev/null 2>&1 &
    sleep 5
}

function _unittest_with_coverage {
    local package_dirs="$1"
    local ignore_packages="$2"
    local covermode="atomic"
    logmsg "Running unit tests ..."

    go get -u github.com/jstemmer/go-junit-report
    go get -u github.com/smartystreets/goconvey
    go get -u golang.org/x/tools/cmd/cover
    go get -u github.com/axw/gocov/...
    go get -u github.com/AlekSi/gocov-xml

    # We can't' use the test profile flag with multiple packages. Therefore,
    # run 'go test' for each package, and concatenate the results into
    # 'profile.cov'.
    mkdir -p ${BUILD_DIR}/{test-reports,coverage-reports}
    echo "mode: ${covermode}" > ${BUILD_DIR}/coverage-reports/profile.cov

    for import_path in $(go list -f={{.ImportPath}} ${package_dirs} | grep -v vendor); do
        package=$(basename ${import_path})
        [[ "$ignore_packages" =~ $package ]] && continue

        go test -v -tags="$TEST_SUITE" -covermode=$covermode               \
            -coverprofile="${BUILD_DIR}/coverage-reports/profile_${package}.cov" \
            $import_path | tee /dev/stderr                                       \
            | go-junit-report > "${BUILD_DIR}/test-reports/${package}-report.xml"

    done

    # Concatenate per-package coverage reports into a single file.
    for f in ${BUILD_DIR}/coverage-reports/profile_*.cov; do
        tail -n +2 ${f} >> ${BUILD_DIR}/coverage-reports/profile.cov
        rm $f
    done

    go tool cover -func ${BUILD_DIR}/coverage-reports/profile.cov
    gocov convert ${BUILD_DIR}/coverage-reports/profile.cov \
        | gocov-xml > "${BUILD_DIR}/coverage-reports/coverage.xml"
}


# Main. Example usage: ./test.sh TEST_SUITE
function main {
    local test_dirs="./"
    local package_dirs="./..."
    local ignore_packages="metricsSchema"

    if [[ $TEST_SUITE == "unit" ]]; then
        _gofmt
        _goimports
        _golint "$package_dirs" "$ignore_packages"
        _dockerd
        _unittest_with_coverage "$package_dirs" "$ignore_packages"
    else
        echo "Unsupported test suite '${TEST_SUITE}'"
        exit 1
    fi
}

main
