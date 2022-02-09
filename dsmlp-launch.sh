#!/bin/bash

# FD 3= informational messages initially routed to STDERR but suppressible via "-q" quiet flag
exec 3>&2

# Load libraries
BASEDIR=${BASEDIR:-$(dirname $(cd $(dirname ${BASH_SOURCE[0]}) && pwd))}
LIBDIR=${BASEDIR}/lib
source "${LIBDIR}/jq_helpers.sh"

#########
# Set up our core K8S environment vars (username, UID, kubectl location)
source "${LIBDIR}/kubevars.sh"

########
# Set up some local helper variables

# Some help/debugging information references the script name; when used with a wrapper script
# K8S_CONFIG_SOURCE contains the name of that wrapper for display.
K8S_CONFIG_SOURCE=${K8S_CONFIG_SOURCE:-${BASH_SOURCE[0]}}

# Save script original arguments (prior to parsing)
ORIGINAL_LAUNCH_ARGV=("$@")

#########
# Include launch.sh modules
source "${LIBDIR}/init_podspec.sh"
source "${LIBDIR}/pod_resources.sh"
source "${LIBDIR}/pod_lifecycle.sh"
source "${LIBDIR}/pod_security.sh"
source "${LIBDIR}/pod_scheduling.sh"
source "${LIBDIR}/legacy_proxy.sh"
source "${LIBDIR}/sshd_support.sh"
source "${LIBDIR}/codeserver_support.sh"
source "${LIBDIR}/jupyter_support.sh"
source "${LIBDIR}/job_support.sh"
source "${LIBDIR}/env_vars.sh"
source "${LIBDIR}/nbmessages.sh"
source "${LIBDIR}/extra_nfs.sh"
source "${LIBDIR}/teams_mount.sh"

# FIXME these should all accept env var overrides
function configure_defaults() {
    K8S_IMAGE_PULL_POLICY=${K8S_IMAGE_PULL_POLICY:-IfNotPresent}
    K8S_PRIORITY_CLASS_NAME=${K8S_PRIORITY_CLASS_NAME:-normal}
    FOLLOW_LOGS=NO
    SPAWN_INTERACTIVE_SHELL=${SPAWN_INTERACTIVE_SHELL:-YES}
    K8S_DOCKER_IMAGE=${K8S_DOCKER_IMAGE:-"ucsdets/scipy-ml-notebook:2021.3-stable"}
    K8S_NUM_GPU=${K8S_NUM_GPU:-0}
    K8S_NUM_CPU=${K8S_NUM_CPU:-1}
    K8S_GB_MEM=${K8S_GB_MEM:-1}
    QUIET_MODE=NO
    BACKGROUND_JOB=NO
    K8S_NODENUM=${K8S_NODENUM:-}
    K8S_TEMPLATE=${K8S_TEMPLATE:-${LIBDIR}/standard_pod_template.json}

    BATCH_CMDLINE=()
    LEGACY_PROXY=YES

    K8S_ENABLE_CODESERVER=${K8S_ENABLE_CODESERVER:-NO}
    K8S_ENABLE_JUPYTER=${K8S_ENABLE_JUPYTER:-YES}
    K8S_ENABLE_SSHD=${K8S_ENABLE_SSHD:-NO}
    K8S_ENABLE_TEAMS_MOUNT=${K8S_ENABLE_TEAMS_MOUNT:-NO}

    # Accomodate legacy env var name
    K8S_PRIMARY_GROUP=${K8S_GROUPNAME:-}
}


#################
# Functions added to these lists will be called at various points in the job lifecycle
PRE_LAUNCH_HOOKS=()
FIRST_LAUNCH_HOOKS=()
LAUNCH_HOOKS=()
FINAL_LAUNCH_HOOKS=()
MONITOR_HOOKS=()
CLEANUP_HOOKS=()

###########
## Utility functions

function init_traps() {
    trap "REASON=trap-EXIT; run_cleanup_hooks" EXIT
    trap "REASON=trap-INT; run_cleanup_hooks" INT
}

function clear_traps() {
    trap EXIT 2>/dev/null || true
    trap INT 2>/dev/null || true
}

function display_help() {

# K8S_CONFIG_SOURCE used here in case launch.sh is called from a wrapper script.
cat <<EOM  >&2
Usage: ${K8S_CONFIG_SOURCE} [<args>] [command to execute within container]

Launches a Kubernetes pod (container) within the DSMLP environment with optional interactive shell
and Jupyter notebook, configurable CPU/RAM/GPU limits.

Use "-i <image spec>" to specify a custom image name, "-s" to inhibit Jupyter startup if needed.

Online documentation:
    How to Launch Containers From the Command Line:
    https://support.ucsd.edu/services?id=kb_article_view&sysparm_article=KB0032269

    How to Select and Configure Your Container:
    https://support.ucsd.edu/services?id=kb_article_view&sysparm_article=KB0032273

    Building Your Own Custom Image:
    https://github.com/ucsd-ets/datahub-example-notebook

EOM

if [ "${K8S_CONFIG_SOURCE}" != "${BASH_SOURCE[0]}" ]; then
    cat <<EOM >&2

Calling script specified the following command line:
    "${ORIGINAL_LAUNCH_ARGV[@]}"

EOM
fi

echo "Command line options:"
# Parse per-argument help text ("ARG HELP: (arg): (description)" below) from our source code
grep "## ARG HELP:" ${BASH_SOURCE[0]} | grep -v grep | sed -e 's/^.*ARG HELP: */  /' | while IFS=: read a b; do
    c=$(echo $b | sed -e 's/^ *//')
    printf "       %-18s     %s\\n" "$a" "$c" >&2
done

}

