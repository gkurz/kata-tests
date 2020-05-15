#!/bin/bash
# Copyright (c) 2018 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0

# Run a set of the metrics tests to gather data to be used with the report
# generator. The general ideal is to have the tests configured to generate
# useful, meaninful and repeatable (stable, with minimised variance) results.
# If the tests have to be run more or longer to achieve that, then generally
# that is fine - this test is not intended to be quick, it is intended to
# be repeatable.

# Note - no 'set -e' in this file - if one of the metrics tests fails
# then we wish to continue to try the rest.
# Finally at the end, in some situations, we explicitly exit with a
# failure code if necessary.

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "${SCRIPT_DIR}/../lib/common.bash"
RESULTS_DIR=${SCRIPT_DIR}/../results

# Get working elasticsearch version
VERSIONS_FILE="${SCRIPT_DIR}/../../versions.yaml"

# By default we run all the tests
RUN_ALL=1

help() {
	usage=$(cat << EOF
Usage: $0 [-h] [options]
   Description:
        This script gathers a number of metrics for use in the
        report generation script. Which tests are run can be
        configured on the commandline. Specifically enabling
        individual tests will disable the 'all' option, unless
        'all' is also specified last.
   Options:
        -a,         Run all tests (default).
        -d,         Run the density tests.
        -h,         Print this help.
        -n,         Run the networking tests.
        -s,         Run the storage tests.
        -t,         Run the time tests.
EOF
)
	echo "$usage"
}

# Set up the initial state
init() {
	metrics_onetime_init

	local OPTIND
	while getopts "adhnst" opt;do
		case ${opt} in
		a)
		    RUN_ALL=1
		    ;;
		d)
		    RUN_DENSITY=1
		    RUN_ALL=
		    ;;
		h)
		    help
		    exit 0;
		    ;;
		n)
		    RUN_NETWORK=1
		    RUN_ALL=
		    ;;
		s)
		    RUN_STORAGE=1
		    RUN_ALL=
		    ;;
		t)
		    RUN_TIME=1
		    RUN_ALL=
		    ;;
		?)
		    # parse failure
		    help
		    die "Failed to parse arguments"
		    ;;
		esac
	done
	shift $((OPTIND-1))
}

run_density_ksm() {
	echo "Running KSM density tests"

	# Extract these early, so we fail early - otherwise it could be quite annoying if we spent minutes
	# to get half way through the tests only to fail for some missing binary or file...
	ELASTICSEARCH_VERSION=$("${GOPATH}/bin/yq" read "$VERSIONS_FILE" "docker_images.elasticsearch.version")
	ELASTICSEARCH_IMAGE="elasticsearch:$ELASTICSEARCH_VERSION"

	# Run the memory footprint test - the main test that
	# KSM affects. Run for a sufficient number of containers
	# (that gives us a fair view of how memory gets shared across
	# containers), and a large enough timeout  for KSM to settle.
	# If KSM has not settled down by then, just take the measurement.
	# 'auto' mode should detect when KSM has settled automatically.
	bash density/docker_memory_usage.sh 20 300 auto

	# Grab scaling system level footprint data for different sized
	# container workloads - with KSM enabled.

	# busybox - small container
	export PAYLOAD_SLEEP="1"
	export PAYLOAD="busybox"
	export PAYLOAD_ARGS="tail -f /dev/null"
	export PAYLOAD_RUNTIME_ARGS=" -m 2G"
	bash density/footprint_data.sh

	# mysql - medium sized container
	# Need to wait for mysql to boot and settle before we measure
	export PAYLOAD_SLEEP="10"
	export PAYLOAD="mysql"
	PAYLOAD_ARGS=" --innodb_use_native_aio=0 --disable-log-bin"
	PAYLOAD_RUNTIME_ARGS=" -m 4G -e MYSQL_ALLOW_EMPTY_PASSWORD=1"
	bash density/footprint_data.sh

	# elasticsearch - large container
	# Need to wait for elasticsearch to boot and settle before we measure
	export PAYLOAD_SLEEP="10"
	export PAYLOAD=$ELASTICSEARCH_IMAGE
	PAYLOAD_ARGS=" "
	PAYLOAD_RUNTIME_ARGS=" -m 8G"
	bash density/footprint_data.sh

	# Get a measure for the overhead we take from the container memory
	bash density/memory_usage_inside_container.sh
}

run_density() {
	echo "Running non-KSM density tests"

	# Run the density tests - no KSM, so no need to wait for settle
	# Set a token short timeout, and use enough containers to get a
	# good average measurement.
	bash density/docker_memory_usage.sh 20 5
}

run_time() {
	echo "Running time tests"
	# Run the time tests - take time measures for an ubuntu image, over
	# 100 'first and only container' launches.
	# NOTE - whichever container you test here must support a full 'date'
	# command - busybox based containers (including Alpine) will not work.
	bash time/launch_times.sh -i ubuntu -n 100
}

run_storage() {
	echo "Running storage tests"

	# Enable this if you want to test a volume mount
	#export TEST_VOLUME_MOUNT=1
	bash storage/fio.sh
}

run_network() {
	bash network/cpu_statistics_iperf.sh
}

# Execute metrics scripts
run() {
	pushd "$SCRIPT_DIR/.."

	# If KSM is available on this platform, let's run any tests that are
	# affected by having KSM on/off first, and then turn it off for the
	# rest of the tests, as KSM may introduce some extra noise in the
	# results by stealing CPU time for instance.
	if [[ -f ${KSM_ENABLE_FILE} ]]; then
		# No point enabling and disabling KSM if we have nothing to test.
		if [ -n "$RUN_ALL" ] || [ -n "$RUN_DENSITY" ]; then
			save_ksm_settings
			trap restore_ksm_settings EXIT QUIT KILL
			set_ksm_aggressive

			run_density_ksm

			# And now ensure KSM is turned off for the rest of the tests
			disable_ksm
		fi
	else
		echo "No KSM control file, skipping KSM tests"
	fi

	if [ -n "$RUN_ALL" ] || [ -n "$RUN_TIME" ]; then
		run_time
	fi

	if [ -n "$RUN_ALL" ] || [ -n "$RUN_DENSITY" ]; then
		run_density
	fi

	if [ -n "$RUN_ALL" ] || [ -n "$RUN_STORAGE" ]; then
		run_storage
	fi

	if [ -n "$RUN_ALL" ] || [ -n "$RUN_NETWORK" ]; then
		run_network
	fi

	popd
}

finish() {
	echo "Now please create a suitably descriptively named subdirectory in"
	echo "$RESULTS_DIR and copy the .json results files into it before running"
	echo "this script again."
}

init "$@"
run
finish

