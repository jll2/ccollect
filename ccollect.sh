#!/bin/sh
# Nico Schottelius
# written for SyGroup (www.sygroup.ch)
# Date: Mon Nov 14 11:45:11 CET 2005
# Last Modified: 

#
# where to find our configuration and temporary file
#
CCOLLECT_CONF=${CCOLLECT_CONF:-/etc/ccollect}
CSOURCES=$CCOLLECT_CONF/sources
CDEFAULTS=$CCOLLECT_CONF/defaults
TMP=$(mktemp /tmp/$(basename $0).XXXXXX)
WE=$(basename $0)

#
# unset parallel execution
#
PARALLEL=""

#
# catch signals
#
trap "rm -f \"$TMP\"" 1 2 15


#
# output and errors
#
errecho()
{
   echo "[$name][err] $@" >&2
}

stdecho()
{
   echo "[$name] $@"
}

add_name()
{
   sed "s/^/\[$name\] /"
}

#
# Tell how to use us
#
usage()
{
   echo "$WE: <intervall name> [args] <sources to backup>"
   echo ""
   echo "   Nico Schottelius (nico-linux-ccollect schottelius.org) - 2005-12-06"
   echo ""
   echo "   Backup data pseudo incremental"
   echo ""
   echo "   -h, --help:          Show this help screen"
   echo "   -p, --parallel:      Parellize backup process"
   echo "   -a, --all:           Backup all sources specified in $CSOURCES"
   echo "   -v, --verbose:       Be very verbose."
   echo ""
   echo "   Retrieve latest ccollect at http://linux.schottelius.org/ccollect/."
   echo ""
   exit 0
}

#
# need at least intervall and one source or --all
#
if [ $# -lt 2 ]; then
   usage
fi

#
# check for configuraton directory
#
if [ ! -d "$CCOLLECT_CONF" ]; then
   errecho "Configuration \"$CCOLLECT_CONF\" not found."
   exit 1
fi

#
# Filter arguments
#

INTERVALL=$1; shift

i=1
no_shares=0

while [ $i -le $# ]; do
   eval arg=\$$i
   
   if [ "$NO_MORE_ARGS" = 1 ]; then
        eval share_${no_shares}=\"$arg\"
        no_shares=$[$no_shares+1]
   else
      case $arg in
         -a|--all)
            ALL=1
            ;;
         -v|--verbose)
            VERBOSE=1
            ;;
         -p|--parallel)
            PARALLEL="&"
            ;;
         -h|--help)
            usage
            ;;
         --)
            NO_MORE_ARGS=1
            ;;
         *)
            eval share_${no_shares}=\"$arg\"
            no_shares=$[$no_shares+1]
            ;;
      esac
   fi

   i=$[$i+1]
done

#
# be really really really verbose
#
if [ "$VERBOSE" = 1 ]; then
   set -x
fi

#
# Look, if we should take ALL sources
#
if [ "$ALL" = 1 ]; then
   # reset everything specified before
   no_shares=0
   
   #
   # get entries from sources
   #
   cwd=$(pwd)
   cd "$CSOURCES";
   ls > "$TMP"
   
   while read tmp; do
      eval share_${no_shares}=\"$tmp\"
      no_shares=$[$no_shares+1]
   done < "$TMP"
fi

#
# Need at least ONE source to backup
#
if [ "$no_shares" -lt 1 ]; then
   usage   
else
   echo "==> $WE: Beginning backup using intervall $INTERVALL <=="
fi

#
# check default configuration
#

D_FILE_INTERVALL="$CDEFAULTS/intervalls/$INTERVALL"
D_INTERVALL=$(cat $D_FILE_INTERVALL 2>/dev/null)