function parse_arguments() {
    local OPTIND=1 OPTARG opt 

    while getopts "dsbqfHhrc:g:G:m:p:v:i:N:n:F:jJSPVT" opt; do
        case $opt in
            G)  ## ARG HELP:  -G <groupname>: Designate primary Unix GroupID within container 
                K8S_PRIMARY_GROUP="${OPTARG}"
                ;;
            s)  ## ARG HELP:  -s: Launch only CLI shell; do not launch Jupyter notebook server
                #"Shell" => implies no jupyter in legacy launch.sh
                K8S_ENABLE_JUPYTER=NO
                ;;
            S)  ## ARG HELP:  -S: Do not launch container CLI shell 
                #No shell
                SPAWN_INTERACTIVE_SHELL=NO
                ;;
            b)  ## ARG HELP:  -b: Background (batch) job; disable Jupyter and interactive shell
                # "Batch"
                K8S_ENABLE_JUPYTER=NO
                SPAWN_INTERACTIVE_SHELL=NO
                BACKGROUND_JOB=YES
                ;;
            q)  ## ARG HELP:  -q: Quiet mode - suppress informational messages during container launch.
                QUIET_MODE=YES
                ;;
            f)  ## ARG HELP:  -f: Execute command, dump job output to stdout; implies -S (no shell), -J (no Jupyter)
                SPAWN_INTERACTIVE_SHELL=NO
                K8S_ENABLE_JUPYTER="NO"
                FOLLOW_LOGS=YES
                ;;
            H)  ## ARG HELP:  -H: Launch sshd within container for use with ProxyCommand (see documentation)
                K8S_ENABLE_SSHD=YES
                K8S_ENABLE_JUPYTER=NO
                SPAWN_INTERACTIVE_SHELL=NO
                K8S_ENABLE_CODESERVER=NO
                QUIET_MODE=YES
                ;;
            h)  ## ARG HELP:  -h: Display usage instructions
                display_help
                exit 0
                ;;
            r)  ## ARG HELP:  -r: Legacy option (ignored) - to execute commands within container, simply append to command line.
                # no-op 
                ;;
            c)  ## ARG HELP:  -c ##: Specify number of CPU cores assigned to container
                if ! [[ $OPTARG =~ ^[.[:digit:]]+$ ]]; then
                    echo "Error: Invalid cpu specification: $OPTARG" >&2; exit 1
                fi
    
                K8S_NUM_CPU=$OPTARG
                ;;
            g)  ## ARG HELP:  -g ##: Specify number of GPU assigned to container
                if ! [[ $OPTARG =~ ^[0-9]+$ ]]; then
                    echo "Error: Non-numeric #gpu: $OPTARG" >&2; exit 1
                fi
    
                K8S_NUM_GPU="$OPTARG"
                ;;
            m)  ## ARG HELP:  -g ##: Specify RAM (GB) assigned to container
                if ! [[ $OPTARG =~ ^[.[:digit:]]+$ ]]; then
                    echo "Error: Invalid memory specification: $OPTARG" >&2; exit 1
                fi
    
                K8S_GB_MEM=$OPTARG
                ;;
            p)  ## ARG HELP:  -p ##: Specify priority (low|normal) assigned to container
                if ! [[ $OPTARG =~ ^(low|normal)$ ]]; then
                    echo "Error: Invalid priority specification: $OPTARG" >&2; exit 1
                fi
    
                K8S_PRIORITY_CLASS_NAME=$OPTARG
                ;;
            v)  ## ARG HELP:  -v <model>: Specify GPU model (1070ti|1080ti|2080ti|rtxtitan) for container
                if [[ $OPTARG =~ ^(1080ti|1070ti|2080ti|rtxtitan)$ ]]; then
                    K8S_GPU_MODEL_NAME=$OPTARG
                else
                    echo "Error: Invalid gpu type specification: $OPTARG" >&2; exit 1
                fi
                ;;
            P)  ## ARG HELP: -P: Inhibit legacy (socat) proxy
                LEGACY_PROXY=NO
                ;;
            i)  ## ARG HELP: -i <img>:  Specify alternate Docker image name
                K8S_DOCKER_IMAGE="$OPTARG"
                ;;
            F)  ## ARG HELP: -F <mntspec>:  NFS mount additional filesytem(s) into pod; mntspec=/mntpoint:server_fqdn:/path[,/mnt2:server2:/path2[,...]]
                # setup_extra_nfs_mount can cope with empty comma-separated argument
                K8S_EXTRA_NFS_MOUNT="${K8S_EXTRA_NFS_MOUNT},$OPTARG"
                ;;
            N)  ## ARG HELP: -N <name>:  Specify alternate Pod name
                K8S_POD_NAME="$OPTARG"
                ;;
            n)  ## ARG HELP: -n <node>:  Launch job on specific Node; can be numeric (e.g. "23") or a hostname ("its-dsmlp-n01")
                K8S_NODENUM="$OPTARG"
                ;;
            j)  ## ARG HELP: -j:  launch Jupyter notebook server within container (default)
                K8S_ENABLE_JUPYTER="YES"
                ;;
            J)  ## ARG HELP: -J:  inhibit launch of Jupyter notebook server
                K8S_ENABLE_JUPYTER="NO"
                ;;
            T)  ## ARG HELP: -T:  Mount /teams filesystem into pod
                K8S_ENABLE_TEAMS_MOUNT="YES"
                ;;
            V)  ## ARG HELP: -V:  Enable legacy (non-SSH-based) CodeServer
                K8S_ENABLE_CODESERVER="YES"
                ;;
            d)  ## ARG HELP:  -d: Dump Kubernetes Pod spec (JSON) - do not execute
                ## ARG HELP: --:  End processing of command line; remaining arguments are passed to container 
                # sneaking that second help line here since "--" doesn't have an explicit getopts stanza
                DUMP_PODSPEC_STDOUT=YES
                ;;
            \?)
                echo "Invalid option: -$OPTARG" >&2
                exit 1
                ;;
            :)
                echo "Option -$OPTARG requires an argument." >&2
                exit 1
                ;;
        esac
    done
    
   # If additional command line arguments supplied, treat as batch command
   # (and inhibit Jupyter)
   if (( $# >= $OPTIND )); then
        shift $(( $OPTIND -1 ))
        BATCH_CMDLINE=("$@")
        K8S_ENABLE_JUPYTER=NO
   fi

}

function prelaunch_display_podname() {
    echo $(date) "Submitting job ${K8S_POD_NAME}" 1>&3
}

function run_setup() {

    setup_initial_podspec
   
    setup_pod_scheduling

    PRE_LAUNCH_HOOKS+=( "init_traps" "prelaunch_display_podname" )
    FIRST_LAUNCH_HOOKS+=( "launch_podspec" "monitor_launch" )

    # App setup (jupyter/code-server) under legacy proxy requires
    # that the port forwarding mappings be already established
    [ "$LEGACY_PROXY" = "YES" ] &&          setup_legacy_proxy

    (( ${#BATCH_CMDLINE[@]} ))              && setup_batch
    [ "$K8S_ENABLE_JUPYTER" = "YES" ]       && setup_jupyter
    [ "$K8S_ENABLE_CODESERVER" = "YES" ]    && setup_codeserver
    [ "$K8S_ENABLE_TEAMS_MOUNT" = "YES" ]   && setup_teams_mount
    [ "$K8S_ENABLE_SSHD" = "YES" ]          && setup_sshd
    [ "$FOLLOW_LOGS" = "YES" ]              && setup_follow_logs
    [ "$SPAWN_INTERACTIVE_SHELL" = "YES" ]  && setup_interactive_shell
    [ "$CN_CMD_MODIFIED" = "NO" ]           && setup_fallback_pause

    # This should come last to permit SSH/Jupyter/etc jobs to be backgrounded
    [ "$BACKGROUND_JOB" = "YES" ]           && setup_background_job

    [ "${K8S_EXPORT_ENV_PREFIX}" ]          && setup_extra_env_vars 

    [ "${K8S_EXTRA_NFS_MOUNT}" ]          && setup_extra_nfs_mount

    setup_gpu

    setup_cpu_limits
    setup_mem_limits

    setup_legacy_security_context
    setup_security_context

    setup_nbmessages

    # Dump final podspec if requested (implies exit)
    [ "$DUMP_PODSPEC_STDOUT" = "YES" ]      && launch_dump_podspec && exit 0

    CLEANUP_HOOKS+=( "clear_traps" "cleanup_pod" )
}

function main() {

    configure_defaults

    parse_arguments "$@"

    [ "$QUIET_MODE" = "YES" ] && exec 3>/dev/null

    run_setup 

    run_prelaunch_hooks
    run_launch_hooks

    run_monitor_hooks
    run_cleanup_hooks

    exit 0
}

#################################
# Must remain at bottom of script to prevent forward references!
# (inhibit option in case we source this script into a wrapper, rather than 
# the traditional exec-from-wrapper)
[ "$INHIBIT_LAUNCH_SH_MAIN" ] || main "$@"
