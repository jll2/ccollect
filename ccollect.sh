#!/bin/sh
# 
# 2005-2009 Nico Schottelius (nico-ccollect at schottelius.org)
# 
# This file is part of ccollect.
#
# ccollect is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# ccollect is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with ccollect. If not, see <http://www.gnu.org/licenses/>.
#
# Initially written for SyGroup (www.sygroup.ch)
# Date: Mon Nov 14 11:45:11 CET 2005

# Error upon expanding unset variables:
set -u

#
# Standard variables (stolen from cconf)
#
__pwd="$(pwd -P)"
__mydir="${0%/*}"; __abs_mydir="$(cd "$__mydir" && pwd -P)"
__myname=${0##*/}; __abs_myname="$__abs_mydir/$__myname"

#
# where to find our configuration and temporary file
#
CCOLLECT_CONF=${CCOLLECT_CONF:-/etc/ccollect}
CSOURCES=${CCOLLECT_CONF}/sources
CDEFAULTS=${CCOLLECT_CONF}/defaults
CPREEXEC="${CDEFAULTS}/pre_exec"
CPOSTEXEC="${CDEFAULTS}/post_exec"

TMP=$(mktemp "/tmp/${__myname}.XXXXXX")
VERSION=0.7.1
RELEASE="2009-02-02"
HALF_VERSION="ccollect ${VERSION}"
FULL_VERSION="ccollect ${VERSION} (${RELEASE})"

#
# CDATE: how we use it for naming of the archives
# DDATE: how the user should see it in our output (DISPLAY)
# TSORT: how to sort: tc = ctime, t = mtime
#
CDATE="date +%Y%m%d-%H%M"
DDATE="date +%Y-%m-%d-%H:%M:%S"
TSORT="tc"

#
# unset parallel execution
#
PARALLEL=""

#
# catch signals
#
trap "rm -f \"${TMP}\"" 1 2 15

#
# Functions
#

# time displaying echo
_techo()
{
   echo "$(${DDATE}): $@"
}

# exit on error
_exit_err()
{
   _techo "$@"
   rm -f "${TMP}"
   exit 1
}

add_name()
{
   awk "{ print \"[${name}] \" \$0 }"
}

pcmd()
{
   if [ "$remote_host" ]; then
      ssh "$remote_host" "$@"
   else
      "$@"
   fi
}

#
# Version
#
display_version()
{
   echo "${FULL_VERSION}"
   exit 0
}

#
# Tell how to use us
#
usage()
{
   echo "${__myname}: <interval name> [args] <sources to backup>"
   echo ""
   echo "   ccollect creates (pseudo) incremental backups"
   echo ""
   echo "   -h, --help:          Show this help screen"
   echo "   -p, --parallel:      Parallelise backup processes"
   echo "   -a, --all:           Backup all sources specified in ${CSOURCES}"
   echo "   -v, --verbose:       Be very verbose (uses set -x)"
   echo "   -V, --version:       Print version information"
   echo ""
   echo "   This is version ${VERSION}, released on ${RELEASE}"
   echo "   (the first version was written on 2005-12-05 by Nico Schottelius)."
   echo ""
   echo "   Retrieve latest ccollect at http://unix.schottelius.org/ccollect/"
   exit 0
}

#
# need at least interval and one source or --all
#
if [ $# -lt 2 ]; then
   if [ "$1" = "-V" -o "$1" = "--version" ]; then
      display_version
   else
      usage
   fi
fi

#
# check for configuraton directory
#
[ -d "${CCOLLECT_CONF}" ] || _exit_err "No configuration found in " \
   "\"${CCOLLECT_CONF}\" (is \$CCOLLECT_CONF properly set?)"

#
# Filter arguments
#
export INTERVAL="$1"; shift
i=1
no_sources=0

#
# Capture options and create source "array"
#
WE=""
ALL=""
NO_MORE_ARGS=""
while [ "$#" -ge 1 ]; do
   eval arg=\"\$1\"; shift

   if [ "${NO_MORE_ARGS}" = 1 ]; then
        eval source_${no_sources}=\"${arg}\"
        no_sources=$((${no_sources}+1))
        
        # make variable available for subscripts
        eval export source_${no_sources}
   else
      case "${arg}" in
         -a|--all)
            ALL=1
            ;;
         -v|--verbose)
            set -x
            ;;
         -p|--parallel)
            PARALLEL=1
            ;;
         -h|--help)
            usage
            ;;
         --)
            NO_MORE_ARGS=1
            ;;
         *)
            eval source_${no_sources}=\"$arg\"
            no_sources=$(($no_sources+1))
            ;;
      esac
   fi

   i=$(($i+1))