#
# Let's do the backup
#
i=0
while [ "$i" -lt "$no_shares" ]; do

   #
   # Standard locations
   #
   eval name=\$share_${i}
   backup="$CSOURCES/$name"
   c_source="$backup/source"
   c_dest="$backup/destination"
   c_exclude="$backup/exclude"
   c_verbose="$backup/verbose"
   c_rsync_extra="$backup/rsync_options"

   stdecho "Beginning to backup this source ..."
   i=$[$i+1]
   
   #
   # Standard configuration checks
   #
   if [ ! -e "$backup" ]; then
      errecho "Source does not exist."
      continue
   fi
   if [ ! -d "$backup" ]; then
      errecho "\"$name\" is not a cconfig-directory. Skipping."
      continue
   fi

   #
   # intervall definition: First try source specific, fallback to default
   #
   c_intervall="$(cat "$backup/intervalls/$INTERVALL" 2>/dev/null)"

   if [ -z "$c_intervall" ]; then
      c_intervall=$D_INTERVALL

      if [ -z "$c_intervall" ]; then
         errecho "Default and source specific intervall missing. Skipping."
         continue
      fi
   fi

   #
   # standard rsync options
   #
   VERBOSE=""
   EXCLUDE=""
   RSYNC_EXTRA=""

   #
   # next configuration checks
   #
   if [ ! -f "$c_source" ]; then
      stdecho "Source description $c_source is not a file. Skipping."
      continue
   else
      source=$(cat "$c_source")
      if [ $? -ne 0 ]; then
         stdecho "Skipping: Source $c_source is not readable"
         continue
      fi
   fi

   if [ ! -d "$c_dest" ]; then
      errecho "Destination $c_dest does not link to a directory. Skipping"
      continue
   fi

   # exclude
   if [ -f "$c_exclude" ]; then
      EXCLUDE="--exclude-from=$c_exclude"
   fi
   
   # extra options for rsync
   if [ -f "$c_rsync_extra" ]; then
      RSYNC_EXTRA="$(cat "$c_rsync_extra")"
   fi
   
   # verbose
   if [ -f "$c_verbose" ]; then
      VERBOSE="-v"
   fi
   
   #
   # check if maximum number of backups is reached, if so remove
   #
   
   # the created directories are named $INTERVALL.$DATE
   count=$(ls -d "$c_dest/${INTERVALL}."?*  2>/dev/null | wc -l)
   stdecho "Currently $count backup(s) exist, total keeping $c_intervall backup(s)."
   
   if [ "$count" -ge "$c_intervall" ]; then
      substract=$(echo $c_intervall - 1 | bc)
      remove=$(echo $count - $substract | bc)
      stdecho "Removing $remove backup(s)..."

      ls -d "$c_dest/${INTERVALL}."?* | sort -n | head -n $remove > "$TMP"
      while read to_remove; do
         dir="$to_remove"
         stdecho "Removing $dir ..."
         rm -rf "$dir" 2>&1 | add_name
      done < "$TMP"
   fi
   
   #
   # clone the old directory with hardlinks
   #

   destination_date=$(date +%Y-%m-%d-%H:%M)
   destination_dir="$c_dest/${INTERVALL}.${destination_date}.$$"
   
   last_dir=$(ls -d "$c_dest/${INTERVALL}."?* 2>/dev/null | sort -n | tail -n 1)
   
   # give some info
   stdecho "Beginning to backup, this may take some time..."

   # only copy if a directory exists
   if [ "$last_dir" ]; then
      stdecho "Hard linking..."
      cp -al $VERBOSE "$last_dir" "$destination_dir" 2>&1 | add_name
   else
      stdecho "Creating $destination_dir"
      mkdir "$destination_dir" 2>&1 | add_name
   fi

   if [ $? -ne 0 ]; then
      errecho "Creating/cloning backup directory failed. Skipping backup."
      continue
   fi

   #
   # the rsync part
   # options stolen shameless from rsnapshot
   #
   
   stdecho "Transferring files..."
   rsync -a $VERBOSE $RSYNC_EXTRA $EXCLUDE \
      --delete --numeric-ids --relative --delete-excluded \
      "$source" "$destination_dir" 2>&1 $PARALLEL | add_name
   
   if [ $? -ne 0 ]; then
      errecho "rsync failed, backup may be broken (see rsync errors)"
      continue
   fi
   
   stdecho "Successfully finished backup."
done

#
# Be a good parent and wait for our children, if they are running wild parallel
#
if [ "$PARALLEL" ]; then
   echo "Waiting for rsync jobs to complete..."
   wait
fi

rm -f "$TMP"
echo "==> Finished $WE <=="
