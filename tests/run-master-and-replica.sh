#!/bin/bash

set -e
set -x

umask 0007

docker=${docker:-docker}

sudo=sudo

VOLUME=${VOLUME:-/tmp/freeipa-test-$$/data}

function wait_for_ipa_container() {
	set +x
	N="$1" ; shift
	set -e
	$docker logs -f "$N" &
	trap "kill $! 2> /dev/null || : ; trap - RETURN EXIT" RETURN EXIT
	EXIT_STATUS=999
	while true ; do
		sleep 10
		status=$( $docker inspect "$N" --format='{{.State.Status}}' )
		if [ "$status" == exited -o "$status" == stopped ] ; then
			EXIT_STATUS=$( $docker inspect "$N" --format='{{.State.ExitCode}}' )
			echo "The container has exited with .State.ExitCode [$EXIT_STATUS]."
			break
		elif [ "$1" != "exit-on-finished" ] ; then
			# With exit-on-finished, we expect the container to exit, seeing it exited above
			STATUS=$( $docker exec "$N" systemctl is-system-running 2> /dev/null || : )
			if [ "$STATUS" == 'running' ] ; then
				echo "The container systemctl is-system-running [$STATUS]."
				EXIT_STATUS=0
				break
			elif [ "$STATUS" == 'degraded' ] ; then
				echo "The container systemctl is-system-running [$STATUS]."
				$docker exec "$N" systemctl
				$docker exec "$N" systemctl status
				EXIT_STATUS=1
				break
			fi
		fi
	done
	date
	if test -O $VOLUME/build-id ; then
		sudo=
	fi
	if [ "$EXIT_STATUS" -ne 0 ] ; then
		exit "$EXIT_STATUS"
	fi
	if $docker exec "$N" grep '^2' /data/volume-version \
		&& $docker diff "$N" | tee /dev/stderr | grep -Evf tests/docker-diff-ipa.out | grep . ; then
		exit 1
	fi
	MACHINE_ID=$( cat $VOLUME/etc/machine-id )
	# Check that journal landed on volume and not in host's /var/log/journal
	$sudo ls -la $VOLUME/var/log/journal/$MACHINE_ID
	if [ -e /var/log/journal/$MACHINE_ID ] ; then
		ls -la /var/log/journal/$MACHINE_ID
		exit 1
	fi
}

function run_ipa_container() {
	set +x
	IMAGE="$1" ; shift
	N="$1" ; shift
	set -e
	date
	HOSTNAME=ipa.example.test
	if [ "$N" == "freeipa-replica" ] ; then
		HOSTNAME=replica.example.test
		VOLUME=/tmp/freeipa-test-$$/data-replica
	fi
	mkdir -p $VOLUME
	OPTS=
	if [ "${docker%podman}" = "$docker" ] ; then
		OPTS="-v /sys/fs/cgroup:/sys/fs/cgroup:ro --sysctl net.ipv6.conf.all.disable_ipv6=0"
	fi
	if [ -n "$seccomp" ] ; then
		OPTS="$OPTS --security-opt=seccomp:$seccomp"
	fi
	(
	set -x
	umask 0
	$docker run $readonly_run -d --name "$N" -h $HOSTNAME \
		$OPTS \
		-v $VOLUME:/data:Z $DOCKER_RUN_OPTS \
		-e PASSWORD=Secret123 "$IMAGE" "$@"
	)
	wait_for_ipa_container "$N" "$@"
}

IMAGE="$1"

if [ "$readonly" == "--read-only" ] ; then
	readonly_run="$readonly --dns=127.0.0.1"
fi

if [ -f "$VOLUME/build-id" ] ; then
	# If we were given already populated volume, just run the container
	run_ipa_container $IMAGE freeipa-master exit-on-finished
else
	# Initial setup of the FreeIPA server
	dns_opts="--auto-reverse --allow-zone-overlap"
	if [ "$replica" = 'none' ] ; then
		dns_opts=""
	fi
	run_ipa_container $IMAGE freeipa-master exit-on-finished -U -r EXAMPLE.TEST --setup-dns --no-forwarders $dns_opts --no-ntp $ca

	if [ -n "$ca" ] ; then
		$docker rm -f freeipa-master
		date
		$sudo cp tests/generate-external-ca.sh $VOLUME/
		$docker run --rm -v $VOLUME:/data:Z --entrypoint /data/generate-external-ca.sh "$IMAGE"
		# For external CA, provide the certificate for the second stage
		run_ipa_container $IMAGE freeipa-master exit-on-finished -U -r EXAMPLE.TEST --setup-dns --no-forwarders --no-ntp \
			--external-cert-file=/data/ipa.crt --external-cert-file=/data/ca.crt
	fi
fi

while [ -n "$1" ] ; do
	IMAGE="$1"
	$docker rm -f freeipa-master
	# Start the already-setup master server, or upgrade to next image
	run_ipa_container $IMAGE freeipa-master exit-on-finished
	shift
done

(
set -x
date
$docker stop freeipa-master
date
$docker start freeipa-master
)
wait_for_ipa_container freeipa-master

$docker rm -f freeipa-master
# Force "upgrade" path by simulating image change
$sudo mv $VOLUME/build-id $VOLUME/build-id.initial
uuidgen | $sudo tee $VOLUME/build-id
$sudo touch -r $VOLUME/build-id.initial $VOLUME/build-id
run_ipa_container $IMAGE freeipa-master

# Wait for the services to start to the point when SSSD is operational
for i in $( seq 1 20 ) ; do
	if $docker exec freeipa-master id admin 2> /dev/null ; then
		break
	fi
	if [ "$((i % 5))" == 1 ] ; then
		echo "Waiting for SSSD in the container to start ..."
	fi
	sleep 5
done
(
set -x
$docker exec freeipa-master bash -c 'yes Secret123 | kinit admin'
$docker exec freeipa-master ipa user-add --first Bob --last Nowak bob$$
$docker exec freeipa-master id bob$$

$docker exec freeipa-master ipa-adtrust-install -a Secret123 --netbios-name=EXAMPLE -U
)

if [ "$replica" = 'none' ] ; then
	echo OK $0.
	exit
fi

# Setup replica
readonly_run="$readonly"
MASTER_IP=$( $docker inspect --format '{{ .NetworkSettings.IPAddress }}' freeipa-master )
DOCKER_RUN_OPTS="--dns=$MASTER_IP"
if [ "$docker" != "sudo podman" -a "$docker" != "podman" ] ; then
	DOCKER_RUN_OPTS="--link freeipa-master:ipa.example.test $DOCKER_RUN_OPTS"
fi
SETUP_CA=--setup-ca
if [ $(( $RANDOM % 2 )) == 0 ] ; then
	SETUP_CA=
fi
run_ipa_container $IMAGE freeipa-replica no-exit ipa-replica-install -U --principal admin $SETUP_CA --no-ntp
date
if $docker diff freeipa-master | tee /dev/stderr | grep -Evf tests/docker-diff-ipa.out | grep . ; then
	exit 1
fi
if [ -z "$SETUP_CA" ] ; then
	$docker exec freeipa-replica ipa-ca-install -p Secret123
	$docker exec freeipa-replica systemctl is-system-running
fi
echo OK $0.