done

# also export number of sources
export no_sources

#
# Look, if we should take ALL sources
#
if [ "${ALL}" = 1 ]; then
   # reset everything specified before
   no_sources=0

   #
   # get entries from sources
   #
   cwd=$(pwd -P)
   ( cd "${CSOURCES}" && ls > "${TMP}" ); ret=$?

   [ "${ret}" -eq 0 ] || _exit_err "Listing of sources failed. Aborting."

   while read tmp; do
      eval source_${no_sources}=\"${tmp}\"
      no_sources=$((${no_sources}+1))
   done < "${TMP}"
fi

#
# Need at least ONE source to backup
#
if [ "${no_sources}" -lt 1 ]; then
   usage
else
   _techo "${HALF_VERSION}: Beginning backup using interval ${INTERVAL}"
fi

#
# Look for pre-exec command (general)
#
if [ -x "${CPREEXEC}" ]; then
   _techo "Executing ${CPREEXEC} ..."
   "${CPREEXEC}"; ret=$?
   _techo "Finished ${CPREEXEC} (return code: ${ret})."

   [ "${ret}" -eq 0 ] || _exit_err "${CPREEXEC} failed. Aborting"
fi

#
# check default configuration
#

D_FILE_INTERVAL="${CDEFAULTS}/intervals/${INTERVAL}"
D_INTERVAL=$(cat "${D_FILE_INTERVAL}" 2>/dev/null)


#
# Let's do the backup
#
i=0
while [ "${i}" -lt "${no_sources}" ]; do

   #
   # Get current source
   #
   eval name=\"\$source_${i}\"
   i=$((${i}+1))

   export name

   #
   # start ourself, if we want parallel execution
   #
   if [ "${PARALLEL}" ]; then
      "$0" "${INTERVAL}" "${name}" &
      continue
   fi

#
# Start subshell for easy log editing
#
(
   #
   # Stderr to stdout, so we can produce nice logs
   #
   exec 2>&1

   #
   # Configuration
   #
   backup="${CSOURCES}/${name}"
   c_source="${backup}/source"
   c_dest="${backup}/destination"
   c_pre_exec="${backup}/pre_exec"
   c_post_exec="${backup}/post_exec"
   for opt in exclude verbose very_verbose rsync_options summary delete_incomplete remote_host ; do
      if [ -f "${backup}/$opt" -o -f "${backup}/no_$opt"  ]; then
         eval c_$opt=\"${backup}/$opt\"
      else
         eval c_$opt=\"${CDEFAULTS}/$opt\"
      fi
   done

   #
   # Marking backups: If we abort it's not removed => Backup is broken
   #
   c_marker=".ccollect-marker"

   #
   # Times
   #
   begin_s=$(date +%s)

   _techo "Beginning to backup"

   #
   # Standard configuration checks
   #
   if [ ! -e "${backup}" ]; then
      _exit_err "Source does not exist."
   fi

   #
   # configuration _must_ be a directory
   #
   if [ ! -d "${backup}" ]; then
      _exit_err "\"${name}\" is not a cconfig-directory. Skipping."
   fi

   #
   # first execute pre_exec, which may generate destination or other
   # parameters
   #
   if [ -x "${c_pre_exec}" ]; then
      _techo "Executing ${c_pre_exec} ..."
      "${c_pre_exec}"; ret="$?"
      _techo "Finished ${c_pre_exec} (return code ${ret})."

      if [ "${ret}" -ne 0 ]; then
         _exit_err "${c_pre_exec} failed. Skipping."
      fi
   fi

   #
   # interval definition: First try source specific, fallback to default
   #
   c_interval="$(cat "${backup}/intervals/${INTERVAL}" 2>/dev/null)"

   if [ -z "${c_interval}" ]; then
      c_interval="${D_INTERVAL}"

      if [ -z "${c_interval}" ]; then
         _exit_err "No definition for interval \"${INTERVAL}\" found. Skipping."
      fi
   fi

   #
   # Source checks
   #
   if [ ! -f "${c_source}" ]; then
      _exit_err "Source description \"${c_source}\" is not a file. Skipping."
   else
      source=$(cat "${c_source}"); ret="$?"
      if [ "${ret}" -ne 0 ]; then
         _exit_err "Source ${c_source} is not readable. Skipping."
      fi
   fi

   #
   # Verify source is up and accepting connections before deleting any old backups
   #
   rsync "${source}" >/dev/null || _exit_err "Source ${source} is not readable. Skipping."

   #
   # Destination is a path
   #
   if [ ! -f "${c_dest}" ]; then
      _exit_err "Destination ${c_dest} is not a file. Skipping."
   else
      ddir=$(cat "${c_dest}"); ret="$?"
      if [ "${ret}" -ne 0 ]; then
         _exit_err "Destination ${c_dest} is not readable. Skipping."
      fi
   fi

   #
   # do we backup to a remote host? then set pre-cmd
   #
   if [ -f "${c_remote_host}" ]; then
      # adjust ls and co
      remote_host=$(cat "${c_remote_host}"); ret="$?"
      if [ "${ret}" -ne 0 ]; then
         _exit_err "Remote host file ${c_remote_host} exists, but is not readable. Skipping."
      fi
      destination="${remote_host}:${ddir}"
   else
      remote_host=""
      destination="${ddir}"
   fi
   export remote_host

   #
   # check for existence / use real name
   #
   ( pcmd cd "$ddir" ) || _exit_err "Cannot change to ${ddir}. Skipping."


   # NEW method as of 0.6:
   # - insert ccollect default parameters
   # - insert options
   # - insert user options
   
   #
   # rsync standard options
   #

   set -- "$@" "--archive" "--delete" "--numeric-ids" "--relative"   \
               "--delete-excluded" "--sparse" 

   #
   # exclude list
   #
   if [ -f "${c_exclude}" ]; then
      set -- "$@" "--exclude-from=${c_exclude}"
   fi

   #
   # Output a summary
   #
   if [ -f "${c_summary}" ]; then
      set -- "$@" "--stats"
   fi

   #
   # Verbosity for rsync, rm, and mkdir
   #
   VVERBOSE=""
   if [ -f "${c_very_verbose}" ]; then
      set -- "$@" "-vv"
      VVERBOSE="-v"
   elif [ -f "${c_verbose}" ]; then
      set -- "$@" "-v"
   fi

   #
   # extra options for rsync provided by the user
   #
   if [ -f "${c_rsync_options}" ]; then
      while read line; do
         set -- "$@" "$line"
      done < "${c_rsync_options}"
   fi

   #
   # Check for incomplete backups
   #
   pcmd ls -1 "$ddir/${INTERVAL}"*".${c_marker}" 2>/dev/null | while read marker; do
      incomplete="$(echo ${marker} | sed "s/\\.${c_marker}\$//")"
      _techo "Incomplete backup: ${incomplete}"
      if [ -f "${c_delete_incomplete}" ]; then
         _techo "Deleting ${incomplete} ..."
         pcmd rm $VVERBOSE -rf "${incomplete}" || \
            _exit_err "Removing ${incomplete} failed."
         pcmd rm $VVERBOSE -f "${marker}" || \
            _exit_err "Removing ${marker} failed."
      fi
   done

   #
   # check if maximum number of backups is reached, if so remove
   # use grep and ls -p so we only look at directories
   #
   count="$(pcmd ls -p1 "${ddir}" | grep "^${INTERVAL}\..*/\$" | wc -l \
      | sed 's/^ *//g')"  || _exit_err "Counting backups failed"

   _techo "Existing backups: ${count} Total keeping backups: ${c_interval}"
   
   if [ "${count}" -ge "${c_interval}" ]; then
      substract=$((${c_interval} - 1))
      remove=$((${count} - ${substract}))
      _techo "Removing ${remove} backup(s)..."

      pcmd ls -${TSORT}p1r "$ddir" | grep "^${INTERVAL}\..*/\$" | \
        head -n "${remove}" > "${TMP}"      || \
        _exit_err "Listing old backups failed"

      i=0
      while read to_remove; do
         eval remove_$i=\"${to_remove}\"
         i=$(($i+1))
      done < "${TMP}"

      j=0
      while [ "$j" -lt "$i" ]; do
         eval to_remove=\"\$remove_$j\"
         _techo "Removing ${to_remove} ..."
         pcmd rm ${VVERBOSE} -rf "${ddir}/${to_remove}" || \
            _exit_err "Removing ${to_remove} failed."
         j=$(($j+1))
      done
   fi


   #
   # Check for backup directory to clone from: Always clone from the latest one!
   #
   # Use ls -1c instead of -1t, because last modification maybe the same on all
   # and metadate update (-c) is updated by rsync locally.
   #
   last_dir="$(pcmd ls -${TSORT}p1 "${ddir}" | grep '/$' | head -n 1)" || \
      _exit_err "Failed to list contents of ${ddir}."
   
   #
   # clone from old backup, if existing
   #
   if [ "${last_dir}" ]; then
      set -- "$@" "--link-dest=${ddir}/${last_dir}"
      _techo "Hard linking from ${last_dir}"
   fi
      

   # set time when we really begin to backup, not when we began to remove above
   destination_date=$(${CDATE})
   destination_dir="${ddir}/${INTERVAL}.${destination_date}.$$"
   destination_full="${destination}/${INTERVAL}.${destination_date}.$$"

   # give some info
   _techo "Beginning to backup, this may take some time..."

   _techo "Creating ${destination_dir} ..."
   pcmd mkdir ${VVERBOSE} "${destination_dir}" || \
      _exit_err "Creating ${destination_dir} failed. Skipping."

   #
   # added marking in 0.6 (and remove it, if successful later)
   #
   pcmd touch "${destination_dir}.${c_marker}"

   #
   # the rsync part
   #

   _techo "Transferring files..."
   rsync "$@" "${source}" "${destination_full}"; ret=$?

   #
   # remove marking here
   #
   pcmd rm "${destination_dir}.${c_marker}" || \
      _exit_err "Removing ${destination_dir}/${c_marker} failed."

   _techo "Finished backup (rsync return code: $ret)."
   if [ "${ret}" -ne 0 ]; then
      _techo "Warning: rsync exited non-zero, the backup may be broken (see rsync errors)."
   fi

   #
   # post_exec
   #
   if [ -x "${c_post_exec}" ]; then
      _techo "Executing ${c_post_exec} ..."
      "${c_post_exec}"; ret=$?
      _techo "Finished ${c_post_exec}."

      if [ ${ret} -ne 0 ]; then
         _exit_err "${c_post_exec} failed."
      fi
   fi

   # Calculation
   end_s=$(date +%s)

   full_seconds=$((${end_s} - ${begin_s}))
   hours=$((${full_seconds} / 3600))
   seconds=$((${full_seconds} - (${hours} * 3600)))
   minutes=$((${seconds} / 60))
   seconds=$((${seconds} - (${minutes} * 60)))

   _techo "Backup lasted: ${hours}:${minutes}:${seconds} (h:m:s)"

) | add_name
done

#
# Be a good parent and wait for our children, if they are running wild parallel
#
if [ "${PARALLEL}" ]; then
   _techo "Waiting for children to complete..."
   wait
fi

#
# Look for post-exec command (general)
#
if [ -x "${CPOSTEXEC}" ]; then
   _techo "Executing ${CPOSTEXEC} ..."
   "${CPOSTEXEC}"; ret=$?
   _techo "Finished ${CPOSTEXEC} (return code: ${ret})."

   if [ ${ret} -ne 0 ]; then
      _techo "${CPOSTEXEC} failed."
   fi
fi

rm -f "${TMP}"
_techo "Finished ${WE}"
